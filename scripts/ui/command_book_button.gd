class_name CommandBookButton
extends Button
## 指令入口保留原生 Button 交互，书页通过同一组矢量控制点开合，不更改命中区。

const ANIMATION_SECONDS := 0.12
const ICON_SIZE := 24.0
const STROKE_WIDTH := 1.7
const INK := Color("202633")
const OPEN_ICON = preload("res://assets/ui/assembly_book.svg")
const CLOSED_ICON = preload("res://assets/ui/command_book_closed.svg")

var book_open := false
var book_progress := 0.0:
	set(value):
		book_progress = clampf(value, 0.0, 1.0)
		queue_redraw()
var _book_tween: Tween
var _focus_style: StyleBox
var _keyboard_focus_visible := false


## 原生图标保留为资源与布局依据；实际绘制居中，避免 SVG 内部留白造成偏心。
func _ready() -> void:
	icon = CLOSED_ICON
	_focus_style = get_theme_stylebox("focus")
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# 只隐藏原生图标这一绘制层，文字、焦点、提示和真实按钮事件继续由 Button 管理。
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color", "icon_disabled_color"]:
		add_theme_color_override(state, Color.TRANSPARENT)
	resized.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	visibility_changed.connect(_on_visibility_changed)
	set_book_open(book_open, false)


## 窗口负责决定开合时序；重复调用会从当前书页位置继续，不叠加动画或翻转目标。
func set_book_open(open: bool, animated: bool = true) -> void:
	book_open = open
	icon = OPEN_ICON if open else CLOSED_ICON
	if _book_tween != null:
		_book_tween.kill()
		_book_tween = null
	var target := 1.0 if open else 0.0
	if not animated or not is_inside_tree() or is_equal_approx(book_progress, target):
		book_progress = target
		return
	_book_tween = create_tween()
	_book_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_book_tween.tween_property(self, "book_progress", target, ANIMATION_SECONDS)


## 两个 SVG 端点的外轮廓均以 (12,12) 为中心，中途按同源书页轮廓逐点展开。
func _draw() -> void:
	var icon_size := minf(ICON_SIZE, minf(size.x, size.y))
	var icon_rect := Rect2((size - Vector2.ONE * icon_size) * 0.5, Vector2.ONE * icon_size)
	var tint := Color(1, 1, 1, 0.36 if disabled else 1.0)
	if is_zero_approx(book_progress) or is_equal_approx(book_progress, 1.0):
		draw_texture_rect(CLOSED_ICON if book_progress < 0.5 else OPEN_ICON, icon_rect, false, tint)
		return
	draw_set_transform(icon_rect.position, 0.0, Vector2.ONE * icon_size / ICON_SIZE)
	var color := INK
	color.a = tint.a
	# 封面从合拢边缘向左右展开，书脊移动到正中；这是真实路径形变而非两张图交叉淡入。
	var closed_cover := PackedVector2Array([Vector2(5.5, 6.25), Vector2(5.5, 6.25), Vector2(5.5, 20.25), Vector2(18.5, 20.25), Vector2(18.5, 6.25), Vector2(18.5, 6.25)])
	var open_cover := PackedVector2Array([Vector2(4.5, 6.25), Vector2(2, 6.25), Vector2(2, 20.25), Vector2(22, 20.25), Vector2(22, 6.25), Vector2(19.5, 6.25)])
	var cover_color := color
	cover_color.a *= book_progress
	_stroke(_morph_points(closed_cover, open_cover), cover_color)
	var closed := PackedVector2Array([
		Vector2(7.75, 20.25), Vector2(7, 20.25), Vector2(6.25, 20.25), Vector2(5.5, 20.25),
		Vector2(5.5, 3.75), Vector2(6.25, 3.75), Vector2(7, 3.75), Vector2(7.75, 3.75),
		Vector2(10.5, 3.75), Vector2(14.5, 3.75), Vector2(18.5, 3.75),
		Vector2(18.5, 20.25), Vector2(14.5, 20.25), Vector2(10.5, 20.25), Vector2(7.75, 20.25)])
	var opened := PackedVector2Array([
		Vector2(12, 20.25), Vector2(9.8, 18.45), Vector2(7.2, 17.75), Vector2(4.5, 17.75),
		Vector2(4.5, 3.75), Vector2(7.2, 3.75), Vector2(9.8, 4.45), Vector2(12, 6.25),
		Vector2(14.2, 4.45), Vector2(16.8, 3.75), Vector2(19.5, 3.75),
		Vector2(19.5, 17.75), Vector2(16.8, 17.75), Vector2(14.2, 18.45), Vector2(12, 20.25)])
	var page := _morph_points(closed, opened)
	var outline := _curve(page[0], page[1], page[2], page[3])
	outline.append_array(_curve(page[4], page[5], page[6], page[7]))
	outline.append_array(_curve(page[7], page[8], page[9], page[10]))
	outline.append_array(_curve(page[11], page[12], page[13], page[14]))
	_stroke(outline, color)
	_stroke(PackedVector2Array([page[7], page[0]]), color)
	draw_set_transform(Vector2.ZERO)


## 控制点按相同拓扑插值，正向开书和反向合书具有连续的中间帧。
func _morph_points(closed: PackedVector2Array, opened: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(closed.size()):
		points.append(closed[index].lerp(opened[index], book_progress))
	return points


## 三次曲线细分为抗锯齿线段，使翻页弧线保持与 SVG 端点相同的柔和轮廓。
func _curve(start: Vector2, first: Vector2, second: Vector2, end: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for step in range(13):
		points.append(start.bezier_interpolate(first, second, end, float(step) / 12.0))
	return points


## 圆端线条与 SVG 的 round 端点一致，动画中不出现尖角或粗细突变。
func _stroke(points: PackedVector2Array, color: Color) -> void:
	draw_polyline(points, color, STROKE_WIDTH, true)
	for point in points:
		draw_circle(point, STROKE_WIDTH * 0.5, color, true, -1.0, true)


## 只隐藏鼠标焦点外观，保留真实焦点和 Tab 导航；弹窗可同步关闭时的输入方式。
func set_keyboard_focus_visible(enabled: bool) -> void:
	_keyboard_focus_visible = enabled
	if _focus_style != null:
		add_theme_stylebox_override("focus", _focus_style if enabled else StyleBoxEmpty.new())


## 浮层读取打开方式，以便键盘返回时保留可见焦点、鼠标返回时不产生蓝圈。
func is_keyboard_focus_visible() -> bool:
	return _keyboard_focus_visible


## 输入模式与现有地图编辑器一致，鼠标或触摸隐藏描边，键盘恢复焦点提示。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		set_keyboard_focus_visible(false)
	elif event is InputEventKey and event.pressed:
		set_keyboard_focus_visible(true)


## 页面离开后立即收书，避免导航或父层销毁中留下半开图标。
func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		set_book_open(false, false)


## 控件移出场景树时停止局部补间，不让旧动画干涉新的页头实例。
func _exit_tree() -> void:
	if _book_tween != null:
		_book_tween.kill()
