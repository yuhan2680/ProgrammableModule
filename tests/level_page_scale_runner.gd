extends "res://tests/windows_menu_card_runner.gd"
## 通过实际选关页面验证高分辨率图标、文字和命中范围，并隔离所有测试存档。

var _base_icon_bounds := Vector2.ZERO
var _base_header_height := 0.0
var _last_icon_width := 0.0
var _svg_sources: Dictionary = {}


## 同一真实游戏实例跨分辨率和字号复用页面，覆盖初次进入及返回后的布局。
func _run() -> void:
	_check_exportable_svg_sources()
	_temporary = "user://tests/level_page_scale_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	for path: String in ["navigation_back", "navigation_forward", "search", "search_collapse", "more", "refresh", "import_level", "sort"]:
		_svg_sources[path] = load("res://assets/ui/" + path + ".svg")
	await _create_game()
	_set_platform("Windows")
	_game.settings.set_menu_background("solid")
	_game.settings.set_language("zh_CN")
	_add_player_fixtures()
	_game.catalog.refresh(_game.registry)
	for dimensions: Vector2i in WINDOWS_SIZES:
		if not _native_size_available(dimensions):
			continue
		await _check_level_size(dimensions)
	await _check_platform_and_resize()
	await _dispose_game()
	_finish()


## 打包用 XML 必须与矢量原件一致，后续改图时不能让导出程序继续绘制旧图标。
func _check_exportable_svg_sources() -> void:
	var source_script = preload("res://scripts/ui/level_browser_icon_sources.gd")
	for path: String in source_script.SVG:
		_check(source_script.SVG[path] == FileAccess.get_file_as_string(path), "可导出图标源数据与原 SVG 一致 " + path)


## 七张合法玩家地图让两组都能展开；写盘仅限本轮独占目录。
func _add_player_fixtures() -> void:
	DirAccess.make_dir_recursive_absolute(_game.user_levels_directory)
	for index in 7:
		var document := _game.catalog.levels[0].document.duplicate_document()
		document.id = "scale_player_%02d" % index
		document.display_name = "缩放测试%02d" % index
		document.properties.level["creator"] = "Muna"
		_check(MapCodec.save_file(document, _game.user_levels_directory.path_join(document.id + ".json"), _game.registry).is_ok(), "写入隔离玩家关卡 " + document.id)
	_game.drafts.mark_completed("level_001")


## 基准图标与主菜单实际比例作为视觉证据，避免仅重复生产缩放公式。
func _check_level_size(dimensions: Vector2i) -> void:
	var context := "%dx%d" % [dimensions.x, dimensions.y]
	_game.settings.set_ui_scale(100)
	_game._tutorials_expanded = false
	_game._players_expanded = false
	_game.settings.set_window_resolution(context)
	_game._show_main_page()
	await _settle(12)
	var menu_factor := _game._menu_card.get_global_transform().get_scale().x
	await _click(_game.find_child("StartGameButton", true, false) as Control)
	await _settle(12)
	if not _check(_game.page == GameShell.Page.LEVELS, "真实开始按钮进入选关页 " + context):
		return
	var icon := _level_icon("level_001")
	var header := _game._level_header
	if dimensions == Vector2i(1280, 800):
		_base_icon_bounds = icon.get_global_rect().size
		_base_header_height = header.get_global_rect().size.y
	_check(icon.get_global_rect().size.is_equal_approx(_base_icon_bounds * menu_factor), "选关图标按主菜单实际比例扩大 " + context)
	_check(absf(header.get_global_rect().size.y - _base_header_height * menu_factor) <= 1.0, "导航搜索和更多按钮随关卡图标同比例扩大 " + context)
	_check(icon.size.is_equal_approx(_base_icon_bounds) and icon.get_theme_constant("icon_max_width") == GameShell.LEVEL_THUMBNAIL_SIZE, "图标保持矢量逻辑尺寸，不更改地图缩略图数据 " + context)
	_check_svg_raster(menu_factor, context)
	if dimensions.x > 1280:
		_check(icon.get_global_rect().size.x > _last_icon_width + 10.0, "更高分辨率实际增大图标而非只增加卡片间距 " + context)
	_last_icon_width = icon.get_global_rect().size.x
	for percentage: int in [100, 110, 125]:
		_game.settings.set_ui_scale(percentage)
		await _settle(12)
		_check_visible_layout(menu_factor, percentage, context)
		if percentage > 100:
			await _check_header_and_menus(menu_factor, context + " " + str(percentage))
	for percentage: int in [150, 200]:
		_game.settings.set_ui_scale(percentage)
		await _settle(12)
		_check(_level_icon("level_001").get_global_rect().size.is_equal_approx(_base_icon_bounds * menu_factor), "高档文字百分比不重复扩大图标 " + context + " " + str(percentage))
		_check(_game._level_header._title.get_theme_font_size("font_size") == roundi(22 * percentage / 100.0), "UHD 高档文字比例应用真实字号 " + context + " " + str(percentage))
		for grid: GridContainer in _game._level_grids:
			_check(grid.columns == 7 and grid.get_global_rect().end.x <= root.get_visible_rect().end.x + 1.0, "UHD 高档文字仍保持七列横向边界 " + context + " " + str(percentage))
	_game.settings.set_ui_scale(125)
	await _settle(12)
	await _check_expansion(context)
	await _capture("windows_levels_" + context + "_125")
	await _click(_game._level_header._back_button)
	await _settle(12)
	_check(_game.page == GameShell.Page.MAIN and _game._page_layout.get_global_transform().get_scale().is_equal_approx(Vector2.ONE), "离开选关后通用页面布局恢复原比例 " + context)
	_check(is_instance_valid(_game._menu_card) and is_equal_approx(_game._menu_card.get_global_transform().get_scale().x, menu_factor), "返回主菜单不重复累计高分辨率比例 " + context)


## 校验可见七列、导入入口、真实字号和相邻名称，文字百分比不能放大图标。
func _check_visible_layout(factor: float, percentage: int, context: String) -> void:
	var suffix := context + " " + str(percentage)
	var viewport := root.get_visible_rect()
	var header := _game._level_header
	_check(header.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "选关页头实际变换继承视觉比例 " + suffix)
	_check(viewport.grow(1).encloses(header.get_global_rect()), "页头完整留在实际画幅内 " + suffix)
	_check(header._title.get_theme_font_size("font_size") == roundi(22 * percentage / 100.0), "页头文字使用真实字号百分比 " + suffix)
	_check(_game._tutorials_expanded == false and _game._players_expanded == false, "基准保持独立折叠状态 " + suffix)
	for identity: String in ["level_001", "scale_player_00"]:
		var card := _level_card(identity)
		var title := card.get_node("LevelCardTitle") as Label
		var caption := card.get_node("LevelCardCaption") as Label
		_check(title.get_theme_font_size("font_size") == roundi(14 * percentage / 100.0), "短关卡名称用真实字号放大 " + suffix + " " + identity)
		_check(caption.get_theme_font_size("font_size") == roundi(12 * percentage / 100.0), "完成与署名文字沿用全局字号 " + suffix + " " + identity)
		_check(title.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "关卡文字随图标一起呈现比例 " + suffix + " " + identity)
	var import_icon := _game.find_child("ImportLevelButton", true, false) as Button
	_check(import_icon.get_global_rect().size.is_equal_approx(_base_icon_bounds * factor), "导入入口与关卡缩略图同比例且不跟字号重复放大 " + suffix)
	_check(import_icon.get_theme_font_size("font_size") == roundi(44 * percentage / 100.0), "导入加号使用独立真实字号 " + suffix)
	for grid: GridContainer in _game._level_grids:
		_check(grid.columns == 7 and not (_game._body.find_child("LevelScroll", true, false) as ScrollContainer).get_h_scroll_bar().visible, "每组保持七列且没有横向滚动 " + suffix + " " + grid.name)
		var row: Array[Control] = []
		for child in grid.get_children():
			if child.visible:
				row.append(child)
		_check(row.size() == 7, "折叠首排恰好七项 " + suffix + " " + grid.name)
		var previous := Rect2()
		for column: Control in row:
			var bounds := column.get_global_rect()
			_check(viewport.grow(1).encloses(bounds), "七列卡片与文字完整位于画幅内 " + suffix + " " + grid.name)
			if previous.has_area():
				_check(bounds.position.x >= previous.end.x - 1.0 and absf(bounds.position.y - previous.position.y) <= 1.0, "同排卡片不互相挤压且保持水平对齐 " + suffix)
			previous = bounds


## 真正点击缩放后的搜索和更多入口，独立浮层的坐标不能沿用未缩放按钮位置。
func _check_header_and_menus(factor: float, context: String) -> void:
	var header := _game._level_header
	await _click(header._search_button)
	await create_timer(0.36).timeout
	_check(header._search_input.has_focus() and header._search_open, "缩放后真实点击搜索仍聚焦输入 " + context)
	var search_bounds := header._search_area.get_global_rect()
	var more_bounds := header._more_button.get_global_rect()
	_check(root.get_visible_rect().grow(1).encloses(search_bounds) and search_bounds.end.x < more_bounds.position.x, "搜索展开不溢出或盖住更多入口 " + context)
	await _key(root, KEY_ESCAPE)
	await create_timer(0.28).timeout
	_check(not header._search_open, "搜索 Esc 保留原生收起行为 " + context)
	await _click(header._more_button)
	await create_timer(0.2).timeout
	var actions := header._actions_menu
	if _check(actions.is_open(), "缩放后的更多命中区打开菜单 " + context):
		_check(actions._panel.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "独立更多菜单继承入口的完整比例 " + context)
		_check(actions._overlay.get_global_rect().is_equal_approx(root.get_visible_rect()), "放大更多菜单的遮挡层仍精确覆盖视口 " + context)
		_check(root.get_visible_rect().grow(1).encloses(actions._panel.get_global_rect()), "更多菜单完整留在真实画幅内 " + context)
		_check(absf(actions._panel.get_global_rect().end.x - more_bounds.end.x) <= 1.0 and actions._panel.get_global_rect().position.y >= more_bounds.end.y, "独立更多菜单仍贴入口右下角 " + context)
		await _key(root, KEY_DOWN)
		await _key(root, KEY_DOWN)
		await _key(root, KEY_RIGHT)
		_check(actions._sort_open and root.get_visible_rect().grow(1).encloses(actions._sort_panel.get_global_rect()), "排序子菜单键盘操作与边界正常 " + context)
		_check(actions._sort_panel.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "排序子菜单继承相同视觉比例 " + context)
		await _key(root, KEY_ESCAPE)
		await _key(root, KEY_ESCAPE)
	_check(not actions.is_open(), "更多菜单逐级 Esc 不穿透关卡 " + context)
	var player := _level_icon("scale_player_00")
	await _right_click(player)
	var menu := _game._player_level_context_menu
	_check(menu.is_open() and root.get_visible_rect().grow(1).encloses(menu._panel.get_global_rect()), "放大玩家图标可右键打开完整菜单 " + context)
	_check(menu._panel.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "独立玩家右键菜单随关卡同比例放大 " + context)
	_check(menu._overlay.get_global_rect().is_equal_approx(root.get_visible_rect()), "玩家右键遮挡层放大后仍完整覆盖视口 " + context)
	_check(menu._definition == _level_definition("scale_player_00"), "右键命中真实玩家关卡且未误选邻列 " + context)
	await _key(root, KEY_ESCAPE)
	_check(not menu.is_open() and _game.page == GameShell.Page.LEVELS, "右键取消不进入或删除背景关卡 " + context)


## 展开、滚轮及收起保留首排横向位置；纵向条不能重新挤压七列布局。
func _check_expansion(context: String) -> void:
	var before := _row_horizontal_bounds()
	var scroll := _game.find_child("LevelScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(_game._tutorial_toggle)
	await _settle(8)
	await _click(_game._tutorial_toggle)
	await _settle(12)
	_check(_game._tutorials_expanded and scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page, "全部教学展开产生真实纵向滚动范围 " + context)
	_check_row_unchanged(before, "教学展开 " + context)
	await _wheel_down(_level_icon("level_001"))
	_check(scroll.scroll_vertical > 0, "放大列表仍可用原生滚轮滚动 " + context)
	_check_row_unchanged(before, "滚轮滚动 " + context)
	scroll.scroll_vertical = 0
	await _settle(8)
	scroll.ensure_control_visible(_game._tutorial_toggle)
	await _settle(8)
	await _click(_game._tutorial_toggle)
	await _settle(8)
	scroll.ensure_control_visible(_game._player_toggle)
	await _settle(8)
	await _click(_game._player_toggle)
	await _settle(12)
	_check(_game._players_expanded, "玩家组独立展开 " + context)
	_check_row_unchanged(before, "玩家展开 " + context)
	scroll.scroll_vertical = 0
	await _settle(8)
	scroll.ensure_control_visible(_game._player_toggle)
	await _settle(8)
	await _click(_game._player_toggle)
	await _settle(8)
	scroll.scroll_vertical = 0
	await _settle(8)
	_check(not _game._tutorials_expanded and not _game._players_expanded, "两组收起恢复原首排 " + context)
	_check_row_unchanged(before, "最终收起 " + context)


## 小 SVG 必须按显示比例重新生成纹理，但不能放大逻辑命中区或污染共享资源。
func _check_svg_raster(factor: float, context: String) -> void:
	var header := _game._level_header
	var controls := [header._back_button, header._forward_button, header._search_button, header._search_close_button, header._more_button, header._search_icon]
	var sources := ["navigation_back", "navigation_forward", "search", "search_collapse", "more", "search"]
	for index in header._actions_menu._items.size():
		controls.append(header._actions_menu._items[index])
		sources.append(["refresh", "import_level", "sort"][index])
	controls.append(header._actions_menu._sort_chevron)
	sources.append("navigation_forward")
	for index in controls.size():
		var control: Control = controls[index]
		var texture: Texture2D = control.icon if control is Button else control.texture
		var original: Texture2D = _svg_sources[sources[index]]
		_check(texture.get_width() >= original.get_width() * ceili(factor), "小 SVG 纹理分辨率覆盖实际显示倍率 " + context + " " + str(control.name))
		_check(load("res://assets/ui/" + sources[index] + ".svg") == original and original.get_width() == 24, "共享 SVG 原件仍保留原纹理与 24 像素尺寸 " + context + " " + sources[index])
		if factor > 1.0:
			_check(texture != original, "高分辨率使用控件自己的 SVG 副本 " + context + " " + str(control.name))
	for control: Button in [header._back_button, header._forward_button, header._search_button, header._search_close_button, header._more_button]:
		_check(control.size.is_equal_approx(Vector2(44, 44)), "高分辨率 SVG 不撑大 44 像素逻辑命中区 " + context + " " + str(control.name))
	_check(header._search_icon.size.is_equal_approx(Vector2(24, 24)), "搜索图标保留 24 像素逻辑绘制矩形 " + context)


## 同一页面调整真实根窗口并切换平台，旧比例不能继续留在非 Windows 页面上。
func _check_platform_and_resize() -> void:
	_game.settings.set_ui_scale(125)
	_game.settings.set_window_resolution("1280x800")
	_game._show_level_page()
	await _settle(12)
	var header := _game._level_header
	root.size = Vector2i(1920, 1080)
	await _settle(12)
	_check(_game._level_header == header and _level_icon("level_001").get_global_rect().size.x > _base_icon_bounds.x * 1.25, "原地扩大窗口无需重建搜索页头也放大图标")
	root.size = Vector2i(1024, 640)
	await _settle(12)
	_check(_level_icon("level_001").get_global_rect().size.is_equal_approx(_base_icon_bounds), "恢复小窗口立刻取消高分辨率倍率")
	_check(root.get_visible_rect().grow(1).encloses(header.get_global_rect()), "小窗口页头不会被旧倍率裁切")
	_set_platform("macOS")
	await _settle(12)
	_check(_game._page_layout.get_global_transform().get_scale().is_equal_approx(Vector2.ONE), "macOS 选关沿用原逻辑布局")
	_check(_level_card("level_001").get_node("LevelCardTitle").get_theme_font_size("font_size") == 14, "macOS 禁用 Windows 百分比但保留保存偏好")
	_set_platform("Windows")
	_game.settings.set_window_resolution("1280x800")
	await _settle(12)
	await _click(_level_icon("level_001"))
	await _settle(12)
	_check(_game.page == GameShell.Page.ASSEMBLY and _game._page_layout.get_global_transform().get_scale().is_equal_approx(Vector2.ONE), "进入真实关卡组装后不遗留选关专用比例")
	_game._dialogue_dialog.hide()
	await _settle(4)
	await _click(_game._back_button)
	await _settle(12)
	_check(_game.page == GameShell.Page.LEVELS, "组装返回复用正常选关路由")


## 按目录身份取得卡片，测试不能依赖排序后的动态索引。
func _level_card(identity: String) -> Control:
	for entry in _game._level_entries:
		if entry.definition.id == identity:
			return entry.control
	return null


## 图标按钮与卡片名称分别测量，以便发现只缩放文字或只缩放留白的问题。
func _level_icon(identity: String) -> Button:
	return _level_card(identity).get_child(0) as Button


## 使用当前目录真实对象验证右键菜单目标而非只检查面板是否出现。
func _level_definition(identity: String) -> LevelDefinition:
	for entry in _game._level_entries:
		if entry.definition.id == identity:
			return entry.definition
	return null


## 存储首排横向像素矩形，纵向滚动允许改变 y 但不得改变每列 x 与宽度。
func _row_horizontal_bounds() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for grid: GridContainer in _game._level_grids:
		for index in 7:
			var bounds := (grid.get_child(index) as Control).get_global_rect()
			positions.append(Vector2(bounds.position.x, bounds.size.x))
	return positions


## 比较真实布局结果，避免把滚动条是否显示当作没有挤压的充分条件。
func _check_row_unchanged(before: Array[Vector2], context: String) -> void:
	var after := _row_horizontal_bounds()
	for index in before.size():
		_check(before[index].distance_to(after[index]) < 1.0, "滚动显隐不改变列位置与宽度 " + context + " " + str(index))


## 从实际控件中心提交右键按下和抬起，保持 Canvas 坐标与原生菜单输入一致。
func _right_click(control: Control) -> void:
	var point := root.get_final_transform() * (control.get_global_transform_with_canvas() * (control.size * 0.5))
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle(8)


## 用原生滚轮提交少量向下滚动，验证缩放后输入坐标仍落在真实滚动视口。
func _wheel_down(control: Control) -> void:
	var point := root.get_final_transform() * (control.get_global_transform_with_canvas() * (control.size * 0.5))
	for unused in 3:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		event.pressed = true
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		event = event.duplicate()
		event.pressed = false
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle(8)


## 超时按失败退出并清理独占目录，不能留下测试控制器改变后续运行。
func _timeout() -> void:
	if _finished:
		return
	_check(false, "高分辨率选关回归超过 90 秒")
	await _dispose_game()
	_finish()


## 独立标记供包装脚本检查，同时复用原验证器的全局状态恢复与安全清理。
func _finish() -> void:
	if not _finished:
		print("LEVEL_PAGE_SCALE_TESTS %d checks, %d failures" % [_checks, _failures])
	super._finish()
