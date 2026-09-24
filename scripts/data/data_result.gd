class_name DataResult
extends RefCounted
## 数据边界统一使用显式结果，避免把无效内容当成可用内容。

var value: Variant = null
var errors: PackedStringArray = PackedStringArray()


## 创建一个成功结果；调用方通过 value 获取载入的数据。
static func success(result_value: Variant = null) -> DataResult:
	var result := DataResult.new()
	result.value = result_value
	return result


## 创建一个失败结果；错误文本面向编辑器和日志展示。
static func failure(message: String) -> DataResult:
	var result := DataResult.new()
	result.errors.append(message)
	return result


## 判断本次操作是否成功，不依赖 value 是否为空。
func is_ok() -> bool:
	return errors.is_empty()
