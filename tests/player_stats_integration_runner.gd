extends SceneTree
## 玩家档案端到端回归：正式统计、活动墙钟、编辑器隔离和系统确认均走真实入口。

class StatisticsShell extends GameShell:
	## 无窗口后端会把窗口模式报告为最小化；平台边界另由活动统计回归注入覆盖。
	func _is_activity_window_minimized() -> bool:
		return false if DisplayServer.get_name() == "headless" else super._is_activity_window_minimized()

const SOLUTION := "main(){\nmove(0,4)\nmove(90,3)\nmove(180,4)\nmove(90,3)\nmove(0,4)\n}"
const MAX_STEPS := 1000
var _checks := 0
var _failures := 0
var _temporary := ""
var _clock := [1000.0]
var _native_callbacks: Array[Callable] = []
var _native_buttons: Array[PackedStringArray] = []
var _game: GameShell


## 使用真实帧处理异步文本事件，墙钟秒数由独立注入值精确控制。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 所有磁盘和系统边界仅访问本次独占目录，不读取或重置实际玩家档案。
func _run() -> void:
	create_timer(90.0).timeout.connect(_timeout)
	_temporary = "user://tests/player_stats_integration_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = StatisticsShell.new()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("player_profile.json")
	_game.profile_clock = func() -> float: return _clock[0]
	_game.profile_native_dialog_handler = _record_native_request
	root.add_child(_game)
	_game.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	_game.settings.set_language("zh_CN")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	if not _check(_game.profile != null and PlayerProfileStore.is_uid(_game.profile.get_uid()), "初次启动生成不可编辑的非零开头数字 UID"):
		await _finish()
		return
	_check(_game.profile.get_username() == "Player" and _game.profile.get_statistics().successes == 0, "新档案默认 Player 且没有伪造历史统计")
	var lesson: LevelDefinition = _game.catalog.levels[0]
	await _test_real_statistics_and_clock(lesson)
	await _test_all_formal_sources(lesson)
	await _test_weighted_identity_and_help(lesson)
	await _test_editor_isolation(lesson)
	await _test_actual_hints(lesson)
	await _test_settings_identity_and_reset(lesson)
	await _finish()


## 真实编译与碰撞失败仅结算一次，修改装配累计而暂停和后台时间排除。
func _test_real_statistics_and_clock(lesson: LevelDefinition) -> void:
	_game._enter_level(lesson)
	_game._dialogue_dialog.hide()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game._profile_tracker.is_active(), "正式关卡从空装配开始计时")
	_advance(4.0)
	_game._update_preparation()
	_game._confirm_assembly()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.profile.get_statistics().failures == 0, "无效装配预览与禁用确认不是实际失败")
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "实际安装第一关中心移动模块")
	_game._confirm_assembly()
	await _settle()
	var bench := _game.workbench
	bench.set_process(false)
	_advance(6.0)
	await _set_source(bench, "main(){unknown()}")
	bench._run_program()
	_check(_game.session.state == GameSession.State.FAILED and _game.profile.get_statistics().failures == 1, "实际编译错误计入一次失败")
	for unused in 8:
		_game.session.step()
	bench._sync_session()
	_check(_game.profile.get_statistics().failures == 1, "失败终态重复步进与刷新不重复结算")
	_advance(3.0)
	await _set_source(bench, "main(){move(180,1)}")
	bench._run_program()
	_advance_to_terminal(_game.session)
	_check(_game.session.state == GameSession.State.FAILED and _game.session.world.tick_index > 0 and _game.profile.get_statistics().failures == 2, "真实撞入 void 的运行错误计入第二次失败")
	_advance(5.0)
	_game._return_to_assembly()
	await _settle()
	_check(is_equal_approx(_game._profile_tracker.get_elapsed_seconds(), 18.0), "失败后编辑和回装配继续累计，不重新开始时钟")
	_advance(4.0)
	_game._confirm_assembly()
	await _settle()
	bench = _game.workbench
	bench.set_process(false)
	_advance(3.0)
	await _set_source(bench, SOLUTION)
	bench._run_program()
	_check(_game.session.state == GameSession.State.RUNNING, "正常解法开始真实运行")
	bench._run_program()
	bench._stop_program()
	bench._reset_position()
	bench._reset_code()
	_check(_game.profile.get_statistics().failures == 2, "重复开始被拒绝、手动停止、重置位置与代码均不影响通过率")
	await _set_source(bench, SOLUTION)
	bench._run_program()
	_advance(2.0)
	_game.session.pause()
	var paused_elapsed := _game._profile_tracker.get_elapsed_seconds()
	_advance(40.0)
	_check(is_equal_approx(_game._profile_tracker.get_elapsed_seconds(), paused_elapsed) and not _game._profile_tracker.is_active(), "暂停的四十秒完全排除")
	_game.session.resume()
	_advance(3.0)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var background_elapsed := _game._profile_tracker.get_elapsed_seconds()
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_PAUSED)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(not _game._profile_tracker.is_active(), "应用仍挂起时焦点恢复不能提前开始计时")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_RESUMED)
	_check(not _game._profile_tracker.is_active(), "应用恢复但仍在后台时也不能开始计时")
	_advance(50.0)
	_check(is_equal_approx(_game._profile_tracker.get_elapsed_seconds(), background_elapsed), "切到后台的五十秒完全排除")
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_advance(7.0)
	_advance_to_terminal(_game.session)
	var stats := _game.profile.get_statistics()
	_check(_game.session.state == GameSession.State.SUCCEEDED and stats.successes == 1 and stats.failures == 2, "一次真实成功与两次真实失败形成三次已结算尝试")
	_check(is_equal_approx(float(stats.fastest_seconds), 37.0) and is_equal_approx(float(stats.longest_seconds), 37.0), "通关耗时精确为三十七秒，含装配与失败修复且排除暂停后台")
	var first_rate := _game.profile.get_weighted_pass_rate()
	var first_ledger: Dictionary = stats.level_ledger["tutorial:" + lesson.id].duplicate(true)
	_check(is_equal_approx(first_rate, 0.2 / 3.0), "默认一般提示与零敌人首通权重0.2，分母含首次成功前两次失败")
	_check(first_ledger.completed and first_ledger.failures == 2 and first_ledger.enemy_count == 0 and first_ledger.hint_mode == "normal", "正式教程首通账本记录真实来源、敌人数与最高帮助档")
	_game.session.completed.emit()
	_check(_challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(stats), "重复成功通知不制造第二次通关或改变时间")
	_advance(100.0)
	_check(is_equal_approx(_game._profile_tracker.get_elapsed_seconds(), 37.0), "成功后等待不继续计时")
	bench._run_program()
	_advance(15.0)
	_advance_to_terminal(_game.session)
	stats = _game.profile.get_statistics()
	_check(stats.successes == 2 and stats.failures == 2 and is_equal_approx(float(stats.fastest_seconds), 15.0) and is_equal_approx(float(stats.longest_seconds), 37.0), "成功后直接重跑从新挑战计时，第二次十五秒不混入成功后的等待")
	_check(is_equal_approx(_game.profile.get_weighted_pass_rate(), first_rate) and stats.level_ledger["tutorial:" + lesson.id] == first_ledger, "同关成功重玩继续计时，但首通账本和通过率冻结")
	await _set_source(bench, "main(){unknown()}")
	bench._run_program()
	stats = _game.profile.get_statistics()
	_check(_game.session.state == GameSession.State.FAILED and stats.failures == 3, "首通后真实失败继续保留兼容挑战汇总")
	_check(is_equal_approx(_game.profile.get_weighted_pass_rate(), first_rate) and stats.level_ledger["tutorial:" + lesson.id] == first_ledger, "首通后的失败也不再影响通过率")
	await _set_source(bench, SOLUTION)
	bench._run_program()
	_advance(9.0)
	_game._back_to_levels()
	_advance(90.0)
	_check(not _game._profile_tracker.has_started() and _challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(stats), "主动退出未完成挑战不产生失败，离开后的等待不保存为耗时")


## 统计只区分正式游玩与编辑器测试，不按教程路径限制未来关卡和玩家地图。
func _test_all_formal_sources(lesson: LevelDefinition) -> void:
	for entry in [["profile_future", "res://data/official/profile_future.json"], ["profile_imported", _temporary.path_join("levels/profile_imported.json")]]:
		var definition := _copy_level(lesson, entry[0], entry[1])
		if definition == null:
			continue
		var before := _game.profile.get_statistics()
		var bench := await _enter_program(definition)
		await _set_source(bench, "main(){missing()}")
		bench._run_program()
		_check(_game.profile.get_statistics().failures == before.failures + 1, "正式来源实际编译失败都统计：" + entry[0])
		await _set_source(bench, SOLUTION)
		bench._run_program()
		_advance(8.0)
		_advance_to_terminal(_game.session)
		_check(_game.session.state == GameSession.State.SUCCEEDED and _game.profile.get_statistics().successes == before.successes + 1, "正式来源真实成功都统计：" + entry[0])
	# 出生点恰好在目标内时，run 自身就能真实通关，不依赖后续帧同步。
	var document := lesson.document.duplicate_document()
	document.id = "profile_immediate"
	document.properties.level.goal.position = document.player_spawn.position.duplicate(true)
	var created := LevelDefinition.from_document(document, _game.registry, "res://data/official/profile_immediate.json")
	if _check(created.is_ok(), "构造真实即时通关目标"):
		var before := _game.profile.get_statistics()
		var bench := await _enter_program(created.value)
		_advance(6.0)
		await _set_source(bench, "main(){}")
		bench._run_program()
		_check(_game.session.state == GameSession.State.SUCCEEDED and _game.profile.get_statistics().successes == before.successes + 1, "run 内立即完成也结算一次成功")
		_check(is_equal_approx(float(_game.profile.get_statistics().fastest_seconds), 6.0), "即时完成仍包含此前六秒装配编程时间")
		# 在实际 run 的启动信号内推进注入时钟，覆盖状态尚未变 RUNNING 的同步编译阶段。
		var compile_time := func() -> void: _advance(4.0)
		_game.session.attempt_started.connect(compile_time)
		_advance(100.0)
		bench._run_program()
		_game.session.attempt_started.disconnect(compile_time)
		_check(_game.session.state == GameSession.State.SUCCEEDED and _game.profile.get_statistics().successes == before.successes + 2, "成功后直接重跑并即时完成仍结算新的尝试")
		_check(is_equal_approx(float(_game.profile.get_statistics().fastest_seconds), 4.0), "即时重跑计入同步编译的四秒，不混入通关后等待")
	var free_document := lesson.document.duplicate_document()
	free_document.id = "profile_no_goal"
	free_document.properties.level.goal = null
	var free_result := LevelDefinition.from_document(free_document, _game.registry, _temporary.path_join("levels/profile_no_goal.json"))
	if _check(free_result.is_ok(), "真实无目标自由地图仍可进入正式流程"):
		var before := _game.profile.get_statistics()
		var bench := await _enter_program(free_result.value)
		# 进入时仅登记帮助档，不产生成功或失败；比较真正运行之前的同一账本快照。
		before = _game.profile.get_statistics()
		await _set_source(bench, "main(){}")
		bench._run_program()
		_check(_game.session.state == GameSession.State.EDITING and _challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(before), "无目标地图执行完成不冒充一次通关或真实失败")


## 来源域分离、玩家文件移动和提示写盘失败都必须经过真实 Shell 入口验证首通身份。
func _test_weighted_identity_and_help(lesson: LevelDefinition) -> void:
	_game.settings.set_code_hints("none")
	var tutorial_before: Dictionary = _game.profile.get_statistics().level_ledger["tutorial:" + lesson.id].duplicate(true)
	for entry in [["official", "res://data/official/" + lesson.id + ".json"], ["player", _temporary.path_join("levels/" + lesson.id + ".json")]]:
		var definition := _copy_level(lesson, lesson.id, entry[1])
		var bench := await _enter_program(definition)
		await _set_source(bench, SOLUTION)
		bench._run_program()
		_advance(2.0)
		_advance_to_terminal(_game.session)
		var record: Dictionary = _game.profile.get_statistics().level_ledger[entry[0] + ":" + lesson.id]
		_check(record.completed and record.failures == 0 and is_equal_approx(float(record.success_weight), 0.4), "同ID在不同正式来源域独立记录首次成功：" + entry[0])
	_check(_game.profile.get_statistics().level_ledger["tutorial:" + lesson.id] == tutorial_before, "同名玩家/未来正式地图不覆盖教学首通账本")
	var moved := _copy_level(lesson, lesson.id, _temporary.path_join("levels/moved_filename.json"))
	var moved_bench := await _enter_program(moved)
	var rate := _game.profile.get_weighted_pass_rate()
	await _set_source(moved_bench, "main(){missing()}")
	moved_bench._run_program()
	_check(is_equal_approx(_game.profile.get_weighted_pass_rate(), rate), "移动或改名玩家文件仍按同一map ID冻结已首通通过率")
	var ceiling := _copy_level(lesson, "profile_hint_ceiling", _temporary.path_join("levels/ceiling.json"))
	var bench := await _enter_program(ceiling)
	var storage_path := _game.profile.storage_path
	# 暂时不可写的档案位置使设置变化无法持久化，之后恢复原档案再完成真实关卡。
	_game.profile.storage_path = _temporary.path_join("unavailable/profile.json")
	_game.settings.set_code_hints("more")
	_game.settings.set_code_hints("none")
	_game.profile.storage_path = storage_path
	_check(_game._profile_hint_mode == "more" and _game.profile.get_statistics().level_ledger["player:profile_hint_ceiling"].hint_mode == "none", "写盘失败时会话仍记住more，模型保持之前有效none记录")
	await _set_source(bench, SOLUTION)
	bench._run_program()
	_advance(2.0)
	_advance_to_terminal(_game.session)
	var record: Dictionary = _game.profile.get_statistics().level_ledger["player:profile_hint_ceiling"]
	_check(record.completed and record.hint_mode == "more" and is_equal_approx(float(record.success_weight), 0.12), "完成提交最高已见帮助档，more切none不能刷高首通权重")
	var waves := _game.catalog.levels[11].document.duplicate_document()
	waves.id = "profile_pending_waves"
	waves.properties.level.goal = {"position": waves.player_spawn.position.duplicate(true), "radius": 0.25}
	var result := LevelDefinition.from_document(waves, _game.registry, "res://data/official/profile_pending_waves.json")
	if _check(result.is_ok(), "含完整待生波机器的即时目标通过正式数据校验"):
		bench = await _enter_program(result.value)
		await _set_source(bench, "main(){}")
		bench._run_program()
		record = _game.profile.get_statistics().level_ledger["official:profile_pending_waves"]
		_check(_game.session.state == GameSession.State.SUCCEEDED and record.enemy_count == 8 and is_equal_approx(float(record.success_weight), 0.85), "敌人数取完整地图八台机器，包含尚未出场波次，不按模块或当前场上数量")
	var disabled := _game.catalog.levels[12].document.duplicate_document()
	disabled.id = "profile_disabled_enemies"
	disabled.properties.level.enemies_enabled = false
	disabled.properties.level.goal = {"position": disabled.player_spawn.position.duplicate(true), "radius": 0.25}
	result = LevelDefinition.from_document(disabled, _game.registry, "res://data/official/profile_disabled_enemies.json")
	if _check(result.is_ok() and disabled.enemies.size() == 10, "关闭敌人的地图仍保留原有十台机器并通过数据校验"):
		bench = await _enter_program(result.value)
		await _set_source(bench, "main(){}")
		bench._run_program()
		record = _game.profile.get_statistics().level_ledger["official:profile_disabled_enemies"]
		_check(_game.session.state == GameSession.State.SUCCEEDED and record.enemy_count == 0 and is_equal_approx(float(record.success_weight), 0.4), "敌人开关关闭时按零台生效机器结算，不用保留的十条地图记录提高权重")
	var extended := waves.duplicate_document()
	extended.id = "profile_unknown_enemy"
	var unknown: Dictionary = extended.enemies[0].duplicate(true)
	unknown.id = "extension_only"
	unknown.behavior = "future_unknown_behavior"
	extended.enemies.append(unknown)
	result = LevelDefinition.from_document(extended, _game.registry, "res://data/official/profile_unknown_enemy.json")
	if _check(result.is_ok() and extended.enemies.size() == 9, "八台真实机器和一条未知行为扩展均可保留为有效地图数据"):
		bench = await _enter_program(result.value)
		await _set_source(bench, "main(){}")
		bench._run_program()
		record = _game.profile.get_statistics().level_ledger["official:profile_unknown_enemy"]
		_check(_game.session.state == GameSession.State.SUCCEEDED and record.enemy_count == 8 and is_equal_approx(float(record.success_weight), 0.85), "未知行为扩展不运行也不计敌人数，八台机器不会跨入九台权重档")
	var reloaded := PlayerProfileStore.new(storage_path)
	_check(reloaded.load_profile().is_ok() and is_equal_approx(reloaded.get_weighted_pass_rate(), _game.profile.get_weighted_pass_rate()), "身份域和首通权重重启加载后保持一致")


## 相同教程 ID 与来源的编辑器快照也不能污染正式档案、草稿或提示次数。
func _test_editor_isolation(lesson: LevelDefinition) -> void:
	_game._open_editor()
	await _settle()
	var before := _game.profile.get_statistics()
	var bytes := _profile_without_activity_time(FileAccess.get_file_as_bytes(_game.profile.storage_path))
	_game._start_editor_playtest(lesson, _game.registry)
	_game._dialogue_dialog.hide()
	await _settle()
	_check(_game._editor_playtest and not _game._profile_tracker.has_started(), "伪装教学来源的编辑器测试仍不启动正式计时")
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "编辑器测试使用独立空装配")
	_game._confirm_assembly()
	await _settle()
	var bench := _game.workbench
	bench.set_process(false)
	await _set_source(bench, "main(){missing()}")
	bench._run_program()
	await _set_source(bench, SOLUTION)
	bench._run_program()
	_advance(30.0)
	_advance_to_terminal(_game.session)
	_check(_game.session.state == GameSession.State.SUCCEEDED and not bench._hint_button.visible, "测试可真实通关但不提供正式教学提示")
	_game._on_profile_code_hint_used()
	_game._flush_activity_statistics()
	_check(_challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(before) and _profile_without_activity_time(FileAccess.get_file_as_bytes(_game.profile.storage_path)) == bytes, "编辑器成功失败与伪造提示只允许活动总时长变化，不改身份或正式挑战统计")
	_check(float(_game.profile.get_statistics().play_seconds) >= float(before.play_seconds) + 30.0, "编辑器试玩的三十秒计入累积游戏时间：之前 %.3f，当前 %.3f" % [float(before.play_seconds), float(_game.profile.get_statistics().play_seconds)])
	_game._return_to_editor()
	_check(_game.page == GameShell.Page.EDITOR and _challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(before), "返回编辑器不补记正式挑战统计")


## 提示服务的独立模拟不计数，只有实际应用一次代码修改才增加一次提示使用。
func _test_actual_hints(lesson: LevelDefinition) -> void:
	_game.settings.set_code_hints("more")
	var bench := await _enter_program(lesson)
	await _set_source(bench, "main(){}")
	var before := _game.profile.get_statistics()
	# 与提示点击入口相同，先把当前输入同步给只读服务，避免读取先前恢复的源码。
	_game.session.source = bench._code.text
	var result := CodeHintService.next_hint(_game.session)
	_check(result.is_ok() and _challenge_statistics(_game.profile.get_statistics()) == _challenge_statistics(before), "直接求提示中的验证会话不结算档案统计")
	bench._hint_button.pressed.emit()
	await _settle()
	_check(bench._code.text.contains("move(0, 4)") and _game.profile.get_statistics().code_hint_uses == before.code_hint_uses + 1, "点击并真正插入一步代码时只累计一次提示")
	bench._hint_undo_button.pressed.emit()
	await _settle()
	_check(_game.profile.get_statistics().code_hint_uses == before.code_hint_uses + 1, "撤销提示不增加或扣减累计使用数")
	await _set_source(bench, SOLUTION)
	bench._hint_button.pressed.emit()
	await _settle()
	_check(_game.profile.get_statistics().code_hint_uses == before.code_hint_uses + 1 and _game.profile.get_statistics().failures == before.failures, "已有正确解法的无修改提示和验证失败不会污染使用数或通过率")
	_game.settings.set_code_hints("none")
	bench._hint_button.pressed.emit()
	await _settle()
	_check(_game.profile.get_statistics().code_hint_uses == before.code_hint_uses + 1, "隐藏提示入口的旧信号不计使用")


## 设置入口、默认署名与系统确认联动；重置只替换档案，保留用户全部关卡文件。
func _test_settings_identity_and_reset(lesson: LevelDefinition) -> void:
	_game._show_settings_page()
	await _settle()
	var entry := _game.find_child("PlayerProfileButton", true, false) as Button
	_check(entry != null and _game.find_child("BasicSettingsSection", true, false) != null, "设置基本分类提供玩家与统计信息入口")
	entry.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.PLAYER_PROFILE and _game.player_profile_panel != null, "真实入口信号进入档案子页")
	var panel := _game.player_profile_panel
	_check(not panel._uid_field.editable and panel._username_field.alignment == HORIZONTAL_ALIGNMENT_RIGHT and panel._username_field.caret_blink, "UID 只读，用户名输入始终右对齐且光标闪烁")
	_check(panel._delete_button.get_theme_color("font_color").is_equal_approx(Color("9d1414")), "删除玩家档案按钮使用指定红色字体")
	var uid := _game.profile.get_uid()
	panel._username_field.text = "测试Player"
	panel._username_field.text_changed.emit(panel._username_field.text)
	_check(panel.commit_username() and _game.profile.get_username() == "测试Player" and _game.profile.get_uid() == uid, "编辑用户名落盘但完全不改变 UID")
	_game._go_back()
	_check(_game.page == GameShell.Page.SETTINGS, "档案子页返回既有设置页面")
	_game._open_editor()
	await _settle()
	_game._editor._new_document()
	_check(_game._editor.editor_document.get_creator() == "测试Player", "新建地图自动关联设置中的玩家署名")
	var map := lesson.document.duplicate_document()
	map.id = "profile_keep_map"
	map.properties.level.creator = "原作者"
	var map_path := _game.user_levels_directory.path_join("profile_keep_map.json")
	_check(MapCodec.save_file(map, map_path, _game.registry).is_ok(), "创建必须保留的玩家关卡夹具")
	_game._open_editor(map_path)
	await _settle()
	_check(_game._editor.initial_map_opened and _game._editor.editor_document.get_creator() == "原作者", "打开旧关卡保持原作者，不被当前玩家名覆盖")
	_game._show_player_profile_page()
	await _settle()
	var profile_bytes := FileAccess.get_file_as_bytes(_game.profile.storage_path)
	var preserved := _snapshot_directory(_temporary)
	preserved.erase(_game.profile.storage_path)
	_game.player_profile_panel._delete_button.pressed.emit()
	var request_count := _native_callbacks.size()
	_check(request_count > 0 and _native_buttons.back() == PackedStringArray(["取消", "删除玩家档案"]), "删除使用系统确认接口并把取消放在默认首位")
	_check(FileAccess.get_file_as_bytes(_game.profile.storage_path) == profile_bytes, "显示系统确认前不清空任何档案内容")
	var canceled_callback: Callable = _native_callbacks.back()
	canceled_callback.call(0)
	await _settle()
	_check(not _game._profile_reset_pending and FileAccess.get_file_as_bytes(_game.profile.storage_path) == profile_bytes, "系统取消原样保留 UID、用户名和统计")
	_game._request_profile_reset()
	var stale_callback: Callable = _native_callbacks.back()
	_game._show_settings_page()
	stale_callback.call(1)
	await _settle()
	_check(FileAccess.get_file_as_bytes(_game.profile.storage_path) == profile_bytes, "离开档案页后迟到的删除响应无效")
	_game._show_player_profile_page()
	await _settle()
	_game._request_profile_reset()
	var deleting_callback: Callable = _native_callbacks.back()
	var open_requests := _native_callbacks.size()
	_game._request_profile_reset()
	_check(_native_callbacks.size() == open_requests, "重复点击删除不会打开第二个确认或生成新 UID")
	deleting_callback.call(1)
	await _settle()
	var reset_uid := _game.profile.get_uid()
	var stats := _game.profile.get_statistics()
	_check(PlayerProfileStore.is_uid(reset_uid) and reset_uid != uid and _game.profile.get_username() == "Player", "明确删除确认后生成新的数字 UID 并恢复 Player")
	_check(stats.successes == 0 and stats.failures == 0 and stats.code_hint_uses == 0 and is_zero_approx(float(stats.fastest_seconds)) and is_zero_approx(float(stats.longest_seconds)) and is_zero_approx(float(stats.play_seconds)) and stats.shark_best_score == 0 and not bool(stats.shark_discovered), "确认重置清空全部统计而不保留旧耗时")
	deleting_callback.call(1)
	canceled_callback.call(1)
	await _settle()
	_check(_game.profile.get_uid() == reset_uid, "同一确认或旧取消回调不能再次重置新档案")
	var after := _snapshot_directory(_temporary)
	after.erase(_game.profile.storage_path)
	_check(after == preserved, "重置保留关卡 JSON、草稿、进度、设置及其原始字节")
	var reloaded := PlayerProfileStore.new(_game.profile.storage_path)
	_check(reloaded.load_profile().is_ok() and reloaded.get_uid() == reset_uid and reloaded.get_statistics() == stats, "重新载入仍保持新身份和空统计")
	# 正式离开允许测试替身接管退出；系统窗口的迟到响应不能写入已退出的档案。
	var quit_requests := [0]
	_game.quit_handler = func() -> void: quit_requests[0] += 1
	_game._request_profile_reset()
	var quit_callback: Callable = _native_callbacks.back()
	var before_quit := FileAccess.get_file_as_bytes(_game.profile.storage_path)
	_game._leave_game()
	quit_callback.call(1)
	await _settle()
	_check(quit_requests[0] == 1 and not _game._profile_reset_pending and FileAccess.get_file_as_bytes(_game.profile.storage_path) == before_quit, "游戏退出立即取消系统删除请求，迟到确认不能重置档案")


## 新来源只改变地图标识和路径，目标与真实地形仍沿用已验证的第一关。
func _copy_level(original: LevelDefinition, id: String, path: String) -> LevelDefinition:
	var document := original.document.duplicate_document()
	document.id = id
	var result := LevelDefinition.from_document(document, _game.registry, path)
	return result.value if _check(result.is_ok(), "新来源地图快照通过实际校验：" + id) else null


## 真实进入与装配流程避免直接构造工作台或绕过出生占地验证。
func _enter_program(definition: LevelDefinition) -> GameWorkbench:
	_game._enter_level(definition)
	_game._dialogue_dialog.hide()
	_game._message_dialog.hide()
	await _settle()
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "正式入口通过公开接口安装移动模块")
	_game._confirm_assembly()
	await _settle()
	_check(_game.workbench != null, "确认真实装配进入编程")
	_game.workbench.set_process(false)
	return _game.workbench


## 设置代码并等待原生异步修改信号，同步会话与成功后编辑状态。
func _set_source(bench: GameWorkbench, source: String) -> void:
	bench._code.text = source
	await _settle()


## 仅推进确定上限的真实模拟步，通关与失败由现有会话判定。
func _advance_to_terminal(session: GameSession) -> void:
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "测试会话应在一千个逻辑步内结束")


## 活动计时采用注入的单调秒数，不依赖引擎帧率或实际等待。
func _advance(seconds: float) -> void:
	_clock[0] += seconds


## 系统模态边界只记录按钮与回调，测试不打开实际删除确认窗口。
func _record_native_request(_title: String, _description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_native_callbacks.append(callback)
	_native_buttons.append(buttons)
	return OK


## 文件快照覆盖测试目录全部文件，不跟随符号链接或触及其他用户数据。
func _snapshot_directory(path: String) -> Dictionary:
	var snapshot := {}
	var directory := DirAccess.open(path)
	if directory == null:
		return snapshot
	for filename in directory.get_files():
		if not directory.is_link(filename):
			var file_path := path.path_join(filename)
			snapshot[file_path] = FileAccess.get_file_as_bytes(file_path)
	for folder in directory.get_directories():
		if not directory.is_link(folder):
			snapshot.merge(_snapshot_directory(path.path_join(folder)))
	return snapshot


## 处理容器、文本与原生回调延迟事件，假时钟在等待期间不变化。
func _settle() -> void:
	for unused in 8:
		await process_frame


## 退出前释放外壳并只清理本次独占目录，报告可供全量测试脚本识别的标记。
func _finish() -> void:
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_cleanup(_temporary)
	print("玩家统计集成回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 独占目录清理不跟随链接，不删除正式关卡或存档。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for folder in directory.get_directories():
		if directory.is_link(folder):
			directory.remove(folder)
		else:
			_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)


## 任意断言失败都累积并使测试进程返回失败，不把局部失败视为通过。
func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)
	return condition


## 超时作为确定失败退出，避免系统模态边界错误导致测试无限等待。
func _timeout() -> void:
	push_error("玩家统计集成回归超时。")
	quit(1)


## 总游戏时间独立于单关挑战，比较正式通过统计时只排除新增的活动秒数。
func _challenge_statistics(statistics: Dictionary) -> Dictionary:
	var result := statistics.duplicate(true)
	result.erase("play_seconds")
	return result


## 编辑器允许累计活动时间，但身份、全部挑战统计和未知扩展字段仍须逐项保留。
func _profile_without_activity_time(bytes: PackedByteArray) -> Dictionary:
	var parsed: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
	parsed.statistics.erase("play_seconds")
	return parsed
