class_name ModuleRestrictionChoice
extends Button
## 固定宽度的模块禁止列表；正文在独立裁剪区绘制，不以完整文字撑大属性卡片。

const SCROLL_SPEED := 32.0
const SCROLL_GAP := 32.0
const HOVER_DELAY := 0.55

var _content: ContentRegistry
var _restricted := PackedStringArray()
var _clip: Control
var _caption: Label
var _repeat: Label
var _arrow: TextureRect
var _hovered := false
var _elapsed := 0.0
var _offset := 0.0
var _text_width := 0.0
var _overflow := false
var _focus_style: StyleBox
var _keyboard_focus_visible := false


## 标准按钮负责键盘与鼠标激活，文本子节点只绘制并保持裁剪。
func _ready() -> void:
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	custom_minimum_size = Vector2(96, 32)
	_focus_style = get_theme_stylebox("focus")
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_clip = Control.new()
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)
	for index in 2:
		var label := Label.new()
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		GameTheme.font_size(label, "font_size", 12)
		_clip.add_child(label)
		if index == 0:
			_caption = label
		else:
			_repeat = label
	_arrow = TextureRect.new()
	_arrow.texture = get_theme_icon("arrow", "OptionButton")
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_arrow)
	resized.connect(_layout_content)
	mouse_entered.connect(_begin_hover)
	mouse_exited.connect(_end_hover)
	visibility_changed.connect(_end_hover)
	set_process(false)
	_refresh_caption()


## 重载目录或切换地图只更新显示；使用原模块 ID，不提交编辑事务。
func configure(content: ContentRegistry, restricted: PackedStringArray) -> void:
	_content = content
	_restricted = restricted.duplicate()
	if is_node_ready():
		_refresh_caption()


## 模块显示名按当前界面语言组合，整段文本仅占裁剪区，悬停也可读取完整提示。
func _refresh_caption() -> void:
	var names := PackedStringArray()
	for module_id in _restricted:
		var definition := _content.get_module(module_id) if _content != null else null
		names.append(tr(definition.display_name) if definition != null else module_id)
	_caption.text = tr("不限制") if names.is_empty() else ", ".join(names)
	_repeat.text = _caption.text
	tooltip_text = _caption.text
	_text_width = ceilf(_caption.get_theme_font("font").get_string_size(_caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	_end_hover()
	_layout_content()
	# 语言或选项更新可能发生在鼠标仍停留框内时；无需先移出再进入才开始走字。
	if is_hovered() and is_visible_in_tree():
		_begin_hover()


## 为下拉箭头保留右侧空间，正文长度不会影响按钮最小宽度。
func _layout_content() -> void:
	if _clip == null:
		return
	_clip.position = Vector2(12, 0)
	_clip.size = Vector2(maxf(1.0, size.x - 34.0), size.y)
	_arrow.position = Vector2(size.x - 19.0, (size.y - 9.0) * 0.5)
	_arrow.size = Vector2(9, 9)
	_overflow = _text_width > _clip.size.x
	for label in [_caption, _repeat]:
		label.size = Vector2(maxf(_text_width, _clip.size.x), size.y)
	_repeat.visible = _hovered and _overflow
	_update_positions()


## 超长名称先短暂停留，再从右向左循环走字，短名称保持静止。
func _begin_hover() -> void:
	_hovered = true
	_elapsed = 0.0
	_repeat.visible = _overflow
	set_process(_overflow)


## 离开、隐藏和切换内容后还原静态开头，不让走字状态带到其他地图。
func _end_hover() -> void:
	_hovered = false
	_elapsed = 0.0
	_offset = 0.0
	set_process(false)
	if _repeat != null:
		_repeat.hide()
		_update_positions()


## 走字仅在可见且悬停时使用时间增量，刷新率不会改变移动速度。
func _process(delta: float) -> void:
	if not is_visible_in_tree() or not _hovered or not _overflow:
		_end_hover()
		return
	_elapsed += delta
	if _elapsed > HOVER_DELAY:
		_offset = -fposmod((_elapsed - HOVER_DELAY) * SCROLL_SPEED, _text_width + SCROLL_GAP)
		_update_positions()


## 两份正文首尾衔接，让整个名称列表反复经过固定显示区。
func _update_positions() -> void:
	_caption.position = Vector2(_offset, 0)
	_repeat.position = Vector2(_offset + _text_width + SCROLL_GAP, 0)


## 鼠标操作只隐藏焦点描边，保留真实焦点，让关闭菜单后仍能继续键盘导航。
func set_keyboard_focus_visible(enabled: bool) -> void:
	if _keyboard_focus_visible == enabled:
		return
	_keyboard_focus_visible = enabled
	add_theme_stylebox_override("focus", _focus_style if enabled else StyleBoxEmpty.new())


## 浮层会先消费鼠标和 Esc，允许菜单同步入口采用的焦点显示方式。
func is_keyboard_focus_visible() -> bool:
	return _keyboard_focus_visible


## 鼠标移动或点击清除蓝色描边，键盘输入恢复提示，不吞掉控件原有事件。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		set_keyboard_focus_visible(false)
	elif event is InputEventKey and event.pressed:
		set_keyboard_focus_visible(true)


## 语言切换只重绘显示名，不修改禁止模块的 ID 和地图历史。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _caption != null:
		_refresh_caption()
