class_name CommandRestrictionMenu
extends CommandReferenceMenu
## 地图作者的指令允许清单，复用阅读窗口的分类和搜索，只报告开关意图。

signal command_toggled(id: String, enabled: bool)
signal toggle(id: String, enabled: bool)

const MENU_TITLE := "管理关卡中允许使用的指令集"
const SWITCH_HINT := "开启表示允许使用，关闭表示限制使用。"
const MAIN_HINT := "main 是程序的必需入口，必须允许使用。"
const UNSUPPORTED_HINT := "当前版本尚不支持此指令。"

var _enabled_commands: Dictionary = {}
var _command_switches: Dictionary = {}
var _swallowed_button := 0
var _header_focus_style: StyleBox
var _content_fade: ScrollContentFade


## 沿用独立浮层的毛玻璃、目录与导航，管理窗口使用自己的标题和节点名。
func _ready() -> void:
	super._ready()
	_overlay.name = "CommandRestrictionOverlay"
	_panel.name = "CommandRestrictionPanel"
	# 管理底窗略深于白色指令卡片；复制本地样式保留玻璃、圆角与阴影。
	var background := Color("EAEDF2")
	var surface := _panel.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	surface.bg_color = Color(background, 0.97)
	_panel.add_theme_stylebox_override("panel", surface)
	(_glass.material as ShaderMaterial).set_shader_parameter("frost_tint", Vector3(background.r, background.g, background.b))
	_header_focus_style = header.back_button.get_theme_stylebox("focus")
	header.back_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	for scroll: ScrollContainer in [_scroll, _directory_scroll]:
		SettingsContentFade.style_scrollbar(scroll.get_v_scroll_bar())
		SettingsScrollFade.attach(scroll)
	_content_fade = ScrollContentFade.new()
	_content_fade.name = "CommandRestrictionContentFade"
	_panel.add_child(_content_fade)
	_panel.remove_child(_scroll)
	_content_fade.set_scroll(_scroll)
	_refresh_title()
	set_process(false)


## 翻译后的条目仍由目录管理，延后设置管理标题以避开阅读工具栏的默认标题刷新。
func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_title.call_deferred()


## 展示完整指令目录；开关状态来自编辑文档，模块限制和旧语法解锁标志不参与筛选。
func show_commands(anchor: Control, registry: ContentRegistry, enabled_ids) -> void:
	sync_enabled_commands(enabled_ids)
	if _open:
		_registry = registry
		catalog.load_directory(catalog_directory)
		_rebuild_directory()
		_rebuild_content()
		_update_placement()
		return
	_swallowed_button = 0
	super.popup_at(anchor, null, registry, "返回地图属性")
	if _open:
		_refresh_title()
		header.back_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		set_process(true)


## 外层依赖联动、撤销和重做只同步现有开关，不重复发信号或重置搜索与滚动位置。
func sync_enabled_commands(ids) -> void:
	_enabled_commands.clear()
	for command_id in ids:
		_enabled_commands[str(command_id)] = true
	_enabled_commands["main"] = true
	for command_id in _command_switches:
		var switch: SettingsSwitch = _command_switches[command_id]
		if is_instance_valid(switch):
			switch.set_pressed_no_signal(_enabled_commands.has(command_id))
			switch.queue_redraw()


## 关闭后隐藏整个浮层并释放其焦点；外点的抬起事件也被消费，避免在地图上落下一笔。
func close_menu(restore_focus: bool = false) -> void:
	if not _open:
		return
	_open = false
	set_process(false)
	set_process_input(_swallowed_button != 0)
	if _tween != null:
		_tween.kill()
		_tween = null
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and _overlay.is_ancestor_of(focus):
		focus.release_focus()
	header.set_active(false)
	_overlay.hide()
	if restore_focus and is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		_anchor.grab_focus()


## 属性页被关闭或切换文档时及时隐藏菜单，防止失去有效入口后浮层继续拦截编辑操作。
func _process(_delta: float) -> void:
	if _open and (not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree()):
		close_menu(false)


## 管理用途始终展示包括 tick 与雷达事件在内的全部静态条目，旧阅读菜单保持原筛选。
func _listed_entries(entries: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in entries:
		result.append(entry)
	return result


## 重建分类与搜索结果时清除旧开关引用，允许状态保持在文档同步的独立集合里。
func _rebuild_content() -> void:
	_command_switches.clear()
	super._rebuild_content()


## 紧凑行只显示语法与开关，资料放在悬停提示中，右侧状态不冒充模块权限。
func _add_command_card(entry: Dictionary, searching: bool) -> void:
	var command_id := str(entry.id)
	var locale := TranslationServer.get_locale()
	var card := PanelContainer.new()
	card.name = "CommandRestrictionItem_" + command_id
	card.set_meta("command_id", command_id)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.tooltip_text = CommandCatalog.localized(entry, "title", locale) + "\n\n" + CommandCatalog.localized(entry, "description", locale)
	var surface := GameTheme.box(Color(1, 1, 1, 0.75), Color.TRANSPARENT, 16)
	surface.set_content_margin_all(0)
	card.add_theme_stylebox_override("panel", surface)
	_list.add_child(card)
	_cards.append(card)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18 if side in ["left", "right"] else 8)
	card.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	margin.add_child(row)
	var text_column := VBoxContainer.new()
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_column.add_theme_constant_override("separation", 6)
	row.add_child(text_column)
	var syntax := _entry_label(text_column, str(entry.syntax), 16, GameTheme.TEXT)
	syntax.name = "CommandRestrictionSyntax_" + command_id
	syntax.tooltip_text = card.tooltip_text
	syntax.add_theme_font_override("font", GameTheme.code_font())
	_syntax.append(syntax)
	if searching:
		_entry_label(text_column, str(entry.get("section_title", "")), 12, GameTheme.MUTED)
	var switch_column := VBoxContainer.new()
	switch_column.alignment = BoxContainer.ALIGNMENT_CENTER
	switch_column.add_theme_constant_override("separation", 6)
	row.add_child(switch_column)
	var switch := SettingsSwitch.new()
	switch.name = "CommandRestrictionSwitch_" + command_id
	switch.set_meta("command_id", command_id)
	switch.set_pressed_no_signal(_enabled_commands.has(command_id))
	switch.disabled = command_id == "main" or command_id not in CommandPermissions.COMMAND_IDS
	switch.tooltip_text = tr(MAIN_HINT if command_id == "main" else UNSUPPORTED_HINT if switch.disabled else SWITCH_HINT)
	switch.toggled.connect(_on_command_toggled.bind(command_id))
	switch_column.add_child(switch)
	_command_switches[command_id] = switch
	if command_id == "main":
		var required := GameTheme.label(switch_column, "必需", 12)
		required.name = "CommandRestrictionRequired"
		required.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		required.add_theme_color_override("font_color", GameTheme.MUTED)
	elif not switch.disabled:
		_command_buttons.append(switch)


## 条目正文使用真实字号和自动换行，玩家代码及已本土化资料不再次自动翻译。
func _entry_label(parent: Node, value: String, font_size: int, color: Color) -> Label:
	var label := GameTheme.label(parent, value, font_size)
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	return label


## 用户切换立即更新本地状态并报告意图，依赖开启或关闭由外层编辑事务统一处理。
func _on_command_toggled(enabled: bool, command_id: String) -> void:
	if command_id == "main" or command_id not in CommandPermissions.COMMAND_IDS:
		sync_enabled_commands(_enabled_commands.keys())
		return
	if enabled:
		_enabled_commands[command_id] = true
	else:
		_enabled_commands.erase(command_id)
	command_toggled.emit(command_id, enabled)
	toggle.emit(command_id, enabled)


## 面板从视口上方展开到下缘，与低处的加号入口脱离，左右正文与目录各自滚动。
func _update_placement() -> void:
	if not _open or _panel == null:
		return
	if not is_instance_valid(_anchor) or not _anchor.is_visible_in_tree():
		close_menu(false)
		return
	var factor := GameTheme.sync_popup_scale(_overlay, _anchor)
	var viewport_size := get_viewport().get_visible_rect().size / factor
	var margin := minf(24.0, viewport_size.x * 0.03)
	var top := 80.0 if viewport_size.y >= 500.0 else 24.0
	var width := maxf(0.0, viewport_size.x - margin * 2.0)
	var height := maxf(0.0, viewport_size.y - top - margin)
	_panel.position = Vector2(margin, top)
	_panel.size = Vector2(width, height)
	_glass.position = Vector2.ONE
	_glass.size = (_panel.size - Vector2(2, 2)).max(Vector2.ZERO)
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	(_glass.material as ShaderMaterial).set_shader_parameter("corner_radius", 27.0)
	var directory_width := clampf(width * 0.24, minf(160.0, width * 0.32), 280.0)
	_sidebar.position = Vector2(12, 12)
	_sidebar.size = Vector2(directory_width, maxf(0.0, height - 24.0))
	_directory_scroll.position = Vector2(10, 48)
	_directory_scroll.size = (_sidebar.size - Vector2(20, 62)).max(Vector2.ZERO)
	var content_left := _sidebar.position.x + directory_width + 20.0
	var content_width := maxf(0.0, width - content_left - 20.0)
	header.position = Vector2(content_left, 16)
	header.size = Vector2(content_width, 44)
	_content_fade.position = Vector2(content_left, 82)
	_content_fade.size = Vector2(content_width, maxf(0.0, height - 102.0))
	_panel.pivot_offset = Vector2(width, 0)


## 统一管理标题，不修改普通阅读窗口的默认标题或导航行为。
func _refresh_title() -> void:
	if header != null and header._title != null:
		header._title.text = tr(MENU_TITLE)
		header._layout_header()


## Esc 直接关闭管理窗口；外点包括抬起事件均消费，Tab 与上下键沿用目录导航。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and _swallowed_button != 0 and _swallowed_button == event.button_index:
		get_viewport().set_input_as_handled()
		if not event.pressed:
			_swallowed_button = 0
			if not _open:
				set_process_input(false)
		return
	if not _open:
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		header.back_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	elif event is InputEventKey and event.pressed:
		header.back_button.add_theme_stylebox_override("focus", _header_focus_style)
	if event is InputEventMouseButton:
		if not _panel.get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()
			if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_swallowed_button = event.button_index
				close_menu(false)
		return
	if event is InputEventKey and event.pressed and event.is_action_pressed("ui_cancel"):
		close_menu(false)
		get_viewport().set_input_as_handled()
		return
	super._input(event)
