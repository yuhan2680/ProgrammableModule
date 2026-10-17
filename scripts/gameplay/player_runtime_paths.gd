class_name PlayerRuntimePaths
extends RefCounted
## 缓存和进度独立授权，只允许已确认玩家目录同级的 Cache / Progress，不扩张地图路径权限。

static var _roots: Dictionary = {}


## 从已确认的 saves 位置推导两类数据目录，不读写玩家内容，也不自动创建目录。
static func configure_from_saves(saves_directory: String, allow_registered_test_root: bool = false) -> DataResult:
	if saves_directory.begins_with("user://"):
		if not PlayerLevelPaths.is_allowed_directory(saves_directory, true):
			return DataResult.failure("运行数据目录必须来自已确认的玩家保存位置。")
		var base := saves_directory.get_base_dir()
		return DataResult.success({"cache_directory": base.path_join("Cache"), "progress_directory": base.path_join("Progress"), "profile_path": base.path_join("Progress/player_profile.json")})
	var checked := PlayerLevelPaths.validate_external_root(saves_directory, allow_registered_test_root)
	if not checked.is_ok():
		return checked
	var base := saves_directory.get_base_dir()
	var location := _location_for_saves(saves_directory, allow_registered_test_root)
	if location.is_empty():
		return DataResult.failure("缓存与进度目录尚未获得系统授权。")
	var result := {"cache_directory": base.path_join("Cache"), "progress_directory": base.path_join("Progress"), "profile_path": base.path_join("Progress/player_profile.json")}
	for key: String in ["cache_directory", "progress_directory"]:
		var directory: String = result[key]
		var relative := _relative_to_anchor(directory, location.anchor)
		checked = PlayerLevelPaths._walk_folder(location.anchor, relative, false)
		if not checked.is_ok():
			return checked
	for key: String in ["cache_directory", "progress_directory"]:
		_roots[result[key]] = {"saves": saves_directory, "allow_test": allow_registered_test_root}
	return DataResult.success(result)


## 存储模型兼容安全的 user:// 测试目录；绝对路径只能是已经登记的两类直接目录。
static func is_allowed_directory(directory: String) -> bool:
	return (directory.begins_with("user://") and DataValidation.is_resource_path(directory)) or _roots.has(directory)


## 每次访问重新确认系统授权和完整目录链，防止授权失效或目录被链接替换。
static func open_directory(directory: String, create: bool = false) -> DataResult:
	if directory == "user://" or (directory.begins_with("user://") and DataValidation.is_resource_path(directory)):
		return PlayerLevelPaths._walk_folder("user://", directory.trim_prefix("user://"), create)
	if not _roots.has(directory):
		return DataResult.failure("运行数据目录不在允许的保存位置。")
	var registration: Dictionary = _roots[directory]
	var checked := PlayerLevelPaths.validate_external_root(registration.saves, registration.allow_test)
	if not checked.is_ok():
		return checked
	var location := _location_for_saves(registration.saves, registration.allow_test)
	if location.is_empty():
		return DataResult.failure("缓存与进度目录尚未获得系统授权。")
	return PlayerLevelPaths._walk_folder(location.anchor, _relative_to_anchor(directory, location.anchor), create)


## 直接文件访问拒绝链接和目录占位，允许尚未创建的安全目录或文件。
static func validate_file(path: String) -> DataResult:
	var filename := path.get_file()
	if filename.is_empty() or filename in [".", ".."] or filename.contains("\\") or filename.contains(":"):
		return DataResult.failure("运行数据文件路径无效。")
	var opened := open_directory(path.get_base_dir())
	if not opened.is_ok() or opened.value == null:
		return opened
	var folder: DirAccess = opened.value
	if folder.is_link(filename) or folder.dir_exists(filename):
		return DataResult.failure("运行数据文件路径不能是链接或目录：%s。" % path)
	return DataResult.success()


## 测试结束时只撤销本类缓存的授权，不改变玩家地图授权和磁盘内容。
static func clear_configuration() -> void:
	_roots.clear()


## 同级目录需要共同祖先权限；只授权 saves 自身不能据此访问其旁边的进度目录。
static func _location_for_saves(saves_directory: String, allow_test: bool) -> Dictionary:
	var base := saves_directory.get_base_dir()
	if allow_test:
		var test_location := PlayerLevelPaths._registered_test_location(base)
		if not test_location.is_empty():
			return test_location
	var platform_base := PlayerLevelPaths._platform_base_directory()
	if not platform_base.is_empty() and saves_directory == platform_base.path_join(PlayerLevelPaths.SAVE_SUFFIX):
		return {"anchor": platform_base}
	var granted := PlayerLevelPaths._granted_anchor(base)
	return {"anchor": granted} if not granted.is_empty() else {}


## 资源锚点先转换为物理目录，测试授权与正式绝对目录使用同样的逐段遍历。
static func _relative_to_anchor(directory: String, anchor: String) -> String:
	return directory.trim_prefix(ProjectSettings.globalize_path(anchor).trim_suffix("/") + "/")
