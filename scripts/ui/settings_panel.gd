class_name SettingsPanel
extends Control
## 极简设置页只绑定设置模型，页面返回由外层游戏入口负责。

signal clear_progress_requested
signal clear_user_levels_requested
signal code_colors_requested
signal about_requested

const TOP_FADE_WIDTH := SettingsContentFade.TOP_FADE_WIDTH
const CONTENT_TOP_GAP := SettingsContentFade.CONTENT_TOP_GAP

var settings: GameSettings
# 外层导航提供可见边界，独立面板未注入时使用自身顶部。
var top_boundary: Control

var _volume_slider: HSlider
var _language_option: OptionButton
var _window_resolution_option: OptionButton
var _tab_completion_toggle: SettingsSwitch
var _assembly_free_zoom_toggle: SettingsSwitch
var _code_hints_option: OptionButton
var _status: Label
var _syncing: bool = false
var _card: Control
var _content_fade: SettingsContentFade
var _column: VBoxContainer
var _scroll: ScrollContainer
var _audio_controls: HBoxContainer
var _progress_result: DataResult
var _result_for_user_levels := false
var _keyboard_option_focus := false
var _available_window_resolutions := PackedStringArray()
var _has_window_resolution_availability := false


## 外层须在 add_child 前注入设置模型，避免面板意外访问真实玩家存储。
func _ready() -> void:
	if settings == null:
		GameTheme.label(self, "设置模型未注入。")
		return
	_build_ui()
	set_notify_transform(true)
	get_viewport().gui_focus_changed.connect(_on_content_focus_changed)
	settings.changed.connect(_sync_controls)
	_sync_controls()


## 动态音量悬停提示和错误说明手动刷新，静态标签继续使用原生翻译通知。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready() and _scroll != null:
		_layout_card.call_deferred()
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _volume_slider != null:
		_sync_controls()
		_layout_card.call_deferred()


## 设置分组直接显示在页面背景上，合成内容只在顶部逐渐透明，不绘制外层卡片。
func _build_ui() -> void:
	_content_fade = SettingsContentFade.new()
	_content_fade.name = "SettingsContentFade"
	add_child(_content_fade)
	_card = Control.new()
	# 保留既有布局容器名称与测试定位；Control 本身没有背景或阴影。
	_card.name = "SettingsCard"
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.theme = SettingsContentFade.inherited_theme(self)
	_content_fade.add_child(_card)
	_scroll = ScrollContainer.new()
	_scroll.name = "SettingsScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	_card.add_child(_scroll)
	SettingsScrollFade.attach(_scroll)
	_column = VBoxContainer.new()
	_column.name = "SettingsColumn"
	_column.add_theme_constant_override("separation", 12)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 让滚动条比灰色卡片向右留出 24 像素，内容宽度仍按原来的居中列计算。
	var scroll_content := MarginContainer.new()
	scroll_content.name = "SettingsScrollbarGutter"
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("margin_right", 24)
	scroll_content.add_theme_constant_override("margin_top", int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP)
	scroll_content.add_theme_constant_override("margin_bottom", CONTENT_TOP_GAP)
	_scroll.add_child(scroll_content)
	scroll_content.add_child(_column)
	var sound := VBoxContainer.new()
	sound.add_theme_constant_override("separation", 12)
	_column.add_child(sound)
	var sound_title := GameTheme.label(sound, "音效", 16)
	sound_title.name = "SoundSectionTitle"
	var volume_row := _create_row(sound, "VolumeRow")
	var volume_label := GameTheme.label(volume_row, "主音量", 16)
	volume_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_audio_controls = HBoxContainer.new()
	_audio_controls.add_theme_constant_override("separation", 12)
	_audio_controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	volume_row.add_child(_audio_controls)
	_add_speaker(_audio_controls, "res://assets/ui/settings_speaker_low.svg")
	_volume_slider = HSlider.new()
	_volume_slider.name = "VolumeSlider"
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 100.0
	_volume_slider.step = 1.0
	_volume_slider.custom_minimum_size = Vector2(120, 32)
	_volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume_slider.value_changed.connect(_on_volume_changed)
	_style_volume_slider()
	_audio_controls.add_child(_volume_slider)
	_add_speaker(_audio_controls, "res://assets/ui/settings_speaker_high.svg")
	_add_section_gap()
	var completion := VBoxContainer.new()
	completion.add_theme_constant_override("separation", 12)
	_column.add_child(completion)
	var completion_title := GameTheme.label(completion, "显示", 16)
	completion_title.name = "CompletionSectionTitle"
	var completion_group := PanelContainer.new()
	completion_group.name = "CompletionSettingsGroup"
	var completion_surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 14)
	completion_surface.set_content_margin_all(0)
	completion_group.add_theme_stylebox_override("panel", completion_surface)
	completion.add_child(completion_group)
	var completion_rows := VBoxContainer.new()
	completion_rows.add_theme_constant_override("separation", 0)
	completion_group.add_child(completion_rows)
	_add_window_resolution_row(completion_rows)
	_add_group_divider(completion_rows, "WindowResolutionDivider")
	var completion_row := _create_row(completion_rows, "TabCompletionRow", true)
	var completion_label := GameTheme.label(completion_row, "Tab 补全", 16)
	completion_label.name = "TabCompletionLabel"
	completion_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	completion_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tab_completion_toggle = SettingsSwitch.new()
	_tab_completion_toggle.name = "TabCompletionToggle"
	_tab_completion_toggle.tooltip_text = "Tab 补全"
	_tab_completion_toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tab_completion_toggle.toggled.connect(_on_tab_completion_toggled)
	completion_row.add_child(_tab_completion_toggle)
	_add_group_divider(completion_rows, "AssemblyFreeZoomDivider")
	var zoom_row := _create_row(completion_rows, "AssemblyFreeZoomRow", true)
	var zoom_label := GameTheme.label(zoom_row, "装配图尺寸自由缩放", 16)
	zoom_label.name = "AssemblyFreeZoomLabel"
	zoom_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_assembly_free_zoom_toggle = SettingsSwitch.new()
	_assembly_free_zoom_toggle.name = "AssemblyFreeZoomToggle"
	_assembly_free_zoom_toggle.tooltip_text = "装配图尺寸自由缩放"
	_assembly_free_zoom_toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_assembly_free_zoom_toggle.toggled.connect(_on_assembly_free_zoom_toggled)
	zoom_row.add_child(_assembly_free_zoom_toggle)
	_add_group_divider(completion_rows, "CodeColorsDivider")
	_add_colors_row(completion_rows)
	_add_group_divider(completion_rows, "CodeHintsDivider")
	var hints_row := _create_row(completion_rows, "CodeHintsRow", true)
	var hints_label := GameTheme.label(hints_row, "代码提示", 16)
	hints_label.name = "CodeHintsLabel"
	hints_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_code_hints_option = OptionButton.new()
	_code_hints_option.name = "CodeHintsOption"
	_style_option(_code_hints_option)
	for caption in ["无", "一般", "多"]:
		_code_hints_option.add_item(caption)
	_code_hints_option.item_selected.connect(_on_code_hints_selected)
	hints_row.add_child(_code_hints_option)
	_add_section_gap()
	var display := VBoxContainer.new()
	display.add_theme_constant_override("separation", 12)
	_column.add_child(display)
	var display_title := GameTheme.label(display, "更多", 16)
	display_title.name = "DisplaySectionTitle"
	var more_group := PanelContainer.new()
	more_group.name = "MoreSettingsGroup"
	var more_surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 14)
	more_surface.set_content_margin_all(0)
	more_group.add_theme_stylebox_override("panel", more_surface)
	display.add_child(more_group)
	var more_rows := VBoxContainer.new()
	more_rows.add_theme_constant_override("separation", 0)
	more_group.add_child(more_rows)
	_add_navigation_row(more_rows, "AboutButton", "关于", about_requested.emit, true)
	_add_group_divider(more_rows, "AboutSettingsDivider")
	var language_row := _create_row(more_rows, "LanguageRow", true)
	var language_label := GameTheme.label(language_row, "显示语言", 16)
	language_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	language_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_language_option = OptionButton.new()
	_language_option.name = "LanguageOption"
	_style_option(_language_option)
	# 语言自名始终保持原文，切换界面语言后仍能辨认每个地区选项。
	_language_option.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_language_option.get_popup().auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_language_option.custom_minimum_size.x = 224
	for caption in GameSettings.LANGUAGE_LABELS:
		_language_option.add_item(caption)
	_language_option.item_selected.connect(_on_language_selected)
	_language_option.get_popup().about_to_popup.connect(_fit_language_popup.call_deferred)
	language_row.add_child(_language_option)
	_add_group_divider(more_rows, "MoreSettingsDivider")
	_add_clear_row(more_rows, "ClearProgressButton", "清除预设进度", _request_clear_progress, false)
	_add_group_divider(more_rows, "MoreSettingsUserDivider")
	_add_clear_row(more_rows, "ClearUserLevelsButton", "清除用户关卡", _request_clear_user_levels, true)
	_status = GameTheme.label(_column, "", 14)
	_status.name = "SettingsStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", GameTheme.ERROR)
	_status.hide()
	resized.connect(_layout_card)
	_layout_card.call_deferred()


## 设置分组之间保留一致留白；窄窗口的滚动容器负责纵向溢出。
func _add_section_gap() -> void:
	var section_gap := Control.new()
	section_gap.custom_minimum_size.y = 8
	section_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(section_gap)


## 每个设置使用同样的浅灰水平行，原生容器负责语言切换后的文字和控件对齐。
func _create_row(parent: Node, node_name: String, grouped: bool = false) -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	panel.custom_minimum_size.y = 64
	# 组内行只提供留白，由唯一外框绘制圆角，避免分隔处出现重复圆角。
	var background := GameTheme.box(Color.TRANSPARENT if grouped else GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 0 if grouped else 14)
	background.content_margin_left = 20
	background.content_margin_right = 16
	background.content_margin_top = 10
	background.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", background)
	parent.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)
	return row


## 组内分隔线使用相同内缩距离，不穿过外框圆角。
func _add_group_divider(parent: Node, node_name: String) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 16)
	parent.add_child(margin)
	var divider := ColorRect.new()
	divider.name = node_name
	divider.color = Color("D0D5DD")
	divider.custom_minimum_size.y = 1
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(divider)


## 预设窗口尺寸放在显示分组首行，选项只保存稳定值，窗口行为由外层控制器处理。
func _add_window_resolution_row(parent: Node) -> void:
	var row := _create_row(parent, "WindowResolutionRow", true)
	var label := GameTheme.label(row, "分辨率", 16)
	label.name = "WindowResolutionLabel"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_window_resolution_option = OptionButton.new()
	_window_resolution_option.name = "WindowResolutionOption"
	_style_option(_window_resolution_option)
	for value: String in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS:
		_window_resolution_option.add_item("最大化" if value == "maximized" else value.replace("x", " × "))
	_window_resolution_option.item_selected.connect(_on_window_resolution_selected)
	_window_resolution_option.get_popup().about_to_popup.connect(_fit_option_popup.bind(_window_resolution_option).call_deferred)
	row.add_child(_window_resolution_option)
	_sync_window_resolution_availability()


## 外层依据当前屏幕提供可用项；禁用超出显示范围的尺寸，不在设置页查询或改动系统窗口。
func set_available_window_resolutions(available: PackedStringArray) -> void:
	_available_window_resolutions = available.duplicate()
	_has_window_resolution_availability = true
	_sync_window_resolution_availability()


## 屏幕信息尚未注入时保持全部选项可选，注入后只改变可用状态而不改保存值。
func _sync_window_resolution_availability() -> void:
	if not is_instance_valid(_window_resolution_option):
		return
	for index in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.size():
		var value: String = GameSettings.SUPPORTED_WINDOW_RESOLUTIONS[index]
		_window_resolution_option.set_item_disabled(index, _has_window_resolution_availability and not _available_window_resolutions.has(value))


## 清除行保留键盘焦点，但改用无边框中性填充，取消返回时不会残留红色描边。
func _add_clear_row(parent: Node, node_name: String, caption: String, action: Callable, last_row: bool) -> void:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size.y = 64
	button.add_theme_font_size_override("font_size", 16)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var tint := Color("E8EBF0") if state == "focus" else Color("FBE7E4") if state in ["hover", "pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(tint, Color.TRANSPARENT, 14 if last_row else 0)
		style.corner_radius_top_left = 0
		style.corner_radius_top_right = 0
		style.content_margin_left = 20
		style.content_margin_right = 16
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color("E1463E"))
	button.pressed.connect(action)
	parent.add_child(button)


## 此入口只请求外层显示确认框，面板不会自行删除任何关卡记录或草稿。
func _request_clear_progress() -> void:
	clear_progress_requested.emit()


## 用户关卡使用独立请求，面板不决定地图及对应记录的删除范围。
func _request_clear_user_levels() -> void:
	clear_user_levels_requested.emit()


## 保存清除结果供本页持续显示，切换语言或调节音量时不会丢失这次操作反馈。
func show_progress_result(result: DataResult) -> void:
	_progress_result = result
	_result_for_user_levels = false
	_sync_controls()


## 显示用户关卡操作结果，与预设进度共用状态区域并保留本土化刷新能力。
func show_user_levels_result(result: DataResult) -> void:
	_progress_result = result
	_result_for_user_levels = true
	_sync_controls()


## 音量两端使用同尺度 SVG 扬声器，图像不拦截滑条附近的鼠标事件。
func _add_speaker(parent: Node, path: String) -> void:
	var icon := TextureRect.new()
	icon.texture = load(path)
	icon.custom_minimum_size = Vector2(22, 22)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(icon)


## 音量轨道改用低对比灰色，白色胶囊滑块仍保留原生拖动、滚轮和键盘操作。
func _style_volume_slider() -> void:
	var track := GameTheme.box(Color("D7D9DF"), Color.TRANSPARENT, 3)
	track.set_content_margin_all(0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = Color("A4A9B2")
	_volume_slider.add_theme_stylebox_override("slider", track)
	_volume_slider.add_theme_stylebox_override("grabber_area", fill)
	_volume_slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	var grabber: Texture2D = load("res://assets/ui/settings_slider_grabber.svg")
	for state in ["grabber", "grabber_highlight", "grabber_disabled"]:
		_volume_slider.add_theme_icon_override(state, grabber)
	_volume_slider.add_theme_constant_override("center_grabber", 0)
	_volume_slider.add_theme_stylebox_override("focus", GameTheme.box(Color.TRANSPARENT, Color("BFC8D4"), 10))


## 设置内容从导航底边延伸至页面底部，顶部留白参与滚动，设置列保持居中等宽。
func _layout_card() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_card) or size.x <= 0 or size.y <= 0:
		return
	var top_y := top_boundary.get_global_rect().end.y if is_instance_valid(top_boundary) else global_position.y
	var offset_y := minf(0.0, top_y - global_position.y)
	_card.position = Vector2(0, offset_y)
	_card.size = Vector2(size.x, maxf(0, size.y - offset_y))
	var column_width := minf(620, maxf(0, size.x - 64))
	_audio_controls.custom_minimum_size.x = clampf(column_width * 0.52, 200, 320)
	_scroll.position = Vector2((size.x - column_width) * 0.5, 0)
	_scroll.size = Vector2(column_width + 24, maxf(0, _card.size.y - CONTENT_TOP_GAP))
	_content_fade.set_fade(_scroll.global_position.y, TOP_FADE_WIDTH, get_viewport().get_visible_rect().size.y)


## 原生跟随焦点完成后留出渐隐带，键盘导航不会把正在操作的设置藏在透明区域。
func _on_content_focus_changed(control: Control) -> void:
	if _keyboard_option_focus and is_instance_valid(control) and _column.is_ancestor_of(control):
		_reveal_focused_control.call_deferred(control)


## 仅调整当前设置焦点的可视位置，弹出菜单与其它页面焦点不触发滚动。
func _reveal_focused_control(control: Control) -> void:
	if not _keyboard_option_focus or not is_instance_valid(control) or not control.has_focus() or not is_visible_in_tree():
		return
	var top := _scroll.global_position.y + TOP_FADE_WIDTH + 8
	var control_top := control.get_global_rect().position.y
	if control_top < top:
		_scroll.scroll_vertical -= ceili(top - control_top)


## 原生弹层完成尺寸计算后在游戏画幅内留边，避免新增地区项使底部圆角被裁掉。
func _fit_language_popup() -> void:
	_fit_option_popup(_language_option)


## 语言和分辨率共用弹层边界约束，较小窗口中仍保留完整选项及圆角。
func _fit_option_popup(option: OptionButton) -> void:
	var popup := option.get_popup()
	if not popup.visible or not popup.is_embedded():
		return
	var bounds := get_viewport().get_visible_rect().grow(-8.0)
	popup.position = Vector2i(
		clampf(popup.position.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - popup.size.x)),
		clampf(popup.position.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - popup.size.y))
	)


## 同步模型到控件时屏蔽输入回调，避免切换语言或载入触发重复保存。
func _sync_controls() -> void:
	_syncing = true
	_volume_slider.set_value_no_signal(round(settings.volume * 100.0))
	var volume_caption := tr("静音") if settings.volume == 0.0 else tr("%d%%") % roundi(settings.volume * 100.0)
	_volume_slider.tooltip_text = tr("主音量") + " · " + volume_caption
	_language_option.select(GameSettings.SUPPORTED_LANGUAGES.find(settings.language))
	_window_resolution_option.select(GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find(settings.window_resolution))
	_code_hints_option.select(GameSettings.SUPPORTED_CODE_HINTS.find(settings.code_hints))
	_tab_completion_toggle.set_pressed_no_signal(settings.tab_completion)
	_tab_completion_toggle.queue_redraw()
	_assembly_free_zoom_toggle.set_pressed_no_signal(settings.assembly_free_zoom)
	_assembly_free_zoom_toggle.queue_redraw()
	_sync_status()
	_syncing = false
	_layout_card.call_deferred()


## 当前设置错误优先显示，其次显示最近一次清除反馈；尚无操作结果时保持留白。
func _sync_status() -> void:
	_status.add_theme_color_override("font_color", GameTheme.ERROR)
	if not settings.last_error.is_empty():
		_status.text = tr("设置错误") + "\n" + GameI18n.translate_errors(settings.last_error.split("\n"))
	elif _progress_result == null:
		_status.text = ""
	elif _progress_result.is_ok():
		_status.text = tr("用户关卡及其通关记录、代码和装配草稿已清除。") if _result_for_user_levels else tr("系统自带关卡的通关记录、代码和装配草稿已清除。")
		_status.add_theme_color_override("font_color", GameTheme.SUCCESS)
	else:
		var messages := GameI18n.translate_errors(_progress_result.errors)
		var failure_title := tr("清除用户关卡失败") if _result_for_user_levels else tr("清除预设进度失败")
		_status.text = failure_title + "\n" + messages
	_status.visible = not _status.text.is_empty()


## 音量拖动即时应用并保存，失败说明保持在当前页面。
func _on_volume_changed(value: float) -> void:
	if _syncing:
		return
	settings.set_volume(value / 100.0)
	_sync_controls()


## 按固定选项对应的 locale 修改语言，选项显示名称不会参与存储。
func _on_language_selected(index: int) -> void:
	if _syncing or index < 0 or index >= GameSettings.SUPPORTED_LANGUAGES.size():
		return
	settings.set_language(GameSettings.SUPPORTED_LANGUAGES[index])
	_sync_controls()


## 只接受当前可用的固定选项，保存结果和失败反馈沿用设置模型的统一同步流程。
func _on_window_resolution_selected(index: int) -> void:
	if _syncing or index < 0 or index >= GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.size():
		return
	if _window_resolution_option.is_item_disabled(index):
		return
	settings.set_window_resolution(GameSettings.SUPPORTED_WINDOW_RESOLUTIONS[index])
	_sync_controls()


## 原生切换按钮支持点击与空格键，禁用只影响代码补全而不改变程序内容。
func _on_tab_completion_toggled(enabled: bool) -> void:
	if _syncing:
		return
	settings.set_tab_completion(enabled)
	_sync_controls()


## 装配图查看开关复用设置持久化，外部页面通过 changed 读取新偏好。
func _on_assembly_free_zoom_toggled(enabled: bool) -> void:
	if _syncing:
		return
	settings.set_assembly_free_zoom(enabled)
	_sync_controls()


## 设置选择器使用一致外观并保留原生键盘操作，不留下鼠标点击后的蓝色描边。
func _style_option(option: OptionButton) -> void:
	option.custom_minimum_size = Vector2(180, 40)
	option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	option.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	option.add_theme_font_size_override("font_size", 16)
	option.add_theme_icon_override("arrow", load("res://assets/ui/settings_language_toggle.svg"))
	option.add_theme_constant_override("arrow_margin", 8)
	option.add_theme_constant_override("modulate_arrow", 0)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var color := Color(1, 1, 1, 0.6) if state == "hover" else Color("E7E9ED") if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(color, Color.TRANSPARENT, 10)
		style.content_margin_left = 8
		style.content_margin_right = 12
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		option.add_theme_stylebox_override(state, style)
	option.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 选择固定等级后由模型保存，显示文案和本土化名称不参与存储。
func _on_code_hints_selected(index: int) -> void:
	if _syncing or index < 0 or index >= GameSettings.SUPPORTED_CODE_HINTS.size():
		return
	settings.set_code_hints(GameSettings.SUPPORTED_CODE_HINTS[index])
	_sync_controls()


## 仅键盘导航显示选择器焦点环；鼠标选择菜单后立即撤掉，避免残留蓝色轮廓。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_option_focus = false
	elif event is InputEventKey and event.pressed:
		_keyboard_option_focus = true
	else:
		return
	for option: OptionButton in [_language_option, _code_hints_option, _window_resolution_option]:
		if option != null:
			var focus: StyleBox = GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 10) if _keyboard_option_focus else StyleBoxEmpty.new()
			option.add_theme_stylebox_override("focus", focus)


## 显示分组的中间行进入颜色子页，沿用统一设置导航行。
func _add_colors_row(parent: Node) -> void:
	_add_navigation_row(parent, "CodeColorsButton", "颜色与显示", code_colors_requested.emit)


## 导航行与设置分组共享外观，首行悬停背景保持外框上角而不溢出圆角。
func _add_navigation_row(parent: Node, node_name: String, caption: String, action: Callable, first_row: bool = false) -> void:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.icon = load("res://assets/ui/settings_disclosure.svg")
	button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 20)
	button.add_theme_font_size_override("font_size", 16)
	button.custom_minimum_size.y = 64
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var tint := Color(1, 1, 1, 0.4) if state == "hover" else Color("E8EBF0") if state in ["pressed", "hover_pressed", "focus"] else Color.TRANSPARENT
		var surface := GameTheme.box(tint, Color.TRANSPARENT, 0)
		if first_row:
			surface.corner_radius_top_left = 14
			surface.corner_radius_top_right = 14
		surface.content_margin_left = 20
		surface.content_margin_right = 24
		button.add_theme_stylebox_override(state, surface)
	button.pressed.connect(action)
	parent.add_child(button)
