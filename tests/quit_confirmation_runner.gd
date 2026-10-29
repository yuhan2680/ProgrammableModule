extends "res://tests/editor_exit_dialog_runner.gd"
## 退出询问仅替换系统窗口与进程退出；真实存档、活动统计、地图保存和会话仍走生产路径。

class ObservedShell extends GameShell:
	var draft_flushes := 0
	var activity_flushes := 0

	## 记录提交次数，并继续真实草稿保存以覆盖写盘失败保护。
	func _save_current_draft(force: bool = false) -> bool:
		draft_flushes += 1
		return super._save_current_draft(force)

	## 只统计含未保存时间的有效刷新，避免将无数据的幂等调用误当重复写盘。
	func _flush_activity_statistics() -> void:
		if _activity_tracker != null and _activity_tracker.get_pending_seconds() > 0.0:
			activity_flushes += 1
		super._flush_activity_statistics()

	## 固定最小化状态，让宿主自动化焦点不影响活动统计边界。
	func _is_activity_window_minimized() -> bool:
		return false

var _quit_requests: Array[Dictionary] = []
var _map_requests: Array[Dictionary] = []
var _native_result := OK
var _immediate_choice := -999
var _quit_count := 0
var _clock := [1000.0]
var _fixture_index := 0


## 退出每个分支都使用独立外壳，测试不会继续操作一个已经提交退出的游戏。
func _run() -> void:
	_temporary = "user://tests/quit_confirmation_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var original_volume := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _test_clean_pages_and_results()
	await _test_native_fallback()
	await _test_confirm_once()
	await _test_running_cancel()
	await _test_draft_failure()
	await _test_dirty_editor()
	await _test_startup_close()
	await _test_startup_handoff()
	await _dispose_game()
	AudioServer.set_bus_volume_db(master, original_volume)
	AudioServer.set_bus_mute(master, original_mute)
	TranslationServer.set_locale(original_locale)
	_cleanup(_temporary)
	print("退出原生确认回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 注入独占目录、可控时钟与两个独立系统窗口替身，不访问正式玩家路径。
func _new_game() -> void:
	await _dispose_game()
	_fixture_index += 1
	_quit_count = 0
	_quit_requests.clear()
	_map_requests.clear()
	_native_result = OK
	_immediate_choice = -999
	_clock[0] = 1000.0
	var folder := _temporary.path_join(str(_fixture_index))
	_game = ObservedShell.new()
	_game.settings_path = folder.path_join("settings.json")
	_game.profile_path = folder.path_join("profile.json")
	_game.user_levels_directory = folder.path_join("levels")
	_game.drafts_directory = folder.path_join("drafts")
	_game.profile_clock = func() -> float: return _clock[0]
	_game.quit_native_dialog_handler = _record_quit_dialog
	_game.quit_handler = _record_quit
	root.add_child(_game)
	await _settle()
	_game._editor_discard_dialog.native_dialog_handler = _record_map_dialog
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_RESUMED)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_game.set_process(false)


## 菜单、设置、关卡与干净地图均先确认；取消、关闭、非法索引及旧响应不能提交退出。
func _test_clean_pages_and_results() -> void:
	await _new_game()
	for locale: String in ["zh_CN", "zh_HK", "es", "en", "ja"]:
		_game.settings.set_language(locale)
		await _settle()
		var leave := _game.find_child("LeaveGameButton", true, false) as Control
		_click(leave.get_global_transform_with_canvas() * (leave.size * 0.5))
		_check(_quit_count == 0 and _game._quit_dialog.is_open() and paused, "真实菜单退出先打开系统询问并冻结底页 " + locale)
		var request: Dictionary = _quit_requests.back()
		_check(request.buttons == PackedStringArray([_game.tr("取消"), _game.tr("退出")]) and not request.title.is_empty() and not request.description.is_empty(), "系统询问提供本土化文案与取消优先按钮 " + locale)
		await _reply(0)
		_check(not _game._quit_dialog.is_open() and not paused and _quit_count == 0, "菜单取消恢复操作且不退出 " + locale)
	for page_name: String in ["settings", "levels", "editor"]:
		if page_name == "settings":
			_game._show_settings_page()
		elif page_name == "levels":
			_game._show_level_page()
		else:
			_game._open_editor()
		await _settle()
		var page_before := _game.page
		for choice in [0, -1, 99]:
			var draft_count: int = _game.draft_flushes
			_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
			_check(_game._quit_dialog.is_open() and _quit_count == 0, "系统关闭及macOS统一关闭通知先询问 " + page_name)
			var count := _quit_requests.size()
			_game._request_quit()
			_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
			_check(_quit_requests.size() == count, "重复关闭请求只保留同一询问 " + page_name)
			var old: Callable = _quit_requests.back().callback
			await _reply(choice)
			old.call(1)
			await _settle()
			_check(_quit_count == 0 and not _game._closing and _game.page == page_before and not paused and _game.draft_flushes == draft_count, "取消、关闭或非法索引保留页面，迟到确认失效 " + page_name)
	_game._request_quit()
	var obsolete: Callable = _quit_requests.back().callback
	await _reply(0)
	_game._request_quit()
	obsolete.call(1)
	await _settle()
	_check(_game._quit_dialog.is_open() and _quit_count == 0, "上一代确认不能替当前新询问作答")
	await _reply(0)
	paused = true
	_game._request_quit()
	await _reply(0)
	_check(paused and _quit_count == 0, "取消保留请求前已暂停的场景树状态")
	paused = false


## 原生接口失败后只由后备询问决定，失败调用的迟到确认不得绕过后备取消。
func _test_native_fallback() -> void:
	await _new_game()
	_native_result = ERR_UNAVAILABLE
	_game._request_quit()
	await _settle()
	var dialog := _game._quit_dialog
	_check(dialog.is_open() and not dialog._native_active and dialog._fallback.visible and _quit_count == 0, "原生失败显示引擎后备确认，不直接退出")
	_quit_requests.back().callback.call(1)
	await _settle()
	_check(dialog.is_open() and _quit_count == 0, "失败原生调用的迟到响应不穿透后备窗口")
	dialog._fallback.canceled.emit()
	await _settle()
	_check(not dialog.is_open() and not paused and _quit_count == 0, "后备取消解除模态并保留游戏")


## 明确确认才保存一次草稿和最后活动段；重复确认与重复窗口关闭均不重放退出。
func _test_confirm_once() -> void:
	await _new_game()
	_game._show_level_page()
	await _settle()
	_game._sync_activity_timer()
	_clock[0] += 7.25
	_game.draft_flushes = 0
	_game.activity_flushes = 0
	var original_seconds: float = _game.profile.get_statistics().play_seconds
	_immediate_choice = 1
	_game._request_quit()
	_check(_quit_count == 0 and _game._quit_dialog.is_open(), "同步系统确认延后提交，不在原生调用栈退出")
	await _settle()
	_check(_quit_count == 1 and _game._closing and _game.draft_flushes == 1 and _game.activity_flushes == 1, "明确退出仅提交一次草稿及有效活动刷新")
	_check(is_equal_approx(_game.profile.get_statistics().play_seconds, original_seconds + 7.25), "最后活动时间真实写入独占玩家档案且不重复累计")
	_quit_requests.back().callback.call(1)
	_game._request_quit()
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _settle()
	_check(_quit_count == 1 and _game.draft_flushes == 1 and _game.activity_flushes == 1, "重复确认和关闭通知不重复写盘或退出")


## 真实程序运行中取消退出，程序、模拟时钟、世界与原暂停状态均保持。
func _test_running_cancel() -> void:
	await _new_game()
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "真实会话装入合法移动模块")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	_game.session.source = "main(){move(0,4)}"
	_game.session.run()
	for originally_paused in [false, true]:
		if originally_paused:
			_game.session.pause()
		var session_before := _game.session
		var state_before := _game.session.state
		var world_before := _game.session.world
		var position_before := _game.session.world.player.position
		var source_before := _game.session.source
		_game.workbench.set_process(true)
		_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
		await create_timer(0.20).timeout
		_check(paused and _game.session == session_before and _game.session.state == state_before and _game.session.world.player.position == position_before, "询问冻结实际工作台推进，不停止或重建模拟")
		_game.workbench.set_process(false)
		await _reply(0)
		_check(not paused and _quit_count == 0 and _game.page == GameShell.Page.PLAY and _game.session == session_before and _game.session.state == state_before and _game.session.world == world_before and _game.session.world.player.position == position_before and _game.session.source == source_before, "取消保持运行或暂停状态、代码与同一模拟世界")


## 明确退出也必须遵守草稿保存失败保护，修复后可以重新询问再退出。
func _test_draft_failure() -> void:
	_game.session.stop()
	var blocked := _temporary.path_join("blocked_drafts")
	var file := FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("preserved")
	file.close()
	var original_directory := _game.drafts.directory
	_game.drafts.directory = blocked.path_join("drafts")
	_game._draft_edited = true
	_game._request_quit()
	await _reply(1)
	_check(_quit_count == 0 and not _game._closing and not paused and _game._message_dialog.visible and _game.session != null, "退出草稿写盘失败保留游戏并显示原错误")
	_check(FileAccess.get_file_as_string(blocked) == "preserved", "退出失败不覆盖阻挡文件")
	_game._message_dialog.hide()
	_game.drafts.directory = original_directory
	_game._request_quit()
	await _reply(1)
	_check(_quit_count == 1 and _game.drafts.load_draft(_game.session.level.id).is_ok(), "修复后重新明确确认可以保存并退出")


## 未保存地图仍使用三选项保护，取消或失败不能退出，成功保存和不保存分别提交一次。
func _test_dirty_editor() -> void:
	await _new_game()
	await _fixture()
	var model := _editor.editor_document
	var before := _signature(model)
	var history := model._undo_stack.size()
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_map_requests.size() == 1 and _quit_requests.is_empty() and _game._editor_discard_dialog.visible, "dirty地图只使用保存、不保存、取消询问")
	await _map_reply(2)
	_check(_quit_count == 0 and _signature(model) == before and model._undo_stack.size() == history and model.is_dirty() and not paused, "取消关闭保留同一地图全部内容与历史")
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var blocked := _temporary.path_join("blocked_maps")
	var file := FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("retain")
	file.close()
	_editor.player_levels_directory = blocked.path_join("levels")
	await _map_reply(0)
	_check(_quit_count == 0 and not _game._editor_exit_save_pending and not _game._editor_exit_quit_requested and model.is_dirty() and _signature(model) == before, "dirty地图保存失败清除退出意图且保留文档")
	_editor._message_dialog.hide()
	_editor.player_levels_directory = _game.user_levels_directory
	_editor._save_document(false)
	await _settle()
	_check(_quit_count == 0 and not model.is_dirty() and FileAccess.file_exists(model.path), "失败后普通保存成功不意外退出")
	model.paint(Vector2i(11, 9), "floor")
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _map_reply(0)
	_check(_quit_count == 1 and not model.is_dirty() and _quit_requests.is_empty(), "dirty选择保存成功后直接退出一次，无重复确认")
	await _new_game()
	await _fixture(_temporary.path_join("discard_original.json"))
	model = _editor.editor_document
	var bytes := FileAccess.get_file_as_bytes(model.path)
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _map_reply(1)
	_check(_quit_count == 1 and FileAccess.get_file_as_bytes(model.path) == bytes and model.is_dirty(), "dirty选择不保存退出一次且外部原件逐字不变")


## 启动进度页在完整游戏尚未接管时也必须询问，不能直接关闭测试宿主。
func _test_startup_close() -> void:
	await _dispose_game()
	_quit_count = 0
	_quit_requests.clear()
	_native_result = OK
	_immediate_choice = -999
	var boot := load("res://scripts/ui/startup_loader.gd").new() as Node
	boot.set("settings_path", _temporary.path_join("startup/settings.json"))
	boot.set("user_levels_directory", _temporary.path_join("startup/levels"))
	boot.set("drafts_directory", _temporary.path_join("startup/drafts"))
	boot.set("scene_path", "res://scenes/missing_quit_confirmation_fixture.tscn")
	boot.set("quit_native_dialog_handler", _record_quit_dialog)
	boot.set("quit_handler", _record_quit)
	# 模拟全新进程默认值，不能借用此前GameShell留下的关闭保护。
	auto_accept_quit = true
	root.add_child(boot)
	_check(not auto_accept_quit, "冷启动入口主动关闭引擎自动退出，不依赖先前游戏状态")
	boot.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_quit_count == 0 and _quit_requests.size() == 1, "首帧启动页系统关闭先询问而非直接退出")
	boot.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_quit_requests.size() == 1, "启动期间重复关闭不会打开第二个询问")
	await _reply(0)
	_check(_quit_count == 0 and is_instance_valid(boot), "启动取消保留启动控制器")
	boot.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _reply(1)
	_check(_quit_count == 1, "启动页只有明确确认才提交退出")
	_quit_requests.back().callback.call(1)
	await _settle()
	_check(_quit_count == 1, "启动确认迟到重复响应不再次退出")
	boot.queue_free()
	await _settle()
	paused = false


## 完整游戏已建立但启动尚未交接时只询问一次，取消后继续同一加载并把关闭权交给外壳。
func _test_startup_handoff() -> void:
	_quit_count = 0
	_quit_requests.clear()
	var boot := load("res://scripts/ui/startup_loader.gd").new() as Node
	boot.set("settings_path", _temporary.path_join("handoff/settings.json"))
	boot.set("user_levels_directory", _temporary.path_join("handoff/levels"))
	boot.set("drafts_directory", _temporary.path_join("handoff/drafts"))
	boot.set("quit_native_dialog_handler", _record_quit_dialog)
	boot.set("quit_handler", _record_quit)
	var completed: Array[Node] = []
	boot.connect("completed", func(game: Node) -> void: completed.append(game))
	boot.connect("phase_changed", func(value: String) -> void:
		if value == "initializing":
			boot.call("_request_quit")
	)
	root.add_child(boot)
	var deadline := Time.get_ticks_msec() + 10000
	while _quit_requests.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_quit_requests.size() == 1, "真实启动初始化阶段发起一次退出询问")
	if _quit_requests.is_empty():
		boot.queue_free()
		await _settle()
		return
	await _settle()
	var game := boot.get("_game") as GameShell
	_check(completed.is_empty() and paused and game != null and game.quit_requests_managed_by_startup, "询问期间不提前交接且完整游戏仍由启动页管理关闭")
	if game != null:
		game.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	boot.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_quit_requests.size() == 1 and _quit_count == 0, "同一窗口通知送到启动与完整游戏时不叠加询问")
	await _reply(0)
	deadline = Time.get_ticks_msec() + 10000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(completed.size() == 1 and completed[0] == game and not game.quit_requests_managed_by_startup and not paused, "取消继续原启动并只交接同一完整游戏一次")
	if is_instance_valid(game):
		game.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
		_check(_quit_requests.size() == 2 and game._quit_dialog.is_open() and _quit_count == 0, "交接后系统关闭由完整游戏独立确认")
		await _reply(0)
		game.queue_free()
	if is_instance_valid(boot):
		boot.queue_free()
	await _settle()
	paused = false


## 系统确认替身记录参数，同步响应和调用失败均由测试显式控制。
func _record_quit_dialog(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_quit_requests.append({"title": title, "description": description, "buttons": buttons, "callback": callback})
	if _immediate_choice != -999:
		callback.call(_immediate_choice)
	return _native_result


## 地图保存询问独立记录，防止把三选项索引误当通用退出确认。
func _record_map_dialog(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_map_requests.append({"title": title, "description": description, "buttons": buttons, "callback": callback})
	return OK


## 只记录进程退出请求，不终止回归宿主。
func _record_quit() -> void:
	_quit_count += 1


## 回复通用系统询问并等待延后分派。
func _reply(choice: int) -> void:
	_quit_requests.back().callback.call(choice)
	await _settle()


## 回复地图系统询问，真实托管保存仍由编辑器完成。
func _map_reply(choice: int) -> void:
	_map_requests.back().callback.call(choice)
	await _settle()


## 清理外壳前显式恢复测试场景树，避免一次失败污染后续独立夹具。
func _dispose_game() -> void:
	paused = false
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_game = null
