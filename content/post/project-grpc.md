---
title: "动态gRPC-HTTP代理（一）：设计"
description: "调研gRPC-HTTP代理，设计自己的代理插件"
keywords: "grpc,protoreflect,dynamic"

publishDate: 2023-11-25T23:30:00+08:00
lastmod: 2023-11-25T23:30:00+08:00

categories:
  - 项目实战
tags:
  - go
  - grpc

toc: true
url: "post/project-grpc.html"
---

在当前主流的微服务架构中，许多公司选择使用gRPC协议作为内部通信机制。然而，在与外部系统进行交互时，HTTP仍然是不可或缺的协议。为了解决这一问题，常见的解决方案是采用grpc-gateway或其他网关自带的插件进行协议转换。但是，这些方案都存在一个共同的痛点：每次更新服务都需要手动更新proto或pb文件，并重新配置网关，这给开发者带来了不小的麻烦。因此，我们迫切需要一个不依赖于proto文件、能够动态感知gRPC服务的插件，以简化这一流程并提高开发效率。本文将探讨这一问题的背景、现有解决方案的局限性，以及我们所期望的理想插件应具备的特性。

<!--more-->

首先，我们要搞清楚为什么需要proto，我们知道，`gRPC`底层是`HTTP2`，
理论上来说，我们收到客户端的HTTP请求，是可以升级成HTTP2再调用后台服务，
但问题是`gRPC`是以proto协议进行传输，当我们收到参数，却不知道后台服务的proto协议（proto文件定义了字段已经字段的顺序），
我们无法将其序列化，所以我们必须知道调用方法的proto定义。

# 方案对比

目前来讲，大体上有以下几种方式实现

|                 | 优点                            | 缺点                  |
|-----------------|--------------------------------|---------------------|
| 同时提供gRPC,HTTP服务 | 无需做HTTP的转换，可直接暴露服务       | 有些项目可能不好拓展，需要调整增加代码 |
| grpc-gateway    | 直接生成HTTP代码，无需额外编写            | 服务更新需要更新gateway插件
| protoreflect    | 利用gRPC反射，不依赖proto文件            | 需要注册反射服务
| HTTP2           | 简单，设置content-type为json直接透传grpc | 牺牲了gRPC的优点（proto）

1. 同时提供gRPC,HTTP服务，这种直接pass，如果选这种也不会有这篇文章。
2. grpc-gateway，这其实是主流方案了，但是加个字段或者接口都得更新插件，很麻烦，很好奇google是如何解决的。
3. protoreflect，这是这次选择的方案，利用反射我们能够动态获取proto定义，完美解决grpc-gateway的问题。
4. HTTP2，不选择这个方案的原因是没有反射实现的有意思。

# 整体结构

## reflect

反射是项目的主要模块，核心功能是提供一个gRPC客户端，能够获取grpc服务的proto协议，
根据proto协议动态调用grpc，随时监听grpc服务变化，如果服务重新更新了，就必须重新读取proto协议

## route

路由的主要功能是将proto定义的HTTP路径[`google.api.http`](https://github.com/googleapis/googleapis/blob/master/google/api/http.proto#L46)，
匹配出grpc对应的method

## codec

编解码模块，功能是HTTP参数与grpc proto二进制的转换，
编码支持json,query,path,form,xml,html转化成proto，
解码目前仅支持proto到json的转换

## proxy

提供HTTP服务，代理请求，路由转发并调用grpc服务，参数处理（content-type），结果返回（json），错误解析（grpc status）等等

# 小结
这是第一篇文章，主要是总体的设计思路，目前只写了简单的demo，项目还没开始写，后续的设计可能还会有所变动，
后面可能还会有四篇文章讲述具体实现细节，每完成一个模块可能就会更新一篇文章。
项目源码 https://github.com/lemon-1997/dynamic-grpc