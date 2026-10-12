extends SceneTree
## 原生导入配置、文件回调与玩家关卡折叠的真实界面回归，全部磁盘内容使用隔离目录。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _capture_dir := ""
var _opened_folders: Array[String] = []


## 场景树准备后启动，可选输出真实渲染截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 构建真实游戏外壳，依次验证选择、失败、取消、陈旧回调与独立列表折叠。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/player_import_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var locale := TranslationServer.get_locale()
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.folder_opener = _record_folder_open
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	_game._show_level_page()
	await _settle()
	var chooser := _game._import_dialog
	_check(chooser is FileDialog and chooser.use_native_dialog, "正式入口配置系统原生文件选择器")
	_check(chooser.access == FileDialog.ACCESS_FILESYSTEM and chooser.file_mode == FileDialog.FILE_MODE_OPEN_FILE, "选择器允许从任意系统目录打开单个文件")
	_check(chooser.filters.size() == 1 and chooser.filters[0].contains("*.json"), "选择器只展示 JSON 关卡过滤器")
	# 原生窗口由系统管理；测试只把同一选择器切到内嵌模式以注入选择与取消信号。
	chooser.use_native_dialog = false
	var source := _write_map("imported_one", "来自下载的关卡")
	await _test_cancel_and_late_selection(source)
	await _test_invalid_files()
	await _test_selected_file(source)
	await _test_player_fold()
	_check(_opened_folders.is_empty(), "全部导入与折叠流程都不调用打开托管目录接口")
	_game.queue_free()
	await _settle()
	TranslationServer.set_locale(locale)
	_cleanup(_temporary)
	print("玩家关卡导入界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 取消与系统返回焦点不刷新背景，已结束的文件选择不得在换页后继续导入。
func _test_cancel_and_late_selection(source: String) -> void:
	var original_sources := _snapshot(_temporary.path_join("downloads"))
	var original_maps := _snapshot(_game.user_levels_directory)
	var original_drafts := _snapshot(_game.drafts.directory)
	var first := _game.catalog.levels[0]
	var body := _game._body.get_child(0)
	var button := _game.find_child("ImportLevelButton", true, false) as Button
	button.pressed.emit()
	await _settle()
	_check(_game._level_import_pending and _game._import_dialog.visible and not _game._message_dialog.visible, "加号直接弹出文件选择器，不显示复制说明")
	var downloads := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if not downloads.is_empty() and DirAccess.dir_exists_absolute(downloads):
		_check(_game._import_dialog.current_dir.simplify_path() == downloads.simplify_path(), "原生选择默认打开当前系统下载目录")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _settle()
	_check(_game._import_dialog.visible and _game._level_import_pending and _game.catalog.levels[0] == first and _game._body.get_child(0) == body, "选择期间系统返回游戏焦点不关闭窗口或重建关卡页")
	_game._import_dialog.canceled.emit()
	await _settle()
	_check(not _game._level_import_pending and not _game._import_dialog.visible, "系统取消回调清除导入状态并关闭选择器")
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(source))
	await _settle()
	_check(_game.catalog.levels.size() == 16 and _game._body.get_child(0) == body, "取消后的过期选择信号不会复制文件或刷新页面")
	_game._import_levels()
	await _settle()
	_game._show_main_page()
	await _settle()
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(source))
	await _settle()
	_check(_game.page == GameShell.Page.MAIN and not _game._level_import_pending and not _game._import_dialog.visible, "离开关卡页取消选择，过期回调不能改变页面")
	_check(_snapshot(_temporary.path_join("downloads")) == original_sources and _snapshot(_game.user_levels_directory) == original_maps and _snapshot(_game.drafts.directory) == original_drafts, "取消与过期回调逐字节保留原件、玩家地图和记录")
	_game._show_level_page()
	await _settle()


## 无效来源只显示错误，不污染已有目录，也不保留待选择状态。
func _test_invalid_files() -> void:
	var invalid := _temporary.path_join("downloads/broken.json")
	_write_text(invalid, "{ invalid json")
	var wrong_extension := _temporary.path_join("downloads/map.txt")
	_write_text(wrong_extension, "{\"id\":\"not_a_map\"}")
	var missing := _temporary.path_join("downloads/missing.json")
	var draft := MapDocument.new()
	draft.id = "unfinished_draft"
	var no_spawn := _temporary.path_join("downloads/no_spawn.json")
	_check(MapCodec.save_file(draft, no_spawn, _game.registry, false).is_ok(), "为无出生点失败路径创建合法编辑草稿")
	var maps_before := _snapshot(_game.user_levels_directory)
	var sources_before := _snapshot(_temporary.path_join("downloads"))
	var level_before := _game.catalog.levels[0]
	for path in [invalid, wrong_extension, missing, no_spawn]:
		_game._import_levels()
		await _settle()
		_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(path))
		await _settle()
		_check(_game._message_dialog.visible and not _game._message_dialog.dialog_text.is_empty() and not _game._import_dialog.visible and not _game._level_import_pending, "无效来源关闭选择器并报告错误：" + path.get_file())
		_check(_snapshot(_game.user_levels_directory) == maps_before and _game.catalog.levels[0] == level_before and _game.catalog.levels.size() == 16, "无效来源不生成地图或重建关卡目录：" + path.get_file())
		_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		await _settle()
		_check(_game._message_dialog.visible and _game.catalog.levels[0] == level_before, "文件选择返回系统焦点不会吞掉导入错误提示：" + path.get_file())
		_game._message_dialog.hide()
	_check(_snapshot(_temporary.path_join("downloads")) == sources_before, "失败导入未改写任何下载原件")


## 文件选择信号完成校验、托管复制和自动刷新，扩展内容与重复来源均保持安全。
func _test_selected_file(source: String) -> void:
	var original_source := FileAccess.get_file_as_bytes(source)
	var expected: MapDocument = MapCodec.load_file(source, _game.registry, true).value
	_game._import_levels()
	await _settle()
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(source))
	await _settle()
	var imported: LevelDefinition = _definition("imported_one")
	_check(imported != null and _game.catalog.levels.size() == 17 and _card("imported_one") != null, "选取下载文件后自动出现一张玩家关卡，无需手动复制或刷新")
	_check(not _game._import_dialog.visible and not _game._level_import_pending and not _game._message_dialog.visible, "成功后关闭选择器，无额外成功确认弹窗")
	if imported == null:
		return
	_check(imported.source_path.get_base_dir() == _game.user_levels_directory and FileAccess.file_exists(imported.source_path), "可见关卡使用已写入托管目录的独立副本")
	_check(imported.document.to_dict() == expected.to_dict(), "署名、Markdown 引导、禁止模块及未知扩展完整保留")
	_check(imported.creator == "Muna" and not "shooting" in imported.allowed_modules and "movement" in imported.allowed_modules, "导入后的实际关卡规则保留创作者和模块限制")
	_check(FileAccess.get_file_as_bytes(source) == original_source, "正常导入逐字节保留下载原件")
	var managed_before := FileAccess.get_file_as_bytes(imported.source_path)
	_game._import_levels()
	await _settle()
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(source))
	await _settle()
	var duplicate: LevelDefinition = _definition("imported_one_2")
	_check(duplicate != null and duplicate.source_path != imported.source_path and _game.catalog.levels.size() == 18, "同一来源重复导入自动去重 ID 和文件，不覆盖旧副本")
	_check(FileAccess.get_file_as_bytes(imported.source_path) == managed_before and FileAccess.get_file_as_bytes(source) == original_source, "重复导入同时保留原件与第一份托管文件")
	var files_before := _snapshot(_game.user_levels_directory)
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(source))
	await _settle()
	_check(_snapshot(_game.user_levels_directory) == files_before and _game.catalog.levels.size() == 18, "已完成选择的重复系统信号不会再创建副本")


## 玩家首行包含一个导入入口和六张地图，独立展开偏好在搜索、排序、刷新后保留。
func _test_player_fold() -> void:
	for index in range(3, 7):
		await _select_source(_write_map("fold_%02d" % index, "玩家练习 %02d" % index))
	_check(_game._player_entries.size() == 6 and _visible_players() == 6 and not _game._player_toggle.visible, "六张玩家关卡加导入入口恰好一排，不显示多余展开按钮")
	_check(_visible_grid_slots() == 7 and _import_is_first(), "折叠首行的七列含始终位于第一格的导入入口")
	await _select_source(_write_map("fold_07", "隐藏目标关卡"))
	_check(_game._player_entries.size() == 7 and _visible_players() == 6 and _game._player_toggle.visible and _game._player_toggle.text == "展示更多（7）", "第七张玩家关卡开始折叠并显示真实地图总数")
	_check(_visible_tutorials() == 7 and not _game._tutorials_expanded and not _game._players_expanded, "新玩家分类不改变教学默认折叠")
	await _capture("players-collapsed.png")
	var maps_before := _snapshot(_game.user_levels_directory)
	_game._player_toggle.pressed.emit()
	await _settle()
	_check(_visible_players() == 7 and _game._players_expanded and _game._player_toggle.text == "收起" and _visible_tutorials() == 7, "玩家展示更多仅展开玩家关卡")
	_game._tutorial_toggle.pressed.emit()
	await _settle()
	_check(_visible_tutorials() == 16 and _visible_players() == 7 and _game._tutorials_expanded, "教学展开独立保留玩家展开状态")
	_game._player_toggle.pressed.emit()
	await _settle()
	_check(_visible_players() == 6 and _visible_tutorials() == 16 and _game._tutorials_expanded and not _game._players_expanded, "玩家收起不收起教学列表")
	_game._refresh_levels()
	await _settle()
	_check(_visible_players() == 6 and _visible_tutorials() == 16 and _game._tutorials_expanded and not _game._players_expanded, "目录刷新分别保留两组展开偏好")
	_game.drafts.mark_completed("imported_one")
	_game._on_level_sort_changed(true)
	await _settle()
	_check(_visible_players() == 6 and _visible_tutorials() == 16 and _import_is_first(), "未通关排序保持分组折叠和导入首位")
	_check(not _card("imported_one").visible, "折叠时按排序后的前六张玩家关卡显示")
	_game._on_level_sort_changed(false)
	await _settle()
	var hidden_entry := _game._player_entries[6]
	var hidden_name := (hidden_entry.get_node("LevelCardTitle") as Label).text
	_check(not hidden_entry.visible, "搜索前目标确实处在折叠的玩家行中")
	_game._level_header.set_search_open(true, false)
	var input := _game.find_child("LevelSearchInput", true, false) as LineEdit
	input.text = hidden_name
	input.text_changed.emit(input.text)
	await _settle()
	_check(hidden_entry.visible and _visible_players() >= 1 and not _game._player_toggle.visible, "搜索可以临时展示被折叠的匹配关卡并隐藏展开按钮")
	_check(not _game._players_expanded and _game._tutorials_expanded and _import_is_first(), "搜索不更改两组折叠偏好或导入位置")
	_game._refresh_levels()
	await _settle()
	_check(_game._level_header.get_query() == hidden_name and _visible_players() >= 1 and not _game._player_toggle.visible, "带查询刷新继续显示匹配玩家关卡")
	input.text = ""
	input.text_changed.emit("")
	await _settle()
	_check(_visible_players() == 6 and _visible_tutorials() == 16 and _game._player_toggle.visible and not _game._players_expanded, "清空查询还原搜索前的独立折叠状态")
	_game._tutorial_toggle.pressed.emit()
	_game._player_toggle.pressed.emit()
	await _settle()
	_game._on_level_sort_changed(true)
	_game._refresh_levels()
	await _settle()
	_check(_visible_tutorials() == 7 and _visible_players() == 7 and _game._players_expanded and not _game._tutorials_expanded, "排序并刷新也保留玩家展开、教学折叠的相反状态")
	for language in ["zh_CN", "zh_HK", "en"]:
		_game.settings.set_language(language)
		await _settle()
		_check(_game._player_toggle.text == _game.tr("收起"), "展开玩家按钮正确本土化：" + language)
		_game._player_toggle.pressed.emit()
		await _settle()
		_check(_game._player_toggle.text == _game.tr("展示更多（%d）") % 7 and _visible_players() == 6, "折叠按钮显示本土化真实数量：" + language)
		_game._player_toggle.pressed.emit()
		await _settle()
	_game.settings.set_language("zh_CN")
	_game._show_main_page()
	await _settle()
	_game._show_level_page()
	await _settle()
	_check(_visible_players() == 7 and _visible_tutorials() == 7 and _game._players_expanded and not _game._tutorials_expanded, "往返主菜单仍保留当前会话两组展开偏好")
	_check(_snapshot(_game.user_levels_directory) == maps_before, "列表折叠、搜索、排序、本土化和返回不修改任何地图")
	await _capture("players-expanded.png")


## 从教学地图建立可运行的下载夹具，添加需保留的玩家字段与未知扩展。
func _write_map(identity: String, title: String) -> String:
	var document := _game.catalog.levels[0].document.duplicate_document()
	document.id = identity
	document.display_name = title
	document.properties.level["creator"] = "Muna"
	document.properties.level.erase("allowed_modules")
	document.properties.level["restricted_modules"] = ["shooting"]
	document.properties["custom_metadata"] = {"note": "原文保留", "values": [3, 9]}
	document.extra["download_extension"] = {"keep": true}
	document.dialogue = [{"speaker": "Muna", "text": "# 探索\n\n## 路线\n\n### 准备\n使用你的模块。", "format": "markdown", "extension": "keep"}]
	var path := _temporary.path_join("downloads").path_join(identity + " 下载.json")
	_check(MapCodec.save_file(document, path, _game.registry).is_ok(), "创建独立下载文件：" + identity)
	return path


## 通过生产选择器的单文件信号导入，不直接调用存储或刷新函数替代界面流程。
func _select_source(path: String) -> void:
	_game._import_levels()
	await _settle()
	_game._import_dialog.file_selected.emit(ProjectSettings.globalize_path(path))
	await _settle()
	_check(not _game._message_dialog.visible and not _game._level_import_pending, "选择关卡后自动完成导入：" + path.get_file())


## 根据实际目录身份查找定义，不依赖排序或不存在的索引便利接口。
func _definition(identity: String) -> LevelDefinition:
	for definition in _game.catalog.levels:
		if definition.id == identity:
			return definition
	return null


## 按真实目录条目找到卡片，避免显示顺序或排序改变后误认固定索引。
func _card(identity: String) -> Control:
	for entry in _game._level_entries:
		if entry.definition.id == identity:
			return entry.control
	return null


## 可见数量以真实控件为准，不以展开布尔值替代布局结果。
func _visible_players() -> int:
	var total := 0
	for card in _game._player_entries:
		if card.visible:
			total += 1
	return total


## 教学分类使用单独计数，检查玩家展开没有牵动原有分类。
func _visible_tutorials() -> int:
	var total := 0
	for card in _game._tutorial_entries:
		if card.visible:
			total += 1
	return total


## 只统计可见实际卡片，不将自动补齐网格的空列算作玩家关卡。
func _visible_grid_slots() -> int:
	var total := 0
	for child in _game.find_child("ImportedLevelGrid", true, false).get_children():
		if child.visible and not child.has_meta("column_spacer"):
			total += 1
	return total


## 导入入口必须始终保持当前玩家网格的首位且可见。
func _import_is_first() -> bool:
	var entry := (_game.find_child("ImportLevelButton", true, false) as Control).get_parent()
	return entry.get_index() == 0 and entry.visible


## 读取隔离目录的所有直接文件原始字节，发现取消或界面操作的意外写盘。
func _snapshot(path: String) -> Dictionary:
	var result := {}
	var folder := DirAccess.open(path)
	if folder != null:
		for filename in folder.get_files():
			result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 错误文件仅写入当前测试独占目录，用于验证选择失败边界。
func _write_text(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()


## 系统打开目录使用记录替身，测试不得启动真实 Finder 或资源管理器。
func _record_folder_open(path: String) -> int:
	_opened_folders.append(path)
	return OK


## 等待控件布局与延迟信号完成。
func _settle() -> void:
	await process_frame
	await process_frame


## 仅在显式 GPU 截图请求时保存画面，普通无窗口回归不访问渲染图片。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	var rendered := root.get_texture().get_image()
	_check(rendered != null and not rendered.is_empty(), "真实界面截图已渲染：" + filename)
	if rendered != null and not rendered.is_empty():
		rendered.save_png(_capture_dir.path_join(filename))


## 只清理本次独占目录，绝不遍历真实玩家数据。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for filename in folder.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in folder.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 汇总可诊断失败并以退出状态供全量测试识别。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
