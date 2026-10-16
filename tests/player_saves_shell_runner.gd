extends SceneTree
## 保存目录解析、旧文件迁移与外壳各入口的定向集成，所有读写均留在独占测试根。

class TestShell extends GameShell:
	var storage_requests := 0
	var upgrade_requests := 0
	var notices: Array[String] = []

	## 只截断真实系统授权窗口，保留调用次数以检验入口门禁，避免测试抢占桌面。
	func _request_player_storage() -> void:
		storage_requests += 1

	## 捕获取消和失败提示而不弹出阻塞窗口，其他页面仍使用真实控件。
	func _show_message(title_text: String, body: String) -> void:
		notices.append(title_text + "\n" + body)

var _checks := 0
var _failures := 0
var _root := ""
var _content := ContentRegistry.new()


## 延后进入场景树，禁止创建或读取真实用户的保存位置配置。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 分别覆盖显式注入、外部迁移成功、取消授权和迁移失败重试四条真实外壳路径。
func _run() -> void:
	_root = "user://tests/player_saves_shell_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_ok(PlayerLevelPaths.register_test_root(_root), "注册独占外部测试根")
	_ok(_content.load_directories(), "加载内置内容定义")
	await _test_injected_directory()
	await _test_external_migration()
	await _test_cancel_authorization()
	await _test_retry_migration()
	PlayerLevelPaths.clear_external_root()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("玩家关卡保存入口回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 显式目录和既有设置注入均不触发正式位置解析，保护历史测试及独立调用者。
func _test_injected_directory() -> void:
	var directory := _root.path_join("explicit/levels")
	var game := _shell("explicit")
	game.user_levels_directory = directory
	await _mount(game)
	_check(game._player_storage_ready and game.catalog.user_directory == directory, "显式目录直接传给 Catalog")
	_check(game.player_save_location == null and game.storage_requests == 0, "显式目录不加载正式保存位置或请求授权")
	game._show_player_level_list_page()
	_check(game.player_level_library.user_directory == directory, "文件管理入口沿用显式目录")
	game._open_editor()
	_check(game._editor != null and game._editor.player_levels_directory == directory and game._editor._player_level_store().directory == directory, "编辑器及其 Store 沿用显式目录")
	_check(not FileAccess.file_exists(game.player_saves_journal), "显式注入不执行旧存档迁移")
	await _release(game)
	var compatible := _shell("compatible")
	await _mount(compatible)
	_check(compatible._player_storage_ready and compatible.user_levels_directory == _root.path_join("compatible/levels"), "旧测试只注入设置路径时自动隔离关卡目录")
	_check(compatible.player_save_location == null, "旧测试兼容路径不触发真实平台默认值")
	await _release(compatible)


## 启动只创建目标目录；用户逐条迁移后列表、导入与编辑沿用同一个外部根。
func _test_external_migration() -> void:
	var game := _shell("external")
	game.player_save_location = _location("external")
	var source := game.player_saves_source.path_join("kept.json")
	_ok(MapCodec.save_file(_map("migrated_shell"), source, _content), "准备旧目录真实地图")
	var second_source := game.player_saves_source.path_join("second.json")
	_ok(MapCodec.save_file(_map("second_shell"), second_source, _content), "准备另一张待迁移旧图")
	var old_bytes := FileAccess.get_file_as_bytes(source)
	await _mount(game)
	var expected := ProjectSettings.globalize_path(_root.path_join("external/Documents")).path_join(PlayerLevelPaths.SAVE_SUFFIX)
	var migrated := expected.path_join("kept.json")
	_check(game._player_storage_ready and game.user_levels_directory == expected and game.catalog.user_directory == expected, "正式准备路径只解析并创建外部根")
	_check(not FileAccess.file_exists(migrated) and FileAccess.get_file_as_bytes(source) == old_bytes and not FileAccess.file_exists(game.player_saves_journal), "首次启动不复制旧图或创建迁移记录")
	_check(_find(game.catalog, "migrated_shell") == null and game.upgrade_requests == 1, "旧图未进入新选关目录且升级仅提示一次")
	game._show_player_level_list_page()
	_check(game.player_level_library.user_directory == expected and game.player_level_library.entries.size() == 2, "列表聚合两张未迁移旧图")
	var legacy := _legacy_entry(game, "kept.json")
	_check(legacy != null, "旧关卡以目录错误条目保留在列表")
	game._migrate_player_entry(legacy)
	_check(FileAccess.get_file_as_bytes(migrated) == old_bytes and FileAccess.get_file_as_bytes(source) == old_bytes, "用户单条迁移只复制选中地图且保留其旧备份")
	_check(not FileAccess.file_exists(expected.path_join("second.json")) and _legacy_entry(game, "second.json") != null, "未选中的旧图保持等待迁移")
	_check(_find(game.catalog, "migrated_shell") != null and FileAccess.file_exists(game.player_saves_journal), "手动迁移后才更新新选关目录与完成记录")
	game._open_editor(migrated, true)
	_check(game._editor != null and game._editor.initial_map_opened and game._editor.player_levels_directory == expected, "重开迁移地图传入相同编辑器保存根")
	if game._editor != null:
		game._editor._save_player_level()
		_check(game._editor.editor_document.path == migrated and game._editor._managed_save_path == migrated, "编辑器保存绑定原迁移副本而不产生第二张地图")
	game._show_level_page()
	var import_source := _root.path_join("external/download/import.json")
	_ok(MapCodec.save_file(_map("import_shell"), import_source, _content), "准备导入来源")
	var import_bytes := FileAccess.get_file_as_bytes(import_source)
	game._level_import_pending = true
	game._on_level_file_selected(ProjectSettings.globalize_path(import_source))
	var imported := _find(game.catalog, "import_shell")
	_check(imported != null and imported.source_path.get_base_dir() == expected, "真实导入完成回调把副本写入外部目录")
	_check(FileAccess.get_file_as_bytes(import_source) == import_bytes and FileAccess.get_file_as_bytes(source) == old_bytes, "导入和编辑不改下载原件及旧目录")
	_check(game.drafts.directory == _root.path_join("external/solutions") and game.settings.storage_path == _root.path_join("external/settings.json"), "关卡搬迁不改变设置或代码草稿目录")
	game._show_player_level_list_page()
	game._migrate_player_entry(_legacy_entry(game, "second.json"))
	_check(game._legacy_upgrade_state.get("retired", false) and not DirAccess.dir_exists_absolute(game.player_saves_source), "最后一张手动迁移后清理已验证旧备份并永久退役")
	_check(FileAccess.file_exists(expected.path_join("second.json")) and game.player_level_library.legacy_directory.is_empty(), "新副本保留且列表停用旧目录")
	await _release(game)
	var restarted := _shell("external")
	restarted.player_save_location = _location("external")
	await _mount(restarted)
	_check(restarted.upgrade_requests == 0 and restarted._legacy_upgrade_state.get("retired", false), "退役后重启不会重复提示或扫描旧目录")
	await _release(restarted)


## 沙盒未授权与取消仅保持门禁；已有旧地图保留，不能向旧目录后备写入。
func _test_cancel_authorization() -> void:
	var game := _shell("denied")
	var location := _location("denied")
	location.sandboxed = true
	location.granted_directories = PackedStringArray()
	game.player_save_location = location
	var source := game.player_saves_source.path_join("old.json")
	_ok(MapCodec.save_file(_map("denied_source"), source, _content), "准备未授权场景旧地图")
	var original := FileAccess.get_file_as_bytes(source)
	await _mount(game)
	_check(not game._player_storage_ready and game.user_levels_directory.is_empty() and game.catalog.user_directory.is_empty(), "未授权时不把旧路径冒充可用保存目录")
	_check(game.catalog.levels.size() > 0 and game.upgrade_requests == 1, "未授权仍有教学关卡且首次升级提示可暂不处理")
	var continued := [false]
	game._player_storage_continuation = func() -> void: continued[0] = true
	game._player_storage_selecting = true
	game._cancel_player_save_folder()
	_check(not game._player_storage_selecting and not game._player_storage_continuation.is_valid() and not continued[0], "取消授权清理待执行操作而不恢复旧路径")
	_check(FileAccess.get_file_as_bytes(source) == original and not FileAccess.file_exists(game.player_saves_journal), "取消保留旧地图且不创建迁移完成记录")
	_check(not DirAccess.dir_exists_absolute(_root.path_join("denied/Documents/ProgrammableModule/saves")), "取消不创建未授权目标目录")
	game._open_editor()
	_check(game._editor == null and not game._player_storage_ready, "未授权打开编辑器仍被门禁阻止")
	game._show_player_level_list_page()
	var legacy := _legacy_entry(game, "old.json")
	_check(legacy != null and game.player_level_library.user_directory.is_empty(), "无需新目录授权即可只读查看旧关卡")
	game._migrate_player_entry(legacy)
	_check(game._player_storage_continuation.is_valid() and not FileAccess.file_exists(game.player_saves_journal), "迁移入口等待明确目录授权而不提前复制")
	location.granted_directories = PackedStringArray([location.documents_directory])
	game._select_player_save_folder(location.documents_directory)
	_check(game._player_storage_ready and FileAccess.get_file_as_bytes(game.user_levels_directory.path_join("old.json")) == original, "授权后继续此前选择的单条迁移")
	_check(game._legacy_upgrade_state.get("retired", false) and not DirAccess.dir_exists_absolute(game.player_saves_source), "授权后的最后一条完成并安全退役")
	await _release(game)


## 单条迁移失败不禁用新目录；修复后用户重试这一条，完成后新目录删除也不会复活旧备份。
func _test_retry_migration() -> void:
	var game := _shell("retry")
	game.player_save_location = _location("retry")
	var source := game.player_saves_source.path_join("old.json")
	_ok(MapCodec.save_file(_map("retry_source"), source, _content), "准备失败重试场景旧地图")
	var original := FileAccess.get_file_as_bytes(source)
	await _mount(game)
	game._show_player_level_list_page()
	var legacy := _legacy_entry(game, "old.json")
	_write(game.player_saves_journal, "broken migration journal")
	game._migrate_player_entry(legacy)
	_check(game._player_storage_ready and not game.notices.is_empty(), "迁移记录损坏会明确报错但不禁用新保存目录")
	_check(FileAccess.get_file_as_bytes(source) == original and FileAccess.get_file_as_string(game.player_saves_journal) == "broken migration journal", "失败保留旧地图和损坏记录原件")
	var destination := game.user_levels_directory.path_join("old.json")
	_check(not FileAccess.file_exists(destination), "迁移校验失败不产生关卡副本")
	_check(DirAccess.remove_absolute(game.player_saves_journal) == OK, "测试修复损坏迁移记录")
	game._refresh_player_level_list()
	game._migrate_player_entry(_legacy_entry(game, "old.json"))
	_check(game._player_storage_ready and game.catalog.user_directory == game.user_levels_directory and game._legacy_upgrade_state.get("retired", false), "单条重试成功刷新目录并完成旧目录退役")
	_check(FileAccess.get_file_as_bytes(destination) == original and _find(game.catalog, "retry_source") != null, "重试复制旧地图并进入选关目录")
	_check(DirAccess.remove_absolute(destination) == OK, "模拟用户在迁移后删除新目录地图")
	game._retry_player_storage()
	_check(game._player_storage_ready and not FileAccess.file_exists(destination), "重复准备新目录不复活已删除地图")
	_check(not DirAccess.dir_exists_absolute(game.player_saves_source), "已迁移备份只在全部完成后被清理")
	await _release(game)


## 构造未进树的真实外壳并注入全部玩家可写路径，避免任何正式 user:// 文件读写。
func _shell(case_name: String) -> TestShell:
	var game := TestShell.new()
	var directory := _root.path_join(case_name)
	game.name = "PlayerSaveTestShell"
	game.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game.settings_path = directory.path_join("settings.json")
	game.profile_path = directory.path_join("profile.json")
	game.drafts_directory = directory.path_join("solutions")
	game.player_saves_source = directory.path_join("legacy/levels")
	game.player_saves_journal = directory.path_join("migration.json")
	game.legacy_upgrade_native_dialog_handler = func(_title: String, _body: String, _buttons: PackedStringArray, callback: Callable) -> int:
		game.upgrade_requests += 1
		callback.call(0)
		return OK
	return game


## 真实位置模型通过显式测试注册验证模拟的 Documents，不能凭注入路径触及真实文稿。
func _location(case_name: String) -> PlayerSaveLocation:
	var location := PlayerSaveLocation.new(_root.path_join(case_name).path_join("location.json"))
	location.platform_name = "macOS"
	location.sandboxed = false
	location.documents_directory = ProjectSettings.globalize_path(_root.path_join(case_name).path_join("Documents"))
	location.allow_registered_test_roots = true
	return location


## 构建全部真实页面并等待启动结束，避免断言落在异步加载中途。
func _mount(game: TestShell) -> void:
	root.add_child(game)
	for unused in 600:
		if game.startup_complete:
			break
		await process_frame
	_check(game.startup_complete, "隔离外壳完成启动")
	for unused in 4:
		await process_frame


## 等待节点释放和延后回调结束后才进入下一独立案例。
func _release(game: TestShell) -> void:
	game.queue_free()
	for unused in 6:
		await process_frame
	PlayerLevelPaths.clear_external_root()


## 使用真实内置文档产生独立 ID，以实际 MapCodec 验证完整可玩数据。
func _map(id: String) -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var document: MapDocument = loaded.value.duplicate_document()
	document.id = id
	document.display_name = "测试地图"
	return document


## 从 Catalog 真实加载的定义中定位迁移或导入结果。
func _find(catalog: LevelCatalog, id: String) -> LevelDefinition:
	for level: LevelDefinition in catalog.levels:
		if level.id == id:
			return level
	return null


## 从真实聚合快照按旧文件名取得待迁移条目，避免伪造菜单授权。
func _legacy_entry(game: GameShell, filename: String) -> PlayerLevelRecord:
	for entry: PlayerLevelRecord in game.player_level_library.entries:
		if entry.needs_migration and entry.source_path.get_file() == filename:
			return entry
	return null


## 仅为坏日志案例写入隔离原始字节，不模拟迁移流程本身。
func _write(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "创建隔离错误日志")
	if file != null:
		file.store_string(value)
		file.close()


## 保留具体错误信息，所有失败统一计入最终退出码。
func _ok(result: DataResult, message: String) -> void:
	_check(result.is_ok(), message + ": " + "; ".join(result.errors))


## 通用断言继续后续案例以提供完整集成回归结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 清理只接受当前独占测试根，遇到链接直接移除，绝不跟随到其他文件树。
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
