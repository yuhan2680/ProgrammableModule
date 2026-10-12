class_name PlayerLevelListContextMenu
extends CanvasLayer
## 设置里的文件列表菜单仅提交操作意图，不自行解析或修改关卡文件。

signal rename_requested(entry: PlayerLevelRecord)
signal delete_requested(entry: PlayerLevelRecord)
signal edit_requested(entry: PlayerLevelRecord)
signal open_folder_requested(entry: PlayerLevelRecord)

const EDGE_MARGIN := 12.0
const MENU_SCALE := 0.8

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _items: Array[Button] = []
var _anchor: Control
var _entry: PlayerLevelRecord
var _pointer := Vector2.ZERO
var _open := false
var _swallowed_button := MOUSE_BUTTON_NONE


## 在独立画布层构造四项轻量菜单，背景合成与设置正文遮罩互不影响。
func _ready() -> void:
	layer = 51
	_overlay = Control.new()
	_overlay.name = "PlayerLevelListContextOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "PlayerLevelListContextPanel"
	_panel.scale = Vector2.ONE * MENU_SCALE
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
	_items.append(_make_item("ListRenamePlayerLevelButton", "重命名关卡", "rename"))
	_items.append(_make_item("ListDeletePlayerLevelButton", "删除关卡", "delete", true))
	_items.append(_make_item("ListEditPlayerLevelButton", "使用地图编辑器更改", "edit"))
	_items.append(_make_item("ListOpenPlayerLevelFolderButton", "查看目录", "folder"))
	get_viewport().size_changed.connect(_update_placement)
	set_process_input(false)


## 普通项目保持深色、删除为红色，禁用项目不接受鼠标与键盘激活。
func _make_item(node_name: String, caption: String, action: String, destructive: bool = false) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	GameTheme.font_size(button, "font_size", 15)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, GameTheme.ERROR if destructive else GameTheme.TEXT)
	button.add_theme_color_override("font_disabled_color", GameTheme.MUTED)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		var fill := Color.TRANSPARENT
		if state in ["hover", "focus", "pressed", "hover_pressed"]:
			fill = Color(1, 0.85, 0.87, 0.7) if destructive else Color(0.78, 0.87, 1, 0.7)
		var style := GameTheme.box(fill, Color.TRANSPARENT, 10)
		style.set_content_margin_all(8)
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(_activate.bind(action))
	button.mouse_entered.connect(_focus_item.bind(button))
	_panel.add_child(button)
	return button


## 悬停仅把焦点移动到可执行项目，回车不会执行另一个菜单项。
func _focus_item(button: Button) -> void:
	if not button.disabled:
		button.grab_focus()


## 每次打开都使用最新记录能力，坏文件仍可删除或查看目录。
func popup_at(anchor: Control, pointer: Vector2, entry: PlayerLevelRecord) -> void:
	close_menu(false)
	if entry == null or not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_entry = entry
	_pointer = pointer
	_items[0].disabled = not entry.can_rename
	_items[2].disabled = not entry.can_edit
	var reason := GameI18n.translate_errors(entry.errors)
	_items[0].tooltip_text = reason if _items[0].disabled else ""
	_items[2].tooltip_text = reason if _items[2].disabled else ""
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	_overlay.show()
	_update_placement()
	set_process_input(true)
	for button in _items:
		if not button.disabled:
			button.grab_focus()
			break


## 关闭后丢弃记录引用，外点关闭仍吞掉本次鼠标抬起，防止穿透表格。
func close_menu(restore_focus: bool = true) -> void:
	_open = false
	_entry = null
	if _overlay != null:
		_overlay.hide()
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 供列表与外层刷新保护查询当前浮层是否占用交互。
func is_open() -> bool:
	return _open


## 按原逻辑尺寸排版后整体缩至八成，以真实屏幕尺寸约束边缘和玻璃圆角。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var bounds := get_viewport().get_visible_rect().size
	# 菜单在独立 CanvasLayer 中；沿入口取白卡比例一次，并继续保留原来的八成显示。
	var layout_scale := maxf(0.001, absf(_anchor.get_global_transform_with_canvas().get_scale().x))
	var menu_scale := MENU_SCALE * layout_scale
	var edge_margin := EDGE_MARGIN * layout_scale
	_panel.scale = Vector2.ONE * menu_scale
	var width := 190.0
	for button in _items:
		width = maxf(width, button.get_combined_minimum_size().x + 16)
	width = minf(width, (bounds.x - 2 * edge_margin) / menu_scale)
	var extent := Vector2(width, 12 + 42 * _items.size())
	var screen_extent := extent * menu_scale
	_panel.size = extent
	_panel.position = (_pointer + Vector2(8, 8) * menu_scale).clamp(Vector2.ONE * edge_margin, (bounds - screen_extent - Vector2.ONE * edge_margin).max(Vector2.ONE * edge_margin))
	_glass.position = Vector2.ONE
	_glass.size = extent - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size * menu_scale)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 15.0 * menu_scale)
	for index in range(_items.size()):
		_items[index].position = Vector2(6, 6 + 42 * index)
		_items[index].size = Vector2(width - 12, 42)


## 菜单打开时截住背景快捷键，Esc 与外点只关闭，方向键跳过禁用项目。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if _swallowed_button != MOUSE_BUTTON_NONE and event.button_index == _swallowed_button:
			get_viewport().set_input_as_handled()
			if not event.pressed:
				_swallowed_button = MOUSE_BUTTON_NONE
				set_process_input(_open)
			return
		if _open and not _panel.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()
			if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_swallowed_button = event.button_index
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
		if selected >= 0 and not _items[selected].disabled:
			_items[selected].pressed.emit()
	elif event is InputEventKey or event is InputEventAction:
		get_viewport().set_input_as_handled()


## 循环查找下一个可用动作，不会把焦点交给菜单背后的关卡行。
func _move_focus(direction: int) -> void:
	var index := _items.find(get_viewport().gui_get_focus_owner())
	for step in range(1, _items.size() + 1):
		var button := _items[posmod(index + direction * step, _items.size())]
		if not button.disabled:
			button.grab_focus()
			return


## 先关闭浮层再发出一次动作，能力受限的项即使被程序触发也不会发出请求。
func _activate(action: String) -> void:
	if not _open or _entry == null or (action == "rename" and not _entry.can_rename) or (action == "edit" and not _entry.can_edit):
		return
	var selected := _entry
	close_menu(false)
	match action:
		"rename": rename_requested.emit(selected)
		"delete": delete_requested.emit(selected)
		"edit": edit_requested.emit(selected)
		"folder": open_folder_requested.emit(selected)


## 翻译变化时关闭旧尺寸菜单，下一次打开重新读取实际文字宽度。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		close_menu(false)
