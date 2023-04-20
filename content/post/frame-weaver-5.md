---
title: "Google分布式框架Weaver（五）：实现自己的部署器"
description: "实现部署接口，完成一个简单的多进程weaver部署应用"
keywords: "weaver,微服务,部署"

publishDate: 2023-04-20T18:41:58+08:00
lastmod: 2023-04-20T18:41:58+08:00

categories:
- 框架教程
tags:
- go
- weaver
- 微服务

toc: true
url: "post/frame-weaver-5.html"
---

上一节我们了解到了weavelet，envelope之间的通信，以及babysister是如何管理各个component，weaver命令多进程部署是如何工作的。
weaver支持开发者去实现部署，可以利用它去实现指定副本的多进程部署（weaver自带的命令默认副本数为2个），多机器部署等等，下面，我将介绍如何去实现自己的部署应用。

<!--more-->

# 简单例子
前不久，weaver官方发布了关于部署的blog，https://serviceweaver.dev/blog/deployers.html，本文将基于官方的例子介绍。

要实现部署，我们必须去实现`EnvelopeHandler`接口
```go
type EnvelopeHandler interface {
    // Components.
    ActivateComponent(context.Context, *protos.ActivateComponentRequest) (*protos.ActivateComponentReply, error)

    // Listeners.
    GetListenerAddress(context.Context, *protos.GetListenerAddressRequest) (*protos.GetListenerAddressReply, error)
    ExportListener(context.Context, *protos.ExportListenerRequest) (*protos.ExportListenerReply, error)

    // Telemetry.
    HandleLogEntry(context.Context, *protos.LogEntry) error
    HandleTraceSpans(context.Context, []trace.ReadOnlySpan) error
}
```
1. `ActivateComponent`：字面意思是激活组件，实际上我们应该去实现启动一个进程，启动服务接收来自其他组件对该组件的服务调用。
2. `GetListenerAddress`：获取组件监听地址，我们的应用需要暴露服务，所有需要指定它要开发的地址。
3. `ExportListener`：组件监听后，weavelet返回给envelope，可以使用代理，统一用一个地址对外暴露。
4. `HandleLogEntry`：组件的日志，也可以统一处理，
5. `HandleTraceSpans`：组件的遥测数据。

当然了，在实现过程中，我们可能还需要借助envelope提供的函数去实现，像比如更新路由信息，更新组件等等。
```go
// Components.
func (e *Envelope) UpdateRoutingInfo(routing *protos.RoutingInfo) error
func (e *Envelope) UpdateComponents(components []string) error

// Telemetry.
func (e *Envelope) GetHealth() protos.HealthStatus
func (e *Envelope) GetMetrics() ([]*metrics.MetricSnapshot, error)
func (e *Envelope) GetLoad() (*protos.LoadReport, error)
func (e *Envelope) GetProfile(req *protos.GetProfileRequest) ([]byte, error)
```
首先，定义`deployer`
```go
package main

type deployer struct {
    mu       sync.Mutex          // guards handlers
    handlers map[string]*handler // handlers, by component
}

type handler struct {
    deployer *deployer          // underlying deployer
    envelope *envelope.Envelope // envelope to the weavelet
    address  string             // weavelet's address
}

var _ envelope.EnvelopeHandler = &handler{}
```
第二步，实现`spawn`方法生成weavelet
```go
func (d *deployer) spawn(component string) (*handler, error) {
    d.mu.Lock()
    defer d.mu.Unlock()

    // 防止重复生成weavelet（每次启动应用时，都会get其他组件，防止无限创建组件）
    h, ok := d.handlers[component]
    if ok {
        return h, nil
    }

    // Spawn a weavelet in a subprocess to host the component.
    info := &protos.EnvelopeInfo{
        App:           "app",               // the application name
        DeploymentId:  deploymentId,        // the deployment id
        Id:            uuid.New().String(), // the weavelet id
        SingleProcess: false,               // is the app a single process?
        SingleMachine: true,                // is the app on a single machine?
        RunMain:       component == "main", // should the weavelet run main?
    }
    config := &protos.AppConfig{
        Name:   "app",       // the application name
        Binary: flag.Arg(0), // 通过命令行参数传入
    }
	// NewEnvelope会创建一个进程，运行指定的Binary，并通过管道进行通信，上一节有介绍
    envelope, err := envelope.NewEnvelope(context.Background(), info, config)
    if err != nil {
        return nil, err
    }
    h = &handler{
        deployer: d,
        envelope: envelope,
        address:  envelope.WeaveletInfo().DialAddr,
    }

    go func() {
        // Inform the weavelet of the component it should host.
        envelope.UpdateComponents([]string{component})

        // Handle messages from the weavelet.
        envelope.Serve(h)
    }()

    // Return the handler.
    d.handlers[component] = h
    return h, nil
}
```
接下来，实现`ActivateComponent`，当`weaver.Get`使用被调用
```go
func (h *handler) ActivateComponent(_ context.Context, req *protos.ActivateComponentRequest) (*protos.ActivateComponentReply, error) {
    // 通过spawn创建出组件
    spawned, err := h.deployer.spawn(req.Component)
    if err != nil {
        return nil, err
    }

    // 更新路由信息
    h.envelope.UpdateRoutingInfo(&protos.RoutingInfo{
        Component: req.Component,
        Replicas:  []string{spawned.address},
    })

    return &protos.ActivateComponentReply{}, nil
}
```
如果我们的应用需要对外暴露，那么需要实现`GetListenerAddress`，`ExportListener`
```go
// 随机监听本机的一个端口
func (h *handler) GetListenerAddress(_ context.Context, req *protos.GetListenerAddressRequest) (*protos.GetListenerAddressReply, error) {
    return &protos.GetListenerAddressReply{Address: "localhost:0"}, nil
}

// 这里没做代理，只做打印
func (h *handler) ExportListener(_ context.Context, req *protos.ExportListenerRequest) (*protos.ExportListenerReply, error) {
    fmt.Printf("Weavelet listening on %s\n", req.Address)
    return &protos.ExportListenerReply{}, nil
}
```
然后是遥测，只是实现，不做处理
```go
func (h *handler) HandleLogEntry(_ context.Context, entry *protos.LogEntry) error {
    pp := logging.NewPrettyPrinter(colors.Enabled())
    fmt.Println(pp.Format(entry))
    return nil
}

func (h *handler) HandleTraceSpans(context.Context, []trace.ReadOnlySpan) error {
    return nil
}
```
最后是实现cmd命令
```go
func main() {
    flag.Parse()
    d := &deployer{handlers: map[string]*handler{}}
    d.spawn("main")
    select {} // block forever
}
```
这样一来，就可以通过我们自己写的部署器去实现多进程部署了。
上面只是weaver官方给的简单例子，实际上，weaver自己的多进程部署还多了其他功能，具体可以看源码，源码还有多机器的SSH方式部署。

# k8s
关于k8s部署weaver应用，官方只提供了`weaver gke`的方式，如果想要在自己的k8s环境上构建，得需要自己去实现k8s部署器。
按我的理解，如果要实现，可能要分成两个部分，一个用来实现`EnvelopeHandler`方法，属于上层，一个有k8s权限，可以在k8s创建容器，并接收另一个创建组件的请求，可以与k8s内的组件通信。
当然，实际情况可能考虑的问题还不少，这只是我的简单想法，等官方实现可能还要等一段时间，目前还没用看到weaver团队的计划。

# 结尾
如果对weaver有兴趣的话，欢迎在下方讨论。

