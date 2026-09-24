extends SceneTree
## 在真实工作台通过原生键盘事件验证行内补全；夹具只使用独占测试存档。

const EMPTY_PROGRAM := "main() {\n    \n}\n"
const MOVEMENT_PROGRAM := "main() {\n    move(0, 4)\n}\n"

var _checks := 0
var _failures := 0
var _temporary := ""
var _draft_notifications := 0


## 场景树准备完成后测试输入，避免在初始化阶段依赖焦点与容器尺寸。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 按真实进入、输入、接受、设置切换和运行锁流程验证补全边界。
func _run() -> void:
	create_timer(36.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 800)
	_temporary = "user://tests/inline_completion_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game.settings.set_language("zh_CN")
	await _test_accept_and_history(game)
	await _test_editor_boundaries(game)
	await _test_unlocks_and_receivers(game)
	await _test_running_and_preview_locks(game)
	game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("行内补全回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从正常的空装配入口进入编程，并通过会话本身持有模块名称与能力。
func _enter_program(game: GameShell, level_index: int) -> GameWorkbench:
	game._enter_level(game.catalog.levels[level_index])
	game._dialogue_dialog.hide()
	await _settle()
	if level_index == 8:
		_check(game.session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "第九关安装测试测距模块")
		_check(game.session.assembly.add_module("movement", Vector2(0, 0.5), "drive").is_ok(), "第九关安装测试移动模块")
	else:
		_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "安装测试中心移动模块")
		if level_index == 2:
			_check(game.session.assembly.add_module("melee", Vector2(0.5, 0), "blade").is_ok(), "第三关安装近战模块")
		elif level_index == 6:
			_check(game.session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "第七关安装射击模块")
	game._confirm_assembly()
	await _settle()
	var workbench := game.workbench
	_check(game.page == GameShell.Page.PLAY and workbench != null, "确认真实装配进入编程页")
	if workbench != null:
		workbench.set_process(false)
		workbench.draft_changed.connect(_record_draft_change)
		workbench._code.grab_focus()
		await _settle()
	return workbench


## 真实键入只产生淡灰建议，Tab 才提交，接受行为合并为一次原生撤销动作。
func _test_accept_and_history(game: GameShell) -> void:
	var workbench := await _enter_program(game, 0)
	if workbench == null:
		return
	_check(workbench._completion != null and workbench._completion.enabled, "缺省设置在真实工作台默认开启补全")
	_check(workbench._completion.get_parent() == workbench._code and workbench._completion.mouse_filter == Control.MOUSE_FILTER_IGNORE, "建议附着编辑器但不截获鼠标与光标定位")
	await _set_source(workbench, EMPTY_PROGRAM, 1, 4)
	await _type_ascii("mo")
	var incomplete := "main() {\n    mo\n}\n"
	_check(workbench._code.text == incomplete and workbench.session.source == incomplete, "实际键入 mo 只把用户文字写入编辑器和会话")
	_check(workbench._completion.suggestion == "ve", "mo 后显示可直接接受的 ve 后缀")
	_check(game._save_current_draft(true), "保存当前尚未接受补全的测试草稿")
	var saved_before := game.drafts.load_draft(workbench.session.level.id)
	_check(saved_before.is_ok() and saved_before.value != null and saved_before.value.source == incomplete, "灰色建议不写入持久化草稿")
	var notifications_before := _draft_notifications
	for unused in 8:
		workbench._completion.refresh()
		await process_frame
	_check(_draft_notifications == notifications_before and workbench.session.source == incomplete and workbench._code.text == incomplete, "刷新与绘制建议不触发源码或草稿修改")
	await _key(KEY_TAB)
	var completed := "main() {\n    move\n}\n"
	_check(workbench._code.text == completed and workbench.session.source == completed, "单次真实 Tab 仅追加 ve，没有额外缩进或换行")
	_check(workbench._code.get_caret_line() == 1 and workbench._code.get_caret_column() == 8, "接受后光标位于完整词末")
	_check(workbench._completion.suggestion.is_empty(), "词已完整时不保留旧建议")
	workbench._code.undo()
	await _settle()
	_check(workbench._code.text == incomplete and workbench.session.source == incomplete, "一次原生撤销只撤回刚才接受的后缀")
	workbench._code.redo()
	await _settle()
	_check(workbench._code.text == completed and workbench.session.source == completed, "一次原生重做恢复补全及会话源码")
	_check(game._save_current_draft(true), "保存已经接受的补全结果")
	var saved_after := game.drafts.load_draft(workbench.session.level.id)
	_check(saved_after.is_ok() and saved_after.value != null and saved_after.value.source == completed, "接受后的完整词沿用原有草稿保存流程")
	_check(game.settings.set_tab_completion(false).is_ok(), "关闭补全设置成功")
	await _set_source(workbench, incomplete, 1, 6)
	_check(not workbench._completion.enabled and workbench._completion.suggestion.is_empty(), "关闭设置立即清除当前建议")
	await _key(KEY_TAB)
	_check(not workbench._code.text.contains("move") and workbench._code.get_line(1).begins_with("    mo") and workbench._code.get_line(1).length() > 6, "关闭补全后 Tab 恢复 CodeEdit 原有缩进")
	_check(game.settings.set_tab_completion(true).is_ok(), "重新开启补全设置成功")
	await _set_source(workbench, incomplete, 1, 6)
	_check(workbench._completion.enabled and workbench._completion.suggestion == "ve", "重新开启后恢复当前位置的建议")
	await _key(KEY_TAB, true)
	_check(not workbench._code.text.contains("move") and workbench._code.get_line(1) == "mo", "Shift+Tab 仍反向缩进，不能接受灰色建议")
	await _set_source(workbench, incomplete, 1, 6)
	await _key(KEY_ESCAPE)
	_check(workbench._completion.suggestion.is_empty(), "Esc 关闭当前建议")
	await _settle()
	_check(workbench._completion.suggestion.is_empty(), "没有新编辑时关闭状态持续有效")
	await _type_ascii("v")
	_check(workbench._completion.suggestion == "e", "继续实际输入后恢复新建议")


## 选区、注释、词中间、多光标和不可见编辑位置不能被建议改写。
func _test_editor_boundaries(game: GameShell) -> void:
	var workbench := game.workbench
	if workbench == null:
		return
	for specimen: Dictionary in [
		{"source": "main() {\n    // mo\n}\n", "line": 1, "column": 9, "label": "注释"},
		{"source": "main() {\n    \"mo\"\n}\n", "line": 1, "column": 7, "label": "字符串"},
		{"source": "main() {\n    move\n}\n", "line": 1, "column": 6, "label": "现有词的中间"},
		{"source": EMPTY_PROGRAM, "line": 1, "column": 4, "label": "空白缩进"},
	]:
		await _set_source(workbench, specimen.source, specimen.line, specimen.column)
		_check(workbench._completion.suggestion.is_empty(), specimen.label + "不出现补全")
	await _set_source(workbench, "main() {\n    mo\n}\n", 1, 6)
	workbench._code.select(1, 4, 1, 6)
	await _settle()
	_check(workbench._completion.suggestion.is_empty(), "有选区时不出现或接受建议")
	await _key(KEY_TAB)
	_check(not workbench._code.text.contains("move"), "选区 Tab 使用原生编辑，不替换为候选词")
	await _set_source(workbench, "main() {\n    mo\n    mo\n}\n", 1, 6)
	var caret_index := workbench._code.add_caret(2, 6)
	_check(caret_index > 0 and workbench._code.get_caret_count() == 2, "建立真实双光标夹具")
	await _settle()
	_check(workbench._completion.suggestion.is_empty(), "双光标编辑不出现单光标建议")
	await _key(KEY_TAB)
	_check(not workbench._code.text.contains("move"), "多光标 Tab 不插入单个候选后缀")
	await _set_source(workbench, "main() {\n    mo\n}\n", 1, 6)
	workbench.header.book_button.grab_focus()
	await _settle()
	_check(workbench._completion.suggestion.is_empty(), "焦点离开编辑器后立即隐藏建议")
	workbench._code.grab_focus()
	await _settle()
	_check(workbench._completion.suggestion == "ve", "重新聚焦恢复有效建议")
	workbench._code.editable = false
	await _settle()
	_check(workbench._completion.suggestion.is_empty(), "编辑器只读时隐藏已有建议")
	var readonly_source := workbench._code.text
	await _key(KEY_TAB)
	_check(workbench._code.text == readonly_source, "只读状态下真实 Tab 不修改代码")
	workbench._code.editable = true
	var long_source := "main() {\n    mo\n" + "    // 留出可滚动的行\n".repeat(90) + "}\n"
	await _set_source(workbench, long_source, 1, 6)
	_check(workbench._completion.suggestion == "ve", "滚动前可见光标显示建议")
	workbench._code.scroll_vertical = 72
	await _settle()
	_check(workbench._code.scroll_vertical > 10 and workbench._completion.suggestion.is_empty(), "光标滚出可见范围时隐藏建议")
	workbench._code.scroll_vertical = 0
	await _settle()
	_check(workbench._completion.suggestion == "ve", "滚回光标所在区域恢复建议")
	var wide_source := "main() {\n    mo\n    // " + "宽行横向滚动夹具".repeat(50) + "\n}\n"
	await _set_source(workbench, wide_source, 1, 6)
	_check(workbench._completion.suggestion == "ve", "水平滚动前的可见光标显示建议")
	workbench._code.scroll_horizontal = 400
	await _settle()
	_check(workbench._code.scroll_horizontal > 100 and workbench._completion.suggestion.is_empty(), "手动水平滚动隐藏光标时同步隐藏建议")
	workbench._code.scroll_horizontal = 0
	await _settle()
	_check(workbench._completion.suggestion == "ve", "水平滚回光标所在位置后恢复建议")


## 在同一 Shell 跨关卡检验解锁、实际实例名称与具体模块的可调用能力。
func _test_unlocks_and_receivers(game: GameShell) -> void:
	var first := game.workbench
	if first == null:
		return
	for prefix: String in ["a", "sh", "lo", "si", "di", "drive.mo"]:
		await _set_source(first, "main() {\n    " + prefix + "\n}\n", 1, 4 + prefix.length())
		_check(first._completion.suggestion.is_empty(), "第一关不建议未解锁指令 " + prefix)
	var third := await _enter_program(game, 2)
	if third == null:
		return
	await _set_source(third, "main() {\n    a\n}\n", 1, 5)
	_check(third._completion.suggestion == "ttack", "第三关自动开放 attack 补全")
	await _key(KEY_TAB)
	_check(third._code.get_line(1) == "    attack", "第三关实际 Tab 接受已解锁近战指令")
	var seventh := await _enter_program(game, 6)
	if seventh == null:
		return
	await _set_source(seventh, "main() {\n    gun.sh\n}\n", 1, 10)
	_check(seventh._completion.suggestion == "oot", "具名射击仅按当前实际枪模块补全")
	await _key(KEY_TAB)
	_check(seventh._code.get_line(1) == "    gun.shoot", "具名调用保留玩家模块名，仅补全方法后缀")
	await _set_source(seventh, "main() {\n    drive.sh\n}\n", 1, 12)
	_check(seventh._completion.suggestion.is_empty(), "移动模块不补全射击方法")
	await _set_source(seventh, "main() {\n    if (gun.re\n}\n", 1, 14)
	_check(seventh._completion.suggestion == "ady", "第七关条件中的具名冷却查询可补全")
	await _set_source(seventh, EMPTY_PROGRAM, 1, 4)
	await _type_ascii("if (gun.re")
	_check(seventh._code.get_line(1) == "    if (gun.re)" and seventh._completion.suggestion == "ady", "原生括号配对后的冷却前缀仍显示建议")
	await _key(KEY_TAB)
	_check(seventh._code.get_line(1) == "    if (gun.ready)" and seventh.session.source == seventh._code.text, "括号内接受 ready 保留唯一闭括号且不添加缩进")
	_check(seventh.session.assembly.rename_module(1, "laser").is_ok(), "修改测试枪模块为实际玩家名称")
	await _set_source(seventh, "main() {\n    laser.sh\n}\n", 1, 12)
	_check(seventh._completion.suggestion == "oot", "模块改名后候选使用当前名称")
	await _set_source(seventh, "main() {\n    gun.sh\n}\n", 1, 10)
	_check(seventh._completion.suggestion.is_empty(), "模块改名后旧名称不再获得补全")
	var ninth := await _enter_program(game, 8)
	if ninth == null:
		return
	await _set_source(ninth, "main() {\n    move(0, di\n}\n", 1, 14)
	_check(ninth._completion.suggestion == "stance", "第九关数值参数中的测距查询可补全")
	await _set_source(ninth, "main() {\n    move(0, sensor.di\n}\n", 1, 21)
	_check(ninth._completion.suggestion == "stance", "实际测距模块支持具名 distance 方法补全")
	await _set_source(ninth, "main() {\n    move(0, drive.di\n}\n", 1, 20)
	_check(ninth._completion.suggestion.is_empty(), "未具有测距能力的实例不提供 distance 候选")
	await _set_source(ninth, EMPTY_PROGRAM, 1, 4)
	await _type_ascii("move(")
	_check(ninth._code.get_line(1) == "    move()" and ninth._code.get_caret_column() == 9, "真实输入左括号使用 CodeEdit 原生自动配对")
	await _type_ascii("0, di")
	_check(ninth._code.get_line(1) == "    move(0, di)" and ninth._completion.suggestion == "stance", "原生闭括号位于光标右侧时仍能补全测距参数")
	await _key(KEY_TAB)
	_check(ninth._code.get_line(1) == "    move(0, distance)" and ninth.session.source == ninth._code.text, "真实 Tab 在自动配对括号内只接受 stance 后缀")
	_check(ninth._code.get_caret_column() == 20 and ninth._code.get_line(1).count(")") == 1, "接受后光标停在原有闭括号前且没有重复括号")


## 运行、暂停和全尺寸动画均使用原有编辑锁，建议不能绕过这些输入约束。
func _test_running_and_preview_locks(game: GameShell) -> void:
	var workbench := await _enter_program(game, 0)
	if workbench == null:
		return
	await _set_source(workbench, MOVEMENT_PROGRAM, 1, 6)
	workbench.header.run_button.pressed.emit()
	await _settle()
	_check(workbench.session.state == GameSession.State.RUNNING and not workbench._code.editable, "真实运行流程锁住代码编辑")
	await _type_ascii("mo")
	await _key(KEY_TAB)
	_check(workbench._completion.suggestion.is_empty() and workbench._code.text == MOVEMENT_PROGRAM and workbench.session.source == MOVEMENT_PROGRAM, "运行中键入和 Tab 不修改程序或生成建议")
	workbench.header.pause_button.pressed.emit()
	await _settle()
	_check(workbench.session.state == GameSession.State.PAUSED and not workbench._code.editable, "真实暂停仍保持编辑锁")
	await _key(KEY_TAB)
	_check(workbench._completion.suggestion.is_empty() and workbench._code.text == MOVEMENT_PROGRAM, "暂停状态的 Tab 不接受补全")
	workbench.header.stop_button.pressed.emit()
	await _set_source(workbench, "main() {\n    mo\n}\n", 1, 6)
	_check(workbench._completion.suggestion == "ve", "停止后恢复正常行内建议")
	var source_before := workbench._code.text
	workbench._preview_button.pressed.emit()
	_check(workbench._preview_layout.transitioning and not workbench._code.editable, "全尺寸展开立即进入编辑锁")
	await _key(KEY_TAB)
	_check(workbench._completion.suggestion.is_empty() and workbench._code.text == source_before and workbench.session.source == source_before, "展开动画中的 Tab 不能接受或泄漏隐藏候选")
	var weak_completion: WeakRef = weakref(workbench._completion)
	game._back_to_levels()
	await _settle()
	_check(weak_completion.get_ref() == null and game.workbench == null, "退出动画中的页面后同时释放补全控件")


## 设置固定源文档后模拟聚焦与定位，不用候选接口直接伪造输入结果。
func _set_source(workbench: GameWorkbench, source: String, line: int, column: int) -> void:
	workbench._code.remove_secondary_carets()
	workbench._code.deselect()
	workbench._code.text = source
	workbench._code.text_changed.emit()
	workbench._code.clear_undo_history()
	workbench._code.set_caret_line(line)
	workbench._code.set_caret_column(column)
	workbench._code.scroll_vertical = 0
	workbench._code.scroll_horizontal = 0
	workbench._code.grab_focus()
	await _settle()
	workbench._completion.refresh()
	await _settle()


## 每个字符经过根视口派发，让 CodeEdit 原生输入顺序与 gui_input 处理真实交互。
func _type_ascii(value: String) -> void:
	for index in value.length():
		var character := value.substr(index, 1)
		var event := InputEventKey.new()
		event.keycode = character.to_upper().unicode_at(0)
		event.physical_keycode = event.keycode
		event.unicode = character.unicode_at(0)
		event.pressed = true
		root.push_input(event)
		event.pressed = false
		root.push_input(event)
	await _settle()


## 按下与释放均进入视口，不重复手动调用信号以免掩盖二次缩进问题。
func _key(keycode: Key, shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.shift_pressed = shift
	event.pressed = true
	root.push_input(event)
	event.pressed = false
	root.push_input(event)
	await _settle()


## 记录正式草稿通知，确认灰色视觉建议不被误认为用户编辑。
func _record_draft_change() -> void:
	_draft_notifications += 1


## 等待光标、输入信号和容器的延迟刷新，避免固定长时间睡眠。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 清理严格限制为本进程创建的测试根目录，不触及正式玩家数据。
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


## 保留独立断言以提供具体失败原因，并让总结果返回非零状态。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 超时中止确保脚本异常不会让测试被误认为成功或永久等待。
func _timeout() -> void:
	push_error("行内补全回归超过 36 秒总时限。")
	quit(1)
