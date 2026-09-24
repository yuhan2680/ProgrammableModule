extends SceneTree
## 第四关通过正式装配、解释器和会话验证射击入门，不读写玩家草稿。

const SOLUTION := "main() {\n}\ntick() {\n    shoot(0)\n}\n"
const MAX_TICKS := 200
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 延迟至引擎初始化完成后读取真实内容和第四关地图。
func _initialize() -> void:
	_run.call_deferred()


## 每个用例使用全新会话，确保敌人、弹丸与失败结果不会跨次运行泄漏。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第四关所需真实模块可加载"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_004.json", _content, true)
	if not _check(loaded.is_ok(), "第四关 JSON 可以加载"):
		quit(1)
		return
	var parsed := LevelDefinition.from_document(loaded.value, _content)
	if not _check(parsed.is_ok(), "第四关关卡规则有效"):
		quit(1)
		return
	_level = parsed.value
	_test_design()
	_test_solution()
	_test_enemy_approach()
	_test_failures()
	_test_pause_reset()
	_test_unlocks()
	_test_metadata_validation()
	_test_goal_deadlines()
	print("第四关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 直接核对公开设计中的六格间距、水平接近、单模块上限和摧毁敌人目标。
func _test_design() -> void:
	_check(_level.id == "level_004" and _level.order == 4, "第四关保持稳定 ID 并排在第三关之后")
	_check(_level.module_limit == 1, "第四关只允许一个模块，不能依靠叠加装配跳过教学")
	_check(_level.allowed_modules == PackedStringArray(["movement", "melee", "shooting"]), "玩家仍可尝试已学模块，第四关解锁射击")
	_check(_level.goal_type == "destroy_enemy", "通关依赖真正摧毁敌人，不使用位置终点")
	_check(_level.allowed_calls.has("shoot") and _level.allow_tick, "射击与 tick 每帧入口在第四关开放")
	_check(_level.document.enemies.size() == 1, "地图包含一台敌方机器")
	var enemy: Dictionary = _level.document.enemies[0]
	var spawn: Dictionary = _level.document.player_spawn.position
	_check(is_equal_approx(float(enemy.position.x) - float(spawn.x), 6.0) and is_equal_approx(float(enemy.position.y), float(spawn.y)), "敌人与玩家中心相距六格且处于同一水平线")
	_check(enemy.id == "guard" and enemy.behavior == "approach_attack", "目标引用有明确接近与近战行为的敌人")
	_check(is_equal_approx(float(enemy.properties.move_distance), 4.5) and is_equal_approx(float(enemy.properties.move_angle), 180.0), "敌人向左接近四点五格")
	_check(enemy.modules.size() == 2 and enemy.modules[0].module_id == "movement" and enemy.modules[1].module_id == "melee", "敌人由真实移动和近战模块组成")
	var session := _session("shooting", SOLUTION)
	_check(not session.assembly.add_module("movement", Vector2(0.5, 0)).is_ok(), "模型也拒绝第四关额外安装第二个模块")


## 一直向右射击必须通过真实弹丸命中，保留敌人静态定义和玩家源码。
func _test_solution() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	var session := _session("shooting", SOLUTION)
	if not _check(session.run().is_ok(), "空 main 配合 tick 射击可启动"):
		return
	var finished: Array[int] = []
	# 用途：记录正式完成信号次数，检查持续 tick 不会多次提交胜利。
	session.completed.connect(func() -> void: finished.append(1))
	_check(session.state == GameSession.State.RUNNING and session.world.tick_index == 0, "开始运行不提前发射或判定通关")
	var saw_projectile := false
	var saw_module_damage := false
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
		saw_projectile = saw_projectile or not session.world.projectiles.is_empty()
		var enemy := session.world.get_machine("guard")
		for module in enemy.modules:
			saw_module_damage = saw_module_damage or not module.available
	_check(saw_projectile and saw_module_damage, "射击生成世界弹丸并摧毁真实敌方模块")
	_check(session.state == GameSession.State.SUCCEEDED and session.world.get_machine("guard").is_destroyed(), "持续向右射击摧毁敌人后通关")
	_check(not session.world.player.is_destroyed() and session.world.player.position.is_equal_approx(Vector2(1.5, 2.5)), "单射击模块原地获胜且玩家仍存活")
	var final_tick := session.world.tick_index
	for unused in 10:
		session.step()
	_check(finished.size() == 1 and session.world.tick_index == final_tick, "胜利后不再推进世界，也不重复发出完成信号")
	_check(session.source == SOLUTION and JSON.stringify(_level.document.to_dict()) == original, "战斗不会修改地图敌人数据或玩家程序")


## 空 main 结束后敌人仍按模拟 tick 接近并攻击，不能靠程序提前结束冻结战场。
func _test_enemy_approach() -> void:
	var session := _session("shooting", "main(){}")
	if not _check(session.run().is_ok(), "无射击程序可以作为教学失败尝试"):
		return
	_check(session.state == GameSession.State.RUNNING, "空 main 不会结束具有存活敌人的战斗会话")
	var origin := session.world.get_machine("guard").position
	var all_horizontal := true
	var previous_x := origin.x
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
		var position := session.world.get_machine("guard").position
		all_horizontal = all_horizontal and is_equal_approx(position.y, origin.y) and position.x <= previous_x + 0.000001
		previous_x = position.x
	var guard := session.world.get_machine("guard")
	_check(all_horizontal, "敌人每个 tick 只向左移动，没有上下位移或倒退")
	_check(is_equal_approx(origin.x - guard.position.x, 4.5), "敌人实际移动四点五格后原地攻击")
	_check(session.state == GameSession.State.FAILED and session.world.player.is_destroyed(), "无射击时玩家被敌人的真实近战伤害击败")
	_check(not guard.is_destroyed(), "敌人未受攻击时不会因计时器被自动移除")


## 错误方向、只射一次和近战装配均不能获得射击关胜利。
func _test_failures() -> void:
	var cases := [
		{"module": "shooting", "program": "main(){}\ntick(){shoot(90)}", "reason": "向上射击"},
		{"module": "shooting", "program": "main(){shoot(0)}", "reason": "只在 main 提前射击一次"},
		{"module": "melee", "program": "main(){}\ntick(){attack(0)}", "reason": "只用近战模块持续攻击"},
	]
	for entry: Dictionary in cases:
		var session := _session(entry.module, entry.program)
		if not _check(session.run().is_ok(), entry.reason + "可以正常运行再观察结果"):
			continue
		_finish(session)
		_check(session.state == GameSession.State.FAILED, entry.reason + "不能通关")
		_check(not session.world.get_machine("guard").is_destroyed(), entry.reason + "不会错误摧毁目标")
		_check(session.source == entry.program and session.assembly.modules.size() == 1, "失败保留程序与装配供玩家修改")
		if entry.module == "melee":
			_check(session.world.tick_index == _level.max_ticks and not session.world.player.is_destroyed(), "仅近战打坏前方驱动后形成僵持，在十五秒练习上限结束")
			_check(is_zero_approx(session.world.get_machine("guard").get_move_speed()), "失去驱动的敌人停止移动，近战模块仍保留为未击毁目标")


## 暂停冻结敌人、弹丸和逻辑时间；重试必须创建无残余弹丸和完整敌人的世界。
func _test_pause_reset() -> void:
	var session := _session("shooting", SOLUTION)
	if not _check(session.run().is_ok(), "暂停回归中的射击会话可以启动"):
		return
	session.step()
	if not _check(not session.world.projectiles.is_empty(), "第一帧生成弹丸后再暂停"):
		return
	var first_world := session.world
	var guard_position := first_world.get_machine("guard").position
	var projectile_position := first_world.projectiles[0].position
	var projectile_speed: float = first_world.projectiles[0].speed
	var count := first_world.projectiles.size()
	var next_shot_tick: int = first_world.player.modules[0].next_shoot_tick
	session.pause()
	for unused in 12:
		session.step()
	_check(session.state == GameSession.State.PAUSED and first_world.tick_index == 1, "暂停不累计模拟 tick")
	_check(first_world.get_machine("guard").position == guard_position and first_world.projectiles.size() == count and first_world.projectiles[0].position == projectile_position and first_world.projectiles[0].speed == projectile_speed and first_world.player.modules[0].next_shoot_tick == next_shot_tick, "暂停同时冻结敌人位置、射击冷却和弹丸运动")
	session.resume()
	session.step()
	_check(first_world.tick_index == 2 and first_world.get_machine("guard").position.x < guard_position.x, "恢复后继续同一个敌人的接近动作")
	_check(first_world.projectiles[0].position.x > projectile_position.x and first_world.projectiles[0].speed < projectile_speed, "恢复后弹丸继续向右移动并减速")
	session.reset()
	_check(session.world == null and session.runner == null and session.state == GameSession.State.EDITING, "重置解除战斗世界和解释器")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 1, "重置保留射击源码与玩家装配")
	if not _check(session.run().is_ok(), "重置后同一程序可以重新启动"):
		return
	_check(session.world != first_world and session.world.tick_index == 0 and session.world.projectiles.is_empty(), "重试创建新世界，不携带旧弹丸或时间")
	var guard := session.world.get_machine("guard")
	_check(guard.position.is_equal_approx(Vector2(7.5, 2.5)), "重试敌人恢复出生点")
	for module in guard.modules:
		_check(module.available and module.health > 0, "重试所有敌方模块恢复可用和耐久")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "暂停重置后完整重试仍能获胜")


## 前三关不提前解锁射击和 tick；第四关缺少射击模块时仍给出源码行错误。
func _test_unlocks() -> void:
	for index in range(1, 4):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, _content, true)
		var previous := LevelDefinition.from_document(loaded.value, _content).value as LevelDefinition
		var locked := GameSession.create(previous, _content)
		_check(not locked.assembly.add_module("shooting", Vector2.ZERO).is_ok(), "前三关保持射击模块未解锁")
		locked.assembly.add_module("movement", Vector2.ZERO)
		locked.source = SOLUTION
		_check(not locked.run().is_ok() and locked.world == null, "前三关 tick 射击在创建世界前被拒绝")
	var missing := _session("movement", SOLUTION)
	_check(not missing.run().is_ok() and missing.current_line == 4 and missing.world.tick_index == 0, "已解锁语法仍要求真实射击模块，错误定位 shoot 行")
	var no_main := _session("shooting", "tick(){shoot(0)}")
	_check(not no_main.run().is_ok() and no_main.world == null, "第四关依然必须提供 main 入口")


## 使用玩家公开装配接口安装唯一中心模块，不能依赖出生模板偷偷预装。
func _session(module_id: String, source: String) -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "第四关每次进入先空装配")
	_check(session.assembly.add_module(module_id, Vector2.ZERO).is_ok(), "玩家可在中心安装本关允许模块")
	session.source = source
	return session


## 在明确上限内推进真实会话，失败不允许导致测试无限运行。
func _finish(session: GameSession) -> void:
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第四关应在二百 tick 内结束")


## 收集明确断言并让测试进程通过退出码报告失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 拒绝错误的敌人目标、入口开关与超时，保留可扩展地图字段。
func _test_metadata_validation() -> void:
	for value in [true, -1, 1.5, "150", 36001]:
		var document := _level.document.duplicate_document()
		document.properties.level.max_ticks = value
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "战斗时限拒绝非法类型或越界数值")
	for value in [0, 1, 36000]:
		var document := _level.document.duplicate_document()
		document.properties.level.max_ticks = value
		_check(LevelDefinition.from_document(document, _content).is_ok(), "不限时及边界时限保持合法")
	for value in [1, "true", [], null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_tick = value
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "每帧入口开关必须为布尔值")
	for value in ["missing", "", 1, true]:
		var document := _level.document.duplicate_document()
		document.properties.level.goal.enemy_id = value
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "摧毁目标必须引用真实已注册敌人")
	var extended := _level.document.duplicate_document()
	extended.enemies[0]["author_note"] = {"future": [1, 2, "保留"]}
	var roundtrip := MapCodec.from_dict(extended.to_dict(), _content, true)
	_check(roundtrip.is_ok() and JSON.stringify(roundtrip.value.enemies) == JSON.stringify(extended.enemies), "敌人扩展字段仍无损往返")


## 最后一个允许的 tick 达成位置或破障目标仍成功，普通地图超时不显示射击敌人提示。
func _test_goal_deadlines() -> void:
	var first := MapCodec.load_file("res://data/levels/level_001.json", _content, true)
	if not _check(first.is_ok(), "读取限时位置目标回归夹具"):
		return
	var document: MapDocument = first.value
	document.properties.level.goal = {"type": "reach_position", "position": {"x": 2.5, "y": 7.5}, "radius": 0.01}
	document.properties.level.max_ticks = 10
	var defined := LevelDefinition.from_document(document, _content)
	if not _check(defined.is_ok(), "位置关卡接受合法练习时限"):
		return
	var reach := GameSession.create(defined.value, _content)
	_check(reach.assembly.add_module("movement", Vector2.ZERO).is_ok(), "限时位置关卡手动安装移动模块")
	reach.source = "main(){move(0,1)}"
	if not _check(reach.run().is_ok(), "限时位置程序可以运行"):
		return
	_finish(reach)
	_check(reach.state == GameSession.State.SUCCEEDED and reach.world.tick_index == 10, "恰好第十 tick 到达终点时先判断成功，不能误报超时")
	document.properties.level.max_ticks = 1
	var limited := LevelDefinition.from_document(document, _content)
	if not _check(limited.is_ok(), "普通关卡也能设置较短合法时限"):
		return
	var expired := GameSession.create(limited.value, _content)
	expired.assembly.add_module("movement", Vector2.ZERO)
	expired.source = reach.source
	if not _check(expired.run().is_ok(), "普通关卡超时夹具可以启动"):
		return
	expired.step()
	_check(expired.state == GameSession.State.FAILED and expired.world.tick_index == 1, "尚未达到位置目标时按设置时限结束")
	_check(expired.message.contains("时间已结束") and not expired.message.contains("敌人") and not expired.message.contains("shoot"), "普通位置关卡超时给出通用提示，不误导玩家安装射击模块")
	var third := MapCodec.load_file("res://data/levels/level_003.json", _content, true)
	if not _check(third.is_ok(), "读取限时破障目标回归夹具"):
		return
	var obstacle_document: MapDocument = third.value
	obstacle_document.objects[0].position.x = 3.5
	obstacle_document.properties.level.max_ticks = 1
	var obstacle_level := LevelDefinition.from_document(obstacle_document, _content)
	if not _check(obstacle_level.is_ok(), "破障关卡接受合法练习时限"):
		return
	var attack := GameSession.create(obstacle_level.value, _content)
	_check(attack.assembly.add_module("melee", Vector2.ZERO).is_ok(), "限时破障关卡手动安装近战模块")
	attack.source = "main(){attack(0)}"
	if not _check(attack.run().is_ok(), "限时破障程序可以运行"):
		return
	attack.step()
	_check(attack.state == GameSession.State.SUCCEEDED and attack.world.tick_index == 1 and attack.world.get_object("training_obstacle").health == 0, "最后一个允许 tick 摧毁真实障碍物优先判定成功")
