---
title: "go自动化生成数据库curd代码（一）：想法与设计"
description: "介绍sqlboy项目，使用方式，整体框架"
keywords: "go,generate,tool,代码生成"

publishDate: 2022-12-26T20:30:00+08:00
lastmod: 2022-12-26T20:30:00+08:00

categories:
- 项目实战
tags:
- go
- generate
- sqlboy

toc: true
url: "post/project-sqlboy.html"
---

在平常业务开发中，我们经常会使用一些数据库框架，诸如gorm，sqlc，ent等等。
每当想新加一个表时，就会产生很多重复性的操作，例如插入数据，读取数据，删除之类。
这大大降低了开发效率，于是，我萌生了一个想法，想把这些操作都交给程序去实现。

<!--more-->

# 想法
在有了这个想法之后，我根据实际业务需要，再结合一些优秀的开源项目后，我认为我的这个工具必须具备以下几个特点
- 简单  
一个是使用简单，代码生成的命令简单，没有复杂的参数，且输入只有sql建表语句。  
另一个是生成的代码简单，可读，可靠，没有bug，尽量不生成冗余代码，使用者一目了然  。
- 全面  
生成的代码要尽可能全面，覆盖到所有可能出现的场景。  
本来我只想生成最基础的curd四个方法，后续又增加了批量插入，以及根据主键以及唯一键生成对于的查询，更新以及删除方法。
- 可用  
可用的意思是即插即用，我生成的代码能立即被使用，无需做任何修改以及封装。  
于是除了curd外，我还额外生成了dao，model，transaction等文件。

# 定义输入输出
## 输入
输入这里有两个选择，我纠结了好几天才做出的决定
- go文件：用go AST将建表sql读取解析。
- 配置文件：采用.yaml或者.json或者.sql的形式，然后读取配置文件。  
利弊分析：
使用配置文件会比较优雅，好实现。
采用go ast读取实现较难，但是可以使用编译时断言。
最终为了学习下go AST，就不用简单的配置文件形式，而是采用后者。
## 输出
暂时决定有两种输出模式，一种是gorm，一种是sqlx，想生成哪种由用户决定。这里以sqlx为例，总共会生成以下文件：
1. assert.go
```go
package sqlboy

func _() {
	_ = map[bool]struct {
	}{false: {}, order == `
-- order_info definition

CREATE TABLE 'order_info' (
  'id' int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT '自增ID',
  'order_id' varchar(20) NOT NULL DEFAULT '' COMMENT '订单号',
  'status' tinyint(3) NOT NULL DEFAULT '0' COMMENT '订单状态',
  'created_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  'updated_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY ('id'),
  UNIQUE KEY 'uk_order' ('order_id')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
`: {}}
}

```
2. model.go
```go
package sqlboy

import "time"

type OrderInfo struct {
	Id        uint32    `db:"id" json:"id"`                 //自增ID
	OrderId   string    `db:"order_id" json:"order_id"`     //订单号
	Status    int8      `db:"status" json:"status"`         //订单状态
	CreatedAt time.Time `db:"created_at" json:"created_at"` //创建时间
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"` //修改时间
}

func (*OrderInfo) TableName() string {
	return `order_info`
}
```
3. dao.go
```go
package sqlboy

import (
	"context"
	"github.com/jmoiron/sqlx"
)

type contextTxKey struct{}

type Dao struct {
	db *sqlx.DB
}

func NewDao(db *sqlx.DB) *Dao {
	return &Dao{
		db: db,
	}
}

func (d *Dao) InTx(ctx context.Context, fn func(ctx context.Context) error) error {
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

func (d *Dao) DB(ctx context.Context) DbTx {
	tx, ok := ctx.Value(contextTxKey{}).(*sqlx.Tx)
	if ok {
		return tx
	}
	return d.db
}
```
4. transaction.go
```go
package sqlboy

import (
	"context"
	"database/sql"
	"github.com/jmoiron/sqlx"
)

type Transaction interface {
	InTx(context.Context, func(ctx context.Context) error) error
}

func NewTransaction(d *Dao) Transaction {
	return d
}

type DbTx interface {
	QueryRowxContext(ctx context.Context, query string, args ...interface{}) *sqlx.Row
	QueryxContext(ctx context.Context, query string, args ...interface{}) (*sqlx.Rows, error)
	NamedExecContext(ctx context.Context, query string, arg interface{}) (sql.Result, error)
	ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
}
```
5. query_table.go (这个文件只展示一部分)
```go
package sqlboy

import "context"

type OrderInfoDao interface {
	CreateOrderInfo(ctx context.Context, orderInfo *OrderInfo) error
	BatchCreateOrderInfo(ctx context.Context, list []*OrderInfo, batchSize int) error
	FindOrderInfo(ctx context.Context, id uint32) (*OrderInfo, error)
	UpdateOrderInfo(ctx context.Context, orderInfo *OrderInfo) error
	DeleteOrderInfo(ctx context.Context, id uint32) error
	FindByOrderId(ctx context.Context, orderId string) (*OrderInfo, error)
	UpdateByOrderId(ctx context.Context, orderInfo *OrderInfo) error
	DeleteByOrderId(ctx context.Context, orderId string) error
}

type OrderInfoImpl struct {
	dao *Dao
}

func NewOrderInfoDao(dao *Dao) OrderInfoDao {
	return &OrderInfoImpl{
		dao: dao,
	}
}

func (d *OrderInfoImpl) CreateOrderInfo(ctx context.Context, orderInfo *OrderInfo) error {
	_, err := d.dao.DB(ctx).NamedExecContext(ctx, "INSERT INTO `order_info` (`id`,`order_id`,`status`,`created_at`,`updated_at`) VALUES (:id,:order_id,:status,:created_at,:updated_at)", orderInfo)
	return err
}

func (d *OrderInfoImpl) BatchCreateOrderInfo(ctx context.Context, list []*OrderInfo, batchSize int) error {
	return d.dao.InTx(ctx, func(ctx context.Context) error {
		for i := 0; i < len(list); i += batchSize {
			ends := i + batchSize
			if ends > len(list) {
				ends = len(list)
			}
			_, err := d.dao.DB(ctx).NamedExecContext(ctx, "INSERT INTO `order_info` (`id`,`order_id`,`status`,`created_at`,`updated_at`) VALUES (:id,:order_id,:status,:created_at,:updated_at)", list[i:ends])
			if err != nil {
				return err
			}
		}
		return nil
	})
}
```

# 设计
- go AST  
这个在前文有提到过，用来做输入的解析，建表语句的读取。这里我还把部分输出任务也给了他
（其实输出不应该用AST，效率低，且难以维护，这里只是为了尝试）
- ANTLR vs yacc  
调研的时候发现很多ddl to struct的项目都是直接引用的一个使用yacc解析sql的库。
不过在经过对比之后，我发现yacc比较古老，而且还得自己去实现分词，因此直接放弃，采用更先进的ANTLR。
- go template  
输出是用的go原生text/template渲染，为了减少依赖，除了ANTLR，就没打算用第三方库。

# 整体架构
![image](https://github.com/lemon-1997/sqlboy/blob/main/img/sqlboy.PNG?raw=true)

# 小结
这是sqlboy这个系列的第一篇文章，主要是写自己的想法由来，后续还将打算写四篇文章讲述具体实现细节。
这个项目已经完成了，欢迎大家使用并给我提bug。  
项目源码 https://github.com/lemon-1997/sqlboy