class_name SettingsSwitch
extends Button
## 原生 Button 保留开关、键盘与保存语义；只为旋钮添加可逆的弹性玻璃过渡。

const GLASS_SHADER := preload("res://assets/ui/settings_switch_glass.gdshader")
const SHADOW_PADDING := 7.0
const SPRING_STIFFNESS := 430.0
const SPRING_DAMPING := 31.0

var interaction_amount := 0.0:
	set(value):
		interaction_amount = clampf(value, 0.0, 1.0)
		queue_redraw()
var thumb_progress := 0.0
var _keyboard_focus := false
var _held := false
var _user_gesture := false
var _target_progress := 0.0
var _thumb_velocity := 0.0
var _interaction_tween: Tween
var _glass_root: Control
var _surface: ColorRect
var _backdrop: BackBufferCopy
var _glass_material: ShaderMaterial
var _glass_host: Node


## 固定输入区域，透明主题不覆盖原生 Button 的切换、禁用或辅助功能行为。
func _init() -> void:
	toggle_mode = true
	custom_minimum_size = Vector2(52, 32)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	toggled.connect(_refresh_switch)
	button_down.connect(_begin_interaction)
	button_up.connect(_end_interaction)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(_reset_interaction)


## 初次挂入时同步无信号初始值；延后创建外部层，避免容器正在挂载子节点时改动父树。
func _ready() -> void:
	_target_progress = 1.0 if button_pressed else 0.0
	thumb_progress = _target_progress
	set_notify_transform(true)
	set_process(false)
	_prepare_glass.call_deferred()


## 玻璃必须位于最外侧 CanvasGroup 之后，避免 Compatibility 把组内屏幕采样读成白色。
func _prepare_glass() -> void:
	if not is_inside_tree() or is_instance_valid(_glass_root):
		return
	var outer_group: CanvasGroup
	var ancestor := get_parent()
	while ancestor != null and not ancestor is Viewport and not ancestor is CanvasLayer:
		if ancestor is CanvasGroup:
			outer_group = ancestor
		ancestor = ancestor.get_parent()
	_glass_host = outer_group.get_parent() if is_instance_valid(outer_group) else self
	if not is_instance_valid(_glass_host):
		_glass_host = self
	_glass_root = Control.new()
	_glass_root.name = String(name) + "SwitchGlassLayer"
	_glass_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass_host.add_child(_glass_root)
	if is_instance_valid(outer_group) and _glass_host == outer_group.get_parent():
		_glass_host.move_child(_glass_root, outer_group.get_index() + 1)
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
	_sync_glass()
	queue_redraw()


## 区分最近的输入方式；鼠标不留下焦点环，键盘导航继续显示当前位置。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var keyboard := _keyboard_focus
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		keyboard = false
	elif event is InputEventKey and event.pressed:
		keyboard = true
	else:
		return
	if keyboard != _keyboard_focus:
		_keyboard_focus = keyboard
		queue_redraw()


## 只有真实按住手势启用玻璃；程序同步或悬停不会触发动画。
func _begin_interaction() -> void:
	if disabled or not is_visible_in_tree():
		return
	_held = true
	_user_gesture = true
	_animate_interaction(1.0, 0.14)


## 先让原生按钮决定是否切换，拖出后释放的取消行为仍由 Button 自己处理。
func _end_interaction() -> void:
	_held = false
	_release_interaction.call_deferred()


## 松开后从当前拉伸连续收回；快速再次按住不会被上一手势的延迟回调打断。
func _release_interaction() -> void:
	if not _held and is_inside_tree():
		_animate_interaction(0.0, 0.30)


## 用户切换保留弹簧速度以便反向；数据回填直接同步，不产生额外切换信号。
func _refresh_switch(pressed: bool) -> void:
	_target_progress = 1.0 if pressed else 0.0
	if _user_gesture and not disabled:
		set_process(true)
	else:
		thumb_progress = _target_progress
		_thumb_velocity = 0.0
	queue_redraw()


## 按下时横向延长多于纵向扩张，滑动的速度只增强形变，不影响固定命中区域。
func get_thumb_rect() -> Rect2:
	var track := Rect2(Vector2(2, 2), size - Vector2(4, 4))
	var diameter := maxf(1.0, track.size.y - 6.0)
	var progress := 1.0 - thumb_progress if is_layout_rtl() else thumb_progress
	var left_center := track.position.x + 3.0 + diameter * 0.5
	var right_center := track.end.x - 3.0 - diameter * 0.5
	var center := Vector2(lerpf(left_center, right_center, progress), size.y * 0.5)
	var motion_stretch := minf(absf(_thumb_velocity) / 5.0, 1.0) * 3.0
	var dimensions := Vector2(diameter + (10.0 + motion_stretch) * interaction_amount, diameter + 4.0 * interaction_amount)
	return Rect2(center - dimensions * 0.5, dimensions)


## 轨道保持矢量清晰；白色静态旋钮在原合成层内，自然继承全部滚动裁剪与透明度。
func _draw() -> void:
	var tint := Color("BCC2CC").lerp(Color("007AFF"), clampf(thumb_progress, 0.0, 1.0))
	if is_hovered():
		tint = tint.lightened(0.06)
	if disabled:
		tint = Color("BCC2CC")
		tint.a = 0.45
	draw_style_box(GameTheme.box(tint, Color.TRANSPARENT, 16), Rect2(Vector2(2, 2), size - Vector2(4, 4)))
	if interaction_amount <= 0.0001 or not is_instance_valid(_surface) or disabled:
		var thumb := GameTheme.box(Color("E7E9ED") if disabled else Color.WHITE, Color(1, 1, 1, 0.7), 16)
		thumb.shadow_color = Color(0.05, 0.10, 0.20, 0.13)
		thumb.shadow_size = 2
		thumb.shadow_offset = Vector2(0, 1)
		draw_style_box(thumb, get_thumb_rect())
	if has_focus() and _keyboard_focus:
		draw_style_box(GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 18), Rect2(Vector2.ZERO, size))


## 原生无信号回填也会请求重绘；禁用、隐藏和窗口失焦立即恢复对应开关状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW:
		var expected := 1.0 if button_pressed else 0.0
		if _target_progress != expected or disabled and interaction_amount > 0.0:
			_reset_interaction()
		_sync_glass()
	elif what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_sync_glass()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_reset_interaction()


## 动画只修改旋钮外观；重复按下会从当前透明度起步，不重建控件或写入设置。
func _animate_interaction(target: float, duration: float) -> void:
	if _interaction_tween != null:
		_interaction_tween.kill()
	_interaction_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_interaction_tween.tween_property(self, "interaction_amount", target, duration)
	set_process(true)


## 分小步计算轻微回弹，使低帧率与高分屏下的快速反向操作保持稳定。
func _process(delta: float) -> void:
	if disabled or not is_visible_in_tree():
		_reset_interaction()
		return
	var remaining := minf(delta, 0.1)
	while remaining > 0.000001:
		var step := minf(remaining, 1.0 / 120.0)
		_thumb_velocity += ((_target_progress - thumb_progress) * SPRING_STIFFNESS - _thumb_velocity * SPRING_DAMPING) * step
		thumb_progress += _thumb_velocity * step
		remaining -= step
	if absf(thumb_progress - _target_progress) < 0.0005 and absf(_thumb_velocity) < 0.005:
		thumb_progress = _target_progress
		_thumb_velocity = 0.0
	_sync_glass()
	queue_redraw()
	if not _held and interaction_amount <= 0.0001 and _thumb_velocity == 0.0:
		interaction_amount = 0.0
		_user_gesture = false
		set_process(false)


## 外部玻璃层复制所有中间祖先的透明度与可视边界，避免滚动后漂浮到卡片之外。
func _sync_glass() -> void:
	if not is_instance_valid(_surface) or not is_inside_tree():
		return
	var active := interaction_amount > 0.0001 and not disabled and is_visible_in_tree()
	_glass_root.visible = active
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_RECT if active else BackBufferCopy.COPY_MODE_DISABLED
	if not active:
		return
	var host_transform: Transform2D = _glass_host.get_global_transform() if _glass_host is CanvasItem else Transform2D.IDENTITY
	var to_host := host_transform.affine_inverse() * get_global_transform()
	_glass_root.position = to_host.origin
	_glass_root.scale = to_host.get_scale()
	_glass_root.rotation = to_host.get_rotation()
	var inherited := self_modulate
	var ancestor: Node = self
	var clip := Rect2(-100000.0, -100000.0, 200000.0, 200000.0)
	var fade_bounds := PackedVector4Array()
	var fade_data := PackedVector4Array()
	while ancestor != null and not ancestor is Viewport and not ancestor is CanvasLayer:
		if ancestor is CanvasItem and ancestor != _glass_host and _glass_host.is_ancestor_of(ancestor):
			inherited *= ancestor.modulate
		if ancestor is Control and ancestor.clip_contents:
			var rect: Rect2 = ancestor.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, ancestor.size)
			clip = clip.intersection(rect)
		if ancestor is SettingsContentFade:
			var parameters: Vector4 = ancestor.get("_fade_parameters")
			fade_bounds.append(Vector4(-100000.0, parameters.x, 100000.0, parameters.w if parameters.w >= 0.0 else 100000.0))
			fade_data.append(Vector4(parameters.y, parameters.y, 1.0, 1.0 if parameters.w >= 0.0 else 0.0))
		elif ancestor is ScrollContentFade:
			_append_scroll_fade(ancestor, fade_bounds, fade_data)
		ancestor = ancestor.get_parent()
	_glass_root.modulate = inherited
	var bounds := get_thumb_rect()
	_surface.position = bounds.position - Vector2.ONE * SHADOW_PADDING
	_surface.size = bounds.size + Vector2.ONE * SHADOW_PADDING * 2.0
	_backdrop.rect = Rect2(_surface.position, _surface.size).grow(4.0)
	_glass_material.set_shader_parameter("thumb_size", bounds.size)
	_glass_material.set_shader_parameter("interaction", interaction_amount)
	_glass_material.set_shader_parameter("shadow_padding", SHADOW_PADDING)
	_glass_material.set_shader_parameter("clip_bounds", Vector4(clip.position.x, clip.position.y, clip.end.x, clip.end.y))
	_glass_material.set_shader_parameter("fade_count", mini(fade_bounds.size(), 4))
	fade_bounds.resize(4)
	fade_data.resize(4)
	_glass_material.set_shader_parameter("fade_bounds", fade_bounds)
	_glass_material.set_shader_parameter("fade_data", fade_data)
	_glass_material.set_shader_parameter("viewport_size", get_viewport().get_visible_rect().size)


## 编辑器淡隐只在仍有内容的边缘启用，使用原组的参数而非猜测滚动距离。
func _append_scroll_fade(fade: ScrollContentFade, bounds: PackedVector4Array, data: PackedVector4Array) -> void:
	var group := fade.get("_group") as CanvasGroup
	var material := group.material as ShaderMaterial
	var content_size: Vector2 = material.get_shader_parameter("content_size")
	var strength: Vector2 = material.get_shader_parameter("edge_strength")
	var width := minf(ScrollContentFade.FADE_WIDTH, content_size.y * 0.25)
	var transform := group.get_global_transform_with_canvas()
	var origin := transform * Vector2.ZERO
	var end := transform * content_size
	bounds.append(Vector4(-100000.0, origin.y, end.x, end.y))
	var scaled_width := maxf(width, 1.0) * absf(transform.get_scale().y)
	data.append(Vector4(scaled_width, scaled_width, strength.x, strength.y))


## 失焦、隐藏或锁定立即清理动画；无信号同步得到准确静态值且不会产生新信号。
func _reset_interaction() -> void:
	_held = false
	_user_gesture = false
	if _interaction_tween != null:
		_interaction_tween.kill()
		_interaction_tween = null
	interaction_amount = 0.0
	_target_progress = 1.0 if button_pressed else 0.0
	thumb_progress = _target_progress
	_thumb_velocity = 0.0
	set_process(false)
	_sync_glass()
	queue_redraw()


## 外部层跟随所属开关释放，避免切页后残留屏幕复制或悬浮旋钮。
func _exit_tree() -> void:
	_reset_interaction()
	if is_instance_valid(_glass_root) and _glass_root.get_parent() != self:
		_glass_root.queue_free()
