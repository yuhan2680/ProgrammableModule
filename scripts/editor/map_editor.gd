class_name MapEditor
extends Control
## 极简地图编辑前端：只维护编辑文档，测试交由外层进入正常组装与编程流程。

signal back_requested
signal playtest_requested(definition: LevelDefinition, content: ContentRegistry)
signal save_finished(success: bool)

const DEFAULT_MAP_PATH := "res://data/maps/movement_lab.json"
const SCENE_LABEL_SIZE := 12
const METADATA_DIALOG_SIZE := Vector2i(456, 342) # 原 760 × 570 窗口的 60%。

var editor_document := MapEditorDocument.new()
var registry := ContentRegistry.new()
var settings: GameSettings

var _canvas: MapEditorCanvas
var _map_view: MapEditorViewport
var _zoom_out_button: Button
var _zoom_in_button: Button
var _guide_button: Button
var _guide_menu: WorkbenchGuideMenu
var _status: Label
var _file_label: Button
var _header: MapEditorHeader
var _actions_menu: MapEditorActionsMenu
var _id_field: LineEdit
var _name_field: LineEdit
var _width_field: SpinBox
var _height_field: SpinBox
var _dimension_texts: Dictionary = {}
var _time_limit_field: LineEdit
var _time_limit_text := "60"
var _module_limit_field: SpinBox
var _player_health_field: LineEdit
var _player_health_text := "1"
var _player_health_baseline := "1"
var _player_health_edited := false
var _paint_button: Button
var _rectangle_button: Button
var _spawn_button: Button
var _goal_button: Button
var _reset_spawn_button: Button
var _reset_goal_button: Button
var _tool_group: ButtonGroup
var _point_tool := ""
var _terrain_mode := MapEditorCanvas.PaintMode.BRUSH
var _brush: OptionButton
var _undo_button: Button
var _redo_button: Button
var _play_button: Button
var _file_dialog: FileDialog
var _dirty_dialog: ConfirmationDialog
var _message_dialog: AcceptDialog
var _metadata_dialog: ConfirmationDialog
var _metadata_text: CodeEdit
var _enemy_panel: MapEditorEnemyPanel
var _brush_ids: Array[String] = []
var _pending_action: String = ""
var _file_operation: String = ""
var _default_module_id: String = ""
var _syncing_fields: bool = false
var _metadata_color_mode := ""


# 用途：载入内容目录、构建最小界面并打开示例地图，失败时显示可诊断错误。
func _ready() -> void:
	_build_ui()
	if settings != null:
		settings.changed.connect(_sync_metadata_color)
	_sync_metadata_color()
	editor_document.changed.connect(_on_document_changed)
	var content_result: DataResult = _load_catalog()
	_populate_catalog()
	_canvas.registry = registry
	if not content_result.is_ok():
		_new_document()
		_show_errors("内容加载失败", content_result.errors)
		return
	if FileAccess.file_exists(DEFAULT_MAP_PATH):
		_load_document(DEFAULT_MAP_PATH)
	else:
		_new_document()


# 用途：提供常见保存和撤销快捷键，文本编辑控件仍使用自身的撤销操作。
func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if not (event.ctrl_pressed or event.meta_pressed) or _metadata_dialog.visible or _file_dialog.visible or _dirty_dialog.visible or _actions_menu.is_open() or _guide_menu.is_open():
		return
	if event.keycode == KEY_O:
		_request_action("open")
		get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_S:
		_save_document(event.shift_pressed)
		get_viewport().set_input_as_handled()
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.keycode == KEY_Z:
		if event.shift_pressed:
			_redo()
		else:
			_undo()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_Y:
		_redo()
		get_viewport().set_input_as_handled()


# 用途：建立文件、地形、关卡上限和测试入口；实际游戏控制由外层工作台提供。
func _build_ui() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	_header = MapEditorHeader.new()
	_header.name = "MapEditorHeader"
	layout.add_child(_header)
	_header.back_requested.connect(back_requested.emit)
	_header.new_requested.connect(_request_action.bind("new"))
	_header.save_requested.connect(_save_document.bind(false))
	_header.undo_requested.connect(_undo)
	_header.redo_requested.connect(_redo)
	_header.more_requested.connect(_show_actions_menu)
	_header.reload_requested.connect(_reload_definitions)
	_undo_button = _header.undo_button
	_redo_button = _header.redo_button
	_actions_menu = MapEditorActionsMenu.new()
	_actions_menu.name = "MapEditorActionsMenu"
	add_child(_actions_menu)
	_actions_menu.save_as_requested.connect(_save_document.bind(true))
	_actions_menu.validate_requested.connect(_validate_document)
	_actions_menu.metadata_requested.connect(_open_metadata)
	visibility_changed.connect(_on_editor_visibility_changed)
	# 路径保留原有未保存标记，同时承接旧“打开”操作，避免图标栏继续堆叠按钮。
	_file_label = Button.new()
	_file_label.name = "MapEditorOpenButton"
	_file_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_file_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_file_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_file_label.clip_text = true
	_file_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_file_label.add_theme_font_size_override("font_size", 13)
	_file_label.add_theme_color_override("font_color", GameTheme.MUTED)
	_file_label.add_theme_color_override("font_hover_color", GameTheme.ACCENT)
	_file_label.custom_minimum_size.y = 24
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := GameTheme.box(Color.TRANSPARENT, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 6)
		style.set_content_margin_all(0)
		_file_label.add_theme_stylebox_override(state, style)
	_file_label.pressed.connect(_request_action.bind("open"))
	layout.add_child(_file_label)
	var workspace := HSplitContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.split_offset = 810
	layout.add_child(workspace)
	var map_panel := PanelContainer.new()
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.custom_minimum_size.x = 360
	workspace.add_child(map_panel)
	var map_area := Control.new()
	map_area.name = "MapEditorMapArea"
	map_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_panel.add_child(map_area)
	_map_view = MapEditorViewport.new()
	_map_view.name = "MapEditorViewport"
	map_area.add_child(_map_view)
	_map_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas = _map_view.canvas
	_canvas.point_placement_cancelled.connect(_cancel_point_tool)
	_canvas.enemy_placement_cancelled.connect(_cancel_point_tool)
	_canvas.enemy_placement_requested.connect(_place_enemy)
	_canvas.stroke_started.connect(editor_document.begin_action)
	_canvas.cell_requested.connect(_paint_cell)
	_canvas.rectangle_requested.connect(_paint_rectangle)
	_canvas.stroke_finished.connect(editor_document.end_action)
	_build_map_controls(map_area)
	_build_properties(workspace)
	_build_dialogs()
	_update_history_buttons()

## 属性使用紧凑横向表单；滚动条独占右侧留白，不与输入框或数字箭头重叠。
func _build_properties(workspace: Control) -> void:
	var card := PanelContainer.new()
	card.name = "MapEditorPropertiesCard"
	card.custom_minimum_size.x = 340
	card.theme = _properties_theme()
	var surface := GameTheme.card()
	surface.content_margin_top = 14
	surface.content_margin_right = 10
	card.add_theme_stylebox_override("panel", surface)
	workspace.add_child(card)
	var scroll := ScrollContainer.new()
	scroll.name = "MapEditorPropertiesScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 固定保留滚动条位置，透明淡出时表单和居中的名称行不会左右跳动。
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	scroll.follow_focus = true
	card.add_child(scroll)
	SettingsScrollFade.attach(scroll)
	var gutter := MarginContainer.new()
	gutter.name = "MapEditorPropertiesGutter"
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", 18)
	scroll.add_child(gutter)
	var fields := VBoxContainer.new()
	fields.name = "MapEditorPropertiesFields"
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 8)
	gutter.add_child(fields)
	GameTheme.label(fields, "地图属性", 16)
	# 右侧包含卡片内边距、滚动条和留白；在名称行左侧补齐相同的总距离。
	var identity_inset := surface.content_margin_right + 18 + scroll.get_v_scroll_bar().get_combined_minimum_size().x - surface.content_margin_left
	_build_identity_fields(fields, identity_inset)
	_property_gap(fields, 6)
	_build_dimensions(fields)
	_property_gap(fields, 12)
	_build_scene_controls(fields)
	var footer_space := Control.new()
	footer_space.custom_minimum_size.y = 24
	footer_space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	footer_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fields.add_child(footer_space)
	_play_button = _add_button(fields, "开始测试", _start_playtest)
	GameTheme.primary(_play_button)
	# 主操作仍保留蓝色，仅缩小其本地留白，不影响其他页面的按钮样式。
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		_play_button.add_theme_stylebox_override(state, _compact_field_style(_play_button.get_theme_stylebox(state)))
	var test_help := GameTheme.label(fields, "测试会进入组装和编程，最终模块占地在确认装配时检查。", 12, true)
	test_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 名称和 ID 共用一行及等宽输入框，缩小字号和高度，整行相对卡片左右对称。
func _build_identity_fields(parent: Node, leading_inset: float) -> void:
	var margin := MarginContainer.new()
	margin.name = "MapEditorIdentityMargin"
	margin.add_theme_constant_override("margin_left", maxi(0, roundi(leading_inset)))
	parent.add_child(margin)
	var identity := GridContainer.new()
	identity.name = "MapEditorIdentityRow"
	identity.columns = 4
	identity.add_theme_constant_override("h_separation", 6)
	margin.add_child(identity)
	for caption: String in ["名称", "ID"]:
		var label := GameTheme.label(identity, caption, 12)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var field := _add_line_edit(identity, 76)
		field.custom_minimum_size.y = 26
		field.add_theme_font_size_override("font_size", 12)
		field.add_theme_constant_override("minimum_character_width", 0)
		for state: StringName in ["normal", "focus", "read_only"]:
			var style := field.get_theme_stylebox(state).duplicate() as StyleBoxFlat
			style.content_margin_left = 6
			style.content_margin_right = 6
			field.add_theme_stylebox_override(state, style)
		field.focus_exited.connect(_commit_identity)
		field.text_submitted.connect(_on_identity_submitted)
		if caption == "名称":
			_name_field = field
		else:
			_id_field = field


## 场景编辑将尺寸与地形工具放入同一折叠内容，英文用 W/H 留出输入空间。
func _build_dimensions(parent: Node) -> void:
	var group := VBoxContainer.new()
	group.name = "MapEditorSceneSize"
	group.add_theme_constant_override("separation", 8)
	parent.add_child(group)
	var body := VBoxContainer.new()
	body.name = "MapEditorSceneEditingBody"
	body.add_theme_constant_override("separation", 14)
	_build_section_heading(group, "场景编辑", body, "MapEditorSizeCollapse")
	group.add_child(body)
	var dimensions := HBoxContainer.new()
	dimensions.name = "MapEditorDimensions"
	dimensions.alignment = BoxContainer.ALIGNMENT_CENTER
	dimensions.add_theme_constant_override("separation", 10)
	body.add_child(dimensions)
	for caption: String in ["宽", "高"]:
		var row := _property_row(dimensions, caption, 0)
		if caption == "宽":
			_width_field = _add_spin(row, 1, 64, 1, 16, false)
		else:
			_height_field = _add_spin(row, 1, 64, 1, 12, false)
	# 输入范围最多两位数字，不使用原生文本框按四个宽字符预留的较大最小宽度。
	for field in [_width_field, _height_field]:
		field.custom_minimum_size.x = 48
		# 旧地图可超过64，模型回填时如实显示；用户输入和应用入口始终限制为1..64。
		field.allow_greater = true
		field.tooltip_text = "宽和高只能输入 1～64 的整数。"
		_dimension_texts[field] = str(int(field.value))
		field.get_line_edit().text_changed.connect(_on_dimension_text_changed.bind(field))
		field.value_changed.connect(_on_dimension_value_changed.bind(field))
		field.get_line_edit().add_theme_constant_override("minimum_character_width", 0)
	var apply := _add_button(dimensions, "应用尺寸", _resize_document)
	apply.custom_minimum_size.x = 90
	_build_paint_tools(body)


## 在键入或粘贴时恢复最后有效内容；允许暂时留空，便于替换整段数字。
func _on_dimension_text_changed(text: String, field: SpinBox) -> void:
	if _syncing_fields:
		return
	if text.is_empty():
		return
	if text.is_valid_int() and text.to_int() >= 1 and text.to_int() <= 64:
		_dimension_texts[field] = text
		# 数值同步到控件供失焦和应用读取，地图仍要点击“应用尺寸”才改变。
		field.value = text.to_int()
		return
	var input := field.get_line_edit()
	var caret := input.caret_column
	input.text = _dimension_texts.get(field, str(clampi(int(field.value), 1, 64)))
	input.caret_column = mini(caret, input.text.length())


## 原生回车、方向键和失焦也不得提交超过上限的值，模型回填不裁剪已有地图。
func _on_dimension_value_changed(value: float, field: SpinBox) -> void:
	if _syncing_fields:
		return
	if value > 64.0 or value < 1.0:
		field.value = clampf(value, 1.0, 64.0)
	_dimension_texts[field] = str(clampi(int(field.value), 1, 64))


## 画笔样式与绘制项目并排：样式控制手势，项目只决定写入哪一种地块。
func _build_paint_tools(parent: Node) -> void:
	var toolbar := HBoxContainer.new()
	toolbar.name = "MapEditorPaintTools"
	toolbar.add_theme_constant_override("separation", 10)
	parent.add_child(toolbar)
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 6)
	toolbar.add_child(modes)
	var mode_label := GameTheme.label(modes, "画笔样式", 12)
	mode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var pill := Panel.new()
	pill.custom_minimum_size = Vector2(56, 28)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var surface := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	pill.add_theme_stylebox_override("panel", surface)
	modes.add_child(pill)
	_tool_group = ButtonGroup.new()
	_paint_button = _view_button(pill, "MapEditorPaintButton", "map_editor_paint", _set_paint_mode.bind(MapEditorCanvas.PaintMode.BRUSH), 0, 2)
	_rectangle_button = _view_button(pill, "MapEditorRectangleButton", "map_editor_rectangle", _set_paint_mode.bind(MapEditorCanvas.PaintMode.RECTANGLE), 1, 2)
	for button in [_paint_button, _rectangle_button]:
		button.toggle_mode = true
		button.button_group = _tool_group
	_paint_button.set_pressed_no_signal(true)
	_paint_button.tooltip_text = "画笔"
	_rectangle_button.tooltip_text = "框选"
	var drawing := HBoxContainer.new()
	drawing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drawing.add_theme_constant_override("separation", 6)
	toolbar.add_child(drawing)
	var item_label := GameTheme.label(drawing, "绘制项目", 12)
	item_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_brush = OptionButton.new()
	_brush.name = "MapEditorDrawingItem"
	# 名称与稳定 ID 分开翻译，不能把“地板 (floor)”整体交给自动翻译。
	_brush.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_brush.fit_to_longest_item = false
	_brush.clip_text = true
	_brush.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_brush.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush.custom_minimum_size = Vector2(94, 32)
	_brush.add_theme_font_size_override("font_size", 12)
	drawing.add_child(_brush)
	_brush.item_selected.connect(_on_drawing_item_selected)


## 玩法分类统一折叠起终点、限时、模块数量及玩家耐久设置。
func _build_scene_controls(parent: Node) -> void:
	var section := VBoxContainer.new()
	section.name = "MapEditorSceneControls"
	section.add_theme_constant_override("separation", 8)
	parent.add_child(section)
	var body := VBoxContainer.new()
	body.name = "MapEditorSceneControlsBody"
	body.add_theme_constant_override("separation", 12)
	_build_section_heading(section, "场景玩法与行为控制", body, "MapEditorSceneCollapse")
	section.add_child(body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	body.add_child(row)
	var placement_column := VBoxContainer.new()
	placement_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	placement_column.add_theme_constant_override("separation", 10)
	row.add_child(placement_column)
	var placement := HBoxContainer.new()
	placement.name = "MapEditorPointTools"
	placement.add_theme_constant_override("separation", 6)
	placement_column.add_child(placement)
	_scene_label(placement, "添加起点与终点", "MapEditorPointLabel")
	var pill := Panel.new()
	pill.custom_minimum_size = Vector2(56, 28)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var surface := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	pill.add_theme_stylebox_override("panel", surface)
	placement.add_child(pill)
	_spawn_button = _view_button(pill, "MapEditorSpawnButton", "map_editor_spawn", _select_point_tool.bind("spawn"), 0, 2)
	_goal_button = _view_button(pill, "MapEditorGoalButton", "map_editor_goal", _select_point_tool.bind("goal"), 1, 2)
	for button in [_spawn_button, _goal_button]:
		button.toggle_mode = true
		button.button_group = _tool_group
	_spawn_button.tooltip_text = "添加起点：选择后单击地图放置"
	_goal_button.tooltip_text = "添加终点（可选）：选择后单击地图放置"
	_build_time_limit(placement_column, pill)
	var reset := VBoxContainer.new()
	reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset.add_theme_constant_override("separation", 8)
	row.add_child(reset)
	_reset_spawn_button = _add_button(reset, "重置起点", _clear_spawn)
	_reset_goal_button = _add_button(reset, "重置终点", _clear_goal)
	for button in [_reset_spawn_button, _reset_goal_button]:
		button.custom_minimum_size.x = 92
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state, Color("dd1d1d"))
	_build_player_limits(body)
	_property_gap(body, 12)
	_enemy_panel = MapEditorEnemyPanel.new()
	body.add_child(_enemy_panel)
	_enemy_panel.placement_requested.connect(_select_enemy_tool)
	_enemy_panel.enabled_changed.connect(_on_enemies_enabled_changed)
	_enemy_panel.feedback.connect(_on_enemy_feedback)


## 场景属性标签统一字体、字重和字号，避免限时与起终点标签视觉不一致。
func _scene_label(parent: Control, caption: String, node_name: String = "") -> Label:
	var label := GameTheme.label(parent, caption, SCENE_LABEL_SIZE)
	if not node_name.is_empty():
		label.name = node_name
	label.add_theme_font_override("font", GameTheme.body_font())
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


## 两项玩家上限并排显示，输入框保持紧凑，长数值仍可直接编辑。
func _build_player_limits(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.name = "MapEditorPlayerLimits"
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var modules := HBoxContainer.new()
	modules.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	modules.add_theme_constant_override("separation", 6)
	row.add_child(modules)
	_scene_label(modules, "玩家模块数量上限")
	_module_limit_field = _add_spin(modules, 1, 256, 1, 1, false)
	_module_limit_field.custom_minimum_size.x = 44
	_module_limit_field.get_line_edit().add_theme_constant_override("minimum_character_width", 0)
	_module_limit_field.tooltip_text = "组装时允许安装的模块总数（1..256）。"
	_module_limit_field.value_changed.connect(_on_module_limit_changed)
	var health := HBoxContainer.new()
	health.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	health.add_theme_constant_override("separation", 6)
	row.add_child(health)
	_scene_label(health, "玩家耐久度上限")
	_player_health_field = _add_line_edit(health, 44)
	_player_health_field.name = "MapEditorPlayerHealthInput"
	_player_health_field.add_theme_constant_override("minimum_character_width", 0)
	_player_health_field.text = "1"
	_player_health_field.tooltip_text = "本地图内玩家每个模块的初始和最大耐久，默认 1；可输入正小数。"
	_player_health_field.text_changed.connect(_on_player_health_text_changed)
	_player_health_field.focus_entered.connect(_begin_player_health_edit)
	_player_health_field.focus_exited.connect(_commit_player_health)
	_player_health_field.text_submitted.connect(_on_player_health_submitted)
	for input: LineEdit in [_module_limit_field.get_line_edit(), _player_health_field]:
		for state in ["normal", "focus", "read_only"]:
			var style := input.get_theme_stylebox(state).duplicate() as StyleBoxFlat
			style.content_margin_left = 8
			style.content_margin_right = 8
			input.add_theme_stylebox_override(state, style)


## 标题旁提供独立SVG折叠按钮，只控制该分类内容的可见性。
func _build_section_heading(parent: Control, caption: String, content: Control, button_name: String) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	parent.add_child(header)
	var label := GameTheme.label(header, caption, 14)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var button := Button.new()
	button.name = button_name
	button.custom_minimum_size = Vector2(22, 22)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.icon = load("res://assets/ui/map_editor_collapse.svg")
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 12)
	button.tooltip_text = "收起分类"
	for state in ["normal", "hover", "pressed", "focus"]:
		var surface := GameTheme.box(Color("EAF0F8") if state in ["hover", "pressed"] else Color.TRANSPARENT, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 8)
		surface.set_content_margin_all(4)
		button.add_theme_stylebox_override(state, surface)
	button.pressed.connect(_toggle_section.bind(content, button))
	header.add_child(button)


## 折叠不重建控件、不清空值，也不进入地图撤销历史；试玩返回保留展开状态。
func _toggle_section(content: Control, button: Button) -> void:
	content.visible = not content.visible
	button.icon = load("res://assets/ui/map_editor_collapse.svg" if content.visible else "res://assets/ui/map_editor_expand.svg")
	button.tooltip_text = "收起分类" if content.visible else "展开分类"


## 秒表旁直接输入秒数，药丸没有加减或上下箭头；沿用场景控制的紧凑布局。
func _build_time_limit(parent: Control, point_pill: Control) -> void:
	var inset := MarginContainer.new()
	parent.add_child(inset)
	var row := HBoxContainer.new()
	row.name = "MapEditorTimeLimitRow"
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 5)
	inset.add_child(row)
	var caption := _scene_label(row, "时间限制", "MapEditorTimeLimitLabel")
	var pill := PanelContainer.new()
	pill.name = "MapEditorTimeLimitPill"
	pill.custom_minimum_size = Vector2(80, 30)
	var surface := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 15)
	surface.content_margin_left = 8
	surface.content_margin_right = 8
	surface.content_margin_top = 2
	surface.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", surface)
	row.add_child(pill)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	pill.add_child(content)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/ui/map_editor_timer.svg")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(18, 18)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(icon)
	_time_limit_field = LineEdit.new()
	_time_limit_field.name = "MapEditorTimeLimitInput"
	_time_limit_field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_time_limit_field.text = "60"
	_time_limit_field.custom_minimum_size.x = 42
	_time_limit_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_limit_field.add_theme_constant_override("minimum_character_width", 0)
	_time_limit_field.add_theme_font_size_override("font_size", 15)
	_time_limit_field.caret_blink = true
	_time_limit_field.caret_blink_interval = 0.5
	for state in ["normal", "focus", "read_only"]:
		_time_limit_field.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_time_limit_field.tooltip_text = "默认 60 秒；大于 0，最多 3600 秒。"
	_time_limit_field.text_changed.connect(_on_time_limit_text_changed)
	_time_limit_field.focus_exited.connect(_commit_time_limit)
	_time_limit_field.text_submitted.connect(_on_time_limit_submitted)
	content.add_child(_time_limit_field)
	var unit := GameTheme.label(row, "秒", 10, true)
	unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var align_row := _align_time_limit.bind(point_pill, pill, caption, inset)
	# 实际文字度量在中英切换及高分屏布局后才可用，布局变化后重新对齐两只药丸。
	point_pill.resized.connect(align_row.call_deferred)
	point_pill.item_rect_changed.connect(align_row.call_deferred)
	pill.resized.connect(align_row.call_deferred)
	caption.resized.connect(align_row.call_deferred)
	align_row.call_deferred()


## 以起终点药丸为中心对齐，时间药丸左右伸出同样距离，单位不计入对齐宽度。
func _align_time_limit(point_pill: Control, timer_pill: Control, caption: Label, inset: MarginContainer) -> void:
	var offset := point_pill.position.x + (point_pill.size.x - timer_pill.size.x) * 0.5 - caption.size.x - 5.0
	inset.add_theme_constant_override("margin_left", maxi(0, roundi(offset)))


## 仅接受正十进制秒数，最多一位小数，以对应0.1秒的模拟精度。
func _valid_time_limit_text(text: String) -> bool:
	var parts := text.split(".")
	if parts.size() > 2 or parts[0].is_empty() or (parts.size() == 2 and parts[1].length() > 1):
		return false
	for part: String in parts:
		for character in part:
			if character < "0" or character > "9":
				return false
	return text.to_float() > 0.0 and text.to_float() <= 3600.0


## 输入或粘贴无效值时恢复有效内容，临时清空仅用于替换数字，不能提交为空。
func _on_time_limit_text_changed(text: String) -> void:
	if _syncing_fields or text.is_empty():
		return
	if _valid_time_limit_text(text):
		_time_limit_text = text
		return
	_time_limit_field.text = _time_limit_text
	_time_limit_field.caret_column = _time_limit_field.text.length()


## 回车与失焦采用同一提交入口，保存与测试也可提交尚未失焦的输入。
func _on_time_limit_submitted(_text: String) -> void:
	_commit_time_limit()


## 保存正限时与二选一通关规则；无效或空白输入恢复上次已提交值。
func _commit_time_limit() -> void:
	if _syncing_fields or _time_limit_field == null:
		return
	var text := _time_limit_field.text
	var seconds := text.to_float() if _valid_time_limit_text(text) else editor_document.get_time_limit_seconds()
	_time_limit_text = String.num(seconds, 1).trim_suffix(".0")
	_time_limit_field.text = _time_limit_text
	var result := editor_document.set_time_limit_seconds(seconds)
	if not result.is_ok():
		_show_errors("无法设置时间限制", result.errors)


## 地形工具与点位工具互斥；回到画笔或框选时恢复对应高亮及原有绘制手势。
func _set_paint_mode(mode: MapEditorCanvas.PaintMode) -> void:
	_canvas.finish_stroke()
	_canvas.clear_enemy_preview()
	_point_tool = ""
	_terrain_mode = mode
	_canvas.paint_mode = mode
	_canvas.mouse_default_cursor_shape = Control.CURSOR_ARROW
	_paint_button.set_pressed_no_signal(mode == MapEditorCanvas.PaintMode.BRUSH)
	_rectangle_button.set_pressed_no_signal(mode == MapEditorCanvas.PaintMode.RECTANGLE)
	if _spawn_button != null:
		_spawn_button.set_pressed_no_signal(false)
		_goal_button.set_pressed_no_signal(false)


## 起点与终点使用单击工具，保留之前的地形手势以便取消后继续绘制。
func _select_point_tool(kind: String) -> void:
	_canvas.finish_stroke()
	_canvas.clear_enemy_preview()
	_point_tool = kind
	_canvas.paint_mode = MapEditorCanvas.PaintMode.POINT
	_canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	_paint_button.set_pressed_no_signal(false)
	_rectangle_button.set_pressed_no_signal(false)
	_spawn_button.set_pressed_no_signal(kind == "spawn")
	_goal_button.set_pressed_no_signal(kind == "goal")
	_status.text = "单击可通行地块放置起点；右键或 Esc 返回地形绘制。" if kind == "spawn" else "单击可通行地块放置终点；右键或 Esc 返回地形绘制。"


## 取消点位工具只切换交互，不清除已经放置的起点或终点。
func _cancel_point_tool() -> void:
	_set_paint_mode(_terrain_mode)


## 模块组合进入单击放置工具，虚影与实际落点共用同一份已校验模板。
func _select_enemy_tool() -> void:
	if not editor_document.get_enemies_enabled():
		return
	_canvas.finish_stroke()
	_point_tool = ""
	_canvas.set_enemy_template(editor_document.get_enemy_template(registry))
	_canvas.paint_mode = MapEditorCanvas.PaintMode.ENEMY
	_canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	for button in [_paint_button, _rectangle_button, _spawn_button, _goal_button]:
		button.set_pressed_no_signal(false)
	_status.text = "单击放置敌人；红色预览表示位置不可用，右键或 Esc 取消。"


## 每次点击只提交一个完整敌人，失败不改文档，连续拖动不会批量放置。
func _place_enemy(position: Vector2) -> void:
	if not editor_document.get_enemies_enabled():
		_cancel_point_tool()
		return
	var result := editor_document.place_enemy(position, registry)
	if not result.is_ok():
		_on_enemy_feedback(tr(result.errors[0]))
		return
	_status.text = "敌人已放置，试玩时会自动靠近并攻击玩家。可撤销。"


## 关闭只取消放置工具，已有敌人由文档保留，运行时按开关决定是否生成。
func _on_enemies_enabled_changed(enabled: bool) -> void:
	if not enabled and _canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY:
		_cancel_point_tool()
	_canvas.queue_redraw()


## 表单自行显示输入错误，指引中同时保留最近一次编辑状态。
func _on_enemy_feedback(message: String) -> void:
	_status.text = message


## 更换绘制项目回到地形工具，同时取消尚未提交的框选。
func _on_drawing_item_selected(_index: int) -> void:
	_set_paint_mode(_terrain_mode)


## 标签与输入控件处于同一行，常用短标签统一对齐，宽高和模块上限按文字自然占位。
func _property_row(parent: Node, caption: String, label_width: float = 40.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var label := _add_label(row, caption)
	label.custom_minimum_size.x = label_width
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return row


## 分组仅增加显示留白，保留每组内部的紧凑间距和原有编辑顺序。
func _property_gap(parent: Node, height: float) -> void:
	var gap := Control.new()
	gap.custom_minimum_size.y = height
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(gap)


## 紧凑主题仅作用于地图属性卡片，保持其他界面的字号、控件大小与焦点样式。
func _properties_theme() -> Theme:
	var result := GameTheme.create_theme()
	result.default_font_size = 14
	# 数字框保留原生范围、文本提交和方向键调节，但不显示框外的增减按钮。
	result.set_constant("buttons_width", "SpinBox", 0)
	result.set_constant("set_min_buttons_width_from_icons", "SpinBox", 0)
	result.set_constant("field_and_buttons_separation", "SpinBox", 0)
	var transparent := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	transparent.fill(Color.TRANSPARENT)
	var hidden_arrow := ImageTexture.create_from_image(transparent)
	for icon: StringName in ThemeDB.get_default_theme().get_icon_list("SpinBox"):
		result.set_icon(icon, "SpinBox", hidden_arrow)
	for kind: String in ["LineEdit", "Button", "OptionButton"]:
		for state: StringName in result.get_stylebox_list(kind):
			result.set_stylebox(state, kind, _compact_field_style(result.get_stylebox(state, kind)))
	return result


## 缩小输入框和按钮内边距及圆角，保留原有颜色与可见的键盘焦点。
func _compact_field_style(original: StyleBox) -> StyleBox:
	var style := original.duplicate() as StyleBoxFlat
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	style.set_corner_radius_all(10)
	return style


## 视图工具固定在地图卡片右上角，浮在裁剪区上方，不挤偏地图观察中心。
func _build_map_controls(parent: Control) -> void:
	var tools := HBoxContainer.new()
	tools.name = "MapEditorViewTools"
	tools.add_theme_constant_override("separation", 8)
	parent.add_child(tools)
	tools.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	tools.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var pill := Panel.new()
	pill.name = "MapEditorZoomPill"
	pill.custom_minimum_size = Vector2(56, 28)
	var surface := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	pill.add_theme_stylebox_override("panel", surface)
	tools.add_child(pill)
	_zoom_out_button = _view_button(pill, "MapEditorZoomOutButton", "map_editor_zoom_out", _map_view.zoom_out, 0, 2)
	_zoom_in_button = _view_button(pill, "MapEditorZoomInButton", "map_editor_zoom_in", _map_view.zoom_in, 1, 2)
	var separator := ColorRect.new()
	separator.color = Color("DCE1E8")
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	separator.position = Vector2(27.5, 8)
	separator.size = Vector2(1, 12)
	pill.add_child(separator)
	_guide_button = _view_button(tools, "MapEditorGuideButton", "workbench_guide", _show_guide, 0, 1)
	_guide_button.add_theme_stylebox_override("normal", surface.duplicate())
	_guide_menu = WorkbenchGuideMenu.new()
	_guide_menu.name = "MapEditorGuideMenu"
	add_child(_guide_menu)
	_guide_menu.configure("未绘制区域及地图外均为 void，机器不可通行。0° 向右，90° 向上；1 地块 = 1 单位。", "画笔可连续绘制；框选拖出范围后松开填充，右键擦除为 void。起点与终点使用独立按钮，单击放置，右键或 Esc 返回地形绘制。终点可选，没有终点也能保存和测试。用 − / + 或滚轮缩放。")
	_guide_menu.directions_label.hide()
	_guide_menu.terrain_label.text = "游戏关卡从 levels 目录读取；地图编辑器的示例不出现在关卡列表。"
	_status = _guide_menu.status_label
	_status.show()
	_map_view.zoom_changed.connect(_update_zoom_buttons)
	_update_zoom_buttons(_map_view.zoom)


## 小型工具保留足够点击范围，图标使用 SVG，圆角仅保留在胶囊外沿。
func _view_button(parent: Node, node_name: String, icon_name: String, action: Callable, index: int, count: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.icon = load("res://assets/ui/%s.svg" % icon_name)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.custom_minimum_size = Vector2(28, 28)
	button.size = button.custom_minimum_size
	button.position = Vector2(index * 28, 0)
	button.add_theme_constant_override("icon_max_width", 14)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.32))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("E2E8F1") if state == "hover" else Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 14)
		style.set_content_margin_all(0)
		style.corner_radius_top_left = 14 if index == 0 else 0
		style.corner_radius_bottom_left = 14 if index == 0 else 0
		style.corner_radius_top_right = 14 if index == count - 1 else 0
		style.corner_radius_bottom_right = 14 if index == count - 1 else 0
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


## 说明与状态统一放入只读指引，打开时先结束绘制并收起其他菜单。
func _show_guide() -> void:
	_map_view.finish_interaction()
	_actions_menu.close_menu(false)
	_guide_menu.popup_at(_guide_button)


## 缩放到边界后禁用对应入口，提示文字继续使用统一的本土化悬浮卡片。
func _update_zoom_buttons(_value: float) -> void:
	_zoom_out_button.disabled = not _map_view.can_zoom_out()
	_zoom_in_button.disabled = not _map_view.can_zoom_in()
	_zoom_out_button.tooltip_text = tr("缩小地图")
	_zoom_in_button.tooltip_text = tr("放大地图")
	_guide_button.tooltip_text = tr("指引")


## 下拉菜单复用保存与校验入口，不更改地图历史或文件路径。
func _show_actions_menu() -> void:
	_map_view.finish_interaction()
	_guide_menu.close_menu(false)
	_actions_menu.popup_at(_header.more_button)


## CanvasLayer 不继承编辑器的隐藏状态；进入试玩前主动收起菜单，避免遮住游戏页。
func _on_editor_visibility_changed() -> void:
	if not is_visible_in_tree() and _actions_menu != null:
		_actions_menu.close_menu(false)
		_guide_menu.close_menu(false)


## 语言切换只更新界面名称和提示，不重填输入框、绘制选择或地图数据。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		var display_path := editor_document.path if not editor_document.path.is_empty() else tr("未保存的地图")
		_file_label.text = ("* " if editor_document.is_dirty() else "") + display_path
		_file_label.tooltip_text = tr("打开地图") + "\n" + display_path
		_update_zoom_buttons(_map_view.zoom)
		_refresh_drawing_item_labels()


# 用途：创建文件选择、未保存确认、错误提示和元数据输入对话框。
func _build_dialogs() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	# macOS/Windows 优先使用系统文件窗口；不支持原生窗口的平台自动使用圆角后备界面。
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.json ; JSON ; application/json"])
	_file_dialog.current_dir = ProjectSettings.globalize_path("res://data/maps")
	_file_dialog.file_selected.connect(_on_file_selected)
	_file_dialog.canceled.connect(_on_file_canceled)
	add_child(_file_dialog)
	GameTheme.style_guide_dialog(_file_dialog)
	_dirty_dialog = ConfirmationDialog.new()
	_dirty_dialog.title = "尚有未保存的修改"
	_dirty_dialog.ok_button_text = "放弃修改并继续"
	_dirty_dialog.cancel_button_text = "取消"
	_dirty_dialog.confirmed.connect(_run_pending_action)
	add_child(_dirty_dialog)
	GameTheme.style_guide_dialog(_dirty_dialog)
	_message_dialog = AcceptDialog.new()
	add_child(_message_dialog)
	GameTheme.style_guide_dialog(_message_dialog)
	_metadata_dialog = ConfirmationDialog.new()
	_metadata_dialog.title = "地图元数据（JSON）"
	_metadata_dialog.ok_button_text = "校验并应用"
	_metadata_dialog.cancel_button_text = "取消"
	_metadata_dialog.dialog_hide_on_ok = false
	_metadata_dialog.confirmed.connect(_apply_metadata)
	# 普通 Control 隔断自动换行标签的瞬时最小高度，避免首次打开时撑大整个窗口。
	var content := Control.new()
	content.clip_contents = true
	_metadata_dialog.add_child(content)
	var body := VBoxContainer.new()
	content.add_child(body)
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 8)
	var explanation := Label.new()
	explanation.text = "objects 支持限时闸门、障碍物、监狱警报与安全门；enemies 支持接近攻击与警卫。player_spawn 可设为 null。\n模块使用 module_id 和 offset；extra 保存未知的顶层字段。"
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.add_theme_font_size_override("font_size", 12)
	body.add_child(explanation)
	_metadata_text = CodeEdit.new()
	# 地图 JSON 属于作者数据；界面语言切换不能改写编辑器中的源文本。
	_metadata_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_metadata_text.add_theme_font_size_override("font_size", 14)
	# CodeEdit 原生滚动条承接长 JSON；内容长度不参与弹窗尺寸计算。
	_metadata_text.scroll_fit_content_height = false
	_metadata_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_metadata_text.gutters_draw_line_numbers = true
	body.add_child(_metadata_text)
	add_child(_metadata_dialog)
	GameTheme.style_guide_dialog(_metadata_dialog)
	for button in [_metadata_dialog.get_cancel_button(), _metadata_dialog.get_ok_button()]:
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			var pill := button.get_theme_stylebox(state).duplicate() as StyleBoxFlat
			pill.set_corner_radius_all(24)
			button.add_theme_stylebox_override(state, pill)
	get_viewport().size_changed.connect(_on_metadata_viewport_resized)


## 元数据窗口按固定紧凑尺寸显示，标题栏和四周留白也计入可见范围。
func _fit_metadata_dialog() -> void:
	var frame := _metadata_dialog.get_theme_stylebox("embedded_border", "Window") as StyleBoxFlat
	var title_height := roundi(frame.expand_margin_top) if _metadata_dialog.is_embedded() else 0
	var available := Vector2i(get_viewport_rect().size) - Vector2i(32, 32 + title_height)
	_metadata_dialog.size = METADATA_DIALOG_SIZE.min(available)
	_metadata_dialog.position = (Vector2i(get_viewport_rect().size) - _metadata_dialog.size - Vector2i(0, title_height)) / 2 + Vector2i(0, title_height)


## 游戏视口变化时重新约束已打开的弹窗，不重填 JSON 或改变文本编辑状态。
func _on_metadata_viewport_resized() -> void:
	if _metadata_dialog.visible:
		_fit_metadata_dialog()


## 元数据共用全局代码配色，保留原生文本状态；高亮仅识别 JSON，不套用游戏指令。
func _sync_metadata_color() -> void:
	var mode := settings.code_color_mode if settings != null else "light"
	if mode == _metadata_color_mode:
		return
	_metadata_color_mode = mode
	GameTheme.style_code(_metadata_text, mode)
	var palette: Dictionary = GameTheme.CODE_DARK if mode == "dark" else GameTheme.CODE_LIGHT
	var syntax := CodeHighlighter.new()
	syntax.number_color = palette.number
	syntax.symbol_color = palette.symbol
	syntax.add_color_region("\"", "\"", palette.query)
	for keyword in ["true", "false", "null"]:
		syntax.add_keyword_color(keyword, palette.keyword)
	_metadata_text.syntax_highlighter = syntax


# 用途：创建普通工具栏按钮并连接唯一操作入口。
func _add_button(parent: Node, title: String, callback: Callable) -> Button:
	var button := GameTheme.button(parent, title, callback)
	button.custom_minimum_size.y = 32
	return button


# 用途：创建工具栏文字标签，保持界面构建代码简短。
func _add_label(parent: Node, title: String) -> Label:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	return label


# 用途：创建地图标识输入框，用户数据不随界面语言变化。
func _add_line_edit(parent: Node, minimum_width: float) -> LineEdit:
	var field := LineEdit.new()
	field.caret_blink = true
	field.caret_blink_interval = 0.5
	field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	field.custom_minimum_size = Vector2(minimum_width, 32)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(field)
	return field


# 用途：创建有明确范围和步长的数值输入框。
func _add_spin(parent: Node, minimum: float, maximum: float, increment: float, initial: float, keep_trailing_space: bool = true) -> SpinBox:
	var field := SpinBox.new()
	field.get_line_edit().caret_blink = true
	field.get_line_edit().caret_blink_interval = 0.5
	field.min_value = minimum
	field.max_value = maximum
	field.step = increment
	field.value = initial
	field.custom_minimum_size = Vector2(56, 32)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(field)
	if not keep_trailing_space:
		return field
	# 数字框后保留18像素（含行间距），与效果图中的宽高和上限输入框比例一致。
	var trailing_space := Control.new()
	trailing_space.custom_minimum_size.x = 10
	trailing_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(trailing_space)
	return field


# 用途：从注册表生成地块画笔，并查找用于首次创建玩家的移动模块。
func _populate_catalog() -> void:
	_brush.clear()
	_brush_ids.clear()
	_default_module_id = ""
	for tile_id: String in registry.tiles:
		var definition := registry.get_tile(tile_id)
		_brush.add_item(definition.display_name + " (" + tile_id + ")")
		_brush_ids.append(tile_id)
	_brush.add_item("擦除 → void")
	_brush_ids.append("")
	for module_id: String in registry.modules:
		if registry.get_module(module_id).behavior == "MovementModule":
			_default_module_id = module_id
			break
	_refresh_drawing_item_labels()
	_enemy_panel.configure(editor_document, registry)
	_set_paint_mode(_terrain_mode)


## 逐项翻译显示名并保留地块 ID；仅更新文字，切换语言时不改变所选项目或画笔状态。
func _refresh_drawing_item_labels() -> void:
	for index in _brush_ids.size():
		var tile_id := _brush_ids[index]
		if tile_id.is_empty():
			_brush.set_item_text(index, tr("擦除 → void"))
		else:
			var definition := registry.get_tile(tile_id)
			_brush.set_item_text(index, "%s (%s)" % [tr(definition.display_name), tile_id])


# 用途：载入内置内容与用户内容目录，供扩展 JSON 和贴图直接加入目录。
func _load_catalog() -> DataResult:
	return registry.load_directories(
		PackedStringArray(["res://data/modules", "user://data/modules"]),
		PackedStringArray(["res://data/tiles", "user://data/tiles"])
	)


# 用途：原子重载内容定义和贴图；失败时保留旧注册表与当前地图。
func _reload_definitions() -> void:
	_canvas.finish_stroke()
	var result := _load_catalog()
	if not result.is_ok():
		_show_errors("内容重载失败，已保留旧定义", result.errors)
		return
	_populate_catalog()
	_canvas.clear_texture_cache()
	_canvas.refresh()
	var checked := MapCodec.validate(editor_document.document, registry, false)
	if not checked.is_ok():
		_show_errors("内容已重载，当前地图需要修正", checked.errors)
		return
	_status.text = tr("内容已重载：%d 种地块、%d 种模块。") % [registry.tiles.size(), registry.modules.size()]


# 用途：地形与起终点交给同一可撤销文档，点位只允许放在可通行格心。
func _paint_cell(cell: Vector2i, erase: bool) -> void:
	if not editor_document.document.in_bounds(cell):
		return
	if not _point_tool.is_empty():
		var tile := registry.get_tile(editor_document.document.get_tile_id(cell))
		if tile == null or tile.collision:
			_status.text = "出生点需要位于可通行地块；请先绘制地板。" if _point_tool == "spawn" else "终点需要位于可通行地块；请先绘制地板。"
			return
		if _point_tool == "spawn":
			if _default_module_id.is_empty():
				_status.text = "内容目录中没有可用于玩家出生的移动模块。"
				return
			editor_document.place_spawn(cell, _default_module_id)
		else:
			var result := editor_document.place_goal(cell)
			if not result.is_ok():
				_show_errors("无法设置终点", result.errors)
		return
	if _brush.selected >= 0 and _brush.selected < _brush_ids.size():
		editor_document.paint(cell, "" if erase else _brush_ids[_brush.selected])


## 地块框选走批量事务，点位工具不会重复创建起终点或涂改地形。
func _paint_rectangle(area: Rect2i, erase: bool) -> void:
	if not _point_tool.is_empty() or _brush.selected < 0 or _brush.selected >= _brush_ids.size():
		return
	editor_document.paint_rectangle(area, "" if erase else _brush_ids[_brush.selected])


# 用途：同步模型变化到地图、表单、文件标签和历史按钮。
func _on_document_changed() -> void:
	_canvas.document = editor_document.document
	_map_view.refresh_map()
	_syncing_fields = true
	if not _id_field.has_focus():
		_id_field.text = editor_document.document.id
	if not _name_field.has_focus():
		_name_field.text = editor_document.document.display_name
	_width_field.value = editor_document.document.width
	_height_field.value = editor_document.document.height
	_dimension_texts[_width_field] = str(editor_document.document.width)
	_dimension_texts[_height_field] = str(editor_document.document.height)
	_module_limit_field.value = editor_document.get_module_limit()
	if not _player_health_field.has_focus():
		_player_health_text = JSON.stringify(editor_document.get_player_max_health()).trim_suffix(".0")
		_player_health_field.text = _player_health_text
		_player_health_baseline = _player_health_text
		_player_health_edited = false
	if not _time_limit_field.has_focus():
		_time_limit_text = String.num(editor_document.get_time_limit_seconds(), 1).trim_suffix(".0")
		_time_limit_field.text = _time_limit_text
	_syncing_fields = false
	_enemy_panel.sync_from_document()
	if _canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY:
		if editor_document.get_enemies_enabled():
			_canvas.set_enemy_template(editor_document.get_enemy_template(registry))
		else:
			_cancel_point_tool()
	var display_path := editor_document.path if not editor_document.path.is_empty() else tr("未保存的地图")
	_file_label.text = ("* " if editor_document.is_dirty() else "") + display_path
	_file_label.tooltip_text = tr("打开地图") + "\n" + display_path
	_update_history_buttons()


# 用途：把当前 ID 与名称输入提交为一个可撤销操作。
func _commit_identity() -> void:
	if _syncing_fields:
		return
	if editor_document.document.id == _id_field.text and editor_document.document.display_name == _name_field.text:
		return
	editor_document.set_identity(_id_field.text, _name_field.text)


# 用途：在名称或标识输入框按回车时提交身份信息。
func _on_identity_submitted(_text: String) -> void:
	_commit_identity()


# 用途：数值改变立即提交一次文档事务；模型回填控件时不反向改写地图。
func _on_module_limit_changed(value: float) -> void:
	if _syncing_fields:
		return
	_canvas.finish_stroke()
	var result := editor_document.set_module_limit(int(value))
	if not result.is_ok():
		_on_document_changed()
		_show_errors("无法修改模块上限", result.errors)
		return
	_status.text = tr("模块数量上限已设为 %d。") % int(value)


# 用途：保存、返回和测试前提交尚未失焦的玩家数值，避免快捷键遗漏输入。
func _commit_module_limit() -> void:
	# SpinBox 的显示文本可能晚于 value 更新；无焦点时重新 apply 会把旧文本写回。
	# 失焦由控件自行提交，这里只补上 Ctrl+S 等不会切换焦点的操作。
	if _module_limit_field.get_line_edit().has_focus():
		_module_limit_field.apply()
	if _player_health_field.has_focus():
		_commit_player_health()
	if _enemy_panel != null:
		_enemy_panel.commit_fields()


## 耐久输入只接收有限正数，保留临时空白和0前缀以便输入小于1的小数。
func _on_player_health_text_changed(text: String) -> void:
	if _syncing_fields:
		return
	if text in ["", "0", "0.", "."]:
		_player_health_edited = true
		return
	if _valid_player_health_text(text):
		_player_health_edited = true
		_player_health_text = text
		return
	_player_health_field.text = _player_health_text
	_player_health_field.caret_column = _player_health_field.text.length()


## 仅访问旧地图的默认显示值不会写入覆盖；真正键入同值仍可显式设置耐久。
func _begin_player_health_edit() -> void:
	_player_health_baseline = _player_health_field.text
	_player_health_edited = false


## 与地图数据层采用相同正数范围，不把非数值或无穷大写入地图。
func _valid_player_health_text(text: String) -> bool:
	if not text.is_valid_float():
		return false
	var health := text.to_float()
	return is_finite(health) and health > 0.0 and health <= 1000000000.0


## 回车与失焦共用一次可撤销提交。
func _on_player_health_submitted(_text: String) -> void:
	_commit_player_health()


## 无效或空白输入恢复文档值；合法设置保存为本地图的玩家模块耐久覆盖。
func _commit_player_health() -> void:
	if _syncing_fields or _player_health_field == null:
		return
	var text := _player_health_field.text
	if (_player_health_edited or text != _player_health_baseline) and _valid_player_health_text(text):
		_canvas.finish_stroke()
		var result := editor_document.set_player_max_health(text.to_float())
		if not result.is_ok():
			_show_errors("无法修改玩家耐久度", result.errors)
	_player_health_text = JSON.stringify(editor_document.get_player_max_health()).trim_suffix(".0")
	_player_health_field.text = _player_health_text
	_player_health_baseline = _player_health_text
	_player_health_edited = false


# 用途：应用地图尺寸；被裁剪的数据可以用撤销恢复。
func _resize_document() -> void:
	_canvas.finish_stroke()
	# 焦点内读取尚未提交的文本，失焦后使用已提交数值；两条路径都再次校验范围。
	var values: Array[int] = []
	for field in [_width_field, _height_field]:
		var text: String = field.get_line_edit().text.strip_edges() if field.get_line_edit().has_focus() else str(int(field.value))
		if not text.is_valid_int() or text.to_int() < 1 or text.to_int() > 64:
			_show_errors("无法应用尺寸", PackedStringArray(["宽和高只能输入 1～64 的整数。"]))
			return
		values.append(text.to_int())
	var new_width := values[0]
	var new_height := values[1]
	for field: String in ["enemies", "objects"]:
		for entity: Dictionary in editor_document.document.get(field):
			var position: Dictionary = entity.get("position", {})
			if field == "objects":
				var checked := MapObjectDefinition.validate(entity, Vector2i(new_width, new_height))
				if not checked.is_ok():
					_show_errors("无法缩小地图", checked.errors)
					return
			if float(position.get("x", 0)) >= new_width or float(position.get("y", 0)) >= new_height:
				_show_errors("无法缩小地图", PackedStringArray(["%s 中有对象位于新范围外。请先通过元数据移动或删除这些对象。" % field]))
				return
	editor_document.resize(new_width, new_height)
	_status.text = "地图尺寸已更新；范围外的地块、起点与终点会被移除。可撤销恢复。"


# 用途：清除玩家出生配置，保留地块和其它地图内容。
func _clear_spawn() -> void:
	_canvas.finish_stroke()
	editor_document.clear_spawn()
	_status.text = "出生点已移除。草稿仍可保存，开始测试前需要重新放置出生点。"


## 重置终点只移除终点目标，完整保留当前地形、出生点与其它地图数据。
func _clear_goal() -> void:
	_canvas.finish_stroke()
	editor_document.clear_goal()
	_status.text = "终点已重置。可重新放置，或保留为没有终点的自由测试地图。"


# 用途：改变画布显示比例，不修改地图单位或机器尺寸。
func _set_zoom(value: float) -> void:
	_map_view.set_zoom(value / MapEditorViewport.BASE_CELL_SIZE)


# 用途：撤销一次地图修改。
func _undo() -> void:
	_canvas.finish_stroke()
	if editor_document.undo():
		_status.text = "已撤销。"


# 用途：重做一次地图修改。
func _redo() -> void:
	_canvas.finish_stroke()
	if editor_document.redo():
		_status.text = "已重做。"


# 用途：在替换文档或关闭窗口前统一保护未保存的修改。
func _request_action(action: String) -> void:
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	_commit_identity()
	_pending_action = action
	if editor_document.is_dirty():
		_dirty_dialog.dialog_text = "当前地图尚未保存。继续将放弃这些修改；取消后可以先保存。"
		_dirty_dialog.popup_centered(Vector2i(480, 180))
	else:
		_run_pending_action()


# 用途：执行已通过未保存检查的新建、打开或退出动作。
func _run_pending_action() -> void:
	var action := _pending_action
	_pending_action = ""
	match action:
		"new":
			_new_document()
		"open":
			_file_operation = "open"
			_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_file_dialog.title = "打开地图"
			_file_dialog.popup_centered_ratio(0.75)
		"quit":
			get_tree().quit()


# 用途：创建仅包含 void 的空白草稿，地图可在尚未放置出生点时保存。
func _new_document() -> void:
	var document := MapDocument.new()
	document.id = "untitled"
	document.display_name = "新地图"
	document.width = 16
	document.height = 12
	document.properties = {"level": {"max_ticks": 600, "completion_mode": "reach_or_clear", "player_max_health": 1.0}}
	editor_document.replace_document(document)
	_map_view.reset_view()
	_status.text = "空白地图已创建。绘制地板后，用场景玩法与行为控制放置起点；终点可按需添加。"


# 用途：校验并载入地图草稿；任何读取错误都不会替换当前文档。
func _load_document(path: String) -> void:
	var result: DataResult = MapCodec.load_file(path, registry, false)
	if not result.is_ok():
		_show_errors("无法打开地图", result.errors)
		return
	editor_document.replace_document(result.value as MapDocument, path)
	_map_view.reset_view()
	_status.text = "已打开地图。所有未指定地块均为 void。"


# 用途：保存当前草稿，首次保存或另存为时先选择目标文件。
func _save_document(save_as: bool) -> void:
	_canvas.finish_stroke()
	_commit_time_limit()
	_commit_module_limit()
	_commit_identity()
	if save_as or editor_document.path.is_empty():
		_file_operation = "save"
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.title = "保存地图"
		_file_dialog.current_file = editor_document.document.id.validate_filename() + ".json"
		_file_dialog.popup_centered_ratio(0.75)
	else:
		_write_document(editor_document.path)


# 用途：将文件选择结果分派给载入或写盘流程。
func _on_file_selected(path: String) -> void:
	var operation := _file_operation
	_file_operation = ""
	if operation == "open":
		_load_document(path)
	else:
		_write_document(path)


## 取消保存位置选择也结束本次保存请求，不能让后续普通保存误触退出。
func _on_file_canceled() -> void:
	var operation := _file_operation
	_file_operation = ""
	if operation == "save":
		save_finished.emit(false)


# 用途：通过统一编解码器写盘，只有保存成功才清除未保存标记。
func _write_document(path: String) -> void:
	_commit_time_limit()
	_commit_module_limit()
	var result: DataResult = MapCodec.save_file(editor_document.document, path, registry, false)
	if not result.is_ok():
		_show_errors("无法保存地图", result.errors)
		save_finished.emit(false)
		return
	editor_document.mark_saved(path)
	_status.text = tr("地图已保存：") + path
	save_finished.emit(true)


# 用途：与游戏关卡入口共用数据规则；玩家实际装配的占地留到确认装配时检查。
func _validate_document() -> void:
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	_commit_identity()
	var result := _test_level_definition()
	if not result.is_ok():
		_show_errors("地图暂不可运行", result.errors)
		return
	_status.text = "校验通过：地图与关卡规则有效；最终模块占地将在确认装配时检查。"


# 用途：将地图扩展数据呈现为可编辑 JSON，不依赖尚未制作的专门 UI。
func _open_metadata() -> void:
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	_fit_metadata_dialog()
	_metadata_dialog.popup()
	# 原生滚动条可见后才能同步首行缓存；同帧复位再换文本，避免旧长文档的行号越界。
	_metadata_text.scroll_vertical = 0
	_metadata_text.scroll_horizontal = 0
	_metadata_text.text = JSON.stringify(editor_document.metadata_dict(), "\t", true)


# 用途：解析并校验元数据副本，全部通过后再修改正式文档。
func _apply_metadata() -> void:
	var parser := JSON.new()
	if parser.parse(_metadata_text.text) != OK:
		_show_errors("JSON 解析失败", PackedStringArray(["第 %d 行：%s" % [parser.get_error_line(), parser.get_error_message()]]))
		return
	if not parser.data is Dictionary:
		_show_errors("元数据无效", PackedStringArray(["元数据必须是 JSON 对象。 "]))
		return
	var data: Dictionary = parser.data
	var shape_errors := PackedStringArray()
	for key: String in data:
		if key not in ["player_spawn", "enemies", "objects", "dialogue", "properties", "extra"]:
			shape_errors.append("未知元数据项 '%s'；扩展字段请写入 extra。" % key)
	for key: String in ["enemies", "objects", "dialogue"]:
		if data.has(key) and not data[key] is Array:
			shape_errors.append(key + " 必须是数组。")
	for key: String in ["properties", "extra"]:
		if data.has(key) and not data[key] is Dictionary:
			shape_errors.append(key + " 必须是对象。")
	if data.get("extra") is Dictionary:
		for key: String in data.extra:
			if key in MapCodec.KNOWN_FIELDS:
				shape_errors.append("extra 不能覆盖保留字段：" + key)
	if data.has("player_spawn") and data.player_spawn != null and not data.player_spawn is Dictionary:
		shape_errors.append("player_spawn 必须是对象或 null。")
	if not shape_errors.is_empty():
		_show_errors("元数据无效", shape_errors)
		return
	var candidate := MapEditorDocument.new()
	candidate.replace_document(editor_document.document)
	candidate.apply_metadata(data)
	var result: DataResult = MapCodec.validate(candidate.document, registry, false)
	if not result.is_ok():
		_show_errors("元数据校验失败", result.errors)
		return
	editor_document.apply_metadata(data)
	_metadata_dialog.hide()
	_status.text = "元数据已应用。开始测试将使用当前地图与关卡规则进入组装和编程。"


## 旧地图缺省限时仅补到测试快照，不因校验或试玩修改原文档与撤销历史。
func _test_level_definition() -> DataResult:
	var candidate := MapEditorDocument.new()
	candidate.replace_document(editor_document.document)
	var timer := candidate.set_time_limit_seconds(editor_document.get_time_limit_seconds())
	if not timer.is_ok():
		return timer
	return LevelDefinition.from_document(candidate.document, registry, editor_document.path)


# 用途：构建关卡快照并请求外层进入正常游戏流程，不在编辑器内创建模拟世界。
func _start_playtest() -> void:
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	_commit_identity()
	var result := _test_level_definition()
	if not result.is_ok():
		_show_errors("无法开始测试", result.errors)
		return
	_status.text = "测试将进入组装和编程；返回编辑器后可继续修改地图。"
	playtest_requested.emit(result.value as LevelDefinition, registry)


# 用途：仅按文档历史决定撤销与重做按钮状态，编辑器不持有局部试玩模式。
func _update_history_buttons() -> void:
	_undo_button.disabled = not editor_document.can_undo()
	_redo_button.disabled = not editor_document.can_redo()


# 用途：同时显示简要状态和详细错误列表，便于修正数据问题。
func _show_errors(title: String, errors: PackedStringArray) -> void:
	_status.text = title + "：" + (errors[0] if not errors.is_empty() else "未知错误")
	_message_dialog.title = title
	_message_dialog.dialog_text = "\n".join(errors.slice(0, 20))
	_message_dialog.popup_centered(Vector2i(660, 260))
