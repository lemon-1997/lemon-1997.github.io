---
title: "Google分布式框架Weaver（一）：单体开发，微服务运行"
description: "Weaver安装使用，设计哲学"
keywords: "go,Weaver,教程,微服务"

publishDate: 2023-03-08T20:00:00+08:00
lastmod: 2023-03-08T20:00:00+08:00

categories:
- 框架教程
tags:
- go
- weaver
- 微服务

toc: true
url: "post/frame-weaver.html"
---

最近，Google开源了一个用于编写、部署和管理分布式应用程序的编程框架：Service Weaver。
这个框架设计思想很巧妙，使用该框架可以以函数调用的方式去调用其他服务，无需考虑任何网络或者序列化问题，在部署时却能够以微服务的方式运行。
这样一来，开发者可以在自己的机器上运行、测试和调试，非常的方便。

<!--more-->

# weaver简介
讲weaver之前，必须先讲下微服务，微服务是一种架构风格，通过将应用程序划分为一组小的、相互独立的服务来构建大型应用程序。尽管微服务架构带来了许多好处，但也存在缺点。
## 微服务痛点
1. 复杂性：微服务架构通常需要将一个应用程序分成多个服务，这样就需要管理和维护多个服务。这增加了应用程序的复杂性，需要额外的工作来确保所有服务能够相互协作。
2. 分布式系统：微服务架构通常是基于分布式系统的，而分布式系统通常比单体应用程序更难以管理和维护。这是因为它涉及到不同的服务运行在不同的机器上，需要处理网络故障、数据同步和一致性等问题。
3. 版本控制：微服务架构中的每个服务都需要进行版本控制，这会增加代码库的复杂性和维护成本。同时，服务之间的接口和依赖关系也需要进行版本控制和管理，以确保不会发生兼容性问题。
4. 监控和调试：微服务架构中的服务可能会分布在不同的机器和数据中心，因此对系统进行监控和调试变得更加困难。同时，由于服务之间存在依赖关系，当一个服务出现问题时，可能会影响整个系统的运行。
5. 测试：微服务架构中的每个服务都需要进行单元测试、集成测试和端到端测试等多种测试，这会增加测试的复杂性和维护成本。同时，由于服务之间存在依赖关系，测试也需要考虑服务之间的交互和一致性。

## 特性
使用weaver我们不用担心以上的问题，我们只需要编写业务代码，微服务的问题交给weaver处理。
1. Components：组件是weaver中的核心概念，它是一组方法的集合，即微服务对外提供的接口，在go中被抽象成了`interface{}`，可以直接函数调用。
2. Observability：weaver为可观测三大指标，日志，指标，链路追踪都封装了API给开发者使用。
3. Testing：weaver提供一个`weavertest`包，可以使用它来测试的weaver服务。
4. Versioning：weaver保证在滚动更新时所以的服务都处在同一版本，不会出现不同版本的服务相互调用的情况。
5. Deploy：weaver配置，部署命令简单，开发者无需编写多个微服务的部署文件。

## 部署
weaver支持三种部署模式：
1. single process：单进程部署，服务之间的调用都是函数调用。
2. multi process：多进程部署，服务会创建多个副本，每个副本都是单独的进程。
3. GKE（Google Kubernetes Engine (GKE)）：多机器部署到云端。

# weaver安装
## 安装
weaver使用也很简单，首先根据官方文档先编写一个简单的反转字符串接口，这里直接复制，后续会讲到weaver提供的接口以及实现原理
```go
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"github.com/ServiceWeaver/weaver"
)

// Reverser component.
type Reverser interface {
	Reverse(context.Context, string) (string, error)
}

// Implementation of the Reverser component.
type reverser struct {
	weaver.Implements[Reverser]
}

func (r *reverser) Reverse(_ context.Context, s string) (string, error) {
	runes := []rune(s)
	n := len(runes)
	for i := 0; i < n/2; i++ {
		runes[i], runes[n-i-1] = runes[n-i-1], runes[i]
	}
	return string(runes), nil
}

func main() {
	// Get a network listener on address "localhost:12345".
	root := weaver.Init(context.Background())
	opts := weaver.ListenerOptions{LocalAddress: "localhost:12345"}
	lis, err := root.Listener("hello", opts)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("hello listener available on %v\n", lis)

	// Get a client to the Reverser component.
	reverser, err := weaver.Get[Reverser](root)
	if err != nil {
		log.Fatal(err)
	}

	// Serve the /hello endpoint.
	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		reversed, err := reverser.Reverse(r.Context(), r.URL.Query().Get("name"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		fmt.Fprintf(w, "Hello, %s!\n", reversed)
	})
	http.Serve(lis, nil)
}
```
1. 编写main文件，如上面的代码。
2. 执行`go mod tidy`安装依赖。
3. 执行`go install github.com/ServiceWeaver/weaver/cmd/weaver@latest`安装weaver。
4. 执行`weaver generate .`生成代码。
5. 执行`go run .`
6. 测试`curl "localhost:12345/hello?name=Weaver"`返回反转的字符串`Hello, revaeW!`

## 遇到的问题
在安装的过程中难免会遇到问题，我把我遇到的问题也记录下，方便相同问题的人能解决
1. gcc：具体的错误信息忘记保存了，大致是因为sqllite的依赖，遇到这个问题直接去装gcc并添加到环境变量就好了，大家都是程序员，我相信都能解决。
2. weaver multi deploy失败：这个问题是系统问题，因为linux子进程继承时可以把文件描述符也带过去，但是windows不支持，而weaver没有对这种情况做处理，导致无法在windows机器上部署多进程，这个我已经提给了官方，相信很快能处理。
3. weaver status报错：
```shell
Get "http://127.0.0.1:12012/debug/serviceweaver/status": dial tcp 127.0.0.1:12012: connectex: No connection could be made because the target machine actively refused it
```
调试weaver代码后，我发现有些weaver服务即使退出了，weaver还认为它存在，所以请求该服务的状态时会失败。
最终发现是golang IDE在2022.3版本之前在debug调试下点击`stop`会发送`os.kill`信号（run模式下和ctrl+c都正常），而这个信号无法被捕获，导致weaver没能判断服务已经退出。
解决方案是删除`~.local\share\serviceweaver\single_registry`以及`~.local\share\serviceweaver\multi_registry`下面的文件即可正常运行。
为了防止再出现这种情况可以将golang IDE升级到2022.3版本修复这个问题。

# 小结
这篇blog先分享weaver的安装以及简介，后续会更详细地介绍这个框架。由于目前weaver还是在0.1版本，官方也明确表示不排除会有大改动。