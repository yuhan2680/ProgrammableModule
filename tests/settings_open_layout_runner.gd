extends SceneTree
## 真实设置页面回归：三种语言下验证滚动、原生输入和白卡导航；可选 GPU 像素验证双端透明渐隐。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _original_transparent := false


## 等待根视口可用，并只在明确指定目录时导出真实 GPU 画面。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 使用独占设置和存档运行六种布局，退出前恢复全局音量与语言。
func _run() -> void:
	_temporary = "user://tests/settings_open_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var original_volume := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.system_sound_preview_handler = func() -> void: pass
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	root.add_child(_game)
	await _settle()
	await _check_interrupted_transition()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			_game._show_main_page()
			await _settle()
			await _open_settings("%dx%d_%s" % [dimensions.x, dimensions.y, locale])
			await _check_page("%dx%d_%s" % [dimensions.x, dimensions.y, locale])
			await _check_colors_page("%dx%d_%s" % [dimensions.x, dimensions.y, locale])
	_add_background_fixtures()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			_game._show_code_colors_page()
			await _settle()
			await _check_color_gallery("%dx%d_%s" % [dimensions.x, dimensions.y, locale])
	if not _capture_directory.is_empty() and DisplayServer.get_name() != "headless":
		_game._show_settings_page()
		await _settle()
		await _check_gpu_alpha(_game.settings_panel.find_child("AudioSettingsGroup", true, false) as Control, _game.settings_panel._scroll, "alpha_probe")
		_game._show_code_colors_page()
		await _settle()
		# 正常颜色页可完整容纳图库；仅压力探针添加空白滚动空间，不改变真实设置控件。
		_game.code_color_panel._column.custom_minimum_size.y = _game.code_color_panel._scroll.size.y * 2.0
		await _settle()
		await _check_gpu_alpha(_game.code_color_panel.find_child("CodeColorGroup", true, false) as Control, _game.code_color_panel._scroll, "colors_alpha_probe")
	_game.queue_free()
	await _settle()
	_check(root.transparent_bg == _original_transparent, "销毁最后一个设置页面恢复原视口透明状态")
	AudioServer.set_bus_volume_db(master, original_volume)
	AudioServer.set_bus_mute(master, original_mute)
	TranslationServer.set_locale(original_locale)
	_remove_tree(_temporary)
	print("设置开放布局回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 外部页面切换取消尚未完成的淡出，旧 Tween 不得稍后把玩家送回设置。
func _check_interrupted_transition() -> void:
	var card := _game._menu_card
	await _click(_game.find_child("SettingsButton", true, false) as Control)
	_check(_game._menu_transitioning and _game.page == GameShell.Page.MAIN, "设置入口先播放菜单淡出")
	_game._show_main_page()
	await create_timer(0.45).timeout
	var button := _game.find_child("SettingsButton", true, false) as Control
	_check(_game.page == GameShell.Page.MAIN and not _game._menu_transitioning and _game._menu_card == card and button != null and button.modulate.a == 1.0, "中途取消后白卡与菜单恢复，不会执行迟到的设置回调")


## 逐帧检查菜单先退、设置再入；卡片和背景持续保留，Esc 不穿透。
func _open_settings(context: String) -> void:
	var card := _game._menu_card
	var card_rect := card.get_global_rect()
	var background := _game._main_background
	var background_path := background._selected_path
	var old_content := _game.find_child("MainMenuActions", true, false) as Control
	await _click(_game.find_child("SettingsButton", true, false) as Control)
	var stable := true
	var overlap := false
	var old_faded := false
	var new_faded := false
	var deadline := Time.get_ticks_msec() + 2000
	var sent_cancel := false
	var captured_old := false
	var captured_new := false
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		stable = stable and _game._menu_card == card and card.is_visible_in_tree() and card.modulate.a == 1.0 and card.get_global_rect().is_equal_approx(card_rect) and _game._main_background == background and background._active and background._selected_path == background_path
		var old_visible := is_instance_valid(old_content) and old_content.is_visible_in_tree()
		if old_visible:
			old_faded = old_faded or (old_content.modulate.a > 0.0 and old_content.modulate.a < 1.0)
		var new_visible := is_instance_valid(_game.settings_panel) and _game.settings_panel.is_visible_in_tree()
		if new_visible:
			new_faded = new_faded or (_game.settings_panel.modulate.a > 0.0 and _game.settings_panel.modulate.a < 1.0)
		overlap = overlap or (old_visible and new_visible)
		if context == "1280x800_zh_CN" and old_visible and not captured_old and old_content.modulate.a < 0.7:
			captured_old = true
			await _capture("menu_fading")
		if context == "1280x800_zh_CN" and new_visible and not captured_new and _game.settings_panel.modulate.a > 0.3:
			captured_new = true
			await _capture("settings_fading")
		if not sent_cancel:
			_key(root, KEY_ESCAPE)
			sent_cancel = true
		await process_frame
	await _settle()
	_check(not _game._menu_transitioning and _game.page == GameShell.Page.SETTINGS, "真实入口动画结束后进入设置，Esc 不穿透 " + context)
	_check(stable and _game._menu_card == card and card.get_global_rect().is_equal_approx(card_rect), "整个淡出淡入过程白卡实例、位置、不透明度和背景连续 " + context)
	_check(old_faded and new_faded and not overlap, "旧菜单先淡出，再显示设置淡入，不同时叠放 " + context)
	_check(_game._header.get_parent() == card and _game._header.global_position.is_equal_approx(card.global_position + Vector2(24, 24)), "设置导航位于白卡内且独立于滚动内容 " + context)


## 内容首尾都经真实滚轮到达，焦点、弹层和点击仍由原生控件处理。
func _check_page(context: String) -> void:
	if not _check(_game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "设置入口真实点击打开页面 " + context):
		return
	var panel := _game.settings_panel
	var scroll := panel._scroll
	_check_panel_navigation(panel._scroll, context)
	var first := panel.find_child("SoundSectionTitle", true, false) as Control
	var last := panel.find_child("ClearProgressButton", true, false) as Control
	var boundary := _game._menu_card.get_global_rect()
	_check(panel.get_parent() == _game._menu_card and panel.card_boundary == _game._menu_card, "设置页沿用主菜单同一张白卡 " + context)
	_check(absf(scroll.global_position.y - boundary.position.y) <= 1.0 and absf(scroll.get_global_rect().end.y - boundary.end.y) <= 1.0, "滚动上下边界与整张白卡边缘对齐 " + context)
	_check(scroll.scroll_vertical == 0 and first.global_position.y >= boundary.position.y + 92.0, "首屏标题留足卡内导航和渐隐空间 " + context)
	_check(root.get_visible_rect().grow(1).encloses(scroll.get_global_rect()), "设置滚动视口留在窗口内 " + context)
	await _capture(context + "_top")
	var volume := panel._volume_slider
	await _click(volume, MOUSE_BUTTON_LEFT, Vector2(0.35, 0.5))
	_check(_game.settings.volume > 0.1 and _game.settings.volume < 0.8, "主音量滑条响应实际坐标输入 " + context)
	var before := _game.settings.tab_completion
	await _scroll_to(scroll, panel._tab_completion_toggle, context)
	await _click(panel._tab_completion_toggle)
	_check(_game.settings.tab_completion != before, "透明布局不拦截开关点击 " + context)
	await _click(panel._tab_completion_toggle)
	await _scroll_to(scroll, panel._code_hints_option, context)
	var hint_index := GameSettings.SUPPORTED_CODE_HINTS.find(_game.settings.code_hints)
	var next_hint_index := (hint_index + 1) % GameSettings.SUPPORTED_CODE_HINTS.size()
	await _click(panel._code_hints_option)
	var popup := panel._code_hints_option.get_popup()
	_check(popup.visible, "代码提示选择器可打开原生下拉 " + context)
	if popup.visible:
		# 勾选菜单打开时定位已保存项；方向键从该项移动，而不是每次从未聚焦状态开始。
		_check(popup.get_focused_item() == hint_index, "原生下拉初始聚焦当前设置 " + context)
		_key(root, KEY_DOWN)
		await _settle()
		_check(popup.get_focused_item() == next_hint_index and panel._code_hints_option.selected == hint_index, "方向键移动焦点但确认前不修改设置 " + context)
		_key(root, KEY_ENTER)
		await _settle()
		_check(_game.settings.code_hints == GameSettings.SUPPORTED_CODE_HINTS[next_hint_index] and panel._code_hints_option.selected == next_hint_index and not popup.visible, "原生下拉键盘选择仍保存设置 " + context)
	await _scroll_to(scroll, last, context)
	_check(scroll.scroll_vertical > 0, "原生滚轮实际移动设置内容 " + context)
	await _capture(context + "_bottom")
	await _click(panel._language_option)
	popup = panel._language_option.get_popup()
	_check(popup.visible and root.get_visible_rect().grow(1).encloses(Rect2(Vector2(popup.position), Vector2(popup.size))), "三语言下地区菜单保持窗口内可见 " + context)
	if popup.visible:
		_key(root, KEY_ESCAPE)
		await _settle()
	await _scroll_to(scroll, first, context)
	for attempt in 20:
		if scroll.scroll_vertical == 0:
			break
		await _click(scroll, MOUSE_BUTTON_WHEEL_UP, Vector2(0.02, 0.5))
	_check(scroll.scroll_vertical == 0, "滚轮可回到完整首项 " + context)
	# 截图取实际滚动过程中的位置，不改变内容的尺寸或绘制方式。
	await _click(scroll, MOUSE_BUTTON_WHEEL_DOWN, Vector2(0.02, 0.5))
	_check_panel_navigation(scroll, context + " 滚动中")
	await _capture(context + "_scroll")
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.MAIN, "滚动内容不覆盖药丸返回命中区 " + context)
	_check(root.transparent_bg == _original_transparent, "返回主菜单恢复原视口透明状态 " + context)


## 通过正式设置入口进入颜色子页，验证透明布局、代码预览点击和两级返回。
func _check_colors_page(context: String) -> void:
	await _open_settings(context)
	var retained_card := _game._menu_card
	var retained_rect := retained_card.get_global_rect()
	var retained_background := _game._main_background
	var colors := _game.settings_panel.find_child("CodeColorsButton", true, false) as Control
	await _scroll_to(_game.settings_panel._scroll, colors, context)
	await _click(colors)
	if not _check(_game.page == GameShell.Page.CODE_COLORS and _game.code_color_panel != null, "颜色子页入口真实点击可达 " + context):
		return
	var panel := _game.code_color_panel
	_check(_game._menu_card == retained_card and retained_card.get_global_rect().is_equal_approx(retained_rect) and _game._main_background == retained_background and retained_background._active, "颜色子页切换保持白卡实例、位置和主菜单背景 " + context)
	var boundary := _game._menu_card.get_global_rect()
	_check_panel_navigation(panel._scroll, context + " 颜色子页")
	var title := panel.find_child("CodeColorTitle", true, false) as Control
	_check(panel.get_parent() == _game._menu_card and panel.card_boundary == _game._menu_card, "颜色子页沿用主菜单同一张白卡 " + context)
	_check(absf(panel._scroll.global_position.y - boundary.position.y) <= 1.0 and absf(panel._scroll.get_global_rect().end.y - boundary.end.y) <= 1.0 and title.global_position.y >= boundary.position.y + 92.0, "颜色子页同样在白卡上下边缘渐隐且首项留白完整 " + context)
	_check(root.get_visible_rect().grow(1).encloses(panel._scroll.get_global_rect()), "颜色子页滚动视口留在窗口内 " + context)
	await _click(panel._buttons["dark"])
	_check(_game.settings.code_color_mode == "dark", "透明子页不阻挡代码颜色选择 " + context)
	await _click(panel._buttons["light"])
	_check(_game.settings.code_color_mode == "light", "可切回浅色代码预览 " + context)
	await _capture(context + "_colors_top")
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.SETTINGS and root.transparent_bg, "颜色子页返回设置继续保持高精度合成 " + context)
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.MAIN and root.transparent_bg == _original_transparent, "两级返回后恢复原视口透明状态 " + context)


## 比较屏幕实际文字范围与内容列，窄窗口及滚动中也不能把正文压到固定导航上。
func _check_panel_navigation(scroll: ScrollContainer, context: String) -> void:
	var title := _game._title
	var font := title.get_theme_font("font")
	var text_width := font.get_string_size(title.tr(title.text), HORIZONTAL_ALIGNMENT_LEFT, -1, title.get_theme_font_size("font_size")).x
	var title_right := title.get_global_transform_with_canvas() * Vector2(text_width, 0)
	_check(scroll.global_position.x >= title_right.x + 15.0, "正文与导航实际文字至少留出16像素，滚动时互不覆盖 " + context)
	_check(scroll.get_global_transform().get_scale().is_equal_approx(Vector2(0.8, 0.8)), "设置内容整体按80%显示，导航和白卡保持原尺寸 " + context)
	var bar := scroll.get_v_scroll_bar()
	var grabber := bar.get_theme_stylebox("grabber") as StyleBoxFlat
	var track := bar.get_theme_stylebox("scroll") as StyleBoxFlat
	_check(grabber != null and grabber.bg_color.a <= 0.4 and track != null and track.bg_color.a <= 0.1, "纵向滚动条采用低对比滑块和透明轨道 " + context)


## 只在测试目录生成五张小图，经真实设置导入接口形成横向图库溢出。
func _add_background_fixtures() -> void:
	var input_directory := _temporary.path_join("images")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(input_directory))
	for index in 5:
		var picture := Image.create(64, 48, false, Image.FORMAT_RGBA8)
		picture.fill(Color.from_hsv(float(index) / 5.0, 0.7, 0.8))
		var path := input_directory.path_join("Layout %d.png" % (index + 1))
		_check(picture.save_png(path) == OK and _game.settings.import_background(ProjectSettings.globalize_path(path)).is_ok(), "创建并导入测试图库图片 %d" % index)
	_game.settings.set_menu_background("default")


## 自定义图片紧接三个内置项，三语言下整排可左右滚动并保持原选择行为。
func _check_color_gallery(context: String) -> void:
	var panel := _game.code_color_panel
	var picker := panel._background_picker
	var scroll := picker._custom_scroll
	await _scroll_to(panel._scroll, scroll, context)
	_check(root.get_visible_rect().grow(1).encloses(scroll.get_global_rect()), "整排背景选项的滚动视口留在颜色页内 " + context)
	_check(scroll.get_h_scroll_bar().visible and scroll.get_h_scroll_bar().max_value > scroll.get_h_scroll_bar().page, "同排内置及自定义选项溢出时提供横向滚动范围 " + context)
	var keys: Array[String] = ["default", "solid", "add"]
	for entry: Dictionary in _game.settings.custom_backgrounds:
		keys.append(entry.id)
	var first: Control = picker._buttons["default"]
	var previous: Control
	var same_row := true
	for key: String in keys:
		var button: Control = picker._buttons[key]
		same_row = same_row and button.get_parent() == first.get_parent() and scroll.is_ancestor_of(button)
		same_row = same_row and absf(button.global_position.y - first.global_position.y) < 1.0 and absf(button.size.y - first.size.y) < 1.0
		if previous != null:
			same_row = same_row and button.global_position.x >= previous.get_global_rect().end.x
		previous = button
	_check(same_row, "默认、纯色、添加及自定义按顺序排在同一行 " + context)
	scroll.scroll_horizontal = 0
	await _settle()
	for key: String in ["default", "solid", "add"]:
		_check(scroll.get_global_rect().grow(1).encloses(picker._buttons[key].get_global_rect()), "整排起点完整显示 " + key + " " + context)
	await _capture(context + "_colors_gallery_start")
	var default_left := first.global_position.x
	var first_custom: Control = picker._buttons[_game.settings.custom_backgrounds[0].id]
	var captured_join := false
	for step in 40:
		var before := scroll.scroll_horizontal
		await _click(scroll, MOUSE_BUTTON_WHEEL_RIGHT)
		if not captured_join and scroll.get_global_rect().grow(1).encloses(first_custom.get_global_rect()):
			await _capture(context + "_colors_gallery_join")
			captured_join = true
		if scroll.scroll_horizontal == before:
			break
	_check(scroll.scroll_horizontal > 0 and first.global_position.x < default_left, "真实横向滚轮移动默认项和后续图片组成的整排 " + context)
	var last_id: String = _game.settings.custom_backgrounds[-1].id
	var last: Control = picker._buttons[last_id]
	_check(scroll.get_global_rect().grow(1).encloses(last.get_global_rect()), "横滚后最后一张自定义图完整可见 " + context)
	await _click(last, MOUSE_BUTTON_RIGHT)
	_check(picker._delete_popup.visible, "缩小后的自定义背景仍可右键打开删除菜单 " + context)
	_check(not _has_visible_vertical_scrollbar(picker._delete_popup), "单项删除菜单完整显示，不产生多余小纵向滚动条 " + context)
	await _capture(context + "_colors_background_delete")
	_key(root, KEY_ESCAPE)
	await _settle()
	await _click(last)
	_check(_game.settings.menu_background_id == last_id, "横滚后的自定义背景可真实点击选择 " + context)
	await _capture(context + "_colors_gallery")
	for step in 40:
		if scroll.scroll_horizontal == 0:
			break
		await _click(scroll, MOUSE_BUTTON_WHEEL_LEFT)
	_check(scroll.scroll_horizontal == 0 and scroll.get_global_rect().grow(1).encloses(first.get_global_rect()), "真实横向滚轮可回到同排默认项 " + context)
	await _click(first)
	_check(_game.settings.menu_background_mode == "default", "回到整排起点后默认背景仍可实际选择 " + context)
	await _click(_game._back_button)
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.MAIN and root.transparent_bg == _original_transparent, "图库页面离开后恢复原视口状态 " + context)


## 检查原生弹窗内部的真实滚动条，而不是仅用外框大小推断文字是否被裁剪。
func _has_visible_vertical_scrollbar(node: Node) -> bool:
	if node is VScrollBar and node.is_visible_in_tree():
		return true
	for child in node.get_children(true):
		if _has_visible_vertical_scrollbar(child):
			return true
	return false


## 将目标滚入不含顶部渐隐的区域，避免透明但仍在几何视口内的控件冒充可见。
func _scroll_to(scroll: ScrollContainer, target: Control, context: String) -> void:
	for attempt in 40:
		var viewport := scroll.get_global_rect()
		viewport.position.y += 80.0
		viewport.size.y -= 136.0
		if viewport.grow(1).encloses(target.get_global_rect()):
			break
		var previous := scroll.scroll_vertical
		var direction := MOUSE_BUTTON_WHEEL_DOWN if target.get_global_rect().end.y > viewport.end.y else MOUSE_BUTTON_WHEEL_UP
		await _click(scroll, direction, Vector2(0.02, 0.5))
		if previous == scroll.scroll_vertical:
			break
	_check(scroll.get_global_rect().grow(1).encloses(target.get_global_rect()), "真实滚轮完整到达 " + target.name + " " + context)


## 改变同一白卡的底色，读取真实设置分组在上下边缘的透明层次，排除白色遮盖。
func _check_gpu_alpha(row: Control, scroll: ScrollContainer, prefix: String) -> void:
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	var surface := card.get_theme_stylebox("panel") as StyleBoxFlat
	var probe_surface := surface.duplicate() as StyleBoxFlat
	card.add_theme_stylebox_override("panel", probe_surface)
	var content := scroll.get_node("SettingsScrollbarGutter") as MarginContainer
	var original_top := content.get_theme_constant("margin_top")
	for edge in ["top", "bottom"]:
		if edge == "bottom":
			# 只加测试留白，使同一个真实分组可以移动到底边；不替换控件或其材质。
			content.add_theme_constant_override("margin_top", original_top + roundi(bounds.size.y))
			await _settle()
		var boundary := bounds.position.y if edge == "top" else bounds.end.y
		var delta := row.global_position.y - boundary + 8.0 if edge == "top" else row.get_global_rect().end.y - boundary - 8.0
		scroll.scroll_vertical += roundi(delta / scroll.get_global_transform().get_scale().y)
		await _settle()
		_check(row.global_position.y < boundary if edge == "top" else row.get_global_rect().end.y > boundary, "GPU 夹具将真实分组移动到白卡边缘 " + prefix + " " + edge)
		probe_surface.bg_color = Color(0.12, 0.32, 0.65)
		var blue := await _capture(prefix + "_" + edge + "_blue")
		probe_surface.bg_color = Color(0.10, 0.65, 0.20)
		var green := await _capture(prefix + "_" + edge + "_green")
		if not _check(blue != null and green != null, "GPU 渲染返回两幅真实视口像素"):
			continue
		var x := roundi(row.global_position.x + 20.0)
		var start := ceili(boundary + 1.0) if edge == "top" else floori(boundary - 1.0)
		var differences: Array[float] = []
		var intermediate := 0
		var largest_step := 0.0
		for distance in range(60):
			var y := start + distance if edge == "top" else start - distance
			var left := blue.get_pixel(x, y)
			var right := green.get_pixel(x, y)
			var difference := Vector3(left.r - right.r, left.g - right.g, left.b - right.b).length()
			if difference > 0.04 and difference < 0.40:
				intermediate += 1
			if not differences.is_empty():
				largest_step = maxf(largest_step, absf(difference - differences[-1]))
			differences.append(difference)
		_check(differences[0] > 0.40 and differences[-1] < 0.04, "白卡边缘揭示底色，向内恢复不透明 " + prefix + " " + edge)
		_check(intermediate >= 8 and largest_step < 0.12, "GPU 渐隐含连续透明层次，无硬裁剪跳变 " + prefix + " " + edge)
		var blank := blue.get_pixel(x - 40, start + (12 if edge == "top" else -12))
		_check(Vector3(blank.r - 0.12, blank.g - 0.32, blank.b - 0.65).length() < 0.03, "分组外保留白卡原底色，无额外白雾 " + prefix + " " + edge)
		print("GPU 渐隐证据 %s %s：边缘底色差 %.3f，内部 %.3f，中间像素 %d，相邻最大变化 %.3f。" % [prefix, edge, differences[0], differences[-1], intermediate, largest_step])
	content.add_theme_constant_override("margin_top", original_top)
	card.add_theme_stylebox_override("panel", surface)
	await _settle()


## 使用视口坐标分发鼠标事件，使原生滚动和命中处理参与验证。
func _click(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT, fraction: Vector2 = Vector2(0.5, 0.5)) -> void:
	if control == null:
		_check(false, "待点击控件存在")
		return
	var point := control.get_global_transform_with_canvas() * (control.size * fraction)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	_send_pointer_event(motion, control is OptionButton)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
		_send_pointer_event(event, control is OptionButton)
	await _settle()


## 原生下拉需要真实全局按键状态，才能在向上展开时忽略打开菜单的同一次鼠标释放。
func _send_pointer_event(event: InputEventMouse, native_state: bool) -> void:
	if native_state:
		# parse_input_event 使用窗口坐标；其余控件沿用视口逻辑坐标的 push_input。
		event.position = root.get_final_transform() * event.position
		event.global_position = event.position
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	else:
		root.push_input(event, true)


## 键盘从根视口进入，由 Godot 转发给当前具有焦点的原生弹出窗口。
func _key(viewport: Viewport, keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		viewport.push_input(event, true)


## 等待容器和翻译重新排版，截图额外等待实际绘制完成。
func _settle() -> void:
	for frame in 4:
		await process_frame


## 可选截图来自实际渲染视口，不使用 headless 占位或重绘模拟界面。
func _capture(filename: String) -> Image:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return null
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(image.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存 GPU 截图 " + filename)
	return image


## 汇总失败后继续其余语言与尺寸，便于一次定位所有可达性回归。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 只递归删除本轮明确创建的测试目录。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
