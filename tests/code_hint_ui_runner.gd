extends SceneTree
## 正式工作台验证三档门槛、SVG 提示与撤销，以及导入/编辑器范围隔离。

var _checks := 0
var _failures := 0
var _temporary := ""
var _draft_events := 0


## 真实帧用于处理编辑器信号和过渡动画，模拟逻辑由测试主动推进。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 使用独立测试存档进入第一教学关，完成用户操作及来源隔离检查。
func _run() -> void:
	create_timer(30.0).timeout.connect(_timeout)
	_temporary = "user://tests/code_hint_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game.settings.set_language("zh_CN")
	var lesson: LevelDefinition = game.catalog.levels[0]
	var bench := await _enter_program(game, lesson)
	if bench == null:
		game.queue_free()
		await _settle()
		_finish()
		return
	_check(game.settings.code_hints == "normal", "设置默认一般")
	_check(not bench._hint_button.visible and not bench._hint_undo_button.visible, "一般档初次进入隐藏两个按钮")
	await _set_source(bench, "main() {\n unknown()\n}\n")
	for attempt in 3:
		bench._run_program()
		await _settle()
		_check(game.session.state == GameSession.State.FAILED, "语法错误作为实际失败尝试")
		_check(game.session.consecutive_failures == attempt + 1, "每次尝试计数一次")
		_check(bench._hint_button.visible == (attempt == 2), "第三次失败后才显示提示按钮")
	_check(game.drafts.get_failure_streak(lesson.id) == 3, "正式教学失败计数持久保存")
	bench._reset_position()
	_check(bench._hint_button.visible, "重置位置不绕过连续失败门槛")
	await _set_source(bench, "// 我的思路\nmain() {\n}\n")
	var original := bench._code.text
	bench.draft_changed.connect(_on_draft)
	_check(bench._hint_button.icon.resource_path.ends_with(".svg"), "提示按钮使用 SVG 资源")
	_check(bench._hint_undo_button.icon.resource_path.ends_with(".svg"), "撤销按钮使用 SVG 资源")
	_check(bench._hint_button.tooltip_text == "代码提示" and bench._hint_undo_button.tooltip_text == "撤销提示", "按钮悬停名称明确")
	bench._hint_button.pressed.emit()
	await _settle()
	var first_step := bench._code.text
	_check(first_step.contains("move(0, 4)") and first_step.count("move(") == 1, "点击只加入一条完整动作")
	_check(first_step.contains("// 我的思路") and game.session.source == first_step, "保留原注释并同步会话")
	_check(bench._hint_undo_button.visible and not bench._hint_undo_button.disabled, "加入提示后显示相邻撤销按钮")
	_check(bench._hint_undo_button.size == bench._hint_button.size, "提示和撤销具有同样尺寸")
	_check(bench._hint_undo_button.get_global_rect().end.x < bench._hint_button.global_position.x, "撤销位于提示左边并留有间隔")
	_check(_draft_events > 0, "提示通过原草稿修改信号保存")
	bench._hint_button.pressed.emit()
	await _settle()
	_check(bench._code.text.count("move(") == 2, "再次提示仅补入下一步")
	var events_before_undo := _draft_events
	bench._hint_undo_button.pressed.emit()
	_check(game.session.source == first_step and _draft_events > events_before_undo, "撤销同一帧同步源码与保存信号，不等待延迟文本事件")
	await _settle()
	_check(bench._code.text == first_step and game.session.source == first_step, "相邻撤销只撤销最新提示")
	_check(bench._hint_undo_button.visible, "仍可继续撤销上一步提示")
	bench._hint_undo_button.pressed.emit()
	await _settle()
	_check(bench._code.text == original and game.session.source == original, "两次撤销恢复提示前原始代码")
	_check(not bench._hint_undo_button.visible, "没有提示可撤回时隐藏撤销按钮")
	bench._hint_button.pressed.emit()
	await _settle()
	bench._code.set_caret_line(0)
	bench._code.set_caret_column(0)
	bench._code.begin_complex_operation()
	bench._code.insert_text_at_caret("// 玩家新增\n")
	bench._code.end_complex_operation()
	await _settle()
	var manual_source := bench._code.text
	_check(not bench._hint_undo_button.visible, "手工修改后不显示会撤走玩家输入的提示撤销")
	bench._hint_undo_button.pressed.emit()
	await _settle()
	_check(bench._code.text == manual_source, "隐藏的撤销入口无法覆盖手工代码")
	game.settings.set_code_hints("none")
	_check(not bench._hint_button.visible and not bench._hint_undo_button.visible, "无档即时隐藏提示及撤销")
	bench._hint_button.pressed.emit()
	await _settle()
	_check(bench._code.text == manual_source, "关闭设置时点击旧信号也不会改代码")
	game.settings.set_code_hints("more")
	game.session.consecutive_failures = 0
	bench._sync_session()
	_check(bench._hint_button.visible, "多档无需失败即可显示")
	await _set_source(bench, "main() {\n move(0, 4)\n}\n")
	bench._run_program()
	_check(bench._hint_button.disabled, "运行时禁用提示")
	game.session.pause()
	_check(bench._hint_button.disabled, "暂停时仍禁用提示")
	bench._reset_position()
	bench._preview_button.pressed.emit()
	_check(bench._hint_button.disabled, "全尺寸过渡开始即禁止提示修改")
	await create_timer(1.3).timeout
	_check(not bench._hint_button.is_visible_in_tree() and not bench._hint_undo_button.is_visible_in_tree(), "全尺寸隐藏编辑区及两个入口")
	bench._preview_button.pressed.emit()
	await create_timer(1.3).timeout
	_check(bench._hint_button.is_visible_in_tree() and not bench._hint_button.disabled, "退出全尺寸恢复提示")
	game.settings.set_code_hints("normal")
	bench = await _enter_program(game, lesson)
	_check(game.session.consecutive_failures == 3 and bench._hint_button.visible, "重新进入教学恢复此前连续失败数")
	await _set_source(bench, "main() { move(0,4)\nmove(90,3)\nmove(180,4)\nmove(90,3)\nmove(0,4) }")
	bench._run_program()
	for unused in 500:
		if game.session.state != GameSession.State.RUNNING:
			break
		game.session.step()
	_check(game.session.state == GameSession.State.SUCCEEDED, "实际通关")
	_check(game.session.consecutive_failures == 0 and game.drafts.get_failure_streak(lesson.id) == 0, "通关清零内存及本关连续失败记录")
	_check(not bench._hint_button.visible, "一般档通关后收起提示")
	game.settings.set_code_hints("more")
	var imported: LevelDefinition = LevelDefinition.from_document(lesson.document.duplicate_document(), game.registry, "user://levels/imported.json").value
	bench = await _enter_program(game, imported)
	_check(not bench._hint_button.visible and not bench._hint_undo_button.visible, "完全相同的导入地图也没有代码提示和撤销")
	_check(not game.session.attempt_failed.is_connected(game._on_attempt_failed), "导入关卡不连接提示次数存盘回调")
	await _set_source(bench, "main() {unknown()}")
	bench._run_program()
	_check(game.drafts.get_failure_streak(lesson.id) == 0, "导入相同 ID 的失败不能污染教学提示门槛")
	bench = await _enter_program(game, lesson)
	bench.allow_draft_save = false
	bench._sync_session()
	_check(not bench._hint_button.visible and not bench._hint_undo_button.visible, "编辑器试玩模式即使借用教学路径也不提供提示")
	game.queue_free()
	await _settle()
	_finish()


## 正式导航、空装配、手工安装移动模块后进入工作台，避免只构造孤立按钮。
func _enter_program(game: GameShell, level: LevelDefinition) -> GameWorkbench:
	game._enter_level(level)
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "手动安装测试移动模块")
	game._confirm_assembly()
	await _settle()
	if not _check(game.workbench != null, "实际确认装配后创建工作台"):
		return null
	game.workbench.set_process(false)
	return game.workbench


## 编辑源文本并等待 CodeEdit 的异步 text_changed 信号落地。
func _set_source(bench: GameWorkbench, source: String) -> void:
	bench._code.text = source
	await _settle()


## 等待真实帧使容器尺寸、文本事件和草稿信号稳定。
func _settle() -> void:
	for unused in 8:
		await process_frame


## 仅记录修改信号次数，不直接替工作台写入玩家磁盘。
func _on_draft() -> void:
	_draft_events += 1


## 失败消息保留具体行为上下文。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 递归清理严格位于本测试专用子目录的文件。
func _remove_tree(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in folder.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)


## 汇总所有用户可见行为并退出，清理独立测试数据。
func _finish() -> void:
	_remove_tree(_temporary)
	print("代码提示界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 防止未完成的界面流程被误报通过。
func _timeout() -> void:
	push_error("代码提示界面回归超时。")
	quit(1)
