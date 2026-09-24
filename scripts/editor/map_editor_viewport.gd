class_name MapEditorViewport
extends Control
## 编辑器视图只保存缩放与观察中心，地图内容及撤销记录仍由编辑文档管理。

signal zoom_changed(value: float)

const BASE_CELL_SIZE := 32.0
const VIEW_PADDING := 40.0
const ZOOM_STEP := 1.25
const MIN_ZOOM := 0.25
const MAX_ZOOM := 4.0
const SCROLLBAR_SIZE := 16.0

var canvas: MapEditorCanvas = MapEditorCanvas.new()
var zoom: float = 1.0
var view_center: Vector2 = Vector2.ZERO
var usable_rect := Rect2()
var _content := Control.new()
var _h_scroll := HScrollBar.new()
var _v_scroll := VScrollBar.new()
var _map_dimensions := Vector2i.ZERO
var _auto_fit := true
var _syncing_scrollbars := false


# 用途：独立裁剪地图显示区，并在其外放置仅在内容溢出时出现的滚动条。
func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_content.name = "MapContent"
	_content.clip_contents = true
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)
	canvas.name = "MapCanvas"
	_content.add_child(canvas)
	# MapCanvas 的 ready 会设为 STOP，加入场景树后恢复滚轮事件向视图冒泡。
	canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_h_scroll.name = "MapHorizontalScroll"
	_v_scroll.name = "MapVerticalScroll"
	_h_scroll.step = 0.0
	_v_scroll.step = 0.0
	_h_scroll.focus_mode = Control.FOCUS_NONE
	_v_scroll.focus_mode = Control.FOCUS_NONE
	add_child(_h_scroll)
	add_child(_v_scroll)
	_h_scroll.value_changed.connect(_on_scroll_changed)
	_v_scroll.value_changed.connect(_on_scroll_changed)
	resized.connect(_on_resized)
	visibility_changed.connect(_on_visibility_changed)
	refresh_map()


# 用途：内容变化时刷新绘图，仅在地图宽高改变时重新适配并居中。
func refresh_map() -> void:
	var dimensions := _document_dimensions()
	if dimensions != _map_dimensions:
		_map_dimensions = dimensions
		reset_view()
		return
	_layout_canvas()


# 用途：新建、打开或改变地图范围后恢复自动适配，小地图保留原始一倍大小。
func reset_view() -> void:
	finish_interaction()
	_map_dimensions = _document_dimensions()
	_auto_fit = true
	view_center = Vector2(_map_dimensions) * 0.5
	zoom = _fit_zoom()
	_layout_canvas()
	zoom_changed.emit(zoom)


# 用途：按固定比例放大当前观察位置，保留范围内的地图观察中心。
func zoom_in() -> void:
	if can_zoom_in():
		set_zoom(zoom * ZOOM_STEP)


# 用途：按固定比例缩小当前观察位置，大地图可缩至完整适配的比例。
func zoom_out() -> void:
	if can_zoom_out():
		set_zoom(zoom / ZOOM_STEP)


# 用途：只改变显示比例，并先结束笔画，避免同一次绘制跨越两套坐标变换。
func set_zoom(value: float) -> void:
	if not is_finite(value):
		return
	var next_zoom := clampf(value, _minimum_zoom(), MAX_ZOOM)
	if is_equal_approx(next_zoom, zoom):
		return
	finish_interaction()
	_auto_fit = false
	zoom = next_zoom
	_layout_canvas()
	zoom_changed.emit(zoom)


# 用途：提供放大按钮的真实可用状态，避免超过显示上限后继续响应。
func can_zoom_in() -> bool:
	return zoom < MAX_ZOOM and not is_equal_approx(zoom, MAX_ZOOM)


# 用途：提供缩小按钮的动态下限，允许最大尺寸地图完整出现在视区中。
func can_zoom_out() -> bool:
	var minimum := _minimum_zoom()
	return zoom > minimum and not is_equal_approx(zoom, minimum)


# 用途：在菜单、页面切换、滚动和缩放前提交尚未完成的绘制事务。
func finish_interaction() -> void:
	canvas.finish_stroke()


# 用途：处理画布冒泡的滚轮缩放，左键绘制和右键擦除仍由原画布处理。
func _gui_input(event: InputEvent) -> void:
	if canvas.document == null or not is_visible_in_tree():
		return
	if event is not InputEventMouseButton or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_in()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		zoom_out()
		accept_event()


# 用途：指针离开地图可见区域时结束笔画，避免鼠标捕获继续修改裁剪区外的地块。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or event is not InputEventMouseMotion:
		return
	# 框选由编辑画布捕获并裁剪，跨出可见边缘时继续显示边界预览。
	if canvas.is_selecting():
		return
	var pointer: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
	if not usable_rect.has_point(pointer) or not Rect2(canvas.position, canvas.size).has_point(pointer):
		canvas.finish_stroke()


# 用途：窗口失焦时提交笔画，避免窗口外松键后留下未结束的事务。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		finish_interaction()


# 用途：窗口调整时自动视图重新适配，手动视图保留范围内的地图观察点。
func _on_resized() -> void:
	finish_interaction()
	if _auto_fit:
		view_center = Vector2(_document_dimensions()) * 0.5
		zoom = _fit_zoom()
	_layout_canvas()
	# 即使比例不变，可用空间也会改变缩小下限，按钮需要重新计算状态。
	zoom_changed.emit(zoom)


# 用途：隐藏编辑器时提交当前笔画，返回时保留观察中心和缩放。
func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		finish_interaction()


# 用途：把滚动条的位置换成地图观察中心，整个过程不修改地图内容或历史。
func _on_scroll_changed(_value: float) -> void:
	if _syncing_scrollbars:
		return
	var next_center := view_center
	if _h_scroll.visible:
		next_center.x = (_h_scroll.value + usable_rect.size.x * 0.5) / canvas.cell_size
	if _v_scroll.visible:
		next_center.y = (_v_scroll.value + usable_rect.size.y * 0.5) / canvas.cell_size
	# 提交笔画会同步触发文档重绘，先保存用户选定位置，避免重绘用旧中心回填滚动条。
	finish_interaction()
	view_center = next_center
	_auto_fit = false
	_layout_canvas(false)


# 用途：读取显示所需的地图宽高，不修改地图或推断任何玩法状态。
func _document_dimensions() -> Vector2i:
	if canvas.document == null:
		return Vector2i.ZERO
	return Vector2i(canvas.document.width, canvas.document.height)


# 用途：按四边留白计算完整地图适配比例，大地图完整显示时无需滚动条。
func _fit_zoom() -> float:
	var dimensions := _document_dimensions()
	if dimensions.x <= 0 or dimensions.y <= 0 or size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	var available := Vector2(maxf(size.x - VIEW_PADDING * 2.0, 1.0), maxf(size.y - VIEW_PADDING * 2.0, 1.0))
	var extent := Vector2(dimensions) * BASE_CELL_SIZE
	return minf(1.0, minf(available.x / extent.x, available.y / extent.y))


# 用途：常规缩小保留四分之一倍下限，大地图需要时使用更低的完整适配比例。
func _minimum_zoom() -> float:
	return minf(MIN_ZOOM, _fit_zoom())


# 用途：同步裁剪区、地图与滚动条，小地图居中，放大后的地图可滚动到四个边缘。
func _layout_canvas(refresh_contents: bool = true) -> void:
	canvas.cell_size = BASE_CELL_SIZE * zoom
	if refresh_contents:
		canvas.refresh()
	var dimensions := Vector2(_document_dimensions())
	var extent := dimensions * canvas.cell_size
	var horizontal := extent.x > size.x
	var vertical := extent.y > size.y
	# 一条滚动条占据空间后可能使另一方向溢出；只需补算一次交叉影响。
	if vertical and extent.x > size.x - SCROLLBAR_SIZE:
		horizontal = true
	if horizontal and extent.y > size.y - SCROLLBAR_SIZE:
		vertical = true
	if vertical and extent.x > size.x - SCROLLBAR_SIZE:
		horizontal = true
	var available := Vector2(maxf(size.x - (SCROLLBAR_SIZE if vertical else 0.0), 1.0), maxf(size.y - (SCROLLBAR_SIZE if horizontal else 0.0), 1.0))
	usable_rect = Rect2(Vector2.ZERO, available)
	_content.size = available
	for axis in 2:
		if extent[axis] <= available[axis]:
			view_center[axis] = dimensions[axis] * 0.5
		else:
			var half_page: float = available[axis] * 0.5 / canvas.cell_size
			view_center[axis] = clampf(view_center[axis], half_page, dimensions[axis] - half_page)
	# refresh 只设置最小尺寸；显式赋值才能在缩小时收回旧尺寸，防止空白区仍可点击。
	canvas.custom_minimum_size = extent
	canvas.size = extent
	canvas.position = available * 0.5 - view_center * canvas.cell_size
	canvas.visible_editing_rect = Rect2(-canvas.position, available).intersection(Rect2(Vector2.ZERO, extent))
	_syncing_scrollbars = true
	_h_scroll.visible = horizontal
	_v_scroll.visible = vertical
	_h_scroll.position = Vector2(0.0, available.y)
	_h_scroll.size = Vector2(available.x, SCROLLBAR_SIZE)
	# 竖向轨道顶部留出工具入口的高度，避免与右上角问号和缩放按钮重叠。
	_v_scroll.position = Vector2(available.x, VIEW_PADDING)
	_v_scroll.size = Vector2(SCROLLBAR_SIZE, maxf(available.y - VIEW_PADDING, 1.0))
	_h_scroll.max_value = maxf(extent.x, available.x)
	_h_scroll.page = available.x
	_h_scroll.value = maxf(-canvas.position.x, 0.0)
	_v_scroll.max_value = maxf(extent.y, available.y)
	_v_scroll.page = available.y
	_v_scroll.value = maxf(-canvas.position.y, 0.0)
	_syncing_scrollbars = false
