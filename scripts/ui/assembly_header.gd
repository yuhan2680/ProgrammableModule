class_name AssemblyHeader
extends Control
## 准备页工具栏只发出操作意图，装配校验、草稿读写和页面切换仍由 GameShell 执行。

signal back_requested
signal confirm_requested
signal save_requested
signal restore_requested
signal help_requested
signal commands_requested

const HEIGHT := 44.0
const CONFIRM_SIZE := 40.0
const ICON_SIZE := 24
const GAP := 10.0

var navigation: Panel
var description_label: Label
var back_button: Button
var confirm_button: Button
var restore_button: Button
var save_button: Button
var help_button: Button
var book_button: Button
var _actions: Panel
var _separators: Array[ColorRect] = []
var _returning_from_code := false
var _playtest := false


## 创建三个独立区域：导航与说明、蓝色确认、保存载入说明胶囊和指令手册。
func _ready() -> void:
	custom_minimum_size = Vector2(356, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigation = GameTheme.navigation_pill(self, back_requested.emit, "返回关卡", "Assembly")
	back_button = navigation.get_node("AssemblyBackButton")
	description_label = GameTheme.label(self, "", 14, true)
	description_label.name = "AssemblyHeaderDescription"
	description_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	description_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	description_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	confirm_button = _icon_button(self, "ConfirmAssemblyButton", "res://assets/ui/assembly_confirm.svg", confirm_requested.emit)
	confirm_button.custom_minimum_size = Vector2.ONE * CONFIRM_SIZE
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var fill := Color("1685FF") if state == "hover" else Color("006CE5") if state == "pressed" else Color("A6CBF7") if state == "disabled" else GameTheme.ACCENT
		confirm_button.add_theme_stylebox_override(state, _button_style(Color.TRANSPARENT if state == "focus" else fill, Color("74B7FF") if state == "focus" else Color.TRANSPARENT, 20))
	confirm_button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.8))
	_actions = Panel.new()
	_actions.name = "AssemblyActionsPill"
	_actions.add_theme_stylebox_override("panel", _button_style(Color("EAEDF2")))
	add_child(_actions)
	save_button = _icon_button(_actions, "SaveAssemblyButton", "res://assets/ui/assembly_save.svg", save_requested.emit)
	restore_button = _icon_button(_actions, "RestoreAssemblyButton", "res://assets/ui/assembly_restore.svg", restore_requested.emit)
	help_button = _icon_button(_actions, "AboutAssemblyButton", "res://assets/ui/assembly_more.svg", help_requested.emit)
	for index in range(2):
		var separator := ColorRect.new()
		separator.name = "AssemblyActionSeparator%d" % index
		separator.color = Color("DCE1E8")
		separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_actions.add_child(separator)
		_separators.append(separator)
	book_button = _icon_button(self, "CommandReferenceButton", "res://assets/ui/assembly_book.svg", commands_requested.emit)
	book_button.add_theme_stylebox_override("normal", _button_style(Color("EAEDF2")))
	resized.connect(_layout_header)
	configure(_returning_from_code, _playtest)


## 页面配置只调整呈现，试玩隐藏保存和载入；确认权限及错误原因由外层设置。
func configure(returning_from_code: bool = false, playtest: bool = false) -> void:
	_returning_from_code = returning_from_code
	_playtest = playtest
	if confirm_button == null:
		return
	confirm_button.tooltip_text = tr("确认装配，返回编程") if returning_from_code else tr("确认装配，开始编程")
	save_button.visible = not playtest
	restore_button.visible = not playtest
	_update_tooltips()
	_layout_header()


## 非确认按钮在语言切换时刷新说明，避免覆盖外层刚更新的装配校验错误。
func _update_tooltips() -> void:
	back_button.tooltip_text = tr("返回地图编辑器") if _playtest else tr("返回关卡")
	description_label.text = "编辑模块后确认，返回编程。" if _returning_from_code else "先组装机器，再开始编写程序。"
	description_label.tooltip_text = tr(description_label.text)
	save_button.tooltip_text = tr("保存草稿文件")
	restore_button.tooltip_text = tr("加载已保存的文件")
	help_button.tooltip_text = tr("关于说明")
	book_button.tooltip_text = tr("指令集合")


## 使用统一44像素命中区与SVG；工具提示为纯图标按钮提供本土化说明。
func _icon_button(parent: Node, node_name: String, icon_path: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load(icon_path)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# SVG 按 4 倍分辨率导入，布局仍按 24 像素绘制，避免全屏时放大低分辨率贴图。
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", ICON_SIZE)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.custom_minimum_size = Vector2(HEIGHT, HEIGHT)
	# SVG 自带最终深色；普通、悬停和焦点状态均保持原色，只有真正禁用时降低透明度。
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var color := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state == "pressed" else Color.TRANSPARENT
		button.add_theme_stylebox_override(state, _button_style(color, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## 去掉文字按钮默认内边距，确保44像素按钮是真圆，胶囊内部仍保持清晰命中分区。
func _button_style(color: Color, border: Color = Color.TRANSPARENT, radius: int = 22) -> StyleBoxFlat:
	var style := GameTheme.box(color, border, radius)
	style.set_content_margin_all(0)
	return style


## 中间分区只圆化整个胶囊的外沿，悬停和焦点底面不会在内部制造凹角。
func _style_segment(button: Button, index: int, count: int) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.corner_radius_top_left = 22 if index == 0 else 0
		style.corner_radius_bottom_left = 22 if index == 0 else 0
		style.corner_radius_top_right = 22 if index == count - 1 else 0
		style.corner_radius_bottom_right = 22 if index == count - 1 else 0
		button.add_theme_stylebox_override(state, style)


## 右侧操作始终贴右固定，说明文字使用剩余空间并省略，窄窗口不会挤掉操作入口。
func _layout_header() -> void:
	if _actions == null:
		return
	navigation.position = Vector2.ZERO
	navigation.size = Vector2(GameTheme.NAVIGATION_WIDTH, HEIGHT)
	# 条件表达式中的数组字面量会丢失元素类型；逐项加入，避免首次布局被运行时类型错误中断。
	var visible_actions: Array[Button] = []
	if not _playtest:
		visible_actions.append(save_button)
		visible_actions.append(restore_button)
	visible_actions.append(help_button)
	var pill_width := HEIGHT * visible_actions.size()
	book_button.position = Vector2(size.x - HEIGHT, 0)
	book_button.size = Vector2(HEIGHT, HEIGHT)
	_actions.position = Vector2(book_button.position.x - GAP - pill_width, 0)
	_actions.size = Vector2(pill_width, HEIGHT)
	# 蓝色实心圆比浅色胶囊更显大，略缩小并在原 44 像素位置中居中，以平衡视觉重量。
	var confirm_inset := (HEIGHT - CONFIRM_SIZE) * 0.5
	confirm_button.position = Vector2(_actions.position.x - GAP - HEIGHT + confirm_inset, confirm_inset)
	confirm_button.size = Vector2.ONE * CONFIRM_SIZE
	for index in range(visible_actions.size()):
		var button := visible_actions[index]
		button.position = Vector2(index * HEIGHT, 0)
		button.size = Vector2(HEIGHT, HEIGHT)
		_style_segment(button, index, visible_actions.size())
	for index in range(_separators.size()):
		_separators[index].visible = index < visible_actions.size() - 1
		_separators[index].position = Vector2((index + 1) * HEIGHT - 0.5, 12)
		_separators[index].size = Vector2(1, 20)
	var text_left := GameTheme.NAVIGATION_WIDTH + 16
	description_label.position = Vector2(text_left, 0)
	description_label.size = Vector2(maxf(0, confirm_button.position.x - text_left - 16), HEIGHT)


## 保留各按钮的功能连接，语言变化只更新静态说明与布局。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		_layout_header()
