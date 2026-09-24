class_name GameWorkbench
extends Control
## 单关工作台：左边观察世界，右边编程或组装；游戏规则只通过 GameSession 调用。

signal draft_changed
signal save_requested
signal edit_modules_requested
signal back_requested
signal help_requested
signal commands_requested
signal actions_requested

var header: ProgramHeader
var _actions_menu: ProgramActionsMenu
var _guide_menu: WorkbenchGuideMenu
var _guide_button: Button
var _preview_button: Button
var _preview_layout: WorkbenchPreviewLayout
var _preview_input_shield: Control
var _preview_deselect_on_focus_loss := true
var _full_preview_requested := false
var _showing_preview_result := false
var _live_status: WorkbenchStatusPill
var session: GameSession
var registry: ContentRegistry
var settings: GameSettings
var allow_draft_save: bool = true
var _playfield: PlayfieldCanvas
var _world_panel: PanelContainer
var _world_scroll: ScrollContainer
var _assembly_panel: AssemblyPanel
var _code: CodeEdit
var _completion: ProgramInlineCompletion
var _code_color_mode := ""
var _hint_button: Button
var _hint_undo_button: Button
var _hint_backdrop: BackBufferCopy
var _hint_undo_versions: Array[int] = []
var _hint_base_right_margins: Dictionary = {}
var _hint_space_reserved := false
var _hint_busy := false
var _hint_notice := ""
var _hint_error := false
var _tabs: TabContainer
var _edit_panel: PanelContainer
var _mode_pill: Panel
var _assembly_tab_button: Button
var _program_tab_button: Button
var _entry_hint: Label
var _program_entry_text: String
var _status_row: HBoxContainer
var _run_button: Button
var _pause_button: Button
var _stop_button: Button
var _reset_code_button: Button
var _status: Label
var _position_label: Label
var _object_status: Label
var _accumulator: float = 0.0
var _highlighted_line: int = -1
var _syncing: bool = false


## 绑定无 UI 的会话模型；外层应在加入场景树前设置 session 和 registry。
func _ready() -> void:
	_build_ui()
	GameI18n.localize_text_edit_menu(_code)
	session.changed.connect(_sync_session)
	_code.text = session.source
	_code.text_changed.connect(_on_code_changed)
	_code.gui_input.connect(_on_code_input)
	_completion = ProgramInlineCompletion.new()
	_completion.name = "InlineCompletion"
	_completion.editor = _code
	_completion.level = session.level
	_completion.assembly = session.assembly
	_code.add_child(_completion)
	if settings != null:
		settings.changed.connect(_sync_completion_setting)
	_sync_completion_setting()
	_refresh_assembly()
	_sync_session()


## 全局偏好即时同步；独立工作台也默认开启，不自行访问玩家设置文件。
func _sync_completion_setting() -> void:
	_completion.enabled = settings.tab_completion if settings != null else true
	_sync_code_color_setting()
	_sync_hint_button()


## 设置通知只给已有编辑器换色，不重建工作台、不同步源码或触碰运行状态。
func _sync_code_color_setting() -> void:
	var mode := settings.code_color_mode if settings != null else "light"
	if mode == _code_color_mode:
		return
	_code_color_mode = mode
	GameTheme.style_code(_code, mode)
	_style_code_assist_buttons()
	# 当前行可能来自语法错误或正在运行的指令，保留原行号并刷新对应底色。
	_highlight_line(_highlighted_line + 1)
	if _completion != null:
		_completion.queue_redraw()


## 动态错误逐条翻译，语言改变后重新生成按钮提示而不改写玩家程序。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_sync_session()


## 固定步长推动解释器，暂停、编辑和结束期间不累积未执行时间。
func _process(delta: float) -> void:
	if session.state != GameSession.State.RUNNING:
		_accumulator = 0.0
		return
	_accumulator += delta
	while _accumulator >= SimulationWorld.TICK_DURATION and session.state == GameSession.State.RUNNING:
		_accumulator -= SimulationWorld.TICK_DURATION
		session.step()


## 离开工作台时停止动作，返回组装或退出关卡都不能遗留仍在运行的解释器。
func _exit_tree() -> void:
	if _actions_menu != null:
		_actions_menu.close_menu(false)
	if _guide_menu != null:
		_guide_menu.close_menu(false)
	if session != null:
		# 页面已经移出场景树时立即退订，避免等待queue_free的同帧仍收到旧会话刷新。
		if session.changed.is_connected(_sync_session):
			session.changed.disconnect(_sync_session)
		session.stop()


## 页头集中导航与图标操作；地图和代码区上移，所有操作仍调用原有会话入口。
func _build_ui() -> void:
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layout)
	header = ProgramHeader.new()
	header.name = "ProgramHeader"
	layout.add_child(header)
	header.configure_level(session.level.display_name, _goal_text(), not allow_draft_save)
	header.back_requested.connect(_request_back)
	header.run_requested.connect(_run_program)
	header.pause_requested.connect(_toggle_pause)
	header.stop_requested.connect(_stop_program)
	header.reset_requested.connect(_reset_position)
	header.more_requested.connect(_show_actions_menu)
	header.commands_requested.connect(_request_commands)
	_run_button = header.run_button
	_pause_button = header.pause_button
	_stop_button = header.stop_button
	_actions_menu = ProgramActionsMenu.new()
	_actions_menu.name = "ProgramActionsMenu"
	add_child(_actions_menu)
	_actions_menu.set_save_allowed(allow_draft_save)
	_actions_menu.help_requested.connect(help_requested.emit)
	_actions_menu.edit_modules_requested.connect(_request_module_edit)
	_actions_menu.reset_requested.connect(_reset_position)
	_actions_menu.reset_code_requested.connect(_reset_code)
	_actions_menu.save_requested.connect(_request_draft_save)
	_reset_code_button = _actions_menu._items[3]
	_guide_menu = WorkbenchGuideMenu.new()
	_guide_menu.name = "WorkbenchGuideMenu"
	add_child(_guide_menu)
	_guide_menu.configure(_goal_text(), session.level.description)
	_object_status = _guide_menu.status_label
	# 卡片向两侧扩展，页头仍保留与选关页一致的导航位置。
	var workspace := GameTheme.margin(layout, 0)
	workspace.name = "WorkbenchCards"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("margin_left", -14)
	workspace.add_theme_constant_override("margin_right", -14)
	_preview_layout = WorkbenchPreviewLayout.new()
	_preview_layout.name = "WorkbenchPreviewLayout"
	_preview_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(_preview_layout)
	_build_world_panel(_preview_layout.split)
	_build_edit_panel(_preview_layout.split)
	_preview_layout.configure(_world_panel, _edit_panel)
	_preview_layout.transition_started.connect(_on_preview_started)
	_preview_layout.transition_finished.connect(_on_preview_finished)
	_preview_input_shield = Control.new()
	_preview_input_shield.name = "PreviewTransitionInputShield"
	_preview_input_shield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_input_shield.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_input_shield.z_index = 1000
	_preview_input_shield.hide()
	add_child(_preview_input_shield)


## 更多菜单与外层指令资料互斥；弹出时不暂停或重启模拟。
func _show_actions_menu() -> void:
	if _preview_busy():
		return
	_guide_menu.close_menu(false)
	actions_requested.emit()
	_actions_menu.popup_at(header.more_button)


## 阅读资料前关闭操作菜单，资料本身不改写正在编辑的代码或装配。
func _request_commands() -> void:
	if _preview_busy():
		return
	_guide_menu.close_menu(false)
	_actions_menu.close_menu(false)
	commands_requested.emit()


## 保存仍交由 Shell 处理恢复备份和反馈；地图编辑器试玩没有持久化入口。
func _request_draft_save() -> void:
	if _preview_busy():
		return
	if allow_draft_save:
		save_requested.emit()


## 展示同一地图数据和世界位置；目标标记由 PlayfieldCanvas 独立叠加。
func _build_world_panel(parent: Node) -> void:
	var panel := PanelContainer.new()
	_world_panel = panel
	panel.custom_minimum_size.x = 410
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", GameTheme.card())
	parent.add_child(panel)
	var layout := VBoxContainer.new()
	panel.add_child(layout)
	var scroll := ScrollContainer.new()
	_world_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	var centered := CenterContainer.new()
	centered.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centered.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(centered)
	_playfield = PlayfieldCanvas.new()
	_playfield.level = session.level
	_playfield.registry = registry
	_playfield.editing_enabled = false
	_playfield.cell_size = 48.0
	centered.add_child(_playfield)
	scroll.resized.connect(_fit_playfield)
	_build_guide_button(panel)


## 目标文案统一供页头和指引读取，不依赖地图卡片上的常驻标签。
func _goal_text() -> String:
	if session.level.completion_mode == "reach_or_clear":
		if session.total_enemy_count() == 0:
			return "限时目标：到达终点。" if session.level.goal_type in ["reach_position", "escape_prison", "escape_alarms"] else "限时测试：可按需添加终点或敌人作为通关目标。"
		return "限时目标：到达终点或清除全部敌人。" if session.level.goal_type in ["reach_position", "escape_prison", "escape_alarms"] else "限时目标：清除全部敌人。"
	match session.level.goal_type:
		"dodge_attacks":
			return "目标：存活并连续躲过敌人的全部突袭。"
		"destroy_object":
			return "目标：用近战模块摧毁紫色障碍物。"
		"destroy_enemy":
			return "目标：存活并击毁敌人的所有模块。"
		"destroy_waves":
			if session.level.id == "level_015":
				return "雷达事件自动更新目标，隔栅栏击毁全部敌人。"
			if session.level.id == "level_014":
				return "目标：沿主通道推进，隔栅栏击毁全部 10 波敌人。"
			return ("目标：守住中心，击毁全部 10 波随机方向的来敌。" if session.level.id == "level_013" else "目标：存活并击毁八个方向依次来袭的敌人。")
		"escape_alarms":
			return "本关目标：同时解除左右两个警报器，再向上逃出监狱。"
		"escape_prison":
			return "目标：先解除警卫，再破坏警报器，最后向上离开。"
	return "目标：让机器的中心标记到达绿色终点。" if session.level.has_goal else "自由测试：此地图没有设置终点。"


## 指引向左让出一个按钮的位置，状态药丸始终位于指引按钮正左方。
func _build_guide_button(panel: PanelContainer) -> void:
	var overlay := Control.new()
	overlay.name = "WorldGuideAnchor"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(overlay)
	_guide_button = _world_icon_button(overlay, "WorldGuideButton", "res://assets/ui/workbench_guide.svg", "指引", 32.0)
	_guide_button.pressed.connect(_show_guidance)
	_preview_button = _world_icon_button(overlay, "WorldPreviewButton", "res://assets/ui/workbench_expand.svg", "全尺寸预览", 0.0)
	_preview_button.toggle_mode = true
	_preview_button.pressed.connect(_toggle_full_preview)
	_live_status = WorkbenchStatusPill.new()
	_live_status.name = "WorldLiveStatus"
	_live_status.right_inset = 64.0
	overlay.add_child(_live_status)


## 两个圆形按钮共用尺寸与 SVG 绘制规范，随地图卡片右边缘移动。
func _world_icon_button(parent: Control, node_name: String, icon_path: String, hint: String, right_inset: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.tooltip_text = hint
	button.icon = load(icon_path)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 14)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.custom_minimum_size = Vector2(24, 24)
	for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(color_name, Color.WHITE)
	button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.36))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color("E0E5EC") if state in ["hover", "hover_pressed"] else Color("D8E3F1") if state == "pressed" else Color("EAEDF2")
		var style := GameTheme.box(Color.TRANSPARENT if state == "focus" else fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 12)
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	parent.add_child(button)
	button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	button.offset_left = -24 - right_inset
	button.offset_right = -right_inset
	button.offset_bottom = 24
	return button


## 全尺寸预览只改变卡片呈现，不暂停模拟、不重建地图或编辑器。
func _toggle_full_preview() -> void:
	if _preview_busy() or _tabs.current_tab != 0:
		return
	_preview_layout.toggle_preview()


## 动画开始前关闭浮层并锁住所有操作，避免旧坐标上的点击或运行快捷键误触发。
func _on_preview_started(expanding: bool) -> void:
	# 使用目标状态，展开途中完成也能反馈，开始收回就停止展示全尺寸结果。
	_full_preview_requested = expanding
	if expanding:
		_preview_deselect_on_focus_loss = _code.deselect_on_focus_loss_enabled
		# 临时隐藏和换父节点会释放焦点，但不应清掉玩家原有文字选区。
		_code.deselect_on_focus_loss_enabled = false
	_actions_menu.close_menu(false)
	_guide_menu.close_menu(false)
	actions_requested.emit()
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		focused.release_focus()
	_preview_button.set_pressed_no_signal(expanding)
	_preview_input_shield.show()
	_sync_session()


## 卡片归位后重新计算当前会话权限，并恢复预览按钮外观和地图比例。
func _on_preview_finished(expanded: bool) -> void:
	if not expanded:
		_restore_preview_selection_behavior()
	_preview_input_shield.hide()
	_preview_button.icon = load("res://assets/ui/workbench_collapse.svg" if expanded else "res://assets/ui/workbench_expand.svg")
	_preview_button.set_pressed_no_signal(expanded)
	_preview_button.tooltip_text = "缩小至小尺寸" if expanded else "全尺寸预览"
	_sync_session()
	_fit_playfield.call_deferred()


## 恢复正常失焦行为前保存选区；Godot 重新启用该行为会立即清空无焦点的选择。
func _restore_preview_selection_behavior() -> void:
	var selections: Array[Dictionary] = []
	for index in _code.get_caret_count():
		if _code.has_selection(index):
			selections.append({"caret": index, "from_line": _code.get_selection_from_line(index), "from_column": _code.get_selection_from_column(index), "to_line": _code.get_selection_to_line(index), "to_column": _code.get_selection_to_column(index)})
	_code.release_focus()
	_code.deselect_on_focus_loss_enabled = _preview_deselect_on_focus_loss
	for selection: Dictionary in selections:
		_code.select(selection.from_line, selection.from_column, selection.to_line, selection.to_column, selection.caret)


## 统一查询过渡状态，信号触发、键盘快捷键和真实鼠标输入遵守同一个锁。
func _preview_busy() -> bool:
	return _preview_layout != null and _preview_layout.transitioning


## 动画期间拦截键鼠事件；动画外由原有控件和弹窗处理。
func _input(event: InputEvent) -> void:
	if _preview_busy() and (event is InputEventMouse or event is InputEventKey):
		get_viewport().set_input_as_handled()


## 页头返回也经过过渡锁，不能在正在重排卡片时触发重复导航。
func _request_back() -> void:
	if not _preview_busy():
		back_requested.emit()


## 保留停止和重置的原会话行为，过渡过程中忽略排队的操作。
func _stop_program() -> void:
	if not _preview_busy():
		session.stop()


## 重置位置无需退出全尺寸状态，但不能打断卡片动画。
func _reset_position() -> void:
	if not _preview_busy():
		_hint_notice = ""
		session.reset()


## 指引只切换资料浮层；打开时关闭其它浮层，模拟和草稿继续由原会话控制。
func _show_guidance() -> void:
	if _preview_busy():
		return
	_actions_menu.close_menu(false)
	actions_requested.emit()
	_guide_menu.popup_at(_guide_button)


## 卡片内以图标胶囊切换程序与组装；原页签继续共用会话和关卡限制。
func _build_edit_panel(parent: Node) -> void:
	_edit_panel = PanelContainer.new()
	_edit_panel.name = "WorkbenchEditCard"
	_edit_panel.custom_minimum_size.x = 430
	_edit_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_panel.add_theme_stylebox_override("panel", GameTheme.card())
	parent.add_child(_edit_panel)
	var column := VBoxContainer.new()
	_edit_panel.add_child(column)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 10)
	column.add_child(heading)
	_build_mode_pill(heading)
	_entry_hint = GameTheme.label(heading, "", 14, true)
	_entry_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_entry_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tabs = TabContainer.new()
	_tabs.tabs_visible = false
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	column.add_child(_tabs)
	var program_tab := VBoxContainer.new()
	program_tab.name = "程序"
	_tabs.add_child(program_tab)
	var entry_text := "main() 执行一次；tick() 每 0.1 秒调用一次。" if session.level.allow_tick else "程序从 main() 开始，依次执行每条指令。"
	if session.level.allow_loops:
		entry_text = "loop { ... } 按顺序重复块内指令，直到关卡结束。"
	if session.level.allow_conditionals:
		entry_text = "if / else 根据射击是否就绪，选择不同动作。"
	if session.level.allow_simultaneous:
		entry_text = "同步启动多个动作，全部完成后继续执行。"
	if session.level.allow_distance:
		entry_text = "distance(角度) 测量前方距离，边探路边移动。"
	if session.level.allow_radar and session.level.goal_type == "destroy_enemy":
		entry_text = "反复扫描敌人，在射击冷却期间追近，再重新瞄准。"
	if session.level.allow_functions:
		entry_text = "把检测与闪避写进 function，再从 main() 调用。"
	if session.level.allow_for:
		entry_text = "for 按步长遍历角度，用一组指令检查不同方向。"
	if session.level.id == "level_013":
		entry_text = "用 scan() 锁定目标，再将 Angle() 交给射击模块。"
	if session.level.id == "level_014":
		entry_text = "移动中反复 scan()，发现敌人后用 Angle() 瞄准射击。"
	if session.level.allow_radar_events:
		entry_text = "使用 onDetected 绑定目标变量，再从 main() 中判断并射击。"
	_program_entry_text = entry_text
	_entry_hint.text = entry_text
	_code = CodeEdit.new()
	_code.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.custom_minimum_size.y = 260
	_code.gutters_draw_line_numbers = true
	_code.auto_brace_completion_enabled = true
	_code.indent_size = 4
	_code.add_theme_font_size_override("font_size", 17)
	_code_color_mode = settings.code_color_mode if settings != null else "light"
	GameTheme.style_code(_code, _code_color_mode)
	program_tab.add_child(_code)
	_build_hint_button()
	var help_text := "move(角度, 距离)  ·  一行一条指令，不使用分号\n支持 // 注释。Ctrl+Enter 运行。\n本关只开放 main() 和 move，循环与其他能力稍后解锁。"
	if "attack" in session.level.allowed_calls:
		help_text = "move(角度, 距离) · attack(角度)\n近战射程 2 格，从近战模块中心计算。\n一行一条指令，支持 // 注释。Ctrl+Enter 运行。"
	if "shoot" in session.level.allowed_calls:
		help_text = "shoot(角度) · 0° 向右\n子弹减速，命中伤害随速度降低；冷却中调用无效果。\n把 shoot(0) 写在 tick() 中持续射击。Ctrl+Enter 运行。" if session.level.allow_tick else "shoot(角度) · 0° 向右\n子弹减速，命中伤害随速度降低；冷却中调用无效果。"
	if session.level.allow_named_calls:
		help_text = "模块名.attack(角度) · 只调用该模块\n直接 attack 会调用所有近战模块。\n命名同样支持 move 和 shoot；Ctrl+Enter 运行。"
	if session.level.allow_loops:
		help_text = "观察一组台阶，把重复的动作写进 loop。\n花括号内一行一条指令，填写后再运行。\n暂停保留循环进度；Ctrl+Enter 运行。"
	if session.level.allow_conditionals:
		help_text = "模块名.ready() 查询射击冷却，不会开火。\n在 loop 中用 if / else 选择射击或后退。\nif 必须填写动作；else 可省略。Ctrl+Enter 运行。"
	if session.level.allow_simultaneous:
		help_text = "simultaneously { ... } 同一帧启动块内动作。\n使用不同的模块名分别控制左右攻击，全部完成后再移动。\n警报解除前移动或先后拆除都会报警；Ctrl+Enter 运行。"
	if session.level.allow_distance:
		help_text = "distance(角度) 从测距模块中心测量，不消耗时间。\n测得距离减去安全间隙，再交给 move；用 loop 重复转弯。\n请留意整个装配的占地；Ctrl+Enter 运行。"
	if session.level.allow_radar and session.level.goal_type == "destroy_enemy":
		help_text = "scan() 探测目标；先判断 != null，再读取 Angle() 和 Distance。\n用 ready() 配合短距离移动与射击；常量、变量可选用。\n敌人随机游走，及时重新扫描；Ctrl+Enter 运行。"
	if session.level.allow_functions:
		help_text = "function 定义一组可重复调用的指令。\n用 distance 检测敌人接近，再用 if 选择闪避方向。\n函数写在 main() 外；用 loop 重复调用。Ctrl+Enter 运行。"
	if session.level.goal_type == "destroy_waves":
		help_text = "用 for 遍历八个方向，把角度交给 distance 和 shoot。\n先测距再射击，用 loop 持续警戒下一波来敌。\n迭代变量只在 for 块内有效；Ctrl+Enter 运行。"
	if session.level.id == "level_013":
		help_text = "用 scan() 扫描目标，判断 != null 后读取 Angle()。\n把角度交给 shoot，用 loop 持续扫描与射击。\n击毁全部 10 波来敌；Ctrl+Enter 运行。"
	if session.level.id == "level_014":
		help_text = "用 loop 反复扫描；有目标时射击，没有目标时短步向上移动。\n铁栅栏阻挡机器，但允许雷达、子弹与近战攻击通过。\n消灭全部 10 波；Ctrl+Enter 运行。"
	if session.level.allow_radar_events:
		help_text = "在 main() 外声明 variable，再用雷达 onDetected 绑定它。\n事件自动更新目标；无目标为 null，有目标时读取 Angle() 射击。\n没有目标时短步前进；Ctrl+Enter 运行。"
	var help := GameTheme.label(program_tab, help_text, 14, true)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_assembly_tab()
	_tabs.tab_changed.connect(_on_tab_changed)
	_on_tab_changed(0)
	_status_row = HBoxContainer.new()
	_status_row.name = "WorkbenchStatus"
	column.add_child(_status_row)
	_status = GameTheme.label(_status_row, "", 14)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_position_label = GameTheme.label(_status_row, "", 13, true)
	_position_label.custom_minimum_size.x = 160
	_position_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_position_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS


## 两个同尺寸 SVG 圆形按钮固定在代码区右上角，撤销紧邻提示左侧。
func _build_hint_button() -> void:
	_hint_backdrop = BackBufferCopy.new()
	_hint_backdrop.name = "CodeAssistBackdrop"
	_hint_backdrop.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	_code.add_child(_hint_backdrop)
	_hint_button = _code_assist_button("CodeHintButton", "代码提示", "workbench_code_hint", -16)
	_hint_button.pressed.connect(_apply_code_hint)
	_hint_undo_button = _code_assist_button("CodeHintUndoButton", "撤销提示", "workbench_hint_undo", -50)
	_hint_undo_button.pressed.connect(_undo_code_hint)
	_code.resized.connect(_sync_hint_backdrop)
	_style_code_assist_buttons()


## 统一提示与撤销的 SVG 比例、圆底和悬停样式，避免点击后残留蓝色边框。
func _code_assist_button(node_name: String, caption: String, asset: String, right: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.tooltip_text = caption
	button.icon = load("res://assets/ui/%s.svg" % asset)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 17)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.set_meta("assist_asset", asset)
	var glass := ColorRect.new()
	glass.name = "CodeAssistGlass"
	glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glass.show_behind_parent = true
	var glass_material := ShaderMaterial.new()
	glass_material.shader = load("res://assets/ui/code_assist_glass.gdshader")
	glass.material = glass_material
	button.add_child(glass)
	glass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_code.add_child(button)
	button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	button.offset_left = right - 28
	button.offset_right = right
	button.offset_top = 10
	button.offset_bottom = 38
	return button


## 随代码区选择更换两枚 SVG 和圆底；玻璃只画背景，保留原生图标及按钮状态反馈。
func _style_code_assist_buttons() -> void:
	var dark := _code_color_mode == "dark"
	for button: Button in [_hint_button, _hint_undo_button]:
		if button == null:
			continue
		var suffix := "_dark" if dark else ""
		button.icon = load("res://assets/ui/%s%s.svg" % [button.get_meta("assist_asset"), suffix])
		for state in ["normal", "hover", "hover_pressed", "pressed", "disabled", "focus"]:
			var fill := Color("E9EDF3") if state == "normal" else Color("EEF0F4") if state == "disabled" else Color("DFE6EE")
			if dark:
				fill = Color("30343B")
				fill.a = 0.28 if state == "normal" else 0.15 if state == "focus" else 0.60
				if state in ["hover", "hover_pressed"]:
					fill = Color(0.28, 0.30, 0.34, 0.40)
			var style := GameTheme.box(fill, Color.TRANSPARENT, 14)
			style.set_content_margin_all(5)
			button.add_theme_stylebox_override(state, style)
		for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
			button.add_theme_color_override(color_name, Color.WHITE)
		button.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.38) if dark else Color(1, 1, 1, 0.4))
	_sync_hint_backdrop()


## 只复制按钮附近的代码背景；全尺寸过渡使用同色圆底，避免与卡片合成缓冲互相采样。
func _sync_hint_backdrop() -> void:
	if _hint_backdrop == null or _hint_button == null or _hint_undo_button == null:
		return
	var glass_active := _code_color_mode == "dark" and _hint_button.visible and not _preview_busy() and not (_preview_layout != null and _preview_layout.expanded)
	_hint_backdrop.copy_mode = BackBufferCopy.COPY_MODE_RECT if glass_active else BackBufferCopy.COPY_MODE_DISABLED
	_hint_backdrop.rect = Rect2(Vector2(_code.size.x - 88, 2), Vector2(80, 44))
	for button: Button in [_hint_button, _hint_undo_button]:
		var glass := button.get_node("CodeAssistGlass") as ColorRect
		glass.visible = glass_active
		(glass.material as ShaderMaterial).set_shader_parameter("panel_size", button.size)


## 教学身份以正式资源路径为准；编辑器试玩即使借用教学地图也不启用代码提示。
func _hint_allowed() -> bool:
	if not allow_draft_save or session == null or session.level == null:
		return false
	if session.level.source_path != "res://data/levels/%s.json" % session.level.id:
		return false
	var mode := settings.code_hints if settings != null else "normal"
	return mode == "more" or (mode == "normal" and session.consecutive_failures >= 3)


## 三档门槛只读取设置与会话计数，撤销仅在最近一步确为提示插入时出现。
func _sync_hint_button() -> void:
	if _hint_button == null:
		return
	_hint_button.visible = _hint_allowed()
	_reserve_hint_space(_hint_button.visible)
	_hint_button.disabled = _hint_busy or _preview_busy() or session.state in [GameSession.State.RUNNING, GameSession.State.PAUSED, GameSession.State.SUCCEEDED] or (_preview_layout != null and _preview_layout.expanded)
	_hint_button.tooltip_text = "正在查找下一步…" if _hint_busy else "代码提示"
	_hint_undo_button.visible = _hint_button.visible and not _hint_undo_versions.is_empty() and _code.get_version() == _hint_undo_versions.back() and _code.has_undo()
	_hint_undo_button.disabled = _hint_button.disabled
	_sync_hint_backdrop()


## 提示出现时为按钮保留文字边距，长代码使用原生横向滚动而不被按钮遮住。
func _reserve_hint_space(active: bool) -> void:
	if active == _hint_space_reserved:
		return
	_hint_space_reserved = active
	for state in ["normal", "read_only", "focus"]:
		var style := _code.get_theme_stylebox(state).duplicate() as StyleBox
		if not _hint_base_right_margins.has(state):
			_hint_base_right_margins[state] = style.get_content_margin(SIDE_RIGHT)
		# 只缓存原始边距；保留当前色盘，避免收起提示时重新套回上一种背景。
		var original: float = _hint_base_right_margins[state]
		style.set_content_margin(SIDE_RIGHT, maxf(original, 88.0) if active else original)
		_code.add_theme_stylebox_override(state, style)


## 撤回最近一次提示的编辑事务；手工输入后隐藏入口，避免撤走玩家的新代码。
func _undo_code_hint() -> void:
	_sync_hint_button()
	if not _hint_undo_button.visible or _hint_undo_button.disabled:
		return
	_hint_undo_versions.pop_back()
	_code.undo()
	# CodeEdit 文本事件延迟发送，同帧保存/返回仍须读取已撤回的源码。
	session.source = _code.text
	draft_changed.emit()
	_hint_notice = "已撤销提示。"
	_hint_error = false
	_sync_session()
	_code.grab_focus()


## 只在明确点击时计算一条提示；源码修改共用一次撤销操作与原自动保存信号。
func _apply_code_hint() -> void:
	if _hint_button == null or not _hint_button.visible or _hint_button.disabled or _hint_busy:
		return
	_hint_busy = true
	_sync_hint_button()
	# 先呈现忙碌状态，再进行有时间上限的隔离验证；离开页面后不插入旧结果。
	await get_tree().process_frame
	if not is_inside_tree() or not _hint_allowed() or _preview_busy() or session.state in [GameSession.State.RUNNING, GameSession.State.PAUSED, GameSession.State.SUCCEEDED]:
		_hint_busy = false
		_sync_hint_button()
		return
	session.source = _code.text
	var result := CodeHintService.next_hint(session)
	_hint_busy = false
	if not result.is_ok():
		_hint_notice = "\n".join(result.errors)
		_hint_error = true
		_sync_session()
		return
	var next_source: String = result.value.source
	if next_source == _code.text:
		_hint_notice = "代码提示已完成。"
		_hint_error = false
		_sync_session()
		return
	session.stop()
	_syncing = true
	_code.remove_secondary_carets()
	_code.begin_complex_operation()
	_code.select_all()
	_code.insert_text_at_caret(next_source)
	_code.end_complex_operation()
	_hint_undo_versions.append(_code.get_version())
	if _hint_undo_versions.size() > 64:
		_hint_undo_versions.pop_front()
	_code.deselect()
	_code.set_caret_line(maxi(0, int(result.value.line) - 1))
	_code.set_caret_column(_code.get_line(_code.get_caret_line()).length())
	session.source = _code.text
	_syncing = false
	_hint_notice = str(result.value.message) + "\n" + tr("已补入一步代码，可撤销。")
	_hint_error = false
	_sync_session()
	_code.grab_focus()
	draft_changed.emit()


## 两个纯图标共用药丸外框，原生悬停提示跟随界面语言切换。
func _build_mode_pill(parent: Node) -> void:
	_mode_pill = Panel.new()
	_mode_pill.name = "WorkbenchModePill"
	_mode_pill.custom_minimum_size = Vector2(88, 44)
	_mode_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var background := GameTheme.box(Color("EAEDF2"), Color.TRANSPARENT, 22)
	background.set_content_margin_all(0)
	_mode_pill.add_theme_stylebox_override("panel", background)
	parent.add_child(_mode_pill)
	var group := ButtonGroup.new()
	for index in range(2):
		var button := Button.new()
		var assembly := index == 0
		button.name = "AssemblyModeButton" if assembly else "ProgramModeButton"
		button.tooltip_text = "组装" if assembly else "程序"
		button.icon = load("res://assets/ui/workbench_assembly.svg" if assembly else "res://assets/ui/workbench_program.svg")
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 20)
		button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(44, 44)
		button.position = Vector2(index * 44, 0)
		button.size = Vector2(44, 44)
		for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
			button.add_theme_color_override(color_name, Color.WHITE)
		for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			var fill := Color("DFE5ED") if state in ["hover", "hover_pressed"] else Color("E4E9F0") if state == "pressed" else Color.TRANSPARENT
			var style := GameTheme.box(fill, Color("A7CDFF") if state == "focus" else Color.TRANSPARENT, 22)
			style.set_content_margin_all(0)
			style.corner_radius_top_left = 22 if assembly else 0
			style.corner_radius_bottom_left = 22 if assembly else 0
			style.corner_radius_top_right = 0 if assembly else 22
			style.corner_radius_bottom_right = 0 if assembly else 22
			button.add_theme_stylebox_override(state, style)
		button.pressed.connect(_select_mode.bind(1 if assembly else 0))
		_mode_pill.add_child(button)
		if assembly:
			_assembly_tab_button = button
		else:
			_program_tab_button = button
	var divider := ColorRect.new()
	divider.color = Color("DCE1E8")
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.position = Vector2(43.5, 12)
	divider.size = Vector2(1, 20)
	_mode_pill.add_child(divider)


## 图标切换只改变当前页，保留编辑内容、装配和运行锁。
func _select_mode(index: int) -> void:
	if _preview_busy() or _preview_layout.expanded:
		return
	_tabs.current_tab = index


## 组装页签使用整行宽度展示双列；返回程序页签时恢复地图观察区。
func _on_tab_changed(index: int) -> void:
	if index != 0:
		_guide_menu.close_menu(false)
		_live_status.hide_status(true)
	_world_panel.visible = index == 0
	_program_tab_button.set_pressed_no_signal(index == 0)
	_assembly_tab_button.set_pressed_no_signal(index == 1)
	_entry_hint.text = _program_entry_text if index == 0 else "先组装机器，再开始编写程序。"
	# 显隐后容器需先分配新尺寸，再按实际观察区域调整地图比例。
	_fit_playfield.call_deferred()
	_sync_live_status.call_deferred()


## 工作台复用准备页的双列装配组件，目录、画布和所有编辑规则只维护一份。
func _build_assembly_tab() -> void:
	_assembly_panel = AssemblyPanel.new()
	_assembly_panel.name = "组装"
	_assembly_panel.settings = settings
	_assembly_panel.model = session.assembly
	_assembly_panel.registry = registry
	_assembly_panel.draft_changed.connect(_on_assembly_changed)
	_tabs.add_child(_assembly_panel)


## 编程输入只更新草稿；修改失败或成功后的程序会回到可重新运行状态。
func _on_code_changed() -> void:
	if _syncing:
		return
	if session.source == _code.text:
		_sync_hint_button()
		return
	_hint_notice = ""
	session.source = _code.text
	# 撤销重置或继续改写模板后，旧的“已恢复初始程序”提示不再描述当前内容。
	var edited_after_reset := session.message == "代码已恢复为本关初始程序。" and session.source != session.level.starter_program
	if session.state in [GameSession.State.FAILED, GameSession.State.SUCCEEDED] or edited_after_reset:
		session.stop()
	_sync_hint_button()
	draft_changed.emit()


## 返回独立组装页前同步最新源文本；不要求程序能编译，出错时也能继续改模块。
func _request_module_edit() -> void:
	if _preview_busy():
		return
	if session.source != _code.text:
		session.source = _code.text
		draft_changed.emit()
	# 这里只发出导航请求；外层复用会话并停止试运行，不经过重新进入关卡的初始化。
	edit_modules_requested.emit()


## 在代码编辑器内处理运行快捷键，避免 Ctrl+Enter 插入多余换行。
func _on_code_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.ctrl_pressed or event.meta_pressed) and event.keycode == KEY_ENTER:
		_run_program()
		_code.accept_event()


## 运行前同步文本，静态编译或装配错误由会话返回并显示到状态栏。
func _run_program() -> void:
	# 快捷键与禁用按钮遵守同一运行锁，避免反复按键清空正在推进的时间累加器。
	if _preview_busy() or session.state in [GameSession.State.RUNNING, GameSession.State.PAUSED]:
		return
	_hint_notice = ""
	session.source = _code.text
	_tabs.current_tab = 0
	_accumulator = 0.0
	session.run()
	_sync_session()


## 同一个按钮在暂停与继续之间切换，始终保留当前移动进度。
func _toggle_pause() -> void:
	if _preview_busy():
		return
	if session.state == GameSession.State.PAUSED:
		session.resume()
	else:
		session.pause()


## 将恢复初始代码作为一次可撤销编辑；仍走现有草稿事件，编辑器试玩不会写正式存档。
func _reset_code() -> void:
	if _preview_busy():
		return
	# 必须先取消旧解释器并解除编辑锁，运行中或暂停时也不能继续执行已替换的代码。
	_hint_notice = ""
	session.reset_code()
	_accumulator = 0.0
	_tabs.current_tab = 0
	_syncing = true
	if _code.text != session.source:
		# 重置针对整份程序，避免多光标状态把模板同时插入多个位置。
		_code.remove_secondary_carets()
		_code.begin_complex_operation()
		_code.select_all()
		_code.insert_text_at_caret(session.source)
		_code.end_complex_operation()
	_code.deselect()
	_code.set_caret_line(0)
	_code.set_caret_column(0)
	_code.scroll_vertical = 0.0
	_code.scroll_horizontal = 0
	_syncing = false
	_code.grab_focus()
	draft_changed.emit()


## 统一刷新运行按钮、世界显示和错误行，避免界面自行推断游戏结果。
func _sync_session() -> void:
	var locked := session.state in [GameSession.State.RUNNING, GameSession.State.PAUSED]
	var run_disabled := locked
	var run_reason := tr("程序正在运行或暂停，请先停止。") if locked else ""
	if not locked:
		# 顶部按钮与快捷键继续采用同一装配校验，菜单不会绕过执行权限。
		var prepared := session.assembly.build_document()
		run_disabled = not prepared.is_ok()
		if not prepared.is_ok():
			run_reason = GameI18n.translate_errors(prepared.errors)
	header.set_run_state(run_disabled, run_reason, session.state == GameSession.State.PAUSED, session.world != null, locked)
	var transitioning := _preview_busy()
	header.set_transition_locked(transitioning)
	_guide_button.disabled = transitioning
	_preview_button.disabled = transitioning
	_program_tab_button.disabled = transitioning
	_assembly_tab_button.disabled = transitioning
	_code.editable = not locked and not transitioning and not _preview_layout.expanded
	if _completion != null:
		_completion.refresh()
	_assembly_panel.interaction_enabled = not locked and not transitioning and not _preview_layout.expanded
	_playfield.world = session.world
	_playfield.attack_animation_enabled = session.state == GameSession.State.RUNNING
	_playfield.wreck_animation_enabled = session.state in [GameSession.State.RUNNING, GameSession.State.SUCCEEDED, GameSession.State.FAILED]
	_playfield.show_defeat_attack_feedback = session.state == GameSession.State.FAILED
	# 编辑预览只替换装配清单，不借助 create()，因空装配也需要能显示地图。
	if session.world == null:
		var preview := session.level.document.duplicate_document()
		preview.player_spawn.modules = session.assembly.modules.duplicate(true)
		_playfield.document = preview
	else:
		_playfield.document = session.world.document
	_playfield.refresh()
	_fit_playfield()
	_status.text = GameI18n.translate_errors(session.message.split("\n"))
	_status.add_theme_color_override("font_color", GameTheme.ERROR if session.state == GameSession.State.FAILED else GameTheme.SUCCESS if session.state == GameSession.State.SUCCEEDED else GameTheme.TEXT)
	_position_label.text = "准备就绪"
	if session.world != null:
		_position_label.text = tr("位置 (%.2f, %.2f)  ·  %.1f 秒") % [session.world.player.position.x, session.world.player.position.y, session.world.tick_index * SimulationWorld.TICK_DURATION]
	_position_label.visible = session.world != null
	_status_row.visible = session.world != null or session.state in [GameSession.State.FAILED, GameSession.State.SUCCEEDED] or session.message == "代码已恢复为本关初始程序。"
	_position_label.tooltip_text = _position_label.text
	_sync_object_status()
	_sync_live_status()
	_highlight_line(session.current_line)
	_sync_hint_button()
	if not _hint_notice.is_empty() and not locked:
		_status.text = GameI18n.translate_errors(_hint_notice.split("\n"))
		_status.add_theme_color_override("font_color", GameTheme.ERROR if _hint_error else GameTheme.TEXT)
		_status_row.show()


## 全尺寸结果优先替换同一药丸并保持显示；普通运行继续展示机关状态。
func _sync_live_status() -> void:
	if _live_status == null or _tabs == null:
		return
	if _tabs.current_tab != 0:
		_live_status.hide_status(true)
		return
	var finished := session.state in [GameSession.State.SUCCEEDED, GameSession.State.FAILED]
	if _full_preview_requested and finished:
		_showing_preview_result = true
		_live_status.status_label.add_theme_color_override("default_color", GameTheme.SUCCESS if session.state == GameSession.State.SUCCEEDED else GameTheme.ERROR)
		_live_status.show_status(GameI18n.translate_errors(session.message.split("\n")), true)
		return
	var active := session.state in [GameSession.State.RUNNING, GameSession.State.PAUSED] and not _object_status.text.is_empty()
	if active and session.level.goal_type == "reach_position" and session.world != null:
		# 路线关卡的闸门倒计时完成后不再常驻；敌人与障碍物状态跟随本次运行。
		active = false
		for entry: Dictionary in session.level.document.objects:
			var object := MapObjectDefinition.from_entry(entry)
			if object != null and object.kind == "timed_gate" and session.world.tick_index < object.close_after_ticks:
				active = true
	# 重试有即时状态时直接换字；退出全尺寸或重置则撤掉结果，不留下延迟收回回调。
	if _showing_preview_result:
		_showing_preview_result = false
		if not active:
			_live_status.hide_status(true)
	_live_status.status_label.add_theme_color_override("default_color", GameTheme.TEXT)
	if _full_preview_requested and session.state == GameSession.State.EDITING:
		_live_status.hide_status(true)
		return
	_live_status.show_status(_object_status.text, active)


## 按视口完整显示阶梯等较大关卡；极大导入地图保留最低可读网格与滚动条。
func _fit_playfield() -> void:
	if _world_scroll == null or _playfield == null or _playfield.document == null:
		return
	var available := _world_scroll.size - Vector2(16, 16)
	if available.x <= 0.0 or available.y <= 0.0:
		return
	var document := _playfield.document
	var fit := floorf(minf(available.x / document.width, available.y / document.height))
	var progress := _preview_layout.get_expand_progress() if _preview_layout != null else 0.0
	# 普通布局保留原上限；展开时逐渐解除上限，以完整地图的宽高比占用可用画幅。
	var upper := lerpf(48.0, maxf(48.0, fit), progress)
	var fitted := clampf(fit, 8.0, upper)
	if not is_equal_approx(_playfield.cell_size, fitted):
		_playfield.cell_size = fitted
		_playfield.refresh()


## 将解释器的一基行号转换为编辑器行索引，错误和执行位置使用不同底色。
func _highlight_line(line: int) -> void:
	if _highlighted_line >= 0 and _highlighted_line < _code.get_line_count():
		_code.set_line_background_color(_highlighted_line, Color.TRANSPARENT)
	_highlighted_line = line - 1
	if _highlighted_line < 0 or _highlighted_line >= _code.get_line_count():
		return
	var color := _code.get_theme_color("program_error_color" if session.state == GameSession.State.FAILED else "program_execution_color")
	_code.set_line_background_color(_highlighted_line, color)


## 完成一次装配修改后更新预览并通知外层保存草稿。
func _on_assembly_changed() -> void:
	if session.state not in [GameSession.State.RUNNING, GameSession.State.PAUSED]:
		session.stop()
	_refresh_assembly()
	draft_changed.emit()


## 刷新数量限制和网格，不直接重新创建装配模型。
func _refresh_assembly() -> void:
	_assembly_panel.refresh()


## 将模拟 tick 和目标状态投影为提示，暂停与重置无需额外 UI 计时器。
func _sync_object_status() -> void:
	if session.level.completion_mode == "reach_or_clear":
		var tick := session.world.tick_index if session.world != null else 0
		var status := tr("剩余 %.1f 秒") % (maxi(0, session.level.max_ticks - tick) * SimulationWorld.TICK_DURATION)
		if session.total_enemy_count() > 0:
			status += " · " + tr("剩余敌人 %d") % session.remaining_enemy_count()
		_object_status.text = status
		_object_status.show()
		return
	var lines := PackedStringArray()
	var tick := session.world.tick_index if session.world != null else 0
	if session.level.goal_type == "destroy_waves":
		_sync_wave_status()
		return
	if session.level.goal_type == "dodge_attacks":
		_sync_dodge_status()
		return
	if session.level.goal_type == "escape_alarms":
		_sync_paired_alarm_status()
		return
	if session.level.goal_type == "escape_prison":
		_sync_prison_status()
		return
	if session.level.goal_type == "destroy_enemy":
		var total := 0
		var alive := 0
		var health := 0.0
		if session.world != null:
			var enemy := session.world.get_machine(session.level.goal_enemy_id)
			if enemy != null:
				total = enemy.modules.size()
				for module in enemy.modules:
					if module.available:
						alive += 1
						health += module.health
		else:
			for entry: Dictionary in session.level.document.enemies:
				if entry.get("id") == session.level.goal_enemy_id:
					total = entry.modules.size()
					alive = total
					for module: Dictionary in entry.modules:
						health += float(entry.get("properties", {}).get("module_health", {}).get(module.id, 1.0))
		lines.append(tr("敌方耐久 %.1f") % health if session.level.allow_radar else tr("敌方模块 %d / %d") % [alive, total])
		if session.world != null:
			for module in session.world.player.modules:
				if module.available and not module.behavior.get_shoot_profile(module).is_empty():
					# 第七关面板与 ready 查询使用相同的下一动作 tick，避免提示与条件分支矛盾。
					var action_tick := tick + (1 if session.level.allow_conditionals else 0)
					var remaining := maxi(0, module.next_shoot_tick - action_tick)
					lines.append(tr("射击就绪") if remaining == 0 else tr("射击冷却 %.1f 秒") % (remaining * SimulationWorld.TICK_DURATION))
					break
		if session.level.max_ticks > 0:
			lines.append(tr("练习剩余 %.1f 秒") % (maxi(0, session.level.max_ticks - tick) * SimulationWorld.TICK_DURATION))
	for entry: Dictionary in session.level.document.objects:
		var object := MapObjectDefinition.from_entry(entry)
		if object == null:
			continue
		if object.kind == "timed_gate":
			var remaining := maxi(0, object.close_after_ticks - tick)
			lines.append(tr("闸门已落下") if remaining == 0 else tr("闸门将在 %.1f 秒后落下") % (remaining * SimulationWorld.TICK_DURATION))
		elif object.id == session.level.goal_object_id:
			var health := object.max_health
			if session.world != null:
				health = session.world.get_object(object.id).health
			lines.append(tr("障碍物已摧毁") if health <= 0 else tr("近战射程 2 格 · 障碍物耐久 %.0f") % health)
	_object_status.text = "\n".join(lines)
	_object_status.visible = not lines.is_empty()


## 波次只读真实世界进度，间隔和冷却均沿用同一模拟 tick，暂停时自然冻结。
func _sync_wave_status() -> void:
	var total := session.level.document.enemies.size()
	var completed := 0
	var lines := PackedStringArray()
	if session.world != null:
		var status: Dictionary = session.world.get_enemy_wave_status()
		total = int(status.get("total", total))
		completed = int(status.get("completed", 0))
		lines.append(tr("已击毁 %d / %d 波敌人") % [completed, total])
		if not status.get("all_cleared", false):
			if not str(status.get("active_enemy_id", "")).is_empty() and session.level.id not in ["level_014", "level_015"]:
				lines.append(tr("第 %d 波敌人来袭") % int(status.get("current", completed + 1)))
			# 第十三、十四关省略下一波倒计时，长廊仅显示击毁进度与射击状态。
			elif session.level.id not in ["level_013", "level_014", "level_015"] and int(status.get("next_spawn_tick", -1)) >= 0:
				var remaining := maxi(0, int(status.next_spawn_tick) - session.world.tick_index)
				lines.append(tr("下一波将在 %.1f 秒后出现") % (remaining * SimulationWorld.TICK_DURATION))
		for module in session.world.player.modules:
			if module.available and not module.behavior.get_shoot_profile(module).is_empty():
				var remaining := maxi(0, module.next_shoot_tick - session.world.tick_index - 1)
				lines.append(tr("射击就绪") if remaining == 0 else tr("射击冷却 %.1f 秒") % (remaining * SimulationWorld.TICK_DURATION))
				break
	else:
		lines.append(tr("已击毁 %d / %d 波敌人") % [completed, total])
		var guidance := "沿主通道前进，扫描两侧支道" if session.level.id == "level_014" else ("持续扫描，警戒任意方向" if session.level.id == "level_013" else "从八个方向持续警戒")
		if session.level.id == "level_015":
			guidance = "沿主通道前进，由雷达事件更新目标"
		lines.append(tr(guidance))
	_object_status.text = "\n".join(lines)
	_object_status.visible = true


## 越狱状态取自同一模拟快照，避免 UI 自己维护目标或出口的第二套规则。
func _sync_prison_status() -> void:
	var guard_cleared := false
	var alarm_cleared := false
	var alarm_triggered := false
	if session.world != null:
		var guard := session.world.get_machine(session.level.goal_enemy_id)
		var alarm := session.world.get_object(session.level.goal_object_id)
		guard_cleared = guard != null and guard.is_destroyed()
		alarm_cleared = alarm != null and alarm.health <= 0.0
		alarm_triggered = alarm != null and alarm.triggered
	var guard_text := tr("警卫已解除") if guard_cleared else tr("左侧警卫存活")
	var alarm_text := tr("警报已触发") if alarm_triggered else tr("警报器已拆除") if alarm_cleared else tr("右侧警报器待拆除")
	var exit_text := tr("出口已解锁 · 向上离开") if guard_cleared and alarm_cleared else tr("出口锁定")
	_object_status.text = guard_text + " · " + alarm_text + "\n" + exit_text
	_object_status.visible = true


## 双警报状态复用真实世界数据，进入全尺寸后由统一药丸切换到最终胜负反馈。
func _sync_paired_alarm_status() -> void:
	var alive := session.level.goal_alarm_ids.size()
	var triggered := false
	if session.world != null:
		alive = 0
		for alarm_id in session.level.goal_alarm_ids:
			var alarm := session.world.get_object(alarm_id)
			if alarm != null:
				if alarm.health > 0.0:
					alive += 1
				triggered = triggered or alarm.triggered
	_object_status.text = tr("警报已触发") if triggered else tr("警报已解除，出口已打开") if alive == 0 else tr("警报器 {alive} / {total}").format({"alive": alive, "total": session.level.goal_alarm_ids.size()})
	_object_status.visible = true


## 闪避计数与敌人阶段只读取模拟快照；暂停冻结，重置自动回到准备状态。
func _sync_dodge_status() -> void:
	var count := 0
	var phase_text := tr("等待开始")
	if session.world != null:
		var status: Dictionary = session.world.get_enemy_attack_status(session.level.goal_enemy_id)
		count = int(status.get("dodged", 0))
		match str(status.get("phase", "")):
			"tracking":
				phase_text = tr("敌人正在锁定")
			"approach":
				phase_text = tr("敌人正在接近")
			"attack":
				phase_text = tr("敌人正在突袭")
			"recover":
				phase_text = tr("敌人正在恢复")
	var progress := tr("已躲过 {count} / {total} 次攻击").format({"count": count, "total": session.level.goal_attack_count})
	_object_status.text = progress + " · " + phase_text
	_object_status.visible = true
