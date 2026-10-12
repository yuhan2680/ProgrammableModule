class_name MapEditorHeader
extends Control
## 地图编辑器页头只负责导航和操作呈现，文档与未保存保护仍由编辑器及外壳处理。

signal back_requested
signal zoom_out_requested
signal zoom_in_requested
signal guide_requested
signal new_requested
signal save_requested
signal undo_requested
signal redo_requested
signal more_requested
signal reload_requested

const HEIGHT := GameTheme.NAVIGATION_HEIGHT
const ICON_SIZE := 22
const GROUP_GAP := 14.0

var navigation: Panel
var back_button: Button
var zoom_out_button: Button
var zoom_in_button: Button
var guide_button: Button
var new_button: Button
var save_button: Button
var undo_button: Button
var redo_button: Button
var more_button: Button
var reload_button: Button
var title_label: Label
var subtitle_label: Label
var _zoom_pill: Panel
var _file_pill: Panel
var _focus_buttons: Array[Button] = []
var _focus_styles: Array[StyleBox] = []
var _keyboard_focus_visible := false
var _icon_raster_scale := 1


## 与选关和编程页共用导航尺寸，右侧按查看、文件编辑及独立重载分组。
func _ready() -> void:
	custom_minimum_size = Vector2(600, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	navigation = GameTheme.navigation_pill(self, back_requested.emit, "返回开始页面", "MapEditor")
	back_button = navigation.get_node("MapEditorBackButton")
	_register_focus_button(back_button)
	title_label = GameTheme.label(self, "地图编辑器", 22)
	title_label.name = "MapEditorTitle"
	var font := GameTheme.body_font().duplicate() as FontVariation
	font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 600.0}
	font.spacing_top = -2
	font.spacing_bottom = -2
	title_label.add_theme_font_override("font", font)
	subtitle_label = GameTheme.label(self, "绘制地形、设置出生点，再保存为地图 JSON。", 10, true)
	subtitle_label.name = "MapEditorSubtitle"
	for label: Label in [title_label, subtitle_label]:
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zoom_pill = _create_pill("MapEditorZoomPill", 3)
	zoom_out_button = _icon_button(_zoom_pill, "MapEditorZoomOutButton", "map_editor_zoom_out", zoom_out_requested.emit, 0, 3)
	zoom_in_button = _icon_button(_zoom_pill, "MapEditorZoomInButton", "map_editor_zoom_in", zoom_in_requested.emit, 1, 3)
	# 横排镜身与加减号需要更宽的图标，命中区仍与页头其他按钮一致。
	for button: Button in [zoom_out_button, zoom_in_button]:
		button.add_theme_constant_override("icon_max_width", 32)
	guide_button = _icon_button(_zoom_pill, "MapEditorGuideButton", "workbench_guide", guide_requested.emit, 2, 3)
	_file_pill = _create_pill("MapEditorFilePill", 5)
	new_button = _icon_button(_file_pill, "MapEditorNewButton", "map_editor_new", new_requested.emit, 0, 5)
	save_button = _icon_button(_file_pill, "MapEditorSaveButton", "map_editor_save", save_requested.emit, 1, 5)
	undo_button = _icon_button(_file_pill, "MapEditorUndoButton", "map_editor_undo", undo_requested.emit, 2, 5)
	redo_button = _icon_button(_file_pill, "MapEditorRedoButton", "map_editor_redo", redo_requested.emit, 3, 5)
	more_button = _icon_button(_file_pill, "MapEditorMoreButton", "assembly_more", more_requested.emit, 4, 5)
	reload_button = _icon_button(self, "MapEditorReloadButton", "map_editor_reload", reload_requested.emit, 0, 1)
	reload_button.add_theme_stylebox_override("normal", _button_style(Color("EAEDF2")))
	resized.connect(_layout_header)
	title_label.minimum_size_changed.connect(_layout_header.call_deferred)
	subtitle_label.minimum_size_changed.connect(_layout_header.call_deferred)
	# 字号会先变更主题、随后才刷新标签缓存；首次载入大字号也必须重新测量两行。
	title_label.theme_changed.connect(_layout_header.call_deferred)
	subtitle_label.theme_changed.connect(_layout_header.call_deferred)
	_update_tooltips()
	_layout_header()


## 导航小 SVG 按显示比例重新栅格化；保留原逻辑图标与命中区，不修改共享纹理。
func set_presentation_scale(factor: float) -> void:
	var raster_scale := ceili(maxf(1.0, factor))
	if raster_scale == _icon_raster_scale or not is_node_ready():
		return
	_icon_raster_scale = raster_scale
	var sources = preload("res://scripts/ui/level_browser_icon_sources.gd")
	for direction: String in ["back", "forward"]:
		var button := navigation.get_node("MapEditor%sButton" % direction.capitalize()) as Button
		var path := "res://assets/ui/navigation_%s.svg" % direction
		var texture := load(path) as Texture2D
		if raster_scale > 1:
			var raster := Image.new()
			if raster.load_svg_from_string(sources.SVG[path], raster_scale) == OK:
				texture = ImageTexture.create_from_image(raster)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 24)
		button.icon = texture


## 每组胶囊保持浅灰底与细分隔线，不增加额外白色卡片或文字工具栏。
func _create_pill(node_name: String, count: int) -> Panel:
	var pill := Panel.new()
	pill.name = node_name
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override("panel", _button_style(Color("EAEDF2")))
	add_child(pill)
	for index in range(count - 1):
		var separator := ColorRect.new()
		separator.name = "Separator%d" % index
		separator.color = Color("DCE1E8")
		separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		separator.position = Vector2((index + 1) * HEIGHT - 0.5, 12)
		separator.size = Vector2(1, 20)
		pill.add_child(separator)
	return pill


## 高清 SVG 以小于命中区的尺寸绘制；分段仅在胶囊外沿保留圆角。
func _icon_button(parent: Node, node_name: String, icon_name: String, action: Callable, index: int, count: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load("res://assets/ui/%s.svg" % icon_name)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.custom_minimum_size = Vector2.ONE * HEIGHT
	button.position = Vector2(index * HEIGHT, 0)
	button.size = button.custom_minimum_size
	button.add_theme_constant_override("icon_max_width", ICON_SIZE)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := _button_style(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT)
		style.corner_radius_top_left = 22 if index == 0 else 0
		style.corner_radius_bottom_left = 22 if index == 0 else 0
		style.corner_radius_top_right = 22 if index == count - 1 else 0
		style.corner_radius_bottom_right = 22 if index == count - 1 else 0
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(action)
	parent.add_child(button)
	_register_focus_button(button)
	return button


## 保存各分段原有圆角焦点样式；鼠标模式仅隐藏描边，不取消按钮的实际焦点。
func _register_focus_button(button: Button) -> void:
	_focus_buttons.append(button)
	_focus_styles.append(button.get_theme_stylebox("focus"))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 菜单会先消费鼠标和Esc等输入，因此允许它同步页头焦点提示的输入方式。
func set_keyboard_focus_visible(enabled: bool) -> void:
	if _keyboard_focus_visible == enabled:
		return
	_keyboard_focus_visible = enabled
	for index in range(_focus_buttons.size()):
		var style: StyleBox = _focus_styles[index] if enabled else StyleBoxEmpty.new()
		_focus_buttons[index].add_theme_stylebox_override("focus", style)


## 让更多菜单继承打开入口时的输入方式，避免鼠标打开菜单却显示键盘选中态。
func is_keyboard_focus_visible() -> bool:
	return _keyboard_focus_visible


## 鼠标操作结束不残留蓝框，键盘导航仍恢复清晰描边，事件继续交给原有控件处理。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		set_keyboard_focus_visible(false)
	elif event is InputEventKey and event.pressed:
		set_keyboard_focus_visible(true)


## 移除文字按钮内边距，44 像素胶囊与其他页头的点击区域一致。
func _button_style(fill: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := GameTheme.box(fill, border, 22)
	style.set_content_margin_all(0)
	return style


## 原生悬停提示继续交给统一玻璃层，标题和空白不挂提示。
func _update_tooltips() -> void:
	back_button.tooltip_text = tr("返回开始页面")
	zoom_out_button.tooltip_text = tr("缩小地图")
	zoom_in_button.tooltip_text = tr("放大地图")
	guide_button.tooltip_text = tr("指引")
	new_button.tooltip_text = tr("新建")
	save_button.tooltip_text = tr("保存")
	undo_button.tooltip_text = tr("撤销")
	redo_button.tooltip_text = tr("重做")
	more_button.tooltip_text = tr("更多")
	reload_button.tooltip_text = tr("重载内容")


## 左侧坐标固定，工具靠右排列；窗口缩小时只截断副标题，不挤压操作按钮。
func _layout_header() -> void:
	if _file_pill == null:
		return
	var title_height := _text_line_height(title_label)
	var subtitle_height := _text_line_height(subtitle_label)
	var line_gap := ceilf(maxf(0, title_label.get_theme_font_size("font_size") / 22.0 - 1.0) * 4.0)
	var heading_height := title_height + line_gap + subtitle_height
	# 手动大字号需要额外行高时才增加页头，图标命中区不随字体重复放大。
	custom_minimum_size.y = maxf(HEIGHT, heading_height)
	var tools_top := maxf(0, (size.y - HEIGHT) * 0.5)
	navigation.position = Vector2(0, tools_top)
	navigation.size = Vector2(GameTheme.NAVIGATION_WIDTH, HEIGHT)
	reload_button.position = Vector2(size.x - HEIGHT, tools_top)
	_file_pill.position = Vector2(reload_button.position.x - GROUP_GAP - HEIGHT * 5, tools_top)
	_file_pill.size = Vector2(HEIGHT * 5, HEIGHT)
	_zoom_pill.position = Vector2(_file_pill.position.x - GROUP_GAP - HEIGHT * 3, tools_top)
	_zoom_pill.size = Vector2(HEIGHT * 3, HEIGHT)
	var text_left := GameTheme.NAVIGATION_WIDTH + 16
	var text_width := maxf(0, _zoom_pill.position.x - text_left - 20)
	var text_top := maxf(0, (size.y - heading_height) * 0.5)
	title_label.position = Vector2(text_left, text_top)
	title_label.size = Vector2(text_width, title_height)
	subtitle_label.position = Vector2(text_left, text_top + title_height + line_gap)
	subtitle_label.size = Vector2(text_width, subtitle_height)


## 直接读取当前字号的字体度量，避免尚未刷新的标签最小高度压缩已放大的文字。
func _text_line_height(label: Label) -> float:
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	return ceilf(maxf(label.get_minimum_size().y, font.get_height(font_size)))


## 切换语言仅刷新标签度量和悬停名称，保留按钮状态及文档内容。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		_layout_header.call_deferred()
