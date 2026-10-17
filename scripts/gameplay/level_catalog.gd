class_name LevelCatalog
extends RefCounted
## 关卡选择页的数据源；内置关卡始终优先，自定义坏文件不会遮蔽其他关卡。

var levels: Array[LevelDefinition] = []
var errors: PackedStringArray = PackedStringArray()
var user_directory: String = "user://levels"
# 删除授权绑定本次实际扫描的对象及文件字节，不能只凭可伪造的地图 ID 推导路径。
var _user_level_sources: Dictionary = {}
static var _player_level_name_pattern: RegEx


## 重新扫描关卡目录，收集逐文件错误并保留本次成功读取的全部关卡。
func refresh(content: ContentRegistry) -> DataResult:
	levels.clear()
	errors.clear()
	_user_level_sources.clear()
	if content == null:
		errors.append("关卡目录需要已加载的内容注册表。")
		return DataResult.failure(errors[0])
	var used_ids: Dictionary = {}
	_load_directory("res://data/levels", content, used_ids)
	if PlayerLevelPaths.is_allowed_directory(user_directory):
		_load_directory(user_directory, content, used_ids)
	else:
		errors.append("玩家关卡目录不在允许的保存位置。")
	var result := DataResult.success(levels)
	result.errors = errors.duplicate()
	return result


## 创建自定义关卡目录并返回绝对路径，打开系统文件夹由 UI 自行处理。
func ensure_import_directory() -> DataResult:
	var opened := PlayerLevelPaths.open_directory(user_directory, true)
	if not opened.is_ok():
		return opened
	return DataResult.success(ProjectSettings.globalize_path(user_directory))


## 只为本次目录实际拥有的玩家关卡提供删除入口；磁盘状态在执行时重新检查。
func can_delete_user_level(definition: LevelDefinition) -> bool:
	if definition == null or not levels.has(definition):
		return false
	var snapshot: Dictionary = _user_level_sources.get(definition.get_instance_id(), {})
	if snapshot.is_empty() or snapshot.directory != user_directory:
		return false
	var path := definition.source_path
	return snapshot.path == path and snapshot.id == definition.id and PlayerLevelPaths.is_direct_json(path, user_directory) and path.get_base_dir() == user_directory


## 仅返回当前玩家卡片实际所属的安全目录；读取入口不创建目录，也不打开外部来源。
func get_user_level_directory(definition: LevelDefinition) -> DataResult:
	if not can_delete_user_level(definition):
		return DataResult.failure("只能访问当前列表中的玩家关卡。")
	var folder_result := _user_clear_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null:
		return DataResult.failure("玩家关卡文件已不存在，请刷新关卡列表。")
	var filename := definition.source_path.get_file()
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡路径不安全，未访问任何文件：%s。" % definition.source_path)
	if not folder.file_exists(filename):
		return DataResult.failure("玩家关卡文件已不存在，请刷新关卡列表。")
	return DataResult.success(ProjectSettings.globalize_path(definition.source_path.get_base_dir()))


## 重命名入口统一校验原始文字，不修剪空白，也不改变已有地图读取时允许的旧名称。
static func validate_player_level_name(value: String) -> DataResult:
	if value.is_empty() or value.length() > DataValidation.MAX_PLAYER_NAME_LENGTH:
		return DataResult.failure("关卡名称必须为 1 到 30 个字符。")
	if _player_level_name_pattern == null:
		# 仅允许 Unicode 字母和十进制数字；排除分类为字母的不可见韩文字母填充符与表情信息符。
		_player_level_name_pattern = RegEx.create_from_string("\\A(?!.*[\\x{115F}\\x{1160}\\x{2139}\\x{3164}\\x{FFA0}])[\\p{L}\\p{Nd}_-]+\\z")
	if _player_level_name_pattern.search(value) == null:
		return DataResult.failure("关卡名称仅可包含文字、数字、下划线和连字符，不能包含空格、其他符号或表情。")
	return DataResult.success(value)


## 只修改已授权玩家文件的显示名称；原子写盘成功后才更新卡片及后续操作的文件快照。
func rename_user_level(definition: LevelDefinition, new_name: String, content: ContentRegistry) -> DataResult:
	var name_result := validate_player_level_name(new_name)
	if not name_result.is_ok():
		return name_result
	var directory_result := get_user_level_directory(definition)
	if not directory_result.is_ok():
		return directory_result
	var name := new_name
	var snapshot: Dictionary = _user_level_sources[definition.get_instance_id()]
	var path: String = snapshot.path
	var fingerprint := _user_file_fingerprint(path)
	if fingerprint.is_empty() or fingerprint != snapshot.fingerprint:
		return DataResult.failure("玩家关卡文件已改变，请刷新后再重命名。")
	# 从磁盘快照读取，不能把调用方对卡片文档的临时修改一并写回正式地图。
	var loaded := MapCodec.load_file(path, content, true)
	if not loaded.is_ok():
		return loaded
	var checked := LevelDefinition.from_document(loaded.value, content, path)
	if not checked.is_ok():
		return checked
	if loaded.value.id != snapshot.id or _user_file_fingerprint(path) != fingerprint:
		return DataResult.failure("玩家关卡文件已改变，请刷新后再重命名。")
	if loaded.value.display_name == name:
		return DataResult.success({"path": path, "level_id": snapshot.id, "name": name})
	var document: MapDocument = loaded.value.duplicate_document()
	document.display_name = name
	# 重新检查目录链与直接文件类型，外部替换成链接或目录时绝不进入写盘。
	directory_result = get_user_level_directory(definition)
	if not directory_result.is_ok():
		return directory_result
	if _user_file_fingerprint(path) != fingerprint:
		return DataResult.failure("玩家关卡文件已改变，请刷新后再重命名。")
	var saved := _write_user_level(document, path, content)
	if not saved.is_ok():
		return saved
	definition.display_name = name
	definition.document = document
	snapshot.fingerprint = _user_file_fingerprint(path)
	_user_level_sources[definition.get_instance_id()] = snapshot
	return DataResult.success({"path": path, "level_id": snapshot.id, "name": name})


## 删除一张已确认归属且未被外部替换的玩家地图；不读取或清除程序、装配和通关记录。
func delete_user_level(definition: LevelDefinition) -> DataResult:
	if not can_delete_user_level(definition):
		return DataResult.failure("只能删除当前列表中的玩家关卡。")
	var folder_result := _user_clear_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null:
		return DataResult.failure("玩家关卡文件已不存在，请刷新关卡列表。")
	var snapshot: Dictionary = _user_level_sources[definition.get_instance_id()]
	var path: String = snapshot.path
	var filename := path.get_file()
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡路径不安全，未删除任何文件：%s。" % path)
	if not folder.file_exists(filename):
		return DataResult.failure("玩家关卡文件已不存在，请刷新关卡列表。")
	var fingerprint := _user_file_fingerprint(path)
	if fingerprint.is_empty() or fingerprint != snapshot.fingerprint:
		return DataResult.failure("玩家关卡文件已改变，请刷新后再删除。")
	# 所有检查与删除均同步完成；再次验证路径类型，避免错误地删除换成目录或链接的条目。
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡路径不安全，未删除任何文件：%s。" % path)
	var remove_error := _remove_user_level(ProjectSettings.globalize_path(path))
	if remove_error != OK:
		return DataResult.failure("无法删除玩家关卡：%s（%s）。" % [path, error_string(remove_error)])
	levels.erase(definition)
	_user_level_sources.erase(definition.get_instance_id())
	return DataResult.success({"path": path, "level_id": snapshot.id})


## 对有大小上限的原始文件计算指纹，拒绝不可读取或读取不完整的文件而不猜测其身份。
func _user_file_fingerprint(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length := file.get_length()
	if length <= 0 or length > DataValidation.MAX_FILE_BYTES:
		file.close()
		return ""
	var bytes := file.get_buffer(length)
	var read_error := file.get_error()
	file.close()
	if bytes.size() != length or (read_error != OK and read_error != ERR_FILE_EOF):
		return ""
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK or hashing.update(bytes) != OK:
		return ""
	return hashing.finish().hex_encode()


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
		# 资源别名和物理绝对路径须按同一路径比较，同时保护拆分后的 Cache 与 Progress。
		var maps_path := ProjectSettings.globalize_path(user_directory).simplify_path().trim_suffix("/").to_lower()
		for records_directory: String in [draft_store.directory, draft_store.progress_directory]:
			if records_directory.is_empty():
				continue
			var records_path := ProjectSettings.globalize_path(records_directory).simplify_path().trim_suffix("/").to_lower()
			if records_path == maps_path or records_path.begins_with(maps_path + "/") or maps_path.begins_with(records_path + "/"):
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


## 文件管理复用严格目录授权，拒绝根目录、配置目录以及任何托管目录链接。
func _user_clear_folder() -> DataResult:
	return PlayerLevelPaths.open_directory(user_directory, false, true)


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


## 重命名复用地图原子写盘，独立入口用于验证系统拒绝写入时的状态保护。
func _write_user_level(document: MapDocument, path: String, content: ContentRegistry) -> DataResult:
	return MapCodec.save_file(document, path, content, true)


## 每个目录单独排序后追加，保证用户 order 不会改变内置关卡的优先位置。
func _load_directory(directory: String, content: ContentRegistry, used_ids: Dictionary) -> void:
	var folder: DirAccess
	if directory == user_directory:
		var opened := PlayerLevelPaths.open_directory(directory)
		if not opened.is_ok():
			errors.append_array(opened.errors)
			return
		folder = opened.value
		if folder == null:
			return
	else:
		if not DataValidation.is_resource_path(directory):
			errors.append("关卡目录路径无效：%s。" % directory)
			return
		if not DirAccess.dir_exists_absolute(directory):
			errors.append("内置关卡目录不存在：%s。" % directory)
			return
		folder = DirAccess.open(directory)
		if folder == null:
			errors.append("无法打开关卡目录：%s。" % directory)
			return

	folder.include_hidden = false
	var names := folder.get_files()
	names.sort()
	var loaded: Array[LevelDefinition] = []
	for filename in names:
		if filename.get_extension().to_lower() != "json":
			continue
		var path := directory.path_join(filename)
		var is_user_file := directory == user_directory
		if is_user_file and folder.is_link(filename):
			errors.append("玩家关卡路径不安全，未访问任何文件：%s。" % path)
			continue
		var fingerprint := _user_file_fingerprint(path) if is_user_file else ""
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
		if is_user_file:
			if fingerprint.is_empty() or fingerprint != _user_file_fingerprint(path):
				errors.append("玩家关卡读取期间文件发生变化，请刷新关卡列表：%s。" % path)
				continue
			_user_level_sources[level.get_instance_id()] = {"path": path, "directory": directory, "id": level.id, "fingerprint": fingerprint}
		used_ids[level.id] = true
		loaded.append(level)
	loaded.sort_custom(_level_before)
	levels.append_array(loaded)


## order 相同时按源文件路径排序，文件扫描顺序不会改变关卡列表。
static func _level_before(left: LevelDefinition, right: LevelDefinition) -> bool:
	return left.order < right.order or (left.order == right.order and left.source_path < right.source_path)
