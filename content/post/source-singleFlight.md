---
title: "解决重复请求和缓存击穿，go神器SingleFlight深度解析"
description: "分析go包SingleFlight的实现"
keywords: "go,SingleFlight,缓存击穿,重复请求"

publishDate: 2023-03-01T22:30:00+08:00
lastmod: 2023-03-01T22:30:00+08:00

categories:
- 源码分析
tags:
- go
- SingleFlight
- 缓存击穿

toc: true
url: "post/source-singleFlight.html"
---

当应用程序面临高并发请求时，重复请求往往是一种常见的问题。针对这一问题，Go 语言中提供了 SingleFlight 库，它可以有效地解决并发请求中的重复请求问题，提升应用程序的性能和稳定性。在本文中，我们将介绍 SingleFlight 库的作用和价值，并详细讲解如何在 Go 语言中使用 SingleFlight 库来解决并发请求中的重复请求问题。同时，我们将探讨 SingleFlight 库的原理和实现，以及其在实际项目中的应用场景和注意事项。

<!--more-->

# 使用方式
我们可以直接在应用程序中导入 SingleFlight 库，并使用 Group 结构体和 Do 函数来解决并发请求中的重复请求问题。具体实现如下：
```go
import (
    "golang.org/x/sync/singleflight"
)

var group singleflight.Group

func exampleFunction() (interface{}, error) {
    result, err, _ := group.Do("key", func() (interface{}, error) {
        // 在这里写具体的业务逻辑
        return "value", nil
    })
    if err != nil {
        return nil, err
    }
    return result, nil
}
```
可以看到使用非常简单，当相同的key并发请求过来时，最终只有一个去调用函数，其他goruntine都会阻塞等待。
除了最基本的`Do`，go还提供了另外两个API：
```go
func (g *Group) DoChan(key string, fn func() (interface{}, error)) <-chan Result
func (g *Group) Forget(key string)
```
`DoChan`功能和`Do`是一样的，只是利用`chan`改为异步，而`Forget`则是可以清除某个key，不需要等到阻塞执行完才清除。

# 原理实现
## 结构
Group结构简单，mu是互斥锁，所以m的操作都会被锁住，m是一个map结构，每个key对应一个call结构。
```go
type Group struct {
   mu sync.Mutex       
   m  map[string]*call 
}
```
接着是call结构
```go
type call struct {
   // wg用于同步阻塞相同key的调用
   wg sync.WaitGroup
   // val跟err存调用执行结果
   val interface{}
   err error
   // forgotten是一个标志位，调用完成时调用forget函数，后面会具体讲作用
   forgotten bool
   // dups记录重复调用的次数
   dups  int
   // chans发送调用结果给channel
   chans []chan<- Result
}
```
这里的chan<- Result 表示每个元素都是只能发送的chan，不能接受
```go
type Result struct {
   Val    interface{}
   Err    error
   Shared bool
}
```
这个是chan的返回结果，跟上面的一样就不重复讲了。

## API
`Do`方法通过mu，保证在并发的时候只有一个goruntine写入key，并执行调用fn，重复的key最终都会走wg.wait逻辑等待docall完成。
```go
func (g *Group) Do(key string, fn func() (interface{}, error)) (v interface{}, err error, shared bool) {
   g.mu.Lock()
   // 懒加载
   if g.m == nil {
      g.m = make(map[string]*call)
   }
   // 重复的key
   if c, ok := g.m[key]; ok {
      c.dups++
      g.mu.Unlock()
      // 阻塞等待
      c.wg.Wait()

      if e, ok := c.err.(*panicError); ok {
         panic(e)
      } else if c.err == errGoexit {
         runtime.Goexit()
      }
      return c.val, c.err, true
   }
   c := new(call)
   c.wg.Add(1)
   g.m[key] = c
   g.mu.Unlock()
    // 调用fn
   g.doCall(c, key, fn)
   return c.val, c.err, c.dups > 0
}
```
`DoChan`功能一样，只是返回chan，不阻塞直接返回
```go
func (g *Group) DoChan(key string, fn func() (interface{}, error)) <-chan Result {
   ch := make(chan Result, 1)
   g.mu.Lock()
   if g.m == nil {
      g.m = make(map[string]*call)
   }
   if c, ok := g.m[key]; ok {
      c.dups++
      c.chans = append(c.chans, ch)
      g.mu.Unlock()
      return ch
   }
   c := &call{chans: []chan<- Result{ch}}
   c.wg.Add(1)
   g.m[key] = c
   g.mu.Unlock()

   go g.doCall(c, key, fn)

   return ch
}
```
然后是docall逻辑，本该是个简单的函数，但是因为要区分panic和goexit，增加了复杂度
```go
func (g *Group) doCall(c *call, key string, fn func() (interface{}, error)) {
    // 正常返回标志位
   normalReturn := false
   // panic标志位
   recovered := false

   defer func() {
      // 如果没有正常返回且不是panic
      if !normalReturn && !recovered {
         c.err = errGoexit
      }
      // fn执行完，c.val，c.err已经确定
      c.wg.Done()
      g.mu.Lock()
      defer g.mu.Unlock()
      // 外部没有调用forget，需要自己删除key，防止后面相同key一直复用这个结果
      if !c.forgotten {
         delete(g.m, key)
      }

      if e, ok := c.err.(*panicError); ok {
         // 防止channel阻塞，直接go panic()
         if len(c.chans) > 0 {
            go panic(e)
            select {} 
         } else {
            // 正常返回，直接往上panic
            panic(e)
         }
      } else if c.err == errGoexit {
         // goexit无需处理
      } else {
         // 发送ch
         for _, ch := range c.chans {
            ch <- Result{c.val, c.err, c.dups > 0}
         }
      }
   }()

   func() {
      defer func() {
         if !normalReturn {
            // 这里还无法确定panic还是goexit
            if r := recover(); r != nil {
               c.err = newPanicError(r)
            }
         }
      }()

      c.val, c.err = fn()
      normalReturn = true
   }()

   // goexit无法到这里，如果这里没正常返回，则说明是panic，被recover了
   if !normalReturn {
      recovered = true
   }
}
```
由于panic和goexit都会进入recover，所以这里用了两次recover来区分这两种情况，主逻辑就是调用fn，获取结果，通知其他协程，删除掉key。
```go
func (g *Group) Forget(key string) {
   g.mu.Lock()
   if c, ok := g.m[key]; ok {
      c.forgotten = true
   }
   delete(g.m, key)
   g.mu.Unlock()
}
```
`Forget`最简单，就是删key，然后更改forgotten标志位，防止docall去删除

# 小结
## 应用场景
- 缓存穿透：缓存穿透是指恶意请求或者缓存过期等原因导致大量请求直接落到数据库上，导致数据库压力过大。使用 SingleFlight 库可以在缓存未命中时，只有一个请求会去查询数据库，其他请求会等待第一个请求的结果并复用。
- 防止瞬间高并发：在高并发场景下，单个请求可能会被大量的并发请求同时触发。使用 SingleFlight 库可以让这些请求只触发一次，避免瞬间高并发带来的问题。

## 注意事项
- 在并发量不高的场景下，使用 SingleFlight 库可能会带来额外的开销。因此，在使用 SingleFlight 库时，需要根据实际场景权衡利弊。
- 在使用 SingleFlight 库时，需要确保传递给 Do 函数的 key 值唯一，否则可能会导致请求结果不符合预期。

## 优点
- 避免重复的计算和查询，减少了不必要的性能开销。
- 减少数据库和其他外部资源的负载，避免了由此产生的性能问题。
- 以避免竞态条件的发生，保证了程序的正确性和稳定性。

## 缺点
- 由于 SingleFlight 库需要维护一个请求池，因此在并发量较小的场景下，可能会带来额外的开销。
- SingleFlight 库适用于高并发读场景，但不适用于高并发写场景。
- 一旦结果返回err，则全部的请求都会返回err。

## 改进
针对第三个缺点，我认为可以在`Do`和`DoChan`结构增加一个重试次数的参数，一旦此调用返回err，则继续重试，防止上述情况的发生。