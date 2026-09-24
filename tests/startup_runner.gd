extends SceneTree
## 启动回归不静态引用任何游戏类，避免在白色进度页之前提前载入完整游戏。

const STARTUP_SCENE := "res://scenes/startup.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const CUSTOM_ID := "0123456789abcdef0123456789abcdef"
var _checks := 0
var _failures := 0
var _finished := false
var _temporary := ""
var _boot: Node
var _game: Node
var _values: Array[Dictionary] = []
var _phases: Array[String] = []
var _completed_count := 0
var _failed_count := 0
var _failure_message := ""
var _hidden_clicks := 0
var _blocked_background := false
var _blocked_menu := false
var _background_snapshot: Dictionary = {}
var _original_locale := ""
var _original_volume := 0.0
var _original_mute := false


## 等根场景就绪后才动态载入轻量启动场景。
func _initialize() -> void:
	_run.call_deferred()


## 用独立配置覆盖三种背景、失败重试与启动中断，并汇总生命周期断言。
func _run() -> void:
	_temporary = "user://tests/startup_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	create_timer(55.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_check(ProjectSettings.get_setting("application/run/main_scene") == STARTUP_SCENE, "项目入口使用轻量启动场景")
	for mode in ["default", "solid", "custom"]:
		await _test_success(mode)
	await _test_failure_retry("res://scenes/missing_startup_test.tscn", "缺失资源")
	await _test_failure_retry("res://assets/ui/workshop.svg", "重复预热资源且非场景")
	await _test_interrupted()
	_finish()


## 每轮只改变隔离设置的背景模式，完成之前不能暴露可点击菜单。
func _test_success(mode: String) -> void:
	var folder := _temporary.path_join(mode)
	_write_settings(folder, mode)
	_start_boot(folder)
	var bar := _boot.find_child("StartupProgress", true, false) as ProgressBar
	_check(bar != null and not bar.show_percentage and is_equal_approx(bar.size.x, 240.0) and is_equal_approx(bar.size.y, 4.0), "启动条为无百分比的240×4细条 " + mode)
	if bar != null:
		var fill := bar.get_theme_stylebox("fill") as StyleBoxFlat
		_check(fill != null and fill.bg_color.r < 0.1 and fill.corner_radius_top_left == 2 and fill.corner_radius_bottom_right == 2, "启动条使用黑色圆头 " + mode)
	_check(_boot.get("phase") == "waiting" and is_zero_approx(float(_boot.get("progress"))), "添加启动页时先停在零进度首帧 " + mode)
	if not await _wait_for_completion():
		await _dispose()
		return
	_validate_success(mode)
	_check(_game.get("settings").get("menu_background_mode") == mode, "初始化载入所选背景模式 " + mode)
	var background: Node = _game.get("_main_background")
	_check(background.call("is_render_ready"), "完成时背景已可呈现 " + mode)
	if mode == "solid":
		_check(not background.get("visible") and background.get("_source_texture") == null, "纯色无需等待模糊缓存")
	elif mode == "custom":
		_check(String(background.get("_selected_path")).ends_with(CUSTOM_ID + ".png"), "自定义图使用隔离目录中的托管副本")
	else:
		_check(background.get("_selected_path") == "res://assets/backgrounds/main_menu.png", "默认图使用随项目打包的图片")
	_check_completed_click()
	await _dispose()


## 无法载入的资源保留错误反馈，点击重试后只生成一个正常菜单。
func _test_failure_retry(path: String, context: String) -> void:
	var folder := _temporary.path_join("retry_" + str(_checks))
	_write_settings(folder, "solid")
	_start_boot(folder, path)
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(_boot) and _boot.get("phase") != "failed" and Time.get_ticks_msec() < deadline:
		await process_frame
	var failed_ready: bool = is_instance_valid(_boot) and _boot.get("phase") == "failed"
	_check(failed_ready, "无效启动资源进入失败状态 " + context)
	if not failed_ready:
		await _dispose()
		return
	_check(_failed_count == 1 and not _failure_message.is_empty(), "失败发出一次可读错误反馈 " + context)
	_check(_completed_count == 0 and float(_boot.get("progress")) < 1.0 and _count_games() == 0, "失败不冒充加载完成且没有残留游戏 " + context)
	var retry := _boot.find_child("StartupRetry", true, false) as Button
	_check(retry != null and retry.is_visible_in_tree() and not retry.disabled, "失败窗口提供可用重试按钮 " + context)
	_check(_boot.get("_screen").modulate.a == 1.0, "失败保留白色反馈层 " + context)
	_boot.set("scene_path", GAME_SCENE)
	_reset_observations()
	if retry != null:
		_click(retry)
	else:
		_boot.call("_retry")
	if await _wait_for_completion():
		_validate_success("重试 " + context)
		_check(_failed_count == 0, "恢复有效资源后不再次报错 " + context)
		_check_completed_click()
	await _dispose()


## 初始化中途撤去启动页时不能遗留尚未交接的游戏或菜单动画。
func _test_interrupted() -> void:
	var folder := _temporary.path_join("interrupted")
	_write_settings(folder, "default")
	_start_boot(folder)
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(_boot) and _boot.get("phase") != "initializing" and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(is_instance_valid(_boot) and _boot.get("phase") == "initializing", "可以观察分阶段初始化")
	if is_instance_valid(_boot):
		_boot.queue_free()
	await process_frame
	await process_frame
	_check(_count_games() == 0 and _completed_count == 0, "中断启动释放未交接游戏且不发完成通知")
	_boot = null
	_game = null


## 动态载入启动页，所有潜在写入路径在入树之前指向本次测试目录。
func _start_boot(folder: String, target: String = GAME_SCENE) -> void:
	_reset_observations()
	_boot = load(STARTUP_SCENE).instantiate()
	_boot.set("scene_path", target)
	_boot.set("settings_path", folder.path_join("settings.json"))
	_boot.set("user_levels_directory", folder.path_join("levels"))
	_boot.set("drafts_directory", folder.path_join("drafts"))
	_boot.connect("progress_changed", _record_progress)
	_boot.connect("phase_changed", _record_phase)
	_boot.connect("completed", _record_completed)
	_boot.connect("failed", _record_failed)
	root.add_child(_boot)


## 等待真实生命周期信号，同时在背景和窗口过渡中检查输入保护。
func _wait_for_completion() -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while _completed_count == 0 and _failed_count == 0 and Time.get_ticks_msec() < deadline:
		if is_instance_valid(_boot):
			var current_phase: String = _boot.get("phase")
			if current_phase == "background" and not _blocked_background:
				_blocked_background = true
				_check_input_blocked("背景淡入时")
			elif current_phase == "menu" and not _blocked_menu:
				_blocked_menu = true
				_check_input_blocked("菜单弹出过程中")
		await process_frame
	var success := _completed_count == 1 and is_instance_valid(_game)
	_check(success, "启动在有界时间内完成而非停留白屏")
	await process_frame
	return success


## 统一验证进度因实际阶段单调前进，并按背景先行、菜单随后顺序完成。
func _validate_success(context: String) -> void:
	var monotonic := true
	var previous := 0.0
	var full_ready := true
	var initial_steps: Dictionary = {}
	for record in _values:
		var value: float = record["value"]
		monotonic = monotonic and value >= previous and value >= 0.0 and value <= 1.0
		previous = value
		if value >= 1.0:
			full_ready = full_ready and record["presentable"] and not record["card_visible"]
		if record["phase"] == "initializing":
			initial_steps[value] = true
	_check(monotonic and not _values.is_empty() and is_equal_approx(previous, 1.0), "进度单调有界且最后达到100% " + context)
	_check(full_ready, "100%时后台已可呈现而菜单仍隐藏 " + context)
	_check(initial_steps.size() >= 3, "资源完成后仍有真实初始化阶段反馈 " + context)
	var expected: Array[String] = ["resources", "initializing", "rendering", "background", "menu", "complete"]
	var ordered: Array[String] = []
	for observed in _phases:
		if observed != "waiting":
			ordered.append(observed)
	_check(ordered == expected, "启动阶段顺序保持资源→初始化→背景→菜单 " + context)
	_check(_background_snapshot.get("presentable", false) and not _background_snapshot.get("card_visible", true), "背景过渡开始时图片已好且窗口未显示 " + context)
	_check(_blocked_background and _blocked_menu and _hidden_clicks == 0, "两段过渡均保护菜单输入 " + context)
	_check(_count_games() == 1 and current_scene == _game and not is_instance_valid(_boot), "交接后只有一个游戏且启动层已释放 " + context)
	var card := _game.find_child("MainMenuCard", true, false) as Control
	_check(card != null and card.visible and is_equal_approx(card.modulate.a, 1.0) and card.scale.is_equal_approx(Vector2.ONE), "完成后卡片恢复完整可见尺寸 " + context)
	for name in ["StartGameButton", "MapEditorButton", "SettingsButton", "LeaveGameButton"]:
		var button := _game.find_child(name, true, false) as Button
		_check(button != null and button.is_visible_in_tree() and not button.disabled and button.focus_mode == Control.FOCUS_ALL, "交接后入口恢复可交互 " + name + " " + context)


## 交接完成后点击开始游戏，验证输入恢复而不是只改变按钮外观。
func _check_completed_click() -> void:
	var start := _game.find_child("StartGameButton", true, false) as Button
	if start != null:
		_click(start)
		_check(_game.find_child("MainMenuCard", true, false) == null, "完成后开始游戏的鼠标点击可离开菜单")


## 隐藏和过渡中的按钮保持禁用并屏蔽焦点，真实输入不能绕过覆盖层。
func _check_input_blocked(context: String) -> void:
	var game: Node = _boot.get("_game")
	_check(is_instance_valid(game), context + "游戏已建立")
	if not is_instance_valid(game):
		return
	var protected := true
	for name in ["StartGameButton", "MapEditorButton", "SettingsButton", "LeaveGameButton"]:
		var button := game.find_child(name, true, false) as Button
		protected = protected and button != null and button.disabled and button.focus_mode == Control.FOCUS_NONE
		if button != null and not button.pressed.is_connected(_record_hidden_click):
			button.pressed.connect(_record_hidden_click)
	_check(protected, context + "四入口禁用且不能获取键盘焦点")
	var start := game.find_child("StartGameButton", true, false) as Button
	if start != null:
		_click(start)
	for keycode in [KEY_TAB, KEY_ENTER, KEY_SPACE]:
		for down in [true, false]:
			var event := InputEventKey.new()
			event.keycode = keycode
			event.pressed = down
			root.push_input(event)
	_check(game.find_child("MainMenuCard", true, false) != null and _hidden_clicks == 0, context + "鼠标与键盘不能触发隐藏入口")


## 以动态属性读取记录100%时的实际可呈现状态，避免提前引用重型游戏脚本。
func _record_progress(value: float) -> void:
	var game: Node = _boot.get("_game")
	var card: Control = game.find_child("MainMenuCard", true, false) if is_instance_valid(game) else null
	_values.append({"value": value, "phase": _boot.get("phase"), "presentable": is_instance_valid(game) and game.call("is_startup_presentable"), "card_visible": card != null and card.visible})


## 记录阶段和背景过渡起点的窗口可见性。
func _record_phase(value: String) -> void:
	_phases.append(value)
	if value == "background":
		var game: Node = _boot.get("_game")
		var card: Control = game.find_child("MainMenuCard", true, false) if is_instance_valid(game) else null
		_background_snapshot = {"presentable": is_instance_valid(game) and game.call("is_startup_presentable"), "card_visible": card != null and card.visible}


## 成功信号持有交接后的游戏引用，启动层随后可以正常释放。
func _record_completed(game: Node) -> void:
	_completed_count += 1
	_game = game


## 失败信号只记录可读文案，不忽略或关闭错误窗口。
func _record_failed(message: String) -> void:
	_failed_count += 1
	_failure_message = message


## 记录隐藏入口被意外触发的次数。
func _record_hidden_click() -> void:
	_hidden_clicks += 1


## 每次重试重新观察一个独立进度周期。
func _reset_observations() -> void:
	_values.clear()
	_phases.clear()
	_completed_count = 0
	_failed_count = 0
	_failure_message = ""
	_hidden_clicks = 0
	_blocked_background = false
	_blocked_menu = false
	_background_snapshot.clear()


## 发出一对真实鼠标事件，不通过直接发射pressed信号绕开禁用状态。
func _click(control: Control) -> void:
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = control.get_global_rect().get_center()
		event.global_position = event.position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event)


## 仅用原始JSON和PNG准备独立配置，防止fixture预加载游戏类。
func _write_settings(folder: String, mode: String) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var backgrounds: Array = []
	if mode == "custom":
		DirAccess.make_dir_recursive_absolute(folder.path_join("backgrounds"))
		var image := Image.create(96, 64, false, Image.FORMAT_RGB8)
		image.fill(Color("6c398d"))
		image.fill_rect(Rect2i(32, 8, 40, 40), Color("ddc0f0"))
		image.save_png(folder.path_join("backgrounds/" + CUSTOM_ID + ".png"))
		backgrounds.append({"id": CUSTOM_ID, "name": "独立启动测试背景"})
	var data := {"format_version": 1, "audio": {"master_volume": 1.0}, "interface": {"language": "zh_CN", "menu_background_mode": mode, "menu_background_id": CUSTOM_ID if mode == "custom" else "", "custom_backgrounds": backgrounds}}
	var file := FileAccess.open(folder.path_join("settings.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


## 统计游戏实例而不引用其类名，失败和重试不能留下第二个Shell。
func _count_games() -> int:
	var count := 0
	for node in root.get_children():
		if node.has_method("is_startup_presentable"):
			count += 1
	return count


## 清理本轮启动层和游戏，确保后续背景与重试互不影响。
func _dispose() -> void:
	if is_instance_valid(_boot):
		_boot.queue_free()
	if is_instance_valid(_game):
		if current_scene == _game:
			current_scene = null
		_game.queue_free()
	await process_frame
	await process_frame
	_boot = null
	_game = null


## 保存结果并恢复当前进程的语言与音量，不删除其他测试或玩家目录。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	TranslationServer.set_locale(_original_locale)
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	_remove_tree(_temporary)
	print("启动加载回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 输出断言结果并累计失败，不因首个失败而遗漏剩余阶段。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print(("PASS " if condition else "FAIL ") + message)


## 超时也给出明确失败标记，避免未完成的进程被视为测试通过。
func _timeout() -> void:
	_check(false, "启动回归超时")
	await _dispose()
	_finish()


## 仅递归清理当前启动回归的独占目录。
func _remove_tree(path: String) -> void:
	assert(path.begins_with("user://tests/startup_"))
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
