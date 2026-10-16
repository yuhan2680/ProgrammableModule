extends SceneTree
## 保存位置授权、重启恢复及原子元数据持久化；所有写盘都限制在独占测试根。

class RenameFailureLocation extends PlayerSaveLocation:
	var fail_replacement: bool = false
	var destination_bytes_at_failure: PackedByteArray = PackedByteArray()

	## 仅阻止临时文件替换，让测试验证原件始终存在于原路径。
	func _rename_file(source: String, destination: String) -> Error:
		if fail_replacement and source.ends_with(".tmp"):
			destination_bytes_at_failure = FileAccess.get_file_as_bytes(destination) if FileAccess.file_exists(destination) else PackedByteArray()
			return ERR_CANT_CREATE
		return super._rename_file(source, destination)


class ConcurrentLocation extends PlayerSaveLocation:
	var external_source := ""

	## 在读取旧记录后模拟其他进程改写，正式提交必须用指纹拒绝覆盖外部结果。
	func _write_config(config: Dictionary, fingerprint: String) -> DataResult:
		var file := FileAccess.open(storage_path, FileAccess.WRITE)
		if file != null:
			file.store_string(external_source)
			file.close()
		return super._write_config(config, fingerprint)


var _checks := 0
var _failures := 0
var _root := ""
var _physical := ""
var _legacy_exists := false


## 等待全局类注册后运行，避免测试启动触碰正式外部保存目录。
func _initialize() -> void:
	_run.call_deferred()


## 每次测试使用独立根，退出前撤销授权并仅清理本次生成的文件。
func _run() -> void:
	_root = "user://tests/player_save_location_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_legacy_exists = DirAccess.dir_exists_absolute("user://levels")
	var registered := PlayerLevelPaths.register_test_root(_root)
	if _ok(registered, "注册隔离物理路径"):
		_physical = registered.value
		_test_platform_resolution()
		_test_authorization_and_restart()
		_test_invalid_metadata()
		_test_authority_boundaries()
		_test_atomic_failure()
		_test_external_change()
		_test_profile_independence()
		_test_symlinks()
	_check(DirAccess.dir_exists_absolute("user://levels") == _legacy_exists, "任何失败都不创建或删除旧正式关卡目录")
	PlayerLevelPaths.clear_external_root()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("玩家关卡保存位置回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 平台分支用真实受控根验证，Windows 不使用 Documents，其他平台保持旧默认位置。
func _test_platform_resolution() -> void:
	var location := _location("mac_default")
	location.sandboxed = false
	location.documents_directory = _physical.path_join("mac_documents")
	location.user_profile_directory = _physical.path_join("ignored_profile")
	var result := location.resolve()
	if _ok(result, "非沙盒 macOS 解析 Documents 下的根"):
		_check(result.value == _physical.path_join("mac_documents/ProgrammableModule/saves"), "macOS 返回完整目标而非 user:// 后备")
		_check(PlayerLevelPaths.default_directory() == result.value, "解析成功同步活动托管根")
	_check(not DirAccess.dir_exists_absolute(location.documents_directory), "解析位置本身不创建 Documents 或关卡目录")
	location.platform_name = "Windows"
	location.user_profile_directory = _physical.path_join("windows_profile").replace("/", "\\")
	result = location.resolve()
	if _ok(result, "Windows 解析 USERPROFILE 下的根"):
		_check(result.value == _physical.path_join("windows_profile/ProgrammableModule/saves"), "Windows 不追加 Documents 并统一系统分隔符")
	location.user_profile_directory = ""
	_error(location.resolve(), "缺少 USERPROFILE 明确失败")
	_check(not location.needs_authorization, "Windows 目录缺失不请求 macOS 授权")
	location.platform_name = "Linux"
	result = location.resolve()
	_check(result.is_ok() and result.value == "user://levels", "其他平台保持现有位置")
	_check(not FileAccess.file_exists(location.storage_path), "默认位置解析不生成不必要的元数据")
	_error(location.accept_directory(_physical), "非 macOS 沙盒不接受目录授权回调")
	PlayerLevelPaths.clear_external_root()


## 首次缺记录请求授权，真实受控根授权后持久化并能由新实例恢复，失效时拒绝回退。
func _test_authorization_and_restart() -> void:
	var location := _location("restart")
	var directory := _physical.path_join("chosen_documents")
	_error(location.resolve(), "沙盒没有配置时不返回容器 Documents")
	_check(location.needs_authorization and not FileAccess.file_exists(location.storage_path), "首次启动只请求授权且不写空记录")
	_error(location.accept_directory(directory), "选择器未授予访问权时拒绝目录")
	_check(location.needs_authorization and not FileAccess.file_exists(location.storage_path), "未授权选择不产生元数据")
	location.granted_directories = PackedStringArray([directory])
	var accepted := location.accept_directory(directory + "/")
	if not _ok(accepted, "授权完成后接受目录并持久化"):
		return
	_check(accepted.value == directory.path_join("ProgrammableModule/saves") and not location.needs_authorization, "选择目录追加完整游戏子目录")
	var saved := DataValidation.read_json_object(location.storage_path)
	_check(saved.is_ok() and saved.value.documents_directory == directory and saved.value.format_version == 1, "保存元数据包含版本和原授权目录")
	_check(not DirAccess.dir_exists_absolute(directory), "仅选择保存位置不提前创建关卡目标")
	var bytes := FileAccess.get_file_as_bytes(location.storage_path)
	var restored := _location("restart")
	restored.granted_directories = [directory]
	var resolved := restored.resolve()
	_check(resolved.is_ok() and resolved.value == accepted.value, "新实例从配置与已恢复系统书签解析同一目标")
	_check(FileAccess.get_file_as_bytes(location.storage_path) == bytes, "重启解析不重写有效元数据")
	restored.granted_directories = []
	_error(restored.resolve(), "系统授权撤销后不能继续采用已保存路径")
	_check(restored.needs_authorization and FileAccess.get_file_as_bytes(location.storage_path) == bytes, "失效授权要求重新选择并保留原记录")
	var other_directory := _physical.path_join("other_documents")
	restored.granted_directories = [other_directory]
	_error(restored.accept_directory(other_directory), "重授权限时不能隐式改换已绑定的保存目录")
	_check(restored.needs_authorization and restored.last_error.contains(directory), "选错位置明确显示原目录并允许继续重选")
	_check(FileAccess.get_file_as_bytes(location.storage_path) == bytes and PlayerLevelPaths.default_directory() == accepted.value, "选错位置不改有效配置或既有活动根")
	restored.granted_directories = [directory]
	var reauthorized := restored.accept_directory(directory)
	_check(reauthorized.is_ok() and reauthorized.value == accepted.value and not restored.needs_authorization, "选回原目录后成功重授并沿用原迁移目标")
	restored.granted_directories = [directory + "_sibling"]
	_error(restored.resolve(), "相似字符串前缀不能冒用目录授权")
	restored.granted_directories = [_physical]
	_check(restored.resolve().is_ok(), "真实祖先授权允许恢复其子目录")
	PlayerLevelPaths.clear_external_root()


## 损坏、错误类型、新版本或超限元数据不被自动修复，显式选择也不能覆盖未知原件。
func _test_invalid_metadata() -> void:
	var invalid_sources: Array[String] = [
		"{broken", "[]", "{}", '{"format_version":2,"documents_directory":"/Users/Test/Documents"}',
		'{"format_version":true,"documents_directory":"/Users/Test/Documents"}',
		'{"format_version":1,"documents_directory":null}',
		'{"format_version":1,"documents_directory":"/Users/Test/../Documents"}',
		" ".repeat(PlayerSaveLocation.MAX_CONFIG_BYTES + 1),
	]
	for index in range(invalid_sources.size()):
		var location := _location("invalid_%d" % index)
		location.granted_directories = [_physical]
		_write(location.storage_path, invalid_sources[index])
		var before := FileAccess.get_file_as_bytes(location.storage_path)
		_error(location.resolve(), "无效记录拒绝解析 %d" % index)
		_check(not location.needs_authorization, "坏记录不能被当作首次未授权 %d" % index)
		_error(location.accept_directory(_physical.path_join("new_documents")), "无效记录禁止被选择结果覆盖 %d" % index)
		_check(FileAccess.get_file_as_bytes(location.storage_path) == before, "无效记录保留原字节 %d" % index)
	for path: String in ["res://forbidden.json", "/tmp/forbidden.json", "user://../forbidden.json", "user://bad\\path.json", "user://bad\npath.json", _root.path_join("no_extension")]:
		var location := _location("ignored")
		location.storage_path = path
		_error(location.resolve(), "配置位置拒绝危险路径 " + path)
	var blocked := _location("blocked")
	DirAccess.make_dir_recursive_absolute(blocked.storage_path)
	_error(blocked.resolve(), "同名目录不能被当作缺少的记录")
	var parent_blocked := _location("parent_blocked")
	_write(parent_blocked.storage_path.get_base_dir(), "blocker")
	_error(parent_blocked.resolve(), "父目录文件占位返回错误")


## 注入的平台与伪造权限不是系统授权；测试开关也只能使用已注册的物理测试树。
func _test_authority_boundaries() -> void:
	var location := _location("boundaries")
	location.allow_registered_test_roots = false
	location.granted_directories = [_physical]
	_error(location.accept_directory(_physical.path_join("pretend_documents")), "仅注入权限列表不能假冒真实 macOS 授权")
	_check(not FileAccess.file_exists(location.storage_path), "底层授权拒绝不写元数据")
	location.allow_registered_test_roots = true
	var unregistered := ProjectSettings.globalize_path(_root + "_other")
	location.granted_directories = [unregistered]
	_error(location.accept_directory(unregistered), "测试开关不能授权未注册的兄弟目录")
	_check(not DirAccess.dir_exists_absolute(unregistered), "拒绝未注册目录不产生外部写入")
	location.granted_directories = [_physical]
	for path: String in [_physical + "/../outside", _physical + "//duplicate", "user://tests/pretend", "", "/"]:
		_error(location.accept_directory(path), "选择器返回不规范路径仍被拒绝 " + path)


## 原子替换失败保留旧字节与旧活动根，首次失败不会留下可用配置或临时文件。
func _test_atomic_failure() -> void:
	var location := RenameFailureLocation.new()
	_setup(location, "atomic")
	location.granted_directories = [_physical]
	var first_directory := _physical.path_join("atomic_first")
	if not _ok(location.accept_directory(first_directory), "先建立有效保存位置"):
		return
	var saved: Dictionary = DataValidation.read_json_object(location.storage_path).value
	saved["extension"] = {"keep": ["future", 8]}
	_write(location.storage_path, JSON.stringify(saved))
	var before := FileAccess.get_file_as_bytes(location.storage_path)
	location.fail_replacement = true
	_error(location.accept_directory(first_directory), "模拟目标替换失败返回错误")
	_check(location.destination_bytes_at_failure == before, "原子提交尝试时旧记录仍在原路径，没有先移走原件的空档")
	_check(FileAccess.get_file_as_bytes(location.storage_path) == before, "替换失败保留旧元数据完整字节")
	_check(PlayerLevelPaths.default_directory() == first_directory.path_join("ProgrammableModule/saves"), "落盘失败恢复先前成功的活动根")
	_check(DirAccess.open(location.storage_path.get_base_dir()).get_files().size() == 1, "失败不残留临时文件或备份")
	location.fail_replacement = false
	_ok(location.accept_directory(first_directory), "恢复写盘后可重新授权原位置")
	saved = DataValidation.read_json_object(location.storage_path).value
	_check(saved.extension.keep[0] == "future", "替换有效位置保留未知扩展字段")
	var fresh := RenameFailureLocation.new()
	_setup(fresh, "atomic_fresh")
	fresh.granted_directories = [_physical]
	fresh.fail_replacement = true
	PlayerLevelPaths.clear_external_root()
	_error(fresh.accept_directory(_physical.path_join("fresh_documents")), "首次配置替换失败明确拒绝")
	_check(not FileAccess.file_exists(fresh.storage_path), "首次失败不留下位置记录")
	_check(DirAccess.open(fresh.storage_path.get_base_dir()).get_files().is_empty(), "首次失败清理临时文件")
	PlayerLevelPaths.clear_external_root()


## 读写之间外部改动的记录优先保留，本次授权选择不得无提示覆盖其他进程的结果。
func _test_external_change() -> void:
	var original := _location("concurrent")
	original.granted_directories = [_physical]
	if not _ok(original.accept_directory(_physical.path_join("concurrent_original")), "建立并发写入测试原件"):
		return
	var location := ConcurrentLocation.new()
	_setup(location, "concurrent")
	location.granted_directories = [_physical]
	location.external_source = JSON.stringify({"format_version": 1, "documents_directory": _physical.path_join("other_process")})
	_error(location.accept_directory(_physical.path_join("concurrent_original")), "读取后外部变化拒绝提交")
	_check(FileAccess.get_file_as_string(location.storage_path) == location.external_source, "并发外部配置保留原字节")
	_check(DirAccess.open(location.storage_path.get_base_dir()).get_files().size() == 1, "指纹拒绝清理自己的临时文件")
	PlayerLevelPaths.clear_external_root()


## 删除玩家档案只重置身份与统计，不删除独立保存位置记录。
func _test_profile_independence() -> void:
	var location := _location("profile_independence")
	location.granted_directories = [_physical]
	if not _ok(location.accept_directory(_physical.path_join("profile_documents")), "建立独立位置记录"):
		return
	var before := FileAccess.get_file_as_bytes(location.storage_path)
	var profile := PlayerProfileStore.new(_root.path_join("profile_independence/player_profile.json"))
	if _ok(profile.load_profile(), "在同一隔离目录建立玩家档案"):
		var uid := profile.get_uid()
		_ok(profile.reset_profile(), "删除玩家档案生成新身份")
		_check(profile.get_uid() != uid, "档案确实重置")
		_check(FileAccess.get_file_as_bytes(location.storage_path) == before, "档案重置不改变位置记录")
	PlayerLevelPaths.clear_external_root()


## 配置自身、配置父目录和已授权目标内的链接都被拒绝，外部目标保持原字节。
func _test_symlinks() -> void:
	var directory := _root.path_join("links")
	DirAccess.make_dir_recursive_absolute(directory)
	var target := directory.path_join("original.json")
	_write(target, '{"format_version":1,"documents_directory":"' + _physical + '"}')
	var folder := DirAccess.open(directory)
	var linked := directory.path_join("linked.json")
	if folder.create_link(ProjectSettings.globalize_path(target), "linked.json") != OK:
		print("当前平台无法建立测试符号链接，跳过链接用例。")
		return
	var location := _location("links_metadata")
	location.storage_path = linked
	location.granted_directories = [_physical]
	var before := FileAccess.get_file_as_bytes(target)
	_error(location.resolve(), "位置配置文件链接拒绝读取")
	_error(location.accept_directory(_physical), "位置配置文件链接拒绝替换")
	_check(FileAccess.get_file_as_bytes(target) == before and folder.is_link("linked.json"), "链接与其目标均保留")
	var linked_parent := directory.path_join("linked_parent")
	if folder.create_link(ProjectSettings.globalize_path(directory), "linked_parent") == OK:
		location.storage_path = linked_parent.path_join("new.json")
		_error(location.resolve(), "配置父目录链接不能穿透")
	var selected := _physical.path_join("links_documents")
	DirAccess.make_dir_recursive_absolute(selected)
	var selected_folder := DirAccess.open(selected)
	if selected_folder.create_link(ProjectSettings.globalize_path(directory), "ProgrammableModule") == OK:
		location = _location("links_destination")
		location.granted_directories = [selected]
		_error(location.accept_directory(selected), "真实授权根内的子目录链接仍被拒绝")
		_check(not FileAccess.file_exists(location.storage_path), "目标链接拒绝时不提交位置记录")


## 创建只使用隔离配置和明确测试权限的实例，不替换底层路径检查实现。
func _location(name: String) -> PlayerSaveLocation:
	var result := PlayerSaveLocation.new()
	_setup(result, name)
	return result


## 测试仅注入环境数据，成功写盘仍需 PlayerLevelPaths 注册的真实物理根。
func _setup(location: PlayerSaveLocation, name: String) -> void:
	location.storage_path = _root.path_join(name).path_join("location.json")
	location.platform_name = "macOS"
	location.sandboxed = true
	location.documents_directory = _physical.path_join("container_documents")
	location.user_profile_directory = ""
	location.granted_directories = []
	location.allow_registered_test_roots = true


## 原始坏文件仅能写入本次测试根，方便验证保护行为和原件不变。
func _write(path: String, source: String) -> void:
	if not _check(path.begins_with(_root + "/"), "测试写盘限制在独占目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "创建隔离测试原件"):
		file.store_string(source)
		file.close()


## 统计所有断言并在失败时输出原因，不能被返回码为零的脚本错误掩盖。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 成功结果附带底层错误文本，以便识别路径、磁盘和配置层的失败。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result.is_ok(), message + "；" + "; ".join(result.errors))


## 失败必须具有明确原因和空值，防止调用方误把旧根当作本次成功位置。
func _error(result: DataResult, message: String) -> void:
	_check(not result.is_ok() and not result.errors.is_empty() and result.value == null, message)


## 清理只在本次根内递归，遇到链接只删除链接本身，不访问其目标。
func _cleanup(path: String) -> void:
	if _root.is_empty() or not (path == _root or path.begins_with(_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var filename := folder.get_next()
	while not filename.is_empty():
		var child := path.path_join(filename)
		if folder.is_link(filename) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)
