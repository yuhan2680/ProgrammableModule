extends SceneTree
## 验证代码卡片内布局和百分比缩放，不用重建编辑器模拟用户操作。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""


## 使用独占档案并延迟到场景树准备完成后建立真实工作台。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 覆盖配色、字号边界、长错误和编辑状态保留，截图仅在真实图形后端执行。
func _run() -> void:
	_temporary = "user://tests/code_layout_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_game._enter_level(_game.catalog.levels[4])
	_game._dialogue_dialog.hide()
	_game.session.assembly.add_module("movement", Vector2.ZERO, "drive")
	_game.session.assembly.add_module("melee", Vector2(-0.5, 0), "left")
	_game.session.assembly.add_module("melee", Vector2(0.5, 0), "right")
	_game._confirm_assembly()
	await _settle()
	var bench := _game.workbench
	bench.set_process(false)
	_check(bench._tabs.get_tab_count() == 1 and bench.find_child("WorkbenchModePill", true, false) == null, "代码框不再包含旧装配页签或模式胶囊")
	_check(bench._edit_panel.is_ancestor_of(bench._status) and bench._code_toolbar.is_ancestor_of(bench._code_zoom), "字号与错误状态位于代码卡片内")
	_check(bench.code_zoom_percent == 100 and bench._code.get_theme_font_size("font_size") == 17, "默认保持原字号100%")
	await _click_code(bench._code)
	_check(bench._code.has_focus() and bench._code.caret_blink, "点击代码仍取得原生输入焦点并保持闪烁光标")
	_check(bench._code.get_theme_stylebox("focus") is StyleBoxEmpty, "代码获得焦点时不绘制蓝色外框")
	await _capture("code_focused")
	bench._code.text = "main() {\n}\n" + ("// " + "long_comment_".repeat(30) + "\n").repeat(100)
	bench._code.set_caret_line(50)
	bench._code.set_caret_column(12)
	bench._code.insert_text_at_caret("test_undo")
	await _settle()
	_check(not bench._code.deselect_on_focus_loss_enabled, "实际工作台在工具栏和导航失焦时保留选区")
	bench._code.select(50, 4, 50, 12)
	bench._code.scroll_vertical = 30
	bench._code.scroll_horizontal = 40
	var source := bench._code.text
	var version := bench._code.get_version()
	var editor_id := bench._code.get_instance_id()
	for mode: String in ["dark", "light"]:
		_game.settings.set_code_color_mode(mode)
		for percent: int in [50, 100, 200]:
			bench.set_code_zoom_percent(percent)
			await _settle()
			_check(bench._code.get_instance_id() == editor_id and bench._code.text == source and bench._code.get_version() == version and bench._code.has_undo(), "缩放与配色不重建编辑器或改写撤销历史")
			_check(bench._code.has_selection() and bench._code.get_selection_from_column() == 4 and bench._code.get_selection_to_column() == 12, "缩放保留选区")
			_check(bench._code.get_theme_font_size("font_size") == roundi(17 * percent / 100.0) and bench._status.get_theme_font_size("font_size") == roundi(14 * percent / 100.0), "代码与错误文本同步缩放")
			_check(bench._code_zoom.decrease_button.disabled == (percent == 50) and bench._code_zoom.increase_button.disabled == (percent == 200), "百分比端点正确禁用按钮")
			_check(bench._code.get_global_rect().position.y >= bench._code_toolbar.get_global_rect().end.y, "代码首行避开字号与提示工具栏")
			_check(bench._edit_panel.get_global_rect().encloses(bench._code.get_global_rect()), "代码框保持在卡片内部")
			_check(bench._code.get_theme_stylebox("focus") is StyleBoxEmpty and bench._code.caret_blink, "切换配色和字号不会恢复焦点蓝框或关闭光标闪烁")
	bench.set_code_zoom_percent(100)
	for button: Button in [bench._code_zoom.increase_button, bench._code_zoom.decrease_button]:
		bench._code.grab_focus()
		_check(bench._code.has_focus(), "真实点击字号前由原生代码编辑器持有焦点")
		await _click(button)
		_check(bench.code_zoom_percent == (110 if button == bench._code_zoom.increase_button else 100), "真实鼠标点击字号按钮调整10%")
		_check(bench._code.has_selection() and bench._code.get_selection_from_line() == 50 and bench._code.get_selection_from_column() == 4 and bench._code.get_selection_to_line() == 50 and bench._code.get_selection_to_column() == 12, "字号按钮取得并释放焦点仍保留原选区")
		_check(bench._code.text == source and bench._code.get_version() == version and bench._code.has_undo(), "真实字号点击不改源码或撤销历史")
		_check(not bench._code_zoom.increase_button.has_focus() and not bench._code_zoom.decrease_button.has_focus(), "鼠标字号操作没有残留按钮焦点")
	bench.set_code_zoom_percent(-20)
	_check(bench.code_zoom_percent == 50, "外部非法低值钳制50%")
	bench.set_code_zoom_percent(999)
	_check(bench.code_zoom_percent == 200, "外部非法高值钳制200%")
	_game.settings.set_code_color_mode("dark")
	bench._code.text = "main() {\n    lift.attack(180)\n    right.attack(0)\n    move(90, 5)\n}"
	bench.header.run_button.pressed.emit()
	await _settle()
	_check(bench.session.state == GameSession.State.FAILED and bench._status.text.contains("lift"), "真实运行错误显示到卡片底部")
	_check(bench._status_row.get_child_count() == 1, "底部只有状态消息，不再显示位置与模拟时间")
	_check(bench._status.get_theme_color("font_color") == GameTheme.ERROR, "原错误红色不随深色或字号改变")
	for dimensions: Vector2i in [Vector2i(1000, 740), Vector2i(1280, 800), Vector2i(1920, 1080)]:
		root.size = dimensions
		for percent: int in [50, 100, 200]:
			bench.set_code_zoom_percent(percent)
			await _settle()
			_check(bench._edit_panel.get_global_rect().encloses(bench._status_scroll.get_global_rect()), "错误滚动栏不溢出代码卡片")
			_check(bench._status_scroll.size.y <= 161 and bench._code.size.y >= 120, "长错误保留可用代码高度")
			if dimensions == Vector2i(1920, 1080) and percent in [100, 200]:
				await _capture("code_layout_%d" % percent)
	bench.set_code_zoom_percent(100)
	bench._code.undo()
	await _settle()
	_check(bench._code != null, "缩放后的原生编辑器仍可操作")
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("代码布局与字号回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 真实图形后端可按显式环境变量输出截图，headless不制造空图成功记录。
func _capture(label: String) -> void:
	var directory := OS.get_environment("CODEX_WORKBENCH_CAPTURE")
	if directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(label + ".png"))


## 原生鼠标按下与释放会经过焦点转移，不能用 pressed.emit 跳过选区丢失路径。
func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		event.global_position = point
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)
		await process_frame
	await _settle()


## 使用真实编辑器鼠标事件确认移除描边没有通过禁用焦点绕过输入行为。
func _click_code(editor: CodeEdit) -> void:
	var point := editor.get_global_rect().position + Vector2(100.0, 20.0)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		event.global_position = point
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)
		await process_frame
	await _settle()


## 等待原生容器和字号的延迟布局完成。
func _settle() -> void:
	for unused in 10:
		await process_frame


## 失败持续记录，不因后续断言成功而掩盖。
func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)


## 清理仅限本次隔离夹具路径。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
