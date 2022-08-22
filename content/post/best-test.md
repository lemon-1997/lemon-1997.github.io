---
title: "如何在go中写好单元测试"
description: "如何在go中写好单元测试"
keywords: "go,test,单元测试"

date: 2022-08-15T22:44:12+08:00
lastmod: 2022-08-22T22:44:12+08:00

categories:
- 最佳实践
tags:
- go
- 单元测试

toc: true
url: "post/best-test.html"
---

当你还在用postman测试你的api时，那表明你还没找到使用go的最佳姿势，阅读这篇文章，一起来了解下go内置的测试框架，这会对你有所帮助。

<!--more-->

# 单元测试

## 什么是单元测试 覆盖率

## 单元测试的优点

# go内置测试框架
go官方包自带了测试框架，这不仅仅是go官方为了所有gopher能更方便的写测试，也直接证明了测试的重要性，官方直接把他丢进了std里，可见一斑。
在最新版本的go中，go团队加入了模糊测试，不过本篇文章只涉及单元测试，不会讲解基准测试以及模糊测试。

## testing.T
在go中写单元测试，我们先写了解下 `testing.T` 这个类型以及其持有的方法
```go
// TB is the interface common to T and B.
type TB interface {
    Cleanup(func())
    Error(args ...interface{})
    Errorf(format string, args ...interface{})
    Fail()
    FailNow()
    Failed() bool
    Fatal(args ...interface{})
    Fatalf(format string, args ...interface{})
    Helper()
    Log(args ...interface{})
    Logf(format string, args ...interface{})
    Name() string
    Skip(args ...interface{})
    SkipNow()
    Skipf(format string, args ...interface{})
    Skipped() bool
    TempDir() string
    
    // A private method to prevent users implementing the
    // interface and so future additions to it will not
    // violate Go 1 compatibility.
    private()
}

type T struct {
    common
    isParallel bool
    context    *testContext // For running tests and subtests.
}

var _ TB = (*T)(nil)
```
这里顺便给大家科普下，`var _ TB = (*T)(nil)` 这行语句，使用了编译型断言，如果 `T` 没有实现 `TB` 里定义的方法，那么编译就会报错，这样能让开发者及时发现问题，避免错误的发生。大家平常写代码也可以使用编译型断言来让自己的项目更加健壮。

常用方法
* Logf：记录日志，提供代码测试时运行信息
* Errorf：记录日志，但会让测试不能通过
* Fatalf：记录日志，测试立即停止且测试失败
* Skipf：记录日志，并跳过该测试函数
* Cleanup：清理函数，资源的释放
* Helper：辅助函数，打印文件行信息

## 官方例子
`testing.T` 看起来比较简单，老规矩，先上官方例子
```go
package greetings

import (
    "testing"
    "regexp"
)

// TestHelloName calls greetings.Hello with a name, checking
// for a valid return value.
func TestHelloName(t *testing.T) {
    name := "Gladys"
    want := regexp.MustCompile(`\b`+name+`\b`)
    msg, err := Hello("Gladys")
    if !want.MatchString(msg) || err != nil {
        t.Fatalf(`Hello("Gladys") = %q, %v, want match for %#q, nil`, msg, err, want)
    }
}

// TestHelloEmpty calls greetings.Hello with an empty string,
// checking for an error.
func TestHelloEmpty(t *testing.T) {
    msg, err := Hello("")
    if msg != "" || err == nil {
        t.Fatalf(`Hello("") = %q, %v, want "", error`, msg, err)
    }
}
```
上面的例子大家应该都看得懂，我就不总结具体的测试流程了，这里主要是为了给大家展示在go中写单元测试是多么方便。
# 最佳实践
## starting 
go测试规范 文件 函数命名规范
## table test
## mock test (interface)
## db test (how to mock)
## set up tear down how to di
