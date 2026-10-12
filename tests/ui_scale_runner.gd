extends "res://tests/window_resolution_ui_runner.gd"
## Windows 缩放策略与真实控件回归：在当前引擎注入平台和物理屏幕画像，不冒充真实 Windows 系统。

var _profile_size := Vector2i(1920, 1080)


## 平台权限、保存恢复、实际字号缩放与小窗口可达性均在隔离存档中检查。
func _run() -> void:
	_temporary = "user://tests/ui_scale_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	create_timer(90.0).timeout.connect(_timeout)
	root.gui_embed_subwindows = true
	_check_scale_policy()
	await _create_game()
	await _open_settings()
	_set_profile("macOS", Vector2i(3840, 2160))
	await _settle(8)
	var option := _scale_option()
	var toggle_size := _game.settings_panel._tab_completion_toggle.custom_minimum_size
	_check(option != null and option.disabled and option.item_count == 1 and option.get_item_text(0) == "100%", "macOS 缩放显示 100% 且不可点击")
	var label := _game.settings_panel.find_child("UiScaleLabel", true, false) as Label
	_check(label.get_theme_color("font_color") == GameTheme.MUTED, "macOS 缩放标签显示灰色")
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and root.content_scale_factor == 1.0, "macOS 保持原有画幅策略")
	var resolution_row := _game.settings_panel.find_child("WindowResolutionRow", true, false) as Control
	var scale_row := _game.settings_panel.find_child("UiScaleRow", true, false) as Control
	var tab_row := _game.settings_panel.find_child("TabCompletionRow", true, false) as Control
	_check(resolution_row.get_index() < scale_row.get_index() and scale_row.get_index() < tab_row.get_index(), "缩放与布局紧接分辨率、位于 Tab 补全之前")
	await _capture("scale_disabled_macos")
	_set_profile("Windows", Vector2i(1920, 1080))
	await _settle(8)
	await _choose_resolution("1280x720", true)
	_check(not _scale_option().disabled and _scale_option().item_count == 3 and _game.settings.ui_scale == 100, "Windows 普通显示器默认 100% 并开放三档")
	for value in [110, 125, 100]:
		await _choose_scale(value)
		_check_scale_geometry(value)
		_check(root.size == Vector2i(1280, 720), "1080p 档位无需改变有效窗口尺寸 " + str(value))
		await _capture("windows_scale_%d" % value)
	await _choose_scale(125)
	await _check_scaled_tutorial("1080p_125")
	await _open_settings()
	_set_profile("Windows", Vector2i(3840, 2160))
	await _settle(8)
	_check(_scale_option().item_count == 5, "4K 显示器额外开放 150% 与 200%")
	for value in [150, 200]:
		await _choose_scale(value)
		_check_scale_geometry(value)
		_check(root.size == Vector2i(1280, 720), "字号增大仍能放入现有设置行时保持窗口原尺寸 " + str(value))
		_check(_game.settings_panel._tab_completion_toggle.custom_minimum_size == toggle_size, "缩放不放大开关图标或命中区 " + str(value))
		await _capture("windows_4k_profile_scale_%d" % value)
	if not _option().is_item_disabled(GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find("3840x2160")):
		await _choose_resolution("3840x2160", true)
		_check_scale_geometry(200)
		_check(root.size == Vector2i(3840, 2160) and root.get_visible_rect().size.is_equal_approx(Vector2(3840, 2160)), "4K 200% 保留完整物理画幅，仅字号变为两倍")
	await _check_text_layout_growth()
	await _check_scaled_tutorial("4k_200")
	await _check_code_font_state()
	await _open_settings()
	var stored := GameSettings.new(_game.settings_path)
	_check(stored.load_settings().is_ok() and stored.ui_scale == 200, "真实缩放菜单保存到隔离配置")
	_set_profile("Windows", Vector2i(1920, 1080))
	await _settle(8)
	_check(_game.window_controller.effective_ui_scale == 100 and _game.settings.ui_scale == 200 and _scale_option().item_count == 3 and _scale_option().get_item_id(_scale_option().selected) == 100, "4K 高档偏好在普通屏幕临时回退 100%，不删除保存值")
	_set_profile("Windows", Vector2i(3840, 2160))
	await _settle(8)
	_check_scale_geometry(200)
	_check(_scale_option().get_item_id(_scale_option().selected) == 200, "回到 4K 恢复高档偏好")
	_set_profile("macOS", Vector2i(3840, 2160))
	await _settle(8)
	_check(_scale_option().disabled and root.content_scale_factor == 1.0 and _game.settings.ui_scale == 200, "Windows 配置在 macOS 不应用缩放且保留原偏好")
	await _dispose_game()
	await _create_game()
	_set_profile("Windows", Vector2i(3840, 2160))
	await _settle(8)
	_check(_game.settings.ui_scale == 200, "重建游戏恢复保存的缩放设置")
	_check_scale_geometry(200)
	await _open_settings()
	await _choose_scale(100)
	await _choose_resolution("1280x800", true)
	await _dispose_game()
	_finish()


## 4K 要同时满足长边和短边，超宽但非 UHD 的屏幕不能误开放高档位。
func _check_scale_policy() -> void:
	for platform in ["macOS", "Linux", "Android"]:
		_check(GameWindowController.ui_scales_for_screen(platform, Vector2i(7680, 4320)).is_empty(), "非 Windows 平台禁用手动缩放 " + platform)
	for dimensions in [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3440, 1440), Vector2i(3840, 1600)]:
		_check(GameWindowController.ui_scales_for_screen("Windows", dimensions) == PackedInt32Array([100, 110, 125]), "普通 Windows 屏幕开放三档 " + str(dimensions))
	for dimensions in [Vector2i(3840, 2160), Vector2i(2160, 3840), Vector2i(4096, 2160), Vector2i(7680, 4320)]:
		_check(GameWindowController.ui_scales_for_screen("Windows", dimensions) == PackedInt32Array([100, 110, 125, 150, 200]), "UHD、竖屏及更高分辨率开放五档 " + str(dimensions))
	var available := GameWindowController.resolutions_for_area(Vector2i(3840, 2160), Vector2i(1000, 560))
	_check(available.has("1280x720") and available.has("3840x2160") and available.has("maximized"), "字号缩放不提前禁用仍能容纳的窗口尺寸")


## 只替换控制器的系统查询依赖，仍由同一生产路径刷新权限与实际窗口。
func _set_profile(platform: String, dimensions: Vector2i) -> void:
	_profile_size = dimensions
	_game.window_controller.platform_name = platform
	_game.window_controller.screen_size_provider = _profile_screen_size
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()


## 屏幕画像保持纯只读值，不更改宿主操作系统或玩家的系统设置。
func _profile_screen_size() -> Vector2i:
	return _profile_size


## 每次获取当前设置页的原生百分比控件，页面重建后不保留旧引用。
func _scale_option() -> OptionButton:
	return _game.settings_panel.find_child("UiScaleOption", true, false) as OptionButton


## 真实鼠标打开下拉，再由原生键盘路由选择，不直接发射 item_selected。
func _choose_scale(value: int) -> void:
	var option := _scale_option()
	if not _check(not option.disabled, "Windows 缩放选择器可点击"):
		return
	_game.settings_panel._scroll.ensure_control_visible(option)
	await _settle(8)
	await _click(option)
	var popup := option.get_popup()
	await _settle(8)
	if not _check(popup.visible, "真实输入打开缩放菜单"):
		return
	var index := -1
	for item in option.item_count:
		if option.get_item_id(item) == value:
			index = item
	if not _check(index >= 0, "目标百分比存在 " + str(value)):
		popup.hide()
		return
	var deadline := Time.get_ticks_msec() + 3000
	while popup.get_focused_item() != index and Time.get_ticks_msec() < deadline:
		await _key(root, KEY_UP if popup.get_focused_item() > index else KEY_DOWN)
	if not _check(popup.get_focused_item() == index, "原生菜单聚焦目标百分比 " + str(value)):
		popup.hide()
		return
	await _key(root, KEY_ENTER)
	await _settle(12)
	_check(_game.settings.ui_scale == value and not popup.visible, "缩放选择即时保存并关闭菜单 " + str(value))
	_check(_scale_option().get_item_id(_scale_option().selected) == value, "菜单显示实际应用百分比 " + str(value))


## 只增大字号，视口、开关、卡片和图标维持原尺度，不能整体拉伸游戏画面。
func _check_scale_geometry(value: int) -> void:
	var factor := value / 100.0
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED and is_equal_approx(root.content_scale_factor, 1.0), "Windows 不整体放大画布 " + str(value))
	_check(root.get_visible_rect().size.is_equal_approx(Vector2(root.size)), "逻辑视口保持原画幅 " + str(value))
	if is_instance_valid(_game.settings_panel):
		_check(_scale_option().get_theme_font_size("font_size") == roundi(16 * factor), "原 16 号设置字体按百分比增大 " + str(value))
	_check_fill_geometry("Windows scale " + str(value))
	_check(_game.window_controller.effective_ui_scale == value, "窗口控制器记录实际应用值 " + str(value))


## 正常文字先保留窗口；真实容器最小宽度超过窗口时才增大边界，不凭档位提前放大。
func _check_text_layout_growth() -> void:
	await _choose_scale(100)
	await _choose_resolution("1280x720", true)
	var fixture := HBoxContainer.new()
	fixture.name = "FontLayoutGrowthFixture"
	fixture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game.add_child(fixture)
	fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var label := GameTheme.label(fixture, "宽".repeat(45), 16)
	await _settle(12)
	_check(root.size == Vector2i(1280, 720) and label.get_theme_font_size("font_size") == 16, "原字号能放下时不扩大窗口")
	await _choose_scale(200)
	await _settle(16)
	_check(label.get_theme_font_size("font_size") == 32, "字体缩放同时应用到新加入页面的文字")
	_check(root.size.x >= ceili(fixture.get_combined_minimum_size().x) and root.size.x > 1280, "文字容器确实放不下后才扩大窗口 window=%s minimum=%s mode=%s" % [root.size, fixture.get_combined_minimum_size(), root.mode])
	fixture.queue_free()
	await _settle(8)


## 使用正式第一关的装配及教程页面，验证用户截图中的弹窗与图纸在缩放后完整可见。
func _check_scaled_tutorial(context: String) -> void:
	_game._enter_level(_game.catalog.levels[0])
	await _settle(12)
	_check(_game._dialogue_dialog.visible and root.get_visible_rect().grow(1).encloses(Rect2(_game._dialogue_dialog.position, _game._dialogue_dialog.size)), "缩放后教程弹窗完整可见 " + context)
	var canvas := _game.assembly_panel.canvas
	_check(Rect2(Vector2.ZERO, canvas.size).grow(1).encloses(canvas._paper_rect()), "缩放后装配图纸不裁切 " + context)
	for spin: SpinBox in _game.assembly_panel.find_children("*", "SpinBox", true, false):
		var edit := spin.get_line_edit()
		var text_width := edit.get_theme_font("font").get_string_size(edit.text, HORIZONTAL_ALIGNMENT_LEFT, -1, edit.get_theme_font_size("font_size")).x
		_check(edit.size.x - edit.get_theme_stylebox("normal").get_minimum_size().x >= text_width, "数值输入框确实放不下时增加边界，完整显示小数 " + context)
		for value in [-AssemblyModel.MAX_OFFSET, 9.5, 0.0]:
			spin.value = value
			await _settle(8)
			text_width = edit.get_theme_font("font").get_string_size(edit.text, HORIZONTAL_ALIGNMENT_LEFT, -1, edit.get_theme_font_size("font_size")).x
			_check(edit.size.x - edit.get_theme_stylebox("normal").get_minimum_size().x >= text_width, "程序更新数值后负数和多位数仍完整可见 " + context + " " + edit.text)
	await _capture("windows_tutorial_" + context)
	_game._show_main_page()
	await _settle(8)


## 编程区新建后沿用当前字号，改色和反复缩放保留代码、光标、选区，不能累计放大。
func _check_code_font_state() -> void:
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	_game.session.assembly.add_module("movement", Vector2.ZERO)
	_game._confirm_assembly()
	await _settle(16)
	var code := _game.workbench._code
	code.text = "main() {\n    move(0, 1)\n}"
	code.set_caret_line(1)
	code.set_caret_column(8)
	code.select(1, 4, 1, 8)
	var source := code.text
	for value in [200, 100, 200, 125, 200]:
		_game.settings.set_ui_scale(value)
		_game.settings.set_code_color_mode("dark" if value == 200 else "light")
		await _settle(16)
		_check(code.get_theme_font_size("font_size") == roundi(17 * value / 100.0), "编程字号保持基准 17 的真实百分比且不累积 " + str(value))
		_check(code.text == source and code.get_caret_line() == 1 and code.get_caret_column() == 8 and code.has_selection() and code.get_selection_from_column() == 4 and code.get_selection_to_column() == 8, "缩放与改色不修改程序、光标和选区")
	var markdown := RichTextLabel.new()
	markdown.custom_minimum_size = Vector2(600, 160)
	GuideMarkdown.render(markdown, "# 测试标题\n正文文字")
	_game.add_child(markdown)
	await _settle(16)
	_check(markdown.get_theme_font_size("normal_font_size") == 32 and markdown.get_meta("ui_scaled_markdown_factor") == 2.0, "先排版后加入游戏的 Markdown 正文和标题补用当前百分比")
	_game.settings.set_ui_scale(100)
	await _settle(16)
	_check(markdown.get_theme_font_size("normal_font_size") == 16 and markdown.get_meta("ui_scaled_markdown_factor") == 1.0 and markdown.get_parsed_text() == "测试标题\n正文文字", "Markdown 返回 100% 恢复原字号且保留原文")
	_game.settings.set_ui_scale(200)
	markdown.queue_free()
	await _settle(8)
	await _check_tooltip_font()
	await _capture("windows_code_font_200")
	_game._show_main_page()
	await _settle(8)


## 真实悬停的原生提示按大字号排版，玻璃层文字和原生矩形一致且不夺走代码焦点。
func _check_tooltip_font() -> void:
	var control := _game.workbench._guide_button
	var position := control.get_global_transform_with_canvas() * (control.size * 0.5)
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(position)
	var motion := InputEventMouseMotion.new()
	motion.position = root.get_final_transform() * position
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	await create_timer(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) + 0.2).timeout
	await _settle(8)
	var glass := _game.get_node("GlassTooltips") as GlassTooltipLayer
	if _check(glass.visible and is_instance_valid(glass._source_label), "200% 下真实悬停显示玻璃提示"):
		_check(glass._label.get_theme_font_size("font_size") == glass._source_label.get_theme_font_size("font_size") and GameTheme.font_scale(glass._source_label) == 2.0, "原生提示和玻璃文字使用相同的大字号")
		_check(glass._label.size.y + 1 >= glass._label.get_minimum_size().y and glass._label.size.x + 1 >= glass._label.get_minimum_size().x, "提示矩形能容纳放大后的文字")
	motion.position = Vector2(1, 1)
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	await _settle(8)


## 缩放回归单独输出完成标记，再复用基础回归的全局状态恢复与测试目录清理。
func _finish() -> void:
	if not _finished:
		print("界面缩放回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	super._finish()
