class_name PlayerLevelLibrary
extends RefCounted
## 独立管理玩家地图文件，包括未完成和损坏文档；不会更改选关目录的可玩规则。

var user_directory: String = "user://levels"
var entries: Array[PlayerLevelRecord] = []
var _sources: Dictionary = {}


## 读取直接 JSON 文件并逐项保留诊断，坏文件不会阻止其余条目显示。
func refresh(content: ContentRegistry) -> DataResult:
	entries.clear()
	_sources.clear()
	if content == null:
		return DataResult.failure("玩家关卡文件列表需要已加载的内容注册表。")
	var folder_result := _safe_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null:
		return DataResult.success(entries)
	var dates := _windows_creation_times(ProjectSettings.globalize_path(user_directory)) if OS.get_name() == "Windows" else {}
	var names := folder.get_files()
	names.sort()
	var ids: Dictionary = {}
	for filename in names:
		if filename.get_extension().to_lower() != "json":
			continue
		var record := PlayerLevelRecord.new()
		record.source_path = user_directory.path_join(filename)
		record.display_name = filename.get_basename()
		entries.append(record)
		if folder.is_link(filename) or folder.dir_exists(filename):
			record.errors.append("玩家关卡文件不能是符号链接或目录。")
			continue
		var fingerprint := _fingerprint(record.source_path)
		if fingerprint.is_empty():
			record.errors.append("无法读取玩家关卡文件，请检查文件权限。")
			continue
		record.created_at = int(dates.get(filename, 0)) if OS.get_name() == "Windows" else _creation_time(record.source_path)
		var level_id := _read_record(record, content)
		if not level_id.is_empty():
			if not ids.has(level_id):
				ids[level_id] = []
			ids[level_id].append(record)
		# 解析与日期读取期间也可能被外部程序替换，只有完整稳定快照才能授权操作。
		if folder.is_link(filename) or folder.dir_exists(filename) or fingerprint != _fingerprint(record.source_path):
			record.can_edit = false
			record.can_rename = false
			record.playable = false
			record.errors.append("玩家关卡文件已改变，请刷新文件列表。")
			continue
		_sources[record.get_instance_id()] = {"path": record.source_path, "directory": user_directory, "fingerprint": fingerprint, "editable": record.can_edit, "id": level_id}
	var builtin_ids := _builtin_ids()
	for level_id: String in ids:
		if ids[level_id].size() > 1 or builtin_ids.has(level_id):
			for record: PlayerLevelRecord in ids[level_id]:
				record.errors.append("关卡 ID 重复，无法用于游玩：%s。" % level_id)
				record.playable = false
	return DataResult.success(entries)


## 对可编辑草稿只修改显示名，复用现有名称规则和允许无出生点的原子保存。
func rename_entry(record: PlayerLevelRecord, new_name: String, content: ContentRegistry) -> DataResult:
	var name_result := LevelCatalog.validate_player_level_name(new_name)
	if not name_result.is_ok():
		return name_result
	var source_result := _verified_source(record)
	if not source_result.is_ok():
		return source_result
	var snapshot: Dictionary = source_result.value
	if not snapshot.editable or content == null:
		return DataResult.failure("此地图无法解析为可编辑文档，不能重命名。")
	var loaded := MapCodec.load_file(snapshot.path, content, false)
	if not loaded.is_ok():
		return loaded
	var document: MapDocument = loaded.value
	if document.id != snapshot.id:
		return DataResult.failure("玩家关卡文件已改变，请刷新文件列表。")
	# 始终从磁盘快照读取，不把可修改的显示字段或外部文档带入保存。
	if document.display_name == new_name:
		return DataResult.success(record)
	document.display_name = new_name
	source_result = _verified_source(record)
	if not source_result.is_ok():
		return source_result
	var saved := _write_document(document, snapshot.path, content)
	if not saved.is_ok():
		return saved
	record.display_name = new_name
	snapshot.fingerprint = _fingerprint(snapshot.path)
	_sources[record.get_instance_id()] = snapshot
	# 原子替换可能产生新的真实创建时间；未知时间保持未知，不伪造旧时间。
	if OS.get_name() == "Windows":
		record.created_at = int(_windows_creation_times(ProjectSettings.globalize_path(user_directory)).get(snapshot.path.get_file(), 0))
	else:
		record.created_at = _creation_time(snapshot.path)
	return DataResult.success(record)


## 删除当前快照对应的单个玩家文件，空文件和坏 JSON 同样可删除，绝不清理游玩记录。
func delete_entry(record: PlayerLevelRecord) -> DataResult:
	var source_result := _verified_source(record)
	if not source_result.is_ok():
		return source_result
	var path: String = source_result.value.path
	var removed := _remove_file(ProjectSettings.globalize_path(path))
	if removed != OK:
		return DataResult.failure("无法删除玩家关卡：%s（%s）。" % [path, error_string(removed)])
	entries.erase(record)
	_sources.erase(record.get_instance_id())
	return DataResult.success({"path": path})


## 仅返回当前真实文件所在绝对目录，系统文件管理器由界面调用。
func get_entry_directory(record: PlayerLevelRecord) -> DataResult:
	var source_result := _verified_source(record)
	if not source_result.is_ok():
		return source_result
	return DataResult.success(ProjectSettings.globalize_path(source_result.value.path.get_base_dir()))


## 可编辑文件也须重新核验快照，防止旧菜单打开外部替换后的文件。
func get_entry_edit_path(record: PlayerLevelRecord) -> DataResult:
	var source_result := _verified_source(record)
	if not source_result.is_ok():
		return source_result
	if not source_result.value.editable:
		return DataResult.failure("此地图无法解析为可编辑文档，不能在地图编辑器中打开。")
	return DataResult.success(source_result.value.path)


## 分离结构可编辑性和运行规则，尽量从坏地图的合法字段保留名称及署名。
func _read_record(record: PlayerLevelRecord, content: ContentRegistry) -> String:
	var parsed := _read_object(record)
	if not parsed.is_ok():
		record.errors.append_array(parsed.errors)
		return ""
	var data: Dictionary = parsed.value
	if DataValidation.is_text(data.get("name"), false):
		record.display_name = data.name
	var metadata: Variant = data.get("properties", {})
	if metadata is Dictionary:
		metadata = metadata.get("level", {})
		if metadata is Dictionary and DataValidation.is_creator(metadata.get("creator", "")):
			record.creator = metadata.get("creator", "")
	var level_id: String = data.id if DataValidation.is_id(data.get("id")) else ""
	var editable := MapCodec.from_dict(data, content, false)
	if not editable.is_ok():
		record.errors.append_array(editable.errors)
		record.requires_newer_version = _requires_newer_version(data, content, editable.errors)
		return level_id
	record.can_rename = true
	record.can_edit = true
	var runnable := LevelDefinition.from_document(editable.value, content, record.source_path)
	if not runnable.is_ok():
		record.errors.append_array(runnable.errors)
		record.requires_newer_version = _requires_newer_version(data, content, runnable.errors)
		return level_id
	record.playable = true
	var level: LevelDefinition = runnable.value
	var active_enemies: bool = level.document.properties.get("level", {}).get("enemies_enabled", true) and not level.document.enemies.is_empty()
	if not level.has_goal and not (level.completion_mode == "reach_or_clear" and active_enemies):
		# 这是文件列表诊断；旧沙盒仍按既有规则可玩，不改底层地图格式或终局语义。
		record.errors.append("缺少必要的终点")
	return level_id


## 先检查编码和JSON语法，将文件损坏与可解析文档的版本或字段异常分开。
func _read_object(record: PlayerLevelRecord) -> DataResult:
	var file := FileAccess.open(record.source_path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取玩家关卡文件，请检查文件权限。")
	var length := file.get_length()
	if length > DataValidation.MAX_FILE_BYTES:
		file.close()
		return DataResult.failure("地图超过 8 MiB 文件大小上限")
	var bytes := file.get_buffer(length)
	var read_error := file.get_error()
	file.close()
	if bytes.size() != length or (read_error != OK and read_error != ERR_FILE_EOF):
		return DataResult.failure("无法完整读取玩家关卡文件，请刷新后重试。")
	if not _valid_utf8(bytes):
		record.is_corrupt = true
		return DataResult.failure("文件不是有效的 UTF-8 文本。")
	if bytes.size() >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf:
		bytes = bytes.slice(3)
	var parser := JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK:
		record.is_corrupt = true
		return DataResult.failure("%s 第 %d 行 JSON 错误：%s" % [record.source_path, parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary:
		return DataResult.failure("JSON 根节点必须为对象：%s" % record.source_path)
	if not DataValidation.is_json_value(parser.data):
		return DataResult.failure("JSON 含有非有限数字或超过大小、嵌套上限：%s" % record.source_path)
	return DataResult.success(parser.data)


## 解码前校验UTF-8，拒绝截断、过长编码和代理码，避免乱码触发引擎错误或丢失字节。
static func _valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first := bytes[index]
		if first < 0x80:
			index += 1
			continue
		var width := 2 if first >= 0xc2 and first <= 0xdf else (3 if first >= 0xe0 and first <= 0xef else (4 if first >= 0xf0 and first <= 0xf4 else 0))
		if width == 0 or index + width > bytes.size():
			return false
		for offset in range(1, width):
			if bytes[index + offset] < 0x80 or bytes[index + offset] > 0xbf:
				return false
		var second := bytes[index + 1]
		if (first == 0xe0 and second < 0xa0) or (first == 0xed and second >= 0xa0) or (first == 0xf0 and second < 0x90) or (first == 0xf4 and second >= 0x90):
			return false
		index += width
	return true


## 仅沿校验实际失败的字段识别新版本，非法ID和其他位置的未知引用不混淆诊断。
func _requires_newer_version(data: Dictionary, content: ContentRegistry, diagnostics: PackedStringArray) -> bool:
	var message := "\n".join(diagnostics)
	if message.contains("format_version"):
		return DataValidation.is_integer(data.get("format_version"), 2, 2147483647)
	if message.contains("未知地块") and data.get("tiles") is Array:
		var matched := RegEx.create_from_string("tiles\\[(\\d+)\\]").search(message)
		if matched != null and int(matched.get_string(1)) < data.tiles.size():
			var tile: Variant = data.tiles[int(matched.get_string(1))]
			return tile is Dictionary and DataValidation.is_id(tile.get("tile_id")) and content.get_tile(tile.tile_id) == null
	if not message.contains("未知模块"):
		return false
	var properties: Dictionary = data.get("properties", {}) if data.get("properties", {}) is Dictionary else {}
	var level: Dictionary = properties.get("level", {}) if properties.get("level", {}) is Dictionary else {}
	if message.contains("allowed_modules"):
		return _first_module_reference_is_unknown(level.get("allowed_modules"), content)
	if message.contains("限制使用的模块"):
		return _first_module_reference_is_unknown(level.get("restricted_modules"), content)
	if message.contains("敌人组合"):
		var editor: Variant = properties.get("editor", {})
		if editor is Dictionary and editor.get("enemy_template") is Dictionary:
			return _first_module_reference_is_unknown(editor.enemy_template.get("module_ids"), content)
		return false
	var matched := RegEx.create_from_string("(player_spawn|enemies\\[(\\d+)\\]|objects\\[(\\d+)\\])\\.modules\\[(\\d+)\\]").search(message)
	if matched == null:
		return false
	var machine: Variant = data.get("player_spawn")
	if matched.get_string(1).begins_with("enemies"):
		machine = data.enemies[int(matched.get_string(2))]
	elif matched.get_string(1).begins_with("objects"):
		machine = data.objects[int(matched.get_string(3))]
	if not machine is Dictionary or not machine.get("modules") is Array:
		return false
	var module_index := int(matched.get_string(4))
	if module_index >= machine.modules.size() or not machine.modules[module_index] is Dictionary:
		return false
	var module_id: Variant = machine.modules[module_index].get("module_id")
	return DataValidation.is_id(module_id) and content.get_module(module_id) == null


## 模块数组按原校验顺序读取，只有首个错误是合法但未注册的ID时才标记新版引用。
static func _first_module_reference_is_unknown(value: Variant, content: ContentRegistry) -> bool:
	if not value is Array:
		return false
	for module_id: Variant in value:
		if not DataValidation.is_id(module_id):
			return false
		if content.get_module(module_id) == null:
			return true
	return false


## 授权同时绑定当前对象、目录、直接文件类型和原始字节，字段伪造无法转移操作目标。
func _verified_source(record: PlayerLevelRecord) -> DataResult:
	if record == null or not entries.has(record):
		return DataResult.failure("只能操作当前文件列表中的玩家关卡。")
	var snapshot: Dictionary = _sources.get(record.get_instance_id(), {})
	if snapshot.is_empty() or snapshot.directory != user_directory or snapshot.path != record.source_path:
		return DataResult.failure("只能操作当前文件列表中的玩家关卡。")
	var path: String = snapshot.path
	if not DataValidation.is_resource_path(path) or path.get_base_dir() != user_directory or path.get_extension().to_lower() != "json":
		return DataResult.failure("玩家关卡文件路径不安全。")
	var folder_result := _safe_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null:
		return DataResult.failure("玩家关卡文件已不存在，请刷新文件列表。")
	var filename := path.get_file()
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡文件不能是符号链接或目录。")
	if not folder.file_exists(filename):
		return DataResult.failure("玩家关卡文件已不存在，请刷新文件列表。")
	var fingerprint := _fingerprint(path)
	if fingerprint.is_empty() or fingerprint != snapshot.fingerprint:
		return DataResult.failure("玩家关卡文件已改变，请刷新文件列表。")
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("玩家关卡文件不能是符号链接或目录。")
	return DataResult.success(snapshot)


## 只遍历正式玩家目录或独占测试目录，不跟随任何目录链接，也不隐式创建缺失目录。
func _safe_folder() -> DataResult:
	if not DataValidation.is_resource_path(user_directory) or not user_directory.begins_with("user://"):
		return DataResult.failure("玩家关卡文件目录必须是安全的 user://levels 路径。")
	var segments := user_directory.trim_prefix("user://").split("/")
	var isolated_test := segments.size() >= 3 and segments[0] == "tests"
	if user_directory != "user://levels" and not isolated_test:
		return DataResult.failure("只允许操作玩家关卡目录，不能操作设置或记录目录。")
	if segments[-1] in ["solutions", "settings", "data"]:
		return DataResult.failure("玩家关卡文件目录不能使用设置或记录目录。")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问玩家关卡根目录。")
	for segment in segments:
		if folder.is_link(segment):
			return DataResult.failure("玩家关卡目录不能包含符号链接。")
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("玩家关卡目录被同名文件占用。")
			return DataResult.success()
		if folder.change_dir(segment) != OK:
			return DataResult.failure("无法访问玩家关卡文件目录。")
	folder.include_hidden = true
	return DataResult.success(folder)


## 以固定小块计算完整字节指纹，既支持空文件与超限坏文件，也不为其分配巨大缓冲区。
func _fingerprint(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length := file.get_length()
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		file.close()
		return ""
	var remaining := length
	while remaining > 0:
		var chunk := file.get_buffer(mini(remaining, 65536))
		if chunk.is_empty() or hashing.update(chunk) != OK:
			file.close()
			return ""
		remaining -= chunk.size()
	var read_error := file.get_error()
	var stable_length := file.get_length() == length
	file.close()
	if not stable_length or (read_error != OK and read_error != ERR_FILE_EOF):
		return ""
	return "%d:%s" % [length, hashing.finish().hex_encode()]


## 单独读取内置地图 ID，仅用于重复诊断，文件管理绝不取得内置路径的写权限。
func _builtin_ids() -> Dictionary:
	var result: Dictionary = {}
	var folder := DirAccess.open("res://data/levels")
	if folder == null:
		return result
	for filename in folder.get_files():
		if filename.get_extension().to_lower() != "json":
			continue
		var parsed := DataValidation.read_json_object("res://data/levels".path_join(filename))
		if parsed.is_ok() and DataValidation.is_id(parsed.value.get("id")):
			result[parsed.value.id] = true
	return result


## 原生文件系统出生时间是真实创建时间；不支持的平台或失败读取统一返回未知。
func _creation_time(path: String) -> int:
	var arguments: PackedStringArray
	if OS.get_name() == "macOS":
		arguments = PackedStringArray(["-f", "%B", ProjectSettings.globalize_path(path)])
	elif OS.get_name() in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		arguments = PackedStringArray(["-c", "%W", ProjectSettings.globalize_path(path)])
	else:
		return 0
	if not FileAccess.file_exists("/usr/bin/stat"):
		return 0
	var output: Array = []
	if OS.execute("/usr/bin/stat", arguments, output, false) != 0 or output.is_empty():
		return 0
	var value := str(output[0]).strip_edges()
	return maxi(int(value), 0) if value.is_valid_int() else 0


## Windows 按目录一次读取 CreationTimeUtc，编码固定脚本并转义 LiteralPath，文件名不会成为命令。
func _windows_creation_times(absolute_directory: String) -> Dictionary:
	var literal := absolute_directory.replace("'", "''")
	var source := "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); $ErrorActionPreference = 'Stop'; $dates = @{}; Get-ChildItem -LiteralPath '%s' -File -Force | ForEach-Object { $dates[$_.Name] = ([DateTimeOffset]$_.CreationTimeUtc).ToUnixTimeSeconds() }; ConvertTo-Json -InputObject $dates -Compress" % literal
	var encoded := Marshalls.raw_to_base64(source.to_utf16_buffer())
	var output: Array = []
	if OS.execute("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]), output, false) != 0 or output.is_empty():
		return {}
	var parser := JSON.new()
	if parser.parse(str(output[0]).strip_edges()) != OK or not parser.data is Dictionary:
		return {}
	var result: Dictionary = {}
	for filename: String in parser.data:
		var value: Variant = parser.data[filename]
		if DataValidation.is_integer(value, 1, 253402300799):
			result[filename] = int(value)
	return result


## 原子写盘保持草稿兼容，独立入口允许回归模拟系统写入失败。
func _write_document(document: MapDocument, path: String, content: ContentRegistry) -> DataResult:
	return MapCodec.save_file(document, path, content, false)


## 删除仅操作已验证的绝对路径，独立入口允许验证拒绝删除时的状态保留。
func _remove_file(path: String) -> Error:
	return DirAccess.remove_absolute(path)
