class_name PlayerRuntimeMigration
extends RefCounted
## 首次升级将旧草稿、进度与档案原样复制到可见目录；原件保留，完成后永久停止读取旧源。

const DESTINATION_MARKER := ".legacy_runtime_migrated.json"
var cache_directory: String
var progress_directory: String
var legacy_solutions: String
var legacy_profile: String
var marker_path: String


## 所有旧源与检查点可注入独占测试路径，正式入口沿用旧版的本机位置。
func _init(cache: String, progress: String, solutions: String = "user://solutions", profile: String = "user://player_profile.json", marker: String = "user://runtime_storage_migration.json") -> void:
	cache_directory = cache
	progress_directory = progress
	legacy_solutions = solutions
	legacy_profile = profile
	marker_path = marker


## 新文件优先且绝不覆盖；只有完整迁移后才发布完成标记，失败由调用方阻止创建默认档案。
func migrate() -> DataResult:
	if not legacy_solutions.begins_with("user://") or not DataValidation.is_resource_path(legacy_solutions) or not legacy_profile.begins_with("user://") or not DataValidation.is_resource_path(legacy_profile) or not marker_path.begins_with("user://") or not DataValidation.is_resource_path(marker_path):
		return DataResult.failure("旧版运行数据迁移只接受安全的本机用户路径。")
	for directory: String in [cache_directory, progress_directory]:
		var opened := PlayerRuntimePaths.open_directory(directory)
		if not opened.is_ok():
			return opened
	var markers: Array[String] = [marker_path, progress_directory.path_join(DESTINATION_MARKER)]
	var completed := false
	for path: String in markers:
		var checked := PlayerRuntimePaths.validate_file(path)
		if not checked.is_ok():
			return checked
		if FileAccess.file_exists(path):
			var loaded := DataValidation.read_json_object(path)
			if not loaded.is_ok() or not _is_marker(loaded.value):
				return DataResult.failure("运行数据迁移检查点无效，旧存档保持不变：%s。" % path)
			completed = true
	if not completed:
		var sources := _source_files()
		if not sources.is_ok():
			return sources
		for item: Dictionary in sources.value:
			var copied := _copy_file(item.source, item.destination)
			if not copied.is_ok():
				return copied
	# 任一有效标记即可阻止旧源复活；补齐另一个标记不再扫描旧目录。
	for path: String in markers:
		if not FileAccess.file_exists(path):
			var written := _write_marker(path)
			if not written.is_ok():
				return written
	return DataResult.success({"cache_directory": cache_directory, "progress_directory": progress_directory})


## 检查点绑定迁移源与目标，避免注入其它目录后误把不相关升级当成已完成。
func _marker_data() -> Dictionary:
	return {"format_version": 1, "completed": true, "legacy_solutions": legacy_solutions, "legacy_profile": legacy_profile, "cache_directory": cache_directory, "progress_directory": progress_directory}


## 只收集旧存储模型拥有的直接文件名，不迁移未知 JSON、目录或递归内容。
func _source_files() -> DataResult:
	var opened := PlayerRuntimePaths.open_directory(legacy_solutions)
	if not opened.is_ok():
		return opened
	var files: Array[Dictionary] = []
	if opened.value != null:
		var folder: DirAccess = opened.value
		var listed := folder.list_dir_begin()
		if listed != OK:
			return DataResult.failure("无法读取旧版运行数据目录。")
		var filename := folder.get_next()
		while not filename.is_empty():
			var kind := _record_kind(filename)
			if not kind.is_empty():
				if folder.is_link(filename) or folder.current_is_dir():
					folder.list_dir_end()
					return DataResult.failure("旧版运行数据不是普通文件，未完成迁移：%s。" % filename)
				var target := progress_directory if kind == "progress" else cache_directory
				files.append({"source": legacy_solutions.path_join(filename), "destination": target.path_join(filename)})
			filename = folder.get_next()
		folder.list_dir_end()
	var checked := PlayerRuntimePaths.validate_file(legacy_profile)
	if not checked.is_ok():
		return checked
	if FileAccess.file_exists(legacy_profile):
		files.append({"source": legacy_profile, "destination": progress_directory.path_join("player_profile.json")})
	return DataResult.success(files)


## 完整 SHA256 键加既有后缀才属于旧版存档，恢复备份同样保留原始字节。
func _record_kind(filename: String) -> String:
	if filename.length() <= 64:
		return ""
	for character in filename.left(64):
		if not character in "0123456789abcdef":
			return ""
	var suffix := filename.substr(64)
	if suffix == ".progress.json":
		return "progress"
	if suffix == ".draft.json":
		return "draft"
	if not suffix.begins_with(".draft.recovery.") or not suffix.ends_with(".json"):
		return ""
	var parts := suffix.trim_prefix(".draft.recovery.").trim_suffix(".json").split(".")
	if parts.size() != 3 or not parts[0].is_valid_int() or not parts[1].is_valid_int() or parts[2].length() != 32:
		return ""
	for character in parts[2]:
		if not character in "0123456789abcdef":
			return ""
	return "draft"


## 已存在的新数据优先，损坏旧 JSON 仍按字节保留，由实际读取模型报告格式错误。
func _copy_file(source: String, destination: String) -> DataResult:
	for path: String in [source, destination]:
		var checked := PlayerRuntimePaths.validate_file(path)
		if not checked.is_ok():
			return checked
	if FileAccess.file_exists(destination):
		return DataResult.success(destination)
	var fingerprint := FileAccess.get_sha256(source)
	if fingerprint.is_empty():
		return DataResult.failure("无法读取旧版运行数据：%s。" % source)
	var opened := PlayerRuntimePaths.open_directory(destination.get_base_dir(), true)
	if not opened.is_ok():
		return opened
	var temporary := destination + "." + Crypto.new().generate_random_bytes(16).hex_encode() + ".tmp"
	var copied := DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(temporary))
	if copied != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return DataResult.failure("运行数据复制失败，旧文件保持不变：%s。" % error_string(copied))
	if FileAccess.get_sha256(temporary) != fingerprint or FileAccess.get_sha256(source) != fingerprint:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return DataResult.failure("运行数据迁移校验失败，旧文件保持不变。")
	var checked := PlayerRuntimePaths.validate_file(destination)
	if not checked.is_ok() or FileAccess.file_exists(destination):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return checked if not checked.is_ok() else DataResult.success(destination)
	var renamed := _rename_file(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(destination))
	if renamed != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return DataResult.failure("运行数据发布失败，可在下次启动重试：%s。" % error_string(renamed))
	return DataResult.success(destination)


## 完成标记只写一次，不覆盖旧槽，临时文件回读成功才提交，避免 Windows 覆盖改名窗口。
func _write_marker(path: String) -> DataResult:
	var checked := PlayerRuntimePaths.validate_file(path)
	if not checked.is_ok():
		return checked
	var opened := PlayerRuntimePaths.open_directory(path.get_base_dir(), true)
	if not opened.is_ok():
		return opened
	var temporary := path + "." + Crypto.new().generate_random_bytes(16).hex_encode() + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return DataResult.failure("无法写入运行数据迁移检查点。")
	file.store_string(JSON.stringify(_marker_data(), "\t") + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	var loaded := DataValidation.read_json_object(temporary)
	if write_error != OK or not loaded.is_ok() or not _is_marker(loaded.value):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return DataResult.failure("运行数据迁移检查点校验失败。")
	checked = PlayerRuntimePaths.validate_file(path)
	if not checked.is_ok() or FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return checked if not checked.is_ok() else DataResult.failure("运行数据迁移检查点已由其它进程改变。")
	var renamed := _rename_file(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))
	if renamed != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
		return DataResult.failure("运行数据迁移检查点保存失败，可在下次启动重试。")
	return DataResult.success()


## 集中系统提交边界，隔离回归可注入发布或检查点故障。
func _rename_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


## JSON 回读整数统一成浮点，检查点比较先按同样格式规范数值类型。
func _is_marker(data: Dictionary) -> bool:
	return data == JSON.parse_string(JSON.stringify(_marker_data()))
