class_name MapEditorActionsMenu
extends CanvasLayer
## 地图编辑器更多菜单只发出操作意图，文档保存、校验和元数据仍交给编辑器处理。

signal save_as_requested
signal validate_requested
signal metadata_requested

const MENU_WIDTH := 220.0
const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 8.0
const ROW_HEIGHT := 44.0
const ROW_GAP := 4.0

var _items: Array[Button] = []
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _anchor: Control
var _open := false
var _tween: Tween
var _origin := Vector2.ZERO
var _reveal_progress := 1.0
var _swallowed_button := MOUSE_BUTTON_NONE


## 在独立画布层复用编程菜单的玻璃表面，展开不会挤动工具栏和地图。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "MapEditorActionsOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "MapEditorActionsPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1.0, 0.82), Color(1, 1, 1, 0.88), 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "MapEditorActionsGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_add_item("MapEditorSaveAsMenuItem", "另存为", "res://assets/ui/map_editor_save_as.svg", 0)
	_add_item("MapEditorValidateMenuItem", "校验", "res://assets/ui/map_editor_validate.svg", 1)
	_add_item("MapEditorMetadataMenuItem", "元数据 JSON", "res://assets/ui/map_editor_metadata.svg", 2)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 三项操作统一使用原生按钮和高清 SVG，复用编程菜单的焦点、悬停与按下外观。
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


## 向工具栏和页面切换公开状态，不要求外部读取内部控件。
func is_open() -> bool:
	return _open


## 只改变菜单位置与透明度，右边缘固定，避免缩放文字造成动画过程模糊。
func _set_reveal_progress(progress: float) -> void:
	_reveal_progress = progress
	_panel.position = _origin + Vector2(0, -8.0 * (1.0 - progress))
	_panel.modulate.a = progress


## 按翻译后的文字度量计算尺寸，始终贴齐入口右侧并限制在视口内。
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
	for item in _items:
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


## 优先接管关闭和焦点操作，吞掉外部完整点击，防止再次点入口时重开或误操作地图。
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
	elif event is InputEventKey:
		# 菜单保持打开时，不把未使用的快捷键传给背后的文档或地图。
		get_viewport().set_input_as_handled()


## 只收集可见且可用的行，键盘焦点始终停留在当前菜单。
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


## 先关闭再广播；后续文件或元数据弹窗不会与菜单同时占用输入。
func _activate(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	close_menu()
	match index:
		0:
			save_as_requested.emit()
		1:
			validate_requested.emit()
		2:
			metadata_requested.emit()


## 翻译更新后延迟测量，避免沿用语言切换前的按钮最小宽度。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_update_placement.call_deferred()


## 等待工具栏完成窗口尺寸调整，再读取入口的新位置。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()
