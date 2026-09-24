class_name LevelActionsMenu
extends CanvasLayer
## 选关工具菜单仅负责呈现和输入，刷新目录及导入行为仍由 GameShell 执行。

signal refresh_requested
signal import_requested
signal sort_changed(enabled: bool)

const MENU_WIDTH := 220.0
const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 8.0

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _items: Array[Button] = []
var _anchor: Control
var _open := false
var _tween: Tween
var _sort_enabled := false
var _sort_open := false
var _sort_panel: Panel
var _sort_glass: ColorRect
var _sort_options: Array[Button] = []
var _sort_marks: Array[Label] = []
var _sort_chevron: TextureRect
var _separator: ColorRect


## 构建独立浮层，不把菜单插入页头容器，避免展开时推动标题或搜索框。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "LevelActionsOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	# 显式在菜单绘制前复制页面，防止圆角阴影或前一帧菜单混入模糊采样。
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "LevelActionsPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1.0, 0.82), Color(1, 1, 1, 0.88), 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "MenuGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_add_item("LevelRefreshMenuItem", "刷新", "res://assets/ui/refresh.svg", 0)
	_add_item("LevelImportMenuItem", "导入关卡", "res://assets/ui/import_level.svg", 1)
	_separator = ColorRect.new()
	_separator.name = "MenuSortSeparator"
	_separator.color = Color(0.65, 0.69, 0.76, 0.3)
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_separator)
	_add_item("LevelSortMenuItem", "排列方式", "res://assets/ui/sort.svg", 2)
	_sort_chevron = TextureRect.new()
	_sort_chevron.name = "SortSubmenuChevron"
	_sort_chevron.texture = load("res://assets/ui/navigation_forward.svg")
	_sort_chevron.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sort_chevron.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_sort_chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_items[2].add_child(_sort_chevron)
	_sort_panel = Panel.new()
	_sort_panel.name = "LevelSortPanel"
	_sort_panel.add_theme_stylebox_override("panel", surface.duplicate() as StyleBoxFlat)
	_sort_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(_sort_panel)
	_sort_panel.hide()
	_sort_glass = ColorRect.new()
	_sort_glass.name = "SortMenuGlass"
	_sort_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 两个玻璃面使用独立材质参数，子菜单尺寸变化不能影响主菜单圆角。
	_sort_glass.material = glass_material.duplicate() as ShaderMaterial
	_sort_panel.add_child(_sort_glass)
	_add_sort_option("LevelSortDefaultMenuItem", "默认顺序", false)
	_add_sort_option("LevelSortUncompletedMenuItem", "未通关优先", true)
	set_sort_enabled(_sort_enabled)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 为菜单项保留原生按钮的鼠标、可访问名称和焦点语义，图标始终使用矢量资源。
func _add_item(node_name: String, caption: String, icon_path: String, index: int) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	item.icon = load(icon_path)
	item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.add_theme_constant_override("h_separation", 12)
	item.add_theme_constant_override("icon_max_width", 22)
	_style_menu_item(item)
	item.pressed.connect(_activate.bind(index))
	_panel.add_child(item)
	_items.append(item)


## 两个排序选项分别绑定明确状态，勾选互斥由当前会话状态统一更新。
func _add_sort_option(node_name: String, caption: String, enabled: bool) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.toggle_mode = true
	_style_menu_item(item)
	item.pressed.connect(_activate_sort.bind(enabled))
	_sort_panel.add_child(item)
	_sort_options.append(item)
	var mark := Label.new()
	mark.name = "SortCheckmark"
	mark.text = "✓"
	mark.add_theme_color_override("font_color", GameTheme.ACCENT)
	mark.add_theme_font_size_override("font_size", 18)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(mark)
	_sort_marks.append(mark)


## 主菜单和子菜单共用行间距与悬停反馈，勾选不另起一套视觉风格。
func _style_menu_item(item: Button) -> void:
	item.add_theme_font_size_override("font_size", 16)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var color := Color(0.79, 0.87, 0.99, 0.68) if state in ["hover", "focus"] else Color(0.71, 0.82, 0.98, 0.82) if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(color, Color.TRANSPARENT, 10)
		style.set_content_margin_all(10)
		item.add_theme_stylebox_override(state, style)


## 从入口按钮右下方展开；再次调用同一入口相当于收起，且不改变底层页面状态。
func popup_at(anchor: Control) -> void:
	if _open:
		close_menu()
		return
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_open = true
	_overlay.show()
	_update_placement()
	set_process_input(true)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_panel.pivot_offset = Vector2(_panel.size.x, 0)
	_panel.scale = Vector2(0.97, 0.92)
	_panel.modulate.a = 0.0
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_panel, "scale", Vector2.ONE, 0.18)
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.14)
	_items[0].grab_focus()


## 同步关闭后才释放输入，确保选择导入时不会和新出现的独占对话框争抢焦点。
func close_menu(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	_sort_open = false
	_sort_panel.hide()
	set_process_input(false)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 向页头和页面切换代码公开菜单状态，不要求外部读取内部控件。
func is_open() -> bool:
	return _open


## 只同步会话中的排序勾选状态，不反向触发排序或修改玩家存档。
func set_sort_enabled(enabled: bool) -> void:
	_sort_enabled = enabled
	for index in range(_sort_marks.size()):
		var selected := enabled == (index == 1)
		_sort_marks[index].visible = selected
		_sort_options[index].set_pressed_no_signal(selected)


## 使用逻辑画布坐标定位，缩放窗口和切换语言都保持右边缘对齐及安全留白。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var width := MENU_WIDTH
	for item in _items:
		width = maxf(width, item.get_combined_minimum_size().x + 44.0)
	width = minf(width, maxf(0.0, viewport_size.x - EDGE_MARGIN * 2.0))
	var menu_size := Vector2(width, 168.0)
	var anchor_rect := _anchor.get_global_rect()
	var origin := Vector2(anchor_rect.end.x - menu_size.x, anchor_rect.end.y + ANCHOR_GAP)
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - menu_size.x - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	_panel.position = origin
	_panel.size = menu_size
	_panel.pivot_offset = Vector2(menu_size.x, 0)
	_glass.position = Vector2.ONE
	_glass.size = menu_size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 17.0)
	for index in range(_items.size()):
		_items[index].position = Vector2(8, 8 + index * 48 + (12 if index == 2 else 0))
		_items[index].size = Vector2(width - 16, 44)
	_separator.position = Vector2(18, 108)
	_separator.size = Vector2(width - 36, 1)
	_sort_chevron.position = Vector2(width - 47, 13)
	_sort_chevron.size = Vector2(18, 18)
	if _sort_open:
		_place_sort_menu(viewport_size)


## 主菜单位于右侧时优先向左打开排序选项，空间不足时改到下方并限制在视口内。
func _place_sort_menu(viewport_size: Vector2) -> void:
	var width := MENU_WIDTH
	for item in _sort_options:
		width = maxf(width, item.get_combined_minimum_size().x + 44)
	width = minf(width, maxf(0.0, viewport_size.x - EDGE_MARGIN * 2))
	var menu_size := Vector2(width, 108)
	var main_rect := Rect2(_panel.position, _panel.size)
	var origin := Vector2(main_rect.position.x - width - ANCHOR_GAP, main_rect.position.y + 116)
	if origin.x < EDGE_MARGIN:
		origin = Vector2(main_rect.end.x + ANCHOR_GAP, main_rect.position.y + 116)
		if origin.x + width > viewport_size.x - EDGE_MARGIN:
			origin = Vector2(main_rect.end.x - width, main_rect.end.y + ANCHOR_GAP)
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - width - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	_sort_panel.position = origin
	_sort_panel.size = menu_size
	_sort_glass.position = Vector2.ONE
	_sort_glass.size = menu_size - Vector2(2, 2)
	(_sort_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _sort_glass.size)
	(_sort_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 17.0)
	for index in range(_sort_options.size()):
		_sort_options[index].position = Vector2(8, 8 + index * 48)
		_sort_options[index].size = Vector2(width - 16, 44)
		_sort_marks[index].position = Vector2(width - 54, 0)
		_sort_marks[index].size = Vector2(28, 44)


## 打开排序子菜单时把焦点交给当前选中项，保持主菜单原位置和可点击状态。
func _open_sort_menu() -> void:
	_sort_open = true
	_sort_panel.show()
	_update_placement()
	_sort_options[1 if _sort_enabled else 0].grab_focus()


## 返回主菜单时只关闭子面板，Esc 和向左键都可逐级返回。
func _close_sort_menu() -> void:
	_sort_open = false
	_sort_panel.hide()
	_items[2].grab_focus()


## 在页面控件处理之前截获关闭和键盘导航，外部点击不会穿透到关卡卡片。
func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		var inside_sort := _sort_open and _sort_panel.get_global_rect().has_point(mouse.position)
		if not _panel.get_global_rect().has_point(mouse.position) and not inside_sort:
			get_viewport().set_input_as_handled()
			if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				close_menu()
			return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _sort_open:
			_close_sort_menu()
		else:
			close_menu()
	elif _sort_open and event.is_action_pressed("ui_left"):
		get_viewport().set_input_as_handled()
		_close_sort_menu()
	elif not _sort_open and event.is_action_pressed("ui_right") and _items[2].has_focus():
		get_viewport().set_input_as_handled()
		_open_sort_menu()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_focus_next", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(1)
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_focus_prev", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(-1)
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		get_viewport().set_input_as_handled()
		var active := _sort_options if _sort_open else _items
		var focused := active.find(get_viewport().gui_get_focus_owner())
		if _sort_open:
			_activate_sort(focused == 1)
		else:
			_activate(maxi(0, focused))


## 菜单项之间循环焦点，不把 Tab 或方向键交给背后的选关网格。
func _move_focus(direction: int) -> void:
	var active := _sort_options if _sort_open else _items
	var index := active.find(get_viewport().gui_get_focus_owner())
	active[posmod(index + direction, active.size())].grab_focus()


## 只发出一次用户选择信号；隐藏菜单后再执行外部回调，避免页面重建悬空引用。
func _activate(index: int) -> void:
	if not _open:
		return
	if index == 2:
		_open_sort_menu()
		return
	close_menu(false)
	if index == 0:
		refresh_requested.emit()
	elif index == 1:
		import_requested.emit()


## 先隐藏整组菜单再广播明确排序状态，重复选择当前项不会把它反向切换。
func _activate_sort(enabled: bool) -> void:
	if not _open or not _sort_open:
		return
	close_menu(false)
	set_sort_enabled(enabled)
	sort_changed.emit(enabled)


## 翻译通知先让按钮更新度量，再重算菜单宽度和相对入口的位置。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_update_placement.call_deferred()


## 等待父容器完成新尺寸布局后再读取入口坐标，避免使用窗口缩放前的位置。
func _on_viewport_resized() -> void:
	_update_placement.call_deferred()
