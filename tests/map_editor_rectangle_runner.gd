extends SceneTree
## 框选回归：真实鼠标输入验证预览、批量填充、边界、取消和单步历史。

var _checks := 0
var _failures := 0
var _game: GameShell
var _editor: MapEditor
var _temporary: String


## 延迟构建场景，不读取或写入正式玩家记录。
func _initialize() -> void:
	_run.call_deferred()


## 模型先验证批量事务，再通过真正的编辑器入口验证手势与视图转换。
func _run() -> void:
	_test_batch()
	_temporary = "user://tests/rectangle_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_editor = _game._editor
	await _test_tools()
	await _test_fill()
	await _test_cancellation()
	await _test_scaled_selection()
	await _test_spawn_and_brush()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图框选回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 边界内批量修改只通知一次，无效或相同填充不污染历史，最大地图仍是一笔。
func _test_batch() -> void:
	var model := MapEditorDocument.new()
	var document := MapDocument.new()
	document.width = 8
	document.height = 6
	document.properties = {"custom": {"keep": 7}}
	document.cell_extras[Vector2i(1, 1)] = {"custom_cell": "keep"}
	model.replace_document(document)
	var notifications := [0]
	model.changed.connect(func() -> void: notifications[0] += 1)
	model.paint_rectangle(Rect2i(-2, -3, 6, 5), "floor")
	_check(model.document.cells.size() == 8 and model.document.get_tile_id(Vector2i(3, 1)) == "floor" and model.document.get_tile_id(Vector2i(4, 1)).is_empty(), "批量填充裁剪到地图边界并覆盖范围内所有格子")
	_check(notifications[0] == 1 and model._undo_stack.size() == 1 and model._action_depth == 0, "整块只发一次通知并记录一次撤销")
	_check(model.document.properties.custom.keep == 7 and model.document.cell_extras[Vector2i(1, 1)].custom_cell == "keep", "填充保留地图和格子扩展字段")
	model.paint_rectangle(Rect2i(0, 0, 4, 2), "floor")
	model.paint_rectangle(Rect2i(20, 20, 3, 3), "wall")
	_check(model._undo_stack.size() == 1, "相同内容和越界区域不新增历史")
	_check(model.undo() and model.document.cells.is_empty() and not model.is_dirty(), "一次撤销完整还原区域并恢复保存点")
	_check(model.redo() and model.document.cells.size() == 8, "一次重做恢复整块填充")
	model.paint_rectangle(Rect2i(1, 0, 2, 2), "")
	_check(model.document.cells.size() == 4 and not model.document.cell_extras.has(Vector2i(1, 1)), "矩形擦除同时移除对应格子扩展数据")
	_check(model.undo() and model.document.cell_extras[Vector2i(1, 1)].custom_cell == "keep", "撤销矩形擦除恢复扩展字段")
	document = MapDocument.new()
	document.width = 256
	document.height = 256
	model.replace_document(document)
	notifications[0] = 0
	model.paint_rectangle(Rect2i(0, 0, 256, 256), "floor")
	_check(model.document.cells.size() == 65536 and notifications[0] == 1 and model._undo_stack.size() == 1, "最大地图65536格只刷新一次且可单步撤销")
	_check(model.undo() and model.document.cells.is_empty(), "最大地图批量填充可完整撤销")


## SVG工具组与绘制项目同行，中英文和最小窗口均不重叠或越出属性区。
func _test_tools() -> void:
	_check(_editor._canvas.paint_mode == MapEditorCanvas.PaintMode.BRUSH and _editor._paint_button.button_pressed, "默认选择普通画笔")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var context := locale + " " + str(dimensions)
			var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
			for control: Control in [_editor._paint_button, _editor._rectangle_button, _editor._brush]:
				_check(scroll.get_global_rect().encloses(control.get_global_rect()), "工具完整显示 " + context + str(control.name))
			_check(_editor._paint_button.icon != null and _editor._rectangle_button.icon != null and not _editor._rectangle_button.get_tooltip().is_empty(), "两个SVG图标及悬停名称已设置 " + context)
			_check(_editor._paint_button.get_global_rect().end.x <= _editor._rectangle_button.global_position.x and _editor._rectangle_button.get_global_rect().end.x < _editor._brush.global_position.x, "画笔、框选、项目按顺序排列 " + context)
			_check(absf(_editor._brush.get_global_rect().get_center().y - _editor._paint_button.get_global_rect().get_center().y) < 1.0, "工具与绘制项目垂直居中对齐 " + context)
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()


## 四个拖动方向与单击均按完整格子提交；预览本身不改地图，填充和擦除各占一笔。
func _test_fill() -> void:
	for reverse_x in [false, true]:
		for reverse_y in [false, true]:
			await _fresh()
			_click(_editor._rectangle_button.get_global_rect().get_center())
			var start := Vector2i(5 if reverse_x else 2, 4 if reverse_y else 2)
			var finish := Vector2i(2 if reverse_x else 5, 2 if reverse_y else 4)
			_mouse(_point(start), MOUSE_BUTTON_LEFT, true)
			_motion(_point(finish), MOUSE_BUTTON_MASK_LEFT)
			await _settle()
			_check(_editor._canvas.is_selecting() and _editor._canvas.selection_cells() == Rect2i(2, 2, 4, 3), "框选预览包含起止格，支持反向拖动")
			_check(_editor.editor_document.document.cells.is_empty() and not _editor.editor_document.is_dirty(), "松开前仅预览，文档和历史保持原样")
			_mouse(_point(finish), MOUSE_BUTTON_LEFT, false)
			await _settle()
			_check(_editor.editor_document.document.cells.size() == 12 and not _editor._canvas.is_selecting(), "松开后完整填充12格并收起选框")
			_check(_editor.editor_document._undo_stack.size() == 1 and _editor.editor_document._action_depth == 0, "一次框选仅提交一笔历史")
	_editor._undo()
	_check(_editor.editor_document.document.cells.is_empty(), "编辑器撤销按钮还原整块")
	_editor._redo()
	_check(_editor.editor_document.document.cells.size() == 12, "编辑器重做恢复整块")
	_drag(Vector2i(3, 2), Vector2i(4, 4), MOUSE_BUTTON_RIGHT)
	_check(_editor.editor_document.document.cells.size() == 6, "框选模式右键擦除整块")
	_editor._undo()
	_select_item("")
	_drag(Vector2i(2, 2), Vector2i(5, 4))
	_check(_editor.editor_document.document.cells.is_empty(), "绘制项目选择擦除时左键框选也能整块擦除")
	_select_item("floor")
	_click(_point(Vector2i(6, 6)))
	_check(_editor.editor_document.document.cells.size() == 1 and _editor.editor_document.document.get_tile_id(Vector2i(6, 6)) == "floor", "框选原地点击只填一格")


## 取消、切换项目、失焦和缩放都清理待定范围；之后松开不会意外产生修改。
func _test_cancellation() -> void:
	for action in ["escape", "tool", "item", "zoom", "focus", "hide", "new"]:
		await _fresh()
		_editor._set_paint_mode(MapEditorCanvas.PaintMode.RECTANGLE)
		_mouse(_point(Vector2i(2, 2)), MOUSE_BUTTON_LEFT, true)
		_motion(_point(Vector2i(5, 4)), MOUSE_BUTTON_MASK_LEFT)
		match action:
			"escape":
				var key := InputEventKey.new()
				key.keycode = KEY_ESCAPE
				key.pressed = true
				root.push_input(key)
			"tool": _editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
			"item": _select_item("")
			"zoom": _editor._map_view.zoom_in()
			"focus": _editor._canvas.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
			"hide": _editor.hide()
			"new": _editor._new_document()
		_mouse(_point(Vector2i(5, 4)), MOUSE_BUTTON_LEFT, false)
		_editor.show()
		await _settle()
		_check(not _editor._canvas.is_selecting() and _editor.editor_document._undo_stack.is_empty() and _editor.editor_document._action_depth == 0, "清理未提交的框选：" + action)
		_check(_editor.editor_document.document.cells.is_empty(), "取消后松开不会意外填充：" + action)


## 缩放和滚动后的选区使用画布局部格坐标，拖出画幅只填到当前可见边界。
func _test_scaled_selection() -> void:
	await _fresh(Vector2i(64, 48))
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.RECTANGLE)
	var view := _editor._map_view
	view.set_zoom(1.5)
	await _settle()
	view._h_scroll.value += 40.0
	view._v_scroll.value += 24.0
	await _settle()
	var center := Vector2i(view.view_center.floor())
	_drag(center - Vector2i.ONE, center + Vector2i.ONE)
	_check(_editor.editor_document.document.cells.size() == 9 and _editor.editor_document.document.get_tile_id(center - Vector2i.ONE) == "floor" and _editor.editor_document.document.get_tile_id(center + Vector2i.ONE) == "floor", "150%缩放和滚动后准确填充3×3格")
	_editor._undo()
	_mouse(_point(center), MOUSE_BUTTON_LEFT, true)
	var outside := view.get_global_rect().end + Vector2(60, 60)
	_motion(outside, MOUSE_BUTTON_MASK_LEFT)
	await _settle()
	var area := _editor._canvas.selection_cells()
	_check(_editor._canvas.is_selecting() and area.has_area(), "拖出画幅仍保留裁剪后的选框")
	_mouse(outside, MOUSE_BUTTON_LEFT, false)
	await _settle()
	_check(_editor.editor_document.document.cells.size() == area.get_area() and Rect2i(0, 0, 64, 48).encloses(area), "画布外松开只提交预览区域，不填充地图外或不可见的远处")
	_editor._undo()
	_mouse(_point(center), MOUSE_BUTTON_LEFT, true)
	view._h_scroll.value += 10.0
	_mouse(_point(center + Vector2i.ONE), MOUSE_BUTTON_LEFT, false)
	_check(not _editor._canvas.is_selecting() and _editor.editor_document.document.cells.is_empty(), "滚动视角取消待定选区，不沿新坐标误填")


## 出生点回到单点模式；再切回画笔仍保留快速拖动补线和原有撤销语义。
func _test_spawn_and_brush() -> void:
	await _fresh()
	_editor.editor_document.paint_rectangle(Rect2i(0, 0, 12, 10), "floor")
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.RECTANGLE)
	_editor._spawn_button.pressed.emit()
	_check(_editor._spawn_button.button_pressed and not _editor._paint_button.button_pressed and _editor._canvas.paint_mode == MapEditorCanvas.PaintMode.POINT, "独立起点按钮切换到单击模式，不选中地形画笔")
	_click(_point(Vector2i(4, 5)))
	_check(_editor.editor_document.document.player_spawn.position == {"x": 4.5, "y": 5.5}, "出生点仍使用原有单点放置")
	_select_item("floor")
	_check(not _editor._rectangle_button.disabled, "回到地块项目后重新开放框选")
	await _fresh()
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	_drag(Vector2i(1, 2), Vector2i(5, 2))
	_check(_editor.editor_document.document.cells.size() == 5 and _editor.editor_document._undo_stack.size() == 1, "原画笔快速拖动仍补齐连续格子并记录一笔")


## 每个交互用例替换独立空白地图，不向磁盘保存测试地图。
func _fresh(dimensions := Vector2i(12, 10)) -> void:
	_editor._canvas.finish_stroke()
	var document := MapDocument.new()
	document.id = "rectangle_test"
	document.width = dimensions.x
	document.height = dimensions.y
	_editor.editor_document.replace_document(document)
	_editor._map_view.reset_view()
	_select_item("floor")
	await _settle()


## 模拟下拉框真实选择，确保同步工具可用状态和取消旧预览。
func _select_item(item: String) -> void:
	var index := _editor._brush_ids.find(item)
	_editor._brush.select(index)
	_editor._brush.item_selected.emit(index)


## 用当前画布实际变换取得格心，避免把缩放视图误按原像素坐标测试。
func _point(cell: Vector2i) -> Vector2:
	return _editor._canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2(0.5, 0.5)) * _editor._canvas.cell_size)


## 一次真实拖动覆盖按下、运动和松开三个阶段。
func _drag(first: Vector2i, last: Vector2i, button := MOUSE_BUTTON_LEFT) -> void:
	_mouse(_point(first), button, true)
	_motion(_point(last), 1 << (button - 1))
	_mouse(_point(last), button, false)


## 按钮和单格测试均走视口事件路由。
func _click(point: Vector2) -> void:
	_mouse(point, MOUSE_BUTTON_LEFT, true)
	_mouse(point, MOUSE_BUTTON_LEFT, false)


## 发送完整鼠标事件，以覆盖画布外释放和控件捕获。
func _mouse(point: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.button_mask = 1 << (button - 1) if pressed else 0
	root.push_input(event)


## 运动事件保留按键掩码，模拟实际按住鼠标拖动。
func _motion(point: Vector2, mask: int) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.button_mask = mask
	root.push_input(event)


## 等待容器布局及信号触发后的画布尺寸稳定。
func _settle() -> void:
	await process_frame
	await process_frame


## 只删除本轮独占测试目录，不触碰正式设置或地图。
func _cleanup(path: String) -> void:
	if not (path == _temporary or path.begins_with(_temporary + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 汇总独立失败，最终退出码反映实际检查结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
