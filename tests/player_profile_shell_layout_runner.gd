extends "res://tests/window_resolution_ui_runner.gd"
## 真实玩家设置页面回归；Windows 画像只替换能力查询，不冒充实际 Windows 桌面。

var _screen_profile := Vector2i(3840, 2160)
var _original_transparent := false


## 基准与 UHD 通过同一真实入口，四种语言和字号检查白卡、值栏、渐隐与键盘滚动。
func _run() -> void:
	_temporary = "user://tests/player_profile_shell_layout_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_check(_game.profile.set_username("YWMKerman").is_ok() and _game.profile.record_hint_use().is_ok() and _game.profile.record_completion(75.0).is_ok() and _game.profile.record_completion(1427.0).is_ok() and _game.profile.record_failure().is_ok() and _game.profile.record_play_time(23.2 * 3600.0).is_ok(), "准备独立姓名与统计展示夹具，默认未触发未知栏目")
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = _profile_screen_size
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()
	await _settle(12)
	_game.settings.set_window_resolution("1280x800")
	_game.settings.set_ui_scale(100)
	_game.settings.set_language("zh_CN")
	await _check_profile_route("default_hidden_1280x800_100_zh_CN", 100)
	_check(not _game.player_profile_panel._mystery_row.visible and not _game.player_profile_panel._mystery_divider.visible, "正式档案页面默认隐藏未知栏目和前分隔线")
	await _capture("player_profile_shell_default_hidden_1280x800_100_zh_CN")
	_check(_game.profile.record_shark_discovery().is_ok(), "首次零分触发持久化发现标记")
	await _settle(12)
	_check(_game.player_profile_panel._mystery_row.visible and _game.player_profile_panel._mystery_divider.visible and _game.player_profile_panel._mystery_value.text == "0", "正式页面首次发现即时显示零分未知栏目")
	await _capture("player_profile_shell_discovered_zero_1280x800_100_zh_CN")
	_check(_game.profile.record_shark_score(456).is_ok(), "解锁后准备独立非零最高分展示")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(3840, 2160)]:
		var value := "%dx%d" % [dimensions.x, dimensions.y]
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(value):
			print("SKIP 玩家档案原生 GPU 尺寸 %s：宿主显示器不能容纳该客户区，4K 几何由 headless 验证。" % value)
			continue
		for percentage: int in [100, 150, 200]:
			_game.settings.set_ui_scale(percentage)
			_game.settings.set_window_resolution(value)
			await _settle(12)
			for locale: String in ["zh_CN", "zh_HK", "es", "en"]:
				_game.settings.set_language(locale)
				_game._show_main_page()
				await _settle(12)
				var context := "%s_%d_%s" % [value, percentage, locale]
				await _check_profile_route(context, percentage)
				if percentage == 100 and dimensions == Vector2i(1280, 800) and locale in ["zh_CN", "es", "en"]:
					await _capture("player_profile_shell_" + context)
				elif percentage == 200 and dimensions == Vector2i(3840, 2160) and locale == "zh_CN":
					await _capture("player_profile_shell_" + context)
				await _check_keyboard_visibility(context)
				await _click(_game._back_button)
				_check(_game.page == GameShell.Page.SETTINGS, "玩家资料返回设置 " + context)
				await _click(_game._back_button)
				_check(_game.page == GameShell.Page.MAIN, "设置返回主菜单 " + context)
	await _check_real_input()
	await _dispose_game()
	_check(root.transparent_bg == _original_transparent, "释放最后一张玩家资料页后恢复视口透明状态")
	_finish()


## 设置、档案、草稿和关卡四种持久数据均指向本次独占目录。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("profile.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle(12)


## 返回完整 UHD 能力尺寸，只读画像不会改变宿主系统分辨率。
func _profile_screen_size() -> Vector2i:
	return _screen_profile


## 点击主菜单和基本分类正式按钮，确认两个页面持续复用同一白卡和背景。
func _check_profile_route(context: String, percentage: int) -> void:
	if not await _open_settings():
		return
	await _settle(12)
	var card := _game._menu_card
	var card_rect := card.get_global_rect()
	var background := _game._main_background
	var basic := _game.settings_panel.find_child("BasicSectionTitle", true, false) as Control
	var sound := _game.settings_panel.find_child("SoundSectionTitle", true, false) as Control
	_check(basic != null and sound != null and basic.global_position.y < sound.global_position.y, "基本分类在音效之前 " + context)
	var entry := _game.settings_panel.find_child("PlayerProfileButton", true, false) as Button
	if not _check(entry != null, "玩家档案真实入口存在 " + context):
		return
	await _click(entry)
	await _settle(12)
	if not _check(_game.page == GameShell.Page.PLAYER_PROFILE and is_instance_valid(_game.player_profile_panel), "真实入口打开玩家资料页 " + context):
		return
	var panel := _game.player_profile_panel
	_check(_game._menu_card == card and card.get_global_rect().is_equal_approx(card_rect) and _game._main_background == background and background._active, "玩家资料共用原白卡、矩形与菜单背景 " + context)
	_check(panel.get_parent() == card and panel.card_boundary == card and panel.navigation_title == _game._title, "资料正文注入同一白卡和真实导航边界 " + context)
	_check(_game._title.text == "玩家与统计信息" and not _game._subtitle.visible, "页头使用玩家资料标题 " + context)
	var bounds := panel._scroll.get_global_rect()
	_check(absf(bounds.position.y - card_rect.position.y) <= 1.0 and absf(bounds.end.y - card_rect.end.y) <= 1.0, "正文从白卡顶端到下缘使用统一渐隐边界 " + context)
	_check(root.get_visible_rect().grow(1.0).encloses(bounds), "正文视口不超出实际窗口 " + context)
	_check(is_equal_approx(panel._scroll.get_global_transform().get_scale().x, card.scale.x * 0.8), "正文八成比例叠加白卡高分辨率比例 " + context)
	var title := _game._title
	var title_width := title.get_theme_font("font").get_string_size(title.tr(title.text), HORIZONTAL_ALIGNMENT_LEFT, -1, title.get_theme_font_size("font_size")).x
	var title_right := title.get_global_transform_with_canvas() * Vector2(title_width, 0.0)
	_check(bounds.position.x >= title_right.x + 15.0 * card.scale.x, "正文避让本土化导航文字 " + context)
	var identity := panel.find_child("PlayerIdentityGroup", true, false) as Control
	var stats := panel.find_child("PlayerStatisticsGroup", true, false) as Control
	_check(identity.get_global_rect().end.y < stats.get_global_rect().position.y and stats.get_global_rect().end.y < panel._delete_button.get_global_rect().position.y, "身份、统计和删除按钮按分组顺序显示 " + context)
	for field: LineEdit in [panel._username_field, panel._uid_field]:
		_check(identity.get_global_rect().grow(1.0).encloses(field.get_global_rect()) and field.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "资料值栏留在灰卡中并右对齐 " + context + " " + field.name)
		_check(field.get_theme_font_size("font_size") == roundi(16.0 * percentage / 100.0), "资料值使用真实统一字体字号 " + context + " " + field.name)
	var uid := panel._uid_field
	var uid_width := uid.get_theme_font("font").get_string_size(uid.text, HORIZONTAL_ALIGNMENT_RIGHT, -1, uid.get_theme_font_size("font_size")).x
	_check(not uid.editable and uid_width <= uid.size.x - uid.get_theme_stylebox("read_only").get_minimum_size().x + 1.0, "完整 13 位 UID 可读且不能编辑 " + context)
	_check(panel._username_field.text == _game.profile.get_username() and panel._username_field.caret_blink, "姓名显示原文并保留闪烁光标 " + context)
	for row_name: String in ["PlayerHintsRow", "PlayerPlayTimeRow", "PlayerPassRateRow", "PlayerFastestRow", "PlayerLongestRow", "PlayerMysteryRow"]:
		var row := panel.find_child(row_name, true, false) as MarginContainer
		var body := row.get_child(0) as HBoxContainer
		var caption := body.get_child(0) as Label
		var value := body.get_child(1) as Label
		if row_name == "PlayerMysteryRow":
			_check(row.visible == bool(_game.profile.get_statistics().shark_discovered) and panel._mystery_divider.visible == row.visible, "未知栏目和分隔线随真实发现状态显示 " + context)
			if not row.visible:
				continue
		_check(stats.get_global_rect().grow(1.0).encloses(row.get_global_rect()) and row.get_global_rect().grow(1.0).encloses(caption.get_global_rect()) and row.get_global_rect().grow(1.0).encloses(value.get_global_rect()), "统计文字与数值完整留在分组内 " + context + " " + row_name)
		_check(caption.get_global_rect().end.x <= value.get_global_rect().position.x and caption.size.y >= caption.get_theme_font("font").get_height(caption.get_theme_font_size("font_size")), "统计说明与右侧数值不重叠且有完整行高 " + context + " " + row_name)
	_check(panel._delete_button.get_theme_color("font_color") == Color("9d1414"), "删除档案字色符合指定值 " + context)


## 键盘从页尾回到姓名、再到删除按钮，原生焦点滚动必须避开导航和透明边缘。
func _check_keyboard_visibility(context: String) -> void:
	if not is_instance_valid(_game.player_profile_panel):
		return
	var panel := _game.player_profile_panel
	panel._scroll.scroll_vertical = 100000
	await _settle(12)
	await _key(root, KEY_TAB)
	panel._username_field.release_focus()
	panel._username_field.grab_focus()
	await _settle(12)
	_check_focus_visible(panel._username_field, panel, context + " 姓名")
	panel._delete_button.grab_focus()
	await _settle(12)
	_check_focus_visible(panel._delete_button, panel, context + " 删除")
	panel._scroll.scroll_vertical = 0
	panel._delete_button.release_focus()
	await _settle(8)


## 以玩家实际可读范围检查焦点控件，不只检查未遮罩的原始矩形。
func _check_focus_visible(control: Control, panel: PlayerProfilePanel, context: String) -> void:
	var bounds := panel._scroll.get_global_rect()
	var factor := absf(panel.get_global_transform().get_scale().y)
	var safe := Rect2(Vector2(bounds.position.x, bounds.position.y + SettingsContentFade.CARD_FOCUS_TOP_INSET * factor), Vector2(bounds.size.x, bounds.size.y - (SettingsContentFade.CARD_FOCUS_TOP_INSET + SettingsContentFade.TOP_FADE_WIDTH + 8.0) * factor))
	_check(control.has_focus() and safe.grow(1.0).encloses(control.get_global_rect()), "键盘焦点位于完全可读区域 " + context)


## 真正 OS 剪贴板输入仅在 GPU 运行测试，结束时恢复原剪贴板；headless 仍验证键盘与失焦。
func _check_real_input() -> void:
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution("1280x800")
	_game.settings.set_language("zh_CN")
	_game._show_player_profile_page()
	await _settle(12)
	var panel := _game.player_profile_panel
	var name := panel._username_field
	var uid := _game.profile.get_uid()
	await _click(name)
	_check(name.has_focus(), "原生鼠标点击姓名栏获得输入焦点")
	if DisplayServer.get_name() != "headless":
		var previous_clipboard := DisplayServer.clipboard_get()
		name.select_all()
		DisplayServer.clipboard_set("玩家🐬名字")
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = KEY_V
			event.physical_keycode = KEY_V
			event.pressed = pressed
			event.meta_pressed = OS.get_name() == "macOS"
			event.ctrl_pressed = OS.get_name() != "macOS"
			root.push_input(event, true)
		await _settle(8)
		_check(name.text == "玩家名字" and name.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "实际系统粘贴过滤表情同时保留右对齐")
		DisplayServer.clipboard_set(previous_clipboard)
	var point := _game._menu_card.get_global_rect().position + Vector2(20, 200) * _game._menu_card.scale
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
	await _settle(8)
	_check(not name.has_focus() and _game.profile.get_username() == name.text and _game.profile.get_uid() == uid, "实际白卡空白点击提交姓名并释放焦点，UID 不改变")


## 保留本运行专属结束标记，报告真实几何验证与明确跳过的宿主 GPU 尺寸。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	TranslationServer.set_locale(_original_locale)
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	_remove_tree(_temporary)
	print("PLAYER_PROFILE_SHELL_LAYOUT_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
