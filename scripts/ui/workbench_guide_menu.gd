class_name WorkbenchGuideMenu
extends CanvasLayer
## 地图指引仅显示目标、玩法说明与动态状态，不改变程序或模拟进度。

const EDGE_MARGIN := 12.0
const ANCHOR_GAP := 8.0
const MIN_WIDTH := 360.0
const MAX_WIDTH := 420.0
const MAX_HEIGHT := 420.0

var goal_label: Label
var description_label: Label
var status_label: Label
var directions_label: Label
var terrain_label: Label
var expand_from_top_right := false
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _title: Label
var _scroll: ScrollContainer
var _body: VBoxContainer
var _anchor: Control
var _goal_source := ""
var _description_source := ""
var _open := false
var _placement_queued := false
var _tween: Tween
var _origin := Vector2.ZERO
var _reveal_progress := 1.0
var _swallowed_button := MOUSE_BUTTON_NONE
var _morph_clip: Control
var _collapse_button: Button
var _morph_target_size := Vector2.ZERO
var _morph_anchor_rect := Rect2()
var _anchor_modulate := Color.WHITE
var _anchor_hidden := false


## 在独立画布层创建玻璃浮窗，展开不会改变地图卡片的大小。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "WorkbenchGuideOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "WorkbenchGuidePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1.0, 0.82), Color(1, 1, 1, 0.88), 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.14)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 4)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "WorkbenchGuideGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_title = GameTheme.label(_panel, "指引", 20)
	_title.name = "WorkbenchGuideTitle"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll = ScrollContainer.new()
	_scroll.name = "WorkbenchGuideScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.focus_mode = Control.FOCUS_ALL
	_panel.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.name = "WorkbenchGuideContent"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 16)
	_scroll.add_child(_body)
	goal_label = _add_paragraph("WorkbenchGuideGoal", false)
	description_label = _add_paragraph("WorkbenchGuideDescription", false)
	status_label = _add_paragraph("WorkbenchGuideStatus", true)
	status_label.hide()
	directions_label = _add_paragraph("WorkbenchGuideDirections", true)
	directions_label.text = "0° → 右    90° ↑ 上    180° ← 左    270° ↓ 下"
	terrain_label = _add_paragraph("WorkbenchGuideTerrain", true)
	terrain_label.text = "每格 = 1 单位；灰色区域为 void，机器不可通过。"
	if expand_from_top_right:
		_build_anchor_morph()
	_apply_content()
	_body.minimum_size_changed.connect(_queue_placement)
	get_viewport().size_changed.connect(_queue_placement)
	set_process_input(false)
	set_process(false)


## 仅装配指引选择入口变形样式，其他页面继续使用原有下拉指引。
func _build_anchor_morph() -> void:
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.08, 0.16, 0.27, 0.12)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 3)
	_panel.add_theme_stylebox_override("panel", surface)
	(_glass.material as ShaderMaterial).shader = load("res://assets/ui/assembly_glass.gdshader")
	(_glass.material as ShaderMaterial).set_shader_parameter("frost", 0.84)
	_morph_clip = Control.new()
	_morph_clip.name = "WorkbenchGuideMorphContent"
	_morph_clip.clip_contents = true
	_morph_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_morph_clip)
	_title.reparent(_morph_clip)
	_title.text = "装配规则"
	_title.add_theme_font_size_override("font_size", 17)
	_scroll.reparent(_morph_clip)
	_collapse_button = Button.new()
	_collapse_button.name = "WorkbenchGuideCollapseButton"
	_collapse_button.icon = load("res://assets/ui/navigation_forward.svg")
	_collapse_button.tooltip_text = "关闭"
	_collapse_button.expand_icon = true
	_collapse_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_collapse_button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_collapse_button.add_theme_constant_override("icon_max_width", 18)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		_collapse_button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		_collapse_button.add_theme_color_override("icon_" + state + "_color", Color.WHITE if state == "normal" else GameTheme.ACCENT)
	_collapse_button.pressed.connect(close_menu)
	_panel.add_child(_collapse_button)


## 指引独立释放时恢复入口外观，避免留下不可见的问号。
func _exit_tree() -> void:
	_restore_anchor_visual()


## 每段正文独立换行，保留段间留白并允许长说明纵向滚动。
func _add_paragraph(node_name: String, muted: bool) -> Label:
	var paragraph := GameTheme.label(_body, "", 14, muted)
	paragraph.name = node_name
	paragraph.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	paragraph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paragraph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return paragraph


## 保留源文案供原生标签即时翻译，配置不会修改关卡数据或玩家程序。
func configure(goal: String, description: String) -> void:
	_goal_source = goal
	_description_source = description
	if is_node_ready():
		_apply_content()
		_queue_placement()


## 仅更新目标和指导，动态状态标签始终由工作台按模拟状态填写。
func _apply_content() -> void:
	goal_label.text = _goal_source
	goal_label.visible = not _goal_source.is_empty()
	description_label.text = _description_source
	description_label.visible = not _description_source.is_empty()


## 默认从问号下方淡入，装配模式由圆钮原地展开；再次触发均可收起。
func popup_at(anchor: Control) -> void:
	if _open:
		close_menu()
		return
	if not is_node_ready() or not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_restore_anchor_visual()
	_anchor = anchor
	if expand_from_top_right:
		_anchor_modulate = anchor.modulate
		_anchor_hidden = true
		anchor.modulate.a = 0.0
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	_overlay.show()
	_scroll.scroll_vertical = 0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_reveal_progress = 0.0
	_update_placement()
	set_process_input(true)
	set_process(expand_from_top_right)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_reveal_progress, 0.0, 1.0, 0.22 if expand_from_top_right else 0.18)
	if expand_from_top_right:
		_collapse_button.grab_focus()
	else:
		_scroll.grab_focus()
	_queue_placement()


## 关闭后恢复入口焦点，外部点击的对应抬起继续拦截以防穿透。
func close_menu(restore_focus: bool = true) -> void:
	if not _open and not (expand_from_top_right and _overlay != null and _overlay.visible):
		return
	_open = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if expand_from_top_right and restore_focus and _reveal_progress > 0.0:
		_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_method(_set_reveal_progress, _reveal_progress, 0.0, 0.16)
		_tween.tween_callback(_finish_close.bind(restore_focus))
		return
	_finish_close(restore_focus)


## 装配动画完整收回后恢复圆钮；页面切换与互斥关闭直接走同一个清理入口。
func _finish_close(restore_focus: bool) -> void:
	_overlay.hide()
	_restore_anchor_visual()
	set_process(false)
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 展开时隐藏入口圆底以免透过玻璃，收回和销毁时恢复原本颜色。
func _restore_anchor_visual() -> void:
	if _anchor_hidden and is_instance_valid(_anchor):
		_anchor.modulate = _anchor_modulate
	_anchor_hidden = false


## 公开浮窗状态，让其他工具栏弹窗及页面切换互斥显示。
func is_open() -> bool:
	return _open


## 默认菜单淡入移动，装配菜单固定右上角变形；文字始终保持原尺寸。
func _set_reveal_progress(progress: float) -> void:
	_reveal_progress = progress
	if expand_from_top_right:
		_panel.size = _morph_anchor_rect.size.lerp(_morph_target_size, progress)
		_panel.position = Vector2(_morph_anchor_rect.end.x - _panel.size.x, _morph_anchor_rect.position.y)
		_glass.position = Vector2.ZERO
		_glass.size = _panel.size
		(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
		_morph_clip.size = _panel.size
		_morph_clip.modulate.a = smoothstep(0.15, 0.75, progress)
		_collapse_button.position = Vector2(_panel.size.x - _morph_anchor_rect.size.x, 0)
		_collapse_button.size = _morph_anchor_rect.size
		return
	_panel.position = _origin + Vector2(0, -8.0 * (1.0 - progress))
	_panel.modulate.a = progress


## 等容器完成换行测量后再计算窗口高度，多个状态更新只排队一次。
func _queue_placement() -> void:
	if not _open or _placement_queued:
		return
	_placement_queued = true
	_update_placement.call_deferred()


## 指引右边缘对齐问号，宽高限制在当前视口内，超长内容保留滚动。
func _update_placement() -> void:
	_placement_queued = false
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if expand_from_top_right:
		_update_morph_placement(viewport_size)
		return
	var width := minf(clampf(viewport_size.x * 0.3, MIN_WIDTH, MAX_WIDTH), maxf(1, viewport_size.x - EDGE_MARGIN * 2))
	_body.custom_minimum_size.x = maxf(1, width - 54)
	var anchor_rect := _anchor.get_global_rect()
	var available_height := maxf(100, viewport_size.y - anchor_rect.end.y - ANCHOR_GAP - EDGE_MARGIN)
	var height_limit := minf(MAX_HEIGHT, minf(available_height, maxf(1, viewport_size.y - EDGE_MARGIN * 2)))
	var natural_height := _body.get_combined_minimum_size().y + 76.0
	var menu_size := Vector2(width, minf(maxf(160, natural_height), height_limit))
	_origin = Vector2(anchor_rect.end.x - width, anchor_rect.end.y + ANCHOR_GAP)
	_origin.x = clampf(_origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - width - EDGE_MARGIN))
	_origin.y = clampf(_origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - menu_size.y - EDGE_MARGIN))
	_panel.size = menu_size
	_glass.position = Vector2.ONE
	_glass.size = menu_size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 17.0)
	_title.position = Vector2(20, 16)
	_title.size = Vector2(maxf(1, width - 40), 30)
	_scroll.position = Vector2(20, 58)
	_scroll.size = Vector2(maxf(1, width - 40), maxf(1, menu_size.y - 76))
	_set_reveal_progress(_reveal_progress)


## 右上弧线严格重合原问号，宽度向左、高度向下展开，正文只裁切而不缩放。
func _update_morph_placement(viewport_size: Vector2) -> void:
	_morph_anchor_rect = _anchor.get_global_rect()
	var width := minf(clampf(viewport_size.x * 0.3, MIN_WIDTH, MAX_WIDTH), maxf(1, _morph_anchor_rect.end.x - EDGE_MARGIN))
	_body.custom_minimum_size.x = maxf(1, width - 54)
	var available_height := maxf(1, viewport_size.y - _morph_anchor_rect.position.y - EDGE_MARGIN)
	var natural_height := _body.get_combined_minimum_size().y + 64.0
	_morph_target_size = Vector2(width, minf(maxf(160, natural_height), minf(MAX_HEIGHT, available_height)))
	var radius := minf(_morph_anchor_rect.size.x, _morph_anchor_rect.size.y) * 0.5
	(_panel.get_theme_stylebox("panel") as StyleBoxFlat).set_corner_radius_all(int(radius))
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", radius)
	_title.position = Vector2(20, 6)
	_title.size = Vector2(maxf(1, width - _morph_anchor_rect.size.x - 32), 30)
	_scroll.position = Vector2(20, 46)
	_scroll.size = Vector2(maxf(1, width - 40), maxf(1, _morph_target_size.y - 64))
	_set_reveal_progress(_reveal_progress)


## 仅变形模式跟随入口位置与可见性，隐藏页面不会留下独立的玻璃层。
func _process(_delta: float) -> void:
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
	elif _open and _anchor.get_global_rect() != _morph_anchor_rect:
		_queue_placement()


## 拦截外部点击和快捷键，键盘焦点与滚动始终停留在只读浮窗内。
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
	elif expand_from_top_right and _collapse_button.has_focus() and event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		close_menu()
	elif event.is_action_pressed("ui_focus_next", false, true) or event.is_action_pressed("ui_focus_prev", false, true):
		get_viewport().set_input_as_handled()
		_scroll.grab_focus()
	elif event is InputEventKey:
		get_viewport().set_input_as_handled()
		var key := event as InputEventKey
		if not key.pressed:
			return
		match key.keycode:
			KEY_DOWN:
				_scroll.scroll_vertical += 36
			KEY_UP:
				_scroll.scroll_vertical -= 36
			KEY_PAGEDOWN:
				_scroll.scroll_vertical += int(_scroll.size.y * 0.85)
			KEY_PAGEUP:
				_scroll.scroll_vertical -= int(_scroll.size.y * 0.85)
			KEY_HOME:
				_scroll.scroll_vertical = 0
			KEY_END:
				_scroll.scroll_vertical = int(_body.size.y)


## 原生标签自动翻译后重新测量段落，避免换语言导致内容裁切。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_queue_placement()
