extends "res://tests/windows_menu_card_runner.gd"
## 验证设置选择菜单的勾选呈现、原生输入和持久化；真实 GPU 额外检查蓝底白勾。


## 使用隔离设置实例覆盖窄窗、常用画幅和手动缩放，所有更改均限制在测试目录。
func _run() -> void:
	_temporary = "user://tests/settings_option_checkmark_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_set_platform("Windows")
	await _settle(12)
	if not await _open_settings():
		await _dispose_game()
		_finish()
		return
	for profile: Dictionary in [{"size": Vector2i(1000, 740), "scale": 100}, {"size": Vector2i(1280, 800), "scale": 100}, {"size": Vector2i(1280, 800), "scale": 125}, {"size": Vector2i(3840, 2160), "scale": 200}]:
		if profile.size.x >= 3840 and not _native_size_available(profile.size):
			continue
		_game.settings.set_language("ja" if profile.scale == 200 else "zh_CN")
		_game.settings.set_code_hints("normal")
		_game.settings.set_window_resolution("1280x800")
		_game.settings.set_ui_scale(profile.scale)
		await _settle(10)
		root.size = profile.size
		await _settle(10)
		var context := "%dx%d_%d" % [root.size.x, root.size.y, profile.scale]
		for node_name: String in ["LanguageOption", "CodeHintsOption", "WindowResolutionOption"]:
			await _check_selected_menu(node_name, context)
	# 4K 大字号只覆盖锚定；后续持久化、鼠标选择用常规字号，避免窗口缩小时菜单覆盖打开指针。
	_game.settings.set_ui_scale(125)
	_game.settings.set_window_resolution("1280x800")
	await _settle(12)
	await _check_disabled_skip()
	await _check_submission("LanguageOption", 2)
	await _check_submission("CodeHintsOption", 2)
	await _check_submission("WindowResolutionOption", GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find("1024x640"))
	var stored := GameSettings.new(_game.settings_path)
	_check(stored.load_settings().is_ok() and stored.language == "es" and stored.code_hints == "more" and stored.window_resolution == "1024x640", "三类原生菜单均将选择写入隔离设置文件")
	await _dispose_game()
	await _create_game()
	_set_platform("Windows")
	await _settle(10)
	await _open_settings()
	for node_name: String in ["LanguageOption", "CodeHintsOption", "WindowResolutionOption"]:
		await _check_selected_menu(node_name, "restored")
		await _check_pointer_open(node_name)
	_set_platform("macOS")
	_game.settings.set_language("zh_CN")
	await _settle(12)
	for node_name: String in ["LanguageOption", "CodeHintsOption", "WindowResolutionOption"]:
		await _check_selected_menu(node_name, "macOS")
		await _check_pointer_open(node_name)
	await _dispose_game()
	_finish()


## 打开后检查当前项，移动焦点不得提前改变勾选；Esc 和重新打开保留原有设置。
func _check_selected_menu(node_name: String, context: String) -> void:
	var option := _game.settings_panel.find_child(node_name, true, false) as OptionButton
	var popup := option.get_popup()
	var original := option.selected
	await _open_option(option)
	if not _check(popup.visible, "原生选择菜单可打开 " + node_name + " " + context):
		return
	_check_checked(popup, original, node_name + " " + context)
	_check_anchor_alignment(option, context)
	_check(popup.get_focused_item() == original, "重新打开焦点定位到当前设置 " + node_name + " " + context)
	await _check_blue_selection(popup, node_name + " " + context)
	await _capture("checkmark_" + context + "_" + node_name)
	if popup.item_count <= 5:
		await _hover_menu(popup, popup.get_visible_rect().get_center())
		_check(popup.get_focused_item() >= 0 and option.selected == original, "鼠标悬停不提交菜单选项 " + node_name)
		_check_checked(popup, original, node_name + " 鼠标悬停")
		if node_name == "LanguageOption" and context == "1280x800_100":
			await _capture("checkmark_hover_language")
	await _key(root, KEY_DOWN)
	_check(option.selected == original, "方向键只移动焦点而不提前提交 " + node_name)
	_check_checked(popup, original, node_name + " 方向键预览")
	if node_name == "LanguageOption" and context == "1280x800_100":
		await _capture("checkmark_focused_other_language")
	await _key(root, KEY_ESCAPE)
	await _settle(6)
	_check(not popup.visible and option.selected == original, "Esc 关闭并保留选择 " + node_name)
	await _open_option(option)
	_check_checked(popup, original, node_name + " 再次打开")
	await _key(root, KEY_ESCAPE)


## 比较菜单与实际选项边缘，覆盖右对齐文字、父级缩放和画幅约束。
func _check_anchor_alignment(option: OptionButton, context: String) -> void:
	var popup := option.get_popup()
	var popup_to_root := root.get_screen_transform().affine_inverse() * popup.get_screen_transform()
	var menu_bounds := popup_to_root * popup.get_visible_rect()
	var anchor := option.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, option.size)
	var available := root.get_visible_rect().grow(-8.0)
	if anchor.end.x <= available.end.x and anchor.end.x - menu_bounds.size.x >= available.position.x:
		_check(absf(menu_bounds.end.x - anchor.end.x) <= 1.1, "菜单右边缘对齐当前选项，短文字菜单不落在整行左端 " + option.name + " " + context)
	if anchor.end.y + menu_bounds.size.y <= available.end.y:
		_check(absf(menu_bounds.position.y - anchor.end.y) <= 1.1, "下方有空间时菜单紧接当前选项下方 " + option.name + " " + context)
	_check(available.grow(1.1).encloses(menu_bounds), "菜单保持完整且不超出窗口 " + option.name + " " + context)


## 只有保存项保留原生选中语义，确保视觉替换不变成多选或取消选中。
func _check_checked(popup: PopupMenu, expected: int, context: String) -> void:
	var checked: Array[int] = []
	for index in popup.item_count:
		if popup.is_item_checked(index):
			checked.append(index)
	_check(checked == [expected], "唯一勾选对应已保存设置 " + context + " actual=" + str(checked))


## 使用真实键盘选择并重开菜单；代码提示和语言的显示名不参与保存值。
func _check_submission(node_name: String, target: int) -> void:
	var option := _game.settings_panel.find_child(node_name, true, false) as OptionButton
	var popup := option.get_popup()
	await _open_option(option)
	for step in popup.item_count:
		if popup.get_focused_item() == target:
			break
		await _key(root, KEY_UP if popup.get_focused_item() > target else KEY_DOWN)
	_check(popup.get_focused_item() == target, "原生方向键可达目标项 " + node_name)
	await _key(root, KEY_ENTER)
	await _settle(10)
	_check(option.selected == target and not popup.visible, "回车提交并关闭 " + node_name)
	await _open_option(option)
	_check_checked(popup, target, node_name + " 提交后重新打开")
	await _check_blue_selection(popup, node_name + " 提交后重新打开")
	await _capture("checkmark_committed_" + node_name)
	await _key(root, KEY_ESCAPE)


## 保留真实禁用项跳过行为，临时禁用只作用于测试菜单，不触及数据模型。
func _check_disabled_skip() -> void:
	_game.settings.set_language("zh_CN")
	await _settle(6)
	var option := _game.settings_panel.find_child("LanguageOption", true, false) as OptionButton
	option.set_item_disabled(1, true)
	await _open_option(option)
	await _key(root, KEY_DOWN)
	_check(option.get_popup().get_focused_item() == 2 and option.selected == 0, "勾选样式保留方向键跳过禁用项")
	await _key(root, KEY_ESCAPE)
	option.set_item_disabled(1, false)


## 滚动正文使按钮可达，再从控件的真实焦点打开菜单。
func _open_option(option: OptionButton) -> void:
	_game.settings_panel._scroll.ensure_control_visible(option)
	await _settle(6)
	option.grab_focus()
	await _key(root, KEY_SPACE)
	await _settle(10)


## 向实际弹层客户区发送鼠标移动，确认没有点击时不会提交任何选项。
func _hover_menu(popup: PopupMenu, local_point: Vector2) -> void:
	var point := root.get_screen_transform().affine_inverse() * popup.get_screen_transform() * local_point
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(point)
		await _settle(3)
	var event := InputEventMouseMotion.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	event.relative = Vector2(12, 12)
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _settle(6)


## 鼠标打开与键盘打开同样首先突出已保存项，不要求玩家先移动方向键。
func _check_pointer_open(node_name: String) -> void:
	var option := _game.settings_panel.find_child(node_name, true, false) as OptionButton
	_game.settings_panel._scroll.ensure_control_visible(option)
	await _settle(6)
	await _click(option)
	await _settle(10)
	var popup := option.get_popup()
	_check(popup.visible and popup.get_focused_item() == option.selected, "鼠标打开时直接高亮已保存项 " + node_name)
	_check_checked(popup, option.selected, node_name + " 鼠标打开")
	_check_anchor_alignment(option, "鼠标打开")
	await _check_blue_selection(popup, node_name + " 鼠标打开")
	await _capture("checkmark_pointer_" + node_name)
	await _key(root, KEY_ESCAPE)


## 从实际菜单纹理识别蓝色条和其左侧白色勾选，避免只验证主题字段而漏掉渲染缺失。
func _check_blue_selection(popup: PopupMenu, context: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var rendered := popup.get_texture().get_image()
	var blue_rows: Array[int] = []
	for y in rendered.get_height():
		var blue_count := 0
		for x in range(0, rendered.get_width(), 2):
			var color := rendered.get_pixel(x, y)
			if color.a > 0.75 and color.b > 0.75 and color.b > color.r + 0.2 and color.b > color.g + 0.08:
				blue_count += 1
		if blue_count > rendered.get_width() * 0.20:
			blue_rows.append(y)
	if not _check(blue_rows.size() >= 5, "真实菜单纹理含蓝色选中行 " + context):
		return
	var top: int = blue_rows.front()
	var bottom: int = blue_rows.back()
	var white_count := 0
	var mark_limit := mini(roundi(26 * popup.content_scale_factor), rendered.get_width() / 3)
	for y in range(top, bottom + 1):
		for x in range(0, mark_limit):
			var color := rendered.get_pixel(x, y)
			if color.a > 0.85 and color.r > 0.9 and color.g > 0.9 and color.b > 0.9:
				white_count += 1
	_check(white_count >= 3, "选中行左侧实际绘制白色勾选 " + context + " pixels=" + str(white_count))


## 输出专用结束标记，清理隔离文件和语言音量状态沿用通用界面夹具。
func _finish() -> void:
	if not _finished:
		print("SETTINGS_OPTION_CHECKMARK_TESTS: %d checks, %d failures" % [_checks, _failures])
	super._finish()
