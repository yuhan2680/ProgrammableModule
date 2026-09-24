class_name GameDraftStore
extends RefCounted
## 玩家程序和装配单独保存，不修改地图；通关进度使用独立文件。

var directory: String = "user://solutions"


## 可注入独立存储目录，方便无窗口测试与多个存档槽扩展。
func _init(storage_directory: String = "user://solutions") -> void:
	directory = storage_directory


## 保存尚未运行的玩家草稿，允许空程序及空装配以支持继续编辑。
func save_draft(level_id: String, source: String, modules: Array) -> DataResult:
	var validation := _validate_draft(level_id, source, modules)
	if not validation.is_ok():
		return validation
	var data := {
		"format_version": 1, "level_id": level_id,
		"source": source, "modules": modules.duplicate(true),
	}
	return _save_json(_path(level_id, "draft"), data)


## 读取草稿并校验磁盘内容；没有草稿时成功返回 null，不伪造保存状态。
func load_draft(level_id: String) -> DataResult:
	var key_result := _validate_storage(level_id)
	if not key_result.is_ok():
		return key_result
	var path := _path(level_id, "draft")
	if not FileAccess.file_exists(path):
		return DataResult.success()
	var result := DataValidation.read_json_object(path)
	if not result.is_ok():
		return result
	var data: Dictionary = result.value
	if not DataValidation.is_integer(data.get("format_version"), 1, 1) or data.get("level_id") != level_id:
		return DataResult.failure("玩家草稿版本或关卡 ID 不匹配：%s。" % path)
	var validation := _validate_draft(level_id, data.get("source"), data.get("modules"))
	if not validation.is_ok():
		return DataResult.failure("%s：%s" % [path, "; ".join(validation.errors)])
	return DataResult.success(data.duplicate(true))


## 原样备份已有草稿；即使 JSON 已损坏，也保留其全部字节供用户恢复。
func backup_draft(level_id: String) -> DataResult:
	var validation := _validate_storage(level_id)
	if not validation.is_ok():
		return validation
	var source_path := ProjectSettings.globalize_path(_path(level_id, "draft"))
	if not FileAccess.file_exists(source_path):
		return DataResult.success()
	# 哈希直接读取文件字节，不经过 JSON 解析、字符解码或重新序列化。
	var original_hash := FileAccess.get_sha256(source_path)
	if original_hash.is_empty():
		return DataResult.failure("无法读取待备份的玩家草稿：%s。" % source_path)
	var path_result := _recovery_path(source_path)
	if not path_result.is_ok():
		return path_result
	var backup_path: String = path_result.value
	var copy_error := DirAccess.copy_absolute(source_path, backup_path)
	if copy_error != OK:
		DirAccess.remove_absolute(backup_path)
		return DataResult.failure("草稿恢复备份失败，原文件保持不变：%s。" % error_string(copy_error))
	# 同时复核源文件，若复制期间源文件被其它进程修改则拒绝宣称备份成功。
	if FileAccess.get_sha256(backup_path) != original_hash or FileAccess.get_sha256(source_path) != original_hash:
		DirAccess.remove_absolute(backup_path)
		return DataResult.failure("草稿恢复备份校验失败，原文件保持不变。")
	return DataResult.success(backup_path)


## 在原目录生成独立恢复文件名，先排除已有文件和目录，绝不复用旧备份名。
func _recovery_path(source_path: String) -> DataResult:
	var random := Crypto.new()
	for _attempt in range(16):
		var nonce := random.generate_random_bytes(16).hex_encode()
		if nonce.is_empty():
			return DataResult.failure("无法生成唯一的草稿恢复备份名称。")
		var suffix := "%d.%d.%s" % [OS.get_process_id(), Time.get_ticks_usec(), nonce]
		var path := "%s.recovery.%s.json" % [source_path.get_basename(), suffix]
		if not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path):
			return DataResult.success(path)
	return DataResult.failure("无法找到未占用的草稿恢复备份路径。")


## 只记录指定关卡的通关事实，不覆盖其程序或装配草稿。
func mark_completed(level_id: String) -> DataResult:
	var validation := _validate_storage(level_id)
	if not validation.is_ok():
		return validation
	return _save_json(_path(level_id, "progress"), {"format_version": 1, "level_id": level_id, "completed": true, "failure_streak": 0})


## 提示门槛按关卡保存；旧进度没有计数时默认为零，不主动改写磁盘。
func get_failure_streak(level_id: String) -> int:
	if not _validate_storage(level_id).is_ok():
		return 0
	var path := _path(level_id, "progress")
	if not FileAccess.file_exists(path):
		return 0
	var loaded := DataValidation.read_json_object(path)
	if not loaded.is_ok():
		return 0
	var data: Dictionary = loaded.value
	if not DataValidation.is_integer(data.get("format_version"), 1, 1) or data.get("level_id") != level_id or not data.get("completed") is bool:
		return 0
	var count: Variant = data.get("failure_streak", 0)
	return int(count) if DataValidation.is_integer(count, 0, 1000000) else 0


## 只更新失败次数，保留已完成标志；损坏的进度原件不能被提示功能覆盖。
func save_failure_streak(level_id: String, count: int) -> DataResult:
	var validation := _validate_storage(level_id)
	if not validation.is_ok():
		return validation
	if count < 0 or count > 1000000:
		return DataResult.failure("连续失败次数必须为 0..1000000 的整数。")
	var path := _path(level_id, "progress")
	var data := {"format_version": 1, "level_id": level_id, "completed": false}
	if FileAccess.file_exists(path):
		var loaded := DataValidation.read_json_object(path)
		if not loaded.is_ok():
			return loaded
		data = loaded.value.duplicate(true)
		if not DataValidation.is_integer(data.get("format_version"), 1, 1) or data.get("level_id") != level_id or not data.get("completed") is bool or not DataValidation.is_integer(data.get("failure_streak", 0), 0, 1000000):
			return DataResult.failure("提示记录保存失败：原通关记录格式无效，文件保持不变。")
	data["failure_streak"] = count
	return _save_json(path, data)


## 缺失或损坏的进度不视为已完成，避免无效文件误解锁通关状态。
func is_completed(level_id: String) -> bool:
	if not _validate_storage(level_id).is_ok():
		return false
	var path := _path(level_id, "progress")
	if not FileAccess.file_exists(path):
		return false
	var result := DataValidation.read_json_object(path)
	if not result.is_ok():
		return false
	var data: Dictionary = result.value
	return DataValidation.is_integer(data.get("format_version"), 1, 1) and data.get("level_id") == level_id and data.get("completed") is bool and data["completed"]


## 仅清除调用方明确指定关卡的代码、装配、通关记录及本类生成的草稿恢复文件。
func clear_level_records(level_ids: Array[String]) -> DataResult:
	# 先校验整个批次，不能清到一半才发现后面的 ID 或路径不合法。
	var keys: Dictionary = {}
	for level_id in level_ids:
		var validation := _validate_storage(level_id)
		if not validation.is_ok():
			return validation
		keys[level_id.sha256_text()] = true
	var folder_result := _clear_storage_folder()
	if not folder_result.is_ok():
		return folder_result
	var folder: DirAccess = folder_result.value
	if folder == null or keys.is_empty():
		return DataResult.success()
	var candidates: Array[String] = []
	var list_error := folder.list_dir_begin()
	if list_error != OK:
		return DataResult.failure("无法读取待清除的存档目录：%s。" % error_string(list_error))
	var filename := folder.get_next()
	while not filename.is_empty():
		if _is_level_record_file(filename, keys):
			# 不跟随链接，也不递归删除同名目录；任何异常都在移动首个文件前返回。
			if folder.is_link(filename) or folder.current_is_dir():
				folder.list_dir_end()
				return DataResult.failure("存档路径不是普通文件，未清除任何记录：%s。" % directory.path_join(filename))
			candidates.append(filename)
		filename = folder.get_next()
	folder.list_dir_end()
	if candidates.is_empty():
		return DataResult.success()
	candidates.sort()
	return _clear_record_files(folder, candidates)


## 校验完整目录链，拒绝通过 user:// 内的符号链接访问其它目录；缺失目录不创建。
func _clear_storage_folder() -> DataResult:
	var validation := _validate_storage("clear_records")
	if not validation.is_ok():
		return validation
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问玩家存档根目录：%s。" % error_string(DirAccess.get_open_error()))
	for segment in directory.trim_prefix("user://").split("/"):
		if folder.is_link(segment):
			return DataResult.failure("玩家存档目录不能包含符号链接，未清除任何记录：%s。" % directory)
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("玩家存档目录被同名文件占用，未清除任何记录：%s。" % directory)
			return DataResult.success()
		var change_error := folder.change_dir(segment)
		if change_error != OK:
			return DataResult.failure("无法访问待清除的存档目录：%s。" % error_string(change_error))
	folder.include_hidden = true
	return DataResult.success(folder)


## 文件所有权只由完整哈希键与既有命名格式确定，损坏 JSON 也可清除而不会扩大范围。
func _is_level_record_file(filename: String, keys: Dictionary) -> bool:
	if filename.length() < 64 or not keys.has(filename.left(64)):
		return false
	var suffix := filename.substr(64)
	if suffix in [".draft.json", ".progress.json"]:
		return true
	if not suffix.begins_with(".draft.recovery.") or not suffix.ends_with(".json"):
		return false
	var parts := suffix.trim_prefix(".draft.recovery.").trim_suffix(".json").split(".")
	if parts.size() != 3 or not parts[0].is_valid_int() or not parts[1].is_valid_int() or parts[2].length() != 32:
		return false
	for character in parts[2]:
		if not character in "0123456789abcdef":
			return false
	return true


## 所有候选文件先改名暂存；暂存失败会恢复已移动文件，成功后删除暂存文件，不留恢复副本。
func _clear_record_files(folder: DirAccess, filenames: Array[String]) -> DataResult:
	var nonce := Crypto.new().generate_random_bytes(16).hex_encode()
	if nonce.is_empty():
		return DataResult.failure("无法生成存档清除临时目录，未清除任何记录。")
	var staging_name := ".clear_records_%s" % nonce
	# make_dir 不复用已有目录，避免把不属于本次操作的内容当作临时记录。
	var create_error := folder.make_dir(staging_name)
	if create_error != OK:
		return DataResult.failure("无法创建存档清除临时目录，未清除任何记录：%s。" % error_string(create_error))
	var absolute := ProjectSettings.globalize_path(folder.get_current_dir())
	var staging_path := absolute.path_join(staging_name)
	var staged: Array[String] = []
	for filename in filenames:
		# 紧邻改名再次检查，避免校验后出现链接或同名目录时将其移走。
		var move_error := ERR_FILE_BAD_PATH
		if not folder.is_link(filename) and not folder.dir_exists(filename) and folder.file_exists(filename):
			move_error = _rename_clear_file(absolute.path_join(filename), staging_path.path_join(filename))
		if move_error != OK:
			var rollback := _restore_clear_files(absolute, staging_path, staged)
			if not rollback.is_ok():
				return rollback
			return DataResult.failure("无法暂存待清除的记录，原记录已恢复：%s（%s）。" % [filename, error_string(move_error)])
		staged.append(filename)
	# 删除阶段无法撤销已删除的文件；失败时归还其余文件，使下一次重试仍能处理它们。
	for index in staged.size():
		var filename := staged[index]
		var remove_error := _remove_clear_file(staging_path.path_join(filename))
		if remove_error != OK:
			var rollback := _restore_clear_files(absolute, staging_path, staged.slice(index))
			if not rollback.is_ok():
				return rollback
			return DataResult.failure("清除未完成：已清除 %d 个文件，其余记录已恢复原位置。请检查目录权限后重试（%s）。" % [index, error_string(remove_error)])
	var cleanup_error := DirAccess.remove_absolute(staging_path)
	if cleanup_error != OK:
		return DataResult.failure("记录已清除，但临时目录未能清理：%s（%s）。" % [staging_path, error_string(cleanup_error)])
	return DataResult.success()


## 暂存失败时逆序归还记录；如目标被其它程序重建则保留暂存原件并报告位置，不覆盖新数据。
func _restore_clear_files(absolute: String, staging_path: String, filenames: Array[String]) -> DataResult:
	for index in range(filenames.size() - 1, -1, -1):
		var filename := filenames[index]
		var destination := absolute.path_join(filename)
		var folder := DirAccess.open(absolute)
		if folder == null or folder.file_exists(filename) or folder.dir_exists(filename) or folder.is_link(filename):
			return DataResult.failure("记录恢复路径被占用，原记录保留于：%s。" % staging_path)
		if _rename_clear_file(staging_path.path_join(filename), destination) != OK:
			return DataResult.failure("记录暂存与恢复失败，未删除的原记录保留于：%s。" % staging_path)
	if DirAccess.remove_absolute(staging_path) != OK:
		return DataResult.failure("原记录已恢复，但临时目录未能清理：%s。" % staging_path)
	return DataResult.success()


## 集中处理暂存与回滚的同目录改名，回归测试可模拟任意一次磁盘失败。
func _rename_clear_file(source_path: String, destination_path: String) -> Error:
	return DirAccess.rename_absolute(source_path, destination_path)


## 清理成功后不保留恢复副本；独立接口允许验证删除失败不会被误报成功。
func _remove_clear_file(path: String) -> Error:
	return DirAccess.remove_absolute(path)


## 存储键允许任意非空文本，通过 SHA-256 映射为固定文件名以隔离路径。
func _path(level_id: String, kind: String) -> String:
	return directory.path_join("%s.%s.json" % [level_id.sha256_text(), kind])


## 用户数据始终写在受控 user:// 目录，调用方不能借目录参数跳出存储根。
func _validate_storage(level_id: Variant) -> DataResult:
	if not DataValidation.is_text(level_id, false):
		return DataResult.failure("存档关卡 ID 必须是非空字符串，最多 65536 字符。")
	if not directory.begins_with("user://") or not DataValidation.is_resource_path(directory):
		return DataResult.failure("玩家草稿目录必须是安全的 user:// 路径。")
	return DataResult.success()


## 磁盘草稿检查基本结构；关卡限制和重叠关系由装配模型再次校验。
func _validate_draft(level_id: Variant, source: Variant, modules: Variant) -> DataResult:
	var storage := _validate_storage(level_id)
	if not storage.is_ok():
		return storage
	if not DataValidation.is_text(source):
		return DataResult.failure("程序必须是最多 65536 字符的字符串。")
	if not modules is Array or modules.size() > 256 or not DataValidation.is_json_value(modules):
		return DataResult.failure("草稿装配必须是最多 256 个模块的有效 JSON 数组。")
	var used: Dictionary = {}
	for instance in modules:
		if not instance is Dictionary or not AssemblyModel.is_instance_name(instance.get("id")) or not DataValidation.is_id(instance.get("module_id")):
			return DataResult.failure("草稿模块必须具有有效的实例名和模块 ID。")
		if used.has(instance.id):
			return DataResult.failure("草稿模块名称重复：%s。" % instance.id)
		used[instance.id] = true
		var offset: Variant = instance.get("offset")
		if not DataValidation.is_position(offset):
			return DataResult.failure("草稿模块偏移必须是有限数值坐标。")
		for axis in ["x", "y"]:
			var coordinate := float(offset[axis])
			if absf(coordinate) > AssemblyModel.MAX_OFFSET or coordinate / AssemblyModel.GRID_STEP != round(coordinate / AssemblyModel.GRID_STEP):
				return DataResult.failure("草稿模块偏移须位于 -4..4，且以 0.5 格为步长。")
	return DataResult.success()


## 写入同目录临时文件并回读后才替换，验证失败不会触碰已有存档。
func _save_json(path: String, data: Dictionary) -> DataResult:
	var source := JSON.stringify(data, "\t", false) + "\n"
	if source.to_utf8_buffer().size() > DataValidation.MAX_FILE_BYTES:
		return DataResult.failure("玩家存档超过 8 MiB 上限。")
	var absolute := ProjectSettings.globalize_path(path)
	var folder_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if folder_error != OK:
		return DataResult.failure("无法创建玩家存档目录：%s。" % error_string(folder_error))
	var suffix := ".%d.%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var temporary := absolute + suffix + ".tmp"
	var backup := absolute + suffix + ".bak"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return DataResult.failure("无法创建临时存档：%s。" % error_string(FileAccess.get_open_error()))
	file.store_string(source)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("玩家存档写入失败：%s。" % error_string(write_error))
	var readback := DataValidation.read_json_object(temporary)
	if not readback.is_ok() or readback.value != JSON.parse_string(source):
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("临时存档回读校验失败，原存档保持不变。")
	return _replace_file(temporary, absolute, backup)


## 替换失败时恢复旧文件，无法恢复时保留备份并返回其确切位置。
func _replace_file(temporary: String, destination: String, backup: String) -> DataResult:
	var had_original := FileAccess.file_exists(destination)
	if had_original:
		var backup_error := DirAccess.rename_absolute(destination, backup)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary)
			return DataResult.failure("无法备份原存档：%s。" % error_string(backup_error))
	var replace_error := DirAccess.rename_absolute(temporary, destination)
	if replace_error != OK:
		var restore_error := OK
		if had_original:
			restore_error = DirAccess.rename_absolute(backup, destination)
		DirAccess.remove_absolute(temporary)
		if restore_error != OK:
			return DataResult.failure("存档替换和恢复均失败，原文件保留于：%s。" % backup)
		return DataResult.failure("无法替换玩家存档，原文件已保留。")
	if had_original and DirAccess.remove_absolute(backup) != OK:
		push_warning("玩家存档已保存，但无法删除备份：%s。" % backup)
	return DataResult.success(destination)
