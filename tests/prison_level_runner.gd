extends SceneTree
## 第五关通过真实地图、装配、解释器和会话验证越狱顺序，不改写玩家存档。

const SOLUTION := "main() {\n    left.attack(180)\n    right.attack(0)\n    move(90, 5)\n}\n"
const SIMULTANEOUS := "main() {\n    left.attack(180)\n    move(90, 5)\n}\ntick() {\n    right.attack(0)\n}\n"
const SPAWN := Vector2(4.5, 6.5)
const MAX_TICKS := 120
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待引擎初始化后加载实际第五关，测试不使用替代关卡或模拟器。
func _initialize() -> void:
	_run.call_deferred()


## 每个场景使用独立会话，以真实动作核对成功、失败和重试边界。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第五关所需真实内容可加载"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_005.json", _content, true)
	if not _check(loaded.is_ok(), "第五关 JSON 可通过地图校验"):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "越狱目标和命名调用配置合法"):
		quit(1)
		return
	_level = defined.value
	_test_design()
	_test_metadata_validation()
	_test_solution()
	_test_alarm_first()
	_test_exit_lock()
	_test_pause_retry()
	_test_named_errors()
	_test_named_movement_and_shooting()
	_test_same_tick()
	_test_broadcast_compatibility()
	_test_unlocks()
	print("第五关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 核对第五关明确的三模块上限、两侧目标、出口和按关卡解锁的命名调用。
func _test_design() -> void:
	_check(_level.id == "level_005" and _level.order == 5, "第五关保持稳定 ID 和排序")
	_check(_level.module_limit == 3 and _level.allow_named_calls and _level.allow_tick, "三模块、命名调用和已学 tick 在第五关开放")
	_check(_level.goal_type == "escape_prison" and _level.goal_enemy_id == "guard" and _level.goal_object_id == "alarm", "越狱目标同时引用真实警卫和警报器")
	_check(_level.goal_position.is_equal_approx(Vector2(4.5, 1.5)), "出口位于出生点正上方五格")
	_check(_level.document.enemies.size() == 1 and _level.document.enemies[0].behavior == "alarm_guard", "关卡使用明确的警报警卫行为")
	var enemy: Dictionary = _level.document.enemies[0]
	_check(Vector2(float(enemy.position.x), float(enemy.position.y)).is_equal_approx(SPAWN + Vector2(-2, 0)), "警卫处于出生点左侧两格")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("shooting", Vector2(1, 0)).is_ok(), "公开装配模型也不能绕过三模块上限")
	_check(session.assembly.build_document().is_ok(), "中心驱动与左右近战的完整出生占地可运行")


## 先打警卫再拆警报器仅解除门禁，玩家实际进入出口后才发出唯一胜利信号。
func _test_solution() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "合法命名程序通过整树预检并开始运行"):
		return
	var completed: Array[int] = []
	# 用途：只记录完成通知，检查关卡结束后不会重复写入通关事件。
	session.completed.connect(func() -> void: completed.append(1))
	_check(session.world.tick_index == 0 and session.world.player.position == SPAWN, "启动只排队，不提前推进或攻击")
	_check(session.world.get_object("alarm").definition.rect.get_center().is_equal_approx(SPAWN + Vector2(2, 0)), "警报器实际位于出生点右侧两格")
	session.step()
	_check(session.world.get_machine("guard").is_destroyed() and session.world.get_object("alarm").health > 0, "首条命名攻击只摧毁警卫，警报器仍完整")
	_check(session.world.player.get_module("left").next_attack_tick > 0 and session.world.player.get_module("right").next_attack_tick == 0, "指定左模块攻击不会让右模块进入冷却")
	_check(session.state == GameSession.State.RUNNING and not session.world.player.is_destroyed(), "先消灭警卫不触发处决或提前胜利")
	session.step()
	_check(session.world.get_object("alarm").health == 0 and session.world.get_machine("guard").is_destroyed(), "第二条命名攻击解除警报器")
	_check(session.state == GameSession.State.RUNNING and session.world.player.position == SPAWN and completed.is_empty(), "两个目标都被摧毁时仍需真正离开监狱")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED and not session.world.player.is_destroyed(), "出口解锁后向上移动可安全通关")
	_check(session.world.player.position.distance_to(_level.goal_position) <= _level.goal_radius + 0.00001, "胜利位置确实落在出口半径内")
	var final_tick := session.world.tick_index
	for unused in 5:
		session.step()
	_check(completed.size() == 1 and session.world.tick_index == final_tick, "胜利只通知一次，后续 step 不继续执行")
	_check(session.source == SOLUTION and JSON.stringify(_level.document.to_dict()) == original, "运行不回写静态警卫、警报器、门禁或玩家程序")


## 警报器先毁时同一 tick 结束就处决所有玩家模块，不能继续补打警卫。
func _test_alarm_first() -> void:
	var source := "main() {\n    right.attack(0)\n    left.attack(180)\n    move(90, 5)\n}\n"
	var session := _session(source)
	if not _check(session.run().is_ok(), "错误攻击顺序是可运行的教学尝试"):
		return
	session.step()
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 1, "警报先毁在当帧判定失败，无额外宽限 tick")
	_check(session.world.get_object("alarm").health == 0 and not session.world.get_machine("guard").is_destroyed(), "失败保留真实的警报损坏和存活警卫状态")
	var all_destroyed := true
	for module in session.world.player.modules:
		all_destroyed = all_destroyed and not module.available and module.health == 0
	_check(all_destroyed and session.world.player.is_destroyed(), "警卫处决整台玩家机器，而非只破坏一个模块")
	_check(session.source == source and session.assembly.modules.size() == 3, "失败保留可修改的源码与三模块装配")
	for unused in 3:
		session.step()
	_check(session.world.tick_index == 1 and not session.world.get_machine("guard").is_destroyed(), "失败后后续攻击不会继续执行")
	# 修正同一个会话中的程序，应重新生成世界并恢复所有目标和玩家模块。
	session.source = SOLUTION
	if not _check(session.run().is_ok(), "失败后修改顺序可直接重新运行"):
		return
	_check(session.world.tick_index == 0 and session.world.get_object("alarm").health > 0 and not session.world.get_machine("guard").is_destroyed() and not session.world.player.is_destroyed(), "失败重试恢复双方耐久及未破坏警报器")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "同一失败会话修正顺序后可真正通关")


## 门禁要求两个目标同时解除，直奔出口或只拆一个目标均不能绕过教学。
func _test_exit_lock() -> void:
	for source in ["main(){move(90,5)}", "main(){\nleft.attack(180)\nmove(90,5)\n}"]:
		var session := _session(source)
		if not _check(session.run().is_ok(), "未完全解除门禁时仍可尝试向上移动"):
			continue
		_finish(session)
		_check(session.state == GameSession.State.FAILED and session.world.player.position.y > 5.0, "闭合门禁通过真实占地扫掠阻止越过出口")
		_check(session.world.get_object("alarm").health > 0 and not session.world.player.is_destroyed(), "门禁阻挡不会伪造警报拆除或处决伤害")
	var stopped := _session("main(){\nleft.attack(180)\nright.attack(0)\n}")
	if not _check(stopped.run().is_ok(), "仅拆除两个目标的程序可以执行"):
		return
	for unused in 3:
		stopped.step()
	_check(stopped.world.get_machine("guard").is_destroyed() and stopped.world.get_object("alarm").health == 0, "无移动尝试确实已拆除全部目标")
	_check(stopped.state != GameSession.State.SUCCEEDED and stopped.world.player.position == SPAWN, "没有走到出口不能获得越狱胜利")


## 暂停同时冻结玩家动作、门禁和冷却；重置恢复初态但保留手工命名与代码。
func _test_pause_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停测试中的越狱程序可以启动"):
		return
	session.step()
	var first_world := session.world
	var cooldown := first_world.player.get_module("left").next_attack_tick
	session.pause()
	for unused in 8:
		session.step()
	_check(session.state == GameSession.State.PAUSED and first_world.tick_index == 1 and first_world.player.position == SPAWN, "暂停不推进世界时间或玩家位置")
	_check(first_world.get_machine("guard").is_destroyed() and first_world.get_object("alarm").health > 0 and first_world.player.get_module("left").next_attack_tick == cooldown, "暂停保留警卫状态、完整警报器和模块冷却")
	session.resume()
	session.step()
	_check(first_world.tick_index == 2 and first_world.get_object("alarm").health == 0, "恢复只执行原程序的下一条攻击")
	session.reset()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "重置释放旧世界和命令")
	_check(session.source == SOLUTION and session.assembly.modules[1].id == "left" and session.assembly.modules[2].id == "right", "重置保留源码及真实实例名")
	if not _check(session.run().is_ok(), "重置后原越狱程序仍可启动"):
		return
	_check(session.world != first_world and session.world.tick_index == 0 and session.world.player.position == SPAWN, "重试从新的出生世界开始")
	_check(not session.world.get_machine("guard").is_destroyed() and session.world.get_object("alarm").health > 0 and session.world.player.get_module("left").next_attack_tick == 0, "重试恢复警卫、警报器与冷却")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "暂停和重置不破坏后续通关")


## 命名错误在整份程序预检时报告，后置错误也不能让前面的合法攻击先执行。
func _test_named_errors() -> void:
	for bad_call in ["missing.attack(0)", "Left.attack(180)", "drive.attack(0)", "left.move(90,1)", "right.shoot(0)"]:
		var source := "main() {\n    left.attack(180)\n    %s\n}\n" % bad_call
		var session := _session(source)
		_check(not session.run().is_ok() and session.state == GameSession.State.FAILED, "不存在、大小写不符或缺少能力的命名调用被拒绝：" + bad_call)
		_check(session.current_line == 3 and session.message.contains("列"), "命名调用错误保留准确源码行列")
		if session.world != null:
			_check(session.world.tick_index == 0 and session.world.player.position == SPAWN and not session.world.get_machine("guard").is_destroyed() and session.world.get_object("alarm").health > 0, "运行前检查失败不会部分推进或造成伤害")
		_check(session.source == source and session.assembly.modules.size() == 3, "错误诊断不会修改玩家程序或装配")
	var callback := _session("main(){left.attack(180)}\ntick(){\nmissing.attack(0)\n}")
	_check(not callback.run().is_ok() and callback.current_line == 3, "tick 内的缺失实例也在 main 首次执行前报告")
	if callback.world != null:
		_check(callback.world.tick_index == 0 and not callback.world.get_machine("guard").is_destroyed(), "无效 tick 不能让合法 main 偷跑一次攻击")


## 命名移动只汇总指定驱动，命名射击只消耗指定枪的冷却，旧广播仍影响全部同类模块。
func _test_named_movement_and_shooting() -> void:
	for named in [true, false]:
		var moving := GameSession.create(_level, _content)
		_check(moving.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "移动选择性测试手动安装中心驱动")
		_check(moving.assembly.add_module("movement", Vector2(-0.5, 0), "second").is_ok(), "移动选择性测试安装第二个共边驱动")
		moving.source = "main(){%smove(90,1)}" % ("drive." if named else "")
		if not _check(moving.run().is_ok(), "命名与广播移动程序均能运行"):
			continue
		moving.step()
		var expected_distance := 0.1 if named else 0.2
		_check(is_equal_approx(SPAWN.y - moving.world.player.position.y, expected_distance), "指定驱动只贡献自身速度，广播仍叠加两个驱动的速度")
		_check(moving.world.player.get_move_speed() == 2.0, "命名调用不会破坏机器其余驱动的能力")
		moving.stop()
		var shooting := GameSession.create(_level, _content)
		_check(shooting.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "射击选择性测试手动安装中心驱动")
		_check(shooting.assembly.add_module("shooting", Vector2(-0.5, 0), "left").is_ok() and shooting.assembly.add_module("shooting", Vector2(0.5, 0), "right").is_ok(), "射击选择性测试安装两个独立命名枪模块")
		shooting.source = "main(){%sshoot(0)}" % ("left." if named else "")
		if not _check(shooting.run().is_ok(), "命名与广播射击程序均能运行"):
			continue
		shooting.step()
		_check(shooting.world.projectiles.size() == (1 if named else 2), "命名只生成指定枪的弹丸，广播会生成两颗")
		_check(shooting.world.player.get_module("left").next_shoot_tick > 0 and (shooting.world.player.get_module("right").next_shoot_tick == 0) == named, "指定射击不消耗其他枪的冷却，广播共享原有逐模块冷却规则")
		shooting.stop()


## main 和 tick 同帧击毁两个目标时，警报判定必须读取统一提交后的双方状态。
func _test_same_tick() -> void:
	var session := _session(SIMULTANEOUS)
	if not _check(session.run().is_ok(), "已解锁 main 与 tick 可分别控制两个近战模块"):
		return
	session.step()
	_check(session.world.tick_index == 1 and session.world.get_machine("guard").is_destroyed() and session.world.get_object("alarm").health == 0, "同一 tick 内两个独立命名攻击都完成")
	_check(session.state == GameSession.State.RUNNING and not session.world.player.is_destroyed(), "原子伤害提交后两目标同时已毁，不误判警报先毁")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "合法的同时解除方案也可从出口逃脱")


## 不带接收者的旧广播调用保持有效，命名扩展不强制替换已学的玩法。
func _test_broadcast_compatibility() -> void:
	var session := _session("main(){\nattack(180)\nattack(0)\nmove(90,5)\n}")
	if not _check(session.run().is_ok(), "第五关仍允许广播攻击和移动"):
		return
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "原有广播指令按照相同目标顺序仍能通关")


## 前四关继续限制命名调用，前三关不提前开放射击或 tick，第四关保留原解锁。
func _test_unlocks() -> void:
	for index in range(1, 5):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, _content, true)
		if not _check(loaded.is_ok(), "兼容检查可读取原有关卡 %d" % index):
			continue
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "前四关规则仍可解析"):
			continue
		var previous: LevelDefinition = defined.value
		_check(not previous.allow_named_calls, "前四关不因第五关加入而提前开放命名调用")
		var session := GameSession.create(previous, _content)
		_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "原关卡可手动安装并命名移动模块")
		session.source = "main(){drive.move(0,1)}"
		_check(not session.run().is_ok() and session.world == null, "未解锁命名调用在创建世界前拒绝")
		_check(previous.allow_tick == (index == 4) and previous.allowed_calls.has("shoot") == (index == 4), "仅原第四关保留射击和 tick 权限")
		_check(previous.allowed_calls.has("attack") == (index >= 3), "近战权限仍从第三关开放")


## 复合目标与命名开关严格校验类型和引用，失败不得修改输入快照或原关卡。
func _test_metadata_validation() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	for value in [0, 1, "true", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_named_calls = value
		_reject_unchanged(document, "allow_named_calls 拒绝非布尔值 " + str(value))
	for field in ["enemy_id", "object_id"]:
		var missing := _level.document.duplicate_document()
		missing.properties.level.goal.erase(field)
		_reject_unchanged(missing, "越狱目标不能省略 " + field)
		for value in ["unknown_target", "", true, 1, [], {}, null]:
			var document := _level.document.duplicate_document()
			document.properties.level.goal[field] = value
			_reject_unchanged(document, "越狱目标拒绝未知或错误类型的 " + field + "：" + str(value))
	# 这些引用在地图中确实存在，但指向错误类别，不能被当作合法的越狱目标。
	var wrong_enemy := _level.document.duplicate_document()
	wrong_enemy.properties.level.goal.enemy_id = "alarm"
	_reject_unchanged(wrong_enemy, "enemy_id 不能指向实际警报对象")
	var wrong_object := _level.document.duplicate_document()
	wrong_object.properties.level.goal.object_id = "exit_gate_1"
	_reject_unchanged(wrong_object, "object_id 不能指向实际安全门")
	var ordinary_object := _level.document.duplicate_document()
	ordinary_object.objects[0].type = "destructible"
	_check(MapCodec.validate(ordinary_object, _content, true).is_ok(), "普通可破坏对象夹具在地图层仍合法")
	_reject_unchanged(ordinary_object, "正确 ID 的普通障碍也不能代替 prison_alarm")
	# 第二名警卫是真实合法实体，排除悬空引用错误，专门检查复合目标的绑定一致性。
	var mismatched := _level.document.duplicate_document()
	var other_guard: Dictionary = mismatched.enemies[0].duplicate(true)
	other_guard.id = "other_guard"
	other_guard.position = {"x": 1.5, "y": 6.5}
	mismatched.enemies.append(other_guard)
	mismatched.objects[0].properties.guard_id = "other_guard"
	_check(MapCodec.validate(mismatched, _content, true).is_ok(), "不同警卫绑定夹具在地图层引用完整且合法")
	_reject_unchanged(mismatched, "目标警卫和警报器实际 guard_id 必须匹配")
	var missing_exit := _level.document.duplicate_document()
	missing_exit.properties.level.goal.erase("position")
	_reject_unchanged(missing_exit, "越狱目标不能省略出口位置")
	for position in [null, [], "4.5,1.5", {"y": 1.5}, {"x": true, "y": 1.5}, {"x": -0.5, "y": 1.5}, {"x": 9.0, "y": 1.5}, {"x": 4.5, "y": 9.0}, {"x": 0.5, "y": 0.5}, {"x": 3.0, "y": 1.5}]:
		var document := _level.document.duplicate_document()
		document.properties.level.goal.position = position
		_reject_unchanged(document, "出口拒绝非法坐标、地图外、void 或半径包含 void：" + str(position))
	_check(JSON.stringify(_level.document.to_dict()) == original, "所有负例都基于独立快照，生产关卡始终不变")


## 统一验证每个失败不突变其输入文档，也不通过共享引用改写原第五关。
func _reject_unchanged(document: MapDocument, reason: String) -> void:
	var input_snapshot := JSON.stringify(document.to_dict())
	var original_snapshot := JSON.stringify(_level.document.to_dict())
	_check(not LevelDefinition.from_document(document, _content).is_ok(), reason)
	_check(JSON.stringify(document.to_dict()) == input_snapshot and JSON.stringify(_level.document.to_dict()) == original_snapshot, "校验失败不改写输入或原关卡：" + reason)


## 通过玩家公开接口创建真实三模块装配，拒绝隐式使用地图出生模板。
func _session(source: String) -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "第五关每次进入都从空装配开始")
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "手动安装中心移动模块 drive")
	_check(session.assembly.add_module("melee", Vector2(-0.5, 0), "left").is_ok(), "手动安装左侧共边近战模块 left")
	_check(session.assembly.add_module("melee", Vector2(0.5, 0), "right").is_ok(), "手动安装右侧共边近战模块 right")
	session.source = source
	return session


## 用有限步数推进实际会话，任何程序停滞都明确失败而不阻塞整组回归。
func _finish(session: GameSession) -> void:
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第五关有限越狱程序应在一百二十 tick 内结束")


## 汇总断言并输出非零退出码，让测试包装器发现逻辑错误和脚本异常。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
