extends SceneTree
## 第十一关使用正式 JSON 验证函数闪避、雷达锁定、真实出手计数、暂停重试及旧关兼容。

const SOLUTION := "main() {\n    loop {\n        dodge()\n    }\n}\n\nfunction dodge() {\n    if (distance(0) < 2.5) {\n        move(90, 1)\n    } else {\n        move(0, 0)\n    }\n}\n"
const VARIABLE_SOLUTION := "constant warning = 2.5\nvariable checks = 0\nmain() {\n    loop {\n        dodge()\n    }\n}\nfunction dodge() {\n    variable observed = distance(0)\n    checks = checks + 1\n    if (observed < warning) {\n        move(90, 1)\n    } else {\n        move(0, 0)\n    }\n}\n"
const WAITING := "main() {\n    loop {\n        move(0, 0)\n    }\n}\n"
const ENEMY_ID := "radar_hunter"
const SPAWN := Vector2(4.5, 9.5)
const MAX_STEPS := 950
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待项目全局类初始化后加载生产关卡，不读取玩家草稿或进度。
func _initialize() -> void:
	_run.call_deferred()


## 依次检查教学定义、实际通关、失败边界及可重复运行。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第十一关所需模块内容可以加载"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_011.json", _content, true)
	if not _check(loaded.is_ok(), "第十一关正式 JSON 合法：" + str(loaded.errors)):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "第十一关闪避规则有效：" + str(defined.errors)):
		quit(1)
		return
	_level = defined.value
	_test_design_and_unlocks()
	_test_solution()
	_test_stationary_failures()
	_test_pause_and_retry()
	_test_interrupted_enemy()
	_test_deadline()
	_test_validation()
	print("第十一关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 按真实第十一关顺序，继承常变量能力；玩家雷达与扫描一并开放。
func _test_design_and_unlocks() -> void:
	_check(_level.id == "level_011" and _level.order == 11 and _level.display_name == "第十一关 · 巧能躲避", "第十一关使用独立 ID、顺序及玩家指定的中文名")
	_check(_level.module_limit == 2 and _level.max_ticks == 900, "两模块装配上限与九十秒练习时限来自正式数据")
	_check(_level.allow_functions and _level.allow_variables and _level.allow_tick and _level.allow_named_calls and _level.allow_loops and _level.allow_conditionals and _level.allow_simultaneous and _level.allow_distance, "本关解锁函数、继承常变量并保留前九关已学能力")
	_check(_level.allowed_modules == PackedStringArray(["movement", "melee", "shooting", "rangefinder", "radar"]), "第十一关开放五种玩家模块，包括雷达")
	_check(_level.goal_type == "dodge_attacks" and _level.goal_enemy_id == ENEMY_ID and _level.goal_attack_count == 5, "目标明确要求指定敌人的五次实际落空攻击")
	_check(_level.document.enemies.size() == 1 and _level.document.objects.is_empty(), "闪避场地仅有一台敌人，不加入额外机关或终点")
	var enemy: Dictionary = _level.document.enemies[0]
	_check(enemy.behavior == "radar_lunge" and enemy.modules.size() == 3, "敌人通过注册的雷达突进行为控制真实三模块机器")
	_check(enemy.modules[0].module_id == "melee" and enemy.modules[1].module_id == "movement" and enemy.modules[2].module_id == "radar", "敌方近战、移动、雷达各为独立模块")
	_check(_level.document.get_tile_id(Vector2i(0, 0)).is_empty() and _level.document.get_tile_id(Vector2i(4, 4)) == "floor", "边界保留 void，场地提供连续闪避空间")
	_check(_level.document.dialogue.size() == 8 and _level.starter_program.contains("function dodge()"), "提供八页中文引导及雷达说明，保留空函数框架")
	_check(not _level.starter_program.contains("distance(") and not _level.starter_program.contains("move(") and not _level.starter_program.contains("if") and not _level.starter_program.contains("loop"), "初始程序不预填测距阈值、条件或完整答案")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("movement", Vector2(-0.5, 0), "extra").is_ok(), "装配接口拒绝第三个模块")
	_check(session.assembly.build_document().is_ok(), "推荐中心测距、右侧移动的实际出生占地合法")
	var radar_player := GameSession.create(_level, _content)
	_check(radar_player.assembly.add_module("radar", Vector2.ZERO, "radar").is_ok(), "第十一关可以安装已开放的玩家雷达")
	var catalog := LevelCatalog.new()
	catalog.user_directory = "user://tests/dodge_missing_imports_%d" % Time.get_ticks_usec()
	if _check(catalog.refresh(_content).is_ok(), "正式关卡目录可以刷新"):
		var ids: Array[String] = []
		for entry: LevelDefinition in catalog.levels:
			ids.append(entry.id)
		_check(ids == ["level_001", "level_002", "level_003", "level_004", "level_005", "level_006", "level_007", "level_008", "level_009", "level_010", "level_011", "level_012", "level_013", "level_014", "level_015"], "目录按第一至第十五关依次排列")
	for number in range(1, 10):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(loaded.is_ok(), "第 %d 关的旧地图仍可加载" % number):
			continue
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "旧关卡权限定义仍合法"):
			continue
		var previous: LevelDefinition = defined.value
		_check(not previous.allow_functions and not previous.allow_variables and not previous.allow_radar and not "radar" in previous.allowed_modules, "旧关卡不会提前解锁自定义函数、常变量或雷达")
		_check(not _parse("main(){helper()}\nfunction helper(){move(0,0)}", previous).is_ok(), "旧关卡的真实解析入口拒绝新函数语法")
		_check(not _parse("main(){variable x=1}", previous).is_ok() and not _parse("constant x=1\nmain(){}", previous).is_ok(), "旧关卡的真实解析入口仍拒绝常变量语法")
	_check(_parse("main(){variable x = 1\nx=x+1}").is_ok() and _parse("constant x=1\nmain(){constant y=x}").is_ok() and _parse("value x=1\nmain(){}").is_ok(), "第十一关继承常量、变量、赋值与旧 value 别名")
	_check(not _parse("main(){scan()}").is_ok(), "scan 是查询表达式，不能单独作为动作指令")


## 函数反复读取真实测距并侧移，五次出手落空后只发送一次通关事件。
func _test_solution() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	var assembly := JSON.stringify(session.assembly.modules)
	if not _check(session.run().is_ok(), "main 前向调用后面定义的闪避函数可以启动：" + session.message):
		return
	_check(session.world.tick_index == 0 and session.world.player.position == SPAWN, "启动只排队，不提前扫描或移动")
	var events: Array[int] = []
	var attacks: Array[AttackCommand] = []
	# 用途：只记录完成通知，避免捕获会话形成循环引用。
	session.completed.connect(func() -> void: events.append(1))
	# 用途：独立统计实际完成的敌方攻击，不能只依据目标计数自证。
	session.world.attack_finished.connect(func(command: AttackCommand) -> void:
		if command.machine_id == ENEMY_ID and command.state == SimulationCommand.State.COMPLETED:
			attacks.append(command)
	)
	var saw_approach := false
	var saw_recover := false
	var moved_up := false
	var continuous := true
	var counts_valid := true
	var footprints_valid := true
	var prior_dodges := 0
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			break
		var before_tick := session.world.tick_index
		var before_enemy := session.world.get_machine(ENEMY_ID).position
		var before_player := session.world.player.position
		session.step()
		var state := session.world.get_enemy_attack_status(ENEMY_ID)
		saw_approach = saw_approach or state.get("phase") == "approach"
		saw_recover = saw_recover or state.get("phase") == "recover"
		moved_up = moved_up or session.world.player.position.y < before_player.y
		continuous = continuous and session.world.tick_index - before_tick <= 1 and session.world.get_machine(ENEMY_ID).position.distance_to(before_enemy) <= 0.10001
		var dodged := int(state.get("dodged", -1))
		counts_valid = counts_valid and dodged >= prior_dodges and dodged - prior_dodges <= 1 and dodged == attacks.size() and int(state.get("attempts", -1)) == attacks.size()
		if dodged < 5:
			counts_valid = counts_valid and session.state != GameSession.State.SUCCEEDED
		prior_dodges = dodged
		for machine: MachineInstance in [session.world.player, session.world.get_machine(ENEMY_ID)]:
			footprints_valid = footprints_valid and MachineFactory.validate_placement(machine, session.world.document, _content).is_ok()
	_check(session.state == GameSession.State.SUCCEEDED, "函数测距闪避实际完成五次攻击：" + session.message)
	_check(saw_approach and saw_recover and moved_up, "解法经历敌人接近与恢复，并真实向上闪避")
	_check(continuous and footprints_valid, "敌人按每秒一格连续移动而非瞬移，双方完整占地始终合法")
	_check(counts_valid and attacks.size() == 5 and prior_dodges == 5, "恰好五次实际出手才通关，扫描、移动和恢复不冒充闪避")
	for command in attacks:
		_check(command.hit_count == 0, "计数中的攻击确实落空，没有命中其他对象")
	_check(session.world.failure_reason.is_empty() and not session.world.player.is_destroyed(), "成功通关时玩家保持存活且没有隐藏世界错误")
	_check(session.world.tick_index > 150 and session.world.tick_index < _level.max_ticks, "五轮锁定、接近与闪避消耗真实时间且可在时限内完成")
	var final_tick := session.world.tick_index
	for unused in 10:
		session.step()
	_check(events.size() == 1 and session.world.tick_index == final_tick and session.runner.state == ProgramRunner.State.CANCELLED, "通关只通知一次，并取消循环停止计时")
	_check(session.source == SOLUTION and JSON.stringify(session.assembly.modules) == assembly and JSON.stringify(_level.document.to_dict()) == original, "通关不改写源码、装配草稿或地图模板")
	var named := _session(SOLUTION.replace("distance(", "sensor.distance(").replace("move(", "drive.move("))
	if _check(named.run().is_ok(), "函数内部可以使用已经解锁的具名测距和移动"):
		_finish(named)
		_check(named.state == GameSession.State.SUCCEEDED, "具名能力调用也经过同一场地完成五次闪避")


## 站桩、提前结束或测距不足都不能自动通关；任一模块受击立即失败。
func _test_stationary_failures() -> void:
	for source in [WAITING, "main() {}"]:
		var session := _session(source)
		var assembly := JSON.stringify(session.assembly.modules)
		if not _check(session.run().is_ok(), "站桩尝试允许启动观察真实敌人行动"):
			continue
		_finish(session)
		_check(session.state == GameSession.State.FAILED and not session.world.failure_reason.is_empty(), "站桩在第一次真实近战命中后失败")
		var status := session.world.get_enemy_attack_status(ENEMY_ID)
		_check(int(status.get("attempts", -1)) == 1 and int(status.get("dodged", -1)) == 0, "命中不是闪避，也无需等敌人再次出手才判败")
		_check(session.world.player.get_module("sensor").available and not session.world.player.get_module("drive").available, "只损失前方驱动、中心测距尚存时也立即失败")
		_check(session.source == source and JSON.stringify(session.assembly.modules) == assembly, "失败仍保留源代码和完整装配草稿")
		var frozen_tick := session.world.tick_index
		for unused in 8:
			session.step()
		_check(session.world.tick_index == frozen_tick, "命中失败后世界不会继续破坏幸存模块")
	var late := _session(SOLUTION.replace("< 2.5", "< 0.1"))
	if _check(late.run().is_ok(), "错误测距阈值仍可试运行"):
		_finish(late)
		_check(late.state == GameSession.State.FAILED and int(late.world.get_enemy_attack_status(ENEMY_ID).get("dodged", -1)) == 0, "测距阈值过小会错过侧移时机")
	var missing := GameSession.create(_level, _content)
	missing.assembly.add_module("movement", Vector2.ZERO, "drive")
	missing.source = SOLUTION
	_check(not missing.run().is_ok() and missing.state == GameSession.State.FAILED, "函数里的测距依然要求真实装配来源，不能跳过能力预检")
	_check(missing.world == null or missing.world.tick_index == 0, "函数能力错误在第一步世界执行前定位")


## 暂停冻结扫描、恢复、次数和双方位置；重置创建新世界并保留编辑作品。
func _test_pause_and_retry() -> void:
	var session := _session(VARIABLE_SOLUTION)
	if not _check(session.run().is_ok(), "暂停恢复案例可以启动"):
		return
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING or int(session.world.get_enemy_attack_status(ENEMY_ID).get("dodged", 0)) >= 1:
			break
		session.step()
	var old_world := session.world
	var snapshot := _snapshot(session)
	session.pause()
	for unused in 15:
		session.step()
	_check(session.state == GameSession.State.PAUSED and _snapshot(session) == snapshot, "暂停冻结敌人状态、下一次扫描时间和真实闪避次数")
	session.resume()
	session.step()
	_check(session.world == old_world and _snapshot(session) != snapshot, "恢复继续同一世界而非重新扫描出生位置")
	var assembly := JSON.stringify(session.assembly.modules)
	session.reset()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "重置位置释放旧世界与函数调用栈")
	_check(session.source == VARIABLE_SOLUTION and JSON.stringify(session.assembly.modules) == assembly, "重置位置保留带常变量的函数源码和具名装配")
	if not _check(session.run().is_ok(), "重置后函数程序可以重新开始"):
		return
	var reset_status := session.world.get_enemy_attack_status(ENEMY_ID)
	_check(session.world != old_world and session.world.tick_index == 0 and session.world.player.position == SPAWN, "重试从全新零时间世界与出生点开始")
	_check(int(reset_status.get("dodged", -1)) == 0 and int(reset_status.get("attempts", -1)) == 0, "重试不会继承已经躲过的次数")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "常量阈值、函数局部测距与全局变量在暂停重置后仍可完成五轮闪避")
	session.reset_code()
	_check(session.source == _level.starter_program and JSON.stringify(session.assembly.modules) == assembly and session.world == null, "重置代码只恢复空教学框架，不替换装配草稿")


## 雷达、近战或驱动失效不能通过空循环或取消动作凭空增加成功次数。
func _test_interrupted_enemy() -> void:
	for module_id in ["radar", "blade", "engine"]:
		var created := SimulationWorld.create(_level.document, _content)
		if not _check(created.is_ok(), "中断能力用例可创建独立真实世界"):
			continue
		var world: SimulationWorld = created.value
		world.get_machine(ENEMY_ID).get_module(module_id).apply_damage(1000)
		var attempts: Array[int] = []
		# 用途：从完成信号独立观察被毁能力是否错误地制造了攻击。
		world.attack_finished.connect(func(command: AttackCommand) -> void:
			if command.machine_id == ENEMY_ID and command.state == SimulationCommand.State.COMPLETED:
				attempts.append(1)
		)
		for unused in 90:
			world.step()
		var status := world.get_enemy_attack_status(ENEMY_ID)
		_check(attempts.is_empty() and int(status.get("attempts", -1)) == 0 and int(status.get("dodged", -1)) == 0, "敌人 %s 失效时未出手不能刷闪避" % module_id)
	var created := SimulationWorld.create(_level.document, _content)
	if not _check(created.is_ok(), "取消行动用例可创建独立真实世界"):
		return
	var world: SimulationWorld = created.value
	for unused in 80:
		if world.get_enemy_attack_status(ENEMY_ID).get("phase") == "approach":
			break
		world.step()
	_check(world.cancel_command(ENEMY_ID).is_ok(), "可通过公开接口取消敌人的接近动作")
	world.step()
	var status := world.get_enemy_attack_status(ENEMY_ID)
	_check(int(status.get("attempts", -1)) == 0 and int(status.get("dodged", -1)) == 0, "取消移动后的下一 tick 不被当作已经出手落空")


## 时限只是失败边界，不能把时间已到或不足五次误判为通关。
func _test_deadline() -> void:
	var document := _level.document.duplicate_document()
	document.properties.level.max_ticks = 2
	var defined := LevelDefinition.from_document(document, _content)
	if not _check(defined.is_ok(), "独立短时限闪避地图可以定义"):
		return
	var session := _session(SOLUTION, defined.value)
	if not _check(session.run().is_ok(), "短时限闪避程序可以运行"):
		return
	_finish(session)
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 2 and session.runner.state == ProgramRunner.State.CANCELLED, "到达明确时限后失败并取消剩余函数循环")
	_check(int(session.world.get_enemy_attack_status(ENEMY_ID).get("dodged", -1)) == 0, "超时不会增加闪避次数")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 2, "超时保留玩家作品")


## 新权限及目标输入采用严格类型检查，拒绝时原 JSON 快照不变。
func _test_validation() -> void:
	for flag in ["allow_functions", "allow_variables", "allow_radar"]:
		for value in [0, 1, "true", [], {}, null]:
			var document := _level.document.duplicate_document()
			document.properties.level[flag] = value
			var before := JSON.stringify(document.to_dict())
			_check(not LevelDefinition.from_document(document, _content).is_ok(), "函数与常变量开关拒绝非布尔值：" + flag)
			_check(JSON.stringify(document.to_dict()) == before, "函数与常变量开关拒绝坏值不改写输入：" + flag)
	for value in [0, -1, 1.5, true, "5", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.goal.attack_count = value
		var before := JSON.stringify(document.to_dict())
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "闪避次数拒绝非正整数或错误类型")
		_check(JSON.stringify(document.to_dict()) == before, "目标校验失败不改写输入")
	for enemy_id in ["missing", "", "player"]:
		var document := _level.document.duplicate_document()
		document.properties.level.goal.enemy_id = enemy_id
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "闪避目标必须指向存在的敌方机器")
	var wrong_behavior := _level.document.duplicate_document()
	wrong_behavior.enemies[0].behavior = "idle"
	_check(not LevelDefinition.from_document(wrong_behavior, _content).is_ok(), "不会把没有闪避计数能力的敌人定义成目标")
	var legacy := _level.document.duplicate_document()
	legacy.properties.level.erase("allow_functions")
	legacy.properties.level.erase("allow_variables")
	var defined := LevelDefinition.from_document(legacy, _content)
	_check(defined.is_ok() and not defined.value.allow_functions and not defined.value.allow_variables, "旧地图省略函数及常变量开关时默认锁定")


## 测试解析与真实会话使用相同的逐关权限，不自行扩大语言范围。
func _parse(source: String, definition: LevelDefinition = null) -> DataResult:
	var selected: LevelDefinition = _level if definition == null else definition
	return ProgramParser.parse(source, selected.allowed_calls, selected.allow_tick, selected.allow_named_calls, selected.allow_loops, selected.allow_conditionals, selected.allow_simultaneous, selected.allow_distance, selected.allow_functions, selected.allow_variables, selected.allow_radar)


## 每次从公开接口手工安装两个模块，不能用地图模板绕过空装配要求。
func _session(source: String, definition: LevelDefinition = null) -> GameSession:
	var session := GameSession.create(_level if definition == null else definition, _content)
	_check(session.assembly.modules.is_empty(), "第十一关进入时仍为空装配")
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "手动安装中心测距模块")
	_check(session.assembly.add_module("movement", Vector2(0.5, 0), "drive").is_ok(), "手动安装右侧共边移动模块")
	session.source = source
	return session


## 只读取公开状态建立暂停快照，不依赖敌人私有状态机字典。
func _snapshot(session: GameSession) -> String:
	return var_to_str([session.world.tick_index, session.world.player.position, session.world.get_machine(ENEMY_ID).position, session.world.get_enemy_attack_status(ENEMY_ID), session.current_line])


## 所有完整试运行都有界，异常时输出检查失败而不让测试永久循环。
func _finish(session: GameSession) -> void:
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第十一关试运行应在九十五秒的测试边界内结束")


## 汇总真实断言并保留清晰失败原因，供统一测试脚本读取。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
