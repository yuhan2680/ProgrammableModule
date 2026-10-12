class_name DataValidation
extends RefCounted
## JSON 数值可能是浮点数；所有类型转换都应先通过此处的显式检查。

const MAX_FILE_BYTES: int = 8 * 1024 * 1024
const MAX_TEXT_LENGTH: int = 65536
const MAX_CREATOR_LENGTH: int = 128
# 玩家新编辑的关卡名称与署名分别限长；读取旧地图仍保留上方格式兼容上限。
const MAX_PLAYER_NAME_LENGTH: int = 30
const MAX_EDITOR_CREATOR_LENGTH: int = 11
const MAX_LEVEL_SUBTITLE_LENGTH: int = 70
static var _subtitle_character_pattern: RegEx


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


## Unicode 私用区由平台或字体自行约定；普通 emoji、变体选择符和组合表情不属于此范围。
static func is_private_use_character(code: int) -> bool:
	return (code >= 0xE000 and code <= 0xF8FF) or (code >= 0xF0000 and code <= 0xFFFFD) or (code >= 0x100000 and code <= 0x10FFFD)


## 新编写的引导不能包含平台专用字形，其余正文仍沿用原有文本长度和格式约束。
static func is_portable_guide_text(value: Variant) -> bool:
	if not is_text(value):
		return false
	for index in range(value.length()):
		if is_private_use_character(value.unicode_at(index)):
			return false
	return true


## 只过滤私用字符及其紧邻的变体标记，保留普通 emoji、肤色、ZWJ、旗帜和 Markdown 原文。
static func filter_guide_text(value: String) -> String:
	var filtered := ""
	var index := 0
	while index < value.length():
		if is_private_use_character(value.unicode_at(index)):
			index += 1
			while index < value.length() and ((value.unicode_at(index) >= 0xFE00 and value.unicode_at(index) <= 0xFE0F) or (value.unicode_at(index) >= 0xE0100 and value.unicode_at(index) <= 0xE01EF)):
				index += 1
			continue
		filtered += value.substr(index, 1)
		index += 1
	return filtered


## 创作者署名保留中文、表情与标点原文，只限制单行长度和不可见控制字符。
static func is_creator(value: Variant) -> bool:
	if not value is String or value.length() > MAX_CREATOR_LENGTH:
		return false
	for index in range(value.length()):
		var code: int = value.unicode_at(index)
		if code < 32 or (code >= 127 and code <= 159) or code == 0x2028 or code == 0x2029:
			return false
	return true


## 副标题只接受单行普通文字、数字、空格与标点，不允许表情、控制码或不可见格式字符。
static func is_level_subtitle(value: Variant) -> bool:
	if not value is String or value.length() > MAX_LEVEL_SUBTITLE_LENGTH:
		return false
	for character: String in value:
		if not _is_subtitle_character(character):
			return false
	return true


## 输入过滤先移除非法字符再按 Unicode 字符限长，避免表情占用合法粘贴内容的额度。
static func filter_level_subtitle(value: String) -> String:
	var filtered := ""
	for character: String in value:
		if _is_subtitle_character(character):
			filtered += character
			if filtered.length() == MAX_LEVEL_SUBTITLE_LENGTH:
				break
	return filtered


## Unicode 分类保留各语言和常用标点，排除图形表情属性、变体选择符及键帽标记。
static func _is_subtitle_character(character: String) -> bool:
	var code := character.unicode_at(0)
	if code == 0x20E3 or (code >= 0xFE00 and code <= 0xFE0F) or (code >= 0xE0100 and code <= 0xE01EF):
		return false
	if code >= 32 and code <= 126:
		return true
	if _subtitle_character_pattern == null:
		_subtitle_character_pattern = RegEx.create_from_string("^(?!\\p{Extended_Pictographic})[\\p{L}\\p{M}\\p{N}\\p{P}\\p{Zs}\\p{Sm}\\p{Sc}]$")
	return _subtitle_character_pattern.search(character) != null


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
