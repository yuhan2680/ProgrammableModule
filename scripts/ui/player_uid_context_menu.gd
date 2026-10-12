class_name PlayerUidContextMenu
extends CanvasLayer
## 只读玩家 UID 的单项玻璃菜单，复制意图交给所属档案页面处理。

signal copy_requested

const EDGE_MARGIN := 12.0

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _copy_button: Button
var _anchor: Control
var _pointer := Vector2.ZERO
var _open := false
var _swallowed_button := MOUSE_BUTTON_NONE


## 复用已有菜单的玻璃着色器及表面，不使用系统文本编辑菜单。
func _ready() -> void:
	layer = 51
	_overlay = Control.new()
	_overlay.name = "PlayerUidMenuOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "PlayerUidMenuPanel"
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
	var material := ShaderMaterial.new()
	material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = material
	_panel.add_child(_glass)
	_copy_button = Button.new()
	_copy_button.name = "CopyPlayerUidButton"
	_copy_button.text = "复制 UID"
	_copy_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	GameTheme.font_size(_copy_button, "font_size", 15)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color(0.78, 0.87, 1, 0.7) if state in ["hover", "focus"] else Color(0.71, 0.82, 0.98, 0.8) if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 10)
		style.set_content_margin_all(8)
		_copy_button.add_theme_stylebox_override(state, style)
	_copy_button.pressed.connect(_activate_copy)
	_panel.add_child(_copy_button)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)
	set_process(false)


## 从右键落点显示，焦点只停留在唯一的复制项。
func popup_at(anchor: Control, pointer: Vector2) -> void:
	close_menu(false)
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_pointer = pointer
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	_overlay.show()
	_update_placement()
	set_process_input(true)
	set_process(true)
	_copy_button.grab_focus()


## 收起时恢复只读栏焦点；外部点击的抬起事件仍由菜单吞掉。
func close_menu(restore_focus: bool = true) -> void:
	_open = false
	if _overlay != null:
		_overlay.hide()
	set_process(false)
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 页面和测试可查询菜单是否占用输入。
func is_open() -> bool:
	return _open


## 菜单随入口实际缩放，并限制在当前视口边界内。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var factor := GameTheme.sync_popup_scale(_overlay, _anchor)
	var bounds := get_viewport().get_visible_rect().size / factor
	var row_size := _copy_button.get_combined_minimum_size()
	var width := minf(maxf(140.0, row_size.x + 12), bounds.x - EDGE_MARGIN * 2)
	var height := maxf(42.0, row_size.y)
	_panel.size = Vector2(width, height + 12)
	_panel.position = (_pointer / factor + Vector2(8, 8)).clamp(Vector2.ONE * EDGE_MARGIN, (bounds - _panel.size - Vector2.ONE * EDGE_MARGIN).max(Vector2.ONE * EDGE_MARGIN))
	_copy_button.position = Vector2(6, 6)
	_copy_button.size = Vector2(width - 12, height)
	_glass.position = Vector2.ONE
	_glass.size = _panel.size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 15.0)


## 等入口布局更新后重新约束菜单位置。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()


## 外层页面隐藏时同步关闭独立画布层，避免旧菜单残留。
func _process(_delta: float) -> void:
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)


## 菜单独占键盘和外部点击，关闭动作不会触发背景的删除档案按钮。
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
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_activate_copy()
	elif event is InputEventKey or event is InputEventAction:
		get_viewport().set_input_as_handled()
		_copy_button.grab_focus()


## 仅可见菜单允许发出一次复制请求，不会改动档案。
func _activate_copy() -> void:
	if not _open:
		return
	close_menu()
	copy_requested.emit()


## 切换语言后让下一次打开重新测量菜单文字。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		close_menu(false)
