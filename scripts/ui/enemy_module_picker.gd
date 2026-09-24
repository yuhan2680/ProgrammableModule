class_name EnemyModulePicker
extends CanvasLayer
## 敌人模块菜单与页面共用视口采样，选择结果仍交给原表单事务处理。

signal item_selected(index: int)

const BASE_WIDTH := 142.0
const MAX_WIDTH := 220.0
const ROW_HEIGHT := 42.0
const ICON_SIZE := 32
const FONT_SIZE := 12
const PADDING := 9.0
const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 4.0

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _scroll: ScrollContainer
var _content: VBoxContainer
var _items: Array[Button] = []
var _anchor: Control
var _open := false
var _selected := -1
var _swallowed_button := MOUSE_BUTTON_NONE
var _last_anchor_rect := Rect2()


## 在同一画布层先复制页面，再绘制玻璃和清晰模块行，避免独立Popup视口采样空白。
func _ready() -> void:
	layer = 55
	_overlay = Control.new()
	_overlay.name = "EnemyModulePickerOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.name = "EnemyModulePickerBackdrop"
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "EnemyModulePickerPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 12)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.10, 0.16, 0.24, 0.14)
	surface.shadow_size = 9
	surface.shadow_offset = Vector2(0, 3)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "EnemyModulePickerGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/assembly_glass.gdshader")
	glass_material.set_shader_parameter("corner_radius", 12.0)
	glass_material.set_shader_parameter("frost", 0.84)
	_glass.material = glass_material
	_panel.add_child(_glass)
	_scroll = ScrollContainer.new()
	_scroll.name = "EnemyModulePickerScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	_panel.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.name = "EnemyModulePickerItems"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 0)
	_scroll.add_child(_content)
	get_viewport().size_changed.connect(_update_placement)
	set_process(false)
	set_process_input(false)


## 同一入口再次点击收起；条目文字已由表单本土化，此层不翻译模块ID或玩家数据。
func popup_at(anchor: Control, entries: Array[Dictionary], selected: int) -> void:
	if _open and _anchor == anchor:
		close_menu()
		return
	if not is_node_ready() or not is_instance_valid(anchor) or not anchor.is_visible_in_tree() or (anchor is BaseButton and anchor.disabled):
		return
	close_menu(false)
	_anchor = anchor
	_selected = selected
	_swallowed_button = MOUSE_BUTTON_NONE
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_items.clear()
	for index in entries.size():
		_add_item(entries[index], index)
	if _items.is_empty():
		return
	_open = true
	_overlay.show()
	_scroll.scroll_vertical = 0
	_update_placement()
	set_process(true)
	set_process_input(true)
	_focus_initial_item.call_deferred()


## 标准按钮统一限制图标尺寸，原SVG画布大小不会拉高菜单或让射击图标单独变大。
func _add_item(entry: Dictionary, index: int) -> void:
	var item := Button.new()
	item.name = "EnemyModulePickerItem%d" % index
	item.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	item.text = str(entry.get("text", ""))
	item.tooltip_text = item.text
	item.icon = entry.get("icon") as Texture2D
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.expand_icon = true
	item.clip_text = true
	item.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	item.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	item.custom_minimum_size.y = ROW_HEIGHT
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.add_theme_constant_override("icon_max_width", ICON_SIZE)
	item.add_theme_constant_override("h_separation", 8)
	item.add_theme_font_size_override("font_size", FONT_SIZE)
	item.disabled = bool(entry.get("disabled", false))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color(0.57, 0.73, 0.97, 0.20) if index == _selected and state == "normal" else Color.TRANSPARENT
		if state in ["hover", "focus"]:
			fill = Color(0.63, 0.77, 0.98, 0.32)
		elif state in ["pressed", "hover_pressed"]:
			fill = Color(0.51, 0.70, 0.96, 0.45)
		var style := GameTheme.box(fill, Color.TRANSPARENT, 7)
		style.content_margin_left = 5 if item.icon != null else 5 + ICON_SIZE + 8
		style.content_margin_right = 5
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		item.add_theme_stylebox_override(state, style)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		item.add_theme_color_override(state, Color.WHITE)
	item.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.35))
	item.pressed.connect(_activate.bind(index))
	_content.add_child(item)
	_items.append(item)


## 关闭后恢复入口焦点；由外侧按下关闭时继续吞掉对应抬起，防止地图被误绘制。
func close_menu(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	_overlay.hide()
	set_process(false)
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and _anchor_available():
		_anchor.grab_focus()


## 对外暴露菜单开合状态，不要求表单访问绘制节点。
func is_open() -> bool:
	return _open


## 入口被隐藏、禁用、释放或滚出属性裁剪区时关闭；普通布局移动继续跟随入口。
func _process(_delta: float) -> void:
	if not _anchor_available():
		close_menu(false)
		return
	if not _last_anchor_rect.is_equal_approx(_anchor.get_global_rect()):
		_update_placement()


## 检查真实入口及祖先裁剪范围，防止菜单在页面切换后单独留在画面上。
func _anchor_available() -> bool:
	if not is_instance_valid(_anchor) or not _anchor.is_inside_tree() or not _anchor.is_visible_in_tree() or (_anchor is BaseButton and _anchor.disabled):
		return false
	var rect := _anchor.get_global_rect()
	var ancestor := _anchor.get_parent()
	while ancestor != null:
		if ancestor is Control and ancestor.clip_contents and not ancestor.get_global_rect().intersects(rect):
			return false
		ancestor = ancestor.get_parent()
	return true


## 六行中文菜单为142×270，英文按必要文字扩宽；可用高度不足时只滚动菜单内部。
func _update_placement() -> void:
	if not _open:
		return
	if not _anchor_available():
		close_menu(false)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var width := BASE_WIDTH
	for item in _items:
		var caption_width := item.get_theme_font("font").get_string_size(item.text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
		var icon_width := float(ICON_SIZE + 8) if item.icon != null else 0.0
		width = maxf(width, ceilf(caption_width + icon_width + 10.0 + PADDING * 2.0))
	width = minf(width, minf(MAX_WIDTH, maxf(1.0, viewport_size.x - EDGE_MARGIN * 2.0)))
	_last_anchor_rect = _anchor.get_global_rect()
	var desired_height := _items.size() * ROW_HEIGHT + PADDING * 2.0
	var below := viewport_size.y - EDGE_MARGIN - _last_anchor_rect.end.y - ANCHOR_GAP
	var above := _last_anchor_rect.position.y - ANCHOR_GAP - EDGE_MARGIN
	var open_above := below < desired_height and above > below
	var available_height := above if open_above else below
	var height := minf(desired_height, maxf(ROW_HEIGHT + PADDING * 2.0, available_height))
	height = minf(height, maxf(1.0, viewport_size.y - EDGE_MARGIN * 2.0))
	if desired_height > height:
		width = minf(width + _scroll.get_v_scroll_bar().get_combined_minimum_size().x, minf(MAX_WIDTH, viewport_size.x - EDGE_MARGIN * 2.0))
	var origin := Vector2(_last_anchor_rect.position.x, _last_anchor_rect.position.y - ANCHOR_GAP - height if open_above else _last_anchor_rect.end.y + ANCHOR_GAP)
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - width - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - height - EDGE_MARGIN))
	_panel.position = origin
	_panel.size = Vector2(width, height)
	_glass.position = Vector2.ZERO
	_glass.size = _panel.size
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	_scroll.position = Vector2(PADDING, PADDING)
	_scroll.size = (_panel.size - Vector2.ONE * PADDING * 2.0).max(Vector2.ONE)


## 打开后优先聚焦当前选择；空槽或禁用项不会使键盘焦点落到菜单外。
func _focus_initial_item() -> void:
	if not _open:
		return
	if _selected >= 0 and _selected < _items.size() and not _items[_selected].disabled:
		_focus_item(_selected)
	else:
		_move_focus(1)


## 键盘与鼠标共用标准按钮焦点，并将目标行滚动到内部可见区域。
func _focus_item(index: int) -> void:
	_items[index].grab_focus()
	_scroll.ensure_control_visible(_items[index])


## 上下方向键和Tab只循环可用条目，不穿过菜单去修改背后输入框。
func _move_focus(direction: int) -> void:
	var available: Array[int] = []
	for index in _items.size():
		if not _items[index].disabled:
			available.append(index)
	if available.is_empty():
		return
	var focused := _items.find(get_viewport().gui_get_focus_owner())
	var current := available.find(focused)
	var next := posmod(current + direction, available.size()) if current >= 0 else 0 if direction > 0 else available.size() - 1
	_focus_item(available[next])


## 先关闭再发出选择，允许外层同步重建槽位或释放入口而不留下陈旧菜单。
func _activate(index: int) -> void:
	if not _open or not _anchor_available() or index < 0 or index >= _items.size() or _items[index].disabled:
		return
	close_menu()
	item_selected.emit(index)


## 菜单外的完整点击只关闭菜单；菜单内滚轮交给原生ScrollContainer处理。
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
	if not _open or not event is InputEventKey:
		return
	get_viewport().set_input_as_handled()
	if event.is_action_pressed("ui_cancel"):
		close_menu()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_focus_next", false, true):
		_move_focus(1)
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_focus_prev", false, true):
		_move_focus(-1)
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		_activate(_items.find(get_viewport().gui_get_focus_owner()))


## 已翻译条目的语言来源由表单管理；切换语言时关闭旧菜单，重开使用最新文字。
func _notification(what: int) -> void:
	if what in [NOTIFICATION_TRANSLATION_CHANGED, NOTIFICATION_APPLICATION_FOCUS_OUT] and _open:
		close_menu(false)
