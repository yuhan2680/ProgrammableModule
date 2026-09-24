class_name CommandCatalog
extends RefCounted
## 指令资料仅供界面阅读；JSON 不注册调用、不执行脚本，也不改变关卡或语言权限。

const DEFAULT_DIRECTORY := "res://data/commands"
const MAX_FILE_BYTES := 65536
const MAX_ENTRIES := 512
const FLAG_REQUIREMENTS := ["allow_tick", "allow_loops", "allow_named_calls", "allow_conditionals", "allow_simultaneous", "allow_distance", "allow_functions", "allow_variables", "allow_radar", "allow_random", "allow_for", "allow_radar_events"]
const FIELDS := ["format_version", "id", "order", "title", "description", "syntax", "category", "category_title", "requirements"]

var entries: Array[Dictionary] = []
var errors := PackedStringArray()


## 每次打开资料时重新扫描直接 JSON 文件；坏文件逐项报告，有效条目仍可供菜单显示。
func load_directory(path: String = DEFAULT_DIRECTORY) -> DataResult:
	entries.clear()
	errors.clear()
	if not DataValidation.is_resource_path(path):
		errors.append("指令资料目录必须是安全的 res:// 或 user:// 路径。")
		return _result()
	var folder := DirAccess.open(path)
	if folder == null:
		errors.append("无法打开指令资料目录：%s。" % path)
		return _result()
	var filenames := folder.get_files()
	filenames.sort()
	var used_ids: Dictionary = {}
	for filename in filenames:
		if filename.get_extension().to_lower() != "json":
			continue
		if entries.size() >= MAX_ENTRIES:
			errors.append("指令资料最多显示 %d 项，其余文件尚未载入。" % MAX_ENTRIES)
			break
		var source_path := path.path_join(filename)
		var loaded := _read_entry(source_path)
		if not loaded.is_ok():
			for message in loaded.errors:
				errors.append("%s：%s" % [source_path, message])
			continue
		var entry: Dictionary = loaded.value
		if used_ids.has(entry.id):
			errors.append("%s：指令资料 ID 重复，已保留先读取的 '%s'。" % [source_path, entry.id])
			continue
		used_ids[entry.id] = true
		entry["source_path"] = source_path
		entries.append(entry)
	entries.sort_custom(_before)
	return _result()


## 按已加载的模块行为组织资料；语言结构始终放在基础目录，未匹配的资料也不隐藏。
func sections(registry: ContentRegistry, locale: String = "zh_CN") -> Array[Dictionary]:
	var general_entries: Array[Dictionary] = []
	var result: Array[Dictionary] = [{
		"id": "general", "kind": "general", "title": localized({
			"title": {"zh_CN": "编程基础", "zh_HK": "編程基礎", "en": "Programming Basics"},
		}, "title", locale), "texture": "", "entries": general_entries,
	}]
	if registry != null:
		var module_ids: Array = registry.modules.keys()
		module_ids.sort()
		for module_id: String in module_ids:
			var definition := registry.get_module(module_id)
			if definition == null:
				continue
			var module_entries: Array[Dictionary] = []
			result.append({
				"id": module_id, "kind": "module", "title": _module_title(definition, locale),
				"texture": definition.texture, "entries": module_entries,
			})
	for entry in entries:
		var assigned := false
		var behavior := str(entry.get("requirements", {}).get("module_behavior", ""))
		# if / else 依赖射击查询，但属于程序结构；分组不能删掉它真实的执行权限要求。
		if entry.category != "structure" and not behavior.is_empty():
			for index in range(1, result.size()):
				var definition := registry.get_module(result[index].id)
				if definition.behavior == behavior:
					result[index].entries.append(entry.duplicate(true))
					assigned = true
		if not assigned:
			general_entries.append(entry.duplicate(true))
	return result


## 全局搜索本土化标题、说明、语法及模块名；结果附归属快照，不写入原始条目。
func search(query: String, registry: ContentRegistry, locale: String = "zh_CN") -> Array[Dictionary]:
	var needle := query.strip_edges().to_lower()
	var result: Array[Dictionary] = []
	for section in sections(registry, locale):
		for entry: Dictionary in section.entries:
			var fields := [localized(entry, "title", locale), localized(entry, "description", locale), str(entry.syntax), str(section.title)]
			var matched := needle.is_empty()
			for field: String in fields:
				if field.to_lower().contains(needle):
					matched = true
					break
			if matched:
				var found := entry.duplicate(true)
				found["section_id"] = section.id
				found["section_kind"] = section.kind
				found["section_title"] = section.title
				found["section_texture"] = section.texture
				result.append(found)
	return result


## 模块沿用已安装翻译资源；读取指定语言不会切换全局语言或改写自定义名称。
static func _module_title(definition: ModuleDefinition, locale: String) -> String:
	var source := definition.display_name if not definition.display_name.is_empty() else definition.id
	# 香港带脚本标记的别名统一请求已注册的香港翻译，模块目录与资料正文保持同语种。
	var requested_locale := "zh_HK" if locale.replace("-", "_").to_lower() in ["zh_hk", "zh_hant_hk"] else locale
	var translation := TranslationServer.get_translation_object(TranslationServer.standardize_locale(requested_locale))
	if translation != null:
		var translated := str(translation.get_message(source))
		if not translated.is_empty():
			return translated
	return source


## 返回当前有效条目快照及完整错误列表，不让调用方改写返回值时污染目录本身。
func _result() -> DataResult:
	var result := DataResult.success(entries.duplicate(true))
	result.errors = errors.duplicate()
	return result


## 限制单文件大小并先校验纯 JSON 结构；不把文档路径或示例交给任何脚本加载器。
func _read_entry(path: String) -> DataResult:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DataResult.failure("文件无法读取：%s。" % error_string(FileAccess.get_open_error()))
	if file.get_length() > MAX_FILE_BYTES:
		file.close()
		return DataResult.failure("指令资料文件不能超过 64 KiB。")
	file.close()
	var parsed := DataValidation.read_json_object(path)
	if not parsed.is_ok():
		return parsed
	var entry: Dictionary = parsed.value
	for field in entry:
		if not field in FIELDS:
			return DataResult.failure("未知的指令资料字段：%s。" % field)
	if not DataValidation.is_integer(entry.get("format_version"), 1, 1):
		return DataResult.failure("指令资料仅支持 format_version: 1。")
	if not DataValidation.is_id(entry.get("id")) or not DataValidation.is_id(entry.get("category")):
		return DataResult.failure("指令资料 id 和 category 必须是有效的稳定 ID。")
	if not DataValidation.is_integer(entry.get("order"), -1000000, 1000000):
		return DataResult.failure("指令资料 order 必须为 -1000000..1000000 的整数。")
	for field in ["title", "description", "category_title"]:
		var limit := 4096 if field == "description" else 256
		if not _valid_localized_text(entry.get(field), limit):
			return DataResult.failure("%s 必须包含 1..16 个语言键及非空文案，每项最多 %d 字符。" % [field, limit])
	if not _bounded_text(entry.get("syntax"), 2048):
		return DataResult.failure("syntax 必须是非空的纯文本，最多 2048 字符。")
	if not _valid_requirements(entry.get("requirements", {})):
		return DataResult.failure("requirements 只支持关卡权限布尔值和 module_behavior 行为名称。")
	var normalized := entry.duplicate(true)
	normalized["requirements"] = entry.get("requirements", {}).duplicate(true)
	return DataResult.success(normalized)


## 中英文及扩展语言均放在资料本身；语种缺失时依次尝试同语种、中文、英文和稳定首项。
static func localized(entry: Dictionary, field: String, locale: String = "zh_CN") -> String:
	var translations: Variant = entry.get(field)
	if not translations is Dictionary:
		return ""
	var locale_key := locale.replace("-", "_").to_lower()
	var exact := _translated_value(translations, locale_key)
	if not exact.is_empty():
		return exact
	# 香港语言写法先互相匹配，避免 zh_Hant_HK 在同语种排序时误选简体文案。
	if locale_key in ["zh_hk", "zh_hant_hk"]:
		for hong_kong_locale in ["zh_hk", "zh_hant_hk"]:
			var hong_kong_text := _translated_value(translations, hong_kong_locale)
			if not hong_kong_text.is_empty():
				return hong_kong_text
	var language := locale_key.get_slice("_", 0)
	var generic := _translated_value(translations, language)
	if not generic.is_empty():
		return generic
	var keys: Array = translations.keys()
	keys.sort()
	for key in keys:
		if key is String and key.replace("-", "_").to_lower().get_slice("_", 0) == language and _bounded_text(translations[key], 4096):
			return translations[key]
	for fallback in ["zh_cn", "en"]:
		var value := _translated_value(translations, fallback)
		if not value.is_empty():
			return value
	for key in keys:
		if _bounded_text(translations[key], 4096):
			return translations[key]
	return ""


## 可用性只表示本关已开放的语法和模块能力；不检查是否已经装配，也不修改真实解析权限。
static func is_available(entry: Dictionary, level: LevelDefinition, registry: ContentRegistry) -> bool:
	if level == null:
		return false
	var requirements: Variant = entry.get("requirements", {})
	if not _valid_requirements(requirements):
		return false
	for flag in FLAG_REQUIREMENTS:
		if requirements.get(flag, false) and not level.get(flag):
			return false
	if requirements.has("module_behavior"):
		if registry == null:
			return false
		for module_id in level.allowed_modules:
			var definition := registry.get_module(module_id)
			if definition != null and definition.behavior == requirements.module_behavior:
				return true
		return false
	return true


## 权限键必须显式识别，拼写错误不能让菜单误标为已解锁。
static func _valid_requirements(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for key in value:
		if key in FLAG_REQUIREMENTS:
			if not value[key] is bool:
				return false
		elif key == "module_behavior":
			if not DataValidation.is_id(value[key]):
				return false
		else:
			return false
	return true


## 限制本土化字段数量、键名和文本长度，避免单条资料把菜单撑成无界内容。
static func _valid_localized_text(value: Variant, limit: int) -> bool:
	if not value is Dictionary or value.is_empty() or value.size() > 16:
		return false
	for key in value:
		if not key is String or key.length() < 2 or key.length() > 32 or not _bounded_text(value[key], limit):
			return false
		for character in key:
			if not character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":
				return false
	return true


## 文案必须是有实际可见内容的短字符串，不隐式接受数字或其它 JSON 类型。
static func _bounded_text(value: Variant, limit: int) -> bool:
	return value is String and not value.strip_edges().is_empty() and value.length() <= limit


## 语言键大小写及连字符写法统一比较，但保留作者的原始文案和键名。
static func _translated_value(translations: Dictionary, locale_key: String) -> String:
	for key in translations:
		if key is String and key.replace("-", "_").to_lower() == locale_key and _bounded_text(translations[key], 4096):
			return translations[key]
	return ""


## 资料先按显式 order，再按稳定 ID 排列，不依赖文件系统的枚举顺序。
static func _before(left: Dictionary, right: Dictionary) -> bool:
	return left.order < right.order or (left.order == right.order and left.id < right.id)
