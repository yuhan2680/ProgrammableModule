extends SceneTree
## 香港繁体回归：覆盖真实设置、静态词典、指令资料和原生控件，仅写本次独占目录。

const LOCALES: Array[String] = ["zh_CN", "zh_HK", "en"]
const LANGUAGE_CAPTIONS: Array[String] = ["简体中文", "繁體中文", "English"]

var _checks := 0
var _failures := 0
var _test_root := ""


## 等待场景树可接受控件后运行，避免初始化阶段修改根节点。
func _initialize() -> void:
	_run.call_deferred()


## 分别验证数据与真实界面，并在退出前恢复引擎全局状态及清理测试文件。
func _run() -> void:
	_test_root = "user://tests/hong_kong_locale_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var original_size := root.size
	var original_content_scale := root.content_scale_size
	var original_embed := root.gui_embed_subwindows
	var master := AudioServer.get_bus_index("Master")
	var original_volume := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	root.size = Vector2i(1000, 740)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	GameI18n.install()
	_test_dictionary_completeness()
	_test_settings_round_trip()
	_test_command_documents()
	_test_formatted_errors()
	await _test_startup_failure_locale()
	await _test_settings_panel()
	await _test_native_menu()
	TranslationServer.set_locale(original_locale)
	AudioServer.set_bus_volume_db(master, original_volume)
	AudioServer.set_bus_mute(master, original_mute)
	root.size = original_size
	root.content_scale_size = original_content_scale
	root.gui_embed_subwindows = original_embed
	_remove_test_tree(_test_root)
	print("香港繁体回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 每个已有中文源串必须有显式香港译文，格式参数类型及顺序不可在翻译中变更。
func _test_dictionary_completeness() -> void:
	var loaded_before := TranslationServer.get_loaded_locales().size()
	GameI18n.install()
	_check(TranslationServer.get_loaded_locales().size() == loaded_before, "重复安装香港词典不会增加语言资源")
	for source: String in GameI18n.ENGLISH:
		_check(GameI18nHK.MESSAGES.has(source), "香港词典覆盖静态源串：" + source)
		if not GameI18nHK.MESSAGES.has(source):
			continue
		var translated: String = GameI18nHK.MESSAGES[source]
		_check(not translated.strip_edges().is_empty(), "香港静态译文非空：" + source)
		_check(_placeholders(source) == _placeholders(translated), "香港译文保留格式参数顺序与类型：" + source)
	for source: String in GameI18n.NATIVE_MENU_CHINESE:
		_check(GameI18nHK.NATIVE_MENU.has(source) and not str(GameI18nHK.NATIVE_MENU.get(source, "")).is_empty(), "香港原生菜单覆盖：" + source)
	TranslationServer.set_locale("zh_HK")
	for pair: Array in [["开始游戏", "開始遊戲"], ["地图编辑器", "地圖編輯器"], ["设置", "設定"], ["雷达模块", "雷達模組"]]:
		_check(str(TranslationServer.translate(pair[0])) == pair[1], "香港静态界面显示地区译文：" + pair[0])
	for source: String in GameI18nHK.MESSAGES:
		_check(str(TranslationServer.translate(source)) == GameI18nHK.MESSAGES[source], "香港语言实际资源与静态词典一致：" + source)
	_check(_missing_cjk_glyphs("".join(GameI18nHK.MESSAGES.values())).is_empty(), "随项目字体覆盖香港静态译文全部汉字")


## 提取 printf 占位，包括小数精度和转义百分号，避免遗漏非 %s/%d 的显示格式。
func _placeholders(source: String) -> PackedStringArray:
	var pattern := RegEx.new()
	pattern.compile("%[-+0 #]*[0-9]*(?:\\.[0-9]+)?[a-zA-Z%]")
	var values := PackedStringArray()
	for matched: RegExMatch in pattern.search_all(source):
		values.append(matched.get_string())
	return values


## 检查实际随工程字体的汉字覆盖，避免只有未截图页面才出现缺字方框。
func _missing_cjk_glyphs(source: String) -> String:
	var seen: Dictionary = {}
	var missing := ""
	var font := GameTheme.body_font()
	for index in source.length():
		var character := source.unicode_at(index)
		if character < 0x2e80 or seen.has(character):
			continue
		seen[character] = true
		if not font.has_char(character):
			missing += String.chr(character)
	return missing


## 三种地区选择跨模型保存恢复，旧 en 不迁移，其他偏好与玩家扩展数据保持原值。
func _test_settings_round_trip() -> void:
	var path := _test_root.path_join("settings.json")
	var legacy := {"format_version": 1, "audio": {"master_volume": 0.35}, "interface": {"language": "en", "tab_completion": false, "code_hints": "more", "code_color_mode": "dark", "assembly_free_zoom": true, "player_note": "设置 main() { move(0, 3) }"}, "future": {"地图名称": "简体玩家地图"}}
	_write_text(path, JSON.stringify(legacy))
	var before := FileAccess.get_file_as_bytes(path)
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.language == "en", "旧 en 配置仍按英文加载")
	_check(FileAccess.get_file_as_bytes(path) == before, "读取旧英文配置不自动迁移或改写文件")
	_check(GameSettings.SUPPORTED_LANGUAGES == LOCALES, "地区选择固定为简体第一、香港繁体第二、英语第三")
	for locale: String in ["zh_HK", "en", "zh_CN", "zh_HK"]:
		_check(settings.set_language(locale).is_ok(), "有效地区设置立即保存：" + locale)
		_check(TranslationServer.get_locale() == locale, "地区选择立即更新引擎：" + locale)
		var reloaded := GameSettings.new(path)
		_check(reloaded.load_settings().is_ok() and reloaded.language == locale, "重启模型恢复地区选择：" + locale)
		_check(reloaded.volume == 0.35 and not reloaded.tab_completion and reloaded.code_hints == "more" and reloaded.code_color_mode == "dark" and reloaded.assembly_free_zoom, "语言切换保留音量、补全、提示、配色和缩放")
		var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(saved.interface.language == locale and saved.interface.player_note == legacy.interface.player_note and saved.future == legacy.future, "地区键准确持久化，扩展名称、程序和 JSON 不被翻译")
	before = FileAccess.get_file_as_bytes(path)
	for invalid: Variant in ["zh_TW", "zh", "hk", "fr", true, null]:
		_check(not settings.set_language(invalid).is_ok() and settings.language == "zh_HK", "非法地区不改变已保存的香港语言")
	_check(FileAccess.get_file_as_bytes(path) == before, "非法地区不能覆盖有效配置")


## 内置资料各字段包含香港版本，地区搜索命中译文且 DSL 模板与资料结构保持只读。
func _test_command_documents() -> void:
	var catalog := CommandCatalog.new()
	_check(catalog.load_directory().is_ok() and catalog.entries.size() == 27, "全部二十七项内置指令资料可以加载")
	var before := JSON.stringify(catalog.entries)
	for entry: Dictionary in catalog.entries:
		for field: String in ["title", "description", "category_title"]:
			var values: Dictionary = entry[field]
			_check(values.has("zh_HK") and not str(values.get("zh_HK", "")).strip_edges().is_empty(), "香港指令字段完整：" + str(entry.id) + "/" + field)
			_check(CommandCatalog.localized(entry, field, "zh-HK") == values.get("zh_HK", ""), "香港地区及连字符选择优先准确译文：" + str(entry.id) + "/" + field)
			_check(_missing_cjk_glyphs(str(values.get("zh_HK", ""))).is_empty(), "随项目字体覆盖香港指令字段全部汉字：" + str(entry.id) + "/" + field)
		var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(entry.source_path))
		_check(entry.syntax == raw.syntax, "指令目录保持源文件 DSL 语法文本：" + str(entry.id))
	var registry := ContentRegistry.new()
	_check(registry.load_directories().is_ok(), "地区搜索使用真实模块注册表")
	_check(_has_entry(catalog.search("循環", registry, "zh_HK"), "loop"), "香港搜索按繁体循环标题命中")
	_check(_has_entry(catalog.search("雷達", registry, "zh_HK"), "scan"), "香港搜索按繁体雷达说明或模块名命中")
	_check(_has_entry(catalog.search("randomInt", registry, "zh_HK"), "random_int"), "香港搜索仍支持原始 DSL 函数名")
	_check(catalog.sections(registry, "zh_HK")[0].title == "編程基礎", "指令基础目录标题使用香港繁体")
	_check(JSON.stringify(catalog.entries) == before, "翻译、模块分组和搜索不改写指令 JSON 快照")


## 查询结果只比较稳定 ID，避免依赖搜索返回顺序或显示文案排序。
func _has_entry(entries: Array[Dictionary], id: String) -> bool:
	for entry: Dictionary in entries:
		if entry.id == id:
			return true
	return false


## 格式化错误可反复切换语言，玩家名称含中文、百分号与 JSON 时仍只翻译外层诊断。
func _test_formatted_errors() -> void:
	var source_template := "名称“%s”尚未声明或不在当前作用域中。"
	var player_name := "设置_地图_%s_%d_main()_{\"名称\":\"玩家简体\"}"
	var detail := source_template % player_name
	var located := "第 12 行，第 4 列：" + detail
	var integer_template := "程序最多允许 %d 个用户函数。"
	var unknown := "玩家 JSON：{\"name\":\"设置\",\"code\":\"main(){move(0,3)}\"}"
	for locale: String in ["en", "zh_HK", "zh_CN", "zh_HK", "en"]:
		TranslationServer.set_locale(locale)
		var expected_detail: String = source_template if locale == "zh_CN" else (GameI18n.ENGLISH[source_template] if locale == "en" else GameI18nHK.MESSAGES[source_template])
		expected_detail = expected_detail % player_name
		var actual := GameI18n.translate_errors(PackedStringArray([located]))
		_check(actual.ends_with(expected_detail) and actual.contains("12") and actual.contains("4"), "诊断按当前语言翻译并保留源码位置：" + locale)
		_check(actual.contains(player_name), "动态诊断完整保留中文名称、百分号和程序 JSON 载荷：" + locale)
		if locale == "zh_HK":
			_check(actual.begins_with("第 12 行，第 4 列：") and not actual.begins_with("Line"), "香港源码位置使用中文地区格式")
		var expected_integer: String = integer_template if locale == "zh_CN" else (GameI18n.ENGLISH[integer_template] if locale == "en" else GameI18nHK.MESSAGES[integer_template])
		_check(GameI18n.translate_errors(PackedStringArray([integer_template % 32])) == expected_integer % 32, "整数诊断不会沿用上一个语言的缓存：" + locale)
		_check(GameI18n.translate_errors(PackedStringArray([unknown])) == unknown, "未知诊断及玩家 JSON 不作自动繁简转换：" + locale)
		_check(GameI18n.translate_errors(PackedStringArray(["x".repeat(8193)])) == "x".repeat(8193), "超长未知诊断有界原样返回：" + locale)


## 完整游戏尚未加载时，真实启动失败提示仍读取已保存地区且不改写玩家配置。
func _test_startup_failure_locale() -> void:
	var path := _test_root.path_join("startup/settings.json")
	for locale: String in LOCALES:
		_write_text(path, JSON.stringify({"format_version": 1, "audio": {"master_volume": 0.5}, "interface": {"language": locale}}))
		var before := FileAccess.get_file_as_bytes(path)
		# 故意将全局语言设为另一语言，证明故障页在模型尚未载入时也尊重磁盘设置。
		TranslationServer.set_locale("en" if locale != "en" else "zh_CN")
		var startup: Node = load("res://scenes/startup.tscn").instantiate()
		startup.set("settings_path", path)
		startup.set("scene_path", "res://scenes/hong_kong_missing_test_scene.tscn")
		startup.set("user_levels_directory", _test_root.path_join("startup/levels"))
		startup.set("drafts_directory", _test_root.path_join("startup/solutions"))
		root.add_child(startup)
		for unused in 120:
			if startup.get("phase") == "failed":
				break
			await process_frame
		_check(startup.get("phase") == "failed", "缺失启动场景进入可重试故障页：" + locale)
		var retry := startup.find_child("StartupRetry", true, false) as Button
		var expected_retry := "重試" if locale == "zh_HK" else ("Retry" if locale == "en" else "重试")
		_check(retry != null and retry.text == expected_retry, "早期失败重试按钮使用已保存地区：" + locale)
		var label: Label = startup.get("_message")
		var expected_message := "找不到啟動資源。" if locale == "zh_HK" else ("A startup resource could not be found." if locale == "en" else "找不到启动资源。")
		_check(label != null and label.text == expected_message, "启动资源错误使用已保存地区：" + locale)
		_check(FileAccess.get_file_as_bytes(path) == before, "启动故障仅读取语言且不改写设置")
		startup.queue_free()
		await _settle()


## 在最小窗口用真实设置控件切换三个地区，名称自身不翻译且标签、当前值与弹层不溢出。
func _test_settings_panel() -> void:
	var settings := GameSettings.new(_test_root.path_join("panel.json"))
	settings.load_settings()
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.theme = GameTheme.create_theme()
	panel.position = Vector2(24, 100)
	panel.size = Vector2(952, 600)
	root.add_child(panel)
	await _settle()
	var option := panel.find_child("LanguageOption", true, false) as OptionButton
	var row := panel.find_child("LanguageRow", true, false) as Control
	var card := panel.find_child("SettingsCard", true, false) as Control
	var scroll := panel.find_child("SettingsScroll", true, false) as ScrollContainer
	_check(option != null and row != null and card != null and scroll != null, "最小窗口建立实际设置选择器")
	if option != null and row != null and card != null and scroll != null:
		_check(option.item_count == 3, "显示语言包含三个地区选项")
		var labels := row.find_children("*", "Label", true, false)
		var label := labels[0] as Label if not labels.is_empty() else null
		for locale: String in ["zh_HK", "en", "zh_CN", "zh_HK"]:
			var index := LOCALES.find(locale)
			option.select(index)
			option.item_selected.emit(index)
			await _settle()
			_check(settings.language == LOCALES[index] and option.selected == index, "真实选择器应用地区：" + LOCALES[index])
			for caption_index in LANGUAGE_CAPTIONS.size():
				var caption := LANGUAGE_CAPTIONS[caption_index]
				_check(option.get_item_text(caption_index) == caption and option.atr(caption) == caption and option.get_popup().atr(caption) == caption, "地区名称始终保留各自语言：" + caption)
			var reloaded := GameSettings.new(settings.storage_path)
			_check(reloaded.load_settings().is_ok() and reloaded.language == LOCALES[index], "控件选择跨模型恢复")
			scroll.ensure_control_visible(row)
			await _settle()
			_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(card.get_global_rect()) and scroll.get_global_rect().grow(1).encloses(option.get_global_rect()), "1000×740 中卡片和地区选择器完整可见")
			_check(row.get_global_rect().encloses(option.get_global_rect()) and label != null and label.get_global_rect().end.x < option.global_position.x, "地区名称选择器与左侧语言标签不重叠")
			_check(option.size.x + 1 >= option.get_minimum_size().x, "地区选择器宽度满足完整文字与箭头最小需求")
			option.show_popup()
			await _settle()
			var popup := option.get_popup()
			_check(popup.visible and Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(Rect2(Vector2(popup.position), Vector2(popup.size))), "三个地区的原生弹出菜单位于最小窗口内：窗口%s，菜单%s，显示%s" % [root.size, Rect2(Vector2(popup.position), Vector2(popup.size)), popup.visible])
			popup.hide()
	panel.queue_free()
	await process_frame


## 原生 CodeEdit 菜单完整繁体化且保留命令、快捷键、只读限制及真实撤销行为。
func _test_native_menu() -> void:
	var code := CodeEdit.new()
	code.position = Vector2(30, 30)
	code.size = Vector2(700, 400)
	code.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	code.text = "main() {\n    // 设置、地图、Copy 与玩家程序保持原文\n    move(0, 3)\n}"
	var original_source := code.text
	root.add_child(code)
	GameI18n.localize_text_edit_menu(code)
	await _settle()
	await _open_code_menu(code)
	var menu := code.get_menu()
	var initial := _menu_entries(menu)
	_check(initial.size() == TextEdit.MENU_INSERT_SHY + 1, "香港菜单保留完整原生命令及子菜单")
	menu.hide()
	for locale: String in ["zh_HK", "en", "zh_CN", "zh_HK"]:
		TranslationServer.set_locale(locale)
		await _settle()
		await _open_code_menu(code)
		var entries := _menu_entries(menu)
		_check(menu.visible and entries.keys() == initial.keys(), "真实右键菜单保留原生命令ID和顺序：" + locale)
		for id: int in initial:
			var source: String = entries[id].source
			var expected: String = source if locale == "en" else (GameI18n.NATIVE_MENU_CHINESE.get(source, "") if locale == "zh_CN" else GameI18nHK.NATIVE_MENU.get(source, ""))
			_check(entries[id].display == expected and not expected.is_empty(), "原生菜单及书写方向子菜单使用地区译文：" + locale + "/" + source)
			_check(entries[id].accelerator == initial[id].accelerator, "翻译保留原生菜单快捷键：" + source)
		_check(code.text == original_source and code.atr("设置") == "设置", "编辑区禁翻译保留玩家程序")
		menu.id_pressed.emit(TextEdit.MENU_SELECT_ALL)
		menu.id_pressed.emit(TextEdit.MENU_CLEAR)
		_check(code.text.is_empty() and code.has_undo(), "地区菜单的清空命令保留原生撤销")
		menu.id_pressed.emit(TextEdit.MENU_UNDO)
		_check(code.text == original_source, "地区菜单撤销恢复完整玩家源代码")
		menu.hide()
		code.editable = false
		await _open_code_menu(code)
		_check(menu.is_item_disabled(menu.get_item_index(TextEdit.MENU_CUT)) and menu.is_item_disabled(menu.get_item_index(TextEdit.MENU_CLEAR)), "地区菜单重建保留只读写入限制")
		menu.hide()
		code.editable = true
	code.queue_free()
	await process_frame


## 递归采集原生子菜单，实际显示值由与 PopupMenu 绘制相同的 atr 提供。
func _menu_entries(menu: PopupMenu) -> Dictionary:
	var entries: Dictionary = {}
	for index in menu.item_count:
		if menu.is_item_separator(index):
			continue
		var source := menu.get_item_text(index)
		entries[menu.get_item_id(index)] = {"source": source, "display": menu.atr(source), "accelerator": menu.get_item_accelerator(index)}
		var submenu := menu.get_item_submenu_node(index)
		if submenu != null:
			entries.merge(_menu_entries(submenu))
	return entries


## 使用视口真实右键按下和抬起，覆盖引擎重建编辑菜单的路径。
func _open_code_menu(code: CodeEdit) -> void:
	code.get_menu().hide()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.position = code.global_position + Vector2(80, 70)
	event.global_position = event.position
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
	await process_frame


## 等待布局及原生翻译通知完成，避免读取尚未重新计算的矩形。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 测试配置仅写独占路径，不访问玩家默认设置。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "可创建独占香港语言测试夹具")
	if file != null:
		file.store_string(source)
		file.close()


## 递归清理前限定路径必须属于本次独占根目录。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in directory.get_directories():
		_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## 累积所有独立问题并在最终用非零退出状态报告。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
