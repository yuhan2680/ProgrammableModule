extends SceneTree
## 单张玩家关卡删除回归，全部写盘仅发生在本次独占测试目录。

class FailingCatalog extends LevelCatalog:
	## 模拟操作系统拒绝删除，验证界面可重试且文件和列表不会提前改变。
	func _remove_user_level(_path: String) -> Error:
		return ERR_FILE_NO_PERMISSION


var _checks: int = 0
var _failures: int = 0
var _test_root: String = ""
var _content := ContentRegistry.new()


## 延后到脚本注册完成后开始模型验证。
func _initialize() -> void:
	_run.call_deferred()


## 检查删除边界、真实文件删除及失败恢复，不接触玩家的正式存档。
func _run() -> void:
	_test_root = "user://tests/player_level_delete_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_ok(_content.load_directories(), "读取模块与地块目录")
	_test_single_delete()
	_test_definition_ownership()
	_test_changed_and_missing_file()
	_test_failed_remove()
	_test_protected_directory()
	_test_symbolic_links()
	_cleanup(_test_root)
	print("玩家关卡删除模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 删除只移除本地选中地图，外部导出、其他地图和同 ID 游玩记录全部保留。
func _test_single_delete() -> void:
	var directory := _test_root.path_join("single/levels")
	var target := directory.path_join("target.json")
	var other := directory.path_join("other.json")
	var export_path := _test_root.path_join("single/export/target.json")
	_write_map(target, "delete_target")
	_write_map(other, "keep_other")
	_write_map(export_path, "delete_target")
	var record := _test_root.path_join("single/solutions/delete_target.json")
	_write_text(record, "{\"completed\":true,\"program\":\"main() {}\",\"assembly\":[]}")
	var protected_paths := [other, export_path, record, "res://data/levels/level_001.json"]
	var before: Dictionary = {}
	for path in protected_paths:
		before[path] = FileAccess.get_file_as_bytes(path)
	var catalog := _catalog(directory)
	var selected := _find(catalog, "delete_target")
	if not _check(selected != null, "正式目录载入待删除的有效地图"):
		return
	_check(catalog.can_delete_user_level(selected), "仅本地玩家地图显示删除入口")
	var count := catalog.levels.size()
	var deleted := catalog.delete_user_level(selected)
	if _ok(deleted, "删除当前选中的本地地图"):
		_check(deleted.value.path == target and deleted.value.level_id == "delete_target", "成功返回确切文件与 ID")
	_check(not FileAccess.file_exists(target), "选中地图文件实际从磁盘移除")
	_check(catalog.levels.size() == count - 1 and not catalog.levels.has(selected), "成功后目录内存移除该项")
	_check(not catalog.can_delete_user_level(selected), "删除后旧对象不能再次授权")
	_error(catalog.delete_user_level(selected), "重复删除返回明确失败")
	for path in protected_paths:
		_check(FileAccess.get_file_as_bytes(path) == before[path], "其他地图、外部原件和玩家记录逐字节不变：" + path.get_file())
	_ok(catalog.refresh(_content), "删除后可正常刷新目录")
	_check(_find(catalog, "delete_target") == null and _find(catalog, "keep_other") != null, "刷新后已删卡片消失且其他卡片保留")


## 不能把内置对象、伪造的相同 ID、篡改路径或上次扫描的旧对象当成删除授权。
func _test_definition_ownership() -> void:
	var directory := _test_root.path_join("ownership/levels")
	var target := directory.path_join("owned.json")
	_write_map(target, "owned")
	var catalog := _catalog(directory)
	var selected := _find(catalog, "owned")
	var bytes := FileAccess.get_file_as_bytes(target)
	_error(catalog.delete_user_level(null), "空对象不能删除")
	var builtin := _find(catalog, "level_001")
	_check(not catalog.can_delete_user_level(builtin), "教学关卡没有删除入口")
	_error(catalog.delete_user_level(builtin), "内置关卡不能删除")
	var forged: LevelDefinition = LevelDefinition.from_document(selected.document, _content, target).value
	catalog.levels.append(forged)
	_check(not catalog.can_delete_user_level(forged), "手工追加同 ID 与同路径对象也不能授权")
	_error(catalog.delete_user_level(forged), "伪造的对象不能删除")
	catalog.levels.erase(forged)
	for path in ["res://data/levels/level_001.json", directory.path_join("../outside.json"), ProjectSettings.globalize_path(target), directory.path_join("nested/owned.json")]:
		selected.source_path = path
		_error(catalog.delete_user_level(selected), "对象路径被改写时不能删除：" + path)
	selected.source_path = target
	selected.id = "level_001"
	_error(catalog.delete_user_level(selected), "对象 ID 被改写时不能删除")
	selected.id = "owned"
	catalog.user_directory = _test_root.path_join("ownership/other")
	_error(catalog.delete_user_level(selected), "目录设置改变后旧对象不能删除")
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "刷新恢复当前文件的真实对象")
	_error(catalog.delete_user_level(selected), "刷新前的旧对象不能再用于删除")
	_check(FileAccess.get_file_as_bytes(target) == bytes, "所有越界请求均保留真实地图字节")
	_check(catalog.can_delete_user_level(_find(catalog, "owned")), "当前刷新后的对象仍可正常删除")


## 文件即使保留原 ID 但内容变化，也必须先刷新；文件消失时保持列表以便用户处理错误。
func _test_changed_and_missing_file() -> void:
	var directory := _test_root.path_join("changed/levels")
	var target := directory.path_join("changing.json")
	_write_map(target, "changing")
	var catalog := _catalog(directory)
	var selected := _find(catalog, "changing")
	var replacement := selected.document.duplicate_document()
	replacement.display_name = "External replacement"
	_ok(MapCodec.save_file(replacement, target, _content), "模拟相同 ID 文件被外部更新")
	var changed_bytes := FileAccess.get_file_as_bytes(target)
	_error(catalog.delete_user_level(selected), "相同 ID 的外部替换不会被旧卡片误删")
	_check(FileAccess.get_file_as_bytes(target) == changed_bytes and catalog.levels.has(selected), "外部新内容和旧列表均保留")
	_ok(catalog.refresh(_content), "刷新后读取替换文件")
	_ok(catalog.delete_user_level(_find(catalog, "changing")), "用户重新选择刷新后的地图可以删除")
	_write_map(target, "missing")
	_ok(catalog.refresh(_content), "载入将被外部移除的地图")
	selected = _find(catalog, "missing")
	_check(DirAccess.remove_absolute(target) == OK, "测试主动移除独占目录的地图")
	_error(catalog.delete_user_level(selected), "已不存在的文件给出明确失败")
	_check(catalog.levels.has(selected), "失败时不提前改变目录内存")
	DirAccess.make_dir_recursive_absolute(target)
	_error(catalog.delete_user_level(selected), "同名目录不能被误删")
	_check(DirAccess.dir_exists_absolute(target), "同名目录保留")


## 操作系统删除错误不能改变保存文件，也不能使未成功删除的卡片从目录中消失。
func _test_failed_remove() -> void:
	var directory := _test_root.path_join("failure/levels")
	var target := directory.path_join("blocked.json")
	_write_map(target, "blocked")
	var bytes := FileAccess.get_file_as_bytes(target)
	var catalog := FailingCatalog.new()
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "载入供权限失败测试的地图")
	var selected := _find(catalog, "blocked")
	_error(catalog.delete_user_level(selected), "删除权限失败会传递错误")
	_check(FileAccess.get_file_as_bytes(target) == bytes and catalog.levels.has(selected), "删除失败时文件与卡片保留")
	_check(catalog.can_delete_user_level(selected), "失败后保持授权以便重试")


## 即便错误地把设置目录扫描为关卡目录，也不能通过关卡删除入口移除其中的 JSON。
func _test_protected_directory() -> void:
	var directory := _test_root.path_join("protected/settings")
	var target := directory.path_join("settings.json")
	_write_map(target, "protected")
	var bytes := FileAccess.get_file_as_bytes(target)
	var catalog := _catalog(directory)
	_error(catalog.delete_user_level(_find(catalog, "protected")), "设置目录禁止单张删除")
	_check(FileAccess.get_file_as_bytes(target) == bytes, "设置目录文件保留")


## 文件链接与中途被换成链接的父目录都不能让删除操作跨越托管边界。
func _test_symbolic_links() -> void:
	var directory := _test_root.path_join("links/levels")
	var target := directory.path_join("owned.json")
	var external := _test_root.path_join("links/external/owned.json")
	_write_map(target, "linked")
	_write_map(external, "linked")
	var external_bytes := FileAccess.get_file_as_bytes(external)
	var catalog := _catalog(directory)
	var selected := _find(catalog, "linked")
	var folder := DirAccess.open(directory)
	_check(DirAccess.remove_absolute(target) == OK, "为文件链接用例移除原测试副本")
	var link_error := folder.create_link(ProjectSettings.globalize_path(external), "owned.json")
	if link_error != OK:
		print("当前系统不能创建测试符号链接，跳过链接特有断言：%s" % error_string(link_error))
		return
	_error(catalog.delete_user_level(selected), "加载后被替换成符号链接的文件不能删除")
	_check(folder.is_link("owned.json") and FileAccess.get_file_as_bytes(external) == external_bytes, "链接及外部目标都保留")
	_error(catalog.refresh(_content), "扫描链接地图报告安全错误，不读取链接目标")
	_check(_find(catalog, "linked") == null and FileAccess.get_file_as_bytes(external) == external_bytes, "链接目标未加载且字节保持不变")
	_error(catalog.delete_user_level(_find(catalog, "linked")), "直接载入的链接地图也不能删除")
	DirAccess.remove_absolute(target)
	_write_map(target, "linked")
	_ok(catalog.refresh(_content), "恢复普通文件并建立新授权")
	selected = _find(catalog, "linked")
	var moved := directory + "_original"
	_check(DirAccess.rename_absolute(directory, moved) == OK, "将测试关卡目录暂移")
	var parent := DirAccess.open(directory.get_base_dir())
	if _check(parent.create_link(ProjectSettings.globalize_path(external.get_base_dir()), "levels") == OK, "建立父目录链接"):
		_error(catalog.delete_user_level(selected), "父目录被替换成链接后不能删除")
		_check(FileAccess.get_file_as_bytes(external) == external_bytes and FileAccess.file_exists(moved.path_join("owned.json")), "父目录外部目标与移走的原件均保留")


## 用真实加载流程构造目录，以便删除授权来自实际地图文件。
func _catalog(directory: String) -> LevelCatalog:
	var catalog := LevelCatalog.new()
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "扫描隔离关卡目录")
	return catalog


## 按稳定 ID 找回本轮真实加载的关卡对象。
func _find(catalog: LevelCatalog, level_id: String) -> LevelDefinition:
	for definition in catalog.levels:
		if definition.id == level_id:
			return definition
	return null


## 在本次独占目录写入有效地图，复用内置结构但使用独立 ID。
func _write_map(path: String, level_id: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "地图写入限制在测试目录"):
		return
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	if not _ok(loaded, "读取有效地图模板"):
		return
	var document: MapDocument = loaded.value
	document.id = level_id
	document.display_name = "Player " + level_id
	_ok(MapCodec.save_file(document, path, _content), "保存独立玩家地图")


## 辅助记录只用于验证删除地图不会连带擦除其他文件。
func _write_text(path: String, source: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "记录写入限制在测试目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "测试记录可写入"):
		file.store_string(source)
		file.close()


## 递归清理本次独占目录，遇到符号链接只移除链接本身而不进入目标。
func _cleanup(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var name := folder.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if folder.is_link(name) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		name = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 成功结果附带底层错误文本，便于定位真实文件系统失败。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；没有结果"))


## 失败必须有明确错误信息，不能用空结果伪装成功。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 统计断言并使用非零退出码报告失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
