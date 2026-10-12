extends Node
## 调整同一原生菜单滚动条的真实矩形与闲置透明度，选项、数值和输入仍由引擎处理。

const END_INSET := 6.0
const ROUNDING_TOLERANCE := 1.0
const SCROLL_FADE := preload("res://scripts/ui/settings_scroll_fade.gd")

var popup: PopupMenu
var scroll: ScrollContainer
var _bar: VScrollBar
var _fade: Node
var _layout_queued := false


## 内部容器每次原生排版后重新内缩，真实点击区域与看到的滚动条始终一致。
func _ready() -> void:
	_bar = scroll.get_v_scroll_bar()
	_fade = SCROLL_FADE.attach_bar(_bar)
	scroll.sort_children.connect(_queue_layout)
	_bar.resized.connect(_queue_layout)
	_bar.changed.connect(_queue_layout)
	popup.about_to_popup.connect(_queue_layout)
	popup.size_changed.connect(_queue_layout)
	popup.popup_hide.connect(_reset_fade)
	_queue_layout()


## 容器的滚动条定位也是延迟执行，尺寸信号合并后可在它完成时应用最终矩形。
func _queue_layout() -> void:
	if _layout_queued or not is_inside_tree():
		return
	_layout_queued = true
	_layout_bar.call_deferred()


## 只缩短原生条的行程，不修改滚动范围、菜单项高度或可见页数。
func _layout_bar() -> void:
	_layout_queued = false
	if not is_instance_valid(popup) or not popup.visible or not popup.is_embedded() or not is_instance_valid(scroll):
		return
	if _round_up_short_menu():
		return
	var panel := scroll.get_theme_stylebox("panel")
	var lower := panel.get_margin(SIDE_BOTTOM)
	var horizontal := scroll.get_h_scroll_bar()
	if horizontal.visible:
		lower += horizontal.size.y
	var top := panel.get_margin(SIDE_TOP)
	var inset := minf(END_INSET, maxf(0.0, (scroll.size.y - top - lower - _bar.get_combined_minimum_size().y) * 0.5))
	var bounds := Rect2(Vector2(scroll.size.x - panel.get_margin(SIDE_RIGHT) - _bar.size.x, top + inset), Vector2(_bar.size.x, maxf(0.0, scroll.size.y - top - lower - inset * 2.0)))
	if not _bar.get_rect().is_equal_approx(bounds):
		_bar.position = bounds.position
		_bar.size = bounds.size


## 分数缩放可能少分配不足一像素高度；有空间时补齐，短列表不为舍入误差出现滚动条。
func _round_up_short_menu() -> bool:
	var overflow := _bar.max_value - _bar.page
	if not _bar.visible or overflow <= 0.0 or overflow > ROUNDING_TOLERANCE:
		return false
	var extra := maxi(1, ceili(overflow * popup.content_scale_factor))
	var parent_height := floori(popup.get_parent().get_viewport().get_visible_rect().size.y)
	var limit: int = mini(parent_height, popup.max_size.y) if popup.max_size.y > 0 else parent_height
	if popup.size.y + extra > limit:
		return false
	popup.size.y += extra
	return true


## 菜单关闭时即使鼠标在窗口外松开，也不把拖动或淡出状态带到下次打开。
func _reset_fade() -> void:
	if is_instance_valid(_fade):
		_fade._dragging = false
		_fade._idle_elapsed = 0.0
		_fade.set_process(false)
	if is_instance_valid(_bar):
		_bar.modulate.a = 0.0
