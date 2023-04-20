---
title: "Google分布式框架Weaver（四）：多进程部署原理"
description: "使用weaver多进程部署时，服务如何注册，提供服务"
keywords: "weaver,微服务,部署"

publishDate: 2023-03-30T19:15:36+08:00
lastmod: 2023-03-30T19:15:36+08:00

categories:
- 框架教程
tags:
- go
- weaver
- 微服务

toc: true
url: "post/frame-weaver-4.html"
---

到上一小节，我们已经学会了如何去使用weaver进行项目开发，相信很多人对weaver的原理很感兴趣，想了解weaver内部到底是如何实现的。
这一节，我将介绍weaver在多进程部署中，组件之间的通信过程。

<!--more-->

# codegen
在看源码之前，我们可以先阅读weaver生成的代码。
```go
func init() {
	codegen.Register(codegen.Registration{
		Name:        "github.com\\lemon-1997\\weaver\\service\\product\\T",
		Iface:       reflect.TypeOf((*T)(nil)).Elem(),
		New:         func() any { return &impl{} },
		ConfigFn:    func(i any) any { return i.(*impl).WithConfig.Config() },
		LocalStubFn: func(impl any, tracer trace.Tracer) any { return t_local_stub{impl: impl.(T), tracer: tracer} },
		ClientStubFn: func(stub codegen.Stub, caller string) any {
			return t_client_stub{stub: stub, listMetrics: codegen.MethodMetricsFor(codegen.MethodLabels{Caller: caller, Component: "github.com\\lemon-1997\\weaver\\service\\product\\T", Method: "List"}), createMetrics: codegen.MethodMetricsFor(codegen.MethodLabels{Caller: caller, Component: "github.com\\lemon-1997\\weaver\\service\\product\\T", Method: "Create"}), updateMetrics: codegen.MethodMetricsFor(codegen.MethodLabels{Caller: caller, Component: "github.com\\lemon-1997\\weaver\\service\\product\\T", Method: "Update"}), deleteMetrics: codegen.MethodMetricsFor(codegen.MethodLabels{Caller: caller, Component: "github.com\\lemon-1997\\weaver\\service\\product\\T", Method: "Delete"})}
		},
		ServerStubFn: func(impl any, addLoad func(uint64, float64)) codegen.Server {
			return t_server_stub{impl: impl.(T), addLoad: addLoad}
		},
	})
}
```
这里可以看到codegen会注册我们的组件，比较重要的是这三个函数`LocalStubFn`，`ClientStubFn`，`ServerStubFn`。
1. `LocalStubFn`返回本地调用对象`t_local_stub`，`t_local_stub`实现了`product/T`的接口。
2. `ClientStubFn`返回RPC客户端`t_client_stub`，`t_client_stub`实现了`product/T`的接口。
3. `ServerStubFn`返回RPC服务端`t_server_stub`，`t_server_stub`处理来自`t_client_stub`的调用。

这里估计大多数应该可以猜到，`LocalStubFn`是用于单进程部署，而`ClientStubFn`，`ServerStubFn`则会在多进程部署用到。

# weavelet
`weavelet`在weaver中是用来管理组件，每个进程中都会有一个weavelet（通过weaver.Init创建）。
```go
func Init(ctx context.Context) Instance {
	root, err := initInternal(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, fmt.Errorf("error initializing Service Weaver: %w", err))
		os.Exit(1)
	}
	return root
}

func initInternal(ctx context.Context) (Instance, error) {
	wlet, err := newWeavelet(ctx, codegen.Registered())
	if err != nil {
		return nil, fmt.Errorf("internal error creating weavelet: %w", err)
	}

	return wlet.start()
}
```
`weavelet`初始化时会拿到组件注册的信息（codegen.Registered），注册服务（前面生成代码提到的PRC服务端）。
```go
func (w *weavelet) start() (Instance, error) {
	...
	handlers := &call.HandlerMap{}
	for _, c := range w.componentsByName {
		w.addHandlers(handlers, c)
	}
	...
}
```
# envelope
`envelope`运行在部署进程中，能够和`weavelet`进行通讯，双方是利用管道发送消息，有两条管道，一个是`weavelet`=>`envelope`，另一个是`envelope`=>`weavelet`。
`envelope`的主要作用是检查`weavelet`的运行状态，通知订阅`weavelet`组件的路由信息，处理来自`weavelet`的消息，如创建新的组件，http代理等等。
```go
type EnvelopeHandler interface {
	// StartComponent starts the given component.
	StartComponent(entry *protos.ComponentToStart) error

	// GetAddress gets the address a weavelet should listen on for a listener.
	GetAddress(req *protos.GetAddressRequest) (*protos.GetAddressReply, error)

	// ExportListener exports the given listener.
	ExportListener(req *protos.ExportListenerRequest) (*protos.ExportListenerReply, error)

	// RecvLogEntry enables the envelope to receive a log entry.
	RecvLogEntry(entry *protos.LogEntry)

	// RecvTraceSpans enables the envelope to receive a sequence of trace spans.
	RecvTraceSpans(spans []trace.ReadOnlySpan) error
}
```

# babysitter
`babysitter`运行在部署进程上，管理了所有`envelope`，是`weaver`中的大脑。
当我们运行命令`weave mulit deploy`时，会创建`babysitter`，`babysitter`会固定创建出两个`main`组件。
这两个`main`组件运行在不同进程，执行配置文件指定的`binary`文件。一般来说，我们会指定http服务的端口号。
```go
func (s *Server) Run(addr string) error {
	lis, err := s.root.Listener("lemon", weaver.ListenerOptions{LocalAddress: addr})
	if err != nil {
		return err
	}
	s.root.Logger().Debug("listener available", "addr", lis)
	return http.Serve(lis, otelhttp.NewHandler(http.DefaultServeMux, "http"))
}
```
`weaver`为了防止端口被占用，实际上两个`main`进程绑定的都是随机的端口，通过`weavelet`调用`ExportListener`发送到`envelope`，由`babysitter`处理代理的逻辑
```go
func (b *Babysitter) ExportListener(req *protos.ExportListenerRequest) (*protos.ExportListenerReply, error) {
	if p, ok := b.proxies[req.Listener.Name]; ok {
		p.proxy.AddBackend(req.Listener.Addr)
		return &protos.ExportListenerReply{ProxyAddress: p.addr}, nil
	}

	lis, err := net.Listen("tcp", req.LocalAddress)
	if errors.Is(err, syscall.EADDRINUSE) {
		// Don't retry if this address is already in use.
		return &protos.ExportListenerReply{Error: err.Error()}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("proxy listen: %w", err)
	}
	addr := lis.Addr().String()
	b.logger.Info("Proxy listening", "address", addr)
	proxy := proxy.NewProxy(b.logger)
	proxy.AddBackend(req.Listener.Addr)
	b.proxies[req.Listener.Name] = &proxyInfo{
		listener: req.Listener.Name,
		proxy:    proxy,
		addr:     addr,
	}
	go func() {
		if err := serveHTTP(b.ctx, lis, proxy); err != nil {
			b.logger.Error("proxy", err)
		}
	}()
	return &protos.ExportListenerReply{ProxyAddress: addr}, nil
}
```
在`main`程序执行过程中，程序会调用到`weaver.Get`来获取组件。
```go
func Get[T any](requester Instance) (T, error) {
	var zero T
	iface := reflect.TypeOf(&zero).Elem()
	rep := requester.rep()
	component, err := rep.wlet.getComponentByType(iface)
	if err != nil {
		return zero, err
	}
	result, err := rep.wlet.getInstance(component, rep.info.Name)
	if err != nil {
		return zero, err
	}
	return result.(T), nil
}
```
在第一次获取组件的过程中需要初始化，`main`进程调用`RegisterComponentToStart`中向`babysitter`发送需要初始化的组件，
`babysitter`收到请求后，会创建两个新的子进程，子进程创建后`weavelet`会把自己组件的tcp地址发送回`babysitter`，
`babysitter`会把路由信息发送给订阅的`weavelet`组件。
```go
func (h *handler) StartComponent(req *protos.ComponentToStart) error {
	if err := h.subscribeTo(req); err != nil {
		return err
	}
	return h.startComponent(req)
}
```
这样一来，当进程调用组件的方法时，就能拿到组件提供RPC服务的地址，完成组件方法的调用，最终的程序多进程部署后会像这样。
```
$ weaver multi status
╭────────────────────────────────────────────────────╮
│ DEPLOYMENTS                                        │
├───────┬──────────────────────────────────────┬─────┤
│ APP   │ DEPLOYMENT                           │ AGE │
├───────┼──────────────────────────────────────┼─────┤
│ lemon │ f74f7512-a8ff-48e2-bdce-8a1a3dd4c640 │ 22s │
╰───────┴──────────────────────────────────────┴─────╯
╭──────────────────────────────────────────────────────────────────────────╮
│ COMPONENTS                                                               │
├───────┬────────────┬──────────────────────────────────────┬──────────────┤
│ APP   │ DEPLOYMENT │ COMPONENT                            │ REPLICA PIDS │
├───────┼────────────┼──────────────────────────────────────┼──────────────┤
│ lemon │ f74f7512   │ lemon\service\category\T             │ 10272, 15264 │
│ lemon │ f74f7512   │ lemon\service\category\categoryCache │ 4692, 15116  │
│ lemon │ f74f7512   │ lemon\service\product\T              │ 11788, 13260 │
│ lemon │ f74f7512   │ main                                 │ 4508, 13236  │
╰───────┴────────────┴──────────────────────────────────────┴──────────────╯
╭─────────────────────────────────────────────────╮
│ LISTENERS                                       │
├───────┬────────────┬──────────┬─────────────────┤
│ APP   │ DEPLOYMENT │ LISTENER │ ADDRESS         │
├───────┼────────────┼──────────┼─────────────────┤
│ lemon │ f74f7512   │ lemon    │ 127.0.0.1:12345 │
╰───────┴────────────┴──────────┴─────────────────╯
```
每个组件都运行在两个不同的进程，`main`处理http服务，其他组件各自处理自己的服务，这8个进程都是部署进程的子进程，通过管道进行通信，同步组件服务的路由，
`main`最早被初始化，后续通过`weaver.Get`不断创建新的组件进程。

# 小结
讲的比较简单，只是个大概，有兴趣的可以去看github上的源码，比较有意思，我在看源码的过程中也修了两个Windows上的兼容bug，算是有所收获。