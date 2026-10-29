class_name PlayerLevelListPanel
extends Control
## 玩家关卡文件列表只展示目录快照并发出操作请求，持久化与文件校验由外层负责。

signal rename_requested(entry: PlayerLevelRecord, new_name: String)
signal delete_requested(entry: PlayerLevelRecord)
signal edit_requested(entry: PlayerLevelRecord)
signal open_folder_requested(entry: PlayerLevelRecord)
signal migration_requested(entry: PlayerLevelRecord)

const COLUMN_WEIGHTS := [0.34, 0.18, 0.20, 0.28]
const MIN_COLUMN_WIDTH := 64.0
const COLUMN_DIVIDER_WIDTH := 12.0
const COLUMN_NAMES := ["PlayerLevelName", "PlayerLevelCreator", "PlayerLevelCreatedAt", "PlayerLevelStatus"]
const SORT_COLUMNS := ["name", "creator", "created_at", "status"]
const SORT_CAPTIONS := ["名称", "作者", "创建日期", "关卡状态"]
const SEARCH_HEIGHT := 44.0
const SEARCH_MAX_WIDTH := 344.0
const SEARCH_BACKGROUND := Color("EAEDF2")

var card_boundary: Control
var navigation_title: Label
var _entries: Array[PlayerLevelRecord] = []
var _rows: Dictionary = {}
var _content_fade: SettingsContentFade
var _surface: Control
var _scroll: ScrollContainer
var _scrollbar: VScrollBar
var _padding: MarginContainer
var _column: VBoxContainer
var _table_inset: MarginContainer
var _table_column: VBoxContainer
var _header_slot: Control
var _table_header: VBoxContainer
var _header_cover: ColorRect
var _header_columns: HBoxContainer
var _column_dividers: Array[PlayerLevelColumnDivider] = []
var _column_weights := PackedFloat64Array(COLUMN_WEIGHTS)
var _column_resize_index := -1
var _column_resize_total := 0.0
var _column_resize_pair := 0.0
var _column_resize_left := 0.0
var _rows_container: VBoxContainer
var _search_input: LineEdit
var _search_layer: CanvasLayer
var _search_area: Control
var _search_surface: Panel
var _search_glass: ColorRect
var _search_close_surface: Panel
var _search_close_glass: ColorRect
var _search_icon: TextureRect
var _search_button: Button
var _search_close_button: Button
var _search_tween: Tween
var _search_open := false
var _search_progress := 0.0
var _name_sort: Button
var _sort_buttons: Dictionary = {}
var _sort_chevrons: Dictionary = {}
var _sort_column := "name"
var _message: Label
var _empty: Label
var _context_menu: PlayerLevelListContextMenu
var _ascending := true
var _selected_path := ""
var _keyboard_focus := false
var _rename_entry: PlayerLevelRecord
var _rename_input: LineEdit
var _rename_label: Label


## 独立表格保持正常字号，加入共享白卡时只接受边界与导航，不读取用户目录。
func _ready() -> void:
	_build_ui()
	set_notify_transform(true)
	resized.connect(_layout_content)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_rebuild_rows()
	_layout_content.call_deferred()


## 刷新只替换传入记录并保留搜索和滚动位置，旧菜单与未提交重命名不能跨快照复用。
func set_entries(entries: Array[PlayerLevelRecord]) -> void:
	_entries.assign(entries)
	if is_node_ready():
		_message.hide()
		_rebuild_rows()


## 写盘或校验失败在当前行保留输入与提示，外层无须弹出阻塞对话框。
func show_entry_error(entry: PlayerLevelRecord, errors: PackedStringArray) -> void:
	if entry == null or not is_node_ready():
		return
	var message := GameI18n.translate_errors(errors)
	_message.text = message
	_message.visible = not message.is_empty()
	if _rows.has(entry.source_path):
		var row: Button = _rows[entry.source_path].button
		row.tooltip_text = message
	if _rename_entry != null and _rename_entry.source_path == entry.source_path:
		_set_rename_error(message)


## 供系统返回焦点时的目录刷新保护查询是否有未提交输入。
func is_editing() -> bool:
	return is_instance_valid(_rename_input)


## 供外层刷新保护查询右键菜单，避免菜单引用在用户选择前失效。
func is_context_menu_open() -> bool:
	return is_instance_valid(_context_menu) and _context_menu.is_open()


## 使用原生纵向滚动、统一透明渐隐与低对比滚动条，表格无需整体缩小。
func _build_ui() -> void:
	_content_fade = SettingsContentFade.new()
	_content_fade.name = "PlayerLevelListContentFade"
	add_child(_content_fade)
	_surface = Control.new()
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.theme = SettingsContentFade.inherited_theme(self)
	_content_fade.add_child(_surface)
	_scroll = ScrollContainer.new()
	_scroll.name = "PlayerLevelListScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.follow_focus = true
	_surface.add_child(_scroll)
	# 独立滚动条避开搜索按钮；正文仍覆盖完整白卡以保留上下边缘淡出。
	_scrollbar = VScrollBar.new()
	_scrollbar.name = "PlayerLevelListScrollBar"
	_surface.add_child(_scrollbar)
	SettingsContentFade.style_scrollbar(_scrollbar)
	_scroll.get_v_scroll_bar().share(_scrollbar)
	_scrollbar.changed.connect(_sync_scrollbar_visibility)
	SettingsScrollFade.attach_bar(_scrollbar)
	_padding = MarginContainer.new()
	_padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_padding.add_theme_constant_override("margin_top", SettingsContentFade.CARD_CONTENT_TOP_PADDING)
	_padding.add_theme_constant_override("margin_bottom", 60)
	_padding.add_theme_constant_override("margin_right", 24)
	_scroll.add_child(_padding)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 14)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_padding.add_child(_column)
	_build_intro_card()
	_build_search()
	_table_inset = GameTheme.margin(_column, 0)
	_table_inset.name = "PlayerLevelTableInset"
	_table_column = VBoxContainer.new()
	_table_column.add_theme_constant_override("separation", 14)
	_table_inset.add_child(_table_column)
	_table_column.sort_children.connect(_layout_sticky_header, CONNECT_DEFERRED)
	_scroll.sort_children.connect(_layout_sticky_header, CONNECT_DEFERRED)
	_message = GameTheme.label(_table_column, "", 13)
	_message.name = "PlayerLevelListError"
	_message.add_theme_color_override("font_color", Color("cb2222"))
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.hide()
	_header_slot = Control.new()
	_header_slot.name = "PlayerLevelHeaderSlot"
	_header_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header_slot.resized.connect(_layout_sticky_header, CONNECT_DEFERRED)
	_table_column.add_child(_header_slot)
	# 表头只保留一个真实控件；原滚动位置留占位，浮动层承担吸顶后的显示与点击。
	_header_cover = ColorRect.new()
	_header_cover.name = "PlayerLevelHeaderCover"
	_header_cover.color = Color.WHITE
	_header_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_header_cover.gui_input.connect(_on_header_scroll_input)
	_header_cover.hide()
	_surface.add_child(_header_cover)
	_table_header = VBoxContainer.new()
	_table_header.name = "PlayerLevelStickyHeader"
	_table_header.add_theme_constant_override("separation", 14)
	_table_header.gui_input.connect(_on_header_scroll_input)
	_surface.add_child(_table_header)
	_header_columns = HBoxContainer.new()
	_header_columns.name = "PlayerLevelTableHeader"
	_header_columns.add_theme_constant_override("separation", 12)
	_header_columns.sort_children.connect(_layout_column_dividers, CONNECT_DEFERRED)
	var header_padding := GameTheme.margin(_table_header, 0)
	header_padding.add_theme_constant_override("margin_left", 14)
	header_padding.add_theme_constant_override("margin_right", 14)
	header_padding.add_child(_header_columns)
	for index in range(4):
		_build_sort_header(_header_columns, index)
	for index in range(3):
		var splitter := PlayerLevelColumnDivider.new()
		splitter.name = "PlayerLevelColumnDivider%d" % index
		splitter.drag_started.connect(_begin_column_resize.bind(index))
		splitter.drag_changed.connect(_resize_columns)
		splitter.drag_finished.connect(_finish_column_resize)
		splitter.gui_input.connect(_on_header_scroll_input)
		_surface.add_child(splitter)
		_column_dividers.append(splitter)
	_name_sort = _sort_buttons.name
	var divider := ColorRect.new()
	divider.color = Color(0.79, 0.82, 0.87, 0.55)
	divider.custom_minimum_size.y = 1
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_table_header.add_child(divider)
	_header_slot.custom_minimum_size.y = _table_header.get_combined_minimum_size().y
	_rows_container = VBoxContainer.new()
	_rows_container.name = "PlayerLevelRows"
	_rows_container.add_theme_constant_override("separation", 2)
	_table_column.add_child(_rows_container)
	_empty = GameTheme.label(_table_column, "", 16, true)
	_empty.name = "PlayerLevelListEmpty"
	_empty.custom_minimum_size.y = 96
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_context_menu = PlayerLevelListContextMenu.new()
	_context_menu.name = "PlayerLevelListContextMenu"
	add_child(_context_menu)
	_context_menu.rename_requested.connect(_begin_rename)
	_context_menu.delete_requested.connect(delete_requested.emit)
	_context_menu.edit_requested.connect(edit_requested.emit)
	_context_menu.open_folder_requested.connect(open_folder_requested.emit)
	_context_menu.migration_requested.connect(migration_requested.emit)


## 标题说明放在比表格略宽的浅灰圆角卡片中，长译文在卡片内部自然换行。
func _build_intro_card() -> void:
	var card := PanelContainer.new()
	card.name = "PlayerLevelListIntroCard"
	var style := GameTheme.box(Color("F1F3F6"), Color.TRANSPARENT, 16)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	card.add_theme_stylebox_override("panel", style)
	_column.add_child(card)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	card.add_child(content)
	GameTheme.label(content, "玩家关卡列表", 22)
	var subtitle := GameTheme.label(content, "管理已保存和导入的关卡，右键查看更多操作。", 14, true)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 表头按钮不以译文撑大列宽，文本和箭头独立布局并共用整列点击区域。
func _build_sort_header(parent: HBoxContainer, index: int) -> void:
	var button := Button.new()
	button.name = COLUMN_NAMES[index] + "SortButton"
	button.custom_minimum_size.y = 28
	button.tooltip_text = SORT_CAPTIONS[index]
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.pressed.connect(_sort_by.bind(SORT_COLUMNS[index]))
	button.gui_input.connect(_on_header_scroll_input)
	parent.add_child(button)
	_configure_cell(button, index)
	var caption := GameTheme.label(button, SORT_CAPTIONS[index], 14, true)
	caption.name = "SortCaption"
	caption.clip_text = true
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var chevron := PlayerLevelSortChevron.new()
	chevron.name = "SortChevron"
	button.add_child(chevron)
	_sort_buttons[SORT_COLUMNS[index]] = button
	_sort_chevrons[SORT_COLUMNS[index]] = chevron
	button.resized.connect(_layout_sort_header.bind(button))
	_layout_sort_header.call_deferred(button)


## 箭头紧随真实标题宽度，窄列只省略文字且保留箭头，不干扰正文列比例。
func _layout_sort_header(button: Button) -> void:
	var caption := button.get_node("SortCaption") as Label
	var chevron := button.get_node("SortChevron") as PlayerLevelSortChevron
	var text_width := caption.get_theme_font("font").get_string_size(tr(caption.text), HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var caption_width := minf(text_width, maxf(0.0, button.size.x - 20.0))
	caption.position = Vector2.ZERO
	caption.size = Vector2(caption_width, button.size.y)
	chevron.position = Vector2(caption_width + 6.0, (button.size.y - 14.0) * 0.5)
	chevron.size = Vector2.ONE * 14.0


## 刷新与筛选不重置动画目标，只有实际改变排序方向的箭头才开始翻转。
func _sync_sort_headers() -> void:
	for column: String in SORT_COLUMNS:
		var button: Button = _sort_buttons[column]
		var caption := button.get_node("SortCaption") as Label
		caption.add_theme_color_override("font_color", GameTheme.TEXT if column == _sort_column else GameTheme.MUTED)
		_sort_chevrons[column].set_state(column == _sort_column, _ascending)
		_layout_sort_header(button)


## 搜索复用选关页的圆形按钮、胶囊与收起图标，独立层避开固定导航整行的鼠标拦截。
func _build_search() -> void:
	_search_layer = CanvasLayer.new()
	_search_layer.name = "PlayerLevelSearchLayer"
	_search_layer.layer = 1
	add_child(_search_layer)
	# 在所有搜索表面绘制前只捕获一次，多个玻璃表面不会采样到彼此或上一帧的自身。
	var backdrop := BackBufferCopy.new()
	backdrop.name = "PlayerLevelSearchBackdropCopy"
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_search_layer.add_child(backdrop)
	_search_area = Control.new()
	_search_area.name = "PlayerLevelSearchArea"
	_search_area.theme = SettingsContentFade.inherited_theme(self)
	_search_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_layer.add_child(_search_area)
	_search_surface = Panel.new()
	_search_surface.name = "PlayerLevelSearchSurface"
	_search_surface.add_theme_stylebox_override("panel", _search_style(Color.TRANSPARENT))
	_search_surface.clip_contents = true
	_search_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_area.add_child(_search_surface)
	_search_glass = _build_search_glass(_search_surface, "PlayerLevelSearchGlass")
	_search_icon = TextureRect.new()
	_search_icon.texture = load("res://assets/ui/search.svg")
	_search_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_search_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_search_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_surface.add_child(_search_icon)
	_search_input = LineEdit.new()
	_search_input.name = "PlayerLevelSearchInput"
	_search_input.placeholder_text = "搜索名称或作者"
	_search_input.tooltip_text = "搜索名称或作者"
	_search_input.expand_to_text_length = false
	_search_input.caret_blink = true
	GameTheme.font_size(_search_input, "font_size", 14)
	_search_input.add_theme_color_override("font_placeholder_color", GameTheme.MUTED)
	for state in ["normal", "focus", "read_only"]:
		_search_input.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_search_input.text_changed.connect(_on_search_changed)
	_search_surface.add_child(_search_input)
	_search_close_surface = Panel.new()
	_search_close_surface.name = "PlayerLevelSearchCloseSurface"
	_search_close_surface.add_theme_stylebox_override("panel", _search_style(Color.TRANSPARENT))
	_search_close_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_area.add_child(_search_close_surface)
	_search_close_glass = _build_search_glass(_search_close_surface, "PlayerLevelSearchCloseGlass")
	_search_button = _search_icon_button("PlayerLevelSearchButton", "res://assets/ui/search.svg", "搜索名称或作者", set_search_open.bind(true))
	_search_close_button = _search_icon_button("PlayerLevelSearchCloseButton", "res://assets/ui/search_collapse.svg", "收起搜索", set_search_open.bind(false))
	_search_input.editable = false
	_search_input.context_menu_enabled = false
	_layout_search()


## 毛玻璃独立位于文字与按钮下方，浅灰蓝色调保留搜索区域的辨识度。
func _build_search_glass(parent: Control, node_name: String) -> ColorRect:
	var glass := ColorRect.new()
	glass.name = node_name
	glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/ui/menu_glass.gdshader")
	material.set_shader_parameter("frost_tint", Vector3(SEARCH_BACKGROUND.r, SEARCH_BACKGROUND.g, SEARCH_BACKGROUND.b))
	material.set_shader_parameter("frost_mix", 0.72)
	material.set_shader_parameter("corner_radius", SEARCH_HEIGHT * 0.5)
	glass.material = material
	parent.add_child(glass)
	return glass


## 玻璃圆角由实际动画尺寸计算，极窄窗口和快速收起也不留下矩形边缘。
func _layout_search_glass(glass: ColorRect, dimensions: Vector2) -> void:
	glass.position = Vector2.ZERO
	glass.size = dimensions
	var layout_scale := absf(_search_area.scale.x)
	var material := glass.material as ShaderMaterial
	material.set_shader_parameter("panel_size", dimensions * layout_scale)
	material.set_shader_parameter("corner_radius", minf(dimensions.x, dimensions.y) * 0.5 * layout_scale)


## 圆形按钮保持44像素命中区与选关页同一SVG，不以文字字符替代搜索图标。
func _search_icon_button(node_name: String, icon_path: String, tooltip: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load(icon_path)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2.ONE * SEARCH_HEIGHT
	button.add_theme_stylebox_override("normal", _search_style(Color.TRANSPARENT))
	button.add_theme_stylebox_override("hover", _search_style(Color(0.80, 0.85, 0.92, 0.24)))
	button.add_theme_stylebox_override("pressed", _search_style(Color(0.73, 0.81, 0.91, 0.38)))
	button.add_theme_stylebox_override("focus", _search_style(Color.TRANSPARENT))
	button.pressed.connect(action)
	_search_area.add_child(button)
	GameTheme.toolbar_highlight.call_deferred(button)
	return button


## 胶囊与圆钮使用同一半径和零内容边距，展开过程不出现叠加底面。
func _search_style(color: Color) -> StyleBoxFlat:
	var style := GameTheme.box(color, Color.TRANSPARENT, 22)
	style.set_content_margin_all(0)
	return style


## 展开后立即聚焦并保留查询；收起会清空筛选，反向操作先终止旧动画。
func set_search_open(open: bool, animate: bool = true) -> void:
	if not is_node_ready():
		return
	_context_menu.close_menu(false)
	_cancel_rename()
	_stop_search_tween()
	_search_open = open
	_search_input.editable = open
	_search_input.context_menu_enabled = open
	if not open:
		_search_input.release_focus()
		if not _search_input.text.is_empty():
			_search_input.clear()
			_on_search_changed("")
	_layout_search()
	if open:
		_search_input.grab_focus()
	var target := 1.0 if open else 0.0
	if not animate or is_equal_approx(_search_progress, target):
		_set_search_progress(target)
		_finish_search_motion()
		return
	_search_tween = create_tween()
	_search_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT if open else Tween.EASE_IN_OUT)
	_search_tween.tween_method(_set_search_progress, _search_progress, target, 0.32 if open else 0.24)
	_search_tween.tween_callback(_finish_search_motion)


## 右端以白卡真实圆角圆心为锚点向左展开，窗口变化期间仍保持同心与导航间隔。
func _layout_search() -> void:
	if not is_instance_valid(_search_button):
		return
	var bounds := card_boundary.get_global_rect() if is_instance_valid(card_boundary) else get_global_rect()
	var radius := 32.0
	if card_boundary is Panel:
		var surface := card_boundary.get_theme_stylebox("panel") as StyleBoxFlat
		if surface != null:
			radius = surface.corner_radius_top_right
	# 独立 CanvasLayer 不继承白卡变换；只在搜索根控件补入一次比例，定位仍使用视口坐标。
	var layout_scale := maxf(0.001, absf(get_global_transform().get_scale().x))
	_search_area.scale = Vector2.ONE * layout_scale
	var right := bounds.end.x - (radius - SEARCH_HEIGHT * 0.5) * layout_scale
	var safe_left := bounds.position.x + 24.0 * layout_scale
	if is_instance_valid(navigation_title):
		safe_left = (navigation_title.get_global_transform() * Vector2(navigation_title.get_combined_minimum_size().x, 0)).x + 16.0 * layout_scale
	var expanded_width := maxf(SEARCH_HEIGHT, minf(SEARCH_MAX_WIDTH, (right - safe_left) / layout_scale))
	var width := lerpf(SEARCH_HEIGHT, expanded_width, _search_progress)
	_search_area.position = Vector2(right - width * layout_scale, bounds.position.y + (radius - SEARCH_HEIGHT * 0.5) * layout_scale)
	_search_area.size = Vector2(width, SEARCH_HEIGHT)
	var surface_left := 52.0 * _search_progress
	_search_surface.position = Vector2(surface_left, 0)
	_search_surface.size = Vector2(maxf(0.0, width - surface_left), SEARCH_HEIGHT)
	_layout_search_glass(_search_glass, _search_surface.size)
	_search_icon.position = Vector2(10, 10)
	_search_icon.size = Vector2(24, 24)
	_search_icon.visible = _search_open or _search_progress > 0.0
	_search_input.position = Vector2(40, 0)
	_search_input.size = Vector2(maxf(0.0, _search_surface.size.x - 54.0), SEARCH_HEIGHT)
	_search_input.visible = _search_open or _search_progress > 0.0
	_search_input.modulate.a = _search_progress
	_search_input.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE
	_search_button.position = Vector2(width - SEARCH_HEIGHT, 0)
	_search_button.size = Vector2.ONE * SEARCH_HEIGHT
	_search_button.visible = not _search_open and _search_progress <= 0.0
	_search_close_button.position = Vector2.ZERO
	_search_close_button.size = Vector2.ONE * SEARCH_HEIGHT
	_search_close_button.visible = _search_open or _search_progress > 0.0
	_search_close_button.modulate.a = clampf((_search_progress - 0.35) / 0.65, 0.0, 1.0)
	_search_close_button.mouse_filter = Control.MOUSE_FILTER_STOP if _search_open else Control.MOUSE_FILTER_IGNORE
	_search_close_surface.position = Vector2.ZERO
	_search_close_surface.size = Vector2.ONE * SEARCH_HEIGHT
	_search_close_surface.visible = _search_close_button.visible
	_search_close_surface.modulate.a = _search_close_button.modulate.a
	_layout_search_glass(_search_close_glass, _search_close_surface.size)


## 动画只驱动进度，尺寸和窗口变化始终由同一布局入口计算。
func _set_search_progress(progress: float) -> void:
	_search_progress = clampf(progress, 0.0, 1.0)
	_layout_search()


## 停止旧动画，防止快速展开和收起同时修改宽度。
func _stop_search_tween() -> void:
	if _search_tween != null and _search_tween.is_valid():
		_search_tween.kill()
	_search_tween = null


## 收起结束仅把焦点交还搜索按钮，弹出菜单已经获得的焦点不被抢走。
func _finish_search_motion() -> void:
	_search_tween = null
	if not _search_open and is_visible_in_tree() and not is_context_menu_open():
		_search_button.grab_focus()


## 表头与每一行采用相同列比例，长文本只省略自身，不撑宽表格。
func _configure_cell(control: Control, index: int) -> void:
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.custom_minimum_size.x = MIN_COLUMN_WIDTH
	control.size_flags_stretch_ratio = _column_weights[index]
	if control is Label:
		control.clip_text = true
		control.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE


## 搜索同时匹配名称和作者，排序只作用于显示，不改变模型或磁盘顺序。
func _rebuild_rows() -> void:
	_cancel_rename()
	_context_menu.close_menu(false)
	var previous_scroll := _scroll.scroll_vertical
	for child in _rows_container.get_children():
		_rows_container.remove_child(child)
		child.queue_free()
	_rows.clear()
	var shown: Array[PlayerLevelRecord] = []
	var query := _search_input.text.strip_edges().to_lower()
	for entry in _entries:
		if query.is_empty() or entry.display_name.to_lower().contains(query) or entry.creator.to_lower().contains(query):
			shown.append(entry)
	shown.sort_custom(_comes_before)
	for entry in shown:
		_add_row(entry)
	_sync_sort_headers()
	_empty.text = tr("尚无玩家关卡") if _entries.is_empty() else tr("没有匹配的关卡")
	_empty.visible = shown.is_empty()
	_scroll.set_deferred("scroll_vertical", previous_scroll)
	_layout_content.call_deferred()


## 主列按指定方向排序，空作者和未知日期始终末尾，同值以名称及路径升序稳定排列。
func _comes_before(first: PlayerLevelRecord, second: PlayerLevelRecord) -> bool:
	var compared := 0
	match _sort_column:
		"creator":
			var first_empty := first.creator.strip_edges().is_empty()
			var second_empty := second.creator.strip_edges().is_empty()
			if first_empty != second_empty:
				return not first_empty
			if not first_empty:
				compared = first.creator.naturalnocasecmp_to(second.creator)
		"created_at":
			if (first.created_at <= 0) != (second.created_at <= 0):
				return first.created_at > 0
			if first.created_at > 0 and second.created_at > 0:
				compared = -1 if first.created_at < second.created_at else 1 if first.created_at > second.created_at else 0
		"status":
			compared = _status_rank(first) - _status_rank(second)
		_:
			compared = first.display_name.naturalnocasecmp_to(second.display_name)
	if compared != 0:
		return compared < 0 if _ascending else compared > 0
	compared = first.display_name.naturalnocasecmp_to(second.display_name)
	if compared == 0:
		compared = first.source_path.naturalnocasecmp_to(second.source_path)
	if compared == 0:
		compared = first.source_path.casecmp_to(second.source_path)
	return compared < 0


## 状态排序沿用显示诊断的优先级，旧目录条目独立排在内容诊断之后。
func _status_rank(entry: PlayerLevelRecord) -> int:
	if entry.needs_migration:
		return 4
	if entry.is_corrupt:
		return 3
	if entry.requires_newer_version:
		return 2
	return 1 if not entry.errors.is_empty() else 0


## 整行可选中和右键，用户名称与署名始终原样显示，不经过翻译。
func _add_row(entry: PlayerLevelRecord) -> void:
	var button := Button.new()
	button.name = "PlayerLevelRow"
	button.set_meta("source_path", entry.source_path)
	button.custom_minimum_size.y = 44
	button.clip_contents = false
	button.pressed.connect(_select_row.bind(entry.source_path))
	button.gui_input.connect(_on_row_input.bind(entry, button))
	_rows_container.add_child(button)
	var cells := HBoxContainer.new()
	cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cells.add_theme_constant_override("separation", 12)
	button.add_child(cells)
	cells.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cells.offset_left = 14
	cells.offset_right = -14
	var captions := [entry.display_name, entry.creator if not entry.creator.is_empty() else tr("未署名"), _created_date(entry.created_at), _entry_status(entry)]
	var labels: Array[Label] = []
	for index in range(4):
		var label := GameTheme.label(cells, captions[index], 15 if index == 0 else 14, index in [1, 2])
		label.name = COLUMN_NAMES[index]
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.tooltip_text = captions[index]
		_configure_cell(label, index)
		labels.append(label)
	var issue := entry.needs_migration or entry.is_corrupt or entry.requires_newer_version or not entry.errors.is_empty()
	labels[3].add_theme_color_override("font_color", Color("ff2c2c") if entry.needs_migration else Color("e62020") if entry.is_corrupt or entry.requires_newer_version else Color("cb2222") if issue else GameTheme.TEXT)
	var explanation := GameI18n.translate_errors(entry.errors)
	# 子标签忽略鼠标以保留整行右键；真正接收悬停的按钮承载完整状态与诊断。
	button.tooltip_text = captions[3] + ("\n" + explanation if not explanation.is_empty() else "") if issue else entry.display_name + "\n" + captions[1] + "\n" + entry.source_path.get_file()
	_rows[entry.source_path] = {"button": button, "entry": entry, "name": labels[0], "status": labels[3]}
	_style_row(button, entry.source_path == _selected_path)


## 旧目录优先显示迁移状态，当前目录再区分内容诊断；完整诊断保留在行提示。
func _entry_status(entry: PlayerLevelRecord) -> String:
	if entry.needs_migration:
		return tr("目录错误")
	if entry.is_corrupt:
		return tr("文件损坏")
	if entry.requires_newer_version:
		return tr("此关卡可能由更新的版本创建")
	if not entry.errors.is_empty():
		return tr("异常：%s") % GameI18n.translate_errors(PackedStringArray([entry.errors[0]])).get_slice("\n", 0)
	return tr("状态正常")


## 创建日期使用当前系统时区显示年月日，未知时间不伪造为导入日期。
func _created_date(timestamp: int) -> String:
	if timestamp <= 0:
		return tr("未知")
	var offset := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(timestamp + offset).left(10)


## 选中行用低对比灰蓝色，鼠标焦点不遗留额外蓝色边框。
func _style_row(button: Button, selected: bool) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color("E8EFF8") if selected else Color.TRANSPARENT
		if state in ["hover", "pressed", "hover_pressed"]:
			fill = Color("E8EDF3")
		var border := Color("A7CDFF") if state == "focus" and _keyboard_focus else Color.TRANSPARENT
		var style := GameTheme.box(fill, border, 9)
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)


## 单击只选择条目，文件管理操作通过右键菜单或相应键盘入口发起。
func _select_row(path: String) -> void:
	_selected_path = path
	for row_path: String in _rows:
		_style_row(_rows[row_path].button, row_path == path)


## 右键与菜单键打开同一菜单，F2 可为支持修改的当前行进入原位重命名。
func _on_row_input(event: InputEvent, entry: PlayerLevelRecord, button: Button) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_cancel_rename()
		_select_row(entry.source_path)
		_context_menu.popup_at(button, button.get_global_mouse_position(), entry)
		button.accept_event()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_MENU or (event.keycode == KEY_F10 and event.shift_pressed):
			_context_menu.popup_at(button, button.get_global_rect().get_center(), entry)
			button.accept_event()
		elif event.keycode == KEY_F2 and entry.can_rename and not entry.needs_migration:
			_begin_rename(entry)
			button.accept_event()


## 改变查询立即筛选，搜索框保留焦点与原文，清空后恢复全部条目。
func _on_search_changed(_value: String) -> void:
	_message.hide()
	_rebuild_rows()


## 保留名称排序入口以兼容已有调用，四个表头统一使用相同切换规则。
func _toggle_sort() -> void:
	_sort_by("name")


## 新列从升序开始，重复点击当前列则翻转；刷新只重建显示行而不修改记录顺序。
func _sort_by(column: String) -> void:
	if not SORT_COLUMNS.has(column):
		return
	_ascending = not _ascending if _sort_column == column else true
	_sort_column = column
	_rebuild_rows()


## 名称单元格内覆盖无外框输入，保留原文字占位与用户选区，避免重排整行。
func _begin_rename(entry: PlayerLevelRecord) -> void:
	_cancel_rename()
	if entry == null or entry.needs_migration or not entry.can_rename or not _rows.has(entry.source_path):
		return
	_select_row(entry.source_path)
	_message.hide()
	_rename_entry = entry
	_rename_label = _rows[entry.source_path].name
	_rename_input = LineEdit.new()
	_rename_input.name = "PlayerLevelListNameInput"
	_rename_input.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_rename_input.text = entry.display_name
	_rename_input.expand_to_text_length = false
	_rename_input.caret_blink = true
	_rename_input.keep_editing_on_text_submit = true
	GameTheme.font_size(_rename_input, "font_size", 15)
	_rename_input.text_changed.connect(_on_rename_changed)
	_rename_input.text_submitted.connect(_submit_rename)
	_rename_input.focus_exited.connect(_on_rename_focus_exited.bind(_rename_input))
	# 名称标签会裁剪文本，输入必须作为整行的子节点，避免上下边框及光标被标签高度截断。
	_rows[entry.source_path].button.add_child(_rename_input)
	_rename_label.item_rect_changed.connect(_layout_rename_input)
	_rename_label.self_modulate.a = 0
	_set_rename_error("")
	_layout_rename_input()
	_rename_input.grab_focus()
	_rename_input.select_all()
	_reveal_focus.call_deferred(_rename_input)


## 输入沿原名称列定位并在行内垂直居中，窗口或滚动布局改变时仍保留完整边框。
func _layout_rename_input() -> void:
	if not is_instance_valid(_rename_input) or not is_instance_valid(_rename_label):
		return
	var row := _rename_input.get_parent() as Control
	var name_rect := row.get_global_transform().affine_inverse() * _rename_label.get_global_rect()
	var height := maxf(36.0, _rename_input.get_combined_minimum_size().y)
	_rename_input.position = Vector2(name_rect.position.x, (row.size.y - height) * 0.5)
	_rename_input.size = Vector2(name_rect.size.x, height)


## 只验证新输入，不截断粘贴内容；旧长名称可以完整选中并修改为合法名称。
func _on_rename_changed(value: String) -> void:
	var checked := LevelCatalog.validate_player_level_name(value)
	_set_rename_error("" if checked.is_ok() else GameI18n.translate_errors(checked.errors))
	_message.hide()


## 合法名称保持透明无框，错误仅增加细红边与完整说明，不自动提交或丢弃输入。
func _set_rename_error(message: String) -> void:
	if not is_instance_valid(_rename_input):
		return
	var style := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT if message.is_empty() else Color("cb2222"), 4)
	style.content_margin_left = 2
	style.content_margin_right = 2
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	_rename_input.add_theme_stylebox_override("normal", style)
	_rename_input.add_theme_stylebox_override("focus", style)
	_rename_input.tooltip_text = tr("Enter 确认，Esc 取消") if message.is_empty() else message


## 原生文本提交信号只在输入法确认后触发，校验失败时留在当前名称单元格。
func _submit_rename(value: String) -> void:
	if _rename_entry == null or not is_instance_valid(_rename_input):
		return
	var checked := LevelCatalog.validate_player_level_name(value)
	if not checked.is_ok():
		show_entry_error(_rename_entry, checked.errors)
		return
	rename_requested.emit(_rename_entry, value)


## 放弃重命名只还原视觉状态，不能把未确认的文字写入记录。
func _cancel_rename() -> void:
	if _rename_entry != null and is_instance_valid(_message):
		_message.hide()
	if is_instance_valid(_rename_label):
		if _rename_label.item_rect_changed.is_connected(_layout_rename_input):
			_rename_label.item_rect_changed.disconnect(_layout_rename_input)
		_rename_label.self_modulate.a = 1
	if is_instance_valid(_rename_input):
		_rename_input.get_parent().remove_child(_rename_input)
		_rename_input.queue_free()
	_rename_input = null
	_rename_label = null
	_rename_entry = null


## 等当前原生输入事件完成后再判断失焦，避免文本菜单展开的一帧被提前取消。
func _on_rename_focus_exited(input: LineEdit) -> void:
	_cancel_unfocused_rename.call_deferred(input)


## 文本右键菜单和输入法不会当作离开编辑，真正失焦才取消未确认名称。
func _cancel_unfocused_rename(input: LineEdit) -> void:
	if is_instance_valid(input) and input == _rename_input and not input.has_focus() and not input.get_menu().visible:
		_cancel_rename()


## 鼠标空白处取消编辑并释放输入焦点；键盘焦点只在主动键盘导航时显示。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or is_context_menu_open():
		return
	var previous_keyboard_focus := _keyboard_focus
	if event is InputEventMouseButton and event.pressed:
		_keyboard_focus = false
		if is_editing() and not _rename_input.get_menu().visible and not _rename_input.get_global_rect().has_point(event.position):
			_cancel_rename()
		if _search_input.has_focus() and not _search_input.get_global_rect().has_point(event.position):
			_search_input.release_focus()
	elif event is InputEventKey and event.pressed:
		_keyboard_focus = true
		if is_editing() and event.is_action_pressed("ui_cancel") and not _rename_input.has_ime_text() and not _rename_input.get_menu().visible:
			get_viewport().set_input_as_handled()
			var path := _rename_entry.source_path
			_cancel_rename()
			if _rows.has(path):
				_rows[path].button.grab_focus()
		elif _search_open and event.is_action_pressed("ui_cancel") and not _search_input.has_ime_text() and not _search_input.get_menu().visible:
			get_viewport().set_input_as_handled()
			set_search_open(false)
	if previous_keyboard_focus == _keyboard_focus:
		return
	for path: String in _rows:
		_style_row(_rows[path].button, path == _selected_path)


## 表格可视区域贴白卡上下边缘，横向只在正文可能覆盖导航文字时向右让出空间。
func _layout_content() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_surface) or size.x <= 0 or size.y <= 0:
		return
	if _column_resize_index >= 0:
		for splitter in _column_dividers:
			splitter.cancel_drag()
	var bounds := get_global_transform().affine_inverse() * card_boundary.get_global_rect() if is_instance_valid(card_boundary) else Rect2(Vector2.ZERO, size)
	_surface.position = bounds.position
	_surface.size = bounds.size
	var width := minf(860.0, maxf(0.0, bounds.size.x - 88.0))
	var left := (bounds.size.x - width) * 0.5
	if is_instance_valid(navigation_title) and navigation_title.is_visible_in_tree():
		var title_right := navigation_title.get_global_transform() * Vector2(navigation_title.get_combined_minimum_size().x, 0)
		var safe_left := (_surface.get_global_transform().affine_inverse() * title_right).x + 16
		left = maxf(left, safe_left)
		width = minf(width, maxf(0.0, bounds.size.x - left - 56))
	_scroll.position = Vector2(left, 0)
	_scroll.size = Vector2(width + 24, bounds.size.y)
	var scrollbar_width := _scrollbar.get_combined_minimum_size().x
	var scrollbar_top := minf(float(_padding.get_theme_constant("margin_top")), maxf(0.0, bounds.size.y - _scrollbar.get_combined_minimum_size().y))
	_scrollbar.position = Vector2(_scroll.position.x + _scroll.size.x - scrollbar_width, scrollbar_top)
	_scrollbar.size = Vector2(scrollbar_width, bounds.size.y - scrollbar_top)
	# 隐藏内部条后补回它原本的占位，表格宽度和状态列位置不变。
	_padding.add_theme_constant_override("margin_right", 24 + ceili(scrollbar_width))
	_sync_scrollbar_visibility()
	var table_margin := roundi(clampf(width * 0.03, 12.0, 26.0))
	_table_inset.add_theme_constant_override("margin_left", table_margin)
	_table_inset.add_theme_constant_override("margin_right", table_margin)
	_layout_search()
	var visible_rect := _scroll.get_global_rect()
	var layout_scale := absf(get_global_transform().get_scale().y)
	_content_fade.set_fade(visible_rect.position.y, SettingsContentFade.TOP_FADE_WIDTH * layout_scale, get_viewport().get_visible_rect().size.y, visible_rect.end.y)
	if is_context_menu_open():
		_context_menu._update_placement()
	_layout_sticky_header.call_deferred()


## 表头随说明卡滚动，抵达导航下方后固定；白色遮挡区隔开继续滚动的行与排序按钮。
func _layout_sticky_header() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_header_slot):
		return
	var natural := _surface.get_global_transform().affine_inverse() * _header_slot.get_global_rect()
	var height := _table_header.get_combined_minimum_size().y
	_header_slot.custom_minimum_size.y = height
	var top := float(_padding.get_theme_constant("margin_top"))
	_table_header.position = Vector2(natural.position.x, maxf(natural.position.y, top))
	_table_header.size = Vector2(natural.size.x, height)
	_header_cover.position = Vector2(_scroll.position.x, 0.0)
	_header_cover.size = Vector2(_column.size.x, top + height)
	_header_cover.visible = natural.position.y <= top
	_layout_column_dividers()


## 三个拖动命中区始终跟随真实表头列间留白，吸顶与窗口缩放后仍能准确点击。
func _layout_column_dividers() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_header_columns):
		return
	for index in range(_column_dividers.size()):
		var button: Button = _sort_buttons[SORT_COLUMNS[index]]
		var rect := _surface.get_global_transform().affine_inverse() * button.get_global_rect()
		var gap := float(_header_columns.get_theme_constant("separation"))
		_column_dividers[index].position = Vector2(rect.end.x + (gap - COLUMN_DIVIDER_WIDTH) * 0.5, rect.position.y)
		_column_dividers[index].size = Vector2(COLUMN_DIVIDER_WIDTH, rect.size.y)


## 以当前实际宽度作为拖动起点，窄窗口的最小列宽和像素舍入不会造成初次拖动跳动。
func _begin_column_resize(index: int) -> void:
	_column_resize_index = index
	_column_resize_total = 0.0
	for column in range(4):
		_column_weights[column] = _sort_buttons[SORT_COLUMNS[column]].size.x
		_column_resize_total += _column_weights[column]
	_column_resize_pair = _column_weights[index] + _column_weights[index + 1]
	_column_resize_left = _column_weights[index]
	for column in range(4):
		_column_weights[column] /= maxf(1.0, _column_resize_total)


## 只在相邻两列之间分配宽度，其他列保持比例；每行和表头同步更新而不重建记录或改变排序。
func _resize_columns(delta_x: float) -> void:
	if _column_resize_index < 0:
		return
	var scale_x := maxf(0.001, absf(_table_header.get_global_transform().get_scale().x))
	var left := clampf(_column_resize_left + delta_x / scale_x, MIN_COLUMN_WIDTH, _column_resize_pair - MIN_COLUMN_WIDTH)
	_column_weights[_column_resize_index] = left / maxf(1.0, _column_resize_total)
	_column_weights[_column_resize_index + 1] = (_column_resize_pair - left) / maxf(1.0, _column_resize_total)
	for column in range(4):
		_sort_buttons[SORT_COLUMNS[column]].size_flags_stretch_ratio = _column_weights[column]
	for path: String in _rows:
		var row: Button = _rows[path].button
		for column in range(4):
			var cell := row.find_child(COLUMN_NAMES[column], true, false) as Label
			cell.size_flags_stretch_ratio = _column_weights[column]


## 松开后只结束临时手势，当前列比例继续用于排序、筛选、刷新与窗口缩放。
func _finish_column_resize() -> void:
	_column_resize_index = -1


## 浮动表头接收到的滚轮继续驱动同一原生范围，点击排序和隐藏行的鼠标命中互不穿透。
func _on_header_scroll_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	var direction := 0
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		direction = 1
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		direction = -1
	if direction != 0:
		_scrollbar.value += direction * maxf(1.0, _scrollbar.page / 8.0) * event.factor
		get_viewport().set_input_as_handled()


## 范围由原生滚动容器计算，外条只共享范围并在内容溢出时显示。
func _sync_scrollbar_visibility() -> void:
	_scrollbar.visible = _scrollbar.max_value - _scrollbar.page > _scrollbar.min_value


## 键盘移入行或名称输入框后，确保控件不会停在导航与上下渐隐区域。
func _on_focus_changed(control: Control) -> void:
	if _keyboard_focus and is_instance_valid(control) and _column.is_ancestor_of(control):
		_reveal_focus.call_deferred(control)


## 原生滚动跟随完成后补足清晰区留白，鼠标打开重命名也能看见完整输入行。
func _reveal_focus(control: Control) -> void:
	if not is_instance_valid(control) or not control.has_focus() or not is_visible_in_tree():
		return
	var visible_rect := _scroll.get_global_rect()
	var target := control.get_global_rect()
	var layout_scale := absf(get_global_transform().get_scale().y)
	var top := maxf(visible_rect.position.y + SettingsContentFade.CARD_FOCUS_TOP_INSET * layout_scale, _table_header.get_global_rect().end.y + 8.0 * layout_scale)
	var bottom := visible_rect.end.y - (SettingsContentFade.TOP_FADE_WIDTH + 8) * layout_scale
	var scroll_scale := maxf(0.001, absf(_scroll.get_global_transform().get_scale().y))
	if target.position.y < top:
		_scroll.scroll_vertical -= ceili((top - target.position.y) / scroll_scale)
	elif target.end.y > bottom:
		_scroll.scroll_vertical += ceili((target.end.y - bottom) / scroll_scale)


## 翻译只重建显示文案；隐藏时关闭独立浮层，防止菜单留在下一页面。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_layout_content.call_deferred()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_rebuild_rows.call_deferred()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready() and not is_visible_in_tree():
		_context_menu.close_menu(false)
		_cancel_rename()
		_stop_search_tween()
		_search_layer.hide()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready() and is_visible_in_tree():
		_search_layer.show()
		_set_search_progress(1.0 if _search_open else 0.0)
