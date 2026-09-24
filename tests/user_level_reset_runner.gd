extends SceneTree
## 用户关卡清除回归；仅在本轮独占的 user://tests 子树建立和删除数据。

class FailingCatalog extends LevelCatalog:
	var rename_calls: int = 0
	var fail_rename_at: int = 0
	var remove_calls: int = 0
	var fail_remove_at: int = 0
	var fail_builtin_read: bool = false

	## 让第二次暂存失败，检验第一张真实地图是否被恢复。
	func _rename_user_level(source_path: String, destination_path: String) -> Error:
		rename_calls += 1
		if rename_calls == fail_rename_at:
			return ERR_FILE_CANT_WRITE
		return super._rename_user_level(source_path, destination_path)

	## 让最终删除中途失败，检验残余地图恢复与重试行为。
	func _remove_user_level(path: String) -> Error:
		remove_calls += 1
		if remove_calls == fail_remove_at:
			return ERR_FILE_CANT_WRITE
		return super._remove_user_level(path)

	## 模拟无法完整读取内置关卡，确认不会使用不完整排除列表继续清除。
	func _builtin_clear_exclusions() -> DataResult:
		if fail_builtin_read:
			return DataResult.failure("测试：内置关卡读取失败")
		return super._builtin_clear_exclusions()


class FailingDrafts extends GameDraftStore:
	## 保留空批次校验，但拒绝实际记录清除，检验已暂存的地图是否回滚。
	func clear_level_records(level_ids: Array[String]) -> DataResult:
		if not level_ids.is_empty():
			return DataResult.failure("测试：玩家记录清除失败")
		return super.clear_level_records(level_ids)


var _test_root: String
var _checks: int = 0
var _failures: int = 0
var _content: ContentRegistry


## 在场景树初始化后运行，返回统一测试退出码。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖完整删除、草稿隔离、危险路径和失败恢复，全程不修改真实玩家存档。
func _run() -> void:
	_test_root = "user://tests/user_level_reset_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_content = ContentRegistry.new()
	_ok(_content.load_directories(PackedStringArray(["res://data/modules"]), PackedStringArray(["res://data/tiles"])), "读取内置模块和地块")
	_test_complete_clear()
	_test_map_only_and_missing()
	_test_bom_id()
	_test_unsafe_directories()
	_test_links()
	_test_preflight_and_stage_failure()
	_test_record_failure()
	_test_partial_delete_and_retry()
	_remove_test_tree(_test_root)
	print("用户关卡清除回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 删除全部直接 JSON 包括坏文件、重复 ID 和隐藏 JSON，同时保留内置与无关数据。
func _test_complete_clear() -> void:
	var catalog := _catalog("complete/levels")
	var drafts := _drafts("complete/solutions")
	var filenames := ["a.json", "b.JSON", "cached.json"]
	var imported_ids: Array[String] = ["import_a", "import_b", "import_cached"]
	for index in imported_ids.size():
		_write_map(catalog.user_directory.path_join(filenames[index]), imported_ids[index])
		_seed_record(drafts, imported_ids[index])
	_ok(catalog.refresh(_content), "先真实加载三张用户地图")
	_write_text(catalog.user_directory.path_join("cached.json"), "{now broken")
	_write_map(catalog.user_directory.path_join("duplicate.json"), "import_b")
	_write_map(catalog.user_directory.path_join("builtin_duplicate.json"), "level_001")
	_write_text(catalog.user_directory.path_join("invalid.json"), "not json")
	_write_text(catalog.user_directory.path_join("invalid_structure.json"), "{\"id\":\"old_import\",\"invalid\":true}")
	_seed_record(drafts, "old_import")
	_write_map(catalog.user_directory.path_join(".hidden.json"), "hidden_import")
	_seed_record(drafts, "hidden_import")
	var malformed_bytes := "{\"id\":\"broken_encoding\",\"name\":\"".to_ascii_buffer()
	malformed_bytes.append(255)
	malformed_bytes.append_array("\"}".to_ascii_buffer())
	var malformed_file := FileAccess.open(catalog.user_directory.path_join("invalid_encoding.json"), FileAccess.WRITE)
	_check(malformed_file != null, "建立包含非法 UTF-8 的 JSON 测试文件")
	if malformed_file != null:
		malformed_file.store_buffer(malformed_bytes)
		malformed_file.close()
	_seed_record(drafts, "broken_encoding")
	var builtin_before: Dictionary = {}
	for index in range(1, 13):
		var level_id := "level_%03d" % index
		_seed_record(drafts, level_id)
		for kind in ["draft", "progress"]:
			var path := _record_path(drafts, level_id, kind)
			builtin_before[path] = FileAccess.get_file_as_bytes(path)
		var map_path := "res://data/levels/%s.json" % level_id
		builtin_before[map_path] = FileAccess.get_file_as_bytes(map_path)
	_seed_record(drafts, "unrelated_record")
	var retained: Dictionary = {}
	for relative_path in ["complete/settings.json", "complete/original_maps/original.json", "complete/levels/readme.txt", "complete/levels/map.json.backup", "complete/levels/icon.svg", "complete/levels/nested/level.json", "complete/levels/directory.json/keep.txt"]:
		var path := _test_root.path_join(relative_path)
		_write_text(path, "unchanged bytes: " + relative_path)
		retained[path] = FileAccess.get_file_as_bytes(path)
	for kind in ["draft", "progress"]:
		var path := _record_path(drafts, "unrelated_record", kind)
		retained[path] = FileAccess.get_file_as_bytes(path)
	var result := catalog.clear_user_levels(drafts)
	_ok(result, "清除全部九个直接用户 JSON 及其可识别游玩记录")
	if result.is_ok():
		_check(result.value.file_count == 9, "统计包含坏文件、重复、大小写、非法编码和隐藏 JSON")
		_check(result.value.level_ids.size() == 6 and not "level_001" in result.value.level_ids, "ID 去重并排除所有内置 ID")
	for level_id in imported_ids + ["old_import", "hidden_import", "broken_encoding"]:
		_check(not drafts.is_completed(level_id) and drafts.load_draft(level_id).value == null, "对应用户记录和代码装配被清除")
	for path in builtin_before:
		_check(FileAccess.get_file_as_bytes(path) == builtin_before[path], "内置地图与全部内置记录保持字节不变")
	for path in retained:
		_check(FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path) == retained[path], "设置、原始地图、非 JSON、子目录和无关记录均保留")
	for filename in _files(catalog.user_directory):
		_check(filename.get_extension().to_lower() != "json", "成功后不留直接 JSON 恢复副本")
	_check(_directories(catalog.user_directory).size() == 2, "成功后仅保留原有子目录，无隐藏暂存目录")
	_ok(catalog.refresh(_content), "清除后关卡目录可正常刷新")
	_check(catalog.levels.size() == 15 and catalog.levels[14].id == "level_015", "刷新后仅保留第一至第十五关共十五个内置关卡")
	_ok(catalog.clear_user_levels(drafts), "重复清除是无副作用的成功空操作")


## 可选的仅地图清除保留记录；缺失目录和空目录不创建地图或修改草稿。
func _test_map_only_and_missing() -> void:
	var catalog := _catalog("maps_only/custom")
	var drafts := _drafts("maps_only/solutions")
	_write_map(catalog.user_directory.path_join("one.json"), "one")
	_seed_record(drafts, "one")
	var before := _snapshot(drafts.directory)
	_ok(catalog.clear_user_levels(), "不传草稿存储时只删除地图")
	_check(_snapshot(drafts.directory) == before, "仅地图模式保留游玩记录和玩家作品")
	var missing := _catalog("missing/levels")
	_ok(missing.clear_user_levels(drafts), "缺失导入目录为成功空操作")
	_check(not DirAccess.dir_exists_absolute(missing.user_directory), "空操作不创建缺失目录")
	_check(_snapshot(drafts.directory) == before, "缺失导入目录不影响记录")


## 未刷新进显示缓存的 UTF-8 BOM 地图也能提供真实 ID，不会删除地图后漏掉已保存记录。
func _test_bom_id() -> void:
	var catalog := _catalog("bom/levels")
	var drafts := _drafts("bom/solutions")
	var path := catalog.user_directory.path_join("bom.json")
	_write_map(path, "bom_import")
	var source := FileAccess.get_file_as_bytes(path)
	var with_bom := PackedByteArray([0xef, 0xbb, 0xbf])
	with_bom.append_array(source)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "建立含 UTF-8 BOM 的导入地图"):
		file.store_buffer(with_bom)
		file.close()
	_seed_record(drafts, "bom_import")
	_check(catalog.levels.is_empty(), "BOM 地图没有可供回退的已加载 ID 缓存")
	var result := catalog.clear_user_levels(drafts)
	_ok(result, "带 BOM 的地图与其记录能一起清除")
	if result.is_ok():
		_check(result.value.level_ids == ["bom_import"], "正确剥离开头 BOM 后读取唯一用户关卡 ID")
	_check(not FileAccess.file_exists(path), "BOM 地图原件已清除")
	_check(_files(drafts.directory).is_empty(), "BOM 地图的通关、代码装配和恢复备份均已清除")


## 删除入口严格禁止根目录、配置目录、路径跳转和包含关系，失败前不触碰有效地图。
func _test_unsafe_directories() -> void:
	for path in ["user://", "res://data/levels", "user://../levels", "user://levels/../solutions", "user://solutions", "user://data", "user://settings", "user://tests", "user://tests/alone", _test_root.path_join("unsafe/solutions")]:
		var catalog := LevelCatalog.new()
		catalog.user_directory = path
		_error(catalog.clear_user_levels(), "危险删除目录被拒绝：" + path)
	var blocked_path := _test_root.path_join("occupied")
	_write_text(blocked_path, "keep directory blocker")
	var blocked := _catalog("occupied/levels")
	_error(blocked.clear_user_levels(), "目录链被普通文件占用时拒绝")
	_check(FileAccess.get_file_as_string(blocked_path) == "keep directory blocker", "目录占用文件保留")
	var catalog := _catalog("overlap/levels")
	_write_map(catalog.user_directory.path_join("one.json"), "one")
	for records_directory in [catalog.user_directory, catalog.user_directory.path_join("records"), catalog.user_directory.get_base_dir()]:
		_error(catalog.clear_user_levels(GameDraftStore.new(records_directory)), "导入与存档目录包含关系拒绝")
	_check(FileAccess.file_exists(catalog.user_directory.path_join("one.json")), "危险配置没有删除任何地图")


## JSON 链接使整批提前失败；非 JSON 链接原样保留，不读取、改写或删除任何链接目标。
func _test_links() -> void:
	var catalog := _catalog("links/levels")
	_write_map(catalog.user_directory.path_join("one.json"), "one")
	var target := _test_root.path_join("link_target/keep.json")
	_write_text(target, "protected target")
	var folder := DirAccess.open(catalog.user_directory)
	var link_error := folder.create_link(ProjectSettings.globalize_path(target), "linked.json")
	if link_error != OK:
		print("平台不允许创建测试链接，跳过链接用例：%s。" % error_string(link_error))
		return
	_error(catalog.clear_user_levels(), "JSON 文件链接拒绝整批清除")
	_check(folder.is_link("linked.json") and FileAccess.file_exists(catalog.user_directory.path_join("one.json")), "链接与其它地图都保持原位")
	_check(FileAccess.get_file_as_string(target) == "protected target", "链接目标未被删除或修改")
	folder.remove("linked.json")
	_check(folder.create_link(ProjectSettings.globalize_path(target + ".missing"), "broken.JSON") == OK, "建立悬空 JSON 链接")
	_error(catalog.clear_user_levels(), "悬空 JSON 链接也拒绝整批")
	folder.remove("broken.JSON")
	_check(folder.create_link(ProjectSettings.globalize_path(target), "keep_link.txt") == OK, "建立非 JSON 链接")
	_ok(catalog.clear_user_levels(), "非 JSON 链接不会阻止正常地图清除")
	_check(folder.is_link("keep_link.txt") and FileAccess.get_file_as_string(target) == "protected target", "非 JSON 链接和目标均保留")
	var parent_folder := DirAccess.open(_test_root.path_join("links"))
	_check(parent_folder.create_link(ProjectSettings.globalize_path(catalog.user_directory), "linked_levels") == OK, "建立导入目录链接")
	var linked := _catalog("links/linked_levels")
	_error(linked.clear_user_levels(), "拒绝导入目录路径中的符号链接")


## 内置保护列表读取失败先拒绝；地图暂存中途失败时已移动的文件按原始字节恢复。
func _test_preflight_and_stage_failure() -> void:
	var catalog := FailingCatalog.new()
	catalog.user_directory = _test_root.path_join("stage_failure/levels")
	var drafts := _drafts("stage_failure/solutions")
	for level_id in ["one", "two"]:
		_write_map(catalog.user_directory.path_join(level_id + ".json"), level_id)
		_seed_record(drafts, level_id)
	var maps_before := _snapshot(catalog.user_directory)
	var records_before := _snapshot(drafts.directory)
	catalog.fail_builtin_read = true
	_error(catalog.clear_user_levels(drafts), "内置排除 ID 读取失败时拒绝整批")
	_check(_snapshot(catalog.user_directory) == maps_before and _snapshot(drafts.directory) == records_before, "内置保护读取失败无磁盘副作用")
	catalog.fail_builtin_read = false
	catalog.fail_rename_at = 2
	_error(catalog.clear_user_levels(drafts), "第二张地图暂存失败向调用方报告")
	_check(catalog.rename_calls == 3, "第一张已暂存地图确实执行回滚")
	_check(_snapshot(catalog.user_directory) == maps_before and _snapshot(drafts.directory) == records_before, "暂存失败恢复全部地图且尚未清除记录")
	_check(_directories(catalog.user_directory).is_empty(), "回滚后无残留暂存目录")


## 草稿批量清除失败后地图必须恢复，避免丢失用于下一次清除的关卡 ID 来源。
func _test_record_failure() -> void:
	var catalog := _catalog("record_failure/levels")
	var drafts := FailingDrafts.new()
	drafts.directory = _test_root.path_join("record_failure/solutions")
	_write_map(catalog.user_directory.path_join("one.json"), "one")
	_seed_record(drafts, "one")
	var maps_before := _snapshot(catalog.user_directory)
	var records_before := _snapshot(drafts.directory)
	_error(catalog.clear_user_levels(drafts), "记录清除失败不能报告整体成功")
	_check(_snapshot(catalog.user_directory) == maps_before and _snapshot(drafts.directory) == records_before, "记录失败后地图恢复、原记录未变")
	_check(_directories(catalog.user_directory).is_empty(), "记录失败回滚后不留隐藏地图备份")
	_ok(catalog.clear_user_levels(GameDraftStore.new(drafts.directory)), "修复记录存储后可以重试成功")


## 地图部分删除失败恢复剩余地图并报告部分完成；重试后无地图、记录或恢复副本残留。
func _test_partial_delete_and_retry() -> void:
	var catalog := FailingCatalog.new()
	catalog.user_directory = _test_root.path_join("partial_failure/levels")
	var drafts := _drafts("partial_failure/solutions")
	for level_id in ["one", "two", "three"]:
		_write_map(catalog.user_directory.path_join(level_id + ".json"), level_id)
		_seed_record(drafts, level_id)
	catalog.fail_remove_at = 2
	var result := catalog.clear_user_levels(drafts)
	_error(result, "第二张地图删除失败不能报告成功")
	_check("; ".join(result.errors).contains("已清除 1 个地图文件") and "; ".join(result.errors).contains("游玩记录可能已清除"), "错误明确报告地图与游玩记录可能部分删除")
	_check(_files(catalog.user_directory).size() == 2 and _directories(catalog.user_directory).is_empty(), "未删除的两张地图恢复原位，无隐藏备份")
	_check(_files(drafts.directory).is_empty(), "该失败发生在记录成功清除之后")
	catalog.fail_remove_at = 0
	_ok(catalog.clear_user_levels(drafts), "修复后剩余地图能够再次清除")
	_check(_files(catalog.user_directory).is_empty() and _directories(catalog.user_directory).is_empty(), "成功重试不保留任何地图恢复副本")


## 为各用例分别创建导入目录模型，不使用真实 user://levels。
func _catalog(relative_path: String) -> LevelCatalog:
	var catalog := LevelCatalog.new()
	catalog.user_directory = _test_root.path_join(relative_path)
	return catalog


## 为各用例注入独占草稿目录，不访问正式 solutions。
func _drafts(relative_path: String) -> GameDraftStore:
	return GameDraftStore.new(_test_root.path_join(relative_path))


## 使用真实内置地图结构构造可被 MapCodec 和 LevelDefinition 加载的用户地图。
func _write_map(path: String, level_id: String) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/levels/level_001.json"))
	data.id = level_id
	data.name = "Custom " + level_id
	_write_text(path, JSON.stringify(data, "\t") + "\n")


## 创建含代码、装配、通关和恢复副本的完整测试记录。
func _seed_record(drafts: GameDraftStore, level_id: String) -> void:
	_ok(drafts.save_draft(level_id, "main() {}", []), "建立测试代码装配草稿")
	_ok(drafts.mark_completed(level_id), "建立测试通关记录")
	_ok(drafts.backup_draft(level_id), "建立真实恢复备份")


## 按公开存储命名格式定位对应记录，避免调用模型的私有路径函数。
func _record_path(drafts: GameDraftStore, level_id: String, kind: String) -> String:
	return drafts.directory.path_join("%s.%s.json" % [level_id.sha256_text(), kind])


## 原始字节快照包含隐藏文件，防止将暂存副本遗漏在验证范围之外。
func _snapshot(path: String) -> Dictionary:
	var result: Dictionary = {}
	for filename in _files(path):
		result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 枚举直接文件时包含隐藏项；测试不递归读取任何链接目标。
func _files(path: String) -> PackedStringArray:
	var folder := DirAccess.open(path)
	folder.include_hidden = true
	return folder.get_files()


## 枚举所有直接子目录，以检测清除过程遗留的隐藏暂存目录。
func _directories(path: String) -> PackedStringArray:
	var folder := DirAccess.open(path)
	folder.include_hidden = true
	return folder.get_directories()


## 测试写入严格限制在当前独占目录，不能触及玩家原始文件。
func _write_text(path: String, text: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "写入路径限制在本次独占测试目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "测试数据可以写入"):
		file.store_string(text)
		file.close()


## 只递归清理独占测试树，遇到符号链接时删除链接自身而不访问其目标。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
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
			_remove_test_tree(child)
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 成功断言附加底层诊断，不能仅以非空对象作为成功依据。
func _ok(result: DataResult, message: String) -> void:
	_check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；缺少结果"))


## 所有失败均要求含明确原因，供玩家修复权限或路径后重试。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 累计独立断言后统一报告，失败不会影响其它用例清理自身测试文件。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
