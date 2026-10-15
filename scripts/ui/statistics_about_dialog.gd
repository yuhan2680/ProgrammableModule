class_name StatisticsAboutDialog
extends CanvasLayer
## 统计说明使用独立模态画布，绕过设置正文的透明遮罩并阻挡底页交互。

const DESCRIPTION := "统计信息是自从你首次运行此程序，并游玩关卡后，系统将自动结合你的游戏行为而进行的统计程序，它将自动计算，分析你在每一关卡中的耗时，通过率等参数，并向你展示。 所有的统计信息将在你本地进行，不会上传至云端"
const PANEL_WIDTH := 384.0
const PANEL_HEIGHT := 384.0
const PANEL_MARGIN := Vector2(28, 24)
const BODY_FONT_SIZE := 11 # 原 18 号正文的 60%，取最接近的整数像素。

var _overlay: Control
var _dimmer: ColorRect
var _panel: Panel
var _layout: VBoxContainer
var _title: Label
var _scroll: ScrollContainer
var _content_fade: ScrollContentFade
var _body: Label
var _footer_gap: Control
var _footer: HBoxContainer
var _close: Button
var _anchor: Control
var _open := false


## 白卡只由一个圆角面板绘制；遮罩覆盖整个视口而非滚动正文。
func _ready() -> void:
	layer = 110
	_overlay = Control.new()
	_overlay.name = "StatisticsAboutOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	_dimmer = ColorRect.new()
	_dimmer.name = "StatisticsAboutDimmer"
	_dimmer.color = Color(0.12, 0.14, 0.17, 0.38)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_dimmer)
	_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = Panel.new()
	_panel.name = "StatisticsAboutCard"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color.WHITE, Color.TRANSPARENT, 24)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.05, 0.07, 0.10, 0.18)
	surface.shadow_size = 24
	surface.shadow_offset = Vector2(0, 8)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_build_content()
	get_viewport().size_changed.connect(_update_placement)
	set_process_input(false)


## 标题和关闭栏固定，较小视口仅滚动正文，不裁剪按钮或将正文挤出卡片。
func _build_content() -> void:
	_layout = VBoxContainer.new()
	_layout.name = "StatisticsAboutLayout"
	_layout.add_theme_constant_override("separation", 16)
	_panel.add_child(_layout)
	_title = GameTheme.label(_layout, "关于统计", 22)
	_title.name = "StatisticsAboutTitle"
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title_font := GameTheme.body_font().duplicate() as FontVariation
	title_font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 650.0}
	_title.add_theme_font_override("font", title_font)
	_scroll = ScrollContainer.new()
	_scroll.name = "StatisticsAboutScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_content_fade = ScrollContentFade.new()
	_content_fade.name = "StatisticsAboutContentFade"
	_content_fade.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_layout.add_child(_content_fade)
	_content_fade.set_scroll(_scroll)
	SettingsContentFade.style_scrollbar(_scroll.get_v_scroll_bar())
	SettingsScrollFade.attach(_scroll)
	_body = GameTheme.label(_scroll, DESCRIPTION, BODY_FONT_SIZE)
	_body.name = "StatisticsAboutDescription"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_constant_override("line_spacing", 4)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 保留原分隔区域高度但不绘制线条，正文留白与关闭按钮位置保持不变。
	_footer_gap = Control.new()
	_footer_gap.name = "StatisticsAboutFooterGap"
	_footer_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer_gap.custom_minimum_size.y = maxf(1.0, _body.get_theme_constant("separation", "HSeparator"))
	_layout.add_child(_footer_gap)
	_footer = HBoxContainer.new()
	_footer.name = "StatisticsAboutFooter"
	_footer.alignment = BoxContainer.ALIGNMENT_END
	_layout.add_child(_footer)
	_close = GameTheme.button(_footer, "关闭", close_dialog)
	_close.name = "StatisticsAboutCloseButton"
	_close.custom_minimum_size = Vector2(84, 38)
	GameTheme.font_size(_close, "font_size", 16)
	_close.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_close.focus_next = _close.get_path_to(_close)
	_close.focus_previous = _close.get_path_to(_close)
	_body.theme_changed.connect(_queue_placement)
	_title.theme_changed.connect(_queue_placement)
	_close.theme_changed.connect(_queue_placement)


## 打开时只显示已固定的说明文字，不读取网络、不修改档案或统计。
func popup_dialog(anchor: Control) -> void:
	if _open or not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_open = true
	_scroll.scroll_vertical = 0
	_overlay.show()
	_update_placement()
	_update_placement.call_deferred()
	set_process_input(true)
	_close.grab_focus()


## 外部导航通过此状态优先关闭说明，而不是跳转到背景页面。
func is_open() -> bool:
	return _open


## 关闭后恢复问号入口焦点，隐藏或销毁页面时可以跳过焦点恢复。
func close_dialog(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	set_process_input(false)
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 模态阻止背景鼠标和全部键盘输入；唯一操作是关闭及正文滚动。
func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventAction:
		get_viewport().set_input_as_handled()
		if not event.is_pressed() or event.is_echo():
			return
		if event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_accept"):
			close_dialog()
		elif event.is_action_pressed("ui_focus_next", false, true) or event.is_action_pressed("ui_focus_prev", false, true):
			_close.grab_focus()
		elif event.is_action_pressed("ui_down") or event.is_action_pressed("ui_page_down"):
			_scroll.scroll_vertical += roundi(48.0 * GameTheme.font_scale(_body))
		elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_page_up"):
			_scroll.scroll_vertical -= roundi(48.0 * GameTheme.font_scale(_body))
	elif event is InputEventMouseButton and not _panel.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and not _panel.get_global_rect().has_point(event.position):
		get_viewport().set_input_as_handled()


## 字号变更先等待原生最小尺寸更新，随后合并到下一轮卡片布局。
func _queue_placement() -> void:
	_update_placement.call_deferred()


## 各语言共用稳定卡片尺寸；长文或大字号只扩展正文滚动范围，不拉长外框。
func _update_placement() -> void:
	if not _open or not is_instance_valid(_panel) or not is_inside_tree():
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_dialog(false)
		return
	var factor := _anchor_layout_scale()
	var available := get_viewport().get_visible_rect().size
	var bounds := (available / factor - Vector2(32, 32)).max(Vector2.ONE)
	_panel.size = Vector2(minf(PANEL_WIDTH, bounds.x), minf(PANEL_HEIGHT, bounds.y))
	_panel.position = ((available - _panel.size) * 0.5).floor()
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * factor
	_layout.position = PANEL_MARGIN
	_layout.size = (_panel.size - PANEL_MARGIN * 2.0).max(Vector2.ONE)


## 只继承外层白卡的呈现比例，避免把统计正文的八成缩放叠加到模态窗口。
func _anchor_layout_scale() -> float:
	var ancestor: Node = _anchor
	while is_instance_valid(ancestor):
		if ancestor.has_meta("ui_menu_layout_scale"):
			return maxf(1.0, float(ancestor.get_meta("ui_menu_layout_scale")))
		ancestor = ancestor.get_parent()
	return 1.0


## 翻译通知只触发布局刷新，退出场景时清除打开状态以便安全销毁。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_queue_placement()
	elif what == NOTIFICATION_EXIT_TREE:
		_open = false
