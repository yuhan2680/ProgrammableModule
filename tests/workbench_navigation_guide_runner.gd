extends SceneTree
## 使用真实导航入口往返编程与组装，检查源码、视点和同一会话的隔离边界。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""
var _finished := false


## 场景初始化完成后再建立正式外壳，避免测试夹具抢先触发页面回调。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 独占设置和存档目录，正常与试玩都走真实空装配、确认及左右导航。
func _run() -> void:
	create_timer(35.0).timeout.connect(_timeout)
	_temporary = "user://tests/workbench_navigation_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_game.settings.set_language("zh_CN")
	await _test_normal_navigation()
	await _test_running_return(false)
	await _test_running_return(true)
	await _test_playtest_navigation()
	_test_system_rules()
	await _finish()


## 两个前进入口始终共用正式装配校验，编程返回前直接读取同帧源码。
func _test_normal_navigation() -> void:
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	var session := _game.session
	var assembly := session.assembly
	var header := _game.assembly_panel.header
	_check(header.forward_button.disabled and header.confirm_button.disabled, "空装配同时禁用前进箭头与蓝确认")
	_check(header.forward_button.tooltip_text == header.confirm_button.tooltip_text, "两个确认入口共享同一无效原因")
	header.forward_button.pressed.emit()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session == session, "直接发射禁用前进也不能绕过空装配校验")
	_check(assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "通过真实模型安装中心移动模块")
	await _settle()
	_check(not header.forward_button.disabled and not header.confirm_button.disabled, "有效装配同时启用两个前进入口")
	header.forward_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.PLAY and _game.session == session and session.assembly == assembly, "左侧前进箭头确认后保留同一关卡会话和装配")
	var bench := _game.workbench
	bench.set_process(false)
	bench.code_zoom_percent = 150
	bench._code.text = "main() {\n}\n" + ("// " + "long_view_".repeat(28) + "\n").repeat(90)
	await _settle()
	# 此次修改后不等待帧，模拟玩家输入后立即点击返回。
	var expected_source := bench._code.text + "// same_frame_edit\n"
	bench._code.text = expected_source
	bench._code.set_caret_line(40)
	bench._code.set_caret_column(15)
	bench._code.select(40, 4, 40, 15)
	bench._code.scroll_vertical = 25.0
	bench._code.scroll_horizontal = 50
	var expected_scroll := Vector2(bench._code.scroll_horizontal, bench._code.scroll_vertical)
	var failures := session.consecutive_failures
	bench.header.back_button.pressed.emit()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session == session and session.assembly == assembly, "编程页左箭头返回同一会话的独立组装页")
	_check(session.source == expected_source and session.consecutive_failures == failures, "同帧源码完整保存，手动返回不增加失败次数")
	_check(_game.assembly_panel.header.forward_button.tooltip_text.contains("返回编程"), "返回组装后前进箭头明确说明返回编程")
	_game.assembly_panel.header.confirm_button.pressed.emit()
	await _settle()
	bench = _game.workbench
	bench.set_process(false)
	_check(bench._code.text == expected_source and bench.code_zoom_percent == 150, "蓝确认返回编程保留完整源码和代码缩放")
	_check(bench._code.get_caret_line() == 40 and bench._code.get_caret_column() == 15, "重建编辑器后恢复主光标行列")
	_check(bench._code.has_selection() and bench._code.get_selection_from_line() == 40 and bench._code.get_selection_from_column() == 4 and bench._code.get_selection_to_column() == 15, "往返保留主选区")
	_check(absf(bench._code.scroll_vertical - expected_scroll.y) < 0.01 and absf(bench._code.scroll_horizontal - expected_scroll.x) < 1.0, "往返保留代码双向滚动位置")
	bench.header.back_button.pressed.emit()
	_game.assembly_panel.header.back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.LEVELS and _game.session == null, "普通组装页左箭头仍离开关卡返回目录")
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	_check(_game._program_editor_view.is_empty(), "再次进入关卡不会继承上一会话的临时光标与缩放")
	_game.assembly_panel.header.back_button.pressed.emit()
	await _settle()


## 正在运行和暂停的程序都沿用停止语义，取消旧执行器不计为失败。
func _test_running_return(paused: bool) -> void:
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "运行返回夹具安装移动模块")
	_game.assembly_panel.header.forward_button.pressed.emit()
	await _settle()
	var bench := _game.workbench
	bench.set_process(false)
	bench._code.text = "main() {\n    move(0, 3)\n}\n"
	bench.header.run_button.pressed.emit()
	var session := _game.session
	_check(session.state == GameSession.State.RUNNING and session.runner != null, "由真实运行按钮创建执行器")
	var runner := session.runner
	if paused:
		bench.header.pause_button.pressed.emit()
		_check(session.state == GameSession.State.PAUSED, "真实暂停入口冻结执行")
	var failures := session.consecutive_failures
	var stats := _game.profile.get_statistics().duplicate(true)
	bench.header.back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session == session and session.state == GameSession.State.EDITING, "运行或暂停时左返回进入同一装配会话")
	_check(runner.state == ProgramRunner.State.CANCELLED and session.world == null, "返回取消旧程序并清理旧世界")
	var after := _game.profile.get_statistics()
	_check(session.consecutive_failures == failures and after.failures == stats.failures and after.successes == stats.successes, "手动返回保持失败计数和通过率统计")
	_game.assembly_panel.header.back_button.pressed.emit()
	await _settle()


## 试玩先返回组装，再离开时恢复原编辑器节点与文档，不访问正式草稿。
func _test_playtest_navigation() -> void:
	_game._open_editor()
	await _settle()
	var editor := _game._editor
	var model := editor.editor_document
	var original := JSON.stringify(model.document.to_dict(), "", true)
	var dirty := model.is_dirty()
	var undo_count := model._undo_stack.size()
	_game._start_editor_playtest(_game.catalog.levels[0], _game.registry)
	_game._dialogue_dialog.hide()
	await _settle()
	var session := _game.session
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "试玩真实空装配安装模块")
	_game.assembly_panel.header.forward_button.pressed.emit()
	await _settle()
	var bench := _game.workbench
	bench._code.text = "main() {\n    move(0, 1)\n}\n// playtest"
	bench.code_zoom_percent = 125
	bench.header.back_button.pressed.emit()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game._editor_playtest and _game.session == session, "试玩编程左返回仅回组装，不提前退出试玩")
	_game.assembly_panel.header.forward_button.pressed.emit()
	await _settle()
	_check(_game.workbench._code.text.ends_with("// playtest") and _game.workbench.code_zoom_percent == 125, "试玩前进往返也保留源码与缩放")
	_game.workbench.header.back_button.pressed.emit()
	_game.assembly_panel.header.back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and _game._editor == editor and editor.editor_document == model, "试玩组装页左返回恢复原编辑器和文档")
	_check(model.is_dirty() == dirty and model._undo_stack.size() == undo_count and JSON.stringify(model.document.to_dict(), "", true) == original, "两次导航没有改变原地图、dirty或撤销历史")
	_check(not _game._editor_playtest and _game.session == null and _game._program_editor_view.is_empty(), "退出试玩清除临时会话和代码视点")


## 每关程序说明来自既有能力规则，只生成可翻译系统页，绝不追加下方详细帮助。
func _test_system_rules() -> void:
	var expected := {
		0: "程序从 main() 开始，依次执行每条指令。",
		3: "main() 执行一次；tick() 每 0.1 秒调用一次。",
		5: "loop { ... } 按顺序重复块内指令，直到关卡结束。",
		8: "distance(角度) 测量前方距离，边探路边移动。",
		11: "for 按步长遍历角度，用一组指令检查不同方向。",
		12: "用 scan() 锁定目标，再将 Angle() 交给射击模块。",
		14: "使用 onDetected 绑定目标变量，再从 main() 中判断并射击。",
		15: "distance(角度) 测量前方距离，边探路边移动。",
	}
	for index: int in expected:
		var level: LevelDefinition = _game.catalog.levels[index]
		var before := JSON.stringify(level.document.to_dict(), "", true)
		_check(WorkbenchProgramGuide.entry_text(level) == expected[index], "系统程序说明保持原能力规则优先级：" + level.id)
		_check(WorkbenchProgramGuide.page(level).text == expected[index] and JSON.stringify(level.document.to_dict(), "", true) == before, "生成说明页不追加详细帮助、不修改地图：" + level.id)


## 等待布局和延迟视点恢复稳定，不用人为写入最终控件尺寸掩盖问题。
func _settle() -> void:
	for unused in 8:
		await process_frame


## 失败继续记录，最终统一退出码，避免只看到后续成功断言。
func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)


## 清理范围仅限本次夹具的独占目录，不触碰任何正式关卡和玩家档案。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 正常与超时均释放外壳，并给出可验证的最终完成标记。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_cleanup(_temporary)
	print("编程导航与系统说明回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 超时是明确失败，不能将引擎自动退出误认为测试成功。
func _timeout() -> void:
	_check(false, "编程导航与系统说明回归超时")
	_finish()
