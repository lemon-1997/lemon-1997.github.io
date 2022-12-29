---
title: "go自动化生成数据库curd代码（四）：模板生成"
description: "go官方包template生成代码"
keywords: "go,template"

publishDate: 2022-12-29T20:28:00+08:00
lastmod: 2022-12-29T20:28:00+08:00

categories:
- 项目实战
tags:
- go
- generate
- sqlboy
- template

toc: true
url: "post/project-sqlboy-4.html"
---

上一节我们完成了对SQL的解析，得到了表的相关信息。根据这些信息，我们就可以确定表相对应的curd代码，生成代码我们使用go自带的标准包text/template。
下面将为大家介绍template，并使用template实现代码生成功能。

<!--more-->

# template使用
## 模板数据
下面的例子，执行完会输出`10 items`
```go
type Data struct {
	Count    uint
}
tmpl, err := template.New("test").Parse("{{.Count}} items")
if err != nil { panic(err) }
err = tmpl.Execute(os.Stdout, Data{Count: 10})
if err != nil { panic(err) }
```
模板里`{{.Count}}`指的从当前对象取`Count`变量，其中`.`指的就是当前对象，也就是我们传入的`Data`对象，所以最终`{{.Count}}`会被替换成10，这也是最基础的用法。
## 空白去除
假设有以下模板
```
"{{23 -}} < {{- 45}}"
```
最终的结果是
```
"23<45"
```
`-}}`与`{{-`是template规定的一种语法，`-}}`表示去除后面的空格，反之同理。去除空白是一个很实用的功能，后面我将利用他去除多余的空行。
如果没有这个功能，我们的模板文件将会变得很拥挤，难以维护。所以，要多利用去除空白，让我们的模板变得更清晰。
## 常用的Action
介绍两个比较常用的，一个是条件判断
```
{{if pipeline}} T1 {{else if pipeline}} T0 {{end}}
```
另一个是遍历，这里要注意的是作用域的问题，range里面的作用域`{{.}}`实际上是你遍历的对象，而不再是顶层的渲染对象。
```
{{range pipeline}} T1 {{end}}
```
这两个都比较简单，后面会使用到。
## 变量
我们还可以在模板定义我们的变量
```
$variable := pipeline
$variable = pipeline
range $index, $element := pipeline
```
## 函数
template有内置函数供我们使用，以下摘自go官方文档
```
and
	Returns the boolean AND of its arguments by returning the
	first empty argument or the last argument. That is,
	"and x y" behaves as "if x then y else x."
	Evaluation proceeds through the arguments left to right
	and returns when the result is determined.
call
	Returns the result of calling the first argument, which
	must be a function, with the remaining arguments as parameters.
	Thus "call .X.Y 1 2" is, in Go notation, dot.X.Y(1, 2) where
	Y is a func-valued field, map entry, or the like.
	The first argument must be the result of an evaluation
	that yields a value of function type (as distinct from
	a predefined function such as print). The function must
	return either one or two result values, the second of which
	is of type error. If the arguments don't match the function
	or the returned error value is non-nil, execution stops.
html
	Returns the escaped HTML equivalent of the textual
	representation of its arguments. This function is unavailable
	in html/template, with a few exceptions.
index
	Returns the result of indexing its first argument by the
	following arguments. Thus "index x 1 2 3" is, in Go syntax,
	x[1][2][3]. Each indexed item must be a map, slice, or array.
slice
	slice returns the result of slicing its first argument by the
	remaining arguments. Thus "slice x 1 2" is, in Go syntax, x[1:2],
	while "slice x" is x[:], "slice x 1" is x[1:], and "slice x 1 2 3"
	is x[1:2:3]. The first argument must be a string, slice, or array.
js
	Returns the escaped JavaScript equivalent of the textual
	representation of its arguments.
len
	Returns the integer length of its argument.
not
	Returns the boolean negation of its single argument.
or
	Returns the boolean OR of its arguments by returning the
	first non-empty argument or the last argument, that is,
	"or x y" behaves as "if x then x else y".
	Evaluation proceeds through the arguments left to right
	and returns when the result is determined.
print
	An alias for fmt.Sprint
printf
	An alias for fmt.Sprintf
println
	An alias for fmt.Sprintln
urlquery
	Returns the escaped value of the textual representation of
	its arguments in a form suitable for embedding in a URL query.
	This function is unavailable in html/template, with a few
	exceptions.
```
不仅如此，还支持我们自定义函数，这个下面将会讲到，有了自定义函数，模板渲染也将变得更加灵活。
## 模板定义
我们还可以定义我们的模板（定义不会输出）
```
{{define "T1"}}ONE{{end}}
```
使用定义的模板（输出模板T1定义的内容）
```
{{template "T1"}}
```
了解了template的基本语法后，就可以开发了。

# 静态文件
我把生成的文件分成静态和动态，静态是指不依赖数据表，文件内容始终一样的，只有包名是不确定，需要我们传入。
静态有`dao.go`以及`transaction.go`文件，先把渲染函数实现。
```go
func render(tmpl string, wr io.Writer, data interface{}) error {
    t, err := template.New(tmpl).Parse(tmpl)
    if err != nil {
        return err
    }
    return t.Execute(wr, data)
}
```
而我们的模板只有一处是变化的，就是包名`package {{.}}`，我们直接用`{{.}}`，所以渲染的调用方式类似下面这样
```go
var packageName string
var buf bytes.Buffer
err := render(tmpl, &buf, packageName)
if err != nil{
	return err
}
```

# 动态文件
动态文件在这里只有curd代码，表对应的结构体代码已经交给AST生成，这里就不再说了，只讲template部分。
由于curd代码比较复杂，所以我们需要用到自定义函数，自定义函数是这样使用的
```go
funcMap := template.FuncMap{
    "caseExport":      camelCaseExport,
    "caseInternal":    camelCaseInternal,
}
t, err := template.New(tmpl).Funcs(funcMap).Parse(tmpl)
if err != nil {
    return err
}
return t.Execute(wr, data)
```
`camelCaseExport`，`camelCaseInternal`是我自定义的函数，功能是把变量转化成驼峰命名，一个是可导出的命名（首字母大写），一个是内部的命名（首字母小写）。
在模板文件中，可以直接调用自定义函数
```
{{- $tableExport := caseExport .Table -}}
{{- $tableInternal := caseInternal .Table -}}
```
这里定义了两个变量，分别是表名的导出命名和内部命名，后续直接引用变量就行。在编写模板文件时，难点在于需要生成主键，以及唯一键的curd代码。
我们可以先定义好渲染的变量
```go
type Column struct {
	Name      string
	Type      string
	IsNotNull bool
}

type QueryData struct {
	Package    string
	Table      string
	Columns    []Column
	PrimaryKey []Column
	UniqueKeys [][]Column
	ImportSqlx bool
}
```
以唯一键为例，我们需要遍历，表中定义的唯一键
```bash
// keyFunSign表示遍历传入的唯一键，并将其变成导出命名，比如我们有一组唯一键（`id`, `count`），那么将会变成：IdCount
{{- define "keyFunSign" -}} 
{{range .}}{{caseExport .Name}}{{end}} 
{{- end -}}

// keyParams表示遍历传入的唯一键，比如我们有一组唯一键（`id`, `count`），将会生成：, id int64, count int64
{{- define "keyParams" -}}
{{range .}}, {{caseInternal .Name}} {{.Type}}{{end}}
{{- end -}}

{{- range .UniqueKeys}}
	FindBy{{template "keyFunSign" .}}(ctx context.Context{{template "keyParams" .}}) (*{{$tableExport}}, error)
	UpdateBy{{template "keyFunSign" .}}(ctx context.Context, {{$tableInternal}} *{{$tableExport}}) error
	DeleteBy{{template "keyFunSign" .}}(ctx context.Context{{template "keyParams" .}}) error
{{- end}}
```
其他的过程都大同小异，只不过生成sqlx代码会复杂点，因为存在null特殊结构，而且还需要拼接sql，不过也差不多，花点时间加上自定义函数的帮助也能够实现，这里就不再展开描述。

# 小结
在这节过后，我们已经完成了90%的工作，所以的模块，功能已经实现。剩下的任务就是将这些模块拼接，集成使用，由于模块比较分散，组装也不是件容易的事，这个我会在下一篇文章讲到。  
项目源码：https://github.com/lemon-1997/sqlboy