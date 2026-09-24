extends SceneTree
## 敌人放置画布使用真实鼠标路由验证半格预览、单次提交和显示清理，不写玩家存档。

var _checks := 0
var _failures := 0
var _view: MapEditorViewport
var _canvas: MapEditorCanvas
var _registry := ContentRegistry.new()
var _model := MapEditorDocument.new()
var _requests: Array[Vector2] = []
var _cancelled := 0
var _last_result: DataResult
var _config := {"module_limit": 2, "module_health": 2.5, "module_ids": ["movement", "melee"]}


## 等待场景树就绪后构建独立视口，不读取设置、关卡进度或草稿。
func _initialize() -> void:
	_run.call_deferred()


## 先检查放置与历史，再覆盖工具退出及缩放滚动后的实际落点。
func _run() -> void:
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_check(_registry.load_directories().is_ok(), "真实模块与地块目录可载入")
	_view = MapEditorViewport.new()
	_view.position = Vector2(70, 70)
	_view.size = Vector2(640, 550)
	root.add_child(_view)
	_canvas = _view.canvas
	_canvas.registry = _registry
	_canvas.enemy_placement_requested.connect(_place_enemy)
	_canvas.enemy_placement_cancelled.connect(_cancel_enemy)
	_model.changed.connect(_sync_document)
	await _test_preview_and_placement()
	await _test_invalid_footprint()
	await _test_cancellation()
	await _test_zoom_and_scroll()
	_view.queue_free()
	await _settle()
	print("地图敌人画布回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 半格悬浮预览保持文档干净；左键拖动只在按下时建立一条完整敌人历史。
func _test_preview_and_placement() -> void:
	await _fresh()
	var supplied := _config.duplicate(true)
	_canvas.set_enemy_template(supplied)
	supplied.module_ids.clear()
	_motion(_point(Vector2(3.23, 4.18)))
	await _settle()
	_check(not _canvas._enemy_preview.is_empty() and _canvas._enemy_preview_valid, "有效模板在可通行地板显示合法预览")
	_check(_canvas._enemy_preview_position == Vector2(3, 4), "鼠标位置按最近半格吸附")
	_check(_canvas._enemy_preview.modules.size() == 2 and _canvas._enemy_template.module_ids.size() == 2, "预览使用独立模板副本及真实两个模块")
	_check(_model.document.enemies.is_empty() and _model._undo_stack.is_empty() and not _model.is_dirty(), "鼠标预览不写地图、不记录撤销")
	var preview := _canvas._enemy_preview.duplicate(true)
	for item: Dictionary in preview.modules:
		var definition := _registry.get_module(item.module_id)
		_check(definition != null and definition.size == Vector2(0.5, 0.5) and definition.texture.ends_with(".svg"), "预览模块使用注册定义中的真实占地和SVG")
	_mouse(_point(Vector2(3.23, 4.18)), MOUSE_BUTTON_LEFT, true)
	_check(_requests.size() == 1 and _requests[0] == Vector2(3, 4) and _last_result.is_ok(), "左键按下只发出一个吸附后的放置请求")
	_check(_canvas._enemy_preview.is_empty() and _model.document.enemies.size() == 1 and _model._undo_stack.size() == 1, "成功放置清理旧幽灵且整台机器只占一条历史")
	_motion(_point(Vector2(5.2, 4.2)), MOUSE_BUTTON_MASK_LEFT)
	_mouse(_point(Vector2(5.2, 4.2)), MOUSE_BUTTON_LEFT, false)
	await _settle()
	_check(_requests.size() == 1 and _model.document.enemies.size() == 1, "按住拖动与松开不连续刷出敌人")
	_check(_model.document.enemies[0].modules == preview.modules and _model.document.enemies[0].behavior == "auto_chase_attack", "实际地图沿用预览模块装配与已注册敌人行为")
	_check(_model.undo() and _model.document.enemies.is_empty() and not _model.is_dirty(), "一次撤销完整移除敌人并回到保存点")
	_check(_model.redo() and _model.document.enemies.size() == 1, "一次重做恢复整台敌人")
	await _settle()


## 已占位置、void和真实模块越界均显示非法预览，点击拒绝后不污染历史。
func _test_invalid_footprint() -> void:
	_motion(_point(Vector2(3, 4)))
	await _settle()
	_check(not _canvas._enemy_preview.is_empty() and not _canvas._enemy_preview_valid, "与已有敌人重叠时保留红色非法预览")
	var count := _model._undo_stack.size()
	_click(_point(Vector2(3, 4)))
	_check(not _last_result.is_ok() and _model.document.enemies.size() == 1 and _model._undo_stack.size() == count, "非法点击交给模型拒绝，敌人和撤销历史保持不变")
	_model.paint(Vector2i(7, 5), "")
	_motion(_point(Vector2(7.5, 5.5)))
	await _settle()
	_check(not _canvas._enemy_preview.is_empty() and not _canvas._enemy_preview_valid, "真实模块占据void时不能放置")
	_motion(_point(Vector2(0.02, 4)))
	await _settle()
	_check(_canvas._enemy_preview_position == Vector2(0, 4) and not _canvas._enemy_preview_valid, "边缘按半格吸附但模块越出地图时显示非法")
	var requests := _requests.size()
	_motion(_point(Vector2(12.2, 4)))
	_click(_point(Vector2(12.2, 4)))
	await _settle()
	_check(_canvas._enemy_preview.is_empty() and _requests.size() == requests, "鼠标位于地图外空白时清除预览且不能发送放置请求")


## 结束手势、开菜单前清理、视图变化及工具取消都只清除预览，不提交敌人。
func _test_cancellation() -> void:
	for action in ["finish", "zoom", "scroll", "focus", "hide", "template", "mode", "refresh", "outside", "right", "escape"]:
		await _fresh(Vector2i(64, 48))
		_view.set_zoom(1.5)
		await _settle()
		var point := _point(_view.view_center.snapped(Vector2(0.5, 0.5)))
		_motion(point)
		await _settle()
		_check(not _canvas._enemy_preview.is_empty(), "清理前已有真实预览：" + action)
		var cancellations := _cancelled
		match action:
			"finish": _canvas.finish_stroke()
			"zoom": _view.zoom_in()
			"scroll": _view._h_scroll.value += 20
			"focus": _canvas.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
			"hide": _view.hide()
			"template": _canvas.set_enemy_template(_config)
			"mode": _canvas.paint_mode = MapEditorCanvas.PaintMode.POINT
			"refresh": _canvas.refresh()
			"outside": _motion(_view.get_global_rect().end + Vector2(30, 30))
			"right": _click(point, MOUSE_BUTTON_RIGHT)
			"escape":
				var key := InputEventKey.new()
				key.keycode = KEY_ESCAPE
				key.pressed = true
				root.push_input(key)
		_check(_canvas._enemy_preview.is_empty() and _requests.is_empty() and _model._undo_stack.is_empty(), "只清除预览、不改变地图与历史：" + action)
		if action in ["right", "escape"]:
			_check(_cancelled == cancellations + 1 and _canvas.paint_mode == MapEditorCanvas.PaintMode.BRUSH, "取消信号恢复地形绘制且只触发一次：" + action)
		_view.show()
		await _settle()


## 缩放滚动后的鼠标位置转回正确地图坐标，裁剪外区域不能被误当作可编辑位置。
func _test_zoom_and_scroll() -> void:
	await _fresh(Vector2i(64, 48))
	_view.set_zoom(2.0)
	await _settle()
	_view._h_scroll.value += 40
	_view._v_scroll.value += 24
	await _settle()
	var position := _view.view_center.floor() + Vector2(0.5, 0.5)
	_motion(_point(position + Vector2(0.1, 0.1)))
	await _settle()
	_check(_canvas._enemy_preview_position == position and _canvas._enemy_preview_valid, "200%缩放和滚动后预览仍按正确半格坐标吸附")
	_click(_point(position + Vector2(0.1, 0.1)))
	_check(_requests.size() == 1 and _requests[0] == position and _last_result.is_ok(), "缩放滚动后实际放置位置与预览一致")
	var outside := Vector2(_view.global_position.x - 8, _view.get_global_rect().get_center().y)
	_motion(outside)
	_click(outside)
	await _settle()
	_check(_canvas._enemy_preview.is_empty() and _requests.size() == 1 and _view.clip_contents and _view._content.clip_contents, "被视口裁剪的地图不保留幽灵也不能误放敌人")


## 用独立内存地图重建每个用例，模板设置完成后重新建立干净的历史起点。
func _fresh(dimensions := Vector2i(12, 10)) -> void:
	var document := MapDocument.new()
	document.width = dimensions.x
	document.height = dimensions.y
	for y in dimensions.y:
		for x in dimensions.x:
			document.set_tile(Vector2i(x, y), "floor")
	_model.replace_document(document)
	_model.set_enemies_enabled(true)
	_check(_model.set_enemy_template(_config, _registry).is_ok(), "测试敌人模板通过公共校验")
	_model.replace_document(_model.document)
	_requests.clear()
	_canvas.set_enemy_template(_config)
	_canvas.paint_mode = MapEditorCanvas.PaintMode.ENEMY
	_view.reset_view()
	await _settle()


## 每次模型事务将最新快照同步到现有画布，重绘不生成额外编辑步骤。
func _sync_document() -> void:
	_canvas.document = _model.document
	_view.refresh_map()


## 放置信号交给编辑文档处理，测试不绕开模型占地与开关校验。
func _place_enemy(position: Vector2) -> void:
	_requests.append(position)
	_last_result = _model.place_enemy(position, _registry)


## 模拟编辑器收到取消信号后恢复地形画笔，画布自身不擅自改动外部工具选择。
func _cancel_enemy() -> void:
	_cancelled += 1
	_canvas.paint_mode = MapEditorCanvas.PaintMode.BRUSH


## 世界位置通过当前画布变换换算成真实视口鼠标坐标。
func _point(position: Vector2) -> Vector2:
	return _canvas.get_global_transform_with_canvas() * (position * _canvas.cell_size)


## 单击包含完整按下与释放，覆盖原生GUI路由和画布外捕获逻辑。
func _click(point: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	_mouse(point, button, true)
	_mouse(point, button, false)


## 鼠标按钮经根视口派发，禁止直接调用画布处理器掩盖裁剪问题。
func _mouse(point: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.button_mask = 1 << (button - 1) if pressed else 0
	root.push_input(event)


## 运动保留按键状态，以区分悬停、拖动和可见区外清理。
func _motion(point: Vector2, mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.button_mask = mask
	root.push_input(event)


## 给容器与绘制各一帧完成当前布局及输入状态。
func _settle() -> void:
	await process_frame
	await process_frame


## 汇总断言并报告全部独立失败，最终退出码由失败数决定。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
