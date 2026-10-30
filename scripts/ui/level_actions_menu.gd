class_name LevelActionsMenu
extends CanvasLayer
## 选关工具菜单仅负责呈现和输入，刷新、排序及显示偏好由页面处理。

signal refresh_requested
signal sort_changed(enabled: bool)
signal display_changed(show_author: bool, show_completion: bool)
signal input_observed(event: InputEvent)

const MENU_WIDTH := 220.0
const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 8.0
const ROW_MIN_HEIGHT := 44.0
const ROW_GAP := 4.0
const SORT_INDEX := 1
const DISPLAY_INDEX := 2
const SUBMENU_HOVER_DELAY := 0.15
const SUBMENU_AIM_DELAY := 0.30

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _items: Array[Button] = []
var _captions: Dictionary = {}
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
var _show_author := true
var _show_completion := true
var _display_open := false
var _display_panel: Panel
var _display_glass: ColorRect
var _display_options: Array[Button] = []
var _display_marks: Array[Label] = []
var _display_chevron: TextureRect
var _separator: ColorRect
var _swallowed_button := MOUSE_BUTTON_NONE
var _layout_dirty := true
var _last_anchor_transform := Transform2D.IDENTITY
var _last_anchor_rect := Rect2()
var _last_viewport_size := Vector2.ZERO
var _row_layout_cache: Dictionary = {}
var _hovered_main_index := -1
var _pending_hover_index := -1
var _hover_elapsed := 0.0
var _hover_delay := SUBMENU_HOVER_DELAY
var _last_pointer_position := Vector2.ZERO
var _submenu_aim_origin := Vector2.ZERO


## 构建独立浮层，不把菜单插入页头容器，避免展开时推动标题或搜索框。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "LevelActionsOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_overlay.size = get_viewport().get_visible_rect().size
	_overlay.hide()
	# 显式在菜单绘制前复制页面，防止圆角阴影或前一帧菜单混入模糊采样。
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = _create_panel("LevelActionsPanel")
	_glass = _create_glass(_panel, "MenuGlass")
	_add_item("LevelRefreshMenuItem", "刷新", 0)
	_add_item("LevelSortMenuItem", "排列方式", SORT_INDEX)
	_add_item("LevelDisplayMenuItem", "显示内容", DISPLAY_INDEX)
	_separator = ColorRect.new()
	_separator.name = "MenuSortSeparator"
	_separator.color = Color(0.65, 0.69, 0.76, 0.3)
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_separator)
	_sort_chevron = _add_chevron(_items[SORT_INDEX], "SortSubmenuChevron")
	_display_chevron = _add_chevron(_items[DISPLAY_INDEX], "DisplaySubmenuChevron")
	_sort_panel = _create_panel("LevelSortPanel")
	_sort_glass = _create_glass(_sort_panel, "SortMenuGlass")
	_sort_panel.hide()
	_add_sort_option("LevelSortDefaultMenuItem", "默认顺序", false)
	_add_sort_option("LevelSortUncompletedMenuItem", "未通关优先", true)
	_display_panel = _create_panel("LevelDisplayPanel")
	_display_glass = _create_glass(_display_panel, "DisplayMenuGlass")
	_display_panel.hide()
	_add_display_option("LevelShowAuthorMenuItem", "显示作者信息", 0)
	_add_display_option("LevelShowCompletionMenuItem", "显示是否完成", 1)
	set_sort_enabled(_sort_enabled)
	set_display_options(_show_author, _show_completion)
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)
	set_process(false)


## 各级菜单共用浅白圆角与阴影，每个面板保留独立尺寸和输入遮挡。
func _create_panel(node_name: String) -> Panel:
	var panel := Panel.new()
	panel.name = node_name
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1.0, 0.82), Color(1, 1, 1, 0.88), 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(panel)
	return panel


## 每块玻璃单独保存圆角参数，子菜单变宽不会影响主菜单的背景取样。
func _create_glass(panel: Panel, node_name: String) -> ColorRect:
	var glass := ColorRect.new()
	glass.name = node_name
	glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	glass.material = glass_material
	panel.add_child(glass)
	return glass


## 主菜单使用原生按钮承担鼠标、键盘及可访问名称，文字独立换行以适应大字号。
func _add_item(node_name: String, caption: String, index: int) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	_style_menu_item(item)
	item.pressed.connect(_activate.bind(index))
	_panel.add_child(item)
	_items.append(item)


## 右侧箭头只表示存在下一层，不占据左侧用于选择状态的勾号位置。
func _add_chevron(item: Button, node_name: String) -> TextureRect:
	var chevron := TextureRect.new()
	chevron.name = node_name
	chevron.texture = load("res://assets/ui/navigation_forward.svg")
	chevron.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	chevron.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(chevron)
	return chevron


## 两个排序选项分别绑定明确状态，勾选互斥由当前会话状态统一更新。
func _add_sort_option(node_name: String, caption: String, enabled: bool) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	item.toggle_mode = true
	_style_menu_item(item)
	item.pressed.connect(_activate_sort.bind(enabled))
	item.mouse_entered.connect(item.grab_focus)
	_sort_panel.add_child(item)
	_sort_options.append(item)
	_sort_marks.append(_add_checkmark(item, "SortCheckmark"))


## 显示项分别切换自己的布尔值，不使用互斥按钮组或排序状态。
func _add_display_option(node_name: String, caption: String, index: int) -> void:
	var item := Button.new()
	item.name = node_name
	item.text = caption
	item.toggle_mode = true
	_style_menu_item(item)
	item.pressed.connect(_activate_display.bind(index))
	item.mouse_entered.connect(item.grab_focus)
	_display_panel.add_child(item)
	_display_options.append(item)
	_display_marks.append(_add_checkmark(item, "DisplayCheckmark"))


## 勾号使用正文的中性色，选中行不增加蓝底、模块图标或锁头。
func _add_checkmark(item: Button, node_name: String) -> Label:
	var mark := Label.new()
	mark.name = node_name
	mark.text = "✓"
	mark.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	mark.add_theme_color_override("font_color", GameTheme.TEXT)
	GameTheme.font_size(mark, "font_size", 18)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(mark)
	return mark


## 选择仅由左勾表达；悬停和键盘焦点共用浅灰反馈，实际按下也不染蓝。
func _style_menu_item(item: Button) -> void:
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.clip_text = true
	GameTheme.font_size(item, "font_size", 16)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		item.add_theme_color_override(state, Color.TRANSPARENT)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var color := Color(0.78, 0.80, 0.83, 0.38) if state in ["hover", "hover_pressed", "focus"] else Color.TRANSPARENT
		var style := GameTheme.box(color, Color.TRANSPARENT, 10)
		style.set_content_margin_all(10)
		item.add_theme_stylebox_override(state, style)
	var caption := Label.new()
	caption.name = "MenuCaption"
	caption.text = item.text
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_color_override("font_color", GameTheme.TEXT)
	GameTheme.font_size(caption, "font_size", 16)
	item.add_child(caption)
	_captions[item] = caption
	caption.theme_changed.connect(_invalidate_layout)


## 从入口按钮右下方展开；再次调用同一入口相当于收起，且不改变底层页面状态。
func popup_at(anchor: Control) -> void:
	if _open:
		close_menu()
		return
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_open = true
	_hovered_main_index = -1
	_cancel_pending_hover()
	_last_pointer_position = _overlay.get_global_mouse_position()
	_overlay.show()
	_update_placement()
	set_process_input(true)
	set_process(true)
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


## 同步关闭各级面板，外部点击的释放仍由当前浮层吞掉，避免触发底层卡片。
func close_menu(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	_cancel_pending_hover()
	_hovered_main_index = -1
	_sort_open = false
	_display_open = false
	_sort_panel.hide()
	_display_panel.hide()
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	set_process(false)
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


## 同步两项独立的显示偏好，调用者回填设置时不产生新的用户选择信号。
func set_display_options(show_author: bool, show_completion: bool) -> void:
	_show_author = show_author
	_show_completion = show_completion
	for index in range(_display_marks.size()):
		var selected := show_author if index == 0 else show_completion
		_display_marks[index].visible = selected
		_display_options[index].set_pressed_no_signal(selected)


## 稳定帧只比较几何并推进悬停计时；不重复整组测字、排版或上传玻璃参数。
func _process(delta: float) -> void:
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	if _layout_dirty or _last_anchor_transform != _anchor.get_global_transform() or _last_anchor_rect != _anchor.get_global_rect() or _last_viewport_size != get_viewport().get_visible_rect().size:
		_update_placement()
	if _pending_hover_index < 0:
		return
	_hover_elapsed += delta
	if _hover_elapsed < _hover_delay:
		return
	var index := _pending_hover_index
	_cancel_pending_hover()
	if index != _hovered_main_index:
		return
	if index == SORT_INDEX:
		_open_sort_menu(false)
	elif index == DISPLAY_INDEX:
		_open_display_menu(false)
	else:
		_sort_open = false
		_display_open = false
		_sort_panel.hide()
		_display_panel.hide()
		_items[index].grab_focus()


## 字体或翻译变化只标记一次失效，等待本帧主题传播结束再测量最终字形。
func _invalidate_layout() -> void:
	_layout_dirty = true
	_row_layout_cache.clear()


## 鼠标必须真正进入主行才安排展开，键盘返回后静止鼠标不会重开子菜单。
func _handle_pointer_motion(position: Vector2) -> void:
	var active_panel: Panel = _sort_panel if _sort_open else _display_panel if _display_open else null
	var active_index := SORT_INDEX if _sort_open else DISPLAY_INDEX if _display_open else -1
	var index := -1
	if active_panel == null or not active_panel.get_global_rect().has_point(position):
		for item_index in range(_items.size()):
			if _items[item_index].get_global_rect().has_point(position):
				index = item_index
				break
	if index == active_index and index >= 0:
		_submenu_aim_origin = position
	if index != _hovered_main_index:
		_hovered_main_index = index
		_cancel_pending_hover()
		if index >= 0:
			var protect_path := active_panel != null and _moving_toward_submenu(position, active_panel.get_global_rect())
			if not protect_path:
				_items[index].grab_focus()
			if index != active_index and (index > 0 or active_index >= 0):
				_pending_hover_index = index
				_hover_delay = SUBMENU_AIM_DELAY if protect_path else SUBMENU_HOVER_DELAY
	_last_pointer_position = position


## 斜向跨过相邻主行进入已开子菜单时短暂保留分支；停在新行仍会正常切换。
func _moving_toward_submenu(position: Vector2, submenu_rect: Rect2) -> bool:
	var main_rect := _panel.get_global_rect()
	var near_start: Vector2
	var near_end: Vector2
	if submenu_rect.end.x <= main_rect.position.x:
		if position.x >= _last_pointer_position.x:
			return false
		near_start = Vector2(submenu_rect.end.x, submenu_rect.position.y - 8.0)
		near_end = Vector2(submenu_rect.end.x, submenu_rect.end.y + 8.0)
	elif submenu_rect.position.x >= main_rect.end.x:
		if position.x <= _last_pointer_position.x:
			return false
		near_start = Vector2(submenu_rect.position.x, submenu_rect.position.y - 8.0)
		near_end = Vector2(submenu_rect.position.x, submenu_rect.end.y + 8.0)
	else:
		if position.y <= _last_pointer_position.y:
			return false
		near_start = Vector2(submenu_rect.position.x - 8.0, submenu_rect.position.y)
		near_end = Vector2(submenu_rect.end.x + 8.0, submenu_rect.position.y)
	return Geometry2D.point_is_inside_triangle(position, _submenu_aim_origin, near_start, near_end)


## 同步取消驻留，无延迟回调跨越关闭、换页或键盘导航重新打开菜单。
func _cancel_pending_hover() -> void:
	_pending_hover_index = -1
	_hover_elapsed = 0.0


## 独立浮层补入入口的实际缩放一次，继续在原逻辑尺寸内排版和限制边缘。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	_last_anchor_transform = _anchor.get_global_transform()
	_last_anchor_rect = _anchor.get_global_rect()
	_last_viewport_size = get_viewport().get_visible_rect().size
	_layout_dirty = false
	var presentation_scale := _sync_anchor_scale()
	var viewport_size := get_viewport().get_visible_rect().size / presentation_scale
	var menu_size := _layout_rows(_items, viewport_size.x - EDGE_MARGIN * 2.0, false)
	var actual_anchor_rect := _anchor.get_global_rect()
	var anchor_rect := Rect2(actual_anchor_rect.position / presentation_scale, actual_anchor_rect.size / presentation_scale)
	var origin := Vector2(anchor_rect.end.x - menu_size.x, anchor_rect.end.y + ANCHOR_GAP)
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - menu_size.x - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	_panel.position = origin
	_panel.size = menu_size
	_panel.pivot_offset = Vector2(menu_size.x, 0)
	_sync_glass(_glass, menu_size)
	_separator.position = Vector2(18, _items[0].position.y + _items[0].size.y + 6)
	_separator.size = Vector2(menu_size.x - 36, 1)
	for index in [SORT_INDEX, DISPLAY_INDEX]:
		var chevron := _sort_chevron if index == SORT_INDEX else _display_chevron
		chevron.position = Vector2(_items[index].size.x - 28, (_items[index].size.y - 18) * 0.5)
		chevron.size = Vector2(18, 18)
	if _sort_open:
		_place_sort_menu(viewport_size)
	if _display_open:
		_place_display_menu(viewport_size)


## 按翻译后文字测宽，窄窗口改为完整换行；行高同时满足字体与左勾的实际高度。
func _layout_rows(items: Array[Button], available_width: float, checkable: bool) -> Vector2:
	var cache_key := items[0]
	if _row_layout_cache.has(cache_key):
		var cached: Dictionary = _row_layout_cache[cache_key]
		if is_equal_approx(float(cached["available_width"]), available_width):
			return cached["size"]
	var width := MENU_WIDTH
	var left := 42.0 if checkable else 14.0
	var right := 14.0 if checkable else 40.0
	for item in items:
		var caption: Label = _captions[item]
		var font := caption.get_theme_font("font")
		var font_size := caption.get_theme_font_size("font_size")
		width = maxf(width, ceilf(font.get_string_size(caption.tr(caption.text), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x) + left + right + 16.0)
	width = minf(width, maxf(1.0, available_width))
	var y := 8.0
	for index in range(items.size()):
		var item := items[index]
		var caption: Label = _captions[item]
		var text_width := maxf(1.0, width - 16.0 - left - right)
		# 先让 Label 按新宽度更新智能换行最小高度；同时写宽高会被旧的逐字行高钳住。
		caption.size.x = text_width
		var height := maxf(ROW_MIN_HEIGHT, caption.get_minimum_size().y + 20.0)
		item.position = Vector2(8, y)
		item.size = Vector2(width - 16, height)
		caption.position = Vector2(left, 0)
		caption.size = Vector2(text_width, height)
		y += height + ROW_GAP
		if not checkable and index == 0:
			y += 10.0
	var result := Vector2(width, y - ROW_GAP + 8.0)
	_row_layout_cache[cache_key] = {"available_width": available_width, "size": result}
	return result


## CanvasLayer 不继承页根变换；全屏命中层统一缩放，避免菜单与字号重复放大。
func _sync_anchor_scale() -> float:
	var anchor_transform := _anchor.get_global_transform()
	var presentation_scale := maxf(0.01, minf(anchor_transform.x.length(), anchor_transform.y.length()))
	_overlay.position = Vector2.ZERO
	_overlay.scale = Vector2.ONE * presentation_scale
	_overlay.size = get_viewport().get_visible_rect().size / presentation_scale
	return presentation_scale


## 玻璃始终贴合当前面板尺寸，避免字体变化后圆角与外框分离。
func _sync_glass(glass: ColorRect, panel_size: Vector2) -> void:
	glass.position = Vector2.ONE
	glass.size = panel_size - Vector2(2, 2)
	(glass.material as ShaderMaterial).set_shader_parameter("panel_size", glass.size)
	(glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 17.0)


## 排序子菜单保留独立节点和状态，入口位置由实际排版后的排序行决定。
func _place_sort_menu(viewport_size: Vector2) -> void:
	_place_submenu(_sort_panel, _sort_glass, _sort_options, _sort_marks, SORT_INDEX, viewport_size)


## 显示子菜单沿用排序层的尺寸与边界规则，两项勾选不参与主菜单布局。
func _place_display_menu(viewport_size: Vector2) -> void:
	_place_submenu(_display_panel, _display_glass, _display_options, _display_marks, DISPLAY_INDEX, viewport_size)


## 优先向左展开，空间不足改到右侧或下方；文字和勾号都限制在可用画幅内。
func _place_submenu(panel: Panel, glass: ColorRect, items: Array[Button], marks: Array[Label], parent_index: int, viewport_size: Vector2) -> void:
	var menu_size := _layout_rows(items, viewport_size.x - EDGE_MARGIN * 2.0, true)
	var main_rect := Rect2(_panel.position, _panel.size)
	var origin := Vector2(main_rect.position.x - menu_size.x - ANCHOR_GAP, main_rect.position.y + _items[parent_index].position.y)
	if origin.x < EDGE_MARGIN:
		origin = Vector2(main_rect.end.x + ANCHOR_GAP, origin.y)
		if origin.x + menu_size.x > viewport_size.x - EDGE_MARGIN:
			origin = Vector2(main_rect.end.x - menu_size.x, main_rect.end.y + ANCHOR_GAP)
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - menu_size.x - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	panel.position = origin
	panel.size = menu_size
	_sync_glass(glass, menu_size)
	for index in range(items.size()):
		marks[index].position = Vector2(8, 0)
		marks[index].size = Vector2(26, items[index].size.y)


## 鼠标展开时保留主行焦点，点击和键盘进入时才聚焦当前选中的子项。
func _open_sort_menu(focus_submenu: bool = true) -> void:
	_cancel_pending_hover()
	_submenu_aim_origin = _last_pointer_position
	_display_open = false
	_display_panel.hide()
	_sort_open = true
	_sort_panel.show()
	_update_placement()
	if focus_submenu:
		_sort_options[1 if _sort_enabled else 0].grab_focus()
	else:
		_items[SORT_INDEX].grab_focus()


## 返回主菜单时只关闭排序面板，Esc 和向左键都可逐级返回。
func _close_sort_menu() -> void:
	_cancel_pending_hover()
	_sort_open = false
	_sort_panel.hide()
	_items[SORT_INDEX].grab_focus()


## 显示选项不是互斥选择，进入时从第一项开始，保留两项当前的独立状态。
func _open_display_menu(focus_submenu: bool = true) -> void:
	_cancel_pending_hover()
	_submenu_aim_origin = _last_pointer_position
	_sort_open = false
	_sort_panel.hide()
	_display_open = true
	_display_panel.show()
	_update_placement()
	if focus_submenu:
		_display_options[0].grab_focus()
	else:
		_items[DISPLAY_INDEX].grab_focus()


## 返回显示入口时不改变任何偏好，也不关闭仍可继续操作的主菜单。
func _close_display_menu() -> void:
	_cancel_pending_hover()
	_display_open = false
	_display_panel.hide()
	_items[DISPLAY_INDEX].grab_focus()


## 在页面控件处理之前截获关闭和键盘导航，外部完整点击不会穿透到关卡卡片。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if _swallowed_button != MOUSE_BUTTON_NONE and mouse.button_index == _swallowed_button:
			get_viewport().set_input_as_handled()
			if not mouse.pressed:
				_swallowed_button = MOUSE_BUTTON_NONE
				set_process_input(_open)
			return
	if not _open:
		return
	input_observed.emit(event)
	if event is InputEventMouseMotion:
		_handle_pointer_motion((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton or event is InputEventKey or event is InputEventAction or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_cancel_pending_hover()
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		var inside_sort := _sort_open and _sort_panel.get_global_rect().has_point(mouse.position)
		var inside_display := _display_open and _display_panel.get_global_rect().has_point(mouse.position)
		if not _panel.get_global_rect().has_point(mouse.position) and not inside_sort and not inside_display:
			get_viewport().set_input_as_handled()
			if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_swallowed_button = mouse.button_index
				close_menu()
			return
	if event.is_action_pressed("ui_cancel") or ((_sort_open or _display_open) and event.is_action_pressed("ui_left")):
		get_viewport().set_input_as_handled()
		if _sort_open:
			_close_sort_menu()
		elif _display_open:
			_close_display_menu()
		else:
			close_menu()
	elif event.is_action_pressed("ui_right") and _items[SORT_INDEX].has_focus():
		get_viewport().set_input_as_handled()
		_open_sort_menu()
	elif event.is_action_pressed("ui_right") and _items[DISPLAY_INDEX].has_focus():
		get_viewport().set_input_as_handled()
		_open_display_menu()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_focus_next", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(1)
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_focus_prev", false, true):
		get_viewport().set_input_as_handled()
		_move_focus(-1)
	elif event.is_action_pressed("ui_accept") and not event.is_echo():
		get_viewport().set_input_as_handled()
		var focused := get_viewport().gui_get_focus_owner()
		if focused in _items:
			_activate(_items.find(focused))
		elif focused in _sort_options and _sort_open:
			_activate_sort(_sort_options.find(focused) == 1)
		elif focused in _display_options and _display_open:
			_activate_display(_display_options.find(focused))
	elif event is InputEventKey or event is InputEventAction or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()


## 当前层内部循环焦点，不把 Tab 或方向键交给背后的选关网格。
func _move_focus(direction: int) -> void:
	var active := _sort_options if _sort_open else _display_options if _display_open else _items
	var index := active.find(get_viewport().gui_get_focus_owner())
	# 悬停展开时焦点仍在主行；首次按上应进入末项，按下则进入首项。
	var next := (0 if direction > 0 else active.size() - 1) if index < 0 else posmod(index + direction, active.size())
	active[next].grab_focus()


## 子菜单在当前浮层展开，实际刷新先隐藏菜单再交给上层，避免重建后悬空引用。
func _activate(index: int) -> void:
	if not _open:
		return
	if index == SORT_INDEX:
		_open_sort_menu()
	elif index == DISPLAY_INDEX:
		_open_display_menu()
	elif index == 0:
		close_menu()
		refresh_requested.emit()


## 先隐藏整组菜单再广播明确排序状态，重复选择当前项不会把它反向切换。
func _activate_sort(enabled: bool) -> void:
	if not _open or not _sort_open:
		return
	close_menu()
	set_sort_enabled(enabled)
	sort_changed.emit(enabled)


## 一次只切换选中的显示项，关闭菜单后发送完整状态供页面同步卡片。
func _activate_display(index: int) -> void:
	if not _open or not _display_open or index not in [0, 1]:
		return
	close_menu()
	set_display_options(not _show_author if index == 0 else _show_author, not _show_completion if index == 1 else _show_completion)
	display_changed.emit(_show_author, _show_completion)


## 翻译通知不在标签更新途中测字，下一帧统一按最终语言重排。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_invalidate_layout()


## 标记视口变化，下一帧读取父容器完成布局后的入口坐标。
func _on_viewport_resized() -> void:
	_invalidate_layout()
