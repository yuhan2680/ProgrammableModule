class_name PlayerLevelSortChevron
extends Control
## 表头细线箭头只负责视觉翻转，排序状态仍由列表面板持有。

var direction_progress := 1.0:
	set(value):
		direction_progress = value
		queue_redraw()
var active_strength := 0.0:
	set(value):
		active_strength = value
		queue_redraw()
var _motion: Tween
var _target_direction := 1.0
var _target_strength := 0.0
var _initialized := false


## 保持小尺寸且不截获鼠标，整块表头仍是唯一可点击目标。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


## 快速切换从当前形状继续插值，避免旧动画叠加或先跳回初始方向。
func set_state(active: bool, ascending: bool, animate: bool = true) -> void:
	var direction := -1.0 if active and ascending else 1.0
	var strength := 1.0 if active else 0.0
	if _initialized and is_equal_approx(direction, _target_direction) and is_equal_approx(strength, _target_strength):
		return
	if _motion != null and _motion.is_valid():
		_motion.kill()
	_target_direction = direction
	_target_strength = strength
	if not animate or not _initialized or not is_inside_tree():
		direction_progress = direction
		active_strength = strength
		_initialized = true
		return
	_initialized = true
	_motion = create_tween().set_parallel(true)
	_motion.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_motion.tween_property(self, "direction_progress", direction, 0.20)
	_motion.tween_property(self, "active_strength", strength, 0.20)


## 以垂直翻转的两段抗锯齿细线绘制箭头，非活动列保持淡色向下。
func _draw() -> void:
	var center := size * 0.5
	var offset := 2.4 * direction_progress
	var color := GameTheme.MUTED
	color.a = lerpf(0.42, 0.90, active_strength)
	draw_polyline(PackedVector2Array([center + Vector2(-4.1, -offset), center + Vector2(0, offset), center + Vector2(4.1, -offset)]), color, 1.45, true)
