extends SceneTree
## 玩家文件管理走真实设置入口、表格菜单、原位输入与编辑器返回，只使用独立测试目录。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_dir := ""
var _game: GameShell
var _paths: Dictionary = {}
var _opened_folders: Array[String] = []


## 延后构造场景，GPU截图仅写入显式传入的目录。
func _initialize() -> void:
	Engine.max_fps = 120
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 完整入口与文件生命周期使用隔离资料库，不读取或修改真实玩家存档。
func _run() -> void:
	_temporary = "user://tests/player_list_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.folder_opener = func(path: String) -> int:
		_opened_folders.append(path)
		return OK
	root.add_child(_game)
	for unused in 600:
		if _game.startup_complete:
			break
		await process_frame
	_check(_game.startup_complete, "独立测试游戏完成启动")
	await _settle()
	_create_fixtures()
	_check(_game.drafts.save_draft("list_good", "main() {}", []).is_ok() and _game.drafts.mark_completed("list_good").is_ok(), "夹具拥有独立程序和通关记录")
	var records := _records()
	await _test_settings_entry()
	await _test_all_column_sorting()
	await _test_sticky_header()
	await _test_column_dividers()
	await _test_statuses_and_layout()
	await _test_windows_card_transforms()
	await _test_rename()
	await _test_folder_and_delete()
	await _test_editor_roundtrip()
	await _test_stale_selection()
	await _test_failed_initial_path()
	await _test_game_page()
	_check(_records() == records, "管理列表的改名、编辑、删除均不触碰程序草稿和通关记录")
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("玩家关卡列表界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 从已加载教学地图复制有效结构，再分别制造真实的草稿、损坏与版本不兼容文件。
func _create_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(_game.user_levels_directory)
	var base := _game.catalog.levels[0].document.duplicate_document()
	base.id = "list_good"
	base.display_name = "Alpha地图"
	base.dialogue.clear()
	base.properties.level["creator"] = "Muna"
	base.extra["custom_extension"] = {"preserved": [1, "地图元数据"]}
	_save_fixture("good", base)
	var spawn := base.duplicate_document()
	spawn.id = "list_spawn"
	spawn.display_name = "缺少起点"
	spawn.player_spawn = null
	_save_fixture("spawn", spawn)
	var goal := base.duplicate_document()
	goal.id = "list_goal"
	goal.display_name = "缺少终点"
	goal.properties.level.erase("goal")
	_save_fixture("goal", goal)
	var battle := _game.catalog.levels[3].document.duplicate_document()
	battle.id = "list_battle"
	battle.display_name = "击毁目标"
	battle.dialogue.clear()
	_save_fixture("battle", battle)
	var newer := base.to_dict()
	newer.id = "list_newer"
	newer.name = "更新版本地图"
	newer.format_version = 99
	_write_fixture("newer", JSON.stringify(newer))
	var module := base.to_dict()
	module.id = "list_module"
	module.name = "未知模块地图"
	module.player_spawn.modules[0].module_id = "future_module"
	_write_fixture("module", JSON.stringify(module))
	_write_fixture("broken", "{broken")
	var unnamed := base.duplicate_document()
	unnamed.id = "list_unnamed"
	unnamed.display_name = "未署名地图"
	unnamed.properties.level.erase("creator")
	_save_fixture("unnamed", unnamed)


## 所有正常和未完成地图均通过编辑器一致的草稿校验写入指定路径。
func _save_fixture(key: String, document: MapDocument) -> void:
	_paths[key] = _game.user_levels_directory.path_join(key + ".json")
	_check(MapCodec.save_file(document, _paths[key], _game.registry, false).is_ok(), "保存隔离地图夹具 " + key)


## 损坏文件和新版本文件刻意绕过编辑校验，仅作为列表展示与拒绝操作的夹具。
func _write_fixture(key: String, value: String) -> void:
	_paths[key] = _game.user_levels_directory.path_join(key + ".json")
	var file := FileAccess.open(_paths[key], FileAccess.WRITE)
	file.store_string(value)
	file.close()


## 从主菜单真实点击设置，等待内容过渡后滚动到新的文件列表入口。
func _test_settings_entry() -> void:
	await _click_control(_game.find_child("SettingsButton", true, false) as Control)
	for unused in 300:
		if _game.page == GameShell.Page.SETTINGS and not _game._menu_transitioning:
			break
		await process_frame
	_check(_game.page == GameShell.Page.SETTINGS, "真实设置按钮进入设置页")
	var card := _game._menu_card
	var entry := _game.settings_panel.find_child("PlayerLevelListButton", true, false) as Button
	_check(entry != null and entry.text == "玩家关卡列表", "设置更多分组提供玩家关卡列表入口")
	_game.settings_panel._scroll.ensure_control_visible(entry)
	await _settle()
	await _click_control(entry)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST and _game.player_level_list_panel != null, "点击新入口直接显示文件列表")
	_check(_game._menu_card == card, "文件列表沿用设置同一白色卡片和背景")
	_check(_game.player_level_library.entries.size() == _paths.size(), "有效、草稿、新版本和损坏JSON都保留在管理列表")
	await _click_control(_game._back_button)
	_check(_game.page == GameShell.Page.SETTINGS, "管理列表返回按钮回到设置")
	_game._show_player_level_list_page()
	await _settle()


## 独立展示记录覆盖同名、同作者和同秒创建时间；日期列必须按真实时间字段而非日期文本排序。
func _test_all_column_sorting() -> void:
	var panel := _game.player_level_list_panel
	var records: Array[PlayerLevelRecord] = []
	var definitions := [
		["a", "Zulu", "Muna", 1700000002, 0],
		["b", "Alpha", "Nora", 1700000001, 3],
		["c", "Alpha", "Muna", 1700000003, 1],
		["d", "Beta", "", 0, 2],
		["e", "Gamma", "Muna", 1700000002, 0],
	]
	for values: Array in definitions:
		var entry := PlayerLevelRecord.new()
		entry.source_path = _temporary.path_join(str(values[0]) + ".json")
		entry.display_name = values[1]
		entry.creator = values[2]
		entry.created_at = values[3]
		if values[4] == 1:
			entry.errors.append("缺少必要的终点")
		entry.requires_newer_version = values[4] == 2
		entry.is_corrupt = values[4] == 3
		records.append(entry)
	panel.set_entries(records)
	await _settle()
	var expected := {
		"name": [["b", "c", "d", "e", "a"], ["a", "e", "d", "b", "c"]],
		"creator": [["c", "e", "a", "b", "d"], ["b", "c", "e", "a", "d"]],
		"created_at": [["b", "e", "a", "c", "d"], ["c", "e", "a", "b", "d"]],
		"status": [["e", "a", "c", "d", "b"], ["b", "d", "c", "e", "a"]],
	}
	for column: String in expected:
		var button := _sort_button(column)
		_check(button != null and button.find_child("SortChevron", true, false) != null, "四个表头都具有真实可点击的排序箭头 " + column)
		if panel._sort_column != column or not panel._ascending:
			await _click_control(button)
		await _wait_sort(button, true)
		_check(_shown_names() == expected[column][0], "升序按本列真实值排列，同值名称路径升序，空值末尾 " + column)
		await _click_control(button)
		await _wait_sort(button, false)
		_check(_shown_names() == expected[column][1], "降序只反转主值，同值顺序稳定，空值仍末尾 " + column)
		var reordered := records.duplicate()
		reordered.reverse()
		panel.set_entries(reordered)
		await _settle()
		_check(_shown_names() == expected[column][1], "刷新传入顺序变化仍保持当前列、方向与同值稳定次序 " + column)
	await _click_control(_sort_button("created_at"))
	await _wait_sort(_sort_button("created_at"), true)
	var date_strings: Array[String] = []
	for row in panel._rows_container.get_children():
		if row.get_meta("source_path").get_file() != "d.json":
			date_strings.append((row.find_child("PlayerLevelCreatedAt", true, false) as Label).text)
	_check(date_strings.size() == 4 and date_strings.count(date_strings[0]) == 4 and _shown_names() == expected.created_at[0], "同一天不同秒的创建时间仍正确排序，而非按显示日期或文件名排列")
	await _test_sort_animation(_sort_button("created_at"), expected.created_at)
	panel.set_search_open(true, false)
	_type_text(panel._search_input, "Muna")
	await _settle()
	_check(_shown_names() == ["e", "a", "c"], "搜索结果继承当前创建时间升序")
	panel.set_entries(records)
	await _settle()
	_check(panel._search_input.text == "Muna" and _shown_names() == ["e", "a", "c"] and panel._sort_column == "created_at" and panel._ascending, "数据刷新保留筛选和非名称列的排序方向")
	panel.set_search_open(false, false)
	_game._refresh_player_level_list()
	await _settle()
	await _click_control(_sort_button("name"))
	await _wait_sort(_sort_button("name"), true)
	panel._scroll.scroll_vertical = 0
	await _settle()


## 长列表滚动后表头吸顶仍能排序和滚动，隐藏的行不能穿透点击，键盘聚焦行保持完整可读。
func _test_sticky_header() -> void:
	var panel := _game.player_level_list_panel
	var records: Array[PlayerLevelRecord] = []
	for index in 30:
		var entry := PlayerLevelRecord.new()
		entry.source_path = _temporary.path_join("sticky_%02d.json" % index)
		entry.display_name = "Sticky%02d" % index
		entry.creator = "Muna"
		records.append(entry)
	panel.set_entries(records)
	for locale in ["zh_CN", "en", "zh_HK"]:
		_game.settings.set_language(locale)
		for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			panel._scroll.scroll_vertical = 0
			await _settle()
			var header := panel.find_child("PlayerLevelStickyHeader", true, false) as Control
			var context := str(locale) + str(dimensions)
			var initial_rect := header.get_global_rect()
			var first_row := panel._rows_container.get_child(0) as Control
			_check(initial_rect.end.y < first_row.global_position.y and not panel._header_cover.visible, "未吸顶表头保持说明卡下方原位置 " + context)
			panel._scroll.scroll_vertical = 500
			await _settle()
			var pinned_rect := header.get_global_rect()
			var row_before := first_row.global_position.y
			_check(panel._header_cover.visible and pinned_rect.position.y < initial_rect.position.y and pinned_rect.position.y > panel._search_area.get_global_rect().end.y, "表头滑到导航下方后固定且避开搜索 " + context)
			panel._scroll.scroll_vertical += 80
			await _settle()
			_check(header.get_global_rect() == pinned_rect and first_row.global_position.y < row_before - 70, "表头位置固定时下方列表仍继续滚动 " + context)
			var before_sort := panel._scroll.scroll_vertical
			var ascending := not panel._ascending
			await _click_control(_sort_button("name"))
			await _wait_sort(_sort_button("name"), ascending)
			_check(panel._ascending == ascending and _shown_names()[0] == ("sticky_00" if ascending else "sticky_29"), "吸顶排序按钮真实命中并改变列表顺序 " + context)
			_check(panel._scroll.scroll_vertical == before_sort and header.get_global_rect() == pinned_rect, "点击吸顶排序保留滚动位置和表头几何 " + context)
			await _wheel_on_header(header.get_global_rect().get_center())
			_check(panel._scroll.scroll_vertical > before_sort and header.get_global_rect() == pinned_rect, "表头上滚轮继续滚动列表 " + context)
			var selected := panel._selected_path
			await _click(Vector2(pinned_rect.position.x + 20, pinned_rect.position.y - 15), MOUSE_BUTTON_RIGHT)
			_check(panel._selected_path == selected and not panel.is_context_menu_open(), "吸顶上方隐藏的行不能接收右键 " + context)
			await _key(KEY_TAB)
			var focused_row := panel._rows_container.get_child(0) as Button
			focused_row.grab_focus()
			await _settle()
			_check(focused_row.get_global_rect().position.y >= header.get_global_rect().end.y + 7, "键盘聚焦行滚入吸顶表头下方清晰区 " + context)
			if locale == "zh_CN" and dimensions.x == 1280:
				panel._scroll.scroll_vertical = 450
				await _settle()
				await _capture("list-sticky-header")
	_game.settings.set_language("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game._refresh_player_level_list()
	panel._scroll.scroll_vertical = 0
	await _settle()


## 真实拖动三个列间分隔，验证正文同步、最小宽度、吸顶、刷新与不同语言窗口。
func _test_column_dividers() -> void:
	var panel := _game.player_level_list_panel
	var records: Array[PlayerLevelRecord] = []
	for index in 30:
		var entry := PlayerLevelRecord.new()
		entry.source_path = _temporary.path_join("width_%02d.json" % index)
		entry.display_name = "Width%02d" % index
		entry.creator = "Muna"
		records.append(entry)
	panel.set_entries(records)
	for locale in ["zh_CN", "en", "zh_HK"]:
		_game.settings.set_language(locale)
		for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			panel._scroll.scroll_vertical = 0
			await _settle()
			var context := str(locale) + str(dimensions)
			for index in 3:
				var before := _column_widths()
				var sorting := [panel._sort_column, panel._ascending]
				var selected := panel._selected_path
				var delta := 18.0 if index != 1 else -18.0
				await _drag_column(index, delta)
				var after := _column_widths()
				_check(absf(after[index] - before[index] - delta) <= 2 and absf(after[index + 1] - before[index + 1] + delta) <= 2, "分隔%d只在相邻两列之间分配宽度 %s" % [index, context])
				for column in 4:
					if column != index and column != index + 1:
						_check(absf(after[column] - before[column]) <= 2, "拖动不挤压其他列 %d %s" % [column, context])
				_check(absf(after[0] + after[1] + after[2] + after[3] - before[0] - before[1] - before[2] - before[3]) <= 2, "拖动保持表格总宽 " + context)
				_check(sorting == [panel._sort_column, panel._ascending] and selected == panel._selected_path and panel._column_resize_index == -1, "分隔拖动松手不触发排序或行选中 " + context)
				_check_column_alignment(context)
			var saved := _column_widths()
			panel._scroll.scroll_vertical = 400
			await _settle()
			_check_column_alignment("吸顶 " + context)
			await _click_control(_sort_button("creator"))
			_check(_column_widths() == saved, "排序重建行仍保留用户列宽 " + context)
			panel.set_entries(records)
			await _settle()
			_check(_column_widths() == saved, "刷新列表仍保留用户列宽 " + context)
			await _drag_column(2, -12)
			_check_column_alignment("吸顶拖动 " + context)
			var scroll_before := panel._scroll.scroll_vertical
			await _wheel_on_header(panel._column_dividers[1].get_global_rect().get_center())
			_check(panel._scroll.scroll_vertical > scroll_before, "分隔线上的滚轮仍可滚动正文 " + context)
			if locale == "zh_CN" and dimensions.x == 1280:
				var filtered_widths := _column_widths()
				await _click_control(panel._search_button)
				await _wait_search(true)
				await _type_text(panel._search_input, "Width00")
				await _settle()
				_check(panel._rows.size() == 1 and _column_widths() == filtered_widths, "搜索筛选重建单行仍保留用户列宽")
				await _click_control(panel._search_close_button)
				await _wait_search(false)
				_check(panel._rows.size() == 30 and _column_widths() == filtered_widths, "关闭搜索恢复全部行并保留用户列宽")
				panel._scroll.scroll_vertical = 400
				await _settle()
				await _capture("list-columns-resized")
			await _drag_column(0, -2000)
			_check(absf(_column_widths()[0] - 64.0) <= 1, "名称列极端拖动保留64像素最小宽度 " + context)
			await _drag_column(0, 2000)
			_check(absf(_column_widths()[1] - 64.0) <= 1, "作者列极端拖动保留64像素最小宽度 " + context)
			_reset_column_widths()
			await _settle()
	# 调整窗口会终止旧尺寸手势，后续移动不能沿旧缓存改动新布局。
	var pointer := panel._column_dividers[0].get_global_rect().get_center()
	_column_pointer(pointer, true)
	root.size = Vector2i(1100, 740)
	root.content_scale_size = root.size
	await _settle()
	_check(panel._column_resize_index == -1 and not panel._column_dividers[0]._dragging, "窗口缩放终止进行中的列宽拖动")
	_column_pointer(pointer, false)
	_game.settings.set_language("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_reset_column_widths()
	_game._refresh_player_level_list()
	await _click_control(_sort_button("name"))
	if not panel._ascending:
		await _click_control(_sort_button("name"))
	panel._scroll.scroll_vertical = 0
	await _settle()
	await _capture("list-column-dividers")


## 读取实际表头宽度作为输入前后的独立证据，不依赖生产计算公式。
func _column_widths() -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for column in ["name", "creator", "created_at", "status"]:
		result.append(_sort_button(column).size.x)
	return result


## 每个分隔必须位于两列中间，正文与标题四列保持同一左右边界。
func _check_column_alignment(context: String) -> void:
	var panel := _game.player_level_list_panel
	var row := panel._rows_container.get_child(0) as Control
	for index in 4:
		var header := _sort_button(PlayerLevelListPanel.SORT_COLUMNS[index]).get_global_rect()
		var body := (row.find_child(PlayerLevelListPanel.COLUMN_NAMES[index], true, false) as Control).get_global_rect()
		_check(absf(header.position.x - body.position.x) <= 1 and absf(header.end.x - body.end.x) <= 1, "表头正文列边界一致 %d %s" % [index, context])
		if index < 3:
			var divider := panel._column_dividers[index]
			_check(absf(divider.get_global_rect().get_center().x - header.end.x - 6) <= 1 and absf(divider.global_position.y - header.position.y) <= 1, "分隔线始终跟随表头列间留白 %d %s" % [index, context])


## 测试后还原默认比例，避免后续字号与省略号回归依赖本轮拖动顺序。
func _reset_column_widths() -> void:
	var panel := _game.player_level_list_panel
	panel._column_weights = PackedFloat64Array(PlayerLevelListPanel.COLUMN_WEIGHTS)
	for index in 4:
		panel._configure_cell(_sort_button(PlayerLevelListPanel.SORT_COLUMNS[index]), index)
	for row in panel._rows_container.get_children():
		for index in 4:
			panel._configure_cell(row.find_child(PlayerLevelListPanel.COLUMN_NAMES[index], true, false) as Control, index)


## 鼠标从细线按下后移动到命中区以外并松开，验证原生捕获完整结束手势。
func _drag_column(index: int, delta: float) -> void:
	var panel := _game.player_level_list_panel
	var pointer := panel._column_dividers[index].get_global_rect().get_center()
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(pointer)
		await _settle()
	_column_pointer(pointer, true)
	for step in range(1, 4):
		var motion := InputEventMouseMotion.new()
		motion.position = root.get_final_transform() * (pointer + Vector2(delta * step / 3.0, 0))
		motion.global_position = motion.position
		motion.relative = Vector2(delta / 3.0, 0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(motion)
		Input.flush_buffered_events()
		await _settle()
	_column_pointer(pointer + Vector2(delta, 0), false)
	await _settle()


## 独立按下和松开事件保留原生按钮状态，窗口缩放测试也能结束捕获。
func _column_pointer(pointer: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * pointer
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(event)
	Input.flush_buffered_events()


## 完整滚轮按下和抬起路径验证浮动表头转发，不留下半次手势或原生鼠标捕获。
func _wheel_on_header(position: Vector2) -> void:
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(position)
		await _settle()
	var window_position := root.get_final_transform() * position
	var motion := InputEventMouseMotion.new()
	motion.position = window_position
	motion.global_position = window_position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = window_position
		event.global_position = window_position
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle()


## 箭头真实翻转经过中间角度，连续点击重定向后图标方向与实际排序最终一致。
func _test_sort_animation(button: Button, expected: Array) -> void:
	var arrow := button.find_child("SortChevron", true, false)
	_click_now(button)
	var intermediate := false
	for unused in 90:
		await process_frame
		var direction := float(arrow.direction_progress)
		intermediate = intermediate or (direction > -0.95 and direction < 0.95)
		if is_equal_approx(direction, 1.0):
			break
	_check(intermediate and is_equal_approx(float(arrow.direction_progress), 1.0) and _shown_names() == expected[1], "倒序箭头经过可见中间态再落定，实际列表同步倒序")
	for unused in 3:
		_click_now(button)
	await _wait_sort(button, true)
	_check(_shown_names() == expected[0] and _game.player_level_list_panel._ascending, "动画中快速三次点击最终停在升序，旧动画不能覆盖最后选择")


## 根据稳定节点名获取列按钮，避免测试依赖表头子节点顺序。
func _sort_button(column: String) -> Button:
	var names := {"name": "Name", "creator": "Creator", "created_at": "CreatedAt", "status": "Status"}
	return _game.player_level_list_panel.find_child("PlayerLevel%sSortButton" % names[column], true, false) as Button


## 按实际渲染行顺序返回短文件名，不调用生产比较器生成测试期待值。
func _shown_names() -> Array[String]:
	var result: Array[String] = []
	for row in _game.player_level_list_panel._rows_container.get_children():
		result.append(String(row.get_meta("source_path")).get_file().get_basename())
	return result


## 有界等待箭头自身的动画属性，验证最终方向而非固定帧数。
func _wait_sort(button: Button, ascending: bool) -> void:
	var arrow := button.find_child("SortChevron", true, false)
	for unused in 90:
		if is_equal_approx(float(arrow.direction_progress), -1.0 if ascending else 1.0):
			break
		await process_frame
	_check(is_equal_approx(float(arrow.direction_progress), -1.0 if ascending else 1.0), "排序箭头最终方向与升降序一致")


## 不等待完整动画便再次发出真实点击，用于复现用户快速切换排序方向。
func _click_now(control: Control) -> void:
	var position := control.get_global_transform_with_canvas() * (control.size * 0.5)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)


## 浅灰说明卡完整包住标题和描述，三语窄窗中卡片与表格对齐且不会遮挡导航。
func _check_intro_card(context: String) -> void:
	var panel := _game.player_level_list_panel
	var intro := panel.find_child("PlayerLevelListIntroCard", true, false) as PanelContainer
	_check(intro != null, "说明采用独立圆角卡片 " + context)
	if intro == null:
		return
	var surface := intro.get_theme_stylebox("panel") as StyleBoxFlat
	_check(surface != null and surface.bg_color.a > 0.9 and surface.bg_color.r > 0.85 and surface.bg_color.r < 0.995 and surface.corner_radius_top_left >= 8, "说明卡使用浅灰圆角背景 " + context)
	var labels := intro.find_children("*", "Label", true, false)
	_check(labels.size() >= 2 and _game._menu_card.get_global_rect().encloses(intro.get_global_rect()), "说明标题和正文位于白卡内 " + context)
	for label: Label in labels:
		_check(intro.get_global_rect().grow(-6).encloses(label.get_global_rect()), "说明文字完整容纳并与灰卡边缘留白 " + context)
	var header := panel.find_child("PlayerLevelTableHeader", true, false) as Control
	_check(intro.get_global_rect().end.y < header.global_position.y, "说明卡与列表表头留有间距 " + context)
	for column in ["name", "creator", "created_at", "status"]:
		var button := _sort_button(column)
		var caption := button.find_child("SortCaption", true, false) as Label
		var arrow := button.find_child("SortChevron", true, false) as Control
		_check(caption != null and arrow != null and button.get_global_rect().encloses(arrow.get_global_rect()) and caption.get_global_rect().end.x <= arrow.global_position.x + 1, "各列标题和排序箭头完整可见且不重叠 " + column + context)


## 缩小菜单仍以实际显示矩形约束边缘，三语文字完整且每个选项可被真实点击。
func _test_scaled_menu(locale: String) -> void:
	root.size = Vector2i(1000, 740)
	root.content_scale_size = root.size
	await _settle()
	var panel := _game.player_level_list_panel
	panel._scroll.ensure_control_visible(_row("good"))
	await _settle()
	var row := _row("good")
	var pointer := row.get_global_transform_with_canvas() * Vector2(row.size.x - 2, row.size.y - 2)
	await _click(pointer, MOUSE_BUTTON_RIGHT)
	var menu := panel._context_menu
	var screen_rect := menu._panel.get_global_rect()
	_check(menu.is_open() and is_equal_approx(screen_rect.size.y, 144.0), "四项菜单整体80%后实际高度为144像素 " + locale)
	_check(Rect2(Vector2(12, 12), root.get_visible_rect().size - Vector2(24, 24)).encloses(screen_rect), "菜单按缩小后显示范围保留屏幕边缘12像素 " + locale)
	for button: Button in menu._items:
		_check(absf(button.get_global_rect().size.y - 33.6) < 0.01 and screen_rect.encloses(button.get_global_rect()), "缩小菜单每项实际命中高度33.6且留在菜单中 " + locale)
		var text_width := button.get_theme_font("font").get_string_size(button.tr(button.text), HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x
		_check(text_width + 16 <= button.size.x + 1, "缩小后本土化菜单文本仍完整容纳 " + button.text + locale)
	await _capture("list-menu-80-" + locale)
	await _key(KEY_ESCAPE)
	_check(not menu.is_open() and _game.page == GameShell.Page.PLAYER_LEVEL_LIST, "缩小菜单Esc关闭不离开文件列表")
	panel._scroll.scroll_vertical = 0
	await _settle()


## 三种语言与最小窗口仍完整排列表格，状态颜色区分普通问题、新版本、损坏与正常。
func _test_statuses_and_layout() -> void:
	for locale in ["zh_CN", "en", "zh_HK"]:
		_game.settings.set_language(locale)
		for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			await _settle()
			var panel := _game.player_level_list_panel
			var card_rect := _game._menu_card.get_global_rect()
			_check(card_rect.encloses(panel._scroll.get_global_rect()), "列表滚动区域位于白卡内 " + locale + str(dimensions))
			_check_search_circle(locale + str(dimensions))
			_check_intro_card(locale + str(dimensions))
			for key: String in _paths:
				var row := _row(key)
				_check(row != null, "列表包含文件行 " + key + locale)
				if row == null:
					continue
				var previous_right := row.global_position.x
				for node_name in PlayerLevelListPanel.COLUMN_NAMES:
					var label := row.find_child(node_name, true, false) as Label
					_check(label.size.x > 0 and label.global_position.x >= previous_right and label.get_global_rect().end.x <= row.get_global_rect().end.x + 1, "四列保持正宽度且互不重叠 " + node_name + locale)
					previous_right = label.get_global_rect().end.x
				_check(row.size.x <= panel._scroll.size.x, "长状态不撑宽表格 " + key + locale)
				var status_text := _label(key, "PlayerLevelStatus").text
				_check(not status_text.contains("⚠") and not status_text.contains("ⓘ"), "状态仅显示文字、没有额外标识符 " + key + locale)
			_check(_label("good", "PlayerLevelCreator").text == "Muna" and _label("good", "PlayerLevelName").text == "Alpha地图", "切换语言不翻译用户名称或署名")
			_check(_label("good", "PlayerLevelStatus").text == panel.tr("状态正常") and _label("good", "PlayerLevelStatus").get_theme_color("font_color") == GameTheme.TEXT, "正常关卡使用信息提示和普通文字色 " + locale)
			_check(_label("broken", "PlayerLevelStatus").text == panel.tr("文件损坏") and _label("broken", "PlayerLevelStatus").get_theme_color("font_color") == Color("e62020"), "坏JSON标明文件损坏并使用警告红色 " + locale)
			for key in ["newer", "module"]:
				_check(_label(key, "PlayerLevelStatus").text == panel.tr("此关卡可能由更新的版本创建") and _label(key, "PlayerLevelStatus").get_theme_color("font_color") == Color("e62020"), "新格式和未知模块显示更新版本提示 " + key + locale)
			for key in ["spawn", "goal"]:
				_check(_label(key, "PlayerLevelStatus").get_theme_color("font_color") == Color("cb2222") and _label(key, "PlayerLevelStatus").text != panel.tr("文件损坏") and not _row(key).tooltip_text.is_empty(), "未完成地图显示具体原因与普通问题色 " + key + locale)
			_check(_label("battle", "PlayerLevelStatus").text == panel.tr("状态正常"), "击毁敌人的有效目标不误判为缺少终点 " + locale)
			_check(not _label("good", "PlayerLevelCreatedAt").text.is_empty(), "创建日期列具有真实日期或明确未知提示")
			if locale == "zh_CN" and dimensions.x == 1280:
				await _check_status_pixels()
			await _capture("list-" + locale + "-" + str(dimensions.x))
		await _test_scaled_menu(locale)
		await _test_search_and_sort(locale)
	_game.settings.set_language("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _settle()


## 注入 Windows 像素画幅验证独立搜索和菜单只继承一次白卡比例，焦点滚动仍按逻辑坐标移动。
func _test_windows_card_transforms() -> void:
	var controller := _game.window_controller
	var original_platform := controller.platform_name
	var original_screen_provider := controller.screen_size_provider
	var original_size := root.size
	var original_content_size := root.content_scale_size
	controller.platform_name = "Windows"
	controller.screen_size_provider = func() -> Vector2i:
		return Vector2i(3840, 2160)
	controller._refresh_screen()
	controller._on_settings_changed()
	root.size = Vector2i(3840, 2160)
	await _settle()
	var panel := _game.player_level_list_panel
	var factor := 2.7
	_check_search_circle("Windows 4K")
	_check(panel._search_button.get_global_rect().size.is_equal_approx(Vector2.ONE * PlayerLevelListPanel.SEARCH_HEIGHT * factor), "4K 搜索按钮与白卡一起放大，独立画布不重复应用比例")
	var closed_right := panel._search_area.get_global_rect().end.x
	await _click_control(panel._search_button)
	await _wait_search(true)
	_check(_game._menu_card.get_global_rect().encloses(panel._search_area.get_global_rect()) and absf(panel._search_area.get_global_rect().end.x - closed_right) < 1, "4K 搜索仍固定右端向左展开并保持白卡内完整命中区")
	root.size = Vector2i(1000, 740)
	await _settle()
	var title_right := _game._title.get_global_transform() * Vector2(_game._title.get_combined_minimum_size().x, 0)
	_check(_game._menu_card.get_global_rect().encloses(panel._search_area.get_global_rect()) and panel._search_area.global_position.x >= title_right.x + 15 and panel._search_area.scale.is_equal_approx(Vector2.ONE), "展开搜索从4K回到窄窗口后恢复一倍并避开导航")
	await _click_control(panel._search_close_button)
	await _wait_search(false)
	root.size = Vector2i(3840, 2160)
	await _settle()
	panel._scroll.ensure_control_visible(_row("good"))
	await _settle()
	await _click_control(_row("good"), MOUSE_BUTTON_RIGHT)
	var menu := panel._context_menu
	_check(menu.is_open() and absf(menu._panel.get_global_rect().size.y - 144.0 * factor) < 1, "4K 文件菜单保留八成比例并继承白卡放大")
	_check(root.get_visible_rect().encloses(menu._panel.get_global_rect()), "4K 文件菜单位于实际视口内")
	root.size = Vector2i(1000, 740)
	await _settle()
	_check(menu.is_open() and absf(menu._panel.get_global_rect().size.y - 144.0) < 1 and root.get_visible_rect().encloses(menu._panel.get_global_rect()), "打开菜单缩回窄窗口后重新按入口比例定位并恢复原命中高度")
	await _key(KEY_ESCAPE)
	root.size = Vector2i(3840, 2160)
	await _settle()
	# 只增加内存显示记录来制造滚动距离，不写入任何玩家文件或持久偏好。
	var original_entries := panel._entries.duplicate()
	var focus_entries: Array[PlayerLevelRecord] = []
	for index in 24:
		var entry := PlayerLevelRecord.new()
		entry.source_path = _temporary.path_join("scale_focus_%02d.json" % index)
		entry.display_name = "Scale Focus %02d" % index
		focus_entries.append(entry)
	panel.set_entries(focus_entries)
	await _settle()
	var target := panel._rows_container.get_child(12) as Control
	var visible := panel._scroll.get_global_rect()
	var desired_bottom := visible.end.y - 32.0 * factor
	panel._scroll.scroll_vertical += roundi((target.get_global_rect().end.y - desired_bottom) / factor)
	await _settle()
	panel._keyboard_focus = true
	target.grab_focus()
	await _settle()
	var top := maxf(visible.position.y + SettingsContentFade.CARD_FOCUS_TOP_INSET * factor, panel._table_header.get_global_rect().end.y + 8.0 * factor)
	var bottom := visible.end.y - (SettingsContentFade.TOP_FADE_WIDTH + 8.0) * factor
	var clear_region := Rect2(Vector2(visible.position.x, top), Vector2(visible.size.x, bottom - top))
	_check(clear_region.grow(1).encloses(target.get_global_rect()), "4K 键盘聚焦行完整进入导航和渐隐之外，不把视口像素当作逻辑滚动距离")
	_check(is_equal_approx(panel._content_fade._fade_parameters.y, SettingsContentFade.TOP_FADE_WIDTH * factor), "玩家列表渐隐宽度随同一张白卡等比放大")
	panel.set_entries(original_entries)
	panel._keyboard_focus = false
	controller.platform_name = original_platform
	controller.screen_size_provider = original_screen_provider
	controller._refresh_screen()
	controller._on_settings_changed()
	root.size = original_size
	root.content_scale_size = original_content_size
	await _settle()


## 搜索同时匹配作者与名称，清空恢复全部记录，表头点击真实反转显示顺序。
func _test_search_and_sort(locale: String) -> void:
	var panel := _game.player_level_list_panel
	var search := panel.find_child("PlayerLevelSearchInput", true, false) as LineEdit
	var area := panel.find_child("PlayerLevelSearchArea", true, false) as Control
	var before_open := area.get_global_rect()
	await _click_control(panel.find_child("PlayerLevelSearchButton", true, false) as Control)
	await _wait_search(true)
	_check(search.is_visible_in_tree() and search.has_focus() and search.caret_blink, "圆形搜索展开后自动聚焦并闪烁光标 " + locale)
	_check(area.size.x > before_open.size.x + 100 and absf(area.get_global_rect().end.x - before_open.end.x) < 1 and area.global_position.x < before_open.position.x, "搜索固定右端向左展开 " + locale)
	var card := _game._menu_card.get_global_rect()
	_check(card.encloses(area.get_global_rect()), "展开搜索完整位于白卡内 " + locale)
	_type_text(search, "Muna")
	await _settle()
	_check(panel._rows.size() == 5 and _row("broken") == null and _row("unnamed") == null, "按作者搜索排除无署名及坏JSON " + locale)
	await _capture("list-search-" + locale)
	var filtered_order := _shown_names()
	_game._refresh_player_level_list()
	await _settle()
	_check(search.text == "Muna" and search.has_focus() and _shown_names() == filtered_order, "真实目录刷新保持搜索焦点、查询及排序结果 " + locale)
	root.size = Vector2i(1000, 740)
	root.content_scale_size = root.size
	await _settle()
	var title_right := _game._title.get_global_transform() * Vector2(_game._title.get_theme_font("font").get_string_size(_game._title.tr(_game._title.text), HORIZONTAL_ALIGNMENT_LEFT, -1, _game._title.get_theme_font_size("font_size")).x, 0)
	_check(_game._menu_card.get_global_rect().encloses(area.get_global_rect()) and area.global_position.x > title_right.x + 15 and search.text == "Muna", "搜索展开时缩到最小窗口仍避让导航、保留输入 " + locale)
	_type_text(search, "缺少起点")
	await _settle()
	_check(panel._rows.size() == 1 and _row("spawn") != null, "按名称搜索保留缺起点草稿 " + locale)
	_type_text(search, "没有匹配结果")
	await _settle()
	_check(panel._rows.is_empty() and panel._empty.visible, "无匹配时显示空状态 " + locale)
	await _key(KEY_ESCAPE)
	await _wait_search(false)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST and search.text.is_empty() and not search.has_focus() and panel._rows.size() == _paths.size(), "Esc清空筛选并收起搜索，不返回设置 " + locale)
	_check_search_circle(locale + " Esc后")
	await _click_control(panel.find_child("PlayerLevelSearchButton", true, false) as Control)
	await _wait_search(true)
	_type_text(search, "Muna")
	await _settle()
	await _click_control(panel.find_child("PlayerLevelSearchCloseButton", true, false) as Control)
	await _wait_search(false)
	_check(search.text.is_empty() and panel._rows.size() == _paths.size(), "收起箭头也清空筛选并恢复全部地图 " + locale)
	var before: Array[String] = []
	for child in panel._rows_container.get_children():
		before.append(child.get_meta("source_path"))
	await _click_control(panel.find_child("PlayerLevelNameSortButton", true, false) as Control)
	var after: Array[String] = []
	for child in panel._rows_container.get_children():
		after.append(child.get_meta("source_path"))
	before.reverse()
	_check(before == after and after.size() == _paths.size(), "名称排序反转行顺序且没有丢失地图 " + locale)


## 初始搜索圆与白卡右上R角共享圆心，输入框关闭时不占据标题行。
func _check_search_circle(context: String) -> void:
	var panel := _game.player_level_list_panel
	var button := panel.find_child("PlayerLevelSearchButton", true, false) as Control
	var search := panel.find_child("PlayerLevelSearchInput", true, false) as LineEdit
	var boundary := _game._menu_card.get_global_rect()
	var surface := _game._menu_card.get_theme_stylebox("panel") as StyleBoxFlat
	var radius := float(surface.corner_radius_top_right) * absf(_game._menu_card.get_global_transform().get_scale().x)
	var expected := Vector2(boundary.end.x - radius, boundary.position.y + radius)
	_check(button.is_visible_in_tree() and is_equal_approx(button.size.x, button.size.y) and button.get_global_rect().get_center().distance_to(expected) < 1, "圆形搜索与白卡右上圆角同心 " + context)
	_check(not search.is_visible_in_tree(), "收起时仅显示放大镜、不展示输入框 " + context)


## 有界等待实际搜索进度，避免把动画时长假定为固定几帧。
func _wait_search(open: bool) -> void:
	var panel := _game.player_level_list_panel
	for unused in 300:
		if is_equal_approx(panel._search_progress, 1.0 if open else 0.0):
			break
		await process_frame
	await _settle()
	_check(is_equal_approx(panel._search_progress, 1.0 if open else 0.0), "搜索展开或收起动画完成")


## 右键名称原位重命名，取消与非法输入不写盘，合法回车保留元数据和文件路径。
func _test_rename() -> void:
	var original := FileAccess.get_file_as_bytes(_paths.good)
	await _action("good", "ListRenamePlayerLevelButton")
	var edit := _active_input()
	_check(edit != null and edit.has_focus() and edit.get_selected_text() == "Alpha地图" and edit.caret_blink, "菜单重命名全选原名并显示闪烁光标")
	if edit == null:
		return
	await _click_control(edit, MOUSE_BUTTON_RIGHT)
	_check(edit.get_menu().visible and _active_input() == edit, "右键原位文本打开系统编辑菜单，不取消改名")
	await _key(KEY_ESCAPE)
	_check(not edit.get_menu().visible and _active_input() == edit and edit.has_focus(), "Esc收起系统文本菜单后继续保持名称编辑焦点")
	_type_text(edit, "取消改名")
	await _key(KEY_ESCAPE)
	_check(_active_input() == null and _game.page == GameShell.Page.PLAYER_LEVEL_LIST and FileAccess.get_file_as_bytes(_paths.good) == original, "Esc只取消原位改名，不离开列表或写盘")
	await _action("good", "ListRenamePlayerLevelButton")
	edit = _active_input()
	for candidate in ["前 后", "地图%", "地图🌊", "abcdefghijklmnopqrstuvwxyz12345"]:
		_type_text(edit, candidate)
		await _key(KEY_ENTER)
		_check(_active_input() == edit and edit.has_focus() and FileAccess.get_file_as_bytes(_paths.good) == original, "非法名称不能按回车保存：" + candidate)
	_check(not _game._message_dialog.visible and not edit.tooltip_text.is_empty(), "错误在原位显示，不弹出改名对话框")
	if DisplayServer.get_name() != "headless":
		var previous_clipboard := DisplayServer.clipboard_get()
		DisplayServer.clipboard_set("粘贴 % 🌊 名称")
		edit.select_all()
		await _key(KEY_V, true)
		_check(edit.text == "粘贴 % 🌊 名称", "系统剪贴板非法内容可以原样粘入供用户修正")
		await _key(KEY_ENTER)
		_check(_active_input() == edit and FileAccess.get_file_as_bytes(_paths.good) == original, "强行粘贴非法内容后回车仍无法保存")
		DisplayServer.clipboard_set(previous_clipboard)
	await _check_input_outline(edit)
	await _capture("list-rename-invalid")
	_type_text(edit, "新地图_Muna-É3")
	await _capture("list-rename")
	await _key(KEY_ENTER)
	var loaded := MapCodec.load_file(_paths.good, _game.registry, false)
	_check(_active_input() == null and loaded.is_ok() and loaded.value.display_name == "新地图_Muna-É3", "合法名字直接回车写入并退出原位编辑")
	_check(loaded.value.id == "list_good" and loaded.value.properties.level.creator == "Muna" and loaded.value.extra.custom_extension.preserved[1] == "地图元数据", "列表改名保持ID、路径、作者和地图扩展字段")
	await _action("spawn", "ListRenamePlayerLevelButton")
	_type_text(_active_input(), "可编辑的草稿")
	await _key(KEY_ENTER)
	_check(MapCodec.load_file(_paths.spawn, _game.registry, false).value.display_name == "可编辑的草稿", "不能运行的缺起点地图仍可原位重命名")


## 文件夹请求交给注入的系统适配器，坏JSON可删但其编辑和改名入口禁用。
func _test_folder_and_delete() -> void:
	await _action("good", "ListOpenPlayerLevelFolderButton")
	_check(_opened_folders == [ProjectSettings.globalize_path(_game.user_levels_directory)], "查看目录只调用已导入关卡的真实托管目录")
	await _open_menu("broken")
	var panel := _game.player_level_list_panel
	_check((panel.find_child("ListRenamePlayerLevelButton", true, false) as Button).disabled and (panel.find_child("ListEditPlayerLevelButton", true, false) as Button).disabled, "坏JSON禁用不可用的改名和编辑")
	_check(not (panel.find_child("ListDeletePlayerLevelButton", true, false) as Button).disabled and not (panel.find_child("ListOpenPlayerLevelFolderButton", true, false) as Button).disabled, "坏JSON仍可删除或查看目录")
	await _capture("list-context-menu")
	var preserved := FileAccess.get_file_as_bytes(_paths.good)
	await _click_control(panel.find_child("ListDeletePlayerLevelButton", true, false) as Control)
	_check(not FileAccess.file_exists(_paths.broken) and _row("broken") == null and FileAccess.get_file_as_bytes(_paths.good) == preserved, "删除只移除选中坏文件并即时刷新列表")


## 从列表打开草稿直接绑定其托管路径，保存退出和放弃退出都返回同一管理入口。
func _test_editor_roundtrip() -> void:
	await _action("spawn", "ListEditPlayerLevelButton")
	var editor := _game._editor
	_check(_game.page == GameShell.Page.EDITOR and editor != null and editor.initial_map_opened, "不能运行但结构有效的草稿可以进入地图编辑器")
	if editor == null:
		return
	_check(editor.editor_document.path == _paths.spawn and editor._managed_save_path == _paths.spawn and editor.editor_document.document.id == "list_spawn" and not editor.editor_document.is_dirty(), "编辑器首次就打开正确托管文档且初始无脏状态")
	_check(editor.editor_document.document.player_spawn == null and editor.initial_map_error.is_empty(), "载入缺起点草稿不补造起点或中途加载示例地图")
	await _click_control(editor._header.back_button)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST, "未修改直接返回玩家列表")
	await _action("spawn", "ListEditPlayerLevelButton")
	editor = _game._editor
	editor.editor_document.paint(Vector2i(0, 0), "floor")
	_check(editor.editor_document.is_dirty(), "真实地图编辑进入未保存状态")
	await _click_control(editor._header.back_button)
	_check(_game._editor_discard_dialog.visible and _game.page == GameShell.Page.EDITOR, "有改动返回保留原未保存确认语义")
	await _click_control(_game._editor_discard_dialog._cancel_button)
	_check(_game._editor == editor and editor.editor_document.is_dirty(), "取消退出保留同一编辑器和历史")
	await _click_control(editor._header.back_button)
	await _click_control(_game._editor_discard_dialog._save_button)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST and not _game._editor_discard_dialog.visible, "保存完成后回玩家列表")
	var saved := MapCodec.load_file(_paths.spawn, _game.registry, false)
	_check(saved.is_ok() and saved.value.get_tile_id(Vector2i(0, 0)) == "floor" and saved.value.id == "list_spawn", "保存写回原托管文件，不新建副本或改变ID")
	_check(DirAccess.get_files_at(_game.user_levels_directory).size() == _paths.size() - 1, "编辑已有关卡保存不会额外产生玩家地图")
	await _action("spawn", "ListEditPlayerLevelButton")
	editor = _game._editor
	var baseline := FileAccess.get_file_as_bytes(_paths.spawn)
	editor.editor_document.paint(Vector2i(0, 0), "")
	await _click_control(editor._header.back_button)
	await _click_control(_game._editor_discard_dialog._discard_button)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST and FileAccess.get_file_as_bytes(_paths.spawn) == baseline, "不保存返回玩家列表且磁盘草稿不变")
	await _action("good", "ListEditPlayerLevelButton")
	editor = _game._editor
	editor._start_playtest()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game._editor_playtest, "已打开的有效地图仍可进入原装配试玩流程")
	_game._go_back()
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and _game._editor == editor and editor.editor_document.path == _paths.good, "试玩返回保留同一编辑器与原托管路径")
	await _click_control(editor._header.back_button)


## 外部修改及刷新使旧条目失效，迟到编辑、删除、目录请求都不能误操作新文件。
func _test_stale_selection() -> void:
	var stale := _entry("good")
	var external := MapCodec.load_file(_paths.good, _game.registry, false).value as MapDocument
	external.display_name = "外部更新地图"
	_check(MapCodec.save_file(external, _paths.good, _game.registry, false).is_ok(), "模拟列表打开后外部替换文件")
	var bytes := FileAccess.get_file_as_bytes(_paths.good)
	_game._open_editor_from_player_entry(stale)
	_game._delete_player_entry(stale)
	_game._open_player_entry_folder(stale)
	_check(_game.page == GameShell.Page.PLAYER_LEVEL_LIST and FileAccess.get_file_as_bytes(_paths.good) == bytes and _opened_folders.size() == 1, "旧快照无法编辑、删除或打开外部已改变的文件")
	_check((_game.player_level_list_panel.find_child("PlayerLevelListError", true, false) as Label).visible, "过期选择显示可读错误且不离开列表")
	_game._refresh_player_level_list()
	await _settle()
	_check(_label("good", "PlayerLevelName").text == "外部更新地图", "刷新后显示最新文件名称")
	var current := _entry("good")
	_game._show_settings_page()
	_game._delete_player_entry(current)
	_game._open_editor_from_player_entry(current)
	_game._open_player_entry_folder(current)
	_check(_game.page == GameShell.Page.SETTINGS and FileAccess.get_file_as_bytes(_paths.good) == bytes and _opened_folders.size() == 1, "离开管理页后的迟到请求不会修改文件或跳页")


## 初始路径失效时编辑器返回明确错误，不加载无关示例或打开自己的阻塞提示。
func _test_failed_initial_path() -> void:
	var editor := MapEditor.new()
	editor.initial_map_path = _game.user_levels_directory.path_join("missing.json")
	editor.player_levels_directory = _game.user_levels_directory
	root.add_child(editor)
	await _settle()
	_check(not editor.initial_map_opened and not editor.initial_map_error.is_empty(), "初始指定文件消失时向外壳返回可读失败")
	_check(editor.editor_document.path.is_empty() and PlayerLevelStore.is_generated_map_id(editor.editor_document.document.id) and not editor._message_dialog.visible, "指定图打开失败仅留下有新随机 ID 的空白草稿，不偷换示例或弹出编辑器对话框")
	editor.queue_free()
	await _settle()


## 进入游玩选关时只保留原有效关卡，没有旧的底部导入错误展示按钮。
func _test_game_page() -> void:
	_game.catalog.refresh(_game.registry)
	_game._show_level_page()
	await _settle()
	var good_found := false
	var invalid_found := false
	for entry: Dictionary in _game._level_entries:
		good_found = good_found or entry.definition.id == "list_good"
		invalid_found = invalid_found or entry.definition.id in ["list_spawn", "list_newer", "list_module"]
	_check(good_found and not invalid_found, "游玩页面继续展示有效地图并排除无法运行的文件")
	var old_status := false
	for node in _game.find_children("*", "Control", true, false):
		if node is Button:
			old_status = old_status or node.text == "查看导入问题"
	_check(not old_status, "游戏关卡页不再提供旧导入问题按钮")
	_game._show_player_level_list_page()
	await _settle()
	await _capture("list-final")


## 依据源路径找回当前行，不依赖排序或重建后的控件引用。
func _row(key: String) -> Button:
	if not is_instance_valid(_game.player_level_list_panel):
		return null
	for row in _game.player_level_list_panel.find_children("*", "Button", true, false):
		if row.get_meta("source_path", "") == _paths[key]:
			return row as Button
	return null


## 读取指定文件行的稳定命名字段，用于界面结果断言。
func _label(key: String, node_name: String) -> Label:
	var row := _row(key)
	return row.find_child(node_name, true, false) as Label if row != null else null


## 每次操作从当前列表快照取记录，只有安全性测试刻意保留旧对象。
func _entry(key: String) -> PlayerLevelRecord:
	for entry: PlayerLevelRecord in _game.player_level_library.entries:
		if entry.source_path == _paths[key]:
			return entry
	return null


## 当前输入框只在编辑态存在，不引用已经释放的旧控件。
func _active_input() -> LineEdit:
	return _game.player_level_list_panel.find_child("PlayerLevelListNameInput", true, false) as LineEdit


## 把目标行滚入清晰区域并真实右键，菜单应靠近点击坐标而非焦点滚动后的行位置。
func _open_menu(key: String) -> void:
	var panel := _game.player_level_list_panel
	panel._scroll.ensure_control_visible(_row(key))
	await _settle()
	var clicked_center := _row(key).get_global_rect().get_center()
	await _click_control(_row(key), MOUSE_BUTTON_RIGHT)
	_check(panel.is_context_menu_open(), "真实右键打开文件操作菜单 " + key)
	var menu_rect := panel._context_menu._panel.get_global_rect()
	var current_center := _row(key).get_global_rect().get_center()
	var placed_near_row := menu_rect.grow(20).has_point(clicked_center) and root.get_visible_rect().encloses(menu_rect)
	_check(placed_near_row, "右键菜单紧邻点击行且完整留在窗口内 %s（点击 %s、当前 %s、菜单 %s、指针 %s）" % [key, clicked_center, current_center, menu_rect, panel._context_menu._pointer])
	if not placed_near_row:
		await _capture("list-menu-placement-failure-" + key)


## 菜单命令从按钮命中执行，不直接发出面板信号。
func _action(key: String, button_name: String) -> void:
	await _open_menu(key)
	await _click_control(_game.player_level_list_panel.find_child(button_name, true, false) as Control)


## 对逻辑控件经完整变换计算屏幕坐标，同时支持设置内容的80%缩放。
func _click_control(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_check(is_instance_valid(control), "真实点击目标存在")
	if not is_instance_valid(control):
		return
	await _click(control.get_global_transform_with_canvas() * (control.size * 0.5), button)


## 同一帧完成鼠标移动、按下与抬起，避免真实桌面鼠标在半次手势中改变悬停。
func _click(position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(position)
		await _settle()
	var window_position := root.get_final_transform() * position
	var motion := InputEventMouseMotion.new()
	motion.position = window_position
	motion.global_position = window_position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = window_position
		event.global_position = window_position
		event.button_index = button
		event.pressed = down
		event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if down else 0
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle()


## 文字走聚焦输入框的键盘路由，空文本使用退格而非伪造信号。
func _type_text(input: LineEdit, text: String) -> void:
	if input == null:
		_check(false, "待输入的原位名称框存在")
		return
	input.select_all()
	if text.is_empty():
		var erase := InputEventKey.new()
		erase.pressed = true
		erase.keycode = KEY_BACKSPACE
		root.push_input(erase, true)
	for character in text:
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = character.unicode_at(0)
		root.push_input(event, true)


## 提交和取消都采用真实按键事件，保证场景导航不会抢走编辑中的Esc。
func _key(code: Key, command: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.meta_pressed = command and OS.get_name() == "macOS"
		event.ctrl_pressed = command and OS.get_name() != "macOS"
		event.pressed = down
		root.push_input(event, true)
	await _settle()


## 原位错误边框的上边应完整可见，不能被原标题的单行裁剪区域切掉。
func _check_input_outline(input: LineEdit) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var ratio := Vector2(image.get_size()) / root.get_visible_rect().size
	var bounds := input.get_global_rect()
	var colored := 0
	for y in range(maxi(0, int(bounds.position.y * ratio.y) - 1), mini(image.get_height(), ceili((bounds.position.y + 3) * ratio.y))):
		for x in range(int((bounds.position.x + 6) * ratio.x), mini(image.get_width(), int((bounds.end.x - 6) * ratio.x))):
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.5 and pixel.g < 0.45 and pixel.b < 0.45:
				colored += 1
	_check(colored >= 15, "原位错误框上边未被标题裁剪，实际红边采样%d像素" % colored)


## 从实际GPU成像中的实心字形采样，确保合成渐隐没有改变要求的两种红色。
func _check_status_pixels() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var scroll := _game.player_level_list_panel._scroll
	var original_scroll := scroll.scroll_vertical
	for key: String in ["goal", "newer"]:
		var label := _label(key, "PlayerLevelStatus")
		scroll.scroll_vertical += roundi(label.get_global_rect().get_center().y - scroll.get_global_rect().get_center().y)
		await _settle()
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var ratio := Vector2(image.get_size()) / root.get_visible_rect().size
		var expected := Color("cb2222") if key == "goal" else Color("e62020")
		var label_rect := _label(key, "PlayerLevelStatus").get_global_rect()
		var solid := 0
		for y in range(int(label_rect.position.y * ratio.y), mini(image.get_height(), ceili(label_rect.end.y * ratio.y))):
			for x in range(int((label_rect.position.x + 20) * ratio.x), mini(image.get_width(), ceili(label_rect.end.x * ratio.x))):
				var pixel := image.get_pixel(x, y)
				if absf(pixel.r - expected.r) < 0.004 and absf(pixel.g - expected.g) < 0.004 and absf(pixel.b - expected.b) < 0.004:
					solid += 1
		_check(solid >= 10, "GPU实心文字保持指定颜色 #%s，采样%d像素" % [expected.to_html(false), solid])

	scroll.scroll_vertical = original_scroll
	await _settle()

## 保存完整场景截图，始终由真实GPU渲染产出。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename + ".png")) == OK, "保存界面截图 " + filename)


## 记录独立存档字节，管理操作不得重写游玩进度。
func _records() -> Dictionary:
	var result := {}
	for name: String in DirAccess.get_files_at(_game.drafts_directory):
		result[name] = FileAccess.get_file_as_bytes(_game.drafts_directory.path_join(name))
	return result


## 等待布局、延后刷新与释放完成。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 统一累计断言，让失败日志保留明确场景与期待行为。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 清理范围仅限当前进程创建的测试目录。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	for file: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for directory: String in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(directory))
	DirAccess.remove_absolute(path)
