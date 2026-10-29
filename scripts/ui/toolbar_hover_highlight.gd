extends Node
## 工具按钮的底面独立绘制鼠标局部光；原生 Button 继续负责图标、焦点与输入。

const SURFACE_SHADER := preload("res://assets/ui/toolbar_pointer_highlight.gdshader")
const FADE_IN_SECONDS := 0.14
const FADE_OUT_SECONDS := 0.20
const WHITE_OPACITY := 0.576
const PRESS_OPACITY := 0.34
const LIGHT_RADIUS := 26.0

var button: Button
var _surface: ColorRect
var _material: ShaderMaterial
var _amount := 0.0
var _start_amount := 0.0
var _target := 0.0
var _elapsed := 0.0
var _duration := FADE_IN_SECONDS
var _window_active := true
var _styles: Dictionary = {}
var _colors: Dictionary = {}
var _focus_style: StyleBox
var _manage_focus := false


## 底面置于原生图标之下，四角与原有分段一致，不新增命中区或修改共享主题。
func _ready() -> void:
	set_process(false)
	if not is_instance_valid(button):
		return
	_material = ShaderMaterial.new()
	_material.shader = SURFACE_SHADER
	_material.set_shader_parameter("light_radius", LIGHT_RADIUS)
	_material.set_shader_parameter("hover_opacity", WHITE_OPACITY)
	_material.set_shader_parameter("press_opacity", PRESS_OPACITY)
	_refresh_styles()
	# 已由页头或自绘书本管理的空焦点样式不再接管，避免相互覆盖键盘模式。
	_focus_style = button.get_theme_stylebox("focus")
	_manage_focus = _focus_style is StyleBoxFlat and not button.has_method("set_keyboard_focus_visible")
	if _manage_focus:
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_surface = ColorRect.new()
	_surface.name = "ToolbarPointerLight"
	_surface.show_behind_parent = true
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.material = _material
	button.add_child(_surface)
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.resized.connect(_sync_geometry)
	button.mouse_entered.connect(_on_mouse_entered)
	button.mouse_exited.connect(_on_mouse_exited)
	button.visibility_changed.connect(_on_visibility_changed)
	# 原生绘制态包含鼠标、键盘按下及禁用切换，避免另建一套点击状态。
	button.draw.connect(_sync_native_state)
	_sync_geometry()
	_sync_native_state()


## 只在外部替换样式时接收新底色，保留重排后的圆角；不用主题信号反复触发自己。
func _refresh_styles() -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var source := button.get_theme_stylebox(state) as StyleBoxFlat
		if source == null:
			continue
		if _styles.get(state) == source and source.bg_color.a == 0.0:
			continue
		var color: Color = source.bg_color if source.bg_color.a > 0.0 else source.get_meta("toolbar_original_fill", source.bg_color)
		_colors[state] = color
		var style := source.duplicate() as StyleBoxFlat
		style.set_meta("toolbar_original_fill", color)
		style.bg_color = Color.TRANSPARENT
		_styles[state] = style
		button.add_theme_stylebox_override(state, style)
	var normal := button.get_theme_stylebox("normal") as StyleBoxFlat
	var radius := minf(button.size.x, button.size.y) * 0.5
	var corners := Vector4(radius, radius, radius, radius)
	if normal != null:
		corners = Vector4(normal.corner_radius_top_left, normal.corner_radius_top_right, normal.corner_radius_bottom_right, normal.corner_radius_bottom_left)
	_material.set_shader_parameter("corner_radii", corners)


## 使用按钮本地坐标，因此高分屏和父级缩放下高光仍以实际鼠标为中心。
func _sync_geometry() -> void:
	_material.set_shader_parameter("panel_size", button.size)
	_sync_pointer()


## 逐帧读取当前鼠标，不插值光点位置，避免快速划过时光点追赶鼠标。
func _sync_pointer() -> void:
	_material.set_shader_parameter("pointer_position", button.get_local_mouse_position())


## 按下时仅使用完整底面高光；松开立即恢复局部光，禁用不产生高光。
func _sync_native_state() -> void:
	if _material == null:
		return
	_refresh_styles()
	var mode := button.get_draw_mode()
	var available := not button.disabled and button.is_visible_in_tree() and _window_active
	var pressed := available and mode in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED]
	var selected := button.toggle_mode and button.button_pressed
	var base: Color = _colors.get("normal", Color.TRANSPARENT)
	# 切换工具的选中底色和蓝色主要操作的按下色均来自原样式，不被白光替换。
	if selected or (pressed and base.s > 0.4 and base.a > 0.0):
		base = _colors.get("pressed", base)
	_material.set_shader_parameter("base_color", base)
	_material.set_shader_parameter("pressed", pressed and not selected)
	_surface.visible = not button.disabled
	if not available:
		_reset()
	elif button.is_hovered():
		_on_mouse_entered()
	else:
		_on_mouse_exited()


## 只有可用按钮进入局部高光，禁用按钮的原生原因提示仍然保留。
func _on_mouse_entered() -> void:
	if not button.disabled and button.is_visible_in_tree() and _window_active:
		_sync_pointer()
		_transition_to(1.0)


## 鼠标移出后从当前亮度淡出，光点仍跟随鼠标且始终裁切在按钮内。
func _on_mouse_exited() -> void:
	_transition_to(0.0)


## 保存当前亮度作为新的起点，快速反向不叠加动画或突然跳亮。
func _transition_to(target: float) -> void:
	if is_equal_approx(_target, target):
		return
	_start_amount = _amount
	_target = target
	_elapsed = 0.0
	_duration = FADE_IN_SECONDS if target > _amount else FADE_OUT_SECONDS
	set_process(true)


## 只在悬停或淡出时更新鼠标和亮度，空闲按钮停止逐帧处理。
func _process(delta: float) -> void:
	if not is_instance_valid(button) or button.disabled or not button.is_visible_in_tree() or not _window_active:
		_reset()
		return
	_sync_pointer()
	_elapsed = minf(_duration, _elapsed + delta)
	var progress := clampf(_elapsed / _duration, 0.0, 1.0)
	var eased := progress * progress * (3.0 - 2.0 * progress)
	_amount = lerpf(_start_amount, _target, eased)
	_material.set_shader_parameter("hover_amount", _amount)
	if progress >= 1.0 and is_zero_approx(_target):
		set_process(false)


## 隐藏页面立即清除残留状态，重新显示时再根据原生状态同步。
func _on_visibility_changed() -> void:
	_sync_native_state()


## 禁用、隐藏及失焦恢复原底色，不改变按钮的实际焦点与功能。
func _reset() -> void:
	_target = 0.0
	_start_amount = 0.0
	_amount = 0.0
	_elapsed = 0.0
	if _material != null:
		_material.set_shader_parameter("hover_amount", 0.0)
		_material.set_shader_parameter("pressed", false)
	set_process(false)


## 普通工具按钮只在键盘操作时显示焦点，鼠标移动或点击不留下蓝色外框。
func _input(event: InputEvent) -> void:
	if not _manage_focus or not button.is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		if not button.get_theme_stylebox("focus") is StyleBoxEmpty:
			button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	elif event is InputEventKey and event.pressed:
		if button.get_theme_stylebox("focus") != _focus_style:
			button.add_theme_stylebox_override("focus", _focus_style)


## 窗口失焦不留下高光；返回窗口后按当前鼠标和原生按钮状态恢复。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_window_active = false
		_reset()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_window_active = true
		if is_node_ready():
			_sync_native_state()
