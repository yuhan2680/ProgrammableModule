extends SceneTree
## 第十二关使用正式地图、实际装配和普通会话验证八方向防守，不注入胜负结果。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _reference := ""


## 延后一帧开始，等待全局脚本类就绪。
func _initialize() -> void:
	_run.call_deferred()


## 连通教学数据、解锁权限、真实通关、暂停恢复和失败重试。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "加载正式内容"):
		_finish()
		return
	var path := "res://data/levels/level_012.json"
	var loaded := MapCodec.load_file(path, _content, true)
	if not _check(loaded.is_ok(), "正式第十二关地图有效：" + str(loaded.errors)):
		_finish()
		return
	var defined := LevelDefinition.from_document(loaded.value, _content, path)
	if not _check(defined.is_ok(), "正式第十二关规则有效：" + str(defined.errors)):
		_finish()
		return
	_level = defined.value
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_012.json"))
	_reference = str(hint.source).replace("{{sensor}}", "sensor").replace("{{gun}}", "gun")
	_test_definition()
	_test_permissions()
	_test_complete()
	_test_failure_retry()
	_test_timeout()
	_finish()


## 本地化、教程、模块上限和空装配遵循教学关卡的共同入口。
func _test_definition() -> void:
	_check(_level.display_name == "第十二关 · 八方来敌" and _level.order == 12, "关卡名称和顺序正确")
	_check(_level.module_limit == 2 and _level.goal_type == "destroy_waves", "两模块防守全部波次")
	_check(_level.allowed_modules.size() == 5 and _level.allow_functions and _level.allow_variables and _level.allow_random and _level.allow_radar, "继承前关已解锁的工具")
	_check(_level.document.enemies.size() == 8, "正式地图有八个方向的敌人")
	var angles := []
	for entry: Dictionary in _level.document.enemies:
		angles.append(int(entry.properties.move_angle))
	angles.sort()
	_check(angles == [0, 45, 90, 135, 180, 225, 270, 315], "八个攻击方向完整无重复")
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "进入关卡仍需玩家手动安装模块")
	_check(not _level.starter_program.contains("for") and not _level.starter_program.contains("shoot"), "初始程序不预填完整答案")
	for page: Dictionary in _level.document.dialogue:
		_check(GameI18n.ENGLISH.has(page.text), "教程各页具备英文译文")
	_check(GameI18n.ENGLISH.has(_level.description), "关卡描述具备英文译文")
	var changed := _level.document.duplicate_document()
	changed.enemies.clear()
	_check(not LevelDefinition.from_document(changed, _content).is_ok(), "无波次时不能设置全波次通关目标")
	changed = _level.document.duplicate_document()
	changed.properties.level.allow_for = "true"
	_check(not LevelDefinition.from_document(changed, _content).is_ok(), "for 权限严格校验布尔类型")
	changed.properties.level.erase("allow_for")
	var old := LevelDefinition.from_document(changed, _content)
	_check(old.is_ok() and not old.value.allow_for, "旧地图省略 for 权限仍保持锁定")


## 新循环独立于旧解锁开关；旧十一关不提前获得语法。
func _test_permissions() -> void:
	for number in range(1, 14):
		var path := "res://data/levels/level_%03d.json" % number
		var map := MapCodec.load_file(path, _content, true)
		if not _check(map.is_ok(), "逐关载入：%d" % number):
			continue
		var result := LevelDefinition.from_document(map.value, _content, path)
		if not _check(result.is_ok(), "逐关规则：%d" % number):
			continue
		var level: LevelDefinition = result.value
		_check(level.allow_for == (number >= 12), "第十二关起继承 for")
	var locked := _level.document.duplicate_document()
	locked.properties.level.allow_for = false
	var session := _session(LevelDefinition.from_document(locked, _content).value)
	_check(not session.run().is_ok() and session.world == null, "真实会话在创建世界前拒绝未解锁循环")


## 真实扫描、变量与射击必须消灭八个方向全部模块；等待下一波不应提前胜利。
func _test_complete() -> void:
	var original := _level.document.to_dict()
	var session := _session()
	var started := session.run()
	if not _check(started.is_ok(), "正式参考程序启动：" + str(started.errors)):
		return
	var encountered := {}
	var previous_completed := 0
	var saw_gap := false
	var tested_pause := false
	for unused in 900:
		if session.state != GameSession.State.RUNNING:
			break
		var status := session.world.get_enemy_wave_status()
		if not str(status.active_enemy_id).is_empty():
			encountered[status.active_enemy_id] = true
		if int(status.completed) > 0 and int(status.pending) > 0 and str(status.active_enemy_id).is_empty():
			saw_gap = true
			_check(session.state == GameSession.State.RUNNING and not status.all_cleared, "波次间隙仍未通关")
			if not tested_pause:
				tested_pause = true
				session.pause()
				var before := session.world.tick_index
				for ignored in 20:
					session.step()
				_check(session.world.tick_index == before and session.world.get_enemy_wave_status() == status, "暂停冻结波次间隔和敌人状态")
				session.resume()
		_check(int(status.completed) >= previous_completed and int(status.completed) <= 8, "真实击毁进度单调且有界")
		previous_completed = int(status.completed)
		var tick_before := session.world.tick_index
		session.step()
		_check(session.world.tick_index - tick_before <= 1, "扫描八方向每次仍最多推进一个世界 tick")
	_check(session.state == GameSession.State.SUCCEEDED, "参考解法八方向实战通关：" + session.message)
	_check(encountered.size() == 8 and saw_gap and tested_pause, "遇见八波并测试波间暂停")
	if session.state == GameSession.State.SUCCEEDED:
		var finished := session.world.get_enemy_wave_status()
		_check(finished.completed == 8 and finished.pending == 0 and finished.all_cleared, "最后一个模块击毁才完成全部目标")
		_check(session.world.player.modules.all(func(module: ModuleInstance) -> bool: return module.available), "成功解法保住两个玩家模块")
		print("八方向正式参考通关耗时：%.1f 秒。" % (session.world.tick_index / 10.0))
		for entry: Dictionary in _level.document.enemies:
			_check(session.world.get_machine(entry.id).is_destroyed(), "所有敌方实际模块均已击毁")
	_check(_level.document.to_dict() == original, "运行不改写地图模板")
	var source := session.source
	var assembly := session.assembly.modules.duplicate(true)
	session.reset()
	_check(session.source == source and session.assembly.modules == assembly, "重置保留代码与装配")
	_check(session.run().is_ok(), "已完成关卡可重新运行")
	_check(session.world.tick_index == 0 and session.world.get_enemy_wave_status().completed == 0 and session.world.get_enemy_wave_status().pending == 7, "重试恢复完整八波及初始时间")
	session.stop()


## 不射击不会自动通关；敌人仍用真实近战伤害击败玩家，重试恢复耐久。
func _test_failure_retry() -> void:
	var session := _session()
	session.source = "main() {\n}\n"
	_check(session.run().is_ok(), "空程序可开始观测敌人")
	for unused in 120:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.FAILED and not session.world.failure_reason.is_empty(), "不防守时由实际近战导致失败")
	_check(session.world.get_enemy_wave_status().completed == 0 and session.consecutive_failures == 1, "失败不算击毁任何波次且只记录一次")
	session.source = _reference
	_check(session.run().is_ok(), "失败后可用原装配重试")
	_check(session.world.player.modules.all(func(module: ModuleInstance) -> bool: return module.available), "重试恢复玩家模块")
	session.stop()


## 整体截止时间只从模拟 tick 读取，暂停不消耗关卡时限。
func _test_timeout() -> void:
	var changed := _level.document.duplicate_document()
	changed.properties.level.max_ticks = 1
	var session := _session(LevelDefinition.from_document(changed, _content).value)
	_check(session.run().is_ok(), "短时限测试启动")
	session.step()
	_check(session.state == GameSession.State.FAILED and session.message.contains("八个方向"), "超时反馈准确描述八方向扫描")


## 用普通装配 API 建立建议组合，第三个模块仍受到数量上限约束。
func _session(level: LevelDefinition = null) -> GameSession:
	var session := GameSession.create(_level if level == null else level, _content)
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "中心安装测距")
	_check(session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "右侧安装射击")
	_check(not session.assembly.add_module("movement", Vector2(-0.5, 0), "drive").is_ok(), "不允许第三个模块")
	session.source = _reference
	return session


## 收集失败原因，供统一回归入口判定结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 打印完成标记并以失败数决定退出码。
func _finish() -> void:
	print("第十二关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
