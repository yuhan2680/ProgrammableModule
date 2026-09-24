class_name ProgramHeader
extends Control
## 编程页页头只管理布局与按钮状态，程序执行和导航仍由外层工作台负责。

signal back_requested
signal run_requested
signal pause_requested
signal stop_requested
signal reset_requested
signal more_requested
signal commands_requested

const HEIGHT := 44.0
const RUN_SIZE := 40.0
const ICON_SIZE := 24
const GAP := 10.0

var navigation: Panel
var back_button: Button
var description_label: Label
var title_label: Label
var goal_label: Label
var run_button: Button
var pause_button: Button
var stop_button: Button
var reset_button: Button
var more_button: Button
var book_button: Button
var _actions: Panel
var _segments: Array[Button] = []
var _separators: Array[ColorRect] = []
var _description := ""
var _goal := ""
var _has_level_heading := false
var _playtest := false
var _run_disabled := false
var _run_reason := ""
var _paused := false
var _has_world := false
var _active := false
var _transition_locked := false


## 创建固定高度导航、运行入口、四段操作胶囊和指令集合按钮。
func _ready() -> void:
	custom_minimum_size = Vector2(400, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	navigation = GameTheme.navigation_pill(self, back_requested.emit, "返回关卡", "Program")
	back_button = navigation.get_node("ProgramBackButton")
	title_label = GameTheme.label(self, "", 22)
	title_label.name = "ProgramHeaderTitle"
	var title_font := GameTheme.body_font().duplicate() as FontVariation
	title_font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 600.0}
	# 收紧字体度量中的上下留白，让标题与小号目标在原有 44 像素页头内完整显示。
	title_font.spacing_top = -2
	title_font.spacing_bottom = -2
	title_label.add_theme_font_override("font", title_font)
	description_label = title_label
	goal_label = GameTheme.label(self, "", 10, true)
	goal_label.name = "ProgramHeaderGoal"
	for label: Label in [title_label, goal_label]:
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.clip_text = true
		# 标题及目标占用剩余栏宽，但整块文字区域都不应触发悬停提示。
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	run_button = _icon_button(self, "RunProgramButton", "res://assets/ui/assembly_confirm.svg", run_requested.emit)
	run_button.custom_minimum_size = Vector2.ONE * RUN_SIZE
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := GameTheme.ACCENT
		if state == "hover":
			fill = Color("1685FF")
		elif state in ["pressed", "hover_pressed"]:
			fill = Color("006CE5")
		elif state == "disabled":
			fill = Color("A6CBF7")
		run_button.add_theme_stylebox_override(state, _button_style(Color.TRANSPARENT if state == "focus" else fill, Color("74B7FF") if state == "focus" else Color.TRANSPARENT, 20))
	run_button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.8))
	_actions = Panel.new()
	_actions.name = "ProgramActionsPill"
	_actions.add_theme_stylebox_override("panel", _button_style(Color("EAEDF2")))
	add_child(_actions)
	pause_button = _icon_button(_actions, "PauseProgramButton", "res://assets/ui/program_pause.svg", pause_requested.emit)
	stop_button = _icon_button(_actions, "StopProgramButton", "res://assets/ui/program_stop.svg", stop_requested.emit)
	reset_button = _icon_button(_actions, "ResetPositionButton", "res://assets/ui/program_reset.svg", reset_requested.emit)
	more_button = _icon_button(_actions, "ProgramMoreButton", "res://assets/ui/assembly_more.svg", more_requested.emit)
	_segments.append(pause_button)
	_segments.append(stop_button)
	_segments.append(reset_button)
	_segments.append(more_button)
	for index in range(3):
		var separator := ColorRect.new()
		separator.name = "ProgramActionSeparator%d" % index
		separator.color = Color("DCE1E8")
		separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_actions.add_child(separator)
		_separators.append(separator)
	book_button = _icon_button(self, "ProgramCommandReferenceButton", "res://assets/ui/assembly_book.svg", commands_requested.emit)
	book_button.add_theme_stylebox_override("normal", _button_style(Color("EAEDF2")))
	resized.connect(_layout_header)
	_update_tooltips()
	_layout_header()
	set_run_state(_run_disabled, _run_reason, _paused, _has_world, _active)


## 兼容旧的单行说明入口，新工作台通过 configure_level 传入标题和目标。
func configure(description: String, playtest: bool = false) -> void:
	_description = description
	_goal = ""
	_has_level_heading = false
	_playtest = playtest
	if run_button == null:
		return
	_update_tooltips()
	_layout_header()


## 将关卡源名称与简短目标分成两行显示，不修改作者保存的标题和规则文本。
func configure_level(title: String, goal: String, playtest: bool = false) -> void:
	_description = title
	_goal = goal
	_has_level_heading = true
	_playtest = playtest
	if run_button == null:
		return
	_update_tooltips()
	_layout_header()


## 接收工作台计算好的状态，保留停止世界和随时重置位置的原有行为。
func set_run_state(run_disabled: bool, reason: String, paused: bool, has_world: bool, active: bool) -> void:
	_run_disabled = run_disabled
	_run_reason = reason
	_paused = paused
	_has_world = has_world
	_active = active
	if run_button == null:
		return
	_apply_button_states()
	pause_button.icon = load("res://assets/ui/program_resume.svg" if paused else "res://assets/ui/program_pause.svg")
	_update_tooltips()


## 布局动画期间集中锁住导航和操作；运行状态更新不会提前解除这个锁。
func set_transition_locked(locked: bool) -> void:
	_transition_locked = locked
	if run_button != null:
		_apply_button_states()


## 运行权限和布局过渡分别计算，过渡完成后恢复当前会话对应的状态。
func _apply_button_states() -> void:
	back_button.disabled = _transition_locked
	run_button.disabled = _transition_locked or _run_disabled
	pause_button.disabled = _transition_locked or not _active
	stop_button.disabled = _transition_locked or not _has_world
	for button: Button in [reset_button, more_button, book_button]:
		button.disabled = _transition_locked


## 每个纯图标入口都提供本土化名称，运行失败原因附在名称之后。
func _update_tooltips() -> void:
	back_button.tooltip_text = tr("返回地图编辑器") if _playtest else tr("返回关卡")
	title_label.text = _description
	title_label.add_theme_font_size_override("font_size", 22 if _has_level_heading else 14)
	title_label.add_theme_color_override("font_color", GameTheme.TEXT if _has_level_heading else GameTheme.MUTED)
	goal_label.text = _goal
	goal_label.visible = _has_level_heading and not _goal.is_empty()
	run_button.tooltip_text = tr("运行程序")
	if not _run_reason.is_empty():
		run_button.tooltip_text += "\n" + tr(_run_reason)
	pause_button.tooltip_text = tr("继续") if _paused else tr("暂停")
	stop_button.tooltip_text = tr("停止")
	reset_button.tooltip_text = tr("重置位置")
	more_button.tooltip_text = tr("更多")
	book_button.tooltip_text = tr("指令集合")


## 图标采用高分辨率SVG并限制绘制宽度，避免原生96像素贴图撑大按钮。
func _icon_button(parent: Node, node_name: String, icon_path: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load(icon_path)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", ICON_SIZE)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.custom_minimum_size = Vector2(HEIGHT, HEIGHT)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		button.add_theme_stylebox_override(state, _button_style(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## 清除默认文字内边距，确保胶囊与圆形命中区尺寸一致。
func _button_style(color: Color, border: Color = Color.TRANSPARENT, radius: int = 22) -> StyleBoxFlat:
	var style := GameTheme.box(color, border, radius)
	style.set_content_margin_all(0)
	return style


## 仅对整个胶囊左右外沿设置圆角，内部悬停底色保持完整分段。
func _style_segment(button: Button, index: int) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.corner_radius_top_left = 22 if index == 0 else 0
		style.corner_radius_bottom_left = 22 if index == 0 else 0
		style.corner_radius_top_right = 22 if index == _segments.size() - 1 else 0
		style.corner_radius_bottom_right = 22 if index == _segments.size() - 1 else 0
		button.add_theme_stylebox_override(state, style)


## 右侧操作贴边固定，标题与目标共用剩余宽度，缩窄窗口时以省略号截断。
func _layout_header() -> void:
	if _actions == null:
		return
	navigation.position = Vector2.ZERO
	navigation.size = Vector2(GameTheme.NAVIGATION_WIDTH, HEIGHT)
	book_button.position = Vector2(size.x - HEIGHT, 0)
	book_button.size = Vector2(HEIGHT, HEIGHT)
	_actions.position = Vector2(book_button.position.x - GAP - HEIGHT * 4, 0)
	_actions.size = Vector2(HEIGHT * 4, HEIGHT)
	var inset := (HEIGHT - RUN_SIZE) * 0.5
	run_button.position = Vector2(_actions.position.x - GAP - HEIGHT + inset, inset)
	run_button.size = Vector2.ONE * RUN_SIZE
	for index in range(_segments.size()):
		_segments[index].position = Vector2(index * HEIGHT, 0)
		_segments[index].size = Vector2(HEIGHT, HEIGHT)
		_style_segment(_segments[index], index)
	for index in range(_separators.size()):
		_separators[index].position = Vector2((index + 1) * HEIGHT - 0.5, 12)
		_separators[index].size = Vector2(1, 20)
	var text_left := GameTheme.NAVIGATION_WIDTH + 16
	var text_width := maxf(0, run_button.position.x - text_left - 16)
	if goal_label.visible:
		var title_height := title_label.get_minimum_size().y
		var goal_height := goal_label.get_minimum_size().y
		var text_top := maxf(0, (HEIGHT - title_height - goal_height) * 0.5)
		title_label.position = Vector2(text_left, text_top)
		title_label.size = Vector2(text_width, title_height)
		goal_label.position = Vector2(text_left, text_top + title_height)
		goal_label.size = Vector2(text_width, goal_height)
	else:
		title_label.position = Vector2(text_left, 0)
		title_label.size = Vector2(text_width, HEIGHT)


## 语言切换只更新显示文本，执行状态仍以工作台传入的值为准。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		_layout_header()
