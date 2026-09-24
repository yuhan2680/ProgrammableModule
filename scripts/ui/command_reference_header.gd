class_name CommandReferenceHeader
extends Control
## 指令窗口独立的导航与搜索工具栏，只报告查询和关闭意图，不读取模块或关卡规则。

signal close_requested
signal query_changed(query: String)

const HEIGHT := 44.0
const NAVIGATION_WIDTH := 88.0
const SEARCH_MIN_WIDTH := 240.0
const SEARCH_MAX_WIDTH := 344.0
const SEARCH_BACKGROUND := Color("EAEDF2")

var navigation: Panel
var back_button: Button
var search_button: Button
var search_input: LineEdit
var search_close_button: Button
var _forward_button: Button
var _title: Label
var _search_area: Control
var _search_surface: Panel
var _search_icon: TextureRect
var _search_tween: Tween
var _search_open := false
var _search_progress := 0.0
var _active := false
var _back_caption := "返回装配"


## 只构建一次控件，让分类切换和查询结果更新保留光标、输入法及动画状态。
func _ready() -> void:
	custom_minimum_size.y = HEIGHT
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_navigation()
	_build_search()
	_update_tooltips()
	resized.connect(_layout_header)
	visible = _active
	_layout_header()


## 语言切换只刷新标题和提示，不翻译玩家键入的搜索文本。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		_layout_header.call_deferred()


## 窗口关闭时立即停止动画，避免隐藏控件在稍后回调中重新取得焦点。
func _exit_tree() -> void:
	_stop_search_tween()


## 重复激活不重置查询；停用时保留目标状态，由外层决定下次打开是否清空。
func set_active(active: bool) -> void:
	if _active == active and visible == active:
		return
	_active = active
	visible = active
	if not is_node_ready():
		return
	if not active:
		_stop_search_tween()
		search_input.release_focus()
		_set_search_progress(1.0 if _search_open else 0.0)
	else:
		_layout_header()


## 搜索固定右端并向左缓动展开，关闭时清空过滤，反向点击会从当前进度继续运动。
func set_search_open(open: bool, animate: bool = true) -> void:
	if not is_node_ready():
		return
	if _search_open == open and animate:
		return
	_stop_search_tween()
	_search_open = open
	search_input.editable = open
	if not open:
		search_input.release_focus()
		if not search_input.text.is_empty():
			# 程序赋值不会触发 LineEdit.text_changed，因此在此只广播一次清空查询。
			search_input.text = ""
			query_changed.emit("")
	_layout_header()
	if open and _active:
		search_input.grab_focus()
	var target := 1.0 if open else 0.0
	if not animate or not _active or is_equal_approx(_search_progress, target):
		_set_search_progress(target)
		_finish_search_motion()
		return
	_search_tween = create_tween()
	_search_tween.set_trans(Tween.TRANS_CUBIC)
	_search_tween.set_ease(Tween.EASE_OUT if open else Tween.EASE_IN_OUT)
	_search_tween.tween_method(_set_search_progress, _search_progress, target, 0.32 if open else 0.24)
	_search_tween.tween_callback(_finish_search_motion)


## 查询文本原样交由外层匹配当前本土化名称及指令，不在工具栏内解释或修改它。
func get_query() -> String:
	return search_input.text if search_input != null else ""


## 复用药丸导航的几何与交互，仅替换本窗口专用高清图标，前进始终禁用。
func _build_navigation() -> void:
	navigation = GameTheme.navigation_pill(self, _request_close, "返回装配", "CommandReference")
	back_button = navigation.get_node("CommandReferenceBackButton")
	_forward_button = navigation.get_node("CommandReferenceForwardButton")
	_set_sharp_icon(back_button, "res://assets/ui/reference_back.svg")
	_set_sharp_icon(_forward_button, "res://assets/ui/reference_forward.svg")
	_title = GameTheme.label(self, "指令集合", 22)
	_title.name = "CommandReferenceTitle"
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE


## 收起按钮与输入框分离，但共用动画进度，避免转场出现错位的边角或突然跳动。
func _build_search() -> void:
	_search_area = Control.new()
	_search_area.name = "CommandReferenceSearchArea"
	_search_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_search_area)
	_search_surface = Panel.new()
	_search_surface.name = "CommandReferenceSearchSurface"
	_search_surface.add_theme_stylebox_override("panel", _capsule_style(SEARCH_BACKGROUND))
	_search_surface.clip_contents = true
	_search_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_area.add_child(_search_surface)
	_search_icon = TextureRect.new()
	_search_icon.texture = load("res://assets/ui/reference_search.svg")
	_search_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_search_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_search_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_search_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_surface.add_child(_search_icon)
	search_input = LineEdit.new()
	search_input.name = "CommandReferenceSearchInput"
	search_input.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	search_input.editable = false
	search_input.add_theme_color_override("font_placeholder_color", GameTheme.MUTED)
	search_input.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	search_input.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	search_input.add_theme_stylebox_override("read_only", StyleBoxEmpty.new())
	search_input.text_changed.connect(_on_query_changed)
	search_input.gui_input.connect(_on_search_input)
	_search_surface.add_child(search_input)
	# 查询文本不自动翻译，但原生剪切、复制等菜单仍使用当前界面语言。
	search_input.get_menu().auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS
	search_button = _icon_button(_search_area, "CommandReferenceSearchButton", "res://assets/ui/reference_search.svg", _open_search)
	search_close_button = _icon_button(_search_area, "CommandReferenceSearchCloseButton", "res://assets/ui/reference_collapse.svg", _close_search)


## 图标控件保留44像素命中区，高清96像素纹理只按24逻辑像素显示，防止撑大布局。
func _icon_button(parent: Node, node_name: String, icon_path: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = Vector2(HEIGHT, HEIGHT)
	_set_sharp_icon(button, icon_path)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var color := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state == "pressed" else Color.TRANSPARENT if state == "focus" else SEARCH_BACKGROUND
		button.add_theme_stylebox_override(state, _capsule_style(color, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT))
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## 分离图像采样分辨率与界面尺寸，并保留SVG原色和禁用状态的透明度反馈。
func _set_sharp_icon(button: Button, path: String) -> void:
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 24)
	button.icon = load(path)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))


## 圆形入口和展开的胶囊共享圆角与零内边距，让收起后的外观保持一致。
func _capsule_style(color: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := GameTheme.box(color, border, 22)
	style.set_content_margin_all(0)
	return style


## 本土化标题可缩略，搜索区永不越过导航；整个动画中输入框右边缘固定不变。
func _layout_header() -> void:
	if _search_area == null:
		return
	navigation.position = Vector2.ZERO
	navigation.size = Vector2(NAVIGATION_WIDTH, HEIGHT)
	back_button.position = Vector2.ZERO
	back_button.size = Vector2(HEIGHT, HEIGHT)
	_forward_button.position = Vector2(HEIGHT, 0)
	_forward_button.size = Vector2(HEIGHT, HEIGHT)
	var title_left := NAVIGATION_WIDTH + 18.0
	var title_width := _title.get_theme_font("font").get_string_size(tr(_title.text), HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	var desired_width := clampf(size.x - title_left - title_width - 24, SEARCH_MIN_WIDTH, SEARCH_MAX_WIDTH)
	var maximum_room := maxf(HEIGHT, size.x - title_left - 12)
	var expanded_width := minf(desired_width, maximum_room)
	var animated_width := lerpf(HEIGHT, expanded_width, _search_progress)
	_search_area.position = Vector2(size.x - animated_width, 0)
	_search_area.size = Vector2(animated_width, HEIGHT)
	var title_room := maxf(0, _search_area.position.x - title_left - 20)
	_title.visible = title_room >= 24
	_title.position = Vector2(title_left, 0)
	_title.size = Vector2(title_room, HEIGHT)
	_layout_search(animated_width)


## 输入区在圆形入口基础上向左展开，关闭图标等两块底面分开后再渐入。
func _layout_search(width: float) -> void:
	var surface_left := 52.0 * _search_progress
	_search_surface.position = Vector2(surface_left, 0)
	_search_surface.size = Vector2(maxf(0, width - surface_left), HEIGHT)
	_search_icon.position = Vector2(10, 10)
	_search_icon.size = Vector2(24, 24)
	_search_icon.visible = _search_open or _search_progress > 0
	search_input.position = Vector2(40, 0)
	search_input.size = Vector2(maxf(0, _search_surface.size.x - 54), HEIGHT)
	search_input.visible = _search_open or _search_progress > 0
	search_input.modulate.a = _search_progress
	search_input.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE
	search_button.position = Vector2(width - HEIGHT, 0)
	search_button.size = Vector2(HEIGHT, HEIGHT)
	search_button.visible = not _search_open and _search_progress <= 0
	search_close_button.position = Vector2.ZERO
	search_close_button.size = Vector2(HEIGHT, HEIGHT)
	search_close_button.visible = _search_open or _search_progress > 0
	search_close_button.modulate.a = clampf((_search_progress - 0.35) / 0.65, 0, 1)
	search_close_button.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE


## 悬停提示使用当前语言，而LineEdit的原始查询始终由玩家控制。
func _update_tooltips() -> void:
	back_button.tooltip_text = tr(_back_caption)
	_forward_button.tooltip_text = tr("没有可前进的页面")
	search_button.tooltip_text = tr("搜索指令或功能")
	search_input.placeholder_text = tr("搜索指令或功能")
	search_input.tooltip_text = tr("搜索指令或功能")
	search_close_button.tooltip_text = tr("收起搜索")


## 动画仅更新规范化进度，窗口缩放时可按新宽度连续重排。
func _set_search_progress(progress: float) -> void:
	_search_progress = clampf(progress, 0, 1)
	_layout_header()


## 中止旧动画避免新旧Tween同时控制输入区宽度。
func _stop_search_tween() -> void:
	if _search_tween != null and _search_tween.is_valid():
		_search_tween.kill()
	_search_tween = null


## 收起结束才交还放大镜焦点，隐藏窗口不会因此意外抢夺输入。
func _finish_search_motion() -> void:
	_search_tween = null
	if not _search_open and _active:
		var focus := get_viewport().gui_get_focus_owner()
		# 动画结束不能抢走玩家在收起期间主动移到目录或正文的焦点。
		if focus == null or focus == search_close_button or focus == search_input:
			search_button.grab_focus()


## 放大镜只打开输入区，查询结果由独立内容窗口处理。
func _open_search() -> void:
	if _active:
		set_search_open(true)


## 双箭头和输入框内Esc共用收起路径。
func _close_search() -> void:
	set_search_open(false)


## 原生输入事件报告查询，光标与中文输入法继续由LineEdit管理。
func _on_query_changed(query: String) -> void:
	query_changed.emit(query)


## 首次Esc收起并清空搜索且消费事件，再次Esc由外层关闭指令窗口。
func _on_search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		search_input.accept_event()
		set_search_open(false)


## 返回箭头只发出关闭请求，组件不持有或修改游戏会话。
func _request_close() -> void:
	if _active:
		close_requested.emit()


## 同一资料窗口可从装配或编程打开，返回提示跟随来源并支持即时本土化。
func set_back_caption(caption: String) -> void:
	_back_caption = caption
	if back_button != null:
		back_button.tooltip_text = tr(_back_caption)
