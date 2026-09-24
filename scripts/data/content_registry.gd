class_name ContentRegistry
extends RefCounted
## 内容注册表按稳定顺序载入；任一文件失败时保留上一次完整注册表。

var modules: Dictionary = {}
var tiles: Dictionary = {}


## 扫描指定目录的 JSON 文件；缺失的可选 user:// 目录按空目录处理。
func load_directories(
	module_dirs: PackedStringArray = PackedStringArray(["res://data/modules"]),
	tile_dirs: PackedStringArray = PackedStringArray(["res://data/tiles"])
) -> DataResult:
	var new_modules: Dictionary = {}
	var new_tiles: Dictionary = {}
	var result := DataResult.success()
	_load_kind(module_dirs, true, new_modules, result.errors)
	_load_kind(tile_dirs, false, new_tiles, result.errors)
	if result.is_ok():
		modules = new_modules
		tiles = new_tiles
		result.value = self
	return result


## 按稳定 ID 查询模块；不存在时返回空值。
func get_module(module_id: String) -> ModuleDefinition:
	return modules.get(module_id)


## 按稳定 ID 查询地块；void 不存在于注册表中。
func get_tile(tile_id: String) -> TileDefinition:
	return tiles.get(tile_id)


## 分别载入一种内容并收集所有文件错误，避免只报告首个文件。
func _load_kind(directories: PackedStringArray, is_module: bool, target: Dictionary, errors: PackedStringArray) -> void:
	var paths: PackedStringArray = PackedStringArray()
	for directory in directories:
		if not DataValidation.is_resource_path(directory):
			errors.append("内容目录路径无效：%s" % directory)
			continue
		if not DirAccess.dir_exists_absolute(directory):
			if not directory.begins_with("user://"):
				errors.append("内容目录不存在：%s" % directory)
			continue
		var folder := DirAccess.open(directory)
		if folder == null:
			errors.append("无法打开内容目录：%s" % directory)
			continue
		for file_name in folder.get_files():
			if file_name.get_extension().to_lower() == "json":
				paths.append(directory.path_join(file_name))
	paths.sort()
	for path in paths:
		var parsed := DataValidation.read_json_object(path)
		if not parsed.is_ok():
			errors.append_array(parsed.errors)
			continue
		var definition := _parse_module(parsed.value) if is_module else _parse_tile(parsed.value)
		if not definition.is_ok():
			for error in definition.errors:
				errors.append("%s：%s" % [path, error])
			continue
		var content_id: String = definition.value.id
		if target.has(content_id):
			errors.append("重复的内容 ID '%s'：%s" % [content_id, path])
		else:
			target[content_id] = definition.value


## 校验模块公共字段及移动模块的速度，行为名称仍交给运行时解析。
static func _parse_module(data: Dictionary) -> DataResult:
	var common := _validate_common(data)
	if not common.is_ok():
		return common
	if not DataValidation.is_text(data.get("description", "")):
		return DataResult.failure("description 必须是字符串")
	if not DataValidation.is_id(data.get("script_type")):
		return DataResult.failure("script_type 必须是有效的行为名称")
	var dimensions: Variant = data.get("size")
	if not dimensions is Dictionary:
		return DataResult.failure("size 必须是包含 width、height 的对象")
	for axis in ["width", "height"]:
		var extent: Variant = dimensions.get(axis)
		if not DataValidation.is_number(extent) or float(extent) < 0.001 or float(extent) > 256.0:
			return DataResult.failure("size.%s 必须为 0.001..256 的有限数字" % axis)
	var properties: Dictionary = data.get("properties", {})
	if data.script_type == "MovementModule":
		var speed: Variant = properties.get("move_speed")
		if not DataValidation.is_number(speed) or float(speed) <= 0.0:
			return DataResult.failure("移动模块 properties.move_speed 必须是大于 0 的有限数字")
	var health: Variant = properties.get("max_health", 1.0)
	if not DataValidation.is_number(health) or float(health) <= 0.0 or float(health) > 1000000000.0:
		return DataResult.failure("模块 properties.max_health 必须是大于 0、最多 1000000000 的有限数字")
	var definition := ModuleDefinition.new()
	definition.id = data.id
	definition.display_name = data.name
	definition.description = data.get("description", "")
	definition.size = Vector2(float(dimensions.width), float(dimensions.height))
	definition.texture = data.texture
	definition.behavior = data.script_type
	definition.properties = properties.duplicate(true)
	definition.raw = data.duplicate(true)
	return DataResult.success(definition)


## 校验地块字段，碰撞与雷达遮挡必须使用明确的布尔值。
static func _parse_tile(data: Dictionary) -> DataResult:
	var common := _validate_common(data)
	if not common.is_ok():
		return common
	for field in ["collision", "radar_block"]:
		if not data.get(field) is bool:
			return DataResult.failure("%s 必须是布尔值" % field)
	# 缺省沿用旧地块的碰撞语义；铁栅栏可单独放行攻击。
	if data.has("attack_block") and not data.attack_block is bool:
		return DataResult.failure("attack_block 必须是布尔值")
	var definition := TileDefinition.new()
	definition.id = data.id
	definition.display_name = data.name
	definition.texture = data.texture
	definition.collision = data.collision
	definition.radar_block = data.radar_block
	definition.attack_block = data.get("attack_block", data.collision)
	definition.properties = data.get("properties", {}).duplicate(true)
	definition.raw = data.duplicate(true)
	return DataResult.success(definition)


## 在建立定义对象前检查版本、ID、名称、贴图和扩展属性类型。
static func _validate_common(data: Dictionary) -> DataResult:
	if not DataValidation.is_integer(data.get("format_version"), 1, 1):
		return DataResult.failure("仅支持 format_version: 1")
	if not DataValidation.is_id(data.get("id")):
		return DataResult.failure("id 无效，且不能使用保留名称 void")
	if not DataValidation.is_text(data.get("name"), false):
		return DataResult.failure("name 必须是非空字符串")
	if not DataValidation.is_resource_path(data.get("texture")):
		return DataResult.failure("texture 必须为安全的 res:// 或 user:// 资源路径")
	var texture_result := ContentTextureLoader.load_texture(data.texture)
	if not texture_result.is_ok():
		return texture_result
	if not data.get("properties", {}) is Dictionary:
		return DataResult.failure("properties 必须是对象")
	return DataResult.success()
