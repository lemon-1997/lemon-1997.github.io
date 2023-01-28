---
title: "go整洁架构简单模板"
description: "go构建微服务项目简单示例"
keywords: "go,整洁架构,template"

publishDate: 2023-01-28T15:00:00+08:00
lastmod: 2023-01-28T15:00:00+08:00

categories:
- 最佳实践
tags:
- go
- 整洁架构

toc: true
url: "post/best-clean.html"
---

在日常开发中，我们大多的精力都花在业务开发上，设计可能只占用了少部分的时间。
实际上，好的架构会让别人维护起来很舒服，很轻松。而不好的设计，会浪费你更多的时间，提高成本。
近些年来，整洁架构，领域驱动设计特别火，很多程序员也都用上了。
接下来，我将基于实际开发，介绍go使用整洁架构的例子。

<!--more-->

# 分层设计
分层设计相信大家都知道，最熟悉的应该就是MVC（Model-View-Controller）架构了，分层能带来许多好处，它能解决各模块的依赖，且有很好的扩展性，对于越来越复杂的业务，如果没有任何设计，后期将难以维护。
这里，我介绍下我项目基于整洁架构的分层设计，这是目录结构：
```
├─api
│  ├─dto
│  └─handler
├─cmd
├─config
├─data
├─entity
├─test
└─usecase
```
这个是最简单的结构，在实际业务开发中，可能还有日志，监控等其他模块，可以再增加pkg目录，然后通过wire注入依赖。
整体的架构大概是这样：
![image](https://github.com/lemon-1997/clean/blob/main/clean.PNG?raw=true)

# 模块介绍

下面我将基于目录结构介绍各个模块

## api
`api`是架构图的右侧部分，起数据传递的功能，将输入的数据转化成`entity`的格式，转发`usecase`处理后将`entity`转换成业务需要的数据。
其中，`dto`（Data Transfer Object）是外部输入输出（http，grpc）的数据结构，`handler`是处理`dto`跟`entity`的相互转化，并转发到`usecase`处理业务逻辑
（这一层也可以做基本的数据校验，required，lte等等）。
```go
func (h *Order) orderCreate(w http.ResponseWriter, r *http.Request) {
    // 处理输入
    var req dto.OrderCreateReq
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
    }
    // 转发usecase
    id, err := h.order.CreateOrder(r.Context(), transCreateReqToOrder(&req), transCreateReqToPay(&req))
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
    }
    // 处理输出
    reply := &dto.OrderCreateReply{OrderID: id}
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(reply)
}
```
实际开发中，`handler`会有很多重复代码，可以利用反射，或者自动化生成代码减少重复性的工作。

## cmd
`cmd`是项目的入口，主要是做初始化工作，依赖注入，程序的启动，优雅退出。
```go
func main() {
	c := config.New()
	d, err := data.NewData(c.DB)
	if err != nil {
		panic(err)
	}
	orderRepo := data.NewOrderRepo(d)
	payRepo := data.NewPayRepo(d)
	tm := data.NewTransaction(d)
	uc := usecase.NewOrder(orderRepo, payRepo, tm)
	orderHandler := handler.NewOrder(uc)
	s := api.NewServer(c.Server, orderHandler)
	if err = s.Run(); err != nil {
		panic(err)
	}
}
```

## config
存放配置文件，可能是json，yaml或者配置中心等等都可以，根据实际项目选择最合适的，主要工作是配置解析。
```go
func New() *Config {
	// TODO Config init from file
	return &Config{
		Server: &Server{
			Addr: ":8080",
		},
		DB: &DB{
			Driver: "mysql",
			Source: "root:123456@tcp(127.0.0.1:3306)/testDB",
		},
	}
}
```

## data
`data`是`repo`接口的实现，主要是数据库的curd，或者是其他微服务的调用，项目里我只展示数据库的操作。
```go
type Data struct {
	db *sql.DB
}

func NewData(conf *config.DB) (*Data, error) {
	db, err := sql.Open(conf.Driver, conf.Source)
	if err != nil {
		return nil, err
	}
	defer func() { _ = db.Close() }()
	return &Data{
		db: db,
	}, nil
}
```
接口的实现
```go
type payRepo struct {
	data *Data
}

func NewPayRepo(data *Data) usecase.PayRepo {
	return &payRepo{data: data}
}

func (payRepo) CreatePay(ctx context.Context, pay *entity.Pay) (int64, error) {
	//TODO implement me
	panic("implement me")
}

func (payRepo) DeletePayByID(ctx context.Context, i int64) error {
	//TODO implement me
	panic("implement me")
}
```
针对跨repo的事务下面会详细介绍。

## entity
`entity`层主要定义的各个领域的业务对象，这些结构是共用的，`handler`，`usecase`，`data`都是使用`entity`所定义的结构进行通讯。
所以应该根据自己的实际业务需要，定义好自己的实体结构（并不是简单的根据表结构去定义）。
```go
type Order struct {
    ID            int64     `json:"id"`
    OrderNo       string    `json:"order_no"`       //  订单编号
    OrderStatus   int       `json:"order_status"`   //  订单状态 0未付款,1已付款,2已发货,3已签收,-1退货申请,-2退货中,-3已退货,-4取消交易
    ProductCount  int64     `json:"product_count"`  //  商品数量
    ProductAmount float64   `json:"product_amount"` //  商品总价
    OrderAmount   float64   `json:"order_amount"`   //  实际付款金额
    PayTime       time.Time `json:"pay_time"`       //  付款时间
    DeliveryTime  time.Time `json:"delivery_time"`  //  发货时间
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}
```

## test
`test` 这个目录，主要是对整个链路的测试，如http，grpc等等，而单元测试还是按照go官方的形式，放在自己项目下，用mock生成接口，具体可以看我之前写的单元测试的blog。
```
### Get Order
GET http://127.0.0.1:8080/order?id=1

### Create Order
POST http://127.0.0.1:8080/order
Content-Type: application/json

{
  "value": "content"
}

### Update Order
PUT http://127.0.0.1:8080/order

### Delete Order
DELETE http://127.0.0.1:8080/order
```

## usecase
`usecase`主要是业务逻辑的实现，输入输出统一用`entity`层的结构。
```go
type OrderUseCase struct {
	order OrderRepo
	pay   PayRepo
	tm    Transaction
}

func NewOrder(order OrderRepo, pay PayRepo, tm Transaction) *OrderUseCase {
	return &OrderUseCase{
		order: order,
		pay:   pay,
		tm:    tm,
	}
}

func (uc *OrderUseCase) CreateOrder(ctx context.Context, order *entity.Order, pay *entity.Pay) (orderID int64, err error) {
	err = uc.tm.InTx(ctx, func(ctx context.Context) error {
		if orderID, err = uc.order.CreateOrder(ctx, order); err != nil {
			return err
		}
		if _, err = uc.pay.CreatePay(ctx, pay); err != nil {
			return err
		}
		return nil
	})
	return
}
```
这一层不会有依赖，有依赖都使用`interface`，测试都用mock生成。
```go
type OrderRepo interface {
	CreateOrder(context.Context, *entity.Order) (int64, error)
	FindOrderByID(context.Context, int64) (*entity.Order, error)
	UpdateOrderByID(context.Context, *entity.Order, int64) error
	DeleteOrderByID(context.Context, int64) error
}

type PayRepo interface {
	CreatePay(context.Context, *entity.Pay) (int64, error)
	DeletePayByID(context.Context, int64) error
}

```

# 事务
关于整洁架构，有时候我们需要在多个`repo`开启事务，如何实现呢，这里我推荐一个比较优雅的办法，也是最多人使用的。
首先我们可以定义我们的事务接口：
```go
type Transaction interface {
    InTx(context.Context, func(ctx context.Context) error) error
}
```
输入是`context`和执行事务的函数，输出是`error`，实现通过`data`实现
```go
func NewTransaction(d *Data) usecase.Transaction {
    return d
}

func (d *Data) InTx(ctx context.Context, fn func(ctx context.Context) error) error {
    tx, err := d.db.Begin()
    if err != nil {
        return err
    }
    defer func() { _ = tx.Rollback() }()
    
    err = fn(context.WithValue(ctx, contextTxKey{}, tx))
    
    if err != nil {
        return err
    }
    
    return tx.Commit()
}
```
而我们`repo`的实现统一使用`data`的`DB`函数返回`DbTx`去跟数据库交互
```go
type DbTx interface {
    QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
    QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
    ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func (d *Data) DB(ctx context.Context) DbTx {
    tx, ok := ctx.Value(contextTxKey{}).(*sql.Tx)
    if ok {
        return tx
    }
    return d.db
}
```
这样一来，我们就可以轻松实现跨repo的事务，而且，repo的实现不用去考虑事务的东西，事务完全是由外部去控制。

# 总结
说了这么多，总结以下整洁架构的优缺点，如果你觉得合适，才能用在项目中，切勿无脑使用。

## 优点
- 可扩展，每一层都是单一职责，不相互依赖，业务增长时，项目不易腐烂，具有很好的扩展性。
- 可测试，可以利用mock在没有依赖时轻松测试自己的业务逻辑。
- 可迁移，项目使用了interface抽象，可以轻松迁移框架，或者数据库等等。

## 缺点
- 复杂，这是一个相对复杂的架构，需要你对自己的业务有很好的理解，不熟悉业务会对领域的拆分，实体的结构定义可能会不准确，后续只会增加你的额外工作。
- 适用场景，如果你的项目比较简单，稳定，建议使用传统的MVC架构，该架构并不适用简单的CURD项目。

## 项目地址
https://github.com/lemon-1997/clean
