class_name MapEditorHeader
extends Control
## 地图编辑器页头只负责导航和操作呈现，文档与未保存保护仍由编辑器及外壳处理。

signal back_requested
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
var new_button: Button
var save_button: Button
var undo_button: Button
var redo_button: Button
var more_button: Button
var reload_button: Button
var title_label: Label
var subtitle_label: Label
var _file_pill: Panel
var _history_pill: Panel


## 与选关和编程页共用导航尺寸，右侧采用双按钮、三按钮和独立重载入口。
func _ready() -> void:
	custom_minimum_size = Vector2(600, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	navigation = GameTheme.navigation_pill(self, back_requested.emit, "返回开始页面", "MapEditor")
	back_button = navigation.get_node("MapEditorBackButton")
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
	_file_pill = _create_pill("MapEditorFilePill", 2)
	new_button = _icon_button(_file_pill, "MapEditorNewButton", "map_editor_new", new_requested.emit, 0, 2)
	save_button = _icon_button(_file_pill, "MapEditorSaveButton", "map_editor_save", save_requested.emit, 1, 2)
	_history_pill = _create_pill("MapEditorHistoryPill", 3)
	undo_button = _icon_button(_history_pill, "MapEditorUndoButton", "map_editor_undo", undo_requested.emit, 0, 3)
	redo_button = _icon_button(_history_pill, "MapEditorRedoButton", "map_editor_redo", redo_requested.emit, 1, 3)
	more_button = _icon_button(_history_pill, "MapEditorMoreButton", "assembly_more", more_requested.emit, 2, 3)
	reload_button = _icon_button(self, "MapEditorReloadButton", "map_editor_reload", reload_requested.emit, 0, 1)
	reload_button.add_theme_stylebox_override("normal", _button_style(Color("EAEDF2")))
	resized.connect(_layout_header)
	_update_tooltips()
	_layout_header()


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
	return button


## 移除文字按钮内边距，44 像素胶囊与其他页头的点击区域一致。
func _button_style(fill: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := GameTheme.box(fill, border, 22)
	style.set_content_margin_all(0)
	return style


## 原生悬停提示继续交给统一玻璃层，标题和空白不挂提示。
func _update_tooltips() -> void:
	back_button.tooltip_text = tr("返回开始页面")
	new_button.tooltip_text = tr("新建")
	save_button.tooltip_text = tr("保存")
	undo_button.tooltip_text = tr("撤销")
	redo_button.tooltip_text = tr("重做")
	more_button.tooltip_text = tr("更多")
	reload_button.tooltip_text = tr("重载内容")


## 左侧坐标固定，工具靠右排列；窗口缩小时只截断副标题，不挤压操作按钮。
func _layout_header() -> void:
	if _history_pill == null:
		return
	navigation.position = Vector2.ZERO
	navigation.size = Vector2(GameTheme.NAVIGATION_WIDTH, HEIGHT)
	reload_button.position = Vector2(size.x - HEIGHT, 0)
	_history_pill.position = Vector2(reload_button.position.x - GROUP_GAP - HEIGHT * 3, 0)
	_history_pill.size = Vector2(HEIGHT * 3, HEIGHT)
	_file_pill.position = Vector2(_history_pill.position.x - GROUP_GAP - HEIGHT * 2, 0)
	_file_pill.size = Vector2(HEIGHT * 2, HEIGHT)
	var text_left := GameTheme.NAVIGATION_WIDTH + 16
	var text_width := maxf(0, _file_pill.position.x - text_left - 20)
	var title_height := title_label.get_minimum_size().y
	var subtitle_height := subtitle_label.get_minimum_size().y
	var text_top := maxf(0, (HEIGHT - title_height - subtitle_height) * 0.5)
	title_label.position = Vector2(text_left, text_top)
	title_label.size = Vector2(text_width, title_height)
	subtitle_label.position = Vector2(text_left, text_top + title_height)
	subtitle_label.size = Vector2(text_width, subtitle_height)


## 切换语言仅刷新标签度量和悬停名称，保留按钮状态及文档内容。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		_layout_header.call_deferred()
