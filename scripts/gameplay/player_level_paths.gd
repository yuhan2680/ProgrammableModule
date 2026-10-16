class_name PlayerLevelPaths
extends RefCounted
## 玩家地图专用的路径授权与目录遍历，不扩大其他资源、设置或草稿的路径权限。

const SAVE_SUFFIX := "ProgrammableModule/saves"
static var _configured_external_root: String = ""
static var _test_roots: Dictionary = {}


## 仅正式入口调用平台默认值；模型保留 user://levels 默认以便独立测试注入。
static func default_directory() -> String:
	if not _configured_external_root.is_empty():
		return _configured_external_root
	var base := _platform_base_directory()
	if not base.is_empty():
		return base.path_join(SAVE_SUFFIX)
	return "" if OS.get_name() in ["macOS", "Windows"] else "user://levels"


## 外部保存根只能来自系统默认位置或 macOS 已获得的原生目录授权，不创建目录。
static func configure_external_root(root: String, allow_registered_test_root: bool = false) -> DataResult:
	var checked := validate_external_root(root, allow_registered_test_root)
	if not checked.is_ok():
		return checked
	_configured_external_root = root
	return DataResult.success(root)


## 先校验但不切换活动根，供保存位置设置原子写盘后再提交配置。
static func validate_external_root(root: String, allow_registered_test_root: bool = false) -> DataResult:
	if not _is_safe_absolute(root) or not root.ends_with("/" + SAVE_SUFFIX):
		return DataResult.failure("玩家关卡目录不在允许的保存位置。")
	if allow_registered_test_root:
		var test_location := _registered_test_location(root)
		if not test_location.is_empty():
			var test_checked := _walk_folder(test_location.anchor, test_location.relative, false)
			return DataResult.success(root) if test_checked.is_ok() else test_checked
	var base := _platform_base_directory()
	var anchor := base if not base.is_empty() and root == base.path_join(SAVE_SUFFIX) else _granted_anchor(root)
	if anchor.is_empty():
		return DataResult.failure("玩家关卡目录尚未获得系统授权。")
	var checked := _walk_folder(anchor, "" if root == anchor else root.trim_prefix(anchor + "/"), false)
	if not checked.is_ok():
		return checked
	return DataResult.success(root)


## 撤销显式根配置以便失败回滚；平台默认值仍必须通过原有安全校验。
static func clear_external_root() -> void:
	_configured_external_root = ""


## 测试只能注册 user://tests 下的独占物理根，禁止借测试接口开放任意系统目录。
static func register_test_root(root: String) -> DataResult:
	var resource := root
	var absolute_user := ProjectSettings.globalize_path("user://").trim_suffix("/")
	if _is_safe_absolute(root) and root.begins_with(absolute_user + "/"):
		resource = "user://" + root.trim_prefix(absolute_user + "/")
	if not DataValidation.is_resource_path(resource) or not resource.begins_with("user://tests/"):
		return DataResult.failure("测试保存根必须位于独占的 user://tests 目录。")
	var segments := resource.trim_prefix("user://").split("/")
	if segments.size() < 2 or segments[-1] in ["solutions", "settings", "data"]:
		return DataResult.failure("测试保存根必须位于独占的 user://tests 目录。")
	var checked := _walk_folder("user://", resource.trim_prefix("user://"), false)
	if not checked.is_ok():
		return checked
	var physical := ProjectSettings.globalize_path(resource)
	_test_roots[physical] = resource
	return DataResult.success(physical)


## 回归结束时撤销本次物理根授权，不删除目录或影响其他测试实例。
static func unregister_test_root(root: String) -> void:
	var physical := ProjectSettings.globalize_path(root) if root.begins_with("user://") else root
	_test_roots.erase(physical)


## 普通保存保留安全 user:// 子目录；文件管理只开放旧正式位置及隔离测试目录。
static func is_allowed_directory(directory: String, strict: bool = false) -> bool:
	if directory.begins_with("user://"):
		if not DataValidation.is_resource_path(directory):
			return false
		if not strict:
			return true
		var segments := directory.trim_prefix("user://").split("/")
		return (directory == "user://levels" or (segments.size() >= 3 and segments[0] == "tests")) and not segments[-1] in ["solutions", "settings", "data"]
	if not _is_safe_absolute(directory):
		return false
	if strict and directory.get_file() in ["solutions", "settings", "data"]:
		return false
	return not _external_location(directory).is_empty()


## 按可信锚点逐段检查和创建目录；缺失的只读目录返回 null，拒绝文件或链接占位。
static func open_directory(directory: String, create: bool = false, strict: bool = false) -> DataResult:
	if not is_allowed_directory(directory, strict):
		return DataResult.failure("玩家关卡目录不在允许的保存位置。")
	if directory.begins_with("user://"):
		return _walk_folder("user://", directory.trim_prefix("user://"), create)
	var location := _external_location(directory)
	if location.is_empty():
		return DataResult.failure("玩家关卡目录尚未获得系统授权。")
	return _walk_folder(location.anchor, location.relative, create)


## 同一直接 JSON 可用资源路径或原生绝对路径表示，但不能越过当前托管目录。
static func is_direct_json(path: String, directory: String) -> bool:
	if not is_allowed_directory(directory) or path.get_extension().to_lower() != "json":
		return false
	if not (DataValidation.is_resource_path(path) or _is_safe_absolute(path)):
		return false
	var absolute_path := ProjectSettings.globalize_path(path)
	return absolute_path.get_base_dir() == ProjectSettings.globalize_path(directory)


## 系统返回的 Windows 分隔符先统一；外部调用传入的路径不进行会吞掉跳转段的简化。
static func _platform_base_directory() -> String:
	if not OS.get_name() in ["macOS", "Windows"]:
		return ""
	var root := platform_default_directory(OS.get_name(), OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS), OS.get_environment("USERPROFILE"), OS.is_sandboxed())
	return root.get_base_dir().get_base_dir() if not root.is_empty() else ""


## 纯路径推导不读取磁盘或改变环境，便于跨平台回归确认 Documents 与 USERPROFILE 的边界。
static func platform_default_directory(platform: String, documents: String, user_profile: String, sandboxed: bool = false) -> String:
	if not platform in ["macOS", "Windows"]:
		return "user://levels"
	# 沙盒系统目录指向容器，不得把它冒充用户真正的 Documents 保存位置。
	if platform == "macOS" and sandboxed:
		return ""
	var base := (user_profile.replace("\\", "/") if platform == "Windows" else documents).trim_suffix("/")
	return base.path_join(SAVE_SUFFIX) if _is_safe_absolute(base) else ""


## 原生 macOS 授权目录是唯一的外部扩展来源，优先采用最具体的已授权祖先。
static func _granted_anchor(root: String) -> String:
	if OS.get_name() != "macOS":
		return ""
	var selected := ""
	for permission: String in OS.get_granted_permissions():
		var path := permission.trim_suffix("/")
		if _is_safe_absolute(path) and (root == path or root.begins_with(path + "/")) and path.length() > selected.length():
			selected = path
	return selected


## 返回已知根的目录锚点，不把导入来源、外部导出目标或字符串前缀近似项当作托管目录。
static func _external_location(directory: String) -> Dictionary:
	var base := _platform_base_directory()
	if not base.is_empty() and directory == base.path_join(SAVE_SUFFIX):
		return {"anchor": base, "relative": SAVE_SUFFIX}
	if directory == _configured_external_root and not directory.is_empty():
		var granted := _granted_anchor(directory)
		if not granted.is_empty():
			return {"anchor": granted, "relative": "" if granted == directory else directory.trim_prefix(granted + "/")}
	return _registered_test_location(directory)


## 测试权限必须先显式注册且始终限制于 user://tests 的物理树，不能模拟任意用户磁盘授权。
static func _registered_test_location(directory: String) -> Dictionary:
	var absolute_user := ProjectSettings.globalize_path("user://").trim_suffix("/")
	for root: String in _test_roots:
		if directory == root or directory.begins_with(root + "/"):
			return {"anchor": "user://", "relative": directory.trim_prefix(absolute_user + "/")}
	return {}


## 绝对路径仅接受规范分隔与普通段，拒绝 URI、UNC、上级跳转和不可见控制字符。
static func _is_safe_absolute(path: String) -> bool:
	if path.is_empty() or path.contains("\\") or path.contains("://") or path.ends_with("/") or path.contains("//"):
		return false
	var relative := ""
	if path.begins_with("/"):
		relative = path.substr(1)
	elif path.length() > 3 and path.substr(1, 2) == ":/" and path.left(1).to_lower() >= "a" and path.left(1).to_lower() <= "z":
		relative = path.substr(3)
	else:
		return false
	for character in path:
		if character.unicode_at(0) < 32:
			return false
	for segment in relative.split("/"):
		if segment.is_empty() or segment in [".", ".."] or segment.contains(":"):
			return false
	return true


## 可信系统锚点之外不猜测访问权；已有锚点可检查时同样拒绝它本身被改成链接。
static func _walk_folder(anchor: String, relative: String, create: bool) -> DataResult:
	if not anchor.begins_with("user://"):
		var parent := DirAccess.open(anchor.get_base_dir())
		if parent != null and parent.is_link(anchor.get_file()):
			return DataResult.failure("玩家关卡目录不能包含符号链接：%s。" % anchor)
	var folder := DirAccess.open(anchor)
	if folder == null:
		return DataResult.failure("无法打开玩家关卡根目录：%s。" % error_string(DirAccess.get_open_error()))
	if not relative.is_empty():
		for segment in relative.split("/"):
			if segment.is_empty() or segment in [".", ".."] or segment.contains("\\"):
				return DataResult.failure("玩家关卡目录不在允许的保存位置。")
			if folder.is_link(segment):
				return DataResult.failure("玩家关卡目录不能包含符号链接：%s。" % folder.get_current_dir().path_join(segment))
			if not folder.dir_exists(segment):
				if folder.file_exists(segment):
					return DataResult.failure("玩家关卡目录被同名文件占用：%s。" % folder.get_current_dir().path_join(segment))
				if not create:
					return DataResult.success()
				var created := folder.make_dir(segment)
				if created != OK:
					return DataResult.failure("无法创建玩家关卡目录：%s。" % error_string(created))
			# 创建后重新检查，不能把外部替换的新目录链接传给 MapCodec。
			if folder.is_link(segment):
				return DataResult.failure("玩家关卡目录不能包含符号链接：%s。" % folder.get_current_dir().path_join(segment))
			var changed := folder.change_dir(segment)
			if changed != OK:
				return DataResult.failure("无法打开玩家关卡目录：%s。" % error_string(changed))
	folder.include_hidden = true
	return DataResult.success(folder)
