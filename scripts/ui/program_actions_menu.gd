class_name ProgramActionsMenu
extends CanvasLayer
## 编程操作菜单只发出用户意图，关卡、装配和草稿逻辑由工作台及外层页面处理。

signal help_requested
signal edit_modules_requested
signal reset_requested
signal reset_code_requested
signal save_requested

const MENU_WIDTH := 220.0
const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 8.0
const ROW_HEIGHT := 44.0
const ROW_GAP := 4.0
const DESTRUCTIVE_COLOR := Color("d64646")

var _items: Array[Button] = []
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _separator: ColorRect
var _anchor: Control
var _open := false
var _save_allowed := true
var _tween: Tween
var _origin := Vector2.ZERO
var _reveal_progress := 1.0
var _swallowed_button := MOUSE_BUTTON_NONE


## 在独立画布层绘制玻璃菜单，展开不会挤动编程页工具栏或代码编辑器。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "ProgramActionsOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "ProgramActionsPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1.0, 0.82), Color(1, 1, 1, 0.88), 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "ProgramActionsGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_add_item("ProgramHelpMenuItem", "关卡说明", "res://assets/ui/program_help.svg", 0)
	_add_item("EditModulesButton", "编辑模块", "res://assets/ui/program_edit.svg", 1)
	_add_item("ProgramResetPositionMenuItem", "重置位置", "res://assets/ui/program_reset.svg", 2)
	_separator = ColorRect.new()
	_separator.name = "ProgramResetCodeSeparator"
	_separator.color = Color(0.65, 0.69, 0.76, 0.3)
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_separator)
	_add_item("ResetCodeButton", "重置代码", "res://assets/ui/program_reset_code.svg", 3)
	_add_item("SaveProgramDraftMenuItem", "保存草稿", "res://assets/ui/assembly_save.svg", 4)
	set_save_allowed(_save_allowed)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 保留原生按钮与高清SVG，危险操作在所有文字交互状态下都保持明确红色。
func _add_item(node_name: String, caption: String, icon_path: String, index: int) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	item.icon = load(icon_path)
	item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.expand_icon = true
	item.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	item.add_theme_constant_override("h_separation", 12)
	item.add_theme_constant_override("icon_max_width", 22)
	item.add_theme_font_size_override("font_size", 16)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color", "icon_disabled_color"]:
		item.add_theme_color_override(state, Color.WHITE)
	if index == 3:
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color", "font_outline_color"]:
			item.add_theme_color_override(state, DESTRUCTIVE_COLOR)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color(0.79, 0.87, 0.99, 0.68) if state in ["hover", "focus"] else Color(0.71, 0.82, 0.98, 0.82) if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 10)
		style.set_content_margin_all(10)
		item.add_theme_stylebox_override(state, style)
	item.pressed.connect(_activate.bind(index))
	_panel.add_child(item)
	_items.append(item)


## 从入口下方向下滑入并淡入；再次调用入口时直接关闭同一个菜单。
func popup_at(anchor: Control) -> void:
	if _open:
		close_menu()
		return
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	_overlay.show()
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_reveal_progress = 0.0
	_update_placement()
	set_process_input(true)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_reveal_progress, 0.0, 1.0, 0.18)
	var visible_items := _focusable_items()
	if not visible_items.is_empty():
		visible_items[0].grab_focus()


## 同步隐藏后才返回焦点；外部按下关闭时继续吞掉对应抬起，防止点击穿透。
func close_menu(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_overlay.hide()
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 向页面切换与书本弹窗公开状态，不要求外部读取内部控件。
func is_open() -> bool:
	return _open


## 试玩隐藏保存入口，其他菜单项顺序及索引不受影响。
func set_save_allowed(allowed: bool) -> void:
	_save_allowed = allowed
	if _items.size() < 5:
		return
	var had_focus := _items[4].has_focus()
	_items[4].visible = allowed
	if _open:
		_update_placement()
		if had_focus and not allowed:
			_items[0].grab_focus()


## 只改变菜单位置与透明度，右边缘固定，避免缩放文字造成动画过程模糊。
func _set_reveal_progress(progress: float) -> void:
	_reveal_progress = progress
	_panel.position = _origin + Vector2(0, -8.0 * (1.0 - progress))
	_panel.modulate.a = progress


## 按可见行和翻译后的文字度量计算尺寸，始终贴齐入口右侧并限制在视口内。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var width := MENU_WIDTH
	for item in _items:
		if item.visible:
			width = maxf(width, item.get_combined_minimum_size().x + 32.0)
	width = minf(width, maxf(0, viewport_size.x - EDGE_MARGIN * 2))
	var cursor_y := 8.0
	for index in range(_items.size()):
		var item := _items[index]
		if not item.visible:
			continue
		if index == 3:
			_separator.position = Vector2(18, cursor_y + 2)
			_separator.size = Vector2(width - 36, 1)
			cursor_y += 8
		item.position = Vector2(8, cursor_y)
		item.size = Vector2(width - 16, ROW_HEIGHT)
		cursor_y += ROW_HEIGHT + ROW_GAP
	var menu_size := Vector2(width, cursor_y - ROW_GAP + 8)
	var anchor_rect := _anchor.get_global_rect()
	_origin = Vector2(anchor_rect.end.x - width, anchor_rect.end.y + ANCHOR_GAP)
	_origin.x = clampf(_origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - width - EDGE_MARGIN))
	_origin.y = clampf(_origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	_panel.size = menu_size
	_glass.position = Vector2.ONE
	_glass.size = menu_size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 17.0)
	_set_reveal_progress(_reveal_progress)


## 优先接管关闭和焦点操作，菜单外的鼠标事件不会送到背后编程控件。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if _swallowed_button != MOUSE_BUTTON_NONE and mouse.button_index == _swallowed_button:
			get_viewport().set_input_as_handled()
			if not mouse.pressed:
				_swallowed_button = MOUSE_BUTTON_NONE
				set_process_input(_open)
			return
		if _open and not _panel.get_global_rect().has_point(mouse.position):
			get_viewport().set_input_as_handled()
			if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_swallowed_button = mouse.button_index
				close_menu()
			return
	if not _open:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close_menu()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_focus_next", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(1)
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_focus_prev", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(-1)
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		get_viewport().set_input_as_handled()
		var focused := _items.find(get_viewport().gui_get_focus_owner())
		if focused >= 0:
			_activate(focused)


## 只收集可见且可用的行，试玩时键盘不会进入隐藏的保存入口。
func _focusable_items() -> Array[Button]:
	var result: Array[Button] = []
	for item in _items:
		if item.visible and not item.disabled:
			result.append(item)
	return result


## 在菜单内部循环焦点，Tab与上下方向键都不跳到背景页面。
func _move_focus(direction: int) -> void:
	var visible_items := _focusable_items()
	if visible_items.is_empty():
		return
	var index := visible_items.find(get_viewport().gui_get_focus_owner())
	visible_items[posmod(index + direction, visible_items.size())].grab_focus()


## 先关闭再广播，兼容工作台直接触发原生pressed信号的已有自动化调用。
func _activate(index: int) -> void:
	if index < 0 or index >= _items.size() or (index == 4 and not _save_allowed):
		return
	close_menu()
	match index:
		0:
			help_requested.emit()
		1:
			edit_modules_requested.emit()
		2:
			reset_requested.emit()
		3:
			reset_code_requested.emit()
		4:
			save_requested.emit()


## 翻译更新后延迟测量，避免沿用语言切换前的按钮最小宽度。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_update_placement.call_deferred()


## 等待工具栏完成窗口尺寸调整，再读取入口的新位置。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()
