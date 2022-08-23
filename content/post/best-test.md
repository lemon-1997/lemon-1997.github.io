---
title: "如何在go中写好单元测试"
description: "如何在go中写好单元测试"
keywords: "go,test,单元测试"

date: 2022-08-15T22:44:12+08:00
lastmod: 2022-08-23T21:44:12+08:00

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
todo
## 什么是单元测试 覆盖率
todo
## 单元测试的优点
todo

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
在开始之前，我们要先了解go的测试规范
* 文件名：前缀为测试代码的文件名，以 `_test.go` 结尾（go build 会忽略这些文件）
* 文件位置：位于测试的代码同一 `package` 下
* 函数名：`Test` 为前缀，后面是测试函数名，函数参数为 `*testing.T`

## table test
`table test` 是一种很棒的写法，它能让你的测试代码足够清晰，让你的测试用例易于维护，该写法可以在各种库中见到。其大体流程为：
1. 定义`tests` 为测试用例，其结构为匿名结构体切片 `[]struct{}`
2. 补充匿名结构体变量，定义好输入输出，丰富测试用例
3. 遍历测试用例，调用测试方法，判断测试结果是否符合预期
4. 使用 `testing.T` 里的方法记录日志或让测试失败

go源码 encoding/json/encode_test.go 里就采用了这种测试方式
```go
func TestRoundtripStringTag(t *testing.T) {
	tests := []struct {
		name string
		in   StringTag
		want string // empty to just test that we roundtrip
	}{
		{
			name: "AllTypes",
			in: StringTag{
				BoolStr:    true,
				IntStr:     42,
				UintptrStr: 44,
				StrStr:     "xzbit",
				NumberStr:  "46",
			},
			want: `{
				"BoolStr": "true",
				"IntStr": "42",
				"UintptrStr": "44",
				"StrStr": "\"xzbit\"",
				"NumberStr": "46"
			}`,
		},
		{
			// See golang.org/issues/38173.
			name: "StringDoubleEscapes",
			in: StringTag{
				StrStr:    "\b\f\n\r\t\"\\",
				NumberStr: "0", // just to satisfy the roundtrip
			},
			want: `{
				"BoolStr": "false",
				"IntStr": "0",
				"UintptrStr": "0",
				"StrStr": "\"\\u0008\\u000c\\n\\r\\t\\\"\\\\\"",
				"NumberStr": "0"
			}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			// Indent with a tab prefix to make the multi-line string
			// literals in the table nicer to read.
			got, err := MarshalIndent(&test.in, "\t\t\t", "\t")
			if err != nil {
				t.Fatal(err)
			}
			if got := string(got); got != test.want {
				t.Fatalf(" got: %s\nwant: %s\n", got, test.want)
			}

			// Verify that it round-trips.
			var s2 StringTag
			if err := Unmarshal(got, &s2); err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if !reflect.DeepEqual(test.in, s2) {
				t.Fatalf("decode didn't match.\nsource: %#v\nEncoded as:\n%s\ndecode: %#v", test.in, string(got), s2)
			}
		})
	}
}
```

## mock test
当我们由于某些原因，不好直接调用我们的函数去做测试时，我们应该如何做呢？答案就是 `interface` ，如果我们的测试函数输入刚好是 `interface` 时，那很棒，如果不是呢，考虑下将函数参数抽象为 `interfae` ，是否你的代码会更好。  
直接看下面的例子，这也是来自go源码 io/io_test.go
```go
type zeroErrReader struct {
	err error
}

func (r zeroErrReader) Read(p []byte) (int, error) {
	return copy(p, []byte{0}), r.err
}

type errWriter struct {
	err error
}

func (w errWriter) Write([]byte) (int, error) {
	return 0, w.err
}

// In case a Read results in an error with non-zero bytes read, and
// the subsequent Write also results in an error, the error from Write
// is returned, as it is the one that prevented progressing further.
func TestCopyReadErrWriteErr(t *testing.T) {
	er, ew := errors.New("readError"), errors.New("writeError")
	r, w := zeroErrReader{err: er}, errWriter{err: ew}
	n, err := Copy(w, r)
	if n != 0 || err != ew {
		t.Errorf("Copy(zeroErrReader, errWriter) = %d, %v; want 0, writeError", n, err)
	}
}
```
其实就是自己去mock数据，实现 `io.Writer` 以及 `io.Reader` ，具体怎样实现取决于你想测试的东西。

## dependency injection
有些时候，我们的测试需要外部依赖，例如我们需要数据库实例或者http server，这时候我们可以利用 `TestMain` 的特性  
来看看go源码 net/http/main_test.go
```go
func TestMain(m *testing.M) {
	setupTestData()
	installTestHooks()

	st := m.Run()

	testHookUninstaller.Do(uninstallTestHooks)
	if testing.Verbose() {
		printRunningGoroutines()
		printInflightSockets()
		printSocketStats()
	}
	forceCloseSockets()
	os.Exit(st)
}
```
这样一来，就解决了我们资源的依赖问题。这里给出一个模板参考，具体的 `setup()` 和 `teardown()` 的实现由自己的项目代码所决定。
```go
func setup() {
    fmt.Printf("Setup")
}

func teardown() {
    fmt.Printf("Teardown")
}

func TestMain(m *testing.M) {
    setup()
    code := m.Run()
    teardown()
    os.Exit(code)
}
```
# 结语
这篇文章所讲的东西都是自己最近写单元测试的一些感悟，如果有错误可在下方评论指出，如果对你有帮助，我也很希望在评论区看到你的评论。
好了，到这里就结束了，感谢阅读！