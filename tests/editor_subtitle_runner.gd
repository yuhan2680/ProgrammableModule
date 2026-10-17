extends SceneTree
## 副标题覆盖实际输入、光标、保存、试玩及正式关卡页头，所有用户目录隔离。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _editor: MapEditor
var _field: LineEdit


## 就绪后创建真实编辑器，可选导出实际 GPU 截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 实际表单输入后沿正式保存与组装编程路径验证显示。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/editor_subtitle_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	_game._editor_discard_dialog.use_native_dialog = false
	_editor = _game._editor
	_editor._load_document(MapEditor.DEFAULT_MAP_PATH) # 此回归需要有出生点的既有地图夹具。
	_field = _editor._subtitle_field
	_check(_field.caret_blink and is_equal_approx(_field.caret_blink_interval, 0.5) and _field.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "副标题使用正常闪烁光标且原文不翻译")
	_check(_field.text.is_empty() and not _editor.editor_document.is_dirty(), "旧地图缺省留空不自动改写")
	await _test_input()
	await _test_save_and_focus()
	await _test_layout()
	await _test_playtest()
	await _test_formal_level()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("副标题编辑界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 键入表情即时过滤，中文和粘贴在过滤后限长；中间光标不被推到末尾。
func _test_input() -> void:
	_field.grab_focus()
	_field.text = ""
	_type_codepoint(0x4E2D)
	_type_codepoint(0x6587)
	_type_codepoint(0x1F600)
	await _settle()
	_check(_field.text == "中文" and _field.has_focus(), "真实 Unicode 键盘输入保留中文并移除表情")
	for unit: String in ["中", "x"]:
		_set_text("😀".repeat(20) + unit.repeat(71))
		_check(_field.text == unit.repeat(70), "混合粘贴先去表情再限七十字符 " + unit)
	_set_text("前😀后", 2)
	_check(_field.text == "前后" and _field.caret_column == 1, "过滤中间表情后光标仍留在同一文字位置")
	_set_text("目标：到达终点。")
	_check(_editor.editor_document.get_subtitle().is_empty(), "正在输入只改表单，未提交不创建文档历史")


## 未失焦保存和卡片空白点击提交同一字段，历史及重新打开完整往返。
func _test_save_and_focus() -> void:
	var model := _editor.editor_document
	_set_text("限时目标：清除全部敌人。")
	_field.grab_focus()
	_editor._save_document(false)
	var loaded := MapCodec.load_file(model.path, _editor.registry, false)
	_check(loaded.is_ok() and loaded.value.properties.level.subtitle == _field.text and not model.is_dirty(), "仍聚焦时保存也提交副标题并写盘")
	_field.release_focus()
	model.undo()
	await _settle()
	_check(model.get_subtitle().is_empty() and _field.text.is_empty(), "撤销同步移除副标题")
	model.redo()
	await _settle()
	_check(_field.text == "限时目标：清除全部敌人。" and not model.is_dirty(), "重做回到保存点同步表单")
	_field.grab_focus()
	_set_text("新的副标题，空白点击提交。")
	_click(_editor._properties_card.get_global_rect().position + Vector2(18, 6))
	await _settle()
	_check(not _field.has_focus() and model.get_subtitle() == "新的副标题，空白点击提交。", "点卡片空白真正失焦并提交")
	_editor._save_document(false)
	var path := model.path
	_editor._load_document(path)
	await _settle()
	_check(_field.text == "新的副标题，空白点击提交。" and not model.is_dirty(), "重新打开副标题原文回填")
	_set_text("限时目标：清除全部敌人。")
	_editor._commit_identity()
	await _capture("editor-subtitle")


## 最小窗口、三种语言及高字号仍完整容纳输入框，并保持身份字段的上下顺序。
func _test_layout() -> void:
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	for dimensions: Vector2i in [Vector2i(1000, 740), Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(3840, 2160)]:
		if DisplayServer.get_name() != "headless" and (dimensions.x > DisplayServer.screen_get_usable_rect().size.x or dimensions.y > DisplayServer.screen_get_usable_rect().size.y):
			continue
		root.size = dimensions
		for language: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(language)
			for percentage: int in [100, 125, 200]:
				_game.settings.set_ui_scale(percentage)
				await _settle()
				scroll.ensure_control_visible(_field)
				await _settle()
				var context := str(dimensions) + language + str(percentage)
				_check(scroll.get_global_rect().grow(1).encloses(_field.get_global_rect()), "副标题完整留在卡片滚动区 " + context)
				_check(_field.get_theme_font_size("font_size") == roundi(12 * percentage / 100.0), "副标题随全局真实字号更新 " + context)
				var identity := _editor.find_child("MapEditorIdentityRow", true, false) as Control
				var creator := _editor.find_child("MapEditorCreatorRow", true, false) as Control
				_check(_field.get_global_rect().position.y >= identity.get_global_rect().end.y and _field.get_global_rect().end.y <= creator.get_global_rect().position.y, "副标题位于名称与创作者之间 " + context)
	_game.settings.set_language("zh_CN")
	_game.settings.set_ui_scale(100)
	root.size = Vector2i(1280, 800)
	await _settle()


## 当前未保存输入进入真实试玩页头；语言切换保留作者原文，清空恢复系统目标说明。
func _test_playtest() -> void:
	_set_text("限时目标：清除全部敌人。")
	_field.grab_focus()
	_editor._start_playtest()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level.subtitle == "限时目标：清除全部敌人。", "未失焦副标题进入试玩快照")
	await _confirm_assembly()
	if _game.workbench == null:
		return
	var header := _game.workbench.header
	_check(header.goal_label.text == "限时目标：清除全部敌人。" and header.goal_label.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "编程标题下显示用户副标题而非生成目标")
	_game.settings.set_language("en")
	await _settle()
	_check(header.goal_label.text == "限时目标：清除全部敌人。" and header.goal_label.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "切换英文仍显示用户中文原文")
	await _capture("play-subtitle")
	_game._return_to_editor()
	await _settle()
	_set_text("")
	_editor._start_playtest()
	await _settle()
	await _confirm_assembly()
	if _game.workbench != null:
		_check(_game.workbench.header.goal_label.text == _game.workbench._goal_text() and _game.workbench.header.goal_label.auto_translate_mode != Node.AUTO_TRANSLATE_MODE_DISABLED, "清空副标题恢复默认目标和系统翻译")
	_game._return_to_editor()
	await _settle()


## 保存后的正式玩家关卡也使用同一字段，不依赖编辑器试玩状态。
func _test_formal_level() -> void:
	_set_text("本关副标题：先移动，再攻击。")
	_editor._save_document(false)
	var loaded := MapCodec.load_file(_editor.editor_document.path, _editor.registry)
	if not _check(loaded.is_ok(), "正式玩家关卡重新载入"):
		return
	var level := LevelDefinition.from_document(loaded.value, _editor.registry, _editor.editor_document.path)
	if not _check(level.is_ok(), "正式关卡定义构造成功"):
		return
	_game._enter_level(level.value)
	await _settle()
	await _confirm_assembly()
	_check(_game.workbench != null and _game.workbench.header.goal_label.text == "本关副标题：先移动，再攻击。", "正式关卡显示保存的副标题")


## 复用正常空装配与确认按钮进入编程，不能跳过出生占地校验。
func _confirm_assembly() -> void:
	_game._dialogue_dialog.hide()
	_game.session.assembly.add_module("movement", Vector2.ZERO)
	_game._confirm_assembly_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.PLAY, "实际组装确认进入编程")


## 明确模拟已提交文本信号，粘贴与输入过滤共用此入口，不修改系统剪贴板。
func _set_text(text: String, caret: int = -1) -> void:
	_field.text = text
	_field.caret_column = text.length() if caret < 0 else caret
	_field.text_changed.emit(text)


## 经实际视口分发 Unicode 按键，验证原生 LineEdit 的正常输入与焦点路径。
func _type_codepoint(code: int) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.pressed = pressed
		event.unicode = code
		root.push_input(event, true)


## 使用当前全局矩形提交点击，不缓存滚动前的坐标。
func _click(point: Vector2) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)


## 等待两轮以上容器和字体排版完成。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 捕获真实 GPU 画面，headless 不生成模拟截图。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(root.get_texture().get_image().save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存实际画面 " + filename)


## 只清理本次用户测试目录，符号链接不递归。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.list_dir_begin()
	var entry := folder.get_next()
	while not entry.is_empty():
		var child := path.path_join(entry)
		if folder.is_link(entry) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		entry = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 失败明确累加并输出原因，避免脚本运行错误被零退出码掩盖。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
