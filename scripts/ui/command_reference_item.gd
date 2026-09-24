class_name CommandReferenceItem
extends PanelContainer
## 指令条目默认只显示语法入口，介绍按需展开；内容始终为只读普通文本。

var header_button: Button
var preview: Label
var details: Label
var syntax: Label
var expanded := false
var _header_row: HBoxContainer
var _arrow: TextureRect
var _body_clip: Control
var _body: VBoxContainer
var _reveal_progress := 0.0
var _reveal_tween: Tween


## 由资料窗注入已本土化内容与权限颜色；未解锁条目也能正常展开阅读。
func configure(entry: Dictionary, text_color: Color, lock_hint: String, section_title: String = "") -> void:
	var entry_id := str(entry.id).validate_node_name()
	name = "CommandCard_" + entry_id
	tooltip_text = lock_hint
	set_meta("command_id", entry.id)
	set_meta("available", lock_hint.is_empty())
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var surface := GameTheme.box(Color(0.97, 0.978, 0.99, 0.92), Color.TRANSPARENT, 16)
	surface.set_content_margin_all(0)
	add_theme_stylebox_override("panel", surface)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 0)
	add_child(column)
	header_button = Button.new()
	header_button.name = "CommandToggle_" + entry_id
	header_button.toggle_mode = true
	header_button.tooltip_text = lock_hint
	header_button.custom_minimum_size.y = 52
	header_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 状态变化只调整柔和背景；标题和语法颜色不受按钮的蓝色选中样式影响。
	for state in ["normal", "pressed", "hover", "hover_pressed", "focus"]:
		var background := Color(0.88, 0.91, 0.96, 0.35) if state in ["hover", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(background, Color("B4CEF0") if state == "focus" else Color.TRANSPARENT, 16)
		style.set_content_margin_all(0)
		header_button.add_theme_stylebox_override(state, style)
	column.add_child(header_button)
	_header_row = HBoxContainer.new()
	_header_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header_row.add_theme_constant_override("separation", 16)
	header_button.add_child(_header_row)
	preview = GameTheme.label(_header_row, _compact_syntax(entry), 16)
	preview.name = "CommandPreview_" + entry_id
	preview.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	preview.add_theme_font_override("font", GameTheme.code_font())
	preview.add_theme_color_override("font_color", text_color)
	preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var arrow_slot := Control.new()
	arrow_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow_slot.custom_minimum_size = Vector2(20, 20)
	arrow_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_header_row.add_child(arrow_slot)
	_arrow = TextureRect.new()
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.texture = load("res://assets/ui/reference_forward.svg")
	_arrow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.size = Vector2(20, 20)
	_arrow.pivot_offset = Vector2(10, 10)
	_arrow.modulate.a = 1.0 if lock_hint.is_empty() else 0.6
	arrow_slot.add_child(_arrow)
	_body_clip = Control.new()
	_body_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body_clip.clip_contents = true
	column.add_child(_body_clip)
	_body = VBoxContainer.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_constant_override("separation", 12)
	_body_clip.add_child(_body)
	var title := _body_label(CommandCatalog.localized(entry, "title", TranslationServer.get_locale()), 18, text_color)
	title.name = "CommandTitle_" + entry_id
	if not section_title.is_empty():
		_body_label(section_title, 13, text_color)
	syntax = _body_label(str(entry.syntax), 16, text_color)
	syntax.name = "CommandSyntax_" + entry_id
	syntax.add_theme_font_override("font", GameTheme.code_font())
	# 单行动作入口已经给出全部语法；多行结构在展开区呈现完整模板。
	syntax.visible = str(entry.syntax).strip_edges().contains("\n")
	details = _body_label(CommandCatalog.localized(entry, "description", TranslationServer.get_locale()), 15, text_color)
	details.name = "CommandDetails_" + entry_id
	details.add_theme_constant_override("line_spacing", 4)
	header_button.toggled.connect(set_expanded)
	header_button.resized.connect(_layout_contents)
	_body_clip.resized.connect(_layout_contents)
	preview.minimum_size_changed.connect(_layout_contents.call_deferred)
	_body.minimum_size_changed.connect(_layout_contents.call_deferred)
	_body_clip.hide()
	_layout_contents.call_deferred()


## 条件分支入口只显示结构名称；其他多行指令保留首行和展开提示。
func _compact_syntax(entry: Dictionary) -> String:
	if entry.id == "if_else":
		return "if {}"
	var normalized := str(entry.syntax).strip_edges().replace("\r", "")
	return normalized.get_slice("\n", 0).strip_edges() + (" …" if normalized.contains("\n") else "")


## 标题、语法与说明共用权限色，不自动翻译来自 JSON 的已本土化文本。
func _body_label(caption: String, font_size: int, color: Color) -> Label:
	var label := GameTheme.label(_body, caption, font_size)
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


## 从当前展开进度平滑反向，连续点击不会留下空白高度或正在播放的旧动画。
func set_expanded(value: bool, animate: bool = true) -> void:
	expanded = value
	header_button.set_pressed_no_signal(value)
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	if not animate:
		_set_reveal_progress(1.0 if value else 0.0)
		return
	_body_clip.show()
	_layout_contents()
	_reveal_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT if value else Tween.EASE_IN_OUT)
	_reveal_tween.tween_method(_set_reveal_progress, _reveal_progress, 1.0 if value else 0.0, 0.24)


## 按当前可用宽度计算换行高度，窗口缩放时保持正文完整，不缓存失效的高度。
func _layout_contents() -> void:
	if not is_instance_valid(_body):
		return
	_header_row.position = Vector2(18, 14)
	_header_row.size = Vector2(maxf(1, header_button.size.x - 36), _header_row.get_combined_minimum_size().y)
	header_button.custom_minimum_size.y = maxf(52, _header_row.get_combined_minimum_size().y + 28)
	_body.position = Vector2(18, 0)
	_body.size = Vector2(maxf(1, size.x - 36), _body.get_combined_minimum_size().y)
	_set_reveal_progress(_reveal_progress)


## 只改变裁切区域的高度；容器自动把后续条目往下推或向上收回。
func _set_reveal_progress(value: float) -> void:
	_reveal_progress = value
	_body_clip.custom_minimum_size.y = (_body.get_combined_minimum_size().y + 18) * value
	_body_clip.visible = value > 0.0 or expanded
	_arrow.rotation = value * PI * 0.5


## 搜索或目录重建时停止旧条目的动画，避免对已释放节点继续更新。
func _exit_tree() -> void:
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
