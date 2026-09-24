extends SceneTree
## 第十三关通过真实装配、雷达与弹丸验证随机十波，禁止代扣血通关。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _source := ""


## 等待类注册后运行数据与实战验证。
func _initialize() -> void:
	_run.call_deferred()


## 正式数据独立载入，种子仅写入测试副本。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "内容可加载")
	var loaded := MapCodec.load_file("res://data/levels/level_013.json", _content, true)
	if not _check(loaded.is_ok(), "第十三关地图有效：" + str(loaded.errors)):
		_finish()
		return
	var defined := LevelDefinition.from_document(loaded.value, _content, "res://data/levels/level_013.json")
	if not _check(defined.is_ok(), "第十三关定义有效：" + str(defined.errors)):
		_finish()
		return
	_level = defined.value
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_013.json"))
	_source = str(hint.source).replace("{{radar}}", "radar").replace("{{gun}}", "gun")
	_check(_level.display_name == "第十三关 · 十面埋伏" and _level.order == 13 and _level.module_limit == 2 and _level.goal_type == "destroy_waves", "名称、顺序、数量及目标符合要求")
	_check(_level.allow_radar and _level.allow_random and _level.allow_for and _level.allow_functions, "继承已有权限")
	_check(_level.document.enemies.size() == 10, "正式地图十波")
	for entry in _level.document.enemies:
		_check(not entry.properties.random_spawn.has("seed") and entry.properties.module_health == {"blade": 2.0, "engine": 2.0} and entry.properties.wreck_fade_seconds == 3.0, "正式敌人血量、淡出及无固定种子")
	_test_validation()
	var template := _level.document.to_dict()
	for sample in range(32):
		_test_battle(sample)
	_check(_level.document.to_dict() == template, "测试没有污染静态地图")
	_test_failure_pause_and_spawn()
	_test_fade_and_retry()
	_test_hint()
	_finish()


## 候选装配仍走正式 API，不允许第三个模块或自动装配。
func _session(sample: int = -1) -> GameSession:
	var level := _level
	if sample >= 0:
		var document := _level.document.duplicate_document()
		for entry in document.enemies:
			entry.properties.random_spawn.seed = sample
		level = LevelDefinition.from_document(document, _content).value
	var session := GameSession.create(level, _content)
	_check(session.assembly.modules.is_empty(), "先空装配")
	_check(session.assembly.add_module("radar", Vector2.ZERO, "radar").is_ok(), "中心安装雷达")
	_check(session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "右侧安装射击")
	_check(not session.assembly.add_module("movement", Vector2(-0.5, 0), "drive").is_ok(), "限制两个模块")
	session.source = _source
	return session


## 随机角度使用普通程序真实完成十波；记录每波并验证无重叠、无幽灵目标。
func _test_battle(sample: int) -> void:
	var session := _session(sample)
	if not _check(session.run().is_ok(), "真实战斗开始 %d" % sample):
		return
	var seen := {}
	var off_axis := false
	for unused in _level.max_ticks:
		var status := session.world.get_enemy_wave_status()
		if status.active and not seen.has(status.active_enemy_id):
			var enemy := session.world.get_machine(status.active_enemy_id)
			seen[enemy.id] = true
			_check(enemy.modules.all(func(module: ModuleInstance) -> bool: return module.health == 2.0), "出生耐久为2.0")
			_check(MachineFactory.validate_placement(enemy, session.world.document, _content).is_ok(), "随机真实占地合法")
			var angle: float = session.world.query_scan("player", "radar").value.angle
			off_axis = off_axis or absf(angle / 45.0 - roundf(angle / 45.0)) > 0.01
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "雷达参考程序真实通关 %d: %s tick=%d status=%s" % [sample, session.message, session.world.tick_index, session.world.get_enemy_wave_status()])
	_check(seen.size() == 10 and off_axis, "十波均实际出场，含非八方向角度")
	_check(session.world.player.position == Vector2(9.5, 9.5) and session.world.player.modules.all(func(module: ModuleInstance) -> bool: return module.available), "驻守未受损，无脚本瞬移")
	session.stop()


## 坏配置在执行前拒绝；共享模块定义不被加血或扩大。
func _test_validation() -> void:
	for pair: Array in [["wreck_fade_seconds", 0], ["wreck_fade_seconds", INF], ["wreck_fade_seconds", true], ["random_spawn", []], ["random_spawn", {"center": {"x": NAN, "y": 0}}]]:
		var entry: Dictionary = _level.document.enemies[0].duplicate(true)
		entry.properties[pair[0]] = pair[1]
		_check(not EnemyDefinition.validate(entry, _content).is_ok(), "拒绝非法配置：" + str(pair))
	_check(_content.get_module("movement").size == Vector2(0.5, 0.5) and _content.get_module("melee").size == Vector2(0.5, 0.5), "不扩大共享碰撞体")


## 显示帧只淡化已毁整机，暂停冻结，重试清空；战斗数据不会被显示删除。
func _test_fade_and_retry() -> void:
	var session := _session(73)
	_check(session.run().is_ok(), "淡出测试启动")
	var canvas := MapCanvas.new()
	canvas.world = session.world
	canvas.document = session.world.document
	canvas.registry = _content
	root.add_child(canvas)
	canvas.wreck_animation_enabled = true
	var enemy := session.world.get_machine("wave_01")
	enemy.get_module("blade").apply_damage(2)
	canvas.refresh()
	canvas._process(4.0)
	_check(canvas.enemy_wreck_opacity(enemy) == 1.0, "残存模块不触发整机消失")
	enemy.get_module("engine").apply_damage(2)
	session.step()
	canvas.refresh()
	var progress := session.world.get_enemy_wave_status()
	canvas._process(1.5)
	_check(is_equal_approx(canvas.enemy_wreck_opacity(enemy), 0.5), "半程线性淡出")
	_check(is_equal_approx(canvas._attack_trace_opacity({"source_machine_id": enemy.id}), 0.5), "最后一道攻击光束同步淡出")
	canvas.wreck_animation_enabled = false
	canvas._process(5)
	_check(is_equal_approx(canvas.enemy_wreck_opacity(enemy), 0.5), "暂停冻结淡出")
	canvas.wreck_animation_enabled = true
	canvas._process(1.5)
	_check(canvas.enemy_wreck_opacity(enemy) == 0.0 and not canvas.is_processing(), "三秒消失并停止空刷新")
	_check(canvas._attack_trace_opacity({"source_machine_id": enemy.id}) == 0.0, "残骸消失后不留悬空光束")
	_check(session.world.get_enemy_wave_status() == progress and session.world.get_machine(enemy.id) == enemy, "显示不推进波次或删除战斗记录")
	_check(session.world.query_scan("player").value == null, "已毁残骸不被雷达扫描")
	var code := session.source
	session.reset()
	_check(session.source == code and session.run().is_ok(), "重置保留程序装配并可重新开始")
	canvas.world = session.world
	canvas.refresh()
	_check(canvas._wreck_ages.is_empty() and session.world.get_enemy_wave_status().pending == 9, "重试清空旧残骸并恢复十波")
	canvas.free()
	session.stop()


## 正式来源可逐步补齐；冒充同 ID 的导入文件仍不获得教学提示。
func _test_hint() -> void:
	var session := _session()
	session.source = _level.starter_program
	for unused in 20:
		var result := CodeHintService.next_hint(session)
		if not result.is_ok():
			_check(result.errors[0].contains("已经能够完成"), "代码提示可用：" + str(result.errors))
			break
		session.source = result.value.source
	_check(session.source.contains("scan()") and session.source.contains("shoot(aim)"), "提示补齐雷达射击方案")
	var defined := LevelDefinition.from_document(_level.document, _content, "user://levels/level_013.json")
	var imported := GameSession.create(defined.value, _content)
	_check(not CodeHintService.next_hint(imported).is_ok(), "导入同名地图仍不开放教学提示")


## 汇总可定位的失败，供统一测试入口读取。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 输出统一完成标记及退出码。
func _finish() -> void:
	print("第十三关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 暂停不重抽方向，坏随机出生占地拒绝；不瞄准的程序仍会真实失败。
func _test_failure_pause_and_spawn() -> void:
	var session := _session(73)
	session.source = "main() { loop { gun.shoot(0) } }"
	_check(session.run().is_ok(), "未瞄准对照开始")
	var enemy := session.world.get_machine("wave_01")
	var position := enemy.position
	var waves := session.world.get_enemy_wave_status()
	session.pause()
	for unused in 5:
		session.step()
		_check(enemy.position == position and session.world.get_enemy_wave_status() == waves, "暂停不移动或重抽角度")
	session.resume()
	for unused in _level.max_ticks:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.FAILED and not session.world.get_enemy_wave_status().all_cleared, "错误瞄准会失败，不能自动清波")
	session.stop()
	var bad := _level.document.duplicate_document()
	bad.enemies[9].properties.random_spawn.center = {"x": 100, "y": 100}
	_check(not SimulationWorld.create(bad, _content).is_ok(), "未来波次随机落在地图外也在建世界时拒绝")
	var fresh := _session()
	_check(fresh.run().is_ok(), "正式随机启动")
	var first_position := fresh.world.get_machine("wave_01").position
	fresh.reset()
	_check(fresh.run().is_ok() and fresh.world.get_machine("wave_01").position != first_position, "正式重试重新随机来袭方向")
	fresh.stop()
