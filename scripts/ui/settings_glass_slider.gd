class_name SettingsGlassSlider
extends HSlider
## 音量滑条只替换旋钮绘制；数值、命中、拖动、键盘与滚轮仍由原生 HSlider 管理。

const GRABBER_SIZE := Vector2(32, 26)
const REST_SIZE := Vector2(27, 19)
const ACTIVE_SIZE := Vector2(41, 23)
const DRAG_STRETCH_SIZE := Vector2(6, -1.5)
const SHADOW_PADDING := 7.0
const GLASS_SHADER := preload("res://assets/ui/settings_slider_glass.gdshader")

var glass_overlay: Control
var interaction_amount := 0.0:
	set(value):
		interaction_amount = clampf(value, 0.0, 1.0)
		_sync_thumb()
var press_amount := 0.0:
	set(value):
		press_amount = value
		_sync_thumb()
var drag_stretch := 0.0
var _stretch_target := 0.0
var _stretch_velocity := 0.0
var _last_motion_msec := 0
var _dragging := false
var _interaction_tween: Tween
var _pulse_timer: Timer
var _idle: Panel
var _surface: ColorRect
var _backdrop: BackBufferCopy
var _glass_material: ShaderMaterial
var _focus_style: StyleBox
var _keyboard_focus_visible := false
var _glass_root: Control
var _clip_bounds := Rect2(-100000, -100000, 200000, 200000)
var _fade_width := 1.0


## 透明原生纹理保留原有行程与命中几何，矢量旋钮始终在轨道之后绘制。
func _ready() -> void:
	var image := Image.create(int(GRABBER_SIZE.x), int(GRABBER_SIZE.y), false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var spacer := ImageTexture.create_from_image(image)
	for state in ["grabber", "grabber_highlight", "grabber_disabled"]:
		add_theme_icon_override(state, spacer)
	add_theme_constant_override("center_grabber", 0)
	_focus_style = get_theme_stylebox("focus")
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_idle = Panel.new()
	_idle.name = "RestingThumb"
	_idle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var resting := StyleBoxFlat.new()
	resting.bg_color = Color.WHITE
	resting.border_color = Color("CED1D8")
	resting.set_border_width_all(1)
	resting.set_corner_radius_all(10)
	resting.anti_aliasing = true
	resting.shadow_color = Color(0.20, 0.24, 0.30, 0.13)
	resting.shadow_size = 2
	resting.shadow_offset = Vector2(0, 1)
	_idle.add_theme_stylebox_override("panel", resting)
	add_child(_idle)
	# CanvasGroup 内部的 screen_texture 在 Compatibility 返回白色；操作态单独合成。
	_glass_root = Control.new()
	_glass_root.name = String(name) + "GlassLayer"
	_glass_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(glass_overlay if is_instance_valid(glass_overlay) else self).add_child(_glass_root)
	_backdrop = BackBufferCopy.new()
	_backdrop.name = "ThumbBackdrop"
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	_glass_root.add_child(_backdrop)
	_surface = ColorRect.new()
	_surface.name = "LiquidGlassThumb"
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass_material = ShaderMaterial.new()
	_glass_material.shader = GLASS_SHADER
	_surface.material = _glass_material
	_glass_root.add_child(_surface)
	_pulse_timer = Timer.new()
	_pulse_timer.one_shot = true
	_pulse_timer.wait_time = 0.18
	_pulse_timer.timeout.connect(_release_interaction)
	add_child(_pulse_timer)
	drag_started.connect(_begin_drag)
	drag_ended.connect(_end_drag)
	value_changed.connect(_on_value_changed)
	resized.connect(_sync_thumb)
	focus_exited.connect(_reset_interaction)
	set_notify_transform(true)
	_sync_thumb()
	set_process(false)


## 与 center_grabber=false 的原生行程一致；放大只改变视觉，边界值不会移动输入映射。
func get_thumb_rect() -> Rect2:
	var fraction := 1.0 - ratio if is_layout_rtl() else ratio
	var center := Vector2(GRABBER_SIZE.x * 0.5 + maxf(size.x - GRABBER_SIZE.x, 0.0) * fraction, size.y * 0.5)
	# 横向增长大于纵向，快速拖动进一步拉长；原生中心与数值没有跟随延迟。
	var dimensions := REST_SIZE.lerp(ACTIVE_SIZE, press_amount) + DRAG_STRETCH_SIZE * clampf(drag_stretch, 0.0, 1.0)
	return Rect2(center - dimensions * 0.5, dimensions)


## 外层提供与设置正文完全相同的视口边界；浮动玻璃随滚动一起裁剪和透明渐隐。
func set_glass_clip(bounds: Rect2, fade_width: float) -> void:
	_clip_bounds = bounds
	_fade_width = maxf(fade_width, 1.0)
	_sync_thumb()


## 空闲关闭屏幕复制；操作中只复制旋钮及折射余量，避免每帧复制整个高分屏。
func _sync_thumb() -> void:
	if not is_instance_valid(_surface):
		return
	var bounds := get_thumb_rect()
	var active := (interaction_amount > 0.0001 or absf(press_amount) > 0.001 or drag_stretch > 0.002) and is_visible_in_tree()
	if is_instance_valid(glass_overlay):
		var transform_to_overlay := glass_overlay.get_global_transform().affine_inverse() * get_global_transform()
		_glass_root.position = transform_to_overlay.origin
		_glass_root.scale = transform_to_overlay.get_scale()
	_idle.position = bounds.position
	_idle.size = bounds.size
	_idle.visible = not active
	_idle.modulate.a = 1.0 if editable else 0.45
	_surface.visible = active
	_surface.position = bounds.position - Vector2.ONE * SHADOW_PADDING
	_surface.size = bounds.size + Vector2.ONE * SHADOW_PADDING * 2.0
	_backdrop.rect = Rect2(_surface.position, _surface.size).grow(4.0)
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_RECT if active else BackBufferCopy.COPY_MODE_DISABLED
	_glass_material.set_shader_parameter("thumb_size", bounds.size)
	_glass_material.set_shader_parameter("interaction", interaction_amount)
	_glass_material.set_shader_parameter("shadow_padding", SHADOW_PADDING)
	_glass_material.set_shader_parameter("clip_bounds", Vector4(_clip_bounds.position.x, _clip_bounds.position.y, _clip_bounds.end.x, _clip_bounds.end.y))
	_glass_material.set_shader_parameter("fade_width", _fade_width)
	_glass_material.set_shader_parameter("viewport_size", get_viewport().get_visible_rect().size)


## 外部无信号同步也会触发原生重绘；隐藏、禁用和失焦时不保留半透明旋钮。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW:
		if not editable and interaction_amount > 0.0:
			_reset_interaction()
		_sync_thumb()
	elif what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_sync_thumb()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()):
		_reset_interaction()


## 不拦截任何原生输入；仅真实调整手势激活材质，悬停和程序改值保持白色。
func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	if event is InputEventMouseMotion and _dragging:
		var now := Time.get_ticks_msec()
		var seconds := maxf(float(now - _last_motion_msec) / 1000.0, 1.0 / 240.0)
		_stretch_target = clampf(absf(event.relative.x) / seconds / 1100.0, 0.0, 1.0)
		_last_motion_msec = now
	elif event is InputEventMouseButton and event.pressed and scrollable and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_pulse_interaction()
	elif event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		for action in ["ui_left", "ui_right", "ui_home", "ui_end"]:
			if event.is_action_pressed(action, true):
				_pulse_interaction()
				break


## 鼠标操作不留下焦点边框，键盘导航继续显示原生焦点提示。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _focus_style == null:
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion or event is InputEventScreenTouch:
		if _keyboard_focus_visible:
			_keyboard_focus_visible = false
			add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	elif event is InputEventKey and event.pressed:
		if not _keyboard_focus_visible:
			_keyboard_focus_visible = true
			add_theme_stylebox_override("focus", _focus_style)


## 按住时保持玻璃态，暂停移动不会提前收回。
func _begin_drag() -> void:
	_dragging = true
	_last_motion_msec = Time.get_ticks_msec()
	_pulse_timer.stop()
	_animate_interaction(1.0)


## 松开后平滑回到白色胶囊，不干预现有音量试听和设置保存信号。
func _end_drag(_changed: bool) -> void:
	_dragging = false
	_stretch_target = 0.0
	_release_interaction()


## 键盘或滚轮采用短暂激活，每次连续输入延后收回时机。
func _pulse_interaction() -> void:
	_animate_interaction(1.0)
	_pulse_timer.start()


## 已结束的交互从当前形态连续收回，防止快速重复操作导致跳变。
func _release_interaction() -> void:
	if not _dragging:
		_animate_interaction(0.0)


## 动画只改材质和旋钮外形，行高、轨道与设置值保持稳定。
func _animate_interaction(target: float) -> void:
	if _interaction_tween != null:
		_interaction_tween.kill()
	_interaction_tween = create_tween()
	_interaction_tween.set_parallel(true)
	_interaction_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_interaction_tween.tween_property(self, "interaction_amount", target, 0.14 if target > 0.0 else 0.24)
	# 轮廓与材质分别补间：轻微越过目标再回弹，避免整块等比放大的僵硬感。
	_interaction_tween.tween_property(self, "press_amount", target, 0.24 if target > 0.0 else 0.30).set_trans(Tween.TRANS_BACK)
	set_process(true)


## 活动期间同步禁用状态；静止后停用逐帧回调，不持续占用渲染和 CPU。
func _process(delta: float) -> void:
	if not editable:
		_reset_interaction()
		return
	# 停止移动后回到按住时的形状；用解析阻尼弹簧避免低帧率或窗口切换产生爆振。
	if not _dragging or Time.get_ticks_msec() - _last_motion_msec > 50:
		_stretch_target = 0.0
	var elapsed := minf(delta, 0.1)
	var offset := drag_stretch - _stretch_target
	var spring := _stretch_velocity + 20.0 * offset
	var decay := exp(-20.0 * elapsed)
	drag_stretch = _stretch_target + (offset + spring * elapsed) * decay
	_stretch_velocity = (_stretch_velocity - 20.0 * spring * elapsed) * decay
	if not _dragging and interaction_amount <= 0.0001 and absf(press_amount) < 0.001 and drag_stretch < 0.002 and absf(_stretch_velocity) < 0.01 and _pulse_timer.is_stopped():
		interaction_amount = 0.0
		press_amount = 0.0
		drag_stretch = 0.0
		set_process(false)
	else:
		_sync_thumb()


## 保留原生值更新路径，同一帧把玻璃移动到新的旋钮位置。
func _on_value_changed(_value: float) -> void:
	_sync_thumb()


## 页面离开、焦点丢失或销毁会立即清理动画和屏幕复制，返回时从空闲状态开始。
func _reset_interaction() -> void:
	_dragging = false
	_stretch_target = 0.0
	_stretch_velocity = 0.0
	drag_stretch = 0.0
	if _interaction_tween != null:
		_interaction_tween.kill()
		_interaction_tween = null
	if is_instance_valid(_pulse_timer):
		_pulse_timer.stop()
	interaction_amount = 0.0
	press_amount = 0.0
	set_process(false)


## 清理未结束的补间，避免删除页面后仍访问旋钮子节点。
func _exit_tree() -> void:
	_reset_interaction()
	if is_instance_valid(_glass_root) and _glass_root.get_parent() != self:
		_glass_root.queue_free()
