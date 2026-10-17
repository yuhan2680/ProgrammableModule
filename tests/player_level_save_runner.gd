extends SceneTree
## 玩家关卡保存集成回归通过真实编辑器及选关入口验证，全程使用独占用户目录。

var _checks := 0
var _failures := 0
var _temporary: String
var _game: GameShell
var _capture_path := ""
var _managed_a := ""
var _managed_b := ""
var _player_b_id := ""


## 延后初始化，并仅接受显式指定的可选 GPU 截图路径。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_path = argument.trim_prefix("--capture=")
	_run.call_deferred()


## 保存全局显示设置，依次验证编辑器绑定、重启扫描及真实空装配入口。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/player_level_save_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_temporary.path_join("exports")))
	var locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var master_db := AudioServer.get_bus_volume_db(master)
	var master_mute := AudioServer.is_bus_mute(master)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _create_game()
	await _test_new_map_ids()
	await _test_editor_binding()
	await _test_restart_and_entry()
	_game.queue_free()
	await _settle()
	AudioServer.set_bus_volume_db(master, master_db)
	AudioServer.set_bus_mute(master, master_mute)
	TranslationServer.set_locale(locale)
	_cleanup(_temporary)
	print("玩家关卡保存集成回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 每次构造外壳都注入同一测试目录，重建时只复用本次测试已保存的地图。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	for unused in 600:
		if _game.startup_complete:
			break
		await process_frame
	await _settle()
	_check(_game.startup_complete and not _game._message_dialog.visible, "隔离外壳完成启动且没有加载错误")


## 连续未保存新建分配独立十位身份，失败则保留当前路径、文档、撤销历史和视点。
func _test_new_map_ids() -> void:
	_game._open_editor()
	await _settle()
	var editor := _game._editor
	var model := editor.editor_document
	var initial_id := model.document.id
	_check(PlayerLevelStore.is_generated_map_id(initial_id) and model.document.cells.is_empty() and model.document.player_spawn == null and model.path.is_empty(), "主菜单编辑器入口直接创建空白地图，无需额外点新建")
	_check(not model.is_dirty() and not model.can_undo() and model.get_creator() == _game.profile.get_username(), "主菜单新建使用玩家署名及干净初始历史")
	var seen: Dictionary = {initial_id: true}
	for _index in range(32):
		editor._new_document()
		var map_id := model.document.id
		_check(PlayerLevelStore.is_generated_map_id(map_id) and not seen.has(map_id), "每次新建使用独立的 map_ 加十位数字 ID")
		seen[map_id] = true
		_check(model.path.is_empty() and not model.is_dirty() and not model.can_undo() and editor._id_field.text == map_id and not editor._id_field.editable, "分配 ID 属于新地图初始状态，不产生修改历史且表单只读")
	_check(_player_files().is_empty(), "未保存新建不生成任何玩家关卡文件")
	model.paint(Vector2i(1, 1), "floor")
	var before := model.document.to_dict()
	var undo_count := model._undo_stack.size()
	var center := editor._map_view.view_center
	var zoom := editor._map_view.zoom
	var directory := editor.player_levels_directory
	editor.player_levels_directory = "user://../invalid"
	editor._new_document()
	_check(editor._message_dialog.visible and model.document.to_dict() == before and model._undo_stack.size() == undo_count and model.is_dirty(), "新 ID 分配失败保留现有未保存地图与历史")
	_check(editor._map_view.view_center == center and editor._map_view.zoom == zoom, "分配失败不重置当前地图视点")
	editor._message_dialog.hide()
	editor.player_levels_directory = directory
	# 显式打开已有地图后再走无路径入口，不能自动恢复上一张地图。
	_game._open_editor(MapEditor.DEFAULT_MAP_PATH)
	await _settle()
	_check(_game._editor.initial_map_opened and _game._editor.editor_document.path == MapEditor.DEFAULT_MAP_PATH, "明确指定路径时仍完整打开已有地图")
	_game._show_main_page()
	_game._open_editor()
	await _settle()
	var reopened := _game._editor.editor_document
	_check(PlayerLevelStore.is_generated_map_id(reopened.document.id) and reopened.document.id != initial_id and reopened.document.cells.is_empty() and reopened.path.is_empty(), "离开示例再进入编辑器仍新建独立空白图，不把旧文档当缓存恢复")


## 普通保存与另存为、打开、新建交错时只更新当前拥有的玩家关卡文件。
func _test_editor_binding() -> void:
	_game._open_editor(MapEditor.DEFAULT_MAP_PATH)
	await _settle()
	var editor := _game._editor
	editor._file_dialog.use_native_dialog = false
	var model := editor.editor_document
	var source_bytes := FileAccess.get_file_as_bytes(MapEditor.DEFAULT_MAP_PATH)
	_check(model.path == MapEditor.DEFAULT_MAP_PATH and editor.player_levels_directory == _game.catalog.user_directory, "显式示例与游戏玩家关卡目录正确注入编辑器")
	editor._header.save_button.pressed.emit()
	_managed_a = model.path
	_check(_is_managed(_managed_a) and FileAccess.file_exists(_managed_a) and not editor._file_dialog.visible and not model.is_dirty(), "显式打开的res示例正常保存直接生成玩家关卡且不弹路径选择")
	_check(FileAccess.get_file_as_bytes(MapEditor.DEFAULT_MAP_PATH) == source_bytes, "保存示例没有修改内置res原件")
	_check(_find_level(_game.catalog, model.document.id) != null, "普通保存成功时外壳立即刷新关卡目录")
	var file_count := _player_files().size()
	model.paint(Vector2i.ZERO, "floor")
	var undo_count := model._undo_stack.size()
	editor._header.save_button.pressed.emit()
	_check(model.path == _managed_a and _player_files().size() == file_count and model._undo_stack.size() == undo_count and not model.is_dirty(), "重复保存复用同文件且保留撤销历史和最新保存点")
	editor._undo()
	_check(model.is_dirty() and model.document.get_tile_id(Vector2i.ZERO).is_empty(), "保存后的撤销仍能回到实际编辑前内容")
	editor._redo()
	_check(not model.is_dirty() and model.document.get_tile_id(Vector2i.ZERO) == "floor", "重做回到保存点后恢复未修改状态")
	var export_path := _temporary.path_join("exports/a_copy.json")
	editor._save_document(true)
	_check(editor._file_dialog.visible and editor._file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE, "另存为继续显示文件选择器")
	editor._file_dialog.file_selected.emit(export_path)
	editor._file_dialog.hide()
	var exported := FileAccess.get_file_as_bytes(export_path)
	model.set_identity(model.document.id, "玩家地图 A")
	editor._save_document(false)
	_check(model.path == _managed_a and _player_files().size() == file_count and FileAccess.get_file_as_bytes(export_path) == exported, "另存为后普通保存保留外部副本并继续写原托管文件")
	var a_bytes := FileAccess.get_file_as_bytes(_managed_a)
	var external_b := _temporary.path_join("exports/b_source.json")
	var source_b := model.document.duplicate_document()
	source_b.id = "external_b"
	source_b.display_name = "外部地图 B"
	_check(MapCodec.save_file(source_b, external_b, editor.registry, false).is_ok(), "外部B夹具只写入测试导出目录")
	var b_source_bytes := FileAccess.get_file_as_bytes(external_b)
	editor._load_document(external_b)
	model.set_identity(model.document.id, "玩家地图 B")
	editor._save_document(false)
	_managed_b = model.path
	_player_b_id = model.document.id
	_check(_is_managed(_managed_b) and _managed_b != _managed_a and _player_files().size() == file_count + 1 and FileAccess.get_file_as_bytes(_managed_a) == a_bytes and FileAccess.get_file_as_bytes(external_b) == b_source_bytes, "打开外部B后保存创建独立玩家文件，不沿用A绑定或覆盖B源文件")
	# 先切回A，再打开已托管B，专门覆盖旧绑定残留造成跨地图覆盖的问题。
	editor._load_document(_managed_a)
	editor._load_document(_managed_b)
	model.set_identity(model.document.id, "玩家地图 B · 更新")
	editor._save_document(false)
	var saved_b := MapCodec.load_file(_managed_b, editor.registry, false)
	_check(model.path == _managed_b and saved_b.is_ok() and saved_b.value.display_name == "玩家地图 B · 更新" and FileAccess.get_file_as_bytes(_managed_a) == a_bytes and _player_files().size() == file_count + 1, "打开托管B后只更新B，先前A的内容与文件数保持不变")
	var before_failed_load := JSON.stringify(model.document.to_dict(), "", true)
	editor._load_document(_temporary.path_join("missing.json"))
	_check(editor._message_dialog.visible and model.path == _managed_b and JSON.stringify(model.document.to_dict(), "", true) == before_failed_load, "载入失败保留当前文档与路径")
	editor._message_dialog.hide()
	model.set_identity(model.document.id, "玩家地图 B · 继续编辑")
	editor._save_document(false)
	_check(model.path == _managed_b and FileAccess.get_file_as_bytes(_managed_a) == a_bytes and _player_files().size() == file_count + 1, "失败载入后的普通保存仍绑定B，不产生副本或覆盖A")
	var b_bytes := FileAccess.get_file_as_bytes(_managed_b)
	editor._new_document()
	var created_id := model.document.id
	editor._save_document(false)
	var new_path := model.path
	_check(_is_managed(new_path) and new_path != _managed_a and new_path != _managed_b and FileAccess.file_exists(new_path) and FileAccess.get_file_as_bytes(_managed_b) == b_bytes and not model.is_dirty(), "新建清除旧绑定，未完成出生点草稿也能单独保存")
	_check(_find_level(_game.catalog, model.document.id) == null, "未设置出生点的已保存草稿不会伪装成可玩关卡")
	_check(PlayerLevelStore.is_generated_map_id(created_id) and model.document.id == created_id, "新地图首存使用创建时的随机 ID")
	model.paint(Vector2i(1, 1), "floor")
	model.place_spawn(Vector2i(1, 1), "movement")
	model.set_identity(model.document.id, "玩家新建地图")
	editor._save_document(false)
	_check(model.path == new_path and _find_level(_game.catalog, model.document.id) != null, "补齐出生点后继续保存同一文件并立即进入玩家关卡目录")
	_check(model.document.id == created_id, "改名、绘图、放起点和重复保存不重新分配 ID")
	editor._undo()
	_check(model.document.id == created_id, "撤销地图编辑保持创建时 ID")
	editor._redo()
	_check(model.document.id == created_id and not model.is_dirty(), "重做回到保存点仍保持 ID")
	var export_id_path := _temporary.path_join("exports/random_map.json")
	editor._save_document(true)
	editor._file_dialog.file_selected.emit(export_id_path)
	editor._file_dialog.hide()
	var exported_random := MapCodec.load_file(export_id_path, editor.registry, false)
	_check(exported_random.is_ok() and exported_random.value.id == created_id and editor._managed_save_path == new_path, "另存为保留 ID 且不改变普通保存绑定")
	var path_before_test := model.path
	editor._start_playtest()
	await _settle()
	_check(_game._editor_playtest and _game.session.level.id == created_id and model.document.id == created_id, "未保存测试快照与编辑文档使用相同稳定 ID")
	_game._return_to_editor()
	await _settle()
	_check(_game._editor == editor and model.document.id == created_id and model.path == path_before_test and editor._managed_save_path == new_path and not model.is_dirty(), "测试返回保留同一文档、随机 ID 和保存点")
	editor._load_document(new_path)
	editor._save_document(false)
	_check(model.document.id == created_id and model.path == new_path, "重开后仍读取持久 ID，保存不再次随机")
	var builtin_path := "res://data/levels/level_001.json"
	var builtin_bytes := FileAccess.get_file_as_bytes(builtin_path)
	editor._load_document(builtin_path)
	model.set_identity(model.document.id, "玩家自建教学副本")
	editor._save_document(false)
	var copied_id := model.document.id
	var builtin := _find_level(_game.catalog, "level_001")
	var copy := _find_level(_game.catalog, copied_id)
	_check(copied_id != "level_001" and _is_managed(model.path) and builtin != null and builtin.source_path == builtin_path and copy != null and copy.source_path == model.path, "与教学ID冲突的保存采用独立身份且不会遮蔽原教学关卡")
	_check(FileAccess.get_file_as_bytes(builtin_path) == builtin_bytes and FileAccess.get_file_as_bytes(MapEditor.DEFAULT_MAP_PATH) == source_bytes and _builtin_count(_game.catalog) == 16, "托管保存始终保留内置文件与十六个教学入口")
	_check(_game.catalog.errors.is_empty() and _player_files().size() == 4, "四个完成的玩家地图均可被目录读取且没有重复保存文件")


## 重建目录和整个外壳后仍显示玩家地图，再点击真实关卡卡片进入空装配。
func _test_restart_and_entry() -> void:
	var catalog := LevelCatalog.new()
	catalog.user_directory = _game.user_levels_directory
	catalog.refresh(_game.registry)
	_check(catalog.errors.is_empty() and _find_level(catalog, _player_b_id) != null and _builtin_count(catalog) == 16, "独立新目录实例可从磁盘恢复玩家地图与全部教学关卡")
	_game.queue_free()
	await _settle()
	await _create_game()
	var start := _game.find_child("StartGameButton", true, false) as Button
	start.pressed.emit()
	var deadline := Time.get_ticks_msec() + 3000
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not _game._menu_transitioning, "菜单转场完成后检查玩家关卡")
	await _settle()
	var player_section := _game.find_child("ImportedSection", true, false)
	var player_grid := _game.find_child("ImportedLevelGrid", true, false)
	var category_found := false
	for child in player_section.find_children("*", "Label", true, false):
		if child is Label and child.text == "玩家关卡":
			category_found = true
	_check(_game.page == GameShell.Page.LEVELS and category_found and _game.catalog.levels.size() == 20, "重建游戏后真实选关页在玩家关卡分类展示全部四张保存地图")
	await _capture_player_page()
	var index := -1
	for item in _game.catalog.levels.size():
		if _game.catalog.levels[item].id == _player_b_id:
			index = item
	var card := _game.find_child("LevelButton_%d" % index, true, false) as Button
	_check(card != null and card.is_visible_in_tree() and card.get_parent().get_parent() == player_grid, "玩家地图对应真实可见卡片且位于玩家网格")
	if card == null:
		return
	var scroll := _game.find_child("LevelScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(card)
	await _settle()
	var point := card.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and _game.session.level.id == _player_b_id and _game.session.assembly.modules.is_empty() and _game.assembly_panel != null, "真实点击玩家关卡先进入空装配，地图出生模板不会被当成玩家装配")


## 可选截图仅保存实际 GPU 画面，不在无界面回归中生成占位图片。
func _capture_player_page() -> void:
	if _capture_path.is_empty() or DisplayServer.get_name() == "headless":
		return
	if not _capture_path.is_absolute_path():
		_check(false, "截图路径必须为绝对路径")
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_path.get_base_dir())
	_check(root.get_texture().get_image().save_png(_capture_path) == OK, "保存真实玩家关卡页GPU截图")


## 按稳定ID查找关卡，断言不依赖玩家关卡排序位置。
func _find_level(catalog: LevelCatalog, map_id: String) -> LevelDefinition:
	for level: LevelDefinition in catalog.levels:
		if level.id == map_id:
			return level
	return null


## 来源路径用于区分教学与玩家地图，不依据名称或ID前缀猜测分类。
func _builtin_count(catalog: LevelCatalog) -> int:
	var count := 0
	for level: LevelDefinition in catalog.levels:
		if level.source_path.begins_with("res://data/levels/"):
			count += 1
	return count


## 托管结果必须直接落在本轮玩家关卡目录中。
func _is_managed(path: String) -> bool:
	return not path.is_empty() and ProjectSettings.globalize_path(path).get_base_dir() == ProjectSettings.globalize_path(_game.user_levels_directory)


## 只统计玩家目录中的直接JSON文件，重复保存不得不断创建新地图。
func _player_files() -> PackedStringArray:
	var files := PackedStringArray()
	if not DirAccess.dir_exists_absolute(_game.user_levels_directory):
		return files
	for filename: String in DirAccess.get_files_at(_game.user_levels_directory):
		if filename.get_extension().to_lower() == "json":
			files.append(filename)
	return files


## 等待原生容器、页面替换和延迟释放完成。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 记录断言错误，同时保留后续路径的回归结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只清理本轮测试独占目录，不触碰玩家存档或导出原件。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	for filename: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory: String in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(directory))
	DirAccess.remove_absolute(path)
