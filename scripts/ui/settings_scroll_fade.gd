class_name SettingsScrollFade
extends Node
## 只改变原生滚动条透明度，始终保留控件占位、键盘操作和现有右侧留白。

const IDLE_SECONDS := 0.8
const FADE_SECONDS := 0.2

var _scroll: ScrollContainer
var _bar: VScrollBar
var _idle_elapsed := 0.0
var _dragging := false


## 将控制器随滚动容器一同创建和释放，不保留跨页面的计时器或动画回调。
static func attach(scroll: ScrollContainer) -> SettingsScrollFade:
	var controller := SettingsScrollFade.new()
	controller.name = "SettingsScrollFade"
	controller._scroll = scroll
	scroll.add_child(controller)
	return controller


## 默认透明；实际数值变化覆盖滚轮、触控板、键盘和原生拖动的共同路径。
func _ready() -> void:
	_bar = _scroll.get_v_scroll_bar()
	_bar.modulate.a = 0.0
	_bar.value_changed.connect(_on_value_changed)
	_bar.gui_input.connect(_on_bar_input)
	set_process(false)


## 只有原生条实际收到按下才锁住显示，覆盖层拦截的点击和单纯悬停均不显示。
func _on_bar_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = true
		_show_scrollbar()


## 全局跟踪按住原生滚动条的手势，移出条外或容器外松开也能正常开始淡出。
func _input(event: InputEvent) -> void:
	if not _dragging or not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or event.pressed:
		return
	_dragging = false
	_show_scrollbar()


## 数值变化意味着内容确实滚动，重新开始停顿时间并立即取消正在进行的淡出。
func _on_value_changed(_value: float) -> void:
	_show_scrollbar()


## 只在存在可滚动内容的可见页面显示原生条，不改变其宽度或布局状态。
func _show_scrollbar() -> void:
	if not _scroll.is_visible_in_tree() or not _bar.is_visible_in_tree():
		return
	_idle_elapsed = 0.0
	_bar.modulate.a = 1.0
	set_process(true)


## 拖动按住时保持可见，松手后停顿再线性淡出；完全透明时停止逐帧处理。
func _process(delta: float) -> void:
	if _dragging:
		return
	_idle_elapsed += delta
	if _idle_elapsed <= IDLE_SECONDS:
		return
	_bar.modulate.a = maxf(0.0, 1.0 - (_idle_elapsed - IDLE_SECONDS) / FADE_SECONDS)
	if _bar.modulate.a == 0.0:
		set_process(false)


## 窗口失焦可能收不到鼠标松开，解除拖动锁以免滚动条永久停留。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _dragging:
		_dragging = false
		_show_scrollbar()
