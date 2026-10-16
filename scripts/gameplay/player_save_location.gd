class_name PlayerSaveLocation
extends RefCounted
## 保存位置与玩家档案分离；系统书签由 Godot 管理，此处只记录已经授权的目录。

const DEFAULT_STORAGE_PATH := "user://player_saves_location.json"
const MAX_CONFIG_BYTES := 16 * 1024

var storage_path: String = DEFAULT_STORAGE_PATH
var needs_authorization: bool = false
var last_error: String = ""
var platform_name: String = OS.get_name()
var sandboxed: bool = OS.is_sandboxed()
var documents_directory: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
var user_profile_directory: String = OS.get_environment("USERPROFILE")
# null 表示每次查询引擎恢复的真实书签；测试数组不替代底层路径授权。
var granted_directories: Variant = null
var allow_registered_test_roots: bool = false
var _resolved_directory: String = ""


## 配置路径可以注入隔离测试位置，但读写始终经过 user:// 路径与符号链接检查。
func _init(path: String = DEFAULT_STORAGE_PATH) -> void:
	storage_path = path


## 沙盒仅恢复已获得系统授权的位置；其他桌面平台使用明确默认根，失败不后备旧目录。
func resolve() -> DataResult:
	needs_authorization = false
	if platform_name == "macOS" and sandboxed:
		var loaded := _read_config()
		if not loaded.is_ok():
			return _remember(loaded)
		var config: Dictionary = loaded.value.config
		if config.is_empty():
			return _authorization_required()
		var directory: String = config["documents_directory"]
		if not _has_directory_grant(directory):
			return _authorization_required()
		return _configure_directory(directory.path_join(PlayerLevelPaths.SAVE_SUFFIX))
	if not platform_name in ["macOS", "Windows"]:
		_resolved_directory = "user://levels"
		return _remember(DataResult.success(_resolved_directory))
	var root := PlayerLevelPaths.platform_default_directory(platform_name, documents_directory, user_profile_directory)
	if root.is_empty():
		return _remember(DataResult.failure("无法确定玩家关卡的系统保存目录。"))
	return _configure_directory(root)


## 只接受原生选择器已授予访问权的目录；原子保存失败时撤回本次根配置，不创建关卡目录。
func accept_directory(directory: String) -> DataResult:
	needs_authorization = false
	if platform_name != "macOS" or not sandboxed:
		return _remember(DataResult.failure("此平台无需选择玩家关卡保存目录。"))
	var base := directory.trim_suffix("/")
	if not _is_directory_path(base):
		return _remember(DataResult.failure("玩家关卡保存位置必须是安全的绝对目录。"))
	if not _has_directory_grant(base):
		return _authorization_required()
	var loaded := _read_config()
	if not loaded.is_ok():
		return _remember(loaded)
	var next: Dictionary = loaded.value.config.duplicate(true)
	if not next.is_empty() and next["documents_directory"] != base:
		needs_authorization = true
		return _remember(DataResult.failure("请重新授权原保存目录：%s。现有保存位置保持不变。" % next["documents_directory"]))
	next["format_version"] = 1
	next["documents_directory"] = base
	var previous := _resolved_directory
	var configured := _configure_directory(base.path_join(PlayerLevelPaths.SAVE_SUFFIX))
	if not configured.is_ok():
		return configured
	var saved := _write_config(next, loaded.value.fingerprint)
	if not saved.is_ok():
		PlayerLevelPaths.clear_external_root()
		_resolved_directory = ""
		if not previous.is_empty() and previous != "user://levels":
			var restored := PlayerLevelPaths.configure_external_root(previous, allow_registered_test_roots)
			if restored.is_ok():
				_resolved_directory = previous
		return _remember(saved)
	return _remember(DataResult.success(_resolved_directory))


## 即使调用方注入平台或权限列表，也只能配置系统允许或明确注册过的隔离测试根。
func _configure_directory(root: String) -> DataResult:
	var checked := PlayerLevelPaths.validate_external_root(root, allow_registered_test_roots)
	if not checked.is_ok():
		return _remember(checked)
	var configured := PlayerLevelPaths.configure_external_root(root, allow_registered_test_roots)
	if not configured.is_ok():
		return _remember(configured)
	_resolved_directory = root
	return _remember(DataResult.success(root))


## 目录授权按完整路径边界判断，授权目录的子目录可访问，相似前缀与父目录不能冒用。
func _has_directory_grant(directory: String) -> bool:
	var permissions: Variant = OS.get_granted_permissions() if granted_directories == null else granted_directories
	if not (permissions is PackedStringArray or permissions is Array):
		return false
	for candidate: Variant in permissions:
		if not candidate is String:
			continue
		var anchor: String = candidate.trim_suffix("/")
		if _is_directory_path(anchor) and (directory == anchor or directory.begins_with(anchor + "/")):
			return true
	return false


## 复用平台路径规则验证普通绝对路径，不简化上级跳转或 URI。
func _is_directory_path(directory: String) -> bool:
	return not PlayerLevelPaths.platform_default_directory("macOS", directory, "").is_empty()


## 缺少或失效的系统书签只请求重新授权，不伪造成功位置或创建旧 user://levels。
func _authorization_required() -> DataResult:
	needs_authorization = true
	return _remember(DataResult.failure("请授权玩家关卡保存目录。"))


## 读取有大小限制的位置记录并验证版本；坏 JSON 或新版记录原样保留。
func _read_config() -> DataResult:
	var checked := _validate_storage_path()
	if not checked.is_ok():
		return checked
	if not FileAccess.file_exists(storage_path):
		return DataResult.success({"config": {}, "fingerprint": ""})
	var fingerprint := FileAccess.get_sha256(storage_path)
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取玩家关卡保存位置：%s。" % error_string(FileAccess.get_open_error()))
	if file.get_length() > MAX_CONFIG_BYTES:
		file.close()
		return DataResult.failure("玩家关卡保存位置记录过大，原文件保持不变。")
	var source := file.get_as_text()
	file.close()
	var parsed := JSON.new()
	if parsed.parse(source) != OK or not parsed.data is Dictionary:
		return DataResult.failure("玩家关卡保存位置记录损坏，原文件保持不变。")
	var config: Dictionary = parsed.data
	if not DataValidation.is_integer(config.get("format_version"), 1, 1) or not config.get("documents_directory") is String or not _is_directory_path(config["documents_directory"]):
		return DataResult.failure("玩家关卡保存位置记录无效或版本不受支持，原文件保持不变。")
	if fingerprint.is_empty() or FileAccess.get_sha256(storage_path) != fingerprint:
		return DataResult.failure("玩家关卡保存位置记录已在外部改变，请重试。")
	return DataResult.success({"config": config, "fingerprint": fingerprint})


## 元数据只允许安全的 user:// JSON 文件，逐段拒绝链接、文件占位和控制字符。
func _validate_storage_path(create_parents: bool = false) -> DataResult:
	if not storage_path.begins_with("user://") or not DataValidation.is_resource_path(storage_path) or storage_path.get_extension().to_lower() != "json":
		return DataResult.failure("玩家关卡保存位置记录必须位于安全的 user:// JSON 路径。")
	for character: String in storage_path:
		if character.unicode_at(0) < 32:
			return DataResult.failure("玩家关卡保存位置记录路径无效。")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问玩家数据目录。")
	var segments := storage_path.trim_prefix("user://").split("/")
	for index in range(segments.size()):
		var segment: String = segments[index]
		if folder.is_link(segment):
			return DataResult.failure("玩家关卡保存位置记录路径不能包含符号链接。")
		if index == segments.size() - 1:
			return DataResult.failure("玩家关卡保存位置记录被目录占用。") if folder.dir_exists(segment) else DataResult.success()
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("玩家关卡保存位置记录目录被文件占用。")
			if not create_parents:
				return DataResult.success()
			var created := folder.make_dir(segment)
			if created != OK:
				return DataResult.failure("无法创建玩家关卡保存位置记录目录：%s。" % error_string(created))
		if folder.is_link(segment) or folder.change_dir(segment) != OK:
			return DataResult.failure("无法安全访问玩家关卡保存位置记录目录。")
	return DataResult.failure("玩家关卡保存位置记录路径无效。")


## 临时文件写入并回读后再替换；外部改动、写入失败及改名失败均保留旧记录。
func _write_config(config: Dictionary, fingerprint: String) -> DataResult:
	var checked := _validate_storage_path(true)
	if not checked.is_ok():
		return checked
	var source := JSON.stringify(config, "\t", false) + "\n"
	if source.to_utf8_buffer().size() > MAX_CONFIG_BYTES:
		return DataResult.failure("玩家关卡保存位置记录过大，原文件保持不变。")
	var absolute := ProjectSettings.globalize_path(storage_path)
	var suffix := ".%d.%d.%s" % [OS.get_process_id(), Time.get_ticks_usec(), Crypto.new().generate_random_bytes(8).hex_encode()]
	var temporary := absolute + suffix + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return DataResult.failure("无法创建临时保存位置记录：%s。" % error_string(FileAccess.get_open_error()))
	file.store_string(source)
	file.flush()
	var write_error := file.get_error()
	file.close()
	var readback := DataValidation.read_json_object(temporary)
	if write_error != OK or not readback.is_ok() or readback.value != JSON.parse_string(source):
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("玩家关卡保存位置写入或回读失败，原文件保持不变。")
	checked = _validate_storage_path()
	if not checked.is_ok() or FileAccess.get_sha256(storage_path) != fingerprint:
		DirAccess.remove_absolute(temporary)
		return checked if not checked.is_ok() else DataResult.failure("玩家关卡保存位置记录已在外部改变，请重试。")
	# 此记录只在 macOS 授权流程中写入，同目录 rename 原子替换，不先移走旧记录。
	if _rename_file(temporary, absolute) != OK:
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("玩家关卡保存位置替换失败，原文件保持不变。")
	return DataResult.success()


## 改名集中在可覆盖边界，使隔离测试能够验证替换失败保留原件而不模拟磁盘内容。
func _rename_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


## 对外保留具体失败原因，成功时清除上次错误。
func _remember(result: DataResult) -> DataResult:
	last_error = "\n".join(result.errors)
	return result
