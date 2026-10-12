extends SceneTree
## 全应用活动时间和鲨鱼最高分端到端回归，只访问本次独占玩家档案。

class ActivityShell extends GameShell:
	var minimized_for_test := false

	## 仅替换平台最小化状态，计时和页面生命周期仍使用正式外壳实现。
	func _is_activity_window_minimized() -> bool:
		return minimized_for_test

var _checks := 0
var _failures := 0
var _finished := false
var _temporary := ""
var _clock := [1000.0]
var _game: ActivityShell
var _native_callbacks: Array[Callable] = []
var _expected_seconds := 0.0


## 延后构造外壳，固定注入墙钟避免真实帧等待影响计时断言。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 页面、生命周期、重置和最高分使用同一持久档案验证，窗口交互不会读写真实用户资料。
func _run() -> void:
	create_timer(60.0).timeout.connect(_timeout)
	_temporary = "user://tests/player_activity_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_test_tracker_boundaries()
	await _create_game()
	await _test_excluded_pages()
	await _test_foreground_boundaries()
	await _test_periodic_save_and_retry()
	await _test_editor_and_challenge()
	await _test_shark_activity_and_scores()
	await _test_restart_and_reset()
	await _finish()


## 纯计时器验证浮点小量、保存期间增量、异常和倒退时钟，不依赖窗口或真实等待。
func _test_tracker_boundaries() -> void:
	var clock_value: Array = [10.0]
	var tracker := PlayerActivityTracker.new(func() -> Variant: return clock_value[0])
	tracker.set_active(true)
	clock_value[0] = 10.125
	var saved_snapshot := tracker.get_pending_seconds()
	_check(is_equal_approx(saved_snapshot, 0.125), "八分之一秒小量累计不被整秒截断")
	clock_value[0] = 10.375
	tracker.acknowledge(saved_snapshot)
	_check(is_equal_approx(tracker.get_pending_seconds(), 0.25), "确认旧快照后保留写盘期间新增四分之一秒")
	tracker.acknowledge(0.25)
	clock_value[0] = 9.0
	_check(is_zero_approx(tracker.get_pending_seconds()), "时钟倒退不会产生负数或重记已保存时间")
	clock_value[0] = 10.375
	_check(is_zero_approx(tracker.get_pending_seconds()), "时钟恢复旧最高水位仍不重复计时")
	clock_value[0] = 10.5
	_check(is_equal_approx(tracker.get_pending_seconds(), 0.125), "时钟超过历史水位才累计新时间")
	for invalid: Variant in [NAN, INF, -INF, "invalid", null]:
		clock_value[0] = invalid
		_check(is_equal_approx(tracker.get_pending_seconds(), 0.125), "异常时钟保持最近有效累计：%s" % str(invalid))
	for invalid: float in [NAN, INF, -INF, -1.0]:
		tracker.acknowledge(invalid)
		_check(is_equal_approx(tracker.get_pending_seconds(), 0.125), "异常确认秒数不能扣除待存活动：%s" % str(invalid))
	clock_value[0] = 10.75
	tracker.set_active(false)
	clock_value[0] = 100.0
	_check(is_equal_approx(tracker.get_pending_seconds(), 0.375), "关闭活动后长时间等待不增加待存秒数")
	tracker.reset()
	_check(is_zero_approx(tracker.get_pending_seconds()) and not tracker.is_active(), "后台重置清空待存秒数且保持非活动状态")
	tracker.set_active(true)
	clock_value[0] = 100.25
	tracker.reset()
	clock_value[0] = 100.5
	_check(is_equal_approx(tracker.get_pending_seconds(), 0.25) and tracker.is_active(), "前台重置只保留新身份开始后的时间")


## 每次重建复用测试档案；明确注入前台状态，避免宿主窗口焦点影响测试。
func _create_game() -> void:
	_game = ActivityShell.new()
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("player_profile.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.profile_clock = func() -> float: return _clock[0]
	_game.profile_native_dialog_handler = _native_dialog
	root.add_child(_game)
	await _settle()
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_RESUMED)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_game.set_process(false)
	_game._sync_activity_timer()


## 主菜单、设置和三个设置子页面全部排除，关于与版权卡扩展也不计入。
func _test_excluded_pages() -> void:
	_check(not bool(_game.profile.get_statistics().shark_discovered), "新档案默认没有触发鲨鱼彩蛋")
	_advance(90.0)
	_expect_seconds("主菜单停留九十秒不计入")
	for route: String in ["_show_settings_page", "_show_code_colors_page", "_show_player_level_list_page", "_show_player_profile_page"]:
		_game.call(route)
		await _settle()
		_advance(40.0)
		_expect_seconds("设置与只读子页排除：" + route)
	_game._show_settings_page()
	await _settle()
	_game._show_about_dialog()
	_advance(17.0)
	_expect_seconds("关于窗口停留不计入")
	_game._open_shark_game()
	_game._about_dialog._expansion_tween.pause()
	_advance(8.0)
	_expect_seconds("关于卡片扩展过渡不计入")
	_game._cancel_shark_entry()
	_check(not bool(_game.profile.get_statistics().shark_discovered), "取消关于卡片扩展不会提前解锁彩蛋统计")
	_game._about_dialog.close_dialog(false)


## 选关会累计；后台、应用暂停和最小化独立暂停，任何恢复顺序均不能提前计时。
func _test_foreground_boundaries() -> void:
	_game._show_level_page()
	await _settle()
	_advance(1.25, true)
	_expect_seconds("选关页累计一又四分之一秒并保存小数")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_advance(51.0)
	_expect_seconds("后台停留排除")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_PAUSED)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_advance(22.0)
	_expect_seconds("有焦点但应用仍暂停不计入")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_RESUMED)
	_advance(13.0)
	_expect_seconds("应用恢复但仍在后台不计入")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_advance(2.5, true)
	_game.minimized_for_test = true
	_game._sync_activity_timer()
	_advance(101.0)
	_expect_seconds("最小化不计入，前台选关两秒半保留")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_game.minimized_for_test = false
	_game._sync_activity_timer()
	_advance(16.0)
	_expect_seconds("取消最小化但没有焦点仍不计入")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_advance(0.75, true)
	_game._show_settings_page()
	_expect_seconds("进入设置立即结算选关尾段，累计四秒半")
	var disk := PlayerProfileStore.new(_game.profile.storage_path)
	_check(disk.load_profile().is_ok() and is_equal_approx(float(disk.get_statistics().play_seconds), _expected_seconds), "立即落盘可由独立档案实例读取")


## 周期保存走正式帧入口；外部写入冲突必须保留原文件与待存秒数，恢复后只保存一次。
func _test_periodic_save_and_retry() -> void:
	_game._show_level_page()
	await _settle()
	var before := float(_game.profile.get_statistics().play_seconds)
	_advance(30.5, true)
	_game._process(GameShell.ACTIVITY_SAVE_INTERVAL - 0.5)
	_check(is_equal_approx(float(_game.profile.get_statistics().play_seconds), before), "周期阈值之前不会提前落盘")
	_game._process(0.5)
	_check(is_equal_approx(float(_game.profile.get_statistics().play_seconds), _expected_seconds), "达到三十秒保存周期自动落盘所有新增活动")
	_check(is_zero_approx(_game._activity_tracker.get_pending_seconds()), "周期保存成功后待存秒数扣除")
	var original := FileAccess.get_file_as_bytes(_game.profile.storage_path)
	var externally_changed := original.duplicate()
	externally_changed.append_array("\n ".to_utf8_buffer())
	_write_profile_bytes(externally_changed)
	_advance(3.5, true)
	_game._flush_activity_statistics()
	_check(is_equal_approx(float(_game.profile.get_statistics().play_seconds), _expected_seconds - 3.5), "写盘冲突不会提前增加内存中的已存总时长")
	_check(is_equal_approx(_game._activity_tracker.get_pending_seconds(), 3.5), "写盘失败保留三秒半待存活动")
	_check(FileAccess.get_file_as_bytes(_game.profile.storage_path) == externally_changed, "统计写盘失败不覆盖外部更新的档案字节")
	_advance(1.25, true)
	_write_profile_bytes(original)
	_game._flush_activity_statistics()
	_expect_seconds("恢复原档案后重试，之前失败的三秒半及后续一秒又四分之一只计一次")
	_check(is_zero_approx(_game._activity_tracker.get_pending_seconds()), "重试保存成功后旧待存活动清空")
	_game._flush_activity_statistics()
	_expect_seconds("重复刷新不会重记已经成功保存的活动时间")
	_game._show_settings_page()


## 仅修改测试专用档案以制造可恢复的外部写入冲突，不使用全局文件或伪造存储实现。
func _write_profile_bytes(bytes: PackedByteArray) -> void:
	var file := FileAccess.open(_game.profile.storage_path, FileAccess.WRITE)
	if _check(file != null, "测试专用档案可写"):
		file.store_buffer(bytes)
		file.close()


## 编辑器及其试玩计总活动时间；真实装配、编程和主动暂停均累计且不改旧失败语义。
func _test_editor_and_challenge() -> void:
	var before := _challenge_stats()
	_game._open_editor()
	await _settle()
	_advance(3.25, true)
	var lesson: LevelDefinition = _game.catalog.levels[0]
	_game._start_editor_playtest(lesson, _game.registry)
	_game._dialogue_dialog.hide()
	await _settle()
	_advance(4.0, true)
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "试玩安装真实移动模块")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	_advance(5.0, true)
	_game.session.source = "main(){move(0,4)}"
	_game.session.run()
	_game.session.pause()
	_check(_game.session.state == GameSession.State.PAUSED, "试玩进入真实暂停状态")
	_advance(6.0, true)
	_game._return_to_editor()
	await _settle()
	_advance(2.0, true)
	_game._show_settings_page()
	_expect_seconds("编辑、试玩装配编程和暂停共二十秒又四分之一计入")
	_check(_challenge_stats() == before, "试玩活动时间不会混入提示、通过率及单关最快最慢时间")
	_game._enter_level(lesson)
	_game._dialogue_dialog.hide()
	await _settle()
	# 入场只登记提示档位；将这一合法元数据作为运行前基线。
	before = _challenge_stats()
	_advance(2.0, true)
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "正式关卡安装真实移动模块")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	_advance(3.0, true)
	_game.session.source = "main(){move(0,4)}"
	_game.session.run()
	_game.session.pause()
	_advance(4.0, true)
	_game.session.stop()
	_game._back_to_levels()
	_advance(1.0, true)
	_game._show_settings_page()
	_expect_seconds("正式装配编程、手动暂停及返回选关累计十秒")
	_check(_challenge_stats() == before, "手动停止与活动累计不会制造失败或成功")


## 真实隐藏入口交接后即计时，活着退出也保存得分；失败和较低后续局不能降低最高分。
func _test_shark_activity_and_scores() -> void:
	var before := _challenge_stats()
	await _open_shark()
	_check(_game.shark_game.screen_state == SharkCaveGame.Screen.INTRO and _game.shark_game.run.score == 0 and bool(_game.profile.get_statistics().shark_discovered), "首次零分入场已经标记实际触发，不要求产生分数")
	_advance(2.0, true)
	_game.shark_game._advance_intro(SharkCaveGame.INTRO_DURATION)
	_game.shark_game.run.score = 37
	_advance(3.0, true)
	_game.shark_game._pause_run()
	_advance(4.0, true)
	_game.shark_game._exit_game()
	await _settle()
	_expect_seconds("鲨鱼入场、游戏及手动暂停累计九秒，退出关于即结算")
	_check(int(_game.profile.get_statistics().shark_best_score) == 37, "活着退出的三十七分通过真实退出信号保存")
	_advance(50.0)
	_expect_seconds("返回关于后的停留不计入")
	await _open_shark()
	_check(_game.shark_game.best_score == 37, "再次进入读取已保存最高分")
	_game.shark_game._advance_intro(SharkCaveGame.INTRO_DURATION)
	_game.shark_game.run.score = 19
	_game.shark_game._finish_run()
	_advance(1.5, true)
	_game.shark_game._exit_game()
	await _settle()
	_expect_seconds("鲨鱼终局前台停留也计时")
	_check(int(_game.profile.get_statistics().shark_best_score) == 37, "较低的失败局和退出不降低最高分")
	await _open_shark()
	_game.shark_game._advance_intro(SharkCaveGame.INTRO_DURATION)
	_game.shark_game.run.score = 83
	_game.shark_game._finish_run()
	_check(int(_game.profile.get_statistics().shark_best_score) == 83, "真实结束信号立即持久化新最高分")
	_game.shark_game._exit_game()
	await _settle()
	await _open_shark()
	_game.shark_game._advance_intro(SharkCaveGame.INTRO_DURATION)
	_game.shark_game.run.score = 101
	_game.shark_game._pause_run()
	_game.shark_game._retry.pressed.emit()
	_check(_game.shark_game.run.score == 0 and _game.shark_game.best_score == 101, "暂停后重新开始清空本局分数但保留先前取得的新高")
	_game.shark_game._exit_game()
	await _settle()
	_check(int(_game.profile.get_statistics().shark_best_score) == 101, "暂停重开后直接退出仍持久化重开前最高分")
	_check(_challenge_stats() == before, "彩蛋得分和时间不污染主游戏挑战统计")


## 重启保留已保存时间与最高分，重置换身份后旧会话数据不可回灌。
func _test_restart_and_reset() -> void:
	_game._show_level_page()
	_advance(2.25, true)
	var old_uid := _game.profile.get_uid()
	_game.queue_free()
	await _settle()
	_game = null
	_clock[0] += 500.0
	await _create_game()
	_expect_seconds("销毁外壳保存最后活动段，重启不计离线五百秒")
	_check(_game.profile.get_uid() == old_uid and int(_game.profile.get_statistics().shark_best_score) == 101 and bool(_game.profile.get_statistics().shark_discovered), "重启保持同一UID、最高分和已触发标记")
	_game._show_player_profile_page()
	await _settle()
	_game._request_profile_reset()
	var callback: Callable = _native_callbacks.back()
	callback.call(1)
	await _settle()
	_expected_seconds = 0.0
	_expect_seconds("确认删除玩家档案清空累计时间")
	_check(_game.profile.get_uid() != old_uid and int(_game.profile.get_statistics().shark_best_score) == 0 and not bool(_game.profile.get_statistics().shark_discovered), "确认删除生成新UID并清空最高分和触发标记")
	_game._flush_activity_statistics()
	_expect_seconds("重置后的刷新不会重放旧UID未结算活动段")
	_game._show_settings_page()
	await _settle()
	await _open_shark()
	_check(_game.shark_game.best_score == 0, "重置后重新进入彩蛋不恢复旧最高分缓存")
	_game.shark_game._exit_game()
	await _settle()
	_game._show_level_page()
	_advance(1.0, true)
	_game.quit_handler = func() -> void: pass
	_game._leave_game()
	_advance(80.0)
	_expect_seconds("退出请求保存最后一秒且退出后不继续累计")


## 保留正式开启动画状态但主动推进交接，时间仅由注入时钟计算。
func _open_shark() -> void:
	if not _game._about_dialog.is_open():
		_game._show_about_dialog()
	_game._open_shark_game()
	if not _check(_game._shark_entry_pending, "隐藏入口开始关于卡片扩展"):
		return
	_game._about_dialog._expansion_tween.pause()
	_game._about_dialog._finish_easter_expansion(_game._about_dialog._expansion_generation)
	_check(is_instance_valid(_game.shark_game), "扩展完成构造真实鲨鱼界面")
	_game._shark_entry_tween.pause()
	_game.shark_game.set_process(false)
	_advance(7.0)
	_expect_seconds("鲨鱼海洋淡入尚未交接的七秒不计入")
	_game._finish_shark_entry(_game._shark_entry_generation)
	await _settle()
	_check(not _game._shark_entry_pending and _game.shark_game.is_visible_in_tree(), "交接后鲨鱼正式显示，即使底层页面仍为设置")


## 显式活动预期来自测试情境，推进假时钟不等待真实秒数。
func _advance(seconds: float, included: bool = false) -> void:
	_clock[0] += seconds
	if included:
		_expected_seconds += seconds
	_game._sync_activity_timer()


## 通过生产落盘入口比较累计秒数，独立文件读取验证内存与磁盘一致。
func _expect_seconds(context: String) -> void:
	_game._flush_activity_statistics()
	var actual := float(_game.profile.get_statistics().play_seconds)
	_check(is_equal_approx(actual, _expected_seconds), context + "：实际 %.4f，预期 %.4f" % [actual, _expected_seconds])


## 单关挑战字段单独快照，累计游戏时间和彩蛋得分具有独立统计语义。
func _challenge_stats() -> Dictionary:
	var statistics := _game.profile.get_statistics()
	statistics.erase("play_seconds")
	statistics.erase("shark_best_score")
	statistics.erase("shark_discovered")
	return statistics


## 删除确认只捕获系统回调，测试不弹出真正的操作系统窗口。
func _native_dialog(_title: String, _body: String, _buttons: PackedStringArray, callback: Callable) -> int:
	_native_callbacks.append(callback)
	return OK


## 等待真实容器和信号队列，不在等待过程中推进注入墙钟。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 所有断言均保留上下文，失败后继续收集独立边界情况。
func _check(condition: bool, context: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL " + context)
	return condition


## 只删除本次测试创建的独占目录，保留真实档案与关卡。
func _cleanup(path: String) -> void:
	if not path.begins_with("user://tests/player_activity_"):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for folder in directory.get_directories():
		_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)


## 正常结束或超时都关闭测试外壳，输出供总回归识别的完成标记。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_cleanup(_temporary)
	print("玩家活动统计回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 超时明确作为失败，避免未执行断言被错误识别为成功。
func _timeout() -> void:
	_check(false, "玩家活动统计回归超时")
	_finish()
