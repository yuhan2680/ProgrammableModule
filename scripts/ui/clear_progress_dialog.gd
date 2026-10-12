class_name ClearProgressDialog
extends CanvasLayer
## 清除预设进度优先使用系统询问；后备浮层只负责呈现，不读取或写入玩家存档。

signal confirmed
signal canceled

const WARNING_BODY := "此选项将会清除全部系统自带关卡的通关记录、代码和装配草稿。一旦清除，不可恢复。"

var use_native_dialog := true
var native_dialog_handler: Callable
var _native_active := false
var _request_generation := 0
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _heading: HBoxContainer
var _body: Label
var _confirm: Button
var _cancel: Button
var _anchor: Control
var _open := false
var _tween: Tween
var _layout_scale := 1.0
var _opening_progress := 1.0


## 构建一体圆角玻璃面和输入屏障，正文及按钮不再额外绘制卡片背景。
func _ready() -> void:
	layer = 100
	_overlay = Control.new()
	_overlay.name = "ClearProgressOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	var dimmer := ColorRect.new()
	dimmer.color = Color(0.13, 0.16, 0.22, 0.055)
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = Panel.new()
	_panel.name = "ClearProgressPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1, 0.82), Color(1, 1, 1, 0.9), 48)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.11, 0.15, 0.24, 0.16)
	surface.shadow_size = 16
	surface.shadow_offset = Vector2(0, 7)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_heading = HBoxContainer.new()
	_heading.alignment = BoxContainer.ALIGNMENT_CENTER
	_heading.add_theme_constant_override("separation", 10)
	_panel.add_child(_heading)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/ui/progress_warning.svg")
	icon.custom_minimum_size = Vector2(84, 84)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_heading.add_child(icon)
	var title := GameTheme.label(_heading, "警告", 25)
	title.name = "ClearProgressTitle"
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var title_font := GameTheme.body_font().duplicate() as FontVariation
	title_font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 650.0}
	title.add_theme_font_override("font", title_font)
	_body = GameTheme.label(_panel, WARNING_BODY, 16)
	_body.name = "ClearProgressBody"
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_theme_constant_override("line_spacing", 5)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.minimum_size_changed.connect(_on_body_minimum_size_changed)
	_confirm = _create_action("ConfirmClearProgressButton", "清除", true)
	_cancel = _create_action("CancelClearProgressButton", "取消", false)
	_confirm.pressed.connect(_confirm_clear)
	_cancel.pressed.connect(_cancel_requested)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 两个按钮分别表达确认和取消；清除使用橙色强调，不将确认设为默认焦点。
func _create_action(node_name: String, caption: String, destructive: bool) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	GameTheme.font_size(button, "font_size", 17)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var tint := Color("EA9627") if destructive else Color("EAEDF1")
		if state == "hover":
			tint = Color("F3A233") if destructive else Color("E1E6EC")
		elif state in ["pressed", "hover_pressed"]:
			tint = Color("D9861F") if destructive else Color("D7DEE7")
		elif state == "focus":
			tint = Color.TRANSPARENT
		var style := GameTheme.box(tint, Color("C4CBD5") if state == "focus" else Color.TRANSPARENT, 24)
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE if destructive else GameTheme.TEXT)
	_panel.add_child(button)
	return button


## 每次打开都先聚焦取消；入口只用于取消后的焦点恢复，不暗示用户已确认清除。
func popup_dialog(anchor: Control) -> void:
	if _open or not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_body.text = WARNING_BODY
	_open = true
	_request_generation += 1
	_native_active = use_native_dialog and (native_dialog_handler.is_valid() or (OS.get_name() in ["macOS", "Windows"] and DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG)))
	set_process_input(true)
	if _native_active:
		var generation := _request_generation
		var callback := _on_native_choice.bind(generation)
		# 取消作为首项，避免默认回车立即清除记录；只有索引一表示明确确认。
		var buttons := PackedStringArray([tr("取消"), tr("清除")])
		var result: int = native_dialog_handler.call(tr("清除预设进度"), tr(WARNING_BODY), buttons, callback) if native_dialog_handler.is_valid() else DisplayServer.dialog_show(tr("清除预设进度"), tr(WARNING_BODY), buttons, callback)
		if result == OK or generation != _request_generation or not _open:
			return
		# 原生调用失败后旧回调失效，明确选择须来自当前后备浮层。
		_request_generation += 1
		_native_active = false
	_opening_progress = 0.0
	_overlay.show()
	_update_placement()
	# 首次宽度赋值后，自动换行会重新计算最小高度；下一次布局消除旧高度造成的撑高。
	_update_placement.call_deferred()
	set_process_input(true)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_panel.pivot_offset = _panel.size * 0.5
	_panel.modulate.a = 0
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_apply_opening_progress, 0.0, 1.0, 0.18)
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.14)
	_cancel.grab_focus()


## 弹出动画只改变相对幅度，白卡的基础比例和手动字号始终分别处理。
func _apply_opening_progress(progress: float) -> void:
	_opening_progress = progress
	_panel.scale = Vector2.ONE * _layout_scale * lerpf(0.97, 1.0, progress)


## 独立画布只取祖先白卡的呈现比例，不能把入口正文的八成缩放重复用于确认窗口。
func _anchor_layout_scale() -> float:
	var ancestor: Node = _anchor
	while is_instance_valid(ancestor):
		if ancestor.has_meta("ui_menu_layout_scale"):
			return maxf(1.0, float(ancestor.get_meta("ui_menu_layout_scale")))
		ancestor = ancestor.get_parent()
	return 1.0


## 取消及页面切换同步释放浮层；只有明确确认函数可以发出清除信号。
func close_dialog(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	_native_active = false
	_request_generation += 1
	set_process_input(false)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 让上层协调页面跳转及其他浮层，不暴露内部控件作为操作接口。
func is_open() -> bool:
	return _open


## 文字按当前语言换行，浮层和按钮居中保持同宽并限制在窗口安全边距内。
func _update_placement() -> void:
	if not _open or _native_active:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_dialog(false)
		return
	var available := get_viewport().get_visible_rect().size
	_layout_scale = _anchor_layout_scale()
	var logical_available := available / _layout_scale
	var width := minf(400, logical_available.x - 32)
	var heading_height := maxf(84, _heading.get_combined_minimum_size().y)
	var body_top := 24 + heading_height + 24
	var confirm_height := maxf(48, _confirm.get_combined_minimum_size().y)
	var cancel_height := maxf(48, _cancel.get_combined_minimum_size().y)
	_body.size.x = width - 64
	# 手动字号提高文字及按钮最小高度时只增加必要空间，基准字号仍保留原来的 400×440。
	var required_height := body_top + _body.get_combined_minimum_size().y + 24 + confirm_height + 10 + cancel_height + 30
	var height := minf(maxf(440, required_height), logical_available.y - 32)
	_panel.size = Vector2(width, height)
	_panel.position = (available - _panel.size) * 0.5
	_panel.pivot_offset = _panel.size * 0.5
	_apply_opening_progress(_opening_progress)
	_glass.position = Vector2.ONE
	_glass.size = _panel.size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size * _layout_scale)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 47.0 * _layout_scale)
	_heading.position = Vector2(28, 24)
	_heading.size = Vector2(width - 56, heading_height)
	_body.position = Vector2(32, body_top)
	var cancel_top := height - 30 - cancel_height
	var confirm_top := cancel_top - 10 - confirm_height
	_body.size = Vector2(width - 64, maxf(0, confirm_top - 24 - _body.position.y))
	_confirm.position = Vector2(28, confirm_top)
	_confirm.size = Vector2(width - 56, confirm_height)
	_cancel.position = Vector2(28, cancel_top)
	_cancel.size = Vector2(width - 56, cancel_height)


## 点击外部和 Esc 都取消；方向键及 Tab 只在两个按钮间移动，其他按键不传给底页。
func _input(event: InputEvent) -> void:
	if not _open:
		return
	if _native_active:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if not _panel.get_global_rect().has_point(mouse.position):
			get_viewport().set_input_as_handled()
			if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_cancel_requested()
			return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel_requested()
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") or event.is_action_pressed("ui_focus_next", false, true) or event.is_action_pressed("ui_focus_prev", false, true):
		get_viewport().set_input_as_handled()
		if _cancel.has_focus():
			_confirm.grab_focus()
		else:
			_cancel.grab_focus()
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		get_viewport().set_input_as_handled()
		if _confirm.has_focus():
			_confirm_clear()
		else:
			_cancel_requested()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()


## 隐藏确认框后只广播一次明确选择，实际清除范围和事务由外层存档服务控制。
func _confirm_clear() -> void:
	if not _open:
		return
	close_dialog(false)
	confirmed.emit()


## 只有用户主动取消才发出取消信号；生命周期关闭仍使用无信号的 close_dialog。
func _cancel_requested() -> void:
	if not _open:
		return
	close_dialog()
	canceled.emit()


## 等待视口完成尺寸变更后重新居中，避免缩放过程中使用上一帧的窗口坐标。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()


## 自动换行的最小高度晚于首次宽度更新，重新应用目标高度以免正文边界延伸到按钮。
func _on_body_minimum_size_changed() -> void:
	if _open:
		_update_placement.call_deferred()


## 本土化切换只重新排版文案，不改变确认状态或默认按钮。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_update_placement.call_deferred()


## 系统窗口回调延后处理，避免在系统模态循环内部修改页面和存档。
func _on_native_choice(index: int, generation: int) -> void:
	_apply_native_choice.call_deferred(index, generation)


## 只消费当前有效请求；导航隐藏、取消、重复及迟到系统响应都不能清除进度。
func _apply_native_choice(index: int, generation: int) -> void:
	if not _open or not _native_active or generation != _request_generation:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		_cancel_requested()
		return
	if index == 1:
		_confirm_clear()
	else:
		_cancel_requested()


## 销毁时作废系统回调，无法把已离开的页面请求重放到新页面。
func _exit_tree() -> void:
	close_dialog(false)
