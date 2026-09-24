class_name DataValidation
extends RefCounted
## JSON 数值可能是浮点数；所有类型转换都应先通过此处的显式检查。

const MAX_FILE_BYTES: int = 8 * 1024 * 1024
const MAX_TEXT_LENGTH: int = 65536


## 判断值是否为有限实数；布尔值和字符串均不作为数字接受。
static func is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## 检查整数范围，同时接受 JSON 解析得到的整数值浮点数。
static func is_integer(value: Variant, minimum: int, maximum: int) -> bool:
	if not is_number(value):
		return false
	var number := float(value)
	return number >= minimum and number <= maximum and number == floor(number)


## 内容 ID 使用稳定 ASCII 字符，保留 void 作为无地块的语义。
static func is_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 128:
		return false
	if value == "void":
		return false
	for character in value:
		if not character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.":
			return false
	return true


## 检查带长度上限的字符串字段。
static func is_text(value: Variant, allow_empty: bool = true) -> bool:
	return value is String and value.length() <= MAX_TEXT_LENGTH and (allow_empty or not value.is_empty())


## 校验二维坐标对象，未知字段保留给未来版本使用。
static func is_position(value: Variant) -> bool:
	return value is Dictionary and is_number(value.get("x")) and is_number(value.get("y"))


## 只允许资源目录和用户目录中的直接资源路径，禁止上级目录跳转。
static func is_resource_path(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.contains("\\"):
		return false
	if not (value.begins_with("res://") or value.begins_with("user://")):
		return false
	var relative: String = value.substr(value.find("://") + 3)
	if relative.is_empty() or relative.begins_with("/") or relative.contains(":"):
		return false
	for segment in relative.split("/"):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


## 读取有大小限制的 JSON 对象，返回带路径的明确错误。
static func read_json_object(path: String) -> DataResult:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取 %s：%s" % [path, error_string(FileAccess.get_open_error())])
	if file.get_length() > MAX_FILE_BYTES:
		file.close()
		return DataResult.failure("文件超过 8 MiB 上限：%s" % path)
	var source := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(source) != OK:
		return DataResult.failure("%s 第 %d 行 JSON 错误：%s" % [path, parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary:
		return DataResult.failure("JSON 根节点必须为对象：%s" % path)
	if not is_json_value(parser.data):
		return DataResult.failure("JSON 含有非有限数字或超过大小、嵌套上限：%s" % path)
	return DataResult.success(parser.data)


## 拒绝不可序列化对象并限制嵌套，保证扩展属性仍能安全往返。
static func is_json_value(value: Variant, depth: int = 0) -> bool:
	if depth > 32:
		return false
	if value == null or value is bool or value is String or value is StringName:
		return true
	if value is int or value is float:
		return is_number(value)
	if value is Array:
		if value.size() > 65536:
			return false
		for entry in value:
			if not is_json_value(entry, depth + 1):
				return false
		return true
	if value is Dictionary:
		if value.size() > 65536:
			return false
		for key in value:
			if not (key is String or key is StringName) or not is_json_value(value[key], depth + 1):
				return false
		return true
	return false
