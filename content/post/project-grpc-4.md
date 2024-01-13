---
title: "动态gRPC-HTTP代理（四）：编解码"
description: "http与gRPC请求和响应的转换"
keywords: "grpc,http,codec"

date: 2024-01-13T13:15:19+08:00
lastmod: 2024-01-13T13:15:19+08:00

categories:
  - 项目实战
tags:
  - go
  - grpc

toc: true
url: "post/project-grpc-4.html"
---

在构建将HTTP请求代理并转换为gRPC调用后端服务的系统中，编解码模块起到了至关重要的作用。它承担着将HTTP请求和响应与gRPC消息格式之间进行转换的任务，确保了请求能够顺利地传递到目标服务并返回结果。本文将详细介绍编解码模块的设计与实现，以及如何处理转换过程中的各种细节和挑战。

<!--more-->

# HTTP gRPC差异
为了更好地进行转换，我们需要深入理解HTTP和gRPC的消息结构及其差异。

## HTTP
`HTTP`我们都很熟悉，先说下请求参数，HTTP就支持多种方式，多种形式，甚至可以是自己定义格式的body。
当然这种我们不考虑，我们只处理常见的，比如放在url里的path和query，放在body里的`json`，`urlencoded`等等格式。
因为有这么多格式，而且行为也不同，但是功能是相同的，需要把他们都转换成gRPC需要的格式，那么我们可以抽象一个`Unmarshal`函数。

这是请求部分，响应呢，这里我们直接简单做，只返回json格式给客户端，这也是目前普遍采用的方式。

## gRPC
`gRPC`不论是请求还是返回，都采用了proto编码，官方其实是提供了jsonPb支持json和proto的转换，但是我们不仅仅有json格式，
所以我们还需要了解proto所支持的类型，并对不同类型做不同的转换，这部分我们自己实现。

# 实现
了解了两者后，我们可以开始设计并实现，第一步是先抽象出interface。
## interface

```go
type Codec interface {
	Marshal(v *dynamic.Message) ([]byte, error)
	Unmarshal(data []byte, params map[string]string, v *dynamic.Message) error
	Subtype() string
}
```

`Marshal`是响应部分的转化，`Unmarshal`是请求部分，所以多了`params`字段，表示url参数，而`Subtype`则是HTTP header`Content-type`的子类型。

由于HTTP格式比较多，我们这次只实现json和form格式。
```go
type jsonCodec struct {
    log          *slog.Logger
    marshalOpt   *jsonpb.Marshaler
    unmarshalOpt *jsonpb.Unmarshaler
}

type formCodec struct {
    log          *slog.Logger
    marshalOpt   *jsonpb.Marshaler
    unmarshalOpt *jsonpb.Unmarshaler
}
```

## Marshal
这一部分比较简单，之前说过我们只需要实现json的响应就行了，而官方有jsonPb包。
```go
func (jsonCodec) Marshal(msg *dynamic.Message) ([]byte, error) {
	return msg.MarshalJSONPB(&jsonpb.Marshaler{OrigName: true, EmitDefaults: true})
}
```

## Unmarshal
这是请求的转换，我们这里要先实现`decodeFields`函数，作用是将string类型转化为proto对应的类型
```go
func decodeFields(fd *desc.FieldDescriptor, val []string) interface{} {
	switch fd.GetType() {
	case descriptorpb.FieldDescriptorProto_TYPE_ENUM:
		vd := fd.GetEnumType().FindValueByName(val[0])
		if vd != nil {
			return vd.GetNumber()
		}
		return nil
	case descriptorpb.FieldDescriptorProto_TYPE_BOOL:
		if val[0] == "true" {
			return true
		} else if val[0] == "false" {
			return false
		}
		return nil
	case descriptorpb.FieldDescriptorProto_TYPE_BYTES:
		return []byte(val[0])
	case descriptorpb.FieldDescriptorProto_TYPE_STRING:
		return val[0]
	case descriptorpb.FieldDescriptorProto_TYPE_FLOAT:
		if f, err := strconv.ParseFloat(val[0], 32); err == nil {
			return float32(f)
		} else {
			return float32(0)
		}
	case descriptorpb.FieldDescriptorProto_TYPE_DOUBLE:
		if f, err := strconv.ParseFloat(val[0], 64); err == nil {
			return f
		} else {
			return float64(0)
		}
	case descriptorpb.FieldDescriptorProto_TYPE_INT32,
		descriptorpb.FieldDescriptorProto_TYPE_SINT32,
		descriptorpb.FieldDescriptorProto_TYPE_SFIXED32:
		if i, err := strconv.ParseInt(val[0], 10, 32); err == nil {
			return int32(i)
		} else {
			return int32(0)
		}
	case descriptorpb.FieldDescriptorProto_TYPE_UINT32,
		descriptorpb.FieldDescriptorProto_TYPE_FIXED32:
		if i, err := strconv.ParseUint(val[0], 10, 32); err == nil {
			return uint32(i)
		} else {
			return uint32(0)
		}
	case descriptorpb.FieldDescriptorProto_TYPE_INT64,
		descriptorpb.FieldDescriptorProto_TYPE_SINT64,
		descriptorpb.FieldDescriptorProto_TYPE_SFIXED64:
		if i, err := strconv.ParseInt(val[0], 10, 64); err == nil {
			return i
		} else {
			return int64(0)
		}
	case descriptorpb.FieldDescriptorProto_TYPE_UINT64,
		descriptorpb.FieldDescriptorProto_TYPE_FIXED64:
		if i, err := strconv.ParseUint(val[0], 10, 64); err == nil {
			return i
		} else {
			return uint64(0)
		}
	default:
		return nil
	}
}
```
接下来是json和form的实现
```go
func (c jsonCodec) Unmarshal(data []byte, pathParams map[string]string, msg *dynamic.Message) error {
	for k, v := range pathParams {
		fd := msg.GetMessageDescriptor().FindFieldByName(k)
		if fd == nil {
			continue
		}
		val := decodeFields(fd, []string{v})
		if val == nil {
			continue
		}
		if err := msg.TrySetFieldByName(k, val); err != nil {
			c.log.Warn("unmarshal set field fail", "field", k, "err", err)
		}
	}
	return msg.UnmarshalJSONPB(&jsonpb.Unmarshaler{AllowUnknownFields: true}, data)
}
```

```go
func (c formCodec) Unmarshal(data []byte, pathParams map[string]string, msg *dynamic.Message) error {
	vs, err := url.ParseQuery(string(data))
	if err != nil {
		return err
	}
	for k, v := range pathParams {
		vs.Set(k, v)
	}
	for k, v := range vs {
		if len(v) == 0 {
			continue
		}
		fd := msg.GetMessageDescriptor().FindFieldByName(k)
		if fd == nil {
			if c.unmarshalOpt.AllowUnknownFields {
				continue
			}
			return fmt.Errorf("message type %s has no known field named %s", msg.GetMessageDescriptor().GetFullyQualifiedName(), k)
		}
		val := decodeFields(fd, v)
		if val == nil {
			continue
		}
		if err = msg.TrySetFieldByName(k, val); err != nil {
			c.log.Warn("unmarshal set field fail", "field", k, "err", err)
		}
	}
	return nil
}
```
代码也不难，主要是proto类型要和传入的参数类型保持一致。

# 总结

通过本文的介绍，您将深入了解编解码模块在代理服务中的关键作用，以及如何设计和实现一个高效、可靠的编解码模块来处理HTTP与gRPC之间的转换。无论您是正在构建自己的代理服务还是对gRPC和HTTP之间的转换感兴趣，本文都将为您提供有价值的见解和实用建议。
下一篇博客我们将完成最后模块，是最上层的代理模块，它将暴露HTTP服务，代理所有指向gRPC服务的HTTP请求。

项目源码 https://github.com/lemon-1997/dynamic-grpc