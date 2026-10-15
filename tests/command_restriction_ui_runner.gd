extends SceneTree
## 真实编辑器开关、目录刷新、文件往返与执行入口回归；本轮存储全部隔离。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _capture_dir := ""


## 可选真实 GPU 截图，随后建立正式编辑器与独占设置目录。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 验证开关含义、布局、依赖历史、保存与试玩的真实执行路径。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/command_restriction_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	var editor := _game._editor
	var model := editor.editor_document
	var menu := editor._command_menu
	var button := editor._command_button
	var row := editor.find_child("MapEditorCommandManagement", true, false) as ResponsivePropertyRow
	var label := editor.find_child("MapEditorCommandManagementLabel", true, false) as Label
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	var original := model.document.to_dict()
	_check(label.text == "管理关卡中允许使用的指令集" and row.alignment == BoxContainer.ALIGNMENT_CENTER, "最新入口文字与加号作为一组居中")
	_check(not model.is_dirty() and not model.can_undo(), "旧地图打开不写入白名单或历史")
	scroll.ensure_control_visible(button)
	await _settle()
	var group_center := (label.get_global_rect().position.x + button.get_global_rect().end.x) * 0.5
	_check(absf(group_center - row.get_global_rect().get_center().x) < 1.1 and absf(label.get_global_rect().get_center().y - button.get_global_rect().get_center().y) < 1.1, "文字加号整体水平居中且纵向同心")
	await _capture("command-editor.png")
	_click(button.get_global_rect().get_center())
	await _settle()
	_check(menu.is_open() and menu.catalog.entries.size() == 27, "真实加号打开配置中的全部27条指令")
	_check(menu._panel.position.y < button.global_position.y and menu._panel.size.y > 600, "低处入口打开足高的指令集窗口")
	_check(menu._glass.material is ShaderMaterial and menu.header._title.text == "管理关卡中允许使用的指令集", "新窗口沿用玻璃与管理标题")
	_check(model.document.to_dict() == original, "浏览目录不会改写地图")
	var main_switch: SettingsSwitch = menu._command_switches.get("main")
	_check(main_switch != null and main_switch.disabled and main_switch.button_pressed, "main必要入口一直开启且不能关闭")
	menu.select_section("movement")
	await _settle()
	_check(menu._displayed_entries.size() == 2 and menu._command_switches.has("move") and menu._command_switches.has("named_move"), "移动模块直接列出既有配置的广播与具名指令")
	var broadcast: SettingsSwitch = menu._command_switches.move
	_click(broadcast.get_global_rect().get_center())
	await _settle()
	_check(not broadcast.button_pressed and not "move" in model.get_enabled_commands(editor.registry), "关闭开关真正限制广播移动")
	var named: SettingsSwitch = menu._command_switches.named_move
	_click(named.get_global_rect().get_center())
	await _settle()
	var enabled := model.get_enabled_commands(editor.registry)
	_check(named.button_pressed and "named_move" in enabled and "named_calls" in enabled and not "move" in enabled, "开启具名移动只联动必要前提，不打开广播移动")
	var selected := model.document.to_dict()
	model.undo()
	_check(not named.button_pressed and not "named_move" in model.get_enabled_commands(editor.registry), "依赖开关作为一次事务撤销并同步界面")
	model.redo()
	_check(named.button_pressed and model.document.to_dict() == selected, "重做恢复完整允许集合")
	_key(KEY_S, true)
	await _settle()
	_check(model.document.to_dict() == selected and model.path == MapEditor.DEFAULT_MAP_PATH, "窗口内保存快捷键不泄漏给地图表单")
	await _capture("command-movement.png")
	_click(menu.header.search_button.get_global_rect().get_center())
	await create_timer(0.25).timeout
	menu.header.search_input.text = "onDetected"
	menu.header.search_input.text_changed.emit("onDetected")
	await _settle()
	_check(menu._command_switches.has("radar_event"), "未开放的雷达事件仍可在管理搜索中出现")
	menu.header.search_input.clear()
	menu.header.search_input.text_changed.emit("")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not menu.is_open() and not button.has_focus(), "Esc关闭整层且不保留鼠标蓝框")
	var outside_snapshot := model.document.to_dict()
	_click(button.get_global_rect().get_center())
	await _settle()
	_click(Vector2(500, 35))
	await _settle()
	_check(not menu.is_open() and model.document.to_dict() == outside_snapshot, "外部按下抬起关闭窗口，不穿透绘图或修改地图")
	for language: String in ["en", "zh_HK", "zh_CN"]:
		_game.settings.set_language(language)
		await _settle()
		_check(model.document.to_dict() == outside_snapshot and row.size.x <= editor._properties_card.size.x, "三语入口不改写数据或撑宽属性卡：" + language)
	_game.settings.set_language("zh_CN")
	await _settle()
	model.set_restricted_modules([], editor.registry)
	_check(model.set_enabled_commands(["main", "named_move"], editor.registry).is_ok(), "设定仅允许具名移动的完整策略")
	editor._save_document(false)
	var saved_path := model.path
	_check(saved_path.begins_with(_temporary) and not model.is_dirty(), "普通保存将允许指令写入隔离玩家目录")
	editor._load_document(saved_path)
	await _settle()
	_check(model.get_enabled_commands(editor.registry) == PackedStringArray(["main", "named_calls", "named_move"]), "重开保存文件完整恢复白名单")
	await _test_session_and_completion(editor, saved_path)
	var before_playtest := model.document.to_dict()
	_check(model.set_command_enabled("random", true, editor.registry).is_ok(), "未保存修改开启随机小数")
	var snapshot := model.document.to_dict()
	editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level.has_command_policy and "random" in _game.session.level.enabled_commands, "未保存策略进入真实试玩会话")
	_check(not menu.is_open(), "进入试玩前关闭CanvasLayer菜单")
	_game._return_to_editor()
	await _settle()
	_check(model.document.to_dict() == snapshot and model.is_dirty() and model.can_undo(), "试玩返回保留未保存策略与历史")
	model.undo()
	_check(model.document.to_dict() == before_playtest, "试玩之后仍可撤销允许指令修改")
	await _test_dynamic_catalog(editor)
	editor._new_document()
	_check(not model.document.properties.level.has("enabled_commands") and not model.can_undo(), "新建地图清理之前策略并保持旧默认能力")
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("COMMAND_RESTRICTION_UI_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 正式GameSession读取已保存策略，补全与资料权限跟随，手写代码也不能绕过。
func _test_session_and_completion(editor: MapEditor, saved_path: String) -> void:
	var loaded := MapCodec.load_file(saved_path, editor.registry, true)
	_check(loaded.is_ok(), "已保存玩家关卡完整校验")
	if not loaded.is_ok():
		return
	var definition := LevelDefinition.from_document(loaded.value, editor.registry, saved_path)
	_check(definition.is_ok(), "已保存玩家关卡可建立定义")
	if not definition.is_ok():
		return
	var session := GameSession.create(definition.value, editor.registry)
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "正式会话真实安装移动模块")
	session.source = "main(){move(0,1)}"
	var blocked := session.run()
	_check(not blocked.is_ok() and session.world == null and session.source == "main(){move(0,1)}", "手动输入被禁广播在创建世界前拒绝且保留源码")
	session.source = "main(){drive.move(0,1)}"
	_check(session.run().is_ok(), "已允许的具名移动正常运行")
	session.stop()
	_check(_completion("main(){mo|}", session.level, session.assembly).is_empty(), "补全不会提示已禁用广播")
	_check(_completion("main(){drive.mo|}", session.level, session.assembly) == "ve", "允许的具名移动仍可补全")
	var catalog := CommandCatalog.new()
	catalog.load_directory()
	for entry: Dictionary in catalog.entries:
		if entry.id in ["move", "named_move"]:
			_check(CommandCatalog.is_available(entry, session.level, editor.registry) == (entry.id == "named_move"), "正常阅读目录也按显式允许策略显示：" + entry.id)
	var all := LevelDefinition.from_document(session.level.document, editor.registry).value as LevelDefinition
	all.has_command_policy = true
	all.enabled_commands = PackedStringArray(["main", "constants", "random_int"])
	all.allow_variables = true
	all.allow_random = true
	_check(_completion("co|", all, session.assembly) == "nstant" and _completion("var|", all, session.assembly).is_empty(), "常量和变量补全独立控制")
	_check(_completion("main(){constant x=randomI|}", all, session.assembly) == "nt" and _completion("main(){constant x=rand|}", all, session.assembly) == "omInt", "randomInt独立允许，不优先补出被禁random")
	_check(_completion("main(){constant x=1\nconstant y=x|}", all, session.assembly).is_empty(), "完整的普通x变量引用不会误当雷达字段")
	all.enabled_commands = PackedStringArray(["main", "move", "constants", "functions"])
	all.allow_functions = true
	_check(_completion("function drive(){move(0,1)}\nmain(){dr|}", all, session.assembly) == "ive", "同名模块不会吞掉已允许的用户函数候选")
	_check(_completion("constant EnemyPosition=1\nmain(){move(EnemyP|,1)}", all, session.assembly) == "osition", "合法常量名称不会误当未启用的事件关键字")
	_check(_completion("constant onDetected=1\nmain(){move(onD|,1)}", all, session.assembly) == "etected", "合法绑定优先于上下文成员关键字")
	all.enabled_commands = PackedStringArray(["main", "constants", "random_int"])
	_check(_completion("main(){move(0,randomI|)}", all, session.assembly).is_empty(), "禁止动作的参数位置不会引导输入可用随机函数")
	_check(_completion("variable hidden=randomI|", all, session.assembly).is_empty(), "禁止变量声明的右侧不提供误导候选")


## 新配置每次打开自动出现；当前解释器未知的资料可见但不能开启执行。
func _test_dynamic_catalog(editor: MapEditor) -> void:
	var directory := _temporary.path_join("commands")
	DirAccess.make_dir_recursive_absolute(directory)
	var entry: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/commands/020_move.json"))
	entry.id = "future_command"
	entry.title.zh_CN = "未来指令资料"
	entry.syntax = "futureMove(angle, distance)"
	var file := FileAccess.open(directory.path_join("future.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(entry))
	file.close()
	var menu := editor._command_menu
	menu.catalog_directory = directory
	editor._open_command_restrictions()
	menu.select_section("movement")
	await _settle()
	_check(menu._command_switches.has("future_command") and menu._command_switches.future_command.disabled, "新JSON资料自动同步且不冒充新执行语法")
	entry.id = "move"
	file = FileAccess.open(directory.path_join("supported.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(entry))
	file.close()
	menu.close_menu(false)
	editor._open_command_restrictions()
	menu.select_section("movement")
	await _settle()
	_check(menu._command_switches.has("move") and not menu._command_switches.move.disabled, "再次打开自动重扫新增的既有语法配置")
	var modules_directory := _temporary.path_join("modules")
	DirAccess.make_dir_recursive_absolute(modules_directory)
	var module: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/modules/movement.json"))
	module.id = "future_movement"
	module.display_name = "新增移动模块"
	file = FileAccess.open(modules_directory.path_join("future_movement.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(module))
	file.close()
	var expanded := ContentRegistry.new()
	_check(expanded.load_directories(PackedStringArray(["res://data/modules", modules_directory]), PackedStringArray(["res://data/tiles"])).is_ok(), "新增模块配置通过真实注册表加载")
	menu.show_commands(editor._command_button, expanded, editor.editor_document.get_enabled_commands(editor.registry))
	menu.select_section("future_movement")
	await _settle()
	_check(menu._selected_section_key == "module:future_movement" and menu._command_switches.has("move") and menu._command_switches.has("future_command"), "新增模块自动出现目录并显示匹配行为的既有指令")
	menu.close_menu(false)
	menu.catalog_directory = "res://data/commands"


## 光标标记转换为实际行列，调用纯补全策略而不修改程序。
func _completion(marked: String, level: LevelDefinition, assembly: AssemblyModel) -> String:
	var position := marked.find("|")
	var before := marked.left(position).split("\n")
	return ProgramCompletion.suggest(marked.replace("|", ""), before.size() - 1, before[before.size() - 1].length(), level, assembly)


## 可选真实GPU图像仅保存本轮生成的测试窗口，不读取用户屏幕。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename)) == OK, "保存指令管理真实截图：" + filename)


## 真实GUI输入覆盖按下与抬起，测试浮层是否正确消费完整点击。
func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event, true)


## 快捷键沿用窗口与编辑器的真实输入链。
func _key(key: Key, modifier: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		event.ctrl_pressed = modifier
		root.push_input(event, true)


## 等待控件布局与延后同步，不模拟任意墙钟等待。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 失败项汇总为可验证退出状态。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 仅清理本轮独占目录，禁止访问正式玩家设置与存档。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in folder.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
