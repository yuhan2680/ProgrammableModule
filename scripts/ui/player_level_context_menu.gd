class_name PlayerLevelContextMenu
extends CanvasLayer
## 玩家关卡的右键菜单仅呈现操作意图，文件边界交给关卡目录再次校验。

signal rename_requested(definition: LevelDefinition)
signal open_folder_requested(definition: LevelDefinition)
signal delete_requested(definition: LevelDefinition)

const EDGE_MARGIN := 12.0
const MENU_WIDTH := 164.0

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _rename_button: Button
var _open_folder_button: Button
var _delete_button: Button
var _items: Array[Button] = []
var _anchor: Control
var _definition: LevelDefinition
var _pointer := Vector2.ZERO
var _open := false
var _swallowed_button := MOUSE_BUTTON_NONE


## 复用现有半透明菜单表面和红色操作，浮层不参与关卡网格布局。
func _ready() -> void:
	layer = 51
	_overlay = Control.new()
	_overlay.name = "PlayerLevelContextOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_overlay.size = get_viewport().get_visible_rect().size
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "PlayerLevelContextPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1, 0.82), Color(1, 1, 1, 0.88), 16)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_rename_button = _make_item("RenamePlayerLevelButton", "重命名关卡", _activate_rename)
	_open_folder_button = _make_item("OpenPlayerLevelFolderButton", "打开关卡所在文件夹", _activate_open_folder)
	_delete_button = _make_item("DeletePlayerLevelButton", "删除关卡", _activate, true)
	_items = [_rename_button, _open_folder_button, _delete_button]
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 普通操作沿用深色文字，删除保持红色；悬停同步键盘焦点，避免回车执行另一行。
func _make_item(node_name: String, caption: String, callback: Callable, destructive: bool = false) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	GameTheme.font_size(button, "font_size", 15)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, GameTheme.ERROR if destructive else GameTheme.TEXT)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var hover := Color(1, 0.85, 0.87, 0.7) if destructive else Color(0.78, 0.87, 1, 0.7)
		var pressed := Color(0.98, 0.79, 0.82, 0.8) if destructive else Color(0.71, 0.82, 0.98, 0.8)
		var fill := hover if state in ["hover", "focus"] else pressed if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 10)
		style.set_content_margin_all(8)
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(callback)
	button.mouse_entered.connect(button.grab_focus)
	_panel.add_child(button)
	return button


## 记录本次目录对象并贴近右键落点显示，初始焦点放在非破坏性的首项。
func popup_at(anchor: Control, pointer: Vector2, definition: LevelDefinition) -> void:
	close_menu(false)
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree() or definition == null:
		return
	_anchor = anchor
	_definition = definition
	_pointer = pointer
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	_overlay.show()
	_update_placement()
	set_process_input(true)
	_rename_button.grab_focus()


## 关闭即丢弃选中的关卡，外部关闭时仍吞掉对应抬起事件，防止误进入背景关卡。
func close_menu(restore_focus: bool = true) -> void:
	_open = false
	_definition = null
	if _overlay != null:
		_overlay.hide()
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 外部可以查询浮层状态，以便互斥菜单和页面切换。
func is_open() -> bool:
	return _open


## 独立浮层补入卡片的实际缩放，指针和视口边界转回原逻辑坐标后排版。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var presentation_scale := _sync_anchor_scale()
	var bounds := get_viewport().get_visible_rect().size / presentation_scale
	var width := MENU_WIDTH
	for button in _items:
		width = maxf(width, button.get_combined_minimum_size().x + 16)
	width = minf(width, bounds.x - 2 * EDGE_MARGIN)
	var menu_size := Vector2(width, 12 + 42 * _items.size())
	_panel.size = menu_size
	_panel.position = (_pointer / presentation_scale + Vector2(8, 8)).clamp(Vector2.ONE * EDGE_MARGIN, (bounds - menu_size - Vector2.ONE * EDGE_MARGIN).max(Vector2.ONE * EDGE_MARGIN))
	_glass.position = Vector2.ONE
	_glass.size = menu_size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 15.0)
	for index in range(_items.size()):
		_items[index].position = Vector2(6, 6 + 42 * index)
		_items[index].size = Vector2(width - 12, 42)


## 全屏命中层跟随当前卡片比例一次，内部字体、阴影和玻璃圆角保留原逻辑度量。
func _sync_anchor_scale() -> float:
	var anchor_transform := _anchor.get_global_transform()
	var presentation_scale := maxf(0.01, minf(anchor_transform.x.length(), anchor_transform.y.length()))
	_overlay.position = Vector2.ZERO
	_overlay.scale = Vector2.ONE * presentation_scale
	_overlay.size = get_viewport().get_visible_rect().size / presentation_scale
	return presentation_scale


## 让页根先完成新视口布局，再读取卡片比例和菜单可用边界。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()


## 外部完整点击只关闭浮层，键盘留在当前菜单，Esc 永远不会误触删除。
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
		var selected := _items.find(get_viewport().gui_get_focus_owner())
		_items[maxi(0, selected)].pressed.emit()
	elif event is InputEventKey or event is InputEventAction:
		get_viewport().set_input_as_handled()


## 菜单内部循环方向键与 Tab 焦点，不把导航交给背景的关卡卡片。
func _move_focus(direction: int) -> void:
	var index := _items.find(get_viewport().gui_get_focus_owner())
	_items[posmod(index + direction, _items.size())].grab_focus()


## 先关闭菜单再请求修改名称，避免卡片内输入与旧的菜单焦点冲突。
func _activate_rename() -> void:
	if not _open or _definition == null:
		return
	var selected := _definition
	close_menu(false)
	rename_requested.emit(selected)


## 打开文件夹同样只传递当前关卡对象，不在菜单层拼接或信任文件路径。
func _activate_open_folder() -> void:
	if not _open or _definition == null:
		return
	var selected := _definition
	close_menu(false)
	open_folder_requested.emit(selected)


## 先移除浮层再发出一次删除意图；隐藏菜单不能复用旧选择触发操作。
func _activate() -> void:
	if not _open or _definition == null:
		return
	var selected := _definition
	close_menu(false)
	delete_requested.emit(selected)


## 切换语言时关闭已有选择，防止翻译期间沿用旧目录对象和旧尺寸。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		close_menu(false)
