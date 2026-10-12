extends "res://tests/window_resolution_ui_runner.gd"
## 验证 Windows 高分辨率白卡的实际占屏比例；平台画像只替换能力查询，不冒充真实 Windows 桌面。

const BASE_CARD_SIZE := Vector2(1120, 640)
const WINDOWS_SIZES := [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]

var _screen_profile := Vector2i(3840, 2160)
var _original_transparent := false
var _previous_large_card := Vector2.ZERO
var _wide_occupancy := -1.0
var _base_message_extent := Vector2.ZERO


## 独占存档覆盖基准、高分辨率、字号和两级设置；GPU 只创建真实显示器能容纳的原生窗口。
func _run() -> void:
	_temporary = "user://tests/windows_menu_card_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_set_platform("Windows")
	await _settle(12)
	for dimensions: Vector2i in WINDOWS_SIZES:
		if not _native_size_available(dimensions):
			continue
		await _check_windows_size(dimensions)
	await _check_small_windows()
	await _check_macos()
	await _dispose_game()
	_check(root.transparent_bg == _original_transparent, "销毁页面后恢复视口透明状态")
	_finish()


## 只注入控制器公开的平台与只读屏幕查询；画布模式、字体和白卡均由生产路径更新。
func _set_platform(platform: String) -> void:
	_game.window_controller.platform_name = platform
	_game.window_controller.screen_size_provider = _profile_screen_size
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()


## UHD 画像用于开放全部手动字号，实际原生窗口容量仍由宿主显示器决定。
func _profile_screen_size() -> Vector2i:
	return _screen_profile


## 无显示驱动可覆盖真实 4K 逻辑画幅；GPU 超过宿主可用客户区时明确跳过，不生成虚构截图。
func _native_size_available(dimensions: Vector2i) -> bool:
	var value := "%dx%d" % [dimensions.x, dimensions.y]
	if DisplayServer.get_name() == "headless" or _game.window_controller.available_resolutions.has(value):
		return true
	print("SKIP Windows 白卡原生 GPU 尺寸 %s：宿主可用区域 %s，不能容纳此客户区。" % [value, DisplayServer.screen_get_usable_rect(root.current_screen).size])
	return false


## 检查实际窗口占用、等比增长和居中，并通过真实控件切换字号与共享设置页面。
func _check_windows_size(dimensions: Vector2i) -> void:
	var context := "%dx%d" % [dimensions.x, dimensions.y]
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution(context)
	await _settle(12)
	_check(root.size == dimensions and root.get_visible_rect().size.is_equal_approx(Vector2(dimensions)), "Windows 实际画幅等于客户区 " + context)
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED and is_equal_approx(root.content_scale_factor, 1.0), "Windows 高分辨率没有整体拉伸画布 " + context)
	await _check_startup_card(context)
	var card := _game._menu_card
	var card_bounds := card.get_global_rect()
	_check_card_geometry(context, true)
	if dimensions == Vector2i(1280, 800):
		_check(card_bounds.size.is_equal_approx(BASE_CARD_SIZE), "1280×800 保留 1120×640 基准白卡")
	else:
		_check(card_bounds.size.x > BASE_CARD_SIZE.x * 1.25 and card_bounds.size.y > BASE_CARD_SIZE.y * 1.25, "高分辨率白卡实际扩大，不停留在基准小卡 " + context)
		if _previous_large_card != Vector2.ZERO:
			_check(card_bounds.size.x > _previous_large_card.x and card_bounds.size.y > _previous_large_card.y, "更大画幅同时扩大白卡宽高 " + context)
		_previous_large_card = card_bounds.size
		var occupancy := card_bounds.get_area() / (dimensions.x * dimensions.y)
		if _wide_occupancy < 0:
			_wide_occupancy = occupancy
		else:
			_check(absf(occupancy - _wide_occupancy) < 0.005, "相同宽高比下高分辨率白卡保持相同占屏比例 " + context)
	var title := _game.find_child("MainMenuTitle", true, false) as Label
	var icon := _game.find_child("MainMenuIcon", true, false) as Control
	var factor := _card_factor()
	_check(card.size.is_equal_approx(BASE_CARD_SIZE) and title.get_theme_font_size("font_size") == 36, "卡片与字体保留稳定逻辑基准，高分辨率由父卡片统一放大 " + context)
	_check(icon.get_global_rect().size.is_equal_approx(Vector2(104, 104) * factor), "图标与白卡同比例扩大 " + context)
	var action := _game.find_child("StartGameButton", true, false) as Control
	_check(action.get_global_rect().size.is_equal_approx(action.size * factor) and action.get_global_rect().size.y >= 64.0 * factor, "菜单按钮与命中区随白卡同比例扩大 " + context)
	await _capture("windows_main_card_" + context)
	await _check_shared_pages(context)
	_check(_game.page == GameShell.Page.MAIN, "两级设置返回主菜单 " + context)
	_check_card_geometry(context + " 返回", true)
	await _check_footer_fonts(context)


## 使用生产启动弹出流程，确认动画完成后保留高分辨率比例并恢复按钮输入。
func _check_startup_card(context: String) -> void:
	_game._startup_menu_pending = true
	_game._show_main_page()
	await _settle(4)
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	_check(not card.visible and not _game._startup_menu_buttons.is_empty(), "启动弹出前隐藏白卡并锁住按钮 " + context)
	await _game.reveal_startup_menu()
	_check(card.visible and card.get_global_rect().is_equal_approx(bounds) and not _game._startup_menu_pending, "启动弹出结束保留原有白卡比例与中心 " + context)
	var start := _game.find_child("StartGameButton", true, false) as Button
	_check(not start.disabled and start.focus_mode == Control.FOCUS_ALL, "启动动画完成后按钮恢复原生输入 " + context)


## 比较用户可见的几何结果，不复制生产中的缩放公式；所有入口都必须留在白卡内。
func _check_card_geometry(context: String, require_occupancy: bool) -> void:
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	var viewport := root.get_visible_rect()
	var host := _game._menu_host.get_global_rect()
	_check(viewport.grow(1).encloses(bounds) and host.grow(1).encloses(bounds), "白卡不溢出宿主或实际视口 " + context)
	_check(bounds.get_center().distance_to(viewport.get_center()) <= 1.0 and bounds.get_center().distance_to(host.get_center()) <= 1.0, "白卡在实际视口和宿主内居中 " + context)
	_check(card.scale.x >= 1.0 and is_equal_approx(card.scale.x, card.scale.y) and is_equal_approx(card.modulate.a, 1.0), "白卡统一等比呈现且完全不透明 " + context)
	if require_occupancy:
		var occupancy := bounds.get_area() / viewport.get_area()
		_check(occupancy >= 0.60 and occupancy <= 0.72, "白卡占实际画幅 60%–72%，高分辨率下仍有足够使用面积 " + context + " actual=" + str(occupancy))
		_check(absf(bounds.size.x / bounds.size.y - 1.75) < 0.002, "未受小窗限制时保留白卡 7:4 比例 " + context)
	for name: String in ["MainMenuBrand", "MainMenuActions", "SettingsButton", "LeaveGameButton", "StartGameButton", "MapEditorButton"]:
		var control := _game.find_child(name, true, false) as Control
		_check(control != null and control.is_visible_in_tree() and bounds.grow(1).encloses(control.get_global_rect()), "主菜单内容完整留在白卡内 " + context + " " + name)
	print("Windows 白卡几何 %s：视口 %s，白卡 %s，占屏 %.3f，中心 %s。" % [context, viewport.size, bounds.size, bounds.get_area() / viewport.get_area(), bounds.get_center()])


## 逐帧观察真实设置按钮的淡出淡入，白卡实例、矩形和背景在转场中始终保持。
func _check_shared_pages(context: String) -> void:
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	var background := _game._main_background
	var old_content := _game.find_child("MainMenuActions", true, false) as Control
	await _click(_game.find_child("SettingsButton", true, false) as Control)
	var stable := true
	var old_faded := false
	var new_faded := false
	var overlap := false
	var deadline := Time.get_ticks_msec() + 2500
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		stable = stable and _same_card(card, bounds) and _game._main_background == background and background._active
		var old_visible := is_instance_valid(old_content) and old_content.is_visible_in_tree()
		var new_visible := is_instance_valid(_game.settings_panel) and _game.settings_panel.is_visible_in_tree()
		if old_visible:
			old_faded = old_faded or (old_content.modulate.a > 0.0 and old_content.modulate.a < 1.0)
		if new_visible:
			new_faded = new_faded or (_game.settings_panel.modulate.a > 0.0 and _game.settings_panel.modulate.a < 1.0)
			overlap = overlap or old_visible
			stable = stable and card.get_global_rect().grow(1).encloses(_game.settings_panel.get_global_rect())
		await process_frame
	await _settle(8)
	if not _check(_game.page == GameShell.Page.SETTINGS and not _game._menu_transitioning and is_instance_valid(_game.settings_panel), "真实点击完成设置转场 " + context):
		return
	_check(stable and _same_card(card, bounds), "设置淡出淡入始终保留白卡实例、矩形、不透明度和背景 " + context)
	_check(old_faded and new_faded and not overlap, "菜单先淡出，设置再淡入，没有内容重叠 " + context)
	_check_fade_bounds(_game.settings_panel, context + " 设置")
	await _check_manual_fonts(card, bounds, context)
	await _check_settings_message(context)
	await _capture("windows_settings_card_" + context)
	var colors := _game.settings_panel.find_child("CodeColorsButton", true, false) as Control
	_game.settings_panel._scroll.ensure_control_visible(colors)
	await _settle(8)
	await _click(colors)
	await _settle(8)
	if not _check(_game.page == GameShell.Page.CODE_COLORS and is_instance_valid(_game.code_color_panel), "真实点击打开颜色与显示子页 " + context):
		return
	_check(_same_card(card, bounds) and _game._main_background == background and background._active, "颜色子页仍复用同一白卡、矩形和背景 " + context)
	_check_fade_bounds(_game.code_color_panel, context + " 颜色")
	await _capture("windows_colors_card_" + context)
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.SETTINGS and _same_card(card, bounds), "颜色返回设置保持白卡矩形 " + context)
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.MAIN and _same_card(card, bounds), "设置返回主菜单保持白卡矩形 " + context)
	_game._show_message("测试消息", "此消息不修改任何玩家文件。")
	await _settle(4)
	_check(is_equal_approx(_game._message_dialog.content_scale_factor, 1.0), "离开设置后通用弹窗恢复基准比例 " + context)
	_game._message_dialog.hide()
	await _settle(4)


## 设置文件问题的独立弹窗按白卡比例呈现，不会被正文渐隐或挡住确认按钮。
func _check_settings_message(context: String) -> void:
	var factor := _card_factor()
	_game._show_message("测试消息", "此消息不修改任何玩家文件。")
	await _settle(4)
	var dialog := _game._message_dialog
	print("设置消息弹窗诊断 %s：比例 %.3f，窗口尺寸 %s，逻辑视口 %s，最小尺寸 %s。" % [context, factor, dialog.size, dialog.get_visible_rect(), dialog.min_size])
	_check(dialog.visible and is_equal_approx(dialog.content_scale_factor, factor), "设置消息弹窗继承共享白卡比例 " + context)
	_check(root.get_visible_rect().grow(1).encloses(Rect2(Vector2(dialog.position), Vector2(dialog.size))), "设置消息弹窗完整处于视口内 " + context)
	# AcceptDialog 会按相同正文收紧到内容最小尺寸，比较基准实际尺寸才能检查真实呈现比例。
	if is_equal_approx(factor, 1.0):
		_base_message_extent = Vector2(dialog.size)
	var expected := _base_message_extent * factor
	_check((Vector2(dialog.size) - expected).abs().x <= 2 and (Vector2(dialog.size) - expected).abs().y <= 2, "设置消息弹窗的实际宽高同步等比放大 " + context)
	dialog.hide()
	await _settle(4)


## 手动百分比经原生下拉菜单提交，字号确实改变而实际窗口与白卡尺寸保持独立。
func _check_manual_fonts(card: Panel, bounds: Rect2, context: String) -> void:
	var window_size := root.size
	for percentage: int in [110, 125, 150, 200, 100]:
		await _choose_font_percentage(percentage)
		_check(_game.window_controller.effective_ui_scale == percentage, "手动字号实际生效 " + context + " " + str(percentage))
		var option := _game.settings_panel.find_child("UiScaleOption", true, false) as OptionButton
		_check(option.get_theme_font_size("font_size") == roundi(16 * percentage / 100.0), "手动百分比改变字体且不累积 " + context + " " + str(percentage))
		_check(root.size == window_size and _same_card(card, bounds), "手动字号不改变客户区或白卡矩形 " + context + " " + str(percentage))
		_check_fade_bounds(_game.settings_panel, context + " 字号 " + str(percentage))


## 用真实鼠标和原生键盘路由选择字号，不直接调用控件信号或字体缩放器。
func _choose_font_percentage(percentage: int) -> void:
	var option := _game.settings_panel.find_child("UiScaleOption", true, false) as OptionButton
	if not _check(option != null and not option.disabled, "Windows 字号选择器可达"):
		return
	_game.settings_panel._scroll.ensure_control_visible(option)
	await _settle(8)
	await _click(option)
	var popup := option.get_popup()
	await _settle(8)
	if not _check(popup.visible, "真实点击打开字号菜单"):
		return
	_check_popup_geometry(option, popup)
	var index := -1
	for item in option.item_count:
		if option.get_item_id(item) == percentage:
			index = item
	if not _check(index >= 0, "UHD 画像开放目标字号 " + str(percentage)):
		popup.hide()
		return
	var deadline := Time.get_ticks_msec() + 2500
	while popup.get_focused_item() != index and Time.get_ticks_msec() < deadline:
		await _key(root, KEY_UP if popup.get_focused_item() > index else KEY_DOWN)
	if not _check(popup.get_focused_item() == index, "原生菜单聚焦目标字号 " + str(percentage)):
		popup.hide()
		return
	await _key(root, KEY_ENTER)
	await _settle(12)
	_check(_game.settings.ui_scale == percentage and not popup.visible, "原生选择保存百分比并关闭菜单 " + str(percentage))


## 检查两端渐隐的实际视口坐标和导航边界，放大白卡后遮罩仍严格封闭在同一矩形。
func _check_fade_bounds(panel: Control, context: String) -> void:
	var bounds := _game._menu_card.get_global_rect()
	var scroll: ScrollContainer = panel.get("_scroll")
	var fade: SettingsContentFade = panel.get("_content_fade")
	var scroll_bounds := scroll.get_global_rect()
	var factor := _card_factor()
	_check(panel.get_parent() == _game._menu_card and panel.get("card_boundary") == _game._menu_card and bounds.grow(1).encloses(panel.get_global_rect()), "共享面板完整封闭在白卡内 " + context)
	_check(bounds.grow(1).encloses(scroll_bounds) and root.get_visible_rect().grow(1).encloses(scroll_bounds), "设置滚动视口不溢出白卡或实际画幅 " + context)
	_check(absf(scroll_bounds.position.y - bounds.position.y) <= 1.0 and absf(scroll_bounds.end.y - bounds.end.y) <= 1.0, "渐隐上下边界紧贴白卡 " + context)
	_check(absf(fade._fade_parameters.x - bounds.position.y) <= 1.0 and absf(fade._fade_parameters.w - bounds.end.y) <= 1.0 and is_equal_approx(fade._fade_parameters.z, root.get_visible_rect().size.y), "渐隐材质使用真实白卡边缘和视口高度 " + context)
	_check(is_equal_approx(fade._fade_parameters.y, 48.0 * factor) and scroll.get_global_transform().get_scale().is_equal_approx(Vector2(0.8, 0.8) * factor), "渐隐宽度和设置正文随白卡同比例扩大 " + context)
	_check(_game._header.get_parent() == _game._menu_card and not fade.is_ancestor_of(_game._header) and bounds.grow(1).encloses(_game._header.get_global_rect()), "导航留在白卡内且独立于渐隐 " + context)


## 同一节点、全局矩形和不透明度一起比较，避免只凭相同尺寸漏掉重建或移动。
func _same_card(card: Panel, bounds: Rect2) -> bool:
	return _game._menu_card == card and card.is_visible_in_tree() and card.get_global_rect().is_equal_approx(bounds) and is_equal_approx(card.modulate.a, 1.0)


## 从真实全局变换读取呈现比例，用于验证子控件和渐隐跟随父卡片。
func _card_factor() -> float:
	return absf(_game._menu_card.get_global_transform().get_scale().x)


## 真实弹窗记录字号、画幅和缩放，明确原生嵌入窗口是否继承父控件的视觉比例。
func _check_popup_geometry(option: OptionButton, popup: PopupMenu) -> void:
	var bounds := Rect2(Vector2(popup.position), Vector2(popup.size))
	_check(root.get_visible_rect().grow(1).encloses(bounds), "缩放后的原生字号弹窗完整位于实际视口内")
	var popup_base := GameTheme.base_font_size(popup, "font_size")
	_check(popup.get_theme_font_size("font_size") == roundi(popup_base * _game.settings.ui_scale / 100.0), "原生弹窗沿用自身逻辑字号基准并独立应用手动百分比")
	_check(popup.get_screen_transform().get_scale().is_equal_approx(option.get_global_transform().get_scale()), "原生嵌入弹窗自动继承设置控件的视觉比例，不重复放大字体")
	print("Windows 字号弹窗诊断：画幅 %s，白卡比例 %.3f，已应用字号 %d%%，选项全局矩形 %s，弹窗矩形 %s，选项字体 %d，弹窗字体 %d，弹窗内容比例 %.3f，屏幕变换 %s。" % [root.size, _card_factor(), _game.settings.ui_scale, option.get_global_rect(), bounds, option.get_theme_font_size("font_size"), popup.get_theme_font_size("font_size"), popup.content_scale_factor, popup.get_screen_transform().get_scale()])


## 在中英文字号放大与恢复后检查页脚，最小文本高度不能挤掉等距底部和侧边留白。
func _check_footer_fonts(context: String) -> void:
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	var window_size := root.size
	for locale: String in ["zh_CN", "en"]:
		_game.settings.set_language(locale)
		for percentage: int in [100, 125, 200]:
			_game.settings.set_ui_scale(percentage)
			await _settle(12)
			_check(root.size == window_size and _same_card(card, bounds), "主菜单手动字号和语言不改变白卡或窗口 " + context + " " + locale + " " + str(percentage))
			var inset := 16.0 * _card_factor()
			for name: String in ["LeaveGameButton", "SettingsButton"]:
				var button := _game.find_child(name, true, false) as Button
				var button_bounds := button.get_global_rect()
				_check(bounds.grow(1).encloses(button_bounds), "放大文字后页脚按钮完整留在白卡内 " + context + " " + locale + " " + str(percentage) + " " + name)
				_check(absf(bounds.end.y - button_bounds.end.y - inset) <= 1.0, "页脚按钮保持同比例底边留白 " + context + " " + locale + " " + str(percentage) + " " + name)
				var side_inset := button_bounds.position.x - bounds.position.x if name == "LeaveGameButton" else bounds.end.x - button_bounds.end.x
				_check(absf(side_inset - inset) <= 1.0, "页脚按钮保持同比例侧边留白 " + context + " " + locale + " " + str(percentage) + " " + name)
				_check(button.size.x + 1.0 >= button.get_combined_minimum_size().x and button.size.y + 1.0 >= button.get_combined_minimum_size().y and button.get_theme_font_size("font_size") == roundi(16 * percentage / 100.0), "页脚容纳真实最小文本尺寸且独立应用手动字号 " + context + " " + locale + " " + str(percentage) + " " + name)
			if percentage == 200:
				await _capture("windows_footer_%s_%s_200" % [context, locale])
	_game.settings.set_ui_scale(100)
	_game.settings.set_language("zh_CN")
	await _settle(12)


## 小窗沿用有限的原始尺寸并收窄到宿主，不能因高分辨率屏幕画像而强行放大白卡。
func _check_small_windows() -> void:
	_set_platform("Windows")
	_game.settings.set_ui_scale(100)
	for dimensions: Vector2i in [Vector2i(1024, 640), Vector2i(1000, 560)]:
		if not _native_size_available(Vector2i(1024, 640)):
			continue
		# 1000×560 是系统最小客户区压力夹具，直接改变真实根窗口而不加入玩家分辨率选项。
		root.size = dimensions
		await _settle(12)
		var card := _game._menu_card
		_check(card.size.x <= BASE_CARD_SIZE.x and card.size.y <= BASE_CARD_SIZE.y and card.size.is_equal_approx(_game._menu_host.size), "小窗白卡收窄到宿主且不放大 " + str(dimensions))
		_check_card_geometry("小窗 " + str(dimensions), false)
		await _capture("windows_main_card_small_%dx%d" % [dimensions.x, dimensions.y])


## 非 Windows 保持原逻辑白卡和字体；相同大窗口切换平台也要立即重新布局。
func _check_macos() -> void:
	var dimensions := Vector2i(3840, 2160) if DisplayServer.get_name() == "headless" else Vector2i(1280, 800)
	if not _native_size_available(dimensions):
		return
	# 小窗压力夹具直接改变过窗口，先提交另一预设再恢复目标，避免重复偏好被控制器正确忽略。
	_game.settings.set_window_resolution("1024x640")
	_game.settings.set_window_resolution("%dx%d" % [dimensions.x, dimensions.y])
	await _settle(12)
	if DisplayServer.get_name() == "headless":
		_check(_game._menu_card.get_global_rect().size.x > BASE_CARD_SIZE.x * 2.0, "切换平台前实际 4K Windows 卡片已经扩大")
	_set_platform("macOS")
	_game.settings.set_ui_scale(200)
	await _settle(12)
	var card := _game._menu_card
	_check(card.size.is_equal_approx(BASE_CARD_SIZE), "macOS 大窗口保持原 1120×640 逻辑白卡")
	_check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and is_equal_approx(root.content_scale_factor, 1.0), "macOS 保持原 Canvas Items 画幅策略")
	var title := _game.find_child("MainMenuTitle", true, false) as Label
	_check(title.get_theme_font_size("font_size") == 36 and _game.settings.ui_scale == 200 and _game.window_controller.effective_ui_scale == 100, "macOS 忽略 Windows 手动字号且保留保存值")
	_check_card_geometry("macOS", false)
	await _capture("macos_main_card_unchanged")
	if await _open_settings():
		var bounds := card.get_global_rect()
		var option := _game.settings_panel.find_child("UiScaleOption", true, false) as OptionButton
		_check(option.disabled and _same_card(card, bounds), "macOS 字号控件禁用且设置沿用同一白卡")
		_check_fade_bounds(_game.settings_panel, "macOS 设置")
		await _click(_game._back_button)


## 超时统一按失败退出，并仅清理当前进程创建的隔离存档。
func _timeout() -> void:
	if _finished:
		return
	_check(false, "Windows 白卡回归超过 90 秒")
	await _dispose_game()
	_finish()


## 输出可核对的专用完成标记，再恢复共享全局状态并删除唯一测试目录。
func _finish() -> void:
	if not _finished:
		print("Windows 主菜单白卡回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	super._finish()
