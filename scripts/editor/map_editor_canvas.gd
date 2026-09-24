class_name MapEditorCanvas
extends MapCanvas
## 框选只属于地图编辑器；先预览范围，松开后发出一次矩形修改意图。

signal rectangle_requested(area: Rect2i, erase: bool)
signal point_placement_cancelled
signal enemy_placement_requested(position: Vector2)
signal enemy_placement_cancelled

enum PaintMode { BRUSH, RECTANGLE, POINT, ENEMY }

var paint_mode := PaintMode.BRUSH:
	set(value):
		if paint_mode != value:
			finish_stroke()
		paint_mode = value
var visible_editing_rect := Rect2()
var _selection_button := MOUSE_BUTTON_NONE
var _selection_start := Vector2i.ZERO
var _selection_end := Vector2i.ZERO
var _selection_document: MapDocument
var _selection_dimensions := Vector2i.ZERO
var _enemy_template: Dictionary = {}
var _enemy_preview: Dictionary = {}
var _enemy_preview_position := Vector2.ZERO
var _enemy_preview_valid := false
var _enemy_preview_document: MapDocument


## 复用原画布输入连接；鼠标离开小地图时立即收起悬浮敌人，不留下旧位置。
func _ready() -> void:
	super._ready()
	mouse_exited.connect(clear_enemy_preview)


## 模板只保留本地副本；更换模块或耐久后必须在新指针位置重新检查真实占地。
func set_enemy_template(config: Dictionary) -> void:
	_enemy_template = config.duplicate(true)
	clear_enemy_preview()


## 清除显示用敌人快照，不更改当前放置工具、地图内容或撤销记录。
func clear_enemy_preview() -> void:
	_enemy_preview.clear()
	_enemy_preview_valid = false
	_enemy_preview_document = null
	queue_redraw()


## 文档、地图尺寸或缩放刷新后不沿用旧占地结论，移动鼠标才重新建立预览。
func refresh() -> void:
	clear_enemy_preview()
	super.refresh()


## 查询当前是否正在框选，供视口保留跨出边缘的鼠标捕获。
func is_selecting() -> bool:
	return _selection_button != MOUSE_BUTTON_NONE


## 选区包含起止两端的完整格子，四个拖动方向使用相同结果。
func selection_cells() -> Rect2i:
	if not is_selecting():
		return Rect2i()
	var first := _selection_start.min(_selection_end)
	var last := _selection_start.max(_selection_end)
	return Rect2i(first, last - first + Vector2i.ONE)


## 切换工具、缩放、滚动或离开页面时取消未提交的框选，普通笔画仍按原逻辑结束。
func finish_stroke() -> void:
	_selection_button = MOUSE_BUTTON_NONE
	_selection_document = null
	clear_enemy_preview()
	queue_redraw()
	super.finish_stroke()


## 普通画笔复用已有连续绘制；框选按下时仅建立预览，不修改地图和历史。
func _on_gui_input(event: InputEvent) -> void:
	if paint_mode == PaintMode.ENEMY:
		_on_enemy_gui_input(event)
		return
	if paint_mode == PaintMode.POINT:
		if editing_enabled and document != null and event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var cell := Vector2i((event.position / cell_size).floor())
				if document.in_bounds(cell):
					cell_requested.emit(cell, false)
				accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				point_placement_cancelled.emit()
				accept_event()
		return
	if paint_mode == PaintMode.BRUSH:
		super._on_gui_input(event)
		return
	if not editing_enabled or document == null:
		return
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if event.pressed:
			finish_stroke()
			_selection_button = event.button_index
			_selection_start = _cell_at(event.position)
			_selection_end = _selection_start
			_selection_document = document
			_selection_dimensions = Vector2i(document.width, document.height)
			queue_redraw()
		elif event.button_index == _selection_button:
			_commit_selection(event.position)
		accept_event()
	elif event is InputEventMouseMotion and is_selecting():
		_selection_end = _cell_at(event.position)
		queue_redraw()
		accept_event()


## Esc 取消点位工具并返回原绘制手势；优先让文本框和弹窗处理自身快捷键。
func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and editing_enabled and paint_mode == PaintMode.ENEMY and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		clear_enemy_preview()
		enemy_placement_cancelled.emit()
		get_viewport().set_input_as_handled()
		return
	if is_visible_in_tree() and editing_enabled and paint_mode == PaintMode.POINT and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		point_placement_cancelled.emit()
		get_viewport().set_input_as_handled()


## 捕获画布外的拖动与松开，并支持 Esc；坐标始终转换到当前缩放和滚动后的画布。
func _input(event: InputEvent) -> void:
	if paint_mode == PaintMode.ENEMY and event is InputEventMouseMotion:
		var local_pointer: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		if not editing_enabled or not is_visible_in_tree() or not _enemy_editing_bounds().has_point(local_pointer):
			clear_enemy_preview()
	if not is_selecting():
		super._input(event)
		return
	if not editing_enabled or not is_visible_in_tree() or document != _selection_document:
		finish_stroke()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		finish_stroke()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_selection_end = _cell_at(get_global_transform_with_canvas().affine_inverse() * event.position)
		queue_redraw()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == _selection_button:
		_commit_selection(get_global_transform_with_canvas().affine_inverse() * event.position)
		get_viewport().set_input_as_handled()


## 失焦或隐藏时不能把旧预览带入新页面，也不能在恢复窗口时意外填充。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()):
		finish_stroke()


## 指针越界时限制到可见地图边缘；整格吸附仍由真实 cell_size 计算。
func _cell_at(point: Vector2) -> Vector2i:
	var bounds := Rect2(Vector2.ZERO, Vector2(document.width, document.height) * cell_size)
	if visible_editing_rect.has_area():
		bounds = bounds.intersection(visible_editing_rect)
	var clamped := Vector2(clampf(point.x, bounds.position.x, bounds.end.x - 0.001), clampf(point.y, bounds.position.y, bounds.end.y - 0.001))
	return Vector2i(floori(clamped.x / cell_size), floori(clamped.y / cell_size))


## 只有完成拖动才提交，先清除捕获状态，避免文档重绘或松开冒泡导致重复提交。
func _commit_selection(point: Vector2) -> void:
	if document != _selection_document or Vector2i(document.width, document.height) != _selection_dimensions:
		finish_stroke()
		return
	_selection_end = _cell_at(point)
	var area := selection_cells()
	var erase := _selection_button == MOUSE_BUTTON_RIGHT
	finish_stroke()
	rectangle_requested.emit(area, erase)


## 使用淡蓝透明填充和像素级虚线边框；范围随格子缩放，边线保持清晰可辨。
func _draw() -> void:
	super._draw()
	_draw_goal_marker()
	_draw_enemy_placement_preview()
	if not is_selecting() or not editing_enabled:
		return
	var area := selection_cells()
	var rect := Rect2(Vector2(area.position) * cell_size, Vector2(area.size) * cell_size)
	draw_rect(rect, Color(0.20, 0.55, 0.95, 0.16))
	var inset := minf(0.75, cell_size * 0.15)
	var outline := rect.grow(-inset)
	var color := Color(0.23, 0.49, 0.80, 0.78)
	var corners := [outline.position, Vector2(outline.end.x, outline.position.y), outline.end, Vector2(outline.position.x, outline.end.y)]
	for index in 4:
		draw_dashed_line(corners[index], corners[(index + 1) % 4], color, 1.5, 5.0)


## 敌人按下左键只提交一次位置，按住移动仅更新预览；右键只取消，不擦除地形。
func _on_enemy_gui_input(event: InputEvent) -> void:
	if not editing_enabled or document == null or registry == null:
		clear_enemy_preview()
		return
	if event is InputEventMouseMotion:
		_update_enemy_preview(event.position)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _update_enemy_preview(event.position):
				var position := _enemy_preview_position
				clear_enemy_preview()
				enemy_placement_requested.emit(position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			clear_enemy_preview()
			enemy_placement_cancelled.emit()
			accept_event()


## 可放置区域同时受地图和视口裁剪约束，不能在被滚动遮住的图外建立落点。
func _enemy_editing_bounds() -> Rect2:
	if document == null or cell_size <= 0.0:
		return Rect2()
	var bounds := Rect2(Vector2.ZERO, Vector2(document.width, document.height) * cell_size)
	return bounds.intersection(visible_editing_rect) if visible_editing_rect.has_area() else bounds


## 半格吸附使用当前缩放后的局部像素；合法性和最终提交共用同一个真实模块检查器。
func _update_enemy_preview(point: Vector2) -> bool:
	if document == null or registry == null or not _enemy_editing_bounds().has_point(point):
		clear_enemy_preview()
		return false
	var snapped := (point / cell_size).snapped(Vector2(0.5, 0.5))
	_enemy_preview_position = snapped.clamp(Vector2.ZERO, Vector2(document.width - 0.5, document.height - 0.5))
	var built := MapEditorEnemyTemplate.build_entry(_enemy_template, _enemy_preview_position, registry, "enemy_preview")
	if not built.is_ok():
		clear_enemy_preview()
		return false
	_enemy_preview = built.value
	_enemy_preview_document = document
	_enemy_preview_valid = MapEditorEnemyTemplate.validate_placement(_enemy_preview, document, registry).is_ok()
	queue_redraw()
	return true


## 按各模块真实宽高绘制半透明SVG；越界或碰撞显示红色，预览不创建战斗实体。
func _draw_enemy_placement_preview() -> void:
	if paint_mode != PaintMode.ENEMY or not editing_enabled or _enemy_preview.is_empty() or document != _enemy_preview_document:
		return
	var bounds := _enemy_editing_bounds()
	var tint := Color(1.0, 1.0, 1.0, 0.55) if _enemy_preview_valid else Color(1.0, 0.32, 0.32, 0.55)
	var fill := Color(GameTheme.ACCENT, 0.25) if _enemy_preview_valid else Color(0.9, 0.12, 0.12, 0.35)
	var outline := Color(GameTheme.ACCENT, 0.75) if _enemy_preview_valid else Color(0.9, 0.12, 0.12, 0.8)
	for item: Dictionary in _enemy_preview.modules:
		var definition := registry.get_module(str(item.module_id))
		if definition == null:
			continue
		var offset: Dictionary = item.offset
		var center := _enemy_preview_position + Vector2(float(offset.x), float(offset.y))
		var module_rect := Rect2((center - definition.size * 0.5) * cell_size, definition.size * cell_size)
		var clipped := module_rect.intersection(bounds)
		if not clipped.has_area():
			continue
		draw_rect(clipped, fill)
		var texture := _get_texture(definition.texture)
		if texture != null:
			var source := Rect2((clipped.position - module_rect.position) / module_rect.size * texture.get_size(), clipped.size / module_rect.size * texture.get_size())
			draw_texture_rect_region(texture, clipped, source, tint)
		draw_rect(clipped, outline, false, 1.5)


## 编辑画布直接读取保存的目标坐标绘制绿色终点，与试玩使用同一份关卡元数据。
func _draw_goal_marker() -> void:
	if document == null:
		return
	var goal := MapEditorDocument.position_goal(document)
	if goal.is_empty():
		return
	var center := Vector2(goal.position.x, goal.position.y) * cell_size
	draw_circle(center, cell_size * 0.31, Color(0.39, 0.88, 0.77, 0.22))
	draw_arc(center, cell_size * 0.36, 0, TAU, 48, GameTheme.SUCCESS, 2.0, true)
	var unit := cell_size * 0.1
	draw_line(center + Vector2(-1.5, 0) * unit, center + Vector2(-0.3, 1.2) * unit, GameTheme.SUCCESS, 2.0, true)
	draw_line(center + Vector2(-0.3, 1.2) * unit, center + Vector2(1.8, -1.5) * unit, GameTheme.SUCCESS, 2.0, true)
