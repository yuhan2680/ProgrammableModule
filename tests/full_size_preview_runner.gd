extends SceneTree
## 实际工作台的全尺寸预览回归；夹具只写入本进程独占的 user://tests 子目录。

const STAIR_PROGRAM := "main() {\n    loop {\n        move(0, 3)\n        move(90, 2)\n    }\n}\n"
const GATE_PROGRAM := "main() {\n    move(0, 8)\n}\n"
const MAX_TRANSITION_FRAMES := 300

var _checks := 0
var _failures := 0
var _temporary := ""
var _transition_events: Array[String] = []


## 等待场景树初始化，并将逐帧等待限制在可预测的测试时长内。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 两种窗口覆盖长地图、交互屏障、运行状态药丸、重排和离场清理。
func _run() -> void:
	create_timer(42.0).timeout.connect(_timeout)
	_temporary = "user://tests/full_preview_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game.settings.set_language("zh_CN")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		await _test_staircase(game, dimensions)
	await _test_running_gate(game)
	await _test_exit_during_transition(game)
	game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("全尺寸预览回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从真实空装配流程进入编程；不替换正式地图、模板或玩家存档。
func _enter_program(game: GameShell, index: int) -> GameWorkbench:
	game._enter_level(game.catalog.levels[index])
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "安装测试中心移动模块")
	if index == 1:
		_check(game.session.assembly.add_module("movement", Vector2(0.5, 0), "drive2").is_ok(), "限时闸门安装第二个移动模块")
	game._confirm_assembly()
	await _settle()
	var workbench := game.workbench
	_check(game.page == GameShell.Page.PLAY and workbench != null, "真实确认装配进入编程页")
	if workbench != null:
		workbench._preview_layout.transition_started.connect(_record_transition_started)
		workbench._preview_layout.transition_finished.connect(_record_transition_finished)
	return workbench


## 第六关完整地图变大，原编辑器、选区、装配和页头在往返后逐项保留。
func _test_staircase(game: GameShell, dimensions: Vector2i) -> void:
	var workbench := await _enter_program(game, 5)
	if workbench == null:
		return
	workbench._code.text = STAIR_PROGRAM
	workbench._code.text_changed.emit()
	workbench._code.select(2, 8, 2, 12)
	workbench._code.set_caret_line(2)
	workbench._code.set_caret_column(12)
	workbench._assembly_panel._select_module(0)
	workbench.session.current_line = 3
	workbench._sync_session()
	workbench._preview_layout.split.split_offset = 68
	await _settle()
	var snapshot := _snapshot(workbench)
	var collapsed_world := workbench._world_panel.get_global_rect()
	var collapsed_editor := workbench._edit_panel.get_global_rect()
	var collapsed_cell := workbench._playfield.cell_size
	var label := "第六关 " + str(dimensions)
	_check(workbench._preview_button.is_visible_in_tree() and workbench._preview_button.icon != null and workbench._preview_button.text.is_empty() and workbench._preview_button.get_tooltip() == "全尺寸预览", "可见纯图标入口和中文悬停说明 " + label)
	_check(not workbench._preview_layout.expanded and not workbench._preview_layout.transitioning, "默认保持双卡片布局 " + label)
	_check_map_fits(workbench, "展开前 " + label)
	_check_corner_alignment(workbench, false, label)
	_transition_events.clear()
	workbench._preview_button.pressed.emit()
	_check(workbench._preview_layout.transitioning and not workbench._preview_layout.expanded, "点击立即进入展开过渡 " + label)
	_check(is_zero_approx(workbench._preview_layout.get_expand_progress()) and _rect_close(workbench._world_panel.get_global_rect(), collapsed_world), "先退去编辑区，再开始拓宽地图 " + label)
	_check(workbench._code.get_theme_font("font") == snapshot.font and workbench._code.get_theme_stylebox("normal") == snapshot.style, "过渡重新挂载时保留编辑器继承主题 " + label)
	if not _exercise_blocked_inputs(game, workbench, label + " 展开"):
		return
	if not await _wait_preview(workbench, true, label):
		return
	_check_expanded(workbench, snapshot, label)
	_check(workbench._playfield.cell_size > collapsed_cell, "阶梯使用新增空间增大网格 " + label)
	_check_map_fits(workbench, "展开后 " + label)
	_check(not workbench.header.run_button.disabled and not workbench.header.more_button.disabled and not workbench._guide_button.disabled and not workbench._preview_button.disabled, "完全展开后恢复可用操作 " + label)
	workbench._guide_button.pressed.emit()
	_check(workbench._guide_menu.is_open(), "完全展开可打开指引 " + label)
	workbench._guide_menu.close_menu(false)
	workbench.header.more_button.pressed.emit()
	_check(workbench._actions_menu.is_open(), "完全展开可打开更多菜单 " + label)
	workbench._actions_menu.close_menu(false)
	workbench.header.book_button.pressed.emit()
	_check(game._command_menu.is_open(), "完全展开可打开指令集合 " + label)
	game._command_menu.close_menu(false)
	workbench._preview_button.pressed.emit()
	if not _exercise_blocked_inputs(game, workbench, label + " 收回"):
		return
	if not await _wait_preview(workbench, false, label):
		return
	_check_restored(workbench, snapshot, collapsed_world, collapsed_editor, label)
	_check(_transition_events == ["start:true", "finish:true", "start:false", "finish:false"], "每次往返只发出对应起止信号 " + label)
	# 同一节点重复重排，避免把累计偏移误当作每次新建页面的默认尺寸。
	for cycle in 2:
		workbench._preview_button.pressed.emit()
		if not await _wait_preview(workbench, true, label):
			return
		if cycle == 0:
			root.size = Vector2i(1000, 740) if dimensions.x == 1280 else Vector2i(1280, 800)
			await _settle()
			_check_full_width(workbench, "展开中调整窗口 " + label)
			_check_map_fits(workbench, "调整窗口 " + label)
			root.size = dimensions
			await _settle()
			_check_full_width(workbench, "恢复窗口 " + label)
		workbench._preview_button.pressed.emit()
		if not await _wait_preview(workbench, false, label):
			return
		_check_restored(workbench, snapshot, collapsed_world, collapsed_editor, "往返 %d " % (cycle + 2) + label)
	workbench._assembly_tab_button.pressed.emit()
	await _settle()
	_check(workbench._tabs.current_tab == 1 and not workbench._world_panel.is_visible_in_tree() and workbench._assembly_panel.is_visible_in_tree(), "收回后仍能进入整行组装页 " + label)
	workbench._program_tab_button.pressed.emit()
	await _settle()
	_check_restored(workbench, snapshot, collapsed_world, collapsed_editor, "组装返回 " + label)
	workbench.header.back_button.pressed.emit()
	await _settle()
	_check(game.page == GameShell.Page.LEVELS, "收回后返回按钮恢复导航 " + label)


## 运行过渡保留世界与执行器；模拟时钟可继续，药丸跟随问号固定在其左侧。
func _test_running_gate(game: GameShell) -> void:
	root.size = Vector2i(1280, 800)
	var workbench := await _enter_program(game, 1)
	if workbench == null:
		return
	workbench._code.text = GATE_PROGRAM
	workbench._run_button.pressed.emit()
	_check(workbench.session.state == GameSession.State.RUNNING, "第二关从真实运行按钮启动")
	var world := workbench.session.world
	var runner := workbench.session.runner
	var header_rect := workbench.header.get_global_rect()
	workbench._preview_button.pressed.emit()
	if not _exercise_blocked_inputs(game, workbench, "闸门运行展开"):
		return
	if not await _wait_preview(workbench, true, "闸门运行展开"):
		return
	_check(workbench.session.world == world and workbench.session.runner == runner and workbench.session.state == GameSession.State.RUNNING, "展开保留同一次闸门运行")
	_check(world.tick_index > 0, "动画期间原有运行时钟仍能推进")
	_check(workbench._playfield.cell_size > 48.0, "全尺寸短地图突破原有 48 像素网格上限")
	_check_map_fits(workbench, "闸门全尺寸")
	_check_corner_alignment(workbench, true, "闸门全尺寸")
	_check(_rect_close(workbench.header.get_global_rect(), header_rect), "运行中展开也不改变顶部栏矩形")
	workbench.header.pause_button.pressed.emit()
	_check(workbench.session.state == GameSession.State.PAUSED, "完全展开后的暂停按钮可用")
	var paused_tick := world.tick_index
	workbench._preview_button.pressed.emit()
	if not _exercise_blocked_inputs(game, workbench, "闸门暂停收回"):
		return
	if not await _wait_preview(workbench, false, "闸门暂停收回"):
		return
	_check(workbench.session.world == world and workbench.session.runner == runner and workbench.session.state == GameSession.State.PAUSED and world.tick_index == paused_tick, "收回保留暂停及同一指令进度")
	_check_corner_alignment(workbench, true, "闸门收回")
	_check(not workbench._code.editable and not workbench._assembly_panel.interaction_enabled, "动画结束仍遵守原有暂停编辑锁")
	workbench.header.pause_button.pressed.emit()
	_check(workbench.session.state == GameSession.State.RUNNING, "收回后继续按钮恢复运行")
	workbench.header.stop_button.pressed.emit()
	_check(workbench.session.world == null and workbench._code.editable, "收回后停止恢复编辑")
	workbench._preview_button.pressed.emit()
	if not await _wait_preview(workbench, true, "闸门重新展开"):
		return
	workbench.header.run_button.pressed.emit()
	_check(workbench.session.state == GameSession.State.RUNNING, "完全展开后可以重新运行")
	workbench.header.reset_button.pressed.emit()
	_check(workbench.session.world == null and workbench.session.source == GATE_PROGRAM, "完全展开重置位置保留代码")
	workbench.header.back_button.pressed.emit()
	await _settle()
	_check(game.page == GameShell.Page.LEVELS, "完全展开时返回按钮可正常离开")


## 退出发生在动画时间线中时，绑定节点的补间与输入锁均随页面释放。
func _test_exit_during_transition(game: GameShell) -> void:
	var workbench := await _enter_program(game, 5)
	if workbench == null:
		return
	var weak_layout: WeakRef = weakref(workbench._preview_layout)
	workbench._preview_button.pressed.emit()
	_check(workbench._preview_layout.transitioning, "离场夹具确实处于动画中")
	game._back_to_levels()
	await _settle()
	_check(weak_layout.get_ref() == null and game.workbench == null, "中途离场释放布局和工作台")
	await create_timer(0.9).timeout
	_check(game.page == GameShell.Page.LEVELS, "旧动画结束时间不会修改后续页面")


## 禁用视觉与实际回调同时受保护，避免快捷键或信号绕过过渡屏障。
func _exercise_blocked_inputs(game: GameShell, workbench: GameWorkbench, label: String) -> bool:
	var session := workbench.session
	var world := session.world
	var runner := session.runner
	var state := session.state
	var source := workbench._code.text
	var modules := JSON.stringify(session.assembly.modules)
	var mode := workbench._tabs.current_tab
	var header := workbench.header
	_check(workbench._preview_layout.transitioning, "验证输入时动画确实尚未完成 " + label)
	for button: Button in [header.run_button, header.pause_button, header.stop_button, header.reset_button, header.more_button, header.book_button, workbench._guide_button, workbench._preview_button, workbench._assembly_tab_button, workbench._program_tab_button, header.back_button]:
		_check(button.disabled, "过渡禁用 " + str(button.name) + " " + label)
		button.pressed.emit()
		if game.workbench != workbench or game.page != GameShell.Page.PLAY:
			_check(false, "过渡期间导航不能离开工作台 " + label)
			return false
		_check(session.world == world and session.runner == runner and session.state == state, "受保护按钮不替换或改变运行 " + str(button.name) + " " + label)
	_check(not workbench._code.editable and not workbench._assembly_panel.interaction_enabled and not workbench._assembly_panel.canvas.interaction_enabled, "过渡锁定代码和装配输入 " + label)
	_check(not workbench._actions_menu.is_open() and not workbench._guide_menu.is_open() and not game._command_menu.is_open(), "过渡期间资料和菜单保持关闭 " + label)
	workbench._code.grab_focus()
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.physical_keycode = KEY_ENTER
	key.ctrl_pressed = true
	key.pressed = true
	root.push_input(key)
	workbench._on_code_input(key)
	key.pressed = false
	root.push_input(key)
	var text_key := InputEventKey.new()
	text_key.keycode = KEY_X
	text_key.unicode = 120
	text_key.pressed = true
	root.push_input(text_key)
	text_key.pressed = false
	root.push_input(text_key)
	workbench._assembly_panel._remove_module(0)
	_check(session.world == world and session.runner == runner and session.state == state, "Ctrl+Enter 不启动、暂停或重启执行 " + label)
	_check(workbench._code.text == source and JSON.stringify(session.assembly.modules) == modules and workbench._tabs.current_tab == mode, "过渡输入不修改代码、装配或模式 " + label)
	return true


## 有界等待真实补间，采样单调地图尺寸和扩展进度，避免固定睡眠掩盖卡住的动画。
func _wait_preview(workbench: GameWorkbench, expanded: bool, label: String) -> bool:
	var previous_progress := workbench._preview_layout.get_expand_progress()
	var previous_width := workbench._world_panel.size.x
	var header_rect := workbench.header.get_global_rect()
	var monotonic := true
	var width_monotonic := true
	var header_fixed := true
	var saw_wipe_before_growth := false
	var hidden_during_growth := true
	for frame in MAX_TRANSITION_FRAMES:
		await process_frame
		if not is_instance_valid(workbench):
			_check(false, "等待时工作台被意外释放 " + label)
			return false
		var progress := workbench._preview_layout.get_expand_progress()
		monotonic = monotonic and (progress + 0.001 >= previous_progress if expanded else progress <= previous_progress + 0.001)
		var width := workbench._world_panel.size.x
		width_monotonic = width_monotonic and (width + 1.5 >= previous_width if expanded else width <= previous_width + 1.5)
		header_fixed = header_fixed and _rect_close(workbench.header.get_global_rect(), header_rect)
		if expanded and progress < 0.001 and workbench._preview_layout._wipe_progress > 0.01:
			saw_wipe_before_growth = true
		if expanded and progress > 0.01:
			hidden_during_growth = hidden_during_growth and not workbench._edit_panel.is_visible_in_tree()
		previous_progress = progress
		previous_width = width
		if not workbench._preview_layout.transitioning:
			await _settle()
			_check(workbench._preview_layout.expanded == expanded and is_equal_approx(progress, 1.0 if expanded else 0.0), "动画抵达请求状态 " + label)
			_check(monotonic, "地图展开或收回进度单调 " + label)
			_check(width_monotonic and header_fixed, "地图宽度单调变化且每帧页头固定 " + label)
			_check(saw_wipe_before_growth or not expanded, "编辑卡片先经历擦除阶段再拓宽地图 " + label)
			_check(hidden_during_growth, "地图拓宽阶段编辑卡片已经退场 " + label)
			return workbench._preview_layout.expanded == expanded
	_check(false, "动画超过 %d 帧仍未完成 " % MAX_TRANSITION_FRAMES + label)
	return false


## 快照保留节点身份及用户正在编辑的状态，检测隐藏时重建编辑器的回归。
func _snapshot(workbench: GameWorkbench) -> Dictionary:
	return {
		"code": workbench._code, "assembly": workbench.session.assembly,
		"panel": workbench._assembly_panel, "world_panel": workbench._world_panel,
		"source": workbench._code.text, "modules": JSON.stringify(workbench.session.assembly.modules),
		"caret_line": workbench._code.get_caret_line(), "caret_column": workbench._code.get_caret_column(),
		"selection": workbench._code.get_selected_text(), "selected_module": workbench._assembly_panel.canvas.selected_index,
		"current_line": workbench.session.current_line, "header": workbench.header.get_global_rect(),
		"split_offset": workbench._preview_layout.split.split_offset,
		"font": workbench._code.get_theme_font("font"), "style": workbench._code.get_theme_stylebox("normal")
	}


## 展开只改变世界卡片宽度与网格比例；页头和编辑对象仍属于原工作台。
func _check_expanded(workbench: GameWorkbench, snapshot: Dictionary, label: String) -> void:
	_check_full_width(workbench, label)
	_check(workbench._preview_button.get_tooltip() == "缩小至小尺寸", "展开入口切换为缩小悬停说明 " + label)
	_check(not workbench._edit_panel.is_visible_in_tree(), "全尺寸状态隐藏编辑卡片 " + label)
	_check_preserved(workbench, snapshot, label)
	_check_corner_alignment(workbench, false, label)


## 收回后恢复相同矩形和编辑权限，模式切换也应继续使用原来的节点。
func _check_restored(workbench: GameWorkbench, snapshot: Dictionary, world_rect: Rect2, editor_rect: Rect2, label: String) -> void:
	_check(not workbench._preview_layout.expanded and workbench._edit_panel.is_visible_in_tree() and workbench._world_panel.is_visible_in_tree(), "恢复双卡片可见性 " + label)
	_check(workbench._preview_button.get_tooltip() == "全尺寸预览", "收回入口恢复全尺寸预览悬停说明 " + label)
	_check(_rect_close(workbench._world_panel.get_global_rect(), world_rect) and _rect_close(workbench._edit_panel.get_global_rect(), editor_rect), "卡片位置与尺寸恢复且没有累计偏移 " + label)
	_check(workbench._code.editable and workbench._assembly_panel.interaction_enabled and not workbench._preview_button.disabled, "恢复空闲编辑和预览入口 " + label)
	_check(workbench._preview_layout.split.split_offset == snapshot.split_offset, "保留玩家调整后的分隔条位置 " + label)
	_check_preserved(workbench, snapshot, label)


## 比较真实源文本、选择与节点身份，不使用新建内容碰巧相同作为保留证据。
func _check_preserved(workbench: GameWorkbench, snapshot: Dictionary, label: String) -> void:
	_check(workbench._code == snapshot.code and workbench.session.assembly == snapshot.assembly and workbench._assembly_panel == snapshot.panel and workbench._world_panel == snapshot.world_panel, "预览复用全部原节点及装配模型 " + label)
	_check(workbench._code.text == snapshot.source and workbench.session.source == snapshot.source and JSON.stringify(workbench.session.assembly.modules) == snapshot.modules, "保留程序和装配内容 " + label)
	_check(workbench._code.get_caret_line() == snapshot.caret_line and workbench._code.get_caret_column() == snapshot.caret_column and workbench._code.get_selected_text() == snapshot.selection, "保留代码光标和选区 %s 实际=%s 预期=%s" % [label, [_line_column(workbench._code), workbench._code.get_selected_text()], [Vector2i(snapshot.caret_line, snapshot.caret_column), snapshot.selection]])
	_check(workbench._assembly_panel.canvas.selected_index == snapshot.selected_module and workbench.session.current_line == snapshot.current_line and workbench._highlighted_line == int(snapshot.current_line) - 1, "保留装配选择和当前高亮行 " + label)
	_check(_rect_close(workbench.header.get_global_rect(), snapshot.header), "顶部栏矩形不受预览影响 " + label)


## 世界卡片应覆盖同一个卡片布局父节点，而非新开独立窗口或复制地图。
func _check_full_width(workbench: GameWorkbench, label: String) -> void:
	var parent := workbench._world_panel.get_parent() as Control
	var world := workbench._world_panel.get_global_rect()
	var frame := parent.get_global_rect()
	_check(absf(world.position.x - frame.position.x) < 1.5 and absf(world.end.x - frame.end.x) < 1.5, "世界卡片填满原布局宽度 " + label)


## 实际绘图尺寸保持方格比例，完整网格留在扣除滚动条的可见区域内。
func _check_map_fits(workbench: GameWorkbench, label: String) -> void:
	var viewport := workbench._world_scroll.get_global_rect()
	var vertical := workbench._world_scroll.get_v_scroll_bar()
	var horizontal := workbench._world_scroll.get_h_scroll_bar()
	if vertical.is_visible_in_tree():
		viewport.size.x -= vertical.size.x
	if horizontal.is_visible_in_tree():
		viewport.size.y -= horizontal.size.y
	var map_rect := workbench._playfield.get_global_rect()
	var document := workbench._playfield.document
	_check(viewport.grow(1.5).encloses(map_rect), "完整地图留在观察视口内 " + label)
	_check(absf(map_rect.size.x / document.width - map_rect.size.y / document.height) < 0.01, "缩放保持横纵方格等比 " + label)


## 新入口在问号右侧，动态药丸仍直接位于问号左侧并保持垂直居中。
func _check_corner_alignment(workbench: GameWorkbench, require_pill: bool, label: String) -> void:
	var guide := workbench._guide_button.get_global_rect()
	var preview := workbench._preview_button.get_global_rect()
	_check(guide.end.x <= preview.position.x and preview.position.x - guide.end.x <= 20.0 and absf(guide.get_center().y - preview.get_center().y) < 1.5, "预览入口紧邻问号右侧并对齐 " + label)
	if require_pill:
		var pill := workbench._live_status.get_global_rect()
		_check(workbench._live_status.is_expanded(), "运行倒计时药丸可见 " + label)
		_check(pill.end.x <= guide.position.x + 1.0 and guide.position.x - pill.end.x <= 20.0 and absf(pill.get_center().y - guide.get_center().y) < 1.5, "药丸始终紧靠问号左侧并对齐 " + label)


## 允许亚像素布局舍入，但不容忍动画结束后的可见漂移。
func _rect_close(actual: Rect2, expected: Rect2) -> bool:
	return actual.position.distance_to(expected.position) < 1.5 and actual.size.distance_to(expected.size) < 1.5


## 记录真实动画起点，验证重复点击不会插入新的过渡。
func _record_transition_started(expanding: bool) -> void:
	_transition_events.append("start:" + str(expanding))


## 记录真实动画终点，与起点按顺序形成一一对应的状态变化。
func _record_transition_finished(expanded: bool) -> void:
	_transition_events.append("finish:" + str(expanded))


## 给容器和滚动区充分的延迟重排帧，不等待无关的长计时器。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 清理只接受当前测试唯一前缀，永远不遍历正式存档目录。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 出错仍继续独立断言，最终返回非零状态供命令行验收。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 总时限兜底阻止脚本错误或意外场景状态造成测试长期挂起。
func _timeout() -> void:
	push_error("全尺寸预览回归超过 42 秒总时限。")
	quit(1)


## 显示回归失败时的光标坐标。
func _line_column(editor: CodeEdit) -> Vector2i:
	return Vector2i(editor.get_caret_line(), editor.get_caret_column())
