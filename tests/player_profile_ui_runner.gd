extends SceneTree
## 玩家设置界面使用隔离档案和系统替身，检查真实控件、输入、统计刷新与删除确认。

var _checks := 0
var _failures := 0
var _directory := ""
var _fixture: Control
var _panel: PlayerProfilePanel
var _settings_panel: SettingsPanel
var _profile: PlayerProfileStore
var _font_scale: GameFontScale
var _dialog: PlayerProfileResetDialog
var _native_requests: Array[Dictionary] = []
var _native_result := OK
var _immediate_choice := -999
var _confirm_count := 0
var _cancel_count := 0
var _reset_count := 0
var _entry_count := 0
var _capture_directory := ""


## 根视口建立后再挂入真实控件，可选导出 GPU 截图用于人工外观确认。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 所有写盘位于专属目录，结束时恢复语言并删除测试文件。
func _run() -> void:
	_directory = "user://tests/player_profile_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	GameI18n.install()
	TranslationServer.set_locale("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_profile = PlayerProfileStore.new(_directory.path_join("profile.json"))
	_check(_profile.load_profile().is_ok(), "界面夹具档案初始化成功")
	_fixture = Control.new()
	_fixture.theme = GameTheme.create_theme()
	root.add_child(_fixture)
	_fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font_scale = GameFontScale.new()
	_font_scale.scope = _fixture
	_fixture.add_child(_font_scale)
	_panel = PlayerProfilePanel.new()
	_panel.profile = _profile
	_panel.reset_requested.connect(func() -> void: _reset_count += 1)
	_fixture.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font_scale.layout_check = _panel._layout_card
	await _settle()
	await _test_fields()
	await _test_uid_menu()
	await _test_statistics()
	await _test_layout()
	await _test_settings_entry()
	await _test_native_dialog()
	_fixture.queue_free()
	await _settle()
	TranslationServer.set_locale(original_locale)
	_cleanup(_directory)
	print("PLAYER_PROFILE_UI_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 输入栏右对齐且保持原生光标，粘贴过滤按 Unicode 字符限长，不改 UID。
func _test_fields() -> void:
	var name := _panel._username_field
	var uid := _profile.get_uid()
	_check(name.text == "Player" and name.alignment == HORIZONTAL_ALIGNMENT_RIGHT and name.caret_blink and is_equal_approx(name.caret_blink_interval, 0.5), "默认 Player 右对齐，输入使用闪烁光标")
	_check(not _panel._uid_field.editable and _panel._uid_field.text == uid and _panel._uid_field.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "UID 只读且右对齐")
	await _type(name, "1234567890🐬甲乙丙")
	_check(name.text == "1234567890甲" and name.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "长名字过滤 emoji 后最多 11 字符，编辑时仍右对齐")
	_check(_profile.get_username() == "Player", "未提交的输入不抢先改动档案")
	_check(_panel.commit_username() and _profile.get_username() == name.text and _profile.get_uid() == uid, "提交姓名会持久保存但 UID 保持不变")
	await _type(name, "小海豚👨‍👩‍👧‍👦🇨🇳👍🏽❤️\n")
	_check(name.text == "小海豚", "Apple 标志和普通、组合 emoji 与换行全部被过滤")
	_check(_panel.commit_username() and _profile.get_username() == "小海豚", "普通中文名字正常提交")
	await _type(name, "")
	_check(name.text.is_empty(), "删除文字时允许空输入临时存在")
	name.text_submitted.emit(name.text)
	await _settle()
	_check(name.text == "Player" and _profile.get_username() == "Player", "提交空白用户名恢复 Player")
	name.grab_focus()
	await _settle()
	var before := _profile.get_username()
	_profile.record_hint_use()
	_check(name.has_focus() and name.text == before, "统计刷新不意外改变输入焦点")
	_panel._uid_field.grab_focus()
	_key(KEY_A, "Z".unicode_at(0))
	await _settle()
	_check(_panel._uid_field.text == uid and _profile.get_uid() == uid, "原生键盘输入不能更改只读 UID")
	await _type(name, "New Name")
	_click(Vector2(20, 20))
	await _settle()
	_check(not name.has_focus() and _profile.get_username() == "New Name", "点击卡片空白处真正释放输入焦点并提交")
	_panel._delete_button.pressed.emit()
	await _settle()
	_check(_reset_count == 1 and _profile.get_uid() == uid, "删除按钮只请求确认，不自行删除档案")
	_check(_panel._delete_button.get_theme_color("font_color") == Color("9d1414") and _panel._delete_button.get_theme_stylebox("focus") is StyleBoxEmpty, "删除按钮使用指定红字且鼠标操作不留下蓝框")
	if DisplayServer.get_name() != "headless":
		var clipboard := DisplayServer.clipboard_get()
		name.grab_focus()
		name.select_all()
		DisplayServer.clipboard_set("Paste🐬名字")
		_key(KEY_V, 0, true)
		await _settle()
		_check(name.text == "Paste名字" and name.alignment == HORIZONTAL_ALIGNMENT_RIGHT, "真实系统剪贴板粘贴也过滤不支持的字符")
		DisplayServer.clipboard_set(clipboard)
		_panel.commit_username()


## 真实右键只打开复制菜单，局部选区仍复制完整 UID，取消不穿透删除按钮。
func _test_uid_menu() -> void:
	var field := _panel._uid_field
	var menu := _panel._uid_menu
	_check(_panel._username_field.get_theme_stylebox("focus") is StyleBoxEmpty and field.get_theme_stylebox("focus") is StyleBoxEmpty, "用户名和 UID 聚焦均不绘制蓝色边框")
	_check(not field.context_menu_enabled, "UID 不使用系统编辑菜单")
	var copied := [0]
	menu.copy_requested.connect(func() -> void: copied[0] += 1)
	if DisplayServer.get_name() == "headless":
		menu.copy_requested.disconnect(_panel._copy_uid)
	var clipboard := DisplayServer.clipboard_get() if DisplayServer.get_name() != "headless" else ""
	field.select(0, 3)
	_mouse_click(field.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(menu.is_open() and not field.get_menu().visible and menu._copy_button.text == "复制 UID", "右键显示单项复制 UID 玻璃菜单，没有原生菜单")
	_check(menu._panel.get_child_count() == 2 and menu._glass.material is ShaderMaterial, "菜单只包含玻璃背景与复制按钮")
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(menu._panel.get_global_rect()), "复制菜单限制在屏幕边界内")
	if not _capture_directory.is_empty() and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(_capture_directory)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(_capture_directory.path_join("player_uid_menu.png"))
	_click(menu._copy_button.get_global_rect().get_center())
	await _settle()
	_check(not menu.is_open() and copied[0] == 1 and field.has_focus(), "点击复制只触发一次并关闭菜单、恢复 UID 焦点")
	if DisplayServer.get_name() != "headless":
		_check(DisplayServer.clipboard_get() == _profile.get_uid(), "系统剪贴板得到完整 UID，而非选中的前三位")
		DisplayServer.clipboard_set(clipboard)
	_key(KEY_MENU)
	await _settle()
	_check(menu.is_open(), "键盘菜单键同样打开复制 UID")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not menu.is_open() and copied[0] == 1, "Esc 关闭不复制或修改资料")
	_mouse_click(field.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _settle()
	var reset_count := _reset_count
	_click(_panel._delete_button.get_global_rect().get_center())
	await _settle()
	_check(not menu.is_open() and _reset_count == reset_count, "菜单外部点击只关闭，不穿透触发删除档案")
	menu.popup_at(field, Vector2(root.size) - Vector2.ONE)
	await _settle()
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(menu._panel.get_global_rect()), "右下角打开会自动移回屏幕内")
	_panel.hide()
	await _settle()
	_check(not menu.is_open(), "隐藏页面同步关闭独立画布菜单")
	_panel.show()
	await _settle()


## 统计栏由同一持久模型实时更新，不伪造没有完成记录的耗时或通过率。
func _test_statistics() -> void:
	_check(_panel._rate_value.text == "—" and _panel._fastest_value.text == "—" and _panel._longest_value.text == "—", "无统计记录时通过率和耗时显示横线")
	_check(_panel._play_time_value.text == "0.0小时" and _panel._mystery_value.text == "0" and not _panel._mystery_row.visible and not _panel._mystery_divider.visible, "新档案显示零小时，未知栏目及前分隔线默认隐藏")
	_check(_profile.record_shark_discovery().is_ok(), "首次零分触发持久发现状态")
	await _settle()
	_check(_panel._mystery_row.visible and _panel._mystery_divider.visible and _panel._mystery_value.text == "0", "首次发现通过变更信号立即显示未知零分与分隔线")
	var restarted := PlayerProfileStore.new(_profile.storage_path)
	var rebuilt := PlayerProfilePanel.new()
	_check(restarted.load_profile().is_ok(), "页面重建夹具从磁盘重新读取零分发现")
	rebuilt.profile = restarted
	_fixture.add_child(rebuilt)
	rebuilt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	_check(rebuilt._mystery_row.visible and rebuilt._mystery_divider.visible and rebuilt._mystery_value.text == "0", "重启后重建面板保留零分解锁状态")
	rebuilt.queue_free()
	await _settle()
	_profile.record_play_time(23.2 * 3600.0)
	_profile.record_shark_score(321)
	await _settle()
	_check(_panel._play_time_value.text == "23.2小时" and _panel._mystery_value.text == "321", "新统计同步显示一位小数小时与最高分")
	var hint_row := _panel.find_child("PlayerHintsRow", true, false) as Control
	var time_row := _panel.find_child("PlayerPlayTimeRow", true, false) as Control
	var mystery_row := _panel.find_child("PlayerMysteryRow", true, false) as MarginContainer
	var longest_row := _panel.find_child("PlayerLongestRow", true, false) as Control
	var mystery_caption := (mystery_row.get_child(0) as HBoxContainer).get_child(0) as Label
	var first_run_row := _panel.find_child("PlayerFirstRunRow", true, false) as MarginContainer
	_check(time_row.get_index() == hint_row.get_index() + 2 and first_run_row.get_index() == longest_row.get_index() + 2 and mystery_row.get_index() == first_run_row.get_index() + 2, "游戏时间位于提示次数正下方，首次运行日期位于最长耗时与未知最高分之间")
	_check(mystery_caption.text == "？？？" and mystery_caption.tooltip_text.is_empty() and _panel._mystery_value.tooltip_text.is_empty(), "未知栏标题与悬停均不暴露彩蛋名字")
	_profile.record_failure("ui_failed", "none")
	_profile.record_completion(75.0, "ui_75", "none", 9)
	_profile.record_completion(1427.0, "ui_1427", "none", 9)
	_profile.record_completion(60.0, "ui_60", "none", 9)
	await _settle()
	_check(float(_panel._rate_value.text.trim_suffix("%")) == 75.0 and _panel._hint_value.text == str(_profile.get_statistics().code_hint_uses), "通过率按逐关成功权重除以真实尝试计算，提示次数实时更新")
	_check(_panel._fastest_value.text == "1分0秒" and _panel._longest_value.text == "23分47秒", "最短最长耗时按真实秒数格式化")
	await _type(_panel._username_field, "Typing")
	_profile.record_hint_use()
	await _settle()
	_check(_panel._username_field.text == "Typing", "模型其他统计变化不覆盖尚未提交的姓名输入")
	_panel.commit_username()
	for locale: String in ["zh_CN", "zh_HK", "en"]:
		TranslationServer.set_locale(locale)
		await _settle()
		_check(_panel._username_field.text == "Typing" and _panel._uid_field.text == _profile.get_uid(), "切换语言保留姓名与 UID " + locale)
		_check(_panel._fastest_value.text == _panel.tr("%d分%d秒") % [1, 0], "时间单位按当前语言显示 " + locale)
		_check(_panel._play_time_value.text == _panel.tr("%s小时") % "23.2" and mystery_caption.text == "？？？" and _panel._mystery_value.text == "321" and _panel._mystery_row.visible and _panel._mystery_divider.visible, "小时单位本土化，未知栏目、分数和发现状态保持原样 " + locale)
	_panel.show_result(DataResult.failure("玩家档案 JSON 损坏，原文件保持不变。"))
	_check(_panel._status.visible and _panel._status.text == _panel.tr("玩家档案 JSON 损坏，原文件保持不变。"), "档案错误在页内显示本土化原因")
	_panel.show_result(DataResult.success())
	_check(not _panel._status.visible, "成功结果清除已过期错误")
	TranslationServer.set_locale("zh_CN")
	_check(restarted.reset_profile().is_ok(), "独立重启实例成功清空档案")
	_check(_profile.load_profile().is_ok(), "活动面板重新载入重置后档案")
	await _settle()
	_check(not _panel._mystery_row.visible and not _panel._mystery_divider.visible and _panel._mystery_value.text == "0", "重置后未知统计与分隔线再次隐藏")


## 三种字体缩放与窗口尺寸均保留八成正文，不让输入值或统计栏越过右边界。
func _test_layout() -> void:
	for percentage: int in [100, 150, 200]:
		_font_scale.set_percentage(percentage)
		for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			await _settle()
			_check(_panel._scroll.scale.is_equal_approx(Vector2.ONE * 0.8), "正文统一沿用八成显示比例")
			_check(_panel._scroll.get_global_rect().end.x <= root.size.x + 1 and _panel._username_field.get_global_rect().end.x <= _panel._scroll.get_global_rect().end.x, "输入与正文不超出窗口右边界 %d %s" % [percentage, dimensions])
			_check(_panel._username_field.get_theme_font_size("font_size") == roundi(16.0 * percentage / 100.0), "用户名随统一字体缩放显示")
			_panel._scroll.scroll_vertical = 0
			await _settle()
			_check(_panel._username_field.get_global_rect().position.y >= 48.0, "输入栏首屏避开顶部渐隐带")
	_font_scale.set_percentage(100)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _settle()
	if not _capture_directory.is_empty() and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(_capture_directory)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(_capture_directory.path_join("player_profile.png"))


## 设置入口位于基本分类第一组，真实按钮把导航意图交给外壳。
func _test_settings_entry() -> void:
	_panel.hide()
	_settings_panel = SettingsPanel.new()
	_settings_panel.settings = GameSettings.new(_directory.path_join("settings.json"))
	_settings_panel.player_profile_requested.connect(func() -> void: _entry_count += 1)
	_fixture.add_child(_settings_panel)
	_settings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	var button := _settings_panel.find_child("PlayerProfileButton", true, false) as Button
	_check(button != null and button.text == "玩家与统计信息" and button.icon != null, "玩家与统计信息入口使用现有披露箭头样式")
	var basic := _settings_panel.find_child("BasicSectionTitle", true, false) as Control
	var sound := _settings_panel.find_child("SoundSectionTitle", true, false) as Control
	_check(basic.get_global_rect().position.y < sound.get_global_rect().position.y, "基本分类位于音效分类之前")
	button.pressed.emit()
	_check(_entry_count == 1, "入口按钮发送独立玩家档案导航信号")
	_settings_panel.queue_free()
	await _settle()
	_panel.show()


## 系统替身覆盖取消、关闭、确认、重复点击、迟到回调与失败后备，不真实清空玩家数据。
func _test_native_dialog() -> void:
	_dialog = PlayerProfileResetDialog.new()
	_dialog.native_dialog_handler = _record_native
	_dialog.confirmed.connect(func() -> void: _confirm_count += 1)
	_dialog.canceled.connect(func() -> void: _cancel_count += 1)
	_fixture.add_child(_dialog)
	await _settle()
	for locale: String in ["zh_CN", "zh_HK", "en"]:
		TranslationServer.set_locale(locale)
		_dialog.open_confirmation()
		var request: Dictionary = _native_requests[-1]
		_check(_dialog.is_open() and _dialog._native_active and not _dialog._fallback.visible, "原生模式不叠加绘制游戏确认窗 " + locale)
		_check(request.buttons == PackedStringArray([_dialog.tr("取消"), _dialog.tr("删除玩家档案")]) and request.description == _dialog._description(), "本土化取消在系统首位，说明重置 UID 并保留关卡 " + locale)
		var count := _native_requests.size()
		_dialog.open_confirmation()
		_check(_native_requests.size() == count, "重复点击只保留当前一个询问")
		request.callback.call(0)
		_check(_dialog.is_open(), "系统同步响应延后到模态窗口关闭后执行")
		await _settle()
		_check(not _dialog.is_open() and _confirm_count == 0, "原生取消不发出删除确认")
	_dialog.open_confirmation()
	var obsolete: Callable = _native_requests[-1].callback
	obsolete.call(-1)
	await _settle()
	_check(not _dialog.is_open() and _confirm_count == 0, "关闭或未知原生结果视为取消")
	_dialog.open_confirmation()
	obsolete.call(1)
	await _settle()
	_check(_dialog.is_open() and _confirm_count == 0, "旧确认迟到回调不能影响新询问")
	_native_requests[-1].callback.call(1)
	await _settle()
	_check(not _dialog.is_open() and _confirm_count == 1, "只有当前原生删除按钮发出一次确认")
	_dialog.open_confirmation()
	var externally_closed: Callable = _native_requests[-1].callback
	_dialog.close_dialog()
	externally_closed.call(1)
	await _settle()
	_check(not _dialog.is_open() and _confirm_count == 1, "页面关闭令旧原生删除回调失效")
	_native_result = FAILED
	_dialog.open_confirmation()
	await _settle()
	_check(_dialog.is_open() and not _dialog._native_active and _dialog._fallback.visible, "系统调用失败仍提供后备确认窗口")
	_check(_dialog._fallback.get_cancel_button().has_focus(), "后备询问默认焦点为取消")
	_native_requests[-1].callback.call(1)
	await _settle()
	_check(_dialog.is_open() and _confirm_count == 1, "失败接口的迟到确认不能绕过后备窗")
	_dialog._fallback.canceled.emit()
	await _settle()
	_check(not _dialog.is_open() and _confirm_count == 1, "后备取消保留资料")
	_native_result = OK
	_immediate_choice = 1
	_dialog.open_confirmation()
	_check(_dialog.is_open() and _confirm_count == 1, "即时系统回调也延后确认")
	await _settle()
	_check(not _dialog.is_open() and _confirm_count == 2 and _cancel_count >= 6, "即时删除响应只发出一次确认")


## 仅记录原生系统边界，供测试显式选择回调与接口失败。
func _record_native(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_native_requests.append({"title": title, "description": description, "buttons": buttons, "callback": callback})
	if _immediate_choice != -999:
		callback.call(_immediate_choice)
	return _native_result


## 借助真实 LineEdit 输入通知模拟一次完整粘贴，同时保留光标位置规则。
func _type(field: LineEdit, text: String) -> void:
	field.grab_focus()
	field.text = text
	field.caret_column = text.length()
	field.text_changed.emit(text)
	await _settle()


## 空白处原生鼠标输入触发焦点退出，与直接调用提交方法分开检查。
func _click(point: Vector2) -> void:
	_mouse_click(point, MOUSE_BUTTON_LEFT)


## 向真实视口发送完整左右键点击，覆盖自定义菜单的原生命中链。
func _mouse_click(point: Vector2, button: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event, true)


## 原生键盘输入覆盖只读字段与真实系统剪贴板，不直接修改模型。
func _key(code: Key, unicode: int = 0, modifier: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.unicode = unicode
		event.pressed = pressed
		event.meta_pressed = modifier and OS.get_name() == "macOS"
		event.ctrl_pressed = modifier and OS.get_name() != "macOS"
		root.push_input(event, true)


## 等待原生容器、字体控制器和延后系统回调稳定，不固定等待用户交互。
func _settle() -> void:
	for _index in range(6):
		await process_frame


## 记录断言并继续检查独立路径，让失败日志保留完整复现信息。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("PLAYER_PROFILE_UI_TEST: " + message)
	return condition


## 只删除本测试创建的目录，档案重置回归不会接触正式地图或玩家文件。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	for child in directory.get_files():
		directory.remove(child)
	DirAccess.remove_absolute(path)
