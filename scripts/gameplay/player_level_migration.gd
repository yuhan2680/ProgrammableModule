class_name PlayerLevelMigration
extends RefCounted
## 旧玩家关卡只复制原始字节；逐文件检查点使迁移可重试，完成后不再复活已删除的关卡。

const DEFAULT_JOURNAL := "user://player_saves_migration.json"
const JOURNAL_VERSION := 1
const MAX_JOURNAL_BYTES := 16 * 1024 * 1024
const COPY_CHUNK_BYTES := 64 * 1024
const MAX_REVISION := 2147483647
var _journal_fingerprints: Dictionary = {}
var _journal_snapshot: Dictionary = {}
var _journal_bytes := PackedByteArray()


## 只处理旧目录的直接 JSON，成功值为本次实际新增的文件数量，不修改任何旧文件或 JSON 内容。
func prepare(source_directory: String, target_directory: String, journal_path: String = DEFAULT_JOURNAL) -> DataResult:
	if not _allowed_source(source_directory):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if ProjectSettings.globalize_path(journal_path.get_base_dir()) in [ProjectSettings.globalize_path(source_directory), ProjectSettings.globalize_path(target_directory)]:
		return DataResult.failure("玩家关卡迁移记录不能放在关卡目录内。")
	var journal_folder := _journal_directory(journal_path, false)
	if not journal_folder.is_ok():
		return journal_folder
	var target := PlayerLevelPaths.open_directory(target_directory, true, true)
	if not target.is_ok():
		return target
	var loaded := _read_journal(journal_path, source_directory, target_directory)
	if not loaded.is_ok():
		return loaded
	var journal: Dictionary = loaded.value
	if journal.complete:
		return DataResult.success(0)
	var listed := _source_files(source_directory)
	if not listed.is_ok():
		return listed
	for pending_name: String in journal.files:
		if not journal.files[pending_name].done and not pending_name in listed.value:
			return DataResult.failure("旧玩家关卡目录在迁移过程中发生变化，请重试。")
	var copied := 0
	for filename: String in listed.value:
		# 已提交的单文件检查点也保护中断期间玩家在新目录所做的删除或修改。
		if journal.files.has(filename) and journal.files[filename].done:
			continue
		var source_path := source_directory.path_join(filename)
		var snapshot := _source_snapshot(source_directory, filename)
		if not snapshot.is_ok():
			return snapshot
		var fingerprint: String = snapshot.value
		var entry: Dictionary = journal.files.get(filename, {})
		if not entry.is_empty() and entry.sha256 != fingerprint:
			return DataResult.failure("旧关卡在迁移过程中发生变化，请恢复原文件后重试：%s。" % source_path)
		var selected := _choose_destination(target_directory, filename, fingerprint, entry.get("destination", ""))
		if not selected.is_ok():
			return selected
		entry = {"sha256": fingerprint, "destination": selected.value, "done": false}
		journal.files[filename] = entry
		var saved := _write_journal(journal_path, journal)
		if not saved.is_ok():
			return saved
		var copied_file := _copy_source(source_directory, filename, target_directory, entry.destination, fingerprint)
		if not copied_file.is_ok():
			return copied_file
		copied += int(copied_file.value)
		entry.done = true
		journal.files[filename] = entry
		saved = _write_journal(journal_path, journal)
		if not saved.is_ok():
			return saved
	# 枚举期间若添加或移除旧文件，保留检查点并在重试时重新核对，不能提前宣告完成。
	var after := _source_files(source_directory)
	if not after.is_ok():
		return after
	if after.value != listed.value:
		return DataResult.failure("旧玩家关卡目录在迁移过程中发生变化，请重试。")
	target = PlayerLevelPaths.open_directory(target_directory, false, true)
	if not target.is_ok():
		return target
	if target.value == null:
		return DataResult.failure("玩家关卡目标目录已消失。")
	journal.complete = true
	var finished := _write_journal(journal_path, journal)
	return DataResult.success(copied) if finished.is_ok() else finished


## 列表只读枚举尚未完成的旧文件；空目标表示只核对既有绑定，不访问或创建任何新保存根。
func pending_files(source_directory: String, target_directory: String, journal_path: String = DEFAULT_JOURNAL) -> DataResult:
	if not _allowed_source(source_directory):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if not target_directory.is_empty() and not PlayerLevelPaths.is_allowed_directory(target_directory, true):
		return DataResult.failure("玩家关卡目录不在允许的保存位置。")
	if ProjectSettings.globalize_path(journal_path.get_base_dir()) == ProjectSettings.globalize_path(source_directory):
		return DataResult.failure("玩家关卡迁移记录不能放在关卡目录内。")
	var loaded := _read_journal(journal_path, source_directory, target_directory, false, target_directory.is_empty())
	if not loaded.is_ok():
		return loaded
	var listed := _source_files(source_directory)
	if not listed.is_ok():
		return listed
	var pending := PackedStringArray()
	for filename: String in listed.value:
		if not loaded.value.files.has(filename) or not loaded.value.files[filename].done:
			pending.append(filename)
	return DataResult.success(pending)


## 生命周期只读取当时已验证成功的源指纹；不访问新副本，玩家后续修改或删除不回退迁移事实。
func completed_files(source_directory: String, target_directory: String, journal_path: String = DEFAULT_JOURNAL) -> DataResult:
	if not _allowed_source(source_directory):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if not target_directory.is_empty() and not PlayerLevelPaths.is_allowed_directory(target_directory, true):
		return DataResult.failure("玩家关卡目录不在允许的保存位置。")
	if ProjectSettings.globalize_path(journal_path.get_base_dir()) == ProjectSettings.globalize_path(source_directory):
		return DataResult.failure("玩家关卡迁移记录不能放在关卡目录内。")
	var loaded := _read_journal(journal_path, source_directory, target_directory, false, target_directory.is_empty())
	if not loaded.is_ok():
		return loaded
	var completed: Dictionary = {}
	for filename: String in loaded.value.files:
		var entry: Dictionary = loaded.value.files[filename]
		if entry.done:
			completed[filename] = {"sha256": entry.sha256, "destination": entry.destination, "target_directory": loaded.value.target}
	return DataResult.success(completed)


## 只有显式选择的稳定旧文件才复制；完成检查点保留旧件并使重复点击及目标删除都不会再次导入。
func migrate_file(source_directory: String, target_directory: String, journal_path: String, filename: String, expected_fingerprint: String) -> DataResult:
	if not _safe_json_name(filename) or not _is_hash(expected_fingerprint):
		return DataResult.failure("迁移关卡文件名或内容指纹无效。")
	var loaded := check_target(source_directory, target_directory, journal_path)
	if not loaded.is_ok():
		return loaded
	var snapshot := _source_snapshot(source_directory, filename)
	if not snapshot.is_ok():
		return snapshot
	if snapshot.value != expected_fingerprint:
		return DataResult.failure("旧玩家关卡已改变，请刷新列表后重试：%s。" % source_directory.path_join(filename))
	var journal: Dictionary = loaded.value
	var entry: Dictionary = journal.files.get(filename, {})
	if not entry.is_empty():
		if entry.sha256 != expected_fingerprint:
			return DataResult.failure("旧关卡在迁移过程中发生变化，请恢复原文件后重试：%s。" % source_directory.path_join(filename))
		if entry.done:
			return DataResult.success(target_directory.path_join(entry.destination))
	var target := PlayerLevelPaths.open_directory(target_directory, true, true)
	if not target.is_ok():
		return target
	var selected := _choose_destination(target_directory, filename, expected_fingerprint, entry.get("destination", ""))
	if not selected.is_ok():
		return selected
	journal["manual"] = true
	entry = {"sha256": expected_fingerprint, "destination": selected.value, "done": false}
	journal.files[filename] = entry
	var saved := _write_journal(journal_path, journal)
	if not saved.is_ok():
		return saved
	var copied := _copy_source(source_directory, filename, target_directory, entry.destination, expected_fingerprint)
	if not copied.is_ok():
		return copied
	entry.done = true
	journal.files[filename] = entry
	saved = _write_journal(journal_path, journal)
	return DataResult.success(target_directory.path_join(entry.destination)) if saved.is_ok() else saved


## 目录选择永久保存前只读核对迁移绑定；恢复槽同样参与检查，不创建目录或记录。
func check_target(source_directory: String, target_directory: String, journal_path: String = DEFAULT_JOURNAL) -> DataResult:
	if not _allowed_source(source_directory):
		return DataResult.failure("旧玩家关卡迁移来源不在允许的目录内。")
	if not PlayerLevelPaths.is_allowed_directory(target_directory, true):
		var allowed := PlayerLevelPaths.validate_external_root(target_directory)
		if not allowed.is_ok():
			return allowed
	if ProjectSettings.globalize_path(journal_path.get_base_dir()) in [ProjectSettings.globalize_path(source_directory), ProjectSettings.globalize_path(target_directory)]:
		return DataResult.failure("玩家关卡迁移记录不能放在关卡目录内。")
	return _read_journal(journal_path, source_directory, target_directory, true)


## 正式来源仅旧关卡目录，测试来源必须显式留在独占 user://tests 子目录。
func _allowed_source(directory: String) -> bool:
	return directory.begins_with("user://") and PlayerLevelPaths.is_allowed_directory(directory, true)


## 不递归目录；JSON 位置的目录或链接都明确失败，其他普通资源不参与迁移。
func _source_files(directory: String) -> DataResult:
	var opened := PlayerLevelPaths.open_directory(directory, false, true)
	if not opened.is_ok():
		return opened
	var names := PackedStringArray()
	var folder := opened.value as DirAccess
	if folder == null:
		return DataResult.success(names)
	if folder.list_dir_begin() != OK:
		return DataResult.failure("无法枚举旧玩家关卡目录：%s。" % directory)
	var filename := folder.get_next()
	while not filename.is_empty():
		if filename.get_extension().to_lower() == "json":
			if not _safe_json_name(filename) or folder.is_link(filename) or folder.current_is_dir():
				folder.list_dir_end()
				return DataResult.failure("迁移关卡不能是目录或符号链接：%s。" % directory.path_join(filename))
			names.append(filename)
		filename = folder.get_next()
	folder.list_dir_end()
	names.sort()
	return DataResult.success(names)


## 指纹读取前后都重新验证真实文件和父目录，空文件同样有有效 SHA256。
func _source_snapshot(directory: String, filename: String) -> DataResult:
	var opened := PlayerLevelPaths.open_directory(directory, false, true)
	if not opened.is_ok():
		return opened
	var folder := opened.value as DirAccess
	if folder == null or folder.is_link(filename) or folder.dir_exists(filename) or not folder.file_exists(filename):
		return DataResult.failure("无法安全读取待迁移的旧关卡：%s。" % directory.path_join(filename))
	var path := directory.path_join(filename)
	var fingerprint := FileAccess.get_sha256(path)
	var rechecked := PlayerLevelPaths.open_directory(directory, false, true)
	if not rechecked.is_ok():
		return rechecked
	folder = rechecked.value as DirAccess
	if fingerprint.is_empty() or folder == null or folder.is_link(filename) or folder.dir_exists(filename) or FileAccess.get_sha256(path) != fingerprint:
		return DataResult.failure("旧关卡在读取过程中发生变化：%s。" % path)
	return DataResult.success(fingerprint)


## 同名同字节直接复用，冲突以源摘要生成稳定后缀，断点丢在复制与检查点之间也不会重复导入。
func _choose_destination(directory: String, filename: String, fingerprint: String, planned: String) -> DataResult:
	var opened := PlayerLevelPaths.open_directory(directory, false, true)
	if not opened.is_ok():
		return opened
	var folder := opened.value as DirAccess
	if folder == null:
		return DataResult.failure("玩家关卡目标目录已消失。")
	var candidates: Array[String] = []
	if not planned.is_empty():
		candidates.append(planned)
	if not filename in candidates:
		candidates.append(filename)
	for index in 10000:
		var candidate := candidates[index] if index < candidates.size() else _legacy_name(filename, fingerprint, index - candidates.size())
		if folder.is_link(candidate) or folder.dir_exists(candidate):
			return DataResult.failure("迁移关卡目标不能是目录或符号链接：%s。" % directory.path_join(candidate))
		if not folder.file_exists(candidate):
			return DataResult.success(candidate)
		var existing := FileAccess.get_sha256(directory.path_join(candidate))
		if existing.is_empty():
			return DataResult.failure("无法读取已有玩家关卡：%s。" % directory.path_join(candidate))
		if existing == fingerprint:
			return DataResult.success(candidate)
	return DataResult.failure("无法为旧玩家关卡分配不冲突的迁移文件名。")


## 保留扩展名，限制后缀文件名的 UTF-8 字节数，避免中文长文件名超过系统长度。
func _legacy_name(filename: String, fingerprint: String, index: int) -> String:
	var stem := filename.get_basename()
	while stem.to_utf8_buffer().size() > 180:
		stem = stem.left(stem.length() - 1)
	var suffix := "" if index == 0 else "_" + str(index + 1)
	return "%s_legacy_%s%s.%s" % [stem, fingerprint.left(12), suffix, filename.get_extension()]


## 分块复制不解析或归一化 JSON；回读及源稳定性验证通过后才发布最终文件名。
func _copy_source(source_directory: String, filename: String, target_directory: String, destination_name: String, fingerprint: String) -> DataResult:
	var selected := _choose_destination(target_directory, filename, fingerprint, destination_name)
	if not selected.is_ok():
		return selected
	if selected.value != destination_name:
		return DataResult.failure("迁移目标在写入前已改变，请重试。")
	var destination := target_directory.path_join(destination_name)
	if FileAccess.file_exists(destination):
		var reused := _source_snapshot(source_directory, filename)
		var existing := PlayerLevelPaths.open_directory(target_directory, false, true)
		var existing_folder := existing.value as DirAccess
		if not reused.is_ok() or reused.value != fingerprint or not existing.is_ok() or existing_folder == null or existing_folder.is_link(destination_name) or existing_folder.dir_exists(destination_name) or FileAccess.get_sha256(destination) != fingerprint:
			return DataResult.failure("关卡迁移写入校验失败或来源发生变化，旧文件保持不变：%s。" % filename)
		return DataResult.success(0)
	var temporary := _temporary_path(target_directory, destination_name)
	var source := FileAccess.open(source_directory.path_join(filename), FileAccess.READ)
	if source == null:
		return DataResult.failure("无法读取旧关卡：%s。" % source_directory.path_join(filename))
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		source.close()
		return DataResult.failure("无法创建迁移临时文件：%s。" % temporary)
	var remaining := source.get_length()
	var failed := false
	while remaining > 0:
		var count := mini(remaining, COPY_CHUNK_BYTES)
		var bytes := source.get_buffer(count)
		if bytes.size() != count:
			failed = true
			break
		output.store_buffer(bytes)
		if output.get_error() != OK:
			failed = true
			break
		remaining -= count
	output.flush()
	failed = failed or output.get_error() != OK
	source.close()
	output.close()
	var stable := _source_snapshot(source_directory, filename)
	var target := PlayerLevelPaths.open_directory(target_directory, false, true)
	if failed or FileAccess.get_sha256(temporary) != fingerprint or not stable.is_ok() or stable.value != fingerprint or not target.is_ok():
		_remove_temporary(temporary)
		return DataResult.failure("关卡迁移写入校验失败或来源发生变化，旧文件保持不变：%s。" % filename)
	var folder := target.value as DirAccess
	if folder == null or folder.is_link(destination_name) or folder.dir_exists(destination_name) or folder.file_exists(destination_name):
		_remove_temporary(temporary)
		return DataResult.failure("关卡迁移目标已被占用，请重试：%s。" % destination)
	var renamed := _rename_file(temporary, ProjectSettings.globalize_path(destination))
	if renamed != OK:
		_remove_temporary(temporary)
		return DataResult.failure("无法提交迁移关卡：%s。" % error_string(renamed))
	if FileAccess.get_sha256(destination) != fingerprint:
		return DataResult.failure("迁移关卡提交后的字节校验失败：%s。" % destination)
	stable = _source_snapshot(source_directory, filename)
	if not stable.is_ok() or stable.value != fingerprint:
		return DataResult.failure("关卡迁移写入校验失败或来源发生变化，旧文件保持不变：%s。" % filename)
	return DataResult.success(1)


## 检查点仅允许正式固定文件或隔离测试文件，逐层拒绝链接和目录占位。
func _journal_directory(path: String, create: bool) -> DataResult:
	if not DataValidation.is_resource_path(path) or not (path == DEFAULT_JOURNAL or path.begins_with("user://tests/")) or not _safe_json_name(path.get_file()):
		return DataResult.failure("玩家关卡迁移记录路径无效。")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法打开玩家关卡迁移记录目录。")
	var segments := path.trim_prefix("user://").split("/")
	for index in segments.size():
		var segment := segments[index]
		if folder.is_link(segment):
			return DataResult.failure("玩家关卡迁移记录不能包含符号链接。")
		if index == segments.size() - 1:
			return DataResult.failure("玩家关卡迁移记录被目录占用。") if folder.dir_exists(segment) else DataResult.success(folder)
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("玩家关卡迁移记录目录被文件占用。")
			if not create:
				return DataResult.success()
			if folder.make_dir(segment) != OK:
				return DataResult.failure("无法创建玩家关卡迁移记录目录。")
		if folder.is_link(segment) or folder.change_dir(segment) != OK:
			return DataResult.failure("无法安全打开玩家关卡迁移记录目录。")
	return DataResult.failure("玩家关卡迁移记录路径无效。")


## 两个固定槽都经路径检查；恢复槽不使用 JSON 扩展，且只允许位于主记录同目录。
func _journal_slots(path: String, create: bool = false) -> DataResult:
	var checked := _journal_directory(path, create)
	if not checked.is_ok():
		return checked
	var recovery := path + ".recovery"
	var folder := checked.value as DirAccess
	if folder != null and (folder.is_link(recovery.get_file()) or folder.dir_exists(recovery.get_file())):
		return DataResult.failure("玩家关卡迁移恢复记录不能是目录或符号链接。")
	return DataResult.success(PackedStringArray([path, recovery]))


## 读取双槽中最新且单调推进的完整检查点；损坏、同序列冲突及绑定不一致都明确拒绝。
func _read_journal(path: String, source: String, target: String, explain_target: bool = false, allow_unbound_target: bool = false) -> DataResult:
	_journal_fingerprints.clear()
	_journal_snapshot.clear()
	_journal_bytes = PackedByteArray()
	var slots := _journal_slots(path)
	if not slots.is_ok():
		return slots
	var initial := {"version": JOURNAL_VERSION, "revision": 0, "source": ProjectSettings.globalize_path(source), "target": ProjectSettings.globalize_path(target), "complete": false, "files": {}}
	var records: Array[Dictionary] = []
	for slot: String in slots.value:
		var read := _read_journal_slot(slot, initial.source)
		if not read.is_ok():
			return read
		_journal_fingerprints[slot] = "" if read.value == null else read.value.fingerprint
		if read.value != null:
			records.append(read.value)
	if records.is_empty():
		_journal_snapshot = initial.duplicate(true)
		return DataResult.success(initial)
	var latest: Dictionary = records[0]
	if records.size() == 2:
		var other: Dictionary = records[1]
		if latest.data.source != other.data.source or latest.data.target != other.data.target:
			return DataResult.failure("玩家关卡迁移记录损坏或与当前目录不匹配。")
		if latest.data.revision == other.data.revision:
			if latest.fingerprint != other.fingerprint:
				return DataResult.failure("玩家关卡迁移记录的恢复序列冲突，已保留两份记录。")
		else:
			var older := latest if latest.data.revision < other.data.revision else other
			latest = other if latest.data.revision < other.data.revision else latest
			if not _journal_advances(older.data, latest.data):
				return DataResult.failure("玩家关卡迁移记录的恢复序列冲突，已保留两份记录。")
	if not allow_unbound_target and latest.data.target != initial.target:
		return DataResult.failure("旧关卡已迁移到 %s，请重新选择对应的文稿文件夹。" % latest.data.target) if explain_target else DataResult.failure("玩家关卡迁移记录损坏或与当前目录不匹配。")
	_journal_snapshot = latest.data.duplicate(true)
	_journal_bytes = latest.bytes
	return DataResult.success(latest.data)


## 每个槽独立验证来源、格式、单调序列号和指纹；存在但损坏的槽绝不能当成缺失覆盖。
func _read_journal_slot(path: String, source: String) -> DataResult:
	if not FileAccess.file_exists(path):
		return DataResult.success()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取玩家关卡迁移记录。")
	if file.get_length() > MAX_JOURNAL_BYTES:
		file.close()
		return DataResult.failure("玩家关卡迁移记录过大，已保留原记录。")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var parser := JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK:
		return DataResult.failure("玩家关卡迁移记录损坏或与当前目录不匹配。")
	var data: Variant = parser.data
	if not data is Dictionary or not DataValidation.is_integer(data.get("version"), JOURNAL_VERSION, JOURNAL_VERSION) or not DataValidation.is_integer(data.get("revision", 0), 0, MAX_REVISION) or not data.get("complete") is bool or not data.get("manual", false) is bool or not data.get("files") is Dictionary or data.get("source") != source or not data.get("target") is String or PlayerLevelPaths.platform_default_directory("macOS", data.target, "").is_empty():
		return DataResult.failure("玩家关卡迁移记录损坏或与当前目录不匹配。")
	data["revision"] = int(data.get("revision", 0))
	for filename: Variant in data.files:
		var entry: Variant = data.files[filename]
		if not filename is String or not _safe_json_name(filename) or not entry is Dictionary or not entry.get("sha256") is String or not _is_hash(entry.sha256) or not entry.get("destination") is String or not _safe_json_name(entry.destination) or not entry.get("done") is bool or (data.complete and not data.get("manual", false) and not entry.done):
			return DataResult.failure("玩家关卡迁移记录中的文件条目无效。")
	var fingerprint := _hash(bytes)
	if FileAccess.get_sha256(path) != fingerprint:
		return DataResult.failure("玩家关卡迁移记录已在读取期间改变。")
	return DataResult.success({"data": data, "bytes": bytes, "fingerprint": fingerprint})


## 新检查点可追加计划和完成标记，但不能回退已完成文件、改变源指纹或重开已结束的迁移。
func _journal_advances(previous: Dictionary, current: Dictionary) -> bool:
	if previous.source != current.source or previous.target != current.target:
		return false
	if previous.complete and (not current.complete or (not current.get("manual", false) and current.files != previous.files)):
		return false
	if previous.get("manual", false) and not current.get("manual", false):
		return false
	if current.complete and not current.get("manual", false):
		for entry: Dictionary in current.files.values():
			if not entry.done:
				return false
	for filename: String in previous.files:
		var old: Dictionary = previous.files[filename]
		if not current.files.has(filename) or current.files[filename].sha256 != old.sha256:
			return false
		if old.done and current.files[filename] != old:
			return false
	return true


## 保留双槽避免 Windows 替换时先删除旧目标的空窗；只在两槽均校验成功后报告提交完成。
func _write_journal(path: String, data: Dictionary) -> DataResult:
	var checked := _journal_slots(path, true)
	if not checked.is_ok():
		return checked
	if _journal_snapshot.is_empty() or not _journal_advances(_journal_snapshot, data) or int(_journal_snapshot.revision) >= MAX_REVISION:
		return DataResult.failure("玩家关卡迁移记录的恢复序列冲突，已保留两份记录。")
	var slots: PackedStringArray = checked.value
	for slot: String in slots:
		if FileAccess.get_sha256(slot) != _journal_fingerprints.get(slot, ""):
			return DataResult.failure("玩家关卡迁移记录写入失败或已被外部修改。")
	# 若恢复槽更新或主槽缺失，先复制最新字节回主槽，避免覆盖唯一的最新检查点。
	if not _journal_bytes.is_empty() and _journal_fingerprints.get(path, "") != _hash(_journal_bytes):
		var restored := _commit_journal_slot(path, path, _journal_bytes)
		if not restored.is_ok():
			return restored
	data["revision"] = int(_journal_snapshot.revision) + 1
	var bytes := (JSON.stringify(data, "\t", false) + "\n").to_utf8_buffer()
	if bytes.size() > MAX_JOURNAL_BYTES:
		return DataResult.failure("玩家关卡迁移记录过大，已保留原记录。")
	# 更新恢复槽期间主槽保留旧进度；更新主槽期间恢复槽保留新进度。
	for slot: String in PackedStringArray([slots[1], slots[0]]):
		var committed := _commit_journal_slot(path, slot, bytes)
		if not committed.is_ok():
			return committed
	_journal_snapshot = data.duplicate(true)
	_journal_bytes = bytes
	return DataResult.success()


## 每次槽提交都核对两个已知指纹并回读新字节；改名失败时保留另一个固定槽以供重启恢复。
func _commit_journal_slot(journal_path: String, slot: String, bytes: PackedByteArray) -> DataResult:
	var checked := _journal_slots(journal_path, true)
	if not checked.is_ok():
		return checked
	var temporary := _temporary_path(journal_path.get_base_dir(), slot.get_file())
	var output := FileAccess.open(temporary, FileAccess.WRITE)
	if output == null:
		return DataResult.failure("无法创建玩家关卡迁移记录临时文件。")
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	checked = _journal_slots(journal_path)
	if error != OK or FileAccess.get_sha256(temporary) != _hash(bytes) or not checked.is_ok():
		_remove_temporary(temporary)
		return DataResult.failure("玩家关卡迁移记录写入失败或已被外部修改。")
	for known: String in checked.value:
		if FileAccess.get_sha256(known) != _journal_fingerprints.get(known, ""):
			_remove_temporary(temporary)
			return DataResult.failure("玩家关卡迁移记录写入失败或已被外部修改。")
	var renamed := _rename_file(temporary, ProjectSettings.globalize_path(slot))
	if renamed != OK:
		_remove_temporary(temporary)
		return DataResult.failure("无法提交玩家关卡迁移记录：%s。" % error_string(renamed))
	if FileAccess.get_sha256(slot) != _hash(bytes):
		return DataResult.failure("玩家关卡迁移记录写入失败或已被外部修改。")
	_journal_fingerprints[slot] = _hash(bytes)
	return DataResult.success()


## 检查点中的文件名只能是直接 JSON，不能借恶意记录越出两个已验证目录。
func _safe_json_name(filename: String) -> bool:
	return not filename.is_empty() and filename.get_file() == filename and not filename.contains("\\") and not filename.contains(":") and filename.get_extension().to_lower() == "json" and not filename in [".", ".."]


## 只接受完整小写 SHA256，避免畸形检查点伪造空摘要或文件路径。
func _is_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true


## 摘要直接作用于原始字节，BOM、换行、坏 JSON 和空文件都不归一化。
func _hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


## 临时文件使用非 JSON 扩展及随机后缀，不会出现在关卡列表或下次迁移枚举中。
func _temporary_path(directory: String, filename: String) -> String:
	return ProjectSettings.globalize_path(directory).path_join(".%s.%d.%s.migration-tmp" % [filename.sha256_text().left(16), OS.get_process_id(), Crypto.new().generate_random_bytes(12).hex_encode()])


## 清理仅针对本次分配的普通临时文件，不沿被外部替换的链接删除其他内容。
func _remove_temporary(path: String) -> void:
	var directory := path.get_base_dir()
	var user_root := ProjectSettings.globalize_path("user://").trim_suffix("/")
	var folder: DirAccess
	if directory == user_root:
		folder = DirAccess.open("user://")
	else:
		if directory.begins_with(user_root + "/"):
			directory = "user://" + directory.trim_prefix(user_root + "/")
		var opened := PlayerLevelPaths.open_directory(directory, false)
		if not opened.is_ok():
			return
		folder = opened.value as DirAccess
	if folder != null and not folder.is_link(path.get_file()) and not folder.dir_exists(path.get_file()):
		folder.remove(path.get_file())


## 文件提交集中在系统边界，失败回归可以替换此方法而仍执行真实复制和回读校验。
func _rename_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)
