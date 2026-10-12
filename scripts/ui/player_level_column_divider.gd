class_name PlayerLevelColumnDivider
extends Control
## 列间细线提供独立拖动命中，宽度计算与列表内容仍由面板负责。

signal drag_started
signal drag_changed(delta_x: float)
signal drag_finished

var _dragging := false
var _hovered := false
var _origin_x := 0.0


## 宽命中区围绕细线布置，横向调整光标提示拖动，不接管排序按钮焦点。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "拖动调整列宽"
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	resized.connect(queue_redraw)


## 原生捕获保持完整手势；采用当前事件坐标，避免桌面鼠标查询滞后或测试注入不更新系统指针。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_origin_x = (get_global_transform() * event.position).x
			drag_started.emit()
			queue_redraw()
		else:
			cancel_drag()
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		drag_changed.emit((get_global_transform() * event.position).x - _origin_x)
		accept_event()


## 页面隐藏、窗口缩放或失焦后结束当前手势，避免后续鼠标移动继续改变列宽。
func cancel_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	drag_finished.emit()
	queue_redraw()


## 悬停只轻微提高分隔线对比度，离开立即还原，避免留下聚焦描边。
func _set_hovered(value: bool) -> void:
	_hovered = value
	queue_redraw()


## 表头内绘制短竖线，实际拖动范围比线宽更大，正文无需增加贯穿整页的线条。
func _draw() -> void:
	var color := Color("8291A6") if _hovered or _dragging else Color("D3D9E2")
	var center := size.x * 0.5
	draw_line(Vector2(center, 5), Vector2(center, size.y - 5), color, 1.2, true)


## 失焦和隐藏均不能保留原生拖动状态，返回列表后从新手势开始。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()):
		cancel_drag()
