class_name AboutGameDialog
extends CanvasLayer
## 关于窗口呈现作者与联系方式；图标连击提供隐藏彩蛋入口，具体页面由外壳管理。

signal link_requested(url: String)
signal easter_egg_requested
signal easter_expansion_finished
signal easter_expansion_canceled

const WEBSITE_URL := "https://naiwenel.com/"
const EMAIL_URL := "mailto:YWMKerman@gmail.com"
const BILIBILI_URL := "https://space.bilibili.com/443343766"
const YOUTUBE_URL := "https://www.youtube.com/@YWMKerman"
const GITHUB_URL := "https://github.com/YWMKerman"
const PANEL_SIZE := Vector2(384, 608)
const CORNER_RADIUS := 36
const CLOSE_DIAMETER := 28
const LOGO_CLICK_TARGET := 7
const EASTER_EXPANSION_SECONDS := 0.85

var _logo: TextureRect
var _logo_click_count := 0
var _logo_pressed := false
var _logo_triggered := false
var _window_focus_generation := 0

var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _layout: VBoxContainer
var _scroll: ScrollContainer
var _content: VBoxContainer
var _error: Label
var _close: Button
var _focusables: Array[BaseButton] = []
var _focus_styles: Array[StyleBox] = []
var _anchor: Control
var _open := false
var _dismiss_button := MOUSE_BUTTON_NONE
var _tween: Tween
var _layout_scale := 1.0
var _opening_progress := 1.0
var _surface: StyleBoxFlat
var _expansion_tween: Tween
var _expansion_active := false
var _expansion_generation := 0
var _expansion_progress := 0.0
var _expansion_origin := Rect2()
var _expansion_content_size := Vector2.ZERO


## 独立画布避开设置内容的透明度遮罩，屏障负责拦截所有底页鼠标输入。
func _ready() -> void:
	layer = 100
	_overlay = Control.new()
	_overlay.name = "AboutGameOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	var dimmer := ColorRect.new()
	dimmer.color = Color(0.13, 0.16, 0.22, 0.045)
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dimmer)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = Panel.new()
	_panel.name = "AboutGamePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color(0.99, 0.995, 1, 0.80), Color(1, 1, 1, 0.85), CORNER_RADIUS)
	_surface = surface
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.10, 0.15, 0.23, 0.14)
	surface.shadow_size = 18
	surface.shadow_offset = Vector2(0, 7)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.name = "AboutGameGlass"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	glass_material.set_shader_parameter("corner_radius", float(CORNER_RADIUS - 1))
	_glass.material = glass_material
	_panel.add_child(_glass)
	_build_content()
	get_viewport().size_changed.connect(_on_viewport_resized)
	set_process_input(false)


## 正文独立滚动，右上角关闭按钮保持在滚动区之外。
func _build_content() -> void:
	_layout = VBoxContainer.new()
	_layout.name = "AboutGameLayout"
	_layout.add_theme_constant_override("separation", 16)
	_panel.add_child(_layout)
	_scroll = ScrollContainer.new()
	_scroll.name = "AboutGameScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	_layout.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.name = "AboutGameContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 0)
	_scroll.add_child(_content)
	var header := _make_section(_content, 5)
	var icon := TextureRect.new()
	icon.name = "AboutGameIcon"
	icon.texture = load("res://assets/ui/workshop.svg")
	icon.custom_minimum_size = Vector2(104, 104)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_STOP
	_logo = icon
	icon.gui_input.connect(_on_logo_input)
	header.add_child(icon)
	var title := _make_label(header, "AboutGameTitle", "可编程模块", 26)
	var title_font := GameTheme.body_font().duplicate() as FontVariation
	title_font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 650.0}
	title.add_theme_font_override("font", title_font)
	_make_label(header, "AboutGameYears", "2026–2027", 14, true, false)
	_add_space(14)
	var authors := _make_section(_content, 3)
	_make_label(authors, "AboutGameAuthorsHeading", "作者", 13, true)
	_make_label(authors, "AboutGameAuthors", "小涵Naiwenel · YWMKerman", 16, false, false)
	_add_space(18)
	var separator := HSeparator.new()
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var line := StyleBoxLine.new()
	line.color = Color(0.60, 0.66, 0.74, 0.25)
	line.thickness = 1
	separator.add_theme_stylebox_override("separator", line)
	_content.add_child(separator)
	_add_space(15)
	_make_label(_content, "AboutGameContactHeading", "联系我们", 18)
	_add_space(10)
	var website := _make_section(_content, 1)
	_make_label(website, "AboutGameWebsiteAuthor", "小涵Naiwenel", 13, true, false)
	_make_link(website, "AboutWebsiteLink", WEBSITE_URL, WEBSITE_URL)
	_add_space(9)
	var social := _make_section(_content, 1)
	_make_label(social, "AboutGameSocialAuthor", "YWMKerman", 13, true, false)
	var platforms := HBoxContainer.new()
	platforms.alignment = BoxContainer.ALIGNMENT_CENTER
	platforms.add_theme_constant_override("separation", 22)
	social.add_child(platforms)
	_make_link(platforms, "AboutBilibiliLink", "Bilibili", BILIBILI_URL)
	_make_link(platforms, "AboutYoutubeLink", "YouTube", YOUTUBE_URL)
	_make_link(platforms, "AboutGithubLink", "GitHub", GITHUB_URL)
	_add_space(8)
	_make_link(_content, "AboutEmailLink", "YWMKerman@gmail.com", EMAIL_URL)
	_error = _make_label(_content, "AboutGameLinkError", "打开链接失败，请稍后重试。", 13)
	_error.add_theme_color_override("font_color", Color("BA473B"))
	_error.hide()
	_close = _make_close_button()
	_focusables.append(_close)
	for index in _focusables.size():
		var button := _focusables[index]
		_focus_styles.append(button.get_theme_stylebox("focus"))
		button.focus_next = button.get_path_to(_focusables[(index + 1) % _focusables.size()])
		button.focus_previous = button.get_path_to(_focusables[posmod(index - 1, _focusables.size())])
		button.focus_entered.connect(_on_focus_entered.bind(button))
	_set_keyboard_focus_visible(false)


## 小分组保持独立间距，让标题、作者和联系地址的层级稳定且易于调整。
func _make_section(parent: Node, separation: int) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", separation)
	parent.add_child(section)
	return section


## 固定身份与地址不参与翻译；界面源串交由Godot通知更新并自动换行。
func _make_label(parent: Node, node_name: String, caption: String, font_size: int, muted: bool = false, translate: bool = true) -> Label:
	var label := GameTheme.label(parent, caption, font_size, muted)
	label.name = node_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not translate:
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	return label


## 留白由容器高度参与布局，不使用正文控件的绝对坐标。
func _add_space(height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(spacer)


## 真实链接保留键盘与鼠标语义；不设置uri，避免绕过外壳直接打开系统程序。
func _make_link(parent: Node, node_name: String, caption: String, url: String) -> LinkButton:
	var link := LinkButton.new()
	link.name = node_name
	link.text = caption
	link.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	link.tooltip_text = url
	link.custom_minimum_size.y = 28
	link.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	link.focus_mode = Control.FOCUS_ALL
	link.mouse_filter = Control.MOUSE_FILTER_STOP
	link.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	link.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	GameTheme.font_size(link, "font_size", 16)
	link.add_theme_color_override("font_color", Color("3073BE"))
	link.add_theme_color_override("font_hover_color", Color("185DAD"))
	link.add_theme_color_override("font_pressed_color", Color("104982"))
	link.add_theme_color_override("font_focus_color", Color("185DAD"))
	var focus := GameTheme.box(Color.TRANSPARENT, Color(0.20, 0.48, 0.81, 0.60), 5)
	focus.set_content_margin_all(2)
	link.add_theme_stylebox_override("focus", focus)
	link.pressed.connect(_request_link.bind(url))
	parent.add_child(link)
	_focusables.append(link)
	return link


## 关闭动作常驻正文之外，缩小窗口或出现链接错误时仍能立即退出。
func _make_close_button() -> Button:
	var button := Button.new()
	button.name = "AboutCloseButton"
	button.icon = load("res://assets/ui/close.svg")
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.tooltip_text = "关闭"
	button.custom_minimum_size = Vector2.ONE * CLOSE_DIAMETER
	button.size = button.custom_minimum_size
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color(0.78, 0.82, 0.88, 0.38)
		if state == "hover":
			fill = Color(0.75, 0.80, 0.87, 0.52)
		elif state in ["pressed", "hover_pressed"]:
			fill = Color(0.68, 0.75, 0.84, 0.56)
		elif state == "focus":
			fill = Color.TRANSPARENT
		var border := Color(0.45, 0.55, 0.69, 0.65) if state == "focus" else Color.TRANSPARENT
		var surface := GameTheme.box(fill, border, CLOSE_DIAMETER / 2)
		surface.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, surface)
	button.pressed.connect(close_dialog)
	_panel.add_child(button)
	return button


## 打开时重置滚动与错误，默认聚焦关闭，并记录原入口供关闭后恢复。
func popup_dialog(anchor: Control) -> void:
	if _open or not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_window_focus_generation += 1
	cancel_easter_expansion(false)
	_reset_logo_clicks()
	_logo_triggered = false
	_open = true
	_dismiss_button = MOUSE_BUTTON_NONE
	_set_keyboard_focus_visible(false)
	_error.hide()
	_scroll.scroll_vertical = 0
	_opening_progress = 0.0
	_overlay.show()
	_update_placement()
	_update_placement.call_deferred()
	set_process_input(true)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_panel.modulate.a = 0
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_apply_opening_progress, 0.0, 1.0, 0.18)
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.14)
	_close.grab_focus()


## 动画只调整相对弹出幅度，视口变化时仍沿用当前白卡的基础呈现比例。
func _apply_opening_progress(progress: float) -> void:
	_opening_progress = progress
	_panel.scale = Vector2.ONE * _layout_scale * lerpf(0.98, 1.0, progress)


## 独立画布不继承入口变换；沿祖先读取白卡比例，避免额外计入设置正文的八成缩放。
func _anchor_layout_scale() -> float:
	var ancestor: Node = _anchor
	while is_instance_valid(ancestor):
		if ancestor.has_meta("ui_menu_layout_scale"):
			return maxf(1.0, float(ancestor.get_meta("ui_menu_layout_scale")))
		ancestor = ancestor.get_parent()
	return 1.0


## 关闭立即释放视觉浮层；外部关闭点击的抬起仍被吞掉，避免触发底页。
func close_dialog(restore_focus: bool = true) -> void:
	_window_focus_generation += 1
	_reset_logo_clicks()
	if not _open:
		return
	_open = false
	cancel_easter_expansion()
	set_process_input(_dismiss_button != MOUSE_BUTTON_NONE)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 外壳用此状态协调设置页面导航和其他模态窗口。
func is_open() -> bool:
	return _open


## 连击后版权卡向四周对称扩展；正文仅淡出，不随着卡片拉伸变形。
func begin_easter_expansion() -> bool:
	if not _open or _expansion_active or not is_inside_tree():
		return false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_opening_progress = 1.0
	_panel.scale = Vector2.ONE * _layout_scale
	_panel.modulate.a = 1.0
	_expansion_active = true
	_expansion_generation += 1
	_expansion_progress = 0.0
	_expansion_origin = Rect2(_panel.position, _panel.size)
	_expansion_content_size = _layout.size
	get_viewport().gui_release_focus()
	_expansion_tween = create_tween().set_parallel(true)
	_expansion_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_expansion_tween.tween_method(_apply_easter_expansion, 0.0, 1.0, EASTER_EXPANSION_SECONDS)
	_expansion_tween.tween_property(_layout, "modulate:a", 0.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_expansion_tween.tween_property(_close, "modulate:a", 0.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_expansion_tween.chain().tween_callback(_finish_easter_expansion.bind(_expansion_generation))
	return true


## 扩展完成后仍保持模态白色底板，等待外壳将海洋淡入后再关闭。
func is_easter_expanding() -> bool:
	return _expansion_active


## 取消会作废旧回调并恢复正常版权卡；外壳主动清理时可关闭通知以避免递归。
func cancel_easter_expansion(notify_canceled: bool = true) -> void:
	var was_active := _expansion_active
	_expansion_active = false
	_expansion_generation += 1
	if _expansion_tween != null and _expansion_tween.is_valid():
		_expansion_tween.kill()
	_expansion_tween = null
	_expansion_progress = 0.0
	_logo_triggered = false
	_reset_logo_clicks()
	if is_instance_valid(_layout):
		_layout.modulate.a = 1.0
		_close.modulate.a = 1.0
		_opening_progress = 1.0
		_panel.scale = Vector2.ONE * _layout_scale
		_panel.modulate.a = 1.0
		_surface.set_corner_radius_all(CORNER_RADIUS)
		_surface.bg_color = Color(0.99, 0.995, 1, 0.80)
		_glass.modulate.a = 1.0
		(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", float(CORNER_RADIUS - 1))
		if _open and is_inside_tree():
			_update_placement()
	if was_active and notify_canceled:
		easter_expansion_canceled.emit()


## 每帧同步卡片、圆角与毛玻璃采样尺寸，最后完整覆盖视口而不留下边角。
func _apply_easter_expansion(progress: float) -> void:
	if not _open or not _expansion_active:
		return
	_expansion_progress = progress
	var available := get_viewport().get_visible_rect().size
	var full_size := available / _layout_scale
	# 内容仍保持逻辑尺寸；完整展开的全局矩形恰好覆盖视口，不能再把物理尺寸放大第二次。
	_panel.position = _expansion_origin.position.lerp((available - full_size) * 0.5, progress)
	_panel.size = _expansion_origin.size.lerp(full_size, progress)
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * _layout_scale
	var radius := int(round(lerpf(float(CORNER_RADIUS), 0.0, progress)))
	_surface.set_corner_radius_all(radius)
	_surface.bg_color = Color(0.99, 0.995, 1, lerpf(0.80, 1.0, progress))
	var inset := Vector2.ONE * (1.0 - progress)
	_glass.position = inset
	_glass.size = (_panel.size - inset * 2.0).max(Vector2.ONE)
	_glass.modulate.a = 1.0 - progress
	var material := _glass.material as ShaderMaterial
	material.set_shader_parameter("panel_size", _glass.size * _layout_scale)
	material.set_shader_parameter("corner_radius", maxf(float(radius - 1), 0.0) * _layout_scale)
	_layout.size = _expansion_content_size
	_layout.position = (_panel.size - _expansion_content_size) * 0.5


## 只允许当前一轮扩展通知外壳，取消或重新打开后旧动画不能延迟启动彩蛋。
func _finish_easter_expansion(generation: int) -> void:
	if not _open or not _expansion_active or generation != _expansion_generation:
		return
	_apply_easter_expansion(1.0)
	easter_expansion_finished.emit()


## 系统拒绝链接时保留关于窗口，并滚动显示可本土化的错误信息。
func show_link_error() -> void:
	if not _open:
		return
	_error.show()
	_scroll.ensure_control_visible.call_deferred(_error)


## 点击只提交已声明的固定地址，实际打开与白名单检查由外壳完成。
func _request_link(url: String) -> void:
	if not _open or _expansion_active:
		return
	_error.hide()
	link_requested.emit(url)


## 标准窗口保持竖卡尺寸；更小视口缩小正文区域，圆角与玻璃采样同步更新。
func _update_placement() -> void:
	if not _open:
		return
	_layout_scale = _anchor_layout_scale()
	if _expansion_active:
		_apply_easter_expansion(_expansion_progress)
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_dialog(false)
		return
	var available := get_viewport().get_visible_rect().size
	_panel.size = PANEL_SIZE.min((available / _layout_scale - Vector2(32, 32)).max(Vector2(1, 1)))
	_panel.position = ((available - _panel.size) * 0.5).floor()
	_panel.pivot_offset = _panel.size * 0.5
	_apply_opening_progress(_opening_progress)
	_glass.position = Vector2.ONE
	_glass.size = (_panel.size - Vector2(2, 2)).max(Vector2.ONE)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size * _layout_scale)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", float(CORNER_RADIUS - 1) * _layout_scale)
	# 圆角圆心为 (宽度 - R, R)，按钮共用该圆心；顶边与右边内缩均为 R - r。
	var close_radius := CLOSE_DIAMETER * 0.5
	_close.position = Vector2(_panel.size.x - CORNER_RADIUS - close_radius, CORNER_RADIUS - close_radius)
	_close.size = Vector2.ONE * CLOSE_DIAMETER
	var content_top := CORNER_RADIUS + close_radius + 16.0
	_layout.position = Vector2(28, content_top)
	_layout.size = (_panel.size - Vector2(56, content_top + 24.0)).max(Vector2.ONE)


## 键盘仅在五条链接与关闭按钮之间循环，Esc和外部点击关闭且不向底页传递。
func _input(event: InputEvent) -> void:
	if not _open:
		if event is InputEventMouseButton and event.button_index == _dismiss_button:
			get_viewport().set_input_as_handled()
			if not event.pressed:
				_dismiss_button = MOUSE_BUTTON_NONE
				set_process_input(false)
		return
	if _expansion_active:
		get_viewport().set_input_as_handled()
		if event.is_action_pressed("ui_cancel") and not event.is_echo():
			cancel_easter_expansion()
			_close.grab_focus()
		return
	if event is InputEventMouseButton and event.pressed:
		_set_keyboard_focus_visible(false)
		if event.button_index != MOUSE_BUTTON_LEFT or not _logo.get_global_rect().has_point(event.position):
			_reset_logo_clicks()
	elif event is InputEventMouseButton and not _logo.get_global_rect().has_point(event.position):
		_reset_logo_clicks()
	elif event is InputEventScreenTouch and event.pressed:
		_set_keyboard_focus_visible(false)
		_reset_logo_clicks()
	if event is InputEventMouseButton and not _panel.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()
		if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dismiss_button = event.button_index
			close_dialog()
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
		_reset_logo_clicks()
		get_viewport().set_input_as_handled()
		if not event.is_pressed() or event.is_echo():
			return
		if event.is_action_pressed("ui_cancel"):
			close_dialog()
		elif event.is_action_pressed("ui_focus_prev", false, true) or event.is_action_pressed("ui_up"):
			_move_focus(-1)
		elif event.is_action_pressed("ui_focus_next", false, true) or event.is_action_pressed("ui_down"):
			_move_focus(1)
		elif event.is_action_pressed("ui_accept"):
			var focused := get_viewport().gui_get_focus_owner() as BaseButton
			if focused in _focusables:
				focused.pressed.emit()


## 彩蛋仅计算图标内部完成的七次左键点击；不限制点击速度，拖离或其它操作会清零。
func _on_logo_input(event: InputEvent) -> void:
	if not _open or _logo_triggered or not _logo.is_visible_in_tree() or not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		_reset_logo_clicks()
		return
	_logo.accept_event()
	if event.pressed:
		_logo_pressed = true
		return
	if not _logo_pressed or not Rect2(Vector2.ZERO, _logo.size).has_point(event.position):
		_reset_logo_clicks()
		return
	_logo_pressed = false
	_logo_click_count += 1
	if _logo_click_count == LOGO_CLICK_TARGET:
		_reset_logo_clicks()
		_logo_triggered = true
		easter_egg_requested.emit()


## 关闭、失焦及非图标交互都会清空尚未完成的隐藏入口手势。
func _reset_logo_clicks() -> void:
	_logo_click_count = 0
	_logo_pressed = false


## 输入方式只控制描边，不释放实际焦点，因此鼠标操作后仍可直接使用回车与Tab。
func _set_keyboard_focus_visible(enabled: bool) -> void:
	for index in _focusables.size():
		var style: StyleBox = _focus_styles[index] if enabled else StyleBoxEmpty.new()
		_focusables[index].add_theme_stylebox_override("focus", style)


## 焦点无法确认时回到关闭；明确顺序让正向和反向导航都不会落到背后设置页。
func _move_focus(direction: int) -> void:
	_set_keyboard_focus_visible(true)
	var index := _focusables.find(get_viewport().gui_get_focus_owner())
	_focusables[posmod(index + direction, _focusables.size()) if index >= 0 else _focusables.size() - 1].grab_focus()


## 键盘定位链接时确保完整进入可见区域，右上角关闭按钮不参与正文滚动。
func _on_focus_entered(button: BaseButton) -> void:
	if _open and button != _close:
		_scroll.ensure_control_visible.call_deferred(button)


## 等待视口尺寸提交后居中，并保留当前焦点链接的可见性。
func _on_viewport_resized() -> void:
	if _expansion_active:
		_expansion_origin.position = (get_viewport().get_visible_rect().size - _expansion_origin.size) * 0.5
	_update_placement.call_deferred()
	var focused := get_viewport().gui_get_focus_owner() as BaseButton
	if _open and focused in _focusables:
		_on_focus_entered.call_deferred(focused)


## 翻译变化后让容器先重排，再按视口更新卡片和当前阅读位置。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_on_viewport_resized.call_deferred()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_window_focus_generation += 1
		_reset_logo_clicks()
		if _expansion_active:
			cancel_easter_expansion()
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _open and is_inside_tree():
		_window_focus_generation += 1
		_confirm_window_focus_out(_window_focus_generation)
	elif what == NOTIFICATION_EXIT_TREE:
		_window_focus_generation += 1
		_open = false
		cancel_easter_expansion(false)


## 嵌入运行的窗口通知可能迟到一帧；只在窗口仍失焦时清理，旧窗口周期不能影响重开。
func _confirm_window_focus_out(generation: int) -> void:
	await get_tree().process_frame
	if generation != _window_focus_generation or not is_inside_tree() or not _open or get_window().has_focus():
		return
	_reset_logo_clicks()
	if _expansion_active:
		cancel_easter_expansion()
