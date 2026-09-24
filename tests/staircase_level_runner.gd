extends SceneTree
## 第六关通过真实阶梯地图、装配和会话验证无限循环，不读写玩家存档。

const SOLUTION := "main() {\n    loop {\n        move(0, 3)\n        move(90, 2)\n    }\n}\n"
const NAMED_SOLUTION := "main() {\n    loop {\n        drive.move(0, 3)\n        drive.move(90, 2)\n    }\n}\n"
const SPAWN := Vector2(1.5, 21.5)
const GOAL := Vector2(31.5, 1.5)
const MAX_TICKS := 550
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待场景树初始化完成后加载正式关卡数据，不使用替代地图或解释器。
func _initialize() -> void:
	_run.call_deferred()


## 每个用例从独立会话开始，汇总返回码与完成标记供统一测试脚本检查。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第六关使用的实际内容可加载"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_006.json", _content, true)
	if not _check(loaded.is_ok(), "第六关 JSON 可以通过完整地图校验"):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "第六关的循环解锁与终点配置合法"):
		quit(1)
		return
	_level = defined.value
	_test_design()
	_test_compilation()
	_test_solution()
	_test_failures()
	_test_pause_stop_retry()
	_test_named_solution()
	_test_zero_distance_loop()
	_test_unlocks()
	_test_metadata_validation()
	print("第六关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 地图恰由十组右三上二的单格阶梯组成，没有额外地板让错误步长走捷径。
func _test_design() -> void:
	_check(_level.id == "level_006" and _level.order == 6, "第六关具有稳定 ID 和排序")
	_check(_level.document.width == 33 and _level.document.height == 23, "十组阶梯使用预期地图尺寸")
	_check(_level.module_limit == 1 and _level.allow_loops, "第六关只允许一个模块并显式开放循环")
	_check(_level.allowed_modules == PackedStringArray(["movement", "melee", "shooting"]) and _level.allow_tick and _level.allow_named_calls, "循环教学保留之前已学模块、tick 和命名调用")
	_check(_level.goal_type == "reach_position" and _level.goal_position == GOAL and is_equal_approx(_level.goal_radius, 0.25), "第六关以到达右上角终点作为唯一胜利目标")
	var spawn: Dictionary = _level.document.player_spawn.position
	_check(Vector2(float(spawn.x), float(spawn.y)) == SPAWN, "机器人从左下角指定位置开始")
	var expected: Dictionary = {}
	var cursor := Vector2i(1, 21)
	expected[cursor] = true
	for unused in 10:
		for step in 3:
			cursor += Vector2i.RIGHT
			expected[cursor] = true
		for step in 2:
			cursor += Vector2i.UP
			expected[cursor] = true
	var exact_route := _level.document.cells.size() == expected.size()
	for cell: Vector2i in expected:
		exact_route = exact_route and _level.document.get_tile_id(cell) == "floor"
	_check(expected.size() == 51 and exact_route, "实际 51 格地板精确构成十组右三上二阶梯")
	_check(cursor == Vector2i(31, 1) and _level.document.get_tile_id(Vector2i(2, 20)).is_empty(), "第十组抵达终点，阶梯之间的空白仍为 void")
	_check(_level.document.enemies.is_empty() and _level.document.objects.is_empty(), "循环移动练习不偷偷依赖敌人、机关或隐藏计时胜利")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("movement", Vector2(0.5, 0)).is_ok(), "模型层也拒绝增加第二个驱动跳过单模块限制")
	_check(session.assembly.build_document().is_ok(), "中心单驱动装配的实际出生占地有效")


## 合法源码只构造显式循环语法树，编译本身不自动组装、推进或执行程序。
func _test_compilation() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	var parsed := ProgramParser.parse(SOLUTION, _level.allowed_calls, _level.allow_tick, _level.allow_named_calls, _level.allow_loops)
	if not _check(parsed.is_ok(), "合法无限循环可以独立编译"):
		return
	# 初始框架刻意不提供动作；沿用空循环诊断，引导玩家补全后再运行。
	var starter := ProgramParser.parse(_level.starter_program, _level.allowed_calls, _level.allow_tick, _level.allow_named_calls, _level.allow_loops)
	_check(not starter.is_ok() and "\n".join(starter.errors).contains("loop 代码块不能为空"), "空循环框架等待玩家自己填写动作，不改变解释器规则")
	_check(parsed.value.main.body.statements.size() == 1 and parsed.value.main.body.statements[0] is ProgramAst.LoopNode, "编译保留 LoopNode，不把循环预展开为有限调用")
	var loop_node: ProgramAst.LoopNode = parsed.value.main.body.statements[0]
	_check(loop_node.body.statements.size() == 2 and loop_node.line == 2, "循环体保留两条移动与准确源码位置")
	_check(session.world == null and session.runner == null and session.state == GameSession.State.EDITING, "仅编译源码不会创建或启动会话世界")
	_check(JSON.stringify(_level.document.to_dict()) == original and session.source == SOLUTION, "编译不改写地图或玩家源码")


## 无限循环沿真实路径重复行走，到达终点后由会话取消运行并且仅通知一次。
func _test_solution() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "中心单驱动可启动无限阶梯程序"):
		return
	var completed: Array[int] = []
	# 用途：只记录胜利通知，以检查无限循环停止后不会重复提交完成结果。
	session.completed.connect(func() -> void: completed.append(1))
	_check(session.world.tick_index == 0 and session.world.player.position == SPAWN, "启动只排队，未调用 step 前不移动")
	var stayed_on_floor := true
	var respected_tick_boundary := true
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			break
		var before := session.world.tick_index
		session.step()
		respected_tick_boundary = respected_tick_boundary and session.world.tick_index - before <= 1
		for module in session.world.player.modules:
			stayed_on_floor = stayed_on_floor and TerrainCollision.is_rect_supported(module.get_world_rect(session.world.player.position), session.world.document, _content)
	_check(session.state == GameSession.State.SUCCEEDED, "真正无限循环完成十组阶梯后通关")
	_check(stayed_on_floor and respected_tick_boundary, "循环不穿越 void，每次 step 至多推进一个逻辑 tick")
	_check(session.world.player.position.distance_to(GOAL) <= _level.goal_radius + 0.00001, "胜利由真实位置进入终点半径触发")
	_check(session.world.tick_index > 450 and session.world.tick_index <= 500, "单驱动确实走入第十组，运行时间符合五十格路线")
	_check(session.runner.state == ProgramRunner.State.CANCELLED, "到达终点后会话取消仍未结束的无限循环")
	var final_tick := session.world.tick_index
	var final_position := session.world.player.position
	for unused in 10:
		session.step()
	_check(completed.size() == 1 and session.world.tick_index == final_tick and session.world.player.position == final_position, "胜利后不执行第十一组，不重复完成或移动")
	_check(session.source == SOLUTION and JSON.stringify(_level.document.to_dict()) == original, "循环运行不污染源码或静态地图")


## 少一次重复、错误距离和缺少驱动都无法获得第六关胜利，错误保留编辑内容。
func _test_failures() -> void:
	var nine_groups := "main() {\n"
	for unused in 9:
		nine_groups += "    move(0, 3)\n    move(90, 2)\n"
	nine_groups += "}\n"
	var short_program := _session(nine_groups)
	if _check(short_program.run().is_ok(), "手工展开九组路径可正常启动"):
		_finish(short_program)
		# Vector2 使用单精度；实测 450 tick 的位移累计约 0.00009 格误差。
		# 使用千分之一格的绝对容差，同时保留失败终态与精确 450 tick 的独立断言。
		var position_error := short_program.world.player.position.distance_to(Vector2(28.5, 3.5))
		_check(short_program.state == GameSession.State.FAILED and position_error < 0.001, "九组程序在第九级结束，不能提前判为通关（state=%d，位置=%s，误差=%.9f）" % [short_program.state, short_program.world.player.position, position_error])
		_check(short_program.world.tick_index == 450, "九组展开与真实移动时间一致，不多跑隐藏循环")
	for source in ["main(){\nloop {\nmove(0,4)\nmove(90,2)\n}\n}", "main(){\nloop {\nmove(0,2)\nmove(90,2)\n}\n}", "main(){\nloop {\nmove(0,3)\nmove(90,3)\n}\n}"]:
		var session := _session(source)
		if not _check(session.run().is_ok(), "语法合法的错误步长可实际运行观察结果"):
			continue
		_finish(session)
		_check(session.state == GameSession.State.FAILED and session.world.tick_index < 60, "错误水平或垂直步长会被真实 void 阻挡")
		_check(session.current_line in [3, 4] and session.message.contains("void"), "循环内受阻保留对应移动语句的错误行")
		_check(session.source == source and session.assembly.modules.size() == 1, "循环失败保留源码和单模块装配")
	for module_id in ["melee", "shooting"]:
		var missing := _session(SOLUTION, module_id)
		_check(not missing.run().is_ok() and missing.state == GameSession.State.FAILED, "已学的非移动模块不能执行阶梯移动")
		_check(missing.world == null or (missing.world.tick_index == 0 and missing.world.player.position == SPAWN), "缺少移动能力时不能部分推进世界")
		_check(missing.current_line == 3, "循环中缺少移动能力仍定位首条 move 的源码行")


## 暂停冻结循环当前动作，停止和重置保留作品；重试从新世界重新开始第一组。
func _test_pause_stop_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停回归中的循环程序可以运行"):
		return
	for unused in 35:
		session.step()
	var first_world := session.world
	var old_position := first_world.player.position
	var old_line := session.current_line
	session.pause()
	for unused in 8:
		session.step()
	_check(session.state == GameSession.State.PAUSED and first_world.tick_index == 35 and first_world.player.position == old_position and session.current_line == old_line, "暂停同时冻结世界、当前移动和源码行")
	session.resume()
	session.step()
	_check(first_world.tick_index == 36 and first_world.player.position != old_position, "恢复继续原来未结束的循环移动")
	session.stop()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "停止释放循环执行栈和旧世界")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 1 and session.assembly.modules[0].id == "drive", "停止保留源码和手工命名的驱动模块")
	if not _check(session.run().is_ok(), "停止后同一程序可重新运行"):
		return
	_check(session.world != first_world and session.world.tick_index == 0 and session.world.player.position == SPAWN, "重试从出生点和全新循环状态开始")
	session.step()
	_check(session.world.player.position.x > SPAWN.x and is_equal_approx(session.world.player.position.y, SPAWN.y), "重试第一条仍是向右，不会接着旧的向上动作")
	session.reset()
	_check(session.world == null and session.source == SOLUTION and session.assembly.modules.size() == 1, "重置也保留作品并解除循环")
	if not _check(session.run().is_ok(), "重置后可再次运行完整循环"):
		return
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "暂停、停止、重置后重试仍能走完阶梯")


## 第五关已学的具名移动可以放进循环，名称解析不能退化为广播或丢失能力检查。
func _test_named_solution() -> void:
	var session := _session(NAMED_SOLUTION)
	if not _check(session.run().is_ok(), "具名 drive.move 可以在循环体中使用"):
		return
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED and session.source == NAMED_SOLUTION, "具名循环通过同一条真实阶梯并保留原代码")
	var typo := _session("main(){\nloop {\nDrive.move(0,3)\nmove(90,2)\n}\n}")
	_check(not typo.run().is_ok() and typo.current_line == 3, "循环中的实例名仍区分大小写并定位错误行")
	_check(typo.world == null or typo.world.tick_index == 0, "循环实例名错误在任何移动前拒绝")


## 零距离循环保持可暂停和停止，每次外部步进至多推进一 tick，不能卡在解释器内。
func _test_zero_distance_loop() -> void:
	var source := "main(){\nloop {\nmove(0,0)\n}\n}"
	var session := _session(source)
	if not _check(session.run().is_ok(), "零距离动作可出现在合法循环中"):
		return
	var bounded := true
	for unused in 12:
		var previous := session.world.tick_index
		session.step()
		bounded = bounded and session.world.tick_index >= previous and session.world.tick_index <= previous + 1
	_check(bounded and session.state == GameSession.State.RUNNING and session.world.player.position == SPAWN, "零距离循环按有限步进让出控制，不假造位移或胜利")
	session.pause()
	var tick_before := session.world.tick_index
	session.step()
	_check(session.state == GameSession.State.PAUSED and session.world.tick_index == tick_before, "零距离循环也能暂停")
	session.stop()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.source == source, "零距离循环可停止，作品仍保留")


## 前五关保持循环未解锁；第六关的 tick 仍禁止循环，不能让回调失去有限边界。
func _test_unlocks() -> void:
	for index in range(1, 6):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, _content, true)
		if not _check(loaded.is_ok(), "兼容检查可读取旧关卡 %d" % index):
			continue
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "旧关卡规则仍有效"):
			continue
		var previous: LevelDefinition = defined.value
		_check(not previous.allow_loops, "前五关不能因新语法加入而提前解锁循环")
		var session := GameSession.create(previous, _content)
		session.assembly.add_module("movement", Vector2.ZERO, "drive")
		session.source = SOLUTION
		_check(not session.run().is_ok() and session.world == null, "旧关卡的循环在世界创建前被拒绝")
		_check(previous.allow_tick == (index >= 4) and previous.allow_named_calls == (index >= 5), "原有 tick 与命名调用解锁顺序保持不变")
	var callback := _session("main(){}\ntick(){\nloop {\nattack(0)\n}\n}", "melee")
	_check(not callback.run().is_ok() and callback.world == null, "即使第六关解锁循环，tick 内仍禁止 loop")


## 循环权限必须是显式布尔值，缺省值继续关闭；校验失败不能改写地图快照。
func _test_metadata_validation() -> void:
	var original := JSON.stringify(_level.document.to_dict())
	for value in [0, 1, "true", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_loops = value
		var snapshot := JSON.stringify(document.to_dict())
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "allow_loops 拒绝非布尔值 " + str(value))
		_check(JSON.stringify(document.to_dict()) == snapshot, "循环权限校验失败不修改输入文档")
	var legacy := _level.document.duplicate_document()
	legacy.properties.level.erase("allow_loops")
	var parsed := LevelDefinition.from_document(legacy, _content)
	_check(parsed.is_ok() and not parsed.value.allow_loops, "省略循环开关时兼容旧地图并保持未解锁")
	_check(JSON.stringify(_level.document.to_dict()) == original, "负例始终使用独立快照，不修改生产关卡")


## 使用公开装配入口手动安装唯一中心模块，避免出生模板自动预装掩盖入口错误。
func _session(source: String, module_id: String = "movement") -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "第六关每次进入先空装配")
	_check(session.assembly.add_module(module_id, Vector2.ZERO, "drive").is_ok(), "玩家可在中心安装本关允许的单模块")
	session.source = source
	return session


## 用稍大于完整路线耗时的明确上限推进会话，不能靠测试进程无限等待判定通过。
func _finish(session: GameSession) -> void:
	for unused in MAX_TICKS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第六关完整路线或错误尝试应在五百五十 tick 内结束")


## 记录所有断言并在失败时输出清晰原因，由退出码和日志共同报告结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
