---
title: "mysql事务在go语言中的正确打开方式"
description: "go实现mysql事务的方式对比"
keywords: "go,mysql,事务"

date: 2022-08-14T17:57:24+08:00
lastmod: 2022-08-15T21:40:00+08:00

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

{{< gist lemon-1997 17eac44491433666f303b3ff0e252714 "go-dev.go" >}}
这是go官方提供的例子，大体的代码流程如下
1. 通过 `DB.Begin` / `DB.BeginTx` 获取 `sql.Tx`
2. 延迟调用 `Tx.Rollback`
3. 执行数据库的插入修改语句
4. 没有出差，通过 `Tx.Commit` 提交

这种方式看起来很不错，失败了能回滚，成功则一起提交，也很清晰的表明事务的整个流程。
但是当你项目的业务逻辑愈加复杂，或者事务里面的某个表新加了字段，需要去调整SQL语句的适合，你必须在这个大函数里面去修改，这看起来很危险。
像这个例子所体现的，该函数里面做了多个SQL操作，除了单一的业务场景，很难被别的地方复用。

## 错误示范
再来看下面这个例子，勿学
## best practices
基于上面两者的结合，最佳实践在这，先看下代码实现
# 总结
