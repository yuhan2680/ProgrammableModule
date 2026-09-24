extends SceneTree
## DSL 独立回归：真实词法/语法树、错误位置、限制，以及固定 tick 顺序解释。

var _registry := ContentRegistry.new()
var _checks: int = 0
var _failures: int = 0
var _finished_count: int = 0
var _line_events: Array[int] = []
var _callback_runner: ProgramRunner
var _loop_repeat_count: int = 0


## 在场景树初始化结束后执行回归，所有失败统一转换为非零进程状态。
func _initialize() -> void:
	_run.call_deferred()


## 加载真实内容定义后执行词法、语法和运行器测试，不依赖游戏界面。
func _run() -> void:
	var loaded := _registry.load_directories()
	_check(loaded.is_ok(), "真实内容注册表可用于语言运行测试")
	if not loaded.is_ok():
		quit(1)
		return
	_test_tokens_and_ast()
	_test_rejections_and_limits()
	_test_tick_parser()
	_test_named_parser()
	_test_sequential_execution()
	_test_blocked_and_cancelled()
	_test_start_validation_and_retry()
	_test_callback_cancellation()
	_test_callback_step_reentry()
	_test_tick_execution()
	_test_tick_cancellation_and_validation()
	_test_named_preflight()
	_test_named_execution()
	_test_named_tick_execution()
	_test_loop_parser()
	_test_loop_preflight()
	_test_loop_execution()
	_test_loop_cancellation_and_reentry()
	_test_conditional_parser()
	_test_conditional_preflight()
	_test_conditional_execution()
	_test_optional_else_execution()
	_test_conditional_tick_execution()
	_test_conditional_cancellation_and_reentry()
	print("语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 无限循环是独立代码块语法，旧关卡权限、换行、小数和全树预算继续生效。
func _test_loop_parser() -> void:
	var calls := PackedStringArray(["move", "attack", "shoot"])
	var source := "main(){\n  loop {\n    move(0, 3.)\n    drive.move(90, +2)\n  }\n}"
	var parsed := ProgramParser.parse(source, calls, true, true, true)
	_check(parsed.is_ok(), "第六关解锁后可解析无限 loop 块与具名调用")
	if parsed.is_ok():
		var ast: ProgramAst.ProgramNode = parsed.value
		_check(ast.main.body.statements.size() == 1 and ast.main.body.statements[0] is ProgramAst.LoopNode, "AST 保留一个循环节点，不提前展开十次动作")
		var loop := ast.main.body.statements[0] as ProgramAst.LoopNode
		_check(loop.line == 2 and loop.column == 3 and loop.body.statements.size() == 2, "循环节点和两个原始动作保留精确结构与位置")
		_check((loop.body.statements[1] as ProgramAst.CallNode).receiver == "drive" and loop.body.statements[1].line == 4, "嵌套调用保留原始命名接收者和源码行")
	var locked := ProgramParser.parse(source, calls, true, true)
	_check(not locked.is_ok() and locked.errors[0].contains("尚未解锁") and locked.errors[0].contains("loop"), "即使前五关能力全开，省略 allow_loops 仍锁定循环")
	_check(ProgramParser.parse("main(){loop\n{\nmove(0,.1)\n}}", calls, false, false, true).is_ok(), "loop 与左花括号间允许自然换行")
	var samples: Array[Dictionary] = [
		{"source": "main(){loop{}}", "reason": "不能为空"},
		{"source": "main(){loop{\n// 空白注释\n}}", "reason": "不能为空"},
		{"source": "main(){loop(10){move(0,1)}}", "reason": "不接受次数参数"},
		{"source": "main(){loop move(0,1)}", "reason": "需要代码块"},
		{"source": "main(){loop{move(0,1)\n}", "reason": "缺少右花括号"},
		{"source": "main(){loop{move(0,1)", "reason": "缺少右花括号"},
		{"source": "main(){loop{move(0,1)};}", "reason": "不允许分号"},
		{"source": "main(){loop{move(0,1)} move(0,2)}", "reason": "每行只能写一条"},
		{"source": "main(){loop{break}}", "reason": "尚未解锁"},
		{"source": "main(){}\ntick(){loop{shoot(0)}}", "reason": "不能包含 loop"},
	]
	for sample: Dictionary in samples:
		var rejected := ProgramParser.parse(sample.source, calls, true, true, true)
		_check(not rejected.is_ok() and rejected.errors[0].contains(sample.reason) and rejected.errors[0].contains("第 "), "非法循环具有清楚的行列诊断：" + sample.reason)
	var nested := "main(){" + "loop{\n".repeat(ProgramParser.MAX_LOOP_DEPTH) + "move(0,0)\n" + "}\n".repeat(ProgramParser.MAX_LOOP_DEPTH) + "}"
	_check(ProgramParser.parse(nested, calls, false, false, true).is_ok(), "16 层嵌套恰好达到允许上限")
	var too_deep := "main(){loop{\n" + nested.trim_prefix("main(){").trim_suffix("}") + "}\n}"
	var deep_result := ProgramParser.parse(too_deep, calls, false, false, true)
	_check(not deep_result.is_ok() and deep_result.errors[0].contains("16 层"), "第17层循环在深入解析之前明确拒绝")
	var budget := "main(){\n" + "move(0,0)\n".repeat(256) + "loop{\n" + "move(0,0)\n".repeat(256) + "}\n}"
	_check(ProgramParser.parse(budget, calls, false, false, true).is_ok(), "main 与循环体共享512条调用上限")
	_check(not ProgramParser.parse(budget.trim_suffix("}") + "move(0,0)\n}", calls, false, false, true).is_ok(), "循环外再添加调用不能绕过总调用预算")
	var named_locked := ProgramParser.parse("main(){loop{drive.move(0,1)}}", calls, false, false, true)
	_check(not named_locked.is_ok() and named_locked.errors[0].contains("命名模块调用尚未解锁"), "只解锁循环不会隐式解锁命名调用")


## 循环内及无限循环之后的错误都必须预检，手工 AST 也不能制造递归环或无动作自旋。
func _test_loop_preflight() -> void:
	for invalid in ["move(90,-1)", "missing.move(0,1)", "drive.attack(0)"]:
		var world := _make_world()
		var runner := _make_loop_runner("main(){\nmove(0,1)\nloop{\n  " + invalid + "\n}\n}", world)
		_check(not runner.start().is_ok() and runner.message.contains("第 4 行，第 3 列"), "后置循环体错误在第一动作前报告：" + invalid)
		world.step()
		_check(world.player.position == Vector2(1.5, 6.5), "循环体预检失败不会先执行前方合法移动")
	var after := _make_loop_runner("main(){loop{move(0,0)}\nmissing.move(0,1)}", _make_world())
	_check(not after.start().is_ok() and after.message.contains("第 2 行"), "即使无限循环之后不可达，非法具名调用仍须预检")
	var no_drive_world := _make_combat_world()
	no_drive_world.player.get_module("drive").available = false
	var no_drive := _make_loop_runner("main(){shoot(0)\nloop{move(0,1)}}", no_drive_world)
	_check(not no_drive.start().is_ok() and no_drive.message.contains("移动模块"), "循环广播移动缺少能力也在全程序预检阶段拒绝")
	no_drive_world.step()
	_check(no_drive_world.projectiles.is_empty(), "后方循环缺移动能力时，前方射击不会先发射")
	var empty_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){}").value
	var empty_loop := ProgramAst.LoopNode.new()
	empty_loop.body = ProgramAst.BlockNode.new()
	empty_ast.main.body.statements.append(empty_loop)
	_check(not ProgramRunner.create(empty_ast, _make_world()).start().is_ok(), "公开 AST 中的空循环不能进入调度器")
	var cyclic_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){}").value
	var cyclic_loop := ProgramAst.LoopNode.new()
	cyclic_loop.body = cyclic_ast.main.body
	cyclic_ast.main.body.statements.append(cyclic_loop)
	var cyclic := ProgramRunner.create(cyclic_ast, _make_world())
	_check(not cyclic.start().is_ok() and cyclic.message.contains("循环引用"), "公开 AST 自引用被有界拒绝，不发生递归溢出")
	# RefCounted 测试夹具主动断开伪造的环，避免测试本身留下循环引用资源。
	cyclic_loop.body = null
	var deep_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){move(0,0)}").value
	for unused in ProgramParser.MAX_LOOP_DEPTH + 1:
		var loop := ProgramAst.LoopNode.new()
		loop.body = deep_ast.main.body
		var outer := ProgramAst.BlockNode.new()
		outer.statements.append(loop)
		deep_ast.main.body = outer
	var deep := ProgramRunner.create(deep_ast, _make_world())
	_check(not deep.start().is_ok() and deep.message.contains("16 层"), "公开 AST 不能绕过解析器嵌套上限")
	var invalid_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){}").value
	invalid_ast.main.body.statements.append(ProgramAst.StatementNode.new())
	_check(not ProgramRunner.create(invalid_ast, _make_world()).start().is_ok(), "未知语句基类不能被默认为移动调用")
	invalid_ast.main.body.statements[0] = null
	_check(not ProgramRunner.create(invalid_ast, _make_world()).start().is_ok(), "空语句节点得到错误而非崩溃")
	var shared_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){loop{move(0,0)}}", PackedStringArray(["move"]), false, false, true).value
	var shared_loop := shared_ast.main.body.statements[0]
	for unused in 512:
		shared_ast.main.body.statements.append(shared_loop)
	var excessive := ProgramRunner.create(shared_ast, _make_world())
	_check(not excessive.start().is_ok() and excessive.message.contains("数量限制"), "共享 AST 子树也按每条语句路径累计预算")
	var tick_ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){}\ntick(){}", PackedStringArray(["shoot"]), true).value
	tick_ast.tick.body.statements.append(shared_loop)
	var forbidden_tick := ProgramRunner.create(tick_ast, _make_world())
	_check(not forbidden_tick.start().is_ok() and forbidden_tick.message.contains("tick()"), "手工 AST 不能绕过 tick 禁止无限循环")


## 每条动作照旧等待实际世界完成，循环边界零额外耗时，零距也每次让出一个世界 tick。
func _test_loop_execution() -> void:
	var world := _make_world()
	var runner := _make_loop_runner("main(){\nmove(0,.1)\nloop{\nmove(0,.2)\nmove(90,.1)\n}\n}", world)
	_reset_observations()
	runner.line_changed.connect(_on_line_changed)
	_check(runner.start().is_ok() and world.tick_index == 0, "循环启动仍仅派发首动作，不推进世界")
	for unused in 7:
		runner.step()
	_check(world.tick_index == 7 and world.player.position.is_equal_approx(Vector2(2.0, 6.3)), "首动作加两轮循环恰好七tick，循环边界不额外等待")
	_check(_line_events == [2, 4, 5, 4, 5] and runner.state == ProgramRunner.State.RUNNING, "循环重复高亮原始两行动作，并保持运行等待外部停止")
	runner.cancel()
	var zero_world := _make_world()
	var zero := _make_loop_runner("main(){loop{move(0,0)}}", zero_world)
	zero.start()
	for unused in 100:
		zero.step()
	_check(zero_world.tick_index == 100 and zero_world.player.position == Vector2(1.5, 6.5) and zero.state == ProgramRunner.State.RUNNING, "零距离无限循环每次step恰好推进一tick，不在单帧内死循环")
	zero.cancel()
	var nested_world := _make_world()
	var nested := _make_loop_runner("main(){move(0,.1)\nloop{move(0,.1)\nloop{move(90,.1)}\nmove(0,1)\n}\n}", nested_world)
	nested.start()
	for unused in 5:
		nested.step()
	_check(nested_world.tick_index == 5 and nested_world.player.position.is_equal_approx(Vector2(1.7, 6.2)), "嵌套无限循环遵循真实控制流，不重跑外层前缀或执行内层后方语句")
	nested.cancel()
	var blocked_world := _make_world()
	var blocked := _make_loop_runner("main(){loop{\nmove(180,10)\nmove(90,1)\n}}", blocked_world)
	blocked.start()
	for unused in 150:
		blocked.step()
	_check(blocked.state == ProgramRunner.State.FAILED and blocked.message.contains("第 2 行") and blocked_world.player.position.y == 6.5, "循环动作遇到 void 即失败并指向当前动作，不执行下一条")
	var combat_world := _make_combat_world()
	var combat := _make_loop_runner("main(){loop{move(0,.1)\nmove(180,.1)}}\ntick(){shoot(0)}", combat_world)
	combat.start()
	for unused in 12:
		combat.step()
	_check(combat_world.tick_index == 12 and combat_world.player.position.is_equal_approx(Vector2(1.5, 6.5)), "循环移动与 tick 射击共用一条固定时间轴")
	_check(combat_world.projectiles.size() == 2 and combat_world.player.get_module("gun").next_shoot_tick == 21, "循环不改变独立射击模块的十tick冷却")
	combat.cancel()


## 循环头重复高亮与世界通知仍可同步取消或请求step，不能越过取消多走一条动作。
func _test_loop_cancellation_and_reentry() -> void:
	var world := _make_world()
	_callback_runner = _make_loop_runner("main(){loop{\nmove(0,.1)\nmove(90,.1)\n}}", world)
	_loop_repeat_count = 0
	_reset_observations()
	_callback_runner.line_changed.connect(_cancel_at_loop_repeat)
	_callback_runner.finished.connect(_on_finished)
	_callback_runner.start()
	_callback_runner.step()
	_callback_runner.step()
	_callback_runner.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and _finished_count == 1 and world.tick_index == 2, "循环第二轮首行高亮取消，不再派发或推进第三tick")
	world.step()
	_check(world.player.position.is_equal_approx(Vector2(1.6, 6.4)), "循环取消后外部世界步进也没有遗留移动")
	_callback_runner.line_changed.disconnect(_cancel_at_loop_repeat)
	var reentry_world := _make_world()
	_callback_runner = _make_loop_runner("main(){loop{move(0,.1)\nmove(90,.1)}}", reentry_world)
	_callback_runner.line_changed.connect(_step_at_line)
	reentry_world.tick_completed.connect(_step_at_tick)
	_callback_runner.start()
	for unused in 4:
		_callback_runner.step()
	_check(reentry_world.tick_index == 4 and reentry_world.player.position.is_equal_approx(Vector2(1.7, 6.3)), "循环跨边界时同步重入也不能额外推进世界或重复派发")
	_callback_runner.cancel()
	_callback_runner.line_changed.disconnect(_step_at_line)
	reentry_world.tick_completed.disconnect(_step_at_tick)
	var tick_world := _make_world()
	_callback_runner = _make_loop_runner("main(){loop{move(0,1)}}", tick_world)
	tick_world.tick_completed.connect(_cancel_at_tick)
	_callback_runner.start()
	_callback_runner.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and tick_world.tick_index == 1, "循环世界通知中取消不会再访问已释放的当前调用或帧")
	tick_world.tick_completed.disconnect(_cancel_at_tick)
	_callback_runner = null


## 在循环体第二次来到同一原始源码行时取消，直接检查跨循环派发边界。
func _cancel_at_loop_repeat(line: int) -> void:
	if line == 2:
		_loop_repeat_count += 1
		if _loop_repeat_count == 2:
			_callback_runner.cancel()


## 测试主动开启第六关权限，旧套件继续使用原来的默认编译参数。
func _make_loop_runner(source: String, simulation: SimulationWorld) -> ProgramRunner:
	var parsed := ProgramParser.parse(source, PackedStringArray(["move", "attack", "shoot"]), true, true, true)
	_check(parsed.is_ok(), "第六关运行测试源码能够静态编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, simulation)


## 验证成员点与既有小数互不干扰，具名调用权限和错误位置独立于 tick 解锁。
func _test_named_parser() -> void:
	var calls := PackedStringArray(["move", "attack", "shoot"])
	var parsed := ProgramParser.parse("main(){\n  Drive_2.move(-90.5, +.25)\n  move(0, 1.)\n}\ntick(){left.attack(180)\nright.shoot(.5)}", calls, true, true)
	_check(parsed.is_ok(), "第五关可混用具名、广播调用与正负小数")
	if parsed.is_ok():
		var ast: ProgramAst.ProgramNode = parsed.value
		var named := ast.main.body.statements[0] as ProgramAst.CallNode
		_check(named.receiver == "Drive_2" and named.callee == "move", "AST 分开保留原大小写的接收实例与方法名")
		_check(named.line == 2 and named.column == 3, "具名调用的位置从接收实例首字符开始")
		_check(named.arguments[0].value == -90.5 and named.arguments[1].value == 0.25, "成员点不会吞掉数字的小数点")
		var broadcast := ast.main.body.statements[1] as ProgramAst.CallNode
		_check(broadcast.receiver.is_empty() and broadcast.arguments[1].value == 1.0, "广播调用保留空接收实例及 1. 字面量")
		_check((ast.tick.body.statements[0] as ProgramAst.CallNode).receiver == "left" and (ast.tick.body.statements[1] as ProgramAst.CallNode).receiver == "right", "同一个 tick 可包含多个独立接收实例")
	var locked := ProgramParser.parse("main(){}\ntick(){gun.shoot(0)}", calls, true)
	_check(not locked.is_ok() and locked.errors[0].contains("命名模块调用尚未解锁"), "旧四关即使解锁 tick 也不能使用具名调用")
	var ability_locked := ProgramParser.parse("main(){left.attack(180)}", PackedStringArray(["move"]), false, true)
	_check(not ability_locked.is_ok() and ability_locked.errors[0].contains("尚未解锁指令"), "命名权限不会绕过具体能力解锁")
	var samples: Array[Dictionary] = [
		{"code": "left..attack(0)", "reason": "点号需要指令名"},
		{"code": "left.arm.attack(0)", "reason": "连续属性访问"},
		{"code": "left.", "reason": "点号需要指令名"},
		{"code": ".attack(0)", "reason": "需要已解锁"},
		{"code": "left.5(0)", "reason": "未知或尚未实现"},
		{"code": "left.\nattack(0)", "reason": "点号需要指令名"},
		{"code": "left.attack(0).attack(0)", "reason": "每行只能写一条"},
		{"code": "left.unknown(0)", "reason": "未知或尚未实现"},
		{"code": "left.attack()", "reason": "需要 1 个参数"},
		{"code": "left.move(0)", "reason": "需要 2 个参数"},
		{"code": "main.attack(0)", "reason": "非保留"},
		{"code": "left.attack(0);", "reason": "不允许分号"},
	]
	for sample: Dictionary in samples:
		var rejected := ProgramParser.parse("main(){\n  " + sample.code + "\n}", calls, true, true)
		_check(not rejected.is_ok() and rejected.errors[0].contains(sample.reason) and rejected.errors[0].contains("第 2 行"), "非法具名语法具有可定位原因：" + sample.code)
	var blocked_tick := ProgramParser.parse("main(){}\ntick(){drive.move(0,1)}", calls, true, true)
	_check(not blocked_tick.is_ok() and blocked_tick.errors[0].contains("必须立即结束"), "具名 move 不能绕过 tick 禁止等待动作")
	_check(ProgramParser.parse("main(){_" + "a".repeat(127) + ".move(0,1)}", calls, false, true).is_ok(), "接收实例名允许 128 字符上限")
	_check(not ProgramParser.parse("main(){_" + "a".repeat(128) + ".move(0,1)}", calls, false, true).is_ok(), "接收实例名超过 128 字符被拒绝")
	_check(ProgramParser.parse("main(){tick.attack(0)\nshoot.shoot(90)}", calls, false, true).is_ok(), "已有装配允许的 tick 与 shoot 名称仍可精确引用")
	var budget := "main(){\n" + "left.attack(0)\n".repeat(256) + "}\ntick(){\n" + "right.attack(180)\n".repeat(256) + "}"
	_check(ProgramParser.parse(budget, calls, true, true).is_ok(), "具名调用仍共享 512 条调用预算")
	_check(not ProgramParser.parse(budget.trim_suffix("}") + "right.attack(180)\n}", calls, true, true).is_ok(), "具名调用不能绕过总调用上限")


## 整树预检必须精确到实例与能力，后方拼写错误不能提前执行前方有效动作。
func _test_named_preflight() -> void:
	var samples: Array[Dictionary] = [
		{"code": "missing.attack(0)", "reason": "找不到名为“missing”"},
		{"code": "Left.attack(0)", "reason": "大小写必须一致"},
		{"code": "drive.attack(0)", "reason": "不支持 attack"},
		{"code": "left.move(0,1)", "reason": "不支持 move"},
		{"code": "left.shoot(0)", "reason": "不支持 shoot"},
	]
	for sample: Dictionary in samples:
		var simulation := _make_named_world()
		var runner := _make_named_runner("main(){\nmove(0,1)\n  " + sample.code + "\n}", simulation)
		var started := runner.start()
		_check(not started.is_ok() and runner.message.contains("第 3 行，第 3 列") and runner.message.contains(sample.reason), "预检精确拒绝接收实例错误：" + sample.code)
		simulation.step()
		_check(simulation.player.position == Vector2(5, 5) and simulation.attack_traces.is_empty() and simulation.projectiles.is_empty(), "后方具名错误发生时整份程序没有先执行任何动作")
	var unavailable_world := _make_named_world()
	unavailable_world.player.get_module("left").available = false
	var unavailable := _make_named_runner("main(){left.attack(0)}", unavailable_world)
	_check(not unavailable.start().is_ok() and unavailable.message.contains("已不可用"), "存在另一可用近战模块也不能代替指定的失效模块")
	var tick_world := _make_named_world()
	var tick := _make_named_runner("main(){move(0,1)}\ntick(){\n  missing.attack(0)\n}", tick_world)
	_check(not tick.start().is_ok() and tick.message.contains("第 3 行，第 3 列"), "预检同时覆盖具名 tick 接收实例")
	tick_world.step()
	_check(tick_world.player.position == Vector2(5, 5), "tick 具名预检失败时 main 不会先移动")
	var tampered: ProgramAst.ProgramNode = ProgramParser.parse("main(){move(0,1)}").value
	var tampered_call := tampered.main.body.statements[0] as ProgramAst.CallNode
	tampered_call.receiver = "drive.extra"
	var invalid_ast := ProgramRunner.create(tampered, _make_named_world())
	_check(not invalid_ast.start().is_ok() and invalid_ast.message.contains("英文标识符"), "公开 AST 不能绕过接收实例标识符约束")


## 使用真实多模块世界验证顺序命令转发接收实例，保留广播速度及射击完成等待。
func _test_named_execution() -> void:
	var simulation := _make_named_world()
	var runner := _make_named_runner("main(){drive.move(0,.2)}", simulation)
	_check(runner.start().is_ok(), "指定单个移动模块能够开始")
	runner.step()
	_check(simulation.player.position.is_equal_approx(Vector2(5.1, 5)) and runner.state == ProgramRunner.State.RUNNING, "具名移动只贡献指定模块速度但移动整台机器")
	runner.step()
	_check(simulation.player.position.is_equal_approx(Vector2(5.2, 5)) and runner.state == ProgramRunner.State.COMPLETED, "具名移动仍准确完成指定距离")
	var broadcast_world := _make_named_world()
	var broadcast := _make_named_runner("main(){move(0,.2)}", broadcast_world)
	broadcast.start()
	broadcast.step()
	_check(broadcast_world.player.position.is_equal_approx(Vector2(5.2, 5)) and broadcast.state == ProgramRunner.State.COMPLETED, "不带实例名的移动继续叠加全部移动模块")
	var melee_world := _make_named_world()
	var melee := _make_named_runner("main(){left.attack(180)\nright.attack(0)}", melee_world)
	melee.start()
	melee.step()
	_check(melee_world.attack_traces.size() == 1 and melee_world.attack_traces[0].from == Vector2(4.5, 5) and melee_world.attack_traces[0].to.x < 4.5, "首条近战只从 left 模块向左发出")
	melee.step()
	_check(melee_world.attack_traces.size() == 1 and melee_world.attack_traces[0].from == Vector2(5.5, 5) and melee_world.attack_traces[0].to.x > 5.5, "次条近战下一 tick 只从 right 模块向右发出")
	var gun_world := _make_named_world()
	var gun := _make_named_runner("main(){gun.shoot(90)}", gun_world)
	gun.start()
	gun.step()
	_check(gun_world.projectiles.size() == 1 and gun_world.projectiles[0].direction == Vector2.UP and is_equal_approx(gun_world.projectiles[0].position.x, 5.0), "具名 main 射击只从选中射击模块发出一颗弹丸")
	_check(gun.state == ProgramRunner.State.RUNNING and gun_world.player.get_module("rear").next_shoot_tick == 0, "具名射击保留弹丸等待且不消耗另一枪冷却")
	for index: int in range(30):
		gun.step()
	_check(gun.state == ProgramRunner.State.COMPLETED, "具名单次弹丸结束后程序仍会正常完成")
	var changed_world := _make_named_world()
	var changed := _make_named_runner("main(){drive.move(0,0)\nleft.attack(180)}", changed_world)
	changed.start()
	changed.step()
	changed_world.player.get_module("left").available = false
	changed.step()
	_check(changed.state == ProgramRunner.State.FAILED and changed.message.contains("第 2 行"), "执行过程中指定模块失效会在后续调用行失败")
	_check(changed_world.attack_traces.is_empty() and changed_world.player.get_module("right").next_attack_tick == 0, "运行时指定模块失效也不会回退到另一个同类模块")


## 同 tick 的不同具名模块分别执行，重复引用和广播共享实际模块冷却与取消边界。
func _test_named_tick_execution() -> void:
	var simulation := _make_named_world()
	var runner := _make_named_runner("main(){}\ntick(){\nleft.attack(180)\nright.attack(0)\nleft.attack(90)\ngun.shoot(90)\nrear.shoot(270)\n}", simulation)
	runner.start()
	runner.step()
	_check(simulation.tick_index == 1 and simulation.attack_traces.size() == 2, "左右具名近战同 tick 分别执行，重复 left 不额外触发")
	_check(simulation.attack_traces[0].to.x < simulation.attack_traces[0].from.x and simulation.attack_traces[1].to.x > simulation.attack_traces[1].from.x, "不同接收模块保留各自的独立方向")
	_check(simulation.projectiles.size() == 2 and simulation.projectiles[0].direction == Vector2.UP and simulation.projectiles[1].direction == Vector2.DOWN, "同 tick 的两把具名枪分别向各自方向射击")
	runner.step()
	_check(simulation.projectiles.size() == 2, "连续具名射击不能绕过模块冷却")
	runner.cancel()
	var mixed_world := _make_named_world()
	var mixed := _make_named_runner("main(){}\ntick(){left.attack(180)\nattack(0)\nright.attack(90)}", mixed_world)
	mixed.start()
	mixed.step()
	_check(mixed_world.attack_traces.size() == 2 and mixed_world.attack_traces[0].to.x < 4.5 and mixed_world.attack_traces[1].to.x > 5.5, "具名与广播混用仍是每个实际模块首条方向生效")
	mixed.cancel()
	var priority_world := _make_named_world()
	var priority := _make_named_runner("main(){gun.shoot(0)}\ntick(){gun.shoot(180)\nrear.shoot(90)}", priority_world)
	priority.start()
	priority.step()
	_check(priority_world.projectiles.size() == 2 and priority_world.projectiles[0].direction == Vector2.RIGHT and priority_world.projectiles[1].direction == Vector2.UP, "main 与 tick 共用指定模块冷却，保留 main 先提交的顺序")
	priority.cancel()
	var cancel_world := _make_named_world()
	_callback_runner = _make_named_runner("main(){}\ntick(){\nleft.attack(180)\nright.attack(0)\n}", cancel_world)
	_callback_runner.line_changed.connect(_cancel_at_second_tick_call)
	_callback_runner.start()
	_callback_runner.step()
	cancel_world.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and cancel_world.attack_traces.is_empty(), "具名 tick 在第二条高亮取消时清除第一条排队攻击")
	_callback_runner.line_changed.disconnect(_cancel_at_second_tick_call)
	_callback_runner = null


## 为第五关语法提供两移动、两近战和两射击模块，区分精确接收与广播的真实结果。
func _make_named_world() -> SimulationWorld:
	var document := _make_world().document.duplicate_document()
	document.player_spawn.position = {"x": 5, "y": 5}
	document.player_spawn.modules = [
		{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}},
		{"id": "drive2", "module_id": "movement", "offset": {"x": 0, "y": -0.5}},
		{"id": "left", "module_id": "melee", "offset": {"x": -0.5, "y": 0}},
		{"id": "right", "module_id": "melee", "offset": {"x": 0.5, "y": 0}},
		{"id": "gun", "module_id": "shooting", "offset": {"x": 0, "y": 0.5}},
		{"id": "rear", "module_id": "shooting", "offset": {"x": 0.5, "y": 0.5}},
	]
	var created := SimulationWorld.create(document, _registry)
	_check(created.is_ok(), "第五关语言夹具具有多个实际可用模块")
	return created.value as SimulationWorld


## 仅第五关测试主动开启具名调用，旧语言测试继续使用原默认权限。
func _make_named_runner(source: String, simulation: SimulationWorld) -> ProgramRunner:
	var parsed := ProgramParser.parse(source, PackedStringArray(["move", "attack", "shoot"]), true, true)
	_check(parsed.is_ok(), "第五关运行测试源码能够静态编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, simulation)


## 检查 CRLF、注释、空行、带符号小数与独立 AST 层级及其行列信息。
func _test_tokens_and_ast() -> void:
	var source := "// 注释\r\n\r\nmain()\r\n{\r\n  move(-90.5, +.25) // 末尾注释\r\n  move(\r\n    0,\r\n    1.\r\n  )\r\n}\r\n"
	var lexed := ProgramLexer.tokenize(source)
	_check(lexed.is_ok(), "词法分析支持注释、CRLF 与小数")
	if lexed.is_ok():
		var tokens: Array[ProgramLexer.Token] = lexed.value
		_check(tokens[2].lexeme == "main" and tokens[2].line == 3 and tokens[2].column == 1, "CRLF 只累计一行，main 位置准确")
		_check(tokens.back().kind == ProgramLexer.Kind.END, "词法输出具有明确结束标记")
	var parsed := ProgramParser.parse(source)
	_check(parsed.is_ok(), "多行 main 与多行参数可解析")
	if parsed.is_ok():
		var ast: ProgramAst.ProgramNode = parsed.value
		_check(ast.main.name == "main" and ast.main.body != null, "AST 显式保留函数和代码块")
		_check(ast.main.body.statements.size() == 2, "代码块持有两条独立调用")
		var call := ast.main.body.statements[0] as ProgramAst.CallNode
		_check(call.line == 5 and call.column == 3 and call.callee == "move", "调用节点准确记录从1开始的行列")
		_check(call.arguments[0].value == -90.5 and call.arguments[1].value == 0.25, "正负小数字面量具有正确数值")
		_check(call.arguments[0].line == 5 and call.arguments[0].column == 8, "带符号数字位置指向其符号")
		_check((ast.main.body.statements[1] as ProgramAst.CallNode).arguments[1].value == 1.0, "支持小数点结尾的有限数字")
	_check(ProgramParser.parse("main(){move(0,1)}").is_ok(), "一个调用可以写在单行代码块内")
	_check(ProgramParser.parse("\nmain(\n)\n{\n\n}\n").is_ok(), "空 main 和自然换行可解析")
	_check(ProgramParser.parse("main(){\rmove(0,1)\r}").is_ok(), "兼容单独 CR 换行")


## 检查错误位置、未解锁语法和所有输入规模限制，防止静默执行未知代码。
func _test_rejections_and_limits() -> void:
	_expect_error("main() {\n  move(0, 1);\n}", "第 2 行，第 13 列", "分号保留准确位置")
	_expect_error("main() {\n move(0,1) move(90,1)\n}", "每行只能写一条", "同一行两条调用被拒绝")
	_expect_error("move(0,1)", "main()", "不能在入口外直接执行指令")
	_expect_error("main() {\nmove(0,1)\n", "缺少右花括号", "不完整代码块给出明确错误")
	_expect_error("main() {}\nmain() {}", "第二个入口", "重复 main 被拒绝")
	_expect_error("main(x) {}", "不接受参数", "入口不能声明参数")
	_expect_error("main() {move(1)}", "需要 2 个参数", "参数过少被拒绝")
	_expect_error("main() {move(1,2,3)}", "需要 2 个参数", "参数过多被拒绝")
	_expect_error("main() {move(1,)}", "逗号后缺少", "尾逗号不会被误当作完整参数")
	_expect_error("main() {move(1 + 2, 1)}", "数字字面量", "数字表达式尚未解锁")
	_expect_error("main() {move(angle, 1)}", "变量和表达式尚未解锁", "变量不能隐式变成数字")
	_expect_error("main() {drive.move(0,1)}", "命名模块调用尚未解锁", "具名模块调用明确报告未解锁")
	_expect_error("main() {time.wait(1)}", "命名模块调用尚未解锁", "等待接口没有被绕过解锁")
	_expect_error("main() {shoot(0)}", "尚未解锁指令", "前三关默认仍未解锁射击")
	_expect_error("main() {radar(0)}", "未知或尚未实现", "未知调用不会被默默接受")
	_expect_error("main() {# 注释\n}", "不支持的字符", "第一关只接受斜线注释")
	_expect_error("main() {move(0,\"1\")}", "不支持的字符", "字符串不会被隐式转成数字")
	_expect_error("main() {move(0,1e3)}", "数字字面量", "未声明的指数形式被拒绝")
	for keyword: String in ["simultaneously", "loop", "if", "else", "for", "while", "function", "fun", "var", "return"]:
		_expect_error("main() {\n  " + keyword + "\n}", "尚未解锁", "控制或声明关键字明确未解锁：" + keyword)
	var locked := ProgramParser.parse("main(){move(0,1)}", PackedStringArray())
	_check(not locked.is_ok() and locked.errors[0].contains("尚未解锁指令"), "allowed_calls 可以收回 move 的使用权限")
	var oversized := ProgramLexer.tokenize("/".repeat(ProgramLexer.MAX_SOURCE_BYTES + 1))
	_check(not oversized.is_ok() and oversized.errors[0].contains("64 KiB"), "源代码字节数限制在词法分析前生效")
	var too_many_tokens := ProgramLexer.tokenize("\n".repeat(ProgramLexer.MAX_TOKENS))
	_check(not too_many_tokens.is_ok() and too_many_tokens.errors[0].contains("token"), "token 上限包括明确结束标记")
	var at_limit := ProgramParser.parse("main(){\n" + "move(0,0)\n".repeat(ProgramParser.MAX_CALLS) + "}")
	_check(at_limit.is_ok(), "最多512条合法调用仍能正常解析")
	_expect_error("main(){\n" + "move(0,0)\n".repeat(ProgramParser.MAX_CALLS + 1) + "}", "512", "调用数量超限被拒绝")
	_expect_error("main(){move(0," + "9".repeat(400) + ")}", "有限数值范围", "溢出数字不会进入语法树")
	var unicode_source := "// " + "中".repeat(22000)
	_check(not ProgramLexer.tokenize(unicode_source).is_ok(), "源码上限按UTF8字节计数，不按Unicode字符数放宽")


## 验证第四关射击及独立 tick 入口，同时保护旧关卡解锁和共享编译预算。
func _test_tick_parser() -> void:
	var calls := PackedStringArray(["move", "attack", "shoot"])
	var parsed := ProgramParser.parse("main() {move(0,.2)}\ntick() {\n  shoot(90)\n  attack(0)\n}", calls, true)
	_check(parsed.is_ok(), "解锁后 main 和 tick 分别解析成函数")
	if parsed.is_ok():
		var ast: ProgramAst.ProgramNode = parsed.value
		_check(ast.tick != null and ast.tick.name == "tick" and ast.main.name == "main", "tick 是独立 AST 函数，不混入 main 语句")
		_check(ast.tick.body.statements[0].line == 3 and ast.tick.body.statements[0].column == 3, "回调调用保留精确源代码位置")
		_check((ast.tick.body.statements[0] as ProgramAst.CallNode).arguments[0].value == 90.0, "shoot 角度保留数值参数")
	_check(ProgramParser.parse("tick() {}\nmain() {}", calls, true).is_ok(), "函数声明顺序不改变 main 入口")
	var rejected: Array[Dictionary] = [
		{"source": "main() {}\ntick() {}", "allow": false, "reason": "尚未解锁 tick"},
		{"source": "tick() {}", "allow": true, "reason": "不能替代 main"},
		{"source": "main() {}\ntick() {}\ntick() {}", "allow": true, "reason": "第二个入口"},
		{"source": "main() {}\ntick(x) {}", "allow": true, "reason": "不接受参数"},
		{"source": "main() {}\ntick() {move(0,1)}", "allow": true, "reason": "必须立即结束"},
		{"source": "main() {}\ntick() {tick()}", "allow": true, "reason": "未知或尚未实现"},
		{"source": "main() {}\ntick() {loop {shoot(0)}}", "allow": true, "reason": "尚未解锁"},
		{"source": "main() {shoot(0,1)}", "allow": true, "reason": "需要 1 个参数"},
		{"source": "main() {}\non_hit() {}", "allow": true, "reason": "其它函数"},
	]
	for sample: Dictionary in rejected:
		var result := ProgramParser.parse(sample.source, calls, sample.allow)
		_check(not result.is_ok() and result.errors[0].contains(sample.reason) and result.errors[0].contains("第 "), "无效第四关语法报告行列及原因：" + sample.reason)
	var shoot_locked := ProgramParser.parse("main() {}\ntick() {shoot(0)}", PackedStringArray(["move"]), true)
	_check(not shoot_locked.is_ok() and shoot_locked.errors[0].contains("尚未解锁指令"), "解锁 tick 本身不会绕过 shoot 的权限")
	var shared_budget := "main(){\n" + "shoot(0)\n".repeat(256) + "}\ntick(){\n" + "shoot(0)\n".repeat(256) + "}"
	_check(ProgramParser.parse(shared_budget, calls, true).is_ok(), "main 和 tick 合计512条调用可解析")
	var over_budget := shared_budget.trim_suffix("}") + "shoot(0)\n}"
	var too_many := ProgramParser.parse(over_budget, calls, true)
	_check(not too_many.is_ok() and too_many.errors[0].contains("512"), "两个入口共享预算，不能各自放512条绕过限制")


## 验证 start 不耗时、每条调用等待完成、下一条在下一 tick 才开始。
func _test_sequential_execution() -> void:
	var simulation := _make_world()
	var original_position := simulation.player.position
	var runner := _make_runner("main(){\nmove(0,0.1)\nmove(90,0.1)\n}", simulation)
	_reset_observations()
	runner.finished.connect(_on_finished)
	runner.line_changed.connect(_on_line_changed)
	_check(runner.start().is_ok(), "合法程序可以开始")
	_check(simulation.tick_index == 0 and simulation.player.position == original_position, "start 只提交指令，不移动机器或推进 tick")
	_check(_line_events == [2], "开始时只高亮首条调用")
	runner.step()
	_check(simulation.tick_index == 1 and simulation.player.position.is_equal_approx(original_position + Vector2(0.1, 0)), "第一 tick 只执行第一条 move")
	_check(runner.state == ProgramRunner.State.RUNNING and _line_events == [2], "前一条完成时不抢先派发下一条")
	runner.step()
	_check(simulation.tick_index == 2 and simulation.player.position.is_equal_approx(original_position + Vector2(0.1, -0.1)), "下一 tick 才提交和执行第二条 move")
	_check(runner.state == ProgramRunner.State.COMPLETED and _line_events == [2, 3], "完成所有调用后进入完成状态")
	runner.step()
	runner.cancel()
	_check(_finished_count == 1 and simulation.tick_index == 2, "终态重复step或cancel不会推进时间或重复发完成信号")
	var empty_world := _make_world()
	var empty := _make_runner("main() {}", empty_world)
	_check(empty.start().is_ok() and empty.state == ProgramRunner.State.COMPLETED and empty_world.tick_index == 0, "空入口立即完成且消耗零 tick")
	var zero_world := _make_world()
	var zero := _make_runner("main(){\nmove(0,0)\nmove(0,0)\n}", zero_world)
	zero.start()
	zero.step()
	_check(zero.state == ProgramRunner.State.RUNNING and zero_world.tick_index == 1, "零距离调用也不能在同 tick 内连锁执行")
	zero.step()
	_check(zero.state == ProgramRunner.State.COMPLETED and zero_world.tick_index == 2, "两个零距离调用按两个tick顺序完成")


## 验证 void 阻挡终止后续语句，取消只影响玩家且不会继续移动。
func _test_blocked_and_cancelled() -> void:
	var simulation := _make_world()
	var start_y := simulation.player.position.y
	var runner := _make_runner("main(){\n// 向边界移动\nmove(180,10)\nmove(90,1)\n}", simulation)
	_reset_observations()
	runner.finished.connect(_on_finished)
	runner.start()
	for tick: int in range(200):
		runner.step()
	_check(runner.state == ProgramRunner.State.FAILED and runner.message.contains("第 3 行"), "阻挡使程序失败并指出失败源码行")
	_check(simulation.player.position.y == start_y and simulation.player.position.x >= 0.249, "阻挡后不执行后续向上调用，也不进入void")
	_check(_finished_count == 1, "阻挡后后续step不重复发送失败信号")
	var cancel_world := _make_world()
	var cancelled := _make_runner("main(){\nmove(0,3)\nmove(90,1)\n}", cancel_world)
	_reset_observations()
	cancelled.finished.connect(_on_finished)
	cancelled.start()
	cancelled.step()
	var stop_position := cancel_world.player.position
	var stop_tick := cancel_world.tick_index
	cancelled.cancel()
	cancelled.cancel()
	cancelled.step()
	_check(cancelled.state == ProgramRunner.State.CANCELLED and _finished_count == 1, "重复取消只有一个取消终态通知")
	_check(cancel_world.tick_index == stop_tick, "取消和已取消程序的step不推进时间")
	cancel_world.step()
	_check(cancel_world.player.position == stop_position, "取消确实移除世界中的待执行动作")
	var ready := _make_runner("main(){move(0,1)}", _make_world())
	ready.cancel()
	_check(ready.state == ProgramRunner.State.CANCELLED and not ready.start().is_ok(), "未开始的程序也能取消，取消后不能重新start")
	var external_world := _make_world()
	var external := _make_runner("main(){move(0,2)}", external_world)
	external.start()
	external_world.cancel_move(external_world.player.id)
	external.step()
	_check(external.state == ProgramRunner.State.CANCELLED and external_world.tick_index == 0, "外部取消命令传递为程序取消终态，且不多推进一个tick")
	# 世界可以持有其它机器，程序取消不能粗暴调用 world.stop() 清空所有动作。
	var shared_world := _make_world()
	var other_config: Dictionary = shared_world.document.player_spawn.duplicate(true)
	other_config.position = {"x": 5.5, "y": 6.5}
	var other := MachineFactory.create_machine("other", other_config, shared_world.document, _registry, ModuleBehaviorRegistry.create_default())
	_check(other.is_ok() and shared_world.add_machine(other.value).is_ok(), "取消隔离测试可以添加第二台机器")
	shared_world.request_move("other", 0, 1)
	var isolated := _make_runner("main(){move(0,1)}", shared_world)
	isolated.start()
	isolated.cancel()
	shared_world.step()
	_check(shared_world.player.position == Vector2(1.5, 6.5), "取消玩家程序后玩家不再移动")
	_check(shared_world.get_machine("other").position.is_equal_approx(Vector2(5.6, 6.5)), "取消玩家程序保留其它机器的独立动作")


## 检查全程序预检的零副作用，以及用新世界和新运行器可靠重试。
func _test_start_validation_and_retry() -> void:
	var simulation := _make_world()
	var original := simulation.player.position
	var invalid := _make_runner("main(){\nmove(0,1)\nmove(90,-1)\n}", simulation)
	_check(not invalid.start().is_ok() and invalid.state == ProgramRunner.State.FAILED, "负距离在执行前被整程序预检拒绝")
	simulation.step()
	_check(simulation.player.position == original, "后续调用预检失败时首条调用也未提交")
	var null_world := ProgramRunner.create(ProgramParser.parse("main(){}").value, null)
	_check(not null_world.start().is_ok(), "运行器拒绝缺少模拟世界")
	var broken_ast := ProgramAst.ProgramNode.new()
	_check(not ProgramRunner.create(broken_ast, _make_world()).start().is_ok(), "运行器拒绝缺少入口的外部AST")
	var first := _make_runner("main(){move(0,0.1)}", _make_world())
	first.start()
	first.step()
	_check(not first.start().is_ok(), "结束的运行器不能复用旧状态重新开始")
	var retry_world := _make_world()
	var retry := _make_runner("main(){move(0,0.1)}", retry_world)
	_check(retry_world.player.position == original and retry_world.tick_index == 0, "新世界重试从初始位置与零tick开始")
	retry.start()
	retry.step()
	_check(retry.state == ProgramRunner.State.COMPLETED and retry_world.player.position.is_equal_approx(original + Vector2(0.1, 0)), "新运行器重试得到确定性相同结果")


## 检查行高亮和世界tick回调中的取消不会留下动作或访问已释放句柄。
func _test_callback_cancellation() -> void:
	var line_world := _make_world()
	_callback_runner = _make_runner("main(){move(0,1)}", line_world)
	_callback_runner.line_changed.connect(_cancel_at_line)
	_callback_runner.start()
	line_world.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and line_world.player.position == Vector2(1.5, 6.5), "行高亮回调取消后不会再提交move")
	var tick_world := _make_world()
	_callback_runner = _make_runner("main(){move(0,1)}", tick_world)
	tick_world.tick_completed.connect(_cancel_at_tick)
	_callback_runner.start()
	_callback_runner.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and tick_world.tick_index == 1, "tick回调取消后runner安全结束当前step")
	tick_world.tick_completed.disconnect(_cancel_at_tick)
	_callback_runner = null


## 验证公开同步信号中的step调用既不能递归派发，也不能额外推进tick。
func _test_callback_step_reentry() -> void:
	var simulation := _make_world()
	_callback_runner = _make_runner("main(){\nmove(0,0.1)\nmove(90,0.1)\n}", simulation)
	_callback_runner.line_changed.connect(_step_at_line)
	simulation.tick_completed.connect(_step_at_tick)
	_check(_callback_runner.start().is_ok() and simulation.tick_index == 0, "行信号中的重入step不递归执行首条调用")
	_callback_runner.step()
	_check(simulation.tick_index == 1 and _callback_runner.state == ProgramRunner.State.RUNNING, "tick信号中的重入step不能提前执行下一条语句")
	_callback_runner.step()
	_check(simulation.tick_index == 2 and _callback_runner.state == ProgramRunner.State.COMPLETED, "两个公开step仍恰好完成两个短动作")
	_check(simulation.player.position.is_equal_approx(Vector2(1.6, 6.4)), "重入信号不会重复提交旧调用或错位执行")
	simulation.tick_completed.disconnect(_step_at_tick)
	_callback_runner.line_changed.disconnect(_step_at_line)
	_callback_runner = null


## 验证持续射击与移动共用同一世界 tick，main 结束后回调继续且冷却有效。
func _test_tick_execution() -> void:
	var simulation := _make_combat_world()
	var runner := _make_combat_runner("main(){move(0,.2)}\ntick(){\nshoot(0)\n}", simulation)
	_reset_observations()
	runner.line_changed.connect(_on_line_changed)
	_check(runner.start().is_ok() and simulation.tick_index == 0 and simulation.projectiles.is_empty(), "start 不执行 tick 或提前产生弹丸")
	runner.step()
	_check(simulation.tick_index == 1 and simulation.player.position.is_equal_approx(Vector2(1.6, 6.5)), "tick 射击不阻挡 main 移动，也不增加世界推进次数")
	_check(simulation.has_pending_projectiles(simulation.player.id) and simulation.projectiles.size() == 1, "第一逻辑帧从真实射击模块产生弹丸")
	runner.step()
	_check(simulation.tick_index == 2 and simulation.player.position.is_equal_approx(Vector2(1.7, 6.5)), "main 第二步按既有速度准确完成移动")
	_check(runner.state == ProgramRunner.State.RUNNING and simulation.projectiles.size() == 1, "main 结束后 tick 保持运行，冷却期间不会额外开火")
	_check(_line_events == [1, 3, 3], "main 与每次 tick 各自通知正确的源代码行")
	runner.step()
	_check(simulation.tick_index == 3 and simulation.player.position.is_equal_approx(Vector2(1.7, 6.5)), "主程序结束后继续推进弹丸而不重复移动")
	runner.cancel()
	var stopped_at := simulation.tick_index
	runner.step()
	_check(simulation.tick_index == stopped_at and runner.state == ProgramRunner.State.CANCELLED, "持续回调取消后不再推进世界")
	var one_shot_world := _make_combat_world()
	var one_shot := _make_combat_runner("main(){shoot(0)}", one_shot_world)
	one_shot.start()
	one_shot.step()
	_check(one_shot.state == ProgramRunner.State.RUNNING and one_shot_world.has_pending_projectiles("player"), "单次 main 射击在弹丸飞行时不抢先完成")
	for index: int in range(30):
		one_shot.step()
	_check(one_shot.state == ProgramRunner.State.COMPLETED and not one_shot_world.has_pending_projectiles("player"), "单次弹丸耗尽后程序正常完成，不会永久等待")
	_check(one_shot_world.tick_index > 1 and one_shot_world.tick_index <= 20, "等待弹丸期间仍按有界寿命推进固定 tick")
	var empty_world := _make_world()
	var empty := _make_combat_runner("main(){}\ntick(){}", empty_world)
	_check(empty.start().is_ok() and empty.state == ProgramRunner.State.RUNNING, "空 tick 也是持续事件入口，不能冻结敌人世界")
	empty.step()
	_check(empty_world.tick_index == 1 and empty.state == ProgramRunner.State.RUNNING, "空 tick 每步仍且只推进一个世界 tick")
	empty.cancel()
	var combined_world := _make_combat_world()
	var combined := _make_combat_runner("main(){}\ntick(){\nshoot(0)\nshoot(90)\nattack(0)\n}", combined_world)
	combined.start()
	combined.step()
	_check(combined.state == ProgramRunner.State.RUNNING and combined_world.tick_index == 1, "多个短回调共享一个 tick，不产生机器忙碌错误")
	_check(combined_world.projectiles.size() == 1 and combined_world.projectiles[0].direction == Vector2.RIGHT, "同帧重复 shoot 合并且保留首条方向，不能绕过冷却")
	_check(not combined_world.attack_traces.is_empty(), "同帧允许射击与近战各一次，不把回调伪装成移动动作")
	combined.cancel()


## 验证整树预检覆盖 tick，回调高亮取消会清空已排队输入，同步重入无副作用。
func _test_tick_cancellation_and_validation() -> void:
	var no_shooter := _make_world()
	var invalid := _make_combat_runner("main(){move(0,1)}\ntick(){\nshoot(0)\n}", no_shooter)
	var result := invalid.start()
	_check(not result.is_ok() and result.errors[0].contains("第 3 行") and result.errors[0].contains("射击模块"), "缺射击模块在全程序预检阶段定位到回调行")
	no_shooter.step()
	_check(no_shooter.player.position == Vector2(1.5, 6.5), "后面 tick 预检失败不会抢先执行 main 移动")
	var tampered: ProgramAst.ProgramNode = ProgramParser.parse("main(){move(0,.1)}").value
	tampered.tick = ProgramAst.FunctionNode.new()
	tampered.tick.name = "tick"
	tampered.tick.body = tampered.main.body
	var bad_ast := ProgramRunner.create(tampered, _make_world())
	_check(not bad_ast.start().is_ok() and bad_ast.message.contains("tick()"), "外部构造 AST 也不能绕过回调禁止阻塞移动的检查")
	var line_world := _make_combat_world()
	_callback_runner = _make_combat_runner("main(){}\ntick(){\nshoot(0)\nshoot(90)\n}", line_world)
	_callback_runner.line_changed.connect(_cancel_at_second_tick_call)
	_callback_runner.start()
	_callback_runner.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and line_world.tick_index == 0, "第二条回调高亮时取消，不再执行当前逻辑 tick")
	line_world.step()
	_check(line_world.projectiles.is_empty(), "取消清除之前已排队的第一条回调，外部步进也不会补发弹丸")
	_callback_runner.line_changed.disconnect(_cancel_at_second_tick_call)
	var reentry_world := _make_combat_world()
	_callback_runner = _make_combat_runner("main(){}\ntick(){shoot(0)}", reentry_world)
	_callback_runner.line_changed.connect(_step_at_line)
	reentry_world.tick_completed.connect(_step_at_tick)
	_callback_runner.start()
	_callback_runner.step()
	_check(reentry_world.tick_index == 1 and reentry_world.projectiles.size() == 1, "tick 高亮与世界事件中重入 step 不递归回调或重复发射")
	_callback_runner.cancel()
	_callback_runner.line_changed.disconnect(_step_at_line)
	reentry_world.tick_completed.disconnect(_step_at_tick)
	_callback_runner = null


## 在地板夹具中安装真实移动、射击和近战模块，以验证能力驱动而非语法模拟。
func _make_combat_world() -> SimulationWorld:
	var document := _make_world().document.duplicate_document()
	document.player_spawn.modules.append({"id": "gun", "module_id": "shooting", "offset": {"x": 0.5, "y": 0}})
	document.player_spawn.modules.append({"id": "blade", "module_id": "melee", "offset": {"x": -0.5, "y": 0}})
	var created := SimulationWorld.create(document, _registry)
	_check(created.is_ok(), "语言战斗夹具能够建立真实模块世界")
	return created.value as SimulationWorld


## 显式解锁第四关语言后创建运行器，不改变旧测试与旧关卡的默认权限。
func _make_combat_runner(source: String, simulation: SimulationWorld) -> ProgramRunner:
	var parsed := ProgramParser.parse(source, PackedStringArray(["move", "attack", "shoot"]), true)
	_check(parsed.is_ok(), "第四关运行测试源码可静态编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, simulation)


## 在第二条 tick 调用前取消，验证前一条已提交输入也能被清理。
func _cancel_at_second_tick_call(line: int) -> void:
	if line == 4:
		_callback_runner.cancel()


## 创建不含特殊玩法的地板世界，使运行断言只依赖公开模拟契约。
func _make_world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 10
	document.height = 10
	for y: int in range(document.height):
		for x: int in range(document.width):
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {
		"position": {"x": 1.5, "y": 6.5},
		"modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}],
	}
	var created := SimulationWorld.create(document, _registry)
	_check(created.is_ok(), "语言测试地图可以创建世界")
	return created.value as SimulationWorld


## 编译已知有效的测试源码，再创建不会自动开始的运行器。
func _make_runner(source: String, simulation: SimulationWorld) -> ProgramRunner:
	var parsed := ProgramParser.parse(source)
	_check(parsed.is_ok(), "运行测试源码能够静态编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, simulation)


## 验证源码失败且包含预期诊断片段，避免只检查失败却忽略定位质量。
func _expect_error(source: String, fragment: String, reason: String) -> void:
	var result := ProgramParser.parse(source)
	_check(not result.is_ok() and result.errors[0].contains(fragment), reason)
	if not result.is_ok() and not result.errors[0].contains(fragment):
		push_error("实际错误：" + result.errors[0])


## 重置事件观测值，使各个运行器的完成次数断言相互独立。
func _reset_observations() -> void:
	_finished_count = 0
	_line_events.clear()


## 记录程序完成信号，验证一次性通知契约。
func _on_finished(_success: bool, _message: String) -> void:
	_finished_count += 1


## 记录执行高亮顺序，确认后续调用不会被提前派发。
func _on_line_changed(line: int) -> void:
	_line_events.append(line)


## 在行高亮事件中取消程序，模拟用户或调试工具的同步停止操作。
func _cancel_at_line(_line: int) -> void:
	_callback_runner.cancel()


## 在世界tick事件中取消程序，覆盖运行器step的重入保护。
func _cancel_at_tick(_tick: int) -> void:
	_callback_runner.cancel()


## 模拟调试器在行号事件内请求step，验证运行器拒绝同步递归派发。
func _step_at_line(_line: int) -> void:
	_callback_runner.step()


## 模拟世界订阅者在tick内请求step，验证外层一次调用只推进一次时间。
func _step_at_tick(_tick: int) -> void:
	_callback_runner.step()


## 累计断言结果，确保脚本错误之外的失败也能被自动化命令识别。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 第七关解锁 ready 条件与可选 else，保留旧关权限、行列和控制结构预算。
func _test_conditional_parser() -> void:
	var calls := PackedStringArray(["move", "attack", "shoot"])
	var source := "main(){\n  if (gun.ready()) {\n    gun.shoot(0)\n  } else {\n    drive.move(90, .1)\n  }\n}"
	var parsed := ProgramParser.parse(source, calls, true, true, true, true)
	_check(parsed.is_ok(), "第七关允许命名冷却条件与两条独立动作分支")
	if parsed.is_ok():
		var ast: ProgramAst.ProgramNode = parsed.value
		var branch := ast.main.body.statements[0] as ProgramAst.IfNode
		_check(branch != null and branch.line == 2 and branch.column == 3, "if 在 AST 中保留独立语句类型与原始位置")
		var condition := branch.condition as ProgramAst.ReadyNode
		_check(condition != null and condition.receiver == "gun" and condition.line == 2 and condition.column == 7, "ready 为独立只读条件节点，位置指向具体模块名")
		_check(branch.then_body.statements[0].line == 3 and branch.else_body.statements[0].line == 5, "真假分支保留各自的完整代码块及动作位置")
	for allow_loops: bool in [false, true]:
		var locked := ProgramParser.parse(source, calls, true, true, allow_loops)
		_check(not locked.is_ok() and locked.errors[0].contains("尚未解锁") and locked.errors[0].contains("if"), "旧关省略新权限时，即使循环已解锁仍拒绝 if")
	var named_locked := ProgramParser.parse(source, calls, true, false, true, true)
	_check(not named_locked.is_ok() and named_locked.errors[0].contains("命名模块调用权限"), "条件权限不能越过具名模块调用权限")
	_check(ProgramParser.parse(source.replace("} else {", "}\n// 冷却期间移动\nelse\n{"), calls, false, true, false, true).is_ok(), "else 与花括号之间允许换行和自然注释")
	_check(ProgramParser.parse("main(){if\n(\ngun.ready(\n)\n)\n{move(0,.1)}else{move(90,+.1)}}", calls, false, true, false, true).is_ok(), "条件可自然换行，数字语法和紧邻 else 仍保持兼容")
	var optional := ProgramParser.parse("main(){if(gun.ready()){move(0,.1)}\nmove(90,.1)}", calls, false, true, false, true)
	_check(optional.is_ok() and optional.value.main.body.statements.size() == 2, "省略 else 保留下一条语句的换行边界")
	if optional.is_ok():
		var optional_branch := optional.value.main.body.statements[0] as ProgramAst.IfNode
		_check(optional_branch.else_body != null and optional_branch.else_body.statements.is_empty(), "省略 else 使用有效空代码块表示假分支")
	var samples: Array[Dictionary] = [
		{"code": "if(gun.ready()){move(0,1)} move(0,0)", "reason": "每行只能写一条"},
		{"code": "if(gun.ready()){}else{move(0,1)}", "reason": "都不能为空"},
		{"code": "if(gun.ready()){move(0,1)}else{// 空白\n}", "reason": "都不能为空"},
		{"code": "if(gun.ready()){move(0,1)}else if(gun.ready()){move(90,1)}", "reason": "需要代码块"},
		{"code": "if(ready()){move(0,1)}else{move(90,1)}", "reason": "必须指定模块名"},
		{"code": "if(gun.ready(1)){move(0,1)}else{move(90,1)}", "reason": "不接受参数"},
		{"code": "if(gun.shoot(0)){move(0,1)}else{move(90,1)}", "reason": "只支持"},
		{"code": "if(gun.ready){move(0,1)}else{move(90,1)}", "reason": "空括号"},
		{"code": "if(gun.arm.ready()){move(0,1)}else{move(90,1)}", "reason": "只支持"},
		{"code": "if(true){move(0,1)}else{move(90,1)}", "reason": "非保留"},
		{"code": "if(gun.ready()) {move(0,1)}else{move(90,1)} move(0,1)", "reason": "每行只能写一条"},
		{"code": "if(gun.ready()){move(0,1)}else{move(90,1)};", "reason": "不允许分号"},
		{"code": "gun.ready()", "reason": "未知或尚未实现"},
	]
	for sample: Dictionary in samples:
		var rejected := ProgramParser.parse("main(){\n  " + sample.code + "\n}", calls, true, true, true, true)
		_check(not rejected.is_ok() and rejected.errors[0].contains(sample.reason) and rejected.errors[0].contains("第 "), "非法条件语法有具体诊断：" + sample.code)
	var missing_outer := ProgramParser.parse("main(){if(gun.ready()){move(0,1)}else{move(90,1)}", calls, true, true, true, true)
	_check(not missing_outer.is_ok() and missing_outer.errors[0].contains("缺少右花括号"), "完整 else 后 EOF 仍准确报告 main 缺少右括号")
	var nested := "main(){" + "if(gun.ready()){\n".repeat(16) + "move(0,0)\n" + "}else{move(90,0)}\n".repeat(16) + "}"
	_check(ProgramParser.parse(nested, calls, false, true, true, true).is_ok(), "16层 if 在结构深度上限内可解析")
	var deep := "main(){if(gun.ready()){\n" + nested.trim_prefix("main(){").trim_suffix("}") + "}else{move(0,0)}\n}"
	var deep_result := ProgramParser.parse(deep, calls, false, true, true, true)
	_check(not deep_result.is_ok() and deep_result.errors[0].contains("16 层"), "第17层 if 在递归前拒绝")
	var mixed := "main(){" + "loop{\n".repeat(8) + "if(gun.ready()){\n".repeat(9) + "move(0,0)\n" + "}else{move(0,0)}\n".repeat(9) + "}\n".repeat(8) + "}"
	_check(not ProgramParser.parse(mixed, calls, false, true, true, true).is_ok(), "混用 loop 与 if 不能绕过共同16层预算")
	var tick_valid := "main(){}\ntick(){if(gun.ready()){gun.shoot(0)}else{attack(0)}}"
	_check(ProgramParser.parse(tick_valid, calls, true, true, true, true).is_ok(), "tick 允许有限且只含攻击动作的 if/else")
	for code: String in ["move(0,1)", "loop{shoot(0)}"]:
		var tick_bad := ProgramParser.parse(tick_valid.replace("attack(0)", code), calls, true, true, true, true)
		_check(not tick_bad.is_ok() and tick_bad.errors[0].contains("tick()"), "tick 隐藏在分支里的等待动作仍被拒绝：" + code)


## 整树预检覆盖条件接收者与真假路径；公开 AST 不能引入空转、递归或隐藏非法能力。
func _test_conditional_preflight() -> void:
	for condition: String in ["missing.ready()", "Gun.ready()", "drive.ready()"]:
		var world := _make_combat_world()
		var runner := _make_conditional_runner("main(){\nmove(0,.1)\n  if(" + condition + "){shoot(0)}else{move(0,0)}\n}", world)
		_check(not runner.start().is_ok() and runner.message.contains("第 3 行，第 6 列"), "条件的拼写或真实能力错误在任何动作前定位：" + condition)
		world.step()
		_check(world.player.position == Vector2(1.5, 6.5) and world.projectiles.is_empty(), "无效条件不会让前面的合法动作提前提交")
	for branch_code: String in ["if(gun.ready()){missing.shoot(0)}else{move(0,0)}", "if(gun.ready()){shoot(0)}else{drive.attack(0)}"]:
		var world := _make_combat_world()
		var runner := _make_conditional_runner("main(){move(0,.1)\n" + branch_code + "}", world)
		_check(not runner.start().is_ok(), "真假路径都必须通过名称与能力预检")
		world.step()
		_check(world.player.position == Vector2(1.5, 6.5) and world.projectiles.is_empty(), "未选中分支非法时也不执行程序前缀")
	var unavailable_world := _make_combat_world()
	unavailable_world.player.get_module("gun").available = false
	var unavailable := _make_conditional_runner("main(){if(gun.ready()){move(0,0)}else{move(90,0)}}", unavailable_world)
	_check(not unavailable.start().is_ok() and unavailable.message.contains("ready 查询失败"), "条件引用已经损坏的枪时不会静默当作未冷却")
	for invalid_kind: int in range(6):
		var ast: ProgramAst.ProgramNode = ProgramParser.parse("main(){}").value
		var branch := ProgramAst.IfNode.new()
		branch.condition = ProgramAst.ReadyNode.new()
		(branch.condition as ProgramAst.ReadyNode).receiver = "gun"
		branch.then_body = ProgramParser.parse("main(){move(0,0)}").value.main.body
		branch.else_body = ProgramParser.parse("main(){move(0,0)}").value.main.body
		match invalid_kind:
			0:
				branch.condition = null
			1:
				branch.condition = ProgramAst.ConditionNode.new()
			2:
				(branch.condition as ProgramAst.ReadyNode).receiver = ""
			3:
				(branch.condition as ProgramAst.ReadyNode).receiver = "gun.extra"
			4:
				branch.then_body = null
			5:
				branch.then_body.statements.clear()
		ast.main.body.statements.append(branch)
		_check(not ProgramRunner.create(ast, _make_combat_world()).start().is_ok(), "公开 if AST 的空条件、错误类型、空分支不能运行：%d" % invalid_kind)
	var cyclic_ast := _conditional_ast("main(){if(gun.ready()){move(0,0)}else{move(0,0)}}")
	var cyclic_branch := cyclic_ast.main.body.statements[0] as ProgramAst.IfNode
	cyclic_branch.else_body = cyclic_ast.main.body
	var cyclic := ProgramRunner.create(cyclic_ast, _make_combat_world())
	_check(not cyclic.start().is_ok() and cyclic.message.contains("循环引用"), "未选中的 else 递归引用也能有界拒绝")
	cyclic_branch.else_body = null
	var deep_ast := _conditional_ast("main(){if(gun.ready()){move(0,0)}else{move(0,0)}}")
	for unused in ProgramParser.MAX_CONTROL_DEPTH:
		var outer_ast := _conditional_ast("main(){if(gun.ready()){move(0,0)}else{move(0,0)}}")
		(outer_ast.main.body.statements[0] as ProgramAst.IfNode).then_body = deep_ast.main.body
		deep_ast = outer_ast
	var deep_runner := ProgramRunner.create(deep_ast, _make_combat_world())
	_check(not deep_runner.start().is_ok() and deep_runner.message.contains("16 层"), "公开 AST 的第17层条件不能绕过解析上限")
	var shared_ast := _conditional_ast("main(){if(gun.ready()){move(0,0)}else{move(0,0)}}")
	var shared_branch := shared_ast.main.body.statements[0]
	for unused in 256:
		shared_ast.main.body.statements.append(shared_branch)
	var excessive := ProgramRunner.create(shared_ast, _make_combat_world())
	_check(not excessive.start().is_ok() and excessive.message.contains("调用数量"), "两分支共享512条调用预算，重复共享 AST 不会漏计")
	var tick_ast := _conditional_ast("main(){}\ntick(){if(gun.ready()){shoot(0)}else{attack(0)}}")
	var tick_branch := tick_ast.tick.body.statements[0] as ProgramAst.IfNode
	tick_branch.else_body = ProgramParser.parse("main(){move(0,0)}").value.main.body
	var tick_runner := ProgramRunner.create(tick_ast, _make_combat_world())
	_check(not tick_runner.start().is_ok() and tick_runner.message.contains("tick()"), "手工 AST 也不能把移动隐藏进 tick 的 else")


## 冷却在每次进入 if 时重新读取，分支结构不增加空白 tick，指定枪与其他枪冷却互不混淆。
func _test_conditional_execution() -> void:
	for cooling: bool in [false, true]:
		var world := _make_combat_world()
		if cooling:
			world.player.get_module("gun").next_shoot_tick = 2
		var runner := _make_conditional_runner("main(){\nif(gun.ready()){move(0,.1)}else{move(90,.1)}\nmove(180,.1)\n}", world)
		_check(runner.start().is_ok() and world.tick_index == 0 and world.projectiles.is_empty(), "条件预检和首次查询不会推进时间或发射弹丸")
		_check(world.player.get_module("gun").next_shoot_tick == (2 if cooling else 0), "ready 查询不会消耗或改写冷却")
		runner.step()
		var expected := Vector2(1.5, 6.4) if cooling else Vector2(1.6, 6.5)
		_check(world.tick_index == 1 and world.player.position.is_equal_approx(expected), "冷却真假分别进入指定分支，首次动作仍只用一tick")
		runner.step()
		_check(world.tick_index == 2 and runner.state == ProgramRunner.State.COMPLETED and world.player.position.is_equal_approx(expected + Vector2(-.1, 0)), "有限分支结束后准确返回外层下一语句，不多等一tick")
	var world := _make_combat_world()
	var repeated := _make_conditional_runner("main(){loop{\nif(gun.ready()){\ngun.shoot(0)\n}else{\nmove(0,.1)\n}\n}}", world)
	_reset_observations()
	repeated.line_changed.connect(_on_line_changed)
	repeated.start()
	for unused in 12:
		repeated.step()
	_check(world.tick_index == 12 and world.player.position.distance_to(Vector2(2.5, 6.5)) < .001, "循环在十次冷却帧移动，每次 step 仍只推进一帧")
	_check(world.player.get_module("gun").next_shoot_tick == 21 and _line_events.count(3) == 2 and _line_events.count(5) == 10, "第1和11tick射击，其余帧进入移动分支，无提前或晚一帧查询")
	_check(_line_events.count(2) == 12 and repeated.state == ProgramRunner.State.RUNNING, "每轮重新高亮并求值同一 if，循环不会缓存首次真假结果")
	repeated.cancel()
	var named_world := _make_named_world()
	named_world.player.get_module("gun").next_shoot_tick = 100
	var named := _make_conditional_runner("main(){if(gun.ready()){gun.shoot(0)}else{if(rear.ready()){rear.shoot(90)}else{drive.move(0,0)}}}", named_world)
	named.start()
	named.step()
	_check(named_world.tick_index == 1 and named_world.player.get_module("gun").next_shoot_tick == 100 and named_world.player.get_module("rear").next_shoot_tick == 11, "两把命名枪分别读取和更新自己的冷却，不广播替换接收者")
	_check(named_world.projectiles.size() == 1 and named_world.projectiles[0].direction == Vector2.UP, "嵌套 else 中的另一把枪精确发射一次")
	named.cancel()
	var boundary_world := _make_combat_world()
	boundary_world.player.get_module("gun").next_shoot_tick = 1
	var boundary := _make_conditional_runner("main(){if(gun.ready()){gun.shoot(0)}else{move(0,0)}}", boundary_world)
	boundary.start()
	boundary.step()
	_check(boundary_world.player.get_module("gun").next_shoot_tick == 11 and boundary_world.projectiles.size() == 1, "ready 以将执行的tick而非当前完成tick判定冷却边界")
	boundary.cancel()
	var changed_world := _make_combat_world()
	var changed := _make_conditional_runner("main(){move(0,0)\n  if(gun.ready()){move(0,0)}else{move(0,0)}}", changed_world)
	changed.start()
	changed.step()
	changed_world.player.get_module("gun").available = false
	changed.step()
	_check(changed.state == ProgramRunner.State.FAILED and changed.message.contains("第 2 行，第 6 列") and changed_world.tick_index == 1, "预检后模块损坏在真正查询处报错，不误走 else 或推进额外tick")


## 省略 else 的假分支不执行动作或增加时间，真分支与后续语句仍按原调度规则运行。
func _test_optional_else_execution() -> void:
	for cooling: bool in [false, true]:
		var world := _make_combat_world()
		world.player.get_module("gun").next_shoot_tick = 100 if cooling else 0
		var runner := _make_conditional_runner("main(){if(gun.ready()){move(0,.1)}\nmove(90,.1)}", world)
		_check(runner.start().is_ok() and world.tick_index == 0, "可选 else 的进入与跳过不推进模拟时间")
		for unused in 3:
			runner.step()
		var expected := Vector2(1.5,6.4) if cooling else Vector2(1.6,6.4)
		_check(runner.state == ProgramRunner.State.COMPLETED and world.tick_index == (1 if cooling else 2) and world.player.position.is_equal_approx(expected), "可选 else 按真假结果顺序执行后续动作")
	var empty_world := _make_combat_world()
	empty_world.player.get_module("gun").next_shoot_tick = 100
	var empty := _make_conditional_runner("main(){if(gun.ready()){move(0,.1)}}",empty_world)
	_check(empty.start().is_ok() and empty.state == ProgramRunner.State.COMPLETED and empty_world.tick_index == 0, "唯一 if 为假时无需额外空白 tick 即可完成")
	var tick_world := _make_combat_world()
	tick_world.player.get_module("gun").next_shoot_tick = 100
	var tick := _make_conditional_runner("main(){}\ntick(){if(gun.ready()){gun.shoot(0)}}",tick_world)
	_check(tick.start().is_ok(), "tick 允许有限可选 else 分支")
	tick.step()
	_check(tick.state == ProgramRunner.State.RUNNING and tick_world.tick_index == 1 and tick_world.projectiles.is_empty(), "tick 假分支只让外部模拟推进一次，不发射或制造额外动作")
	tick.cancel()
	var loop_world := _make_combat_world()
	loop_world.player.get_module("gun").next_shoot_tick = 100
	var spin := _make_conditional_runner("main(){loop{if(gun.ready()){move(0,.1)}}}",loop_world)
	_check(not spin.start().is_ok() and spin.message.contains("预算") and loop_world.tick_index == 0, "省略 else 不能让无动作无限循环越过连续计算预算")
	var preflight_world := _make_combat_world()
	preflight_world.player.get_module("gun").next_shoot_tick = 100
	var invalid := _make_conditional_runner("main(){move(0,.1)\nif(gun.ready()){missing.shoot(0)}}",preflight_world)
	_check(not invalid.start().is_ok() and preflight_world.tick_index == 0, "未执行的可选 else 条件体仍做完整能力预检")


## 有限 tick 分支仍共享每逻辑帧一次推进，重复只读查询不能绕过真实射击冷却。
func _test_conditional_tick_execution() -> void:
	var world := _make_combat_world()
	var runner := _make_conditional_runner("main(){move(0,.2)}\ntick(){if(gun.ready()){gun.shoot(0)}else{blade.attack(0)}}", world)
	runner.start()
	runner.step()
	_check(world.tick_index == 1 and world.projectiles.size() == 1 and world.attack_traces.is_empty(), "tick 条件首次选择射击，与main移动共用一帧")
	runner.step()
	_check(world.tick_index == 2 and world.player.position.is_equal_approx(Vector2(1.7, 6.5)) and world.attack_traces.size() == 1, "下一帧重新检查冷却并切换近战，main移动仍准确完成")
	for unused in 9:
		runner.step()
	_check(world.tick_index == 11 and world.player.get_module("gun").next_shoot_tick == 21 and runner.state == ProgramRunner.State.RUNNING, "main结束后条件tick继续，并在冷却结束当帧再次射击")
	runner.cancel()
	var queued_world := _make_combat_world()
	var queued := _make_conditional_runner("main(){}\ntick(){if(gun.ready()){gun.shoot(0)}else{blade.attack(0)}\nif(gun.ready()){gun.shoot(90)}else{blade.attack(90)}}", queued_world)
	queued.start()
	queued.step()
	_check(queued_world.tick_index == 1 and queued_world.projectiles.size() == 1 and queued_world.projectiles[0].direction == Vector2.RIGHT, "同帧ready查询保持只读，多条排队射击仍由真实模块冷却合并")
	queued.cancel()


## 条件高亮支持取消与同步重入保护；清除队列后不会有延迟发射或额外世界tick。
func _test_conditional_cancellation_and_reentry() -> void:
	var cancel_world := _make_combat_world()
	_callback_runner = _make_conditional_runner("main(){\nif(gun.ready()){shoot(0)}else{move(0,0)}}", cancel_world)
	_reset_observations()
	_callback_runner.line_changed.connect(_cancel_at_line)
	_callback_runner.finished.connect(_on_finished)
	_callback_runner.start()
	_callback_runner.step()
	_callback_runner.cancel()
	cancel_world.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and cancel_world.projectiles.is_empty() and _finished_count == 1, "if高亮时取消会阻止动作提交且完成信号只发一次")
	_callback_runner.line_changed.disconnect(_cancel_at_line)
	var tick_world := _make_combat_world()
	_callback_runner = _make_conditional_runner("main(){}\ntick(){\ngun.shoot(0)\nif(gun.ready()){shoot(90)}else{attack(0)}}", tick_world)
	_callback_runner.line_changed.connect(_cancel_at_second_tick_call)
	_callback_runner.start()
	_callback_runner.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and tick_world.tick_index == 0, "tick中if高亮取消时不推进本帧")
	tick_world.step()
	_check(tick_world.projectiles.is_empty() and tick_world.player.get_module("gun").next_shoot_tick == 0, "if取消清除先前已排队射击，后续世界步进也不会补发")
	_callback_runner.line_changed.disconnect(_cancel_at_second_tick_call)
	var world := _make_combat_world()
	_callback_runner = _make_conditional_runner("main(){loop{if(gun.ready()){move(0,0)}else{move(90,0)}}}", world)
	_callback_runner.line_changed.connect(_step_at_line)
	world.tick_completed.connect(_step_at_tick)
	_check(_callback_runner.start().is_ok() and world.tick_index == 0, "首次if高亮重入step不会递归查询或提前推进时间")
	for unused in 40:
		_callback_runner.step()
	_check(world.tick_index == 40 and world.player.position == Vector2(1.5, 6.5) and _callback_runner.state == ProgramRunner.State.RUNNING, "零距离条件循环每step只推进一tick，嵌套信号不能额外推进")
	_callback_runner.cancel()
	var stopped_at := world.tick_index
	_callback_runner.step()
	_check(world.tick_index == stopped_at, "取消条件循环后后续step完全静止")
	_callback_runner.line_changed.disconnect(_step_at_line)
	world.tick_completed.disconnect(_step_at_tick)
	_callback_runner = null


## 测试显式开启第七关权限，旧关编译调用继续保持原来的默认行为。
func _make_conditional_runner(source: String, simulation: SimulationWorld) -> ProgramRunner:
	return ProgramRunner.create(_conditional_ast(source), simulation)


## 构造供公开边界回归使用的显式条件树，并把意外解析错误作为独立失败记录。
func _conditional_ast(source: String) -> ProgramAst.ProgramNode:
	var parsed := ProgramParser.parse(source, PackedStringArray(["move", "attack", "shoot"]), true, true, true, true)
	_check(parsed.is_ok(), "第七关运行测试源码能够静态编译")
	if not parsed.is_ok():
		push_error("条件夹具解析失败：" + "; ".join(parsed.errors))
	return parsed.value as ProgramAst.ProgramNode
