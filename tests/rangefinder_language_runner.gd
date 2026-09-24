extends SceneTree
## 第九关语言回归：实时只读测距、数值比较、有限表达式与旧语言兼容。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 延迟到类型注册完成后执行，所有世界均为内存夹具。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖新语法和无副作用边界，失败时返回非零退出状态。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "测距语言加载真实模块注册表"):
		quit(1)
		return
	_test_parser()
	_test_preflight()
	_test_dynamic_dispatch()
	_test_comparisons()
	_test_public_ast()
	_test_simultaneous_and_tick()
	print("测距语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 查询节点与算术节点保留源码位置，旧参数默认值不能意外开放下一关语法。
func _test_parser() -> void:
	var source := "main(){\n  move(0, sensor.distance(0) - (0.25 + .5))\n}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "接受具名测距、有限加减和数值括号"):
		var call := parsed.value.main.body.statements[0] as ProgramAst.CallNode
		_check(call.arguments[0] is ProgramAst.NumberNode and (call.arguments[0] as ProgramAst.NumberNode).value == 0.0, "旧字面量仍为 NumberNode 并保留 value")
		var binary := call.arguments[1] as ProgramAst.BinaryNode
		_check(binary != null and binary.operator == "-" and binary.left is ProgramAst.DistanceNode, "测距和减法是显式 AST，而非伪动作或文本解析")
		var query := binary.left as ProgramAst.DistanceNode
		_check(query.receiver == "sensor" and query.line == 2 and query.column == 11, "测距查询保持实例名和查询自身行列")
	_check(not ProgramParser.parse(source, _calls, true, true, true, true, true).is_ok(), "旧七参数解析接口默认关闭测距与表达式")
	_check(not ProgramParser.parse(source, _calls, true, false, true, true, true, true).is_ok(), "测距权限不能绕过命名调用权限")
	_check(ProgramParser.parse("main(){if(distance(0)>1){move(0,.1)}else{move(0,0)}}", _calls, false, false, true, true, false, true).is_ok(), "非具名测距比较不要求命名权限")
	_check(not ProgramParser.parse("main(){if(distance(0)>1){move(0,.1)}else{move(0,0)}}", _calls, false, true, true, false, false, true).is_ok(), "测距权限不能绕过条件语法权限")
	_check(_parse("main(){move(-90.5,+.25)}").is_ok(), "新语法保持有符号小数字面量兼容")
	_check(_parse("main(){move(0,-(1-2))}").is_ok(), "负号支持有限括号数值表达式")
	_check(_parse("main(){if(gun.ready()){shoot(0)}else{move(0,0)}}").is_ok(), "旧射击 ready 条件在第九关继续有效")
	for operator in ProgramParser.COMPARISONS:
		_check(_parse("main(){if(distance(0)" + operator + "sensor.distance(180)){move(0,0)}else{move(90,0)}}").is_ok(), "数值比较符可解析：" + operator)
	for invalid in ["distance(0)", "loop{distance(0)}", "move(0,distance())", "move(0,distance(0,1))", "move(0,distance(0)*2)", "move(0,unknown)", "move(0,shoot(0))", "move(0,sensor.other(0))", "variable x=1", "move(0,distance(0)+)", "if(distance(0)){move(0,0)}else{move(0,0)}", "if(distance(0)>1){}else{move(0,0)}"]:
		var rejected := _parse("main(){" + invalid + "}")
		_check(not rejected.is_ok() and rejected.errors[0].contains("第 "), "有定位地拒绝未开放或无法有限执行的形式：" + invalid)
	var nested := "main(){move(0," + "(".repeat(ProgramParser.MAX_EXPRESSION_DEPTH + 1) + "1" + ")".repeat(ProgramParser.MAX_EXPRESSION_DEPTH + 1) + ")}"
	_check(not _parse(nested).is_ok(), "深括号不能越过表达式递归预算")
	var chain := "main(){move(0,1" + "+1".repeat(ProgramParser.MAX_EXPRESSION_DEPTH + 1) + ")}"
	_check(not _parse(chain).is_ok(), "长加法链不能生成无界深 AST")


## 所有路径都预检模块能力，但当前测距值不用于预测未来动态负距离。
func _test_preflight() -> void:
	for query in ["missing.distance(0)", "drive.distance(0)", "Sensor.distance(0)"]:
		var world := _world()
		var runner := _runner("main(){\nmove(0,1)\nif(1==1){move(0,0)}else{move(0," + query + ")}\n}", world)
		_check(not runner.start().is_ok() and runner.current_line == 3, "未来分支里的缺失、错误类型和大小写错误测距模块在首次动作前拒绝")
		world.step()
		_check(world.player.position == Vector2(5,5) and world.attack_traces.is_empty(), "预检失败不残留动作队列")
	var no_sensor := _world()
	no_sensor.player.get_module("sensor").available = false
	var missing := _runner("main(){move(0,distance(0))}", no_sensor)
	_check(not missing.start().is_ok() and missing.message.contains("distance"), "失效测距模块不能为查询提供能力")
	var negative := _runner("main(){move(0,1)\nmove(0,1-2)}", _world())
	_check(not negative.start().is_ok() and negative.world.tick_index == 0, "纯常量负移动在任何动作之前失败")
	var changing_world := _world()
	var changing := _runner("main(){move(180,1)\nmove(0,distance(0)-15)}", changing_world)
	_check(changing.start().is_ok(), "未来表达式在起点为负也不能被错误地当成静态失败")
	_step_until_done(changing)
	_check(changing.state == ProgramRunner.State.COMPLETED and changing_world.player.position.is_equal_approx(Vector2(4.5,5)), "等前一动作完成后重新测距，使原本为负的未来表达式合法")


## 每条动作真正派发时才查询当前距离，失效与动态负数在对应行安全停止。
func _test_dynamic_dispatch() -> void:
	var world := _world()
	var runner := _runner("main(){\nmove(0,1)\nmove(0,distance(0)-.75)\n}", world)
	_check(runner.start().is_ok() and world.tick_index == 0 and world.player.position == Vector2(5,5), "启动只排队动作，不推进查询世界")
	_step_until_done(runner)
	_check(runner.state == ProgramRunner.State.COMPLETED and world.player.position.is_equal_approx(Vector2(18.75,5)), "第二条移动读取变化后的距离，未缓存起点距离")
	var negative_world := _world()
	var negative := _runner("main(){\nmove(0,1)\nmove(0,distance(0)-14)\nmove(90,1)\n}", negative_world)
	_check(negative.start().is_ok(), "动态负数不能导致合法前置动作被静态误判")
	_step_until_done(negative)
	_check(negative.state == ProgramRunner.State.FAILED and negative.message.contains("第 3 行") and negative.message.contains("负数"), "派发时发现负距离，准确指向该动作源码行")
	_check(negative_world.player.position.is_equal_approx(Vector2(6,5)), "动态失败保留前一动作位置且不执行后续动作")
	var lost_world := _world()
	var lost := _runner("main(){move(0,.1)\nmove(0,sensor.distance(0)-1)}", lost_world)
	lost.start()
	lost.step()
	lost_world.player.get_module("sensor").available = false
	lost.step()
	_check(lost.state == ProgramRunner.State.FAILED and lost.message.contains("第 2 行"), "启动后传感器失效在下一查询时被识别")
	_check(lost_world.player.position.is_equal_approx(Vector2(5.1,5)), "传感器失效不会改用其他能力或继续移动")

	var huge := "9".repeat(308)
	var overflow_world := _world()
	var overflow := _runner("main(){move(0,.1)\nmove(0,\n distance(0)+" + huge + "+" + huge + ")} ", overflow_world)
	_check(overflow.start().is_ok(), "动态溢出表达式在实际派发前不猜测查询值")
	_step_until_done(overflow)
	_check(overflow.state == ProgramRunner.State.FAILED and overflow.message.begins_with("第 3 行") and overflow.message.contains("有限"), "动态算术溢出有界失败并指向真正运算符所在行")
	_check(overflow_world.player.position.is_equal_approx(Vector2(5.1,5)), "溢出不会向世界提交非有限移动")


## 分支每次进入都重新比较；零移动分支仍消费一个 tick，不形成忙循环。
func _test_comparisons() -> void:
	for sample: Dictionary in [{"op":"<", "right":15, "yes":true}, {"op":"<=", "right":14.5, "yes":true}, {"op":">", "right":15, "yes":false}, {"op":">=", "right":14.5, "yes":true}, {"op":"==", "right":14.5, "yes":true}, {"op":"!=", "right":14.5, "yes":false}]:
		var world := _world()
		var runner := _runner("main(){if(distance(0)" + sample.op + str(sample.right) + "){move(0,.1)}else{move(90,.1)}}", world)
		runner.start()
		runner.step()
		var expected := Vector2(5.1,5) if sample.yes else Vector2(5,4.9)
		_check(runner.state == ProgramRunner.State.COMPLETED and world.player.position.is_equal_approx(expected), "比较结果选择正确动作分支：" + sample.op)
	var world := _world()
	var loop := _runner("main(){loop{if(distance(0)>14){move(0,.1)}else{move(0,0)}}}", world)
	loop.start()
	for unused in 20:
		loop.step()
	_check(loop.state == ProgramRunner.State.RUNNING and world.tick_index == 20, "测距条件循环每次 step 最多一个 tick，不忙等")
	_check(world.player.position.x >= 5.49 and world.player.position.x <= 5.61, "循环重新读取距离，到阈值后选择零移动分支")
	loop.cancel()


## 公共 AST 的空值、循环引用、未知运算与非有限数值都必须有界拒绝。
func _test_public_ast() -> void:
	for mode in ["cycle", "null", "operator", "nan", "unknown", "depth", "budget"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){move(0,distance(0)-1)}").value
		var call := ast.main.body.statements[0] as ProgramAst.CallNode
		var expression := call.arguments[1] as ProgramAst.BinaryNode
		match mode:
			"cycle": expression.left = expression
			"null": expression.left = null
			"operator": expression.operator = "*"
			"nan": (expression.right as ProgramAst.NumberNode).value = NAN
			"unknown": expression.left = ProgramAst.ExpressionNode.new()
			"depth":
				for unused in ProgramParser.MAX_EXPRESSION_DEPTH:
					var next := ProgramAst.BinaryNode.new()
					next.operator = "+"
					next.left = call.arguments[1]
					next.right = ProgramAst.NumberNode.new()
					call.arguments[1] = next
			"budget":
				for unused in ProgramParser.MAX_CALLS - 1:
					ast.main.body.statements.append(call)
		var runner := ProgramRunner.create(ast, _world())
		_check(not runner.start().is_ok() and runner.world.tick_index == 0, "公开表达式 AST 在预检有界拒绝：" + mode)
		if mode == "cycle":
			expression.left = null
	var malformed: ProgramAst.ProgramNode = _parse("main(){if(distance(0)>1){move(0,0)}else{move(0,0)}}").value
	(malformed.main.body.statements[0].condition as ProgramAst.ComparisonNode).operator = "&&"
	_check(not ProgramRunner.create(malformed, _world()).start().is_ok(), "公开条件 AST 拒绝未知比较符")


## 并行先求值再原子提交；有限 tick 回调能够读取查询而不额外推进时间。
func _test_simultaneous_and_tick() -> void:
	var world := _world()
	var runner := _runner("main(){simultaneously{drive.move(0,.1)\nblade.attack(distance(0))}}", world)
	_check(runner.start().is_ok() and world.tick_index == 0, "并行表达式求值不提前移动世界")
	runner.step()
	_check(runner.state == ProgramRunner.State.COMPLETED and world.tick_index == 1 and world.attack_traces.size() == 1, "同一 tick 原子提交测距角度攻击与移动")
	if world.attack_traces.size() == 1:
		var direction: Vector2 = (world.attack_traces[0].to - world.attack_traces[0].from).normalized()
		_check(absf(rad_to_deg(atan2(-direction.y, direction.x)) - 14.5) < 0.001, "并行攻击角度读取移动前的同一世界快照")
	var rejected_world := _world()
	var rejected := _runner("main(){simultaneously{blade.attack(0)\nmove(0,distance(0)-100)}}", rejected_world)
	_check(not rejected.start().is_ok(), "并行派发发现动态负距离时整组拒绝")
	rejected_world.step()
	_check(rejected_world.attack_traces.is_empty() and rejected_world.player.position == Vector2(5,5), "前面的合法并行攻击不会在后一个表达式失败后残留")
	var tick_world := _world()
	var tick := _runner("main(){}\ntick(){if(distance(0)>1){blade.attack(0)}else{gun.shoot(0)}}", tick_world)
	_check(tick.start().is_ok(), "有限回调支持只读测距条件")
	tick.step()
	_check(tick_world.tick_index == 1 and tick_world.attack_traces.size() == 1, "回调查询不消耗额外 tick")
	tick.cancel()


## 内存地图给查询提供可预测边界；自己机器的模块不阻挡传感器射线。
func _world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y), "floor")
	document.player_spawn = {"position":{"x":5,"y":5}, "modules":[
		{"id":"drive", "module_id":"movement", "offset":{"x":0,"y":0}},
		{"id":"sensor", "module_id":"rangefinder", "offset":{"x":0.5,"y":0}},
		{"id":"gun", "module_id":"shooting", "offset":{"x":-0.5,"y":0}},
		{"id":"blade", "module_id":"melee", "offset":{"x":0,"y":0.5}},
	]}
	var created := SimulationWorld.create(document, _content)
	_check(created.is_ok(), "测距语言建立独立真实世界")
	return created.value as SimulationWorld


## 显式开启第九关语法，保留每个前置能力的独立开关。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true)


## 测试源码编译失败时计入回归错误，不静默改写程序。
func _runner(source: String, world: SimulationWorld) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "测距执行夹具源码可编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, world)


## 有界推进测试动作，避免回归错误导致测试无限运行。
func _step_until_done(runner: ProgramRunner) -> void:
	for unused in 300:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 累计检查并保留直接可读的失败原因。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
