extends SceneTree
## 全尺寸结果反馈使用真实会话和独立存档，模拟手动步进，界面动画保持真实时间。

const GATE_PROGRAM := "main() {\n    move(0, 8)\n}\n"
const PURSUIT_PROGRAM := "main(){\nloop{\nshoot(0)\nmove(180,0.2)\n}\n}"
const MAX_TRANSITION_FRAMES := 250

var _checks := 0
var _failures := 0
var _temporary := ""


## 限制界面等待时长，防止无帧率上限的无头运行提前耗尽帧数。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 验证结果优先级、持久显示、收回与重置，并保留原有小尺寸状态行为。
func _run() -> void:
	create_timer(24.0).timeout.connect(_timeout)
	_temporary = "user://tests/full_preview_feedback_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game.settings.set_language("zh_CN")
	await _test_gate_feedback(game)
	await _test_pursuit_feedback(game)
	game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("全尺寸结果药丸回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 通过正式装配入口创建工作台，只停用自动模拟推进，不停用子控件和补间。
func _enter_program(game: GameShell, index: int) -> GameWorkbench:
	game._enter_level(game.catalog.levels[index])
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "安装中心驱动")
	var second_type := "movement" if index == 1 else "shooting"
	_check(game.session.assembly.add_module(second_type, Vector2(0.5, 0), "second").is_ok(), "安装关卡允许的第二模块")
	game._confirm_assembly()
	await _settle()
	var workbench := game.workbench
	_check(workbench != null and game.page == GameShell.Page.PLAY, "正式装配流程进入编程页面")
	if workbench != null:
		workbench.set_process(false)
	return workbench


## 无世界的编译失败、路线成功和各个清理入口共享同一药丸。
func _test_gate_feedback(game: GameShell) -> void:
	var workbench := await _enter_program(game, 1)
	if workbench == null:
		return
	var session := workbench.session
	var pill := workbench._live_status
	_start_program(workbench, "main() { move(0, 1")
	_check(session.state == GameSession.State.FAILED and session.world == null, "语法错误在创建世界之前失败")
	_check(not pill.is_expanded(), "小尺寸编译错误仍只使用原有代码区反馈")
	workbench._preview_button.pressed.emit()
	_check(pill.is_expanded() and _pill_text(pill) == _message(session), "已有失败进入全尺寸时立即显示同一结果")
	if not await _wait_preview(workbench, true):
		return
	_check_result(workbench, GameSession.State.FAILED, "无世界的编译错误")
	workbench.header.reset_button.pressed.emit()
	_check(session.state == GameSession.State.EDITING and not pill.is_expanded(), "顶部重置位置立即隐藏失败药丸")
	_start_program(workbench, GATE_PROGRAM)
	await create_timer(0.34).timeout
	_check(pill.is_expanded() and _pill_text(pill).contains("闸门将在"), "全尺寸重试恢复闸门倒计时")
	_check(pill.status_label.get_theme_color("default_color") == GameTheme.TEXT, "重试恢复普通运行文字颜色")
	var reveal_before := pill._reveal_progress
	_advance_until_terminal(session)
	_check_result(workbench, GameSession.State.SUCCEEDED, "真实闸门通关")
	_check(workbench._live_status == pill and is_equal_approx(pill._reveal_progress, reveal_before), "倒计时直接替换通关结果，不重建或跳回收起宽度")
	# 原来的终态停留仅一秒，结果反馈必须在该期限之后仍保留。
	await create_timer(1.55).timeout
	for unused in 8:
		session.changed.emit()
	_check(pill.is_expanded() and is_equal_approx(pill._reveal_progress, 1.0), "通关反馈超过原停留时间仍完整展开")
	_check(is_zero_approx(float(pill._surface_material.get_shader_parameter("gradient_strength"))), "完整结果药丸没有展开中使用的渐变")
	var completed_world := session.world
	game.settings.set_language("en")
	await _settle()
	_check(_pill_text(pill) == "Goal reached — level complete!" and session.world == completed_world, "语言切换即时更新结果，不重建世界")
	game.settings.set_language("zh_CN")
	await _settle()
	_check(_pill_text(pill) == session.message, "切回中文恢复原始通关反馈")
	workbench._preview_button.pressed.emit()
	_check(not pill.is_expanded(), "开始退出全尺寸的同一帧隐藏通关药丸")
	for unused in 8:
		session.changed.emit()
		await process_frame
		_check(not pill.is_expanded(), "收回期间会话刷新不使结果再次出现")
	if not await _wait_preview(workbench, false):
		return
	_check(not pill.is_expanded() and workbench._status_row.is_visible_in_tree(), "小尺寸恢复原有结果状态栏且没有残留药丸")
	workbench._preview_button.pressed.emit()
	if not await _wait_preview(workbench, true):
		return
	_check_result(workbench, GameSession.State.SUCCEEDED, "重新展开已有通关结果")
	workbench.header.more_button.pressed.emit()
	_check(workbench._actions_menu.is_open(), "全尺寸可打开更多菜单")
	workbench._actions_menu._items[2].pressed.emit()
	_check(session.state == GameSession.State.EDITING and not pill.is_expanded(), "更多菜单重置位置立即隐藏结果")
	_start_program(workbench, "main(){move(0,0)}")
	_advance_until_terminal(session)
	_check_result(workbench, GameSession.State.FAILED, "程序结束但尚未抵达终点")
	_check(pill.status_label.get_parsed_text().ends_with("…") and pill.status_label.tooltip_text == _message(session), "较长失败原因省略显示，悬停保留完整原文")
	game.settings.set_language("en")
	await _settle()
	_check(_pill_text(pill) == _message(session) and not _pill_text(pill).contains("程序已执行完"), "完整失败悬停提示也随语言切换")
	game.settings.set_language("zh_CN")
	session.reset()
	_check(not pill.is_expanded(), "直接重置会话也立即清除结果")
	_start_program(workbench, GATE_PROGRAM)
	await create_timer(0.32).timeout
	workbench._preview_button.pressed.emit()
	if not await _wait_preview(workbench, false):
		return
	_check(pill.is_expanded() and _pill_text(pill).contains("闸门将在"), "运行中收回保留小尺寸原有倒计时")
	workbench._preview_button.pressed.emit()
	_advance_until_terminal(session)
	_check(workbench._preview_layout.transitioning and pill.is_expanded() and _pill_text(pill) == _message(session), "展开尚未结束时通关也即时替换运行信息")
	if not await _wait_preview(workbench, true):
		return
	_check_result(workbench, GameSession.State.SUCCEEDED, "展开中通关完成动画后仍显示")
	session.reset()
	_check(not pill.is_expanded(), "第二次通关仍能正常清理")
	game._back_to_levels()
	await _settle()


## 真正的战斗失败直接覆盖已有敌人和射击冷却信息，快速重试不遗留错误。
func _test_pursuit_feedback(game: GameShell) -> void:
	var workbench := await _enter_program(game, 6)
	if workbench == null:
		return
	var session := workbench.session
	var pill := workbench._live_status
	workbench._preview_button.pressed.emit()
	if not await _wait_preview(workbench, true):
		return
	_start_program(workbench, PURSUIT_PROGRAM)
	session.step()
	await create_timer(0.34).timeout
	_check(pill.is_expanded() and _pill_text(pill).contains("敌方模块") and _pill_text(pill).contains("射击冷却"), "战斗药丸显示真实敌人和射击冷却")
	var prior_tween := pill._tween
	var prior_reveal := pill._reveal_progress
	_advance_until_terminal(session)
	_check_result(workbench, GameSession.State.FAILED, "第七关真实攻击导致失败")
	_check(pill._tween == prior_tween and is_equal_approx(pill._reveal_progress, prior_reveal), "战斗结果只替换文本，不重启已展开的补间")
	_check(not _pill_text(pill).contains("敌方模块") and not _pill_text(pill).contains("射击冷却"), "失败原因优先覆盖旧冷却与敌人计数")
	await create_timer(1.45).timeout
	_check(pill.is_expanded() and _pill_text(pill) == _message(session), "失败结果持续显示，不在原倒计时收回期限消失")
	workbench.header.run_button.pressed.emit()
	_check(session.state == GameSession.State.RUNNING and pill.is_expanded() and _pill_text(pill).contains("敌方模块"), "失败后直接重跑恢复实时战斗提示")
	_check(pill.status_label.get_theme_color("default_color") == GameTheme.TEXT, "直接重跑不会继承失败红色")
	session.reset()
	_check(not pill.is_expanded() and session.world == null, "战斗重置立即隐藏药丸并清除运行世界")
	game._back_to_levels()
	await _settle()


## 使用正式运行按钮读取编辑器内容，避免绕过工作台与会话之间的连接。
func _start_program(workbench: GameWorkbench, source: String) -> void:
	workbench._code.text = source
	workbench.header.run_button.pressed.emit()


## 快速推进真实模拟至结果；不同关卡目标与错误仍由 GameSession 自己判定。
func _advance_until_terminal(session: GameSession) -> void:
	for unused in 1000:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state in [GameSession.State.SUCCEEDED, GameSession.State.FAILED], "模拟在有限步数内形成真实结果")


## 合并行显示与药丸一致，翻译使用现有游戏错误翻译入口。
func _message(session: GameSession) -> String:
	return GameI18n.translate_errors(session.message.split("\n")).replace("\n", " · ").strip_edges()


## 悬停文本始终保存完整文本，适合验证被视觉省略的长反馈。
func _pill_text(pill: WorkbenchStatusPill) -> String:
	return pill.status_label.tooltip_text


## 结果的语义、完整反馈和状态色必须同时正确。
func _check_result(workbench: GameWorkbench, expected: GameSession.State, reason: String) -> void:
	var pill := workbench._live_status
	_check(workbench.session.state == expected, reason + "：会话结果正确")
	_check(pill.is_expanded() and _pill_text(pill) == _message(workbench.session), reason + "：显示当前会话的完整结果")
	var expected_color := GameTheme.SUCCESS if expected == GameSession.State.SUCCEEDED else GameTheme.ERROR
	_check(pill.status_label.get_theme_color("default_color") == expected_color, reason + "：结果颜色正确")


## 等待真实展开动画，不修改组件的内部状态来制造全尺寸夹具。
func _wait_preview(workbench: GameWorkbench, expanded: bool) -> bool:
	for unused in MAX_TRANSITION_FRAMES:
		await process_frame
		if not workbench._preview_layout.transitioning:
			await _settle()
			_check(workbench._preview_layout.expanded == expanded, "预览动画抵达请求布局")
			return workbench._preview_layout.expanded == expanded
	_check(false, "预览动画未在规定时间内完成")
	return false


## 让容器布局和延迟信号完成。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 仅清理本进程独占测试目录，不能遍历正式玩家存档。
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


## 累计独立失败，保证其余路径仍会被检查。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 限时兜底避免错误阻塞后续回归。
func _timeout() -> void:
	push_error("全尺寸结果药丸回归超过 24 秒总时限。")
	quit(1)
