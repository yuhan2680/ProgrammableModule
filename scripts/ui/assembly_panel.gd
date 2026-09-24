class_name AssemblyPanel
extends Control
## 独立装配组件：玻璃侧栏选择模块，长方形图纸编辑装配，右侧修改实例属性。
## 关卡准备页和程序工作台共用此组件，数量与布局规则仍由 AssemblyModel 执行。

signal draft_changed

# 准备页使用全宽工具栏；工作台页签共用侧栏和图纸，不重复创建工具栏。
var preparation_mode: bool = false
var header: AssemblyHeader
var preparation_status: Label

var settings: GameSettings:
	set(value):
		if settings == value:
			return
		if settings != null and settings.changed.is_connected(_sync_view_setting):
			settings.changed.disconnect(_sync_view_setting)
		settings = value
		if settings != null:
			settings.changed.connect(_sync_view_setting)
		_sync_view_setting()

var model: AssemblyModel:
	set(value):
		if model == value:
			return
		if model != null and model.changed.is_connected(_on_model_changed):
			model.changed.disconnect(_on_model_changed)
		model = value
		if model != null:
			model.changed.connect(_on_model_changed)
		refresh()
var registry: ContentRegistry:
	set(value):
		registry = value
		refresh()
var interaction_enabled: bool = true:
	set(value):
		interaction_enabled = value
		refresh()

var canvas: AssemblyCanvas
var palette_buttons: Dictionary = {}
var selected_module_id: String = ""
var _module_count: Label
var _view_hint: Label
var _module_name: LineEdit
var _offset_x: SpinBox
var _offset_y: SpinBox
var _apply_button: Button
var _remove_button: Button
var _assembly_message: Label
var _rules_button: Button
var _rules_menu: WorkbenchGuideMenu
var _palette_drawer: AssemblyModuleDrawer
var _palette_button: Button
var _delete_button: Button
var _palette_details_button: Button
var _palette_details_visible := false
var _palette_descriptions: Dictionary = {}
var _editor_card: PanelContainer
var _palette_list: VBoxContainer
var _palette_reasons: Dictionary = {}
var _catalog_definitions: Dictionary = {}
var _built: bool = false


## 组件重新加入场景树时恢复模型订阅，允许准备页与工作台安全复用生命周期。
func _enter_tree() -> void:
	if settings != null and not settings.changed.is_connected(_sync_view_setting):
		settings.changed.connect(_sync_view_setting)
	if model != null and not model.changed.is_connected(_on_model_changed):
		model.changed.connect(_on_model_changed)


## 页面移除时立即断开模型订阅，不等到queue_free才停止旧页面的草稿回调。
func _exit_tree() -> void:
	if settings != null and settings.changed.is_connected(_sync_view_setting):
		settings.changed.disconnect(_sync_view_setting)
	if _palette_drawer != null:
		_palette_drawer.close_drawer(true)
	if _rules_menu != null:
		_rules_menu.close_menu(false)
	if model != null and model.changed.is_connected(_on_model_changed):
		model.changed.disconnect(_on_model_changed)


## 创建自适应图纸与浮动目录，同一组件可放在完整页面或窄页签中。
func _ready() -> void:
	_build_ui()
	_built = true
	refresh()


## 语言切换时重新生成带数量的动态文本，其余静态控件交由Godot原生翻译。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		refresh()


## 同步内容目录、数量、画布和操作权限，不重新创建装配模型。
func refresh() -> void:
	if not _built:
		return
	canvas.model = model
	canvas.registry = registry
	canvas.interaction_enabled = interaction_enabled
	_sync_catalog()
	_ensure_selected_definition()
	for module_id: String in palette_buttons:
		var reason := _placement_block_reason(module_id)
		var button: Button = palette_buttons[module_id]
		button.disabled = not reason.is_empty()
		button.set_pressed_no_signal(module_id == selected_module_id)
		var label: Label = _palette_reasons[module_id]
		label.text = reason if not reason.is_empty() else "已选中，点击图纸放置。" if module_id == selected_module_id else "选择后可在图纸中放置。"
		label.visible = _palette_details_visible
		button.tooltip_text = tr(registry.get_module(module_id).display_name) + "\n" + tr(label.text)
	canvas.can_place = _placement_block_reason(selected_module_id).is_empty()
	canvas.refresh()
	_sync_view_setting()
	if model != null and model.level != null:
		_module_count.text = tr("已安装 %d / %d 个模块") % [model.modules.size(), model.level.module_limit]
		if model.modules.size() >= model.level.module_limit:
			_set_message(tr("此关最多允许 %d 个模块，已达到上限。仍可移动或移除已安装模块。") % model.level.module_limit)
	else:
		_module_count.text = "尚未绑定关卡装配"
	_refresh_selection()


## 共享偏好只改变画布查看方式和对应提示，不提交装配或修改玩家草稿。
func _sync_view_setting() -> void:
	if not _built:
		return
	canvas.free_zoom_enabled = settings.assembly_free_zoom if settings != null else false
	_view_hint.text = "左键放置 · 滚轮缩放 · 右键拖动图纸 · Del 删除" if canvas.free_zoom_enabled else "左键放置 · 拖动模块 · Del 删除"


## 外层滚动容器只保护极窄页签，模块目录以覆盖式玻璃侧栏呈现。
func _build_ui() -> void:
	if preparation_mode:
		_build_preparation_ui()
		return
	var viewport := ScrollContainer.new()
	viewport.name = "AssemblyWorkspaceScroll"
	viewport.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(viewport)
	_build_instance_editor(viewport)


## 准备页的工具栏横跨页面，图纸与属性卡片使用下方全部空间。
func _build_preparation_ui() -> void:
	var layout := VBoxContainer.new()
	layout.name = "PreparationRightColumn"
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 16)
	add_child(layout)
	header = AssemblyHeader.new()
	header.name = "AssemblyHeader"
	layout.add_child(header)
	var viewport := ScrollContainer.new()
	viewport.name = "AssemblyWorkspaceScroll"
	viewport.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	viewport.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	viewport.follow_focus = true
	viewport.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(viewport)
	_build_instance_editor(viewport)
	preparation_status = GameTheme.label(layout, "", 14)
	preparation_status.name = "PreparationStatus"
	preparation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 准备页始终保留一行状态高度，首件成功时清空文字不会让图纸缩放或落点跳动。
	preparation_status.custom_minimum_size.y = preparation_status.get_theme_font("font").get_height(14)
	preparation_status.visible = preparation_mode


## 图纸左侧的玻璃圆钮分别控制目录和删除；目录内容只在请求时覆盖展开。
func _build_palette_tools(parent: Node) -> void:
	var inset := MarginContainer.new()
	inset.add_theme_constant_override("margin_top", 10)
	parent.add_child(inset)
	var rail := VBoxContainer.new()
	rail.name = "AssemblyTools"
	rail.add_theme_constant_override("separation", 10)
	inset.add_child(rail)
	_palette_button = AssemblyGlassButton.new()
	_palette_button.name = "AssemblyPaletteButton"
	_palette_button.icon = load("res://assets/ui/assembly_add.svg")
	_palette_button.tooltip_text = "添加模块"
	_palette_button.pressed.connect(_toggle_palette)
	rail.add_child(_palette_button)
	_delete_button = AssemblyGlassButton.new()
	_delete_button.name = "AssemblyDeleteButton"
	_delete_button.icon = load("res://assets/ui/assembly_delete.svg")
	_delete_button.tooltip_text = "删除选中模块（Del）"
	_delete_button.pressed.connect(_remove_selected)
	rail.add_child(_delete_button)
	_palette_drawer = AssemblyModuleDrawer.new()
	_palette_drawer.name = "AssemblyPalette"
	add_child(_palette_drawer)
	_palette_list = _palette_drawer.content_container
	_palette_details_button = _palette_drawer.details_button
	_palette_details_button.name = "AssemblyPaletteDetailsButton"
	_palette_details_button.toggle_mode = true
	_palette_details_button.tooltip_text = "显示或隐藏模块说明"
	_palette_details_button.pressed.connect(_toggle_palette_details)


## 再次点击加号收回侧栏，与装配规则浮窗互斥，避免两个玻璃面板叠在一起。
func _toggle_palette() -> void:
	if _rules_menu != null:
		_rules_menu.close_menu(false)
	_palette_drawer.toggle_at(_palette_button, _editor_card)


## 说明开关统一展开每个模块的功能介绍及不可用原因，选择状态保持不变。
func _toggle_palette_details() -> void:
	_palette_details_visible = not _palette_details_visible
	_palette_details_button.set_pressed_no_signal(_palette_details_visible)
	for description: Label in _palette_descriptions.values():
		description.visible = _palette_details_visible
	for reason: Label in _palette_reasons.values():
		reason.visible = _palette_details_visible


## 右侧将网格与紧凑属性分开居中，装配规则通过右上角指引显示。
func _build_instance_editor(parent: Node) -> void:
	var panel := PanelContainer.new()
	_editor_card = panel
	panel.name = "AssemblyEditorCard"
	panel.custom_minimum_size.x = 620
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	panel.add_child(layout)
	var heading := HBoxContainer.new()
	layout.add_child(heading)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	heading.add_child(titles)
	_module_count = GameTheme.label(titles, "", 18)
	_view_hint = GameTheme.label(titles, "左键放置 · 拖动模块 · Del 删除", 12, true)
	_view_hint.name = "AssemblyViewHint"
	_build_rules_button(heading)
	var workspace := HBoxContainer.new()
	workspace.name = "AssemblyWorkspace"
	workspace.add_theme_constant_override("separation", 18)
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(workspace)
	_build_palette_tools(workspace)
	# 外层只保留紧凑尺寸，宽窗口中的画布可以变大，窄窗口则按实际空间适配。
	var center := Control.new()
	center.name = "AssemblyCanvasArea"
	center.custom_minimum_size = Vector2(340, 340)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.add_child(center)
	canvas = AssemblyCanvas.new()
	canvas.placement_requested.connect(_place_module)
	canvas.module_selected.connect(_select_module)
	canvas.move_requested.connect(_move_module)
	canvas.remove_requested.connect(_remove_module)
	center.add_child(canvas)
	center.resized.connect(_fit_assembly_canvas.bind(center))
	_fit_assembly_canvas.call_deferred(center)
	_build_module_properties(workspace)


## 画布向上延伸到操作提示下沿，让淡出用完标题与工作区间的留白。
func _fit_assembly_canvas(area: Control) -> void:
	var fade_top_extension := 12.0
	canvas.position = Vector2(0, -fade_top_extension)
	canvas.size = area.size + Vector2(0, fade_top_extension)


## 属性表单使用同一宽度，名称同行、偏移居中、两个操作按钮并列。
func _build_module_properties(parent: Node) -> void:
	var inspector := VBoxContainer.new()
	inspector.name = "AssemblyModuleProperties"
	inspector.custom_minimum_size.x = 264
	inspector.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	inspector.add_theme_constant_override("separation", 10)
	inspector.theme = _inspector_theme()
	parent.add_child(inspector)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	inspector.add_child(name_row)
	var name_label := GameTheme.label(name_row, "名称", 12)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_module_name = LineEdit.new()
	_module_name.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_module_name.caret_blink = true
	_module_name.caret_blink_interval = 0.5
	_module_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_module_name.custom_minimum_size.y = 30
	name_row.add_child(_module_name)
	if model != null and model.level.allow_named_calls:
		var naming_text := "名称用于代码调用，例如 drive.move(0, 3)。修改后点击应用。" if model.level.allow_loops else "名称用于代码调用，例如 left.attack(180)。修改后点击应用。"
		if model.level.allow_conditionals:
			naming_text = "射击模块可命名为 gun；用 gun.ready() 查询冷却。修改后点击应用。"
		if model.level.allow_distance:
			naming_text = "测距模块可命名为 sensor；用 sensor.distance(0) 向右测距。"
		var naming_hint := GameTheme.label(inspector, naming_text, 11, true)
		naming_hint.name = "NamedModuleHint"
		naming_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		naming_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var position_row := HBoxContainer.new()
	position_row.name = "AssemblyOffsetRow"
	position_row.alignment = BoxContainer.ALIGNMENT_CENTER
	position_row.add_theme_constant_override("separation", 8)
	inspector.add_child(position_row)
	var offset_label := GameTheme.label(position_row, "偏移 (x, y)", 12)
	offset_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_offset_x = _offset_input(position_row)
	_offset_y = _offset_input(position_row)
	_offset_x.tooltip_text = "偏移 X"
	_offset_y.tooltip_text = "偏移 Y"
	var actions := HBoxContainer.new()
	actions.name = "AssemblyPropertyActions"
	actions.add_theme_constant_override("separation", 8)
	inspector.add_child(actions)
	_remove_button = GameTheme.button(actions, "移除选中模块", _remove_selected)
	_apply_button = GameTheme.button(actions, "应用名称与位置", _apply_module_fields)
	for button in [_remove_button, _apply_button]:
		button.custom_minimum_size.y = 28
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 11)
	_assembly_message = GameTheme.label(inspector, "点击左侧 + 选择模块，然后在图纸中放置。", 11, true)
	_assembly_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assembly_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_assembly_message.custom_minimum_size.y = 40


## 小型表单保留原生编辑与焦点反馈，仅局部缩小留白和圆角。
func _inspector_theme() -> Theme:
	var result := GameTheme.create_theme()
	result.default_font_size = 13
	result.set_constant("buttons_width", "SpinBox", 14)
	result.set_constant("set_min_buttons_width_from_icons", "SpinBox", 0)
	for kind: String in ["LineEdit", "Button"]:
		for state: StringName in result.get_stylebox_list(kind):
			var style := result.get_stylebox(state, kind).duplicate() as StyleBoxFlat
			style.content_margin_left = 6
			style.content_margin_right = 6
			style.content_margin_top = 4
			style.content_margin_bottom = 4
			style.set_corner_radius_all(10)
			result.set_stylebox(state, kind, style)
	return result


## SVG 问号位于卡片右上角；规则浮窗复用已有玻璃样式及外部点击关闭行为。
func _build_rules_button(parent: Node) -> void:
	_rules_button = Button.new()
	_rules_button.name = "AssemblyRulesButton"
	_rules_button.custom_minimum_size = Vector2(28, 28)
	_rules_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_rules_button.tooltip_text = "装配规则"
	_rules_button.icon = load("res://assets/ui/workbench_guide.svg")
	_rules_button.expand_icon = true
	_rules_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_button.add_theme_constant_override("icon_max_width", 18)
	_rules_button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for state: String in ["normal", "hover", "pressed", "focus"]:
		var fill := Color("EAEDF2") if state == "normal" else Color("E0E7F0") if state == "hover" else Color("D7E4F5")
		var style := GameTheme.box(Color.TRANSPARENT if state == "focus" else fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 14)
		style.set_content_margin_all(0)
		_rules_button.add_theme_stylebox_override(state, style)
	for state: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		_rules_button.add_theme_color_override(state, Color.WHITE)
	parent.add_child(_rules_button)
	_rules_menu = WorkbenchGuideMenu.new()
	_rules_menu.name = "AssemblyRulesMenu"
	_rules_menu.expand_from_top_right = true
	add_child(_rules_menu)
	_rules_menu.configure("网格间距 0.5；首个模块的落点成为装配原点 (0, 0)。其他模块须与任意已有模块共边，允许分支，角点接触不算连接。", "")
	_rules_menu.directions_label.hide()
	_rules_menu.terrain_label.hide()
	_rules_button.pressed.connect(_toggle_rules)
	visibility_changed.connect(_on_panel_visibility_changed)


## 规则与模块目录互斥显示，关闭说明后仍保留图纸视点。
func _toggle_rules() -> void:
	if _palette_drawer != null:
		_palette_drawer.close_drawer(true)
	_rules_menu.popup_at(_rules_button)


## 页面切换或隐藏工作台页签时关闭所有浮窗，避免 CanvasLayer 残留。
func _on_panel_visibility_changed() -> void:
	if is_visible_in_tree():
		return
	if _rules_menu != null:
		_rules_menu.close_menu(false)
	if _palette_drawer != null:
		_palette_drawer.close_drawer(true)


## 根据注册表完整生成目录；允许列表只控制可用性，不负责过滤显示内容。
func _sync_catalog() -> void:
	var definitions: Dictionary = registry.modules if registry != null else {}
	if definitions == _catalog_definitions:
		return
	_catalog_definitions = definitions.duplicate()
	for child: Node in _palette_list.get_children():
		_palette_list.remove_child(child)
		child.queue_free()
	palette_buttons.clear()
	_palette_reasons.clear()
	_palette_descriptions.clear()
	var ids: Array = definitions.keys()
	ids.sort()
	for module_id: String in ids:
		_add_palette_entry(registry.get_module(module_id))


## 首次打开或替换关卡模型时选择一个可用画笔；选择定义本身绝不自动安装模块。
func _ensure_selected_definition() -> void:
	if not palette_buttons.has(selected_module_id) or model == null or model.level == null or not selected_module_id in model.level.allowed_modules:
		selected_module_id = ""
		if model != null and model.level != null:
			for module_id: String in palette_buttons:
				if module_id in model.level.allowed_modules:
					selected_module_id = module_id
					break


## 模块默认仅展示图标和名称，说明开关统一展开介绍与不可用原因。
func _add_palette_entry(definition: ModuleDefinition) -> void:
	var entry := VBoxContainer.new()
	entry.add_theme_constant_override("separation", 5)
	_palette_list.add_child(entry)
	var button := GameTheme.button(entry, definition.display_name, _select_definition.bind(definition.id))
	button.name = "Module_" + definition.id.validate_node_name()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.toggle_mode = true
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 30)
	button.custom_minimum_size.y = 44
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color(1, 1, 1, 0.22) if state == "hover" else Color(0.40, 0.64, 0.94, 0.22) if state in ["pressed", "hover_pressed"] else Color.TRANSPARENT
		button.add_theme_stylebox_override(state, GameTheme.box(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 12))
	var texture_result := ContentTextureLoader.load_texture(definition.texture)
	if texture_result.is_ok():
		button.icon = texture_result.value as Texture2D
	var description := GameTheme.label(entry, definition.description if not definition.description.is_empty() else "暂无模块说明。", 13, true)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.visible = _palette_details_visible
	_palette_descriptions[definition.id] = description
	var reason := GameTheme.label(entry, "", 13, true)
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.visible = _palette_details_visible
	_palette_reasons[definition.id] = reason
	palette_buttons[definition.id] = button


## 集中判断新增限制，目录禁用、空白点击和直接调用都复用同一规则。
func _placement_block_reason(module_id: String) -> String:
	if model == null or model.level == null or registry == null:
		return "尚未绑定有效关卡。"
	if registry.get_module(module_id) == null:
		return "请先从目录选择模块。"
	if not module_id in model.level.allowed_modules:
		return "本关未解锁此模块。"
	if not interaction_enabled:
		return "程序运行或暂停期间无法修改装配。"
	if model.modules.size() >= model.level.module_limit:
		return tr("此关最多允许 %d 个模块；请先移除一个模块。") % model.level.module_limit
	return ""


## 切换新增模块的类型，锁定类型的程序化按钮触发也不会绕过可用性检查。
func _select_definition(module_id: String) -> void:
	var reason := _placement_block_reason(module_id)
	if not reason.is_empty():
		_set_message(reason, true)
		return
	selected_module_id = module_id
	refresh()
	_set_message(tr("已选择“%s”，点击图纸放置。") % tr(registry.get_module(module_id).display_name))
	_palette_drawer.close_drawer()


## 放置所选类型；上限满时在界面边界直接停止，不向模型提交失败的新实例。
func _place_module(offset: Vector2) -> void:
	var reason := _placement_block_reason(selected_module_id)
	if not reason.is_empty():
		_set_message(reason, true)
		return
	var result := model.add_module(selected_module_id, offset)
	if result.is_ok():
		_select_module(int(result.value))
	_show_assembly_result(result)


## 切换当前实例选择，不改变左侧用于新增的模块类型。
func _select_module(index: int) -> void:
	canvas.selected_index = index
	_refresh_selection()
	canvas.queue_redraw()


## 拖动修改只受运行锁和模型几何规则限制，不受已满数量限制影响。
func _move_module(index: int, offset: Vector2) -> void:
	if not interaction_enabled or model == null:
		return
	_show_assembly_result(model.move_module(index, offset))


## 删除后释放一个可用名额，目录与新增开关由模型变化信号立即刷新。
func _remove_module(index: int) -> void:
	if not interaction_enabled or model == null:
		return
	var result := model.remove_module(index)
	if result.is_ok():
		_select_module(-1)
	_show_assembly_result(result)


## 圆形删除按钮与属性按钮共用所选模块删除入口，Del由画布发送同一请求。
func _remove_selected() -> void:
	if canvas.selected_index >= 0:
		_remove_module(canvas.selected_index)


## 通过候选副本同时校验名称与位置，任一字段失败都不会部分提交原装配。
func _apply_module_fields() -> void:
	if not interaction_enabled or model == null:
		return
	var index := canvas.selected_index
	if index < 0:
		return
	var candidate := AssemblyModel.create(model.level, registry)
	candidate.modules = model.modules.duplicate(true)
	var renamed := candidate.rename_module(index, _module_name.text)
	if not renamed.is_ok():
		_show_assembly_result(renamed)
		return
	var moved := candidate.move_module(index, Vector2(_offset_x.value, _offset_y.value))
	if not moved.is_ok():
		_show_assembly_result(moved)
		return
	model.modules = candidate.modules.duplicate(true)
	model.changed.emit()
	_show_assembly_result(DataResult.success())


## 创建使用模型定义的范围与半格步长的偏移输入框。
func _offset_input(parent: Node) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = -AssemblyModel.MAX_OFFSET
	field.max_value = AssemblyModel.MAX_OFFSET
	field.step = AssemblyModel.GRID_STEP
	field.custom_minimum_size = Vector2(60, 30)
	field.get_line_edit().add_theme_constant_override("minimum_character_width", 0)
	field.get_line_edit().caret_blink = true
	field.get_line_edit().caret_blink_interval = 0.5
	parent.add_child(field)
	return field


## 刷新选中实例字段，满上限时仍能修改已有实例的名称和位置。
func _refresh_selection() -> void:
	var index := canvas.selected_index
	var selected := model != null and index >= 0 and index < model.modules.size()
	var editable := selected and interaction_enabled
	_module_name.editable = editable
	_offset_x.editable = editable
	_offset_y.editable = editable
	_apply_button.disabled = not editable
	_remove_button.disabled = not editable
	_delete_button.disabled = not editable
	if selected:
		var instance: Dictionary = model.modules[index]
		_module_name.text = instance.id
		_offset_x.value = float(instance.offset.x)
		_offset_y.value = float(instance.offset.y)
	else:
		_module_name.text = ""


## 处理模型的唯一变更通知；准备页与工作台自行决定何时保存或重置运行预览。
func _on_model_changed() -> void:
	refresh()
	draft_changed.emit()


## 显示模型结果，并在满上限时保持清晰的新增禁用提示。
func _show_assembly_result(result: DataResult) -> void:
	if not result.is_ok():
		_set_message(GameI18n.translate_errors(result.errors), true)
	elif model.modules.size() >= model.level.module_limit:
		_set_message(tr("此关最多允许 %d 个模块，已达到上限。仍可移动或移除已安装模块。") % model.level.module_limit)
	else:
		_set_message("装配已更新。运行前会检查模块是否落在地板内。")


## 集中更新装配提示颜色，错误不只写入开发者日志。
func _set_message(text: String, failed: bool = false) -> void:
	_assembly_message.text = text
	_assembly_message.add_theme_color_override("font_color", GameTheme.ERROR if failed else GameTheme.MUTED)
