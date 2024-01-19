---
title: "动态gRPC-HTTP代理（五）：代理"
description: "http代理gRPC服务"
keywords: "grpc,http"

date: 2024-01-19T15:50:20+08:00
lastmod: 2024-01-19T15:50:20+08:00

categories:
  - 项目实战
tags:
  - go
  - grpc

toc: true
url: "post/project-grpc-5.html"
---

代理模块作为最外层的关键组件，统一处理外部HTTP请求、调用底层模块进行gRPC转换，并返回HTTP响应。本文将详细介绍代理模块的设计理念、核心功能和实现细节，以构建一个高效、稳定、可扩展的代理服务。

<!--more-->

# 实现

我们的代理模块最终会返回go标准包`http.HandlerFunc`，并且用`option`设计提供一系列自定义配置和操作。
接下里，我将一步步实现我们的代理模块。

## 提取grpc服务
当有请求过来时，我们需要请求对应的grpc服务是哪个，因此我们在最前面得先提取出来。
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), p.opts.timeout)
		defer cancel()

		target, path := p.opts.pathExtract(r.URL.Path)
		if target == "" || path == "" {
			p.opts.log.Warn("path not found", "path", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		...
```
默认我们可以以路径的第一个参数作为我们服务的`taget`，并自动转发到`target:50051`的服务上，后续为其proto定义的路径。
```go
// DefaultPathExtract 格式：/target/route*
func DefaultPathExtract(path string) (string, string) {
	parts := strings.Split(path, "/")
	if len(parts) < 3 {
		return "", ""
	}
	target := fmt.Sprintf("%s:50051", parts[1])
	route := strings.TrimPrefix(path, fmt.Sprintf("/%s", parts[1]))
	return target, route
}
```

## 获取grpc客户端
知道了grpc服务后，我们就可以初始化我们的grpc客户端。
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		...

		client, err := p.Client(ctx, target)
		if err != nil {
			p.opts.log.Warn("target not found", "target", target)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		
		...
```
这里我们可以用`sync.Map`存储之前已经初始化好的，不需要每次http调用我们都去创建一次grpc连接。
```go
func (p *Proxy) Client(ctx context.Context, target string) (*ReflectClient, error) {
	client, ok := p.srv.Load(target)
	if ok {
		return client.(*ReflectClient), nil
	}
	c, err := NewReflectClient(ctx, target, p.opts.log, p.opts.grpcOpts)
	if err != nil {
		return nil, err
	}
	p.srv.Store(target, c)
	return c, nil
}
```

## 获取grpc方法
初始化好后，就通过路径匹配proto声明的方法
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		...

		md, params := client.MethodParams(r.Method, path)
		if md == nil {
			p.opts.log.Warn("path not found", "path", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		
		...
```

## 请求转换
确定了服务的方法后，我们就需要将HTTP请求参数转换成proto二进制数据
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		...
		
		msg := dynamic.NewMessage(md.GetInputType())
		if err = RequestEncode(r, msg, params); err != nil {
			p.opts.log.Error("request encode", "err", err)
			p.opts.errDecoder(w, err)
			return
		}
		
		...
```
这里用到我们之前实现的codec实现
```go
func CodecForRequest(r *http.Request, name string) encoding.Codec {
	for _, accept := range r.Header[name] {
		codec := encoding.CodecBySubtype(contentSubtype(accept))
		if codec != nil {
			return codec
		}
	}
	return encoding.CodecBySubtype(encoding.JsonSubType)
}

func RequestEncode(req *http.Request, msg *dynamic.Message, pathParams map[string]string) error {
	switch req.Method {
	case http.MethodGet, http.MethodDelete:
		return QueryEncode(req, msg, pathParams)
	case http.MethodPost, http.MethodPut, http.MethodPatch:
		return BodyEncode(req, msg, pathParams)
	}
	return nil
}

func QueryEncode(req *http.Request, msg *dynamic.Message, pathParams map[string]string) error {
	codec := encoding.CodecBySubtype(encoding.FormSubType)
	if err := codec.Unmarshal([]byte(req.URL.RawQuery), pathParams, msg); err != nil {
		return fmt.Errorf("codec unmarshal error: %v", err)
	}
	return nil
}

func BodyEncode(req *http.Request, msg *dynamic.Message, pathParams map[string]string) error {
	codec := CodecForRequest(req, "Content-Type")
	data, err := io.ReadAll(req.Body)
	if err != nil {
		return fmt.Errorf("read body error: %v", err)
	}
	defer req.Body.Close()
	if err = codec.Unmarshal(data, pathParams, msg); err != nil {
		return fmt.Errorf("codec unmarshal error: %v", err)
	}
	return nil
}
```

## grpc调用
转换完成后，就可以用反射直接动态调用grpc服务了
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		...

		ctx = metadata.NewOutgoingContext(ctx, p.metadataFromHeaders(r.Header))
		resp, header, err := client.Invoke(ctx, md, msg)
		if err != nil {
			p.opts.log.Error("client invoke", "err", err)
			p.opts.errDecoder(w, err)
			return
		}
		
		...
```
要注意将HTTP header转成grpc metadata
```go
func (p *Proxy) metadataFromHeaders(raw map[string][]string) metadata.MD {
	md := make(map[string][]string)
	for k, v := range raw {
		key, ok := p.opts.incomingHeaderMatcher(k)
		if !ok {
			continue
		}
		newKey := strings.ToLower(key)
		// https://github.com/grpc/grpc-go/blob/master/internal/transport/http2_server.go#L417
		if newKey == "connection" {
			continue
		}
		md[newKey] = v
	}
	return md
}
```
如果调用有错误，需要处理grpc和HTTP错误码的转换
```go
func DefaultHTTPError(w http.ResponseWriter, err error) {
	grpcStatus := status.Convert(err)
	w.WriteHeader(runtime.HTTPStatusFromCode(grpcStatus.Code()))
	w.Write([]byte(grpcStatus.Message()))
}
```

## 响应转换
最后就是将grpc返回转换成json格式返回
```go
func (p *Proxy) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		...

		h := p.HeadersFromMetadata(header)
		for k, vs := range h {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}

		if err = ResponseDecode(r, w, resp); err != nil {
			p.opts.log.Error("response decode", "err", err)
			p.opts.errDecoder(w, err)
			return
		}

		return
	}
}
```
还是使用之前实现的codec实现
```go
func ResponseDecode(r *http.Request, w http.ResponseWriter, msg *dynamic.Message) error {
	codec := CodecForRequest(r, "Accept")
	buf, err := codec.Marshal(msg)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return fmt.Errorf("failed to marshal output JSON: %v", err)
	}
	b, err := json.Marshal(Response{
		Status: 0,
		Data:   buf,
		Msg:    "ok",
	})
	if err != nil {
		return fmt.Errorf("failed to write response: %v", err)
	}
	w.WriteHeader(http.StatusOK)
	w.Header().Set("Content-Type", "application/"+codec.Subtype())
	if _, err = w.Write(b); err != nil {
		return fmt.Errorf("failed to write response: %v", err)
	}
	return nil
}

```

## 配置
为了应对不同使用者的需求，需要提供一些option给使用者，让proxy更加灵活
```go
type proxyOptions struct {
	log                   *slog.Logger
	timeout               time.Duration
	marshaler             *jsonpb.Marshaler
	unmarshaler           *jsonpb.Unmarshaler
	incomingHeaderMatcher runtime.HeaderMatcherFunc
	outgoingHeaderMatcher runtime.HeaderMatcherFunc
	pathExtract           PathExtractFunc
	errDecoder            ErrorDecodeFunc
	grpcOpts              []grpc.DialOption
}

func WithLogger(logger *slog.Logger) ProxyOption {
	return func(o *proxyOptions) {
		o.log = logger
	}
}

func WithMarshaler(m *jsonpb.Marshaler) ProxyOption {
	return func(o *proxyOptions) {
		o.marshaler = m
	}
}

func WithUnmarshaler(m *jsonpb.Unmarshaler) ProxyOption {
	return func(o *proxyOptions) {
		o.unmarshaler = m
	}
}

func WithIncomingHeaderMatcher(f runtime.HeaderMatcherFunc) ProxyOption {
	return func(o *proxyOptions) {
		o.incomingHeaderMatcher = f
	}
}

func WithOutgoingHeaderMatcher(f runtime.HeaderMatcherFunc) ProxyOption {
	return func(o *proxyOptions) {
		o.outgoingHeaderMatcher = f
	}
}

func WithPathExtract(f PathExtractFunc) ProxyOption {
	return func(o *proxyOptions) {
		o.pathExtract = f
	}
}

func WithTimeout(d time.Duration) ProxyOption {
	return func(o *proxyOptions) {
		o.timeout = d
	}
}

func WithErrDecode(f ErrorDecodeFunc) ProxyOption {
	return func(o *proxyOptions) {
		o.errDecoder = f
	}
}

func WithGrpcOpts(opts ...grpc.DialOption) ProxyOption {
	return func(o *proxyOptions) {
		o.grpcOpts = opts
	}
}
```

# 使用
只需要几行代码就能轻松将后台的grpc服务以HTTP方式暴露出去
```go
func main() {
	proxy := dynamic_proxy.NewProxy()
	http.HandleFunc("/", proxy.Handler())
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatalf("failed to http serve: %v", err)
	}
}
```
假设我后台目前有这样一个proto服务
```protobuf
// The greeting service definition.
service Greeter {
  // Sends a greeting
  rpc SayHello (HelloRequest) returns (HelloReply)  {
    option (google.api.http) = {
      get: "/helloworld/{name}"
    };
  }
}

// The request message containing the user's name.
message HelloRequest {
  string name = 1;
}

// The response message containing the greetings
message HelloReply {
  string message = 1;
}
```
这时候，比如我发送一个请求
```go
http://proxyAddr/grpcAddr/helloworld/dynamic-proxy
```
proxy服务收到这个请求后，就会转发到grpcAddr这个地址的服务上，并调用SayHello方法后返回。

# 总结
通过本文的介绍，您将深入了解代理模块在整个系统中的关键作用，以及如何设计和实现一个高效、可靠的代理模块来统一处理外部HTTP请求与gRPC转换。无论您是正在构建自己的代理服务还是对代理模块的设计感兴趣，本文都将为您提供有价值的见解和实用建议。

项目源码 https://github.com/lemon-1997/dynamic-grpc