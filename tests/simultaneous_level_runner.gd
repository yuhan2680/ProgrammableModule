extends SceneTree
## 以真实第八关验证双警报同帧解除、移动禁令、目标及重试，不读写玩家存档。

const SOLUTION := "main() {\n    simultaneously {\n        left.attack(180)\n        right.attack(0)\n    }\n    move(90, 6)\n}\n"
const SPAWN := Vector2(5.5, 7.5)
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 引擎初始化后加载生产关卡和注册内容。
func _initialize() -> void:
	_run.call_deferred()


## 用独立真实会话覆盖教学成功路径及容易混淆的失败边界。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第八关内容加载成功"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_008.json", _content, true)
	if not _check(loaded.is_ok(), "生产第八关地图合法：" + str(loaded.errors)):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "生产第八关规则合法：" + str(defined.errors)):
		quit(1)
		return
	_level = defined.value
	_test_design_and_unlocks()
	_test_solution()
	_test_alarm_failures()
	_test_pause_and_retry()
	_test_preflight()
	_test_validation()
	print("第八关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 真实布局、三模块上限和前七关解锁保持与教学设计一致。
func _test_design_and_unlocks() -> void:
	_check(_level.id == "level_008" and _level.order == 8 and _level.module_limit == 3, "稳定第八关 ID、排序与三模块上限")
	_check(_level.allow_simultaneous and _level.allow_named_calls and _level.allow_conditionals and _level.allow_loops and _level.allow_tick, "新能力开放且保留已学能力")
	_check(_level.goal_type == "escape_alarms" and _level.goal_alarm_ids == PackedStringArray(["alarm_left", "alarm_right"]), "目标绑定真实双警报")
	_check(_level.goal_position == Vector2(5.5, 1.5), "出口在出生点上方六格")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("shooting", Vector2(1.5, 0)).is_ok(), "装配公开接口拒绝第四个模块")
	_check(session.assembly.build_document().is_ok(), "真实中心近战及右侧两模块形成合法连续装配")
	_check(not _level.starter_program.contains("attack") and not _level.starter_program.contains("simultaneously"), "初始 main 框架不预填答案")
	for number in range(1, 8):
		var read := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(read.is_ok(), "旧关卡 %d 地图仍可加载" % number):
			continue
		var previous := LevelDefinition.from_document(read.value, _content)
		if not _check(previous.is_ok(), "旧关卡规则仍合法"):
			continue
		var prior: LevelDefinition = previous.value
		_check(not prior.allow_simultaneous, "前七关没有提前开放 simultaneously")
		_check(not ProgramParser.parse(SOLUTION, prior.allowed_calls, prior.allow_tick, prior.allow_named_calls, prior.allow_loops, prior.allow_conditionals, prior.allow_simultaneous).is_ok(), "旧关卡拒绝新语法")


## 双警报必须同一 tick 清除，开门后仍须真实移动进入出口才通关一次。
func _test_solution() -> void:
	var before := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "合法同步越狱程序启动"):
		return
	var completions: Array[int] = []
	# 用途：记录唯一胜利通知，避免后续刷新重复写入进度。
	session.completed.connect(func() -> void: completions.append(1))
	_check(session.world.tick_index == 0 and session.world.player.position == SPAWN, "启动只排队，不提前伤害或移动")
	for gate_id: String in ["exit_gate", "exit_gate_right"]:
		var gate := session.world.get_object(gate_id)
		_check(gate != null and gate.definition.rect.size == Vector2.ONE and gate.is_blocking(0), "出口使用正常一格门锁并初始锁住")
	_check(session.world.get_object("exit_gate").definition.rect.end.x == session.world.get_object("exit_gate_right").definition.rect.position.x, "两扇门共边封住通道且不重叠")
	_check(session.world.get_object("alarm_left").definition.rect.get_center() == SPAWN + Vector2(-2, 0), "左警报实际位于两格处")
	_check(session.world.get_object("alarm_right").definition.rect.get_center() == SPAWN + Vector2(3, 0), "右警报实际位于三格处")
	session.step()
	_check(_alarms_cleared(session) and session.world.tick_index == 1, "同一真实 tick 双攻击完成并解除警报")
	_check(session.world.failure_reason.is_empty() and not session.world.player.is_destroyed(), "同帧双目标伤害不会误报警")
	_check(not session.world.get_object("exit_gate").is_blocking(1) and not session.world.get_object("exit_gate_right").is_blocking(1), "双警报解除后两扇安全门同时解锁")
	_check(session.world.player.position == SPAWN and session.state == GameSession.State.RUNNING and completions.is_empty(), "同帧攻击后没有提前移动或通关")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "解除警报再上行能够实际通关：" + session.message)
	_check(session.world.player.position.distance_to(_level.goal_position) <= _level.goal_radius + 0.00001, "胜利发生在真实出口范围")
	_check(completions.size() == 1 and not session.world.player.is_destroyed(), "安全逃生只通知一次")
	var final_tick := session.world.tick_index
	for unused in 6:
		session.step()
	_check(session.world.tick_index == final_tick and completions.size() == 1, "终态冻结所有动作")
	_check(JSON.stringify(_level.document.to_dict()) == before and session.source == SOLUTION, "运行保持静态地图和玩家源码不变")
	var stationary := _session(SOLUTION.replace("    move(90, 6)\n", ""))
	if _check(stationary.run().is_ok(), "只解除警报的程序可以尝试"):
		_finish(stationary)
		_check(_alarms_cleared(stationary) and stationary.state == GameSession.State.FAILED and stationary.world.player.position == SPAWN, "仅开门不算通关，并提示继续向上")


## 先后拆除、提前移动、同步移动都触发警报，不给下一 tick 补救宽限。
func _test_alarm_failures() -> void:
	var attempts := [
		"main(){\nleft.attack(180)\nright.attack(0)\nmove(90,6)\n}",
		"main(){\nright.attack(0)\nleft.attack(180)\nmove(90,6)\n}",
		"main(){move(90,6)}",
		"main(){\nsimultaneously {\nleft.attack(180)\nright.attack(0)\nmove(90,6)\n}\n}"
	]
	for source in attempts:
		var session := _session(source)
		if not _check(session.run().is_ok(), "错误策略也允许真实尝试"):
			continue
		session.step()
		_check(session.state == GameSession.State.FAILED and session.world.tick_index == 1, "第一帧就反馈报警失败：" + source)
		_check(not session.world.failure_reason.is_empty(), "失败来自世界真实报警条件")
		var tick := session.world.tick_index
		for unused in 4:
			session.step()
		_check(session.world.tick_index == tick, "失败后不允许继续补打或越过出口")
		_check(session.source == source and session.assembly.modules.size() == 3, "教学失败保留代码和装配")


## 暂停冻结并行动作；失败重试或重置重新创建完整警报与门禁。
func _test_pause_and_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停案例可启动"):
		return
	session.pause()
	for unused in 10:
		session.step()
	_check(session.world.tick_index == 0 and not _alarms_cleared(session), "提交后暂停不会推进并行组")
	session.resume()
	session.step()
	_check(_alarms_cleared(session), "恢复提交的原并行组，两个警报同时解除")
	var old_world := session.world
	session.reset()
	_check(session.world == null and session.runner == null and session.state == GameSession.State.EDITING, "重置释放并行运行世界")
	_check(session.source == SOLUTION and session.assembly.modules[0].id == "left", "重置保留源码与具名装配")
	session.source = "main(){left.attack(180)}"
	if _check(session.run().is_ok(), "重置后可尝试顺序错误"):
		session.step()
		_check(session.state == GameSession.State.FAILED, "真实错误导致失败")
	session.source = SOLUTION
	if not _check(session.run().is_ok(), "失败后改正代码可重新运行"):
		return
	_check(session.world != old_world and session.world.tick_index == 0 and session.world.failure_reason.is_empty(), "重试创建无报警的新世界")
	_check(not _alarms_cleared(session) and session.world.get_object("exit_gate").is_blocking(0) and session.world.get_object("exit_gate_right").is_blocking(0), "重试恢复警报与两扇关闭安全门")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "重置及失败重试后仍能通关")


## 后置无效模块或共享资源冲突须整树拒绝，不能先执行之前的合法攻击。
func _test_preflight() -> void:
	for bad in ["missing.attack(0)", "drive.attack(0)", "left.attack(0)"]:
		var source := "main(){\nleft.attack(180)\nsimultaneously {\nleft.attack(180)\n%s\n}\n}" % bad
		var session := _session(source)
		_check(not session.run().is_ok() and session.state == GameSession.State.FAILED, "同步块预检拒绝错误：" + bad)
		_check(session.current_line > 0 and session.message.contains("列"), "错误定位保留可读行列")
		if session.world != null:
			_check(session.world.tick_index == 0 and not _alarms_cleared(session) and session.world.get_object("alarm_left").health == 1, "后置错误不造成任何提前伤害")


## 新开关及复合目标严格验证纯 JSON 类型和对象引用，失败不污染输入快照。
func _test_validation() -> void:
	for value in [0, 1, "true", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_simultaneous = value
		_reject(document, "并行权限拒绝非布尔值")
	for value in [null, [], ["alarm_left"], ["alarm_left", "alarm_left"], ["alarm_left", "missing"], ["alarm_left", "exit_gate"], [true, "alarm_right"], ["alarm_left", "alarm_right", "exit_gate"], {}]:
		var document := _level.document.duplicate_document()
		document.properties.level.goal.alarm_ids = value
		_reject(document, "双警报目标拒绝缺失、重复和错误引用")
	var without := _level.document.duplicate_document()
	without.properties.level.goal.erase("alarm_ids")
	_reject(without, "双警报目标不能省略绑定")
	var missing_flag := _level.document.duplicate_document()
	missing_flag.properties.level.erase("allow_simultaneous")
	var defined := LevelDefinition.from_document(missing_flag, _content)
	_check(defined.is_ok() and not defined.value.allow_simultaneous, "导入地图默认不开放新语法")


## 校验失败后核对传入的地图未被任何清理或默认填充改写。
func _reject(document: MapDocument, reason: String) -> void:
	var before := JSON.stringify(document.to_dict())
	_check(not LevelDefinition.from_document(document, _content).is_ok(), reason)
	_check(JSON.stringify(document.to_dict()) == before, "非法输入保持不变")


## 通过真实公开接口组装向右伸展的三个独立具名模块。
func _session(source: String) -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "进入第八关仍从空装配开始")
	_check(session.assembly.add_module("melee", Vector2.ZERO, "left").is_ok(), "中心安装 left 近战")
	_check(session.assembly.add_module("movement", Vector2(0.5, 0), "drive").is_ok(), "右侧共边安装 drive")
	_check(session.assembly.add_module("melee", Vector2(1, 0), "right").is_ok(), "末端共边安装 right 近战")
	session.source = source
	return session


## 只读取两个真实对象，测试不自行模拟或修改警报行为。
func _alarms_cleared(session: GameSession) -> bool:
	return session.world.get_object("alarm_left").health <= 0 and session.world.get_object("alarm_right").health <= 0


## 限步执行真实会话，防止解释器卡住后测试无期限等待。
func _finish(session: GameSession) -> void:
	for unused in 120:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第八关应在有限步数内结束")


## 汇总检查并向命令行暴露失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
