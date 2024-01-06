---
title: "动态gRPC-HTTP代理（三）：路由"
description: "http路由到后台gRPC服务"
keywords: "grpc,http route"

date: 2024-01-06T21:50:20+08:00
lastmod: 2024-01-06T21:50:20+08:00

categories:
  - 项目实战
tags:
  - go
  - grpc

toc: true
url: "post/project-grpc-3.html"
---

在构建高效、可扩展的后端服务体系中，路由模块起着至关重要的作用。它负责接收前端请求，并根据请求中的信息，精准地将请求导向到相应的后端gRPC服务。本文将深入探讨如何设计并实现一个稳健、高效的路由模块，以确保请求能够准确、快速地到达目标服务。

<!--more-->

# 路由设计

我们在proto定义了服务的路径，我们希望往这个路径的请求都转发到对应的gRPC方法上，那么我们改如何设计呢。

假设我们有这么一个服务，对应的proto如下：
```protobuf
  rpc SayHello (HelloRequest) returns (HelloReply)  {
    option (google.api.http) = {
      get: "/helloworld/{name}"
    };
  }
  
  message HelloRequest {
    string name = 1;
  }
```
如果我们的路径为`/helloworld/lemon`，我们不仅要转发到对应的`SayHello`方法，我们还需要解析url参数出来，
因此，我们路由不仅仅只有转发的作用，还要做一部分参数解析。

那么，我们可以先定义路由的API
```go
type Router interface {
	Add(method, path string, extra interface{}) error
	Match(method, path string) (map[string]string, interface{}, bool)
}
```
有两个方法，第一个是添加路径，参数为http方法，路径，还有一个`extra interface{}`参数，这个参数有什么用呢，因为我们不仅仅要匹配，我们还要知道匹配后的结果，我们该调用gRPC的哪个方法，所以可以用`extra`保存起来。
第二个方法是匹配路径了，输入就不必解释，返回参数一个是`map`，代表url参数，比如上面的helloworld，就是key为name，value为lemon，另一个参数就是上面我们注册路由是所传入的`extra`了，最后一个代表匹配结果。

# 路由底层

底层的实现我们直接使用`grpc-gateway`路由就行了，因为我们是基于它的方式做的，如果自己处理还要考虑通配符等各种问题，之前自己写过一版，但发现要支持太多特性，且自己写的性能还不高，因此放弃。
由于`grpc-gateway`路由模块是在`internal`文件夹下，不能直接引用，所以直接copy过来。

```go
type Pattern struct {
	runtime.Pattern
	extra interface{}
}

type httpRouter struct {
	unescapeMode runtime.UnescapingMode
	patterns     map[string][]Pattern
}
```

先定义好我们的结构，第一个是`pattern`，这个也是跟`grpc-gateway`命名一样，代表一种HTTP请求路径的匹配模式，这里我们多加了`extra`。
第二个是实现`Router`的结构，`patterns`是一个map，key为HTTP方法，value为路径列表。

# 路由实现

## 路由注册

直接调用底层的实现就行，主要是初始化`patterns`，比较简单，这里不考虑并发问题，因为调用的地方是一个一个注册。

```go
func (r *httpRouter) Add(method, path string, extra interface{}) error {
	c, err := httprule.Parse(path)
	if err != nil {
		return err
	}
	tmpl := c.Compile()
	p, err := runtime.NewPattern(tmpl.Version, tmpl.OpCodes, tmpl.Pool, tmpl.Verb)
	if err != nil {
		return err
	}
	r.patterns[method] = append(r.patterns[method], Pattern{
		Pattern: p,
		extra:   extra,
	})
	return nil
}
```

## 路由匹配

匹配这里，除了要处理url参数，还需要把注册的`extra`返回出去

```go
func (r *httpRouter) Match(method, path string) (map[string]string, interface{}, bool) {
	if r == nil {
		return nil, nil, false
	}
	if !strings.HasPrefix(path, "/") {
		return nil, nil, false
	}
	var pathComponents []string
	pathComponents = strings.Split(path[1:], "/")

	if r.unescapeMode == runtime.UnescapingModeAllCharacters {
		pathComponents = encodedPathSplitter.Split(path[1:], -1)
	} else {
		pathComponents = strings.Split(path[1:], "/")
	}

	lastPathComponent := pathComponents[len(pathComponents)-1]
	patterns := r.patterns[method]
	for _, item := range patterns {
		var verb string
		patVerb := item.Verb()

		idx := -1
		if patVerb != "" && strings.HasSuffix(lastPathComponent, ":"+patVerb) {
			idx = len(lastPathComponent) - len(patVerb) - 1
		}
		if idx == 0 {
			return nil, nil, false
		}

		comps := make([]string, len(pathComponents))
		copy(comps, pathComponents)

		if idx > 0 {
			comps[len(comps)-1], verb = lastPathComponent[:idx], lastPathComponent[idx+1:]
		}
		pathParams, err := item.MatchAndEscape(comps, verb, r.unescapeMode)
		if err != nil {
			continue
		}
		return pathParams, item.extra, true
	}
	return nil, nil, false
}
```

# 总结

在本篇博客中，我们深入探讨了项目中路由模块的关键作用，以及如何将HTTP请求精准导向gRPC服务。
我们的路由模块很简单，我们也不会考虑gRPC服务proto的更新等等，我们要做的是一个基础模块，考虑太多只会让代码更加耦合，路由只需要做好简单的注册和匹配功能就好了，剩下由其他模块再去封装。
下一篇博客我们讲继续完成下一个模块，是编接码模块，它将完成HTTP和gRPC的相互转换。

项目源码 https://github.com/lemon-1997/dynamic-grpc