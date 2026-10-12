class_name LevelBrowserHeader
extends Control
## 选关页的轻量导航与搜索框；只发出用户意图，不读取目录、存档或关卡数据。

signal back_requested
signal refresh_requested
signal import_requested
signal sort_changed(enabled: bool)
signal query_changed(query: String)

const HEIGHT := GameTheme.NAVIGATION_HEIGHT
const NAVIGATION_WIDTH := GameTheme.NAVIGATION_WIDTH
const SEARCH_MAX_WIDTH := 344.0
const SEARCH_MIN_WIDTH := 240.0
const BUTTON_GAP := 12.0
const SEARCH_BACKGROUND := Color("EAEDF2")
const IconSources := preload("res://scripts/ui/level_browser_icon_sources.gd")

var _navigation: Panel
var _back_button: Button
var _forward_button: Button
var _title: Label
var _more_button: Button
var _actions_menu: LevelActionsMenu
var _search_area: Control
var _search_surface: Panel
var _search_icon: TextureRect
var _search_button: Button
var _search_input: LineEdit
var _search_close_button: Button
var _search_tween: Tween
var _search_open: bool = false
var _search_progress: float = 0.0
var _active: bool = false
var _icon_raster_scale := 1
var _focus_buttons: Array[Button] = []
var _focus_styles: Array[StyleBox] = []
var _keyboard_focus_visible := false
var _restore_search_focus := false


## 控件只创建一次，刷新目录时保留输入焦点、光标和正在进行的展开动画。
func _ready() -> void:
	custom_minimum_size.y = HEIGHT
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_navigation()
	_build_search()
	_build_actions_menu()
	resized.connect(_layout_header)
	visible = _active
	_layout_header()


## 翻译更新后重新测量标题，搜索区域始终与右侧更多按钮留出间距。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_layout_header.call_deferred()


## 页面离开时停止动画并吸附到目标状态；目录刷新重复激活时完全保留交互状态。
func set_active(active: bool) -> void:
	if _active == active and visible == active:
		return
	_active = active
	visible = active
	if not is_node_ready():
		return
	if not active:
		_actions_menu.close_menu(false)
		_stop_search_tween()
		_search_input.release_focus()
		_set_search_progress(1.0 if _search_open else 0.0)
	else:
		_layout_header()


## 以右侧固定点向左展开；关闭时清空筛选，但不把搜索状态写入任何玩家数据。
func set_search_open(open: bool, animate: bool = true) -> void:
	if not is_node_ready():
		return
	if _search_open == open and animate:
		return
	_actions_menu.close_menu(false)
	_stop_search_tween()
	_restore_search_focus = not open and _keyboard_focus_visible and (_search_input.has_focus() or _search_close_button.has_focus())
	_search_open = open
	_search_input.editable = open
	_search_input.context_menu_enabled = open
	if not open:
		_search_input.release_focus()
		if not _keyboard_focus_visible:
			_search_close_button.release_focus()
		if not _search_input.text.is_empty():
			_search_input.clear()
			query_changed.emit("")
	_layout_header()
	if open and _active:
		_search_input.grab_focus()
	var target := 1.0 if open else 0.0
	if not animate or not _active or is_equal_approx(_search_progress, target):
		_set_search_progress(target)
		_finish_search_motion()
		return
	# 插值进度而非绝对坐标：窗口缩放、语言改变时，右边缘仍稳定依附更多按钮。
	_search_tween = create_tween()
	_search_tween.set_trans(Tween.TRANS_CUBIC)
	_search_tween.set_ease(Tween.EASE_OUT if open else Tween.EASE_IN_OUT)
	_search_tween.tween_method(_set_search_progress, _search_progress, target, 0.32 if open else 0.24)
	_search_tween.tween_callback(_finish_search_motion)


## 向目录提供未经翻译或改写的输入，具体名称匹配由选关页负责。
func get_query() -> String:
	return _search_input.text if _search_input != null else ""


## 小 SVG 根据 Windows 页面比例重新栅格化，避免只放大原来 24 像素的导航与菜单图标。
func set_presentation_scale(factor: float) -> void:
	var raster_scale := ceili(maxf(1.0, factor))
	if raster_scale == _icon_raster_scale or not is_node_ready():
		return
	_icon_raster_scale = raster_scale
	_refresh_svg_icons(self, raster_scale)


## 只替换本页控件持有的纹理，保留原 SVG 路径及所有尺寸；恢复基准时释放放大副本。
func _refresh_svg_icons(node: Node, raster_scale: int) -> void:
	if node is Button or node is TextureRect:
		var texture: Texture2D = node.icon if node is Button else node.texture
		var path: String = node.get_meta("level_svg_source", texture.resource_path if texture != null else "")
		if path.ends_with(".svg") and path.begins_with("res://"):
			node.set_meta("level_svg_source", path)
			if node is Button:
				var icon_width := int(node.get_meta("level_svg_logical_width", node.get_theme_constant("icon_max_width")))
				if icon_width <= 0:
					icon_width = texture.get_width()
				node.set_meta("level_svg_logical_width", icon_width)
				node.expand_icon = true
				node.add_theme_constant_override("icon_max_width", icon_width)
			var rendered: Texture2D = load(path)
			if raster_scale > 1 and IconSources.SVG.has(path):
				var image := Image.new()
				# 源 XML 随脚本打包，不读取在正式导出中已替换为纹理的 .svg 文件。
				if image.load_svg_from_string(IconSources.SVG[path], raster_scale) == OK:
					rendered = ImageTexture.create_from_image(image)
			if node is Button:
				node.icon = rendered
			else:
				node.texture = rendered
	for child in node.get_children():
		_refresh_svg_icons(child, raster_scale)


## 左侧胶囊保留真实返回操作；没有浏览历史时，前进箭头明确禁用。
func _build_navigation() -> void:
	_navigation = GameTheme.navigation_pill(self, _request_back, "返回开始页面", "Level")
	_back_button = _navigation.get_node("LevelBackButton")
	_forward_button = _navigation.get_node("LevelForwardButton")
	_register_focus_button(_back_button)
	_title = GameTheme.label(self, "可编程模块", 22)
	_title.name = "LevelBrowserTitle"
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_more_button = _icon_button(self, "LevelMoreButton", "res://assets/ui/more.svg", "更多操作", _toggle_actions_menu)
	_more_button.add_theme_stylebox_override("normal", _capsule_style(SEARCH_BACKGROUND))


## 搜索按钮与展开后的输入框共用同一个圆角底面，动画中不会出现叠加圆角或接缝。
func _build_search() -> void:
	_search_area = Control.new()
	_search_area.name = "LevelSearchArea"
	_search_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_search_area)
	_search_surface = Panel.new()
	_search_surface.name = "LevelSearchSurface"
	_search_surface.add_theme_stylebox_override("panel", _capsule_style(SEARCH_BACKGROUND))
	_search_surface.clip_contents = true
	_search_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_area.add_child(_search_surface)
	_search_icon = TextureRect.new()
	_search_icon.texture = load("res://assets/ui/search.svg")
	_search_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_search_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_search_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_surface.add_child(_search_icon)
	_search_input = LineEdit.new()
	_search_input.name = "LevelSearchInput"
	_search_input.placeholder_text = "搜索关卡"
	_search_input.tooltip_text = "搜索关卡"
	_search_input.caret_blink = true
	_search_input.caret_blink_interval = 0.5
	_search_input.add_theme_color_override("font_placeholder_color", GameTheme.MUTED)
	_search_input.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_search_input.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_search_input.add_theme_stylebox_override("read_only", StyleBoxEmpty.new())
	_search_input.text_changed.connect(_on_query_changed)
	_search_input.gui_input.connect(_on_search_input)
	_search_surface.add_child(_search_input)
	_search_button = _icon_button(_search_area, "LevelSearchButton", "res://assets/ui/search.svg", "搜索关卡", _open_search)
	_search_close_button = _icon_button(_search_area, "LevelSearchCloseButton", "res://assets/ui/search_collapse.svg", "收起搜索", _close_search)
	_search_close_button.add_theme_stylebox_override("normal", _capsule_style(SEARCH_BACKGROUND))


## 图标保持矢量尺寸与统一命中区域；工具提示承担纯图标按钮的文字说明。
func _icon_button(parent: Node, node_name: String, icon_path: String, tooltip: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load(icon_path)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(HEIGHT, HEIGHT)
	button.add_theme_stylebox_override("normal", _capsule_style(Color.TRANSPARENT))
	button.add_theme_stylebox_override("hover", _capsule_style(Color("E2E8F1")))
	button.add_theme_stylebox_override("pressed", _capsule_style(Color("D7E4F5")))
	button.add_theme_stylebox_override("disabled", _capsule_style(Color.TRANSPARENT))
	button.add_theme_stylebox_override("focus", _capsule_style(Color.TRANSPARENT, Color("A7CDFF")))
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
	if action.is_valid():
		button.pressed.connect(action)
	parent.add_child(button)
	_register_focus_button(button)
	return button


## 鼠标操作隐藏按钮焦点圈，键盘操作保留原生焦点与对应圆角描边。
func _register_focus_button(button: Button) -> void:
	_focus_buttons.append(button)
	_focus_styles.append(button.get_theme_stylebox("focus"))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 输入方式只控制页头按钮外观，不改变搜索文字或键盘导航顺序。
func _set_keyboard_focus_visible(enabled: bool) -> void:
	if _keyboard_focus_visible == enabled:
		return
	_keyboard_focus_visible = enabled
	for index in range(_focus_buttons.size()):
		_focus_buttons[index].add_theme_stylebox_override("focus", _focus_styles[index] if enabled else StyleBoxEmpty.new())


## 空白点击延迟到原生控件命中完成后释放焦点，搜索和卡片仍收到原输入。
func _input(event: InputEvent) -> void:
	_observe_input(event)


## 更多菜单消费输入前也报告输入方式，避免归还页头焦点时重新出现鼠标蓝圈。
func _observe_input(event: InputEvent) -> void:
	if not _active or not is_visible_in_tree():
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		_set_keyboard_focus_visible(false)
		_restore_search_focus = false
	elif (event is InputEventKey or event is InputEventAction) and event.is_pressed():
		_set_keyboard_focus_visible(true)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not _actions_menu.is_open() and not _interactive_hit(event.position):
		_release_blank_focus.call_deferred(event.position)


## 仅清理本页头仍持有的焦点；别的按钮、输入框和弹层按原生规则取得焦点。
func _release_blank_focus(point: Vector2) -> void:
	if not _active or not is_visible_in_tree() or _actions_menu.is_open() or not get_viewport().get_visible_rect().has_point(point) or _interactive_hit(point):
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		focused.release_focus()


## 按实际命中控件父链识别交互区域，避免拖动光标或点击滚动条时误取消编辑。
func _interactive_hit(point: Vector2) -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	if is_instance_valid(hovered) and hovered.is_visible_in_tree() and hovered.get_global_rect().has_point(point):
		var target: Node = hovered
		while target != null:
			if target is BaseButton or target is LineEdit or target is TextEdit or target is Range:
				return true
			target = target.get_parent()
	return false


## 纯图标控件不需要主题默认内边距，44 像素命中区对应真正的圆形或胶囊。
func _capsule_style(color: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := GameTheme.box(color, border, 22)
	style.set_content_margin_all(0)
	return style


## 使用实际译文宽度分配空间，标题与搜索在最小窗口及英文界面中也不会互相覆盖。
func _layout_header() -> void:
	if _search_area == null:
		return
	_navigation.position = Vector2.ZERO
	_navigation.size = Vector2(NAVIGATION_WIDTH, HEIGHT)
	_back_button.position = Vector2.ZERO
	_back_button.size = Vector2(HEIGHT, HEIGHT)
	_forward_button.position = Vector2(HEIGHT, 0)
	_forward_button.size = Vector2(HEIGHT, HEIGHT)
	_more_button.position = Vector2(maxf(0.0, size.x - HEIGHT), 0)
	_more_button.size = Vector2(HEIGHT, HEIGHT)
	var search_right := _more_button.position.x - BUTTON_GAP
	var title_left := NAVIGATION_WIDTH + 18.0
	var title_width := _title.get_theme_font("font").get_string_size(tr(_title.text), HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	var search_width := clampf(search_right - title_left - title_width - 24.0, SEARCH_MIN_WIDTH, SEARCH_MAX_WIDTH)
	var animated_width := lerpf(HEIGHT, search_width, _search_progress)
	_search_area.position = Vector2(search_right - animated_width, 0)
	_search_area.size = Vector2(animated_width, HEIGHT)
	_title.position = Vector2(title_left, 0)
	_title.size = Vector2(maxf(0.0, _search_area.position.x - title_left - 20.0), HEIGHT)
	_layout_search(animated_width)


## 输入胶囊和收起按钮共享展开进度；右端始终不动，搜索内容仅在自身矩形内绘制。
func _layout_search(width: float) -> void:
	var surface_left := 52.0 * _search_progress
	_search_surface.position = Vector2(surface_left, 0)
	_search_surface.size = Vector2(width - surface_left, HEIGHT)
	_search_icon.position = Vector2(10, 10)
	_search_icon.size = Vector2(24, 24)
	_search_icon.visible = _search_open or _search_progress > 0.0
	_search_input.position = Vector2(40, 0)
	_search_input.size = Vector2(maxf(0.0, _search_surface.size.x - 54.0), HEIGHT)
	_search_input.visible = _search_open or _search_progress > 0.0
	_search_input.modulate.a = _search_progress
	_search_input.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE
	_search_button.position = Vector2(width - HEIGHT, 0)
	_search_button.size = Vector2(HEIGHT, HEIGHT)
	_search_button.visible = not _search_open and _search_progress <= 0.0
	_search_close_button.position = Vector2.ZERO
	_search_close_button.size = Vector2(HEIGHT, HEIGHT)
	_search_close_button.visible = _search_open or _search_progress > 0.0
	# 在两块区域分离后再显现关闭圆钮，避免动画起点短暂重叠出灰色台阶。
	_search_close_button.modulate.a = clampf((_search_progress - 0.35) / 0.65, 0.0, 1.0)
	_search_close_button.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE


## 动画仅驱动显示进度，立即重算几何可应对动画期间的窗口变化。
func _set_search_progress(progress: float) -> void:
	_search_progress = clampf(progress, 0.0, 1.0)
	_layout_header()


## 反向操作会中止旧动画，防止两个 Tween 同时争夺同一个搜索框宽度。
func _stop_search_tween() -> void:
	if _search_tween != null and _search_tween.is_valid():
		_search_tween.kill()
	_search_tween = null


## 仅键盘收起才交还搜索入口焦点；鼠标空白点击和期间取得的新焦点不会被动画抢回。
func _finish_search_motion() -> void:
	_search_tween = null
	var focused := get_viewport().gui_get_focus_owner()
	if _restore_search_focus and not _search_open and _active and not _actions_menu.is_open() and (focused == null or focused == _search_close_button):
		_search_button.grab_focus()
	_restore_search_focus = false


## 点击放大镜只改变搜索栏形态，不主动扫描或重建目录。
func _open_search() -> void:
	set_search_open(true)


## 双箭头与 Esc 复用同一个收起入口，保证筛选和动画始终一致。
func _close_search() -> void:
	set_search_open(false)


## 将文本变化原样交给页面过滤，输入法和光标仍由原生 LineEdit 管理。
func _on_query_changed(query: String) -> void:
	query_changed.emit(query)


## 搜索框内按 Esc 收起并消费事件，避免继续触发其他页面快捷键。
func _on_search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_search_input.accept_event()
		set_search_open(false)


## 导航操作交回页面路由，搜索组件不拥有任何游戏会话。
func _request_back() -> void:
	back_requested.emit()


## 刷新按钮只发出请求，重建关卡列表不会重建本组件。
func _request_refresh() -> void:
	refresh_requested.emit()


## 菜单常驻但默认隐藏，两个选项继续通过信号复用目录刷新与导入流程。
func _build_actions_menu() -> void:
	_actions_menu = LevelActionsMenu.new()
	_actions_menu.name = "LevelActionsMenu"
	_actions_menu.refresh_requested.connect(_request_refresh)
	_actions_menu.import_requested.connect(_request_import)
	_actions_menu.sort_changed.connect(_request_sort)
	_actions_menu.input_observed.connect(_observe_input)
	add_child(_actions_menu)


## 更多按钮只切换下拉菜单，菜单关闭由遮挡层处理，不把点击传给关卡卡片。
func _toggle_actions_menu() -> void:
	if not _active:
		return
	if _actions_menu.is_open():
		_actions_menu.close_menu()
	else:
		_actions_menu.popup_at(_more_button)


## 先由菜单收起，再请求上层打开导入对话框，避免两个输入层同时抢占操作。
func _request_import() -> void:
	import_requested.emit()


## 从选关页同步本次会话的排序状态，不触发排序回调或改写玩家存档。
func set_sort_enabled(enabled: bool) -> void:
	if _actions_menu != null:
		_actions_menu.set_sort_enabled(enabled)


## 排序只交给目录显示层处理，菜单不直接改动关卡目录或完成记录。
func _request_sort(enabled: bool) -> void:
	sort_changed.emit(enabled)
