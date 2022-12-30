---
title: "go自动化生成数据库curd代码（五）：面向接口编程"
description: "面向接口编程思想解耦代码"
keywords: "go,design pattern"

publishDate: 2022-12-30T19:27:00+08:00
lastmod: 2022-12-30T19:27:00+08:00

categories:
- 项目实战
tags:
- go
- generate
- sqlboy
- 设计模式

toc: true
url: "post/project-sqlboy-5.html"
---

上一节过后，我们已经完成了所有代码的生成工作，最后的任务就是将解析，生成的模块全部集成在一起，并对外提供命令行调用（cmd）。

<!--more-->

# 抽象接口
在编写代码之前，我的第一个工作，就是针对解析以及生成模块，抽象出两大类接口，解析的以及生成的接口。
这是因为，我的主逻辑不能够依赖底层的模块，而是依赖定义的接口，这样能更好维护项目，且达到解耦的目的，而我的底层模块只需要关注自己的职责，不关注上层的调用。
```go
type Parser interface {
    Name() string
    Parse(interface{}) (interface{}, error)
}

type Generator interface {
    Name() string
    Generate(interface{}) (*bytes.Buffer, error)
}
```
由于`AST`和`ANTRL`的输入和输出不确定，所以对`Parser`的抽象的入参和出参都是`interface{}`，`ANTRL`的实现如下，我们需要定义输入输出方便外部调用
```go
type AntlrParseIn struct {
	Stmt string
}

type AntlrParseOut struct {
	antlrParser.TableAttr
}

type AntlrParser struct{}

func (*AntlrParser) Name() string {
	return "AntlrParser"
}

func (*AntlrParser) Parse(in interface{}) (interface{}, error) {
	parseIn, ok := in.(AntlrParseIn)
	if !ok {
		return nil, errors.New("parse in type error")
	}
	attr, errs := parseStmt(parseIn.Stmt)
	if len(errs) != 0 {
		return nil, errs[0]
	}
	return AntlrParseOut{TableAttr: attr}, nil
}
```
`Generator`只有输入定义为`interface{}`，输出可以都定义为`*bytes.Buffer`，因为最后都是需要生成文件。
这里实现的代码就不贴了，和上面的类似。

# 事件总线
有了第一步的抽象，我发现解析以及生成模块数量比较多，如果要将他们集成在一起，主逻辑会变得复杂臃肿，模块调用之间相互依赖，后期新增删减模块将会异常恶心。
于是这里使用了事件总线（看到ANTLR runtime包受到的启发），事件总线是发布订阅的一种实现，允许不同的组件之间进行彼此通信而又不需要相互依赖，达到一种解耦的目的。
我参考了网上的go事件总线代码，利用反射去实现，而且是异步，性能高
```go
type Topic string

type Bus interface {
	Subscribe(topic Topic, handler interface{}) error
	Publish(topic Topic, args ...interface{})
}

type AsyncEventBus struct {
	handlers map[Topic][]reflect.Value
	lock     sync.Mutex
}

func NewAsyncEventBus() *AsyncEventBus {
	return &AsyncEventBus{
		handlers: map[Topic][]reflect.Value{},
		lock:     sync.Mutex{},
	}
}

func (bus *AsyncEventBus) Subscribe(topic Topic, f interface{}) error {
	bus.lock.Lock()
	defer bus.lock.Unlock()

	v := reflect.ValueOf(f)
	if v.Type().Kind() != reflect.Func {
		return errors.New("handler is not a function")
	}

	handler, ok := bus.handlers[topic]
	if !ok {
		handler = []reflect.Value{}
	}
	handler = append(handler, v)
	bus.handlers[topic] = handler

	return nil
}

func (bus *AsyncEventBus) Publish(topic Topic, args ...interface{}) {
	handlers, ok := bus.handlers[topic]
	if !ok {
		fmt.Println("not found handlers in topic:", topic)
		return
	}

	params := make([]reflect.Value, len(args))
	for i, arg := range args {
		params[i] = reflect.ValueOf(arg)
	}

	for i := range handlers {
		go handlers[i].Call(params)
	}
}
```
有了对解析，生成的抽象以及事件总线后，我们就可以开始编写主逻辑了。

# 主逻辑
先定义我们的结构
```go
type Boy struct {
    file       string        // sql定义文件路径
    mode       GenMode       // 生成代码模式 gorm/sqlx
    genPackage string        // 生成包名
    
    bus  *bus.AsyncEventBus  // 事件总线
    err  chan error          // 错误信号
    done chan struct{}       // 完成信号
    data chan interface{}    // 数据信号
}
```
在`New`结构体时使用了optional设计模式，方便后续新增参数
```go
type Option func(*Boy)

func Mode(mode GenMode) Option {
    return func(boy *Boy) {
        boy.mode = mode
    }
}

func NewBoy(filePath string, opts ...Option) *Boy {
    boy := &Boy{
        file: filePath,
        mode: ModeGorm,

        err:  make(chan error),
        done: make(chan struct{}),
        data: make(chan interface{}, 10),
    }
    for _, opt := range opts {
        opt(boy)
    }
    boy.register()
    return boy
}
```
事件总线初始化
```go
func (b *Boy) register() {
    eventBus := bus.NewAsyncEventBus()
    _ = eventBus.Subscribe(TopicAstParse, b.eventAstParse)
    _ = eventBus.Subscribe(TopicAntlrParse, b.eventAntlrParse)
    _ = eventBus.Subscribe(TopicAssertGenerate, b.eventAssertGenerate)
    _ = eventBus.Subscribe(TopicModelGenerate, b.eventModelGenerate)
    _ = eventBus.Subscribe(TopicDaoGenerate, b.eventDaoGenerate)
    _ = eventBus.Subscribe(TopicTxGenerate, b.eventTxGenerate)
    _ = eventBus.Subscribe(TopicQueryGenerate, b.eventQueryGenerate)
    b.bus = eventBus
}
```
相对应的解析和生成函数，`parse`如果解析成功则会发数据，失败则会发错误的信号，`generate`如果生成成功则会生成文件，生成后发送完成的信号，反之则发错误的信号。
```go
func (b *Boy) parse(parser inter.Parser, in interface{}) {
	res, err := parser.Parse(in)
	if err != nil {
		b.err <- fmt.Errorf("%s:%w", parser.Name(), err)
		return
	}
	b.data <- res
}

func (b *Boy) generate(gen inter.Generator, in interface{}, file string) {
	buf, err := gen.Generate(in)
	if err != nil {
		b.err <- fmt.Errorf("%s:%w", gen.Name(), err)
		return
	}
	source, err := format.Source(buf.Bytes())
	if err != nil {
		b.err <- fmt.Errorf("%s:%w", gen.Name(), err)
		return
	}
	if err = os.WriteFile(b.genPath(file), source, 0664); err != nil {
		b.err <- fmt.Errorf("%s:%w", gen.Name(), err)
		return
	}
	b.done <- struct{}{}
}
```
然后是主逻辑，主要处理数据信号，错误信号以及完成信号，可以看到有了事件总线后代码更加清晰，而且异步效率更高。
```go
func (b *Boy) Do() error {
	b.bus.Publish(TopicAstParse)
	var genTables, genCount int
	tables := make(map[string][]parserAntlr.ColumnDecl)
	for {
		select {
		case data := <-b.data:
			switch data.(type) {
			case parser.AstParseOut:
				res := data.(parser.AstParseOut)
				genTables = len(res.Stmt)
				b.genPackage = res.PackageName
				b.bus.Publish(TopicDaoGenerate)
				b.bus.Publish(TopicTxGenerate)
				b.bus.Publish(TopicAssertGenerate, res.Stmt)
				for _, stmt := range res.Stmt {
					s, err := strconv.Unquote(stmt)
					if err != nil {
						return err
					}
					b.bus.Publish(TopicAntlrParse, s)
				}
			case parser.AntlrParseOut:
				res := data.(parser.AntlrParseOut)
				tables[res.TableName] = res.Columns
				b.bus.Publish(TopicQueryGenerate, b.transRenderData(res))
				if len(tables) == genTables {
					b.bus.Publish(TopicModelGenerate, tables)
				}
			}
		case <-b.done:
			genCount++
			// assert,model,dao,tx is 4 file
			if genCount >= genTables+4 {
				return nil
			}
		case err := <-b.err:
			return err
		default:
			continue
		}
	}
}
```

# cmd
完成主逻辑后，就到我们的命令了，我们规定至少要有一个参数，就是SQL的文件路径，然后只有`mode`一个选项，默认是生成`gorm`代码。
```go
const (
	usage = `sqlboy [packages]
    sqlboy $path -mode gorm
    Find more information at: https://github.com/lemon-1997/sqlboy
`
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("sqlboy:")

	if len(os.Args) < 2 {
		log.Fatal("no specify file")
	}

	flag.Usage = func() {
		fmt.Print(usage)
		flag.PrintDefaults()
	}
	flag.Parse()

	var mode string
	fs := flag.NewFlagSet("sqlboy", flag.ExitOnError)
	fs.StringVar(&mode, "mode", "", "gorm or sqlx")
	_ = fs.Parse(os.Args[2:])

	var opts []sqlboy.Option
	if mode != "" {
		genMode := sqlboy.GenMode(mode)
		if genMode != sqlboy.ModeGorm && genMode != sqlboy.ModeSqlx {
			log.Fatalf("mode %s is not gorm or sqlx", mode)
		}
		opts = append(opts, sqlboy.Mode(genMode))
	}
	boy := sqlboy.NewBoy(os.Args[1], opts...)
	err := boy.Do()
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("generate success")
	os.Exit(0)
}
```

# 测试
先安装命令
```shell
go install github.com/lemon-1997/sqlboy/cmd/sqlboy@latest
```
创建我们的文件，stmt.go，文件内容如下
```go
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
	product = `
-- product_info definition

CREATE TABLE 'product_info' (
  'id' int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT '自增ID',
  'product_id' varchar(20) NOT NULL DEFAULT '' COMMENT '商品编号',
  'sku_id' varchar(20) NOT NULL DEFAULT '' COMMENT 'sku',
  'status' tinyint(3) NOT NULL DEFAULT '0' COMMENT '商品状态',
  'created_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  'updated_at' timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '修改时间',
  PRIMARY KEY ('id'),
  UNIQUE KEY 'uk_product' ('product_id', 'sku_id')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表';
`
)
```
生成gorm代码
```shell
sqlboy ./stmt.go -mode gorm
```
生成sqlx代码
```shell
sqlboy ./stmt.go -mode sqlx
```

# 小结
终于完成了项目和blog的更新，很开心，不过这个系列五篇blog更新的比较仓促，写的匆忙，有许多地方没有写好，因为接下来我有其他事，所以不得不连续五天更新把这个系列完结。
如果对sqlboy感兴趣的话，也欢迎大家使用，有问题可以在github提issue，感谢观看。  
项目源码：https://github.com/lemon-1997/sqlboy