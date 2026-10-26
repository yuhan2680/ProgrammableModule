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
# 新图可由外壳注入玩家署名；载入已有地图仍保留其原作者。
var default_creator: String = ""
var player_levels_directory: String = "user://levels"
var initial_map_path: String = ""
var initial_map_opened := false
var initial_map_error := PackedStringArray()
var _managed_save_path: String = ""
var _assigned_new_id: String = ""

var _canvas: MapEditorCanvas
var _map_view: MapEditorViewport
var _zoom_out_button: Button
var _zoom_in_button: Button
var _guide_button: Button
var _guide_menu: WorkbenchGuideMenu
var _status: Label
var _header: MapEditorHeader
var _actions_menu: MapEditorActionsMenu
var _id_field: LineEdit
var _name_field: LineEdit
var _subtitle_field: LineEdit
var _creator_field: LineEdit
var _identity_uncommitted := false
var _identity_source: MapDocument
var _level_guide_button: Button
var _level_guide_editor: MapGuideEditor
var _width_field: SpinBox
var _height_field: SpinBox
var _dimension_texts: Dictionary = {}
var _time_limit_field: LineEdit
var _time_limit_text := "60"
var _gate_add_button: Button
var _gate_remove_button: Button
var _gate_timer_field: LineEdit
var _new_gate_seconds := MapEditorTimedGate.DEFAULT_SECONDS
var _gate_timer_text := "6"
var _gate_timer_baseline := "6"
var _gate_timer_edited := false
var _gate_document: MapDocument
var _gate_edit_source: MapDocument
var _gate_edit_target := ""
var _module_limit_field: SpinBox
var _restriction_choice: ModuleRestrictionChoice
var _restriction_picker: ModuleRestrictionPicker
var _command_button: Button
var _command_menu: CommandRestrictionMenu
var _allow_code_hints_switch: SettingsSwitch
var _restrict_code_paste_switch: SettingsSwitch
var _restrict_code_paste_label: Label
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
var _save_level_button: Button
var _test_feedback: Label
var _test_feedback_errors := PackedStringArray()
var _test_validation_active := false
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
var _properties_card: PanelContainer
var _presentation_scale := 1.0
var _properties_workspace: Control


# 用途：先载入内容目录；明确指定时打开已有地图，普通入口创建独立空白草稿。
func _ready() -> void:
	_build_ui()
	if settings != null:
		settings.changed.connect(_sync_metadata_color)
		settings.changed.connect(_refresh_test_feedback)
	_sync_metadata_color()
	editor_document.changed.connect(_on_document_changed)
	var content_result: DataResult = _load_catalog()
	_populate_catalog()
	_canvas.registry = registry
	if not content_result.is_ok():
		_new_document()
		if initial_map_path.is_empty():
			_show_errors("内容加载失败", content_result.errors)
		else:
			initial_map_error = content_result.errors.duplicate()
		return
	if not initial_map_path.is_empty():
		initial_map_opened = _load_document(initial_map_path, false)
		if not initial_map_opened:
			_new_document()
	else:
		_new_document()


## 外壳负责编辑页整体几何；独立窗口和浮层同步显示比例，不修改地图、视图缩放或编辑历史。
func set_presentation_scale(factor: float) -> void:
	_presentation_scale = maxf(1.0, factor)
	if not is_node_ready():
		return
	_header.set_presentation_scale(_presentation_scale)
	for dialog: Window in [_dirty_dialog, _message_dialog, _metadata_dialog]:
		dialog.content_scale_factor = _presentation_scale
	for menu in [_actions_menu, _guide_menu, _restriction_picker, _command_menu, _enemy_panel._picker]:
		if menu.is_open():
			menu._update_placement.call_deferred()
	if _level_guide_editor.is_open():
		_level_guide_editor._layout_dialog.call_deferred()
	if _metadata_dialog.visible:
		_fit_metadata_dialog.call_deferred()


# 用途：提供常见保存和撤销快捷键，文本编辑控件仍使用自身的撤销操作。
func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey or not event.pressed or event.echo:
		return
	if not (event.ctrl_pressed or event.meta_pressed) or _metadata_dialog.visible or _file_dialog.visible or _dirty_dialog.visible or _actions_menu.is_open() or _guide_menu.is_open() or _level_guide_editor.is_open() or _restriction_picker.is_open() or _command_menu.is_open():
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
	_actions_menu.open_requested.connect(_request_action.bind("open"))
	_actions_menu.save_as_requested.connect(_save_document.bind(true))
	_actions_menu.validate_requested.connect(_validate_document)
	_actions_menu.metadata_requested.connect(_open_metadata)
	visibility_changed.connect(_on_editor_visibility_changed)
	# 打开入口统一放在更多菜单，路径不再单独占据工作区上方一行。
	_header.title_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	# 地图区吸收剩余宽度，属性卡片只取表单所需宽度，不提供可拖动分隔线。
	var workspace := HBoxContainer.new()
	workspace.name = "MapEditorWorkspace"
	workspace.add_theme_constant_override("separation", 12)
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(workspace)
	var map_panel := Control.new()
	map_panel.name = "MapEditorMapRegion"
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.custom_minimum_size.x = 360
	workspace.add_child(map_panel)
	var map_area := Control.new()
	map_area.name = "MapEditorMapArea"
	map_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_panel.add_child(map_area)
	map_area.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_view = MapEditorViewport.new()
	_map_view.name = "MapEditorViewport"
	map_area.add_child(_map_view)
	_map_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas = _map_view.canvas
	_canvas.point_placement_cancelled.connect(_cancel_point_tool)
	_canvas.enemy_placement_cancelled.connect(_cancel_point_tool)
	_canvas.enemy_placement_requested.connect(_place_enemy)
	_canvas.enemy_selection_requested.connect(_on_enemy_selection_requested)
	_canvas.paint_mode_changed.connect(_sync_enemy_remove_button)
	_canvas.timed_gate_selected.connect(_select_timed_gate)
	_canvas.timed_gate_placement_requested.connect(_place_timed_gate)
	_canvas.timed_gate_removal_requested.connect(_remove_timed_gate)
	_canvas.timed_gate_tool_cancelled.connect(_cancel_point_tool)
	_canvas.stroke_started.connect(editor_document.begin_action)
	_canvas.cell_requested.connect(_paint_cell)
	_canvas.rectangle_requested.connect(_paint_rectangle)
	_canvas.stroke_finished.connect(editor_document.end_action)
	_build_map_controls()
	_build_properties(workspace)
	_build_dialogs()
	_update_history_buttons()
	var focus_handler := preload("res://scripts/ui/map_editor_properties_focus.gd").new()
	focus_handler.name = "MapEditorPropertiesFocus"
	focus_handler.configure(self, _properties_card, _property_focus_blocked)
	focus_handler.card_blank_clicked.connect(_on_property_card_blank_clicked)
	add_child(focus_handler)


## 卡片空白结束闸门及敌人框选工具；输入控件和地图点击仍保留连续放置。
func _on_property_card_blank_clicked() -> void:
	if _canvas.paint_mode in [MapEditorCanvas.PaintMode.GATE_ADD, MapEditorCanvas.PaintMode.GATE_REMOVE, MapEditorCanvas.PaintMode.ENEMY_SELECT]:
		_cancel_point_tool()


## 浮层内部和模态窗口的点击不改变背景表单；收起后的空白点击可正常取消焦点。
func _property_focus_blocked(include_menus: bool = true) -> bool:
	if _file_dialog.visible or _dirty_dialog.visible or _message_dialog.visible or _metadata_dialog.visible or _level_guide_editor.is_open():
		return true
	return include_menus and (_actions_menu.is_open() or _guide_menu.is_open() or _restriction_picker.is_open() or _command_menu.is_open() or _enemy_panel._picker.is_open() or _brush.get_popup().visible)


## 属性宽度由工作区约束，表单按文字和控件需要纵向重排，滚动条保留独立留白。
func _build_properties(workspace: Control) -> void:
	_properties_workspace = workspace
	workspace.resized.connect(_layout_properties_width)
	var card := PanelContainer.new()
	_properties_card = card
	card.name = "MapEditorPropertiesCard"
	card.custom_minimum_size.x = 340
	card.theme = _properties_theme()
	var surface := GameTheme.card()
	# 底部操作与白卡等距内缩，按钮圆角为白卡半径减去内缩，两个圆心保持重合。
	var footer_inset := 8
	surface.set_content_margin_all(footer_inset)
	card.add_theme_stylebox_override("panel", surface)
	workspace.add_child(card)
	var layout := VBoxContainer.new()
	layout.name = "MapEditorPropertiesLayout"
	layout.add_theme_constant_override("separation", 8)
	card.add_child(layout)
	var body_inset := MarginContainer.new()
	body_inset.name = "MapEditorPropertiesBodyInset"
	body_inset.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_inset.add_theme_constant_override("margin_left", 10)
	body_inset.add_theme_constant_override("margin_right", 2)
	body_inset.add_theme_constant_override("margin_top", 6)
	layout.add_child(body_inset)
	var scroll := ScrollContainer.new()
	scroll.name = "MapEditorPropertiesScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 固定保留滚动条位置，透明淡出时表单和居中的名称行不会左右跳动。
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	scroll.follow_focus = true
	var content_fade := preload("res://scripts/ui/map_editor_properties_fade.gd").new()
	content_fade.name = "MapEditorPropertiesFade"
	body_inset.add_child(content_fade)
	content_fade.set_scroll(scroll)
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
	GameTheme.label(fields, "地图属性", 16).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 右侧包含卡片内边距、滚动条和留白；在名称行左侧补齐相同的总距离。
	var identity_inset := 10 + 18 + scroll.get_v_scroll_bar().get_combined_minimum_size().x - 18
	_build_identity_fields(fields, identity_inset)
	_build_subtitle_field(fields, identity_inset)
	_build_creator_field(fields, identity_inset)
	_property_gap(fields, 6)
	_build_dimensions(fields)
	_property_gap(fields, 12)
	_build_scene_controls(fields)
	_property_gap(fields, 12)
	_build_enemy_controls(fields)
	_property_gap(fields, 12)
	_test_feedback = GameTheme.label(layout, "", 12)
	_test_feedback.name = "MapEditorTestFeedback"
	_test_feedback.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_test_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_test_feedback.add_theme_color_override("font_color", Color("bb3434"))
	_test_feedback.hide()
	var actions := ResponsivePropertyRow.new()
	actions.name = "MapEditorFooterActions"
	actions.group_sizes = [1, 1]
	actions.equal_width = true
	actions.add_theme_constant_override("separation", 16)
	layout.add_child(actions)
	_play_button = _add_button(actions, "开始测试", _start_playtest)
	_play_button.name = "MapEditorStartTest"
	_play_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_level_button = _add_button(actions, "保存关卡", _save_document.bind(false))
	_save_level_button.name = "MapEditorSaveLevel"
	_save_level_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	GameTheme.primary(_save_level_button)
	# 主操作仍保留蓝色，仅缩小其本地留白，不影响其他页面的按钮样式。
	for button in [_play_button, _save_level_button]:
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			var style := _compact_field_style(button.get_theme_stylebox(state)) as StyleBoxFlat
			style.set_corner_radius_all(surface.corner_radius_bottom_right - footer_inset)
			button.add_theme_stylebox_override(state, style)
	_layout_properties_width.call_deferred()


## 属性卡优先保留地图画幅，长翻译和字号只增加内部行高，不改变可用横向预算。
func _layout_properties_width() -> void:
	if not is_instance_valid(_properties_card) or not is_instance_valid(_properties_workspace):
		return
	var available := _properties_workspace.size.x
	var width := minf(clampf(available * 0.36, 340.0, 460.0), maxf(240.0, available - 372.0))
	_properties_card.custom_minimum_size.x = floorf(width)


## 名称和 ID 共用一行及等宽输入框，缩小字号和高度，整行相对卡片左右对称。
func _build_identity_fields(parent: Node, leading_inset: float) -> void:
	var margin := MarginContainer.new()
	margin.name = "MapEditorIdentityMargin"
	margin.add_theme_constant_override("margin_left", maxi(0, roundi(leading_inset)))
	parent.add_child(margin)
	var identity := ResponsivePropertyRow.new()
	identity.name = "MapEditorIdentityRow"
	identity.group_sizes = [2, 2]
	identity.add_theme_constant_override("separation", 6)
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
		if caption == "名称":
			_name_field = field
			field.focus_exited.connect(_commit_identity)
			field.text_submitted.connect(_on_identity_submitted)
			field.text_changed.connect(_on_identity_text_changed)
		else:
			_id_field = field
			field.name = "MapEditorIdField"
			field.editable = false
			field.context_menu_enabled = false
			field.selecting_enabled = true
			field.theme_changed.connect(_fit_id_field_width.call_deferred)
			_fit_id_field_width()


## 为完整十位 ID 留出实际文字宽度，随字号变化重算；旧长 ID 不会把属性卡片无限撑宽。
func _fit_id_field_width() -> void:
	if not is_instance_valid(_id_field):
		return
	var font := _id_field.get_theme_font("font")
	var font_size := _id_field.get_theme_font_size("font_size")
	var width := 0.0
	for digit in range(10):
		width = maxf(width, font.get_string_size("map_" + str(digit).repeat(10), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var style := _id_field.get_theme_stylebox("read_only")
	_id_field.custom_minimum_size.x = ceilf(width + style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT) + 1)


## 副标题独占身份字段第二排，闪烁光标、留白和焦点提交沿用原生文字输入框。
func _build_subtitle_field(parent: Node, leading_inset: float) -> void:
	var margin := MarginContainer.new()
	margin.name = "MapEditorSubtitleMargin"
	margin.add_theme_constant_override("margin_left", maxi(0, roundi(leading_inset)))
	parent.add_child(margin)
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorSubtitleRow"
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)
	var caption := GameTheme.label(row, "副标题", 12)
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_subtitle_field = _add_line_edit(row, 76)
	_subtitle_field.name = "MapEditorSubtitleField"
	# 先过滤再限长，避免原生 max_length 把粘贴中的表情算入合法文字额度。
	_subtitle_field.max_length = 0
	_subtitle_field.custom_minimum_size.y = 26
	GameTheme.font_size(_subtitle_field, "font_size", 12)
	_subtitle_field.add_theme_constant_override("minimum_character_width", 0)
	_subtitle_field.tooltip_text = "最多 70 个字符，支持文字、数字和常用标点，不支持表情。留空时显示默认目标说明。"
	for state: StringName in ["normal", "focus", "read_only"]:
		var style := _subtitle_field.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.content_margin_left = 6
		style.content_margin_right = 6
		_subtitle_field.add_theme_stylebox_override(state, style)
	_subtitle_field.focus_exited.connect(_commit_identity)
	_subtitle_field.text_submitted.connect(_on_identity_submitted)
	_subtitle_field.text_changed.connect(_on_subtitle_text_changed)


## 过滤键入和粘贴的非法字符并映射光标位置，不把中间编辑的光标跳到整行末尾。
func _on_subtitle_text_changed(text: String) -> void:
	if _syncing_fields:
		return
	var filtered := DataValidation.filter_level_subtitle(text)
	if filtered != text:
		var caret := DataValidation.filter_level_subtitle(text.substr(0, _subtitle_field.caret_column)).length()
		_subtitle_field.text = filtered
		_subtitle_field.caret_column = mini(caret, filtered.length())
	_identity_uncommitted = true


## 创作者位于副标题下方，沿用同尺寸浅色药丸输入框，内容不参与本土化。
func _build_creator_field(parent: Node, leading_inset: float) -> void:
	var margin := MarginContainer.new()
	margin.name = "MapEditorCreatorMargin"
	margin.add_theme_constant_override("margin_left", maxi(0, roundi(leading_inset)))
	parent.add_child(margin)
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorCreatorRow"
	row.group_sizes = [2, 2]
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)
	var caption := GameTheme.label(row, "创作者", 12)
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_creator_field = _add_line_edit(row, 76)
	_creator_field.name = "MapEditorCreatorField"
	# 保留完整粘贴内容与旧地图长署名，提交校验负责拒绝而不是输入时截断。
	_creator_field.max_length = 0
	_creator_field.custom_minimum_size.y = 26
	_creator_field.add_theme_font_size_override("font_size", 12)
	_creator_field.add_theme_constant_override("minimum_character_width", 0)
	for state: StringName in ["normal", "focus", "read_only"]:
		var style := _creator_field.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.content_margin_left = 6
		style.content_margin_right = 6
		_creator_field.add_theme_stylebox_override(state, style)
	_creator_field.focus_exited.connect(_commit_identity)
	_creator_field.text_submitted.connect(_on_identity_submitted)
	_creator_field.text_changed.connect(_on_identity_text_changed)
	var guide_label := GameTheme.label(row, "关卡引导", 12)
	guide_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_level_guide_button = _view_button(row, "MapEditorLevelGuideButton", "assembly_add", _open_level_guide, 0, 1)
	_level_guide_button.tooltip_text = tr("编辑关卡引导")
	var guide_button_surface := GameTheme.box(GameTheme.SURFACE, Color.TRANSPARENT, 14)
	guide_button_surface.set_content_margin_all(0)
	_level_guide_button.add_theme_stylebox_override("normal", guide_button_surface)


## 作者从属性行打开分页引导编辑，先提交身份表单并结束地图笔画。
func _open_level_guide() -> void:
	_map_view.finish_interaction()
	if not _commit_identity():
		return
	_actions_menu.close_menu(false)
	_guide_menu.close_menu(false)
	_command_menu.close_menu(false)
	_level_guide_editor.open_document(editor_document, _level_guide_button, _map_view)


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
	var dimensions := ResponsivePropertyRow.new()
	dimensions.name = "MapEditorDimensions"
	dimensions.group_sizes = [1, 1, 1]
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
	_build_timed_gate_controls(body)


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
	var toolbar := ResponsivePropertyRow.new()
	toolbar.name = "MapEditorPaintTools"
	toolbar.group_sizes = [1, 1]
	toolbar.add_theme_constant_override("separation", 10)
	parent.add_child(toolbar)
	var modes := ResponsivePropertyRow.new()
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
	var drawing := ResponsivePropertyRow.new()
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
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorPointAndResetRows"
	row.group_sizes = [1, 1]
	row.add_theme_constant_override("separation", 12)
	body.add_child(row)
	var placement_column := VBoxContainer.new()
	placement_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	placement_column.add_theme_constant_override("separation", 10)
	row.add_child(placement_column)
	var placement := ResponsivePropertyRow.new()
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
	_build_code_policy_controls(body)
	_build_module_restrictions(body)
	_build_command_restrictions(body)
	_build_player_limits(body)


## 提示和粘贴规则属于玩法控制，开关与同行标签不混入地形绘制分类。
func _build_code_policy_controls(parent: Control) -> void:
	var hints_row := ResponsivePropertyRow.new()
	hints_row.name = "MapEditorCodeHintsRow"
	hints_row.add_theme_constant_override("separation", 12)
	parent.add_child(hints_row)
	var hints_label := _scene_label(hints_row, "是否启用“代码提示”", "MapEditorCodeHintsLabel")
	hints_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_code_hints_switch = SettingsSwitch.new()
	_allow_code_hints_switch.name = "MapEditorCodeHintsSwitch"
	_allow_code_hints_switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hints_row.add_child(_allow_code_hints_switch)
	_allow_code_hints_switch.toggled.connect(_on_allow_code_hints_toggled)
	var paste_row := ResponsivePropertyRow.new()
	paste_row.name = "MapEditorRestrictCodePasteRow"
	paste_row.add_theme_constant_override("separation", 12)
	parent.add_child(paste_row)
	_restrict_code_paste_label = _scene_label(paste_row, "限制代码区域粘贴", "MapEditorRestrictCodePasteLabel")
	_restrict_code_paste_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_restrict_code_paste_switch = SettingsSwitch.new()
	_restrict_code_paste_switch.name = "MapEditorRestrictCodePasteSwitch"
	_restrict_code_paste_switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	paste_row.add_child(_restrict_code_paste_switch)
	_restrict_code_paste_switch.toggled.connect(_on_restrict_code_paste_toggled)


## 提示开关通过模型事务写入地图；变更失败时表单立即恢复原状态。
func _on_allow_code_hints_toggled(enabled: bool) -> void:
	if _syncing_fields:
		return
	var result := editor_document.set_allow_code_hints(enabled)
	_sync_code_policy_controls()
	if not result.is_ok():
		_show_errors("无法更新代码规则", result.errors)


## 粘贴限制由模型判定是否仍可修改，伪造开关信号也不能改变已有地图。
func _on_restrict_code_paste_toggled(enabled: bool) -> void:
	if _syncing_fields:
		return
	var result := editor_document.set_restrict_code_paste(enabled)
	_sync_code_policy_controls()
	if not result.is_ok():
		_show_errors("无法更新代码规则", result.errors)


## 历史、载入和保存后共同刷新权限；锁定时整项变灰并保留原来的开关位置。
func _sync_code_policy_controls() -> void:
	if _allow_code_hints_switch == null or _restrict_code_paste_switch == null:
		return
	_allow_code_hints_switch.set_pressed_no_signal(editor_document.get_allow_code_hints())
	_restrict_code_paste_switch.set_pressed_no_signal(editor_document.get_restrict_code_paste())
	var locked := editor_document.is_code_paste_policy_locked()
	_restrict_code_paste_switch.disabled = locked
	_restrict_code_paste_switch.mouse_default_cursor_shape = Control.CURSOR_ARROW if locked else Control.CURSOR_POINTING_HAND
	if locked:
		_restrict_code_paste_label.add_theme_color_override("font_color", Color("A1A7B0"))
	else:
		_restrict_code_paste_label.remove_theme_color_override("font_color")
	var explanation := "粘贴限制仅可在首次创建地图时设置，保存后无法更改。" if locked else ""
	_restrict_code_paste_label.tooltip_text = explanation
	_restrict_code_paste_switch.tooltip_text = explanation
	_restrict_code_paste_switch.queue_redraw()
	_allow_code_hints_switch.queue_redraw()


## 禁止模块多选位于限时下方，长正文在固定药丸内走字而不扩宽属性面板。
func _build_module_restrictions(parent: Control) -> void:
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorModuleRestrictions"
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	_scene_label(row, "限制使用的模块", "MapEditorRestrictionLabel")
	_restriction_choice = ModuleRestrictionChoice.new()
	_restriction_choice.name = "MapEditorRestrictionChoice"
	_restriction_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_restriction_choice)
	_restriction_choice.pressed.connect(_open_module_restrictions)
	_restriction_picker = ModuleRestrictionPicker.new()
	_restriction_picker.name = "MapEditorRestrictionPicker"
	add_child(_restriction_picker)
	_restriction_picker.restrictions_changed.connect(_on_module_restrictions_changed)


## 打开前结束地图笔画；菜单只处理模块选择，不向背后地图传递点击或快捷键。
func _open_module_restrictions() -> void:
	_map_view.finish_interaction()
	_actions_menu.close_menu(false)
	_guide_menu.close_menu(false)
	_command_menu.close_menu(false)
	_restriction_picker.show_modules(_restriction_choice, registry, editor_document.get_restricted_modules(registry))


## 每次勾选写入一条可撤销事务，失败保留文档与原有效复选状态。
func _on_module_restrictions_changed(ids: Array) -> void:
	var result := editor_document.set_restricted_modules(ids, registry)
	if not result.is_ok():
		_restriction_picker.close_menu(false)
		_show_errors("无法更新模块限制", result.errors)


## 指令管理文字与圆形加号作为一组居中，沿用上下表单的紧凑字号与间隔。
func _build_command_restrictions(parent: Control) -> void:
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorCommandManagement"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_scene_label(row, "管理关卡中允许使用的指令集", "MapEditorCommandManagementLabel")
	_command_button = Button.new()
	_command_button.name = "MapEditorCommandManagementButton"
	# 加号按SVG画布中心对齐，避免字体基线让符号墨迹偏离圆心。
	_command_button.icon = load("res://assets/ui/assembly_add.svg")
	_command_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_command_button.expand_icon = true
	_command_button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_command_button.add_theme_constant_override("icon_max_width", 18)
	_command_button.add_theme_constant_override("h_separation", 0)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		_command_button.add_theme_color_override(state, Color.WHITE)
	_command_button.custom_minimum_size = Vector2(32, 32)
	_command_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_command_button.tooltip_text = "管理关卡中允许使用的指令集"
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var fill := Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color("E2E8F1") if state == "hover" else Color("EAEDF2")
		var surface := GameTheme.box(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 16)
		surface.set_content_margin_all(0)
		_command_button.add_theme_stylebox_override(state, surface)
	row.add_child(_command_button)
	_command_button.pressed.connect(_open_command_restrictions)
	_command_menu = CommandRestrictionMenu.new()
	_command_menu.name = "MapEditorCommandRestrictionMenu"
	add_child(_command_menu)
	_command_menu.command_toggled.connect(_on_command_toggled)


## 指令面板打开前结束绘制与其他浮层，权限开关不向地图传递点击。
func _open_command_restrictions() -> void:
	_map_view.finish_interaction()
	_actions_menu.close_menu(false)
	_guide_menu.close_menu(false)
	_restriction_picker.close_menu(false)
	_enemy_panel._picker.close_menu(false)
	_command_button.release_focus()
	_command_menu.show_commands(_command_button, registry, editor_document.get_enabled_commands(registry), editor_document.get_module_blocked_commands(registry))


## 开启表示允许；文档一次事务处理依赖项，撤销与失败同步回原有效开关状态。
func _on_command_toggled(command_id: String, enabled: bool) -> void:
	var result := editor_document.set_command_enabled(command_id, enabled, registry)
	_sync_command_restrictions()
	if not result.is_ok():
		_command_menu.close_menu(false)
		_show_errors("无法更新指令集", result.errors)


## 历史、载入与注册表重载只同步开关，不在打开旧地图时写入指令权限。
func _sync_command_restrictions() -> void:
	_command_menu.sync_enabled_commands(editor_document.get_enabled_commands(registry), editor_document.get_module_blocked_commands(registry))


## 敌人设置与场景玩法平级，只折叠自身表单，避免玩家设置牵连敌人配置。
func _build_enemy_controls(parent: Control) -> void:
	var section := VBoxContainer.new()
	section.name = "MapEditorEnemyControls"
	section.add_theme_constant_override("separation", 8)
	parent.add_child(section)
	var body := VBoxContainer.new()
	body.name = "MapEditorEnemyControlsBody"
	body.add_theme_constant_override("separation", 14)
	_build_section_heading(section, "敌人攻击方式与行为控制", body, "MapEditorEnemyCollapse")
	section.add_child(body)
	_enemy_panel = MapEditorEnemyPanel.new()
	body.add_child(_enemy_panel)
	_enemy_panel.placement_requested.connect(_select_enemy_tool)
	_enemy_panel.removal_requested.connect(_select_enemy_remove_tool)
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
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorPlayerLimits"
	row.group_sizes = [1, 1]
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var modules := ResponsivePropertyRow.new()
	modules.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	modules.add_theme_constant_override("separation", 6)
	row.add_child(modules)
	_scene_label(modules, "玩家模块数量上限")
	_module_limit_field = _add_spin(modules, 1, 256, 1, 1, false)
	_module_limit_field.custom_minimum_size.x = 44
	_module_limit_field.get_line_edit().add_theme_constant_override("minimum_character_width", 0)
	_module_limit_field.tooltip_text = "组装时允许安装的模块总数（1..256）。"
	_module_limit_field.value_changed.connect(_on_module_limit_changed)
	var health := ResponsivePropertyRow.new()
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
	var header := ResponsivePropertyRow.new()
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
	if content.visible and _gate_timer_field != null and content.is_ancestor_of(_gate_timer_field):
		_commit_gate_timer()
		if _canvas.paint_mode in [MapEditorCanvas.PaintMode.GATE_ADD, MapEditorCanvas.PaintMode.GATE_REMOVE]:
			_cancel_point_tool()
	if content.visible and _enemy_panel != null and content.is_ancestor_of(_enemy_panel):
		# 先提交正在输入的敌人数值，并收起浮层与放置预览；已有敌人和模板不受影响。
		_enemy_panel.commit_fields()
		_enemy_panel._picker.close_menu(false)
		if _canvas.paint_mode in [MapEditorCanvas.PaintMode.ENEMY, MapEditorCanvas.PaintMode.ENEMY_SELECT]:
			_cancel_point_tool()
	content.visible = not content.visible
	button.icon = load("res://assets/ui/map_editor_collapse.svg" if content.visible else "res://assets/ui/map_editor_expand.svg")
	button.tooltip_text = "收起分类" if content.visible else "展开分类"


## 秒表旁直接输入秒数，药丸没有加减或上下箭头；沿用场景控制的紧凑布局。
func _build_time_limit(parent: Control, point_pill: Control) -> void:
	var inset := MarginContainer.new()
	parent.add_child(inset)
	var row := ResponsivePropertyRow.new()
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
	var font_size := roundi(GameTheme.base_font_size(caption, "font_size") * GameTheme.font_scale(caption))
	var caption_width := caption.get_theme_font("font").get_string_size(caption.atr(caption.text), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var row := caption.get_parent() as ResponsivePropertyRow
	var available := maxf(0.0, inset.size.x - row.preferred_width())
	var offset := point_pill.position.x + (point_pill.size.x - timer_pill.size.x) * 0.5 - caption_width - 5.0
	var margin := roundi(clampf(offset, 0.0, available))
	if inset.get_theme_constant("margin_left") != margin:
		inset.add_theme_constant_override("margin_left", margin)


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
		_time_limit_text = String.num(editor_document.get_time_limit_seconds(), 1).trim_suffix(".0")
		_time_limit_field.text = _time_limit_text
		_show_errors("无法设置时间限制", result.errors)


## 地形工具与点位工具互斥；回到画笔或框选时恢复对应高亮及原有绘制手势。
func _set_paint_mode(mode: MapEditorCanvas.PaintMode) -> void:
	_commit_gate_timer()
	_canvas.selected_gate_id = ""
	_sync_gate_timer(true)
	if _gate_add_button != null:
		_gate_add_button.set_pressed_no_signal(false)
		_gate_remove_button.set_pressed_no_signal(false)
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


## 场景编辑中的两只圆形工具与秒表药丸；工具只改变交互，不提前修改地图。
func _build_timed_gate_controls(parent: Control) -> void:
	var row := ResponsivePropertyRow.new()
	row.name = "MapEditorTimedGateRow"
	row.group_sizes = [3, 2]
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_scene_label(row, "添改限时闸门", "MapEditorTimedGateLabel")
	_gate_remove_button = _gate_tool_button(row, "MapEditorGateRemove", "assembly_delete", "删除限时闸门", MapEditorCanvas.PaintMode.GATE_REMOVE)
	_gate_add_button = _gate_tool_button(row, "MapEditorGateAdd", "map_editor_new", "放置限时闸门", MapEditorCanvas.PaintMode.GATE_ADD)
	var pill := PanelContainer.new()
	pill.name = "MapEditorGateTimerPill"
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
	_gate_timer_field = LineEdit.new()
	_gate_timer_field.name = "MapEditorGateTimerInput"
	_gate_timer_field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_gate_timer_field.text = "6"
	_gate_timer_field.custom_minimum_size.x = 42
	_gate_timer_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gate_timer_field.add_theme_constant_override("minimum_character_width", 0)
	_gate_timer_field.add_theme_font_size_override("font_size", 15)
	_gate_timer_field.caret_blink = true
	_gate_timer_field.caret_blink_interval = 0.5
	for state in ["normal", "focus", "read_only"]:
		_gate_timer_field.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_gate_timer_field.focus_entered.connect(_begin_gate_timer_edit)
	_gate_timer_field.text_changed.connect(_on_gate_timer_text_changed)
	_gate_timer_field.focus_exited.connect(_commit_gate_timer)
	_gate_timer_field.text_submitted.connect(_on_gate_timer_submitted)
	content.add_child(_gate_timer_field)
	_refresh_gate_timer_rules()
	_gate_timer_field.theme_changed.connect(_fit_gate_timer_field)
	_fit_gate_timer_field()
	var unit := GameTheme.label(row, "秒", 10, true)
	unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


## 按当前真实字号预留最宽合法秒数与光标空间，不拉伸字形或依赖文字横向滚动。
func _fit_gate_timer_field() -> void:
	var font := _gate_timer_field.get_theme_font("font")
	var font_size := _gate_timer_field.get_theme_font_size("font_size")
	var whole_width := font.get_string_size("100000", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var fraction_width := font.get_string_size("99999.9", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_gate_timer_field.custom_minimum_size.x = maxf(42, ceilf(maxf(whole_width, fraction_width)) + 8)


## 圆形图标以 SVG 的中心绘制，沿用现有工具组的选择与键盘焦点样式。
func _gate_tool_button(parent: Control, node_name: String, icon_name: String, tooltip: String, mode: MapEditorCanvas.PaintMode) -> Button:
	var button := _view_button(parent, node_name, icon_name, _select_gate_tool.bind(mode), 0, 1)
	button.custom_minimum_size = Vector2(32, 32)
	button.add_theme_constant_override("icon_max_width", 24)
	button.toggle_mode = true
	button.button_group = _tool_group
	button.tooltip_text = tooltip
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("D7E4F5") if state in ["pressed", "hover_pressed"] else Color("E2E8F1") if state == "hover" else Color("EAEDF2")
		var surface := GameTheme.box(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 16)
		surface.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, surface)
	return button


## 秒数输入只接受十进制一位小数；空白可临时编辑，但不作为新倒计时提交。
func _valid_gate_timer_text(text: String) -> bool:
	var parts := text.split(".")
	if parts.size() > 2 or parts[0].is_empty() or (parts.size() == 2 and parts[1].length() > 1):
		return false
	for part: String in parts:
		for character in part:
			if character < "0" or character > "9":
				return false
	return MapEditorTimedGate.ticks_from_seconds(text.to_float()).is_ok()


## 记录本次编辑的文档与所选闸门，避免切换地图或撤销后提交到别的对象。
func _begin_gate_timer_edit() -> void:
	_gate_edit_source = editor_document.document
	_gate_edit_target = _canvas.selected_gate_id
	_gate_timer_baseline = _gate_timer_field.text
	_gate_timer_edited = false


## 允许空白和小数的中间输入，回车或失焦时再统一修正无效值。
func _on_gate_timer_text_changed(text: String) -> void:
	if _syncing_fields:
		return
	_gate_timer_edited = text != _gate_timer_baseline


## 回车与失焦使用同一倒计时提交入口。
func _on_gate_timer_submitted(_text: String) -> void:
	_commit_gate_timer()


## 未选择对象时设置下一扇门的秒数；选择对象后仅修改那扇门的一次编辑事务。
func _commit_gate_timer() -> void:
	if _syncing_fields or _gate_timer_field == null or not _gate_timer_edited:
		return
	_gate_timer_edited = false
	var text := _gate_timer_field.text
	if _gate_edit_source != editor_document.document or _gate_edit_target != _canvas.selected_gate_id:
		_sync_gate_timer(true)
		return
	var maximum := _maximum_gate_ticks()
	if maximum < 1:
		_sync_gate_timer(true)
		return
	var seconds := text.to_float() if _valid_gate_timer_text(text) else float(maximum) * SimulationWorld.TICK_DURATION
	if not MapEditorTimedGate.ticks_from_seconds(seconds, maximum + 1).is_ok():
		seconds = float(maximum) * SimulationWorld.TICK_DURATION
	if _gate_edit_target.is_empty():
		_new_gate_seconds = seconds
	else:
		var result := editor_document.set_timed_gate_seconds(_gate_edit_target, seconds)
		if not result.is_ok():
			_show_errors("无法修改限时闸门", result.errors)
	_sync_gate_timer(true)


## 表单同步不修改旧对象；下一扇门的候选值随当前总限时自动收敛到合法范围。
func _sync_gate_timer(force: bool = false) -> void:
	_refresh_gate_timer_rules()
	if _gate_timer_field == null or (_gate_timer_field.has_focus() and not force):
		return
	var old_sync := _syncing_fields
	_syncing_fields = true
	var maximum := _maximum_gate_ticks()
	if maximum > 0 and (not MapEditorTimedGate.ticks_from_seconds(_new_gate_seconds).is_ok() or roundi(_new_gate_seconds / SimulationWorld.TICK_DURATION) > maximum):
		_new_gate_seconds = float(maximum) * SimulationWorld.TICK_DURATION
	var selected := MapEditorTimedGate.find(editor_document.document, _canvas.selected_gate_id)
	var seconds := _new_gate_seconds if selected.is_empty() else MapEditorTimedGate.seconds(selected)
	_gate_timer_text = "" if maximum == 0 and selected.is_empty() else String.num(seconds, 1).trim_suffix(".0")
	_gate_timer_field.text = _gate_timer_text
	_gate_timer_baseline = _gate_timer_text
	_gate_timer_edited = false
	_gate_edit_source = editor_document.document
	_gate_edit_target = _canvas.selected_gate_id
	_syncing_fields = old_sync


## 旧不限时地图也按表单显示的默认限时计算，最大值总比关卡时间少一个tick。
func _maximum_gate_ticks() -> int:
	return MapEditorTimedGate.maximum_ticks(roundi(editor_document.get_time_limit_seconds() / SimulationWorld.TICK_DURATION))


## 悬浮说明跟随关卡时间与语言刷新；0.1秒关卡无法放置正倒计时闸门。
func _refresh_gate_timer_rules() -> void:
	if _gate_timer_field == null:
		return
	var maximum := _maximum_gate_ticks()
	var available := maximum > 0
	_gate_timer_field.editable = available
	_gate_timer_field.context_menu_enabled = available
	_gate_add_button.disabled = not available
	var tooltip := tr("关卡总时间至少需要 0.2 秒才能设置闸门倒计时。")
	if available:
		tooltip = tr("闸门倒计时：0.1 至 %s 秒，最多一位小数，且须小于关卡总时间。\n回车或离开输入框时，无效输入自动设为最大值；点击已有闸门可修改。") % String.num(float(maximum) * SimulationWorld.TICK_DURATION, 1).trim_suffix(".0")
	_gate_timer_field.tooltip_text = tooltip
	_gate_timer_field.get_parent().tooltip_text = tooltip
	_gate_add_button.tooltip_text = tr("放置限时闸门") if available else tooltip


## 限时闸门工具与地形、起终点、敌人互斥，取消后恢复之前的地形工具。
func _select_gate_tool(mode: MapEditorCanvas.PaintMode) -> void:
	_commit_gate_timer()
	_canvas.finish_stroke()
	_point_tool = ""
	_canvas.paint_mode = mode
	_canvas.selected_gate_id = ""
	_canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	for button in [_paint_button, _rectangle_button, _spawn_button, _goal_button]:
		button.set_pressed_no_signal(false)
	_gate_add_button.set_pressed_no_signal(mode == MapEditorCanvas.PaintMode.GATE_ADD)
	_gate_remove_button.set_pressed_no_signal(mode == MapEditorCanvas.PaintMode.GATE_REMOVE)
	_sync_gate_timer(true)
	_status.text = "单击可通行地块放置闸门；点击已有闸门可修改倒计时，右键或 Esc 取消。" if mode == MapEditorCanvas.PaintMode.GATE_ADD else "单击限时闸门删除；地板和其他对象保持不变，右键或 Esc 取消。"


## 切换所选闸门前提交原对象的输入，随后读出新对象原有倒计时。
func _select_timed_gate(identity: String) -> void:
	_commit_gate_timer()
	_canvas.selected_gate_id = identity
	_sync_gate_timer(true)
	if not identity.is_empty():
		_status.text = "已选择限时闸门，可在秒表药丸中修改倒计时。"


## 放置使用本次工具的秒数；已有选择的倒计时可作为连续放置的模板。
func _place_timed_gate(cell: Vector2i) -> void:
	_commit_gate_timer()
	if _message_dialog.visible:
		return
	var selected := MapEditorTimedGate.find(editor_document.document, _canvas.selected_gate_id)
	var seconds := _new_gate_seconds if selected.is_empty() else MapEditorTimedGate.seconds(selected)
	# 旧不限时地图的表单显示默认60秒，新门也须遵守玩家当前看见的限时。
	var maximum := _maximum_gate_ticks()
	if maximum < 1:
		return
	if not MapEditorTimedGate.ticks_from_seconds(seconds, maximum + 1).is_ok():
		seconds = float(maximum) * SimulationWorld.TICK_DURATION
	var result := editor_document.place_timed_gate(cell, seconds, registry)
	if not result.is_ok():
		_status.text = "；".join(result.errors)
		return
	_select_timed_gate(result.value.id)


## 删除命中的限时闸门；模型更改后同步清除旧选择与倒计时目标。
func _remove_timed_gate(identity: String) -> void:
	_commit_gate_timer()
	var result := editor_document.remove_timed_gate(identity)
	if not result.is_ok():
		_status.text = "；".join(result.errors)
	else:
		_status.text = "限时闸门已删除，可撤销恢复。"


## 起点与终点使用单击工具，保留之前的地形手势以便取消后继续绘制。
func _select_point_tool(kind: String) -> void:
	_commit_gate_timer()
	_canvas.selected_gate_id = ""
	_sync_gate_timer(true)
	if _gate_add_button != null:
		_gate_add_button.set_pressed_no_signal(false)
		_gate_remove_button.set_pressed_no_signal(false)
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
	_commit_gate_timer()
	_canvas.selected_gate_id = ""
	_sync_gate_timer(true)
	if _gate_add_button != null:
		_gate_add_button.set_pressed_no_signal(false)
		_gate_remove_button.set_pressed_no_signal(false)
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


## 首次点击进入敌人框选；松手只选择，再次点击垃圾桶才一次删除全部命中组合体。
func _select_enemy_remove_tool() -> void:
	if not editor_document.get_enemies_enabled():
		return
	if _canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY_SELECT and _canvas.enemy_selection_area.has_area():
		var removed := editor_document.remove_enemies_in_rectangle(_canvas.enemy_selection_area, registry)
		_canvas.finish_stroke()
		_status.text = tr("已删除 %d 组敌人，可撤销恢复。") % removed
	else:
		_set_paint_mode(_terrain_mode)
		_canvas.paint_mode = MapEditorCanvas.PaintMode.ENEMY_SELECT
		_canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
		_paint_button.set_pressed_no_signal(false)
		_rectangle_button.set_pressed_no_signal(false)
		_status.text = "框选要删除的敌人，再次点击删除按钮确认；右键或 Esc 取消。"
	_sync_enemy_remove_button()


## 框选结果仅更新工具说明与绘制，未点击确认时不改保存状态或撤销历史。
func _on_enemy_selection_requested(area: Rect2i) -> void:
	var count := MapEditorEnemyTemplate.in_rectangle(editor_document.document, area, registry).size()
	_status.text = tr("已选中 %d 组敌人，点击删除按钮确认。") % count


## 工具高亮始终来自当前画布模式；点击空白或切换其它工具后不会遗留按钮选中态。
func _sync_enemy_remove_button() -> void:
	if _enemy_panel != null and is_instance_valid(_enemy_panel.remove_button):
		_enemy_panel.remove_button.set_pressed_no_signal(_canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY_SELECT)


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
	if not enabled and _canvas.paint_mode in [MapEditorCanvas.PaintMode.ENEMY, MapEditorCanvas.PaintMode.ENEMY_SELECT]:
		_cancel_point_tool()
	_canvas.queue_redraw()


## 表单自行显示输入错误，指引中同时保留最近一次编辑状态。
func _on_enemy_feedback(message: String) -> void:
	_status.text = message


## 更换绘制项目回到地形工具，同时取消尚未提交的框选。
func _on_drawing_item_selected(_index: int) -> void:
	_set_paint_mode(_terrain_mode)


## 标签与输入控件处于同一行，常用短标签统一对齐，宽高和模块上限按文字自然占位。
func _property_row(parent: Node, caption: String, label_width: float = 40.0) -> ResponsivePropertyRow:
	var row := ResponsivePropertyRow.new()
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


## 视图入口并入页头，地图区域不再为工具和白色卡片预留内部空间。
func _build_map_controls() -> void:
	_zoom_out_button = _header.zoom_out_button
	_zoom_in_button = _header.zoom_in_button
	_guide_button = _header.guide_button
	_header.zoom_out_requested.connect(_map_view.zoom_out)
	_header.zoom_in_requested.connect(_map_view.zoom_in)
	_header.guide_requested.connect(_show_guide)
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
	_command_menu.close_menu(false)
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
	_command_menu.close_menu(false)
	_actions_menu.popup_at(_header.more_button)


## CanvasLayer 不继承编辑器的隐藏状态；进入试玩前主动收起菜单，避免遮住游戏页。
func _on_editor_visibility_changed() -> void:
	if not is_visible_in_tree() and _actions_menu != null:
		_actions_menu.close_menu(false)
		_guide_menu.close_menu(false)
		_level_guide_editor.close_dialog()
		_restriction_picker.close_menu(false)
		_command_menu.close_menu(false)


## 语言切换只更新界面名称和提示，不重填输入框、绘制选择或地图数据。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_document_title()
		_update_zoom_buttons(_map_view.zoom)
		_refresh_drawing_item_labels()
		_level_guide_button.tooltip_text = tr("编辑关卡引导")
		_command_button.tooltip_text = tr("管理关卡中允许使用的指令集")
		_refresh_gate_timer_rules()


# 用途：创建文件选择、未保存确认、错误提示和元数据输入对话框。
func _build_dialogs() -> void:
	_level_guide_editor = MapGuideEditor.new()
	_level_guide_editor.name = "MapGuideEditor"
	add_child(_level_guide_editor)
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	# macOS/Windows 优先使用系统文件窗口；不支持原生窗口的平台自动使用圆角后备界面。
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.json ; JSON ; application/json"])
	_file_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
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
	var title_height := roundi(frame.expand_margin_top * _presentation_scale) if _metadata_dialog.is_embedded() else 0
	var margin := roundi(32 * _presentation_scale)
	var available := Vector2i(get_viewport_rect().size) - Vector2i(margin, margin + title_height)
	_metadata_dialog.size = Vector2i(Vector2(METADATA_DIALOG_SIZE) * _presentation_scale).min(available)
	_metadata_dialog.position = (Vector2i(get_viewport_rect().size) - _metadata_dialog.size - Vector2i(0, title_height)) / 2 + Vector2i(0, title_height)


## 游戏视口变化时重新约束已打开的弹窗，不重填 JSON 或改变文本编辑状态。
func _on_metadata_viewport_resized() -> void:
	if _metadata_dialog.visible:
		_fit_metadata_dialog()


## 元数据共用全局代码配色，保留原生文本状态；高亮仅识别 JSON，不套用游戏指令。
func _sync_metadata_color() -> void:
	var mode := settings.code_color_mode if settings != null else GameSettings.DEFAULT_CODE_COLOR_MODE
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
	_restriction_picker.close_menu(false)
	_sync_module_restrictions()
	_command_menu.close_menu(false)
	_sync_command_restrictions()
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
	if not _test_validation_active:
		_clear_test_feedback()
	var gate_source_changed := _gate_document != editor_document.document
	_gate_document = editor_document.document
	if gate_source_changed or MapEditorTimedGate.find(_gate_document, _canvas.selected_gate_id).is_empty():
		_canvas.selected_gate_id = ""
		_sync_gate_timer(true)
	else:
		_sync_gate_timer()
	_canvas.document = editor_document.document
	_map_view.refresh_map()
	if _identity_source != editor_document.document:
		_identity_source = editor_document.document
		_identity_uncommitted = false
	_syncing_fields = true
	# ID 只用于展示与复制，始终来自模型，不受其它身份字段待提交或控件焦点影响。
	_id_field.text = editor_document.document.id
	if not _identity_uncommitted and not _name_field.has_focus():
		_name_field.text = editor_document.document.display_name
	if not _identity_uncommitted and not _creator_field.has_focus():
		_creator_field.text = editor_document.get_creator()
	if not _identity_uncommitted and not _subtitle_field.has_focus():
		_subtitle_field.text = editor_document.get_subtitle()
	_width_field.value = editor_document.document.width
	_height_field.value = editor_document.document.height
	_dimension_texts[_width_field] = str(editor_document.document.width)
	_dimension_texts[_height_field] = str(editor_document.document.height)
	_module_limit_field.value = editor_document.get_module_limit()
	_sync_code_policy_controls()
	_sync_module_restrictions()
	_sync_command_restrictions()
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
	if _canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY_SELECT and not editor_document.get_enemies_enabled():
		_cancel_point_tool()
	_sync_enemy_remove_button()
	_update_document_title()
	_update_history_buttons()


## 目录加载、历史和地图切换共用纯显示同步，不产生额外元数据或编辑历史。
func _sync_module_restrictions() -> void:
	var restricted := editor_document.get_restricted_modules(registry)
	_restriction_choice.configure(registry, restricted)
	_restriction_picker.sync_selection(restricted)


## 用标题星号保留未保存反馈，文件路径不再作为可见按钮或额外布局行。
func _update_document_title() -> void:
	_header.title_label.text = tr("地图编辑器") + (" *" if editor_document.is_dirty() else "")


# 用途：一次采集身份、副标题与署名，事务结束前不回填控件，避免未失焦内容相互覆盖。
func _commit_identity() -> bool:
	if _syncing_fields:
		return true
	var map_id := editor_document.document.id
	_id_field.text = map_id
	var map_name := _name_field.text
	var creator := _creator_field.text
	var subtitle := _subtitle_field.text
	_identity_uncommitted = false
	var result := editor_document.set_identity_with_subtitle(map_id, map_name, creator, subtitle)
	if not result.is_ok():
		_identity_uncommitted = true
		_show_errors("无法更新地图属性", result.errors)
		return false
	return true


## 待提交的身份输入不能被其它属性变化回填覆盖，便于修正超长粘贴的完整原文。
func _on_identity_text_changed(_text: String) -> void:
	if not _syncing_fields:
		_identity_uncommitted = true


# 用途：在名称或创作者输入框按回车时提交身份信息，ID 由创建或载入流程决定。
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
	_commit_gate_timer()
	_canvas.finish_stroke()
	if editor_document.undo():
		_status.text = "已撤销。"


# 用途：重做一次地图修改。
func _redo() -> void:
	_commit_gate_timer()
	_canvas.finish_stroke()
	if editor_document.redo():
		_status.text = "已重做。"


# 用途：在替换文档或关闭窗口前统一保护未保存的修改。
func _request_action(action: String) -> void:
	_commit_gate_timer()
	if not _level_guide_editor.close_dialog():
		return
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	if not _commit_identity():
		return
	_pending_action = action
	if editor_document.is_dirty():
		_dirty_dialog.dialog_text = "当前地图尚未保存。继续将放弃这些修改；取消后可以先保存。"
		_dirty_dialog.popup_centered(Vector2i(Vector2(480, 180) * _presentation_scale))
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
	var used := {editor_document.document.id: true}
	var allocated := _player_level_store().create_map_id(used)
	if not allocated.is_ok():
		_show_errors("无法创建地图", allocated.errors)
		return
	var document := MapDocument.new()
	document.id = allocated.value
	document.display_name = "新地图"
	document.width = 16
	document.height = 12
	document.properties = {"level": {"max_ticks": 600, "completion_mode": "reach_or_clear", "player_max_health": 1.0, "restricted_modules": [], "allow_code_hints": false, "restrict_code_paste": false, "enabled_commands": CommandPermissions.COMMAND_IDS.duplicate()}}
	# 新地图显式允许全部已有指令；只初始化新草稿，旧地图仍保留自己的解锁策略。
	document.properties.level.merge(CommandPermissions.legacy_flags(PackedStringArray(CommandPermissions.COMMAND_IDS)), true)
	if not default_creator.is_empty() and DataValidation.is_creator(default_creator) and default_creator.length() <= DataValidation.MAX_EDITOR_CREATOR_LENGTH:
		document.properties.level["creator"] = default_creator
	_managed_save_path = ""
	_assigned_new_id = document.id
	editor_document.replace_document(document)
	_map_view.reset_view()
	_status.text = "空白地图已创建。绘制地板后，用场景玩法与行为控制放置起点；终点可按需添加。"


# 用途：校验并载入地图草稿；初始指定图失败交回外壳，普通打开失败保留原文档并提示。
func _load_document(path: String, report_errors: bool = true) -> bool:
	var result: DataResult = MapCodec.load_file(path, registry, false)
	if not result.is_ok():
		if report_errors:
			_show_errors("无法打开地图", result.errors)
		else:
			initial_map_error = result.errors.duplicate()
		return false
	_managed_save_path = _player_level_store().managed_path(path)
	_assigned_new_id = ""
	editor_document.replace_document(result.value as MapDocument, path)
	_map_view.reset_view()
	_status.text = "已打开地图。所有未指定地块均为 void。"
	return true


# 用途：普通保存写入玩家关卡目录，只有另存为才允许选择外部文件。
func _save_document(save_as: bool) -> void:
	_commit_gate_timer()
	if not _level_guide_editor.close_dialog():
		save_finished.emit(false)
		return
	_canvas.finish_stroke()
	_commit_time_limit()
	_commit_module_limit()
	if not _commit_identity():
		save_finished.emit(false)
		return
	if save_as:
		_file_operation = "save"
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.title = "保存地图"
		_file_dialog.current_file = editor_document.document.id.validate_filename() + ".json"
		_file_dialog.popup_centered_ratio(0.75)
	else:
		_save_player_level()


## 每次使用当前注入目录，独立编辑器与游戏外壳共用同一托管规则。
func _player_level_store() -> PlayerLevelStore:
	var store := PlayerLevelStore.new()
	store.directory = player_levels_directory
	return store


## 写盘成功后才更新身份与保存点，不替换编辑模型或清空撤销历史。
func _save_player_level() -> void:
	var policy := editor_document.validate_code_policy_change({})
	if not policy.is_ok():
		_show_errors("无法保存地图", policy.errors)
		save_finished.emit(false)
		return
	var store := _player_level_store()
	var preferred := _managed_save_path
	if preferred.is_empty():
		preferred = store.managed_path(editor_document.path)
	var preserve_id := not _assigned_new_id.is_empty() and _assigned_new_id == editor_document.document.id
	var result := store.save(editor_document.document, registry, preferred, preserve_id)
	if not result.is_ok():
		_show_errors("无法保存地图", result.errors)
		save_finished.emit(false)
		return
	var saved: MapDocument = result.value.document
	if saved.id != editor_document.document.id:
		editor_document.set_identity(saved.id, saved.display_name)
	_managed_save_path = result.value.path
	editor_document.mark_saved(_managed_save_path)
	_status.text = tr("地图已保存：") + _managed_save_path
	save_finished.emit(true)


# 用途：将文件选择结果分派给载入或写盘流程。
func _on_file_selected(path: String) -> void:
	var operation := _file_operation
	_file_operation = ""
	if operation == "open":
		_load_document(path)
	else:
		_write_document(path)


## 取消另存为结束本次导出请求，不改变已经绑定的玩家关卡文件。
func _on_file_canceled() -> void:
	var operation := _file_operation
	_file_operation = ""
	if operation == "save":
		save_finished.emit(false)


# 用途：另存为使用统一原子写盘；外部导出不改变普通保存已经绑定的玩家关卡。
func _write_document(path: String) -> void:
	var policy := editor_document.validate_code_policy_change({})
	if not policy.is_ok():
		_show_errors("无法保存地图", policy.errors)
		save_finished.emit(false)
		return
	_commit_gate_timer()
	_commit_time_limit()
	_commit_module_limit()
	var result: DataResult = MapCodec.save_file(editor_document.document, path, registry, false)
	if not result.is_ok():
		_show_errors("无法保存地图", result.errors)
		save_finished.emit(false)
		return
	if _managed_save_path.is_empty():
		_managed_save_path = _player_level_store().managed_path(path)
	editor_document.mark_saved(path)
	_status.text = tr("地图已保存：") + path
	save_finished.emit(true)


# 用途：与游戏关卡入口共用数据规则；玩家实际装配的占地留到确认装配时检查。
func _validate_document() -> void:
	if not _prepare_test_validation():
		return
	var result := _test_level_definition()
	if not result.is_ok():
		_show_test_feedback(result.errors)
		return
	if not result.value.has_goal:
		_show_test_feedback(PackedStringArray(["此关卡缺乏终点"]))
	_status.text = "校验通过：地图与关卡规则有效；最终模块占地将在确认装配时检查。"


# 用途：将地图扩展数据呈现为可编辑 JSON，不依赖尚未制作的专门 UI。
func _open_metadata() -> void:
	_commit_gate_timer()
	_canvas.finish_stroke()
	_command_menu.close_menu(false)
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	if not _commit_identity():
		return
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
	var policy := editor_document.validate_code_policy_change(data)
	if not policy.is_ok():
		_show_errors("元数据校验失败", policy.errors)
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
	if not _prepare_test_validation():
		return
	var result := _test_level_definition()
	if not result.is_ok():
		_show_test_feedback(result.errors)
		return
	# 无终点只提醒，继续保留自由测试；真正无法运行的地图由上面的共享校验拒绝。
	if not result.value.has_goal:
		_show_test_feedback(PackedStringArray(["此关卡缺乏终点"]))
	_status.text = "测试将进入组装和编程；返回编辑器后可继续修改地图。"
	playtest_requested.emit(result.value as LevelDefinition, registry)


## 测试和校验提交同一份待编辑输入，期间的字段错误统一交给底部红字而非弹出窗口。
func _prepare_test_validation() -> bool:
	_clear_test_feedback()
	_test_validation_active = true
	_commit_gate_timer()
	var guide_valid := _level_guide_editor.close_dialog()
	_canvas.finish_stroke()
	if _time_limit_field.has_focus():
		_commit_time_limit()
	_commit_module_limit()
	var identity_valid := _commit_identity()
	_test_validation_active = false
	return guide_valid and identity_valid and _test_feedback_errors.is_empty()


## 默认不显示说明，地图改动后清除上次检测结果，避免把旧原因当作新地图状态。
func _clear_test_feedback() -> void:
	_test_feedback_errors.clear()
	if _test_feedback != null:
		_test_feedback.text = ""
		_test_feedback.hide()


## 仅在主动测试或校验时显示原因，沿实际卡宽自动换行，固定在操作按钮上方。
func _show_test_feedback(errors: PackedStringArray) -> void:
	for error in errors.slice(0, 20):
		var caption := "此关卡缺乏出生点" if error == "运行地图需要玩家出生点" else error
		if not _test_feedback_errors.has(caption):
			_test_feedback_errors.append(caption)
	_refresh_test_feedback()
	_test_feedback.show()


## 切换语言重新翻译检测提示，玩家名称及地图数据不进入翻译流程。
func _refresh_test_feedback() -> void:
	if _test_feedback == null:
		return
	var translated := PackedStringArray()
	for error in _test_feedback_errors:
		translated.append(tr(error))
	_test_feedback.text = "\n".join(translated)


# 用途：仅按文档历史决定撤销与重做按钮状态，编辑器不持有局部试玩模式。
func _update_history_buttons() -> void:
	_undo_button.disabled = not editor_document.can_undo()
	_redo_button.disabled = not editor_document.can_redo()


# 用途：同时显示简要状态和详细错误列表，便于修正数据问题。
func _show_errors(title: String, errors: PackedStringArray) -> void:
	if _test_validation_active:
		_show_test_feedback(errors)
		return
	_status.text = title + "：" + (errors[0] if not errors.is_empty() else "未知错误")
	_message_dialog.title = title
	_message_dialog.dialog_text = "\n".join(errors.slice(0, 20))
	_message_dialog.popup_centered(Vector2i(Vector2(660, 260) * _presentation_scale))
