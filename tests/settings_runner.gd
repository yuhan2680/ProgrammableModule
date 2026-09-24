extends SceneTree
## 设置独立回归：只使用独占测试目录，并在结束时恢复全局音量与语言状态。

var _checks: int = 0
var _failures: int = 0
var _test_root: String = ""
var _changed_count: int = 0
var _original_locale: String
var _original_db: float
var _original_mute: bool


## 等场景树完成初始化后执行，确保音频总线与原生控件可用。
func _initialize() -> void:
	_run.call_deferred()


## 依次检查真实文件、引擎服务器与面板交互，不使用玩家的 settings.json。
func _run() -> void:
	_test_root = "user://tests/settings_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_db = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	# 其它内容包可先注册英文，项目词典仍必须独立安装。
	var foreign_translation := Translation.new()
	foreign_translation.locale = "en"
	foreign_translation.add_message("external marker", "External translation stays installed")
	TranslationServer.add_translation(foreign_translation)
	_test_defaults_and_round_trip()
	_test_invalid_inputs()
	_test_invalid_files()
	_test_save_failure()
	_test_code_hint_setting()
	_test_assembly_free_zoom_setting()
	_test_error_localization()
	await _test_live_translation_and_panel()
	await _test_completion_switch()
	await _test_assembly_free_zoom_switch()
	await _test_code_hint_selector()
	await _test_native_code_menu()
	AudioServer.set_bus_volume_db(master, _original_db)
	AudioServer.set_bus_mute(master, _original_mute)
	TranslationServer.set_locale(_original_locale)
	TranslationServer.remove_translation(foreign_translation)
	_remove_test_tree(_test_root)
	print("设置回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 缺失配置不自动写盘，有效修改立即影响 Master 并能跨模型重新载入。
func _test_defaults_and_round_trip() -> void:
	var path := _test_root.path_join("round_trip/settings.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	_check(settings.load_settings().is_ok(), "缺失配置使用默认值")
	_check(settings.volume == 1.0 and settings.language == "zh_CN" and settings.tab_completion and settings.code_hints == "normal", "默认音量为1、语言为简体中文、Tab补全开启")
	_check(not FileAccess.file_exists(path), "仅载入默认值不会生成配置文件")
	_check(settings.set_volume(0.25).is_ok(), "有效音量立即保存")
	var master := AudioServer.get_bus_index("Master")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(master), linear_to_db(0.25)), "音量应用到Master总线")
	_check(not AudioServer.is_bus_mute(master), "正音量取消静音")
	_check(settings.set_language("en").is_ok(), "英文设置立即保存")
	_check(TranslationServer.get_locale() == "en", "英文立即应用到TranslationServer")
	_check(settings.set_tab_completion(false).is_ok(), "可关闭Tab补全并立即保存")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok(), "新模型能够载入已保存配置")
	_check(reloaded.volume == 0.25 and reloaded.language == "en" and not reloaded.tab_completion, "音量、语言和补全开关完整往返")
	_check(_changed_count == 4, "载入及三次有效设置各发出一次changed")
	_check(settings.set_tab_completion(true).is_ok() and reloaded.load_settings().is_ok() and reloaded.tab_completion, "重新开启Tab补全也可跨模型恢复")
	_check(settings.set_volume(0.0).is_ok(), "音量允许精确为0")
	_check(AudioServer.is_bus_mute(master), "零音量真正静音Master")
	_check(is_finite(AudioServer.get_bus_volume_db(master)), "静音时不向总线写入负无限分贝")
	_check(settings.set_volume(1.0).is_ok() and not AudioServer.is_bus_mute(master), "恢复音量后取消静音")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(master), 0.0), "满音量对应0dB")


## 布尔、字符串、无穷和超范围值都不能修改当前设置或有效磁盘文件。
func _test_invalid_inputs() -> void:
	var path := _test_root.path_join("invalid_inputs.json")
	var settings := GameSettings.new(path)
	_check(settings.set_volume(0.5).is_ok(), "先保存一份有效设置")
	var before := FileAccess.get_file_as_bytes(path)
	for value in [true, "0.5", INF, NAN, -0.01, 1.01, null]:
		_check(not settings.set_volume(value).is_ok(), "拒绝非法音量：%s" % str(value))
		_check(settings.volume == 0.5, "非法音量不改变内存值")
	for value in [true, 1, "", "fr", null]:
		_check(not settings.set_language(value).is_ok(), "拒绝不支持的语言：%s" % str(value))
		_check(settings.language == "zh_CN", "非法语言不改变内存值")
	for value in [0, 1, 0.0, "false", "true", "", null, [], {}]:
		_check(not settings.set_tab_completion(value).is_ok(), "拒绝非布尔补全值：%s" % str(value))
		_check(settings.tab_completion, "非法补全值不改变已开启状态")
	_check(FileAccess.get_file_as_bytes(path) == before, "非法输入不覆盖原配置")
	_check(not settings.last_error.is_empty(), "非法输入保留可显示的错误")
	_check(settings.set_language("en").is_ok() and settings.last_error.is_empty(), "随后成功修改清除旧错误")
	_check(not GameSettings.new("user://../outside.json").save_settings().is_ok(), "拒绝设置路径上级跳转")
	_check(not GameSettings.new("res://settings.json").save_settings().is_ok(), "不把玩家设置写入资源目录")


## 损坏语法、版本和字段都回退完整默认值，并保留文件原文供用户排查。
func _test_invalid_files() -> void:
	var invalid_sources: Array[String] = [
		"{\"audio\": invalid JSON}",
		"{\"format_version\":999,\"audio\":{\"master_volume\":0.5},\"interface\":{\"language\":\"en\"}}",
		"{\"format_version\":1,\"audio\":{\"master_volume\":true},\"interface\":{\"language\":\"en\"}}",
		"{\"format_version\":1,\"audio\":{\"master_volume\":0.5},\"interface\":{\"language\":\"fr\"}}",
		"{\"format_version\":1,\"audio\":{\"master_volume\":0.5},\"interface\":{\"language\":\"en\",\"tab_completion\":1}}",
		"{\"format_version\":1,\"audio\":{\"master_volume\":0.5},\"interface\":{\"language\":\"en\",\"tab_completion\":\"false\"}}",
		"{\"format_version\":1,\"audio\":{\"master_volume\":0.5},\"interface\":{\"language\":\"en\",\"tab_completion\":null}}",
		"{\"format_version\":1,\"audio\":false,\"interface\":{\"language\":\"zh_CN\"}}",
		"{\"format_version\":1}",
		"[]",
	]
	for index in range(invalid_sources.size()):
		var path := _test_root.path_join("bad_%d.json" % index)
		_write_text(path, invalid_sources[index])
		var settings := GameSettings.new(path)
		settings.volume = 0.3
		settings.language = "en"
		settings.tab_completion = false
		_check(not settings.load_settings().is_ok(), "坏配置返回明确错误")
		_check(settings.volume == 1.0 and settings.language == "zh_CN" and settings.tab_completion, "坏配置使用完整默认值，不部分载入")
		_check(FileAccess.get_file_as_string(path) == invalid_sources[index], "回退不会覆盖坏配置原件")
		_check(not settings.last_error.is_empty(), "读取错误可供UI显示")
	var extended_path := _test_root.path_join("extended.json")
	_write_text(extended_path, JSON.stringify({"format_version": 1, "audio": {"master_volume": 0.7, "device": "保留设备"}, "interface": {"language": "zh_CN", "font": "保留字体"}, "future": {"note": "保留"}}))
	var legacy_bytes := FileAccess.get_file_as_bytes(extended_path)
	var extended := GameSettings.new(extended_path)
	_check(extended.load_settings().is_ok() and extended.tab_completion and extended.code_hints == "normal" and extended.volume == 0.7 and extended.language == "zh_CN", "旧设置没有补全字段时默认开启，并保留已有音量和语言")
	_check(FileAccess.get_file_as_bytes(extended_path) == legacy_bytes, "载入旧设置不自动迁移或改写文件")
	_check(extended.set_tab_completion(false).is_ok() and extended.set_volume(0.8).is_ok(), "带扩展字段的旧设置可以修改补全与音量")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(extended_path))
	_check(saved.get("future", {}).get("note", "") == "保留", "保存保留未知设置章节")
	_check(saved["audio"]["device"] == "保留设备" and saved["interface"]["font"] == "保留字体", "保存保留已知分组中的未知字段")
	_check(saved["interface"]["tab_completion"] is bool and not saved["interface"]["tab_completion"], "新字段保存为真实JSON布尔值")


## 模拟不可写目录，失败仍保留即时音量，并报告尚未持久化的原因。
func _test_save_failure() -> void:
	var blocked := _test_root.path_join("blocked")
	_write_text(blocked, "目录占位文件")
	var settings := GameSettings.new(blocked.path_join("settings.json"))
	var result := settings.set_volume(0.4)
	_check(not result.is_ok() and not settings.last_error.is_empty(), "写盘失败返回错误反馈")
	_check(settings.volume == 0.4, "写盘失败保留用户已经应用的音量")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master")), linear_to_db(0.4)), "写盘失败不妨碍音量即时生效")
	_check(FileAccess.get_file_as_string(blocked) == "目录占位文件", "失败不覆盖阻挡路径中的已有文件")
	var changes_before := _changed_count
	settings.changed.connect(_on_changed)
	_check(not settings.set_tab_completion(false).is_ok() and not settings.tab_completion, "补全保存失败仍保留当前关闭选择")
	_check(_changed_count == changes_before + 1, "补全保存失败也通知编辑器立即采用本次选择")
	_check(FileAccess.get_file_as_string(blocked) == "目录占位文件", "补全保存失败不会改写阻挡文件")


## 真实控件响应语言通知及输入信号，证明设置无需重建页面或重启即可生效。
func _test_live_translation_and_panel() -> void:
	GameI18n.install()
	var before_count := TranslationServer.get_loaded_locales().size()
	GameI18n.install()
	_check(TranslationServer.get_loaded_locales().size() == before_count, "重复install不会添加重复语言资源")
	var settings := GameSettings.new(_test_root.path_join("panel.json"))
	settings.load_settings()
	var native := Label.new()
	native.text = "离开游戏"
	root.add_child(native)
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.size = Vector2(800, 600)
	root.add_child(panel)
	await process_frame
	var chinese_width := native.get_minimum_size().x
	var slider := panel.find_child("VolumeSlider", true, false) as HSlider
	var languages := panel.find_child("LanguageOption", true, false) as OptionButton
	_check(slider != null and languages != null, "设置面板建立音量滑条与语言选项")
	if slider != null and languages != null:
		slider.value = 0.0
		_check(settings.volume == 0.0 and AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")), "滑条输入直接触发静音")
		var english_index := GameSettings.SUPPORTED_LANGUAGES.find("en")
		languages.select(english_index)
		languages.item_selected.emit(english_index)
		await process_frame
		_check(settings.language == "en" and native.tr("离开游戏") == "Leave Game", "语言选项立即切换英文")
		_check(native.text == "离开游戏", "原生控件保留中文源串，玩家数据不会被改写")
		_check(not is_equal_approx(native.get_minimum_size().x, chinese_width), "原生Label收到翻译通知并重新排版")
		_check(native.tr("开始游戏") == "Start Game" and native.tr("地图编辑器") == "Map Editor" and native.tr("设置") == "Settings", "开始页四个入口都有英文翻译")
		languages.select(0)
		languages.item_selected.emit(0)
		await process_frame
		_check(native.tr("离开游戏") == "离开游戏" and is_equal_approx(native.get_minimum_size().x, chinese_width), "切回简体中文即时恢复原生控件显示")
		var reloaded := GameSettings.new(settings.storage_path)
		_check(reloaded.load_settings().is_ok() and reloaded.volume == 0.0 and reloaded.language == "zh_CN", "面板选择已经持久化")
	panel.queue_free()
	native.queue_free()
	await process_frame


## 使用真实鼠标和空格输入验证矢量开关、设置持久化和窄窗口滚动可达性。
func _test_completion_switch() -> void:
	var settings := GameSettings.new(_test_root.path_join("completion_panel.json"))
	settings.load_settings()
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.size = Vector2(800, 600)
	root.add_child(panel)
	for frame in range(4):
		await process_frame
	var toggle := panel.find_child("TabCompletionToggle", true, false) as Button
	var label := panel.find_child("TabCompletionLabel", true, false) as Label
	var title := panel.find_child("CompletionSectionTitle", true, false) as Label
	var row := panel.find_child("TabCompletionRow", true, false) as Control
	var volume_row := panel.find_child("VolumeRow", true, false) as Control
	var more_title := panel.find_child("DisplaySectionTitle", true, false) as Control
	_check(toggle != null and label != null and title != null and row != null, "显示分组包含补全标签与切换按钮")
	if toggle != null and label != null and title != null and row != null:
		_check(toggle.toggle_mode and toggle.button_pressed and settings.tab_completion, "补全开关默认处于开启状态")
		_check(toggle.focus_mode == Control.FOCUS_ALL, "补全开关可以通过键盘获得焦点")
		_check(title.text == "显示" and volume_row.get_global_rect().end.y < title.global_position.y and row.get_global_rect().end.y < more_title.global_position.y, "显示分组位于音效与更多之间")
		_check(row.get_global_rect().encloses(toggle.get_global_rect()) and row.get_global_rect().encloses(label.get_global_rect()), "开关与文案完整位于同一个设置行中")
		_check(absf(label.get_global_rect().get_center().y - toggle.get_global_rect().get_center().y) < 1 and label.get_global_rect().end.x < toggle.global_position.x, "标签左侧、开关右侧并垂直居中")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = toggle.get_global_rect().get_center()
		click.global_position = click.position
		click.pressed = true
		# 坐标已来自视口内控件，不能再次套用窗口拉伸变换。
		root.push_input(click, true)
		click = click.duplicate()
		click.pressed = false
		root.push_input(click, true)
		await process_frame
		_check(not settings.tab_completion and not toggle.button_pressed, "真实鼠标点击关闭补全")
		var reloaded := GameSettings.new(settings.storage_path)
		_check(reloaded.load_settings().is_ok() and not reloaded.tab_completion, "鼠标关闭后独立模型读到已保存状态")
		toggle.grab_focus()
		var key := InputEventKey.new()
		key.keycode = KEY_SPACE
		key.physical_keycode = KEY_SPACE
		key.pressed = true
		root.push_input(key, true)
		key = key.duplicate()
		key.pressed = false
		root.push_input(key, true)
		await process_frame
		_check(settings.tab_completion and toggle.button_pressed, "真实空格键重新开启补全")
		_check(reloaded.load_settings().is_ok() and reloaded.tab_completion, "键盘开启后也持久化保存")
		settings.set_tab_completion(false)
		_check(not toggle.button_pressed, "外部模型修改会同步已有开关")
		settings.set_language("en")
		await process_frame
		_check(label.atr(label.text) == "Tab Completion" and title.atr(title.text) == "Display", "英文完整显示补全标签和显示分组")
		_check(not toggle.button_pressed and not settings.tab_completion, "切换语言不会重新开启已关闭的补全")
		settings.set_language("zh_CN")
		await process_frame
		_check(label.atr(label.text) == "Tab 补全" and title.atr(title.text) == "显示", "简体中文显示补全标签和分组")
		panel.size = Vector2(640, 420)
		for frame in range(4):
			await process_frame
		var scroll := panel.find_child("SettingsScroll", true, false) as ScrollContainer
		var clear_user := panel.find_child("ClearUserLevelsButton", true, false) as Control
		_check(scroll != null and scroll.get_v_scroll_bar().visible, "小窗口为额外设置提供纵向滚动")
		if scroll != null and clear_user != null:
			scroll.ensure_control_visible(clear_user)
			for frame in range(3):
				await process_frame
			# ScrollContainer 使用整数滚动值，允许小数布局末端出现不足一像素的取整差异。
			_check(scroll.get_global_rect().grow(1).encloses(clear_user.get_global_rect()), "小窗口滚动后底部清除按钮完整可达：视口%s，按钮%s" % [scroll.get_global_rect(), clear_user.get_global_rect()])
	panel.queue_free()
	await process_frame


## 通过真正的右键输入打开 CodeEdit 原生菜单，覆盖禁翻译父控件和动态只读状态。
func _test_native_code_menu() -> void:
	var original_size := root.size
	var original_embed := root.gui_embed_subwindows
	root.size = Vector2i(800, 600)
	root.gui_embed_subwindows = true
	var code := CodeEdit.new()
	code.size = Vector2(600, 400)
	# 与正式程序区保持一致：代码不能自动翻译，只有菜单单独启用。
	code.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	root.add_child(code)
	GameI18n.localize_text_edit_menu(code)
	GameI18n.localize_text_edit_menu(code)
	var original_source := "main() {\n    // Cut、Copy 和中文玩家注释必须原样保留。\n    move(0, 3)\n}"
	code.text = original_source
	await process_frame
	await _open_code_menu(code)
	var menu := code.get_menu()
	var initial_entries := _text_menu_entries(menu)
	_check(initial_entries.size() == TextEdit.MENU_INSERT_SHY + 1, "原生菜单保留完整30个命令及两个子菜单")
	_check(menu.id_pressed.get_connections().size() == 1, "重复启用菜单翻译不会重复连接编辑命令")
	menu.hide()
	for locale: String in ["zh_CN", "en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		await process_frame
		await _open_code_menu(code)
		_check(menu.visible, "真实右键输入打开原生菜单：%s" % locale)
		var entries := _text_menu_entries(menu)
		_check(entries.keys() == initial_entries.keys(), "切换语言保留所有原生命令ID与菜单顺序")
		var fully_localized := true
		var shortcuts_unchanged := true
		for command: int in initial_entries:
			var original: Dictionary = initial_entries[command]
			var current: Dictionary = entries[command]
			var source: String = original["source"]
			var expected: String = source if locale == "en" else GameI18n.NATIVE_MENU_CHINESE.get(source, "")
			fully_localized = fully_localized and not expected.is_empty() and current["display"] == expected
			shortcuts_unchanged = shortcuts_unchanged and current["accelerator"] == original["accelerator"]
		_check(fully_localized, "主菜单、书写方向及控制字符全部跟随当前语言")
		_check(shortcuts_unchanged, "全部原生快捷键在中英切换后保持一致")
		var copy_text: String = entries[TextEdit.MENU_COPY]["display"]
		_check(copy_text == ("复制" if locale == "zh_CN" else "Copy"), "原生复制条目使用可见本土化文案")
		_check(code.text == original_source and code.atr("Cut") == "Cut", "本土化不翻译或改写玩家程序")
		if locale == "en":
			_check(TranslationServer.translate("external marker") == "External translation stays installed", "安装游戏翻译后第三方英文资源仍然生效")
		# 通过原生菜单的信号调用编辑行为，不另写替代剪贴板或撤销逻辑。
		menu.id_pressed.emit(TextEdit.MENU_SELECT_ALL)
		_check(code.get_selected_text() == original_source, "本土化全选仍选中完整玩家代码")
		menu.id_pressed.emit(TextEdit.MENU_CLEAR)
		_check(code.text.is_empty() and code.has_undo(), "本土化清空保留原生撤销记录")
		menu.id_pressed.emit(TextEdit.MENU_UNDO)
		_check(code.text == original_source, "本土化撤销恢复原始代码")
		menu.id_pressed.emit(TextEdit.MENU_REDO)
		_check(code.text.is_empty(), "本土化重做再次清空代码")
		menu.id_pressed.emit(TextEdit.MENU_UNDO)
		menu.hide()
		# 运行时程序区会变为只读；每次右键重建后的菜单仍须正确翻译和禁用写操作。
		code.editable = false
		await _open_code_menu(code)
		var readonly_menu := code.get_menu()
		_check(readonly_menu.atr(readonly_menu.get_item_text(readonly_menu.get_item_index(TextEdit.MENU_COPY))) == copy_text, "运行只读状态下重建菜单仍使用当前语言")
		_check(readonly_menu.is_item_disabled(readonly_menu.get_item_index(TextEdit.MENU_CUT)) and readonly_menu.is_item_disabled(readonly_menu.get_item_index(TextEdit.MENU_CLEAR)), "只读菜单继续禁用剪切和清空")
		_check(code.text == original_source, "只读菜单及语言切换保留程序原文")
		readonly_menu.hide()
		code.editable = true
	code.queue_free()
	await process_frame
	root.size = original_size
	root.gui_embed_subwindows = original_embed


## 采集真实菜单的翻译显示值与快捷键；atr 与 PopupMenu 绘制使用相同的自动翻译模式。
func _text_menu_entries(menu: PopupMenu) -> Dictionary:
	var entries: Dictionary = {}
	for index in range(menu.item_count):
		if menu.is_item_separator(index):
			continue
		var source := menu.get_item_text(index)
		entries[menu.get_item_id(index)] = {
			"source": source,
			"display": menu.atr(source),
			"accelerator": menu.get_item_accelerator(index),
		}
		var submenu := menu.get_item_submenu_node(index)
		if submenu != null:
			entries.merge(_text_menu_entries(submenu))
	return entries


## 将按下与释放发送给视口，验证 Godot 的右键入口和菜单更新，而非直接调用 popup。
func _open_code_menu(code: CodeEdit) -> void:
	code.get_menu().hide()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.position = code.global_position + Vector2(80, 70)
	event.global_position = event.position
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await process_frame


## 统计模型变更信号，确保一次有效设置只通知一次。
func _on_changed() -> void:
	_changed_count += 1


## 所有测试文件只写本次独占目录，不访问默认玩家配置。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "测试文件可以写入独占目录")
	if file != null:
		file.store_string(source)
		file.close()


## 仅清理本次创建的测试子树，不能递归触及其它用户数据。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for filename in folder.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in folder.get_directories():
		_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## 累计失败并继续其它用例，最后统一返回非零进程状态。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 三档提示独立持久化，旧文件缺字段使用一般；非法类型或保存失败不破坏其它设置。
func _test_code_hint_setting() -> void:
	var path := _test_root.path_join("code_hints.json")
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.code_hints == "normal", "代码提示默认一般")
	_check(settings.set_tab_completion(false).is_ok(), "提示等级测试保留独立关闭的Tab补全")
	for value in ["none", "normal", "more"]:
		_check(settings.set_code_hints(value).is_ok(), "合法提示等级可保存：" + value)
		var reloaded := GameSettings.new(path)
		_check(reloaded.load_settings().is_ok() and reloaded.code_hints == value and not reloaded.tab_completion, "重载完整保留等级与独立补全开关")
	var before := FileAccess.get_file_as_bytes(path)
	for value in [true, false, null, 0, 1, "", "MORE", "一般", "all", [], {}]:
		_check(not settings.set_code_hints(value).is_ok() and settings.code_hints == "more", "拒绝非法等级且不改变已有选择")
	_check(FileAccess.get_file_as_bytes(path) == before, "非法提示等级不覆盖磁盘配置")
	for value in [true, null, 1, "unknown"]:
		var invalid_path := _test_root.path_join("invalid_hints_%s.json" % str(value))
		var invalid := {"format_version": 1, "audio": {"master_volume": 0.3}, "interface": {"language": "en", "code_hints": value}}
		_write_text(invalid_path, JSON.stringify(invalid))
		var invalid_bytes := FileAccess.get_file_as_bytes(invalid_path)
		var loaded := GameSettings.new(invalid_path)
		_check(not loaded.load_settings().is_ok() and loaded.code_hints == "normal" and loaded.volume == 1.0, "坏提示字段回退完整默认值")
		_check(FileAccess.get_file_as_bytes(invalid_path) == invalid_bytes, "坏提示文件保持原样")
	var blocked := _test_root.path_join("hints_blocked")
	_write_text(blocked, "保留")
	var unsaved := GameSettings.new(blocked.path_join("settings.json"))
	var changes_before := _changed_count
	unsaved.changed.connect(_on_changed)
	_check(not unsaved.set_code_hints("none").is_ok() and unsaved.code_hints == "none", "无法写盘仍采用当前提示等级")
	_check(_changed_count == changes_before + 1 and FileAccess.get_file_as_string(blocked) == "保留", "保存失败也通知UI且不覆盖已有文件")


## 选择器位于显示卡片第二行，模型、中文英文与重新进入页面都保持同一等级。
func _test_code_hint_selector() -> void:
	var settings := GameSettings.new(_test_root.path_join("code_hints_panel.json"))
	settings.load_settings()
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.size = Vector2(800, 700)
	root.add_child(panel)
	for unused in 4:
		await process_frame
	var selector := panel.find_child("CodeHintsOption", true, false) as OptionButton
	var label := panel.find_child("CodeHintsLabel", true, false) as Label
	var divider := panel.find_child("CodeHintsDivider", true, false) as Control
	var toggle := panel.find_child("TabCompletionToggle", true, false) as Button
	_check(selector != null and label != null and divider != null, "显示卡片包含代码提示、三档选择器与分隔线")
	if selector != null and label != null and divider != null:
		_check(selector.item_count == 3 and selector.selected == 1, "代码提示选项为三档且默认选中一般")
		_check(toggle.global_position.y < divider.global_position.y and divider.global_position.y < selector.global_position.y, "代码提示位于Tab补全下方，分隔线位于两行之间")
		selector.select(2)
		selector.item_selected.emit(2)
		_check(settings.code_hints == "more" and settings.tab_completion, "选择更多提示不改变Tab补全")
		var reloaded := GameSettings.new(settings.storage_path)
		_check(reloaded.load_settings().is_ok() and reloaded.code_hints == "more", "选择器修改立即持久化")
		selector.grab_focus()
		_check(selector.get_theme_stylebox("focus") is StyleBoxEmpty, "选择器获得焦点后不会残留蓝色描边")
		settings.set_language("en")
		await process_frame
		_check(label.atr(label.text) == "Code Hints" and selector.atr(selector.get_item_text(2)) == "More", "代码提示标签和当前等级有英文显示")
		_check(selector.selected == 2 and settings.code_hints == "more", "切换语言不改变所选等级")
		settings.set_code_hints("none")
		_check(selector.selected == 0, "外部模型修改同步当前设置页")
		settings.set_language("zh_CN")
		await process_frame
		_check(selector.atr(selector.get_item_text(0)) == "无", "简体中文恢复无提示名称")
	panel.queue_free()
	await process_frame


## 诊断本土化保留玩家名称与准确源码位置，未知消息和超长输入不作猜测。
func _test_error_localization() -> void:
	TranslationServer.set_locale("en")
	var translated := GameI18n.translate_errors(PackedStringArray(["第 12 行，第 4 列：名称“dodge_step”尚未声明或不在当前作用域中。", "第 2 行，第 3 列：常量“step”不能重新赋值。", "程序最多允许 32 个用户函数。", "未知诊断保留"]))
	_check(translated.contains("Line 12, column 4: Name “dodge_step” has not been declared or is outside the current scope."), "变量错误保留行列与原名称并显示英文")
	_check(translated.contains("Line 2, column 3: Constant “step” cannot be reassigned."), "常量写入错误使用英文模板")
	_check(translated.contains("A program allows at most 32 user functions.") and translated.ends_with("未知诊断保留"), "整数参数正确回填且未知诊断保持原文")
	var source := "名称“literal%s”尚未声明或不在当前作用域中。"
	_check(GameI18n.translate_errors(PackedStringArray([source])).contains("literal%s"), "捕获内容中的百分号不会被二次当作格式指令")
	var long_source := "x".repeat(8193)
	_check(GameI18n.translate_errors(PackedStringArray([long_source])) == long_source, "过长未知错误有界返回原文")
	TranslationServer.set_locale("zh_CN")
	_check(GameI18n.translate_errors(PackedStringArray([source])) == source, "中文错误保持原样")


## 自由缩放偏好覆盖缺省、真实布尔值、损坏回退和写盘失败，不接触玩家配置。
func _test_assembly_free_zoom_setting() -> void:
	var path := _test_root.path_join("assembly_zoom.json")
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and not settings.assembly_free_zoom, "缺失配置默认关闭装配图自由缩放")
	_check(not FileAccess.file_exists(path), "仅载入自由缩放默认值不会写盘")
	var legacy := {"format_version": 1, "audio": {"master_volume": 0.3, "device": "retain"}, "interface": {"language": "en", "tab_completion": false, "code_hints": "more", "code_color_mode": "dark", "future_display": {"retain": true}}, "future": [1, 2]}
	_write_text(path, JSON.stringify(legacy))
	var legacy_bytes := FileAccess.get_file_as_bytes(path)
	var legacy_loaded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(settings.load_settings().is_ok() and not settings.assembly_free_zoom and settings.volume == 0.3 and settings.language == "en" and not settings.tab_completion and settings.code_hints == "more" and settings.code_color_mode == "dark", "旧配置缺缩放字段仅补齐关闭值，保留其他偏好")
	_check(FileAccess.get_file_as_bytes(path) == legacy_bytes, "读取旧缩放配置不自动迁移文件")
	settings.changed.connect(_on_changed)
	var previous_changes := _changed_count
	for enabled: bool in [true, false, true]:
		_check(settings.set_assembly_free_zoom(enabled).is_ok(), "装配图自由缩放可保存开启与关闭")
		var reloaded := GameSettings.new(path)
		_check(reloaded.load_settings().is_ok() and reloaded.assembly_free_zoom == enabled, "自由缩放开关跨设置模型往返")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved["interface"]["assembly_free_zoom"] is bool and saved["interface"]["assembly_free_zoom"], "自由缩放保存为真实JSON布尔值")
	_check(_changed_count == previous_changes + 3, "每次有效缩放设置仅通知一次changed")
	_check(saved["future"] == legacy_loaded["future"] and saved["audio"] == legacy_loaded["audio"] and saved["interface"]["future_display"] == legacy_loaded["interface"]["future_display"], "修改自由缩放保留未知字段与其他分组")
	_check(settings.volume == 0.3 and settings.language == "en" and not settings.tab_completion and settings.code_hints == "more" and settings.code_color_mode == "dark", "自由缩放不改变音量、语言、补全、提示与代码配色")
	var before := FileAccess.get_file_as_bytes(path)
	previous_changes = _changed_count
	for invalid in [0, 1, 0.0, "true", "false", "", null, [], {}]:
		_check(not settings.set_assembly_free_zoom(invalid).is_ok() and settings.assembly_free_zoom, "拒绝非布尔缩放值且保留已开启状态")
	_check(_changed_count == previous_changes and FileAccess.get_file_as_bytes(path) == before, "非法缩放值既不发修改通知也不覆盖有效文件")
	for invalid in [0, "false", null, [], {}]:
		var broken := legacy.duplicate(true)
		broken["interface"]["assembly_free_zoom"] = invalid
		var source := JSON.stringify(broken)
		_write_text(path, source)
		_check(not settings.load_settings().is_ok() and not settings.assembly_free_zoom and settings.volume == 1.0 and settings.language == "zh_CN" and settings.tab_completion and settings.code_hints == "normal" and settings.code_color_mode == "light", "损坏缩放字段恢复全部默认值，不部分采用旧字段")
		_check(FileAccess.get_file_as_string(path) == source, "损坏缩放配置保留原件")
	var blocked := _test_root.path_join("zoom_blocked")
	_write_text(blocked, "保留")
	var unsaved := GameSettings.new(blocked.path_join("settings.json"))
	unsaved.changed.connect(_on_changed)
	previous_changes = _changed_count
	_check(not unsaved.set_assembly_free_zoom(true).is_ok() and unsaved.assembly_free_zoom and not unsaved.last_error.is_empty(), "缩放保存失败仍保留当前选择并报告错误")
	_check(_changed_count == previous_changes + 1 and FileAccess.get_file_as_string(blocked) == "保留", "缩放写盘失败仍通知界面，不改阻挡文件")


## 设置中的真实鼠标与空格输入控制缩放偏好，语言和外部修改保持同步。
func _test_assembly_free_zoom_switch() -> void:
	var settings := GameSettings.new(_test_root.path_join("assembly_zoom_panel.json"))
	settings.load_settings()
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.size = Vector2(800, 600)
	root.add_child(panel)
	for unused in 4:
		await process_frame
	var toggle := panel.find_child("AssemblyFreeZoomToggle", true, false) as SettingsSwitch
	var label := panel.find_child("AssemblyFreeZoomLabel", true, false) as Label
	var row := panel.find_child("AssemblyFreeZoomRow", true, false) as Control
	var completion_row := panel.find_child("TabCompletionRow", true, false) as Control
	var colors_row := panel.find_child("CodeColorsButton", true, false) as Control
	_check(toggle != null and label != null and row != null, "显示分组包含装配缩放标签与矢量开关")
	if toggle != null and label != null and row != null:
		_check(not toggle.button_pressed and not settings.assembly_free_zoom, "装配图自由缩放UI默认关闭")
		_check(completion_row.get_global_rect().end.y < row.global_position.y and row.get_global_rect().end.y < colors_row.global_position.y, "装配缩放紧接Tab补全，位于颜色与显示之前")
		_check(row.get_global_rect().encloses(label.get_global_rect()) and row.get_global_rect().encloses(toggle.get_global_rect()) and label.get_global_rect().end.x < toggle.global_position.x, "缩放标签与开关在同一行内不重叠")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = toggle.get_global_rect().get_center()
		click.global_position = click.position
		click.pressed = true
		root.push_input(click, true)
		click = click.duplicate()
		click.pressed = false
		root.push_input(click, true)
		await process_frame
		_check(settings.assembly_free_zoom and toggle.button_pressed and settings.tab_completion, "真实鼠标开启自由缩放，不影响补全开关")
		var reloaded := GameSettings.new(settings.storage_path)
		_check(reloaded.load_settings().is_ok() and reloaded.assembly_free_zoom, "真实缩放开关点击立即持久化")
		toggle.grab_focus()
		var key := InputEventKey.new()
		key.keycode = KEY_SPACE
		key.physical_keycode = KEY_SPACE
		key.pressed = true
		root.push_input(key, true)
		key = key.duplicate()
		key.pressed = false
		root.push_input(key, true)
		await process_frame
		_check(not settings.assembly_free_zoom and not toggle.button_pressed, "真实空格键关闭自由缩放")
		_check(reloaded.load_settings().is_ok() and not reloaded.assembly_free_zoom, "键盘关闭缩放也能跨模型恢复")
		settings.set_assembly_free_zoom(true)
		_check(toggle.button_pressed, "外部设置变更同步现有缩放开关")
		settings.set_language("en")
		await process_frame
		_check(label.atr(label.text) == "Free Blueprint Zoom" and toggle.atr(toggle.tooltip_text) == "Free Blueprint Zoom" and toggle.button_pressed, "缩放标签与提示切成英文，选择保持不变")
		settings.set_language("zh_CN")
		await process_frame
		_check(label.atr(label.text) == "装配图尺寸自由缩放", "缩放标签可恢复中文")
	panel.queue_free()
	await process_frame
