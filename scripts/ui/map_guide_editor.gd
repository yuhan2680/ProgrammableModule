class_name MapGuideEditor
extends CanvasLayer
## 自定义关卡引导以独立草稿分页编辑，关闭时一次提交，正文始终是玩家原文。

signal closed

const PANEL_SIZE := Vector2(568, 408)
const EDGE_MARGIN := 16.0
const CORNER_RADIUS := 28.0
const CLOSE_SIZE := 32.0
const MODE_SIZE := CLOSE_SIZE
const CONTENT_TOP := 64.0

var _overlay: Control
var _panel: Panel
var _title: Label
var _text: TextEdit
var _preview: RichTextLabel
var _preview_button: Button
var _previewing := false
var _previous: Button
var _next: Button
var _close: Button
var _error: Label
var _model: MapEditorDocument
var _anchor: Control
var _map_view: Control
var _pages: Array = []
var _initial_pages: Array = []
var _original_pages: Array = []
var _page_index := 0
var _changed := false
var _open := false
var _syncing := false
var _dismiss_button := MOUSE_BUTTON_NONE
var link_opener: Callable


## 白色圆角卡片和浅灰输入面沿用引导样式，右上关闭按钮圆心与外框 R 角对齐。
func _ready() -> void:
	layer = 80
	_overlay = Control.new()
	_overlay.name = "MapGuideEditorOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrim := ColorRect.new()
	scrim.color = Color(0.1, 0.14, 0.2, 0.065)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(scrim)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = Panel.new()
	_panel.name = "MapGuideEditorPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var surface := GameTheme.box(Color.WHITE, Color.TRANSPARENT, int(CORNER_RADIUS))
	surface.shadow_color = Color(0.10, 0.16, 0.24, 0.16)
	surface.shadow_size = 16
	surface.shadow_offset = Vector2(0, 6)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_title = GameTheme.label(_panel, "", 19)
	_title.name = "MapGuideEditorTitle"
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.clip_text = true
	_title.minimum_size_changed.connect(_layout_dialog.call_deferred)
	_close = Button.new()
	_close.name = "MapGuideEditorClose"
	_close.icon = load("res://assets/ui/close.svg")
	_close.expand_icon = true
	_close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_close.add_theme_constant_override("icon_max_width", 24)
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color("E0E8F2") if state == "hover" else Color("D7E7FF") if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT if state == "focus" else Color("E9EEF5")
		var style := GameTheme.box(fill, GameTheme.ACCENT if state == "focus" else Color.TRANSPARENT, int(CLOSE_SIZE / 2))
		style.set_content_margin_all(0)
		_close.add_theme_stylebox_override(state, style)
	_close.pressed.connect(close_dialog)
	_panel.add_child(_close)
	GameTheme.toolbar_highlight.call_deferred(_close)
	_text = TextEdit.new()
	_text.name = "MapGuideEditorText"
	_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_text.caret_blink = true
	_text.caret_blink_interval = 0.5
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.scroll_fit_content_height = false
	GameTheme.font_size(_text, "font_size", 16)
	_text.text_changed.connect(_on_text_changed)
	_panel.add_child(_text)
	GameI18n.localize_text_edit_menu(_text)
	_preview = RichTextLabel.new()
	_preview.name = "MapGuideEditorPreview"
	_preview.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview.scroll_active = true
	_preview.selection_enabled = true
	_preview.meta_clicked.connect(_open_web_link)
	# 预览沿用正文内边距但不绘制输入框背景，让文字直接落在白色引导窗口上。
	_preview.add_theme_stylebox_override("normal", GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	_preview.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_panel.add_child(_preview)
	_preview.hide()
	_previous = GameTheme.button(_panel, "上一页", _show_previous)
	_previous.name = "MapGuideEditorPrevious"
	_previous.minimum_size_changed.connect(_layout_dialog.call_deferred)
	_next = GameTheme.button(_panel, "下一页", _show_next)
	_next.name = "MapGuideEditorNext"
	_next.minimum_size_changed.connect(_layout_dialog.call_deferred)
	GameTheme.primary(_next)
	_preview_button = _mode_button()
	_error = GameTheme.label(_panel, "", 12)
	_error.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_error.add_theme_color_override("font_color", GameTheme.ERROR)
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.hide()
	_error.minimum_size_changed.connect(_layout_dialog.call_deferred)
	_overlay.hide()
	get_viewport().size_changed.connect(_layout_dialog)
	set_process_input(false)
	set_process_unhandled_key_input(false)


## 同一个圆形图标随模式切换动作，悬停说明交由全局玻璃提示层统一呈现。
func _mode_button() -> Button:
	var button := Button.new()
	button.name = "MapGuideEditorPreviewToggle"
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 18)
	button.focus_mode = Control.FOCUS_ALL
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color("E9EEF5")
		if state == "hover":
			fill = Color("E0E8F2")
		elif state in ["pressed", "hover_pressed"]:
			fill = Color("D7E7FF")
		elif state == "focus":
			fill = Color.TRANSPARENT
		var style := GameTheme.box(fill, GameTheme.ACCENT if state == "focus" else Color.TRANSPARENT, int(MODE_SIZE / 2))
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(_toggle_preview)
	_panel.add_child(button)
	GameTheme.toolbar_highlight.call_deferred(button)
	return button


## 从编辑模型读取独立副本，打开和翻页本身不产生任何撤销或未保存变化。
func open_document(model: MapEditorDocument, anchor: Control, map_view: Control) -> void:
	if _open or model == null:
		return
	_model = model
	_anchor = anchor
	_map_view = map_view
	_pages = model.get_guide_pages()
	_initial_pages = _pages.duplicate(true)
	_original_pages = _pages.duplicate(true)
	if _pages.is_empty():
		_pages.append(_empty_page())
		_original_pages.append(null)
	_page_index = 0
	_changed = false
	_open = true
	_dismiss_button = MOUSE_BUTTON_NONE
	_previewing = false
	_text.show()
	_preview.hide()
	_error.hide()
	_overlay.show()
	set_process_input(true)
	set_process_unhandled_key_input(true)
	_layout_dialog()
	_show_page()
	_text.grab_focus()


## 所有关闭方式提交相同的单次事务；校验失败时保留草稿和窗口供作者修正。
func close_dialog() -> bool:
	if not _open:
		return true
	_store_text()
	if _changed:
		var result := _model.set_guide_pages(_pages)
		if not result.is_ok():
			_error.text = tr("无法更新关卡引导") + "：" + GameI18n.translate_errors(result.errors)
			_error.show()
			return false
	_open = false
	_model = null
	_pages.clear()
	_initial_pages.clear()
	_original_pages.clear()
	_overlay.hide()
	set_process_input(_dismiss_button != MOUSE_BUTTON_NONE)
	set_process_unhandled_key_input(false)
	if is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()
	closed.emit()
	return true


## 外层快捷键和页面切换通过此状态阻挡地图操作。
func is_open() -> bool:
	return _open


## 默认空页只存在于编辑器草稿；未输入正文时不会写入地图。
func _empty_page() -> Dictionary:
	return {"speaker": "引导", "text": "", "format": "markdown"}


## 已有页只在正文真实改变时更新已知字段，其他扩展字段保持不变。
func _store_text() -> void:
	if _syncing or not _open:
		return
	var page: Dictionary = _pages[_page_index]
	if str(page.get("text", "")) == _text.text:
		return
	var original: Variant = _original_pages[_page_index]
	if original is Dictionary and str(original.get("text", "")) == _text.text:
		# TextEdit 撤销回原正文时恢复旧格式和署名，不能仅因输入过程就把旧页改成 Markdown。
		_pages[_page_index] = original.duplicate(true)
	else:
		page["text"] = _text.text
		page["speaker"] = "引导"
		page["format"] = "markdown"
	_changed = _has_changes()


## 空的新建草稿不算修改；与原始页面完全相同的正文和扩展字段也不产生提交。
func _has_changes() -> bool:
	var retained: Array = []
	for index in _pages.size():
		if _original_pages[index] == null and str(_pages[index].get("text", "")).strip_edges().is_empty():
			continue
		retained.append(_pages[index])
	return retained != _initial_pages


## 旧纯文本页预览与正式引导一致；只有明确标记的 Markdown 页才应用标题样式。
func _render_preview() -> void:
	if str(_pages[_page_index].get("format", "plain")) == "markdown":
		GuideMarkdown.render(_preview, _text.text)
	else:
		GuideMarkdown.render(_preview, "")
		_preview.add_text(DataValidation.filter_guide_text(_text.text))


## 输入即时刷新页数和 Markdown 预览，但不写入地图或拆分撤销事务。
func _on_text_changed() -> void:
	if _syncing or not _open:
		return
	var original: Variant = _original_pages[_page_index]
	var unchanged_legacy: bool = original is Dictionary and original.get("text", "") == _text.text
	if not DataValidation.is_portable_guide_text(_text.text) and not unchanged_legacy:
		_filter_private_input()
	_store_text()
	_refresh_text()
	_render_preview()


## 撤回包含私用字符的原生输入，再以过滤后的正文替换同一操作，保留以前的撤销历史。
func _filter_private_input() -> void:
	var raw := _text.text
	var filtered := DataValidation.filter_guide_text(raw)
	if filtered == raw:
		return
	var lines := raw.split("\n", true)
	var caret_line := _text.get_caret_line()
	var prefix := ""
	for index in caret_line:
		prefix += lines[index] + "\n"
	prefix += lines[caret_line].left(_text.get_caret_column())
	prefix = DataValidation.filter_guide_text(prefix)
	_syncing = true
	if _text.has_undo():
		_text.undo()
	_text.begin_complex_operation()
	_text.select_all()
	_text.insert_text_at_caret(filtered)
	_text.end_complex_operation()
	_text.deselect()
	_text.set_caret_line(prefix.count("\n"))
	_text.set_caret_column(prefix.get_slice("\n", prefix.count("\n")).length())
	_syncing = false


## 预览中只有经过网址规则的元数据才打开默认浏览器，失败不会关闭或丢失引导草稿。
func _open_web_link(meta: Variant) -> void:
	if not _open or not _previewing or not meta is String or not GuideMarkdown.is_web_url(meta):
		return
	var result: int = link_opener.call(meta) if link_opener.is_valid() else OS.shell_open(meta)
	if result != OK:
		_error.text = tr("无法打开网页链接。")
		_error.show()
	else:
		_error.hide()
	_layout_dialog()


## 翻到已有页面时替换本地输入，玩家数据禁止交给翻译词典。
func _show_page() -> void:
	_syncing = true
	_text.text = str(_pages[_page_index].get("text", ""))
	_text.clear_undo_history()
	_syncing = false
	_render_preview()
	_preview.scroll_to_line(0)
	_refresh_text()


## 上一页返回前移除当前的空白草稿，避免空页累积或膨胀计数。
func _show_previous() -> void:
	if _page_index <= 0:
		return
	_store_text()
	var original: Variant = _original_pages[_page_index]
	var empty_draft := str(_pages[_page_index].get("text", "")).strip_edges().is_empty()
	if empty_draft and (original == null or str(original.get("text", "")) != str(_pages[_page_index].get("text", ""))):
		_pages.remove_at(_page_index)
		_original_pages.remove_at(_page_index)
		_changed = _has_changes()
	_page_index -= 1
	_show_page()


## 最后一张有效页才允许创建下一页，连续点击不能无限增加空白页面。
func _show_next() -> void:
	_store_text()
	if _page_index + 1 < _pages.size():
		_page_index += 1
	elif not _text.text.strip_edges().is_empty() and _pages.size() < MapValidation.MAX_DIALOGUE:
		_pages.append(_empty_page())
		_original_pages.append(null)
		_page_index += 1
	else:
		return
	_show_page()


## 编辑和预览共用当前草稿内容，不另存一份渲染结果或自动改写 Markdown。
func _toggle_preview() -> void:
	_store_text()
	_previewing = not _previewing
	_text.visible = not _previewing
	_preview.visible = _previewing
	_render_preview()
	_refresh_text()
	if not _previewing:
		_text.grab_focus()


## 页码仅计算有正文的页面，末尾空草稿显示明确的“新页”提示。
func _refresh_text() -> void:
	if not _open:
		return
	var count := 0
	var current := 0
	for index in _pages.size():
		if not str(_pages[index].get("text", "")).strip_edges().is_empty():
			count += 1
			if index <= _page_index:
				current += 1
	var blank := _text.text.strip_edges().is_empty()
	_title.text = tr("引导 · 新页（已有 %d 页）") % count if blank and count > 0 else tr("引导 %d/%d") % [maxi(current, 1), maxi(count, 1)]
	_previous.disabled = _page_index == 0
	_next.disabled = _page_index == _pages.size() - 1 and (blank or _pages.size() >= MapValidation.MAX_DIALOGUE)
	_preview_button.icon = load("res://assets/ui/guide_edit.svg" if _previewing else "res://assets/ui/search.svg")
	_preview_button.tooltip_text = tr("编辑" if _previewing else "预览")
	_preview_button.accessibility_name = _preview_button.tooltip_text
	_close.tooltip_text = tr("关闭")
	_text.placeholder_text = tr("在这里编写关卡引导…\n支持 Markdown：# 标题、## 小标题、### 小节。")


## 优先围绕地图可视区居中，窄窗口下缩小并保留四周安全边距。
func _layout_dialog() -> void:
	if not _open:
		return
	var factor := GameTheme.sync_popup_scale(_overlay, _anchor)
	var viewport_rect := get_viewport().get_visible_rect()
	var bounds := Rect2(viewport_rect.position / factor, viewport_rect.size / factor)
	var panel_size := PANEL_SIZE.min((bounds.size - Vector2.ONE * EDGE_MARGIN * 2).max(Vector2(240, 240)))
	var center := bounds.get_center()
	if is_instance_valid(_map_view) and _map_view.is_visible_in_tree():
		center = _map_view.get_global_rect().get_center() / factor
	_panel.size = panel_size
	_panel.position = (center - panel_size / 2).clamp(bounds.position + Vector2.ONE * EDGE_MARGIN, (bounds.end - panel_size - Vector2.ONE * EDGE_MARGIN).max(bounds.position + Vector2.ONE * EDGE_MARGIN))
	# 标题两侧预留对称空间，右侧两个同径圆钮并排时仍保持页码居中。
	_title.position = Vector2(96, CORNER_RADIUS - 17)
	_title.size = Vector2(panel_size.x - 192, maxf(34, _title.get_combined_minimum_size().y))
	_close.position = Vector2(panel_size.x - CORNER_RADIUS - CLOSE_SIZE / 2, CORNER_RADIUS - CLOSE_SIZE / 2)
	_close.size = Vector2.ONE * CLOSE_SIZE
	_preview_button.position = _close.position - Vector2(MODE_SIZE + 8, 0)
	_preview_button.size = Vector2.ONE * MODE_SIZE
	# 上缘贴近标题栏；150%/200% 字号时按真实行高让出必要空间，不与标题重叠。
	var content_top := maxf(CONTENT_TOP, _title.position.y + _title.size.y + 16)
	var button_size := _previous.get_combined_minimum_size().max(_next.get_combined_minimum_size()).max(Vector2(132, 38))
	var error_height := maxf(25, _error.get_combined_minimum_size().y) if _error.visible else 0.0
	var button_y := panel_size.y - 24 - button_size.y - (error_height + 8 if _error.visible else 0.0)
	_text.position = Vector2(24, content_top)
	_text.size = Vector2(panel_size.x - 48, maxf(1, button_y - 18 - content_top))
	_preview.position = _text.position
	_preview.size = _text.size
	_previous.position = Vector2(24, button_y)
	_previous.size = button_size
	_next.position = Vector2(panel_size.x - 24 - button_size.x, button_y)
	_next.size = button_size
	_error.position = Vector2(24, panel_size.y - 12 - maxf(25, error_height))
	_error.size = Vector2(panel_size.x - 48, maxf(25, error_height))


## 全屏遮罩吞掉关闭的完整鼠标事件；Esc 提交草稿，文本自身的撤销和粘贴仍走原生输入。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if _dismiss_button != MOUSE_BUTTON_NONE and mouse.button_index == _dismiss_button:
			get_viewport().set_input_as_handled()
			if not mouse.pressed:
				_dismiss_button = MOUSE_BUTTON_NONE
				set_process_input(_open)
			return
		if _open and not _panel.get_global_rect().has_point(mouse.position):
			get_viewport().set_input_as_handled()
			if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_dismiss_button = mouse.button_index
				close_dialog()
			return
	if not _open or not event is InputEventKey:
		return
	if _text.has_focus() and event.pressed and DataValidation.is_private_use_character(event.unicode):
		get_viewport().set_input_as_handled()
		return
	if event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_dialog()
	elif (event.ctrl_pressed or event.meta_pressed) and event.keycode in [KEY_S, KEY_O, KEY_N]:
		get_viewport().set_input_as_handled()
	elif event.pressed and event.keycode == KEY_TAB and not get_viewport().gui_get_focus_owner() is TextEdit:
		get_viewport().set_input_as_handled()
		var controls: Array[Control] = [_close, _preview_button, _text if _text.visible else _preview, _previous, _next]
		var available: Array[Control] = []
		for control in controls:
			if not (control is BaseButton and control.disabled):
				available.append(control)
		var index := available.find(get_viewport().gui_get_focus_owner())
		available[posmod(index + (-1 if event.shift_pressed else 1), available.size())].grab_focus()


## 未被正文或按钮处理的键盘输入也不会传给背后的绘制与撤销逻辑。
func _unhandled_key_input(_event: InputEvent) -> void:
	if _open:
		get_viewport().set_input_as_handled()


## 本土化只更新页码和按钮，不重填正在编辑的用户正文。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_refresh_text()
