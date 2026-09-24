class_name MapEditorEnemyPanel
extends VBoxContainer
## 敌人表单只编辑可撤销模板，地图落点与试玩行为仍交给文档及运行层。

signal placement_requested
signal enabled_changed(enabled: bool)
signal feedback(message: String)

var editor_document: MapEditorDocument
var registry: ContentRegistry
var enable_switch: SettingsSwitch
var limit_field: LineEdit
var health_field: LineEdit
var place_button: Button
var _settings_body: VBoxContainer
var _slots: GridContainer
var _choices: Array[EnemyModuleChoice] = []
var _picker: EnemyModulePicker
var _active_choice: EnemyModuleChoice
var _config: Dictionary = {}
var _synced_document: MapDocument
var _feedback_label: Label
var _syncing := false


## 构建开关卡片、并排数值输入和带 SVG 模块图标的组合药丸。
func _ready() -> void:
	name = "MapEditorEnemyPanel"
	_picker = EnemyModulePicker.new()
	add_child(_picker)
	_picker.item_selected.connect(_on_picker_selected)
	add_theme_constant_override("separation", 14)
	GameTheme.label(self, "敌人攻击方式与行为控制", 14)
	var card := PanelContainer.new()
	var surface := GameTheme.box(Color("F5F6F8"), Color.TRANSPARENT, 14)
	surface.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", surface)
	add_child(card)
	var card_body := VBoxContainer.new()
	card_body.add_theme_constant_override("separation", 8)
	card.add_child(card_body)
	var toggle_row := HBoxContainer.new()
	card_body.add_child(toggle_row)
	var caption := GameTheme.label(toggle_row, "是否启用敌人", 12)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	enable_switch = SettingsSwitch.new()
	enable_switch.name = "MapEditorEnemyEnabled"
	enable_switch.custom_minimum_size = Vector2(38, 24)
	enable_switch.tooltip_text = "关闭后保留敌人配置，但试玩时不生成敌人。"
	toggle_row.add_child(enable_switch)
	enable_switch.toggled.connect(_on_enabled_toggled)
	card_body.add_child(HSeparator.new())
	var help := GameTheme.label(card_body, "开启后，选择敌人的模块组合与耐久，再点击左侧＋并在地图中放置。", 11)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settings_body = VBoxContainer.new()
	_settings_body.add_theme_constant_override("separation", 14)
	add_child(_settings_body)
	var limits := HBoxContainer.new()
	limits.name = "MapEditorEnemyLimits"
	limits.add_theme_constant_override("separation", 10)
	_settings_body.add_child(limits)
	limit_field = _number_field(limits, "敌人模块数量限制", "MapEditorEnemyLimit")
	limit_field.tooltip_text = "每组敌人最多包含 1～256 个模块。"
	health_field = _number_field(limits, "敌人耐久度上限", "MapEditorEnemyHealth")
	health_field.tooltip_text = "每个敌人模块的耐久，支持 0.01～1000000 的数值。"
	GameTheme.label(_settings_body, "自定义敌人的模块组合：", 11)
	var combinations := HBoxContainer.new()
	combinations.name = "MapEditorEnemyCombination"
	combinations.add_theme_constant_override("separation", 6)
	_settings_body.add_child(combinations)
	place_button = Button.new()
	place_button.name = "MapEditorPlaceEnemy"
	place_button.icon = load("res://assets/ui/assembly_add.svg")
	place_button.expand_icon = true
	place_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place_button.add_theme_constant_override("h_separation", 0)
	place_button.add_theme_constant_override("icon_max_width", 12)
	place_button.custom_minimum_size = Vector2(26, 26)
	place_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	place_button.tooltip_text = "放置这组敌人"
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := GameTheme.box(Color.TRANSPARENT if state == "focus" else Color("EAEDF2"), GameTheme.ACCENT if state == "focus" else Color.TRANSPARENT, 16)
		style.set_content_margin_all(0)
		place_button.add_theme_stylebox_override(state, style)
	combinations.add_child(place_button)
	place_button.pressed.connect(_request_placement)
	_slots = GridContainer.new()
	_slots.name = "MapEditorEnemyModuleSlots"
	_slots.columns = 4
	_slots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slots.add_theme_constant_override("h_separation", 2)
	_slots.add_theme_constant_override("v_separation", 6)
	combinations.add_child(_slots)
	var behavior_help := GameTheme.label(_settings_body, "移动模块负责靠近玩家；近战或射击模块负责攻击。", 11, true)
	behavior_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback_label = GameTheme.label(_settings_body, "", 11)
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback_label.add_theme_color_override("font_color", Color("dd1d1d"))
	_feedback_label.hide()
	_set_controls_enabled(false)


## 载入目录后绑定真实文档；打开旧地图不隐式新增敌人设置或修改历史。
func configure(model: MapEditorDocument, content: ContentRegistry) -> void:
	editor_document = model
	registry = content
	_config.clear()
	sync_from_document()


## 普通数字输入保留闪烁光标；提交时按数据层范围验证，避免箭头占用紧凑布局。
func _number_field(parent: Control, caption: String, node_name: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)
	var label := GameTheme.label(row, caption, 12)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var field := LineEdit.new()
	field.name = node_name
	field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	field.custom_minimum_size = Vector2(38, 32)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_theme_constant_override("minimum_character_width", 0)
	field.caret_blink = true
	row.add_child(field)
	for state in ["normal", "focus", "read_only"]:
		var style := field.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.set_corner_radius_all(12)
		style.content_margin_left = 7
		style.content_margin_right = 7
		field.add_theme_stylebox_override(state, style)
	field.focus_exited.connect(commit_fields)
	field.text_submitted.connect(_on_number_submitted)
	return field


## 回车与失焦使用同一提交入口，保存快捷键也可主动调用。
func _on_number_submitted(_text: String) -> void:
	commit_fields()


## 两个数值作为同一次模板事务提交，失败只恢复表单，不改地图或历史。
func commit_fields() -> void:
	if _syncing or editor_document == null or _config.is_empty() or not editor_document.get_enemies_enabled():
		return
	var candidate := _config.duplicate(true)
	var limit_text := limit_field.text.strip_edges()
	var health_text := health_field.text.strip_edges()
	if not limit_text.is_valid_int() or limit_text.to_int() < 1 or limit_text.to_int() > 256:
		_report(tr("敌人模块数量限制必须为 1～256 的整数。"))
		_restore_numbers()
		return
	if not health_text.is_valid_float() or not is_finite(health_text.to_float()) or health_text.to_float() < 0.01 or health_text.to_float() > 1000000:
		_report(tr("敌人耐久度必须为 0.01～1000000 的数值。"))
		_restore_numbers()
		return
	candidate.module_limit = limit_text.to_int()
	candidate.module_health = health_text.to_float()
	if candidate.module_ids.size() > candidate.module_limit:
		_report(tr("请先移除多余的组合模块，再降低数量限制。"))
		_restore_numbers()
		return
	if candidate == _config:
		_restore_numbers()
		return
	var result := editor_document.set_enemy_template(candidate, registry)
	sync_from_document()
	_restore_numbers()
	if not result.is_ok():
		_report(tr(result.errors[0]))


## 回填规范数值而不通过文本信号产生新的文档事务。
func _restore_numbers() -> void:
	limit_field.text = str(int(_config.module_limit))
	health_field.text = JSON.stringify(_config.module_health).trim_suffix(".0")


## 开关保存已有敌人和模板，关闭时通知主编辑器取消尚未落地的预览。
func _on_enabled_toggled(enabled: bool) -> void:
	if _syncing or editor_document == null:
		return
	commit_fields()
	var result := editor_document.set_enemies_enabled(enabled)
	sync_from_document()
	enabled_changed.emit(editor_document.get_enemies_enabled())
	if not result.is_ok():
		_report(tr(result.errors[0]))


## 同一文档的无关修改保留正在键入的数字；撤销、载入及 JSON 修改必须回填新模型值。
func sync_from_document() -> void:
	if editor_document == null or registry == null or not is_node_ready():
		return
	_syncing = true
	var candidate := editor_document.get_enemy_template(registry)
	var replaced := _synced_document != editor_document.document
	var rebuild: bool = _choices.size() != _slot_count(candidate) or candidate.get("module_ids") != _config.get("module_ids")
	_feedback_label.hide()
	if replaced or not limit_field.has_focus() or candidate.get("module_limit") != _config.get("module_limit"):
		limit_field.text = str(int(candidate.module_limit))
	if replaced or not health_field.has_focus() or candidate.get("module_health") != _config.get("module_health"):
		health_field.text = JSON.stringify(candidate.module_health).trim_suffix(".0")
	_config = candidate
	_synced_document = editor_document.document
	if rebuild:
		_rebuild_slots()
	var enabled := editor_document.get_enemies_enabled()
	enable_switch.set_pressed_no_signal(enabled)
	enable_switch.queue_redraw()
	_set_controls_enabled(enabled)
	_syncing = false


## 只有实际槽位数改变才重建药丸，避免数值失焦时销毁刚点中的选择按钮。
func _slot_count(config: Dictionary) -> int:
	var next_slot := mini(int(config.module_limit), config.module_ids.size() + 1)
	return mini(256, maxi(4, ceili(next_slot / 4.0) * 4))


## 四个并排药丸保留参考图的空槽；更多组合按四列换行，不横向撑大属性卡片。
func _rebuild_slots() -> void:
	_picker.close_menu(false)
	_active_choice = null
	for child in _slots.get_children():
		_slots.remove_child(child)
		child.queue_free()
	_choices.clear()
	var count := _slot_count(_config)
	for index in count:
		var slot := HBoxContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.add_theme_constant_override("separation", 2)
		_slots.add_child(slot)
		if index % 4 != 0:
			GameTheme.label(slot, "+", 11).size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var choice := EnemyModuleChoice.new()
		choice.name = "EnemyModuleSlot%d" % index
		choice.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		choice.clip_text = true
		choice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		choice.expand_icon = true
		choice.add_theme_constant_override("icon_max_width", 14)
		choice.add_theme_constant_override("h_separation", 2)
		choice.add_theme_font_size_override("font_size", 11)
		choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice.custom_minimum_size = Vector2(44, 28)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			var style := GameTheme.box(Color.TRANSPARENT if state == "focus" else Color("EAEDF2"), GameTheme.ACCENT if state == "focus" else Color.TRANSPARENT, 18)
			style.content_margin_left = 5
			style.content_margin_right = 14
			style.content_margin_top = 3
			style.content_margin_bottom = 3
			choice.add_theme_stylebox_override(state, style)
		slot.add_child(choice)
		choice.add_item(tr("空"))
		choice.set_item_metadata(0, "")
		var selected_id := str(_config.module_ids[index]) if index < _config.module_ids.size() else ""
		for module_id: String in registry.modules:
			var definition := registry.get_module(module_id)
			choice.add_icon_item(load(definition.texture) as Texture2D, tr(definition.display_name))
			var item := choice.item_count - 1
			choice.set_item_metadata(item, module_id)
			if module_id == selected_id:
				choice.select(item)
		choice.tooltip_text = tr(registry.get_module(selected_id).display_name) if registry.get_module(selected_id) != null else tr("选择模块；设为空可移除此槽位。")
		choice.item_selected.connect(_on_module_selected.bind(index))
		choice.popup_requested.connect(_open_module_picker)
		_choices.append(choice)


## 所有药丸共用一个玻璃菜单，展开不改变字段布局或已选模块。
func _open_module_picker(choice: EnemyModuleChoice) -> void:
	if choice.disabled or not editor_document.get_enemies_enabled():
		return
	_active_choice = choice
	_picker.popup_at(choice, choice.items_snapshot(), choice.selected)


## 先更新药丸选项，再复用原有组合校验与可撤销的文档事务。
func _on_picker_selected(index: int) -> void:
	if not is_instance_valid(_active_choice) or _active_choice.disabled:
		return
	var slot := _choices.find(_active_choice)
	_active_choice.select(index)
	_active_choice.item_selected.emit(index)
	# 选择可能同步重建药丸，把焦点交还同一槽位的新按钮而非已释放的旧入口。
	if slot >= 0 and slot < _choices.size():
		_choices[slot].grab_focus()


## 模块组合只保留实际选择的模块，顺序就是地图上共边排列的顺序。
func _on_module_selected(_item: int, _slot: int) -> void:
	if _syncing or not editor_document.get_enemies_enabled():
		return
	commit_fields()
	var selected: Array[String] = []
	for choice in _choices:
		var module_id := str(choice.get_item_metadata(choice.selected))
		if not module_id.is_empty():
			selected.append(module_id)
	if selected.is_empty() or selected.size() > int(_config.module_limit):
		_report(tr("组合至少需要一个模块，且不能超过敌人模块数量限制。"))
		_rebuild_slots()
		_set_controls_enabled(true)
		return
	var candidate := _config.duplicate(true)
	candidate.module_ids = selected
	var result := editor_document.set_enemy_template(candidate, registry)
	sync_from_document()
	if not result.is_ok():
		_rebuild_slots()
		_set_controls_enabled(editor_document.get_enemies_enabled())
		_report(tr(result.errors[0]))


## 禁用既改变外观也关闭输入，灰色表单不会通过键盘或下拉菜单继续修改。
func _set_controls_enabled(enabled: bool) -> void:
	if not enabled:
		_picker.close_menu(false)
		_active_choice = null
	_settings_body.modulate = Color.WHITE if enabled else Color(1, 1, 1, 0.42)
	limit_field.editable = enabled
	health_field.editable = enabled
	place_button.disabled = not enabled
	for choice in _choices:
		choice.disabled = not enabled


## 放置前提交数字，地图预览始终使用当前已验证的文档模板。
func _request_placement() -> void:
	commit_fields()
	if editor_document != null and editor_document.get_enemies_enabled():
		placement_requested.emit()


## 切换语言只刷新显示名称，不翻译模块 ID 或重写作者数据。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and registry != null:
		_rebuild_slots()
		_set_controls_enabled(editor_document.get_enemies_enabled())


## 在当前表单内展示输入错误，避免无效组合悄悄失效。
func _report(message: String) -> void:
	_feedback_label.text = message
	_feedback_label.show()
	feedback.emit(message)
