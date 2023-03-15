---
title: "Google分布式框架Weaver（二）：组件搭建商品后台"
description: "weaver组件使用，从零搭建商品后端系统"
keywords: "weaver,组件,微服务"

publishDate: 2023-03-15T21:00:00+08:00
lastmod: 2023-03-15T21:00:00+08:00

categories:
- 框架教程
tags:
- go
- weaver
- 微服务

toc: true
url: "post/frame-weaver-2.html"
---

组件是weaver中的一个核心抽象，在我们的应用中，组件是一组接口的实现，可以理解为微服务对外提供的API。
所以，组件是学习这个框架的第一步，接下来我将使用组件从零搭建一个简易的商品后台系统。

<!--more-->

# 设计
假设我们正在构建一个在线商店的后端服务，需要设计一个商品管理系统。该系统需要实现对商品的创建、读取、更新和删除操作，以及支持商品的分类管理。
针对该场景我们可以设计两张表：

商品表（product）

| 字段  | 备注  |
|-----|-----|
| id | 商品ID（主键，自增） |
| name | 商品名称 |
| description | 商品描述 |
| price | 商品价格 |
| category_id | 商品分类ID |
| created_at | 创建时间 |
| updated_at | 更新时间 |

商品分类表（category）

| 字段  | 备注  |
|-----|-----|
| id | 分类ID（主键，自增） |
| name | 分类名称 |

# 实现
确定了表设计之后，接下来就是代码实现了。

## 商品
首先是确定商品实体结构，并抽象出对外调用的接口。
```go
type Product struct {
	weaver.AutoMarshal
	ID          int64     `gorm:"column:id"`
	Name        string    `gorm:"column:name"`
	Description string    `gorm:"column:description"`
	Price       float64   `gorm:"column:price"`
	CategoryId  int64     `gorm:"column:category_id"`
	CreatedAt   time.Time `gorm:"column:created_at"`
	UpdatedAt   time.Time `gorm:"column:updated_at"`
}

type T interface {
	List(ctx context.Context, ids []int64) ([]Product, error)
	Create(ctx context.Context, product Product) (int64, error)
	Update(ctx context.Context, id int64, product Product) error
	Delete(ctx context.Context, id int64) error
}
```
这里`Product`结构嵌入了`weaver.AutoMarshal`，它能够让我们在使用`weaver generate`时生成`WeaverMarshal`和`WeaverUnmarshal`，因为组件之间的调用可能是使用`rpc`，因此需要序列化。
不过这里要注意，`weaver.AutoMarshal`并不是所以类型都能序列化，比如`channel`，`func()`都是无法生成代码的。
接下来，我们需要实现以上接口，先定义`impl`结构。
```go
type impl struct {
	weaver.Implements[T]
	weaver.WithConfig[config]
	db *gorm.DB
}

type config struct {
	Dsn string `toml:"dsn"`
}
```
`impl`中嵌入了`weaver.Implements`和`weaver.WithConfig`，其中`weaver.Implements[T]`表示你实现了接口`T`,
后续`weaver generate`生成代码的调用就是使用你的实现，所以要想对外提供服务，这个是必须嵌入的字段。
`weaver.WithConfig`则表明你的组件需要配置，在初始化组件时就会去解析配置文件并转化好我们需要的结构，
在这里我们只需要`dsn`，所以我们在配置文件加上两行。
```
[组件名]
dsn = "local.db"
```
由于我们使用了数据库，所以我们需要实现init函数，组件初始化时`weaver`会判断我们是否实现了`init(ctx) err`，有则会调用，所以并不是所以的组件都必须实现。
```go
func (s *impl) Init(_ context.Context) error {
	cfg := s.Config()
	db, err := gorm.Open(sqlite.Open(cfg.Dsn), &gorm.Config{})
	if err != nil {
		return errors.New("failed to connect database")
	}
	// Migrate the schema
	if err = db.AutoMigrate(&Product{}); err != nil {
		return err
	}
	s.db = db
	return nil
}
```
最后实现商品的curd接口。
```go
func (s *impl) List(ctx context.Context, ids []int64) (list []Product, err error) {
	if err = s.db.WithContext(ctx).Find(&list, ids).Error; err != nil {
		s.Logger().Error("db Find error", err, "ids", ids)
	}
	return
}

func (s *impl) Create(ctx context.Context, product Product) (id int64, err error) {
	if err = s.db.WithContext(ctx).Create(&product).Error; err != nil {
		s.Logger().Error("db Create error", err, "product", product)
	}
	return product.ID, err
}

func (s *impl) Update(ctx context.Context, id int64, product Product) error {
	if err := s.db.WithContext(ctx).Model(&Product{}).Where(`id = ?`, id).Updates(&product).Error; err != nil {
		s.Logger().Error("db Updates error", err, "id", id)
	}
	return nil
}

func (s *impl) Delete(ctx context.Context, id int64) error {
	if err := s.db.WithContext(ctx).Delete(&Product{}, id).Error; err != nil {
		s.Logger().Error("db Delete error", err, "id", id)
	}
	return nil
}
```

## 分类
分类这里，由于weaver提供了会话路由功能，所以可以使用内存的方式去存储商品分类，我们抽象出一个分类缓存。
```go
type categoryCache interface {
	Add(context.Context, int64, Category) error
	Get(context.Context, int64) (Category, error)
	Remove(context.Context, int64) error
}

type categoryCacheImpl struct {
	weaver.Implements[categoryCache]
	weaver.WithRouter[categoryCacheRouter]

	cache sync.Map
}
```
缓存的实现内嵌了`weaver.Implements`和`weaver.WithRouter`，`weaver.Implements`我们已经知道用法了，那么`weaver.WithRouter`呢？
`weaver.WithRouter[categoryCacheRouter]`表示当你调用组件的方法时，它会调用`categoryCacheRouter`的同名方法返回的key去路由，所以我们需要实现`categoryCacheRouter`。
```go
type categoryCacheRouter struct{}

func (categoryCacheRouter) Add(_ context.Context, key int64, _ Category) int64 { return key }
func (categoryCacheRouter) Get(_ context.Context, key int64) int64             { return key }
func (categoryCacheRouter) Remove(_ context.Context, key int64) int64          { return key }
```
不过要注意，必须是跟组件的接口同名，且返回的key有要求，必须是`integer`，`float`或`string`。
这样一来，调用缓存时，相同的key都会路由到同一进程，因此我们可以放到内存去做。
```go
func (c *categoryCacheImpl) Add(_ context.Context, id int64, category Category) error {
	c.cache.Store(id, category)
	return nil
}

func (c *categoryCacheImpl) Get(_ context.Context, id int64) (Category, error) {
	value, ok := c.cache.Load(id)
	if !ok {
		return Category{}, errors.New("record not found")
	}
	cate, ok := value.(Category)
	if !ok {
		return Category{}, errors.New("data error")
	}
	return cate, nil
}

func (c *categoryCacheImpl) Remove(_ context.Context, id int64) error {
	c.cache.Delete(id)
	return nil
}
```
缓存实现了，接下来封装商品分类的服务。
```go
type Category struct {
	weaver.AutoMarshal
	ID   int64
	Name string
}

type T interface {
	Get(ctx context.Context, id int64) (Category, error)
	Create(ctx context.Context, category Category) error
	Update(ctx context.Context, id int64, category Category) error
}

type impl struct {
	weaver.Implements[T]
	cache categoryCache
}

func (s *impl) Init(context.Context) error {
	cache, err := weaver.Get[categoryCache](s)
	if err != nil {
		return err
	}
	s.cache = cache
	return nil
}

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
最后记得`weaver generate`生成组件的调用代码

## API
最后就是提供API接口了，weaver提供了`Listener`方法去创建服务
```go
type Server struct {
	root     weaver.Instance
	product  product.T
	category category.T
}

func NewServer(root weaver.Instance) (*Server, error) {
	productSvc, err := weaver.Get[product.T](root)
	if err != nil {
		return nil, err
	}
	categorySvc, err := weaver.Get[category.T](root)
	if err != nil {
		return nil, err
	}
	s := &Server{
		root:     root,
		product:  productSvc,
		category: categorySvc,
	}
	s.registerHandler()
	return s, nil
}

func (s *Server) Run(addr string) error {
	lis, err := s.root.Listener("lemon", weaver.ListenerOptions{LocalAddress: addr})
	if err != nil {
		return err
	}
	s.root.Logger().Debug("listener available", "addr", lis)
	return http.Serve(lis, otelhttp.NewHandler(http.DefaultServeMux, "http"))
}
```
实现路由逻辑
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

func (s *Server) productHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.getProduct(w, r)
	case http.MethodPost:
		s.createProduct(w, r)
	case http.MethodPut:
		s.updateProduct(w, r)
	case http.MethodDelete:
		s.deleteProduct(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) categoryHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.getCategory(w, r)
	case http.MethodPost:
		s.createCategory(w, r)
	case http.MethodPut:
		s.updateCategory(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
```
handler代码较长，这里就不展示了，需要可以到github仓库看。

# 小结
在这篇博客，我们了解了weaver.Implements，WithRouter，WithConfig以及AutoMarshal的使用，并实现了一个简单的商品后台管理系统。  
项目源码：https://github.com/lemon-1997/weaver-example