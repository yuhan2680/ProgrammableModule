extends SceneTree
## 真实代码编辑器验证配色即时应用，以及源码、原生编辑历史和运行状态的保留。

const EMPTY_PROGRAM := "main() {\n    \n}\n"
const RUN_PROGRAM := "main() {\n    move(0, 4)\n}\n"

var _checks := 0
var _failures := 0
var _temporary := ""
var _draft_events := 0


## 等待场景树初始化后再处理真实编辑器和焦点。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 使用独占存档和同一个工作台贯穿换色、补全、撤销及运行测试。
func _run() -> void:
	create_timer(45.0).timeout.connect(_timeout)
	_temporary = "user://tests/code_color_editor_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	await _test_readonly_preview()
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game._enter_level(game.catalog.levels[0])
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "通过正常空装配入口安装中心移动模块")
	game._confirm_assembly()
	await _settle()
	var bench := game.workbench
	_check(bench != null, "真实组装确认后进入编程工作台")
	if bench != null:
		bench.set_process(false)
		bench.draft_changed.connect(_on_draft)
		_check(game.settings.code_color_mode == "light" and _background(bench._code) == Color("F5F7FB"), "默认浅色保持原代码背景")
		await _test_editing_state(game, bench)
		await _test_completion(game, bench)
		await _test_hint_margin_and_undo(game, bench)
		await _test_runtime_highlights(game, bench)
		await _test_initial_dark_assist(game)
	game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("代码配色编辑器回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 只读预览直接复用正式样式接口，浅色往返不改变源码、字号或只读属性。
func _test_readonly_preview() -> void:
	var edit := CodeEdit.new()
	edit.theme = GameTheme.create_theme()
	edit.size = Vector2(680, 240)
	edit.editable = false
	edit.add_theme_font_size_override("font_size", 16)
	edit.text = "// 注释\nmain() {\n    variable step = 0.5\n    move(0, step)\n}\n"
	root.add_child(edit)
	GameTheme.style_code(edit)
	var source := edit.text
	var initial_version := edit.get_version()
	var light_syntax := edit.syntax_highlighter as CodeHighlighter
	_check(light_syntax.number_color == Color("B46428") and light_syntax.get_keyword_color("move") == Color("176A94"), "缺省语法色保持原有数值和移动指令颜色")
	GameTheme.style_code(edit, "dark")
	await _settle()
	_check_dark_palette(edit)
	_check((edit.get_theme_stylebox("read_only") as StyleBoxFlat).bg_color == Color("121314"), "只读预览与运行锁使用同一深色背景")
	_check(edit.text == source and edit.get_version() == initial_version and not edit.editable and edit.get_theme_font_size("font_size") == 16, "预览换色保留示例原文、版本、只读状态和自定义字号")
	GameTheme.style_code(edit, "light")
	_check(_background(edit) == Color("F5F7FB") and edit.get_theme_color("font_color") == GameTheme.TEXT, "预览切回浅色恢复原背景及正文颜色")
	edit.queue_free()
	await _settle()


## 有真实撤销记录、选区及双向滚动时，设置通知只能改变编辑区的颜色。
func _test_editing_state(game: GameShell, bench: GameWorkbench) -> void:
	var original := "main() {\n" + "    // 保留玩家的注释和代码\n".repeat(90) + "    // " + "wide_source_".repeat(90) + "\n}\n"
	await _set_source(bench, original, 1, 4)
	bench._code.begin_complex_operation()
	bench._code.insert_text_at_caret("我的修改 ")
	bench._code.end_complex_operation()
	await _settle()
	var edited := bench._code.text
	bench._code.set_caret_line(32)
	bench._code.set_caret_column(12)
	bench._code.select(32, 4, 32, 12)
	bench._code.scroll_vertical = 24
	bench._code.scroll_horizontal = 120
	await _settle()
	_check(bench._code.has_undo() and bench._code.has_selection() and bench._code.scroll_vertical > 10 and bench._code.scroll_horizontal > 50, "建立包含原生撤销、选区和双向滚动的真实编辑夹具")
	var snapshot := _snapshot(bench)
	_check(game.settings.set_code_color_mode("dark").is_ok(), "已有工作台接收深色设置")
	_check(_background(bench._code) == Color("121314"), "设置发出变更信号的同一帧应用指定深色背景")
	await _settle()
	_check_preserved(bench, snapshot, "浅色切深色")
	_check_dark_palette(bench._code)
	_check((bench._edit_panel.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == Color.WHITE and (bench._world_panel.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == Color.WHITE, "代码与地图外层卡片保持原白色")
	game.settings.set_code_color_mode("light")
	await _settle()
	_check_preserved(bench, snapshot, "深色切浅色")
	_check(_background(bench._code) == Color("F5F7FB"), "已有工作台可以恢复浅色")
	bench._code.undo()
	await _settle()
	_check(bench._code.text == original and bench.session.source == original, "换色没有插入撤销事务，单次撤销仍仅撤回玩家修改")
	game.settings.set_code_color_mode("dark")
	bench._code.redo()
	await _settle()
	_check(bench._code.text == edited and bench.session.source == edited, "撤销后换色仍保留原生重做内容")


## 灰色候选按当前色盘绘制，自动配对括号不被改写，实际 Tab 接受后仍可撤销。
func _test_completion(game: GameShell, bench: GameWorkbench) -> void:
	var incomplete := "main() {\n    mo()\n}\n"
	await _set_source(bench, incomplete, 1, 6)
	_check(bench._completion.suggestion == "ve", "配对括号前仍显示移动指令后缀")
	var snapshot := _snapshot(bench)
	game.settings.set_code_color_mode("light")
	await _settle()
	_check(bench._completion.suggestion == "ve" and bench._completion.ghost_color() == Color("9BA4B2"), "浅色保持原灰字颜色和候选")
	game.settings.set_code_color_mode("dark")
	await _settle()
	_check(bench._completion.suggestion == "ve" and bench._completion.ghost_color() == Color("8C929A"), "深色立即使用清晰灰色候选")
	_check_preserved(bench, snapshot, "有灰色补全时换色")
	await _key(KEY_TAB)
	_check(bench._code.get_line(1) == "    move()" and bench.session.source == bench._code.text, "深色下真实 Tab 仅补全后缀并保留唯一括号对")
	game.settings.set_code_color_mode("light")
	bench._code.undo()
	await _settle()
	_check(bench._code.text == incomplete, "接受后换色不妨碍一次原生撤销恢复补全前源码")


## 提示边距只缓存尺寸，显隐与主题交替时不能将旧色背景回写到编辑器。
func _test_hint_margin_and_undo(game: GameShell, bench: GameWorkbench) -> void:
	await _set_source(bench, EMPTY_PROGRAM, 1, 4)
	game.settings.set_code_hints("more")
	bench._hint_button.pressed.emit()
	await _settle()
	_check(bench._hint_undo_button.visible and bench._code.text.contains("move(0, 4)"), "真实提示插入建立相邻撤销按钮与独立历史")
	var snapshot := _snapshot(bench)
	var right_margin := bench._code.get_theme_stylebox("normal").get_content_margin(SIDE_RIGHT)
	game.settings.set_code_color_mode("dark")
	await _settle()
	_check_preserved(bench, snapshot, "提示与撤销可见时换色")
	_check(bench._hint_undo_button.visible and right_margin >= 88 and bench._code.get_theme_stylebox("normal").get_content_margin(SIDE_RIGHT) == right_margin, "换色保留提示按钮位置所需边距及撤销可用性")
	_check_assist_appearance(bench, true, "提示插入后切深色")
	game.settings.set_code_color_mode("light")
	await _settle()
	_check_assist_appearance(bench, false, "带可撤销提示切回浅色")
	_check_preserved(bench, snapshot, "提示按钮深浅往返")
	game.settings.set_code_color_mode("dark")
	await _settle()
	# 真实预览过渡使用整卡合成，按钮采样应暂停，收回后恢复而不破坏提示历史。
	bench._preview_button.pressed.emit()
	_check(bench._preview_busy(), "提示存在时真实进入全尺寸过渡")
	_check_assist_backdrop(bench, false, "全尺寸展开过渡")
	await _wait_preview(bench)
	_check_assist_backdrop(bench, false, "全尺寸编辑卡片已隐藏")
	bench._preview_button.pressed.emit()
	_check_assist_backdrop(bench, false, "全尺寸收回过渡")
	await _wait_preview(bench)
	_check_assist_appearance(bench, true, "全尺寸收回后恢复")
	bench._hint_undo_button.pressed.emit()
	await _settle()
	_check(bench._code.text == EMPTY_PROGRAM, "深色下相邻撤销按钮仍只撤最近一次提示")
	game.settings.set_code_hints("none")
	_check(_background(bench._code) == Color("121314") and bench._code.get_theme_stylebox("normal").get_content_margin(SIDE_RIGHT) < 88, "关闭提示只收回边距并保留深色背景")
	_check_assist_backdrop(bench, false, "深色关闭代码提示")
	game.settings.set_code_color_mode("light")
	game.settings.set_code_hints("more")
	game.settings.set_code_color_mode("dark")
	game.settings.set_code_hints("none")
	_check(_background(bench._code) == Color("121314") and (bench._code.get_theme_stylebox("read_only") as StyleBoxFlat).bg_color == Color("121314"), "多轮换色及提示显隐不会恢复过期的可编辑或只读背景")


## 在创建工作台前选定深色，防止初始同步因模式相同而漏掉提示按钮主题。
func _test_initial_dark_assist(game: GameShell) -> void:
	game.settings.set_code_color_mode("dark")
	game.settings.set_code_hints("more")
	game._enter_level(game.catalog.levels[0])
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "初始深色用例仍从真实空装配开始")
	game._confirm_assembly()
	await _settle()
	var bench := game.workbench
	_check(bench != null, "预先选择深色后建立新工作台")
	if bench == null:
		return
	bench.set_process(false)
	bench.draft_changed.connect(_on_draft)
	_check(bench._hint_button.visible and _background(bench._code) == Color("121314"), "工作台首次出现即显示深色编辑区和提示入口")
	_check_assist_appearance(bench, true, "初始即深色")
	var snapshot := _snapshot(bench)
	game.settings.set_code_color_mode("light")
	await _settle()
	_check_assist_appearance(bench, false, "初始深色恢复浅色")
	game.settings.set_code_color_mode("dark")
	await _settle()
	_check_assist_appearance(bench, true, "初始深色往返后")
	_check_preserved(bench, snapshot, "新工作台提示外观往返")


## 检查实际按钮资源、半透明底和不截获输入的玻璃层，浅色须完整恢复旧外观。
func _check_assist_appearance(bench: GameWorkbench, dark: bool, context: String) -> void:
	var buttons := {"workbench_code_hint": bench._hint_button, "workbench_hint_undo": bench._hint_undo_button}
	for asset: String in buttons:
		var button: Button = buttons[asset]
		var expected_path := "res://assets/ui/%s%s.svg" % [asset, "_dark" if dark else ""]
		var expected_fill := Color("30343B") if dark else Color("E9EDF3")
		var style := button.get_theme_stylebox("normal") as StyleBoxFlat
		var matches_fill := false
		if style != null:
			matches_fill = Color(style.bg_color, 1.0).is_equal_approx(expected_fill)
			matches_fill = matches_fill and (style.bg_color.a > 0 and style.bg_color.a < 1 if dark else is_equal_approx(style.bg_color.a, 1.0))
		_check(button.icon != null and button.icon.resource_path == expected_path and matches_fill, "提示与撤销使用当前模式的轮廓SVG和圆底：" + asset + " " + context)
		var glass := button.get_node_or_null("CodeAssistGlass") as ColorRect
		_check(glass != null and glass.mouse_filter == Control.MOUSE_FILTER_IGNORE and glass.show_behind_parent, "玻璃圆底位于SVG之后且不拦截提示或撤销点击：" + asset + " " + context)
	_check_assist_backdrop(bench, dark, context)


## 只在可见深色代码卡片中采样，浅色、关闭提示与预览过渡都应停用屏幕读取。
func _check_assist_backdrop(bench: GameWorkbench, active: bool, context: String) -> void:
	var backdrop := bench._code.get_node_or_null("CodeAssistBackdrop") as BackBufferCopy
	_check(backdrop != null and backdrop.copy_mode == (BackBufferCopy.COPY_MODE_RECT if active else BackBufferCopy.COPY_MODE_DISABLED), "按当前可见状态启停玻璃背景采样：" + context)
	for button: Button in [bench._hint_button, bench._hint_undo_button]:
		var glass := button.get_node_or_null("CodeAssistGlass") as ColorRect
		_check(glass != null and glass.is_visible_in_tree() == (active and button.is_visible_in_tree()), "玻璃绘制与实际按钮可见性同步：" + context)


## 等待真实全尺寸动画结束，设定帧数上限以免异常过渡挂起既有回归。
func _wait_preview(bench: GameWorkbench) -> void:
	for unused in 360:
		if not bench._preview_busy():
			await _settle()
			return
		await process_frame
	_check(false, "全尺寸过渡未在限定帧数内结束")


## 正在执行、暂停和失败时只刷新行底色，保留原解释器、当前指令与失败记录。
func _test_runtime_highlights(game: GameShell, bench: GameWorkbench) -> void:
	await _set_source(bench, RUN_PROGRAM, 1, 4)
	bench._run_program()
	bench.session.step()
	bench.session.step()
	bench._accumulator = 0.047
	_check(bench.session.state == GameSession.State.RUNNING and bench._highlighted_line == 1 and not bench._code.editable, "真实模拟进入移动执行行并锁住代码")
	var running := _snapshot(bench)
	game.settings.set_code_color_mode("light")
	await _settle()
	_check_preserved(bench, running, "运行中换色")
	_check(bench._code.get_line_background_color(1) == Color("E2EEFF"), "切回浅色保留同一运行行并恢复原浅蓝底")
	bench.session.pause()
	var paused := _snapshot(bench)
	game.settings.set_code_color_mode("dark")
	await _settle()
	_check_preserved(bench, paused, "暂停中换色")
	_check(bench._code.get_line_background_color(1) == Color("243343") and not bench._code.editable, "暂停保持同一执行行，深色执行底仍清晰且维持只读")
	bench.session.stop()
	await _set_source(bench, "main() {\n    unknown()\n}\n", 1, 4)
	bench._run_program()
	_check(bench.session.state == GameSession.State.FAILED and bench._highlighted_line == 1, "实际语法错误定位到第二行")
	var failed := _snapshot(bench)
	_check(bench._code.get_line_background_color(1) == Color("3D242B"), "深色语法错误使用可读暗红底")
	game.settings.set_code_color_mode("light")
	await _settle()
	_check_preserved(bench, failed, "错误后换色")
	_check(bench._code.get_line_background_color(1) == Color("FBE5E8"), "浅色恢复原错误底且不丢失错误行")
	game.settings.set_code_color_mode("dark")
	await _settle()
	_check_preserved(bench, failed, "错误状态再次切深色")
	var saved := GameSettings.new(game.settings_path)
	_check(saved.load_settings().is_ok() and saved.code_color_mode == "dark", "工作台使用的配色与独立重载设置一致")


## 保存编辑对象、源码、视图和真实模拟状态，用完整快照判断是否存在隐藏副作用。
func _snapshot(bench: GameWorkbench) -> Dictionary:
	var edit := bench._code
	return {
		"editor": edit, "source": edit.text, "session_source": bench.session.source,
		"version": edit.get_version(), "has_undo": edit.has_undo(), "has_redo": edit.has_redo(),
		"caret": Vector2i(edit.get_caret_column(), edit.get_caret_line()), "caret_count": edit.get_caret_count(),
		"selection": edit.get_selected_text(), "selection_from": Vector2i(edit.get_selection_from_column(), edit.get_selection_from_line()) if edit.has_selection() else Vector2i(-1, -1),
		"selection_to": Vector2i(edit.get_selection_to_column(), edit.get_selection_to_line()) if edit.has_selection() else Vector2i(-1, -1),
		"scroll": Vector2(edit.scroll_horizontal, edit.scroll_vertical), "editable": edit.editable,
		"font": edit.get_theme_font("font"), "font_size": edit.get_theme_font_size("font_size"),
		"world": bench.session.world, "runner": bench.session.runner, "state": bench.session.state,
		"current_line": bench.session.current_line, "highlighted_line": bench._highlighted_line,
		"message": bench.session.message, "failures": bench.session.consecutive_failures,
		"tick": bench.session.world.tick_index if bench.session.world != null else -1,
		"position": bench.session.world.player.position if bench.session.world != null else Vector2.ZERO,
		"modules": JSON.stringify(bench.session.assembly.modules), "accumulator": bench._accumulator,
		"draft_events": _draft_events,
	}


## 每项状态分别断言，失败时直接指出被配色切换误改的对象或属性。
func _check_preserved(bench: GameWorkbench, previous: Dictionary, label: String) -> void:
	var current := _snapshot(bench)
	for key: String in previous:
		_check(current[key] == previous[key], "%s保持%s，原值=%s，实际=%s" % [label, key, str(previous[key]), str(current[key])])


## 检查指定背景与实际语法、光标和选区颜色对比度，确保深色中的内容可辨认。
func _check_dark_palette(edit: CodeEdit) -> void:
	var background := _background(edit)
	var syntax := edit.syntax_highlighter as CodeHighlighter
	_check(background == Color("121314") and edit.get_theme_color("background_color").a == 0, "深色为精确的不透明#121314底，不叠加其他背景色")
	_check(syntax != null and syntax.has_keyword_color("function") and syntax.has_keyword_color("variable") and syntax.has_keyword_color("scan"), "新旧DSL关键词均保留语法高亮")
	for color: Color in [edit.get_theme_color("font_color"), edit.get_theme_color("line_number_color"), edit.get_theme_color("completion_ghost_color"), syntax.number_color, syntax.symbol_color, syntax.function_color, syntax.get_keyword_color("main"), syntax.get_keyword_color("move"), syntax.get_keyword_color("scan")]:
		_check(_contrast(color, background) >= 4.5, "深色正文、行号、灰补全及语法色均达到4.5:1对比度")
	_check(_contrast(edit.get_theme_color("font_selected_color"), edit.get_theme_color("selection_color")) >= 4.5, "深色选区中的正文保持清晰")
	_check(_contrast(edit.get_theme_color("font_color"), edit.get_theme_color("current_line_color")) >= 4.5, "深色当前行底色保持正文可读")
	_check(_contrast(edit.get_theme_color("caret_color"), background) >= 7, "深色光标与背景清楚区分")


## 读取编辑器真正绘制的面板背景，而非仅检查设置模型字段。
func _background(edit: CodeEdit) -> Color:
	return (edit.get_theme_stylebox("normal") as StyleBoxFlat).bg_color


## 按线性亮度计算文字对比度，验证颜色效果而非只镜像色盘常量。
func _contrast(first: Color, second: Color) -> float:
	var a := first.srgb_to_linear().get_luminance()
	var b := second.srgb_to_linear().get_luminance()
	return (maxf(a, b) + 0.05) / (minf(a, b) + 0.05)


## 设置测试起始文本并清空夹具历史，后续修改与撤销全部经过原生CodeEdit。
func _set_source(bench: GameWorkbench, source: String, line: int, column: int) -> void:
	bench._code.remove_secondary_carets()
	bench._code.deselect()
	bench._code.text = source
	bench._code.text_changed.emit()
	bench._code.clear_undo_history()
	bench._code.set_caret_line(line)
	bench._code.set_caret_column(column)
	bench._code.scroll_vertical = 0
	bench._code.scroll_horizontal = 0
	bench._code.grab_focus()
	await _settle()
	bench._completion.refresh()
	await _settle()


## 使用真实按下与释放事件验证Tab入口，不绕过控件自己的输入处理。
func _key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await _settle()


## 统计真实草稿通知，纯样式操作不得触发保存玩家代码的信号。
func _on_draft() -> void:
	_draft_events += 1


## 等待布局、光标位置与延迟文本通知稳定，模拟tick仍由用例手动推进。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 清理范围严格限定本次独占测试目录，不能触及默认玩家设置或草稿。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not (path == _temporary or path.begins_with(_temporary + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 汇总断言失败并保留具体原因，防止脚本错误被成功退出掩盖。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 总时限失败返回非零状态，避免异步异常造成测试永久等待。
func _timeout() -> void:
	push_error("代码配色编辑器回归超过45秒总时限。")
	quit(1)
