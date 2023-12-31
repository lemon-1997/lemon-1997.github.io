---
title: "动态gRPC-HTTP代理（二）：反射"
description: "代理核心模块：grpc反射"
keywords: "grpc,protoreflect"

date: 2023-12-31T17:12:11+08:00
lastmod: 2023-12-31T17:12:11+08:00

categories:
  - 项目实战
tags:
  - go
  - grpc

toc: true
url: "post/project-grpc-2.html"
---

在上一篇博客中，我们介绍了将HTTP请求转换为gRPC请求的总体设计思路，讲述了实现代理所需要的基本模块。然而，实现这一设计的过程中，一个关键的技术挑战是如何在不知道具体gRPC服务定义的情况下，动态地调用这些服务。这正是本篇博客要深入探讨的内容——利用gRPC的反射机制实现动态服务调用。

通过引入gRPC反射，我们的代理服务将能够更加智能化和自适应。它不仅可以处理已知的gRPC服务，还能在遇到新的、未知的服务时，通过反射机制动态地获取服务定义并进行调用。这将极大地增强我们代理服务的可扩展性和适应性。

接下来，我们将首先简要介绍gRPC反射的基本概念和用途，然后通过具体的代码示例详细展示如何利用反射机制实现动态服务调用。让我们一起进入gRPC反射的世界，探索其为我们带来的无限可能。

<!--more-->

# 反射是什么
首先，我们需要了解gRPC反射，gRPC反射是基于Protocol Buffers的Reflection API，通过它，客户端可以获取服务的元数据信息，如服务名称、方法名称、请求和响应类型等。这些信息可以用于构建客户端存根，从而实现动态调用。

# 反射能做什么
接下来，回到我们的需求，我们可以利用gRPC反射做什么，大致可以分为三点：
1. 动态调用grpc服务
2. 获取proto定义的服务，方法以及定义的http路径
3. 监控grpc服务状态，当服务有变化时重新反射获取proto的新定义

# 具体实现

要实现上述的功能，我们可以使用`github.com/jhump/protoreflect`，这个库基于gRPC反射封装了一些API，方便我们实现。

## 动态调用
依照api文档，需要先初始化一个`stub`
```go
    conn, err := grpc.DialContext(ctx, target, opts...)
    if err != nil {
        return nil, fmt.Errorf("failed to create grpc client: %v", err)
    }
    stub := grpcdynamic.NewStub(conn)
```
然后是`invoke`方法
```go
func (c *ReflectClient) Invoke(ctx context.Context, method *desc.MethodDescriptor, req *dynamic.Message) (*dynamic.Message, metadata.MD, error) {
	if method.IsServerStreaming() || method.IsClientStreaming() {
		return nil, nil, fmt.Errorf("failed to invoke stream")
	}
	md := metadata.New(make(map[string]string))
	res, err := c.stub.InvokeRpc(ctx, method, req, grpc.Header(&md))
	if err != nil {
		return nil, nil, err
	}
	dm := dynamic.NewMessage(method.GetOutputType())
	if err = dm.ConvertFrom(res); err != nil {
		return nil, nil, fmt.Errorf("conver output message error: %v", err)
	}
	return dm, md, nil
}
```

## 获取proto
动态调用我们需要确定proto方法，以及需要的请求体，所以我们需要获取并存储proto，这里先假设我们有一个路由模块专门处理这些。
```go
func (c *ReflectClient) route() (Router, error) {
	client := grpcreflect.NewClientAuto(context.Background(), c.conn)
	services, err := client.ListServices()
	if err != nil {
		return nil, fmt.Errorf("failed to ListServices: %v", err)
	}
	router := NewRouter()
	for _, srv := range services {
		srvDesc, err := client.ResolveService(srv)
		if err != nil {
			return nil, fmt.Errorf("failed to ResolveService: %v", err)
		}
		methods := srvDesc.GetMethods()
		for _, method := range methods {
			opts := method.GetMethodOptions()
			ext := proto.GetExtension(opts, annotations.E_Http)
			httpOpt, ok := ext.(*annotations.HttpRule)
			if !ok {
				continue
			}
			switch (httpOpt.GetPattern()).(type) {
			case *annotations.HttpRule_Get:
				err = router.Add(http.MethodGet, httpOpt.GetGet(), method)
			case *annotations.HttpRule_Put:
				err = router.Add(http.MethodPut, httpOpt.GetPut(), method)
			case *annotations.HttpRule_Post:
				err = router.Add(http.MethodPost, httpOpt.GetPost(), method)
			case *annotations.HttpRule_Delete:
				err = router.Add(http.MethodDelete, httpOpt.GetDelete(), method)
			case *annotations.HttpRule_Patch:
				err = router.Add(http.MethodPatch, httpOpt.GetPatch(), method)
			}
			if err != nil {
				c.log.Error("build route fail", "err", err)
				continue
			}
		}
	}
	return router, nil
}
```

## 监控服务

最后就是监控我们的grpc服务，一但服务重新更新，我们也需要更新proto协议
```go
func (c *ReflectClient) watch(ctx context.Context) {
	router, err := c.route()
	if err != nil {
		c.log.Error("update method fail", "err", err)
	}
	c.router = router
	go func() {
		//defer func() {
		//	if rec := recover(); rec != nil {
		//		log.Printf("panic: %v", rec)
		//	}
		//}()
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			c.conn.WaitForStateChange(ctx, c.conn.GetState())
			if c.conn.GetState() != connectivity.Ready {
				continue
			}
			router, err = c.route()
			if err != nil {
				c.log.Error("update method fail", "err", err)
				continue
			}
			c.router = router
			c.log.Info("update method", "target", c.conn.Target())
		}
	}()
}
```

# 总结
好了，到这里，我们已经实现了项目的核心模块反射，我们拿到了服务的proto定义的方法，路径，以及能够动态调用grpc服务，在后面，我们讲继续完善其他功能。

项目源码 https://github.com/lemon-1997/dynamic-grpc