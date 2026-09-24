class_name AssemblyModuleDrawer
extends CanvasLayer
## 模块目录作为玻璃侧栏覆盖蓝图；开合只改变显示，不占用装配布局空间。

signal open_changed(open: bool)

const WIDTH := 296.0
const EDGE_MARGIN := 12.0
const SHADOW_MARGIN := 16.0

var content_container: VBoxContainer
var title_label: Label
var details_button: Button
var _overlay: Control
var _clip: Control
var _panel: Panel
var _content_clip: Control
var _glass: ColorRect
var _collapse_button: Button
var _scroll: ScrollContainer
var _anchor: Control
var _bounds: Control
var _open := false
var _placement_queued := false
var _reveal_progress := 0.0
var _tween: Tween
var _swallowed_button := MOUSE_BUTTON_NONE
var _last_anchor_rect := Rect2()
var _last_bounds_rect := Rect2()
var _target_size := Vector2.ZERO
var _initial_size := Vector2(40, 40)
var _anchor_modulate := Color.WHITE
var _anchor_hidden := false


## 创建独立玻璃层及标准滚动容器，模块行继续由装配面板生成和管理。
func _ready() -> void:
	layer = 45
	_overlay = Control.new()
	_overlay.name = "AssemblyDrawerOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.name = "AssemblyDrawerBackdrop"
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_clip = Control.new()
	_clip.name = "AssemblyDrawerRevealClip"
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.clip_contents = true
	_overlay.add_child(_clip)
	_panel = Panel.new()
	_panel.name = "AssemblyDrawerPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 20)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.08, 0.16, 0.27, 0.12)
	surface.shadow_size = 10
	surface.shadow_offset = Vector2(0, 3)
	_panel.add_theme_stylebox_override("panel", surface)
	_clip.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "AssemblyDrawerGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/assembly_glass.gdshader")
	glass_material.set_shader_parameter("frost", 0.84)
	glass_material.set_shader_parameter("corner_radius", 20.0)
	_glass.material = glass_material
	_panel.add_child(_glass)
	_content_clip = Control.new()
	_content_clip.name = "AssemblyDrawerContentClip"
	_content_clip.clip_contents = true
	_content_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_content_clip)
	title_label = GameTheme.label(_content_clip, "模块目录", 17)
	title_label.name = "AssemblyDrawerTitle"
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details_button = Button.new()
	details_button.name = "AssemblyModuleDetailsButton"
	details_button.toggle_mode = true
	details_button.tooltip_text = "显示模块说明"
	details_button.icon = load("res://assets/ui/assembly_module_details.svg")
	details_button.expand_icon = true
	details_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	details_button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	details_button.add_theme_constant_override("icon_max_width", 19)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var color := Color(1, 1, 1, 0.10) if state == "normal" else Color(1, 1, 1, 0.36)
		var button_style := GameTheme.box(color, Color.TRANSPARENT, 9)
		button_style.set_content_margin_all(0)
		details_button.add_theme_stylebox_override(state, button_style)
		details_button.add_theme_color_override("icon_" + state + "_color", Color.WHITE)
	details_button.add_theme_color_override("icon_focus_color", Color.WHITE)
	var focus_style := GameTheme.box(Color.TRANSPARENT, Color("99C7FF"), 9)
	focus_style.set_content_margin_all(0)
	details_button.add_theme_stylebox_override("focus", focus_style)
	_content_clip.add_child(details_button)
	_scroll = ScrollContainer.new()
	_scroll.name = "AssemblyDrawerScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.focus_mode = Control.FOCUS_ALL
	_content_clip.add_child(_scroll)
	content_container = VBoxContainer.new()
	content_container.name = "AssemblyDrawerContent"
	content_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_container.add_theme_constant_override("separation", 8)
	_scroll.add_child(content_container)
	_collapse_button = Button.new()
	_collapse_button.name = "AssemblyDrawerCollapseButton"
	_collapse_button.icon = load("res://assets/ui/navigation_back.svg")
	_collapse_button.tooltip_text = "收起模块目录"
	_collapse_button.expand_icon = true
	_collapse_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_collapse_button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_collapse_button.add_theme_constant_override("icon_max_width", 20)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		_collapse_button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		_collapse_button.add_theme_color_override("icon_" + state + "_color", Color.WHITE if state == "normal" else GameTheme.ACCENT)
	_collapse_button.pressed.connect(close_drawer)
	_panel.add_child(_collapse_button)
	_collapse_button.position = Vector2.ZERO
	_collapse_button.size = _initial_size
	content_container.minimum_size_changed.connect(_queue_placement)
	get_viewport().size_changed.connect(_queue_placement)
	set_process_input(false)
	set_process(false)


## 独立侧栏被释放时也恢复原按钮的外观，不能将入口遗留为透明状态。
func _exit_tree() -> void:
	_restore_anchor_visual()


## 同一入口再次触发便收回；玻璃从原圆钮位置向右下扩展，不挤压蓝图。
func toggle_at(anchor: Control, bounds: Control) -> void:
	if _open:
		close_drawer()
		return
	if not is_node_ready() or not is_instance_valid(anchor) or not anchor.is_visible_in_tree() or not is_instance_valid(bounds):
		return
	_restore_anchor_visual()
	_anchor = anchor
	_bounds = bounds
	_initial_size = anchor.size
	_anchor_modulate = anchor.modulate
	_anchor_hidden = true
	anchor.modulate.a = 0.0
	_open = true
	_swallowed_button = MOUSE_BUTTON_NONE
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_overlay.show()
	_reveal_progress = 0.0
	_scroll.scroll_vertical = 0
	_update_placement()
	set_process_input(true)
	set_process(true)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_reveal_progress, 0.0, 1.0, 0.22)
	_collapse_button.grab_focus()
	open_changed.emit(true)
	_queue_placement()


## 收回动画保留同一个内容容器；离开页面可立即关闭，防止画布层残留。
func close_drawer(immediate: bool = false) -> void:
	var was_open := _open
	_open = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if immediate or _reveal_progress <= 0.0:
		_set_reveal_progress(0.0)
		_finish_close()
	elif _overlay != null and _overlay.visible:
		_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_method(_set_reveal_progress, _reveal_progress, 0.0, 0.16)
		_tween.tween_callback(_finish_close)
	if was_open:
		open_changed.emit(false)


## 公开开合状态，供装配快捷键、互斥菜单与入口选中外观使用。
func is_open() -> bool:
	return _open


## 完成收回后才隐藏输入层，外侧点击的释放事件仍会被配对吞掉。
func _finish_close() -> void:
	if _overlay == null:
		return
	_overlay.hide()
	_restore_anchor_visual()
	set_process(false)
	set_process_input(_swallowed_button != MOUSE_BUTTON_NONE)
	if is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 展开时原圆钮不透过玻璃；完整收回后恢复它原有的颜色与透明度。
func _restore_anchor_visual() -> void:
	if _anchor_hidden and is_instance_valid(_anchor):
		_anchor.modulate = _anchor_modulate
	_anchor_hidden = false


## 圆角左上弧线固定在入口，表面向右下展开；内部内容裁切淡入且不改变字号。
func _set_reveal_progress(progress: float) -> void:
	_reveal_progress = progress
	if _panel == null:
		return
	_panel.position = Vector2.ONE * SHADOW_MARGIN
	_panel.size = _initial_size.lerp(_target_size, progress)
	_glass.size = _panel.size
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _panel.size)
	_content_clip.size = _panel.size
	_content_clip.modulate.a = smoothstep(0.15, 0.75, progress)
	_collapse_button.size = _initial_size


## 将多次内容测量合并为一次，说明折叠与本土化只更新面板尺寸。
func _queue_placement() -> void:
	if not _open or _placement_queued:
		return
	_placement_queued = true
	_update_placement.call_deferred()


## 左上角与原加号重合，展开高度始终由卡片决定；说明开关不会使侧栏跳动。
func _update_placement() -> void:
	_placement_queued = false
	if not _open:
		return
	if not is_instance_valid(_anchor) or not is_instance_valid(_bounds) or not _anchor.is_visible_in_tree() or not _bounds.is_visible_in_tree():
		close_drawer(true)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var anchor_rect := _anchor.get_global_rect()
	var bounds_rect := _bounds.get_global_rect()
	_last_anchor_rect = anchor_rect
	_last_bounds_rect = bounds_rect
	var width := minf(WIDTH, maxf(1, viewport_size.x - EDGE_MARGIN * 2))
	var origin := anchor_rect.position
	origin.x = clampf(origin.x, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.x - width - EDGE_MARGIN))
	origin.y = clampf(origin.y, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_size.y - 160.0 - EDGE_MARGIN))
	var bottom := minf(bounds_rect.end.y, viewport_size.y - EDGE_MARGIN)
	var available_height := maxf(1, bottom - origin.y)
	content_container.custom_minimum_size.x = maxf(1, width - 42)
	var height := available_height
	_target_size = Vector2(width, height)
	_clip.position = origin - Vector2.ONE * SHADOW_MARGIN
	_clip.size = _target_size + Vector2.ONE * SHADOW_MARGIN * 2
	_glass.position = Vector2.ZERO
	title_label.position = Vector2(52, 6)
	title_label.size = Vector2(maxf(1, width - 110), 30)
	details_button.position = Vector2(width - 44, 6)
	details_button.size = Vector2(30, 30)
	_scroll.position = Vector2(14, 54)
	_scroll.size = Vector2(width - 28, maxf(1, height - 68))
	_set_reveal_progress(_reveal_progress)


## 父页面隐藏时关闭独立画布层，并在卡片调整布局后跟随入口移动。
func _process(_delta: float) -> void:
	if not is_instance_valid(_anchor) or not is_instance_valid(_bounds) or not _anchor.is_visible_in_tree() or not _bounds.is_visible_in_tree():
		close_drawer(true)
		return
	if _open and (_anchor.get_global_rect() != _last_anchor_rect or _bounds.get_global_rect() != _last_bounds_rect):
		_queue_placement()


## 面板之外的关闭点击及其抬起一并拦截，避免误放置模块或启动图纸拖动。
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
				close_drawer()
			return
	if _open and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close_drawer()


## 语言切换后允许标题和模块说明重新测量，保持同一个目录及选择。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_queue_placement()
