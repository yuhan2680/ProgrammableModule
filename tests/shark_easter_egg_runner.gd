extends SceneTree
## 彩蛋入口与独立游戏的真实输入回归；不打开外链，不读写真实用户设置、关卡或进度。

const EXPECTED_LOGO_CLICKS := 7

var _checks := 0
var _failures := 0
var _finished := false
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _dialog: AboutGameDialog
var _anchor: Button
var _signals_received := 0
var _original_locale := ""
var _original_volume := 0.0
var _original_mute := false
var _original_low_processor_mode := false
var _original_max_fps := 0


## 截图必须显式指定目录；无图形后端只运行行为检查，不制造截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 先隔离验证完整七击，再经设置入口运行游戏；超时和正常退出均清理测试目录。
func _run() -> void:
	_temporary = "user://tests/shark_easter_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	_original_low_processor_mode = OS.low_processor_usage_mode
	_original_max_fps = Engine.max_fps
	OS.low_processor_usage_mode = false
	Engine.max_fps = 120
	create_timer(150.0).timeout.connect(_timeout)
	root.gui_embed_subwindows = true
	root.size = Vector2i(1280, 800)
	root.content_scale_size = Vector2i(1280, 800)
	if DisplayServer.get_name() != "headless":
		# macOS 初次显示窗口的迟到失焦通知不能混入七击手势本身的测试。
		root.grab_focus()
		await create_timer(0.35).timeout
		await _settle(8)
		_check(root.has_focus(), "GPU 回归开始前窗口已获得焦点")
	await _check_click_gate()
	await _create_game()
	await _check_hidden_entry()
	await _check_entry_cancellation()
	await _check_full_run()
	await _check_ink_run()
	await _check_tuna_run()
	await _check_sizes_and_languages()
	var saved_best := int(_game.profile.get_statistics().shark_best_score)
	await _dispose_game()
	await _create_game()
	await _open_settings_and_about()
	await _unlock_game()
	if _check(_game.shark_game != null, "重建外壳仍可通过隐藏入口进入"):
		_check(saved_best > 0 and _game.shark_game.best_score >= saved_best and _game.shark_game.best_score == int(_game.profile.get_statistics().shark_best_score) and bool(_game.profile.get_statistics().shark_discovered), "真实碰撞取得的最高分和触发标记跨外壳会话持久化并回填彩蛋界面")
	await _dispose_game()
	_finish()


## 独立窗口让第七击的信号可观察，避免立即打开彩蛋遮盖后续入口边界检查。
func _check_click_gate() -> void:
	_check(AboutGameDialog.LOGO_CLICK_TARGET == EXPECTED_LOGO_CLICKS, "隐藏入口按最新要求连续七次触发")
	GameI18n.install()
	_anchor = Button.new()
	_anchor.text = "Test anchor"
	_anchor.position = Vector2(12, 12)
	_anchor.size = Vector2(120, 36)
	root.add_child(_anchor)
	_dialog = AboutGameDialog.new()
	_dialog.easter_egg_requested.connect(func() -> void: _signals_received += 1)
	root.add_child(_dialog)
	await _reset_dialog()
	var icon := _dialog.find_child("AboutGameIcon", true, false) as Control
	if not _check(icon != null, "关于窗口具有软件 Logo"):
		_dialog.queue_free()
		_anchor.queue_free()
		await _settle()
		return
	for index in EXPECTED_LOGO_CLICKS - 1:
		await _click_logo(icon)
		_check(_signals_received == 0, "前 %d 次左键点击不触发彩蛋" % (index + 1))
	_mouse(icon, MOUSE_BUTTON_LEFT, true)
	await _settle()
	_check(_signals_received == 0, "第七次仅按下尚不触发")
	_mouse(icon, MOUSE_BUTTON_LEFT, false)
	await _settle()
	_check(_signals_received == 1, "第七次完整左键松开触发一次 " + _gate_state())
	for index in 10:
		await _click_logo(icon)
	_check(_signals_received == 1, "同一次关于窗口打开周期只触发一次")
	_dialog.close_dialog()
	for index in EXPECTED_LOGO_CLICKS:
		await _click_logo(icon)
	_check(_signals_received == 1, "隐藏的关于窗口不响应 Logo 点击")
	await _check_click_rhythms(icon)
	await _check_window_focus_handling(icon)
	for interruption: String in ["right", "keyboard", "title", "close", "focus", "drag"]:
		await _reset_dialog()
		for index in EXPECTED_LOGO_CLICKS - 1:
			await _click_logo(icon)
		match interruption:
			"right":
				for index in EXPECTED_LOGO_CLICKS:
					await _click(icon, MOUSE_BUTTON_RIGHT)
			"keyboard":
				_key_event(KEY_SHIFT, true)
				_key_event(KEY_SHIFT, false)
			"title":
				await _click(_dialog.find_child("AboutGameTitle", true, false) as Control)
			"close":
				_dialog.close_dialog()
				await _reset_dialog()
			"focus":
				_dialog.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
			"drag":
				_mouse(icon, MOUSE_BUTTON_LEFT, true)
				_mouse(_dialog.find_child("AboutGameTitle", true, false) as Control, MOUSE_BUTTON_LEFT, false)
				await _settle()
		_check(_signals_received == 0, "中断操作本身不触发 " + interruption)
		for index in EXPECTED_LOGO_CLICKS - 1:
			await _click_logo(icon)
		_check(_signals_received == 0, "中断后重新累计的前六击不触发 " + interruption)
		await _click_logo(icon)
		_check(_signals_received == 1, "中断后重新完成七击才能触发 " + interruption + " " + _gate_state())
	_dialog.close_dialog(false)
	_dialog.queue_free()
	_anchor.queue_free()
	await _settle()
	_dialog = null
	_anchor = null


## 重置真实弹窗的打开周期，动画完成后才发送坐标输入。
func _reset_dialog() -> void:
	_dialog.close_dialog(false)
	_signals_received = 0
	_dialog.popup_dialog(_anchor)
	await create_timer(0.20).timeout
	await _settle()


## 每个合格 Logo 点击都通过原生坐标事件完整按下和抬起。
func _click_logo(icon: Control) -> void:
	await _click(icon)


## 慢速连击不受旧的1.2秒门槛影响；系统双击标记仍只代表一次完整点击。
func _check_click_rhythms(icon: Control) -> void:
	for rhythm: String in ["slow", "double_click"]:
		await _reset_dialog()
		for index in EXPECTED_LOGO_CLICKS:
			if rhythm == "slow" and index > 0:
				await create_timer(1.3).timeout
			_mouse(icon, MOUSE_BUTTON_LEFT, true, rhythm == "double_click" and index % 2 == 1)
			_check(_signals_received == 0, "第%d次按下不提前进入 %s" % [index + 1, rhythm])
			_mouse(icon, MOUSE_BUTTON_LEFT, false)
			await _settle()
			_check(_signals_received == (1 if index == EXPECTED_LOGO_CLICKS - 1 else 0), "第%d次完整点击保持七击门槛 %s" % [index + 1, rhythm])


## 窗口级迟到通知必须等一帧确认；实际应用失焦仍立即清零并取消展开。
func _check_window_focus_handling(icon: Control) -> void:
	await _reset_dialog()
	for index in EXPECTED_LOGO_CLICKS - 1:
		await _click_logo(icon)
	_dialog.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(_dialog.get("_logo_click_count") == EXPECTED_LOGO_CLICKS - 1, "窗口级失焦先等待真实焦点状态，不同步丢弃六次点击")
	await _settle()
	if not root.has_focus():
		_check(_dialog.get("_logo_click_count") == 0, "确认窗口仍失焦后清空隐藏手势")
		return
	_check(_dialog.get("_logo_click_count") == EXPECTED_LOGO_CLICKS - 1, "窗口仍有焦点时忽略迟到失焦通知")
	await _click_logo(icon)
	_check(_signals_received == 1, "暂态窗口通知后第七次完整点击仍进入")
	_check(_dialog.begin_easter_expansion(), "焦点回归启动真实关于展开")
	_dialog.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	await _settle()
	_check(_dialog.is_easter_expanding(), "窗口仍有焦点的迟到通知不取消展开")
	_dialog.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not _dialog.is_easter_expanding() and _dialog.get("_logo_click_count") == 0, "真实应用失焦立即取消展开并清空手势")


## 入口失败时保留计数、按键、焦点及坐标，区分原生失焦通知与实际点击命中问题。
func _gate_state() -> String:
	var icon := _dialog.find_child("AboutGameIcon", true, false) as Control
	var center := icon.get_global_transform_with_canvas() * (icon.size * 0.5)
	return "[count=%s pressed=%s latched=%s signals=%d focus=%s center=%s rect=%s]" % [_dialog.get("_logo_click_count"), _dialog.get("_logo_pressed"), _dialog.get("_logo_triggered"), _signals_received, root.has_focus(), center, icon.get_global_rect()]


## 新建真实游戏外壳，所有可能写盘的位置都指向本次独占目录。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.about_link_opener = func(_url: String) -> int: return OK
	root.add_child(_game)
	await _settle(12)


## 普通菜单、关卡页及未打开关于时不能进入隐藏游戏，也不新增显式彩蛋入口。
func _check_hidden_entry() -> void:
	_game._open_shark_game()
	_check(_game.shark_game == null and _game.find_child("SharkStartButton", true, false) == null, "主菜单不公开彩蛋入口")
	await _click(_game.find_child("StartGameButton", true, false) as Control)
	await _wait_until(func() -> bool: return not _game._menu_transitioning, 3.0, "选关入口转场结束")
	_game._open_shark_game()
	_check(_game.page == GameShell.Page.LEVELS and _game.shark_game == null, "正常选关流程不触发彩蛋")
	_game._show_main_page()
	await _settle()
	await _click(_game.find_child("SettingsButton", true, false) as Control)
	if not await _wait_settings_transition():
		return
	_game._open_shark_game()
	_check(_game.page == GameShell.Page.SETTINGS and _game.shark_game == null, "仅进入设置但未打开关于不能启动彩蛋")
	_check(_game.settings_panel.find_child("SharkStartButton", true, false) == null, "设置分组没有普通可见的彩蛋按钮")


## 设置中的原生滚动容器先滚到关于入口，再通过真实点击打开。
func _open_settings_and_about() -> void:
	if _game.page != GameShell.Page.SETTINGS:
		_game._show_main_page()
		await _settle()
		await _click(_game.find_child("SettingsButton", true, false) as Control)
		if not await _wait_settings_transition():
			return
	if _game._about_dialog.is_open():
		return
	var panel := _game.settings_panel
	var entry := panel.find_child("AboutButton", true, false) as Control
	panel._scroll.ensure_control_visible(entry)
	await _settle(8)
	await _click(entry)
	await create_timer(0.20).timeout
	_check(_game._about_dialog.is_open(), "真实关于入口打开窗口")


## 真实七击启动关于卡片扩展，不直接创建游戏或跳过 Tween。
func _begin_entry() -> void:
	var icon := _game._about_dialog.find_child("AboutGameIcon", true, false) as Control
	for index in EXPECTED_LOGO_CLICKS - 1:
		await _click_logo(icon)
	_check(_game.shark_game == null and not _game._about_dialog.is_easter_expanding(), "Shell 前六击保持原关于卡片")
	await _click_logo(icon)
	await _settle()
	_check(_game.shark_game == null and _game._about_dialog.is_easter_expanding() and _game._about_dialog.is_open(), "第七击先扩展关于卡片，不提前显示游戏")


## 等待真实卡片扩展和游戏淡入，仅冻结游戏自身帧驱动以便后续精准检查四秒引导。
func _unlock_game() -> void:
	await _begin_entry()
	if not await _wait_until(func() -> bool: return _game.shark_game != null, 3.0, "关于卡片扩展完成后创建唯一游戏实例"):
		return
	var mini := _game.shark_game
	mini.set_process(false)
	_check(mini.process_mode == Node.PROCESS_MODE_DISABLED and mini.screen_state == SharkCaveGame.Screen.INTRO, "游戏淡入时禁用处理，不提前消费四秒引导")
	await _wait_until(func() -> bool: return not _game._about_dialog.is_easter_expanding() and not _game._about_dialog.is_open(), 3.0, "淡入结束才关闭关于并完成入口")
	_check(_game.shark_game == mini and mini.process_mode != Node.PROCESS_MODE_DISABLED and mini.modulate.a >= 0.99, "淡入后启用同一游戏实例且完整可见")
	_check(mini.screen_state == SharkCaveGame.Screen.INTRO and mini.run.state == SharkCaveRun.State.PAUSED and mini.run.score == 0 and mini.run.distance == 0.0, "完整入口抵达自动引导，模型尚未开始计分或游动")
	_check(bool(_game.profile.get_statistics().shark_discovered), "真实入口已标记触发彩蛋，零分引导同样解锁统计")


## 等待真实节点状态变化有独立上限，避免遗漏 Tween 回调时拖到整个测试超时。
func _wait_until(condition: Callable, seconds: float, context: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(bool(condition.call()), context)


## 扩展和淡入都允许取消，原关于卡片恢复且迟到 Tween 回调不会重新创建游戏或抢回页面。
func _check_entry_cancellation() -> void:
	var files_before := _snapshot(_temporary)
	for scenario: String in ["escape_expand", "focus_fade", "exit_fade", "navigate_expand"]:
		await _open_settings_and_about()
		var dialog := _game._about_dialog
		var panel := dialog.find_child("AboutGamePanel", true, false) as Control
		var content := dialog.find_child("AboutGameLayout", true, false) as Control
		var original_rect := panel.get_global_rect()
		var original_settings := _game.settings_panel
		var original_scroll := original_settings._scroll.scroll_vertical
		await _begin_entry()
		if scenario.ends_with("expand"):
			await create_timer(0.30).timeout
			_check(panel.size.x > original_rect.size.x and panel.size.y > original_rect.size.y and _game.shark_game == null, "先扩展原关于卡片再创建游戏 " + scenario)
			_check(content.modulate.a <= 0.05 and original_settings.is_visible_in_tree(), "扩展时版权内容先淡出，底层设置仍可见 " + scenario)
			if scenario == "escape_expand":
				await _capture("shark_entry_expanding")
		else:
			if not await _wait_until(func() -> bool: return _game.shark_game != null, 3.0, "扩展后进入可取消的游戏淡入阶段 " + scenario):
				continue
			var pending := _game.shark_game
			pending.set_process(false)
			await create_timer(0.20).timeout
			_check(dialog.is_easter_expanding() and dialog.is_open() and pending.process_mode == Node.PROCESS_MODE_DISABLED and pending.modulate.a > 0.0 and pending.modulate.a < 1.0, "游戏淡入期间仍保留关于并禁止游戏处理 " + scenario)
			_check(panel.get_global_rect().grow(1.0).encloses(root.get_visible_rect()) and original_settings.is_visible_in_tree(), "关于卡片先铺满视口再交接游戏 " + scenario)
			for attempt in 3:
				_game._open_shark_game()
			_check(_game.shark_game == pending and _game.find_children("SharkCaveGame", "", true, false).size() == 1, "淡入时额外入口请求不会重复创建实例 " + scenario)
			if scenario == "focus_fade":
				await _capture("shark_entry_fading")
		match scenario:
			"escape_expand":
				await _press_escape()
			"focus_fade":
				dialog.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
				dialog.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
			"exit_fade":
				_game._close_shark_game()
			"navigate_expand":
				_game._show_main_page()
		await _settle(8)
		_check(_game.shark_game == null and not dialog.is_easter_expanding(), "取消立即清理过渡与临时游戏 " + scenario)
		if scenario != "navigate_expand":
			_check(dialog.is_open() and panel.get_global_rect().is_equal_approx(original_rect) and content.modulate.a >= 0.99, "取消恢复原尺寸和可读关于内容 " + scenario)
			_check(_game.settings_panel == original_settings and original_settings._scroll.scroll_vertical == original_scroll, "取消保留同一设置实例和滚动位置 " + scenario)
		await create_timer(1.45).timeout
		_check(_game.shark_game == null, "原 Tween 完成时间过去后仍不重建游戏 " + scenario)
		_check(not bool(_game.profile.get_statistics().shark_discovered), "在正式入口前取消不能解锁彩蛋统计 " + scenario)
		if scenario == "navigate_expand":
			_check(_game.page == GameShell.Page.MAIN and not dialog.is_open(), "取消后导航不会被迟到回调带回关于")
	_check(_snapshot(_temporary) == files_before, "扩展、淡入和取消均不修改用户存档")


## 四秒入场仅是显示引导，按键不能提前操控；失焦冻结，完成时清除旧键并等待新的真实按下。
func _check_intro(mini: SharkCaveGame) -> void:
	var canvas := mini.get("_canvas") as SharkCaveCanvas
	_check(mini.find_child("SharkMenuPanel", true, false) == null and mini.find_child("SharkStartButton", true, false) == null and mini.find_child("SharkExitButton", true, false) == null, "旧彩蛋菜单已移除，自动进入引导")
	_check(canvas != null and canvas.intro_active and canvas.intro_progress <= 0.03, "正式入场从四秒引导起点开始")
	var starting_y := mini.run.shark_y
	var starting_distance := mini.run.distance
	var starting_elapsed := mini.run.elapsed
	_key_event(KEY_UP, true)
	_advance(mini, 0.75)
	_key_event(KEY_UP, false)
	_check(mini.screen_state == SharkCaveGame.Screen.INTRO and canvas.intro_progress > 0.0 and canvas.intro_progress < 0.25, "四秒引导按独立显示时间逐步推进")
	_check(mini.run.state == SharkCaveRun.State.PAUSED and mini.run.score == 0 and mini.run.distance == starting_distance and mini.run.shark_y == starting_y and mini.run.elapsed == starting_elapsed, "引导期间上下键不移动鲨鱼，也不推进模型或分数")
	await _capture("shark_intro_shark_arriving")
	var progress_before := canvas.intro_progress
	mini.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_advance(mini, 0.60)
	_check(canvas.intro_progress == progress_before and mini.screen_state == SharkCaveGame.Screen.INTRO and mini.run.elapsed == starting_elapsed, "失焦冻结引导而不是提前进入正式游戏")
	mini.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_key_event(KEY_DOWN, true)
	_advance(mini, 1.25)
	await _capture("shark_intro_cave_halfway")
	_advance(mini, 0.80)
	await _capture("shark_intro_cave_approaching")
	_advance(mini, 0.55)
	_check(mini.screen_state == SharkCaveGame.Screen.INTRO and mini.run.score == 0 and mini.run.distance == 0.0, "四秒结束之前始终不控制或计分")
	await _capture("shark_intro_cave_arriving")
	_complete_intro(mini)
	_check(not canvas.intro_active and mini.run.state == SharkCaveRun.State.RUNNING and mini.run.score == 0 and mini.run.distance == 0.0, "四秒引导交接后从原安全起点启动真实模拟")
	await _capture("shark_intro_handoff")
	_key_event(KEY_DOWN, true, true)
	_advance(mini, 0.10)
	_check(absf(mini.run.shark_y - starting_y) < 0.01, "引导中按住的旧键及自动连发不会跨入游戏造成粘键")
	_key_event(KEY_DOWN, false)
	_key_event(KEY_UP, true)
	_advance(mini, 0.10)
	_key_event(KEY_UP, false)
	_check(mini.run.shark_y < starting_y, "交接后新的真实方向键立即获得控制")
	_advance(mini, 0.20)


## 使用真实帧驱动推进剩余引导，到正式游玩立即停止，避免替玩家多游或计分。
func _complete_intro(mini: SharkCaveGame) -> void:
	for tick in 300:
		if mini.screen_state != SharkCaveGame.Screen.INTRO:
			break
		mini._process(1.0 / 60.0)
	_check(mini.screen_state == SharkCaveGame.Screen.PLAYING and mini.run.state == SharkCaveRun.State.RUNNING, "引导自动结束并交接为正式游玩")


## 覆盖真实开始、上下移动、暂停、失焦、碰撞重试及原设置状态恢复。
func _check_full_run() -> void:
	await _open_settings_and_about()
	var original_panel := _game.settings_panel
	var saved_scroll := original_panel._scroll.scroll_vertical
	var files_before := _snapshot(_temporary)
	await _unlock_game()
	if not _check(_game.shark_game != null, "彩蛋实例已创建"):
		return
	var mini := _game.shark_game
	_check(mini.screen_state == SharkCaveGame.Screen.INTRO and mini.best_score == 0, "彩蛋首先自动播放引导且本次最佳为零")
	_check_control_hint(mini, "自动入场")
	_check(mini.get_parent() is CanvasLayer and _game.settings_panel == original_panel, "彩蛋在独立画布覆盖并保留原设置实例")
	await _capture("shark_intro_start_1280_zh_CN")
	await _check_intro(mini)
	_check(mini.run.state == SharkCaveRun.State.RUNNING, "自动引导结束进入游玩")
	_check_control_hint(mini, "开始游玩")
	var initial_y := mini.run.shark_y
	_key_event(KEY_UP, true)
	_advance(mini, 0.20)
	_key_event(KEY_UP, false)
	_check(mini.run.shark_y < initial_y, "上方向键真实输入让鲨鱼上移")
	var upper_y := mini.run.shark_y
	_key_event(KEY_DOWN, true)
	_advance(mini, 0.35)
	_key_event(KEY_DOWN, false)
	_check(mini.run.shark_y > upper_y, "下方向键真实输入让鲨鱼下移")
	_check(mini.run.distance > 0.0 and mini.run.score > 0, "存活推进产生距离及分数")
	await _capture("shark_running_1280_zh_CN")
	await _press_escape()
	_check(mini.run.state == SharkCaveRun.State.PAUSED, "真实 Esc 按键冻结模拟")
	_check_run_actions(mini, true, "首次暂停")
	await _capture("shark_paused_1280_zh_CN")
	await _check_icon_hover(mini)
	var paused_distance := mini.run.distance
	var paused_y := mini.run.shark_y
	_key_event(KEY_UP, true)
	_advance(mini, 0.40)
	_key_event(KEY_UP, false)
	_check(mini.run.distance == paused_distance and mini.run.shark_y == paused_y, "暂停期间输入与帧推进不改变位置或分数")
	_key_event(KEY_ESCAPE, true)
	_key_event(KEY_ESCAPE, false)
	await _settle()
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.distance == paused_distance, "暂停中再次 Esc 恢复同一局")
	await _press_escape()
	await _click(mini.find_child("SharkResumeButton", true, false) as Control)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.distance == paused_distance, "中央开始按钮恢复同一局")
	_check_control_hint(mini, "中央图标恢复游玩")
	_key_event(KEY_DOWN, true)
	mini.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _settle()
	_check(mini.run.state == SharkCaveRun.State.PAUSED, "失焦自动暂停")
	var focus_distance := mini.run.distance
	_advance(mini, 0.40)
	_check(mini.run.distance == focus_distance, "失焦状态不推进洞穴")
	await _click(mini.find_child("SharkResumeButton", true, false) as Control)
	_advance(mini, 0.25)
	var stopped_y := mini.run.shark_y
	_advance(mini, 0.25)
	_check(absf(mini.run.shark_y - stopped_y) < 0.01, "失焦清除按住方向键，继续后不会粘键")
	_key_event(KEY_UP, true)
	_advance_until_over(mini, 2.0)
	_key_event(KEY_UP, false)
	# 手动推进会同步进入终局，只有此处需额外等待新显示容器完成延迟布局。
	await _settle()
	_check(mini.run.state == SharkCaveRun.State.OVER and mini.screen_state == SharkCaveGame.Screen.GAME_OVER, "持续上移撞洞壁真实进入失败页面")
	await _check_failure_transition(mini)
	_check_run_actions(mini, false, "首次失败")
	var final_score := mini.run.score
	_check(final_score > 0 and mini.best_score >= final_score, "真实死亡更新当前会话最佳分数")
	_key_event(KEY_ESCAPE, true)
	_key_event(KEY_ESCAPE, false)
	await _settle()
	_check(mini.screen_state == SharkCaveGame.Screen.GAME_OVER and mini.run.state == SharkCaveRun.State.OVER, "终局 Esc 保留中央三按钮，不绕回菜单或复活")
	await _click(mini.find_child("SharkResumeButton", true, false) as Control)
	_check(mini.run.state == SharkCaveRun.State.OVER, "终局禁用的开始按钮不能恢复死亡局")
	await _capture("shark_game_over_1280_zh_CN")
	await _click(mini.find_child("SharkRetryButton", true, false) as Control)
	mini.set_process(false)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.distance < 10.0 and mini.run.score < final_score, "重试重新开始而非恢复死亡局")
	_check(absf(mini.run.shark_y - SharkCaveRun.WORLD_SIZE.y * 0.5) < 1.0, "重试恢复鲨鱼初始高度")
	_check_failure_reset(mini, "完整失败过渡后重试")
	_advance(mini, 0.30)
	await _press_escape()
	_check(mini.run.distance > 10.0, "暂停重开检查具有可观察的旧局距离")
	await _click(mini.find_child("SharkRetryButton", true, false) as Control)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.distance < 1.0, "暂停中的重新开始同样清空旧局")
	await _press_escape()
	await _click(mini.find_child("SharkExitRunButton", true, false) as Control)
	await _settle(10)
	_check(_game.shark_game == null and _game.page == GameShell.Page.SETTINGS and _game.settings_panel == original_panel, "退出清理彩蛋并恢复原设置面板")
	_check(original_panel._scroll.scroll_vertical == saved_scroll and _game._about_dialog.is_open(), "退出恢复原滚动位置并重新打开关于")
	_check(_snapshot(_temporary) == files_before, "彩蛋只允许档案累计活动时长与最高分，不写设置、教学进度、草稿或额外存档")
	await _unlock_game()
	if _check(_game.shark_game != null, "返回后仍能再次七击进入"):
		_check(_game.shark_game.best_score >= final_score, "同一个 Shell 再次进入保留本次最佳")
		var next_run := _game.shark_game
		_complete_intro(next_run)
		_key_event(KEY_UP, true)
		_advance_until_over(next_run, 2.0)
		_key_event(KEY_UP, false)
		await _settle()
		_check(next_run.run.state == SharkCaveRun.State.OVER, "再次进入可独立运行并碰撞结束")
		_check(float(next_run.get("_death_elapsed")) < 1.15, "退出操作发生在游走动画尚未结束时")
		await _click(next_run.find_child("SharkExitRunButton", true, false) as Control)
		await _settle(10)
		_check(_game.shark_game == null and _game._about_dialog.is_open(), "终局退出按钮直接返回关于")
		await _unlock_game()
		_key_event(KEY_ESCAPE, true)
		_key_event(KEY_ESCAPE, false)
		await _settle(10)
		_check(_game.shark_game == null and _game._about_dialog.is_open(), "引导中真实 Esc 按下与释放安全退出并恢复关于")
	_check(_snapshot(_temporary) == files_before, "暂停与终局三按钮流程保留身份、主游戏记录与偏好")


## 安全直道先验证远高度不喷墨，再走近距同高度的真实预警和碰撞链路，不写入失败状态。
func _check_ink_run() -> void:
	var files_before := _snapshot(_temporary)
	await _open_settings_and_about()
	await _unlock_game()
	if not _check(_game.shark_game != null, "墨汁碰撞回归通过隐藏入口进入"):
		return
	var mini := _game.shark_game
	_complete_intro(mini)
	mini.run.octopuses.clear()
	mini.run.octopuses.append({"world_x": mini.run.distance + SharkCaveRun.SHARK_X + 40.0, "y": mini.run.shark_y + 70.0, "state": SharkCaveRun.OctopusState.IDLE, "timer": 0.0, "ink_radius": 24.0, "scale": 1.0, "side": 1})
	_advance(mini, 0.30)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.fail_reason.is_empty() and int(mini.run.octopuses[0]["state"]) == SharkCaveRun.OctopusState.IDLE, "横向经过但高度相差较远的章鱼保持待机不喷墨")
	mini.run.octopuses.clear()
	mini.run.octopuses.append({"world_x": mini.run.distance + SharkCaveRun.SHARK_X + 100.0, "y": mini.run.shark_y, "state": SharkCaveRun.OctopusState.IDLE, "timer": 0.0, "ink_radius": 24.0, "scale": 1.0, "side": -1})
	_advance(mini, 0.10)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.fail_reason.is_empty() and int(mini.run.octopuses[0]["state"]) == SharkCaveRun.OctopusState.WARNING, "近距离且同高度的章鱼先预警，不提前造成失败")
	_advance(mini, 0.20)
	var octopus: Dictionary = mini.run.octopuses[0]
	var ink_center := mini.run.ink_center(octopus)
	_check(int(octopus["state"]) == SharkCaveRun.OctopusState.INK and mini.run.state == SharkCaveRun.State.RUNNING, "章鱼按预警时长喷墨，接触墨汁前仍可继续游动")
	_check(ink_center.x - float(octopus["ink_radius"]) > float(octopus["world_x"]) and is_equal_approx(ink_center.y, float(octopus["y"])), "墨圆整体位于章鱼右侧并保持喷射高度，与鲨鱼行进方向一致")
	_check(mini.run.octopuses.size() == 1, "喷墨视觉验收仅放置一只章鱼，避免用密集夹具误示正式密度")
	await _capture("shark_ink_facing_right")
	_advance_until_over(mini, 1.50)
	await _settle()
	_check(mini.run.state == SharkCaveRun.State.OVER and mini.run.fail_reason == "ink", "真实墨汁与鲨鱼相交产生独立墨汁失败原因")
	var status := mini.find_child("SharkRunStatus", true, false) as Label
	_check(status != null and status.is_visible_in_tree() and status.atr(status.text) == mini.tr("墨汁遮挡了视线"), "墨汁失败显示专用提示而不是碰壁提示")
	await _capture("shark_ink_game_over")
	_check(float(mini.get("_death_elapsed")) < 1.15, "墨汁重试操作发生在游走动画尚未结束时")
	await _click(mini.find_child("SharkRetryButton", true, false) as Control)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.fail_reason.is_empty(), "墨汁失败后重新开始清除旧失败原因")
	_check_failure_reset(mini, "游走动画中墨汁重试")
	await _press_escape()
	await _click(mini.find_child("SharkExitRunButton", true, false) as Control)
	await _settle(10)
	_check(_game.shark_game == null and _game._about_dialog.is_open(), "墨汁失败与重开后仍能正常退出到关于")
	_check(_snapshot(_temporary) == files_before, "墨汁碰撞与重开仅更新独立档案统计，不写主游戏或额外存档")


## 直道中的单条逆行鱼通过真实时间推进相撞，暂停、失败过渡和重试均沿用正式界面输入。
func _check_tuna_run() -> void:
	var files_before := _snapshot(_temporary)
	await _open_settings_and_about()
	await _unlock_game()
	if not _check(_game.shark_game != null, "逆行金枪鱼回归通过隐藏入口进入"):
		return
	var mini := _game.shark_game
	_complete_intro(mini)
	_add_tuna_fixture(mini)
	var initial_x := float(mini.run.tunas[0]["world_x"])
	var initial_rect := mini.run.tuna_rect(mini.run.tunas[0])
	_check(initial_rect.size.is_equal_approx(SharkCaveRun.SHARK_HALF_SIZE * (2.0 / 3.0)), "金枪鱼实际碰撞体宽高均为鲨鱼的三分之一")
	_advance(mini, 0.15)
	var fish_x := float(mini.run.tunas[0]["world_x"])
	_check(fish_x < initial_x and mini.run.distance > 0.0 and mini.run.state == SharkCaveRun.State.RUNNING, "金枪鱼向左游动，鲨鱼向右推进，双方尚未接触")
	await _capture("shark_tuna_alive")
	await _press_escape()
	var paused_distance := mini.run.distance
	var paused_time := mini.run.elapsed
	var paused_tuna := mini.run.tunas[0].duplicate(true)
	_advance(mini, 0.50)
	_check(mini.run.state == SharkCaveRun.State.PAUSED and mini.run.distance == paused_distance and mini.run.elapsed == paused_time and mini.run.tunas[0] == paused_tuna, "Esc 暂停同时冻结鲨鱼、金枪鱼和真实模拟时间")
	await _click(mini.find_child("SharkResumeButton", true, false) as Control)
	_advance_until_over(mini, 1.0)
	await _settle()
	_check_tuna_failure(mini, "首次相撞")
	_check_run_actions(mini, false, "金枪鱼失败")
	await _capture("shark_tuna_game_over")
	await _check_failure_transition(mini, "shark_tuna_failure")
	await _click(mini.find_child("SharkRetryButton", true, false) as Control)
	_check(mini.run.state == SharkCaveRun.State.RUNNING and mini.run.fail_reason.is_empty() and is_zero_approx(mini.run.distance) and mini.run.score == 0 and mini.run.tunas.is_empty(), "金枪鱼失败后重新开始清除旧鱼、原因和本局进度")
	_check_failure_reset(mini, "金枪鱼完整模糊后重试")
	await _press_escape()
	await _click(mini.find_child("SharkExitRunButton", true, false) as Control)
	await _settle(10)
	_check(_game.shark_game == null and _game._about_dialog.is_open(), "金枪鱼失败重试后退出恢复关于窗口")
	_check(_snapshot(_temporary) == files_before, "金枪鱼相撞、暂停和重开保留主游戏数据且不产生额外存档")


## 夹具只在安全初始直道放一条真实鱼，不直接赋值碰撞结果、失败原因或计分。
func _add_tuna_fixture(mini: SharkCaveGame) -> void:
	mini.run.octopuses.clear()
	mini.run.tunas.clear()
	mini.run.tunas.append({"world_x": mini.run.distance + SharkCaveRun.SHARK_X + 100.0, "y": 180.0, "lane": 0.0})


## 失败文案来自实际金枪鱼碰撞，三语调用均检查当前显示语言而非固定简体文本。
func _check_tuna_failure(mini: SharkCaveGame, context: String) -> void:
	_check(mini.run.state == SharkCaveRun.State.OVER and mini.run.fail_reason == "tuna", "真实反向游动相撞产生金枪鱼失败原因 " + context)
	var status := mini.find_child("SharkRunStatus", true, false) as Label
	_check(status != null and status.is_visible_in_tree() and status.atr(status.text) == mini.tr("撞到逆行金枪鱼了"), "金枪鱼失败显示当前语言专用提示 " + context)


## 终局只推进独立显示时间：先游走，再显示与主菜单相同的缓存高斯模糊，成绩与世界保持冻结。
func _check_failure_transition(mini: SharkCaveGame, capture_prefix: String = "shark_failure") -> void:
	var canvas := mini.get("_canvas") as SharkCaveCanvas
	var blur := mini.get("_failure_blur") as MainMenuBackground
	var world_image := mini.find_child("SharkWorldImage", true, false) as TextureRect
	var actions := mini.find_child("SharkRunActions", true, false) as Control
	if not _check(canvas != null and blur != null and world_image != null and actions != null, "失败过渡具有独立游走画布和主菜单同款模糊层"):
		return
	var elapsed_before := float(mini.get("_death_elapsed"))
	var run_distance := mini.run.distance
	var run_score := mini.run.score
	var run_elapsed := mini.run.elapsed
	var run_y := mini.run.shark_y
	_check(canvas.departure_active and canvas.departure_progress <= 0.03, "碰撞结束立即从游走动画起点开始")
	_check(blur.modulate.a <= 0.01, "鲨鱼刚开始游走时背景保持清楚")
	await _advance_display_frames(mini, 0.50)
	_check(float(mini.get("_death_elapsed")) > elapsed_before and canvas.departure_progress > 0.0 and canvas.departure_progress < 1.0, "失败显示时间推进并带动鲨鱼逐步游走")
	_check(blur.modulate.a <= 0.01, "1.15秒游走完成前不会提前模糊背景")
	await _capture(capture_prefix + "_departure")
	await _advance_display_frames(mini, 0.70)
	await _settle(8)
	for frame in 24:
		if blur.is_render_ready():
			break
		await process_frame
	_check(blur.is_render_ready(), "先完成背景的实际高斯模糊缓存，再开始淡入")
	await _advance_display_frames(mini, 0.70)
	_check(canvas.departure_progress >= 0.99 and blur.visible and blur.modulate.a >= 0.99, "游走完成后在0.65秒内淡入完整模糊背景")
	_check(mini.run.distance == run_distance and mini.run.score == run_score and mini.run.elapsed == run_elapsed and mini.run.shark_y == run_y, "整个失败过渡冻结真实距离、分数、模拟时间和鲨鱼位置")
	var blur_bounds := blur.get_parent() as Control
	_check(blur_bounds != null and blur.size.x > 0.0 and blur.size.y > 0.0 and blur.size.is_equal_approx(blur_bounds.size) and blur.position.is_equal_approx(Vector2.ZERO), "高斯模糊控件以非零尺寸完整铺满边界容器")
	_check(blur_bounds != null and world_image.get_parent() == blur_bounds.get_parent() and blur_bounds.get_parent() == actions.get_parent() and world_image.get_index() < blur_bounds.get_index() and blur_bounds.get_index() < actions.get_index(), "模糊层位于世界画面之上、文字与操作区域之下")
	_check(mini.material == null and actions.material == null and not blur.is_ancestor_of(actions), "背景模糊不继承到独立成绩文字和按钮")
	await _capture(capture_prefix + "_blurred")


## 无论动画途中还是结束后重试，都清空显示计时、离场状态和上一局的背景模糊。
func _check_failure_reset(mini: SharkCaveGame, context: String) -> void:
	var canvas := mini.get("_canvas") as SharkCaveCanvas
	var blur := mini.get("_failure_blur") as MainMenuBackground
	_check(is_zero_approx(float(mini.get("_death_elapsed"))) and canvas != null and not canvas.departure_active and is_zero_approx(canvas.departure_progress), "重试清空失败计时与游走进度 " + context)
	_check(blur != null and not blur.visible and blur.modulate.a <= 0.01, "重试清除上一次模糊背景 " + context)


## 暂停与终局只用透明自动布局容器，三个按钮横排且保持明确的可用状态。
func _check_run_actions(mini: SharkCaveGame, paused: bool, context: String) -> void:
	_check_control_hint(mini, context)
	var actions := mini.find_child("SharkRunActions", true, false) as VBoxContainer
	var row := mini.find_child("SharkRunButtons", true, false) as HBoxContainer
	var exit_button := mini.find_child("SharkExitRunButton", true, false) as Button
	var resume := mini.find_child("SharkResumeButton", true, false) as Button
	var retry := mini.find_child("SharkRetryButton", true, false) as Button
	if not _check(actions != null and row != null and exit_button != null and resume != null and retry != null, "中央透明三按钮节点完整 " + context):
		return
	_check(actions.visible and row.visible and row.get_child_count() == 3, "暂停或终局只显示一排三个操作按钮 " + context)
	_check(mini.find_child("SharkPausePanel", true, false) == null and mini.find_child("SharkGameOverPanel", true, false) == null, "旧暂停和终局卡片已移除 " + context)
	_check(exit_button.get_parent() == row and resume.get_parent() == row and retry.get_parent() == row and exit_button.get_index() < resume.get_index() and resume.get_index() < retry.get_index(), "按钮从左到右为退出、开始、重新开始 " + context)
	var bounds := root.get_visible_rect().grow(1.0)
	var buttons: Array[Button] = [exit_button, resume, retry]
	var names: Array[String] = ["退出", "开始", "重新开始"]
	for index in buttons.size():
		var button := buttons[index]
		_check(button.is_visible_in_tree() and bounds.encloses(button.get_global_rect()), "运行操作按钮完整位于窗口内 %s %s" % [button.name, context])
		_check(button.text.is_empty() and button.icon != null and button.icon.resource_path.ends_with(".svg"), "中央操作仅显示 SVG 图标，无可见按钮文字 %s %s" % [button.name, context])
		_check(button.size.is_equal_approx(Vector2(56, 56)), "中央图标按钮保持 56×56 正方形点击区 %s %s（实际%s）" % [button.name, context, button.size])
		var style := button.get_theme_stylebox("normal") as StyleBoxFlat
		_check(style != null and style.corner_radius_top_left >= 28 and style.corner_radius_top_right >= 28 and style.corner_radius_bottom_left >= 28 and style.corner_radius_bottom_right >= 28, "中央图标按钮四角合成正圆 %s %s" % [button.name, context])
		_check(button.atr(button.tooltip_text) == mini.tr(names[index]), "图标保留当前语言的悬停名称 %s %s" % [button.name, context])
	_check(exit_button.get_global_rect().end.x <= resume.global_position.x and resume.get_global_rect().end.x <= retry.global_position.x and absf(exit_button.global_position.y - retry.global_position.y) < 1.0, "三个操作按钮横向排列互不重叠 " + context)
	_check(not exit_button.disabled and not retry.disabled and resume.disabled == not paused, "退出与重新开始始终可用，开始只在暂停时可用 " + context)
	var status := mini.find_child("SharkRunStatus", true, false) as Label
	var result := mini.find_child("SharkGameOverScore", true, false) as Label
	_check(status != null and status.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER and row.alignment == BoxContainer.ALIGNMENT_CENTER, "状态标题与三按钮行使用居中排版 " + context)
	if not paused:
		var expected := (mini.tr("本次得分：%d") % mini.run.score) + "\n" + (mini.tr("最高纪录得分：%d") % mini.best_score)
		_check(result != null and result.is_visible_in_tree() and result.text == expected and result.get_theme_font_size("font_size") == 14 and result.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "终局成绩以14号字两行居中显示本次得分和最高纪录 " + context)
	_check(absf(actions.get_global_rect().get_center().x - mini.get_global_rect().get_center().x) <= 1.0 and absf(row.get_global_rect().get_center().x - actions.get_global_rect().get_center().x) <= 1.0, "终局或暂停的全部内容与按钮整体水平居中 " + context)


## 教学留在菜单，运行画面不再保留右上角暂停按钮或重复的底部方向键提示。
func _check_control_hint(mini: SharkCaveGame, context: String) -> void:
	_check(mini.find_child("SharkPauseButton", true, false) == null, "右上角暂停按钮已移除 " + context)
	_check(mini.find_child("SharkControlHint", true, false) == null, "运行画面不保留重复的底部方向键提示 " + context)
	_check(mini.find_child("SharkBestScore", true, false) == null, "右上角不再重复显示最高纪录 " + context)


## 移入圆形图标触发原生计时器，验证共用玻璃层在彩蛋画布上方显示正确名称。
func _check_icon_hover(mini: SharkCaveGame) -> void:
	var button := mini.find_child("SharkRetryButton", true, false) as Button
	var glass := _game.get_node_or_null("GlassTooltips") as GlassTooltipLayer
	if not _check(button != null and glass != null, "圆形图标复用外壳已有玻璃提示层"):
		return
	_motion(Vector2(2, root.get_visible_rect().end.y - 2))
	await _settle()
	_motion(button.get_global_transform_with_canvas() * (button.size * 0.5))
	await create_timer(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) + 0.15).timeout
	await _settle()
	var popup := _native_tooltip(root)
	var label := glass.find_child("GlassTooltipText", true, false) as Label
	_check(popup != null and popup.is_embedded() and glass.visible, "真实悬停生成原生提示并显示共用毛玻璃层")
	_check(label != null and label.is_visible_in_tree() and label.text == mini.tr("重新开始"), "玻璃悬停名称准确显示重新开始")
	var game_layer := mini.get_parent() as CanvasLayer
	_check(game_layer != null and glass.layer > game_layer.layer, "玻璃提示层高于小游戏 CanvasLayer，不被场景遮挡")
	await _capture("shark_icon_restart_hover")
	_motion(Vector2(2, root.get_visible_rect().end.y - 2))
	await _settle()
	_check(_native_tooltip(root) == null and not glass.visible, "移出图标后原生提示和玻璃层一并消失")


## 仅查找引擎实际生成并可见的 TooltipPanel，不手动创建窗口制造通过结果。
func _native_tooltip(node: Node) -> PopupPanel:
	if node is PopupPanel and node.visible and node.theme_type_variation == &"TooltipPanel":
		return node
	for child in node.get_children(true):
		var found := _native_tooltip(child)
		if found != null:
			return found
	return null


## 真实窗口预设和三种语言覆盖自动引导与操作布局，较小窗口也保持完整画幅。
func _check_sizes_and_languages() -> void:
	for dimensions: String in ["1024x640", "1280x800"]:
		_game._about_dialog.close_dialog(false)
		_game.settings.set_window_resolution(dimensions)
		await _settle(12)
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			await _open_settings_and_about()
			await _unlock_game()
			if _game.shark_game == null:
				continue
			var mini := _game.shark_game
			_check(mini.find_child("SharkMenuPanel", true, false) == null and mini.find_child("SharkStartButton", true, false) == null and mini.find_child("SharkExitButton", true, false) == null, "所有语言和尺寸均不保留旧彩蛋菜单 %s %s" % [dimensions, locale])
			_check(mini.get_global_rect().grow(1.0).encloses(root.get_visible_rect()), "自动引导完整铺满窗口 %s %s" % [dimensions, locale])
			await _capture("shark_intro_%s_%s" % [dimensions, locale])
			_complete_intro(mini)
			await _press_escape()
			_check_run_actions(mini, true, "%s %s" % [dimensions, locale])
			await _capture("shark_paused_%s_%s" % [dimensions, locale])
			await _click(mini.find_child("SharkResumeButton", true, false) as Control)
			_add_tuna_fixture(mini)
			_advance_until_over(mini, 1.0)
			await _settle()
			_check_tuna_failure(mini, "%s %s" % [dimensions, locale])
			await _click(mini.find_child("SharkExitRunButton", true, false) as Control)
			await _settle(10)
			_check(_game._about_dialog.is_open(), "不同窗口和语言退出都返回关于 %s %s" % [dimensions, locale])
	_game._about_dialog.close_dialog(false)
	_game.settings.set_language("zh_CN")


## 固定小步调用实际画面的帧驱动，保留真实输入状态而不受运行机器帧率影响。
func _advance(mini: SharkCaveGame, seconds: float) -> void:
	for tick in int(ceil(seconds * 60.0)):
		mini._process(1.0 / 60.0)


## 第一次真实碰撞立即停止手动推进，以便单独观察失败显示过渡的起点与过程。
func _advance_until_over(mini: SharkCaveGame, seconds: float) -> void:
	for tick in int(ceil(seconds * 60.0)):
		if mini.run.state != SharkCaveRun.State.RUNNING:
			break
		mini._process(1.0 / 60.0)


## 显示过渡逐帧呈现，让无鱼画面和离屏模糊获得真实渲染帧，不用同步快进跳过缓存准备。
func _advance_display_frames(mini: SharkCaveGame, seconds: float) -> void:
	for tick in int(ceil(seconds * 60.0)):
		mini._process(1.0 / 60.0)
		await process_frame


## 全部坐标使用当前 Canvas 变换，不反算屏幕缩放，兼容 CanvasLayer 与较小物理窗口。
func _mouse(control: Control, button: MouseButton, pressed: bool, double_click: bool = false) -> void:
	if not _check(is_instance_valid(control), "鼠标输入目标存在"):
		return
	var point := control.get_global_transform_with_canvas() * (control.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.double_click = double_click
	root.push_input(event, true)


## 真实点击包含按下和松开，提交后等待控件与延迟进入逻辑稳定。
func _click(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_mouse(control, button, true)
	_mouse(control, button, false)
	await _settle()


## 方向键由正常输入路径进入游戏，不直接修改模拟中的输入、位置或碰撞结果。
func _key_event(keycode: Key, pressed: bool, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	event.echo = echo
	root.push_input(event, true)


## 暂停只能通过完整 Esc 按下与抬起进入，不直接调用游戏暂停方法。
func _press_escape() -> void:
	_key_event(KEY_ESCAPE, true)
	_key_event(KEY_ESCAPE, false)
	await _settle()


## 独立鼠标移动经过视口输入以使用真实 GUI 悬停检测和原生提示计时。
func _motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


## 只在真实主菜单设置入口等待有限时长，动画完成后再验证页面和可操作面板。
func _wait_settings_transition() -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		await process_frame
	await _settle()
	return _check(not _game._menu_transitioning and _game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "真实设置转场按时完成并进入可操作设置面板")


## 帧等待只用于原生布局与延迟队列，不承担游戏距离推进或入口超时。
func _settle(frames: int = 4) -> void:
	for frame in frames:
		await process_frame


## 截取真实 GPU 帧作为菜单、游玩和失败状态的视觉验收材料。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(screenshot.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存 GPU 截图 " + filename)


## 快照仅排除已授权新增的档案活动秒数、彩蛋最高分及触发标记，其余字段继续完整保护。
func _snapshot(path: String) -> Dictionary:
	var result := {}
	var directory := DirAccess.open(path)
	if directory == null:
		return result
	for filename in directory.get_files():
		var file_path := path.path_join(filename)
		var bytes := FileAccess.get_file_as_bytes(file_path)
		if is_instance_valid(_game) and file_path == _game.profile.storage_path:
			var data: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
			data.statistics.erase("play_seconds")
			data.statistics.erase("shark_best_score")
			data.statistics.erase("shark_discovered")
			result[filename] = data
		else:
			result[filename] = bytes
	for child in directory.get_directories():
		result[child + "/"] = _snapshot(path.path_join(child))
	return result


## 外壳释放后才重建下一会话，避免窗口策略或隐藏输入节点重叠。
func _dispose_game() -> void:
	if is_instance_valid(_game):
		_game.queue_free()
	await _settle(10)
	_game = null


## 明确超时报错并清理测试文件，避免错误协程在 CI 中无限等待。
func _timeout() -> void:
	if _finished:
		return
	_check(false, "彩蛋集成回归超过 150 秒")
	_finish()


## 还原进程全局音量和语言，删除独占文件，退出码与累计失败数一致。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	TranslationServer.set_locale(_original_locale)
	OS.low_processor_usage_mode = _original_low_processor_mode
	Engine.max_fps = _original_max_fps
	_remove_tree(_temporary)
	print("鲨鱼彩蛋集成回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 检查失败持续收集，便于一次运行定位入口、模拟、布局和状态恢复问题。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 递归清理仅接受本次创建的测试目录，不触碰真实用户文件。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
