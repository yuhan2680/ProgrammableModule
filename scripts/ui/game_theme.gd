class_name GameTheme
extends RefCounted
## 统一浅色圆角外观；这里只管理显示，不读取关卡规则、装配或世界状态。

const TEXT := Color("1D2433")
const MUTED := Color("647084")
const ACCENT := Color("007AFF")
const SUCCESS := Color("238664")
const ERROR := Color("BE414C")
const PANEL := Color.WHITE
const BACKGROUND := Color("F3F5F9")
# 设置分组直接放在页面底色上，使用独立灰底保持移除白卡后的层次。
const SETTINGS_GROUP_BACKGROUND := Color("E5E7EB")
const SURFACE := Color("EEF2F8")
const LINE := Color("DCE3ED")
const VOID := Color("DCE3EC")
const NAVIGATION_HEIGHT := 44.0
const NAVIGATION_WIDTH := 88.0
const CODE_LIGHT := {
	"background": Color("F5F7FB"), "text": TEXT, "line_number": Color("8793A6"),
	"selection": Color("D5E7FF"), "current_line": Color("EBF1FA"), "caret": ACCENT,
	"focus": Color("A7CDFF"), "ghost": Color("9BA4B2"),
	"error": Color("FBE5E8"), "execution": Color("E2EEFF"),
	"number": Color("B46428"), "symbol": Color("45516B"), "function": Color("236B8F"),
	"keyword": Color("8757AA"), "action": Color("176A94"), "query": Color("167D78"),
	"ready": Color("B07920"), "comment": Color("748298"),
}
const CODE_DARK := {
	"background": Color("121314"), "text": Color("D9DCE1"), "line_number": Color("959BA4"),
	"selection": Color("354961"), "current_line": Color("1D2025"), "caret": Color("E4E8EF"),
	"focus": Color("4B6480"), "ghost": Color("8C929A"),
	"error": Color("3D242B"), "execution": Color("243343"),
	"number": Color("F0B77D"), "symbol": Color("BFC7D2"), "function": Color("91C7DC"),
	"keyword": Color("C8ABEC"), "action": Color("8DC8EB"), "query": Color("84CBBF"),
	"ready": Color("E9C681"), "comment": Color("A1A8B0"),
}
static var _body_font: Font
static var _code_font: Font


## 使用随工程提供的字体，中文和英文在不同电脑上保持相同度量与可读字重。
static func body_font() -> Font:
	if _body_font == null:
		var font := FontVariation.new()
		font.base_font = load("res://assets/fonts/NotoSansSC.ttf")
		font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 500.0}
		_body_font = font
	return _body_font


## 代码字体单独设置中文回退，不能让玩家注释因等宽字体缺字而消失。
static func code_font() -> Font:
	if _code_font == null:
		var font := FontVariation.new()
		font.base_font = load("res://assets/fonts/JetBrainsMono.ttf")
		font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 500.0}
		font.fallbacks = [body_font()]
		_code_font = font
	return _code_font


## 覆盖普通、禁用、只读与弹窗状态，避免默认深色主题混入浅色页面。
static func create_theme() -> Theme:
	var result := Theme.new()
	result.default_font = body_font()
	result.default_font_size = 15
	for kind in ["Label", "Button", "OptionButton", "LineEdit", "TextEdit", "CodeEdit", "PopupMenu", "ItemList", "Tree", "TabBar"]:
		for state in ["font_color", "font_hover_color", "font_focus_color", "font_selected_color", "font_hovered_color", "font_hovered_selected_color", "font_readonly_color", "font_uneditable_color"]:
			result.set_color(state, kind, TEXT)
		result.set_color("font_pressed_color", kind, ACCENT)
		result.set_color("font_hover_pressed_color", kind, ACCENT)
		result.set_color("font_disabled_color", kind, Color("9AA5B5"))
	for kind in ["Button", "OptionButton"]:
		result.set_stylebox("normal", kind, box(SURFACE, Color.TRANSPARENT, 13))
		result.set_stylebox("hover", kind, box(Color("E4EEFC"), Color.TRANSPARENT, 13))
		result.set_stylebox("pressed", kind, box(Color("D7E8FF"), Color.TRANSPARENT, 13))
		result.set_stylebox("hover_pressed", kind, box(Color("D7E8FF"), Color.TRANSPARENT, 13))
		result.set_stylebox("disabled", kind, box(Color("F0F2F6"), Color.TRANSPARENT, 13))
		result.set_stylebox("focus", kind, box(Color.TRANSPARENT, ACCENT, 13))
	result.set_stylebox("panel", "PanelContainer", card())
	result.set_stylebox("panel", "AcceptDialog", card())
	result.set_stylebox("panel", "PopupMenu", card())
	result.set_stylebox("hover", "PopupMenu", box(Color("E4EEFC")))
	# 原生提示保留统一排版与浅色后备外观，嵌入提示由玻璃层绘制真实背景模糊。
	var tooltip := box(Color(1, 1, 1, 0.78), Color(1, 1, 1, 0.72), 18)
	tooltip.content_margin_top = 10
	tooltip.content_margin_bottom = 10
	tooltip.shadow_color = Color(0.1, 0.16, 0.28, 0.10)
	tooltip.shadow_size = 8
	tooltip.shadow_offset = Vector2(0, 3)
	result.set_stylebox("panel", "TooltipPanel", tooltip)
	result.set_color("font_color", "TooltipLabel", TEXT)
	result.set_color("font_shadow_color", "TooltipLabel", Color.TRANSPARENT)
	result.set_color("font_outline_color", "TooltipLabel", Color.TRANSPARENT)
	for kind in ["LineEdit", "TextEdit", "CodeEdit"]:
		result.set_stylebox("normal", kind, box(Color("F5F7FB"), Color.TRANSPARENT, 12))
		result.set_stylebox("read_only", kind, box(Color("F5F7FB"), Color.TRANSPARENT, 12))
		result.set_stylebox("focus", kind, box(Color.TRANSPARENT, Color("A7CDFF"), 12))
		result.set_color("caret_color", kind, ACCENT)
		result.set_color("selection_color", kind, Color("D5E7FF"))
		result.set_color("current_line_color", kind, Color("EBF1FA"))
		result.set_color("line_number_color", kind, Color("8793A6"))
		result.set_color("background_color", kind, Color.TRANSPARENT)
	result.set_font("font", "CodeEdit", code_font())
	for direction in ["up", "down"]:
		result.set_color(direction + "_icon_modulate", "SpinBox", MUTED)
		result.set_color(direction + "_hover_icon_modulate", "SpinBox", ACCENT)
		result.set_color(direction + "_pressed_icon_modulate", "SpinBox", ACCENT)
		result.set_color(direction + "_disabled_icon_modulate", "SpinBox", Color("BDC5D1"))
	result.set_stylebox("panel", "TabContainer", card())
	for kind in ["TabBar", "TabContainer"]:
		for state in ["tab_selected", "tab_hovered", "tab_unselected", "tab_disabled"]:
			result.set_stylebox(state, kind, box(Color.WHITE if state == "tab_selected" else SURFACE, Color.TRANSPARENT, 12))
		result.set_color("font_selected_color", kind, ACCENT)
		result.set_color("font_unselected_color", kind, MUTED)
		result.set_color("font_hovered_color", kind, TEXT)
	for kind in ["ItemList", "Tree"]:
		result.set_stylebox("panel", kind, box(Color("F5F7FB")))
		for state in ["selected", "selected_focus", "hovered", "hovered_selected", "hovered_selected_focus"]:
			result.set_stylebox(state, kind, box(Color("DDEBFF")))
	result.set_color("folder_icon_color", "FileDialog", ACCENT)
	result.set_color("file_icon_color", "FileDialog", MUTED)
	var border := card()
	border.set_expand_margin(SIDE_TOP, 36)
	border.set_content_margin(SIDE_TOP, 36)
	result.set_stylebox("embedded_border", "Window", border)
	result.set_stylebox("embedded_unfocused_border", "Window", border)
	result.set_color("title_color", "Window", TEXT)
	result.set_font("title_font", "Window", body_font())
	result.set_icon("close", "Window", load("res://assets/ui/close.svg"))
	result.set_icon("close_pressed", "Window", load("res://assets/ui/close.svg"))
	var track := box(LINE, Color.TRANSPARENT, 3)
	track.set_content_margin_all(3)
	result.set_stylebox("slider", "HSlider", track)
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = ACCENT
	result.set_stylebox("grabber_area", "HSlider", fill)
	result.set_stylebox("grabber_area_highlight", "HSlider", fill)
	result.set_icon("grabber", "HSlider", load("res://assets/ui/slider.svg"))
	result.set_icon("grabber_highlight", "HSlider", load("res://assets/ui/slider.svg"))
	for kind in ["HSeparator", "VSeparator"]:
		var separator := StyleBoxLine.new()
		separator.color = LINE
		separator.vertical = kind == "VSeparator"
		result.set_stylebox("separator", kind, separator)
	result.set_constant("separation", "VBoxContainer", 10)
	result.set_constant("separation", "HBoxContainer", 10)
	return result


## 保留原有样式构造接口，调用者无需为视觉更新修改操作回调。
static func box(color: Color, border: Color = Color.TRANSPARENT, radius: int = 18) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0.0 else 0)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	return style


## 卡片使用克制的软阴影和更大内边距，与交互控件的浅灰底区分。
static func card() -> StyleBoxFlat:
	var style := box(PANEL, Color.TRANSPARENT, 23)
	style.set_content_margin_all(18)
	style.shadow_color = Color(0.1, 0.16, 0.28, 0.06)
	style.shadow_size = 8
	style.shadow_offset = Vector2(0, 3)
	return style


## 嵌入式引导只由外框绘制完整圆角，透明正文避免接缝处重复圆角和底角露灰。
static func style_guide_dialog(dialog: AcceptDialog) -> void:
	# 先加入场景再调用，才能正确判断是否嵌入；独立原生窗口仍使用普通正文背景。
	if not dialog.is_embedded():
		return
	dialog.transparent_bg = true
	var content := StyleBoxEmpty.new()
	content.set_content_margin_all(18)
	dialog.add_theme_stylebox_override("panel", content)
	var close_icon: Texture2D = load("res://assets/ui/guide_close.svg")
	dialog.add_theme_icon_override("close", close_icon)
	dialog.add_theme_icon_override("close_pressed", load("res://assets/ui/guide_close_pressed.svg"))
	var frame := dialog.get_theme_stylebox("embedded_border", "Window") as StyleBoxFlat
	# 关闭图标偏移指向图像左上角；将其中心放在右上 R 角圆心，顶部与右侧留白相同。
	# 从实际边框读取半径和扩展量，后续调整圆角时无需另行猜测按钮的位置。
	var radius := float(frame.corner_radius_top_right)
	dialog.add_theme_constant_override("close_h_offset", roundi(radius - frame.expand_margin_right + close_icon.get_width() / 2.0))
	dialog.add_theme_constant_override("close_v_offset", roundi(frame.expand_margin_top - radius + close_icon.get_height() / 2.0))


## 给主要操作加蓝色强调；禁用状态仍由原业务逻辑控制并保留原因提示。
static func primary(control: Button) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		control.add_theme_stylebox_override(state, box(Color("1685FF") if state == "hover" else ACCENT, Color.TRANSPARENT, 13))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		control.add_theme_color_override(state, Color.WHITE)


## 仅覆盖单个代码编辑区的颜色；保留字号、提示边距及全部文本和编辑历史。
static func style_code(edit: CodeEdit, mode: String = "light") -> void:
	var palette: Dictionary = CODE_DARK if mode == "dark" else CODE_LIGHT
	edit.begin_bulk_theme_override()
	for state in ["normal", "read_only", "focus"]:
		var style := box(Color.TRANSPARENT if state == "focus" else palette.background, palette.focus if state == "focus" else Color.TRANSPARENT, 12)
		# 提示按钮可能已加大右侧边距；换色不能改变可视宽度或原生滚动位置。
		if edit.has_theme_stylebox_override(state):
			var previous := edit.get_theme_stylebox(state)
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				style.set_content_margin(side, previous.get_content_margin(side))
		edit.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_selected_color", "font_readonly_color", "font_uneditable_color"]:
		edit.add_theme_color_override(state, palette.text)
	var color_keys := {
		"line_number_color": "line_number", "selection_color": "selection",
		"current_line_color": "current_line", "caret_color": "caret",
		"completion_ghost_color": "ghost", "program_error_color": "error",
		"program_execution_color": "execution",
	}
	for color_name: String in color_keys:
		edit.add_theme_color_override(color_name, palette[color_keys[color_name]])
	edit.add_theme_color_override("background_color", Color.TRANSPARENT)
	edit.add_theme_font_override("font", code_font())
	edit.end_bulk_theme_override()
	highlight_program(edit, mode)


## 预览与游戏共用语法色盘，不接入解析器或改写源代码内容；旧调用默认浅色。
static func highlight_program(edit: CodeEdit, mode: String = "light") -> void:
	var palette: Dictionary = CODE_DARK if mode == "dark" else CODE_LIGHT
	var syntax := CodeHighlighter.new()
	syntax.number_color = palette.number
	syntax.symbol_color = palette.symbol
	syntax.function_color = palette.function
	for keyword in ["main", "function", "constant", "value", "variable", "loop", "for", "in", "step", "simultaneously", "if", "else", "null", "Null", "attack", "tick", "onDetected"]:
		syntax.add_keyword_color(keyword, palette.keyword)
	for keyword in ["ready", "shoot"]:
		syntax.add_keyword_color(keyword, palette.ready)
	for keyword in ["distance", "scan", "Angle", "Position", "Distance", "random", "randomInt", "EnemyPosition"]:
		syntax.add_keyword_color(keyword, palette.query)
	syntax.add_keyword_color("move", palette.action)
	syntax.add_color_region("//", "", palette.comment, true)
	edit.syntax_highlighter = syntax


## 添加普通按钮并连接原有用户操作，保留调用接口和节点查找方式。
static func button(parent: Node, caption: String, action: Callable) -> Button:
	var result := Button.new()
	result.text = caption
	result.custom_minimum_size.y = 40
	result.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	result.pressed.connect(action)
	parent.add_child(result)
	return result


## 添加标签；字号和弱化颜色仅用于建立信息层次。
static func label(parent: Node, caption: String, font_size: int = 16, muted: bool = false) -> Label:
	var result := Label.new()
	result.text = caption
	result.add_theme_font_size_override("font_size", font_size)
	if muted:
		result.add_theme_color_override("font_color", MUTED)
	parent.add_child(result)
	return result


## 用统一边距包裹内容，不改变组件的业务归属与生命周期。
static func margin(parent: Node, padding: int = 16) -> MarginContainer:
	var result := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		result.add_theme_constant_override("margin_" + side, padding)
	parent.add_child(result)
	return result


## 选关和关卡内共用同一药丸导航，尺寸、圆角、SVG 与命中区不随页面变化。
static func navigation_pill(parent: Node, back_action: Callable, tooltip: String, prefix: String) -> Panel:
	var panel := Panel.new()
	panel.name = prefix + "Navigation"
	panel.custom_minimum_size = Vector2(NAVIGATION_WIDTH, NAVIGATION_HEIGHT)
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var background := box(Color("EAEDF2"), Color.TRANSPARENT, 22)
	background.set_content_margin_all(0)
	panel.add_theme_stylebox_override("panel", background)
	parent.add_child(panel)
	for index in range(2):
		var left := index == 0
		var button := Button.new()
		button.name = prefix + ("BackButton" if left else "ForwardButton")
		button.icon = load("res://assets/ui/navigation_back.svg" if left else "res://assets/ui/navigation_forward.svg")
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.tooltip_text = tooltip if left else "没有可前进的页面"
		button.disabled = not left
		button.custom_minimum_size = Vector2(NAVIGATION_HEIGHT, NAVIGATION_HEIGHT)
		button.position = Vector2(index * NAVIGATION_HEIGHT, 0)
		button.size = button.custom_minimum_size
		button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			var color := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state == "pressed" else Color.TRANSPARENT
			var style := box(color, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 22)
			style.set_content_margin_all(0)
			# 两个半区只圆化外侧，悬停与焦点底面不会在中缝画出凹角。
			style.corner_radius_top_right = 0 if left else 22
			style.corner_radius_bottom_right = 0 if left else 22
			style.corner_radius_top_left = 22 if left else 0
			style.corner_radius_bottom_left = 22 if left else 0
			button.add_theme_stylebox_override(state, style)
		if left:
			button.pressed.connect(back_action)
		panel.add_child(button)
	var separator := ColorRect.new()
	separator.name = "NavigationSeparator"
	separator.color = Color("DCE1E8")
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	separator.position = Vector2(NAVIGATION_HEIGHT - 0.5, 12)
	separator.size = Vector2(1, 20)
	panel.add_child(separator)
	return panel
