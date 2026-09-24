extends SceneTree
## 编辑器真实场景回归：控件修改、文件往返及独立组装编程试玩，存储全部隔离。

var _failures: int = 0
var _checks: int = 0
var _test_directory: String


## 等待场景树可安全添加 UI 后启动测试。
func _initialize() -> void:
	_run.call_deferred()


## 从独立编辑器场景启动外壳，验证编辑与试玩往返不污染地图或正式作品。
func _run() -> void:
	_test_directory = "user://tests/editor_smoke_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(_test_directory.path_join("maps"))
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/map_editor.tscn").instantiate()
	game.user_levels_directory = _test_directory.path_join("levels")
	game.drafts_directory = _test_directory.path_join("solutions")
	game.settings_path = _test_directory.path_join("settings.json")
	game.folder_opener = _reject_folder_open
	game.quit_handler = _reject_quit
	root.add_child(game)
	await process_frame
	await process_frame
	var editor := game._editor
	_check(game.page == GameShell.Page.EDITOR and editor != null, "独立编辑器场景通过外壳直接打开地图编辑页面")
	if editor == null:
		game.queue_free()
		await process_frame
		_finish()
		return
	_check(not editor._message_dialog.visible and not game._message_dialog.visible, "启动没有错误对话框")
	_check(editor.editor_document.document.id == "movement_lab", "默认示例地图已载入")
	_check(_find_button(editor, "执行 move") == null and _find_button(editor, "停止测试") == null and _find_button(editor, "重置测试") == null, "地图编辑页面移除直接执行 move 和旧测试控制")
	_check(not editor.has_method("_submit_move") and not editor.has_method("_reset_playtest"), "地图编辑器不再暴露旧的手动移动测试入口")
	var canvas := editor._canvas
	_stroke(canvas, Vector2(16, 16), MOUSE_BUTTON_LEFT)
	_check(editor.editor_document.document.get_tile_id(Vector2i.ZERO) == "floor", "鼠标笔画信号放置地板")
	_check(editor.editor_document.is_dirty(), "编辑产生未保存标记")
	editor._undo_button.pressed.emit()
	_check(editor.editor_document.document.get_tile_id(Vector2i.ZERO).is_empty(), "撤销恢复 void")
	editor._redo_button.pressed.emit()
	_check(editor.editor_document.document.get_tile_id(Vector2i.ZERO) == "floor", "重做恢复地板")
	_stroke(canvas, Vector2(16, 16), MOUSE_BUTTON_RIGHT)
	_check(editor.editor_document.document.get_tile_id(Vector2i.ZERO).is_empty(), "右键擦除为 void")
	_test_module_limit(editor)
	# 元数据仍保存扩展字段；设置短距离目标便于通过真实程序验证试玩通关隔离。
	_find_button(editor, "元数据 JSON").pressed.emit()
	var metadata := editor.editor_document.metadata_dict()
	metadata.dialogue.append({"speaker": "测试", "text": "保存后仍应存在。"})
	metadata.extra["smoke_extension"] = {"revision": 2, "flags": [true, "中文"]}
	metadata.properties.level["goal"] = {"position": {"x": 2.5, "y": 1.5}, "radius": 0.2}
	metadata.properties.level["starter_program"] = "main() {\n    // 编辑地图提供的试玩模板\n    move(0, 1)\n}\n"
	editor._metadata_text.text = JSON.stringify(metadata)
	editor._metadata_dialog.confirmed.emit()
	_check(not editor._metadata_dialog.visible, "有效元数据应用后关闭对话框")
	_check(editor.editor_document.document.extra.has("smoke_extension"), "元数据扩展字段已写入模型")
	var target := _test_directory.path_join("maps/editor.json")
	_find_button(editor, "另存为").pressed.emit()
	editor._file_dialog.file_selected.emit(target)
	editor._file_dialog.hide()
	_check(FileAccess.file_exists(target) and not editor.editor_document.is_dirty(), "保存成功后清除未保存标记")
	_find_button(editor, "新建").pressed.emit()
	_check(editor.editor_document.document.cells.is_empty(), "新建文档默认全是 void")
	_find_button(editor, "打开").pressed.emit()
	editor._file_dialog.file_selected.emit(target)
	editor._file_dialog.hide()
	_check(editor.editor_document.document.extra.has("smoke_extension"), "打开文件保留扩展字段")
	_check(int(editor._module_limit_field.value) == 3 and int(editor.editor_document.document.properties.level.module_limit) == 3, "模块上限保存后重新打开仍与控件一致")
	_test_pending_module_limit(editor)
	await _test_playtest_round_trip(game, editor)
	# 无出生点必须留在地图编辑页，提示作者修复，不能创建半初始化试玩会话。
	_find_button(editor, "重置起点").pressed.emit()
	editor._play_button.pressed.emit()
	_check(game.page == GameShell.Page.EDITOR and game.session == null and game._editor == editor, "缺少出生点时开始测试被拒绝且保留同一地图编辑器")
	_check(editor._message_dialog.visible and editor._message_dialog.dialog_text.contains("出生"), "缺少出生点时显示中文诊断")
	editor._message_dialog.hide()
	editor._undo_button.pressed.emit()
	_check(editor.editor_document.document.player_spawn != null, "撤销移除出生点仍能修复原地图")
	# 丢弃确认与读取失败保护仍属于原编辑器，不因切换过试玩而失去作用。
	_find_button(editor, "新建").pressed.emit()
	_check(editor._dirty_dialog.visible and not editor.editor_document.document.cells.is_empty(), "新建前仍保护未保存文档")
	editor._dirty_dialog.hide()
	editor._load_document(_test_directory.path_join("missing.json"))
	_check(editor.editor_document.document.extra.has("smoke_extension"), "读取失败保留当前文档")
	editor._message_dialog.hide()
	await _capture("editor")
	game.settings.set_language("en")
	await _capture("editor_english")
	game.settings.set_language("zh_CN")
	game.queue_free()
	await process_frame
	_finish()


## 数量输入直接写地图规则，范围、撤销和重做均通过实际控件验证。
func _test_module_limit(editor: MapEditor) -> void:
	var field := editor._module_limit_field
	var initial := int(field.value)
	_check(field.min_value == 1 and field.max_value == 256 and field.step == 1, "模块上限输入限制为 1..256 的整数")
	field.value = 3
	_check(int(editor.editor_document.document.properties.level.module_limit) == 3 and editor.editor_document.is_dirty(), "修改模块数量上限立即写入地图并标记未保存")
	editor._undo_button.pressed.emit()
	_check(int(field.value) == initial, "撤销恢复原有模块上限并同步输入框")
	editor._redo_button.pressed.emit()
	_check(int(field.value) == 3 and int(editor.editor_document.document.properties.level.module_limit) == 3, "重做恢复模块上限及地图规则")


## 尚未失焦的数值文本应先提交再保存；模型回填的旧显示文本不能反向覆盖撤销。
func _test_pending_module_limit(editor: MapEditor) -> void:
	var line := editor._module_limit_field.get_line_edit()
	line.grab_focus()
	line.text = "4"
	_check(line.has_focus() and int(editor._module_limit_field.value) == 3, "准备有焦点但尚未提交的模块上限文本")
	_find_button(editor, "保存").pressed.emit()
	var saved := MapCodec.load_file(editor.editor_document.path, editor.registry, false)
	_check(saved.is_ok() and int(saved.value.properties.level.module_limit) == 4 and int(editor._module_limit_field.value) == 4, "保存会提交尚未失焦的上限输入并写入地图")
	line.release_focus()
	editor._undo_button.pressed.emit()
	_find_button(editor, "保存").pressed.emit()
	var restored := MapCodec.load_file(editor.editor_document.path, editor.registry, false)
	_check(restored.is_ok() and int(restored.value.properties.level.module_limit) == 3 and int(editor._module_limit_field.value) == 3, "同帧撤销后保存不会被 SpinBox 旧显示文本回填，并恢复三个模块夹具")


## 试玩走空组装、编程、通关与返回，同时保护地图历史、视图及同 ID 正式存档。
func _test_playtest_round_trip(game: GameShell, editor: MapEditor) -> void:
	var editor_model := editor.editor_document
	var map_id := editor_model.document.id
	var formal_modules: Array = [{"id": "formal_drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]
	var formal_source := "main() {\n    // 正式关卡旧草稿，试玩不可读取或覆盖\n}\n"
	_check(game.drafts.save_draft(map_id, formal_source, formal_modules).is_ok(), "准备同 ID 正式关卡草稿作为隔离夹具")
	_check(not game.drafts.is_completed(map_id), "隔离夹具中正式关卡尚未完成")
	var saved_files := _draft_snapshot(game.drafts.directory)
	# 扩大视图并留下可撤销和可重做两侧历史，避免仅验证一个空历史编辑器。
	editor._width_field.value = 40
	editor._height_field.value = 30
	_find_button(editor, "应用尺寸").pressed.emit()
	_stroke(editor._canvas, Vector2(16, 16), MOUSE_BUTTON_LEFT)
	_stroke(editor._canvas, Vector2(16, 48), MOUSE_BUTTON_LEFT)
	editor._undo_button.pressed.emit()
	await process_frame
	await process_frame
	var map_view := editor._map_view
	map_view.set_zoom(1.25)
	map_view.view_center = Vector2(18, 13)
	map_view.refresh_map()
	await process_frame
	var zoom_before := map_view.zoom
	var center_before := map_view.view_center
	_check(is_equal_approx(zoom_before, 1.25) and center_before.is_equal_approx(Vector2(18, 13)), "试玩夹具保留手动缩放及平移后的地图视点")
	var before_play := JSON.stringify(editor_model.document.to_dict(), "", true)
	var saved_path := editor_model.path
	var undo_count := editor_model._undo_stack.size()
	var redo_count := editor_model._redo_stack.size()
	_check(editor_model.is_dirty() and undo_count > 0 and redo_count > 0, "试玩夹具同时具有未保存修改及双向编辑历史")
	var starter: String = editor_model.document.properties.level.starter_program
	editor._play_button.pressed.emit()
	await process_frame
	await process_frame
	_check(game.page == GameShell.Page.ASSEMBLY and game.session != null, "开始测试进入正常独立组装页")
	if game.session == null:
		return
	_finish_dialogue(game)
	_check(game.session.assembly.modules.is_empty() and game.session.source == starter, "试玩初始装配为空且使用地图模板，不读取同 ID 正式草稿")
	_check(game.session.assembly.content == editor.registry, "试玩使用当前地图编辑器的内容注册表")
	_check(game.session.level.document != editor_model.document and JSON.stringify(game.session.level.document.to_dict(), "", true) == before_play, "试玩使用最新编辑地图的独立快照")
	_check(game._back_button.is_visible_in_tree() and game._back_button.icon != null and TranslationServer.translate(game._back_button.get_tooltip()) == game.tr("返回地图编辑器"), "组装页药丸返回入口明确指向地图编辑器")
	var header := game.assembly_panel.header
	_check(game.assembly_panel.preparation_mode and header != null and header.is_visible_in_tree(), "试玩使用同一准备工具栏")
	_check(not header.save_button.is_visible_in_tree() and not header.restore_button.is_visible_in_tree(), "临时试玩组装页不展示正式草稿保存或载入按钮")
	_check(header.help_button.is_visible_in_tree() and header.book_button.is_visible_in_tree(), "试玩仍保留说明与指令阅读入口")
	header.book_button.pressed.emit()
	await process_frame
	_check(game._command_menu.is_open() and not game._command_menu._cards.is_empty(), "试玩可以读取当前模块的 JSON 指令说明")
	var foundations := game._command_menu.find_child("CommandSection_general", true, false) as Button
	_check(foundations != null and not foundations.disabled, "试玩也可进入编程基础资料")
	if foundations != null:
		foundations.pressed.emit()
		await process_frame
		var first_item := game._command_menu._cards[0] as CommandReferenceItem
		_check(game._command_menu._selected_section_key == "general:general" and not first_item.expanded and first_item.preview.is_visible_in_tree(), "试玩切换目录后默认只显示折叠指令")
		first_item.header_button.button_pressed = true
		await create_timer(0.35).timeout
		_check(first_item.expanded and first_item.details.is_visible_in_tree(), "试玩同样可以点击指令展开完整功能说明")
	game._command_menu.header.back_button.pressed.emit()
	_check(game.session.source == starter and game.session.assembly.modules.is_empty() and game.session.world == null and _draft_snapshot(game.drafts.directory) == saved_files, "试玩阅读资料不执行程序、不安装模块且不修改正式草稿")
	await _capture("editor_playtest_assembly")
	var assembly_canvas := game.assembly_panel.canvas
	for offset: Vector2 in [Vector2.ZERO, Vector2(0.5, 0), Vector2(1, 0), Vector2(1.5, 0)]:
		_stroke(assembly_canvas, assembly_canvas.pixel_at(offset), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 3 and game.assembly_panel.palette_buttons["movement"].disabled, "试玩按编辑器保存的上限允许三个模块并拒绝第四个")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.PLAY and game.workbench != null, "确认试玩装配后进入正常编程工作台")
	if game.workbench == null:
		return
	game.workbench.set_process(false)
	game.workbench.header.more_button.pressed.emit()
	await process_frame
	var trial_save := game.workbench.find_child("SaveProgramDraftMenuItem", true, false) as Button
	_check(game.workbench._actions_menu.is_open() and trial_save != null and not trial_save.is_visible_in_tree(), "临时试玩编程菜单不展示持久化保存入口")
	game.workbench._actions_menu.close_menu()
	game.workbench.header.book_button.pressed.emit()
	await process_frame
	_check(game._command_menu.is_open() and game.page == GameShell.Page.PLAY, "试玩编程页也能打开同一指令资料窗")
	if not game._command_menu._command_buttons.is_empty():
		game._command_menu._command_buttons[0].button_pressed = true
		await create_timer(0.35).timeout
	game._command_menu.header.back_button.pressed.emit()
	_check(game.session.source == starter and game.session.assembly.modules.size() == 3 and game.session.world == null and _draft_snapshot(game.drafts.directory) == saved_files, "试玩编程页阅读资料保留临时代码和装配且不写正式存档")
	await _capture("editor_playtest_program")
	var trial_session := game.session
	var trial_source := "main() {\n    // 实际输入的试玩程序\n    move(0, 1)\n}\n"
	game.workbench._code.text = trial_source
	game.workbench._code.text_changed.emit()
	game.workbench._run_button.pressed.emit()
	trial_session.step()
	_check(trial_session.state == GameSession.State.RUNNING and trial_session.world.tick_index == 1, "试玩程序通过运行按钮与固定 tick 实际执行")
	var first_command := trial_session.runner._command
	game.workbench.header.more_button.pressed.emit()
	await process_frame
	game.workbench.find_child("EditModulesButton", true, false).pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.ASSEMBLY and game.session == trial_session and trial_session.source == trial_source and trial_session.assembly.modules.size() == 3, "试玩编辑模块仍复用同一会话、代码和装配")
	_check(first_command.state == MovementCommand.State.CANCELLED and trial_session.world == null, "试玩返回组装取消当前程序动作")
	game._confirm_assembly_button.pressed.emit()
	await process_frame
	game.workbench.set_process(false)
	game.workbench._run_button.pressed.emit()
	for tick in range(20):
		trial_session.step()
	_check(trial_session.state == GameSession.State.SUCCEEDED, "试玩中的实际程序可以完成当前地图目标")
	game._save_current_draft(true)
	game._save_timer.timeout.emit()
	_check(_draft_snapshot(game.drafts.directory) == saved_files and not game.drafts.is_completed(map_id), "试玩通关、强制保存及计时保存均不写正式草稿或通关记录")
	# 在尚未结束的第二次运行中离开，确保保留下来的旧句柄也已取消。
	game.workbench._code.text = "main() {\n    move(0, 100)\n}\n"
	game.workbench._code.text_changed.emit()
	game.workbench._run_button.pressed.emit()
	trial_session.step()
	var old_world := trial_session.world
	var old_runner := trial_session.runner
	var old_command := old_runner._command
	game._back_button.pressed.emit()
	await process_frame
	await process_frame
	_check(game.page == GameShell.Page.EDITOR and game._editor == editor and editor.editor_document == editor_model, "返回恢复同一个地图编辑器与文档模型")
	_check(game.session == null and game.workbench == null and trial_session.world == null and trial_session.runner == null, "离开试玩释放会话运行对象")
	_check(old_command.state == MovementCommand.State.CANCELLED and old_runner.state == ProgramRunner.State.CANCELLED, "离开试玩取消运行中的命令与解释器")
	var stopped_position := old_world.player.position
	old_runner.step()
	old_world.step()
	_check(old_world.player.position == stopped_position, "已离开的试玩不能通过残留句柄继续移动")
	_check(JSON.stringify(editor_model.document.to_dict(), "", true) == before_play and editor_model.path == saved_path and editor_model.is_dirty(), "试玩返回保持地图内容、保存路径及未保存标记")
	_check(editor_model._undo_stack.size() == undo_count and editor_model._redo_stack.size() == redo_count, "试玩返回保留全部撤销与重做历史")
	_check(editor._map_view == map_view and is_equal_approx(map_view.zoom, zoom_before) and map_view.view_center.is_equal_approx(center_before), "试玩返回保留同一地图视口及原缩放和平移位置")
	await _capture("editor_return")
	editor._redo_button.pressed.emit()
	_check(editor_model.document.get_tile_id(Vector2i(0, 1)) == "floor", "试玩返回后原有重做操作仍然有效")
	editor._undo_button.pressed.emit()
	_check(JSON.stringify(editor_model.document.to_dict(), "", true) == before_play, "试玩返回后原有撤销操作仍然有效")
	# 第二轮采用刚修改的地图与数量规则，但不带入上一轮临时程序或模块。
	editor._module_limit_field.value = 2
	_stroke(editor._canvas, Vector2(16, 80), MOUSE_BUTTON_LEFT)
	editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session != trial_session and game.session.assembly.modules.is_empty(), "再次开始测试创建全新会话并清空临时装配")
	_check(game.session.source == starter and game.session.level.module_limit == 2 and game.session.level.document.get_tile_id(Vector2i(0, 2)) == "floor", "再次试玩采用最新地图与上限，源程序重新取地图模板")
	assembly_canvas = game.assembly_panel.canvas
	for offset: Vector2 in [Vector2.ZERO, Vector2(0.5, 0), Vector2(1, 0)]:
		_stroke(assembly_canvas, assembly_canvas.pixel_at(offset), MOUSE_BUTTON_LEFT)
	_check(game.session.assembly.modules.size() == 2, "再次试玩立即执行修改后的两个模块上限")
	game._back_button.pressed.emit()
	await process_frame
	_check(game.page == GameShell.Page.EDITOR and game._editor == editor and editor_model.document.get_tile_id(Vector2i(0, 2)) == "floor", "直接从试玩组装页也能返回当前编辑地图")
	# 系统关闭请求必须先返回有未保存地图的编辑器；取消原确认框后继续保留文档。
	editor._play_button.pressed.emit()
	await process_frame
	_finish_dialogue(game)
	game.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await process_frame
	_check(game.page == GameShell.Page.EDITOR and game._editor == editor and editor._dirty_dialog.visible, "试玩收到关闭窗口请求会返回编辑器并保护未保存地图")
	editor._dirty_dialog.get_cancel_button().pressed.emit()
	editor._dirty_dialog.hide()
	_check(game._editor == editor and editor_model.is_dirty() and editor_model.document.get_tile_id(Vector2i(0, 2)) == "floor", "取消关闭请求后未保存地图与编辑器仍然保留")
	_check(_draft_snapshot(game.drafts.directory) == saved_files, "多轮试玩及返回后同 ID 正式存档原文完全不变")


## 读取隔离草稿目录的原始文件，比较试玩前后是否发生任何持久化副作用。
func _draft_snapshot(directory_path: String) -> Dictionary:
	var snapshot: Dictionary = {}
	var directory := DirAccess.open(directory_path)
	if directory != null:
		for filename in directory.get_files():
			snapshot[filename] = FileAccess.get_file_as_string(directory_path.path_join(filename))
	return snapshot


## 消费关卡对话，测试与玩家一样通过确认信号推进到操作页面。
func _finish_dialogue(game: GameShell) -> void:
	for index in range(game.session.level.document.dialogue.size() + 1):
		if game._dialogue_dialog.visible:
			game._dialogue_dialog.confirmed.emit()


## 按实际文字或编辑器工具栏句柄定位控件，图标入口仍通过原生按钮信号执行。
func _find_button(parent: Node, title: String) -> Button:
	if parent is MapEditor:
		var editor := parent as MapEditor
		match title:
			"新建":
				return editor._header.new_button
			"保存":
				return editor._header.save_button
			"打开":
				return editor._file_label
	for child in parent.find_children("*", "Button", true, false):
		if child.text == title:
			return child
	return null


## 地图和组装画布都通过真实 gui_input 信号接收一段完整点击笔画。
func _stroke(canvas: Control, position: Vector2, button: MouseButton) -> void:
	# 地图夹具使用一倍32像素的格坐标；自动适配后换算到当前画布局部像素。
	if canvas is MapCanvas:
		position *= (canvas as MapCanvas).cell_size / 32.0
	var event := InputEventMouseButton.new()
	event.position = position
	event.button_index = button
	event.pressed = true
	canvas.gui_input.emit(event)
	event = event.duplicate()
	event.pressed = false
	canvas.gui_input.emit(event)


## 仅在图形运行时保存实际视口，供检查组装、编程及返回编辑器后的布局。
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


## 编辑器测试不需要系统目录交互；若意外调用便失败，而不打开真实资源管理器。
func _reject_folder_open(_path: String) -> int:
	_check(false, "编辑器试玩不应请求打开系统目录")
	return ERR_UNAVAILABLE


## 退出请求用测试替身拦截，避免中断检查汇总。
func _reject_quit() -> void:
	_check(false, "编辑器试玩不应请求退出游戏")


## 仅递归清理当前测试创建的独占用户目录，不触及玩家正式存档。
func _cleanup(path: String) -> void:
	if _test_directory.is_empty() or not (path == _test_directory or path.begins_with(_test_directory + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 清理测试夹具并统一退出，失败保持非零返回码供包装脚本检测。
func _finish() -> void:
	_cleanup(_test_directory)
	print("编辑器冒烟完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 累计错误并继续检查，最后统一报告可读的失败原因。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
