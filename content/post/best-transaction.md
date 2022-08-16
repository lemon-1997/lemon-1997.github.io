---
title: "mysql事务在go语言中的正确打开方式"
description: "go实现mysql事务的方式对比"
keywords: "go,mysql,事务"

date: 2022-08-14T17:57:24+08:00
lastmod: 2022-08-16T22:00:00+08:00

categories:
- 最佳实践
tags:
- go
- mysql

toc: true
url: "post/best-transaction.html"
---

相信大家在做curd项目时经常会使用到mysql中的事务，这篇文章将会展示在go中实现mysql事务的几种方式，希望阅读后能够给你带来启发。

<!--more-->

# mysql事务
acid model
* a
* c
* i
* d

事务使用场景以及利弊

# go实现方式
go开启事务的几个步骤
1. 开启事务
2. 执行数据库操作
3. 结束事务
   * 提交事务
   * 回滚事务

## go官方例子
先欣赏下go官方提供的例子
```go
// CreateOrder creates an order for an album and returns the new order ID.
func CreateOrder(ctx context.Context, albumID, quantity, custID int) (orderID int64, err error) {

    // Create a helper function for preparing failure results.
    fail := func(err error) (int64, error) {
        return fmt.Errorf("CreateOrder: %v", err)
    }

    // Get a Tx for making transaction requests.
    tx, err := db.BeginTx(ctx, nil)
    if err != nil {
        return fail(err)
    }
    // Defer a rollback in case anything fails.
    defer tx.Rollback()

    // Confirm that album inventory is enough for the order.
    var enough bool
    if err = tx.QueryRowContext(ctx, "SELECT (quantity >= ?) from album where id = ?",
quantity, albumID).Scan(&enough); err != nil {
		if err == sql.ErrNoRows {
            return fail(fmt.Errorf("no such album"))
        }
        return fail(err)
    }
    if !enough {
        return fail(fmt.Errorf("not enough inventory"))
    }

    // Update the album inventory to remove the quantity in the order.
    _, err = tx.ExecContext(ctx, "UPDATE album SET quantity = quantity - ? WHERE id = ?",
quantity, albumID)
	if err != nil {
		return fail(err)
	}

    // Create a new row in the album_order table.
    result, err := tx.ExecContext(ctx, 
		"INSERT INTO album_order (album_id, cust_id, quantity, date) VALUES (?, ?, ?, ?)",
albumID, custID, quantity, time.Now())
    if err != nil {
        return fail(err)
    }
    // Get the ID of the order item just created.
    orderID, err := result.LastInsertId()
    if err != nil {
        return fail(err)
    }

    // Commit the transaction.
    if err = tx.Commit(); err != nil {
        return fail(err)
    }

    // Return the order ID.
    return orderID, nil
}
```

这是go官方提供的例子，大体的代码流程如下
1. 通过 `DB.Begin` / `DB.BeginTx` 获取 `sql.Tx`
2. 延迟调用 `Tx.Rollback`
3. 执行数据库的插入修改语句
4. 没有出错，通过 `Tx.Commit` 提交

这种方式看起来很不错，失败了能回滚，成功则一起提交，很清晰的表明事务的整个流程。
但是当你项目的业务逻辑愈加复杂，或者事务里面的某个表新加了字段，需要去调整SQL语句的时候，你必须在这个大函数里面去修改，这看起来很危险。
像这个例子所体现的，该函数里面做了多个SQL操作，除了单一的业务场景，很难被别的地方复用。

## mysql事务封装
于是，针对上面的问题，可以先将事务的操作封装起来，并抽离出数据库执行SQL的函数 `fn`
```go
func WithTransaction(db *sql.DB, fn func(sql.Tx) error) (err error) {
	tx, err := db.Begin()
	if err != nil {
		return
	}

	defer func() {
		if p := recover(); p != nil {
			// a panic occurred, rollback and repanic
			tx.Rollback()
			panic(p)
		} else if err != nil {
			// something went wrong, rollback
			tx.Rollback()
		} else {
			// all good, commit
			err = tx.Commit()
		}
	}()

	err = fn(tx)
	return err
}
```
因此使用起来只需要编写相应的数据库操作函数 `fn`，我们可以对订单，商品数据的操作做更细粒度的封装，就像下面这样
```go
err = WithTransaction(db, func(tx sql.Tx) error {
	// insert a record into order table
	res, err := dao.CreateOrder(tx,order)
	if err != nil {
		return err
	}
	
	// update product inventory
	res, err = dao.UpdateInventory(tx,product)
	if err != nil {
		return err
	}
})
```
好了，目前看来这个例子已经很完美了，我们不需要写过多的重复代码，事务的操作，数据库执行的SQL都能被很好的复用。
但是还有个问题，上面的 `CreateOrder` 和 `UpdateInventory` 函数需要传入 `sql.Tx`，这会使调用者难以下手，理论上调用者不应该关心传入哪个数据库，他只想完成创建订单，扣减库存的操作。
而且，当你的事务只需要执行一次SQL时，并不需要开启事务的，但你的传参确实 `sql.Tx`，这会导致多余的代码，且很不优雅。

## interface登场
假设我们现在有一个数据库操作对象 `Dao`
```go
type Dao struct{
	db sql.Db
}

func (d *Dao ) CreateOrder(ctx context, order entity.Order) error {
    d.db.ExecContext(ctx, `Insert into`, order)
}

func (d *Dao ) UpdateInventory(ctx context, product entity.Product) error {
    d.db.ExecContext(ctx, `Insert into`, product)
}
```
如果我们现在需要开启一个事务，这个事务里需要执行 `CreateOrder` 和 `UpdateInventory`，这个时候，很多人的第一个想法是重新写一个函数，因为现有的函数都是由 `sql.Db` 去执行，而不是 `sql.Tx`。
那我们有没有办法减少重复代码的开发呢？答案是有的，那就是 `interface{}`
```go
// Queries is a common interface that is used by both *sqlx.DB and *sqlx.Tx.
type Queries interface {
    QueryRowxContext(ctx context.Context, query string, args ...interface{}) *sqlx.Row
    QueryxContext(ctx context.Context, query string, args ...interface{}) (*sqlx.Rows, error)
    NamedExecContext(ctx context.Context, query string, arg interface{}) (sql.Result, error)
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
}
```
在这里，我们定义了一个叫 `Queries` 的 `interface` 去实现 `sql.Db` 和 `sql.Tx` 。那么再对 `Dao` 重新调整一下，并对外提供一个 `New` 函数，支持传入 `sql.Db` 和 `sql.Tx`
```go
type Dao struct{
    db Queries
}

fun NewOderDao (db Queries) *Dao{
    return &oderDao{db:db}
}
```
这样一来，我们通过 `Queries` 使 `Dao` 中的函数可以同时是普通执行或者开启事务执行，且调用相关函数时不需要传入数据库对象。那么问题来了，如何与上面封装好的 `WithTransaction`一起使用呢？
## best practices
基于上面两者的结合，最佳实践在这，先看下代码实现
# 总结
