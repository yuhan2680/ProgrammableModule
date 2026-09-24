class_name MapExitDialog
extends Control
## 地图退出提醒与页面共用视口绘制毛玻璃；保存结果由编辑器和外壳负责。

signal save_requested
signal confirmed
signal canceled

const BASE_SIZE := Vector2(380, 408)
const DISPLAY_SCALE := 0.7
const EDGE_MARGIN := 20.0
const PADDING := 24.0
const BUTTON_HEIGHT := 42.0
const BUTTON_GAP := 8.0
const MESSAGE_SIZE := 16

var _layer: CanvasLayer
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _warning: TextureRect
var _message_scroll: ScrollContainer
var _message: Label
var _save_button: Button
var _discard_button: Button
var _cancel_button: Button
var _buttons: Array[Button] = []
var _map_name := ""
var _previous_focus: Control
var _keyboard_focus_visible := false


## 独立画布层高于菜单，但仍在主视口内复制地图作为玻璃底图。
func _ready() -> void:
	theme = GameTheme.create_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer = CanvasLayer.new()
	_layer.name = "MapExitLayer"
	_layer.layer = 65
	add_child(_layer)
	_overlay = Control.new()
	_overlay.name = "MapExitOverlay"
	_overlay.theme = theme
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrim := ColorRect.new()
	scrim.name = "MapExitScrim"
	scrim.color = Color(0.10, 0.14, 0.20, 0.06)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(scrim)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := BackBufferCopy.new()
	backdrop.name = "MapExitBackdrop"
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "MapExitPanel"
	_panel.scale = Vector2.ONE * DISPLAY_SCALE
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 30)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.08, 0.13, 0.22, 0.18)
	surface.shadow_size = 16
	surface.shadow_offset = Vector2(0, 6)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "MapExitGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/assembly_glass.gdshader")
	glass_material.set_shader_parameter("corner_radius", 30.0)
	glass_material.set_shader_parameter("frost", 0.78)
	_glass.material = glass_material
	_panel.add_child(_glass)
	_warning = TextureRect.new()
	_warning.name = "MapExitWarning"
	_warning.texture = load("res://assets/ui/map_warning.svg")
	_warning.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_warning.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_warning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_warning)
	_message_scroll = ScrollContainer.new()
	_message_scroll.name = "MapExitMessageScroll"
	_message_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_message_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_panel.add_child(_message_scroll)
	_message = Label.new()
	_message.name = "MapExitMessage"
	_message.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message.add_theme_font_size_override("font_size", MESSAGE_SIZE)
	_message.add_theme_color_override("font_color", GameTheme.TEXT)
	_message.add_theme_constant_override("line_spacing", 4)
	_message_scroll.add_child(_message)
	_save_button = _make_button("MapExitSave", "保存", true, _save)
	_discard_button = _make_button("MapExitDiscard", "不保存", false, _discard)
	_cancel_button = _make_button("MapExitCancel", "取消", false, _cancel)
	_buttons = [_save_button, _discard_button, _cancel_button]
	get_viewport().size_changed.connect(_layout_dialog)
	visibility_changed.connect(_sync_visibility)
	_refresh_text()
	hide()
	_sync_visibility()


## 胶囊各状态保持相同尺寸；焦点边框由键盘导航显式启用，鼠标移开不残留蓝边。
func _make_button(node_name: String, caption: String, primary: bool, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.add_theme_font_size_override("font_size", 16)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := GameTheme.ACCENT if primary else Color(0.73, 0.77, 0.82, 0.30)
		if state == "hover":
			fill = Color("1987FF") if primary else Color(0.72, 0.77, 0.84, 0.43)
		elif state in ["pressed", "hover_pressed"]:
			fill = Color("006BE0") if primary else Color(0.66, 0.72, 0.81, 0.49)
		elif state == "focus":
			fill = Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 21)
		if state == "focus":
			style.set_border_width_all(1)
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE if primary else GameTheme.TEXT)
	button.pressed.connect(action)
	_panel.add_child(button)
	return button


## 每次打开读取当前地图名，名称只插入已本土化句子，不自动翻译玩家文本。
func open_for_map(map_name: String) -> void:
	_map_name = map_name
	_previous_focus = get_viewport().gui_get_focus_owner()
	_set_keyboard_focus_visible(false)
	_refresh_text()
	_message_scroll.scroll_vertical = 0
	show()
	_layout_dialog()
	_focus_cancel.call_deferred()


## 保留外壳和既有测试使用的取消按钮接口。
func get_cancel_button() -> Button:
	return _cancel_button


## 更新动态翻译而不改变地图名本身，换语言后重新计算换行高度。
func _refresh_text() -> void:
	if not is_instance_valid(_message):
		return
	_message.text = tr("返回开始界面前，请确认“%s”是否已保存。") % _map_name
	_layout_dialog()


## 按七成整体呈现图标、字形、圆角和间距；长名称仍在原逻辑宽度内换行或滚动。
func _layout_dialog() -> void:
	if not is_instance_valid(_panel) or not is_instance_valid(_cancel_button):
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var available := (viewport_size / DISPLAY_SCALE - Vector2.ONE * EDGE_MARGIN * 2.0).max(Vector2.ONE)
	var width := minf(BASE_SIZE.x, available.x)
	var padding := minf(PADDING, width * 0.08)
	var body_width := maxf(1.0, width - padding * 2.0)
	var font := _message.get_theme_font("font")
	var text_size := font.get_multiline_string_size(_message.text, HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, body_width - 14.0), MESSAGE_SIZE, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
	var text_height := ceilf(text_size.y + float(maxi(1, int(ceilf(text_size.y / font.get_height(MESSAGE_SIZE))))) * 4.0)
	var message_height := clampf(text_height, 60.0, 132.0)
	var height := minf(BASE_SIZE.y + message_height - 60.0, available.y)
	_panel.size = Vector2(width, height)
	_panel.position = ((viewport_size - _panel.size * DISPLAY_SCALE) * 0.5).floor()
	_glass.size = _panel.size
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _panel.size)
	var button_height := minf(BUTTON_HEIGHT, maxf(20.0, height * 0.12))
	var button_gap := minf(BUTTON_GAP, height * 0.025)
	var actions_height := button_height * 3.0 + button_gap * 2.0
	var actions_top := height - padding - actions_height
	var warning_size := minf(88.0, maxf(24.0, height * 0.22))
	_warning.position = Vector2(padding, padding)
	_warning.size = Vector2.ONE * warning_size
	var message_top := minf(padding + warning_size + 20.0, maxf(padding, actions_top - 40.0))
	_message_scroll.position = Vector2(padding, message_top)
	_message_scroll.size = Vector2(body_width, maxf(1.0, actions_top - message_top - 20.0))
	_message.custom_minimum_size.y = text_height
	for index in _buttons.size():
		_buttons[index].position = Vector2(padding, actions_top + float(index) * (button_height + button_gap))
		_buttons[index].size = Vector2(body_width, button_height)


## 延后聚焦取消，避免打开弹窗的同一个键意外触发保存或放弃。
func _focus_cancel() -> void:
	if is_visible_in_tree():
		_cancel_button.grab_focus()


## CanvasLayer不继承父Control的显示状态，因此显式同步避免页面切换后悬留。
func _sync_visibility() -> void:
	if not is_instance_valid(_layer):
		return
	var active := is_visible_in_tree()
	_layer.visible = active
	set_process_input(active)


## 保存只提交意图；外壳在写盘成功后才允许退出。
func _save() -> void:
	if not is_visible_in_tree():
		return
	hide()
	save_requested.emit()


## 明确点击不保存时才发出放弃确认，不把外部点击作为确认。
func _discard() -> void:
	if not is_visible_in_tree():
		return
	hide()
	confirmed.emit()


## 取消与Esc均保留地图，并把焦点交还打开弹窗前的编辑控件。
func _cancel() -> void:
	if not is_visible_in_tree():
		return
	hide()
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	canceled.emit()


## 键盘焦点只在三个按钮之间循环，页面快捷键不会穿透确认界面。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventKey:
		get_viewport().set_input_as_handled()
		if not event.pressed or event.is_echo():
			return
		if event.is_action_pressed("ui_cancel"):
			_cancel()
		elif event.is_action_pressed("ui_focus_next", false, true) or event.is_action_pressed("ui_down"):
			_set_keyboard_focus_visible(true)
			_move_focus(1)
		elif event.is_action_pressed("ui_focus_prev", false, true) or event.is_action_pressed("ui_up"):
			_set_keyboard_focus_visible(true)
			_move_focus(-1)
		elif event.is_action_pressed("ui_accept"):
			var focused := get_viewport().gui_get_focus_owner()
			if focused in _buttons:
				(focused as Button).pressed.emit()
	elif event is InputEventMouseButton or event is InputEventMouseMotion:
		_set_keyboard_focus_visible(false)
		# 移动事件交给全屏屏障更新按钮的mouse_exited，外部按键仍在此拦截。
		if event is InputEventMouseButton and not _panel.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()


## 保留安全的默认取消焦点，只随当前输入方式切换可见提示，不改变回车和Esc行为。
func _set_keyboard_focus_visible(enabled: bool) -> void:
	if _keyboard_focus_visible == enabled:
		return
	_keyboard_focus_visible = enabled
	for button in _buttons:
		var focus_style := button.get_theme_stylebox("focus") as StyleBoxFlat
		focus_style.border_color = GameTheme.ACCENT if enabled else Color.TRANSPARENT


## 指定相对方向切换焦点，当前焦点无效时优先返回取消按钮。
func _move_focus(direction: int) -> void:
	var index := _buttons.find(get_viewport().gui_get_focus_owner())
	_buttons[posmod(index + direction, _buttons.size()) if index >= 0 else 2].grab_focus()


## 动态语言与父页面显隐变化也必须同步玻璃层。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_refresh_text()
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		_sync_visibility()
