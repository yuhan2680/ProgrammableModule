class_name PlayerLevelStore
extends RefCounted
## 保存与导入只写托管玩家关卡；路径绑定由编辑器持有，文件导出仍由原入口处理。

const MAX_CANDIDATES: int = 10000
static var _issued_map_ids: Dictionary = {}
static var _map_id_random: RandomNumberGenerator

var directory: String = "user://levels"


## 新建地图先避开磁盘和本进程已分配的标识，不创建文件或改变已有地图。
func create_map_id(extra_used_ids: Dictionary = {}) -> DataResult:
	var folder := _managed_folder(false)
	if not folder.is_ok():
		return folder
	var used_ids := extra_used_ids.duplicate()
	for source: String in ["res://data/maps", "res://data/levels", directory]:
		# 示例地图目录可不存在；新建不依赖示例资源，但正式关卡目录仍沿用原有完整性要求。
		var read := _read_ids(source, "", source == "res://data/levels")
		if not read.is_ok():
			return read
		used_ids.merge(read.value, true)
	var candidate := _draw_unused_map_id(used_ids)
	if candidate.is_empty():
		return DataResult.failure("无法分配新的地图 ID，请重试。")
	return DataResult.success(candidate)


## 固定十位 ASCII 数字只用于新 ID 及同格式副本；旧地图的任意合法 ID 保持兼容。
static func is_generated_map_id(value: String) -> bool:
	if value.length() != 14 or not value.begins_with("map_"):
		return false
	for index in range(4, 14):
		if value.unicode_at(index) < 48 or value.unicode_at(index) > 57:
			return false
	return true


## 碰撞重试有明确上限；保留未保存 ID，避免同一进程连续新建时再次抽到旧草稿标识。
func _draw_unused_map_id(used_ids: Dictionary) -> String:
	for _attempt in MAX_CANDIDATES:
		var candidate := _random_map_id()
		if is_generated_map_id(candidate) and not used_ids.has(candidate) and not _issued_map_ids.has(candidate):
			_issued_map_ids[candidate] = true
			return candidate
	return ""


## 独立随机源不影响游戏行为；两个五位段均匀采样，允许前导零以及任意重复数字。
func _random_map_id() -> String:
	if _map_id_random == null:
		_map_id_random = RandomNumberGenerator.new()
		_map_id_random.randomize()
	return "map_%05d%05d" % [_map_id_random.randi_range(0, 99999), _map_id_random.randi_range(0, 99999)]


## 导入前复用选关目录的完整校验；始终生成独立副本，不绑定或改写玩家选择的来源。
func import_file(path: String, registry: ContentRegistry) -> DataResult:
	if path.is_empty() or path.get_extension().to_lower() != "json":
		return DataResult.failure("请选择 JSON 格式的关卡文件。")
	var loaded := MapCodec.load_file(path, registry, true)
	if not loaded.is_ok():
		return loaded
	var definition := LevelDefinition.from_document(loaded.value, registry, path)
	if not definition.is_ok():
		return definition
	# save 允许编辑草稿；导入须先通过与正式关卡列表一致的出生点和关卡规则检查。
	# 不传来源为保存绑定，使重复导入及同名内置地图也只能生成安全去重后的新副本。
	return save(loaded.value, registry)


## 深拷贝后保存草稿；只有成功结果中的文档与路径可成为编辑器的新保存点。
func save(document: MapDocument, registry: ContentRegistry, preferred_path: String = "", preserve_id: bool = false) -> DataResult:
	var checked := MapCodec.validate(document, registry, false)
	if not checked.is_ok():
		return checked
	var folder_result := _managed_folder(false)
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	var bound_path := managed_path(preferred_path)
	if _has_unsafe_segments(preferred_path):
		return DataResult.failure("玩家关卡保存路径不能包含上级路径或无效分隔符。")
	if not bound_path.is_empty() and folder != null:
		var bound_name := bound_path.get_file()
		if folder.is_link(bound_name) or folder.dir_exists(bound_name):
			return DataResult.failure("玩家关卡保存位置不能是符号链接或目录：%s。" % bound_path)
	var builtin_ids := _read_ids("res://data/levels", "", true)
	if not builtin_ids.is_ok():
		return builtin_ids
	var user_ids := _read_ids(directory, bound_path, false)
	if not user_ids.is_ok():
		return user_ids
	var used_ids: Dictionary = builtin_ids.value
	used_ids.merge(user_ids.value, true)
	# 编辑器刚创建的标识不能在保存时偷偷改变；外部抢占同 ID 时保留草稿并明确失败。
	if preserve_id and used_ids.has(document.id):
		return DataResult.failure("此地图 ID 已被其他关卡使用，请创建新地图后重试。")
	var candidate := document.duplicate_document()
	candidate.id = _available_id(document.id, used_ids)
	if candidate.id.is_empty():
		return DataResult.failure("无法分配新的地图 ID，请重试。")
	var destination := bound_path
	if destination.is_empty():
		destination = _available_path(candidate.id, folder)
	if destination.is_empty():
		return DataResult.failure("玩家关卡文件名重复过多，请重试。")
	# 再检查目录链并按段创建，禁止 MapCodec 的递归创建经过目录链接。
	folder_result = _managed_folder(true)
	if not folder_result.is_ok():
		return folder_result
	folder = folder_result.value
	var filename := destination.get_file()
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡保存位置已改变，请重试：%s。" % destination)
	if bound_path.is_empty() and folder.file_exists(filename):
		return DataResult.failure("玩家关卡文件名已被占用，请重试：%s。" % destination)
	var saved := _write_document(candidate, destination, registry)
	if not saved.is_ok():
		return saved
	return DataResult.success({"path": destination, "document": candidate})


## 将直接托管 JSON 的原生路径统一为当前保存目录表示，外部来源始终生成独立副本。
func managed_path(path: String) -> String:
	if path.is_empty() or _has_unsafe_segments(path) or path.get_file().begins_with("."):
		return ""
	if not PlayerLevelPaths.is_direct_json(path, directory):
		return ""
	return directory.path_join(path.get_file())


## 复用玩家关卡专用目录授权，不改变导出到任意用户选择位置的独立语义。
func _managed_folder(create_missing: bool) -> DataResult:
	return PlayerLevelPaths.open_directory(directory, create_missing)


## 读取所有直接 JSON 的顶层 ID；坏地图也保留 ID 占位，避免修复后遮蔽本次保存。
func _read_ids(path: String, excluded_path: String, builtin: bool) -> DataResult:
	var result: Dictionary = {}
	var folder := DirAccess.open(path)
	if folder == null:
		if not builtin and not DirAccess.dir_exists_absolute(path):
			return DataResult.success(result)
		return DataResult.failure("无法读取关卡 ID 目录：%s。" % path)
	folder.include_hidden = true
	var list_error := folder.list_dir_begin()
	if list_error != OK:
		return DataResult.failure("无法枚举关卡 ID 目录：%s。" % path)
	var filename := folder.get_next()
	while not filename.is_empty():
		if filename.get_extension().to_lower() == "json":
			var source_path := path.path_join(filename)
			if folder.is_link(filename):
				folder.list_dir_end()
				return DataResult.failure("玩家关卡 JSON 不能是符号链接：%s。" % source_path)
			if not folder.current_is_dir() and source_path != excluded_path:
				var parsed := _read_id(source_path)
				if not parsed.is_ok() or (builtin and str(parsed.value).is_empty()):
					folder.list_dir_end()
					return DataResult.failure("无法确认关卡 ID，已取消保存：%s。" % source_path)
				if not str(parsed.value).is_empty():
					result[parsed.value] = true
		filename = folder.get_next()
	folder.list_dir_end()
	if builtin and result.is_empty():
		return DataResult.failure("未找到系统自带关卡 ID，已取消保存。")
	return DataResult.success(result)


## 有界读取 ASCII ID，忽略坏 JSON 并兼容 BOM；不对已有地图做格式修复或写回。
func _read_id(path: String) -> DataResult:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取关卡：%s。" % path)
	if file.get_length() > DataValidation.MAX_FILE_BYTES:
		file.close()
		return DataResult.success("")
	var bytes := file.get_buffer(file.get_length())
	var read_error := file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return DataResult.failure("关卡读取失败：%s。" % path)
	if bytes.size() >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf:
		bytes = bytes.slice(3)
	var parser := JSON.new()
	if parser.parse(bytes.get_string_from_ascii()) != OK or not parser.data is Dictionary:
		return DataResult.success("")
	var map_id: Variant = parser.data.get("id")
	return DataResult.success(map_id if DataValidation.is_id(map_id) else "")


## 保留无冲突 ID；十位随机格式的副本重新抽取，旧 ID 沿用原有确定性后缀以保持兼容。
func _available_id(original: String, used_ids: Dictionary) -> String:
	if not used_ids.has(original):
		return original
	if is_generated_map_id(original):
		return _draw_unused_map_id(used_ids)
	for index in range(2, MAX_CANDIDATES + 2):
		var suffix := "_%d" % index
		var candidate := original.left(128 - suffix.length()) + suffix
		if not used_ids.has(candidate):
			return candidate
	return ""


## 文件名前缀避免隐藏文件与系统保留名称，所有已存在文件、目录和链接均占位。
func _available_path(map_id: String, folder: DirAccess) -> String:
	var stem := "player_" + map_id
	for index in range(1, MAX_CANDIDATES + 1):
		var filename := stem + ("" if index == 1 else "_%d" % index) + ".json"
		if folder == null or not (folder.file_exists(filename) or folder.dir_exists(filename) or folder.is_link(filename)):
			return directory.path_join(filename)
	return ""


## 拒绝路径跳转和混用分隔符；普通外部路径可以作为来源，但永远不会成为写入目标。
func _has_unsafe_segments(path: String) -> bool:
	if path.contains("\\"):
		return true
	for segment in path.split("/"):
		if segment == "." or segment == "..":
			return true
	return false


## 复用既有原子写盘并允许未完成出生点草稿，独立入口用于回归注入真实保存失败。
func _write_document(document: MapDocument, path: String, registry: ContentRegistry) -> DataResult:
	return MapCodec.save_file(document, path, registry, false)
