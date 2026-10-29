class_name EditorPageSwitch
extends Control
## 属性卡顶部的两段切换只提交页面意图；玻璃滑块与排版不持有编辑文档。

signal page_requested(index: int)

const GLASS_SHADER := preload("res://assets/ui/settings_switch_glass.gdshader")
const BASE_HEIGHT := 32.0
const BASE_FONT_SIZE := 14
const SHADOW_PADDING := 7.0
const SPRING_STIFFNESS := 500.0
const SPRING_DAMPING := 32.0

var edit_button: Button
var guide_button: Button
# 当前设置没有减少动态效果选项；保留独立开关，外层将来可直接同步偏好。
var reduce_motion := false:
	set(value):
		reduce_motion = value
		if value and is_node_ready():
			_reset_motion()

var _buttons: Array[Button] = []
var _labels: Array[Label] = []
var _group := ButtonGroup.new()
var _backdrop: BackBufferCopy
var _glass: ColorRect
var _glass_material: ShaderMaterial
var _page := 0
var _visual_progress := 0.0
var _velocity := 0.0
var _interaction := 0.0
var _pointer_held := false
var _dragging := false
var _press_position := Vector2.ZERO
var _previous_pointer := Vector2.ZERO
var _drag_stretch := 0.0
var _keyboard_focus := false
var _minimum_height := BASE_HEIGHT
var _layout_queued := false


## 在加入场景之前就提供两个原生按钮，外层可以立即绑定或配置稳定接口。
func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS
	_backdrop = BackBufferCopy.new()
	_backdrop.name = "MapEditorPageBackdrop"
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	add_child(_backdrop)
	_glass = ColorRect.new()
	_glass.name = "MapEditorPageGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass_material = ShaderMaterial.new()
	_glass_material.shader = GLASS_SHADER
	_glass.material = _glass_material
	_glass.hide()
	add_child(_glass)
	edit_button = _make_button("MapEditorEditTab", "编辑", 0)
	guide_button = _make_button("MapEditorGuideTab", "指引", 1)
	_sync_button_state()


## 原生按钮负责焦点及辅助功能文案，内部标签负责完整换行而不撑宽父容器。
func _make_button(node_name: String, caption: String, index: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.tooltip_text = caption
	button.toggle_mode = true
	button.button_group = _group
	button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	button.clip_text = true
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	GameTheme.font_size(button, "font_size", BASE_FONT_SIZE)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	# Button 仍保存真实名称；仅它自己的单行字形透明，由下方完整标签负责呈现。
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color", "font_outline_color"]:
		button.add_theme_color_override(state, Color.TRANSPARENT)
	button.pressed.connect(_request_page.bind(index))
	button.gui_input.connect(_on_button_gui_input.bind(index))
	button.focus_entered.connect(queue_redraw)
	button.focus_exited.connect(queue_redraw)
	button.theme_changed.connect(_queue_layout)
	add_child(button)
	var label := Label.new()
	label.name = node_name + "Label"
	label.text = caption
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	GameTheme.font_size(label, "font_size", BASE_FONT_SIZE)
	label.theme_changed.connect(_queue_layout)
	button.add_child(label)
	_buttons.append(button)
	_labels.append(label)
	return button


## 初次显示按实际可用宽度和当前字号排版；空闲时不保留动画处理。
func _ready() -> void:
	resized.connect(_queue_layout)
	set_notify_transform(true)
	set_process(false)
	_queue_layout()


## 最小宽度不传播标签长度，只有完整文案所需高度参与外层容器排版。
func _get_minimum_size() -> Vector2:
	return Vector2(0, _minimum_height)


## 外层回填只更新选中态；动画保留当前速度，快速反向不会跳到上一端点。
func set_page(index: int, animated: bool = true) -> void:
	_page = clampi(index, 0, 1)
	_sync_button_state()
	if not animated or reduce_motion or not is_inside_tree() or not is_visible_in_tree():
		_reset_motion()
	else:
		_interaction = maxf(_interaction, 0.45)
		set_process(true)
		_sync_glass()
	queue_redraw()


## 提供当前页面索引，测试与外层同步不必读取滑块的动画中间位置。
func get_page() -> int:
	return _page


## 只对真正改变的选择发出一次信号，点击已选页仍保留原来的明确选中态。
func _request_page(index: int) -> void:
	var changed := _page != index
	set_page(index)
	if changed:
		page_requested.emit(_page)


## 用原生按钮的无信号选中态表达单选，文字统一使用深灰而不引入蓝色焦点框。
func _sync_button_state() -> void:
	for index in _buttons.size():
		_buttons[index].set_pressed_no_signal(index == _page)
		_labels[index].add_theme_color_override("font_color", Color("30343A") if index == _page else Color("727780"))


## 合并字号、翻译和容器尺寸通知，避免在容器布局期间反复递归测量。
func _queue_layout() -> void:
	if _layout_queued or not is_inside_tree():
		return
	_layout_queued = true
	_layout_content.call_deferred()


## 长标签先缩至原字号八成，再智能换行增高，任何语言都不省略或横向撑宽。
func _layout_content() -> void:
	_layout_queued = false
	if not is_inside_tree() or _labels.size() != 2:
		return
	var half_width := maxf(size.x * 0.5, 1.0)
	var text_width := maxf(half_width - 16.0, 1.0)
	var required_height := BASE_HEIGHT
	for label in _labels:
		var nominal := maxi(1, roundi(GameTheme.base_font_size(label, "font_size") * GameTheme.font_scale(label)))
		var font := label.get_theme_font("font")
		var caption := label.tr(label.text)
		var natural_width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, nominal).x
		var fitted := clampi(floori(nominal * text_width / maxf(natural_width, 1.0)), ceili(nominal * 0.8), nominal)
		if label.get_theme_font_size("font_size") != fitted:
			label.add_theme_font_size_override("font_size", fitted)
		var text_size := font.get_multiline_string_size(caption, HORIZONTAL_ALIGNMENT_CENTER, text_width, fitted, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
		# Label 的实际最小高度还包含主题行距，不能只用 Font 的紧密文字度量。
		label.size.x = text_width
		required_height = maxf(required_height, ceilf(maxf(text_size.y, label.get_minimum_size().y)) + 12.0)
	if not is_equal_approx(required_height, _minimum_height):
		_minimum_height = required_height
		update_minimum_size()
	for index in _buttons.size():
		var visual_index := 1 - index if is_layout_rtl() else index
		_buttons[index].position = Vector2(half_width * visual_index, 0)
		_buttons[index].size = Vector2(half_width, maxf(size.y, _minimum_height))
		_labels[index].position = Vector2(8, 4)
		_labels[index].size = Vector2(text_width, maxf(size.y, _minimum_height) - 8.0)
	_sync_glass()
	queue_redraw()


## 滑块位置按实际控件尺寸计算，交互与运动速度只改变外观，不改变点击区域。
func _thumb_rect() -> Rect2:
	var base := Vector2(maxf((size.x - 6.0) * 0.5, 1.0), maxf(size.y - 6.0, 1.0))
	var stretch := (minf(base.x * 0.075, 8.0) + minf(absf(_velocity), 4.0) + _drag_stretch * 3.0) * _interaction
	var dimensions := base + Vector2(stretch, _interaction * 1.5)
	var progress := 1.0 - _visual_progress if is_layout_rtl() else _visual_progress
	var center := Vector2(3.0 + base.x * 0.5 + base.x * progress, size.y * 0.5)
	center.x = clampf(center.x, dimensions.x * 0.5 + 1.5, maxf(dimensions.x * 0.5 + 1.5, size.x - dimensions.x * 0.5 - 1.5))
	return Rect2(center - dimensions * 0.5, dimensions)


## 浅灰轨道与静止白滑块使用矢量样式，键盘提示为中性灰细线，鼠标不残留描边。
func _draw() -> void:
	var track := GameTheme.box(Color("EAECF0"), Color(0.70, 0.73, 0.78, 0.12), roundi(size.y * 0.5))
	draw_style_box(track, Rect2(Vector2.ZERO, size))
	if _interaction <= 0.0001 or reduce_motion:
		var thumb := GameTheme.box(Color.WHITE, Color(1, 1, 1, 0.88), roundi(maxf(size.y - 6.0, 1.0) * 0.5))
		thumb.shadow_color = Color(0.17, 0.20, 0.27, 0.13)
		thumb.shadow_size = 3
		thumb.shadow_offset = Vector2(0, 1)
		draw_style_box(thumb, _thumb_rect())
	if _keyboard_focus:
		for button in _buttons:
			if button.has_focus():
				var focus := GameTheme.box(Color.TRANSPARENT, Color(0.42, 0.46, 0.52, 0.55), roundi(size.y * 0.5))
				draw_style_box(focus, Rect2(button.position + Vector2(2, 2), button.size - Vector2(4, 4)))


## 保留原生点击与键盘激活；方向键直接移动到相邻页，并把焦点交给对应标签。
func _on_button_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_pointer_held = true
		_dragging = false
		_press_position = _buttons[index].position + event.position
		_previous_pointer = _press_position
		if not reduce_motion:
			set_process(true)
	elif event is InputEventKey and event.pressed and not event.is_echo():
		if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
			var direction := -1 if event.is_action_pressed("ui_left") else 1
			if is_layout_rtl():
				direction = -direction
			var target := clampi(index + direction, 0, 1)
			_buttons[target].grab_focus()
			_request_page(target)
			_buttons[index].accept_event()


## 拖动跨越按钮边界仍跟随同一手势，松开只吸附最近页，不依赖鼠标仍停在原按钮。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed:
		_keyboard_focus = true
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_focus = false
		queue_redraw()
	if not _pointer_held:
		return
	if event is InputEventMouseMotion:
		var pointer: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		_dragging = _dragging or absf(pointer.x - _press_position.x) > 3.0
		if _dragging:
			var travel := maxf((size.x - 6.0) * 0.5, 1.0)
			var progress := clampf((pointer.x - 3.0 - travel * 0.5) / travel, 0.0, 1.0)
			_visual_progress = 1.0 - progress if is_layout_rtl() else progress
			_velocity = 0.0
			_drag_stretch = minf(absf(pointer.x - _previous_pointer.x) / 12.0, 1.0)
			_sync_glass()
			queue_redraw()
		_previous_pointer = pointer
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_pointer_held = false
		if _dragging:
			_dragging = false
			_request_page(1 if _visual_progress >= 0.5 else 0)
		elif not reduce_motion:
			set_process(true)


## 弹簧采用小步积分，快速反向、低帧率或拖动松开均连续回弹，不重新开始旧动画。
func _process(delta: float) -> void:
	if reduce_motion or not is_visible_in_tree():
		_reset_motion()
		return
	var remaining := minf(delta, 0.1)
	while remaining > 0.000001:
		var step := minf(remaining, 1.0 / 120.0)
		if not _dragging:
			_velocity += ((float(_page) - _visual_progress) * SPRING_STIFFNESS - _velocity * SPRING_DAMPING) * step
			_visual_progress += _velocity * step
		_interaction = lerpf(_interaction, 1.0 if _pointer_held else 0.0, 1.0 - exp(-step * 16.0))
		_drag_stretch = move_toward(_drag_stretch, 0.0, step * 5.0)
		remaining -= step
	if not _dragging and absf(_visual_progress - _page) < 0.0005 and absf(_velocity) < 0.005:
		_visual_progress = float(_page)
		_velocity = 0.0
	if not _pointer_held and _interaction < 0.001:
		_interaction = 0.0
	_sync_glass()
	queue_redraw()
	if not _pointer_held and _interaction == 0.0 and _velocity == 0.0:
		set_process(false)


## 玻璃位于轨道之后、文字之前，仅活动期间局部复制轨道，复用现有折射与边缘高光材质。
func _sync_glass() -> void:
	if not is_instance_valid(_glass):
		return
	var active := _interaction > 0.0001 and not reduce_motion and is_visible_in_tree()
	_glass.visible = active
	if not active:
		_backdrop.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
		return
	var rect := _thumb_rect()
	_glass.position = rect.position - Vector2.ONE * SHADOW_PADDING
	_glass.size = rect.size + Vector2.ONE * SHADOW_PADDING * 2.0
	# BackBufferCopy 的矩形由渲染器按目标像素直接读取，不随节点的局部变换移动。
	# 同时包含视口缩放和页面变换，避免只复制左上角、让实际滑块采到未写入的黑色区域。
	var to_viewport := get_viewport_transform() * get_global_transform()
	var copy_bounds: Rect2 = to_viewport * Rect2(_glass.position, _glass.size).grow(4.0)
	var copy_origin := copy_bounds.position.floor()
	_backdrop.rect = Rect2(copy_origin, copy_bounds.end.ceil() - copy_origin)
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_RECT
	_glass_material.set_shader_parameter("thumb_size", rect.size)
	_glass_material.set_shader_parameter("interaction", _interaction)
	_glass_material.set_shader_parameter("shadow_padding", SHADOW_PADDING)


## 隐藏、失焦与减少动态效果时立即停止手势，恢复已经确认的页面而不发送新请求。
func _reset_motion() -> void:
	_pointer_held = false
	_dragging = false
	_visual_progress = float(_page)
	_velocity = 0.0
	_interaction = 0.0
	_drag_stretch = 0.0
	set_process(false)
	_sync_glass()
	queue_redraw()


## 翻译或主题变化重新测量完整文字；页面隐藏和系统失焦不能残留按住或屏幕采样状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW or what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_sync_glass()
	elif what in [NOTIFICATION_TRANSLATION_CHANGED, NOTIFICATION_THEME_CHANGED, NOTIFICATION_LAYOUT_DIRECTION_CHANGED]:
		_queue_layout()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_reset_motion()
