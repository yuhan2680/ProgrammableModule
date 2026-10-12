class_name WorkbenchCodeZoom
extends PanelContainer
## 代码字号胶囊只发送百分比变化，编辑内容、光标与撤销历史由工作台管理。

signal zoom_changed(percent: int)

const MIN_PERCENT := 50
const MAX_PERCENT := 200
const STEP_PERCENT := 10
const DEFAULT_PERCENT := 100
const CONTROL_SIZE := Vector2(56, 28)

class ZoomButton:
	extends Button
	var is_plus := false
	var glyph_color := GameTheme.TEXT

	## 直接按按钮矩形中心绘制线段，不使用字体基线定位减号和加号。
	func _draw() -> void:
		var color := glyph_color
		if disabled:
			color.a *= 0.35
		var center := size * 0.5
		_draw_stroke(center - Vector2(4.5, 0), center + Vector2(4.5, 0), color)
		if is_plus:
			_draw_stroke(center - Vector2(0, 4.5), center + Vector2(0, 4.5), color)

	## 圆头细线在任意画布比例下保留相同逻辑位置和抗锯齿。
	func _draw_stroke(start: Vector2, finish: Vector2, color: Color) -> void:
		draw_line(start, finish, color, 1.7, true)
		draw_circle(start, 0.85, color, true, -1, true)
		draw_circle(finish, 0.85, color, true, -1, true)

var decrease_button: Button
var increase_button: Button
var _percent := DEFAULT_PERCENT
var _color_mode := GameSettings.DEFAULT_CODE_COLOR_MODE
var _interaction_enabled := true
var _keyboard_focus_visible := false
var _divider_color := Color("D6DCE6")


## 固定逻辑尺寸不受全局文字缩放影响，两个原生按钮各保留完整的键盘命中区。
func _ready() -> void:
	custom_minimum_size = CONTROL_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	add_child(row)
	decrease_button = _make_button(row, false)
	increase_button = _make_button(row, true)
	_apply_colors()
	_sync_buttons()


## 中间细线属于整个胶囊，不占自动布局宽度，也不截获鼠标事件。
func _draw() -> void:
	draw_line(Vector2(size.x * 0.5, 8), Vector2(size.x * 0.5, size.y - 8), _divider_color, 1.0, true)


## 外部回填静默限制到合法区间，不反向触发工作台的字号修改回调。
func set_zoom_percent(percent: int) -> void:
	_percent = clampi(percent, MIN_PERCENT, MAX_PERCENT)
	if is_node_ready():
		_sync_buttons()


## 公开当前百分比供工作台读取，组件不访问任何设置文件或编辑器。
func get_zoom_percent() -> int:
	return _percent


## 预览动画等外部状态可统一锁定操作，解锁后仍保留百分比端点禁用规则。
func set_interaction_enabled(enabled: bool) -> void:
	_interaction_enabled = enabled
	if is_node_ready():
		_sync_buttons()


## 配色只覆盖当前胶囊，未知模式回到浅色，不改通用主题。
func set_color_mode(mode: String) -> void:
	_color_mode = "dark" if mode == "dark" else "light"
	if is_node_ready():
		_apply_colors()


## 同一输入方式规则作用于两半按钮，鼠标无残留边框，键盘导航仍可显示焦点。
func set_keyboard_focus_visible(enabled: bool) -> void:
	_keyboard_focus_visible = enabled
	if is_node_ready():
		_apply_focus_styles()


## 创建空文字的原生按钮，加减图案由居中线段独立绘制。
func _make_button(parent: Node, plus: bool) -> ZoomButton:
	var button := ZoomButton.new()
	button.name = "CodeZoomIncreaseButton" if plus else "CodeZoomDecreaseButton"
	button.is_plus = plus
	button.custom_minimum_size = Vector2(28, 28)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.size_flags_vertical = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(_change_zoom.bind(STEP_PERCENT if plus else -STEP_PERCENT))
	parent.add_child(button)
	return button


## 每次用户操作只改变十个百分点；边界按钮禁用，重复边界值不发送信号。
func _change_zoom(delta: int) -> void:
	if not _interaction_enabled:
		return
	var next := clampi(_percent + delta, MIN_PERCENT, MAX_PERCENT)
	if next == _percent:
		return
	_percent = next
	_sync_buttons()
	if not _keyboard_focus_visible:
		_release_button_focus()
	zoom_changed.emit(_percent)


## 禁用状态和提示都来自同一个当前值，语言切换时重新格式化百分比。
func _sync_buttons() -> void:
	# 关闭自动翻译会在_ready中同步发出翻译通知，此时两个按钮可能尚未创建。
	if decrease_button == null or increase_button == null:
		return
	decrease_button.disabled = not _interaction_enabled or _percent <= MIN_PERCENT
	increase_button.disabled = not _interaction_enabled or _percent >= MAX_PERCENT
	decrease_button.tooltip_text = tr("缩小代码字号（当前 %d%%）") % _percent
	increase_button.tooltip_text = tr("放大代码字号（当前 %d%%）") % _percent
	for button: Button in [decrease_button, increase_button]:
		button.queue_redraw()
		if button.disabled and button.has_focus():
			var other := increase_button if button == decrease_button else decrease_button
			if _keyboard_focus_visible and not other.disabled:
				other.grab_focus()
			else:
				button.release_focus()


## 一张灰色底板保持完整圆角，悬停与按下只覆盖对应半边。
func _apply_colors() -> void:
	var dark := _color_mode == "dark"
	var surface := GameTheme.box(Color("30343B") if dark else Color("E9EDF3"), Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	add_theme_stylebox_override("panel", surface)
	_divider_color = Color("4B505A") if dark else Color("D6DCE6")
	for button: ZoomButton in [decrease_button, increase_button]:
		button.glyph_color = GameTheme.CODE_DARK.text if dark else GameTheme.TEXT
		for state: String in ["normal", "disabled", "hover", "pressed", "hover_pressed"]:
			var state_fill := Color.TRANSPARENT
			if state == "hover":
				state_fill = Color("3F444D") if dark else Color("DFE6EE")
			elif state in ["pressed", "hover_pressed"]:
				state_fill = Color("4A5260") if dark else Color("D1DCEB")
			button.add_theme_stylebox_override(state, _segment_style(state_fill, Color.TRANSPARENT, button == decrease_button))
		button.queue_redraw()
	_apply_focus_styles()
	queue_redraw()


## 焦点边框只在键盘导航时绘制，浅深配色使用相同可识别的蓝色。
func _apply_focus_styles() -> void:
	for button: Button in [decrease_button, increase_button]:
		var style: StyleBox = _segment_style(Color.TRANSPARENT, GameTheme.ACCENT, button == decrease_button) if _keyboard_focus_visible else StyleBoxEmpty.new()
		button.add_theme_stylebox_override("focus", style)


## 胶囊外端保留圆角，内端接缝保持平直，不在中间叠出两个圆形。
func _segment_style(fill: Color, border: Color, left: bool) -> StyleBoxFlat:
	var style := GameTheme.box(fill, border, 14)
	style.set_content_margin_all(0)
	style.corner_radius_top_left = 14 if left else 0
	style.corner_radius_bottom_left = 14 if left else 0
	style.corner_radius_top_right = 0 if left else 14
	style.corner_radius_bottom_right = 0 if left else 14
	return style


## 点击胶囊外的空白也释放旧焦点，不要求另一个控件先获得焦点。
func _release_button_focus() -> void:
	for button: Button in [decrease_button, increase_button]:
		if button.has_focus():
			button.release_focus()


## 在原生控件接收输入前记录鼠标或键盘方式，保留 Tab、方向键与回车提示。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseButton and event.pressed:
		set_keyboard_focus_visible(false)
		_release_button_focus()
	elif event is InputEventKey and event.pressed and event.keycode in [KEY_TAB, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		set_keyboard_focus_visible(true)


## 翻译刷新不重建控件，不改变用户当前百分比或原生焦点。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_sync_buttons()
