class_name CommandReferenceMenu
extends CanvasLayer
## 宽幅指令资料窗口只读模块目录和 JSON；浏览、搜索与关闭都不修改玩家程序或装配。

const LOCKED_TEXT := Color("939DAC")

var catalog_directory: String = "res://data/commands"
var catalog := CommandCatalog.new()
var header: CommandReferenceHeader
var _overlay: Control
var _panel: Panel
var _glass: ColorRect
var _sidebar: Panel
var _directory_scroll: ScrollContainer
var _directory_list: VBoxContainer
var _scroll: ScrollContainer
var _list: VBoxContainer
var _content_title: Label
var _content_count: Label
var _empty_label: Label
var _error_label: Label
var _section_buttons: Array[Button] = []
var _sections: Array[Dictionary] = []
var _selected_section_key := ""
var _displayed_entries: Array[Dictionary] = []
var _cards: Array[PanelContainer] = []
var _command_buttons: Array[Button] = []
var _details: Array[Label] = []
var _syntax: Array[Label] = []
var _anchor: Control
var _level: LevelDefinition
var _registry: ContentRegistry
var _open := false
var _tween: Tween


## 左目录与右资料各自滚动，导航和搜索固定在资料列顶部，不挤占装配界面的布局。
func _ready() -> void:
	layer = 50
	_overlay = Control.new()
	_overlay.name = "CommandReferenceOverlay"
	_overlay.theme = GameTheme.create_theme()
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.hide()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_overlay.add_child(backdrop)
	_panel = Panel.new()
	_panel.name = "CommandReferencePanel"
	var surface := GameTheme.box(Color(0.995, 0.997, 1, 0.97), Color(1, 1, 1, 0.94), 28)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.12, 0.16, 0.23, 0.15)
	surface.shadow_size = 14
	surface.shadow_offset = Vector2(0, 5)
	_panel.add_theme_stylebox_override("panel", surface)
	_overlay.add_child(_panel)
	_glass = ColorRect.new()
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 宽幅阅读窗口降低背景透出，保留柔和玻璃感，避免原页面文字干扰说明。
	_glass.modulate.a = 0.15
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/menu_glass.gdshader")
	_glass.material = glass_material
	_panel.add_child(_glass)
	_build_directory()
	header = CommandReferenceHeader.new()
	header.name = "CommandReferenceHeader"
	header.close_requested.connect(close_menu)
	header.query_changed.connect(_on_query_changed)
	_panel.add_child(header)
	_scroll = ScrollContainer.new()
	_scroll.name = "CommandReferenceScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	_scroll.focus_mode = Control.FOCUS_ALL
	_panel.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 16)
	_scroll.add_child(_list)
	get_viewport().size_changed.connect(_update_placement)
	set_process_input(false)


## 灰色目录面只显示分组入口，模块贴图和名称直接来自当前游戏内容注册表。
func _build_directory() -> void:
	_sidebar = Panel.new()
	_sidebar.name = "CommandDirectoryPanel"
	_sidebar.add_theme_stylebox_override("panel", GameTheme.box(Color(0.94, 0.945, 0.955, 0.96), Color.TRANSPARENT, 22))
	_panel.add_child(_sidebar)
	var title := GameTheme.label(_sidebar, "目录", 15, true)
	title.position = Vector2(16, 14)
	_directory_scroll = ScrollContainer.new()
	_directory_scroll.name = "CommandDirectoryScroll"
	_directory_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_directory_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_directory_scroll.follow_focus = true
	_sidebar.add_child(_directory_scroll)
	_directory_list = VBoxContainer.new()
	_directory_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_directory_list.add_theme_constant_override("separation", 8)
	_directory_scroll.add_child(_directory_list)


## 每次打开重新扫描 JSON 和模块目录，重新进入时保留上次选择但清空搜索条件。
func popup_at(anchor: Control, level: LevelDefinition, registry: ContentRegistry, back_caption: String = "返回装配") -> void:
	if _open:
		close_menu()
		return
	if not is_instance_valid(anchor) or not anchor.is_visible_in_tree():
		return
	_anchor = anchor
	_level = level
	_registry = registry
	catalog.load_directory(catalog_directory)
	_open = true
	_overlay.show()
	header.set_back_caption(back_caption)
	header.set_active(true)
	header.set_search_open(false, false)
	_rebuild_directory()
	_rebuild_content()
	_update_placement()
	set_process_input(true)
	_panel.pivot_offset = Vector2(_panel.size.x, 0)
	_panel.scale = Vector2(0.99, 0.975)
	_panel.modulate.a = 0
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_panel, "scale", Vector2.ONE, 0.18)
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.14)
	header.back_button.grab_focus()


## 关闭浮层并终止搜索动画，离开装配页面时不聚焦即将被释放的书本入口。
func close_menu(restore_focus: bool = true) -> void:
	if not _open:
		return
	_open = false
	set_process_input(false)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	header.set_active(false)
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 公开窗口状态，外层页面切换仍沿用已有的关闭流程。
func is_open() -> bool:
	return _open


## 语言切换后按当前译文重建目录和搜索结果，输入内容与所选模块保持不变。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _open:
		_rebuild_directory()
		_rebuild_content()
		_update_placement.call_deferred()


## 目录同时包含通用语法与全部模块；使用种类和 ID 组合，允许作者的模块也叫 general。
func _rebuild_directory() -> void:
	_clear_children(_directory_list)
	_section_buttons.clear()
	_sections = catalog.sections(_registry, TranslationServer.get_locale())
	for section in _sections:
		section.entries = _listed_entries(section.entries)
	var selected_exists := false
	for section in _sections:
		if _section_key(section) == _selected_section_key:
			selected_exists = true
	if not selected_exists:
		_selected_section_key = "general:general"
		if _level != null:
			for module_id in _level.allowed_modules:
				for section in _sections:
					if section.kind == "module" and section.id == module_id:
						_selected_section_key = _section_key(section)
						break
				if _selected_section_key != "general:general":
					break
	for section in _sections:
		var item := Button.new()
		item.name = "CommandSection_" + str(section.id).validate_node_name()
		item.set_meta("section_id", section.id)
		item.set_meta("section_kind", section.kind)
		item.text = str(section.title).replace("\n", " ").replace("\r", " ")
		item.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		item.tooltip_text = section.title
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		item.expand_icon = true
		item.add_theme_constant_override("icon_max_width", 28)
		item.add_theme_constant_override("h_separation", 10)
		item.add_theme_font_size_override("font_size", 15)
		item.custom_minimum_size.y = 50
		item.toggle_mode = true
		item.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		item.icon = load("res://assets/ui/reference_general.svg")
		if not str(section.texture).is_empty():
			var texture_result := ContentTextureLoader.load_texture(section.texture)
			if texture_result.is_ok():
				item.icon = texture_result.value
		_style_section(item)
		item.pressed.connect(select_section.bind(str(section.id), str(section.kind)))
		_directory_list.add_child(item)
		_section_buttons.append(item)
	_update_selection()


## 目录按钮显示柔和选中底色，高对比模块图标保持原色，未解锁分组仍然可以打开。
func _style_section(item: Button) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var color := Color("DCE8F8") if state in ["pressed", "hover_pressed"] else Color(1, 1, 1, 0.72) if state == "hover" else Color.TRANSPARENT
		var style := GameTheme.box(color, Color("B4CEF0") if state == "focus" else Color.TRANSPARENT, 13)
		style.set_content_margin_all(10)
		item.add_theme_stylebox_override(state, style)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
		item.add_theme_color_override(state, Color.WHITE)


## 点击模块列出默认折叠的指令；清空全局搜索时仍保留搜索框，方便继续查找。
func select_section(section_id: String, kind: String = "module") -> void:
	var requested := kind + ":" + section_id
	for section in _sections:
		if _section_key(section) == requested:
			_selected_section_key = requested
			if not header.get_query().is_empty():
				header.search_input.clear()
			_update_selection()
			_rebuild_content()
			return


## 搜索有内容时不把任何模块标为唯一结果来源，清空后恢复之前的目录选中状态。
func _update_selection() -> void:
	for item in _section_buttons:
		var key := str(item.get_meta("section_kind")) + ":" + str(item.get_meta("section_id"))
		item.set_pressed_no_signal(header.get_query().strip_edges().is_empty() and key == _selected_section_key)


## 查询由本土化标题、描述、语法及模块名共同匹配，完全不访问玩家编写的程序。
func _on_query_changed(_query: String) -> void:
	if not _open:
		return
	_update_selection()
	_rebuild_content()


## 右侧列出所选模块的全部指令，搜索匹配完整说明但新结果仍默认折叠。
func _rebuild_content() -> void:
	_clear_children(_list)
	_cards.clear()
	_command_buttons.clear()
	_details.clear()
	_syntax.clear()
	_displayed_entries.clear()
	var query := header.get_query().strip_edges()
	var caption := tr("编程基础")
	if not query.is_empty():
		caption = tr("搜索结果")
		_displayed_entries = _listed_entries(catalog.search(query, _registry, TranslationServer.get_locale()))
	else:
		for section in _sections:
			if _section_key(section) == _selected_section_key:
				caption = section.title
				_displayed_entries.assign(section.entries)
				break
	_content_title = GameTheme.label(_list, caption, 22)
	_content_title.name = "CommandContentTitle"
	_content_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_content_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content_count = GameTheme.label(_list, tr("%d 条指令") % _displayed_entries.size(), 13, true)
	_content_count.name = "CommandContentCount"
	for entry in _displayed_entries:
		_add_command_card(entry, not query.is_empty())
	_empty_label = GameTheme.label(_list, "没有找到匹配的指令" if not query.is_empty() else "此模块暂无指令资料", 15, true)
	_empty_label.name = "CommandReferenceEmpty"
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.visible = _displayed_entries.is_empty()
	_error_label = GameTheme.label(_list, "部分指令资料未能读取", 13, true)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = not catalog.errors.is_empty()
	_error_label.tooltip_text = "\n".join(catalog.errors)
	_scroll.scroll_vertical = 0


## 目录和搜索共用显示范围，隐藏逐帧回调及未开放的事件资料，避免提前透露后续关卡语法。
func _listed_entries(entries: Array) -> Array[Dictionary]:
	var listed: Array[Dictionary] = []
	for entry: Dictionary in entries:
		if entry.id == "tick":
			continue
		if entry.get("requirements", {}).get("allow_radar_events", false) and (_level == null or not _level.allow_radar_events):
			continue
		listed.append(entry)
	return listed


## 每条指令独立展开，权限只控制配色和悬停说明，不妨碍阅读完整资料。
func _add_command_card(entry: Dictionary, searching: bool) -> void:
	var available := CommandCatalog.is_available(entry, _level, _registry)
	var card := CommandReferenceItem.new()
	card.configure(entry, GameTheme.TEXT if available else LOCKED_TEXT, "" if available else tr("目前尚未解锁"), str(entry.get("section_title", "")) if searching else "")
	_list.add_child(card)
	_cards.append(card)
	_command_buttons.append(card.header_button)
	_syntax.append(card.syntax)
	_details.append(card.details)


## 目录和文字按当前窗口尺寸分配，书本入口留在窗口上方，可随时再次点击关闭。
func _update_placement() -> void:
	if not _open:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var anchor_rect := _anchor.get_global_rect()
	var margin := 24.0
	var top := anchor_rect.end.y + 8
	var width := viewport_size.x - margin * 2
	var height := viewport_size.y - top - margin
	_panel.position = Vector2(margin, top)
	_panel.size = Vector2(width, height)
	_glass.position = Vector2.ONE
	_glass.size = _panel.size - Vector2(2, 2)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 27.0)
	var directory_width := clampf(width * 0.25, 200, 280)
	_sidebar.position = Vector2(12, 12)
	_sidebar.size = Vector2(directory_width, height - 24)
	_directory_scroll.position = Vector2(10, 48)
	_directory_scroll.size = _sidebar.size - Vector2(20, 62)
	var content_left := _sidebar.position.x + directory_width + 20
	var content_width := width - content_left - 20
	header.position = Vector2(content_left, 16)
	header.size = Vector2(content_width, 44)
	_scroll.position = Vector2(content_left, 82)
	_scroll.size = Vector2(content_width, height - 102)


## 外点只关闭窗口；输入框保留原生编辑行为，键盘焦点不会落到被遮住的装配控件。
func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseButton:
		if not _panel.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()
			if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				close_menu()
		return
	if not event is InputEventKey or not event.pressed:
		return
	if event.is_action_pressed("ui_cancel"):
		if header._search_open:
			header.set_search_open(false)
		else:
			close_menu()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_focus_next", false, true):
		_move_focus(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_focus_prev", false, true):
		_move_focus(-1)
		get_viewport().set_input_as_handled()
	else:
		_handle_content_key(event)


## 目录上下选择即刻切换完整资料，右侧聚焦时支持逐行、翻页和首尾滚动。
func _handle_content_key(event: InputEventKey) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	var index := _section_buttons.find(focus)
	if index >= 0 and (event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up")):
		var next := posmod(index + (1 if event.is_action_pressed("ui_down") else -1), _section_buttons.size())
		_section_buttons[next].grab_focus()
		_section_buttons[next].pressed.emit()
		get_viewport().set_input_as_handled()
	elif _command_buttons.has(focus) and (event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up")):
		var next := clampi(_command_buttons.find(focus) + (1 if event.is_action_pressed("ui_down") else -1), 0, _command_buttons.size() - 1)
		_command_buttons[next].grab_focus()
		get_viewport().set_input_as_handled()
	elif focus == _scroll:
		var step := 44 if event.keycode == KEY_DOWN else -44 if event.keycode == KEY_UP else roundi(_scroll.size.y * 0.8) if event.keycode == KEY_PAGEDOWN else -roundi(_scroll.size.y * 0.8) if event.keycode == KEY_PAGEUP else 0
		if step != 0:
			_scroll.scroll_vertical += step
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_HOME, KEY_END]:
			_scroll.scroll_vertical = 0 if event.keycode == KEY_HOME else roundi(_scroll.get_v_scroll_bar().max_value)
			get_viewport().set_input_as_handled()


## Tab 在导航、搜索、目录和指令入口间循环，回车或空格沿用按钮的展开操作。
func _move_focus(direction: int) -> void:
	var active: Array[Control] = [header.back_button]
	if header._search_open:
		active.append(header.search_close_button)
		active.append(header.search_input)
	else:
		active.append(header.search_button)
	for item in _section_buttons:
		active.append(item)
	for item in _command_buttons:
		active.append(item)
	active.append(_scroll)
	var index := active.find(get_viewport().gui_get_focus_owner())
	active[posmod(index + direction, active.size())].grab_focus()


## 稳定分组键同时包含来源种类，避免同名模块与通用分类互相覆盖。
func _section_key(section: Dictionary) -> String:
	return str(section.kind) + ":" + str(section.id)


## 从父容器立即移除旧内容再排队释放，防止重建一帧内发生重复布局或焦点冲突。
func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
