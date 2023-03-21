---
title: "Google分布式框架Weaver（三）：测试与可观测性"
description: "介绍weaver的测试与可观测性，如何使用官方API"
keywords: "weaver,微服务,测试,可观测"

publishDate: 2023-03-21T20:00:00+08:00
lastmod: 2023-03-21T20:00:00+08:00

categories:
- 框架教程
tags:
- go
- weaver
- 微服务

toc: true
url: "post/frame-weaver-3.html"
---

上一次我们通过weaver中的组件完成了一个简易的商品后台系统，并对外提供http接口。
但是在实际开发中，除了业务逻辑的实现，少不了测试代码，也少不了可观测性（日志，指标，链路追踪）。

<!--more-->

# 测试
weaver官方提供了`weavertest`给开发者去测试自己的服务，`weavertest`对外只提供一个接口`weavertest.Init`
```go
func Init(ctx context.Context, t testing.TB, opts Options) weaver.Instance
```
调用该接口我们可以拿到`weaver.Instance`，以此获取我们需要测试的组件。
该接口参数比较简单，主要是`Options`
```go
type Options struct {
	// 是否单进程
	SingleProcess bool
	// 配置文件的字符串内容
	Config string
}
```
好，现在要测试上次的缓存路由能否生效，并测试增删改查的逻辑是否正确，我们使用表格驱动测试的方式编写
```go
func TestCache(t *testing.T) {
	ctx := context.Background()
	root := weavertest.Init(ctx, t, weavertest.Options{SingleProcess: false})
	cache, err := weaver.Get[categoryCache](root)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name    string
		id      int64
		want    Category
		wantErr bool
		fun     func(c categoryCache) error
	}{
		{
			name:    "Add",
			id:      1,
			want:    Category{ID: 1, Name: "1"},
			wantErr: false,
			fun: func(c categoryCache) error {
				return cache.Add(ctx, 1, Category{ID: 1, Name: "1"})
			},
		},
		{
			name:    "Update",
			id:      2,
			want:    Category{ID: 2, Name: "2"},
			wantErr: false,
			fun: func(c categoryCache) error {
				if err = cache.Add(ctx, 2, Category{ID: 2, Name: "1"}); err != nil {
					return err
				}
				if err = cache.Add(ctx, 2, Category{ID: 2, Name: "2"}); err != nil {
					return err
				}
				return nil
			},
		},
		{
			name:    "Remove",
			id:      1,
			wantErr: true,
			fun: func(c categoryCache) error {
				return cache.Remove(ctx, 1)
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err = tt.fun(cache); err != nil {
				t.Fatal(err)
			}
			got, err := cache.Get(context.Background(), tt.id)
			if (err != nil) != tt.wantErr {
				t.Errorf("Get() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("Get() got = %v, want %v", got, tt.want)
			}
		})
	}
}
```
在测试商品的逻辑时，我们需要配置文件的数据库信息，可以这样初始化
```go
func TestProduct(t *testing.T) {
	ctx := context.Background()
	root := weavertest.Init(ctx, t, weavertest.Options{
		SingleProcess: true,
		Config: `
			["lemon\\service\\product\\T"]
			dsn = "test.db"`,
	})
	service, err := weaver.Get[T](root)
	if err != nil {
		t.Fatal(err)
	}
}
```

# 日志
日志也是我们写代码的关键一环，排查问题通常都是靠它。weaver也提供了自己的`logger`，每个组件都持有自己的`logger`
```go
type Logger interface {
	Debug(msg string, attributes ...any)
	Info(msg string, attributes ...any)
	Error(msg string, err error, attributes ...any)
	With(attributes ...any) Logger
}
```
日志的接口比较简单，下面给一些演示
```go
func (s *impl) LogWithTrace(ctx context.Context) weaver.Logger {
	span := trace.SpanFromContext(ctx)
	return s.Logger().With(
		"spanID", span.SpanContext().SpanID().String(),
		"traceID", span.SpanContext().TraceID().String())
}

func (s *impl) Get(ctx context.Context, id int64) (Category, error) {
	cate, err := s.cache.Get(ctx, id)
	if err != nil {
		s.LogWithTrace(ctx).Error("cache Get err", err, "id", id)
	}
	return cate, nil
}

func (s *impl) Create(ctx context.Context, category Category) error {
	if err := s.cache.Add(ctx, category.ID, category); err != nil {
		s.LogWithTrace(ctx).Error("cache Add err", err, "id", category.ID)
	}
	return nil
}

func (s *impl) Update(ctx context.Context, id int64, category Category) error {
	if err := s.cache.Add(ctx, id, category); err != nil {
		s.LogWithTrace(ctx).Error("cache Add err", err, "id", id)
	}
	return nil
}
```
这是缓存日志的代码，这里我封装了`LogWithTrace`把`spanID`以及`traceID`注入到日志中，方便和链路追踪系统配合排查原因，
打印后的日志大概长这样
```shell
E0321 20:03:02.403842 lemon\service\category\T 27e41665 service.go:45] cache Get err err="record not found" id="1" spanID="1a3177735a5c65b3" traceID="3617bf1460d2ae17a3f54eabc14296ba"
```

# 指标
采集指标，并将指标可视化，可以评估我们服务的可靠性和稳定性，通过指标的变化即使预警，可以让我们及时感知并做出处理。
weaver提供了三种指标，分别是
1. counter：计数器
2. gauges：仪表盘
3. histograms：直方图

下面以计数器为例，计算一个函数被调用的次数
```shell
import "github.com/ServiceWeaver/weaver/metrics"

var (
    count = metrics.NewCounter(
        "count",
        "count number",
    )
)
  
func testFun(_ context.Context) (error) {
    addCount.Add(1)
    // 其他逻辑
    ....
    return nil
}
```

不仅如此，在上次我们写的对外API中，使用了`weaver.InstrumentHandlerFunc`
```go
func (s *Server) registerHandler() {
	instrument := func(label string, fn func(http.ResponseWriter, *http.Request)) http.Handler {
		return weaver.InstrumentHandlerFunc(label, func(w http.ResponseWriter, r *http.Request) {
			span := trace.SpanFromContext(r.Context())
			span.SetAttributes(attribute.String("http.path", r.URL.Path))
			fn(w, r)
		})
	}
	http.Handle("/product", instrument("product", s.productHandler))
	http.Handle("/category", instrument("category", s.categoryHandler))
}
```
而在该函数中，它帮我们实现了几个http通用指标，无需重复编写
```go
func InstrumentHandler(label string, handler http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		labels := httpLabels{Label: label, Host: r.Host}
        
		// http调用次数
		httpRequestCounts.Get(labels).Add(1)
		defer func() {
			// http请求时间
			httpRequestLatencyMicros.Get(labels).Put(
				float64(time.Since(start).Microseconds()))
		}()
		if size, ok := requestSize(r); ok {
			// http接受字节大小
			httpRequestBytesReceived.Get(labels).Put(float64(size))
		}
		writer := responseWriterInstrumenter{w: w}
		handler.ServeHTTP(&writer, r)
		if writer.statusCode >= 400 && writer.statusCode < 600 {
			// http处理失败次数
			httpRequestErrors.Get(httpErrorLabels{
				Label: label,
				Host:  r.Host,
				Code:  writer.statusCode,
			}).Add(1)
		}
		// http返回字节大小
		httpRequestBytesReturned.Get(labels).Put(float64(writer.responseSize(r)))
	})
}
```
而针对每个组件，weaver也会自动生成指标，有兴趣可以自己看看源码。

# 链路追踪
微服务架构导致一个接口，可能会经过到五六个系统，甚至更多，这会导致出现问题很难排查，而有了链路追踪，每一个请求都将清晰明了，可以快速地定位是哪个服务出现问题。
在weaver的生成代码中，它为每个组件的方法都加上了链路追踪，不过前提是我们需要初始化
```go
func (s *Server) Run(addr string) error {
	lis, err := s.root.Listener("lemon", weaver.ListenerOptions{LocalAddress: addr})
	if err != nil {
		return err
	}
	s.root.Logger().Debug("listener available", "addr", lis)
	// 初始化
	return http.Serve(lis, otelhttp.NewHandler(http.DefaultServeMux, "http"))
}
```
生成的调用代码
```go
func (s t_local_stub) List(ctx context.Context, a0 []int64) (r0 []Product, err error) {
	span := trace.SpanFromContext(ctx)
	if span.SpanContext().IsValid() {
		// Create a child span for this method.
		ctx, span = s.tracer.Start(ctx, "product.T.List", trace.WithSpanKind(trace.SpanKindInternal))
		defer func() {
			if err != nil {
				span.RecordError(err)
				span.SetStatus(codes.Error, err.Error())
			}
			span.End()
		}()
	}

	return s.impl.List(ctx, a0)
}
```

# 小结
这一节了解了weaver中的测试以及可观测的API，并把它加入到我们的商品后台项目。
收集到的指标，链路追踪都可以通过`weaver dashboard`去查看，这个大家自行了解。  
项目源码：https://github.com/lemon-1997/weaver-example