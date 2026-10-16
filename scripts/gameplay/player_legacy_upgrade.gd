class_name PlayerLegacyUpgrade
extends RefCounted
## 旧目录升级只提示一次；用户明确放弃或全部迁移完成后安全退役，永不触碰新目录。

const DEFAULT_STATE_DIRECTORY := "user://player_saves_upgrade"
const MAX_STATE_BYTES := 16 * 1024 * 1024
var source_directory: String = "user://levels"
var target_directory: String = ""
var journal_path: String = PlayerLevelMigration.DEFAULT_JOURNAL
var state_directory: String = DEFAULT_STATE_DIRECTORY


## 已退役时不再扫描旧目录；空目录直接退役，其余仅统计未迁移文件和一次提示状态。
func inspect() -> DataResult:
	var retired := _read_marker("retired")
	if not retired.is_ok():
		return retired
	if not retired.value.is_empty():
		return DataResult.success({"needs_notice": false, "retired": true, "pending_count": 0})
	# 已提交的冻结清理意图代表此前明确授权；重启继续它，不再依赖已隐藏的一次询问入口。
	var cleanup := _read_marker("cleanup")
	if not cleanup.is_ok():
		return cleanup
	if not cleanup.value.is_empty():
		var resumed := _cleanup_snapshot(cleanup.value)
		return DataResult.success({"needs_notice": false, "retired": true, "pending_count": 0}) if resumed.is_ok() else resumed
	var snapshot := _snapshot_source()
	if not snapshot.is_ok():
		return snapshot
	if snapshot.value.is_empty():
		var finished := _finish_empty_source()
		return DataResult.success({"needs_notice": false, "retired": true, "pending_count": 0}) if finished.is_ok() else finished
	var pending := PlayerLevelMigration.new().pending_files(source_directory, target_directory, journal_path)
	if not pending.is_ok():
		return pending
	if pending.value.is_empty():
		var finished := retire_if_migrated()
		return DataResult.success({"needs_notice": false, "retired": bool(finished.value), "pending_count": 0}) if finished.is_ok() else finished
	var prompted := _read_marker("prompted")
	if not prompted.is_ok():
		return prompted
	return DataResult.success({"needs_notice": prompted.value.is_empty(), "retired": false, "pending_count": pending.value.size()})


## 展示首次询问前持久化提示标记；关闭或暂不处理不会触发任何旧地图删除。
func mark_prompted() -> DataResult:
	var retired := _read_marker("retired")
	if not retired.is_ok() or not retired.value.is_empty():
		return retired if not retired.is_ok() else DataResult.success()
	return _write_marker("prompted", _marker("prompted"))


## 所有当前旧文件均有已完成记录且字节未变才清理备份；新副本后续修改或删除不影响完成事实。
func retire_if_migrated() -> DataResult:
	var retired := _read_marker("retired")
	if not retired.is_ok():
		return retired
	if not retired.value.is_empty():
		return DataResult.success(true)
	var snapshot := _snapshot_source()
	if not snapshot.is_ok():
		return snapshot
	if snapshot.value.is_empty():
		var finished := _finish_empty_source()
		return DataResult.success(true) if finished.is_ok() else finished
	var completed := PlayerLevelMigration.new().completed_files(source_directory, target_directory, journal_path)
	if not completed.is_ok():
		return completed
	for filename: String in snapshot.value:
		if not completed.value.has(filename):
			return DataResult.success(false)
		if completed.value[filename].sha256 != snapshot.value[filename]:
			return DataResult.failure("已迁移的旧关卡内容发生变化，未删除原文件：%s。" % source_directory.path_join(filename))
	var intent := _cleanup_intent("migrated", snapshot.value)
	if not intent.is_ok():
		return intent
	var cleaned := _cleanup_snapshot(intent.value)
	return DataResult.success(true) if cleaned.is_ok() else cleaned


## 仅供明确选择放弃并删除后调用；冻结当前直接 JSON 列表，坏 JSON 也按原始文件删除。
func discard() -> DataResult:
	var retired := _read_marker("retired")
	if not retired.is_ok() or not retired.value.is_empty():
		return retired if not retired.is_ok() else DataResult.success()
	var snapshot := _snapshot_source()
	if not snapshot.is_ok():
		return snapshot
	var intent := _cleanup_intent("discard", snapshot.value)
	if not intent.is_ok():
		return intent
	return _cleanup_snapshot(intent.value)


## 持久化首次清理意图使部分删除失败可重试，后续新增或替换文件不能进入旧授权快照。
func _cleanup_intent(mode: String, files: Dictionary) -> DataResult:
	var previous := _read_marker("cleanup")
	if not previous.is_ok():
		return previous
	if not previous.value.is_empty():
		return previous
	var value := _marker("cleanup")
	value["mode"] = mode
	value["files"] = files.duplicate(true)
	var saved := _write_marker("cleanup", value)
	return DataResult.success(value) if saved.is_ok() else saved


## 删除前核对全部现存文件，每次删除再次校验原始摘要；任何错误都不提交退役标记。
func _cleanup_snapshot(intent: Dictionary) -> DataResult:
	var current := _snapshot_source()
	if not current.is_ok():
		return current
	for filename: String in current.value:
		if not intent.files.has(filename) or intent.files[filename] != current.value[filename]:
			return DataResult.failure("旧关卡目录在清理过程中发生变化，请检查原文件后重试。")
	var names: Array = current.value.keys()
	names.sort()
	for filename: String in names:
		var fingerprint := _source_hash(filename)
		if not fingerprint.is_ok():
			return fingerprint
		if fingerprint.value != intent.files[filename]:
			return DataResult.failure("旧关卡目录在清理过程中发生变化，请检查原文件后重试。")
		var removed := _remove_source_path(ProjectSettings.globalize_path(source_directory.path_join(filename)))
		if removed != OK:
			return DataResult.failure("无法删除旧关卡：%s（%s）。" % [source_directory.path_join(filename), error_string(removed)])
	var remaining := _snapshot_source()
	if not remaining.is_ok():
		return remaining
	if not remaining.value.is_empty():
		return DataResult.failure("旧关卡目录在清理过程中发生变化，请检查原文件后重试。")
	return _finish_empty_source()


## 只删除已经为空的旧关卡目录本身，非 JSON 文件和子目录原样保留且永不递归。
func _finish_empty_source() -> DataResult:
	var remaining := _snapshot_source()
	if not remaining.is_ok():
		return remaining
	if not remaining.value.is_empty():
		return DataResult.failure("旧关卡目录在清理过程中发生变化，请检查原文件后重试。")
	var opened := _source_folder()
	if not opened.is_ok():
		return opened
	var folder := opened.value as DirAccess
	if folder != null:
		if folder.list_dir_begin() != OK:
			return DataResult.failure("无法枚举旧玩家关卡目录：%s。" % source_directory)
		var empty := folder.get_next().is_empty()
		folder.list_dir_end()
		if empty:
			var removed := _remove_source_path(ProjectSettings.globalize_path(source_directory))
			if removed != OK:
				return DataResult.failure("无法删除空旧关卡目录：%s。" % error_string(removed))
	return _write_marker("retired", _marker("retired"))


## 旧目录只允许固定旧位置或隔离测试子目录，任何目录链接、同名文件及来源目标重叠均拒绝。
func _source_folder() -> DataResult:
	if not source_directory.begins_with("user://") or not PlayerLevelPaths.is_allowed_directory(source_directory, true):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if not target_directory.is_empty():
		var source := ProjectSettings.globalize_path(source_directory)
		var target := ProjectSettings.globalize_path(target_directory)
		if _overlap(source, target):
			return DataResult.failure("旧关卡目录不能与新保存目录重叠。")
	return PlayerLevelPaths.open_directory(source_directory, false, true)


## 不解析地图正文，只冻结安全直接 JSON 的字节摘要，排除链接、目录和不稳定读取。
func _snapshot_source() -> DataResult:
	var opened := _source_folder()
	if not opened.is_ok():
		return opened
	var files: Dictionary = {}
	var folder := opened.value as DirAccess
	if folder == null:
		return DataResult.success(files)
	if folder.list_dir_begin() != OK:
		return DataResult.failure("无法枚举旧玩家关卡目录：%s。" % source_directory)
	var filename := folder.get_next()
	while not filename.is_empty():
		if filename.get_extension().to_lower() == "json":
			if not _safe_filename(filename) or folder.is_link(filename) or folder.current_is_dir():
				folder.list_dir_end()
				return DataResult.failure("旧关卡清理不能包含目录或符号链接：%s。" % source_directory.path_join(filename))
			var fingerprint := _source_hash(filename)
			if not fingerprint.is_ok():
				folder.list_dir_end()
				return fingerprint
			files[filename] = fingerprint.value
		filename = folder.get_next()
	folder.list_dir_end()
	return DataResult.success(files)


## 每次摘要读取前后重验父目录与直接文件，空文件仍有真实 SHA256。
func _source_hash(filename: String) -> DataResult:
	var opened := _source_folder()
	if not opened.is_ok():
		return opened
	var folder := opened.value as DirAccess
	if folder == null or not _safe_filename(filename) or folder.is_link(filename) or folder.dir_exists(filename) or not folder.file_exists(filename):
		return DataResult.failure("无法安全读取待清理的旧关卡：%s。" % source_directory.path_join(filename))
	var path := source_directory.path_join(filename)
	var fingerprint := FileAccess.get_sha256(path)
	opened = _source_folder()
	if not opened.is_ok():
		return opened
	folder = opened.value as DirAccess
	if folder == null or folder.is_link(filename) or folder.dir_exists(filename) or not _is_hash(fingerprint) or FileAccess.get_sha256(path) != fingerprint:
		return DataResult.failure("旧关卡目录在清理过程中发生变化，请检查原文件后重试。")
	return DataResult.success(fingerprint)


## 升级标记位于独立的安全 user:// 目录，不能放入旧地图、新地图或游玩记录目录。
func _state_folder(create: bool = false) -> DataResult:
	if not source_directory.begins_with("user://") or not PlayerLevelPaths.is_allowed_directory(source_directory, true):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if not DataValidation.is_resource_path(state_directory) or not state_directory.begins_with("user://"):
		return DataResult.failure("旧关卡升级标记目录无效。")
	var segments := state_directory.trim_prefix("user://").split("/")
	if state_directory != DEFAULT_STATE_DIRECTORY and not (segments.size() >= 3 and segments[0] == "tests"):
		return DataResult.failure("旧关卡升级标记目录无效。")
	if segments[-1] in ["settings", "solutions", "data", "levels"]:
		return DataResult.failure("旧关卡升级标记目录无效。")
	var absolute := ProjectSettings.globalize_path(state_directory)
	if _overlap(absolute, ProjectSettings.globalize_path(source_directory)) or (not target_directory.is_empty() and _overlap(absolute, ProjectSettings.globalize_path(target_directory))):
		return DataResult.failure("旧关卡升级标记不能放在关卡目录内。")
	return PlayerLevelPaths.open_directory(state_directory, create)


## 首次创建后不再改写的标记绑定来源，格式损坏时保留原件并明确阻止破坏性操作。
func _read_marker(kind: String) -> DataResult:
	var opened := _state_folder()
	if not opened.is_ok():
		return opened
	var folder := opened.value as DirAccess
	if folder == null:
		return DataResult.success({})
	var filename := kind + ".json"
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("旧关卡升级标记不能是目录或符号链接。")
	if not folder.file_exists(filename):
		return DataResult.success({})
	var file := FileAccess.open(state_directory.path_join(filename), FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取旧关卡升级标记。")
	if file.get_length() > MAX_STATE_BYTES:
		file.close()
		return DataResult.failure("旧关卡升级标记损坏或版本不受支持，原文件保持不变。")
	var parser := JSON.new()
	var parsed_ok := parser.parse(file.get_as_text()) == OK
	file.close()
	var parsed: Variant = parser.data
	if not parsed_ok or not parsed is Dictionary or not DataValidation.is_integer(parsed.get("format_version"), 1, 1) or parsed.get("source_directory") != source_directory or parsed.get("kind") != kind:
		return DataResult.failure("旧关卡升级标记损坏或版本不受支持，原文件保持不变。")
	if kind == "cleanup":
		if not parsed.get("mode") in ["discard", "migrated"] or not parsed.get("files") is Dictionary:
			return DataResult.failure("旧关卡升级标记损坏或版本不受支持，原文件保持不变。")
		for filename_key: Variant in parsed.files:
			if not filename_key is String or not _safe_filename(filename_key) or not _is_hash(parsed.files[filename_key]):
				return DataResult.failure("旧关卡升级标记损坏或版本不受支持，原文件保持不变。")
	return DataResult.success(parsed)


## 新标记写入随机临时文件并回读后改名到尚不存在的目标，Windows 不依赖覆盖式改名。
func _write_marker(kind: String, value: Dictionary) -> DataResult:
	var expected: Dictionary = JSON.parse_string(JSON.stringify(value))
	var existing := _read_marker(kind)
	if not existing.is_ok():
		return existing
	if not existing.value.is_empty():
		return DataResult.success() if existing.value == expected else DataResult.failure("旧关卡升级标记已改变，请重试。")
	var opened := _state_folder(true)
	if not opened.is_ok():
		return opened
	var path := state_directory.path_join(kind + ".json")
	var temporary := path + ".%d.%d.%s.tmp" % [OS.get_process_id(), Time.get_ticks_usec(), Crypto.new().generate_random_bytes(8).hex_encode()]
	var text := JSON.stringify(value, "\t", false) + "\n"
	if text.to_utf8_buffer().size() > MAX_STATE_BYTES:
		return DataResult.failure("旧关卡升级标记过大，未删除旧文件。")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return DataResult.failure("无法写入旧关卡升级标记。")
	file.store_string(text)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or JSON.parse_string(FileAccess.get_file_as_string(temporary)) != expected:
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("旧关卡升级标记写入或回读失败。")
	existing = _read_marker(kind)
	if not existing.is_ok() or not existing.value.is_empty():
		DirAccess.remove_absolute(temporary)
		return existing if not existing.is_ok() else (DataResult.success() if existing.value == expected else DataResult.failure("旧关卡升级标记已改变，请重试。"))
	var renamed := _rename_marker(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))
	if renamed != OK:
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("无法提交旧关卡升级标记：%s。" % error_string(renamed))
	return DataResult.success()


## 所有标记最小元数据相同，来源绑定防止测试或错误配置复用其他目录的退役事实。
func _marker(kind: String) -> Dictionary:
	return {"format_version": 1, "source_directory": source_directory, "kind": kind}


## 路径边界按完整目录段比较，拒绝来源、目标与标记目录相互包含。
func _overlap(left: String, right: String) -> bool:
	return left == right or left.begins_with(right + "/") or right.begins_with(left + "/")


## JSON 文件名必须为单个普通段，不能携带上级跳转或控制字符。
func _safe_filename(filename: String) -> bool:
	if filename.is_empty() or filename.get_file() != filename or filename.contains("\\") or filename.contains(":") or filename in [".", ".."] or filename.get_extension().to_lower() != "json":
		return false
	for character: String in filename:
		if character.unicode_at(0) < 32:
			return false
	return true


## 摘要仅接受固定长度小写十六进制，不将缺失值或错误文字当成源文件身份。
func _is_hash(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for character: String in value:
		if not character in "0123456789abcdef":
			return false
	return true


## 删除边界可由隔离测试注入失败，正式实现始终只接收已验证的旧目录绝对路径。
func _remove_source_path(path: String) -> Error:
	return DirAccess.remove_absolute(path)


## 标记改名边界用于验证 Windows 不允许覆盖的行为与提交失败重试。
func _rename_marker(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)
