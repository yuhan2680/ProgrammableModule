class_name ProgramInlineCompletion
extends Control
## 只绘制光标后的浅灰候选；接受前不把建议写入 CodeEdit、草稿或解释器。

const GHOST_COLOR := Color("9BA4B2")

var editor: CodeEdit
var level: LevelDefinition
var assembly: AssemblyModel
var suggestion: String = ""
var enabled: bool = true:
	set(value):
		enabled = value
		_context_dirty = true
		if is_node_ready():
			refresh()
var _context_dirty := true
var _source := ""
var _caret := Vector2i(-1, -1)
var _dismissed := false
var _was_available := false


## 子控件不拦鼠标或焦点；文本、光标和装配变更才重新扫描候选。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	editor.text_changed.connect(_invalidate)
	editor.text_set.connect(_invalidate)
	editor.caret_changed.connect(_invalidate)
	editor.focus_entered.connect(refresh)
	editor.focus_exited.connect(refresh)
	editor.gui_input.connect(_on_editor_input)
	editor.get_v_scroll_bar().value_changed.connect(_on_scroll)
	editor.get_h_scroll_bar().value_changed.connect(_on_scroll)
	assembly.changed.connect(_invalidate)
	refresh()


## IME、选择与只读状态没有统一变化信号，轻量轮询这些状态而不逐帧重新分析源码。
func _process(_delta: float) -> void:
	var available := _can_suggest()
	if available != _was_available or _context_dirty:
		refresh()
	if available and not suggestion.is_empty():
		# 编辑器在绘制时更新光标位置，下一次绘制读取同一基线以跟随滚动和缩放。
		queue_redraw()


## 收起提示时不删除文本；键盘和设置事件可立即调用以免使用过期候选。
func refresh() -> void:
	if editor == null or not is_inside_tree():
		return
	_layout_clip()
	_was_available = _can_suggest()
	if _context_dirty:
		var source := editor.text
		var caret := Vector2i(editor.get_caret_column(), editor.get_caret_line())
		if source != _source or caret != _caret:
			_dismissed = false
		_source = source
		_caret = caret
		_context_dirty = false
	suggestion = ""
	if _was_available and not _dismissed:
		suggestion = ProgramCompletion.suggest(_source, _caret.y, _caret.x, level, assembly)
	queue_redraw()


## 选区、多光标、输入法组合、弹出菜单与不可编辑页面交给原生编辑器处理。
func _can_suggest() -> bool:
	if not enabled or not is_instance_valid(editor) or not editor.is_visible_in_tree():
		return false
	if not editor.has_focus() or not editor.editable or editor.has_ime_text() or editor.has_selection() or editor.get_caret_count() != 1:
		return false
	if editor.get_menu().visible or not editor.is_caret_visible():
		return false
	var line := editor.get_caret_line()
	if line < editor.get_first_visible_line() or line > editor.get_last_full_visible_line():
		return false
	# 允许自动配对产生的括号；已有参数或其它词不挪动，以免灰字遮住真实代码。
	for character in editor.get_line(line).substr(editor.get_caret_column()):
		if not character in " ()[]{},":
			return false
	return true


## 补全独立成为一次撤销操作；无候选、Shift+Tab 或组合快捷键继续走原生缩进。
func _on_editor_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.ctrl_pressed or event.meta_pressed or event.alt_pressed or event.shift_pressed:
		return
	refresh()
	if suggestion.is_empty():
		return
	if event.keycode == KEY_ESCAPE:
		_dismissed = true
		suggestion = ""
		editor.accept_event()
		queue_redraw()
	elif event.keycode == KEY_TAB:
		var accepted := suggestion
		editor.accept_event()
		editor.begin_complex_operation()
		editor.insert_text_at_caret(accepted)
		editor.end_complex_operation()
		_invalidate()


## 内容发生变化后在下次刷新重新获取源码，避免使用缓存的前缀接受错误文本。
func _invalidate() -> void:
	_context_dirty = true
	refresh()


## 滚动后先更新可见性，再等编辑器绘制刷新后的字符位置。
func _on_scroll(_value: float) -> void:
	refresh()


## 可绘制区排除行号、内边距和滚动条，灰字不会越过编辑卡片或覆盖其它控件。
func _layout_clip() -> void:
	var style := editor.get_theme_stylebox("normal")
	position = Vector2(style.get_margin(SIDE_LEFT) + editor.get_total_gutter_width(), style.get_margin(SIDE_TOP))
	var bottom_right := Vector2(style.get_margin(SIDE_RIGHT), style.get_margin(SIDE_BOTTOM))
	if editor.get_v_scroll_bar().visible:
		bottom_right.x += editor.get_v_scroll_bar().size.x
	if editor.get_h_scroll_bar().visible:
		bottom_right.y += editor.get_h_scroll_bar().size.y
	size = (editor.size - position - bottom_right).max(Vector2.ZERO)


## 使用相同矢量字体、字号和原生光标基线，保持高分辨率与缩放下的文字对齐。
func _draw() -> void:
	if suggestion.is_empty() or not _can_suggest():
		return
	_layout_clip()
	var character_rect := editor.get_rect_at_line_column(editor.get_caret_line(), editor.get_caret_column())
	if character_rect.position.x < 0 or character_rect.position.y < 0:
		return
	var font := editor.get_theme_font("font")
	var font_size := editor.get_theme_font_size("font_size")
	var origin := editor.get_caret_draw_pos() - position - Vector2(0, font.get_descent(font_size))
	if origin.x < 0 or origin.x >= size.x:
		return
	var tail := editor.get_line(editor.get_caret_line()).substr(editor.get_caret_column())
	if not tail.strip_edges().is_empty():
		_draw_paired_tail(font, font_size, origin, character_rect, tail)
	draw_string(font, origin, suggestion, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ghost_color())


## 从当前代码区读取补全灰色；独立使用补全组件时保留原来的浅色后备颜色。
func ghost_color() -> Color:
	return editor.get_theme_color("completion_ghost_color") if editor.has_theme_color("completion_ghost_color") else GHOST_COLOR


## 自动配对括号暂时在灰字之后绘制，底层文本与光标完全不变；接受后原生文本自然接替。
func _draw_paired_tail(font: Font, font_size: int, origin: Vector2, character_rect: Rect2i, tail: String) -> void:
	var surface := editor.get_theme_stylebox("normal") as StyleBoxFlat
	var background := surface.bg_color if surface != null else Color("F5F7FB")
	background = background.blend(editor.get_theme_color("background_color"))
	background = background.blend(editor.get_line_background_color(editor.get_caret_line()))
	if editor.highlight_current_line:
		background = background.blend(editor.get_theme_color("current_line_color"))
	var top := float(character_rect.position.y) - position.y
	# 留出原生光标的首个像素，保持编辑器自己的光标闪烁；遮罩只覆盖原来的括号墨迹。
	draw_rect(Rect2(Vector2(origin.x + 1, top), Vector2(maxf(0, size.x - origin.x - 1), editor.get_line_height())), background)
	var color := editor.get_theme_color("font_color")
	if editor.syntax_highlighter is CodeHighlighter:
		color = editor.syntax_highlighter.symbol_color
	var offset := font.get_string_size(suggestion, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, origin + Vector2(offset, 0), tail, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
