extends "res://tests/windows_menu_card_runner.gd"
## Windows 编辑页回归使用真实窗口与输入；平台画像只替换能力查询，存储完全隔离。

var _base_cell_extent := 0.0


## 覆盖四档画幅、全部字号与浮层，随后验证绘图、历史及试玩返回没有缩放副作用。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/map_editor_scale_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(90).timeout.connect(_timeout)
	await _create_game()
	# 此回归核验游戏内后备窗口的几何；原生询问的回调另由 editor_native_exit_runner 覆盖。
	_game._editor_discard_dialog.use_native_dialog = false
	_set_platform("Windows")
	_game.settings.set_language("zh_CN")
	for dimensions: Vector2i in WINDOWS_SIZES:
		if _native_size_available(dimensions):
			await _check_editor_size(dimensions)
	await _check_initial_large_headings()
	await _check_resize_and_history()
	await _dispose_game()
	_finish()


## 从主菜单真实进入，比较菜单实际比例与编辑器的工具、属性、地图和真实字号。
func _check_editor_size(dimensions: Vector2i) -> void:
	var context := "%dx%d" % [dimensions.x, dimensions.y]
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution(context)
	_game._show_main_page()
	await _settle(12)
	var factor := _game._menu_card.get_global_transform().get_scale().x
	await _click(_game.find_child("MapEditorButton", true, false) as Control)
	await _settle(12)
	if not _check(_game.page == GameShell.Page.EDITOR, "真实主菜单进入编辑器 " + context):
		return
	var editor := _game._editor
	var snapshot := _signature(editor)
	for control: Control in [editor._header, editor._properties_card, editor._map_view, editor._canvas]:
		_check(control.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "编辑器各部分跟随主菜单实际比例 " + context + " " + str(control.name))
	_check(editor._header.back_button.get_global_rect().size.is_equal_approx(Vector2(44, 44) * factor), "导航实际命中区同比例扩大 " + context)
	_check(editor._header.back_button.icon.get_width() >= 24 * ceili(factor), "导航矢量纹理覆盖实际显示倍率 " + context)
	_check(root.get_visible_rect().grow(1).encloses(editor._properties_card.get_global_rect()), "属性卡片完整留在实际画幅内 " + context)
	var cell_extent := editor._canvas.cell_size * factor
	if dimensions == Vector2i(1280, 800):
		_base_cell_extent = cell_extent
	else:
		_check(cell_extent > _base_cell_extent * 1.2, "地图格子实际扩大，不只扩大窗口留白 " + context)
	for percentage: int in [100, 110, 125, 150, 200]:
		_game.settings.set_ui_scale(percentage)
		await _settle(8)
		_check(editor._header.title_label.get_theme_font_size("font_size") == roundi(22 * percentage / 100.0), "标题使用真实字号 " + context + " " + str(percentage))
		_check(editor._header.get_global_rect().grow(1).encloses(editor._header.subtitle_label.get_global_rect()), "大字号副标题不会挤出导航页头 " + context + " " + str(percentage))
		_check(editor._header.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "字号与几何倍率分别应用且不累计 " + context + " " + str(percentage))
		_check_heading_lines(editor._header, context + " " + str(percentage))
		_check(root.get_visible_rect().grow(1).encloses(editor._properties_card.get_global_rect()), "放大文字后的属性卡片仍在画幅内 " + context + " " + str(percentage))
		_check_enemy_combination(editor, context + " " + str(percentage), percentage)
		if percentage in [100, 150, 200]:
			await _check_guide_content(editor, context + " " + str(percentage), percentage)
		_check(_signature(editor) == snapshot and not editor.editor_document.can_undo(), "字体与布局不修改地图或历史 " + context)
		if percentage in [125, 200]:
			await _capture_enemy_combination(editor, "windows_enemy_combination_%s_%d" % [context, percentage])
	_game.settings.set_ui_scale(125)
	await _settle(12)
	await _check_popups(editor, factor, context)
	await _capture("windows_editor_" + context + "_125")
	await _click(editor._header.back_button)
	await _settle(8)
	_check(_game.page == GameShell.Page.MAIN and _game._page_layout.scale.is_equal_approx(Vector2.ONE), "离开编辑器恢复其他页面布局 " + context)


## 字体高度独立于标签缓存核验；大字号两行必须有清晰间距，按钮和正文仍不能相交。
func _check_heading_lines(header: MapEditorHeader, context: String) -> void:
	var title := header.title_label
	var subtitle := header.subtitle_label
	for label: Label in [title, subtitle]:
		var measured := label.get_theme_font("font").get_height(label.get_theme_font_size("font_size"))
		_check(label.size.y >= measured, "标签边界容纳当前字体完整行高 " + context + " " + str(label.name))
	var title_bounds := title.get_global_rect()
	var subtitle_bounds := subtitle.get_global_rect()
	_check(not title_bounds.intersects(subtitle_bounds) and subtitle_bounds.position.y >= title_bounds.end.y, "两行文字上下排列且不相交 " + context)
	if title.get_theme_font_size("font_size") >= 33:
		_check(subtitle_bounds.position.y - title_bounds.end.y >= 2 * header.get_global_transform().get_scale().y - 0.1, "150%及200%标题与副标题保留额外行间距 " + context)
	_check(header.get_global_rect().grow(1).encloses(title_bounds) and header.get_global_rect().grow(1).encloses(subtitle_bounds), "两行文字完整留在页头内 " + context)
	var card := _game._editor._properties_card.get_global_rect()
	_check(card.position.y >= header.get_global_rect().end.y, "页头增高后正文从两行文字下方开始 " + context)
	_check(is_equal_approx(header.back_button.get_global_rect().get_center().y, header.reload_button.get_global_rect().get_center().y), "增高页头中左右工具仍沿同一中线对齐 " + context)


## 实际矩形验证两排居中及完整宽度；高字号仍容纳药丸与箭头，不缩小点击区域。
func _check_enemy_combination(editor: MapEditor, context: String, percentage: int) -> void:
	var panel := editor._enemy_panel
	var slots := panel._slots.get_global_rect()
	var add := panel.place_button.get_global_rect()
	var remove := panel.remove_button.get_global_rect()
	var body := panel._settings_body.get_global_rect()
	_check(is_equal_approx(add.get_center().y, remove.get_center().y) and slots.position.y > maxf(add.end.y, remove.end.y), "添加删除同排，模块选配独立在下排 " + context)
	var center_offset := absf((add.position.x + remove.end.x) * 0.5 - slots.get_center().x)
	# 原生容器以整数逻辑像素居中，奇数可用宽度会保留半个逻辑像素的取整差。
	var center_tolerance := maxf(1.1, panel.get_global_transform().get_scale().x * 0.5 + 0.1)
	_check(center_offset <= center_tolerance, "添加删除按钮整体沿模块选配中线居中 " + context)
	_check(absf(slots.position.x - body.position.x) < 1.1 and absf(slots.end.x - body.end.x) < 1.1, "模块选配使用整排可用宽度 " + context)
	for choice: EnemyModuleChoice in panel._choices:
		var bounds := choice.get_global_rect()
		_check(bounds.position.x >= slots.position.x - 1 and bounds.end.x <= slots.end.x + 1 and choice.size.x >= choice.get_combined_minimum_size().x - 1 and choice.size.y >= choice.get_combined_minimum_size().y - 1, "药丸保留完整点击区域且不横向越界 " + context + " " + str(choice.name))
		_check(choice.get_theme_font_size("font_size") == roundi(12 * percentage / 100.0), "模块药丸随全局字号重新排版 " + context + " " + str(choice.name))


## GPU 截图滚到实际组合控件，不生成超出宿主显示器容量的模拟图片。
func _capture_enemy_combination(editor: MapEditor, filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(editor._enemy_panel._choices.back())
	await _settle(8)
	await _capture(filename)


## 覆盖先选择大字号再进入页面的路径，中英文及繁体的首次布局不能沿用默认字号行高。
func _check_initial_large_headings() -> void:
	for percentage: int in [150, 200]:
		_game.settings.set_ui_scale(percentage)
		for language: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(language)
			await _settle(8)
			await _click(_game.find_child("MapEditorButton", true, false) as Control)
			await _settle(12)
			if not _check(_game.page == GameShell.Page.EDITOR, "预设大字号后首次进入编辑器 " + language + " " + str(percentage)):
				return
			var header := _game._editor._header
			_check_heading_lines(header, "首次进入 " + language + " " + str(percentage))
			_check_enemy_combination(_game._editor, "首次进入 " + language + " " + str(percentage), percentage)
			await _check_guide_content(_game._editor, "首次进入 " + language + " " + str(percentage), percentage)
			await _capture("windows_editor_initial_%s_%d" % [language, percentage])
			await _click(header.back_button)
			await _settle(8)
	_game.settings.set_language("zh_CN")
	_game.settings.set_ui_scale(100)
	await _settle(8)


## Windows 各画幅与三语大字号核验内嵌指引正文、换行工具栏和分页命中区互不遮挡。
func _check_guide_content(editor: MapEditor, context: String, percentage: int) -> void:
	var snapshot := _signature(editor)
	var undo_count := editor.editor_document._undo_stack.size()
	await _click(editor._level_guide_button)
	await _settle(8)
	var guide := editor._level_guide_editor
	if not _check(guide.is_open(), "Windows 字号路径真实打开关卡引导 " + context):
		return
	var body := guide._text.get_global_rect()
	var title := guide._title.get_global_rect()
	var panel := guide.get_global_rect()
	var card := editor._properties_card.get_global_rect()
	_check(root.get_visible_rect().grow(1).encloses(card) and card.grow(1).encloses(panel) and panel.grow(1).encloses(body), "关卡指引正文内嵌属性卡片且留在实际视口内 " + context)
	_check(guide._text.get_theme_font_size("font_size") == roundi(16 * percentage / 100.0), "引导正文使用当前真实字号 " + context)
	_check(body.position.y >= guide._toolbar.get_global_rect().end.y and not body.intersects(guide._toolbar.get_global_rect()) and title.position.y >= body.end.y and not body.intersects(title), "工具栏按真实行高换行，正文与底部页码仍互不遮挡 " + context)
	_check(panel.grow(1).encloses(guide._preview_button.get_global_rect()) and not body.intersects(guide._preview_button.get_global_rect()), "预览模式按钮仍在卡片内且避开正文 " + context)
	for button: Button in [guide._previous, guide._next]:
		var bounds := button.get_global_rect()
		_check(guide._toolbar.get_global_rect().grow(1).encloses(bounds) and not body.intersects(bounds), "翻页按钮在顶部工具栏内且与正文完整分离 " + context + " " + str(button.name))
	_check(not guide._previous.get_global_rect().intersects(guide._next.get_global_rect()), "三语大字号上一页与下一页保持独立命中区 " + context)
	await _click(guide._preview_button)
	await _settle(8)
	_check(guide._preview.visible and not guide._text.visible and guide._preview.get_global_rect().is_equal_approx(body), "切到预览后正文仍使用同一内嵌矩形 " + context)
	await _click(editor.find_child("MapEditorEditTab", true, false) as Button)
	await _settle(8)
	_check(_signature(editor) == snapshot and editor.editor_document._undo_stack.size() == undo_count, "大字号引导浏览与预览不改变地图或历史 " + context)


## 独立 CanvasLayer 菜单与窗口必须跟随入口比例，同时保留真实的遮挡、锚点与点击。
func _check_popups(editor: MapEditor, factor: float, context: String) -> void:
	var model := editor.editor_document
	var snapshot := _signature(editor)
	await _click(editor._header.more_button)
	await create_timer(0.23).timeout
	_check_popup(editor._actions_menu, factor, context + " 更多")
	_check(absf(editor._actions_menu._panel.get_global_rect().end.x - editor._header.more_button.get_global_rect().end.x) < 1.1, "更多菜单右边缘贴合缩放后的入口 " + context)
	await _click(editor._actions_menu._items[3])
	await _settle(8)
	var metadata := editor._metadata_dialog
	_check(metadata.visible and is_equal_approx(metadata.content_scale_factor, factor), "真实更多项目打开同比例元数据窗口 " + context)
	_check(root.get_visible_rect().grow(1).encloses(Rect2(Vector2(metadata.position), Vector2(metadata.size))), "元数据窗口位于实际视口内 " + context)
	metadata.hide()
	await _settle(4)
	await _click(editor._header.guide_button)
	await create_timer(0.23).timeout
	_check_popup(editor._guide_menu, factor, context + " 指引")
	await _key(root, KEY_ESCAPE)
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	await _click(editor._level_guide_button)
	await _settle(8)
	var guide := editor._level_guide_editor
	_check(guide.is_open() and guide.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor) and editor._properties_card.get_global_rect().grow(1).encloses(guide.get_global_rect()), "关卡指引继承属性卡片几何缩放且不创建独立浮窗 " + context)
	await _click(editor.find_child("MapEditorEditTab", true, false) as Button)
	scroll.ensure_control_visible(editor._restriction_choice)
	await _settle(8)
	await _click(editor._restriction_choice)
	await _settle(8)
	_check_popup(editor._restriction_picker, factor, context + " 模块限制")
	_check(absf(editor._restriction_picker._panel.get_global_rect().size.x - editor._restriction_choice.get_global_rect().size.x) < 1.1, "模块选择与实际药丸等宽 " + context)
	await _key(root, KEY_ESCAPE)
	scroll.ensure_control_visible(editor._command_button)
	await _settle(8)
	await _click(editor._command_button)
	await create_timer(0.23).timeout
	var menu := editor._command_menu
	_check_popup(menu, factor, context + " 指令集")
	menu.select_section("movement")
	await _settle(8)
	var toggle: SettingsSwitch = menu._command_switches.move
	var enabled := toggle.button_pressed
	await _click(toggle)
	_check(toggle.button_pressed != enabled and model._undo_stack.size() == 1, "真实点击放大后的指令开关仅提交一个事务 " + context)
	model.undo()
	_check(toggle.button_pressed == enabled and _signature(editor) == snapshot, "撤销恢复指令开关和完整地图 " + context)
	await _capture("windows_commands_" + context)
	await _key(root, KEY_ESCAPE)
	_check(not menu.is_open() and _signature(editor) == snapshot, "关闭放大浮层不穿透修改地图 " + context)
	# 取消新建必须保留未保存事务，独立引擎窗口也要继承完整几何。
	model.redo()
	await _click(editor._header.new_button)
	await _settle(8)
	_check(editor._dirty_dialog.visible and is_equal_approx(editor._dirty_dialog.content_scale_factor, factor), "新建保护窗口同步编辑器比例 " + context)
	await _key(root, KEY_ESCAPE)
	await _settle(8)
	_check(not editor._dirty_dialog.visible, "原生 Esc 关闭新建保护窗口 " + context)
	model.undo()
	await _settle(8)
	_check(_signature(editor) == snapshot and not model.is_dirty(), "取消保护窗口保留地图及原保存点 " + context)


## 全局矩形同时验证视觉与输入遮挡，不能只检查节点的局部 scale 数值。
func _check_popup(menu: CanvasLayer, factor: float, context: String) -> void:
	_check(menu.is_open(), "真实入口打开浮层 " + context)
	_check(menu._panel.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "独立浮层继承完整显示比例 " + context)
	_check(menu._overlay.get_global_rect().is_equal_approx(root.get_visible_rect()), "浮层输入遮挡完整覆盖实际视口 " + context)
	_check(root.get_visible_rect().grow(1).encloses(menu._panel.get_global_rect()), "浮层完整位于画幅内 " + context)


## 原地变更画幅与平台后，在真实格子绘图、撤销，再往返正常试玩并保留文档及观察状态。
func _check_resize_and_history() -> void:
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution("1280x800")
	_game._open_editor(MapEditor.DEFAULT_MAP_PATH)
	await _settle(12)
	var editor := _game._editor
	var model := editor.editor_document
	var snapshot := _signature(editor)
	root.size = Vector2i(2560, 1440) if DisplayServer.get_name() == "headless" else Vector2i(1280, 800)
	await _settle(12)
	var factor := editor._header.get_global_transform().get_scale().x
	_check(_game._editor == editor and _signature(editor) == snapshot and not model.can_undo(), "原地放大保留同一编辑器和干净历史")
	var property_scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	var enemies := editor._enemy_panel
	property_scroll.ensure_control_visible(enemies.enable_switch)
	await _settle(8)
	await _click(enemies.enable_switch)
	await _settle(8)
	var choice: EnemyModuleChoice = enemies._choices[0]
	property_scroll.ensure_control_visible(choice)
	await _settle(8)
	await _click(choice)
	await _settle(8)
	_check_popup(enemies._picker, factor, "敌人模块")
	await _key(root, KEY_ESCAPE)
	model.undo()
	await _settle(8)
	_check(_signature(editor) == snapshot, "浏览放大的敌人模块菜单后可撤销唯一启用事务")
	var cell := Vector2i(5, 5)
	_check(model.document.get_tile_id(cell).is_empty(), "绘图夹具原先为空格，点击应产生真实修改")
	var local_point := (Vector2(cell) + Vector2.ONE * 0.5) * editor._canvas.cell_size
	var point := editor._canvas.get_global_transform_with_canvas() * local_point
	_check(editor._map_view.get_global_rect().has_point(point), "绘图测试点位于真实地图视口")
	await _click_point(point)
	_check(model.document.get_tile_id(cell) == "floor" and model._undo_stack.size() == 1, "真实点击放大的地图仍修改正确格子且只有一个笔画")
	await _click(editor._header.undo_button)
	_check(_signature(editor) == snapshot and model.can_redo(), "放大后的撤销入口恢复原地图")
	await _click(editor._header.redo_button)
	await _click(editor._header.zoom_in_button)
	var zoom := editor._map_view.zoom
	var center := editor._map_view.view_center
	var before_test := _signature(editor)
	var undo_count := model._undo_stack.size()
	await _click(editor._header.back_button)
	await _settle(8)
	var exit := _game._editor_discard_dialog
	_check(exit.visible and exit._panel.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor * MapExitDialog.DISPLAY_SCALE), "未保存提醒跟随编辑页且保留原相对大小")
	_check(exit._panel.get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) < 1.5, "未保存提醒在放大的真实画幅内居中")
	await _click(exit.get_cancel_button())
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	# 底部操作固定在卡片边缘，无需随正文滚动定位。
	await _settle(8)
	await _click(editor._play_button)
	await _settle(12)
	print("试玩缩放诊断：page=%s scale=%s status=%s" % [_game.page, _game._page_layout.scale, editor._status.text])
	_check(_game.page == GameShell.Page.ASSEMBLY and _game._page_layout.scale.is_equal_approx(Vector2.ONE), "正常试玩不遗留编辑器显示倍率")
	_game._dialogue_dialog.hide()
	await _click(_game._back_button)
	await _settle(12)
	_check(_game.page == GameShell.Page.EDITOR and _game._editor == editor and editor._header.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "试玩返回恢复同一编辑器及其显示倍率")
	_check(_signature(editor) == before_test and model._undo_stack.size() == undo_count and is_equal_approx(editor._map_view.zoom, zoom) and editor._map_view.view_center.is_equal_approx(center), "试玩保留地图、历史、缩放和观察中心")
	_set_platform("macOS")
	await _settle(12)
	_check(editor._header.get_global_transform().get_scale().is_equal_approx(Vector2.ONE), "macOS 保持既有编辑器逻辑布局")
	_set_platform("Windows")
	_game.settings.set_window_resolution("1024x640")
	await _settle(12)
	_check(editor._header.get_global_transform().get_scale().is_equal_approx(Vector2.ONE), "小窗口不遗留高分辨率倍率")
	_check(_signature(editor) == before_test and model._undo_stack.size() == undo_count, "切换平台及小窗口不改写编辑内容")


## 从实际屏幕坐标提交配对鼠标事件，验证缩放后的画布坐标反变换。
func _click_point(point: Vector2) -> void:
	var window_point := root.get_final_transform() * point
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = window_point
		event.global_position = window_point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle(8)


## 快照比较包含未知扩展字段，显示变化不能造成隐式保存或截断。
func _signature(editor: MapEditor) -> String:
	return JSON.stringify(editor.editor_document.document.to_dict(), "", true)


## 专用完成标记供完整测试脚本和导出 PCK 检查，最后恢复语言音量并清理隔离存储。
func _finish() -> void:
	if not _finished:
		print("MAP_EDITOR_SCALE_TESTS %d checks, %d failures" % [_checks, _failures])
	super._finish()
