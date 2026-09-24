class_name AssemblyCanvas
extends Control
## 模块组装的网格交互层。这里只发出意图，数量、重叠等规则由 AssemblyModel 检查。

signal placement_requested(offset: Vector2)
signal move_requested(index: int, offset: Vector2)
signal remove_requested(index: int)
signal module_selected(index: int)

const GRID_RADIUS: int = 8
const GRID_STEP: float = 0.5
const CELL_PIXELS: float = 26.0
const MIN_CELL_PIXELS: float = 20.0
const BLUEPRINT_SIZE := Vector2(663.0, 442.0)
const BLUEPRINT_MARGIN: float = 12.0
const MIN_ZOOM: float = 0.5
const MAX_ZOOM: float = 2.5
const ZOOM_STEP: float = 1.15
const VIEW_INSET: float = 10.0
const BLUEPRINT_TEXTURE: Texture2D = preload("res://assets/ui/assembly_blueprint.svg")
const EDGE_FADE_SHADER: Shader = preload("res://assets/ui/assembly_edge_fade.gdshader")

var model: AssemblyModel
var registry: ContentRegistry
var selected_index: int = -1
var interaction_enabled: bool = true
var can_place: bool = true
## 默认为完整固定图纸；设置只控制查看方式，不写入装配模型。
var free_zoom_enabled: bool = false:
	set(value):
		if free_zoom_enabled == value:
			return
		free_zoom_enabled = value
		_apply_view_mode()
var _drag_index: int = -1
var _drag_preview := Vector2.ZERO
var _textures: Dictionary = {}
var _zoom: float = 1.0
var _pan := Vector2.ZERO
var _pan_dragging: bool = false
var _pan_anchor := Vector2.ZERO
var _pan_start := Vector2.ZERO
var _cursor_before_pan: Input.CursorShape = Input.CURSOR_ARROW
var _edge_fade: ShaderMaterial
var _drawing_group: AlphaCanvasGroup
var _ink: Node2D
var _origin_offset := Vector2.ZERO
var _origin_model: AssemblyModel
var _paper_anchor := Vector2.ZERO


## 外层铺满矩形视口，默认完整显示3:2图纸；自由查看始终只改变显示。
func _ready() -> void:
	custom_minimum_size = Vector2.ONE * (GRID_RADIUS * 2 + 1) * MIN_CELL_PIXELS
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_edge_fade = ShaderMaterial.new()
	_edge_fade.shader = EDGE_FADE_SHADER
	# 输入仍由原 Control 接收；自由模式只把绘图合成一次，固定模式继续直接绘制。
	material = null
	_drawing_group = AlphaCanvasGroup.new()
	_drawing_group.name = "AssemblyDrawingGroup"
	_sync_drawing_mode()
	add_child(_drawing_group)
	_ink = Node2D.new()
	_ink.name = "AssemblyInk"
	_ink.draw.connect(_draw_ink)
	_drawing_group.add_child(_ink)
	resized.connect(_on_view_resized)
	clip_contents = true
	mouse_force_pass_scroll_events = false
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)


## 模型或选中项变化后重绘，运行期间不保留未完成的拖动。
func refresh() -> void:
	_sync_origin_model()
	if model == null or selected_index >= model.modules.size():
		selected_index = -1
	if not interaction_enabled:
		_drag_index = -1
	queue_redraw()


## 从鼠标位置换算到半格对齐的模块中心偏移。
func offset_at(pixel_position: Vector2) -> Vector2:
	return ((pixel_position - pixel_at(Vector2.ZERO)) / _cell_pixels()).round() * GRID_STEP


## 转换模块相对位置到画布坐标，绘图和鼠标命中共用这一比例。
func pixel_at(offset: Vector2) -> Vector2:
	return _view_center() + (_origin_offset + offset) / GRID_STEP * _cell_pixels()


## 切换时结束未完成手势；回到固定模式只重置查看，不更改装配原点或草稿。
func _apply_view_mode() -> void:
	_end_pan()
	_drag_index = -1
	_sync_drawing_mode()
	if not free_zoom_enabled:
		reset_view()
	else:
		_clamp_pan()
		queue_redraw()


## 仅自由模式开启合成与完整 alpha 精度；固定模式没有额外绘制层或淡出材质。
func _sync_drawing_mode() -> void:
	if _drawing_group == null:
		return
	_drawing_group.alpha_precision_enabled = free_zoom_enabled
	_drawing_group.material = _edge_fade if free_zoom_enabled else null
	_drawing_group.visible = free_zoom_enabled


## 恢复初始缩放并居中当前装配原点；固定模式同时把完整纸张移到该原点周围。
func reset_view() -> void:
	_end_pan()
	_drag_index = -1
	_zoom = 1.0
	if not free_zoom_enabled:
		_paper_anchor = _origin_offset
	_pan = -_origin_offset / GRID_STEP * _cell_pixels()
	_clamp_pan()
	queue_redraw()


## 固定纸张坐标系的视图中心；逻辑原点可在纸上移动，但不会平移整张纸。
func _view_center() -> Vector2:
	return size * 0.5 + _pan


## 用同一等比缩放适配横向图纸，确保格子和模块不会被拉伸。
func _paper_scale() -> float:
	var available := (size - Vector2.ONE * VIEW_INSET * 2.0).max(Vector2.ONE)
	return minf(available.x / BLUEPRINT_SIZE.x, available.y / BLUEPRINT_SIZE.y) * (_zoom if free_zoom_enabled else 1.0)


## 原SVG白框内高度对应17个半格，以此作为扩展图纸和模块共用的格距基准。
func _cell_pixels() -> float:
	return (BLUEPRINT_SIZE.y - BLUEPRINT_MARGIN * 2.0) * _paper_scale() / float(GRID_RADIUS * 2 + 1)


## 固定模式不随首件落点改变纸张；自由模式再补足逻辑原点周围的完整装配范围。
func _paper_source_bounds() -> Rect2:
	var cell := (BLUEPRINT_SIZE.y - BLUEPRINT_MARGIN * 2.0) / float(GRID_RADIUS * 2 + 1)
	var original := Rect2(_paper_anchor / GRID_STEP * cell - BLUEPRINT_SIZE * 0.5, BLUEPRINT_SIZE)
	if not free_zoom_enabled:
		return original
	var origin := _origin_offset / GRID_STEP * cell
	var required := Rect2(origin - Vector2.ONE * BLUEPRINT_SIZE.y * 0.5, Vector2.ONE * BLUEPRINT_SIZE.y)
	return original.merge(required)


## 扩展蓝图不重算缩放或固定纸张中心，旧格线不会因放置首件而跳动。
func _paper_rect() -> Rect2:
	var bounds := _paper_source_bounds()
	return Rect2(_view_center() + bounds.position * _paper_scale(), bounds.size * _paper_scale())


## 仅白框内为网格区域，纯蓝纸边不用于放置模块。
func _grid_rect() -> Rect2:
	return _paper_rect().grow(-BLUEPRINT_MARGIN * _paper_scale())


## 模块编辑只接受当前可见网格内的点，最终半格范围仍由模型校验。
func _is_visible_grid_point(pixel_position: Vector2) -> bool:
	return Rect2(Vector2.ZERO, size).has_point(pixel_position) and _grid_rect().has_point(pixel_position)


## 滚轮以光标为锚点等比缩放，避免查看细节时图纸突然跳回中心。
func _zoom_at(pixel_position: Vector2, multiplier: float) -> void:
	if not free_zoom_enabled:
		return
	var previous := _zoom
	_zoom = clampf(_zoom * multiplier, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(previous, _zoom):
		return
	_pan = pixel_position - size * 0.5 - (pixel_position - _view_center()) * (_zoom / previous)
	_clamp_pan()
	if _drag_index >= 0:
		_drag_preview = offset_at(pixel_position)
	if _pan_dragging:
		_pan_anchor = pixel_position
		_pan_start = _pan
	queue_redraw()


## 右键只查看图纸，不移除模块；开始平移会取消未提交的左键拖动。
func _begin_pan(pixel_position: Vector2) -> void:
	if not free_zoom_enabled or _pan_dragging:
		return
	grab_focus()
	_drag_index = -1
	_pan_dragging = true
	_pan_anchor = pixel_position
	_pan_start = _pan
	_cursor_before_pan = Input.get_current_cursor_shape()
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	Input.set_default_cursor_shape(Input.CURSOR_DRAG)
	queue_redraw()


## 按右键起点计算总位移，避免重叠的输入分发重复累加鼠标运动。
func _update_pan(pixel_position: Vector2) -> void:
	if not free_zoom_enabled or not _pan_dragging:
		return
	_pan = _pan_start + pixel_position - _pan_anchor
	_clamp_pan()
	queue_redraw()


## 结束右键查看并恢复光标，窗口外释放也使用同一清理入口。
func _end_pan() -> void:
	if not _pan_dragging:
		return
	_pan_dragging = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	Input.set_default_cursor_shape(_cursor_before_pan)


## 固定图纸始终完整居中；自由查看则允许非对称扩展，但保留一部分纸张在视口中。
func _clamp_pan() -> void:
	if not free_zoom_enabled:
		_pan = -_paper_anchor / GRID_STEP * _cell_pixels()
		return
	var bounds := _paper_source_bounds()
	var scale := _paper_scale()
	var visible_edge := Vector2.ONE * minf(48.0, minf(size.x, size.y) * 0.25)
	var minimum := visible_edge - size * 0.5 - bounds.end * scale
	var maximum := size * 0.5 - visible_edge - bounds.position * scale
	_pan = _pan.clamp(minimum, maximum)


## 布局变化保留当前缩放与视角，并修正可能完全离屏的平移量。
func _on_view_resized() -> void:
	_clamp_pan()
	queue_redraw()


## 离开页面或切走窗口时取消鼠标捕获，防止返回后仍残留拖动状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()):
		_end_pan()
		_drag_index = -1
		queue_redraw()


## 节点移除时也恢复系统光标，避免抓手泄露到其他页面。
func _exit_tree() -> void:
	_end_pan()


## 捕捉视口外的鼠标移动与释放，让右键平移和左键拖动可靠结束。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _pan_dragging:
		_update_pan(get_global_transform_with_canvas().affine_inverse() * event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT and _pan_dragging:
			_end_pan()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT and _drag_index >= 0:
			_finish_drag(get_global_transform_with_canvas().affine_inverse() * event.position)


## 右键与滚轮受自由查看设置控制；左键及Delete/Backspace继续服从运行锁和模型规则。
func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_begin_pan(event.position)
			else:
				_end_pan()
			accept_event()
			return
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			_zoom_at(event.position, pow(ZOOM_STEP, direction * maxf(1.0, event.factor)))
			accept_event()
			return
	elif event is InputEventMouseMotion and _pan_dragging:
		_update_pan(event.position)
		accept_event()
		return
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_end_pan()
		_drag_index = -1
		queue_redraw()
		accept_event()
		return
	if not interaction_enabled or model == null or _pan_dragging:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _is_visible_grid_point(event.position):
			grab_focus()
			var index := _hit_module(event.position)
			if index >= 0:
				selected_index = index
				_drag_index = index
				_drag_preview = _module_offset(index)
				module_selected.emit(index)
			elif can_place:
				_request_placement(event.position)
		else:
			_finish_drag(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _drag_index >= 0:
		_drag_preview = offset_at(event.position)
		queue_redraw()
		accept_event()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_DELETE, KEY_BACKSPACE] and selected_index >= 0:
		remove_requested.emit(selected_index)
		accept_event()


## 换装配模型时丢弃纯显示原点；同一草稿的编辑或恢复不会重新定位已有模块。
func _sync_origin_model() -> void:
	if _origin_model == model:
		return
	_origin_model = model
	_origin_offset = Vector2.ZERO
	_paper_anchor = Vector2.ZERO
	_drag_index = -1
	_clamp_pan()


## 首件始终向模型提交逻辑零点，仅在同步放置成功后把所点半格设为显示原点。
func _request_placement(pixel_position: Vector2) -> void:
	if model == null or not interaction_enabled or not can_place or not _is_visible_grid_point(pixel_position):
		return
	var target_model := model
	var first := target_model.modules.is_empty()
	var proposed_origin := ((pixel_position - _view_center()) / _cell_pixels()).round() * GRID_STEP
	placement_requested.emit(Vector2.ZERO if first else offset_at(pixel_position))
	# 装配面板同步校验和提交；失败、无监听器或被替换模型都不能移动显示原点。
	if first and model == target_model and target_model.modules.size() == 1 and _module_offset(0).is_equal_approx(Vector2.ZERO):
		_origin_model = model
		_origin_offset = proposed_origin
		queue_redraw()


## 仅在可见白框网格内松开时提交位置，纸边和视口外落点都取消拖动。
func _finish_drag(pixel_position: Vector2) -> void:
	if _drag_index < 0:
		return
	var index := _drag_index
	_drag_index = -1
	if interaction_enabled and _is_visible_grid_point(pixel_position):
		move_requested.emit(index, offset_at(pixel_position))
	queue_redraw()


## 查找鼠标命中的真实模块矩形，不以单个网格格子代替模块尺寸。
func _hit_module(pixel_position: Vector2) -> int:
	if model == null or registry == null or not _is_visible_grid_point(pixel_position):
		return -1
	for index in range(model.modules.size() - 1, -1, -1):
		var definition := registry.get_module(model.modules[index].module_id)
		if definition == null:
			continue
		var extent := definition.size / GRID_STEP * _cell_pixels()
		if Rect2(pixel_at(_module_offset(index)) - extent * 0.5, extent).has_point(pixel_position):
			return index
	return -1


## 从地图的字典坐标读取模块中心偏移，保持模型与 UI 数据格式一致。
func _module_offset(index: int) -> Vector2:
	var offset: Dictionary = model.modules[index].offset
	return Vector2(float(offset.x), float(offset.y))


## 根控件继续接收所有重绘请求；自由模式交给同原点子层，固定模式保留原直接绘制。
func _draw() -> void:
	_sync_edge_fade()
	if free_zoom_enabled and _ink != null:
		_ink.queue_redraw()
	else:
		_draw_content(self)


## 在纯绘图节点的 draw 回调内提交绘制，合成层不参与鼠标或键盘输入。
func _draw_ink() -> void:
	if free_zoom_enabled:
		_draw_content(_ink)


## 图纸、装配原点和模块按同一半格尺度绘制；中心标记不占用模块位置。
func _draw_content(target: CanvasItem) -> void:
	_draw_blueprint(target)
	var center := pixel_at(Vector2.ZERO)
	var arm := _cell_pixels() * 0.35
	target.draw_line(center - Vector2(arm, 0), center + Vector2(arm, 0), Color("DBF4FF"), 1.5, true)
	target.draw_line(center - Vector2(0, arm), center + Vector2(0, arm), Color("DBF4FF"), 1.5, true)
	if model == null or registry == null:
		return
	for index in range(model.modules.size()):
		_draw_module(target, index, _module_offset(index), false)
	if _drag_index >= 0:
		_draw_module(target, _drag_index, _drag_preview, true)


## 固定图纸和未扩展图纸直接使用原SVG，扩展时才复用其边框与格线区域。
func _draw_blueprint(target: CanvasItem) -> void:
	if _paper_source_bounds().size.is_equal_approx(BLUEPRINT_SIZE):
		target.draw_texture_rect(BLUEPRINT_TEXTURE, _paper_rect(), false)
		return
	# 八块边框与中央格线不重叠，继续保持原 SVG 边框和网格相位。
	var inset := BLUEPRINT_MARGIN + 0.75
	_draw_blueprint_frame(target, inset)
	_draw_blueprint_grid(target, inset)


## 从SVG切出四角和四边，仅沿边框长度方向延长，蓝纸边和白框厚度保持原样。
func _draw_blueprint_frame(target: CanvasItem, inset: float) -> void:
	var paper := _paper_rect()
	var margin := inset * _paper_scale()
	var source_x: Array[float] = [0.0, inset, BLUEPRINT_SIZE.x - inset, BLUEPRINT_SIZE.x]
	var source_y: Array[float] = [0.0, inset, BLUEPRINT_SIZE.y - inset, BLUEPRINT_SIZE.y]
	var target_x: Array[float] = [paper.position.x, paper.position.x + margin, paper.end.x - margin, paper.end.x]
	var target_y: Array[float] = [paper.position.y, paper.position.y + margin, paper.end.y - margin, paper.end.y]
	var texture_scale := BLUEPRINT_TEXTURE.get_size() / BLUEPRINT_SIZE
	for row in range(3):
		for column in range(3):
			if row == 1 and column == 1:
				continue
			var source := Rect2(Vector2(source_x[column], source_y[row]), Vector2(source_x[column + 1] - source_x[column], source_y[row + 1] - source_y[row]))
			var target_rect := Rect2(Vector2(target_x[column], target_y[row]), Vector2(target_x[column + 1] - target_x[column], target_y[row + 1] - target_y[row]))
			target.draw_texture_rect_region(BLUEPRINT_TEXTURE, target_rect, Rect2(source.position * texture_scale, source.size * texture_scale))


## 只铺可见的8×8格SVG区域，保持原始相位与正方格距，扩展再大也不分配大贴图。
func _draw_blueprint_grid(target: CanvasItem, inset: float) -> void:
	var visible := _paper_rect().grow(-inset * _paper_scale()).intersection(Rect2(Vector2.ZERO, size))
	if not visible.has_area():
		return
	var cell := _cell_pixels()
	var tile_size := Vector2.ONE * cell * 8.0
	var tile_origin := _view_center() - Vector2.ONE * cell * 4.5
	var first := Vector2i(((visible.position - tile_origin) / tile_size).floor())
	var end := Vector2i(((visible.end - tile_origin) / tile_size).ceil())
	var source_cell := (BLUEPRINT_SIZE.y - BLUEPRINT_MARGIN * 2.0) / float(GRID_RADIUS * 2 + 1)
	var source_origin := BLUEPRINT_SIZE * 0.5 - Vector2.ONE * source_cell * 4.5
	var texture_scale := BLUEPRINT_TEXTURE.get_size() / BLUEPRINT_SIZE
	for row in range(first.y, end.y):
		for column in range(first.x, end.x):
			var tile := Rect2(tile_origin + Vector2(column, row) * tile_size, tile_size)
			var target_rect := tile.intersection(visible)
			var source := Rect2(source_origin + (target_rect.position - tile.position) / _paper_scale(), target_rect.size / _paper_scale())
			target.draw_texture_rect_region(BLUEPRINT_TEXTURE, target_rect, Rect2(source.position * texture_scale, source.size * texture_scale))


## 柔边只用于自由查看；固定模式保留完整SVG蓝纸边和白框，不执行淡出材质。
func _sync_edge_fade() -> void:
	if _edge_fade == null:
		return
	if not free_zoom_enabled:
		_edge_fade.set_shader_parameter("edge_strength", Vector4.ZERO)
		return
	var paper := _paper_rect()
	_edge_fade.set_shader_parameter("viewport_size", size)
	_edge_fade.set_shader_parameter("edge_strength", Vector4(
		1.0 - smoothstep(0.0, VIEW_INSET, paper.position.x),
		1.0 - smoothstep(0.0, VIEW_INSET, paper.position.y),
		1.0 - smoothstep(0.0, VIEW_INSET, size.x - paper.end.x),
		1.0 - smoothstep(0.0, VIEW_INSET, size.y - paper.end.y)
	))


## 绘制模块图片和选中边框；拖动预览不改变底层模块位置。
func _draw_module(target: CanvasItem, index: int, offset: Vector2, ghost: bool) -> void:
	if index >= model.modules.size():
		return
	var definition := registry.get_module(model.modules[index].module_id)
	if definition == null:
		return
	var extent := definition.size / GRID_STEP * _cell_pixels()
	var rect := Rect2(pixel_at(offset) - extent * 0.5, extent)
	var tint := Color(1, 1, 1, 0.4) if ghost else Color.WHITE
	target.draw_rect(rect, GameTheme.ACCENT * tint)
	if not _textures.has(definition.texture):
		var loaded := ContentTextureLoader.load_texture(definition.texture)
		_textures[definition.texture] = loaded.value if loaded.is_ok() else null
	var texture: Texture2D = _textures[definition.texture]
	if texture != null:
		target.draw_texture_rect(texture, rect, false, tint)
	var border := Color("F0FBFF") if index == selected_index or ghost else Color("A8DDF4")
	if index == selected_index and not ghost:
		target.draw_rect(rect.grow(1.0), Color("124C74"), false, 3.0)
	target.draw_rect(rect, border * tint, false, 2.0 if index == selected_index or ghost else 1.0)
