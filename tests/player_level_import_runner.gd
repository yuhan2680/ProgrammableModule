extends SceneTree
## 原生选文件之后的数据导入回归；只写独占目录，检查正式目录可见性与来源保护。

class FailingStore extends PlayerLevelStore:
	var write_attempts := 0

	## 在完成去重后模拟底层写盘失败，不能产生成功身份或残留地图。
	func _write_document(_document: MapDocument, _path: String, _registry: ContentRegistry) -> DataResult:
		write_attempts += 1
		return DataResult.failure("测试：托管目录写入失败")


var _checks := 0
var _failures := 0
var _test_root := ""
var _content := ContentRegistry.new()


## 延后运行，确保项目脚本类已初始化。
func _initialize() -> void:
	_run.call_deferred()


## 验证成功导入、冲突保护、无效来源与写盘失败后清理本轮独占数据。
func _run() -> void:
	_test_root = "user://tests/player_level_import_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "加载真实内容注册表"):
		_test_roundtrip()
		_test_collisions()
		_test_invalid_sources()
		_test_failed_writes()
		_test_managed_directory_protection()
	_cleanup(_test_root)
	print("玩家关卡导入模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 中文和空格文件名可用绝对路径导入，署名、引导和各层扩展内容完整保留。
func _test_roundtrip() -> void:
	var store := _store("roundtrip")
	var document := _map("downloaded_map")
	document.display_name = "下载的关卡 · Muna"
	document.properties.level.creator = "Muna"
	document.properties.level.restricted_modules = ["radar", "rangefinder"]
	document.properties.custom = {"nested": [3, "保留"]}
	document.properties.level.custom_rule = {"enabled": true}
	document.extra = {"custom_package": {"version": 2, "notes": ["原文"]}}
	document.dialogue = [{"text": "# 我的关卡\n欢迎 **Muna**", "format": "markdown", "extra_page": [1, 2]}]
	var cell: Vector2i = document.cells.keys()[0]
	document.cell_extras[cell] = {"custom_tile": {"value": 8}}
	document.player_spawn.custom_spawn = "keep"
	var source := _source("下载关卡 空格.JSON", document.to_dict())
	var original := FileAccess.get_file_as_bytes(source)
	var imported := store.import_file(ProjectSettings.globalize_path(source), _content)
	if not _ok(imported, "从任意绝对路径及大写JSON扩展名导入"):
		return
	var path: String = imported.value.path
	var persisted: MapDocument = imported.value.document
	_check(path.get_base_dir() == store.directory and path != source, "导入成功仅返回直接托管目录中的独立副本")
	_check(persisted.id == document.id and persisted != document, "无冲突地图保持ID且返回独立文档")
	var loaded := MapCodec.load_file(path, _content, true)
	if _ok(loaded, "导入副本可由正式地图读取器重新加载"):
		_check(_json_equal(loaded.value.to_dict(), document.to_dict()), "署名、引导、限制、出生点及所有未知扩展字段无损往返")
	_check(FileAccess.get_file_as_bytes(source) == original, "下载来源的字节与排版保持原样")
	_check(_snapshot(store.directory).size() == 1, "原子写盘没有遗留临时文件或备份")
	var catalog := LevelCatalog.new()
	catalog.user_directory = store.directory
	_ok(catalog.refresh(_content), "正式关卡目录能刷新导入结果")
	var level := _find_level(catalog, persisted.id)
	_check(catalog.errors.is_empty() and catalog.levels.size() == 17 and level != null, "导入完成后十六个教学关卡及新玩家关卡均可见")
	if level != null:
		_check(level.creator == "Muna" and level.source_path == path and level.document.dialogue == persisted.dialogue, "关卡卡片署名及游戏引导读取托管副本")
	# UI 持有返回文档时继续编辑，不能通过共享容器修改已经写入磁盘的副本。
	persisted.properties.level.creator = "Later edit"
	_check(MapCodec.load_file(path, _content, true).value.properties.level.creator == "Muna", "修改返回对象不改变已保存地图")


## 重复下载、内置ID及已托管来源均只生成新身份，不覆盖任何已存在文件。
func _test_collisions() -> void:
	var store := _store("collisions")
	var source := _source("duplicate.json", _map("downloaded").to_dict())
	var original := FileAccess.get_file_as_bytes(source)
	var first := store.import_file(source, _content)
	var second := store.import_file(source, _content)
	if not _ok(first, "首次导入重复测试地图") or not _ok(second, "再次导入同一文件仍成功"):
		return
	_check(first.value.path != second.value.path and second.value.document.id == "downloaded_2", "相同来源重复导入自动去重文件与地图身份")
	var first_bytes := FileAccess.get_file_as_bytes(first.value.path)
	var second_bytes := FileAccess.get_file_as_bytes(second.value.path)
	var managed_copy := store.import_file(ProjectSettings.globalize_path(first.value.path), _content)
	if _ok(managed_copy, "选择已托管地图时仍复制为新地图"):
		_check(managed_copy.value.document.id == "downloaded_3" and managed_copy.value.path != first.value.path, "已托管来源不能自动成为覆盖绑定")
	_check(FileAccess.get_file_as_bytes(first.value.path) == first_bytes and FileAccess.get_file_as_bytes(second.value.path) == second_bytes and FileAccess.get_file_as_bytes(source) == original, "重复导入不改原件或已有两张地图")
	var builtin_path := "res://data/levels/level_001.json"
	var builtin_bytes := FileAccess.get_file_as_bytes(builtin_path)
	var builtin := store.import_file(builtin_path, _content)
	if _ok(builtin, "与内置教学ID相同的地图可导入副本"):
		_check(builtin.value.document.id == "level_001_2" and FileAccess.get_file_as_bytes(builtin_path) == builtin_bytes, "教学ID去重后内置源文件保持完整")
	_write_text(store.directory.path_join("player_filename_collision.json"), "keep invalid file")
	DirAccess.make_dir_recursive_absolute(store.directory.path_join("player_filename_collision_2.json"))
	var occupied := store.import_file(_source("occupied.json", _map("filename_collision").to_dict()), _content)
	if _ok(occupied, "坏文件和目录同名不会阻止找到新的存放位置"):
		_check(occupied.value.path.ends_with("player_filename_collision_3.json") and FileAccess.get_file_as_string(store.directory.path_join("player_filename_collision.json")) == "keep invalid file", "文件与目录占位均跳过且保留旧数据")


## 来源格式或关卡定义不合格时，不能先写入副本让正式目录留下损坏条目。
func _test_invalid_sources() -> void:
	var store := _store("invalid")
	var good_source := _source("good_before_invalid.json", _map("stable").to_dict())
	_ok(store.import_file(good_source, _content), "建立无效导入测试中的有效玩家地图")
	var before := _snapshot(store.directory)
	var cases: Dictionary = {
		"syntax.json": "{broken",
		"array.json": "[]",
		"empty.json": "",
		"wrong.txt": JSON.stringify(_map("wrong_extension").to_dict()),
	}
	var no_spawn := _map("no_spawn").to_dict()
	no_spawn.player_spawn = null
	cases["no_spawn.json"] = JSON.stringify(no_spawn)
	var missing_tile := _map("missing_tile").to_dict()
	missing_tile.tiles[0].tile_id = "not_installed_tile"
	cases["missing_tile.json"] = JSON.stringify(missing_tile)
	var missing_module := _map("missing_module").to_dict()
	missing_module.player_spawn.modules[0].module_id = "not_installed_module"
	cases["missing_module.json"] = JSON.stringify(missing_module)
	var invalid_rule := _map("invalid_rule").to_dict()
	invalid_rule.properties.level.module_limit = 0
	cases["invalid_rule.json"] = JSON.stringify(invalid_rule)
	var invalid_goal := _map("invalid_goal").to_dict()
	invalid_goal.properties.level.goal = {"type": "destroy_enemy", "enemy_id": "unknown_enemy"}
	cases["invalid_goal.json"] = JSON.stringify(invalid_goal)
	var unknown_allowed := _map("unknown_allowed").to_dict()
	unknown_allowed.properties.level.allowed_modules = ["not_installed_module"]
	cases["unknown_allowed.json"] = JSON.stringify(unknown_allowed)
	var invalid_version := _map("invalid_version").to_dict()
	invalid_version.format_version = 99
	cases["invalid_version.json"] = JSON.stringify(invalid_version)
	for filename: String in cases:
		var path := _test_root.path_join("downloads").path_join(filename)
		_write_text(path, cases[filename])
		var source_bytes := FileAccess.get_file_as_bytes(path)
		_error(store.import_file(path, _content), "无效来源被拒绝：" + filename)
		_check(_snapshot(store.directory) == before and FileAccess.get_file_as_bytes(path) == source_bytes, "失败时玩家目录与来源完全不变：" + filename)
	for path in ["", _test_root.path_join("downloads/missing.json")]:
		_error(store.import_file(path, _content), "空路径或不可读取文件返回明确失败")
	_error(store.import_file(good_source, null), "没有注册表不能导入关卡")
	var directory_source := _test_root.path_join("downloads/directory.json")
	DirAccess.make_dir_recursive_absolute(directory_source)
	_error(store.import_file(directory_source, _content), "以JSON命名的目录不能作为可读取关卡")
	var too_large := _test_root.path_join("downloads/too_large.json")
	_write_text(too_large, " ".repeat(DataValidation.MAX_FILE_BYTES + 1))
	_error(store.import_file(too_large, _content), "超过既有8MiB上限的来源不能导入")
	_check(_snapshot(store.directory) == before, "全部错误路径都没有产生半成品或覆盖有效地图")
	var fresh := _store("invalid_without_destination")
	_error(fresh.import_file(_test_root.path_join("downloads/invalid_rule.json"), _content), "不满足关卡规则的新来源被拒绝")
	_check(not DirAccess.dir_exists_absolute(fresh.directory), "先验证来源，失败不创建托管目录")


## 正式写入失败保持来源和已有关卡原样，只向调用方返回错误。
func _test_failed_writes() -> void:
	var store := _store("write_failure")
	var source := _source("failed_write.json", _map("existing").to_dict())
	_ok(store.import_file(source, _content), "建立写盘失败保护的有效地图")
	var before := _snapshot(store.directory)
	var original := FileAccess.get_file_as_bytes(source)
	var failing := FailingStore.new()
	failing.directory = store.directory
	var result := failing.import_file(source, _content)
	_error(result, "去重完成后写盘失败明确返回")
	_check(result.value == null and failing.write_attempts == 1, "失败不公布尚未写出的新地图身份或路径")
	_check(_snapshot(store.directory) == before and FileAccess.get_file_as_bytes(source) == original, "写盘失败无残留且不修改已有文件或下载原件")
	_error(failing.import_file(_test_root.path_join("downloads/invalid_rule.json"), _content), "无效关卡在底层写盘前拒绝")
	_check(failing.write_attempts == 1, "关卡语义校验失败从未进入保存边界")


## 导入与编辑保存共用托管目录保护，不能经坏路径或符号链接覆盖外部文件。
func _test_managed_directory_protection() -> void:
	var source := _source("protected.json", _map("protected").to_dict())
	var original := FileAccess.get_file_as_bytes(source)
	var store := PlayerLevelStore.new()
	for directory in ["res://data/levels", "user://", _test_root.path_join("levels/../solutions")]:
		store.directory = directory
		_error(store.import_file(source, _content), "导入拒绝不安全的托管目录：" + directory)
	var blocker := _test_root.path_join("blocked_parent")
	_write_text(blocker, "keep blocker")
	store.directory = blocker.path_join("levels")
	_error(store.import_file(source, _content), "目标父目录被文件占用时导入失败")
	_check(FileAccess.get_file_as_string(blocker) == "keep blocker", "目标占位文件没有被删除或改写")
	var parent_path := _test_root.path_join("linked_parent")
	DirAccess.make_dir_recursive_absolute(parent_path)
	var target_path := _test_root.path_join("link_target")
	DirAccess.make_dir_recursive_absolute(target_path)
	var parent := DirAccess.open(parent_path)
	var link_error := parent.create_link(ProjectSettings.globalize_path(target_path), "levels")
	if link_error == OK:
		store.directory = parent_path.path_join("levels")
		_error(store.import_file(source, _content), "托管目录链接不能作为导入目标")
		_check(DirAccess.get_files_at(target_path).is_empty() and parent.is_link("levels"), "链接本体保留且外部目标无新文件")
	else:
		print("平台不支持测试符号链接，跳过：%s。" % error_string(link_error))
	_check(FileAccess.get_file_as_bytes(source) == original, "所有目标错误均不会改动下载来源")


## 每个场景拥有独立托管目录，不触碰真实玩家关卡。
func _store(name: String) -> PlayerLevelStore:
	var store := PlayerLevelStore.new()
	store.directory = _test_root.path_join(name).path_join("levels")
	return store


## 基于真实教学关卡创建带独立身份的合法来源，保留真实规则和资源引用。
func _map(id: String) -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content, true)
	var document: MapDocument = loaded.value
	document.id = id
	document.display_name = "Player " + id
	return document


## 来源夹具采用紧凑JSON排版，证明导入只解析副本而不会重写原件。
func _source(filename: String, data: Dictionary) -> String:
	var path := _test_root.path_join("downloads").path_join(filename)
	_write_text(path, JSON.stringify(data, "", false))
	return path


## 按稳定地图ID查找正式目录中的玩家关卡。
func _find_level(catalog: LevelCatalog, id: String) -> LevelDefinition:
	for level: LevelDefinition in catalog.levels:
		if level.id == id:
			return level
	return null


## JSON往返比较数值语义，避免整数和解析后浮点表示差异造成误报。
func _json_equal(left: Dictionary, right: Dictionary) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))


## 读取直接文件的字节快照，包括隐藏临时文件，不跟随目录或链接。
func _snapshot(path: String) -> Dictionary:
	var result: Dictionary = {}
	var folder := DirAccess.open(path)
	if folder == null:
		return result
	folder.include_hidden = true
	for filename in folder.get_files():
		if not folder.is_link(filename):
			result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 测试夹具只能写入本次测试的独占目录。
func _write_text(path: String, source: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "夹具写入限制在独占目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "测试来源能够写入"):
		file.store_string(source)
		file.close()


## 清理独占测试目录，遇到链接只删除链接自身，不进入其目标。
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


## 同时记录成功断言和底层错误文本，方便定位独立数据回归问题。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；没有结果"))


## 失败必须有明确错误且不能暴露伪成功值。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty() and result.value == null, message)


## 统计全部断言，使任何错误都对应非零退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
