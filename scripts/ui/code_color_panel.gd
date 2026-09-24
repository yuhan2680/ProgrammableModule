class_name CodeColorPanel
extends Control
## 颜色子页展示只读代码配色预览与开始菜单背景，共用同一设置模型。

const TOP_FADE_WIDTH := SettingsContentFade.TOP_FADE_WIDTH
const CONTENT_TOP_GAP := SettingsContentFade.CONTENT_TOP_GAP

var settings: GameSettings
var top_boundary: Control
var _card: Control
var _content_fade: SettingsContentFade
var _scroll: ScrollContainer
var _column: VBoxContainer
var _options: HBoxContainer
var _status: Label
var _buttons: Dictionary = {}
var _previews: Dictionary = {}
var _keyboard_focus := false
var _background_picker: MenuBackgroundPicker


## 设置由游戏入口注入，预览不读取玩家代码或自己的存档。
func _ready() -> void:
	if settings == null:
		GameTheme.label(self, "设置模型未注入。")
		return
	_build_ui()
	set_notify_transform(true)
	get_viewport().gui_focus_changed.connect(_on_content_focus_changed)
	settings.changed.connect(_sync_controls)
	_sync_controls()


## 颜色与背景选项沿用主设置页的透明布局，保留各个设置分组及缩略图。
func _build_ui() -> void:
	_content_fade = SettingsContentFade.new()
	_content_fade.name = "CodeColorContentFade"
	add_child(_content_fade)
	_card = Control.new()
	_card.name = "CodeColorCard"
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.theme = SettingsContentFade.inherited_theme(self)
	_content_fade.add_child(_card)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	_card.add_child(_scroll)
	SettingsScrollFade.attach(_scroll)
	_column = VBoxContainer.new()
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override("separation", 16)
	# 让滚动条比灰色卡片向右留出 24 像素，内容宽度仍按原来的居中列计算。
	var scroll_content := MarginContainer.new()
	scroll_content.name = "SettingsScrollbarGutter"
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("margin_right", 24)
	scroll_content.add_theme_constant_override("margin_top", int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP)
	scroll_content.add_theme_constant_override("margin_bottom", CONTENT_TOP_GAP)
	_scroll.add_child(scroll_content)
	scroll_content.add_child(_column)
	var title := GameTheme.label(_column, "颜色与显示", 20)
	title.name = "CodeColorTitle"
	var group := PanelContainer.new()
	group.name = "CodeColorGroup"
	var surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 18)
	surface.content_margin_left = 24
	surface.content_margin_right = 24
	surface.content_margin_top = 16
	surface.content_margin_bottom = 16
	group.add_theme_stylebox_override("panel", surface)
	_column.add_child(group)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	group.add_child(row)
	var caption := GameTheme.label(row, "代码区颜色模式", 17)
	caption.name = "CodeColorModeLabel"
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options = HBoxContainer.new()
	_options.add_theme_constant_override("separation", 18)
	row.add_child(_options)
	_add_choice("light", "浅色模式")
	_add_choice("dark", "深色模式")
	var section_gap := Control.new()
	section_gap.custom_minimum_size.y = 6
	_column.add_child(section_gap)
	_background_picker = MenuBackgroundPicker.new()
	_background_picker.name = "MenuBackgroundPicker"
	_background_picker.settings = settings
	_column.add_child(_background_picker)
	_status = GameTheme.label(_column, "", 14)
	_status.name = "CodeColorStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", GameTheme.ERROR)
	resized.connect(_layout_card)
	_layout_card.call_deferred()


## 整张预览及其标签均可点击；缩略代码禁用焦点和编辑，不拦截父按钮操作。
func _add_choice(mode: String, caption: String) -> void:
	var button := Button.new()
	button.name = "CodeColorLightButton" if mode == "light" else "CodeColorDarkButton"
	button.custom_minimum_size = Vector2(120, 120)
	button.toggle_mode = true
	button.tooltip_text = caption
	button.pressed.connect(_choose_mode.bind(mode))
	for state in ["normal", "pressed", "hover_pressed", "hover", "focus"]:
		var fill := Color(1, 1, 1, 0.35) if state == "hover" else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 12)
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	_options.add_child(button)
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 7)
	button.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 5
	content.offset_right = -5
	content.offset_top = 5
	var preview := CodeEdit.new()
	preview.name = "CodeColorPreview"
	preview.custom_minimum_size = Vector2(110, 88)
	preview.editable = false
	preview.focus_mode = Control.FOCUS_NONE
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.context_menu_enabled = false
	preview.minimap_draw = false
	preview.gutters_draw_line_numbers = true
	preview.highlight_current_line = false
	preview.scroll_past_end_of_file = false
	preview.text = "main()\n{\n\n\n}\n"
	preview.add_theme_font_size_override("font_size", 8)
	preview.add_theme_constant_override("line_spacing", 0)
	GameTheme.style_code(preview, mode)
	for state in ["normal", "read_only", "focus"]:
		var style := preview.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.set_corner_radius_all(9)
		style.set_content_margin_all(4)
		preview.add_theme_stylebox_override(state, style)
	content.add_child(preview)
	# CodeEdit 内部的滚动条不能抢走缩略图上的点击或滚轮。
	preview.get_h_scroll_bar().mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.get_v_scroll_bar().mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := GameTheme.label(content, caption, 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buttons[mode] = button
	_previews[mode] = preview


## 点击当前选项保持单选，使用模型的即时通知和失败反馈，不另写配置文件。
func _choose_mode(mode: String) -> void:
	if settings.code_color_mode != mode or not settings.last_error.is_empty():
		settings.set_code_color_mode(mode)
	_sync_controls()


## 选中项只在缩略图边缘显示细蓝色高亮及柔和阴影，不给鼠标焦点留下永久外框。
func _sync_controls() -> void:
	for mode: String in _buttons:
		var selected := settings.code_color_mode == mode
		var button: Button = _buttons[mode]
		button.set_pressed_no_signal(selected)
		var preview: CodeEdit = _previews[mode]
		for state in ["normal", "read_only"]:
			var style := preview.get_theme_stylebox(state).duplicate() as StyleBoxFlat
			style.border_color = Color("89BFFF") if selected else Color(0, 0, 0, 0.06)
			style.set_border_width_all(1)
			style.shadow_size = 5 if selected else 0
			style.shadow_color = Color(0.1, 0.14, 0.2, 0.14)
			style.shadow_offset = Vector2(0, 2)
			preview.add_theme_stylebox_override(state, style)
	_status.text = "" if settings.last_error.is_empty() else tr("设置错误") + "\n" + GameI18n.translate_errors(settings.last_error.split("\n"))
	_status.visible = not _status.text.is_empty()


## 与主设置页共享导航底边和淡出宽度，宽列承载代码预览与背景图库。
func _layout_card() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_card) or size.x <= 0 or size.y <= 0:
		return
	var top_y := top_boundary.get_global_rect().end.y if is_instance_valid(top_boundary) else global_position.y
	var offset_y := minf(0.0, top_y - global_position.y)
	_card.position = Vector2(0, offset_y)
	_card.size = Vector2(size.x, maxf(0, size.y - offset_y))
	var width := minf(740, maxf(0, size.x - 64))
	_scroll.position = Vector2((size.x - width) * 0.5, 0)
	_scroll.size = Vector2(width + 24, maxf(0, _card.size.y - CONTENT_TOP_GAP))
	_content_fade.set_fade(_scroll.global_position.y, TOP_FADE_WIDTH, get_viewport().get_visible_rect().size.y)


## 键盘导航额外避开顶部渐隐带，鼠标按下时不移动当前按钮。
func _on_content_focus_changed(control: Control) -> void:
	if _keyboard_focus and is_instance_valid(control) and _column.is_ancestor_of(control):
		_reveal_focused_control.call_deferred(control)


## 跟随原生焦点布局结束后确保目标处于完全可见区域，弹出窗口不参与滚动。
func _reveal_focused_control(control: Control) -> void:
	if not _keyboard_focus or not is_instance_valid(control) or not control.has_focus() or not is_visible_in_tree():
		return
	var top := _scroll.global_position.y + TOP_FADE_WIDTH + 8
	if control.global_position.y < top:
		_scroll.scroll_vertical -= ceili(top - control.global_position.y)


## 本土化更新只重排文本和错误反馈，保留当前已选颜色。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready() and _scroll != null:
		_layout_card.call_deferred()
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _status != null:
		_sync_controls()
		_layout_card.call_deferred()


## 键盘导航时显示清晰焦点；鼠标或触摸选择只保留真正的模式选中标记。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_focus = false
	elif event is InputEventKey and event.pressed:
		_keyboard_focus = true
	else:
		return
	for button: Button in _buttons.values():
		button.add_theme_stylebox_override("focus", GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 12) if _keyboard_focus else StyleBoxEmpty.new())
