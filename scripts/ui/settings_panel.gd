class_name SettingsPanel
extends Control
## 极简设置页只绑定设置模型，页面返回由外层游戏入口负责。

signal clear_progress_requested
signal code_colors_requested
signal about_requested
signal player_levels_requested
signal player_profile_requested
signal system_sound_preview_requested
signal system_sound_preview_cancel_requested

const TOP_FADE_WIDTH := SettingsContentFade.TOP_FADE_WIDTH
const CONTENT_TOP_GAP := SettingsContentFade.CONTENT_TOP_GAP
const AUDIO_PREVIEW_DELAY: float = 0.25
const OPTION_GLASS := preload("res://scripts/ui/settings_option_glass.gd")

var settings: GameSettings
# 主菜单白卡提供上下边界；独立面板兼容原来的导航下缘定位。
var card_boundary: Control
var top_boundary: Control
var navigation_title: Label

var _volume_slider: HSlider
var _system_sound_slider: HSlider
var _system_sound_preview_status: Label
var _system_sound_preview_message: String = ""
var _audio_preview_timer: Timer
var _audio_preview_pending: bool = false
var _audio_dragging: bool = false
var _language_option: OptionButton
var _window_resolution_option: OptionButton
var _ui_scale_option: OptionButton
var _ui_scale_label: Label
var _tab_completion_toggle: SettingsSwitch
var _assembly_free_zoom_toggle: SettingsSwitch
var _code_hints_option: OptionButton
var _status: Label
var _syncing: bool = false
var _card: Control
var _content_fade: SettingsContentFade
var _audio_glass_overlay: Control
var _column: VBoxContainer
var _scroll: ScrollContainer
var _scroll_content: MarginContainer
var _audio_controls: HBoxContainer
var _system_sound_controls: HBoxContainer
var _progress_result: DataResult
var _keyboard_option_focus := false
var _available_window_resolutions := PackedStringArray()
var _has_window_resolution_availability := false
var _available_ui_scales := PackedInt32Array()
var _effective_ui_scale := 100


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
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_audio_preview()
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready() and _scroll != null:
		_layout_card.call_deferred()
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _volume_slider != null:
		_sync_controls()
		_layout_card.call_deferred()


## 外层白卡由游戏入口持有，正文合成层只对滚动内容做上下透明渐隐。
func _build_ui() -> void:
	_audio_preview_timer = Timer.new()
	_audio_preview_timer.name = "AudioPreviewTimer"
	_audio_preview_timer.one_shot = true
	_audio_preview_timer.wait_time = AUDIO_PREVIEW_DELAY
	_audio_preview_timer.timeout.connect(_emit_audio_preview)
	add_child(_audio_preview_timer)
	_content_fade = SettingsContentFade.new()
	_content_fade.name = "SettingsContentFade"
	add_child(_content_fade)
	# 玻璃在正文 CanvasGroup 合成后采样，避免 Compatibility 在组内返回白色纹理。
	_audio_glass_overlay = Control.new()
	_audio_glass_overlay.name = "AudioGlassOverlay"
	_audio_glass_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_audio_glass_overlay)
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
	_scroll.scale = Vector2.ONE * SettingsContentFade.CONTENT_SCALE
	SettingsContentFade.style_scrollbar(_scroll.get_v_scroll_bar())
	SettingsScrollFade.attach(_scroll)
	_column = VBoxContainer.new()
	_column.name = "SettingsColumn"
	_column.add_theme_constant_override("separation", 12)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 让滚动条比灰色卡片向右留出 24 像素，内容宽度仍按原来的居中列计算。
	_scroll_content = MarginContainer.new()
	_scroll_content.name = "SettingsScrollbarGutter"
	_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_content.add_theme_constant_override("margin_right", 24)
	_scroll_content.add_theme_constant_override("margin_top", int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP)
	_scroll_content.add_theme_constant_override("margin_bottom", int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP)
	_scroll.add_child(_scroll_content)
	_scroll_content.add_child(_column)
	var basic := VBoxContainer.new()
	basic.name = "BasicSettingsSection"
	basic.add_theme_constant_override("separation", 12)
	_column.add_child(basic)
	var basic_title := GameTheme.label(basic, "基本", 16)
	basic_title.name = "BasicSectionTitle"
	var basic_group := PanelContainer.new()
	basic_group.name = "BasicSettingsGroup"
	var basic_surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 14)
	basic_surface.set_content_margin_all(0)
	basic_group.add_theme_stylebox_override("panel", basic_surface)
	basic.add_child(basic_group)
	_add_navigation_row(basic_group, "PlayerProfileButton", "玩家与统计信息", player_profile_requested.emit, true, true)
	_add_section_gap()
	var sound := VBoxContainer.new()
	sound.add_theme_constant_override("separation", 12)
	_column.add_child(sound)
	var sound_title := GameTheme.label(sound, "音效", 16)
	sound_title.name = "SoundSectionTitle"
	var audio_group := PanelContainer.new()
	audio_group.name = "AudioSettingsGroup"
	var audio_surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 14)
	audio_surface.set_content_margin_all(0)
	audio_group.add_theme_stylebox_override("panel", audio_surface)
	sound.add_child(audio_group)
	var audio_rows := VBoxContainer.new()
	audio_rows.add_theme_constant_override("separation", 0)
	audio_group.add_child(audio_rows)
	_volume_slider = _add_audio_slider(audio_rows, "Volume", "主音量", _on_volume_changed)
	_audio_controls = _volume_slider.get_parent() as HBoxContainer
	_add_group_divider(audio_rows, "AudioSettingsDivider")
	_system_sound_slider = _add_audio_slider(audio_rows, "SystemSound", "系统提示音", _on_system_sound_volume_changed)
	_system_sound_controls = _system_sound_slider.get_parent() as HBoxContainer
	_system_sound_preview_status = GameTheme.label(sound, "", 13)
	_system_sound_preview_status.name = "SystemSoundPreviewStatus"
	_system_sound_preview_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_system_sound_preview_status.add_theme_color_override("font_color", GameTheme.MUTED)
	_system_sound_preview_status.hide()
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
	_add_ui_scale_row(completion_rows)
	_add_group_divider(completion_rows, "UiScaleDivider")
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
	_code_hints_option.get_popup().about_to_popup.connect(_fit_option_popup.bind(_code_hints_option).call_deferred)
	hints_row.add_child(_code_hints_option)
	_add_option_glass(_code_hints_option)
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
	_add_option_glass(_language_option)
	_add_group_divider(more_rows, "PlayerLevelsSettingsDivider")
	_add_navigation_row(more_rows, "PlayerLevelListButton", "玩家关卡列表", player_levels_requested.emit, false)
	_add_group_divider(more_rows, "MoreSettingsDivider")
	_add_clear_row(more_rows, "ClearProgressButton", "清除预设进度", _request_clear_progress, true)
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
	_add_option_glass(_window_resolution_option)
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


## 分辨率下方沿用设置选择器，平台权限未注入时默认禁用，不允许先点再发现不可用。
func _add_ui_scale_row(parent: Node) -> void:
	var row := _create_row(parent, "UiScaleRow", true)
	_ui_scale_label = GameTheme.label(row, "缩放与布局", 16)
	_ui_scale_label.name = "UiScaleLabel"
	_ui_scale_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui_scale_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ui_scale_option = OptionButton.new()
	_ui_scale_option.name = "UiScaleOption"
	_style_option(_ui_scale_option)
	_ui_scale_option.item_selected.connect(_on_ui_scale_selected)
	_ui_scale_option.get_popup().about_to_popup.connect(_fit_option_popup.bind(_ui_scale_option).call_deferred)
	row.add_child(_ui_scale_option)
	_add_option_glass(_ui_scale_option)
	_sync_ui_scale_availability()


## 设置选择器沿用原生菜单，统一勾选高亮、毛玻璃背景和活动滚动条。
func _add_option_glass(option: OptionButton) -> void:
	var glass := OPTION_GLASS.new()
	glass.name = option.name + "Glass"
	glass.option = option
	glass.fit_popup = _fit_option_popup.bind(option)
	add_child(glass)


## 当前平台及物理屏幕可用档位由窗口控制器提供，macOS 整行置灰，屏幕回退只改变实际显示值。
func set_available_ui_scales(available: PackedInt32Array, effective: int) -> void:
	_available_ui_scales = available.duplicate()
	_effective_ui_scale = effective
	_sync_ui_scale_availability()


## 普通屏幕只列三档，4K 再加入高档位；禁用平台保留 100% 文本但不能接收选择。
func _sync_ui_scale_availability() -> void:
	if not is_instance_valid(_ui_scale_option):
		return
	_ui_scale_option.clear()
	var values := _available_ui_scales if not _available_ui_scales.is_empty() else PackedInt32Array([100])
	for value in values:
		_ui_scale_option.add_item("%d%%" % value, value)
	_ui_scale_option.select(values.find(_effective_ui_scale))
	_ui_scale_option.disabled = _available_ui_scales.is_empty()
	_ui_scale_label.add_theme_color_override("font_color", GameTheme.MUTED if _ui_scale_option.disabled else GameTheme.TEXT)
	_ui_scale_option.tooltip_text = "此功能仅适用于 Windows。" if _ui_scale_option.disabled else "缩放与布局"


## 清除行保留键盘焦点，但改用无边框中性填充，取消返回时不会残留红色描边。
func _add_clear_row(parent: Node, node_name: String, caption: String, action: Callable, last_row: bool) -> void:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size.y = 64
	GameTheme.font_size(button, "font_size", 16)
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


## 保存清除结果供本页持续显示，切换语言或调节音量时不会丢失这次操作反馈。
func show_progress_result(result: DataResult) -> void:
	_progress_result = result
	_sync_controls()


## 两级音量共用行、扬声器和滑条外观，保留原生键盘、滚轮及拖动手势。
func _add_audio_slider(parent: Node, prefix: String, caption: String, change_handler: Callable) -> HSlider:
	var row := _create_row(parent, prefix + "Row", true)
	var label := GameTheme.label(row, caption, 16)
	label.name = prefix + "Label"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var controls := HBoxContainer.new()
	controls.name = prefix + "Controls"
	controls.add_theme_constant_override("separation", 12)
	controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(controls)
	_add_speaker(controls, "res://assets/ui/settings_speaker_low.svg")
	var slider := SettingsGlassSlider.new()
	slider.glass_overlay = _audio_glass_overlay
	slider.name = prefix + "Slider"
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.custom_minimum_size = Vector2(120, 32)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(change_handler)
	slider.drag_started.connect(_on_audio_drag_started)
	slider.drag_ended.connect(_on_audio_drag_ended)
	_style_volume_slider(slider)
	controls.add_child(slider)
	_add_speaker(controls, "res://assets/ui/settings_speaker_high.svg")
	return slider


## 音量两端使用同尺度 SVG 扬声器，图像不拦截滑条附近的鼠标事件。
func _add_speaker(parent: Node, path: String) -> void:
	var icon := TextureRect.new()
	icon.texture = load(path)
	# 四倍 SVG 保留高分屏细节，mipmap 让设置正文缩到八成时仍平稳采样。
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.custom_minimum_size = Vector2(22, 22)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(icon)


## 音量轨道保持低对比灰色；旋钮由 SettingsGlassSlider 绘制，原生滑条继续管理输入。
func _style_volume_slider(slider: HSlider) -> void:
	var track := GameTheme.box(Color("D7D9DF"), Color.TRANSPARENT, 3)
	track.set_content_margin_all(0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = Color("A4A9B2")
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	slider.add_theme_constant_override("center_grabber", 0)
	slider.add_theme_stylebox_override("focus", GameTheme.box(Color.TRANSPARENT, Color("BFC8D4"), 10))


## 白卡模式从卡顶滚到卡底，导航留白参与滚动；独立模式仍兼容旧的导航下缘。
func _layout_card() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_card) or size.x <= 0 or size.y <= 0:
		return
	var inside_card := is_instance_valid(card_boundary)
	if inside_card:
		var bounds := get_global_transform().affine_inverse() * card_boundary.get_global_rect()
		_card.position = bounds.position
		_card.size = bounds.size
	else:
		var top_y := top_boundary.get_global_rect().end.y if is_instance_valid(top_boundary) else global_position.y
		var offset_y := minf(0.0, top_y - global_position.y)
		_card.position = Vector2(0, offset_y)
		_card.size = Vector2(size.x, maxf(0, size.y - offset_y))
	var content_scale := SettingsContentFade.CONTENT_SCALE
	var top_padding := SettingsContentFade.CARD_CONTENT_TOP_PADDING if inside_card else int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP
	# 缩小文字与控件，但导航留白和末项清晰区域保持原来的物理尺寸。
	_scroll_content.add_theme_constant_override("margin_top", ceili(top_padding / content_scale))
	_scroll_content.add_theme_constant_override("margin_bottom", ceili((TOP_FADE_WIDTH + CONTENT_TOP_GAP) / content_scale))
	var scroll_rect := SettingsContentFade.content_rect(_card, 620.0, _column.get_combined_minimum_size().x, navigation_title)
	var column_width := scroll_rect.size.x / content_scale - SettingsContentFade.SCROLLBAR_GUTTER
	_audio_controls.custom_minimum_size.x = clampf(column_width * 0.52, 200, 320)
	_system_sound_controls.custom_minimum_size.x = _audio_controls.custom_minimum_size.x
	_scroll.position = scroll_rect.position
	_scroll.size = Vector2(scroll_rect.size.x, maxf(0, scroll_rect.size.y - (0 if inside_card else CONTENT_TOP_GAP))) / content_scale
	var visible_rect := _scroll.get_global_rect()
	_content_fade.set_fade(visible_rect.position.y, TOP_FADE_WIDTH * absf(get_global_transform().get_scale().y), get_viewport().get_visible_rect().size.y, visible_rect.end.y)
	for slider: SettingsGlassSlider in [_volume_slider, _system_sound_slider]:
		slider.set_glass_clip(visible_rect, TOP_FADE_WIDTH * absf(get_global_transform().get_scale().y))


## 原生跟随焦点完成后留出渐隐带，键盘导航不会把正在操作的设置藏在透明区域。
func _on_content_focus_changed(control: Control) -> void:
	if _keyboard_option_focus and is_instance_valid(control) and _column.is_ancestor_of(control):
		_reveal_focused_control.call_deferred(control)


## 仅调整当前设置焦点的可视位置，弹出菜单与其它页面焦点不触发滚动。
func _reveal_focused_control(control: Control) -> void:
	if not _keyboard_option_focus or not is_instance_valid(control) or not control.has_focus() or not is_visible_in_tree():
		return
	var visible_rect := _scroll.get_global_rect()
	var top_inset := SettingsContentFade.CARD_FOCUS_TOP_INSET if is_instance_valid(card_boundary) else TOP_FADE_WIDTH + 8
	var layout_scale := absf(get_global_transform().get_scale().y)
	var top := visible_rect.position.y + top_inset * layout_scale
	var bottom := visible_rect.end.y - (TOP_FADE_WIDTH + 8) * layout_scale
	var focused_rect := control.get_global_rect()
	var scroll_scale := absf(_scroll.get_global_transform().get_scale().y)
	if focused_rect.position.y < top:
		_scroll.scroll_vertical -= ceili((top - focused_rect.position.y) / scroll_scale)
	elif focused_rect.end.y > bottom:
		_scroll.scroll_vertical += ceili((focused_rect.end.y - bottom) / scroll_scale)


## 原生弹层完成尺寸计算后在游戏画幅内留边，避免新增地区项使底部圆角被裁掉。
func _fit_language_popup() -> void:
	_fit_option_popup(_language_option)


## 所有设置菜单对齐选项的右下缘，使用真实画布变换避免缩放与右对齐文字导致横向偏移。
func _fit_option_popup(option: OptionButton) -> void:
	var popup := option.get_popup()
	if not popup.visible or not popup.is_embedded():
		return
	var bounds := get_viewport().get_visible_rect().grow(-8.0)
	# 原生菜单在高字号时可纵向滚动，不能只挪动一个比窗口更高的弹层。
	popup.max_size = Vector2i(0, floori(bounds.size.y))
	if popup.size.y > popup.max_size.y:
		popup.size.y = popup.max_size.y
	var anchor := option.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, option.size)
	var top := anchor.end.y
	# 优先向下展开；底部不足而上方完整可放时翻到上方，其他情况保留原生滚动并收进画幅。
	if top + popup.size.y > bounds.end.y and anchor.position.y - popup.size.y >= bounds.position.y:
		top = anchor.position.y - popup.size.y
	popup.position = Vector2i(
		roundi(clampf(anchor.end.x - popup.size.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - popup.size.x))),
		roundi(clampf(top, bounds.position.y, maxf(bounds.position.y, bounds.end.y - popup.size.y)))
	)


## 同步模型到控件时屏蔽输入回调，避免切换语言或载入触发重复保存。
func _sync_controls() -> void:
	_syncing = true
	_volume_slider.set_value_no_signal(round(settings.volume * 100.0))
	var volume_caption := tr("静音") if settings.volume == 0.0 else tr("%d%%") % roundi(settings.volume * 100.0)
	_volume_slider.tooltip_text = tr("主音量") + " · " + volume_caption
	_system_sound_slider.set_value_no_signal(round(settings.system_sound_volume * 100.0))
	var system_sound_caption := tr("静音") if settings.system_sound_volume == 0.0 else tr("%d%%") % roundi(settings.system_sound_volume * 100.0)
	_system_sound_slider.tooltip_text = tr("系统提示音") + " · " + system_sound_caption
	_sync_system_sound_preview_status()
	_language_option.select(GameSettings.SUPPORTED_LANGUAGES.find(settings.language))
	_window_resolution_option.select(GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find(settings.window_resolution))
	_sync_ui_scale_availability()
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
		_status.text = tr("系统自带关卡的通关记录、代码和装配草稿已清除。")
		_status.add_theme_color_override("font_color", GameTheme.SUCCESS)
	else:
		var messages := GameI18n.translate_errors(_progress_result.errors)
		var failure_title := tr("清除预设进度失败")
		_status.text = failure_title + "\n" + messages
	_status.visible = not _status.text.is_empty()


## 主音量即时应用并保存；实际用户改值才排队试听，程序同步与打开设置保持安静。
func _on_volume_changed(value: float) -> void:
	if _syncing or is_equal_approx(settings.volume, value / 100.0):
		return
	settings.set_volume(value / 100.0)
	_sync_controls()
	_queue_audio_preview()


## 系统提示音独立保存；试听沿用与主音量相同的手势收尾和键盘防抖规则。
func _on_system_sound_volume_changed(value: float) -> void:
	if _syncing or is_equal_approx(settings.system_sound_volume, value / 100.0):
		return
	settings.set_system_sound_volume(value / 100.0)
	_sync_controls()
	_queue_audio_preview()


## 鼠标拖动期间取消空闲定时器，连续经过多个音量值只在手势结束后试听一次。
func _on_audio_drag_started() -> void:
	_audio_dragging = true
	_audio_preview_timer.stop()
	system_sound_preview_cancel_requested.emit()


## 只消费实际改值留下的待试听标记；点击但未改值的滑条不会发声。
func _on_audio_drag_ended(_value_changed: bool) -> void:
	_audio_dragging = false
	_audio_preview_timer.stop()
	_emit_audio_preview()


## 键盘和滚轮停止改值 250 毫秒后试听，两级音量任一静音时立即取消待播请求。
func _queue_audio_preview() -> void:
	if not is_inside_tree() or not is_visible_in_tree() or is_queued_for_deletion():
		return
	# 新的键盘或滚轮改值也要撤销旧解析，防止旧请求在这次调整尚未结束时发声。
	system_sound_preview_cancel_requested.emit()
	if settings.volume <= 0.0 or settings.system_sound_volume <= 0.0:
		_audio_preview_pending = false
		_audio_preview_timer.stop()
		return
	_audio_preview_pending = true
	if not _audio_dragging:
		_audio_preview_timer.start()


## 面板仅请求试听，实际系统声音由外层服务负责；发出前再次检查可见性和静音状态。
func _emit_audio_preview() -> void:
	var pending := _audio_preview_pending
	_audio_preview_pending = false
	if not pending or not is_inside_tree() or not is_visible_in_tree() or is_queued_for_deletion():
		return
	if settings.volume <= 0.0 or settings.system_sound_volume <= 0.0:
		return
	system_sound_preview_requested.emit()


## 隐藏或退出时丢弃手势与定时器状态，旧页面不能在返回后补播试听。
func _cancel_audio_preview() -> void:
	_audio_preview_pending = false
	_audio_dragging = false
	if is_instance_valid(_audio_preview_timer):
		_audio_preview_timer.stop()
	system_sound_preview_cancel_requested.emit()


## 离开场景树时清空延迟试听，销毁后的页面不会继续请求系统声音。
func _exit_tree() -> void:
	_cancel_audio_preview()


## 外层注入系统试听状态，单独保留源文案以支持切换语言且不覆盖设置保存错误。
func set_system_sound_preview_status(message: String) -> void:
	# 读取过程不增减布局高度，只有无法试听等最终反馈才显示说明行。
	_system_sound_preview_message = "" if message == "正在读取系统提示音…" else message
	_sync_system_sound_preview_status()


## 音频状态采用不抢占焦点的轻量文字；无消息时整行收起并恢复原有间距。
func _sync_system_sound_preview_status() -> void:
	if not is_instance_valid(_system_sound_preview_status):
		return
	_system_sound_preview_status.text = tr(_system_sound_preview_message) if not _system_sound_preview_message.is_empty() else ""
	_system_sound_preview_status.visible = not _system_sound_preview_message.is_empty()


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


## 选择必须仍存在于当前屏幕授权列表，原生项标识直接对应稳定百分比。
func _on_ui_scale_selected(index: int) -> void:
	if _syncing or _ui_scale_option.disabled or index < 0 or index >= _ui_scale_option.item_count:
		return
	var value := _ui_scale_option.get_item_id(index)
	if not _available_ui_scales.has(value):
		return
	settings.set_ui_scale(value)
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


## 设置选择器使用一致外观并保留原生键盘操作，所有输入方式均不绘制焦点外框。
func _style_option(option: OptionButton) -> void:
	option.custom_minimum_size = Vector2(180, 40)
	option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	option.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	GameTheme.font_size(option, "font_size", 16)
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


## 记录输入方式以便键盘导航自动滚动到控件，焦点外框始终保持隐藏。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_option_focus = false
	elif event is InputEventKey and event.pressed:
		_keyboard_option_focus = true


## 显示分组的中间行进入颜色子页，沿用统一设置导航行。
func _add_colors_row(parent: Node) -> void:
	_add_navigation_row(parent, "CodeColorsButton", "颜色与显示", code_colors_requested.emit)


## 导航行按首尾位置保留分组外框圆角，单行卡所有交互状态都保持四角圆润。
func _add_navigation_row(parent: Node, node_name: String, caption: String, action: Callable, first_row: bool = false, last_row: bool = false) -> void:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.icon = load("res://assets/ui/settings_disclosure.svg")
	button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 20)
	GameTheme.font_size(button, "font_size", 16)
	button.custom_minimum_size.y = 64
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var tint := Color(1, 1, 1, 0.4) if state == "hover" else Color("E8EBF0") if state in ["pressed", "hover_pressed", "focus"] else Color.TRANSPARENT
		var surface := GameTheme.box(tint, Color.TRANSPARENT, 0)
		if first_row:
			surface.corner_radius_top_left = 14
			surface.corner_radius_top_right = 14
		if last_row:
			surface.corner_radius_bottom_left = 14
			surface.corner_radius_bottom_right = 14
		surface.content_margin_left = 20
		surface.content_margin_right = 24
		button.add_theme_stylebox_override(state, surface)
	button.pressed.connect(action)
	parent.add_child(button)
