class_name LevelCatalog
extends RefCounted
## 关卡选择页的数据源；内置关卡始终优先，自定义坏文件不会遮蔽其他关卡。

var levels: Array[LevelDefinition] = []
var errors: PackedStringArray = PackedStringArray()
var user_directory: String = "user://levels"


## 重新扫描关卡目录，收集逐文件错误并保留本次成功读取的全部关卡。
func refresh(content: ContentRegistry) -> DataResult:
	levels.clear()
	errors.clear()
	if content == null:
		errors.append("关卡目录需要已加载的内容注册表。")
		return DataResult.failure(errors[0])
	var used_ids: Dictionary = {}
	_load_directory("res://data/levels", content, used_ids)
	if user_directory.begins_with("user://"):
		_load_directory(user_directory, content, used_ids)
	else:
		errors.append("自定义关卡目录必须位于 user://。")
	var result := DataResult.success(levels)
	result.errors = errors.duplicate()
	return result


## 创建自定义关卡目录并返回绝对路径，打开系统文件夹由 UI 自行处理。
func ensure_import_directory() -> DataResult:
	if not DataValidation.is_resource_path(user_directory) or not user_directory.begins_with("user://"):
		return DataResult.failure("自定义关卡目录必须位于 user://，且不能包含上级路径。")
	var absolute := ProjectSettings.globalize_path(user_directory)
	var error := DirAccess.make_dir_recursive_absolute(absolute)
	if error != OK:
		return DataResult.failure("无法创建导入目录：%s。" % error_string(error))
	return DataResult.success(absolute)


## 清除导入目录中的直接 JSON 文件；传入草稿存储时同时清除可确认归属的用户关卡记录。
func clear_user_levels(draft_store: GameDraftStore = null) -> DataResult:
	var folder_result := _user_clear_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null:
		return DataResult.success({"file_count": 0, "level_ids": []})
	if draft_store != null:
		# 地图和记录目录不能相互包含，避免错误配置把记录 JSON 当成地图清除。
		var records_path := draft_store.directory
		if records_path == user_directory or records_path.begins_with(user_directory + "/") or user_directory.begins_with(records_path + "/"):
			return DataResult.failure("用户关卡与玩家记录目录不能相互包含，未清除任何文件。")
		var record_validation := draft_store.clear_level_records([])
		if not record_validation.is_ok():
			return record_validation
	var builtin_result := _builtin_clear_exclusions()
	if not builtin_result.is_ok():
		return builtin_result
	var builtin_ids: Dictionary = builtin_result.value
	var filenames: Array[String] = []
	var level_ids: Array[String] = []
	var list_error := folder.list_dir_begin()
	if list_error != OK:
		return DataResult.failure("无法读取用户关卡目录：%s。" % error_string(list_error))
	var filename := folder.get_next()
	while not filename.is_empty():
		if filename.get_extension().to_lower() == "json":
			if folder.is_link(filename):
				folder.list_dir_end()
				return DataResult.failure("用户关卡 JSON 不能是符号链接，未清除任何文件：%s。" % user_directory.path_join(filename))
			if not folder.current_is_dir():
				filenames.append(filename)
		filename = folder.get_next()
	folder.list_dir_end()
	filenames.sort()
	for name in filenames:
		if folder.is_link(name) or folder.dir_exists(name):
			return DataResult.failure("待清除用户关卡的路径已改变，未清除任何文件：%s。" % user_directory.path_join(name))
		var id_result := _read_import_id(user_directory.path_join(name))
		if not id_result.is_ok():
			return id_result
		var level_id: String = id_result.value
		if not level_id.is_empty() and not builtin_ids.has(level_id) and not level_id in level_ids:
			level_ids.append(level_id)
	# 地图在本次会话中变坏时，仍可用先前真实加载的同一路径找回其记录 ID。
	for definition in levels:
		if definition.source_path.get_base_dir() == user_directory and definition.source_path.get_file() in filenames:
			if DataValidation.is_id(definition.id) and not builtin_ids.has(definition.id) and not definition.id in level_ids:
				level_ids.append(definition.id)
	if filenames.is_empty():
		return DataResult.success({"file_count": 0, "level_ids": level_ids})
	return _clear_import_files(folder, filenames, level_ids, draft_store)


## 删除入口只接受正式导入位置或隔离测试目录，拒绝根目录、配置目录及任何路径链接。
func _user_clear_folder() -> DataResult:
	if not DataValidation.is_resource_path(user_directory) or not user_directory.begins_with("user://"):
		return DataResult.failure("用户关卡清除目录必须是安全的 user://levels 路径。")
	var segments := user_directory.trim_prefix("user://").split("/")
	var isolated_test := segments.size() >= 3 and segments[0] == "tests"
	if user_directory != "user://levels" and not isolated_test:
		return DataResult.failure("只允许清除导入关卡目录，不能清除设置、记录或其它数据目录。")
	if segments[-1] in ["solutions", "settings", "data"]:
		return DataResult.failure("用户关卡清除目录不能使用设置或记录目录。")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问用户关卡根目录：%s。" % error_string(DirAccess.get_open_error()))
	for segment in segments:
		if folder.is_link(segment):
			return DataResult.failure("用户关卡目录不能包含符号链接，未清除任何文件：%s。" % user_directory)
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("用户关卡目录被同名文件占用，未清除任何文件：%s。" % user_directory)
			return DataResult.success()
		var change_error := folder.change_dir(segment)
		if change_error != OK:
			return DataResult.failure("无法访问用户关卡目录：%s。" % error_string(change_error))
	folder.include_hidden = true
	return DataResult.success(folder)


## 独立读取全部内置 JSON 的真实 ID，不使用可能遗漏坏文件或重复 ID 的显示列表作为保护范围。
func _builtin_clear_exclusions() -> DataResult:
	var folder := DirAccess.open("res://data/levels")
	if folder == null:
		return DataResult.failure("无法读取系统自带关卡，已取消清除用户关卡。")
	var ids: Dictionary = {}
	for filename in folder.get_files():
		if filename.get_extension().to_lower() != "json":
			continue
		var parsed := DataValidation.read_json_object("res://data/levels".path_join(filename))
		if not parsed.is_ok() or not DataValidation.is_id(parsed.value.get("id") if parsed.is_ok() else null):
			return DataResult.failure("无法确认系统自带关卡 ID，已取消清除用户关卡：%s。" % filename)
		ids[parsed.value.id] = true
	if ids.is_empty():
		return DataResult.failure("未找到系统自带关卡 ID，已取消清除用户关卡。")
	return DataResult.success(ids)


## 只读取顶层合法 ID；坏 JSON 仍属于导入文件，但无法确认归属时不猜测或扩大记录清除范围。
func _read_import_id(path: String) -> DataResult:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取待清除的用户关卡，未清除任何文件：%s（%s）。" % [path, error_string(FileAccess.get_open_error())])
	if file.get_length() > DataValidation.MAX_FILE_BYTES:
		file.close()
		return DataResult.success("")
	# ID 仅允许 ASCII；按单字节文本解析可保持 ASCII JSON 语法和 ID，同时避免损坏 UTF-8 的解码日志。
	# 此处不加载地图内容，不显示解析后的名称，也不改写原文件。
	var source_bytes := file.get_buffer(file.get_length())
	var read_error := file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return DataResult.failure("读取用户关卡失败，未清除任何文件：%s（%s）。" % [path, error_string(read_error)])
	# 带 UTF-8 BOM 的合法导入文件也须识别 ID；只去掉文件开头标记，不修改 JSON 内容。
	if source_bytes.size() >= 3 and source_bytes[0] == 0xef and source_bytes[1] == 0xbb and source_bytes[2] == 0xbf:
		source_bytes = source_bytes.slice(3)
	var source := source_bytes.get_string_from_ascii()
	var parser := JSON.new()
	if parser.parse(source) != OK or not parser.data is Dictionary or not DataValidation.is_id(parser.data.get("id")):
		return DataResult.success("")
	return DataResult.success(parser.data.id)


## 地图先整体暂存，记录清除失败则恢复地图；最终删除失败时恢复尚未删除的地图以支持重试。
func _clear_import_files(folder: DirAccess, filenames: Array[String], level_ids: Array[String], draft_store: GameDraftStore) -> DataResult:
	var nonce := Crypto.new().generate_random_bytes(16).hex_encode()
	if nonce.is_empty():
		return DataResult.failure("无法生成用户关卡清除临时目录，未清除任何文件。")
	var temporary_name := ".clear_user_levels_%s" % nonce
	var create_error := folder.make_dir(temporary_name)
	if create_error != OK:
		return DataResult.failure("无法创建用户关卡清除临时目录：%s。" % error_string(create_error))
	var absolute := ProjectSettings.globalize_path(folder.get_current_dir())
	var temporary := absolute.path_join(temporary_name)
	var staged: Array[String] = []
	for filename in filenames:
		var move_error := ERR_FILE_BAD_PATH
		if not folder.is_link(filename) and not folder.dir_exists(filename) and folder.file_exists(filename):
			move_error = _rename_user_level(absolute.path_join(filename), temporary.path_join(filename))
		if move_error != OK:
			var restored := _restore_user_levels(absolute, temporary, staged)
			if not restored.is_ok():
				return restored
			return DataResult.failure("用户关卡暂存失败，原地图已恢复：%s（%s）。" % [filename, error_string(move_error)])
		staged.append(filename)
	if draft_store != null:
		var cleared := draft_store.clear_level_records(level_ids)
		if not cleared.is_ok():
			var restored := _restore_user_levels(absolute, temporary, staged)
			var result := DataResult.failure("用户关卡清除未完成，部分游玩记录可能已清除。")
			result.errors.append_array(cleared.errors)
			if not restored.is_ok():
				result.errors.append_array(restored.errors)
			return result
	for index in staged.size():
		var remove_error := _remove_user_level(temporary.path_join(staged[index]))
		if remove_error != OK:
			var restored := _restore_user_levels(absolute, temporary, staged.slice(index))
			var result := DataResult.failure("用户关卡清除未完成：已清除 %d 个地图文件，游玩记录可能已清除。请修复目录权限后重试（%s）。" % [index, error_string(remove_error)])
			if not restored.is_ok():
				result.errors.append_array(restored.errors)
			return result
	var cleanup_error := DirAccess.remove_absolute(temporary)
	if cleanup_error != OK:
		return DataResult.failure("用户关卡已清除，但临时目录未能清理：%s（%s）。" % [temporary, error_string(cleanup_error)])
	return DataResult.success({"file_count": filenames.size(), "level_ids": level_ids})


## 逆序恢复本次暂存地图；恢复位置被占用时保留临时原件，不覆盖新写入的文件。
func _restore_user_levels(absolute: String, temporary: String, filenames: Array[String]) -> DataResult:
	var folder := DirAccess.open(absolute)
	if folder == null:
		return DataResult.failure("无法恢复用户关卡，未删除原件保留于：%s。" % temporary)
	for index in range(filenames.size() - 1, -1, -1):
		var filename := filenames[index]
		if folder.is_link(filename) or folder.file_exists(filename) or folder.dir_exists(filename):
			return DataResult.failure("用户关卡恢复位置被占用，未删除原件保留于：%s。" % temporary)
		if _rename_user_level(temporary.path_join(filename), absolute.path_join(filename)) != OK:
			return DataResult.failure("用户关卡恢复失败，未删除原件保留于：%s。" % temporary)
	if DirAccess.remove_absolute(temporary) != OK:
		return DataResult.failure("原地图已恢复，但用户关卡临时目录未能清理：%s。" % temporary)
	return DataResult.success()


## 同目录改名统一入口，独立回归可以模拟中途失败而不依赖系统权限差异。
func _rename_user_level(source_path: String, destination_path: String) -> Error:
	return DirAccess.rename_absolute(source_path, destination_path)


## 删除暂存地图统一入口，失败必须由上层报告并恢复剩余文件。
func _remove_user_level(path: String) -> Error:
	return DirAccess.remove_absolute(path)


## 每个目录单独排序后追加，保证用户 order 不会改变内置关卡的优先位置。
func _load_directory(directory: String, content: ContentRegistry, used_ids: Dictionary) -> void:
	if not DataValidation.is_resource_path(directory):
		errors.append("关卡目录路径无效：%s。" % directory)
		return
	if not DirAccess.dir_exists_absolute(directory):
		if not directory.begins_with("user://"):
			errors.append("内置关卡目录不存在：%s。" % directory)
		return
	var folder := DirAccess.open(directory)
	if folder == null:
		errors.append("无法打开关卡目录：%s。" % directory)
		return
	var names := folder.get_files()
	names.sort()
	var loaded: Array[LevelDefinition] = []
	for filename in names:
		if filename.get_extension().to_lower() != "json":
			continue
		var path := directory.path_join(filename)
		var parsed := MapCodec.load_file(path, content, true)
		if not parsed.is_ok():
			errors.append_array(parsed.errors)
			continue
		var definition := LevelDefinition.from_document(parsed.value, content, path)
		if not definition.is_ok():
			for error in definition.errors:
				errors.append("%s：%s" % [path, error])
			continue
		var level: LevelDefinition = definition.value
		if used_ids.has(level.id):
			errors.append("%s：关卡 ID 重复，不能覆盖已加载关卡 '%s'。" % [path, level.id])
			continue
		used_ids[level.id] = true
		loaded.append(level)
	loaded.sort_custom(_level_before)
	levels.append_array(loaded)


## order 相同时按源文件路径排序，文件扫描顺序不会改变关卡列表。
static func _level_before(left: LevelDefinition, right: LevelDefinition) -> bool:
	return left.order < right.order or (left.order == right.order and left.source_path < right.source_path)
