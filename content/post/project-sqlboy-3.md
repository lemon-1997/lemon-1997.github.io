---
title: "go自动化生成数据库curd代码（三）：ANTLR解析SQL"
description: "ANTLR对mysql建表语句语法分析"
keywords: "go,ANTLR"

publishDate: 2022-12-28T20:30:00+08:00
lastmod: 2022-12-28T20:30:00+08:00

categories:
- 项目实战
tags:
- go
- generate
- sqlboy
- ANTLR

toc: true
url: "post/project-sqlboy-3.html"
---

在上一节我们了解了go的抽象语法树AST，并利用go提供的AST包拿到了用户定义的sql。接下来就是如何解析sql，将sql语句中的表名，列字段的名称，类型等关键信息提取出来。
这就需要我们的语法分析了，在本项目中我们决定采用ANTLR来完成此任务，他是一个强大的工具，下文我将为大家介绍是如何实现的。

<!--more-->

# ANTLR

## 简介
再讲ANTLR之前，还是想先提一下yacc。yacc是比较出名的语法分析器，不过年代久远，诞生于上个世纪70年代，yacc需要与lex一起才能实现完整的语法树构建。
lex是词法分析器，用于分割语句中的词块，也就是token。go官方也提供了goyacc给我们使用，网上也有关于yacc解析sql的源码。
不过我们还是选择了使用更多的ANTLR，ANTLR目前仍在维护，实现起来比较简单，开发快，还支持所有主流语言，还提供了可视化的语法树，debug特别方便。

## 安装
安装ANTLR有两种方式，最简单的是用pip3安装。因为我本机有python3，所以很方便。
```shell
$ pip install antlr4-tools
```
执行命令
```shell
$ antlr4 
Downloading antlr4-4.11.1-complete.jar
ANTLR tool needs Java to run; install Java JRE 11 yes/no (default yes)? y
Installed Java in /Users/parrt/.jre/jdk-11.0.15+10-jre; remove that dir to uninstall
ANTLR Parser Generator  Version 4.11.1
 -o ___              specify output directory where all output is generated
 -lib ___            specify location of grammars, tokens files
...
```
如果上面的命令都没问题，就是安装成功了，我们可以尝试下，比如实现一个计算器。
先创建Expr.g4，文件名必须与grammar相对应
```
grammar Expr;		
prog:	expr EOF ;
expr:	expr ('*'|'/') expr
    |	expr ('+'|'-') expr
    |	INT
    |	'(' expr ')'
    ;
NEWLINE : [\r\n]+ -> skip;
INT     : [0-9]+ ;
```
并使用强大的gui功能（语法树）
```shell
antlr4-parse Expr.g4 prog -gui
```

# 解析SQL
在编写规则的时候，本来是花了几天时间去实现，完成了表名以及id的定义，不过最后还是发现单单一个建表语句就有很多的规则。
如果单靠自己实现，可能会覆盖不全，而且我平时上班，可能需要花一个月的时间，写这个对我来说帮助也不是很大。
所以，我参照了ANTLR官方mysql的语法（ANTLR官方提供了大量的例子，有兴趣的可以去看看），稍微改造了下，只留下了建表的语法，其余的全部被我删除。
不过，lexer那里还是全部保留下来，虽然有很多token没有使用，考虑涉及到关键字的匹配分词，我都没删。
官方提供的语法虽然很牛逼，不过还是有好几个bug（有些规则为了复用，导致一些根本不会出现在建表规则的也匹配到了），不过这倒不影响，我们的功能要求是能解析，你只要能把正确的解析出来就行。
但是这里也不是说直接拷贝过来就完事，还是要考虑几个问题，解析是不支持多条语句的，如果多个表定义多个变量，分多次解析就行，表名也要支持db.tbl这种情况，mysql字段类型go中类型的转化问题，这些问题我都交给了运行时去解决。

# 运行时解析
先定义我们解析的结果
```go
type ColumnDecl struct {
    Decl      string      // sql字段定义，用于debug
    Name      string      // 字段名称
    Comment   string      // 字段描述
    SqlType   string      // mysql中的类型
    GoType    GoType      // go中对应的类型
    IsNotNull bool        // 是否可以为空（sqlx有Null类型） 
}

// 索引（用于生成curd代码的查询条件）
type ColumnIndex struct {
    Decl    string        
    Columns []ColumnDecl
}

type TableAttr struct {
    TableName  string          // 表名
    Columns    []ColumnDecl    // 字段
    PrimaryKey ColumnIndex     // 主键
    UniqueKeys []ColumnIndex   // 唯一键
}
```
GoType的定义
```go
type GoType string

const (
    Invalid = "invalid"
    
    Bool   = "bool"
    Int8   = "int8"
    Int16  = "int16"
    Int32  = "int32"
    Int64  = "int64"
    Uint8  = "uint8"
    Uint16 = "uint16"
    Uint32 = "uint32"
    Uint64 = "uint64"
    
    Float32 = "float32"
    Float64 = "float64"
    
    String     = "string"
    Time       = "time.Time"
    SliceByte  = "[]byte"
    SliceUint8 = "[]uint8"
)

```
定义好解析结果后，我们先用ANTLR生成代码
```shell
antlr4 -Dlanguage=Go *.g4
```
生成之后，我们实现自己的listener
```go
type StmtListener struct {
    *BaseStmtParserListener
    column ColumnDecl
    TableAttr
}

func NewStmtListener() *StmtListener {
    return new(StmtListener)
}
```
代码比较长，这里以提取表名为例子
```go
func (l *StmtListener) EnterTableName(ctx *TableNameContext) {
    var tableName string
    switch ctx.GetStop().GetTokenType() {
    // 需要去掉引号
    case StmtParserREVERSE_QUOTE_ID, StmtParserCHARSET_REVERSE_QOUTE_STRING, StmtParserSTRING_LITERAL:
        name := ctx.GetStop().GetText()
        if len(name) <= 2 {
            return
        }
        tableName = name[1 : len(name)-1] 
    // db.tbl的形式
    case StmtParserDOT_ID:
        name := ctx.GetStop().GetText()
        if len(name) <= 1 {
            return
        }
        tableName = name[1:]
    default:
        tableName = ctx.GetText()
    }
    l.TableName = tableName
}
```
除了解析之外，我们还需要对错误进行处理，不然错误发生我们都还不知道，无法判断SQL是否正确
```go
type ErrorListener struct {
	*antlr.DefaultErrorListener
	errors []error
}

func NewErrorListener() *ErrorListener {
	return new(ErrorListener)
}

func (l *ErrorListener) HasError() bool {
	return len(l.errors) > 0
}

func (l *ErrorListener) Errors() []error {
	return l.errors
}

func (l *ErrorListener) SyntaxError(recognizer antlr.Recognizer, offendingSymbol interface{}, line, column int, msg string, e antlr.RecognitionException) {
	p := recognizer.(antlr.Parser)
	stack := p.GetRuleInvocationStack(p.GetParserRuleContext())
	err := fmt.Errorf("rule: %v line %d: %d at %v : %s", stack[0], line, column, offendingSymbol, msg)
	l.errors = append(l.errors, err)
}
```
随后便将上面两个集成在一起使用
```go
import (
    "github.com/antlr/antlr4/runtime/Go/antlr/v4"
    parser "github.com/lemon-1997/sqlboy/antlr"
)

func parseStmt(ddl string) (parser.TableAttr, []error) {
    input := antlr.NewInputStream(ddl)
    lexer := parser.NewStmtLexer(input)
    stream := antlr.NewCommonTokenStream(lexer, 0)
    p := parser.NewStmtParser(stream)
    
    el := parser.NewErrorListener()
    p.RemoveErrorListeners()
    p.AddErrorListener(el)
    
    p.BuildParseTrees = true
    tree := p.Prog()
    
    if el.HasError() {
        return parser.TableAttr{}, el.Errors()
    }
    
    l := parser.NewStmtListener()
    antlr.ParseTreeWalkerDefault.Walk(l, tree)
    return l.TableAttr, nil
}
```
在实现代码过程中，还发现了ANTLR go runtime包的一个错误，并提了个pr
https://github.com/antlr/antlr4/pull/3999

# 小结
好了，到这里我们已经能够正确把SQL解析，并提取出我们想要的表字段等信息，有了这些信息后，我们就可以根据表的结构，去生成相应的代码了。
下一节我将向大家介绍如果用模板渲染出代码，有兴趣的可以关注一下。  
项目源码：https://github.com/lemon-1997/sqlboy