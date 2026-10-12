extends SceneTree
## 独占目录验证全部玩家文件列表、异常诊断、草稿改名和快照操作保护。

class FailingLibrary extends PlayerLevelLibrary:
	## 模拟系统拒绝原子保存，检查界面快照及文件均保持原样。
	func _write_document(_document: MapDocument, _path: String, _content: ContentRegistry) -> DataResult:
		return DataResult.failure("测试写入失败")

	## 模拟系统拒绝删除，检查条目及授权不提前移除。
	func _remove_file(_path: String) -> Error:
		return ERR_FILE_CANT_WRITE

var _checks := 0
var _failures := 0
var _root := ""
var _content := ContentRegistry.new()


## 等项目全局类初始化后在独占临时目录运行，不触碰真实玩家文件。
func _initialize() -> void:
	_run.call_deferred()


## 按文件状态、字段保留、操作授权和平台真实时间依次验证模型。
func _run() -> void:
	_root = "user://tests/player_level_library_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "载入真实模块和地块"):
		_test_listing()
		_test_alternative_goals()
		_test_newer_versions()
		_test_rename_and_failures()
		_test_snapshot_protection()
		_test_paths_and_links()
		_test_real_creation_time()
	_cleanup(_root)
	print("玩家文件列表模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 坏 JSON、空文件、超限文件及未完成草稿均列出，运行诊断不改旧沙盒规则。
func _test_listing() -> void:
	var directory := _root.path_join("listing/levels")
	var valid := _map("valid")
	valid.properties.level.creator = "Muna"
	_save(directory, "valid.json", valid)
	var draft := _map("draft")
	draft.player_spawn = null
	_save(directory, "draft.json", draft)
	var sandbox := _map("sandbox")
	sandbox.properties.level.erase("goal")
	_save(directory, "sandbox.json", sandbox)
	var combat: MapDocument = MapCodec.load_file("res://data/levels/level_004.json", _content).value
	combat.id = "combat"
	_save(directory, "combat.json", combat)
	_write(directory.path_join("broken.json"), "{broken")
	_write(directory.path_join("empty.JSON"), "")
	var binary := FileAccess.open(directory.path_join("garbled.json"), FileAccess.WRITE)
	binary.store_buffer(PackedByteArray([0x7b, 0xff, 0xc0, 0xaf, 0x7d]))
	binary.close()
	_write(directory.path_join("too_large.json"), " ".repeat(DataValidation.MAX_FILE_BYTES + 1))
	_write(directory.path_join("notes.txt"), "not a map")
	_write(directory.path_join("nested/ignored.json"), "{}")
	var library := _library(directory)
	_check(library.entries.size() == 8, "仅列出直接JSON，不遗漏坏文件也不递归其他目录")
	var selected := _find(library, "valid.json")
	_check(selected != null and selected.display_name == valid.display_name and selected.creator == "Muna" and selected.errors.is_empty() and selected.playable and selected.can_rename and selected.can_edit, "正常地图有真实姓名署名和完整操作")
	selected = _find(library, "draft.json")
	_check(selected != null and not selected.playable and selected.can_edit and selected.can_rename and not selected.errors.is_empty(), "缺出生点草稿不可玩但可编辑及更名")
	selected = _find(library, "sandbox.json")
	_check(selected != null and selected.playable and "缺少必要的终点" in selected.errors, "无目标沙盒显示缺终点诊断但保持既有可玩语义")
	selected = _find(library, "combat.json")
	_check(selected != null and selected.playable and selected.errors.is_empty(), "有效战斗目标不被误报缺终点")
	for filename: String in ["broken.json", "empty.JSON", "garbled.json", "too_large.json"]:
		selected = _find(library, filename)
		_check(selected != null and selected.display_name == filename.get_basename() and selected.creator.is_empty() and not selected.playable and not selected.can_edit and not selected.can_rename and not selected.requires_newer_version and not selected.errors.is_empty(), "坏文件以文件名展示并附诊断：" + filename)
		_check(selected.is_corrupt == (filename != "too_large.json"), "损坏语法和乱码单独标记，超限属于普通诊断")
		_ok(library.get_entry_directory(selected), "坏文件可定位自己的安全目录")
		_error(library.get_entry_edit_path(selected), "坏文件不能伪装成可编辑文档")
		_error(library.rename_entry(selected, "NewName", _content), "坏JSON不能写成丢失内容的新文件")
		_ok(library.delete_entry(selected), "任意坏JSON可安全删除")
		_check(not FileAccess.file_exists(directory.path_join(filename)), "仅目标坏文件被删除")
	_check(FileAccess.file_exists(directory.path_join("valid.json")) and FileAccess.file_exists(directory.path_join("nested/ignored.json")), "删除坏图不影响正常或嵌套文件")


## 已有闪避和分波目标均是有效完成条件，无坐标终点不能产生缺终点警告。
func _test_alternative_goals() -> void:
	var directory := _root.path_join("goals/levels")
	for source: String in ["level_011", "level_012"]:
		var document: MapDocument = MapCodec.load_file("res://data/levels/" + source + ".json", _content).value
		document.id = "player_" + source
		_save(directory, source + ".json", document)
	var clear_enemies: MapDocument = MapCodec.load_file("res://data/levels/level_004.json", _content).value
	clear_enemies.id = "clear_enemies"
	clear_enemies.properties.level.erase("goal")
	clear_enemies.properties.level.completion_mode = "reach_or_clear"
	clear_enemies.properties.level.max_ticks = 600
	_save(directory, "clear_enemies.json", clear_enemies)
	clear_enemies.id = "disabled_enemies"
	clear_enemies.properties.level.enemies_enabled = false
	_save(directory, "disabled_enemies.json", clear_enemies)
	var library := _library(directory)
	for filename: String in ["level_011.json", "level_012.json", "clear_enemies.json"]:
		var record := _find(library, filename)
		_check(record != null and record.playable and record.errors.is_empty(), "合法替代目标不显示缺少终点：" + filename)
	var disabled := _find(library, "disabled_enemies.json")
	_check(disabled != null and disabled.playable and "缺少必要的终点" in disabled.errors, "关闭敌人后不再以清敌作为有效目标，仅追加诊断")


## 高版本及未知合法内容单独标注，负版本、非法引用和普通损坏仍是普通异常。
func _test_newer_versions() -> void:
	var directory := _root.path_join("versions/levels")
	var cases := {"new_version": "version", "old_invalid": "negative", "new_module": "module", "new_tile": "tile", "bad_module": "badmodule", "new_allowed": "allowed", "new_restricted": "restricted", "bad_structure": "structure", "bad_then_new": "mixed"}
	for id: String in cases:
		var data := _map(id).to_dict()
		match cases[id]:
			"version": data.format_version = 2
			"negative": data.format_version = -1
			"module": data.player_spawn.modules[0].module_id = "future_module"
			"badmodule": data.player_spawn.modules[0].module_id = 44
			"mixed": data.properties.level.allowed_modules = [44, "future_allowed"]
			"tile": data.tiles[0].tile_id = "future_tile"
			"allowed": data.properties.level.allowed_modules = ["future_allowed"]
			"restricted": data.properties.level.restricted_modules = ["future_restricted"]
			"structure": data.width = "not_a_dimension"
		_write(directory.path_join(id + ".json"), JSON.stringify(data))
	var duplicate := _map("duplicate")
	_save(directory, "duplicate1.json", duplicate)
	_save(directory, "duplicate2.json", duplicate)
	_save(directory, "builtin_duplicate.json", _map("level_001"))
	var library := _library(directory)
	for id: String in cases:
		var record := _find(library, id + ".json")
		_check(record != null and record.requires_newer_version == id.begins_with("new_") and not record.is_corrupt and not record.errors.is_empty() and not record.playable, "版本问题与普通坏图分别判断：" + id)
	for filename: String in ["duplicate1.json", "duplicate2.json", "builtin_duplicate.json"]:
		var record := _find(library, filename)
		_check(record != null and not record.playable and record.can_edit and record.can_rename and "ID 重复" in " ".join(record.errors), "同ID文件仍可管理但标明游玩冲突：" + filename)


## 草稿名称更新保留原 ID、路径、未知字段及游玩记录，失败无任何提前提交。
func _test_rename_and_failures() -> void:
	var directory := _root.path_join("rename/levels")
	var document := _map("rename")
	document.player_spawn = null
	document.display_name = "旧名称 % 🦈".repeat(12)
	document.properties.level.creator = "作".repeat(128)
	document.extra = {"custom": {"nested": [1, "保留"]}}
	document.dialogue = [{"text": "# 引导", "format": "markdown", "extra": true}]
	_save(directory, "owned.json", document)
	var records := _root.path_join("rename/solutions/rename.json")
	_write(records, "keep progress")
	var library := _library(directory)
	var selected := _find(library, "owned.json")
	_check(selected.display_name == document.display_name and selected.creator == document.properties.level.creator, "旧长名称和旧长署名完整读取")
	var original := FileAccess.get_sha256(selected.source_path)
	for name: String in ["", " 空格", "中间 空格", "百分%", "表情🦈", "x".repeat(31)]:
		_error(library.rename_entry(selected, name, _content), "模型拒绝非法新名称：" + name)
		_check(FileAccess.get_sha256(selected.source_path) == original and selected.display_name == document.display_name, "拒绝输入不写盘也不改卡片")
	var name := "𠀀".repeat(30)
	_ok(library.rename_entry(selected, name, _content), "恰好30字符可为未完成草稿重命名")
	var loaded := MapCodec.load_file(selected.source_path, _content, false)
	_ok(loaded, "更名后的草稿仍可读取")
	document.display_name = name
	_check(JSON.parse_string(JSON.stringify(loaded.value.to_dict())) == JSON.parse_string(JSON.stringify(document.to_dict())), "只修改显示名，其他扩展内容完整保留")
	_check(selected.display_name == name and selected.creator.length() == 128 and selected.source_path == directory.path_join("owned.json"), "模型快照同步名称且保留路径与旧作者")
	_ok(library.get_entry_edit_path(selected), "更名后的同一条目立即可编辑")
	_check(FileAccess.get_file_as_string(records) == "keep progress", "更名保留正式游玩记录")
	var failing := FailingLibrary.new()
	failing.user_directory = directory
	_ok(failing.refresh(_content), "模拟写盘拒绝仍可读取列表")
	selected = _find(failing, "owned.json")
	original = FileAccess.get_sha256(selected.source_path)
	_error(failing.rename_entry(selected, "Denied", _content), "写盘失败向上返回")
	_error(failing.delete_entry(selected), "删除失败向上返回")
	_check(FileAccess.get_sha256(selected.source_path) == original and selected.display_name == name and failing.entries.has(selected), "系统失败保留条目及原文件")
	_ok(failing.get_entry_edit_path(selected), "失败后原文件快照仍有效")


## 外部替换、伪造对象、改路径和刷新后的旧对象均不能进入文件操作。
func _test_snapshot_protection() -> void:
	var directory := _root.path_join("snapshot/levels")
	_save(directory, "owned.json", _map("snapshot"))
	var library := _library(directory)
	var selected := _find(library, "owned.json")
	var forged := PlayerLevelRecord.new()
	forged.source_path = selected.source_path
	forged.can_edit = true
	_assert_rejected(library, forged, "伪造对象")
	var path := selected.source_path
	selected.source_path = "res://data/levels/level_001.json"
	_assert_rejected(library, selected, "伪造内置路径")
	selected.source_path = path
	library.user_directory = _root.path_join("snapshot/other")
	_assert_rejected(library, selected, "偷换目录")
	library.user_directory = directory
	_ok(library.refresh(_content), "刷新创建新授权")
	_assert_rejected(library, selected, "旧对象")
	selected = _find(library, "owned.json")
	var changed := _map("replacement")
	_save(directory, "owned.json", changed)
	_assert_rejected(library, selected, "外部改写")
	_check(MapCodec.load_file(path, _content).value.id == "replacement", "所有过期操作均保留外部新内容")
	_ok(library.refresh(_content), "重新扫描外部改写后的地图")
	selected = _find(library, "owned.json")
	_ok(library.delete_entry(selected), "刷新后的新授权可以删除当前文件")
	_assert_rejected(library, selected, "已经删除的对象")


## 安全目录拒绝越界与符号链接，坏链接不会取得外部文件的删除或改名权限。
func _test_paths_and_links() -> void:
	for directory: String in ["res://data/levels", "user://", "user://settings", "user://levels/../settings", _root.path_join("unsafe/solutions")]:
		var library := PlayerLevelLibrary.new()
		library.user_directory = directory
		_error(library.refresh(_content), "拒绝不属于玩家目录的路径：" + directory)
	var directory := _root.path_join("links/levels")
	var library := _library(directory)
	_check(library.entries.is_empty() and not DirAccess.dir_exists_absolute(directory), "扫描空目录不隐式创建目录")
	var external := _root.path_join("links/external.json")
	_write(external, "external bytes")
	DirAccess.make_dir_recursive_absolute(directory)
	var folder := DirAccess.open(directory)
	var link_error := folder.create_link(ProjectSettings.globalize_path(external), "linked.json")
	if link_error == OK:
		_ok(library.refresh(_content), "链接文件也可安全报告异常")
		var linked := _find(library, "linked.json")
		_check(linked != null and not linked.errors.is_empty() and not linked.can_edit, "链接作为不可操作异常列出")
		_assert_rejected(library, linked, "符号链接")
		_check(FileAccess.get_file_as_string(external) == "external bytes", "链接目标始终保持原字节")
	_save(directory, "replace.json", _map("link_replace"))
	_ok(library.refresh(_content), "建立可操作文件快照")
	var selected := _find(library, "replace.json")
	DirAccess.remove_absolute(selected.source_path)
	if folder.create_link(ProjectSettings.globalize_path(external), "replace.json") == OK:
		_assert_rejected(library, selected, "文件换为符号链接")
		_check(FileAccess.get_file_as_string(external) == "external bytes", "替换链接不能改写外部文件")
	var parent := DirAccess.open(_root.path_join("links"))
	if parent.create_link(ProjectSettings.globalize_path(directory), "linked_directory") == OK:
		library.user_directory = _root.path_join("links/linked_directory")
		_error(library.refresh(_content), "目录链符号链接也被拒绝")


## 创建日期使用真实出生时间，修改时间刻意改为未来后也不能被误当成创建时间。
func _test_real_creation_time() -> void:
	var directory := _root.path_join("date's space/levels")
	_save(directory, "date.json", _map("date"))
	var path := directory.path_join("date.json")
	if OS.get_name() == "macOS":
		OS.execute("/usr/bin/touch", PackedStringArray(["-mt", "203001010101.01", ProjectSettings.globalize_path(path)]))
	var library := _library(directory)
	var selected := _find(library, "date.json")
	if OS.get_name() == "macOS":
		_check(selected.created_at > 0 and selected.created_at < FileAccess.get_modified_time(path) and selected.created_at <= int(Time.get_unix_time_from_system()), "macOS真实创建时间与刻意设为未来的mtime独立")
	else:
		_check(selected.created_at >= 0 and selected.created_at <= int(Time.get_unix_time_from_system()), "其他平台时间可为真实值或明确未知")


## 四个操作都必须拒绝无效目标，不能由UI绕过模型保护。
func _assert_rejected(library: PlayerLevelLibrary, record: PlayerLevelRecord, reason: String) -> void:
	_error(library.rename_entry(record, "SafeName", _content), reason + "不能重命名")
	_error(library.delete_entry(record), reason + "不能删除")
	_error(library.get_entry_directory(record), reason + "不能打开目录")
	_error(library.get_entry_edit_path(record), reason + "不能编辑")


## 只使用测试目录建立资料库并断言目录级读取成功。
func _library(directory: String) -> PlayerLevelLibrary:
	var library := PlayerLevelLibrary.new()
	library.user_directory = directory
	_ok(library.refresh(_content), "读取独占玩家文件目录")
	return library


## 从可信教学地图复制结构，改成独立玩家ID供各类夹具使用。
func _map(id: String) -> MapDocument:
	var document: MapDocument = MapCodec.load_file("res://data/levels/level_001.json", _content).value
	document.id = id
	document.display_name = "Player_" + id
	return document


## 按文件名取得本轮实际授权对象，绝不依赖UI传来的伪造ID。
func _find(library: PlayerLevelLibrary, filename: String) -> PlayerLevelRecord:
	for record in library.entries:
		if record.source_path.get_file() == filename:
			return record
	return null


## 草稿夹具也通过真实编码器写入，覆盖实际保存格式。
func _save(directory: String, filename: String, document: MapDocument) -> void:
	_ok(MapCodec.save_file(document, directory.path_join(filename), _content, false), "保存测试草稿：" + filename)


## 损坏字节夹具只写本轮独占目录。
func _write(path: String, source: String) -> void:
	if not _check(path.begins_with(_root + "/"), "夹具仅写测试目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "测试文件可创建"):
		file.store_string(source)
		file.close()


## 清理隔离测试数据时链接只移除链接本身，不跟随目标。
func _cleanup(path: String) -> void:
	if not (path == _root or path.begins_with(_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for filename in folder.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in folder.get_directories():
		if folder.is_link(dirname):
			DirAccess.remove_absolute(path.path_join(dirname))
		else:
			_cleanup(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## 成功边界附带底层错误供失败时定位。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；没有返回值"))


## 失败边界不允许同时返回可用内容。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and result.value == null and not result.errors.is_empty(), message)


## 汇总失败并令进程返回非零状态，所有断言不依赖真实用户数据。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
