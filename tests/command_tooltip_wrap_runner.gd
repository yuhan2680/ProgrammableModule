extends "res://tests/windows_menu_card_runner.gd"
## 用真实悬停生成提示，覆盖 Windows 高分辨率指令说明与窄视口的再次换行。

var _glass: GlassTooltipLayer


## 平台画像仅替换窗口能力查询，游戏设置、指令目录与鼠标事件走生产路径。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/command_tooltip_wrap_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(100).timeout.connect(_timeout)
	await _create_game()
	_set_platform("Windows")
	_glass = _game.get_node("GlassTooltips") as GlassTooltipLayer
	for dimensions: Vector2i in WINDOWS_SIZES:
		if _native_size_available(dimensions):
			await _check_command_description(dimensions)
	await _dispose_game()
	await _check_narrow_viewport()
	_finish()


## 实际打开指令管理并悬停自定义函数，必须保留完整中英文说明及原编辑状态。
func _check_command_description(dimensions: Vector2i) -> void:
	var context := "%dx%d" % [dimensions.x, dimensions.y]
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution(context)
	_game._show_main_page()
	await _settle(12)
	await _click(_game.find_child("MapEditorButton", true, false) as Control)
	await _settle(12)
	var editor := _game._editor
	var snapshot := JSON.stringify(editor.editor_document.document.to_dict())
	var menu := editor._command_menu
	(editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer).ensure_control_visible(editor._command_button)
	await _settle(8)
	await _click(editor._command_button)
	await _settle(12)
	var percentages := [100, 125, 150, 200] if dimensions.x >= 2560 else [100, 125]
	for percentage: int in percentages:
		_game.settings.set_ui_scale(percentage)
		for language: String in ["zh_CN", "en"]:
			_game.settings.set_language(language)
			menu.select_section("general", "general")
			await _settle(12)
			var card := menu.find_child("CommandRestrictionItem_functions", true, false) as Control
			if not _check(card != null, "真实配置生成自定义函数卡片 " + context):
				return
			menu._scroll.ensure_control_visible(card)
			await _settle(8)
			await _hover_tooltip(card.get_global_rect().get_center(), root)
			_check_wrapped_tooltip(card.get_tooltip(), root.get_visible_rect(), context + " " + language + " " + str(percentage))
			_check(_glass._label.get_theme_font_size("font_size") == roundi(15 * percentage / 100.0), "自动换行不缩小真实字号 " + context + " " + str(percentage))
			_check(JSON.stringify(editor.editor_document.document.to_dict()) == snapshot and not editor.editor_document.can_undo(), "说明预览不修改地图或历史 " + context)
			if percentage == 125:
				await _capture("command_tooltip_%s_%s_%d" % [context, language, percentage])
			await _hover_tooltip(Vector2.ONE, root, false)
	menu.close_menu()
	await _settle(8)
	await _click(editor._header.back_button)
	await _settle(8)


## 正常行宽提示已经换行；完整文字、阴影和可见卡片均必须位于实际窗口内。
func _check_wrapped_tooltip(expected: String, bounds: Rect2, context: String) -> void:
	if not _check(_glass.visible and is_instance_valid(_glass._source_label), "真实延时悬停出现玻璃说明 " + context):
		return
	var label := _glass._label
	_check(label.text == expected and not label.text.ends_with("…"), "长说明逐字保留且没有省略 " + context)
	_check(label.get_line_count() > expected.count("\n") + 1, "长描述新增自动换行 " + context)
	_check(label.size.y >= label.get_minimum_size().y, "提示完整容纳全部行 " + context)
	_check(bounds.grow(1).encloses(_glass._glass.get_global_rect()), "玻璃卡片和阴影完整位于窗口内 " + context)
	_check(_glass._source_label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "原生隐藏窗口与玻璃使用同一换行结果 " + context)
	_check(label.mouse_filter == Control.MOUSE_FILTER_IGNORE and label.focus_mode == Control.FOCUS_NONE, "预览不夺取输入或焦点 " + context)


## 缩窄真实窗口后相同说明必须再次增加行数，靠近边缘也不能超出其范围。
func _check_narrow_viewport() -> void:
	var viewport := root
	viewport.min_size = Vector2i.ONE
	viewport.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	viewport.size = Vector2i(900, 720)
	var scope := Control.new()
	scope.theme = GameTheme.create_theme()
	viewport.add_child(scope)
	scope.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_glass = GlassTooltipLayer.new()
	scope.add_child(_glass)
	var fixture := Button.new()
	fixture.size = Vector2(32, 32)
	fixture.tooltip_text = "Custom Functions\n\n" + str(JSON.parse_string(FileAccess.get_file_as_string("res://data/commands/120_functions.json")).description.en)
	scope.add_child(fixture)
	fixture.position = Vector2(434, 344)
	await _settle(8)
	await _hover_tooltip(fixture.get_rect().get_center(), viewport)
	_check_wrapped_tooltip(fixture.tooltip_text, viewport.get_visible_rect(), "宽视口")
	var wide_lines := _glass._label.get_line_count()
	var wide_width := _glass._label.size.x
	viewport.size = Vector2i(340, 720)
	fixture.position = Vector2(154, 344)
	await _hover_tooltip(Vector2.ONE, viewport, false)
	await _hover_tooltip(fixture.get_rect().get_center(), viewport)
	_check_wrapped_tooltip(fixture.tooltip_text, viewport.get_visible_rect(), "窄视口")
	_check(_glass._label.get_line_count() > wide_lines and _glass._label.size.x < wide_width, "相同文字在窄边界内进一步换行")
	for point: Vector2 in [Vector2(18, 18), Vector2(322, 702)]:
		fixture.position = point - fixture.size * 0.5
		await _hover_tooltip(Vector2(1, 360), viewport, false)
		await _hover_tooltip(point, viewport)
		_check_wrapped_tooltip(fixture.tooltip_text, viewport.get_visible_rect(), "窗口角落 " + str(point))
	await _hover_tooltip(Vector2(1, 360), viewport, false)
	_check(not _glass.visible, "移出悬停后完整清除玻璃提示")
	scope.queue_free()
	await _settle(8)


## 通过原生 GUI 延迟创建窗口，不直接调用提示层的排版或定位函数。
func _hover_tooltip(point: Vector2, viewport: Viewport, waiting: bool = true) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	viewport.push_input(motion, true)
	if waiting:
		await create_timer(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) + 0.15).timeout
	await _settle(8)


## 独立完成标记接入常规检查，并沿用基础测试的存储和全局状态清理。
func _finish() -> void:
	if not _finished:
		print("COMMAND_TOOLTIP_WRAP_TESTS %d checks, %d failures" % [_checks, _failures])
	super._finish()
