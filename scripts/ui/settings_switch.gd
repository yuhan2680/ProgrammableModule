class_name SettingsSwitch
extends Button
## 原生按钮保留鼠标和键盘切换语义，胶囊与滑块使用矢量绘制以适应高分辨率。


var _keyboard_focus := false


## 固定开关的轻量尺寸，所有视觉状态都由统一矢量图形绘制。
func _init() -> void:
	toggle_mode = true
	custom_minimum_size = Vector2(52, 32)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	toggled.connect(_refresh_switch)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


## 区分最近的输入方式：鼠标点击不留下焦点环，键盘导航仍显示当前位置。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_focus = false
	elif event is InputEventKey and event.pressed:
		_keyboard_focus = true
	else:
		return
	queue_redraw()


## 按钮状态变化只刷新图形，设置的写入继续由面板负责。
func _refresh_switch(_pressed: bool) -> void:
	queue_redraw()


## 白色滑块在蓝色开启底和灰色关闭底之间切换，键盘焦点只使用浅蓝细描边。
func _draw() -> void:
	var track_rect := Rect2(Vector2(2, 2), size - Vector2(4, 4))
	var tint := Color("007AFF") if button_pressed else Color("BCC2CC")
	if is_hovered():
		tint = tint.lightened(0.06)
	if disabled:
		tint.a = 0.45
	var track := GameTheme.box(tint, Color.TRANSPARENT, 16)
	draw_style_box(track, track_rect)
	var diameter := track_rect.size.y - 6.0
	var thumb_x := track_rect.end.x - diameter - 3.0 if button_pressed else track_rect.position.x + 3.0
	var thumb := GameTheme.box(Color.WHITE, Color(1, 1, 1, 0.7), 16)
	thumb.shadow_color = Color(0.05, 0.10, 0.20, 0.13)
	thumb.shadow_size = 2
	thumb.shadow_offset = Vector2(0, 1)
	draw_style_box(thumb, Rect2(Vector2(thumb_x, track_rect.position.y + 3), Vector2(diameter, diameter)))
	if has_focus() and _keyboard_focus:
		var ring := GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 18)
		draw_style_box(ring, Rect2(Vector2.ZERO, size))
