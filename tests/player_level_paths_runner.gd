extends SceneTree
## 玩家关卡跨平台默认路径、外部托管边界及三个存储模型的隔离回归。

var _checks := 0
var _failures := 0
var _root := ""
var _external := ""
var _content := ContentRegistry.new()


## 全局类注册完成后运行，不访问玩家真实 Documents 或 USERPROFILE 保存目录。
func _initialize() -> void:
	_run.call_deferred()


## 仅创建本次独占测试根，完成后撤销外部授权并清理生成文件。
func _run() -> void:
	_root = "user://tests/player_level_paths_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_test_default_paths()
	_test_authorization()
	if _ok(_content.load_directories(), "读取真实模块与地块"):
		_test_store_and_catalog()
		_test_library()
		_test_links()
	PlayerLevelPaths.unregister_test_root(_root)
	_check(not PlayerLevelPaths.is_allowed_directory(_external), "撤销测试注册后不保留物理根权限")
	_cleanup(_root)
	print("玩家关卡外部路径回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 平台推导是纯函数，Windows 不误写 Documents，macOS 不依赖环境变量 HOME。
func _test_default_paths() -> void:
	_check(PlayerLevelPaths.platform_default_directory("Windows", "C:/Users/Tester/Documents", "C:\\Users\\Tester") == "C:/Users/Tester/ProgrammableModule/saves", "Windows 使用 USERPROFILE 根")
	_check(PlayerLevelPaths.platform_default_directory("macOS", "/Users/Tester/Documents/", "/ignored") == "/Users/Tester/Documents/ProgrammableModule/saves", "macOS 使用系统 Documents")
	_check(PlayerLevelPaths.platform_default_directory("macOS", "/Users/Tester/Library/Containers/test/Data/Documents", "", true).is_empty(), "macOS 沙盒不默认认可容器 Documents")
	_check(PlayerLevelPaths.platform_default_directory("Linux", "/ignored", "/ignored") == "user://levels", "其他平台保留既有位置")
	_check(PlayerLevelPaths.platform_default_directory("Windows", "/ignored", "").is_empty(), "Windows 未知用户根不能悄悄写其他目录")
	_check(PlayerLevelPaths.platform_default_directory("macOS", "", "/ignored").is_empty(), "macOS 未知 Documents 不猜测目录")
	_check(PlayerLevelPaths.platform_default_directory("macOS", "/Users/Tester/../Documents", "").is_empty(), "系统路径推导同样拒绝上级跳转")
	_check(PlayerLevelStore.new().directory == "user://levels" and LevelCatalog.new().user_directory == "user://levels" and PlayerLevelLibrary.new().user_directory == "user://levels", "模型默认不读取或写入真实外部目录")


## 授权只放行完整托管目录，不接受相似前缀、任意系统根或测试资源目录的越界形式。
func _test_authorization() -> void:
	_check(PlayerLevelPaths.is_allowed_directory("user://custom/levels"), "普通 Store 保留安全 user 子目录兼容")
	_check(not PlayerLevelPaths.is_allowed_directory("user://custom/levels", true), "严格文件管理不开放任意 user 子目录")
	_check(PlayerLevelPaths.is_allowed_directory("user://levels", true), "旧正式目录仍可安全管理")
	_check(PlayerLevelPaths.is_allowed_directory(_root.path_join("levels"), true), "隔离测试目录继续可用")
	for unsafe: String in ["res://data/levels", "user://", "user://levels/../settings", _root.path_join("settings"), _root.path_join("solutions"), _root.path_join("data")]:
		_check(not PlayerLevelPaths.is_allowed_directory(unsafe, true), "严格目录拒绝 " + unsafe)
	for unsafe: String in ["/tmp", "res://tests/example", "user://tests", "user://tests/../levels"]:
		_error(PlayerLevelPaths.register_test_root(unsafe), "测试注册拒绝 " + unsafe)
	var registered := PlayerLevelPaths.register_test_root(_root)
	if _ok(registered, "注册独占测试物理根"):
		_external = str(registered.value).path_join("external/saves")
	_check(not DirAccess.dir_exists_absolute(_root), "授权不创建测试目录")
	_check(PlayerLevelPaths.is_allowed_directory(_external, true), "测试物理根下允许完整外部路径")
	_check(not PlayerLevelPaths.is_allowed_directory(ProjectSettings.globalize_path(_root) + "_sibling/saves"), "相似前缀的兄弟目录不获授权")
	_check(not PlayerLevelPaths.is_allowed_directory(_external + "/../elsewhere"), "外部路径不简化上级跳转")
	_check(not PlayerLevelPaths.is_allowed_directory(_external + "//nested"), "外部路径拒绝空路径段")
	_check(not PlayerLevelPaths.is_direct_json(_external + "/../other.json", _external), "直接 JSON 校验拒绝跳转")
	_check(PlayerLevelPaths.is_direct_json(_external.path_join("valid.JSON"), _external), "直接 JSON 支持大小写扩展名")
	_check(not PlayerLevelPaths.is_direct_json(_external.path_join("nested/valid.json"), _external), "嵌套 JSON 不属于直接托管项")
	_error(PlayerLevelPaths.configure_external_root(ProjectSettings.globalize_path(_root).path_join("ProgrammableModule/saves")), "测试注册不能伪装成系统正式根授权")
	var previous := PlayerLevelPaths.default_directory()
	_error(PlayerLevelPaths.validate_external_root(_external), "预校验拒绝未经平台授权的正式根")
	_check(PlayerLevelPaths.default_directory() == previous, "无副作用校验保留活动配置")
	var test_configured := ProjectSettings.globalize_path(_root).path_join("ProgrammableModule/saves")
	_ok(PlayerLevelPaths.configure_external_root(test_configured, true), "显式测试模式只可配置已注册物理根")
	_check(PlayerLevelPaths.default_directory() == test_configured, "隔离测试可演练活动根切换")
	_error(PlayerLevelPaths.configure_external_root(ProjectSettings.globalize_path(_root) + "_sibling/ProgrammableModule/saves", true), "测试模式也不能配置未注册兄弟根")
	_check(PlayerLevelPaths.default_directory() == test_configured, "配置失败保留此前活动根")
	PlayerLevelPaths.clear_external_root()
	_check(PlayerLevelPaths.default_directory() == previous, "清除配置可安全恢复默认值")
	var absent := PlayerLevelPaths.open_directory(_external)
	_check(absent.is_ok() and absent.value == null and not DirAccess.dir_exists_absolute(_root), "缺失目录只读检查不创建文件")


## 保存、重复保存、导入与目录管理保持相同 ID、外部原件和文件身份校验语义。
func _test_store_and_catalog() -> void:
	var store := PlayerLevelStore.new()
	store.directory = _external
	var document := _map("external_map")
	var saved := store.save(document, _content)
	if not _ok(saved, "保存到隔离外部托管目录"):
		return
	var path: String = saved.value.path
	_check(path.get_base_dir() == _external and FileAccess.file_exists(path), "保存结果保持外部绝对路径")
	_check(store.managed_path(path) == path, "重新打开外部托管文件可绑定原路径")
	document.display_name = "修改后"
	var updated := store.save(document, _content, path)
	_check(updated.is_ok() and updated.value.path == path and updated.value.document.id == document.id, "重复保存覆盖同一托管副本且保持 ID")
	var source := _root.path_join("original/source.json")
	_ok(MapCodec.save_file(_map("imported_map"), source, _content), "准备导入原件")
	var original_bytes := FileAccess.get_file_as_bytes(source)
	_check(store.managed_path(ProjectSettings.globalize_path(source)).is_empty(), "外部原件不能成为托管绑定")
	var imported := store.import_file(ProjectSettings.globalize_path(source), _content)
	_check(imported.is_ok() and imported.value.path.get_base_dir() == _external, "导入写入外部托管副本")
	_check(FileAccess.get_file_as_bytes(source) == original_bytes, "导入不改变原件字节")
	var catalog := LevelCatalog.new()
	catalog.user_directory = _external
	_ok(catalog.refresh(_content), "选关目录扫描外部保存根")
	var level := _find_level(catalog, document.id)
	_check(level != null and catalog.can_delete_user_level(level), "外部玩家项获得真实管理授权")
	if level != null:
		_ok(catalog.rename_user_level(level, "重命名", _content), "外部玩家项可原子改名")
		var folder := catalog.get_user_level_directory(level)
		_check(folder.is_ok() and folder.value == _external, "查看目录返回托管外部根")
		var shadow := LevelDefinition.from_document(document, _content, _external.path_join("not_real.json")).value as LevelDefinition
		_check(not catalog.can_delete_user_level(shadow), "伪造同 ID 对象不能取得删除权限")
		_ok(catalog.delete_user_level(level), "外部玩家项可以删除")
		_check(not FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(source) == original_bytes, "删除只影响托管单文件")
	var ensured := catalog.ensure_import_directory()
	_check(ensured.is_ok() and ensured.value == _external, "创建目录入口也支持外部根")


## 玩家列表保留坏文件及未完成草稿，修改、删除和旧快照拒绝不依赖 user:// 表示。
func _test_library() -> void:
	var draft := _map("unfinished_map")
	draft.player_spawn = null
	var store := PlayerLevelStore.new()
	store.directory = _external
	var saved := store.save(draft, _content)
	if not _ok(saved, "外部根允许保存未完成草稿"):
		return
	var broken := _external.path_join("broken.json")
	_write(broken, "{broken")
	var library := PlayerLevelLibrary.new()
	library.user_directory = _external
	_ok(library.refresh(_content), "玩家文件列表读取外部根")
	var draft_entry := _find_entry(library, str(saved.value.path).get_file())
	var broken_entry := _find_entry(library, "broken.json")
	_check(draft_entry != null and draft_entry.can_edit and draft_entry.can_rename and not draft_entry.playable, "未完成草稿保留编辑能力")
	_check(broken_entry != null and broken_entry.is_corrupt and not broken_entry.can_edit, "坏 JSON 继续显示独立诊断")
	if draft_entry != null:
		_ok(library.rename_entry(draft_entry, "草稿改名", _content), "外部未完成草稿改名")
		var edited := library.get_entry_edit_path(draft_entry)
		_check(edited.is_ok() and edited.value == saved.value.path, "编辑入口保留原外部绑定")
		var folder := library.get_entry_directory(draft_entry)
		_check(folder.is_ok() and folder.value == _external, "草稿目录入口返回外部根")
	if broken_entry != null:
		_ok(library.delete_entry(broken_entry), "外部坏文件可以直接删除")
		_check(not FileAccess.file_exists(broken), "只删除已授权坏文件")
	_ok(library.refresh(_content), "刷新后替换快照")
	if draft_entry != null:
		_error(library.delete_entry(draft_entry), "刷新后的旧条目不可操作")


## 外部目录中的文件链接和中间目录链接均被拒绝，不能借根注册触及受保护目标。
func _test_links() -> void:
	var outside := _root.path_join("protected/original.json")
	_ok(MapCodec.save_file(_map("protected_target"), outside, _content), "准备链接目标的真实地图")
	var protected_bytes := FileAccess.get_file_as_bytes(outside)
	var folder := DirAccess.open(_external)
	if folder == null:
		_check(false, "链接回归需要已经建立外部目录")
		return
	var error := folder.create_link(ProjectSettings.globalize_path(outside), "linked.json")
	if error != OK:
		print("平台不能创建测试链接，跳过链接断言：%s" % error_string(error))
		return
	var store := PlayerLevelStore.new()
	store.directory = _external
	_error(store.save(_map("blocked"), _content, _external.path_join("linked.json")), "托管文件链接禁止保存")
	var library := PlayerLevelLibrary.new()
	library.user_directory = _external
	_ok(library.refresh(_content), "文件列表保留链接诊断")
	var linked := _find_entry(library, "linked.json")
	_check(linked != null and not linked.can_edit, "文件链接没有编辑授权")
	if linked != null:
		_error(library.delete_entry(linked), "文件链接没有删除授权")
	var catalog := LevelCatalog.new()
	catalog.user_directory = _external
	catalog.refresh(_content)
	_check(_find_level(catalog, "protected_target") == null, "选关目录不沿文件链接加载外部地图")
	_check(FileAccess.get_file_as_bytes(outside) == protected_bytes, "链接目标字节不变")
	folder.remove("linked.json")
	var base := DirAccess.open(ProjectSettings.globalize_path(_root))
	if _check(base.create_link(ProjectSettings.globalize_path(outside.get_base_dir()), "directory_link") == OK, "建立外部目录链接"):
		var target := ProjectSettings.globalize_path(_root).path_join("directory_link/saves")
		_error(PlayerLevelPaths.open_directory(target, true), "逐段遍历拒绝目录链接")
		_check(not DirAccess.dir_exists_absolute(outside.get_base_dir().path_join("saves")), "链接目标下不会创建保存目录")
	var blocked := ProjectSettings.globalize_path(_root).path_join("file_block")
	_write(blocked, "blocked")
	_error(PlayerLevelPaths.open_directory(blocked.path_join("saves"), true), "同名普通文件不视为缺失目录")
	_check(FileAccess.get_file_as_string(blocked) == "blocked", "目录创建失败保留占位原件")


## 从真实可玩地图创建独立测试文档，避免测试镜像格式实现。
func _map(id: String) -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var document: MapDocument = loaded.value.duplicate_document()
	document.id = id
	document.display_name = "测试地图"
	return document


## 按真实目录返回的关卡对象定位目标，不伪造存储授权。
func _find_level(catalog: LevelCatalog, id: String) -> LevelDefinition:
	for level: LevelDefinition in catalog.levels:
		if level.id == id:
			return level
	return null


## 玩家列表使用实际源文件名定位包含坏文件的条目。
func _find_entry(library: PlayerLevelLibrary, filename: String) -> PlayerLevelRecord:
	for entry: PlayerLevelRecord in library.entries:
		if entry.source_path.get_file() == filename:
			return entry
	return null


## 隔离测试辅助写盘只为坏文件和占位案例生成原始内容。
func _write(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "写入隔离测试文件"):
		file.store_string(value)
		file.close()


## 记录通用断言并继续执行，以便一次回归报告所有失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 成功结果附带诊断，解析或磁盘错误不会被布尔断言吞掉。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result.is_ok(), message + ": " + "; ".join(result.errors))


## 明确预期拒绝，保证保护检查实际返回错误而非静默跳过。
func _error(result: DataResult, message: String) -> void:
	_check(not result.is_ok(), message)


## 清理只接受本次独占根，链接直接删除而不递归到目标。
func _cleanup(path: String) -> void:
	assert(path == _root or path.begins_with(_root + "/"))
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for filename in folder.get_files():
		folder.remove(filename)
	for dirname in folder.get_directories():
		if folder.is_link(dirname):
			folder.remove(dirname)
		else:
			_cleanup(path.path_join(dirname))
	DirAccess.remove_absolute(path)
