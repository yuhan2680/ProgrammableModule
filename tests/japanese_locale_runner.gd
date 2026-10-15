extends SceneTree
## 日语资源、真实语言选择器、指令资料与持久化回归；全部写入独占测试目录。

var _checks := 0
var _failures := 0
var _directory := ""


## 延后执行以便真实控件与翻译资源可以进入场景树。
func _initialize() -> void:
	_run.call_deferred()


## 保留原地区并隔离文件；语言显示不应改变玩家源代码或扩展数据。
func _run() -> void:
	_directory = "user://tests/japanese_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	GameI18n.install()
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_test_dictionary()
	_test_settings()
	_test_commands()
	_test_diagnostics()
	await _test_selector()
	await _test_startup()
	TranslationServer.set_locale(original_locale)
	_remove_tree(_directory)
	print("JAPANESE_LOCALE_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 完整译文保留 printf 参数、命名参数、段落与实际字体字形。
func _test_dictionary() -> void:
	_check(GameI18nJA.MESSAGES.size() == GameI18n.ENGLISH.size(), "日语覆盖全部静态界面源串")
	TranslationServer.set_locale("ja")
	var font := GameTheme.body_font()
	var checked_characters: Dictionary = {}
	for source: String in GameI18n.ENGLISH:
		_check(GameI18nJA.MESSAGES.has(source), "日语键完整：" + source)
		var translated: String = GameI18nJA.MESSAGES.get(source, "")
		_check(not translated.is_empty() and str(TranslationServer.translate(source)) == translated, "日语翻译已注册：" + source)
		_check(_tokens(source, "%[-+0#]*[0-9]*(?:\\.[0-9]+)?[a-zA-Z%]") == _tokens(translated, "%[-+0#]*[0-9]*(?:\\.[0-9]+)?[a-zA-Z%]"), "保留参数顺序：" + source)
		_check(_tokens(source, "\\{[a-z_]+\\}") == _tokens(translated, "\\{[a-z_]+\\}"), "保留命名参数：" + source)
		_check(source.count("\n") == translated.count("\n"), "保留段落换行：" + source)
		for index in translated.length():
			var character := translated.unicode_at(index)
			if character <= 32 or checked_characters.has(character):
				continue
			checked_characters[character] = true
			_check(font.has_char(character), "随项目字体支持日语字形：" + String.chr(character))
	for source: String in GameI18n.NATIVE_MENU_CHINESE:
		_check(GameI18nJA.NATIVE_MENU.has(source) and str(TranslationServer.translate(source)) == GameI18nJA.NATIVE_MENU[source], "原生文本菜单日语化：" + source)
	var before := TranslationServer.get_loaded_locales().size()
	GameI18n.install()
	_check(TranslationServer.get_loaded_locales().size() == before, "重复安装不会重复注册语言")


## 提取格式标记，避免翻译破坏运行时参数格式。
func _tokens(source: String, expression: String) -> PackedStringArray:
	var pattern := RegEx.new()
	pattern.compile(expression)
	var result := PackedStringArray()
	for matched: RegExMatch in pattern.search_all(source):
		result.append(matched.get_string())
	return result


## 日本語追加在 English 后；更改地区后保存、重读与无效配置保护均有效。
func _test_settings() -> void:
	_check(GameSettings.SUPPORTED_LANGUAGES == ["zh_CN", "zh_HK", "es", "en", "ja"], "日语地区排在英语之后")
	_check(GameSettings.LANGUAGE_LABELS == ["简体中文", "繁體中文", "Español", "English", "日本語"], "语言选择保持自名和顺序")
	var path := _directory.path_join("settings.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"format_version": 1, "audio": {"master_volume": 0.35}, "interface": {"language": "en", "player_note": "main() { move(0, 3) }"}, "future": {"name": "作者のマップ"}}))
	file.close()
	var settings := GameSettings.new(path)
	var bytes := FileAccess.get_file_as_bytes(path)
	_check(settings.load_settings().is_ok() and settings.language == "en", "旧英文偏好原样读取")
	_check(FileAccess.get_file_as_bytes(path) == bytes, "载入不会自动改写旧设置")
	_check(settings.set_language("ja").is_ok() and TranslationServer.get_locale() == "ja", "日语立即保存和应用")
	var restored := GameSettings.new(path)
	_check(restored.load_settings().is_ok() and restored.language == "ja" and is_equal_approx(restored.volume, 0.35), "日语与音量跨重启保留")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved.interface.player_note == "main() { move(0, 3) }" and saved.future.name == "作者のマップ", "玩家文本和扩展字段不翻译")
	bytes = FileAccess.get_file_as_bytes(path)
	_check(not settings.set_language("ja_JP").is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "未知配置地区不覆盖有效设置")


## 每条指令具有真实日语资料，地区别名回退正确，DSL 例子未被翻译。
func _test_commands() -> void:
	var catalog := CommandCatalog.new()
	_check(catalog.load_directory().is_ok() and catalog.entries.size() == 27, "二十七项指令资料仍完整载入")
	for entry: Dictionary in catalog.entries:
		for field: String in ["category_title", "title", "description"]:
			_check(entry[field].has("ja") and not str(entry[field]["ja"]).is_empty(), "指令日语字段完整：" + str(entry.id) + "/" + field)
			_check(CommandCatalog.localized(entry, field, "ja-JP") == entry[field]["ja"], "日语地区变体选择正确资料：" + str(entry.id))
		var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(entry.source_path))
		_check(entry.syntax == raw.syntax, "指令语法保持原文：" + str(entry.id))
	var registry := ContentRegistry.new()
	_check(registry.load_directories().is_ok(), "真实模块目录加载成功")
	_check(catalog.sections(registry, "ja")[0].title == "プログラミングの基礎", "指令基础分类已翻译")
	var matches := catalog.search("ループ", registry, "ja")
	var found := false
	for entry: Dictionary in matches:
		found = found or entry.id == "loop"
	_check(found, "日语关键词可搜索循环指令")


## 动态报错仅翻译外层模板，保留行列、模块名与玩家百分号内容。
func _test_diagnostics() -> void:
	TranslationServer.set_locale("ja")
	var source := "名称“%s”尚未声明或不在当前作用域中。"
	var name := "作者_%s_%d_main()"
	var actual := GameI18n.translate_errors(PackedStringArray(["第 12 行，第 4 列：" + source % name]))
	_check(actual.ends_with(GameI18nJA.MESSAGES[source] % name) and actual.contains("12") and actual.contains("4"), "动态诊断翻译并保留源码位置与玩家名称")
	var code := CodeEdit.new()
	code.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	code.text = "main() {\n    // プレイヤーのコード\n    move(0, 3)\n}"
	root.add_child(code)
	var before := code.text
	GameI18n.localize_text_edit_menu(code)
	_check(code.text == before and code.atr("设置") == "设置", "代码区域原文不参与翻译")
	_check(code.get_menu().atr("Copy") == "コピー", "代码右键菜单使用日语")
	code.queue_free()


## 用真实选择器确认第五项可以选择，切换后界面文本即时更新且原生菜单不截项。
func _test_selector() -> void:
	var settings := GameSettings.new(_directory.path_join("selector.json"))
	settings.load_settings()
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.theme = GameTheme.create_theme()
	panel.size = Vector2(1280, 800)
	root.add_child(panel)
	await _settle()
	var option := panel.find_child("LanguageOption", true, false) as OptionButton
	_check(option != null and option.item_count == 5, "设置显示五个语言选项")
	option.select(4)
	option.item_selected.emit(4)
	await _settle()
	_check(settings.language == "ja" and option.get_item_text(4) == "日本語", "真实选择器选择日本語")
	_check(panel.tr("地图编辑器") == GameI18nJA.MESSAGES["地图编辑器"], "界面立即采用日语")
	var scroll := panel.find_child("SettingsScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(option)
	await _settle()
	option.show_popup()
	await _settle()
	var popup := option.get_popup()
	_check(popup.visible and popup.item_count == 5 and popup.get_item_text(3) == "English" and popup.get_item_text(4) == "日本語", "弹出菜单完整显示日语在英语后")
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(Rect2(Vector2(popup.position), Vector2(popup.size))), "语言弹出菜单位于视口内")
	popup.hide()
	panel.queue_free()
	await _settle()


## 故障页不依赖完整游戏加载，仍从独立已存偏好显示日语错误。
func _test_startup() -> void:
	var startup: CanvasLayer = load("res://scripts/ui/startup_loader.gd").new()
	startup.settings_path = _directory.path_join("settings.json")
	startup.scene_path = "res://scenes/missing_japanese_test.tscn"
	root.add_child(startup)
	for unused in 120:
		if startup.get("phase") == "failed":
			break
		await process_frame
	_check(startup.get("phase") == "failed" and startup.get("_message").text == "起動用リソースが見つかりません。", "早期启动错误使用日语")
	_check(startup.find_child("StartupRetry", true, false).text == "再試行", "早期重试按钮使用日语")
	startup.queue_free()
	await _settle()


## 等待翻译通知和容器重排结束后再读取实际尺寸。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 清理限定本次独占目录，不触碰正式玩家配置。
func _remove_tree(path: String) -> void:
	if not path.begins_with(_directory):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	for child in directory.get_files():
		directory.remove(child)
	DirAccess.remove_absolute(path)


## 汇总错误并以非零退出状态交给完整回归脚本。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
