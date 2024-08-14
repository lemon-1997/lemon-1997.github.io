---
title: "gRPC Metadata的误解"
description: "分析gRPC Metadata的使用误区"
keywords: "go,gRPC,Metadata"

publishDate: 2024-08-14T17:15:00+08:00
lastmod: 2024-08-14T17:15:00+08:00

categories:
  - 源码分析
tags:
  - go
  - gRPC
  - Metadata

toc: true
url: "post/source-metadata.html"
---

最近在处理线上问题时，我遇到一个与 gRPC Metadata 相关的困惑。起初，我以为在 gRPC 请求中，metadata 中相同的 key 会发生覆盖，但实际情况并非如此。相同的 key 并不会覆盖前一个值，反而会形成一个数组，就像 HTTP header 的设计一样。这一现象在初次遇到时并不明显，为了弄清楚其中的原理，我决定深入源码进行分析，最终发现了其中的细节并排查出了导致问题的根源。


<!--more-->

# 问题背景
先看下发生问题的代码
```go
import (
    "context"
    mmd "google.golang.org/grpc/metadata"
    "google.golang.org/protobuf/types/known/emptypb"
)

func metadataPass(ctx context.Context) {
	var i int
	for {
		i++
		ctx = mmd.AppendToOutgoingContext(ctx, "test", i)
		res, _ := client.SayHello(ctx, &emptypb.Empty{})
	}
	return
}
```
代码很简单，就是在一个循环中，每次发起gRPC请求前都调用`AppendToOutgoingContext`添加键值对，
看起来没啥问题，因为`metadata`的go源码实现是依靠于`context`，而`context`如果是相同key则会覆盖，这就导致写这段代码时顺利成章的认为这样使用是没问题的。

# 排查过程
定位问题其实是比较快的，出于好奇，决定看下metadata的源码实现。
先看下`AppendToOutgoingContext`具体做了什么
```go
type rawMD struct {
    md    MD
    added [][]string
}

// AppendToOutgoingContext returns a new context with the provided kv merged
// with any existing metadata in the context. Please refer to the documentation
// of Pairs for a description of kv.
func AppendToOutgoingContext(ctx context.Context, kv ...string) context.Context {
	if len(kv)%2 == 1 {
		panic(fmt.Sprintf("metadata: AppendToOutgoingContext got an odd number of input pairs for metadata: %d", len(kv)))
	}
	md, _ := ctx.Value(mdOutgoingKey{}).(rawMD)
	added := make([][]string, len(md.added)+1)
	copy(added, md.added)
	kvCopy := make([]string, 0, len(kv))
	for i := 0; i < len(kv); i += 2 {
		kvCopy = append(kvCopy, strings.ToLower(kv[i]), kv[i+1])
	}
	added[len(added)-1] = kvCopy
	return context.WithValue(ctx, mdOutgoingKey{}, rawMD{md: md.md, added: added})
}
```
源码比较简单，把`rawMD`从`ctx`取出来，这里并没有做判断是否有key的情况，而是直接把传入的键值对继续往`added`上面追加。

接着看下`FromOutgoingContext`的实现
```go
// FromOutgoingContext returns the outgoing metadata in ctx if it exists.
//
// All keys in the returned MD are lowercase.
func FromOutgoingContext(ctx context.Context) (MD, bool) {
	raw, ok := ctx.Value(mdOutgoingKey{}).(rawMD)
	if !ok {
		return nil, false
	}

	mdSize := len(raw.md)
	for i := range raw.added {
		mdSize += len(raw.added[i]) / 2
	}

	out := make(MD, mdSize)
	for k, v := range raw.md {
		// We need to manually convert all keys to lower case, because MD is a
		// map, and there's no guarantee that the MD attached to the context is
		// created using our helper functions.
		key := strings.ToLower(k)
		out[key] = copyOf(v)
	}
	for _, added := range raw.added {
		if len(added)%2 == 1 {
			panic(fmt.Sprintf("metadata: FromOutgoingContext got an odd number of input pairs for metadata: %d", len(added)))
		}

		for i := 0; i < len(added); i += 2 {
			key := strings.ToLower(added[i])
			out[key] = append(out[key], added[i+1])
		}
	}
	return out, ok
}
```
在返回`metadata`的时候，如果是相同key值，value是一个数组，顺序跟你写入`metadata`的顺序一致。
好吧，看到`MD`定义的时候突然想起来value是一个数组，太久这都忘了，grpc的`metadata`设计其实跟HTTP`header`的设计是类似的，value都是数组。
```go
// MD is a mapping from metadata keys to values. Users should use the following
// two convenience functions New and Pairs to generate MD.
type MD map[string][]string

// Get obtains the values for a given key.
//
// k is converted to lowercase before searching in md.
func (md MD) Get(k string) []string {
    k = strings.ToLower(k)
    return md[k]
}
```
```go
// A Header represents the key-value pairs in an HTTP header.
//
// The keys should be in canonical form, as returned by
// CanonicalHeaderKey.
type Header map[string][]string
```
而最终由于在项目中服务端使用的是kratos框架，默认取的也是第一个元素，所以拿到的还是第一次写入的值
```go
// Get returns the value associated with the passed key.
func (m Metadata) Get(key string) string {
	v := m[strings.ToLower(key)]
	if len(v) == 0 {
		return ""
	}
	return v[0]
}
```

# 解决方案
第一种解决方案是最简单的，直接用空的context
```go
ctx = mmd.AppendToOutgoingContext(context.Background(), "test", i)
```
第二种是取出metadata，重新设置键值，并重新初始化context，这种是推荐的方法（因为context之前携带的其他metadata key值，以及ctx里面的超时信息都能携带过去）
```go
    md, ok := mmd.FromOutgoingContext(ctx)
    if !ok{
        md = make(mmd.MD)
    }
    md.Set("test", i)
    ctx = mmd.NewOutgoingContext(ctx, md)
```

# 总结
这次 gRPC Metadata 相同 key 的问题让我深刻体会到，在开发和调试过程中，深入理解底层实现的重要性。我们往往习惯于依赖文档和现有的经验来解决问题，但面对复杂且不常见的情况时，文档可能并不够用。这时，直接阅读源码就是一种非常有效的手段。

通过这次的排查过程，我不仅解决了具体的问题，还对 gRPC 的内部机制有了更深入的了解。这种理解不仅能帮助我们编写出更加健壮的代码，还能让我们在遇到问题时有更高的洞察力和更快的解决速度。

因此，我强烈建议大家在工作中遇到类似疑惑时，不妨多去看看源码。源码是最权威的参考资料，也是理解框架和工具设计理念的最佳途径。它不仅能帮助我们解决眼前的问题，还能提升我们作为开发者的整体能力。