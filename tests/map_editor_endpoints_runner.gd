extends SceneTree
## 起终点通过真实编辑器输入、保存往返和试玩验证，所有文件使用独立测试目录。
var _checks := 0
var _failures := 0
var _game: GameShell
var _editor: MapEditor
var _temporary := ""


## 等待场景树可构造界面，并限制动画检查的帧率。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 从实际编辑器入口覆盖两种语言、点位工具、历史、校验和真实通关。
func _run() -> void:
	_temporary = "user://tests/endpoints_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_editor = _game._editor
	await _test_layout()
	await _test_placement()
	await _test_optional_finish()
	_test_model_boundaries()
	await _test_dimensions()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图起终点回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 场景控制与其他表单并排适配，中英文最小窗口中控件不互相覆盖。
func _test_layout() -> void:
	_check(not _editor._brush_ids.has("@player_spawn"), "出生点已移出地形下拉菜单")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
			var context := locale + str(dimensions)
			for button in [_editor._spawn_button, _editor._goal_button, _editor._reset_spawn_button, _editor._reset_goal_button]:
				_check(scroll.get_global_rect().encloses(button.get_global_rect()), "场景按钮在可见属性区域内 " + str(button.name) + context)
			_check(_editor._goal_button.get_global_rect().end.x < _editor._reset_goal_button.global_position.x, "点位工具与重置按钮不重叠 " + context)
			for button in [_editor._reset_spawn_button, _editor._reset_goal_button]:
				for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
					_check(button.get_theme_color(state) == Color("dd1d1d"), "重置按钮在所有交互状态保持指定红色 " + context)
			_check(_editor._spawn_button.icon != null and _editor._goal_button.icon != null, "独立点位工具有SVG图标")
			if locale == "en":
				_check(_editor._spawn_button.tr(_editor._spawn_button.tooltip_text).begins_with("Place Start") and _editor._reset_goal_button.tr(_editor._reset_goal_button.text) == "Reset Finish", "起终点名称正确英文本土化")
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()


## 真正鼠标单击设置格心，拖动不移动终点；保存后的同一终点通过真实移动程序完成。
func _test_placement() -> void:
	var document := MapDocument.new()
	document.width = 8
	document.height = 6
	document.properties = {"level": {"module_limit": 1}, "preserved": {"value": 42}}
	for y in 6:
		for x in 8:
			document.set_tile(Vector2i(x, y), "floor")
	_editor.editor_document.replace_document(document)
	_editor._map_view.reset_view()
	await _settle()
	var model := _editor.editor_document
	_editor._spawn_button.pressed.emit()
	_click(_cell_point(Vector2i(1, 2)))
	_check(model.document.player_spawn.position == {"x": 1.5, "y": 2.5}, "起点按钮通过真实地图点击设置出生格心")
	_editor._goal_button.pressed.emit()
	var count := model._undo_stack.size()
	_mouse(_cell_point(Vector2i(5, 2)), MOUSE_BUTTON_LEFT, true)
	var motion := InputEventMouseMotion.new()
	motion.position = _cell_point(Vector2i(6, 3))
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion)
	_mouse(motion.position, MOUSE_BUTTON_LEFT, false)
	_check(MapEditorDocument.position_goal(model.document).position == {"x": 5.5, "y": 2.5}, "终点单击放置，不被按住拖动误移动")
	_check(model._undo_stack.size() == count + 1 and model._action_depth == 0, "一次点位只产生一个已完成的历史事务")
	_check(model.document.properties.preserved.value == 42 and model.document.cells.size() == 48, "设置终点保留地形和其他元数据")
	model.paint(Vector2i.ZERO, "")
	count = model._undo_stack.size()
	_click(_cell_point(Vector2i.ZERO))
	_check(model._undo_stack.size() == count and MapEditorDocument.position_goal(model.document).position.x == 5.5, "void禁止设置终点且不产生历史")
	_click(_cell_point(Vector2i(2, 2)), MOUSE_BUTTON_RIGHT)
	_check(_editor._point_tool.is_empty() and model.document.get_tile_id(Vector2i(2, 2)) == "floor", "点位模式右键只取消工具，不擦除地形")
	_editor._reset_goal_button.pressed.emit()
	_check(MapEditorDocument.position_goal(model.document).is_empty() and model.document.player_spawn != null, "重置终点保留起点")
	_check(model.undo() and not MapEditorDocument.position_goal(model.document).is_empty(), "撤销恢复完整终点")
	_check(model.redo() and MapEditorDocument.position_goal(model.document).is_empty(), "重做再次清除终点")
	model.undo()
	_editor._reset_spawn_button.pressed.emit()
	_check(model.document.player_spawn == null and not MapEditorDocument.position_goal(model.document).is_empty(), "重置起点保留终点")
	model.undo()
	var filename := _temporary.path_join("map.json")
	DirAccess.make_dir_recursive_absolute(_temporary)
	_editor._write_document(filename)
	_check(not model.is_dirty() and FileAccess.file_exists(filename), "保存含起终点的地图成功")
	_editor._load_document(filename)
	_check(MapEditorDocument.position_goal(model.document).position == {"x": 5.5, "y": 2.5} and model.document.player_spawn.position == {"x": 1.5, "y": 2.5}, "重新打开后保留两个点位")
	_editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null, "含终点的地图进入正常试玩装配")
	if _game.session == null:
		return
	_game._dialogue_dialog.hide()
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "试玩仍从空装配安装真实移动模块")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	_game.workbench._code.text = "main() {\n    move(0, 4)\n}"
	_game.workbench.header.run_button.pressed.emit()
	for unused in 100:
		if _game.session.state != GameSession.State.RUNNING:
			break
		_game.session.step()
	_check(_game.session.state == GameSession.State.SUCCEEDED, "真实移动抵达编辑的终点触发通关")
	_game._return_to_editor()
	await _settle()
	_check(_game._editor == _editor and not model.is_dirty(), "试玩结束保留原编辑器地图和保存状态")


## 终点始终可选，重置后仍能保存重开并在正常试玩中完成自由移动。
func _test_optional_finish() -> void:
	_editor._reset_goal_button.pressed.emit()
	var filename := _temporary.path_join("sandbox.json")
	_editor._write_document(filename)
	_editor._load_document(filename)
	var model := _editor.editor_document
	_check(not model.is_dirty() and not model.document.properties.level.has("goal"), "不设置终点也能保存重开且不会生成默认目标")
	_editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and not _game.session.level.has_goal, "没有终点仍可进入空装配试玩")
	if _game.session == null:
		return
	_game._dialogue_dialog.hide()
	_game.session.assembly.add_module("movement", Vector2.ZERO, "drive")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	_game.workbench._code.text = "main() {\n    move(0, 4)\n}"
	_game.workbench.header.run_button.pressed.emit()
	for unused in 100:
		if _game.session.state != GameSession.State.RUNNING:
			break
		_game.session.step()
	_check(_game.session.state == GameSession.State.RUNNING and _game.session.world.tick_index >= 100, "没有终点仍可测试，程序结束后继续倒计时而非立即判未到终点失败")
	_game._return_to_editor()
	await _settle()


## 元数据扩展、复杂出口规则、非法字段及裁剪统一遵循文档事务。
func _test_model_boundaries() -> void:
	var model := MapEditorDocument.new()
	var document := MapDocument.new()
	document.properties = {"level": {"module_limit": 3, "goal": {"type": "escape_prison", "position": {"x": 8.5, "y": 8.5, "extra": "keep"}, "radius": 0.2, "enemy_id": "guard", "object_id": "alarm"}}, "extra": "keep"}
	model.replace_document(document)
	_check(model.place_goal(Vector2i(7, 7)).is_ok(), "已有出口可以重新放置")
	var goal := MapEditorDocument.position_goal(model.document)
	_check(goal.type == "escape_prison" and goal.enemy_id == "guard" and goal.object_id == "alarm" and goal.radius == 0.2 and goal.position.extra == "keep", "移动出口保留条件、半径与位置扩展字段")
	var before := JSON.stringify(model.document.to_dict())
	model.resize(4, 4)
	_check(MapEditorDocument.position_goal(model.document).is_empty(), "缩小地图会移除越界终点")
	_check(model.undo() and JSON.stringify(model.document.to_dict()) == before, "单次撤销完整恢复裁剪前的地图与终点")
	model.document.properties.level = {"goal": {"type": "destroy_waves"}}
	model.clear_goal()
	_check(model.document.properties.level.goal.type == "destroy_waves", "没有坐标终点的战斗目标不被重置按钮清除")
	model.document.properties.level = "invalid"
	before = JSON.stringify(model.document.to_dict())
	_check(not model.place_goal(Vector2i.ONE).is_ok() and JSON.stringify(model.document.to_dict()) == before, "非法规则对象必须先修正，不被设置终点偷偷覆盖")


## 原生输入事件、粘贴信号与提交均限制1..64；旧大地图只读回填不能被意外裁剪。
func _test_dimensions() -> void:
	for field in [_editor._width_field, _editor._height_field]:
		var input: LineEdit = field.get_line_edit()
		_check(field.min_value == 1 and field.max_value == 64, "尺寸输入的范围为1..64")
		input.grab_focus()
		for text: String in ["65", "99999", "0", "-1", "3.5", "1+2", "abc"]:
			input.text = text
			input.text_changed.emit(text)
			_check(input.text.is_valid_int() and input.text.to_int() >= 1 and input.text.to_int() <= 64, "非法键入或粘贴被恢复：" + text)
		await _settle()
		input.select_all()
		for code in [54, 52]:
			var event := InputEventKey.new()
			event.pressed = true
			event.unicode = code
			root.push_input(event)
			await _settle()
		await _settle()
		_check(input.text == "64", "实际键盘输入允许64")
		input.release_focus()
		await _settle()
	_editor._resize_document()
	_check(_editor.editor_document.document.width == 64 and _editor.editor_document.document.height == 64, "两个合法边界值应用为64×64")
	var input := _editor._width_field.get_line_edit()
	input.grab_focus()
	input.text = "65"
	var before := JSON.stringify(_editor.editor_document.document.to_dict())
	_editor._resize_document()
	_check(JSON.stringify(_editor.editor_document.document.to_dict()) == before and _editor._message_dialog.visible, "应用入口再次拒绝超限的未提交文本")
	_editor._message_dialog.hide()
	input.release_focus()
	var legacy := MapDocument.new()
	legacy.width = 128
	legacy.height = 80
	_editor.editor_document.replace_document(legacy)
	await _settle()
	_check(_editor._width_field.value == 128 and _editor._height_field.value == 80 and _editor.editor_document.document.width == 128, "打开旧大地图如实显示原尺寸，不自动裁剪")
	_editor._resize_document()
	_check(_editor.editor_document.document.width == 128 and _editor._message_dialog.visible, "旧大尺寸必须改到合法范围才允许应用")
	_editor._message_dialog.hide()


## 用画布真实变换计算屏幕格心，兼容居中、缩放及窗口大小。
func _cell_point(cell: Vector2i) -> Vector2:
	return _editor._canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2(.5, .5)) * _editor._canvas.cell_size)


## 按下并松开一个真实鼠标按钮。
func _click(point: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	_mouse(point, button, true)
	_mouse(point, button, false)


## 把事件交给视口命中分派，不能绕过画布手势逻辑。
func _mouse(point: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = button
	event.pressed = pressed
	root.push_input(event)


## 让容器和焦点完成延迟更新。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 仅清理本进程独占的测试目录。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for folder in directory.get_directories():
		_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)


## 汇总检查并使用非零退出码报告失败。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
