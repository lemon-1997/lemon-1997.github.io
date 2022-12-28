---
title: "go自动化生成数据库curd代码（二）：go抽象语法树（AST）"
description: "go抽象语法树介绍"
keywords: "go,AST"

publishDate: 2022-12-27T20:30:00+08:00
lastmod: 2022-12-27T20:30:00+08:00

categories:
- 项目实战
tags:
- go
- generate
- sqlboy
- AST

toc: true
url: "post/project-sqlboy-2.html"
---

在上一篇文章中，介绍了我对这个项目的想法，总体设计与思路，而在项目中AST是一个很重要的模块，他主要负责输入的解析，还负责部分代码生成工作。
接下来，我将为大家介绍go中的抽象语法树，也会跟大家分享我是如何利用AST去实现功能的。

<!--more-->

# AST
AST是go中的抽象语法树，许多代码生成工具，代码静态检测都离不开他。如果我们了解了AST，我们可以去实现一些好玩的东西。  
go对节点的定义
```go
// All node types implement the Node interface.
type Node interface {
	Pos() token.Pos // position of first character belonging to the node
	End() token.Pos // position of first character immediately after the node
}
```
主要有 3 类节点：Expr（表达式）, Stmt（语句）, Decl（声明）
```go
// All expression nodes implement the Expr interface.
type Expr interface {
	Node
	exprNode()
}

// All statement nodes implement the Stmt interface.
type Stmt interface {
	Node
	stmtNode()
}

// All declaration nodes implement the Decl interface.
type Decl interface {
	Node
	declNode()
}
```
其中，我们着重要了解下Decl（声明节点），因为会经常用到，有三种Decl
```go
// A declaration is represented by one of the following declaration nodes.
type (
	// A BadDecl node is a placeholder for a declaration containing
	// syntax errors for which a correct declaration node cannot be
	// created.
	//
	BadDecl struct {
		From, To token.Pos // position range of bad declaration
	}

	// A GenDecl node (generic declaration node) represents an import,
	// constant, type or variable declaration. A valid Lparen position
	// (Lparen.IsValid()) indicates a parenthesized declaration.
	//
	// Relationship between Tok value and Specs element type:
	//
	//	token.IMPORT  *ImportSpec
	//	token.CONST   *ValueSpec
	//	token.TYPE    *TypeSpec
	//	token.VAR     *ValueSpec
	//
	GenDecl struct {
		Doc    *CommentGroup // associated documentation; or nil
		TokPos token.Pos     // position of Tok
		Tok    token.Token   // IMPORT, CONST, TYPE, or VAR
		Lparen token.Pos     // position of '(', if any
		Specs  []Spec
		Rparen token.Pos // position of ')', if any
	}

	// A FuncDecl node represents a function declaration.
	FuncDecl struct {
		Doc  *CommentGroup // associated documentation; or nil
		Recv *FieldList    // receiver (methods); or nil (functions)
		Name *Ident        // function/method name
		Type *FuncType     // function signature: type and value parameters, results, and position of "func" keyword
		Body *BlockStmt    // function body; or nil for external (non-Go) function
	}
)
```
通过注释我们可以大致得知，GenDecl用于表示import，const，type或变量声明，FunDecl用于表示函数声明。  
那么，一个go文件会被抽象成什么样呢，下面是`ast.File`结构，后续也会经常用到
```go
type File struct {
	Doc        *CommentGroup   // associated documentation; or nil
	Package    token.Pos       // position of "package" keyword
	Name       *Ident          // package name
	Decls      []Decl          // top-level declarations; or nil
	Scope      *Scope          // package scope (this file only)
	Imports    []*ImportSpec   // imports in this file
	Unresolved []*Ident        // unresolved identifiers in this file
	Comments   []*CommentGroup // list of all comments in the source file
}
```
注释其实也解释的很清楚，有两个关键字段，一个是Name，用于我们提取包名，另外一个是Decls，const变量的声明。  
有了该结构，思路也就来了，只要能拿到改结构体，事情就好办了，不过在开始写代码前，我们还要了解一下这个函数
```go
func Inspect(node Node, f func(Node) bool) {
	Walk(inspector(f), node)
}
```
go官方怕我们对结构不熟悉，加上语法树层级复杂，嵌套的关系，这里贴心的帮我们实现了遍历的方法。
不过在这个项目我并没有用到，一个是我觉得遍历效率低，另一个是我的嵌套并不会很深，直接获取就行了。

# 处理输入
简单了解了AST后，我们就可以准备实现了。首先，我们定义我们的目标，一个是提取文件的包名，另一个是提取const变量以及对应的sql语句。
如何简单又快速的实现呢，这里推荐两种方法，一个是直接到[go AST viewer](https://yuroyoro.github.io/goast-viewer/)网站上去看解析的结果，另一个是自己debug，将需要解析的文件AST抽象后看里面的结构。  
假设我们有以下文件有解析
```go
package sqlboy

const (
	order = `
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
`
)
```
经过抽象后
```
     0  *ast.File {
     1  .  Doc: nil
     2  .  Package: foo:1:1
     3  .  Name: *ast.Ident {
     4  .  .  NamePos: foo:1:9
     5  .  .  Name: "sqlboy"
     6  .  .  Obj: nil
     7  .  }
     8  .  Decls: []ast.Decl (len = 1) {
     9  .  .  0: *ast.GenDecl {
    10  .  .  .  Doc: nil
    11  .  .  .  TokPos: foo:3:1
    12  .  .  .  Tok: const
    13  .  .  .  Lparen: foo:3:7
    14  .  .  .  Specs: []ast.Spec (len = 1) {
    15  .  .  .  .  0: *ast.ValueSpec {
    16  .  .  .  .  .  Doc: nil
    17  .  .  .  .  .  Names: []*ast.Ident (len = 1) {
    18  .  .  .  .  .  .  0: *ast.Ident {
    19  .  .  .  .  .  .  .  NamePos: foo:4:2
    20  .  .  .  .  .  .  .  Name: "order"
    21  .  .  .  .  .  .  .  Obj: *ast.Object {
    22  .  .  .  .  .  .  .  .  Kind: const
    23  .  .  .  .  .  .  .  .  Name: "order"
    24  .  .  .  .  .  .  .  .  Decl: *(obj @ 15)
    25  .  .  .  .  .  .  .  .  Data: 0
    26  .  .  .  .  .  .  .  .  Type: nil
    27  .  .  .  .  .  .  .  }
    28  .  .  .  .  .  .  }
    29  .  .  .  .  .  }
    30  .  .  .  .  .  Type: nil
    31  .  .  .  .  .  Values: []ast.Expr (len = 1) {
    32  .  .  .  .  .  .  0: *ast.BasicLit {
    33  .  .  .  .  .  .  .  ValuePos: foo:4:10
    34  .  .  .  .  .  .  .  Kind: STRING
    35  .  .  .  .  .  .  .  Value: "`\n-- order_info definition\n\nCREATE TABLE 'order_info' (\n  'id' int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT '自增ID',\n  'order_id' varchar(20) NOT NULL DEFAULT '' COMMENT '订单号',\n  'status' tinyint(3) NOT NULL DEFAULT '0' COMMENT '订单状态',\n  'created_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',\n  'updated_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',\n  PRIMARY KEY ('id'),\n  UNIQUE KEY 'uk_order' ('order_id')\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';\n`"
    36  .  .  .  .  .  .  }
    37  .  .  .  .  .  }
    38  .  .  .  .  .  Comment: nil
    39  .  .  .  .  }
    40  .  .  .  }
    41  .  .  .  Rparen: foo:17:1
    42  .  .  }
    43  .  }
    44  .  Scope: *ast.Scope {
    45  .  .  Outer: nil
    46  .  .  Objects: map[string]*ast.Object (len = 1) {
    47  .  .  .  "order": *(obj @ 21)
    48  .  .  }
    49  .  }
    50  .  Imports: nil
    51  .  Unresolved: nil
    52  .  Comments: nil
    53  }
```
因此，我们可以写出以下解析代码
```go
func parse(file *ast.File) (packageName string, ddl map[string]string) {
	if file == nil {
		return
	}
	if file.Name != nil {
		packageName = file.Name.Name
	}
	ddl = make(map[string]string)
	for _, decl := range file.Decls {
		genDecl, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		if genDecl.Tok != token.CONST {
			continue
		}
		for _, spec := range genDecl.Specs {
			valueSpec, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			for i := range valueSpec.Names {
				value, ok := valueSpec.Values[i].(*ast.BasicLit)
				if !ok {
					continue
				}
				if value.Kind != token.STRING {
					continue
				}
				ddl[valueSpec.Names[i].Name] = value.Value
			}
		}
	}
	return
}
```
这样一来，我们就实现了第一步对输入文件的解析，可能有的人会发现，上面的parse函数需要`*ast.File`结构，如何获得呢？  
go已经帮我们实现好了，在`$GOROOT/src/go/parser/interface.go`
```go
func ParseFile(fset *token.FileSet, filename string, src any, mode Mode) (f *ast.File, err error)
```
只需要提供文件路径，如果该文件没有语法错误的话，我们就能构建出`*ast.File`

# 编译时断言
在上一节说到，我们定义了输入的文件，建表的sql语句必须是const变量。这里我解释下，const主要是为了实现编译时断言。
什么是编译时断言呢，就是在编译时就能直接告诉你错误，无法编译通过。
许多自动化生成代码工具都会用到编译时断言，例如断言引用第三方库的版本，断言接口的实现，只要不符合，编译时就能及时发现，避免bug发生。  
这里分享几个编译断言的技巧
- 断言常量N不小于另一个常量M
```go
func _(x []int) {_ = x[N-M]}
func _(){_ = []int{N-M: 0}}
func _([N-M]int){}
var _ [N-M]int
const _ uint = N-M
type _ [N-M]int
```
- 断言两个整数常量相等
```go
var _ [N-M]int; var _ [M-N]int
type _ [N-M]int; type _ [M-N]int
const _, _ uint = N-M, M-N
func _([N-M]int, [M-N]int) {}
```
- 断言一个常量字符串是不是一个空串
```go
type _ [len(aStringConstant)-1]int
var _ = map[bool]int{false: 0, aStringConstant != "": 1}
var _ = aStringConstant[:1]
var _ = aStringConstant[0]
const _ = 1/len(aStringConstant)
```
- 断言字符串相等
```go
const (
    order = `order_info`
    product = `product_info`
)

func _() {
	_ = map[bool]struct {
	}{false: {}, order == `order_info`: {}}
	_ = map[bool]struct {
	}{false: {}, product == `product_info`: {}}
}
```
这个项目我用到了断言字符串相等，我保证了一旦建表语句sql被修改了，就必须重新生成断言文件，不然就无法编译通过。  
确定了断言的方式之后，我们可以先看下断言文件对应的抽象语法树，然后再去编写代码，这里结构会复杂点，我就不放上来，直接贴实现的代码
```go
func buildAssertAST(packageName string, paths, asserts map[string]string) *ast.File {
	importSpecs := make([]ast.Spec, 0)
	for name, path := range paths {
		importSpecs = append(importSpecs, &ast.ImportSpec{
			Name: ast.NewIdent(name),
			Path: &ast.BasicLit{Kind: token.STRING, Value: path},
		})
	}

	maps := make([]*ast.CompositeLit, 0)
	for k, v := range asserts {
		elts := make([]ast.Expr, 0)
		elts = append(elts, &ast.KeyValueExpr{
			Key:   ast.NewIdent("false"),
			Value: &ast.CompositeLit{},
		})
		elts = append(elts, &ast.KeyValueExpr{
			Key:   &ast.BinaryExpr{X: ast.NewIdent(k), Op: token.EQL, Y: &ast.BasicLit{Kind: token.STRING, Value: v}},
			Value: &ast.CompositeLit{},
		})
		maps = append(maps, &ast.CompositeLit{
			Type: &ast.MapType{Key: ast.NewIdent("bool"), Value: &ast.StructType{Fields: &ast.FieldList{}}},
			Elts: elts,
		})
	}

	assignList := make([]ast.Stmt, 0)
	for _, item := range maps {
		assignList = append(assignList, &ast.AssignStmt{
			Lhs: []ast.Expr{ast.NewIdent("_")},
			Tok: token.ASSIGN,
			Rhs: []ast.Expr{item},
		})
	}

	decls := make([]ast.Decl, 0)
	if len(paths) != 0 {
		decls = append(decls, &ast.GenDecl{Tok: token.IMPORT, Specs: importSpecs})
	}
	if len(asserts) != 0 {
		decls = append(decls, &ast.FuncDecl{
			Doc:  &ast.CommentGroup{List: []*ast.Comment{{Text: "//compile-time assertion"}}},
			Name: ast.NewIdent("_"),
			Type: &ast.FuncType{},
			Body: &ast.BlockStmt{List: assignList},
		})
	}

	return &ast.File{Name: ast.NewIdent(packageName), Decls: decls}
}
```
到这里，我们不仅能解析用户的输入，还能构建出断言文件的抽象语法树。不过还差一步，就是将`ast.File`输出成`.go`文件。
当然，go也已经帮我们实现好了，在`$GOROOT/src/go/format/format.go`
```go
func Node(dst io.Writer, fset *token.FileSet, node any) error 
```
这里的参数是`io.Writer`，也就是你想输出到哪里都行，只要是实现了`io.Writer`的接口就行。

# 小结
到这里我们迈出了第一步，定义了输入的文件，并且通过AST将文件解析，提取出我们需要的东西，再将其生成编译时断言的文件。
不过这才刚刚开始，我们仅仅是实现了最简单的一部分，后面还有更难的要解决。下一篇文章是如何去实现对sql的解析，是关于ANTLR的，有兴趣的可以看一下。  
项目源码：https://github.com/lemon-1997/sqlboy