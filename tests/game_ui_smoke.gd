extends SceneTree
## 实际游戏场景的端到端冒烟测试。文件与系统交互均注入测试专属替身。

const SOLUTION := "main() {\n    move(0, 4)\n    move(90, 3)\n    move(180, 4)\n    move(90, 3)\n    move(0, 4)\n}\n"

var _checks: int = 0
var _failures: int = 0
var _opened_paths: Array[String] = []
var _test_directory: String
var _quit_requests: int = 0


## 等待场景树进入可添加节点的阶段，再启动 UI 测试。
func _initialize() -> void:
	_run.call_deferred()


## 依次覆盖关卡页、导入、编程、组装、通关、草稿恢复和地图编辑器入口。
func _run() -> void:
	_test_directory = "user://tests/game_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _test_directory.path_join("levels")
	game.drafts_directory = _test_directory.path_join("solutions")
	game.settings_path = _test_directory.path_join("settings.json")
	game.folder_opener = _record_folder_open
	game.quit_handler = _record_quit
	root.add_child(game)
	await process_frame
	await process_frame
	_check(not game._message_dialog.visible, "启动没有错误提示")
	_check(game.page == GameShell.Page.MAIN and game.session == null, "启动停在开始页面")
	_check(not game._header.visible, "开始页隐藏重复页头")
	for button_name in ["StartGameButton", "MapEditorButton", "SettingsButton", "LeaveGameButton"]:
		_check(game.find_child(button_name, true, false) != null, "开始页包含入口：" + button_name)
	await _capture("start_page")
	await _test_settings_page(game)
	await _test_clear_builtin_progress(game)
	await _test_clear_user_levels(game)
	game.find_child("StartGameButton", true, false).pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.LEVELS, "开始游戏按钮进入关卡网格页")
	_check(not game._header.visible and game._level_header.is_visible_in_tree() and game.find_child("LevelBackButton", true, false).is_visible_in_tree(), "选关页使用新的图标页头和返回入口")
	_check(_find_button(game._body, "地图编辑器") == null, "关卡页不再放地图编辑器入口")
	game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(game.page == GameShell.Page.LEVELS, "选关页重新聚焦只刷新关卡")
	_check(game.catalog.levels.size() == 15 and game.catalog.levels[0].id == "level_001" and game.catalog.levels[14].id == "level_015" and game.catalog.levels[14].order == 15, "初始包含第一至第十五关，编辑器样例未加入列表")
	await _test_level_categories(game)
	await _test_level_actions_menu(game)
	_test_level_thumbnails(game)
	await _capture("level_select")
	var import_button: Button = game.find_child("ImportLevelButton", true, false)
	_check(import_button != null, "关卡页存在加号导入按钮")
	var opened_before := _opened_paths.size()
	import_button.pressed.emit()
	_check(_opened_paths.size() == opened_before + 1, "点击加号确实调用一次打开目录接口")
	_check(DirAccess.dir_exists_absolute(_opened_paths[0]), "导入目录在打开前已创建")
	_check(_opened_paths[0] == ProjectSettings.globalize_path(game.user_levels_directory), "打开的正是游戏扫描的关卡文件夹")
	_check(game._import_dialog.visible and game._import_dialog.dialog_text.contains("拖入"), "提示拖入关卡文件及刷新方法")
	await _capture("level_import")
	await _test_import_cancel(game)
	# 放入有效与错误文件，验证一个坏文件不会影响内置关卡和其他有效导入。
	var custom := game.catalog.levels[0].document.duplicate_document()
	custom.id = "ui_imported_level"
	custom.display_name = "导入测试"
	_check(MapCodec.save_file(custom, game.user_levels_directory.path_join("custom.json"), game.registry).is_ok(), "写入自定义关卡文件")
	var invalid := FileAccess.open(game.user_levels_directory.path_join("broken.json"), FileAccess.WRITE)
	invalid.store_string("{broken JSON")
	invalid.close()
	game._import_dialog.confirmed.emit()
	game._import_dialog.hide()
	_check(game.catalog.levels.size() == 16 and game.catalog.levels[15].id == "ui_imported_level" and not game.catalog.errors.is_empty(), "刷新后有效导入出现在列表，错误文件单独报告")
	var imported_button := game.find_child("LevelButton_15", true, false) as Button
	_check(imported_button != null and imported_button.icon != null and imported_button.text.is_empty(), "导入地图自动得到缩略图，无需单独提供图标")
	var imported_grid := game.find_child("ImportedLevelGrid", true, false) as GridContainer
	import_button = game.find_child("ImportLevelButton", true, false) as Button
	_check(imported_grid != null and import_button.get_parent().get_parent() == imported_grid and import_button.get_parent().get_index() == 0, "导入按钮始终位于独立导入网格第一格")
	_check(imported_button != null and imported_button.get_parent().get_parent() == imported_grid and imported_button.get_parent().get_index() == 1 and imported_button.is_visible_in_tree(), "自定义关卡跟随导入按钮，教学折叠不隐藏导入关卡")
	_check(_visible_tutorial_count(game) == 7 and _tutorial_toggle_text(game) == "展示更多（15）", "导入关卡不计入教学总数，也不改变默认七张教学卡片")
	var first: LevelDefinition = game.catalog.levels[0]
	var original_map := JSON.stringify(first.document.to_dict(), "", true)
	await _test_assembly_validity(game, first)
	var first_button := game.find_child("LevelButton_0", true, false) as Button
	_check(first_button != null, "关卡网格图标可点击")
	# 注册表包含额外类型时，目录仍应展示它，但不能绕过当前地图的允许列表。
	var unavailable := ModuleDefinition.new()
	unavailable.id = "unavailable_test_module"
	unavailable.display_name = "本关未解锁的测试模块"
	unavailable.texture = game.registry.get_module("movement").texture
	game.registry.modules[unavailable.id] = unavailable
	first_button.pressed.emit()
	await process_frame
	_check(game.session != null and game.page == GameShell.Page.ASSEMBLY and game._dialogue_dialog.visible, "点击第一关先组装并显示地图对话")
	_finish_dialogue(game)
	_check(not game._dialogue_dialog.visible, "逐句阅读后可以开始编辑")
	_check(game.session.assembly.modules.is_empty() and game.workbench == null, "进入关卡不预装模块，也不提前创建编程页")
	_check(game._confirm_assembly_button.disabled, "空装配禁用开始编程按钮")
	_check(game._confirm_assembly_button.get_tooltip().contains("至少"), "空装配确认按钮通过中文悬停提示说明原因")
	_check(game.assembly_panel.palette_buttons.size() == game.registry.modules.size(), "左侧目录展示全部注册模块，不按关卡允许列表隐藏")
	_check(game.assembly_panel.palette_buttons[unavailable.id].disabled, "未解锁模块保留可见且禁用")
	game.assembly_panel.palette_buttons[unavailable.id].pressed.emit()
	_check(game.session.assembly.modules.is_empty(), "程序化点击未解锁条目也不会装入模块")
	game._confirm_assembly()
	_check(game.page == GameShell.Page.ASSEMBLY, "空装配不能绕过确认校验")
	await _test_preparation_toolbar_and_commands(game)
	await _capture("assembly_preparation")
	var preparation_canvas := game.assembly_panel.canvas
	var preparation_origin := preparation_canvas.pixel_at(Vector2(0.5, 0))
	_stroke(preparation_canvas, preparation_origin, MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1 and not game._confirm_assembly_button.disabled, "中心外首次放置也可建立合法装配")
	_check(game.session.assembly.modules.size() == 1 and preparation_canvas.pixel_at(Vector2.ZERO).is_equal_approx(preparation_origin) and game.session.assembly.modules[0].offset == {"x": 0.0, "y": 0.0}, "点击位置成为显示原点，首件保存为逻辑零偏移")
	_stroke(preparation_canvas, preparation_canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1 and not game._confirm_assembly_button.disabled, "再次点击首件仅选中，保持装配可确认")
	_check(game.assembly_panel.palette_buttons["movement"].disabled and not preparation_canvas.can_place, "达到上限时目录与画布新增入口均禁用")
	_stroke(preparation_canvas, preparation_canvas.pixel_at(Vector2(1, 0)), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1, "准备阶段达到地图上限后不能再放模块")
	_drag(preparation_canvas, Vector2.ZERO, Vector2(0, -1))
	_check(is_zero_approx(float(game.session.assembly.modules[0].offset.y)) and not game._confirm_assembly_button.disabled, "唯一模块拖离中心会被拒绝，原有合法装配仍可确认")
	_check(game._confirm_assembly_button.icon != null and game._confirm_assembly_button.text.is_empty(), "合法装配继续使用图标确认入口")
	game.assembly_panel.header.book_button.pressed.emit()
	_check(game._command_menu.is_open(), "页面切换前指令菜单处于打开状态")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	_check(not game._command_menu.is_open(), "进入编程时关闭装配指令菜单，释放输入屏障")
	game.workbench.set_process(false)
	_check(game.page == GameShell.Page.PLAY, "确认合法装配后进入编程工作台")
	_check(game.workbench._code.text.contains("main()"), "代码编辑器有可运行的入口模板")
	await _capture("level_program")
	var workbench := game.workbench
	await _test_program_toolbar(game)
	await _test_return_to_assembly(game)
	# 返回组装会替换工作台节点，后续流程必须使用确认后创建的当前节点。
	workbench = game.workbench
	workbench._code.text = "main() {\n    move(0, 1);\n}\n"
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.FAILED and game.session.world == null, "语法错误阻止世界运行")
	_check(workbench._highlighted_line == 1 and workbench._status.text.contains("第 2 行"), "错误行在代码和状态栏同时显示")
	workbench._code.text = first.starter_program
	workbench._tabs.current_tab = 1
	await process_frame
	await process_frame
	_check(not workbench._world_panel.visible and workbench._tabs.size.x > 1000, "组装页签暂时隐藏地图，目录与网格使用整行宽度")
	var canvas := workbench._assembly_panel.canvas
	_delete_at(canvas, Vector2.ZERO)
	_check(game.session.assembly.modules.is_empty(), "选中后 Delete 可以移除玩家安装的模块")
	_check(workbench._run_button.disabled and workbench._run_button.get_tooltip().contains("至少"), "编程页空装配会实时禁用运行并解释原因")
	workbench._run_program()
	_check(game.session.state == GameSession.State.FAILED and workbench._status.text.contains("至少"), "空装配无法运行并提示原因")
	workbench._tabs.current_tab = 1
	await process_frame
	_stroke(canvas, canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1, "在网格中左键安装移动模块")
	_stroke(canvas, canvas.pixel_at(Vector2(1, 0)), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1, "第一关限制一个模块，失败不会偷偷增加")
	_drag(canvas, Vector2.ZERO, Vector2(0.5, 0))
	_check(is_zero_approx(float(game.session.assembly.modules[0].offset.x)), "编程页组装也不能把唯一模块拖离中心")
	workbench._assembly_panel._module_name.text = "my_drive"
	workbench._assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules[0].id == "my_drive", "属性面板可以重命名模块")
	await _capture("level_assembly")
	game.settings.set_language("en")
	await _capture("level_assembly_english")
	game.settings.set_language("zh_CN")
	workbench._code.text = SOLUTION
	await _activate_visible_button(workbench.header.run_button, "通过蓝色图标运行程序")
	_check(workbench.header.run_button.disabled and not workbench.header.pause_button.disabled and not workbench.header.stop_button.disabled, "运行中顶部运行禁用，暂停和停止可用")
	_check(workbench._world_panel.visible and workbench._tabs.current_tab == 0, "运行自动返回程序页并恢复地图观察区")
	_check(game.session.state == GameSession.State.RUNNING, "程序由运行按钮启动")
	_check(not workbench._code.editable and not canvas.interaction_enabled, "运行时锁定程序和装配编辑")
	var active_world := game.session.world
	var active_runner := game.session.runner
	workbench._accumulator = 0.05
	workbench._run_program()
	_check(is_equal_approx(workbench._accumulator, 0.05) and game.session.world == active_world and game.session.runner == active_runner, "运行期间快捷键不会重置时间或替换执行实例")
	game.session.step()
	await _activate_visible_button(workbench.header.pause_button, "通过药丸暂停运行")
	_check(workbench.header.pause_button.get_tooltip() == game.tr("继续") and workbench.header.run_button.disabled, "暂停时图标提示变为继续且不允许重复运行")
	workbench._accumulator = 0.05
	workbench._run_program()
	_check(is_equal_approx(workbench._accumulator, 0.05) and game.session.world == active_world and game.session.runner == active_runner and game.session.state == GameSession.State.PAUSED, "暂停期间快捷键保留累计时间和同一次运行")
	var paused_tick := game.session.world.tick_index
	game.session.step()
	_check(game.session.state == GameSession.State.PAUSED and game.session.world.tick_index == paused_tick, "暂停不会继续移动")
	await _activate_visible_button(workbench.header.pause_button, "通过药丸继续运行")
	_check(workbench.header.pause_button.get_tooltip() == game.tr("暂停"), "继续后暂停图标提示恢复")
	_check(game.session.state == GameSession.State.RUNNING, "继续恢复同一次运行")
	for tick in range(240):
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED, "五段程序完成第一关")
	_check(game.drafts.is_completed(first.id), "通关标记已写入独立进度")
	_check(workbench._status.text.contains("关卡完成"), "界面展示通关结果")
	_check(JSON.stringify(first.document.to_dict(), "", true) == original_map, "组装和程序运行未改写原关卡")
	await _capture("level_complete")
	_press_back(game)
	await process_frame
	_check(game.session == null and game.workbench == null, "返回按钮回到关卡页")
	_check(_visible_tutorial_count(game) == 7, "从关卡返回后保留教学折叠状态")
	game._enter_level(game.catalog.levels[0])
	await process_frame
	_finish_dialogue(game)
	_check(game.session.source == SOLUTION and game.session.assembly.modules.is_empty(), "重新进入保留程序，但仍先显示空组装台")
	game.find_child("RestoreAssemblyButton", true, false).pressed.emit()
	_check(game.session.assembly.modules[0].id == "my_drive", "玩家可主动载入自己的上次装配")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	game.session.reset()
	_check(game.session.world == null and game.session.source == SOLUTION, "重置位置不清空代码")
	await _test_reset_code(game, first)
	_press_back(game)
	await _test_draft_recovery(game, first)
	await _test_fourth_level(game)
	await _test_fifth_level(game)
	_check(_visible_tutorial_count(game) == 7 and not game._tutorials_expanded, "从默认可见的第五关返回后保留首七关折叠状态")
	await _test_sixth_level(game)
	await _test_seventh_level(game)
	await _test_eighth_level(game)
	await _test_ninth_level(game)
	await _test_twelfth_level(game)
	await _test_thirteenth_level(game)
	await _test_fourteenth_level(game)
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.MAIN, "关卡页返回开始页面")
	game.find_child("MapEditorButton", true, false).pressed.emit()
	await process_frame
	_check(game._editor != null, "旧地图编辑器可以从游戏入口打开")
	var opened_editor := game._editor
	opened_editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "主菜单编辑器的开始测试进入空组装流程")
	_check(game._back_button.get_tooltip().contains("地图编辑器"), "主菜单编辑器试玩提供返回编辑地图入口")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.EDITOR and game._editor == opened_editor, "主菜单编辑器试玩返回同一编辑器面板")
	await _test_reset_code_playtest(game)
	await _test_object_playtest(game)
	await _test_enemy_playtest(game)
	game._editor.editor_document.paint(Vector2i.ZERO, "floor")
	_press_back(game)
	_check(game._editor_discard_dialog.visible and game._editor != null, "编辑地图后返回会保护未保存更改")
	game._editor_discard_dialog.confirmed.emit()
	game._editor_discard_dialog.hide()
	_check(game._editor == null and game.page == GameShell.Page.MAIN, "确认后地图编辑器返回开始页面")
	game.find_child("LeaveGameButton", true, false).pressed.emit()
	_check(_quit_requests == 1, "离开游戏按钮发出一次退出请求")
	game.queue_free()
	await process_frame
	_cleanup(_test_directory)
	print("游戏界面冒烟完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 顶部工具与二级菜单走真实输入，资料阅读不修改程序，运行和保存仍使用原会话。
func _test_program_toolbar(game: GameShell) -> void:
	var workbench := game.workbench
	var header := workbench.header
	var menu := workbench._actions_menu
	var original_source := game.session.source
	var original_modules := JSON.stringify(game.session.assembly.modules)
	var original_drafts := _clear_records_snapshot(game.drafts.directory)
	_check(not game._header.is_visible_in_tree() and not game._subtitle.is_visible_in_tree() and not game._save_label.is_visible_in_tree(), "编程页使用新顶部栏，默认隐藏底部常规保存提示")
	_check(game._back_button == header.back_button and header.run_button == workbench._run_button and header.pause_button == workbench._pause_button and header.stop_button == workbench._stop_button, "外壳与运行句柄连接到新图标工具")
	for button: Button in [header.back_button, header.run_button, header.pause_button, header.stop_button, header.reset_button, header.more_button, header.book_button]:
		_check(button.is_visible_in_tree() and button.text.is_empty() and button.icon != null and not button.get_tooltip().is_empty(), "纯图标工具均保留非空悬停说明：" + str(button.name))
	_check(not header.run_button.disabled and header.pause_button.disabled and header.stop_button.disabled, "编辑状态可运行而暂停、停止禁用")
	# 地图说明通过问号访问，读取与关闭都不能改变当前会话内容。
	var guide := workbench._guide_menu
	var guide_button := workbench._guide_button
	var original_state := game.session.state
	_check(not guide.is_open() and not guide.goal_label.is_visible_in_tree() and not guide.description_label.is_visible_in_tree(), "关卡目标和指引默认从地图卡片中收起")
	_check(guide_button.text.is_empty() and guide_button.get_tooltip() == game.tr("指引") and guide_button.icon != null and guide_button.icon.resource_path.ends_with(".svg") and guide_button.icon.get_width() >= 48, "问号入口采用高分辨率 SVG 和指引悬停名称")
	_check(TranslationServer.translate(header.title_label.text) == TranslationServer.translate(game.session.level.display_name), "关卡本土化名字移到地图卡片外的顶部栏")
	await _activate_visible_button(guide_button, "打开地图指引")
	await create_timer(0.25).timeout
	_check(guide.is_open() and guide.goal_label.is_visible_in_tree() and guide.description_label.is_visible_in_tree() and guide.directions_label.is_visible_in_tree() and guide.terrain_label.is_visible_in_tree(), "指引窗口展示目标、原关卡指导、方向与地形说明")
	_check(TranslationServer.translate(guide.goal_label.text) == TranslationServer.translate(header.goal_label.text) and TranslationServer.translate(guide.description_label.text) == TranslationServer.translate(game.session.level.description) and guide.directions_label.text.contains("90°"), "指引内容复用本关目标和指导并保留角度对照")
	await _menu_click(guide_button.get_global_rect().get_center())
	_check(not guide.is_open(), "重复点击问号关闭指引窗口")
	await _activate_visible_button(guide_button, "再次打开地图指引")
	await _menu_key(KEY_ESCAPE)
	_check(not guide.is_open() and guide_button.has_focus(), "Escape 关闭指引并归还问号焦点")
	await _activate_visible_button(guide_button, "检查指引外点击屏障")
	await _menu_click(header.run_button.get_global_rect().get_center())
	_check(not guide.is_open() and game.session.world == null and game.session.state == original_state, "指引外点击仅关闭窗口，不穿透启动程序")
	_check(game.session.source == original_source and JSON.stringify(game.session.assembly.modules) == original_modules and _clear_records_snapshot(game.drafts.directory) == original_drafts, "阅读和关闭指引保留代码、装配及草稿")
	await _open_program_actions(workbench)
	_check(menu._items.size() == 5 and menu._items[0].has_focus(), "更多菜单提供五项操作并默认聚焦第一项")
	for index in range(1, 5):
		await _menu_key(KEY_DOWN)
		_check(menu._items[index].has_focus(), "方向键访问菜单第 %d 项" % (index + 1))
	await _menu_key(KEY_TAB)
	_check(menu._items[0].has_focus(), "Tab 从最后一项循环回第一项")
	await _menu_key(KEY_ESCAPE)
	_check(not menu.is_open() and header.more_button.has_focus(), "Escape 关闭编程菜单并返回更多按钮焦点")
	await _open_program_actions(workbench)
	await _menu_click(header.run_button.get_global_rect().get_center())
	_check(not menu.is_open() and game.session.world == null and game.session.state == GameSession.State.EDITING, "菜单外点击运行仅关闭菜单，不穿透启动程序")
	await _open_program_actions(workbench)
	await _menu_click(header.more_button.get_global_rect().get_center())
	_check(not menu.is_open(), "重复点击更多按钮可以关闭菜单")
	await _open_program_actions(workbench)
	await _activate_visible_button(menu.find_child("ProgramHelpMenuItem", true, false), "从编程菜单打开关卡说明")
	_check(not menu.is_open() and game._dialogue_dialog.visible, "选择关卡说明后先关闭菜单再打开现有引导")
	_finish_dialogue(game)
	await _activate_visible_button(header.book_button, "从编程顶部打开指令集合")
	_check(game._command_menu.is_open(), "编程页书本入口打开现有资料窗口")
	var reference := game._command_menu
	await _activate_visible_button(reference.header.search_button, "编程资料中搜索指令")
	await create_timer(0.4).timeout
	await _set_command_query(reference, "move")
	_check(not reference._cards.is_empty() and _command_items_collapsed(reference), "编程资料搜索得到折叠指令结果")
	if not reference._cards.is_empty():
		await _activate_visible_button(reference._command_buttons[0], "在编程资料中展开指令")
		await create_timer(0.35).timeout
		_check(reference._details[0].is_visible_in_tree(), "编程资料中可展开功能说明")
	await _menu_key(KEY_ESCAPE)
	await _menu_key(KEY_ESCAPE)
	_check(not reference.is_open() and game.page == GameShell.Page.PLAY and game.session.source == original_source and JSON.stringify(game.session.assembly.modules) == original_modules and _clear_records_snapshot(game.drafts.directory) == original_drafts, "在编程页搜索、阅读和关闭资料不修改代码、装配或草稿")
	# 三个位置控制仍取消旧执行对象，程序与装配保持不变。
	var trial_source := "main() {\n    move(0, 2)\n}\n"
	workbench._code.text = trial_source
	for action in ["stop", "reset", "menu_reset"]:
		await _activate_visible_button(header.run_button, "位置控制回归前启动程序")
		game.session.step()
		var old_runner := game.session.runner
		if action == "menu_reset":
			await _open_program_actions(workbench)
			await _activate_visible_button(menu.find_child("ProgramResetPositionMenuItem", true, false), "从二级菜单重置位置")
			_check(not menu.is_open(), "菜单重置位置后关闭浮层")
		else:
			await _activate_visible_button(header.stop_button if action == "stop" else header.reset_button, "通过顶部图标停止或重置位置")
		_check(old_runner.state == ProgramRunner.State.CANCELLED and game.session.world == null and game.session.runner == null and game.session.source == trial_source and JSON.stringify(game.session.assembly.modules) == original_modules, "位置控制取消旧运行但保留程序和装配：" + action)
		_check(not header.run_button.disabled and header.pause_button.disabled and header.stop_button.disabled, "位置控制结束后顶部恢复编辑状态：" + action)
	workbench._code.text_changed.emit()
	game._save_timer.stop()
	await _open_program_actions(workbench)
	await _activate_visible_button(menu.find_child("SaveProgramDraftMenuItem", true, false), "从二级菜单保存草稿")
	var saved := game.drafts.load_draft(game.session.level.id)
	_check(not menu.is_open() and saved.is_ok() and saved.value != null and saved.value.source == trial_source and JSON.stringify(saved.value.modules) == original_modules, "菜单保存复用现有存储并保存当前代码与装配")
	workbench._code.text = original_source
	workbench._code.text_changed.emit()
	game._save_timer.timeout.emit()


## 更多菜单通过当前页面真实可见的图标按钮打开，避免绕过菜单权限或焦点流程。
func _open_program_actions(workbench: GameWorkbench) -> void:
	await _activate_visible_button(workbench.header.more_button, "打开编程操作菜单")
	_check(workbench._actions_menu.is_open(), "编程更多按钮实际展开操作菜单")


## 模块资料窗只呈现说明；目录选择、搜索和 JSON 扩展均不改变玩家内容。
func _test_preparation_toolbar_and_commands(game: GameShell) -> void:
	var header := game.assembly_panel.header
	_check(game.assembly_panel.preparation_mode and header != null and header.is_visible_in_tree(), "准备页使用独立装配工具栏")
	_check(not game._header.is_visible_in_tree() and not game._save_label.is_visible_in_tree(), "准备页不再保留全局页头与底部保存栏")
	_check(game._back_button == header.back_button and game._confirm_assembly_button == header.confirm_button, "外壳返回和确认句柄连接到实际工具栏")
	for pair in [[header.save_button, "保存草稿文件"], [header.restore_button, "加载已保存的文件"], [header.help_button, "关于说明"], [header.book_button, "指令集合"]]:
		var button: Button = pair[0]
		_check(button.is_visible_in_tree() and button.text.is_empty() and button.icon != null and button.get_tooltip() == game.tr(pair[1]), "纯图标工具保留本土化功能说明：" + pair[1])
	await _activate_visible_button(header.help_button, "装配工具栏打开关卡说明")
	_check(game._dialogue_dialog.visible, "关于说明复用当前关卡引导")
	_finish_dialogue(game)
	var original_source := game.session.source
	var original_modules := JSON.stringify(game.session.assembly.modules)
	var original_drafts := _clear_records_snapshot(game.drafts.directory)
	var menu := game._command_menu
	await _activate_visible_button(header.book_button, "打开指令集合")
	_check(menu.is_open() and menu.catalog.errors.is_empty() and menu.catalog.entries.size() == 27, "书本入口载入含函数、常变量、雷达事件、随机函数与 for 的二十七项 JSON 指令资料")
	_check(menu._section_buttons.size() == game.registry.modules.size() + 1 and menu._selected_section_key == "module:movement", "左目录包含全部模块与编程基础，默认显示本关移动模块")
	_check(_command_result_ids(menu).has("move") and not _command_result_ids(menu).has("attack"), "右侧仅展示所选模块的指令")
	var move_index := _command_result_ids(menu).find("move")
	var named_index := _command_result_ids(menu).find("named_move")
	_check(move_index >= 0 and named_index >= 0, "移动模块同时展示已解锁移动与未解锁命名调用")
	if move_index >= 0 and named_index >= 0:
		_check(bool(menu._cards[move_index].get_meta("available")) and not bool(menu._cards[named_index].get_meta("available")), "资料颜色依据当前关卡的真实语法权限")
		_check(menu._details[move_index].get_theme_color("font_color") == GameTheme.TEXT and menu._syntax[move_index].get_theme_color("font_color") == GameTheme.TEXT, "已解锁资料使用正常深色正文与语法")
		_check(menu._details[named_index].get_theme_color("font_color") == CommandReferenceMenu.LOCKED_TEXT and menu._syntax[named_index].get_theme_color("font_color") == CommandReferenceMenu.LOCKED_TEXT, "未解锁命名调用的正文与语法保持灰色")
		_check(menu._cards[move_index].get_tooltip().is_empty(), "已解锁移动卡片不显示未解锁悬停提示")
		_check(_command_lock_hint_is_hover_only(menu._cards[named_index], game.tr("目前尚未解锁")), "命名移动仅通过中文悬停提示未解锁，不显示静态徽章")
		await _test_command_accordion(menu, move_index, named_index)
	await _activate_visible_button(_command_section_button(menu, "general", "general"), "查看编程基础")
	var loop_details := menu.find_child("CommandDetails_loop", true, false) as Label
	_check(menu._selected_section_key == "general:general" and loop_details != null and _command_items_collapsed(menu), "切换编程基础后各条指令默认折叠")
	if loop_details != null:
		_check(loop_details.get_theme_color("font_color") == CommandReferenceMenu.LOCKED_TEXT, "编程基础中的未解锁循环同样使用灰色正文")
		var loop_card := menu.find_child("CommandCard_loop", true, false) as CommandReferenceItem
		await _activate_visible_button(loop_card.header_button, "展开尚未解锁的循环指令")
		await create_timer(0.35).timeout
		_check(loop_card.expanded and loop_details.is_visible_in_tree() and loop_card.syntax.is_visible_in_tree() and loop_card.syntax.text.contains("\n"), "未解锁循环仍可展开多行完整语法和说明")
		_check(_command_lock_hint_is_hover_only(loop_card, game.tr("目前尚未解锁")), "循环资料保持灰色且只在悬停时提示未解锁")
		game.settings.set_language("en")
		await process_frame
		await process_frame
		loop_card = menu.find_child("CommandCard_loop", true, false) as CommandReferenceItem
		_check(game.tr("目前尚未解锁") != "目前尚未解锁" and _command_lock_hint_is_hover_only(loop_card, game.tr("目前尚未解锁")), "切换英文后悬停提示即时本土化，卡片仍无静态未解锁文字")
		game.settings.set_language("zh_CN")
		await process_frame
		await process_frame
	_check(menu._details.size() == menu._displayed_entries.size(), "每条指令保留完整说明数据供展开阅读")
	await _activate_visible_button(_command_section_button(menu, "shooting"), "查看本关尚未解锁的射击模块")
	_check(_command_result_ids(menu).has("shoot") and _command_result_ids(menu).has("ready"), "未解锁模块仍可阅读射击与冷却查询说明")
	await _activate_visible_button(_command_section_button(menu, "unavailable_test_module"), "查看没有资料的扩展模块")
	_check(menu._cards.is_empty() and menu._empty_label.is_visible_in_tree(), "注册表中的新增模块没有资料时显示明确空状态")
	await _activate_visible_button(_command_section_button(menu, "movement"), "恢复移动模块资料")
	_check(_command_items_collapsed(menu), "切回模块目录后展开状态重置为折叠")
	await _menu_key(KEY_ESCAPE)
	_check(not menu.is_open() and header.book_button.has_focus(), "未展开搜索时 Escape 关闭资料窗并归还焦点")
	await _activate_visible_button(header.book_button, "外点击前重新打开资料窗")
	await create_timer(0.25).timeout
	var canvas := game.assembly_panel.canvas
	var placement_point := canvas.get_global_transform() * canvas.pixel_at(Vector2.ZERO)
	_check(menu._panel.get_global_rect().has_point(placement_point), "宽幅资料窗覆盖背后的可放置网格")
	await _menu_click(placement_point)
	_check(menu.is_open() and game.session.assembly.modules.is_empty(), "资料窗内部点击不穿透到装配网格")
	await _menu_click(header.back_button.get_global_rect().get_center())
	_check(not menu.is_open() and game.page == GameShell.Page.ASSEMBLY, "外点关闭吞掉整次导航点击，不误退出装配")
	await _activate_visible_button(header.book_button, "再次打开资料窗")
	await _menu_click(header.book_button.get_global_rect().get_center())
	_check(not menu.is_open(), "外露书本按钮可以重复点击关闭资料窗")
	# 独占 JSON 目录产生一个长分类；描述独有关键词覆盖跨模块检索，避免仅测试标题搜索。
	var fixture_directory := _test_directory.path_join("commands")
	DirAccess.make_dir_recursive_absolute(fixture_directory)
	var template: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/commands/020_move.json"))
	for index in range(12):
		_write_command_fixture(fixture_directory, template, index)
	var previous_directory := menu.catalog_directory
	menu.catalog_directory = fixture_directory
	await _activate_visible_button(header.book_button, "打开扩展指令目录")
	await _activate_visible_button(_command_section_button(menu, "movement"), "查看扩展移动资料")
	_check(menu.catalog.errors.is_empty() and menu._cards.size() == 12 and menu._details.size() == 12 and _command_items_collapsed(menu), "新增 JSON 无需修改 UI，默认仅显示十二条折叠指令")
	await create_timer(0.25).timeout
	await _scroll_command_content(menu)
	_check(menu._scroll.scroll_vertical > 0 and menu._directory_scroll.scroll_vertical == 0, "长指令列表可以独立纵向滚动，不拖动左侧模块目录")
	await _activate_visible_button(_command_section_button(menu, "general", "general"), "从其他分类发起全局搜索")
	await _activate_visible_button(menu.header.search_button, "展开指令搜索框")
	await create_timer(0.4).timeout
	_check(menu.header.search_input.is_visible_in_tree() and menu.header.search_input.has_focus(), "搜索动画展开后输入框可见并获焦")
	await _set_command_query(menu, "斑马索引")
	_check(_command_result_ids(menu) == ["fixture_7"] and menu._details[0].text.contains("斑马索引") and _command_items_collapsed(menu), "隐藏描述中的独有中文关键词仍可跨模块找到折叠指令")
	await _activate_visible_button(menu._command_buttons[0], "展开描述搜索结果")
	await create_timer(0.35).timeout
	_check(menu._details[0].is_visible_in_tree() and menu._details[0].text.contains("斑马索引"), "搜索命中后点击指令即可阅读匹配的说明")
	await _set_command_query(menu, "测试指令 11")
	_check(_command_result_ids(menu) == ["fixture_11"] and _command_items_collapsed(menu), "更换搜索后结果重新折叠，本土化指令标题可以搜索")
	await _set_command_query(menu, "distance")
	_check(menu._cards.size() == 12, "原始语法也参与资料检索")
	await _set_command_query(menu, game.tr("移动模块"))
	_check(menu._cards.size() == 12, "本土化模块名可以匹配其全部指令")
	await _set_command_query(menu, "no_such_command_981")
	_check(menu._cards.is_empty() and menu._empty_label.is_visible_in_tree(), "无匹配时显示空结果，不遗留上一批指令")
	await _set_command_query(menu, "")
	_check(menu._selected_section_key == "general:general" and menu._cards.is_empty(), "清空搜索恢复搜索前选中的分类")
	await _set_command_query(menu, "斑马索引")
	await _menu_key(KEY_ESCAPE)
	await create_timer(0.4).timeout
	_check(menu.is_open() and not menu.header._search_open and menu.header.get_query().is_empty(), "第一次 Escape 只收起搜索并清空查询")
	await _menu_key(KEY_ESCAPE)
	_check(not menu.is_open(), "第二次 Escape 关闭整个资料窗")
	_write_command_fixture(fixture_directory, template, 12)
	await _activate_visible_button(header.book_button, "新增 JSON 后重新打开资料窗")
	await _activate_visible_button(_command_section_button(menu, "movement"), "查看新增移动资料")
	_check(menu._cards.size() == 13 and menu.find_child("CommandCard_fixture_12", true, false) != null, "新文件在再次打开时自动进入当前模块资料")
	game.settings.set_language("en")
	await process_frame
	await process_frame
	_check(menu.is_open() and menu._details[0].text.contains("Test description") and menu._syntax[0].text.contains(template.syntax), "打开中的资料即时切换英文，语法保持原样")
	await _activate_visible_button(menu.header.search_button, "英文展开搜索")
	await create_timer(0.4).timeout
	await _set_command_query(menu, "reference needle")
	_check(_command_result_ids(menu) == ["fixture_7"], "英文说明搜索忽略大小写")
	await _activate_visible_button(menu.header.search_close_button, "通过按钮收起搜索")
	# 在收起动画尚未结束时转移焦点，结束回调不能抢走玩家刚选中的目录。
	var directory_focus := _command_section_button(menu, "movement")
	directory_focus.grab_focus()
	await create_timer(0.4).timeout
	_check(directory_focus.has_focus(), "搜索收起动画结束后保留刚转移到模块目录的键盘焦点")
	_check(menu.is_open() and menu.header.get_query().is_empty() and menu._cards.size() == 13 and _command_items_collapsed(menu), "收起搜索清空查询并恢复模块的折叠指令列表")
	game.settings.set_language("zh_CN")
	await process_frame
	await process_frame
	_check(menu._details[0].text.contains("测试说明"), "资料可以即时切回中文")
	await _activate_visible_button(menu.header.back_button, "返回关闭指令集合")
	menu.catalog_directory = previous_directory
	_check(not menu.is_open() and game.page == GameShell.Page.ASSEMBLY and game.workbench == null and game.session.world == null, "阅读资料不会进入程序页或启动模拟")
	_check(game.session.source == original_source and JSON.stringify(game.session.assembly.modules) == original_modules and _clear_records_snapshot(game.drafts.directory) == original_drafts, "资料操作不修改代码、装配或任何草稿文件")


## 默认只显示指令预览，详情可由真实鼠标、键盘及快速反向操作可靠展开收起。
func _test_command_accordion(menu: CommandReferenceMenu, move_index: int, named_index: int) -> void:
	var move_card := menu._cards[move_index] as CommandReferenceItem
	var named_card := menu._cards[named_index] as CommandReferenceItem
	await create_timer(0.25).timeout
	_check(_command_items_collapsed(menu) and move_card.preview.is_visible_in_tree() and named_card.preview.is_visible_in_tree(), "指令默认只显示预览，功能介绍处于折叠状态")
	var collapsed_height := move_card.size.y
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await create_timer(0.35).timeout
	_check(move_card.expanded and move_card.details.is_visible_in_tree() and move_card.size.y > collapsed_height and not named_card.expanded, "真实鼠标点击只向下展开当前指令的功能介绍")
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await create_timer(0.35).timeout
	_check(not move_card.expanded and absf(move_card.size.y - collapsed_height) < 1.0, "再次点击收起介绍并回收原有列表空间")
	move_card.header_button.grab_focus()
	await _menu_key(KEY_ENTER)
	await create_timer(0.35).timeout
	_check(move_card.expanded and move_card.details.is_visible_in_tree(), "Enter 键可以展开聚焦的指令")
	await _menu_key(KEY_SPACE)
	await create_timer(0.35).timeout
	_check(not move_card.expanded, "Space 键可以收起聚焦的指令")
	await _menu_click(named_card.header_button.get_global_rect().get_center())
	await create_timer(0.35).timeout
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await create_timer(0.35).timeout
	_check(move_card.expanded and named_card.expanded and named_card.details.is_visible_in_tree(), "多条指令可以独立展开，未解锁条目仍可阅读")
	_check(_command_lock_hint_is_hover_only(named_card, TranslationServer.translate("目前尚未解锁")), "展开锁定指令后头部及内容保留悬停提示而无静态徽章")
	# 同一头部连续反向点击，旧动画不能在稍后覆盖最后一次操作。
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await _menu_click(move_card.header_button.get_global_rect().get_center())
	await create_timer(0.4).timeout
	_check(not move_card.expanded and named_card.expanded and absf(move_card.size.y - collapsed_height) < 1.0, "快速收起、展开再收起以后尺寸与最后状态一致，其他条目不受影响")


## 只验证玩家当前可见条目的状态，不将保存在模型内的说明文本误当成默认展开。
func _command_items_collapsed(menu: CommandReferenceMenu) -> bool:
	for card: CommandReferenceItem in menu._cards:
		if card.expanded or card.details.is_visible_in_tree() or not card.header_button.is_visible_in_tree():
			return false
	return true


## 未解锁状态由卡片悬停解释，正文中不再出现单独的状态徽章文字。
func _command_lock_hint_is_hover_only(card: PanelContainer, expected: String) -> bool:
	if card == null or card.get_tooltip() != expected:
		return false
	if card is CommandReferenceItem and card.header_button.get_tooltip() != expected:
		return false
	for label: Label in card.find_children("*", "Label", true, false):
		var displayed := TranslationServer.translate(label.text)
		if label.is_visible_in_tree() and displayed in [TranslationServer.translate("本关未解锁"), TranslationServer.translate("目前尚未解锁")]:
			return false
	return true


## 分类的稳定键包含类型，真实模块即使名为 general 也不与编程基础混淆。
func _command_section_button(menu: CommandReferenceMenu, section_id: String, kind: String = "module") -> Button:
	for button: Button in menu._section_buttons:
		if str(button.get_meta("section_id")) == section_id and str(button.get_meta("section_kind")) == kind:
			return button
	return null


## 按屏幕实际呈现顺序取资料 ID，避免用目录原始数量代替真实过滤结果。
func _command_result_ids(menu: CommandReferenceMenu) -> Array[String]:
	var result: Array[String] = []
	for entry: Dictionary in menu._displayed_entries:
		result.append(entry.id)
	return result


## 通过实际输入控件的文本变化信号触发搜索，不调用过滤器内部实现。
func _set_command_query(menu: CommandReferenceMenu, query: String) -> void:
	var input := menu.header.search_input
	input.grab_focus()
	input.text = query
	input.text_changed.emit(query)
	await process_frame
	await process_frame


## 滚轮事件交给真实右侧滚动区，验证内容可浏览且不会同步滚动左目录。
func _scroll_command_content(menu: CommandReferenceMenu) -> void:
	for index in range(6):
		for pressed in [true, false]:
			var wheel := InputEventMouseButton.new()
			wheel.position = menu._scroll.get_global_rect().get_center()
			wheel.global_position = wheel.position
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
			wheel.factor = 3
			wheel.pressed = pressed
			root.push_input(wheel)
		await process_frame
	await process_frame


## 用真实资料格式创建独占 JSON 夹具，只替换显示字段与稳定 ID，不添加任何可执行内容。
func _write_command_fixture(directory: String, template: Dictionary, index: int) -> void:
	var entry := template.duplicate(true)
	entry.id = "fixture_%d" % index
	entry.order = index
	entry.title = {"zh_CN": "测试指令 %d" % index, "en": "Test Command %d" % index}
	entry.description = {"zh_CN": "测试说明，斑马索引只在本条描述中。" if index == 7 else "测试说明，窗口只展示资料。", "en": "Test description with Reference needle only here." if index == 7 else "Test description; reference content only."}
	var file := FileAccess.open(directory.path_join("%02d.json" % index), FileAccess.WRITE)
	_check(file != null, "创建独占指令 JSON %d" % index)
	if file != null:
		file.store_string(JSON.stringify(entry, "  "))
		file.close()


## 用独占内存关卡覆盖共边分支、删除后的无效装配和确认按钮的即时诊断。
func _test_assembly_validity(game: GameShell, source_level: LevelDefinition) -> void:
	var document := source_level.document.duplicate_document()
	document.id = "ui_assembly_validity"
	document.display_name = "装配连接规则测试"
	document.width = 12
	document.height = 12
	document.player_spawn.position = {"x": 6.5, "y": 6.5}
	document.dialogue.clear()
	document.properties.level.module_limit = 8
	document.properties.level.goal = null
	# 一处真实空地检验确认依据完整出生占地；其余地板让几何规则可以独立验证。
	for y in range(document.height):
		for x in range(document.width):
			document.set_tile(Vector2i(x, y), "floor")
	document.set_tile(Vector2i(8, 6), "")
	var defined := LevelDefinition.from_document(document, game.registry)
	_check(defined.is_ok(), "构造仅供本次 UI 测试的多模块关卡")
	if not defined.is_ok():
		return
	game._enter_level(defined.value)
	await process_frame
	var canvas := game.assembly_panel.canvas
	var model := game.session.assembly
	_check(model.modules.is_empty() and game._confirm_assembly_button.disabled, "多模块关卡也从空装配开始")
	_check(game._confirm_assembly_button.get_tooltip().contains("至少") and game._assembly_status.text.contains("至少"), "空装配的确认悬停提示与状态区均说明缺少模块")
	var first_click := canvas.pixel_at(Vector2(0.5, 0))
	_stroke(canvas, first_click, MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 1 and not game._confirm_assembly_button.disabled, "中心外首次放置可用，逻辑装配确认立即启用")
	_check(model.modules.size() == 1 and canvas.pixel_at(Vector2.ZERO).is_equal_approx(first_click) and model.modules[0].offset == {"x": 0.0, "y": 0.0}, "多模块编辑以首件点击位置显示逻辑原点")
	_stroke(canvas, canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 1, "重新点击显示原点选中首件，不重复新增")
	_stroke(canvas, canvas.pixel_at(Vector2(0.5, 0.5)), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 1, "仅角点接触中心模块不能新增")
	_stroke(canvas, canvas.pixel_at(Vector2(1.5, 0)), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 1, "与现有模块完全悬空的新增被拒绝")
	_stroke(canvas, canvas.pixel_at(Vector2(0.5, 0)), MOUSE_BUTTON_LEFT)
	_stroke(canvas, canvas.pixel_at(Vector2(0, -0.5)), MOUSE_BUTTON_LEFT)
	_stroke(canvas, canvas.pixel_at(Vector2(-0.5, 0)), MOUSE_BUTTON_LEFT)
	_stroke(canvas, canvas.pixel_at(Vector2(1, 0)), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 5 and not game._confirm_assembly_button.disabled, "正长度共边允许从中心建立多个分支并继续延伸")
	var connected_layout := JSON.stringify(model.modules, "", true)
	_drag(canvas, Vector2(0, -0.5), Vector2(0, -1))
	_check(JSON.stringify(model.modules, "", true) == connected_layout, "多模块移动到悬空位置被拒绝并保留原布局")
	_drag(canvas, Vector2(0, -0.5), Vector2(-0.5, -0.5))
	_check(is_equal_approx(float(model.modules[2].offset.x), -0.5) and not game._confirm_assembly_button.disabled, "多模块可以移动到与其他分支共边的合法位置")
	_delete_at(canvas, Vector2.ZERO)
	_check(model.modules.size() == 4 and game._confirm_assembly_button.disabled, "删除中心允许保留其他模块，但立即禁用确认")
	var center_reason := game._confirm_assembly_button.get_tooltip()
	_check(center_reason.contains("中心") and game._assembly_status.text.contains("中心"), "剩余模块缺少中心时确认悬停提示与状态区均说明中文原因")
	game.settings.set_language("en")
	await process_frame
	_check(game._confirm_assembly_button.get_tooltip().to_lower().contains("center"), "缺中心的已有悬停提示可以即时切换英文")
	game.settings.set_language("zh_CN")
	await process_frame
	_check(game._confirm_assembly_button.get_tooltip().contains("中心"), "缺中心悬停提示可以即时切回中文")
	game._confirm_assembly()
	_check(game.page == GameShell.Page.ASSEMBLY and game.workbench == null, "直接调用确认也不能绕过缺少中心的校验")
	# 截图模式把输入投递给游戏视口，让 Godot 自己显示禁用按钮的原生悬停提示。
	if "--capture" in OS.get_cmdline_user_args():
		await process_frame
		var hover := InputEventMouseMotion.new()
		hover.position = game._confirm_assembly_button.get_global_rect().get_center()
		root.push_input(hover)
		await create_timer(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) + 0.1).timeout
	await _capture("assembly_missing_center")
	# 缺少中心属于可继续修复的草稿，保存后主动载入不能被当成损坏内容而丢弃。
	game.find_child("SaveAssemblyButton", true, false).pressed.emit()
	var incomplete_saved := game.drafts.load_draft(document.id)
	_check(incomplete_saved.is_ok() and incomplete_saved.value != null and incomplete_saved.value.modules.size() == 4, "缺少中心的编辑草稿仍可保存全部剩余模块")
	_press_back(game)
	game._enter_level(defined.value)
	await process_frame
	var restore: Button = game.find_child("RestoreAssemblyButton", true, false)
	_check(not game._message_dialog.visible and game.session.assembly.modules.is_empty() and not restore.disabled, "缺中心草稿重新进入时保留手动恢复入口，不误报损坏")
	restore.pressed.emit()
	canvas = game.assembly_panel.canvas
	model = game.session.assembly
	_check(model.modules.size() == 4 and game._confirm_assembly_button.disabled and game._confirm_assembly_button.get_tooltip().contains("中心"), "主动载入缺中心草稿后布局可继续编辑，确认保持禁用")
	_stroke(canvas, canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 5 and not game._confirm_assembly_button.disabled and not game._confirm_assembly_button.get_tooltip().contains("缺少"), "补回中心后确认立即恢复，清除失效的缺中心提示")
	_delete_at(canvas, Vector2(0.5, 0))
	_check(model.modules.size() == 4 and game._confirm_assembly_button.disabled, "删除桥接模块允许编辑，但断开的分支禁止确认")
	var disconnected_reason := game._confirm_assembly_button.get_tooltip()
	_check(disconnected_reason.contains("连接") or disconnected_reason.contains("连通"), "桥接删除后的悬停提示说明模块连接问题")
	game.settings.set_language("en")
	await process_frame
	_check(game._confirm_assembly_button.get_tooltip().to_lower().contains("center"), "断开分支的已有悬停提示可以即时切换英文")
	game.settings.set_language("zh_CN")
	await process_frame
	_check(game._confirm_assembly_button.get_tooltip().contains("连接") or game._confirm_assembly_button.get_tooltip().contains("连通"), "断开分支悬停提示可以即时切回中文")
	game._confirm_assembly()
	_check(game.page == GameShell.Page.ASSEMBLY and game.workbench == null, "直接确认不能绕过仍有中心但已断开的装配")
	_stroke(canvas, canvas.pixel_at(Vector2(0.5, 0)), MOUSE_BUTTON_LEFT)
	_check(not game._confirm_assembly_button.disabled, "补回桥接后确认立即恢复")
	_stroke(canvas, canvas.pixel_at(Vector2(1.5, 0)), MOUSE_BUTTON_LEFT)
	_check(model.modules.size() == 6 and game._confirm_assembly_button.disabled and game._confirm_assembly_button.get_tooltip().contains("void"), "共边合法但出生占地跨入 void 时仍禁用确认并解释地形原因")
	game._confirm_assembly()
	_check(game.page == GameShell.Page.ASSEMBLY and game.workbench == null, "直接确认不能绕过真实出生占地校验")
	_delete_at(canvas, Vector2(1.5, 0))
	_check(not game._confirm_assembly_button.disabled, "移除悬在 void 上的末端模块后确认恢复")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.PLAY and game.workbench != null, "合法多模块分支可确认进入编程页")
	if game.workbench == null:
		_press_back(game)
		return
	game.workbench.set_process(false)
	game.workbench._tabs.current_tab = 1
	await process_frame
	canvas = game.workbench._assembly_panel.canvas
	_delete_at(canvas, Vector2.ZERO)
	_check(game.workbench._run_button.disabled and game.workbench._run_button.get_tooltip().contains("中心"), "编程页删除中心后运行按钮立即禁用并显示同一原因")
	game.workbench._run_program()
	_check(game.session.state == GameSession.State.FAILED and game.session.world == null, "直接调用运行也不能绕过缺少中心的装配")
	game.workbench._tabs.current_tab = 1
	await process_frame
	_stroke(canvas, canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(not game.workbench._run_button.disabled and not game.workbench._run_button.get_tooltip().contains("中心"), "编程页补回中心后运行立即恢复，移除过期提示")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.catalog.levels.size() == 16, "临时关卡不会新增到关卡目录，结束后恢复原选关流程")


## 四种编程状态均通过实际按钮返回组装，保留内存作品并终止旧试运行。
func _test_return_to_assembly(game: GameShell) -> void:
	var original_session := game.session
	var original_assembly := original_session.assembly
	var original_source := original_session.source
	var original_modules := JSON.stringify(original_assembly.modules, "", true)
	var original_name: String = original_assembly.modules[0].id
	var current_name := original_name
	for phase in ["编辑", "运行", "暂停", "语法失败"]:
		var workbench := game.workbench
		workbench.set_process(false)
		var expected_source: String = "main() {\n    // " + phase + "状态保留整段程序\n    move(0, 4)\n}\n"
		if phase == "编辑":
			expected_source = "main() {\n    // 尚未提交、尚未写完的程序也必须保留\n\tmove(0,\n"
		elif phase == "语法失败":
			expected_source = "main() {\n    // 分号是故意保留的语法错误\n    move(0, 1);\n}\n"
		# 程序化设置文本不发送编辑通知，覆盖导航时最后一份尚未同步的内容。
		workbench._code.text = expected_source
		var expected_state := GameSession.State.EDITING
		if phase == "编辑":
			_check(original_session.source != expected_source, "编辑返回夹具确实包含尚未同步的文本")
		else:
			workbench._run_button.pressed.emit()
			if phase == "语法失败":
				expected_state = GameSession.State.FAILED
			else:
				original_session.step()
				expected_state = GameSession.State.RUNNING
				if phase == "暂停":
					workbench._pause_button.pressed.emit()
					expected_state = GameSession.State.PAUSED
		_check(original_session.state == expected_state, phase + "返回夹具处于指定状态")
		var old_world := original_session.world
		var old_runner := original_session.runner
		var old_command: MovementCommand = old_runner._command if old_runner != null else null
		var modules_before := JSON.stringify(original_assembly.modules, "", true)
		# 磁盘刻意保存另一份有效草稿，错误地重新进入关卡会读出不同代码或清空布局。
		var disk_modules: Array = original_assembly.modules.duplicate(true)
		disk_modules[0].id = "disk_only_drive"
		_check(game.drafts.save_draft(original_session.level.id, "main() {\n    // 磁盘旧代码\n}\n", disk_modules).is_ok(), phase + "返回夹具包含不同的磁盘旧草稿")
		var edit_button: Button = workbench.find_child("EditModulesButton", true, false)
		_check(edit_button != null and not edit_button.disabled, phase + "状态可点击编辑模块按钮")
		if edit_button == null:
			return
		var previous_menu := workbench._actions_menu
		await _open_program_actions(workbench)
		await _activate_visible_button(edit_button, phase + "状态从二级菜单编辑模块")
		await process_frame
		_check(not is_instance_valid(previous_menu) or not previous_menu.is_open(), "离开编程页关闭原二级菜单")
		_check(game.page == GameShell.Page.ASSEMBLY and game.workbench == null and game.assembly_panel != null, phase + "状态通过按钮回到独立组装页")
		_check(game.session == original_session and game.session.assembly == original_assembly, phase + "返回复用同一会话和装配对象")
		_check(game.session.source == expected_source and JSON.stringify(game.session.assembly.modules, "", true) == modules_before, phase + "返回完整保留内存程序与布局，不加载磁盘旧草稿")
		_check(game.session.state == GameSession.State.EDITING and game.session.world == null and game.session.runner == null, phase + "返回释放会话中的世界与运行器")
		_check(not game._dialogue_dialog.visible and not game._message_dialog.visible, phase + "返回不重复关卡对话或恢复提示")
		if old_runner != null:
			_check(old_command != null and old_command.state == MovementCommand.State.CANCELLED and old_runner.state == ProgramRunner.State.CANCELLED, phase + "返回取消旧运行器及未完成的移动命令")
			var stopped_position := old_world.player.position
			old_runner.step()
			old_world.step()
			_check(old_world.player.position == stopped_position, phase + "返回后旧世界和运行器不能继续推动机器")
		if phase == "编辑":
			await _capture("return_to_assembly")
		# 唯一模块固定在中心；用实际属性控件重命名验证返回后仍可修改装配。
		var next_name := "return_drive" if current_name == original_name else original_name
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = next_name
		game.assembly_panel._apply_button.pressed.emit()
		_check(original_assembly.modules[0].id == next_name, phase + "返回后已有模块仍可通过属性面板重命名")
		current_name = next_name
		game.find_child("ConfirmAssemblyButton", true, false).pressed.emit()
		await process_frame
		_check(game.page == GameShell.Page.PLAY and game.workbench != null and game.session == original_session, phase + "修改装配后确认回到同一会话的编程页")
		if game.workbench == null:
			return
		game.workbench.set_process(false)
		_check(game.workbench._code.text == expected_source and game.session.assembly.modules[0].id == next_name, phase + "重新打开编程页保留全部源文本和刚修改的装配")
	_check(JSON.stringify(original_assembly.modules, "", true) == original_modules, "返回组装回归结束后恢复原有布局夹具")
	game.workbench._code.text = original_source
	game.workbench._code.text_changed.emit()
	_check(game.session.state == GameSession.State.EDITING and game.session.source == original_source, "返回组装回归结束后恢复正常编程夹具")


## 恢复失败只能暂时显示默认内容，未编辑返回不得覆盖玩家原草稿。
func _test_draft_recovery(game: GameShell, first: LevelDefinition) -> void:
	var valid_saved := game.drafts.save_draft(first.id, SOLUTION, first.document.player_spawn.modules)
	_check(valid_saved.is_ok(), "准备合法历史装配草稿")
	var valid_path: String = valid_saved.value
	var valid_original := FileAccess.get_file_as_string(valid_path)
	await _enter_recovery_level(game, first)
	_press_back(game)
	_check(FileAccess.get_file_as_string(valid_path) == valid_original, "空组装页未编辑返回不会清空合法历史装配")
	var incompatible: Array = first.document.player_spawn.modules.duplicate(true)
	incompatible.append({"id": "second_drive", "module_id": "movement", "offset": {"x": 0.5, "y": 0}})
	var saved := game.drafts.save_draft(first.id, SOLUTION, incompatible)
	_check(saved.is_ok(), "准备格式合法但超过首关模块上限的草稿")
	if not saved.is_ok():
		return
	var draft_path: String = saved.value
	var original := FileAccess.get_file_as_string(draft_path)
	await _enter_recovery_level(game, first)
	_check(game.session.assembly.modules.is_empty() and game._message_dialog.visible, "不兼容装配保留空网格并显示诊断")
	game._message_dialog.hide()
	_press_back(game)
	_check(FileAccess.get_file_as_string(draft_path) == original, "未编辑直接返回保留原有不兼容草稿")
	# 使用真实损坏文本，确保恢复备份保存原始字节而非尝试重新序列化。
	var corrupted := "{ broken 草稿，保留原文以便人工修复\n"
	_overwrite_test_draft(draft_path, corrupted)
	await _enter_recovery_level(game, first)
	_check(game._message_dialog.visible, "损坏 JSON 显示草稿恢复诊断")
	game._message_dialog.hide()
	_press_back(game)
	_check(FileAccess.get_file_as_string(draft_path) == corrupted, "未编辑返回不会把损坏草稿覆盖为初始模板")
	await _enter_recovery_level(game, first)
	game._message_dialog.hide()
	game.session.assembly.add_module("movement", Vector2.ZERO)
	game._confirm_assembly()
	await process_frame
	game.workbench.set_process(false)
	var edited_source := "main() {\n    // 恢复后编写的新程序\n    move(0, 2)\n}\n"
	# 模拟代码控件的用户编辑通知，经过工作台到外壳的自动保存信号链。
	game.workbench._code.text = edited_source
	game.workbench._code.text_changed.emit()
	game._save_timer.timeout.emit()
	var restored := game.drafts.load_draft(first.id)
	_check(restored.is_ok() and restored.value != null and restored.value.source == edited_source, "实际编辑后的自动保存写入新草稿")
	_check(_has_recovery_copy(game.drafts.directory, corrupted), "自动保存前已在同目录备份损坏草稿原文")
	var backup_count := _recovery_count(game.drafts.directory)
	game._save_timer.timeout.emit()
	_check(_recovery_count(game.drafts.directory) == backup_count, "恢复成功后的普通保存不会反复生成恢复备份")
	_press_back(game)
	# 手动点击保存表示玩家明确采用当前内容，即使没有编辑也应先备份再替换。
	var manual_original := "{ 第二份未修改但请求手动恢复的损坏草稿\n"
	_overwrite_test_draft(draft_path, manual_original)
	await _enter_recovery_level(game, first)
	game._message_dialog.hide()
	game.find_child("SaveAssemblyButton", true, false).pressed.emit()
	var manual_saved := game.drafts.load_draft(first.id)
	_check(manual_saved.is_ok() and manual_saved.value != null, "未编辑时手动保存可以采用当前默认内容")
	_check(_has_recovery_copy(game.drafts.directory, manual_original), "手动保存也会先备份待恢复原文")
	_check(game.drafts.is_completed(first.id), "恢复草稿不清除先前的通关记录")
	_press_back(game)
	await process_frame


## 进入恢复测试关卡并关闭教程，保留草稿诊断供用例检查。
func _enter_recovery_level(game: GameShell, definition: LevelDefinition) -> void:
	game._enter_level(definition)
	await process_frame
	_finish_dialogue(game)


## 通过焦点输入切换分类，验证折叠数量、独立导入区和会话内刷新记忆。
func _test_level_categories(game: GameShell) -> void:
	var sections := game.find_child("LevelSections", true, false) as VBoxContainer
	var tutorial := game.find_child("TutorialSection", true, false) as Control
	var imported := game.find_child("ImportedSection", true, false) as Control
	var grid := game.find_child("LevelGrid", true, false) as GridContainer
	var imported_grid := game.find_child("ImportedLevelGrid", true, false) as GridContainer
	_check(sections != null and tutorial != null and imported != null and tutorial.get_parent() == sections and imported.get_parent() == sections, "教学与导入分类都位于同一个纵向列表")
	_check(grid != null and imported_grid != null and grid != imported_grid and grid.columns == 7 and imported_grid.columns == 7, "教学关卡和导入关卡分别使用七列网格")
	_check(not game._tutorials_expanded and _visible_tutorial_count(game) == 7, "首次进入教学关卡只显示前七张")
	for index in range(15):
		var button := game.find_child("LevelButton_%d" % index, true, false) as Button
		_check(button != null and button.get_parent().get_parent() == grid and button.is_visible_in_tree() == (index < 7), "教学卡片 %d 保留原节点且按默认折叠状态显示" % (index + 1))
	var tenth := game.find_child("LevelButton_9", true, false) as Button
	var tenth_labels := PackedStringArray()
	for child in tenth.get_parent().get_children():
		if child is Label:
			tenth_labels.append(child.text)
	_check("第十关 · 猎人游戏" in tenth_labels and "雷达追击 · 制导射击" in tenth_labels, "第十关显示用户指定名称与制导射击说明，不沿用蛇形寻路文案")
	var twelfth := game.find_child("LevelButton_11", true, false) as Button
	var twelfth_labels := PackedStringArray()
	for child in twelfth.get_parent().get_children():
		if child is Label:
			twelfth_labels.append(child.text)
	_check("第十二关 · 八方来敌" in twelfth_labels and "for 循环 · 八方警戒" in twelfth_labels, "第十二关使用八方来敌名称和范围循环主题，不沿用闪避教学")
	_check(_tutorial_toggle_text(game) == "展示更多（15）", "中文展示更多标出十五个教学关卡总数")
	var settings_before := FileAccess.get_file_as_string(game.settings_path)
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "展开教学关卡")
	_check(game._tutorials_expanded and _visible_tutorial_count(game) == 15 and _tutorial_toggle_text(game) == "收起", "实际切换按钮展开全部十五张并显示收起")
	await _open_actions_menu(game)
	await _activate_visible_button(game.find_child("LevelRefreshMenuItem", true, false), "从二级菜单刷新已展开的教学关卡")
	_check(game._tutorials_expanded and _visible_tutorial_count(game) == 15, "手动刷新后保留展开状态")
	game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	await process_frame
	_check(game._tutorials_expanded and _visible_tutorial_count(game) == 15, "失焦后回到选关页保留展开状态")
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "收起教学关卡")
	_check(not game._tutorials_expanded and _visible_tutorial_count(game) == 7, "再次操作按钮收回到前七张")
	_check(FileAccess.get_file_as_string(game.settings_path) == settings_before, "展开和收起不向设置文件写入会话状态")
	game.settings.set_language("en")
	await process_frame
	_check(_tutorial_toggle_text(game) == "Show More (15)", "英文收起状态展示教学关卡总数")
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "英文展开教学关卡")
	_check(_visible_tutorial_count(game) == 15 and _tutorial_toggle_text(game) == "Show Less", "英文展开按钮变为 Show Less")
	game.settings.set_language("zh_CN")
	await process_frame
	_check(_visible_tutorial_count(game) == 15 and _tutorial_toggle_text(game) == "收起", "语言切换保留展开状态并更新按钮翻译")
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "恢复默认教学折叠视图")


## 二级菜单通过真实鼠标屏障和键盘输入验证关闭、导航及原有刷新和导入链路。
func _test_level_actions_menu(game: GameShell) -> void:
	var header := game._level_header
	var more := game.find_child("LevelMoreButton", true, false) as Button
	_check(more != null and more.text.is_empty() and more.icon != null and more.is_visible_in_tree(), "选关页以纯 SVG 更多图标替换文字刷新入口")
	_check(game.find_child("LevelRefreshButton", true, false) == null, "旧刷新药丸不再保留在选关页头")
	await _open_actions_menu(game)
	var refresh := game.find_child("LevelRefreshMenuItem", true, false) as Button
	var imported := game.find_child("LevelImportMenuItem", true, false) as Button
	_check(refresh != null and imported != null and refresh.icon != null and imported.icon != null, "刷新与导入菜单项均包含清晰图标")
	_check(TranslationServer.translate(refresh.text) == "刷新" and TranslationServer.translate(imported.text) == "导入关卡", "二级菜单显示中文操作名称")
	_check(refresh.has_focus(), "键盘打开菜单后首项获得焦点")
	await _menu_key(KEY_DOWN)
	_check(imported.has_focus(), "向下键从刷新移动至导入")
	await _menu_key(KEY_UP)
	_check(refresh.has_focus(), "向上键返回刷新")
	await _menu_key(KEY_TAB)
	_check(imported.has_focus(), "Tab 可在菜单操作之间移动焦点")
	await _menu_key(KEY_TAB)
	var sort := game.find_child("LevelSortMenuItem", true, false) as Button
	_check(sort.has_focus(), "Tab 可以到达第三项排列方式")
	await _menu_key(KEY_ENTER)
	var sort_panel := game.find_child("LevelSortPanel", true, false) as Control
	var original_order := game.find_child("LevelSortDefaultMenuItem", true, false) as Button
	var unfinished := game.find_child("LevelSortUncompletedMenuItem", true, false) as Button
	_check(sort_panel.is_visible_in_tree() and original_order.has_focus(), "键盘确认排列方式后展开子菜单并聚焦当前顺序")
	await _menu_key(KEY_DOWN)
	_check(unfinished.has_focus(), "子菜单向下键到达未通关优先")
	await _menu_key(KEY_TAB)
	_check(original_order.has_focus(), "子菜单两项之间循环 Tab，不跳出子菜单")
	await _menu_key(KEY_ESCAPE)
	_check(header._actions_menu.is_open() and not sort_panel.is_visible_in_tree() and sort.has_focus(), "子菜单 Esc 返回主菜单并把焦点交回排列方式")
	await _menu_key(KEY_DOWN)
	_check(refresh.has_focus(), "第三项向下回到首项，焦点不会离开菜单")
	await _menu_click(more.get_global_rect().get_center())
	_check(not header._actions_menu.is_open() and more.has_focus(), "重复点击更多按钮收起菜单并恢复入口焦点")
	await _open_actions_menu(game)
	var first := game.find_child("LevelButton_0", true, false) as Button
	var first_instance := first.get_instance_id()
	await _menu_click(first.get_global_rect().get_center())
	_check(not header._actions_menu.is_open() and game.page == GameShell.Page.LEVELS and game.session == null, "点击菜单外的关卡卡片只收起菜单，不穿透进入关卡")
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "菜单回归前展开全部教学")
	header.set_search_open(true, false)
	var input := game.find_child("LevelSearchInput", true, false) as LineEdit
	input.text = "初次"
	input.text_changed.emit(input.text)
	await process_frame
	await _open_actions_menu(game)
	await _menu_key(KEY_ESCAPE)
	_check(not header._actions_menu.is_open() and header.get_query() == "初次" and input.is_visible_in_tree(), "菜单内 Esc 只关闭二级菜单，不清空或收回搜索框")
	await _open_actions_menu(game)
	await _activate_visible_button(refresh, "从菜单刷新当前搜索结果")
	_check(not header._actions_menu.is_open() and header.get_query() == "初次" and game._tutorials_expanded, "菜单刷新保留搜索查询和教学展开偏好")
	_check(first_instance != game.find_child("LevelButton_0", true, false).get_instance_id() and _visible_tutorial_count(game) == 1, "菜单刷新重建关卡结果且仍应用当前查询")
	header.set_search_open(false, false)
	await process_frame
	await process_frame
	await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "菜单回归后恢复教学折叠")
	var opened_before := _opened_paths.size()
	await _open_actions_menu(game)
	await _menu_key(KEY_DOWN)
	await _menu_key(KEY_ENTER)
	_check(game._import_dialog.visible and not header._actions_menu.is_open(), "键盘选择导入后先关闭二级菜单，再显示原导入提示")
	_check(_opened_paths.size() == opened_before + 1, "菜单导入只调用一次现有目录打开接口")
	game._import_dialog.get_cancel_button().pressed.emit()
	await process_frame
	await process_frame
	_check(not game._import_dialog.visible and game.page == GameShell.Page.LEVELS, "菜单导入也可以取消并留在选关页")
	await _open_actions_menu(game)
	game._show_main_page()
	await process_frame
	await process_frame
	_check(not header._actions_menu.is_open() and not more.is_visible_in_tree(), "离开选关页会关闭独立菜单，不把隐藏入口重新设为焦点")
	await _activate_visible_button(game.find_child("StartGameButton", true, false), "再次进入关卡列表")
	_check(not header._actions_menu.is_open() and _visible_tutorial_count(game) == 7, "再次进入选关页菜单保持关闭且列表正常")
	# 搜索正在收起时打开菜单，延迟的动画回调也不能夺走玩家已选中的菜单焦点。
	header.set_search_open(true, false)
	await process_frame
	await process_frame
	header.set_search_open(false)
	await _activate_visible_button(more, "搜索收起动画中打开二级菜单")
	await _menu_key(KEY_DOWN)
	_check(imported.has_focus(), "搜索动画结束前已用方向键选中导入")
	await create_timer(0.30).timeout
	_check(header._actions_menu.is_open() and imported.has_focus(), "搜索收起完成不会把焦点从导入菜单抢回搜索按钮")
	await _menu_key(KEY_ESCAPE)



## 从可见更多按钮打开菜单，后续检查不直接调用弹出方法绕过入口。
func _open_actions_menu(game: GameShell) -> void:
	await _activate_visible_button(game.find_child("LevelMoreButton", true, false), "打开关卡二级菜单")
	await create_timer(0.24).timeout
	_check(game._level_header._actions_menu.is_open(), "更多按钮实际展开二级菜单")


## 按下及释放都经真实视口路由，确保关闭屏障吞掉整次鼠标操作。
func _menu_click(position: Vector2) -> void:
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = position
		click.global_position = position
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		root.push_input(click)
	await process_frame
	await process_frame


## 菜单键盘操作使用物理按键，覆盖焦点循环、取消及确认的实际事件链。
func _menu_key(keycode: Key) -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = keycode
		key.physical_keycode = keycode
		key.pressed = pressed
		root.push_input(key)
	await process_frame
	await process_frame


## 只计算教学卡片的真实树可见性，隐藏节点和占位控件不计入数量。
func _visible_tutorial_count(game: GameShell) -> int:
	var count := 0
	for index in range(15):
		var button := game.find_child("LevelButton_%d" % index, true, false) as Button
		if button != null and button.is_visible_in_tree():
			count += 1
	return count


## 读取玩家实际看到的切换文案，兼容显式翻译与控件自动翻译。
func _tutorial_toggle_text(game: GameShell) -> String:
	var toggle := game.find_child("TutorialToggleButton", true, false) as Button
	return "" if toggle == null else TranslationServer.translate(toggle.text)


## 经过视口的键盘焦点处理激活按钮，隐藏或禁用的入口不能伪装成可点击。
func _activate_visible_button(button: Button, reason: String) -> void:
	var usable := button != null and button.is_visible_in_tree() and not button.disabled
	_check(usable, reason + " 的按钮可见且可操作")
	if not usable:
		return
	button.grab_focus()
	await process_frame
	_check(button.has_focus(), reason + " 可以获得键盘焦点")
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = &"ui_accept"
		event.pressed = pressed
		root.push_input(event)
	await process_frame
	await process_frame


## 折叠中的后续关卡先通过展示更多露出入口，再经真实 GUI 输入进入空装配。
func _open_tutorial_card(game: GameShell, index: int) -> bool:
	var card := game.find_child("LevelButton_%d" % index, true, false) as Button
	if card != null and not card.is_visible_in_tree():
		await _activate_visible_button(game.find_child("TutorialToggleButton", true, false), "进入后续关卡前展开教学")
		card = game.find_child("LevelButton_%d" % index, true, false) as Button
	await _activate_visible_button(card, "选择第 %d 关" % (index + 1))
	var entered := game.page == GameShell.Page.ASSEMBLY and game.session != null and game.session.level.id == game.catalog.levels[index].id
	_check(entered, "可见教学卡片经 GUI 输入进入第 %d 关" % (index + 1))
	return entered


## 检查真实选关按钮的 SVG 纹理，以及导入地图的更新、极小和大尺寸边界。
func _test_level_thumbnails(game: GameShell) -> void:
	var previous := PackedByteArray()
	for index in range(game.catalog.levels.size()):
		var level: LevelDefinition = game.catalog.levels[index]
		var snapshot := JSON.stringify(level.document.to_dict())
		var button := game.find_child("LevelButton_%d" % index, true, false) as Button
		_check(button != null and button.text.is_empty() and button.icon != null, "关卡 %d 使用地图图标而非数字" % (index + 1))
		if button == null or button.icon == null:
			continue
		var pixels := button.icon.get_image().get_data()
		_check(button.icon.get_size() == Vector2(320, 320), "缩略图保持正方形并以双倍分辨率呈现")
		if level.id == "level_015":
			_check(pixels == previous, "第十五关沿用第十四关通道布局，缩略图保持一致")
		else:
			_check(pixels != previous, "不同路线和机关生成不同的实际图像")
		previous = pixels
		LevelThumbnail.create_texture(level, game.registry)
		_check(JSON.stringify(level.document.to_dict()) == snapshot, "生成缩略图不会修改关卡数据")
	var preview := LevelDefinition.new()
	preview.document = game.catalog.levels[0].document.duplicate_document()
	var before := LevelThumbnail.create_texture(preview, game.registry).get_image().get_data()
	preview.document.set_tile(Vector2i(2, 2), "floor")
	_check(LevelThumbnail.create_texture(preview, game.registry).get_image().get_data() != before, "编辑后的地图立即产生新缩略图，不依赖固定关卡 ID")
	preview.document = MapDocument.new()
	_check(LevelThumbnail.create_texture(preview, game.registry) != null, "空地图可安全生成预览")
	for cell in [Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5)]:
		preview.document.set_tile(cell, "floor")
	var small_image := LevelThumbnail.create_texture(preview, game.registry).get_image()
	_check(is_zero_approx(small_image.get_pixel(60, 100).a), "两格宽地图居中保留透明区域，地板不会因半格边界向左偏移")
	preview.document.width = 256
	preview.document.height = 256
	for y in range(256):
		for x in range(256):
			preview.document.set_tile(Vector2i(x, y), "floor")
	var svg := LevelThumbnail.build_svg(preview, game.registry)
	_check(svg.count("<rect ") <= 1026 and svg.length() < 300000, "最大地图合并缩略格子，限制 SVG 体积")
	_check(LevelThumbnail.create_texture(preview, game.registry) != null, "最大地图仍能生成有效 SVG 纹理")


## 设置通过实际控件更新，并验证聚焦不会把设置页错误切回关卡页。
func _test_settings_page(game: GameShell) -> void:
	game.find_child("SettingsButton", true, false).pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.SETTINGS, "设置按钮进入设置页面")
	_check(game._header.visible and game._back_button.is_visible_in_tree(), "设置页恢复页头导航")
	_check(game._back_button == game.find_child("GameBackButton", true, false) and game._back_button.text.is_empty() and game._back_button.icon != null, "设置页复用纯箭头药丸返回入口")
	_check(not game._header_mark.is_visible_in_tree() and not game._text_back_button.is_visible_in_tree(), "设置页隐藏软件图标与原有文字返回按钮")
	_check(TranslationServer.translate(game._back_button.tooltip_text) == game.tr("返回开始页面"), "设置返回图标说明正确指向开始页面")
	var status := game.find_child("SettingsStatus", true, false) as Label
	_check(status != null and not status.is_visible_in_tree(), "没有设置错误时不显示多余状态说明")
	game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(game.page == GameShell.Page.SETTINGS, "设置页重新聚焦保持原页面")
	var slider: HSlider = game.find_child("VolumeSlider", true, false)
	slider.value = 35
	_check(is_equal_approx(game.settings.volume, 0.35), "音量滑条连接到持久设置模型")
	_check(slider.get_tooltip().contains("35%"), "当前百分比保留在滑条悬停提示中")
	var language: OptionButton = game.find_child("LanguageOption", true, false)
	var english_index := GameSettings.SUPPORTED_LANGUAGES.find("en")
	language.select(english_index)
	language.item_selected.emit(english_index)
	_check(TranslationServer.get_locale().begins_with("en"), "语言下拉框即时切换英文")
	_check(game.tr("开始游戏") != "开始游戏", "英文词典实际提供开始按钮翻译")
	# 无效资源路径会在写盘前被模型拒绝，不访问真实设置，也不生成错误文件。
	var saved_path := game.settings.storage_path
	var saved_bytes := FileAccess.get_file_as_bytes(saved_path)
	game.settings.storage_path = "res://settings_write_rejected.json"
	slider.value = 40
	_check(not game.settings.last_error.is_empty() and status.is_visible_in_tree() and status.text.contains(game.tr("设置错误")), "保存失败在新设置卡片中显示错误反馈")
	_check(FileAccess.get_file_as_bytes(saved_path) == saved_bytes, "失败不覆盖原有有效设置")
	game.settings.storage_path = saved_path
	slider.value = 35
	_check(game.settings.last_error.is_empty() and not status.is_visible_in_tree(), "后续成功保存清除错误并再次隐藏状态行")
	await _capture("settings_english")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.MAIN, "设置返回开始页面")
	_check(not game._header.visible, "返回开始页后仍隐藏重复页头")
	await _capture("start_page_english")
	game.settings.set_language("zh_CN")
	game.settings.set_volume(1.0)


## 清除操作只使用独占目录中的完整记录，取消逐字节保持原样，确认保留导入地图和设置。
func _test_clear_builtin_progress(game: GameShell) -> void:
	var builtin_ids: Array[String] = []
	var created_paths: Array[String] = []
	var modules: Array = [{"id": "drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}}]
	for definition: LevelDefinition in game.catalog.levels:
		if definition.source_path.begins_with("res://data/levels/"):
			builtin_ids.append(definition.id)
	var custom := game.catalog.levels[0].document.duplicate_document()
	custom.id = "level_900"
	custom.display_name = "清除范围验证"
	var custom_path := game.user_levels_directory.path_join("clear_scope.json")
	_check(MapCodec.save_file(custom, custom_path, game.registry).is_ok(), "清除回归创建带关卡前缀的真实导入地图")
	game.catalog.refresh(game.registry)
	for identity in builtin_ids + [custom.id]:
		_check(game.drafts.save_draft(identity, SOLUTION, modules).is_ok() and game.drafts.mark_completed(identity).is_ok(), "清除夹具写入代码、装配与完成记录：" + identity)
		created_paths.append(game.drafts._path(identity, "draft"))
		created_paths.append(game.drafts._path(identity, "progress"))
		var recovery := game.drafts.backup_draft(identity)
		_check(recovery.is_ok() and recovery.value != null, "清除夹具包含草稿恢复副本：" + identity)
		if recovery.is_ok() and recovery.value != null:
			created_paths.append(recovery.value)
	var records_before := _clear_records_snapshot(game.drafts.directory)
	var settings_before := FileAccess.get_file_as_bytes(game.settings_path)
	var custom_before := FileAccess.get_file_as_bytes(custom_path)
	await _activate_visible_button(game.find_child("SettingsButton", true, false), "进入清除进度设置")
	var clear := game.find_child("ClearProgressButton", true, false) as Button
	_check(clear != null and clear.is_visible_in_tree() and TranslationServer.translate(clear.text) == game.tr("清除预设进度"), "更多设置提供重命名后的清除预设进度入口")
	for method in ["cancel", "escape", "outside"]:
		await _activate_visible_button(clear, "打开清除确认：" + method)
		await create_timer(0.22).timeout
		var cancel := game.find_child("CancelClearProgressButton", true, false) as Button
		var warning := game.find_child("ClearProgressBody", true, false) as Label
		_check(game._clear_progress_dialog.is_open() and cancel.has_focus(), "危险操作默认聚焦取消：" + method)
		_check(warning != null and TranslationServer.translate(warning.text) == game.tr("此选项将会清除全部系统自带关卡的通关记录、代码和装配草稿。一旦清除，不可恢复。"), "确认弹窗完整说明内置关卡、代码、装配与不可恢复范围")
		if method == "cancel":
			await _activate_visible_button(cancel, "取消清除进度")
		elif method == "escape":
			await _menu_key(KEY_ESCAPE)
		else:
			await _menu_click(game._back_button.get_global_rect().get_center())
		_check(not game._clear_progress_dialog.is_open() and game.page == GameShell.Page.SETTINGS, "关闭确认不会穿透触发返回：" + method)
		_check(not _clear_action_has_red_focus_border(clear), "取消预设清除后没有残留红色焦点边框：" + method)
		_check(_clear_records_snapshot(game.drafts.directory) == records_before and FileAccess.get_file_as_bytes(game.settings_path) == settings_before, "取消完整保留全部记录与设置：" + method)
	game._confirm_clear_progress()
	_check(_clear_records_snapshot(game.drafts.directory) == records_before, "没有待确认弹窗时不能直接绕过清除确认")
	await _activate_visible_button(clear, "再次请求清除系统关卡")
	await create_timer(0.22).timeout
	await _activate_visible_button(game.find_child("ConfirmClearProgressButton", true, false), "明确确认清除系统关卡")
	_check(not game._clear_progress_dialog.is_open() and game.page == GameShell.Page.SETTINGS, "确认后收起弹窗并保留设置页面")
	for identity in builtin_ids:
		var loaded := game.drafts.load_draft(identity)
		_check(not game.drafts.is_completed(identity) and loaded.is_ok() and loaded.value == null, "内置关卡的通关、代码及装配草稿已清除：" + identity)
		var prefix := identity.sha256_text() + "."
		var remaining := false
		for filename in _clear_records_snapshot(game.drafts.directory):
			remaining = remaining or str(filename).begins_with(prefix)
		_check(not remaining, "对应内置关卡的恢复副本也已清除：" + identity)
	var imported := game.drafts.load_draft(custom.id)
	_check(imported.is_ok() and imported.value != null and imported.value.source == SOLUTION and imported.value.modules == modules and game.drafts.is_completed(custom.id), "导入关卡的程序、装配与通关记录保留")
	for filename in records_before:
		if str(filename).begins_with(custom.id.sha256_text() + "."):
			_check(FileAccess.get_file_as_bytes(game.drafts.directory.path_join(filename)) == records_before[filename], "导入关卡各记录及恢复副本逐字节保留")
	_check(FileAccess.get_file_as_bytes(custom_path) == custom_before and FileAccess.get_file_as_bytes(game.settings_path) == settings_before, "清除不改导入地图及语言音量设置")
	var status := game.find_child("SettingsStatus", true, false) as Label
	_check(status.is_visible_in_tree() and not status.text.is_empty() and game.settings.last_error.is_empty(), "设置页面显示明确的清除成功反馈")
	# 清除结束后再写入一份新记录，确认回调重入必须保持这份新内容。
	var first_id := builtin_ids[0]
	_check(game.drafts.save_draft(first_id, "main() {}", []).is_ok(), "重复确认防护夹具创建成功")
	game._confirm_clear_progress()
	var guarded := game.drafts.load_draft(first_id)
	_check(guarded.is_ok() and guarded.value != null and guarded.value.source == "main() {}", "已结束的确认不能再次清除后来产生的草稿")
	DirAccess.remove_absolute(game.drafts._path(first_id, "draft"))
	_press_back(game)
	await process_frame
	await _activate_visible_button(game.find_child("StartGameButton", true, false), "清除后重新查看关卡")
	_check(not _has_completion_caption(game.find_child("LevelButton_0", true, false)) and _has_completion_caption(game.find_child("LevelButton_15", true, false)), "关卡列表刷新内置完成标记并保留导入完成标记")
	await _activate_visible_button(game.find_child("LevelButton_0", true, false), "清除后进入第一关")
	game._dialogue_dialog.hide()
	_check(game.session.source == game.session.level.starter_program and game._saved_modules.is_empty(), "清除后首次进入恢复初始代码且没有可载入的旧装配")
	_press_back(game)
	await process_frame
	# 只删除本函数显式创建的路径，后续原有测试仍从十二个内置关卡的空记录开始。
	for path in created_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(custom_path)
	game.catalog.refresh(game.registry)
	_press_back(game)
	await process_frame


## 用户清除仅影响独占导入目录及对应记录，两个确认范围不能相互替换或遗留。
func _test_clear_user_levels(game: GameShell) -> void:
	var builtin_id := game.catalog.levels[0].id
	var custom_ids: Array[String] = ["user_clear_alpha", "level_901"]
	var created_paths: Array[String] = []
	var map_paths: Array[String] = []
	var modules: Array = [{"id": "drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}}]
	for identity in custom_ids:
		var document := game.catalog.levels[0].document.duplicate_document()
		document.id = identity
		document.display_name = "用户清除测试 " + identity
		var map_path := game.user_levels_directory.path_join(identity + ".json")
		_check(MapCodec.save_file(document, map_path, game.registry).is_ok(), "用户清除夹具创建导入地图：" + identity)
		map_paths.append(map_path)
	for identity in [builtin_id] + custom_ids:
		_check(game.drafts.save_draft(identity, SOLUTION, modules).is_ok() and game.drafts.mark_completed(identity).is_ok(), "用户清除夹具写入草稿与完成记录：" + identity)
		created_paths.append(game.drafts._path(identity, "draft"))
		created_paths.append(game.drafts._path(identity, "progress"))
		var recovery := game.drafts.backup_draft(identity)
		_check(recovery.is_ok() and recovery.value != null, "用户清除夹具包含恢复副本：" + identity)
		if recovery.is_ok() and recovery.value != null:
			created_paths.append(recovery.value)
	game.catalog.refresh(game.registry)
	var records_before := _clear_records_snapshot(game.drafts.directory)
	var maps_before := _clear_records_snapshot(game.user_levels_directory)
	var settings_before := FileAccess.get_file_as_bytes(game.settings_path)
	await _activate_visible_button(game.find_child("SettingsButton", true, false), "进入用户关卡清除设置")
	var clear_user := game.find_child("ClearUserLevelsButton", true, false) as Button
	var clear_builtin := game.find_child("ClearProgressButton", true, false) as Button
	_check(clear_user != null and clear_user.is_visible_in_tree() and TranslationServer.translate(clear_user.text) == game.tr("清除用户关卡"), "更多设置第三行显示独立的清除用户关卡入口")
	for method in ["cancel", "escape", "outside"]:
		await _activate_visible_button(clear_user, "打开用户关卡清除确认：" + method)
		await create_timer(0.22).timeout
		var cancel := game.find_child("CancelClearProgressButton", true, false) as Button
		var warning := game.find_child("ClearProgressBody", true, false) as Label
		_check(game._clear_progress_dialog.is_open() and cancel.has_focus() and TranslationServer.translate(warning.text) == game.tr(ClearProgressDialog.USER_LEVELS_WARNING_BODY), "用户清除显示专属范围警告并默认聚焦取消：" + method)
		if method == "cancel":
			await _activate_visible_button(cancel, "取消用户关卡清除")
		elif method == "escape":
			await _menu_key(KEY_ESCAPE)
		else:
			await _menu_click(game._back_button.get_global_rect().get_center())
		_check(not game._clear_progress_dialog.is_open() and game.page == GameShell.Page.SETTINGS and not _clear_action_has_red_focus_border(clear_user), "取消用户清除后不返回、不遗留红色焦点边框：" + method)
		_check(_clear_records_snapshot(game.drafts.directory) == records_before and _clear_records_snapshot(game.user_levels_directory) == maps_before, "取消用户清除逐字节保留全部地图和记录：" + method)
	# 弹窗已打开时，另一请求不得偷偷替换玩家正在阅读的清除范围。
	await _activate_visible_button(clear_user, "检查用户确认范围固定")
	game._request_clear_progress()
	var warning := game.find_child("ClearProgressBody", true, false) as Label
	_check(TranslationServer.translate(warning.text) == game.tr(ClearProgressDialog.USER_LEVELS_WARNING_BODY), "用户确认打开时预设清除请求不能串用正文")
	await _menu_key(KEY_ESCAPE)
	await _activate_visible_button(clear_builtin, "检查预设确认范围固定")
	game._request_clear_user_levels()
	_check(TranslationServer.translate(warning.text) == game.tr(ClearProgressDialog.WARNING_BODY), "预设确认打开时用户清除请求不能串用正文")
	await _menu_key(KEY_ESCAPE)
	game._confirm_clear_progress()
	_check(_clear_records_snapshot(game.drafts.directory) == records_before and _clear_records_snapshot(game.user_levels_directory) == maps_before, "交替取消后不存在可重放的用户或预设清除请求")
	await _activate_visible_button(clear_user, "明确请求只清除用户关卡")
	await create_timer(0.22).timeout
	await _activate_visible_button(game.find_child("ConfirmClearProgressButton", true, false), "明确确认清除用户关卡")
	_check(not game._clear_progress_dialog.is_open() and game.page == GameShell.Page.SETTINGS, "用户清除结束后关闭确认框并保留设置页面")
	for map_path in map_paths:
		_check(not FileAccess.file_exists(map_path), "用户清除删除对应导入 JSON：" + map_path.get_file())
	var after := _clear_records_snapshot(game.drafts.directory)
	for identity in custom_ids:
		var remaining := false
		for filename in after:
			remaining = remaining or str(filename).begins_with(identity.sha256_text() + ".")
		_check(not remaining and not game.drafts.is_completed(identity) and game.drafts.load_draft(identity).value == null, "用户关卡通关记录、代码、装配与恢复副本一并清除：" + identity)
	for filename in records_before:
		if str(filename).begins_with(builtin_id.sha256_text() + "."):
			_check(after.get(filename) == records_before[filename], "用户清除保留预设关卡各记录及恢复副本")
	_check(FileAccess.get_file_as_bytes(game.settings_path) == settings_before, "用户关卡清除保留音量及语言设置")
	var status := game.find_child("SettingsStatus", true, false) as Label
	_check(status.is_visible_in_tree() and not status.text.is_empty(), "用户关卡清除显示结果反馈")
	_press_back(game)
	await process_frame
	await _activate_visible_button(game.find_child("StartGameButton", true, false), "用户清除后查看关卡目录")
	_check(game.catalog.levels.size() == 15 and game.find_child("LevelButton_15", true, false) == null and game.find_child("ImportLevelButton", true, false).is_visible_in_tree(), "选关页移除所有用户卡片并保留十五个预设关卡与导入入口")
	_check(_has_completion_caption(game.find_child("LevelButton_0", true, false)), "用户清除没有误删或隐藏预设关卡完成标记")
	# 仅清理本函数显式创建的夹具，让后续原有预设关卡流程仍从空记录开始。
	for path in created_paths + map_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	game.catalog.refresh(game.registry)
	_press_back(game)
	await process_frame


## 检查取消后的焦点样式没有红色描边；按钮仍由后续真实键盘输入验证可达。
func _clear_action_has_red_focus_border(button: Button) -> bool:
	var style := button.get_theme_stylebox("focus") as StyleBoxFlat
	if style == null or style.border_color.a <= 0.01:
		return false
	var has_border := style.border_width_left + style.border_width_right + style.border_width_top + style.border_width_bottom > 0
	return has_border and style.border_color.r > style.border_color.g + 0.05 and style.border_color.r > style.border_color.b + 0.05


## 以原始字节读取独占记录目录，避免 JSON 重序列化掩盖取消路径中的意外写盘。
func _clear_records_snapshot(directory_path: String) -> Dictionary:
	var snapshot := {}
	var directory := DirAccess.open(directory_path)
	if directory != null:
		for filename in directory.get_files():
			snapshot[filename] = FileAccess.get_file_as_bytes(directory_path.path_join(filename))
	return snapshot


## 完成状态以卡片实际文案为准，验证重进列表后的显示而不仅检查存储模型。
func _has_completion_caption(button: Button) -> bool:
	if button == null:
		return false
	for child in button.get_parent().get_children():
		if child is Label and child.text == "✓ 已完成":
			return true
	return false


## 退出替身保留真实按钮调用链，让测试进程继续汇总结果。
func _record_quit() -> void:
	_quit_requests += 1


## 只覆盖本次测试目录中的已有草稿，用于构造真实磁盘损坏场景。
func _overwrite_test_draft(path: String, source: String) -> void:
	var absolute_root := ProjectSettings.globalize_path(_test_directory).replace("\\", "/")
	var absolute_path := ProjectSettings.globalize_path(path).replace("\\", "/")
	if not absolute_path.begins_with(absolute_root + "/"):
		_check(false, "测试拒绝覆盖隔离目录外的文件")
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "可以写入隔离目录中的损坏草稿夹具")
	if file != null:
		file.store_string(source)
		file.close()


## 在草稿同目录寻找恢复副本，并按原始文本逐字核对保留内容。
func _has_recovery_copy(directory_path: String, original: String) -> bool:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return false
	for filename in directory.get_files():
		if filename.contains(".recovery.") and filename.ends_with(".json"):
			if FileAccess.get_file_as_string(directory_path.path_join(filename)) == original:
				return true
	return false


## 统计恢复文件以检查同一恢复流程不会因普通自动保存重复备份。
func _recovery_count(directory_path: String) -> int:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return 0
	var count := 0
	for filename in directory.get_files():
		if filename.contains(".recovery.") and filename.ends_with(".json"):
			count += 1
	return count


## 记录打开请求而不启动真实资源管理器，测试仍验证了点击后的完整调用链。
func _record_folder_open(path: String) -> int:
	_opened_paths.append(path)
	return OK


## 消费所有地图对话，使用生产对话框的确认信号推进。
func _finish_dialogue(game: GameShell) -> void:
	for index in range(game.session.level.document.dialogue.size() + 1):
		if game._dialogue_dialog.visible:
			game._dialogue_dialog.confirmed.emit()


## 按按钮文字查找实际控件，避免测试绕过关卡按钮的信号连接。
func _find_button(parent: Node, text: String) -> Button:
	for child in parent.find_children("*", "Button", true, false):
		if child.text == text:
			return child
	return null


## 通过真实画布 gui_input 信号模拟点击，而不是直接修改组装模型。
func _stroke(canvas: AssemblyCanvas, position: Vector2, button: MouseButton) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.button_index = button
	event.pressed = true
	canvas.gui_input.emit(event)
	event = event.duplicate()
	event.pressed = false
	canvas.gui_input.emit(event)


## 先用左键选择再按 Delete 删除，右键只用于平移装配视图。
func _delete_at(canvas: AssemblyCanvas, offset: Vector2) -> void:
	_stroke(canvas, canvas.pixel_at(offset), MOUSE_BUTTON_LEFT)
	var event := InputEventKey.new()
	event.keycode = KEY_DELETE
	event.pressed = true
	canvas.gui_input.emit(event)


## 模拟完整的鼠标按下、移动、释放，覆盖图形拖动到模型提交的流程。
func _drag(canvas: AssemblyCanvas, from: Vector2, to: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = canvas.pixel_at(from)
	down.pressed = true
	canvas.gui_input.emit(down)
	var motion := InputEventMouseMotion.new()
	motion.position = canvas.pixel_at(to)
	canvas.gui_input.emit(motion)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = canvas.pixel_at(to)
	up.pressed = false
	canvas.gui_input.emit(up)


## 有图形后端时保存真实视口供目视检查，默认无窗口测试不截图。
func _capture(label: String) -> void:
	if not "--capture" in OS.get_cmdline_user_args():
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://test-results")
	_check(screenshot != null and not screenshot.is_empty(), label + " 视口已渲染")
	if screenshot != null and not screenshot.is_empty():
		screenshot.save_png("res://test-results/" + label + ".png")


## 仅删除本次创建的测试目录，绝不清理玩家实际的关卡与作品目录。
func _cleanup(path: String) -> void:
	if not path.begins_with(_test_directory) or _test_directory.is_empty():
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 汇总所有检查，失败保持非零退出码并保留易读的失败原因。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 动态对象通过实际编辑器测试入口运行，未保存内容、历史和正式草稿保持隔离。
func _test_object_playtest(game: GameShell) -> void:
	var editor := game._editor
	for index in [2, 3]:
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, editor.registry, true)
		_check(loaded.is_ok(), "编辑器可读取含动态对象的完整关卡")
		var path := _test_directory.path_join("object_map_%d.json" % index)
		editor.editor_document.replace_document(loaded.value, path)
		var model := editor.editor_document
		model.begin_action()
		# 修改未保存的对象属性，测试入口必须用它，不能重读内置地图。
		if index == 2:
			model.document.objects[0].properties.close_after_ticks = 31
		else:
			model.document.objects[0].properties.max_health = 2
		model.end_action()
		_check(model.is_dirty(), "动态对象编辑产生未保存标记")
		model.undo()
		_check(not model.is_dirty(), "对象修改可撤销回保存点")
		model.redo()
		var snapshot := JSON.stringify(model.document.to_dict())
		var undo_count := model._undo_stack.size()
		var original_draft := JSON.stringify(game.drafts.load_draft(model.document.id).value)
		var original_completed := game.drafts.is_completed(model.document.id)
		editor._play_button.pressed.emit()
		await process_frame
		game._dialogue_dialog.hide()
		_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "对象试玩沿用空装配入口")
		_check(game.session.level.document.objects == model.document.objects, "对象试玩使用未保存的元数据快照")
		game.session.assembly.add_module("movement", Vector2.ZERO)
		game.session.assembly.add_module("movement" if index == 2 else "melee", Vector2(0.5, 0))
		game.session.source = "main(){move(0,8)}" if index == 2 else "main(){\nmove(0,3)\nattack(0)\nattack(0)\n}"
		game._confirm_assembly()
		await process_frame
		game.workbench.set_process(false)
		_check(not game.workbench.allow_draft_save, "对象试玩隐藏正式草稿保存")
		game.workbench._run_button.pressed.emit()
		if index == 3:
			_check(game.session.world.get_object("training_obstacle").health == 2, "未保存的两点障碍耐久用于试玩实例")
		# 第二关的真实倒计时只做一组动画验证，避免在所有关卡重复等待。
		var running_source := game.session.source
		if index == 2:
			await create_timer(0.3).timeout
			var live_status := game.workbench._live_status
			_check(live_status.is_expanded() and live_status.is_visible_in_tree(), "限时闸门运行时自动展开状态药丸")
			_check(live_status.status_label.text.contains("[b][color=#d82929]"), "倒计时数字以指定红色粗体突出")
			game.workbench._pause_button.pressed.emit()
			var frozen_tick := game.session.world.tick_index
			await create_timer(0.3).timeout
			_check(game.session.state == GameSession.State.PAUSED and game.session.world.tick_index == frozen_tick and live_status.is_expanded(), "暂停时状态药丸保持展开且倒计时不推进")
			game.workbench._pause_button.pressed.emit()
		for unused in 100:
			game.session.step()
		if index == 2:
			_check(game.session.state == GameSession.State.FAILED, "修改后的落闸时间真正参与试玩")
		else:
			_check(game.session.world.get_object("training_obstacle").health == 0, "两次实际攻击击毁修改为两点耐久的障碍")
			# 编辑器现在统一采用限时到达终点或清敌；障碍物不冒充敌人触发胜利。
			_check(game.session.state == GameSession.State.RUNNING, "仅击毁障碍物的无终点、无敌人地图继续倒计时")
		_check(game.workbench._object_status.visible and not game.workbench._object_status.text.is_empty(), "实际工作台显示对象运行状态")
		if index == 2:
			await create_timer(1.5).timeout
			_check(not game.workbench._live_status.is_expanded() and game.session.source == running_source, "终态短暂停留后收回状态药丸且保留玩家代码")
		_press_back(game)
		await process_frame
		_check(game._editor == editor and editor.editor_document == model and model.path == path, "返回保留同一编辑文档及路径")
		_check(model.is_dirty() and model._undo_stack.size() == undo_count and JSON.stringify(model.document.to_dict()) == snapshot, "试玩伤害与闸门不污染原对象或撤销历史")
		_check(JSON.stringify(game.drafts.load_draft(model.document.id).value) == original_draft and game.drafts.is_completed(model.document.id) == original_completed, "同 ID 正式草稿和通关标记不受对象试玩影响")
		var saved := MapCodec.save_file(model.document, path, editor.registry, true)
		_check(saved.is_ok(), "动态对象可保存为地图 JSON")
		# JSON 读取后整数可能变为浮点；比较实际数据，不把 31 与 31.0 的拼写差异当作丢失。
		var roundtrip := MapCodec.load_file(path, editor.registry, true)
		_check(roundtrip.is_ok() and JSON.stringify(JSON.parse_string(JSON.stringify(roundtrip.value.to_dict()))) == JSON.stringify(JSON.parse_string(snapshot)), "动态对象完整文件往返不丢失字段")
		var disk_text := FileAccess.get_file_as_string(path)
		var broken := model.document.duplicate_document()
		broken.objects[0].size = -1
		_check(not MapCodec.save_file(broken, path, editor.registry, true).is_ok() and FileAccess.get_file_as_string(path) == disk_text, "非法对象不能覆盖有效地图文件")


## 通过实际按钮、标题栏鼠标和键盘取消，确认不会刷新列表或退出游戏。
func _test_import_cancel(game: GameShell) -> void:
	var original_level := game.catalog.levels[0]
	var original_page_child := game._body.get_child(0)
	var original_quit_count := _quit_requests
	_check(game._import_dialog.get_cancel_button().text == "取消导入", "导入提示提供明确的取消导入按钮")
	for method in ["button", "title_close", "escape", "close_request"]:
		if not game._import_dialog.visible:
			game.find_child("ImportLevelButton", true, false).pressed.emit()
		await process_frame
		await process_frame
		var opened_before := _opened_paths.size()
		var dialog := game._import_dialog
		if method == "button":
			dialog.get_cancel_button().pressed.emit()
		elif method == "title_close":
			var icon := dialog.get_theme_icon("close", "Window")
			var close_position := Vector2(dialog.position) + Vector2(dialog.size.x - dialog.get_theme_constant("close_h_offset", "Window"), -dialog.get_theme_constant("close_v_offset", "Window")) + icon.get_size() / 2.0
			# 走内嵌窗口的真实命中处理，不能用直接 hide 代替关闭图标测试。
			for pressed in [true, false]:
				var click := InputEventMouseButton.new()
				click.position = close_position
				click.global_position = close_position
				click.button_index = MOUSE_BUTTON_LEFT
				click.pressed = pressed
				root.push_input(click)
		elif method == "escape":
			for pressed in [true, false]:
				var key := InputEventKey.new()
				key.keycode = KEY_ESCAPE
				key.pressed = pressed
				root.push_input(key)
		else:
			dialog.close_requested.emit()
		await process_frame
		await process_frame
		_check(not dialog.visible and game.page == GameShell.Page.LEVELS, method + " 关闭导入提示并留在选关页")
		_check(game.catalog.levels[0] == original_level and game._body.get_child(0) == original_page_child, method + " 不重新扫描或重建关卡列表")
		_check(_opened_paths.size() == opened_before and _quit_requests == original_quit_count, method + " 不打开额外目录或退出游戏")
	game.settings.set_language("en")
	game._import_levels()
	await process_frame
	await process_frame
	_check(TranslationServer.translate(game._import_dialog.get_cancel_button().text) == "Cancel Import", "取消导入支持英文翻译")
	var dialog := game._import_dialog
	for button in [dialog.get_cancel_button(), dialog.get_ok_button()]:
		_check(dialog.get_visible_rect().encloses(button.get_global_rect()), "中英确认与取消按钮都位于提示窗口内")
	dialog.get_cancel_button().pressed.emit()
	await process_frame
	game.settings.set_language("zh_CN")
	game._import_levels()
	await process_frame
	_check(game._import_dialog.visible, "连续取消后仍能重新打开导入并继续原有确认流程")


## 第四关沿用真实空装配、按钮运行、返回编辑和进度保存流程。
func _test_fourth_level(game: GameShell) -> void:
	var fourth: LevelDefinition = game.catalog.levels[3]
	_check(fourth.id == "level_004", "第四张关卡卡片引用第四关")
	game._enter_level(fourth)
	await process_frame
	_finish_dialogue(game)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "第四关从空装配开始")
	var shooting: Button = game.assembly_panel.palette_buttons["shooting"]
	_check(not shooting.disabled, "第四关的射击模块可以手动选择")
	shooting.pressed.emit()
	_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1 and game.session.assembly.modules[0].module_id == "shooting", "画布安装真实射击模块")
	_check(game.assembly_panel.palette_buttons["movement"].disabled and game.assembly_panel.palette_buttons["melee"].disabled, "装满后旧模块也不能绕过单模块上限")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	var source := "main(){}\ntick(){shoot(0)}"
	game.workbench._code.text = source
	game.workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING, "正式运行按钮启动第四关程序")
	game.session.step()
	_check(game.session.world.get_machine("guard") != null and not game.session.world.projectiles.is_empty(), "工作台同一世界内出现敌人与弹丸")
	game.workbench._pause_button.pressed.emit()
	var before := game.session.world.tick_index
	game.session.step()
	_check(game.session.state == GameSession.State.PAUSED and game.session.world.tick_index == before, "第四关暂停按钮冻结战场")
	var session := game.session
	game.workbench.find_child("EditModulesButton", true, false).pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.ASSEMBLY and game.session == session and session.world == null, "战斗暂停时返回组装会停止世界并复用会话")
	_check(session.source == source and session.assembly.modules[0].module_id == "shooting", "返回组装保留射击程序和模块")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	game.workbench._run_button.pressed.emit()
	for unused in 200:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(fourth.id), "实际 UI 射击获胜后保存第四关完成记录")
	_check(game.workbench._object_status.visible and not game.workbench._object_status.text.is_empty(), "敌人状态在工作台中可见")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.session == null, "第四关胜利后正常返回关卡页")


## 第五关经真实卡片和装配属性命名模块，错误可修改并保存正常越狱后的完成记录。
func _test_fifth_level(game: GameShell) -> void:
	var fifth: LevelDefinition = game.catalog.levels[4]
	var card := game.find_child("LevelButton_4", true, false) as Button
	_check(fifth.id == "level_005" and card != null and card.icon != null, "第五关显示地图缩略图并保留可点击卡片")
	if card == null or not (await _open_tutorial_card(game, 4)):
		return
	_finish_dialogue(game)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "第五关实际卡片进入空装配流程")
	var modules := [
		{"module_id": "movement", "id": "drive", "position": Vector2.ZERO},
		{"module_id": "melee", "id": "left", "position": Vector2(-0.5, 0)},
		{"module_id": "melee", "id": "right", "position": Vector2(0.5, 0)},
	]
	for entry: Dictionary in modules:
		game.assembly_panel.palette_buttons[entry.module_id].pressed.emit()
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(entry.position), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = entry.id
		game.assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules.size() == 3 and game.session.assembly.modules[1].id == "left" and game.session.assembly.modules[2].id == "right", "玩家通过画布和名称属性生成可被代码引用的三个模块")
	_check(not game._confirm_assembly_button.disabled and game.assembly_panel.palette_buttons["shooting"].disabled, "合法三模块装配可确认，数量满后不能新增")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	game.workbench._code.text = "main(){\nleft.attack(180)\nmissing.attack(0)\n}"
	game.workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.FAILED and game.workbench._highlighted_line == 2 and game.workbench._status.text.contains("missing"), "拼错模块名在实际代码编辑区高亮错误行并显示实例名")
	if game.session.world != null:
		_check(game.session.world.tick_index == 0 and not game.session.world.get_machine("guard").is_destroyed(), "UI 命名错误预检不会先执行前一条攻击")
	var source := "main(){\nleft.attack(180)\nright.attack(0)\nmove(90,5)\n}"
	game.workbench._code.text = source
	game.workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING, "修正模块名称后可通过正式运行按钮重试")
	for unused in 120:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(fifth.id), "实际 UI 完成越狱后记录第五关通关状态")
	_check(game.workbench._object_status.visible and not game.workbench._object_status.text.is_empty(), "工作台显示警卫和门禁目标状态")
	await _capture("fifth_level_completed")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.session == null, "第五关正常返回关卡网格")
	game._enter_level(fifth)
	await process_frame
	_finish_dialogue(game)
	_check(game.session.assembly.modules.is_empty() and game.session.source == source, "再次进入第五关仍空装配，但保留玩家的命名程序草稿")
	_press_back(game)
	await process_frame


## 第六关通过真实卡片、分页引导和中心装配运行循环，诊断与通关草稿保持完整。
func _test_sixth_level(game: GameShell) -> void:
	var sixth: LevelDefinition = game.catalog.levels[5]
	var card := game.find_child("LevelButton_5", true, false) as Button
	_check(sixth.id == "level_006" and card != null and card.icon != null, "第六关使用可点击的阶梯地图缩略图")
	if card == null or not (await _open_tutorial_card(game, 5)):
		return
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "第六关实际入口仍从空装配开始")
	_check(game._dialogue_dialog.visible and sixth.document.dialogue.size() == 6 and game._dialogue_previous.disabled, "六页循环引导从首页显示，上一页正确禁用")
	var first_guide := game._dialogue_dialog.dialog_text
	game._dialogue_dialog.confirmed.emit()
	_check(game._dialogue_index == 1 and not game._dialogue_previous.disabled, "第六关引导可前进到下一页")
	game._dialogue_previous.pressed.emit()
	_check(game._dialogue_index == 0 and game._dialogue_dialog.dialog_text == first_guide, "上一页按钮恢复第一条引导内容")
	_finish_dialogue(game)
	_check(not game._dialogue_dialog.visible and game._confirm_assembly_button.disabled, "完成引导后仍需手动组装，不能空装配进入编程")
	game.assembly_panel.palette_buttons["movement"].pressed.emit()
	_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 1 and not game._confirm_assembly_button.disabled, "实际画布安装中心移动模块后可确认")
	_check(game.assembly_panel.palette_buttons["movement"].disabled and game.assembly_panel.palette_buttons["shooting"].disabled, "单模块上限在第六关实际目录中生效")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	_check(game.page == GameShell.Page.PLAY and game.workbench._code.text.contains("loop"), "进入编程后显示第六关的循环模板")
	game.workbench._code.text = "main(){\nloop {\nmove(0,)\n}\n}"
	game.workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.FAILED and game.session.world == null, "循环中错误参数被实际运行按钮拒绝")
	_check(game.workbench._highlighted_line == 2 and game.workbench._status.text.contains("第 3 行"), "循环内语法错误高亮对应源代码行")
	var source := "main(){\nloop {\nmove(0,3)\nmove(90,2)\n}\n}"
	game.workbench._code.text = source
	game.workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING and not game.workbench._code.editable, "修正后运行真实无限循环并锁定运行中的编辑")
	for unused in 550:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(sixth.id), "实际 UI 走完十组阶梯并记录第六关完成状态")
	_check(game.session.runner.state == ProgramRunner.State.CANCELLED and game.workbench._status.text.contains("关卡完成"), "到达终点后工作台显示胜利并停止无限循环")
	await _capture("sixth_level_completed")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.session == null, "第六关胜利后正常返回关卡网格")
	game._enter_level(sixth)
	await process_frame
	_finish_dialogue(game)
	_check(game.session.assembly.modules.is_empty() and game.session.source == source, "再次进入第六关保持空装配并恢复循环程序草稿")
	_press_back(game)
	await process_frame


## 第七关由卡片和双模块装配进入条件编程，覆盖双语引导、通关及可撤销代码重置。
func _test_seventh_level(game: GameShell) -> void:
	var seventh: LevelDefinition = game.catalog.levels[6]
	var card := game.find_child("LevelButton_6", true, false) as Button
	_check(seventh.id == "level_007" and card != null and card.icon != null, "第七关显示可点击的追击地图 SVG 缩略图")
	if card == null or not (await _open_tutorial_card(game, 6)):
		return
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty() and game._confirm_assembly_button.disabled, "第七关从空装配与禁用确认开始")
	_check(game._dialogue_dialog.visible and seventh.document.dialogue.size() >= 6 and game._dialogue_previous.disabled, "条件关卡打开分页引导并正确禁用首页返回")
	var source_before := game.session.source
	for index in range(seventh.document.dialogue.size()):
		var original := game._dialogue_dialog.dialog_text
		_check(original == seventh.document.dialogue[index].text, "第七关引导按作者定义逐页显示")
		game.settings.set_language("en")
		await process_frame
		_check(game.tr(original) != original and game.tr(game._dialogue_dialog.ok_button_text) != game._dialogue_dialog.ok_button_text, "第七关每页引导和导航按钮均有英文翻译")
		game.settings.set_language("zh_CN")
		await process_frame
		_check(game.tr(original) == original and game.session.source == source_before, "中文引导恢复原文且语言切换不改写初始代码")
		game._dialogue_dialog.confirmed.emit()
	_check(not game._dialogue_dialog.visible, "第七关最后一页完成后可以继续装配")
	var modules := [
		{"module_id": "movement", "id": "drive", "position": Vector2.ZERO},
		{"module_id": "shooting", "id": "gun", "position": Vector2(0.5, 0)},
	]
	for entry: Dictionary in modules:
		game.assembly_panel.palette_buttons[entry.module_id].pressed.emit()
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(entry.position), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = entry.id
		game.assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules.size() == 2 and game.session.assembly.modules[1].id == "gun" and not game._confirm_assembly_button.disabled, "实际装配画布和属性面板创建共边双模块与 gun 名称")
	_check(game.assembly_panel.palette_buttons["movement"].disabled and game.assembly_panel.palette_buttons["shooting"].disabled, "第七关达到两个模块上限后禁用新增")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	var workbench := game.workbench
	_check(game.page == GameShell.Page.PLAY and workbench._code.text == seventh.starter_program and not workbench._code.text.contains("move(") and not workbench._code.text.contains("ready("), "第七关实际编辑器显示空循环，不预填条件和移动答案")
	var syntax := workbench._code.syntax_highlighter as CodeHighlighter
	_check(syntax != null and syntax.keyword_colors.has("if") and syntax.keyword_colors.has("else") and syntax.keyword_colors.has("ready"), "条件关键字与就绪查询使用正式代码高亮")
	var source := "main() {\n    loop {\n        if (gun.ready()) {\n            gun.shoot(0)\n        } else {\n            move(180, 0.1)\n        }\n    }\n}\n"
	workbench._code.text = source.replace("gun.ready()", "missing.ready()")
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.FAILED and workbench._highlighted_line == 2 and workbench._status.text.contains("missing"), "条件名称错误由真实运行按钮报告并高亮第 3 行")
	_check(game.session.world == null or game.session.world.tick_index == 0, "错误条件未提前推进追击战场")
	workbench._code.text = source
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING and not workbench._code.editable, "修正条件后可运行并锁定运行中的代码")
	game.session.step()
	workbench._pause_button.pressed.emit()
	var paused_tick := game.session.world.tick_index
	game.session.step()
	_check(game.session.state == GameSession.State.PAUSED and game.session.world.tick_index == paused_tick, "第七关实际暂停按钮冻结射击与追击")
	workbench._pause_button.pressed.emit()
	for unused in 350:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(seventh.id), "实际 UI 完成退射并保存第七关通关记录")
	_check(game.session.runner.state == ProgramRunner.State.CANCELLED and workbench._object_status.visible and workbench._status.text.contains("关卡完成"), "击毁敌人后停止无限循环并显示战斗胜利")
	await _capture("seventh_level_completed")
	var assembly := JSON.stringify(game.session.assembly.modules)
	workbench._reset_code_button.pressed.emit()
	await process_frame
	_check(workbench._code.text == seventh.starter_program and game.session.source == seventh.starter_program and game.session.world == null, "第七关重置代码恢复空框架并释放战斗世界")
	_check(JSON.stringify(game.session.assembly.modules) == assembly and game.drafts.is_completed(seventh.id), "重置空框架保留模块与已有通关记录")
	workbench._code.undo()
	await process_frame
	_check(workbench._code.text == source and game.session.source == source, "第七关原生撤销可一次恢复玩家的完整条件程序")
	workbench._code.redo()
	await process_frame
	_check(workbench._code.text == seventh.starter_program and game.session.source == seventh.starter_program, "重做再次恢复空框架并同步会话")
	await create_timer(1.0).timeout
	var saved := game.drafts.load_draft(seventh.id)
	_check(saved.is_ok() and saved.value != null and saved.value.source == seventh.starter_program and JSON.stringify(saved.value.modules) == assembly, "第七关代码重置通过既有自动保存链持久化空模板和装配")
	_press_back(game)
	await process_frame
	game._enter_level(seventh)
	await process_frame
	_finish_dialogue(game)
	_check(game.session.source == seventh.starter_program and game.session.assembly.modules.is_empty(), "重进第七关恢复重置后的模板，仍不自动载入装配")
	game.find_child("RestoreAssemblyButton", true, false).pressed.emit()
	_check(JSON.stringify(game.session.assembly.modules) == assembly, "玩家仍可主动恢复原双模块装配")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.session == null, "第七关流程结束正常返回关卡网格")


## 第八关经过真实装配、资料窗与运行入口，验证并发教学及双语界面使用新关卡数据。
func _test_eighth_level(game: GameShell) -> void:
	var eighth: LevelDefinition = game.catalog.levels[7]
	var card := game.find_child("LevelButton_7", true, false) as Button
	_check(eighth.id == "level_008" and card != null and card.icon != null, "第八关显示可点击的联动警报地图 SVG 缩略图")
	if card == null or not (await _open_tutorial_card(game, 7)):
		return
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty() and game._confirm_assembly_button.disabled, "第八关仍先空装配，不预装地图模板")
	_check(eighth.module_limit == 3 and eighth.allow_simultaneous, "第八关开放并发并限制三个模块")
	var source_before := game.session.source
	_check(game._dialogue_dialog.visible and game._dialogue_previous.disabled, "同步关卡的分页引导从首页开始")
	for index in range(eighth.document.dialogue.size()):
		var original := game._dialogue_dialog.dialog_text
		_check(original == eighth.document.dialogue[index].text, "第八关教程按 JSON 顺序逐页显示")
		game.settings.set_language("en")
		await process_frame
		_check(game.tr(original) != original and game.tr(game._dialogue_dialog.ok_button_text) != game._dialogue_dialog.ok_button_text, "第八关每页教程及分页操作均有英文译文")
		game.settings.set_language("zh_CN")
		await process_frame
		_check(game.tr(original) == original and game.session.source == source_before, "切回中文不改写同步关卡的初始代码")
		game._dialogue_dialog.confirmed.emit()
	_check(not game._dialogue_dialog.visible, "最后一页同步教程完成后可以编辑装配")
	var modules := [
		{"module_id": "melee", "id": "left", "position": Vector2.ZERO},
		{"module_id": "movement", "id": "drive", "position": Vector2(0.5, 0)},
		{"module_id": "melee", "id": "right", "position": Vector2(1, 0)},
	]
	for entry: Dictionary in modules:
		game.assembly_panel.palette_buttons[entry.module_id].pressed.emit()
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(entry.position), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = entry.id
		game.assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules.size() == 3 and game.session.assembly.modules[0].id == "left" and not game._confirm_assembly_button.disabled, "真实画布允许近战放在中心并连接驱动和第二个近战")
	for module_id in ["movement", "melee", "shooting"]:
		_check(game.assembly_panel.palette_buttons[module_id].disabled, "达到三模块上限后禁用目录新增：" + module_id)
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	var workbench := game.workbench
	_check(game.page == GameShell.Page.PLAY and workbench._code.text == eighth.starter_program and not workbench._code.text.contains("attack(") and not workbench._code.text.contains("move(") and not workbench._code.text.contains("simultaneously"), "第八关实际编辑器只显示空 main 框架，不预填解法")
	var syntax := workbench._code.syntax_highlighter as CodeHighlighter
	_check(syntax != null and syntax.keyword_colors.has("simultaneously"), "代码编辑器正式高亮同时执行关键字")
	var help_source := "simultaneously { ... } 同一帧启动块内动作。\n使用不同的模块名分别控制左右攻击，全部完成后再移动。\n警报解除前移动或先后拆除都会报警；Ctrl+Enter 运行。"
	var help_label: Label
	for control in workbench._code.get_parent().get_children():
		if control is Label and control.text == help_source:
			help_label = control
	_check(help_label != null and help_label.is_visible_in_tree(), "程序卡片显示第八关专属三行说明")
	_check(workbench._entry_hint.text == "同步启动多个动作，全部完成后继续执行。" and workbench._goal_text() == "本关目标：同时解除左右两个警报器，再向上逃出监狱。", "工作台使用同步提示与双警报目标，不沿用上一关退射提示")
	for source in [help_source, workbench._entry_hint.text, workbench._goal_text(), "警报器 {alive} / {total}", "警报已解除，出口已打开", "同时破坏两个警报器后，再向上逃出监狱。", "出口已解锁，请继续向上走到终点。"]:
		game.settings.set_language("en")
		_check(game.tr(source) != source, "第八关工作台和警报状态文案有英文译文")
	game.settings.set_language("zh_CN")
	await process_frame
	var menu := game._command_menu
	await _activate_visible_button(workbench.header.book_button, "从第八关编程页打开指令集合")
	await _activate_visible_button(_command_section_button(menu, "general", "general"), "查看新增的同时执行资料")
	var simultaneous_card := menu.find_child("CommandCard_simultaneously", true, false) as CommandReferenceItem
	_check(menu.is_open() and simultaneous_card != null, "新增 JSON 自动出现在编程基础目录")
	if simultaneous_card != null:
		_check(bool(simultaneous_card.get_meta("available")) and simultaneous_card.get_tooltip().is_empty() and simultaneous_card.details.get_theme_color("font_color") == GameTheme.TEXT, "第八关同时执行资料已解锁，使用正常文字且没有未解锁提示")
		await _activate_visible_button(simultaneous_card.header_button, "展开同时执行说明")
		await create_timer(0.35).timeout
		_check(simultaneous_card.expanded and simultaneous_card.details.is_visible_in_tree() and simultaneous_card.syntax.text.begins_with("simultaneously"), "并发资料可展开查看完整语法和功能说明")
	await _activate_visible_button(menu.header.search_button, "展开指令搜索")
	await _set_command_query(menu, "同一模块")
	_check(_command_result_ids(menu) == ["simultaneously"] and _command_items_collapsed(menu), "中文描述关键词可找到新增同时执行指令")
	await _set_command_query(menu, "")
	game.settings.set_language("en")
	await process_frame
	await process_frame
	await _set_command_query(menu, "projectile speed")
	_check(_command_result_ids(menu) == ["simultaneously"] and menu._details[0].text.contains("projectile speed"), "英文搜索可匹配同时执行的弹丸时序说明")
	game.settings.set_language("zh_CN")
	await process_frame
	await _activate_visible_button(workbench.header.book_button, "关闭第八关指令资料窗")
	_check(not menu.is_open() and game.session.source == source_before, "阅读资料和切换语言不改写玩家的初始程序")
	workbench._code.text = "main() {\n    simultaneously {\n        left.attack(180)\n        right.attack(0)\n    }\n    move(90, 6)\n}\n"
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING, "真实运行按钮启动同时执行程序")
	for unused in 80:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(eighth.id), "真实 UI 同时解除警报并逃离，保存第八关通关记录")
	_check(workbench._status.text.contains("关卡完成"), "第八关完成结果进入既有工作台反馈")
	await _capture("eighth_level_completed")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS and game.session == null, "第八关流程结束正常返回选关页面")


## 第四关编辑器测试使用未保存敌人坐标，结束后保留地图并隔离正式进度。
func _test_enemy_playtest(game: GameShell) -> void:
	var editor := game._editor
	var loaded := MapCodec.load_file("res://data/levels/level_004.json", editor.registry, true)
	_check(loaded.is_ok(), "编辑器能够载入第四关敌人地图")
	if not loaded.is_ok():
		return
	var path := _test_directory.path_join("enemy_map.json")
	editor.editor_document.replace_document(loaded.value, path)
	var model := editor.editor_document
	model.begin_action()
	model.document.enemies[0].position.x = 8.5
	model.end_action()
	var snapshot := JSON.stringify(model.document.to_dict())
	var undo_count := model._undo_stack.size()
	var draft := JSON.stringify(game.drafts.load_draft(model.document.id).value)
	var completed_before := game.drafts.is_completed(model.document.id)
	editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "第四关编辑器测试也经过空装配")
	_check(game.session.level.document.enemies[0].position.x == 8.5, "编辑器测试读取未保存的敌人坐标")
	game.session.assembly.add_module("shooting", Vector2.ZERO)
	game.session.source = "main(){}\ntick(){shoot(0)}"
	game._confirm_assembly()
	await process_frame
	game.workbench.set_process(false)
	_check(not game.workbench.allow_draft_save, "敌人试玩不提供正式草稿保存")
	game.workbench._run_button.pressed.emit()
	_check(game.session.world.get_machine("guard").position.x == 8.5, "试玩世界真正使用更新后的敌人出生点")
	for unused in 200:
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED, "编辑器测试复用正式射击与胜利判定")
	_press_back(game)
	await process_frame
	_check(game._editor == editor and editor.editor_document == model and model.path == path, "敌人试玩返回原编辑文档与路径")
	_check(model.is_dirty() and model._undo_stack.size() == undo_count and JSON.stringify(model.document.to_dict()) == snapshot, "弹丸伤害不修改编辑器敌人耐久或撤销历史")
	_check(JSON.stringify(game.drafts.load_draft(model.document.id).value) == draft and game.drafts.is_completed(model.document.id) == completed_before, "第四关试玩不覆盖同 ID 正式草稿和进度")


## 通过正式工作台按钮覆盖初始代码恢复、撤销重做、运行取消和草稿持久化边界。
func _test_reset_code(game: GameShell, first: LevelDefinition) -> void:
	var workbench := game.workbench
	var session := game.session
	var assembly := session.assembly
	var original_modules := JSON.stringify(assembly.modules)
	var original_maps: Array[String] = []
	for definition: LevelDefinition in game.catalog.levels:
		original_maps.append(JSON.stringify(definition.document.to_dict(), "", true))
	var other: LevelDefinition = game.catalog.levels[1]
	var unrelated := game.drafts.save_draft(other.id, "// 其他关卡的独立草稿\nmain(){}\n", other.document.player_spawn.modules)
	_check(unrelated.is_ok(), "重置测试准备另一关的独立存档")
	var unrelated_path := game.drafts._path(other.id, "draft")
	var unrelated_bytes := FileAccess.get_file_as_bytes(unrelated_path)
	var progress_path := game.drafts._path(first.id, "progress")
	var completed_bytes := FileAccess.get_file_as_bytes(progress_path)
	var reset_position := workbench.find_child("ResetPositionButton", true, false) as Button
	var reset_code := workbench.find_child("ResetCodeButton", true, false) as Button
	_check(reset_position != null and reset_code != null, "工作台提供两个独立的重置位置与重置代码按钮")
	if reset_position == null or reset_code == null:
		return
	_check(reset_code == workbench._reset_code_button and reset_code == workbench._actions_menu._items[3] and reset_position == workbench.header.reset_button, "重置位置保持顶部快捷入口，重置代码移至二级菜单")
	_check(reset_code.text == "重置代码" and not reset_code.disabled, "中文重置代码入口可点击")
	game.settings.set_language("en")
	await process_frame
	_check(TranslationServer.translate(reset_code.text) == "Reset Code", "重置代码按钮随设置切换英文")
	game.settings.set_language("zh_CN")
	await process_frame
	_check(session.source == SOLUTION and workbench._code.text == SOLUTION, "切换语言不会翻译或替换玩家代码")

	# 点击已完成关卡的重置入口，再用编辑器自己的撤销栈验证整体替换只有一个步骤。
	await _open_program_actions(workbench)
	await _activate_visible_button(reset_code, "从二级菜单重置当前关卡代码")
	_check(not workbench._actions_menu.is_open(), "执行重置代码前关闭二级菜单")
	await process_frame
	_check(session.source == first.starter_program and workbench._code.text == first.starter_program, "真实按钮回调恢复当前关卡模板而非通关答案")
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null and workbench._code.editable, "恢复代码后回到可编辑的出生预览")
	_check(workbench._code.has_undo(), "恢复初始代码保留可撤销操作")
	workbench._code.undo()
	await process_frame
	_check(workbench._code.text == SOLUTION and session.source == SOLUTION, "一次原生撤销完整恢复玩家原代码并同步会话")
	_check(workbench._status.text != "代码已恢复为本关初始程序。", "撤销恢复玩家原稿后不继续提示当前内容是初始模板")
	workbench._code.redo()
	await process_frame
	_check(workbench._code.text == first.starter_program and session.source == first.starter_program, "一次原生重做完整恢复初始模板并同步会话")
	_check(session.assembly == assembly and JSON.stringify(assembly.modules) == original_modules, "重置及撤销重做保留同一个装配模型和模块名称位置")
	_check(game.drafts.is_completed(first.id) and FileAccess.get_file_as_bytes(progress_path) == completed_bytes, "代码重置不清除或重写已有通关进度")
	_check(not game._save_timer.is_stopped(), "重置及撤销重做通过既有草稿事件安排自动保存")
	# 等待真正的单次计时器到期，不通过手动保存掩盖漏接 draft_changed 的回归。
	await create_timer(1.0).timeout
	var saved := game.drafts.load_draft(first.id)
	_check(saved.is_ok() and saved.value != null and saved.value.source == first.starter_program, "自动保存计时器将初始程序写入本关草稿")
	_check(saved.is_ok() and saved.value != null and JSON.stringify(saved.value.modules) == original_modules, "自动保存初始程序时保留玩家原装配")

	for pause_before_reset in [false, true]:
		workbench._code.text = SOLUTION
		workbench._run_button.pressed.emit()
		for tick in range(3):
			session.step()
		if pause_before_reset:
			workbench._pause_button.pressed.emit()
		_check(session.state == (GameSession.State.PAUSED if pause_before_reset else GameSession.State.RUNNING), "构造运行中或暂停中的代码重置场景")
		var old_runner := session.runner
		var old_world := session.world
		var tick_before := old_world.tick_index
		workbench._accumulator = 0.075
		reset_code.pressed.emit()
		await process_frame
		_check(old_runner.state == ProgramRunner.State.CANCELLED and session.runner == null and session.world == null, "运行或暂停中重置会取消旧解释器并释放世界引用")
		_check(session.state == GameSession.State.EDITING and session.current_line == 0 and workbench._highlighted_line == -1 and is_zero_approx(workbench._accumulator), "运行重置清除时间余量与当前行高亮")
		_check(workbench._code.text == first.starter_program and session.source == first.starter_program and workbench._code.editable and workbench._assembly_panel.interaction_enabled, "运行重置立即显示模板并解除程序与装配编辑锁")
		old_runner.step()
		session.step()
		_check(old_world.tick_index == tick_before, "取消后旧解释器与会话都不能继续推进旧世界")

	workbench._code.text = "main() {\n    move(0, 1);\n}\n"
	workbench._run_button.pressed.emit()
	_check(session.state == GameSession.State.FAILED and workbench._highlighted_line == 1, "构造可定位错误的失败代码")
	reset_code.pressed.emit()
	await process_frame
	_check(session.state == GameSession.State.EDITING and session.current_line == 0 and workbench._highlighted_line == -1 and workbench._status.text == "代码已恢复为本关初始程序。", "失败后重置清除错误行和旧错误提示")
	# 原生 TextEdit 新建行返回透明黑，Color.TRANSPARENT 是透明白；无底色应按 alpha 判定。
	for line in range(workbench._code.get_line_count()):
		_check(is_zero_approx(workbench._code.get_line_background_color(line).a), "恢复后的代码没有遗留错误或执行底色")
	_check(JSON.stringify(assembly.modules) == original_modules and game.drafts.is_completed(first.id) and game.drafts.get_failure_streak(first.id) == 1, "错误尝试只增加提示计数，重置仍保留装配与已完成标志")
	_press_back(game)
	await process_frame
	game._enter_level(first)
	await process_frame
	_finish_dialogue(game)
	_check(game.session.source == first.starter_program and game.session.assembly.modules.is_empty(), "离开重进恢复重置后的初始代码，不恢复旧答案或自动装配")
	game.find_child("RestoreAssemblyButton", true, false).pressed.emit()
	_check(JSON.stringify(game.session.assembly.modules) == original_modules, "重新进入后仍可主动恢复重置前的原装配")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	_check(game.workbench._code.text == first.starter_program, "重新创建的工作台显示已保存的初始代码")
	_check(FileAccess.get_file_as_bytes(unrelated_path) == unrelated_bytes, "重置本关不改写其他关卡的草稿文件")
	for index in range(game.catalog.levels.size()):
		_check(JSON.stringify(game.catalog.levels[index].document.to_dict(), "", true) == original_maps[index], "代码重置不修改当前或其他关卡地图定义")


## 编辑器试玩从未保存快照恢复定制模板，且不读写同 ID 的正式草稿或编辑历史。
func _test_reset_code_playtest(game: GameShell) -> void:
	var editor := game._editor
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", editor.registry, true)
	_check(loaded.is_ok(), "代码重置试玩夹具可以载入第一关地图")
	if not loaded.is_ok():
		return
	var path := _test_directory.path_join("reset_code_map.json")
	editor.editor_document.replace_document(loaded.value, path)
	var model := editor.editor_document
	var starter := "// 我的试玩模板：保留中文注释和缩进\nmain() {\n\tmove(0, 2)\n}\n"
	model.begin_action()
	model.document.properties.level.starter_program = starter
	model.end_action()
	# 留一个可重做事务，验证试玩重置没有借用或清空地图编辑器自己的撤销栈。
	model.paint(Vector2i.ZERO, "floor")
	model.undo()
	var snapshot := JSON.stringify(model.document.to_dict(), "", true)
	var saved_state := model._saved_state
	var undo_count := model._undo_stack.size()
	var redo_count := model._redo_stack.size()
	var formal_path := game.drafts._path(model.document.id, "draft")
	var progress_path := game.drafts._path(model.document.id, "progress")
	var formal_bytes := FileAccess.get_file_as_bytes(formal_path)
	var progress_bytes := FileAccess.get_file_as_bytes(progress_path)
	_check(model.is_dirty() and redo_count > 0 and not formal_bytes.is_empty(), "试玩夹具有未保存自定义模板、重做历史和同 ID 正式存档")
	editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	_check(game.session.source == starter and game.session.assembly.modules.is_empty(), "编辑器试玩从快照模板和空装配开始，不载入正式代码")
	_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	var workbench := game.workbench
	workbench._code.text = SOLUTION
	workbench._run_button.pressed.emit()
	game.session.step()
	var old_runner := game.session.runner
	workbench._code.add_caret(1, 2)
	_check(workbench._code.get_caret_count() == 2, "试玩重置夹具包含两个编辑光标")
	workbench._reset_code_button.pressed.emit()
	await process_frame
	_check(old_runner.state == ProgramRunner.State.CANCELLED and game.session.state == GameSession.State.EDITING, "编辑器试玩的重置按钮也取消进行中的旧程序")
	_check(workbench._code.text == starter and game.session.source == starter and workbench._code.get_caret_count() == 1, "试玩恢复自定义初始程序原文，保留中文注释及制表符且不会按多光标重复插入")
	_check(game.session.assembly.modules.size() == 1 and not workbench.allow_draft_save, "试玩重置保留当前装配并继续隐藏正式保存入口")
	_check(game._save_timer.is_stopped(), "试玩重置不会启动正式草稿自动保存计时器")
	game._save_timer.timeout.emit()
	_check(FileAccess.get_file_as_bytes(formal_path) == formal_bytes and FileAccess.get_file_as_bytes(progress_path) == progress_bytes, "即使保存回调被触发，试玩重置也不改写同 ID 正式作品及进度")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.EDITOR and game._editor == editor and editor.editor_document == model and model.path == path, "代码重置试玩返回同一个编辑器文档和原路径")
	_check(model.is_dirty() and model._saved_state == saved_state and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count and JSON.stringify(model.document.to_dict(), "", true) == snapshot, "代码重置不修改地图内容、保存点或编辑器撤销重做历史")
	_check(FileAccess.get_file_as_bytes(formal_path) == formal_bytes and FileAccess.get_file_as_bytes(progress_path) == progress_bytes, "结束试玩仍完整保留同 ID 正式草稿与通关记录")

	# 空串也是地图作者明确指定的初始代码，不能被通用 main 模板或旧玩家答案替代。
	model.begin_action()
	model.document.properties.level.starter_program = ""
	model.end_action()
	var empty_snapshot := JSON.stringify(model.document.to_dict(), "", true)
	editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	_check(game.session.source.is_empty(), "空模板试玩入口保留作者指定的空程序")
	_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(Vector2.ZERO), MOUSE_BUTTON_LEFT)
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	workbench = game.workbench
	workbench._code.text = SOLUTION
	await process_frame
	workbench._reset_code_button.pressed.emit()
	await process_frame
	_check(workbench._code.text.is_empty() and game.session.source.is_empty(), "恢复空模板真正删除原有代码，不保留选区中的旧答案")
	workbench._code.undo()
	await process_frame
	_check(workbench._code.text == SOLUTION and game.session.source == SOLUTION, "空模板重置同样可以一次撤销恢复玩家代码")
	workbench._code.redo()
	await process_frame
	_check(workbench._code.text.is_empty() and game.session.source.is_empty(), "空模板重置可以一次重做并同步空源代码")
	_press_back(game)
	await process_frame
	_check(JSON.stringify(model.document.to_dict(), "", true) == empty_snapshot and model.document.properties.level.starter_program == "", "空模板恢复和撤销重做不改写编辑器关卡定义")
	_check(FileAccess.get_file_as_bytes(formal_path) == formal_bytes and FileAccess.get_file_as_bytes(progress_path) == progress_bytes, "空模板试玩也不覆盖同 ID 正式草稿及进度")


## 返回只操作当前页面可见的入口，避免向旧页头的隐藏按钮发射信号。
func _press_back(game: GameShell) -> void:
	var button: Button = game.find_child("LevelBackButton", true, false) if game.page == GameShell.Page.LEVELS else game._back_button
	_check(button != null and button.is_visible_in_tree() and not button.disabled, "当前页面的返回按钮可见且可操作")
	if button != null and button.is_visible_in_tree() and not button.disabled:
		button.pressed.emit()


## 第九关从真实选关与空装配进入，验证本土化、测距资料及动态导航的保存链路。
func _test_ninth_level(game: GameShell) -> void:
	var ninth: LevelDefinition = game.catalog.levels[8]
	_check(ninth.id == "level_009" and ninth.display_name == "第九关 · 蜿蜒穿行", "第九关使用指定的中文本土化名称")
	if not (await _open_tutorial_card(game, 8)):
		return
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty() and game._confirm_assembly_button.disabled, "第九关保留空装配与禁用确认")
	var palette: Button = game.assembly_panel.palette_buttons["rangefinder"]
	_check(not palette.disabled and palette.icon != null, "新测距模块带可用 SVG 图标进入实际目录")
	for index in range(ninth.document.dialogue.size()):
		var original := game._dialogue_dialog.dialog_text
		_check(original == ninth.document.dialogue[index].text, "第九关教程按 JSON 顺序显示")
		game.settings.set_language("en")
		await process_frame
		_check(game.tr(original) != original and game.tr(ninth.display_name) == "Level 9 · Winding Passage", "教程与关卡名字具有英文译文")
		game.settings.set_language("zh_CN")
		await process_frame
		game._dialogue_dialog.confirmed.emit()
	for entry: Dictionary in [
		{"module_id": "rangefinder", "id": "sensor", "position": Vector2.ZERO},
		{"module_id": "movement", "id": "drive", "position": Vector2(0, 0.5)},
	]:
		game.assembly_panel.palette_buttons[entry.module_id].pressed.emit()
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(entry.position), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = entry.id
		game.assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules.size() == 2 and not game._confirm_assembly_button.disabled, "真实画布允许测距居中、移动在下的双模块装配")
	for button: Button in game.assembly_panel.palette_buttons.values():
		_check(button.disabled, "第九关装满两个后禁止继续新增")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	var workbench := game.workbench
	workbench.set_process(false)
	_check(workbench._code.text == ninth.starter_program and not workbench._code.text.contains("distance"), "初始代码不预填完整测距答案")
	_check((workbench._code.syntax_highlighter as CodeHighlighter).keyword_colors.has("distance"), "测距查询使用正式语法高亮")
	_check(workbench._entry_hint.text.contains("distance"), "工作台显示测距专属引导")
	var menu := game._command_menu
	await _activate_visible_button(workbench.header.book_button, "从第九关打开测距指令资料")
	await _activate_visible_button(_command_section_button(menu, "rangefinder"), "选择新测距目录")
	_check(_command_result_ids(menu) == ["distance", "named_distance"] and _command_items_collapsed(menu), "测距目录默认折叠两项查询")
	for item in menu._cards:
		_check(bool(item.get_meta("available")) and item.get_tooltip().is_empty(), "第九关测距指令显示已解锁颜色且没有锁定提示")
	await _activate_visible_button(menu.header.search_button, "展开测距资料搜索")
	await _set_command_query(menu, "测距")
	_check(_command_result_ids(menu).has("distance") and _command_result_ids(menu).has("named_distance"), "中文描述搜索找到两种测距查询")
	await _activate_visible_button(workbench.header.book_button, "关闭测距资料")
	workbench._code.text = "main() {\n    loop {\n        move(0, distance(0) - 0.5)\n        move(90, distance(90) - 0.5)\n        move(180, distance(180) - 0.5)\n        move(90, distance(90) - 0.5)\n    }\n}\n"
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING, "界面运行按钮启动动态测距循环")
	for unused in 1400:
		if game.session.state != GameSession.State.RUNNING:
			break
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and game.drafts.is_completed(ninth.id), "测距通过五段通道并从实际会话保存第九关通关记录")
	_check(workbench._status.text.contains("关卡完成"), "测距通关沿用原有工作台结果反馈")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS, "第九关通关后可返回选关")


## 第十二关使用真实空装配与波次会话，检查 for 文案、资料解锁和状态药丸的同源数据。
func _test_twelfth_level(game: GameShell) -> void:
	var level: LevelDefinition = game.catalog.levels[11]
	_check(level.id == "level_012" and level.display_name == "第十二关 · 八方来敌" and level.allow_for, "第十二关按正式数据开放范围循环")
	if not (await _open_tutorial_card(game, 11)):
		return
	_check(game.session.assembly.modules.is_empty() and game._confirm_assembly_button.disabled, "八方来敌仍从空装配开始")
	_finish_dialogue(game)
	for module_id in game.assembly_panel.palette_buttons:
		var button: Button = game.assembly_panel.palette_buttons[module_id]
		_check(button.disabled == (module_id not in level.allowed_modules), "第十二关保留之前开放的模块：" + module_id)
	for entry: Dictionary in [
		{"module_id": "rangefinder", "id": "sensor", "position": Vector2.ZERO},
		{"module_id": "shooting", "id": "gun", "position": Vector2(0.5, 0)},
	]:
		game.assembly_panel.palette_buttons[entry.module_id].pressed.emit()
		_stroke(game.assembly_panel.canvas, game.assembly_panel.canvas.pixel_at(entry.position), MOUSE_BUTTON_LEFT)
		game.assembly_panel._module_name.text = entry.id
		game.assembly_panel._apply_button.pressed.emit()
	_check(game.session.assembly.modules.size() == 2 and not game._confirm_assembly_button.disabled, "测距与射击完成合法双模块装配")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	var workbench := game.workbench
	workbench.set_process(false)
	_check(workbench._entry_hint.text.contains("for") and workbench._goal_text().contains("八个方向"), "工作台说明与目标使用新的八方循环主题")
	_check(workbench._object_status.text.contains("0 / 8"), "未运行时指引显示八波待处理进度")
	for keyword in ["for", "in", "step"]:
		_check((workbench._code.syntax_highlighter as CodeHighlighter).keyword_colors.has(keyword), "新增范围语法有正式代码高亮：" + keyword)
	var menu := game._command_menu
	await _activate_visible_button(workbench.header.book_button, "打开第十二关范围遍历资料")
	await _activate_visible_button(_command_section_button(menu, "general", "general"), "显示新增的 for 资料")
	var card := menu.find_child("CommandCard_for_range", true, false) as CommandReferenceItem
	_check(card != null and bool(card.get_meta("available")) and card.get_tooltip().is_empty(), "for 资料在第十二关正式解锁")
	await _activate_visible_button(workbench.header.book_button, "关闭范围遍历资料")
	workbench._code.text = "main() {\n    loop {\n        for (angle in 0..315 step 45) {\n            shoot(angle)\n        }\n    }\n}\n"
	workbench._run_button.pressed.emit()
	_check(game.session.state == GameSession.State.RUNNING, "从工作台启动真实八方向范围循环")
	if game.session.world != null:
		for unused in range(3):
			game.session.step()
		var wave := game.session.world.get_enemy_wave_status()
		_check(int(wave.get("total", 0)) == 8 and int(wave.get("completed", -1)) == 0, "进度来自实际波次控制器")
		_check(workbench._object_status.text.contains("0 / 8") and workbench._live_status.is_expanded(), "真实运行把波次进度展开到同一个状态药丸")
		workbench._pause_button.pressed.emit()
		var paused_text := workbench._object_status.text
		var paused_tick := game.session.world.tick_index
		game.session.step()
		_check(game.session.world.tick_index == paused_tick and workbench._object_status.text == paused_text, "暂停冻结波次等待与冷却数字")
		game.settings.set_language("en")
		await process_frame
		_check(workbench._object_status.text.contains("Waves cleared:") and game.tr(level.display_name) != level.display_name, "波次状态与关卡名称即时切换英文")
		game.settings.set_language("zh_CN")
		await process_frame
		workbench._preview_button.pressed.emit()
		await create_timer(1.0).timeout
		_check(workbench._full_preview_requested and workbench._live_status.is_expanded(), "全尺寸继续使用同一个波次药丸")
		workbench.header.reset_button.pressed.emit()
		_check(game.session.world == null and workbench._object_status.text.contains("0 / 8") and not workbench._live_status.is_expanded(), "重置后药丸收回，进度恢复为未开始")
	_press_back(game)
	await process_frame
	_check(game.page == GameShell.Page.LEVELS, "第十二关可返回正式关卡目录")


## 正式第十三关从空装配进入，检查雷达说明、翻译与终局残骸显示开关。
func _test_thirteenth_level(game: GameShell) -> void:
	var level: LevelDefinition = game.catalog.levels[12]
	if not (await _open_tutorial_card(game, 12)):
		return
	_check(game.session.assembly.modules.is_empty() and level.id == "level_013", "十面埋伏从空装配开始")
	_finish_dialogue(game)
	_check(game.session.assembly.add_module("radar", Vector2.ZERO, "eyes").is_ok(), "第十三关可安装雷达")
	_check(game.session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "第十三关可安装射击")
	game._confirm_assembly()
	await process_frame
	var bench := game.workbench
	bench.set_process(false)
	_check(bench._entry_hint.text.contains("scan()") and bench._goal_text().contains("10 波") and bench._object_status.text.contains("0 / 10"), "目标、入口说明和状态均使用雷达十波主题")
	game.settings.set_code_hints("more")
	game.settings.set_code_color_mode("dark")
	await process_frame
	_check(bench._hint_button.visible and bench._code.get_theme_stylebox("normal").bg_color == Color("121314"), "沿用教学提示与深色代码区")
	game.settings.set_language("en")
	await process_frame
	_check(game.tr(level.display_name) == "Level 13 · Ambush from All Sides" and game.tr(bench._entry_hint.text).contains("scan()"), "第十三关名称和雷达说明有英文")
	for page: Dictionary in level.document.dialogue:
		_check(game.tr(page.text) != page.text, "每页新教程都有英文翻译")
	game.settings.set_language("zh_CN")
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_013.json"))
	bench._code.text = str(hint.source).replace("{{radar}}", "eyes").replace("{{gun}}", "gun")
	bench._run_button.pressed.emit()
	_check(bench._playfield.wreck_animation_enabled, "运行启用残骸显示时钟")
	game.session.pause()
	_check(not bench._playfield.wreck_animation_enabled, "暂停关闭残骸时钟")
	game.session.resume()
	for unused in level.max_ticks:
		if game.session.state != GameSession.State.RUNNING:
			break
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED and bench._object_status.text.contains("10 / 10"), "真实界面会话完成十波并更新计数")
	_check(bench._playfield.wreck_animation_enabled and not bench._playfield.attack_animation_enabled, "通关停止攻击动画但继续淡出最后一波")
	bench._playfield._process(3.1)
	_check(bench._playfield.enemy_wreck_opacity(game.session.world.get_machine("wave_10")) == 0.0, "最后一波通关后也会消失")
	game.settings.set_code_color_mode("light")
	game.settings.set_code_hints("normal")
	_press_back(game)
	await process_frame


## 第十四关沿真实目录入口进入，核对三模块、双语教程、药丸和重置流程。
func _test_fourteenth_level(game: GameShell) -> void:
	var level: LevelDefinition = game.catalog.levels[13]
	if not (await _open_tutorial_card(game, 13)):
		return
	_check(game.session.assembly.modules.is_empty() and level.id == "level_014", "第十四关从空装配进入")
	_finish_dialogue(game)
	_check(game.session.assembly.add_module("radar", Vector2.ZERO, "eyes").is_ok(), "十四关雷达可安装")
	_check(game.session.assembly.add_module("shooting", Vector2(.5, 0), "gun").is_ok(), "十四关射击可安装")
	_check(game.session.assembly.add_module("movement", Vector2(-.5, 0), "drive").is_ok(), "十四关第三个移动模块可安装")
	game._confirm_assembly()
	await process_frame
	var bench := game.workbench
	bench.set_process(false)
	_check(bench._goal_text().contains("栅栏") and bench._entry_hint.text.contains("移动") and bench._object_status.text.contains("0 / 10"), "编程界面使用推进射击的目标与说明")
	game.settings.set_code_hints("more")
	game.settings.set_code_color_mode("dark")
	await process_frame
	_check(bench._hint_button.visible and bench._code.get_theme_stylebox("normal").bg_color == Color("121314"), "十四关保留教学提示和代码区深色模式")
	game.settings.set_language("en")
	await process_frame
	_check(game.tr(level.display_name) == "Level 14 · Corridor Sweep" and game.tr(bench._goal_text()).contains("bars"), "关卡名称与目标有英文")
	for page: Dictionary in level.document.dialogue:
		_check(game.tr(page.text) != page.text, "十四关每页教程都有英文")
	_check(game.tr("铁栅栏") == "Iron Bars" and game.tr("墙壁") == "Wall", "新增地块名称可本土化")
	game.settings.set_language("zh_CN")
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_014.json"))
	bench._code.text = str(hint.source).replace("{{radar}}", "eyes").replace("{{gun}}", "gun").replace("{{drive}}", "drive")
	bench._run_button.pressed.emit()
	for unused in 42:
		game.session.step()
	_check(game.session.world.get_enemy_wave_status().spawned == 1 and not bench._object_status.text.contains("下一波将在"), "推进触发首波且药丸不显示下一波倒计时")
	game.session.pause()
	await _capture("level14_corridor")
	bench.header.reset_button.pressed.emit()
	_check(game.session.world == null and bench._object_status.text.contains("0 / 10"), "重置清空进度并保留编辑界面")
	game.settings.set_code_color_mode("light")
	game.settings.set_code_hints("normal")
	_press_back(game)
	await process_frame
