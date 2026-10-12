class_name ModuleRestrictionLock
extends Control
## 小锁保留固定尺寸，解锁时抬起锁梁右端，锁上时平滑落回锁体。

const DURATION := 0.18
var locked := false
var _tween: Tween
var _openness := 1.0:
	set(value):
		_openness = value
		queue_redraw()


## 图标不拦截鼠标，整行继续作为模块限制的点击区域。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(16, 16)


## 初次展示直接使用真实状态，点击或历史变化才动画；连续点击从当前进度平滑反向。
func set_locked(value: bool, animate: bool = true) -> void:
	var target := 0.0 if value else 1.0
	if locked == value and is_equal_approx(_openness, target):
		return
	if locked == value and animate and _tween != null and _tween.is_running():
		return
	locked = value
	if _tween != null:
		_tween.kill()
	if not animate or not is_visible_in_tree():
		_openness = target
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "_openness", target, DURATION)


## 以24单位绘制锁体和拱形锁梁，缩放到菜单固定尺寸，不依赖字体符号或原生复选图标。
func _draw() -> void:
	var scale_factor := minf(size.x, size.y) / 24.0
	var origin := (size - Vector2.ONE * 24.0 * scale_factor) * 0.5
	var color := Color("526C88").lerp(Color("8994A3"), _openness)
	var body := GameTheme.box(color, Color.TRANSPARENT, 3)
	body.set_content_margin_all(0)
	draw_style_box(body, Rect2(origin + Vector2(4, 11) * scale_factor, Vector2(16, 12) * scale_factor))
	var arch_y := 7.0 - _openness * 3.0
	var stroke := 2.7 * scale_factor
	draw_arc(origin + Vector2(12, arch_y) * scale_factor, 4.0 * scale_factor, PI, TAU, 24, color, stroke, true)
	draw_line(origin + Vector2(8, arch_y) * scale_factor, origin + Vector2(8, 12) * scale_factor, color, stroke, true)
	draw_line(origin + Vector2(16, arch_y) * scale_factor, origin + Vector2(16, 12.0 - _openness * 4.0) * scale_factor, color, stroke, true)
	var hole := Color("F4F7FB")
	draw_circle(origin + Vector2(12, 16) * scale_factor, 1.65 * scale_factor, hole, true, -1, true)
	draw_line(origin + Vector2(12, 16) * scale_factor, origin + Vector2(12, 20) * scale_factor, hole, 1.65 * scale_factor, true)
