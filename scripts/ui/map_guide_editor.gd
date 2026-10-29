class_name MapGuideEditor
extends Control
## 属性卡片内的独立指引草稿；切页或显式保存时一次提交，正文始终保留玩家原文。

signal closed

const TOOL_SIZE := 28.0
const TOOL_GAP := 4
const BODY_MIN_HEIGHT := 80.0
const BODY_GAP := 10.0
# 原图透明边界只用于 AtlasTexture 显示区域，不重采样或改写 PNG 像素。
const FORMAT_ICON_REGIONS := {
	"guide_bold": Rect2(288, 208, 448, 551),
	"guide_italic": Rect2(264, 218, 499, 551),
	"guide_underline": Rect2(246, 148, 532, 728),
	"guide_strike": Rect2(127, 209, 771, 572),
	"guide_list_bullet": Rect2(165, 265, 710, 452),
	"guide_list_numbered": Rect2(191, 241, 684, 504),
	"guide_list_task": Rect2(167, 243, 708, 486),
}

var _toolbar: HFlowContainer
var _title: Label
var _text: TextEdit
var _preview: RichTextLabel
var _preview_button: Button
var _previewing := false
var _previous: Button
var _next: Button
var _error: Label
var _format_buttons: Dictionary = {}
var _tool_buttons: Array[Button] = []
var _tool_selection: Dictionary = {}
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
var link_opener: Callable


## 内嵌工具栏按实际宽度换行，编辑与预览共用白色正文区域，不创建弹层或遮罩。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_toolbar = HFlowContainer.new()
	_toolbar.name = "MapGuideEditorToolbar"
	_toolbar.alignment = FlowContainer.ALIGNMENT_CENTER
	_toolbar.add_theme_constant_override("h_separation", TOOL_GAP)
	_toolbar.add_theme_constant_override("v_separation", TOOL_GAP)
	add_child(_toolbar)
	var format_row := _tool_group("MapGuideEditorFormatGroup")
	var format_index := 0
	for definition: Array in [["bold", "Bold", "guide_bold", "加粗", "**"], ["italic", "Italic", "guide_italic", "斜体", "*"], ["underline", "Underline", "guide_underline", "下划线", "++"], ["strike", "Strike", "guide_strike", "删除线", "~~"]]:
		if format_index > 0:
			_tool_separator(format_row)
		_format_buttons[definition[0]] = _tool_button("MapGuideEditor" + definition[1], definition[2], definition[3], _wrap_selection.bind(definition[4]), format_row, format_index, 4)
		format_index += 1
	var list_row := _tool_group("MapGuideEditorListGroup")
	var list_index := 0
	for definition: Array in [["bullet", "Bullet", "guide_list_bullet", "无序列表"], ["numbered", "Numbered", "guide_list_numbered", "有序列表"], ["task", "Task", "guide_list_task", "任务列表"]]:
		if list_index > 0:
			_tool_separator(list_row)
		_format_buttons[definition[0]] = _tool_button("MapGuideEditor" + definition[1], definition[2], definition[3], _apply_list.bind(definition[0]), list_row, list_index, 3)
		list_index += 1
	_previous = _tool_button("MapGuideEditorPrevious", "navigation_back", "上一页", _show_previous)
	_next = _tool_button("MapGuideEditorNext", "navigation_forward", "下一页", _show_next)
	_preview_button = _tool_button("MapGuideEditorPreviewToggle", "search", "预览", _toggle_preview)
	_text = TextEdit.new()
	_text.name = "MapGuideEditorText"
	_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_text.caret_blink = true
	_text.caret_blink_interval = 0.5
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.scroll_fit_content_height = false
	GameTheme.font_size(_text, "font_size", 16)
	for state in ["normal", "focus", "read_only"]:
		_text.add_theme_stylebox_override(state, _body_style())
	_text.text_changed.connect(_on_text_changed)
	add_child(_text)
	GameI18n.localize_text_edit_menu(_text)
	_preview = RichTextLabel.new()
	_preview.name = "MapGuideEditorPreview"
	_preview.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview.scroll_active = true
	_preview.selection_enabled = true
	_preview.meta_clicked.connect(_open_web_link)
	_preview.add_theme_stylebox_override("normal", _body_style())
	_preview.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_child(_preview)
	_preview.hide()
	_title = GameTheme.label(self, "", 13)
	_title.name = "MapGuideEditorPageNumber"
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_error = GameTheme.label(self, "", 12)
	_error.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_error.add_theme_color_override("font_color", GameTheme.ERROR)
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.hide()
	for control: Control in [_toolbar, _title, _error]:
		control.minimum_size_changed.connect(_layout_dialog.call_deferred)
	resized.connect(_layout_dialog)
	set_process_input(false)
	set_process_unhandled_key_input(false)
	hide()
	_layout_dialog()


## 白色正文只提供阅读留白，不给输入焦点增加蓝色边框。
func _body_style() -> StyleBoxFlat:
	var style := GameTheme.box(Color.WHITE, Color.TRANSPARENT, 12)
	style.set_content_margin_all(10)
	return style


## 格式和列表各自组成完整药丸，外层 Flow 只在组间换行而不拉宽卡片。
func _tool_group(node_name: String) -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	var style := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 14)
	style.set_content_margin_all(0)
	panel.add_theme_stylebox_override("panel", style)
	_toolbar.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	panel.add_child(row)
	return row


## 药丸内部细线只负责分组视觉，不截获点击或参与键盘导航。
func _tool_separator(parent: Node) -> void:
	var separator := ColorRect.new()
	separator.color = Color("DCE1E8")
	separator.custom_minimum_size = Vector2(1, 12)
	separator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(separator)


## 原始 PNG 仅裁去显示时的透明留白，补足方形逻辑尺寸后等比适配十四像素图标区，为药丸按钮保留更多留白。
func _tool_icon(icon_name: String) -> Texture2D:
	if not FORMAT_ICON_REGIONS.has(icon_name):
		return load("res://assets/ui/%s.svg" % icon_name)
	var texture := AtlasTexture.new()
	texture.atlas = load("res://assets/ui/%s.png" % icon_name)
	texture.region = FORMAT_ICON_REGIONS[icon_name]
	var side := maxf(texture.region.size.x, texture.region.size.y)
	var margin := Vector2.ONE * side - texture.region.size
	texture.margin = Rect2(margin * 0.5, margin)
	texture.filter_clip = true
	return texture


## 工具使用原始格式图案与既有导航图标，固定命中区和焦点保护不改变文字选区。
func _tool_button(node_name: String, icon_name: String, caption: String, action: Callable, parent: Node = null, segment: int = -1, count: int = 1) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = _tool_icon(icon_name)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.add_theme_constant_override("icon_max_width", 14 if FORMAT_ICON_REGIONS.has(icon_name) else 18)
	button.custom_minimum_size = Vector2.ONE * TOOL_SIZE
	button.tooltip_text = tr(caption)
	button.accessibility_name = button.tooltip_text
	button.set_meta("guide_tool_caption", caption)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color(0.78, 0.81, 0.86, 0.24) if state == "focus" else Color.TRANSPARENT if segment >= 0 else Color("EAEDF2")
		var style := GameTheme.box(fill, Color.TRANSPARENT, 14)
		style.set_content_margin_all(0)
		if segment >= 0:
			style.corner_radius_top_left = 14 if segment == 0 else 0
			style.corner_radius_bottom_left = 14 if segment == 0 else 0
			style.corner_radius_top_right = 14 if segment == count - 1 else 0
			style.corner_radius_bottom_right = 14 if segment == count - 1 else 0
		button.add_theme_stylebox_override(state, style)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.52 if FORMAT_ICON_REGIONS.has(icon_name) else 0.32))
	button.pressed.connect(action)
	(parent if parent != null else _toolbar).add_child(button)
	_tool_buttons.append(button)
	GameTheme.toolbar_highlight.call_deferred(button)
	return button


## 从模型读取独立副本；重复激活当前指引不清除页码、选区或预览状态。
func open_document(model: MapEditorDocument, anchor: Control, map_view: Control) -> void:
	if model == null:
		return
	if _open:
		if _model == model:
			show()
			_layout_dialog()
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
	_previewing = false
	_text.show()
	_preview.hide()
	_error.hide()
	show()
	set_process_input(true)
	set_process_unhandled_key_input(true)
	_layout_dialog()
	_show_page()
	_text.grab_focus()


## 保存或试玩先提交一次草稿并更新基线，保留正在看的页、文本历史、选区与预览。
func commit_draft() -> bool:
	if not _open:
		return true
	_store_text()
	if not _changed:
		return true
	var result := _model.set_guide_pages(_pages)
	if not result.is_ok():
		_error.text = tr("无法更新关卡引导") + "：" + GameI18n.translate_errors(result.errors)
		_error.show()
		_layout_dialog()
		return false
	_initial_pages = _model.get_guide_pages()
	_original_pages.clear()
	for page: Dictionary in _pages:
		_original_pages.append(null if str(page.get("text", "")).strip_edges().is_empty() else page.duplicate(true))
	_changed = false
	_error.hide()
	_refresh_text()
	_layout_dialog()
	return true


## 外部明确撤销、重做或更新元数据后重读文档，尽量保留页索引与预览状态。
func refresh_from_document() -> void:
	if not _open or _model == null:
		return
	_pages = _model.get_guide_pages()
	_initial_pages = _pages.duplicate(true)
	_original_pages = _pages.duplicate(true)
	if _pages.is_empty():
		_pages.append(_empty_page())
		_original_pages.append(null)
	_page_index = clampi(_page_index, 0, _pages.size() - 1)
	_changed = false
	_error.hide()
	_show_page()
	_layout_dialog()


## 离开指引页提交当前草稿；校验失败则继续显示原稿，成功后才通知页签切换。
func close_dialog() -> bool:
	if not _open:
		return true
	if not commit_draft():
		return false
	_open = false
	_model = null
	_pages.clear()
	_initial_pages.clear()
	_original_pages.clear()
	hide()
	set_process_input(false)
	set_process_unhandled_key_input(false)
	closed.emit()
	return true


## 外层通过此状态区分正文编辑与地图编辑，但仍可执行保存或试玩入口。
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
	_tool_selection.clear()
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
	_tool_selection.clear()
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


## 底部页码反映当前草稿页；末页只能增加一个空页，防止无内容页面无限累积。
func _refresh_text() -> void:
	if not _open:
		return
	var blank := _text.text.strip_edges().is_empty()
	_title.text = tr("指引 %d/%d") % [_page_index + 1, maxi(_pages.size(), 1)]
	_previous.disabled = _page_index == 0
	_next.disabled = _page_index == _pages.size() - 1 and (blank or _pages.size() >= MapValidation.MAX_DIALOGUE)
	_preview_button.icon = load("res://assets/ui/guide_edit.svg" if _previewing else "res://assets/ui/search.svg")
	_preview_button.tooltip_text = tr("编辑" if _previewing else "预览")
	_preview_button.accessibility_name = _preview_button.tooltip_text
	for key: String in _format_buttons:
		_format_buttons[key].disabled = _previewing
	for button: Button in _tool_buttons:
		if button != _preview_button:
			button.tooltip_text = tr(str(button.get_meta("guide_tool_caption", "")))
			button.accessibility_name = button.tooltip_text
	_text.placeholder_text = tr("在这里编写关卡引导…")
	_text.tooltip_text = tr("支持 Markdown：# 标题、## 小标题、### 小节。")


## 工具栏宽度服从卡片并可换行，正文与底部页码随可用高度排布。
func _layout_dialog() -> void:
	if _toolbar == null or _text == null:
		return
	var width := maxf(1.0, size.x)
	_toolbar.position = Vector2.ZERO
	_toolbar.size.x = width
	var toolbar_height := maxf(TOOL_SIZE, _toolbar.get_combined_minimum_size().y)
	_toolbar.size.y = toolbar_height
	var footer_height := maxf(24.0, _title.get_combined_minimum_size().y)
	var error_height := maxf(24.0, _error.get_combined_minimum_size().y) + BODY_GAP if _error.visible else 0.0
	var minimum_height := toolbar_height + BODY_GAP * 2 + BODY_MIN_HEIGHT + footer_height + error_height
	if not is_equal_approx(custom_minimum_size.y, minimum_height):
		custom_minimum_size.y = minimum_height
	var height := maxf(size.y, minimum_height)
	_text.position = Vector2(0, toolbar_height + BODY_GAP)
	_text.size = Vector2(width, maxf(1, height - _text.position.y - BODY_GAP - footer_height - error_height))
	_preview.position = _text.position
	_preview.size = _text.size
	_title.position = Vector2(0, _text.position.y + _text.size.y + BODY_GAP)
	_title.size = Vector2(width, footer_height)
	_error.position = Vector2(0, height - error_height)
	_error.size = Vector2(width, maxf(1, error_height))


## 工具点击使用 TextEdit 保留的选区；一次原生编辑事务可完整撤销标记。
func _wrap_selection(marker: String) -> void:
	if not _open or _previewing:
		return
	_restore_tool_selection()
	var source := _text.text
	var start := _selection_start_offset()
	var finish := _selection_end_offset()
	var selected := source.substr(start, finish - start)
	_text.begin_complex_operation()
	_text.insert_text_at_caret(marker + selected + marker)
	_text.end_complex_operation()
	_select_offsets(start + marker.length(), start + marker.length() + selected.length())
	_text.grab_focus()


## 列表覆盖选区涉及的完整行，更换样式时先移除已有前缀，不累计列表符号。
func _apply_list(kind: String) -> void:
	if not _open or _previewing:
		return
	_restore_tool_selection()
	var first := _text.get_selection_from_line() if _text.has_selection() else _text.get_caret_line()
	var last := _text.get_selection_to_line() if _text.has_selection() else first
	if _text.has_selection() and last > first and _text.get_selection_to_column() == 0:
		last -= 1
	var start := _offset_for_position(first, 0)
	var result := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("^(?:[-*] \\[[ xX]\\] |[-*] |[0-9]+[.)] )")
	for line_index in range(first, last + 1):
		var line := _text.get_line(line_index)
		var existing := pattern.search(line)
		if existing != null:
			line = line.substr(existing.get_end())
		var prefix := "%d. " % (line_index - first + 1) if kind == "numbered" else "- [ ] " if kind == "task" else "- "
		result.append(prefix + line)
	var replacement := "\n".join(result)
	_text.select(first, 0, last, _text.get_line(last).length())
	_text.begin_complex_operation()
	_text.insert_text_at_caret(replacement)
	_text.end_complex_operation()
	_select_offsets(start, start + replacement.length())
	_text.grab_focus()


## 原生按钮接收焦点前保存选区，避免 TextEdit 在鼠标按下时把选区清除。
func _remember_tool_selection() -> void:
	_tool_selection = {"source": _text.text, "start": _selection_start_offset(), "finish": _selection_end_offset()}


## 格式操作只恢复同一段正文的选择快照，内容已改变时不会误用过期位置。
func _restore_tool_selection() -> void:
	if _tool_selection.get("source") == _text.text:
		_select_offsets(int(_tool_selection.start), int(_tool_selection.finish))
	_tool_selection.clear()


## 无选区时使用当前光标，避免点击工具后把格式插到文末。
func _selection_start_offset() -> int:
	return _offset_for_position(_text.get_selection_from_line(), _text.get_selection_from_column()) if _text.has_selection() else _offset_for_position(_text.get_caret_line(), _text.get_caret_column())


## 选区端点统一换成字符偏移，多行与 emoji 不依赖字节长度。
func _selection_end_offset() -> int:
	return _offset_for_position(_text.get_selection_to_line(), _text.get_selection_to_column()) if _text.has_selection() else _selection_start_offset()


## 从原生行列换算文本字符偏移，供包装和列表操作共享。
func _offset_for_position(line: int, column: int) -> int:
	var offset := column
	for index in line:
		offset += _text.get_line(index).length() + 1
	return offset


## 从字符偏移恢复行列，让格式化后仍选中原内容并保留继续编辑位置。
func _position_for_offset(offset: int) -> Vector2i:
	var remaining := clampi(offset, 0, _text.text.length())
	for line in _text.get_line_count():
		var length := _text.get_line(line).length()
		if remaining <= length:
			return Vector2i(line, remaining)
		remaining -= length + 1
	return Vector2i(_text.get_line_count() - 1, _text.get_line(_text.get_line_count() - 1).length())


## 空内容把光标放到一对标记中间，非空内容恢复真实 TextEdit 选区。
func _select_offsets(start: int, finish: int) -> void:
	var from := _position_for_offset(start)
	var to := _position_for_offset(finish)
	_text.deselect()
	_text.set_caret_line(to.x)
	_text.set_caret_column(to.y)
	if start != finish:
		_text.select(from.x, from.y, to.x, to.y)


## 内嵌编辑只拦截非法输入与退出指引的 Esc；保存等快捷键交由外层地图编辑器处理。
func _input(event: InputEvent) -> void:
	if not _open or not is_visible_in_tree():
		return
	# _input 先于原生 GUI 焦点分派，因而可以保留鼠标点击工具前的真实选区。
	if not _previewing and _text.has_focus():
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			for button: Button in _format_buttons.values():
				if not button.disabled and button.get_global_rect().has_point(event.position):
					_remember_tool_selection()
					break
		elif event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
			_remember_tool_selection()
	if not event is InputEventKey:
		return
	if _text.has_focus() and event.pressed and DataValidation.is_private_use_character(event.unicode):
		get_viewport().set_input_as_handled()
		return
	if event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_dialog()


## 正文和预览内部未处理的普通按键不穿透绘图；保存等命令仍留给外层。
func _unhandled_key_input(event: InputEvent) -> void:
	if not _open or not is_visible_in_tree():
		return
	if event is InputEventKey and (event.ctrl_pressed or event.meta_pressed) and event.keycode in [KEY_S, KEY_O, KEY_N]:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		get_viewport().set_input_as_handled()


## 本土化只更新工具提示和页码，不重填正在编辑的玩家正文。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and _open:
		_refresh_text()
		_layout_dialog.call_deferred()
