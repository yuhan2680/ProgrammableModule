extends SceneTree
## 第十一关函数语言回归：声明/引用、独立权限、真实顺序执行及公开 AST 有界校验。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 类型导入完成后执行；仅使用内存地图，不接触玩家的存档与进度。
func _initialize() -> void:
	_run.call_deferred()


## 从解析、调用图到真实世界验证函数，不通过模拟假动作代替正常执行器。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "函数语言加载真实模块注册表"):
		quit(1)
		return
	_test_parser()
	_test_graph_limits()
	_test_sequential_execution()
	_test_control_execution()
	_test_preflight_and_errors()
	_test_cancellation()
	_test_public_ast()
	print("函数语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 自定义函数是显式节点；新能力不能顺便解锁变量或覆盖已有动作权限。
func _test_parser() -> void:
	var source := "main(){\n  dodge()\n}\nfunction dodge(){\nmove(90,.1)\n}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "main 支持调用后面声明的函数"):
		var ast := parsed.value as ProgramAst.ProgramNode
		var call := ast.main.body.statements[0] as ProgramAst.UserCallNode
		_check(ast.functions.size() == 1 and ast.functions[0].name == "dodge", "用户声明保留独立函数列表")
		_check(call != null and call.callee == "dodge" and call.line == 2 and call.column == 3, "用户调用节点保留自身行列，区别于动作")
	_check(_parse("function dodge(){move(0,0)}\nmain(){dodge()}").is_ok(), "支持函数声明位于 main 之前")
	_check(_parse("main(){}\nfunction spare(){move(0,0)}").is_ok(), "允许未使用的有效函数")
	_check(not ProgramParser.parse(source, _calls, true, true, true, true, true, true).is_ok(), "旧八参数接口默认不开放函数")
	_check(not ProgramParser.parse("main(){dodge()}", _calls).is_ok(), "函数未开放时不能使用用户调用")
	_check(not ProgramParser.parse("main(){dodge()}\nfunction dodge(){attack(0)}", PackedStringArray(["move"]), false, false, false, false, false, false, true).is_ok(), "函数体不绕过已解锁动作列表")
	_check(not ProgramParser.parse("main(){dodge()}\nfunction dodge(){loop{move(0,0)}}", _calls, false, true, false, true, true, true, true).is_ok(), "函数能力不能替代 loop 权限")
	_check(not ProgramParser.parse("main(){dodge()}\nfunction dodge(){if(gun.ready()){move(0,0)}else{move(0,0)}}", _calls, false, true, true, false, true, true, true).is_ok(), "函数能力不能替代 if 权限")
	_check(not ProgramParser.parse("main(){dodge()}\nfunction dodge(){move(0,distance(0))}", _calls, false, true, true, true, true, false, true).is_ok(), "函数能力不能替代测距权限")
	for source_invalid in [
		"main(){missing()}",
		"main(){}\nfunction dodge(){}",
		"main(){}\nfunction dodge(){move(0,0)}\nfunction dodge(){move(0,0)}",
		"main(){dodge(1)}\nfunction dodge(){move(0,0)}",
		"main(){}\nfunction dodge(angle){move(0,0)}",
		"main(){function dodge(){move(0,0)}}",
		"main(){}\nfunction dodge(){return}",
		"main(){}\nfunction dodge(){variable x=1}",
		"main(){}\nfunction dodge(){constant x=1}",
		"main(){}\nfunction dodge(){move(0,dodge())}",
		"main(){Dodge()}\nfunction dodge(){move(0,0)}",
		"main(){}\nfunction dodge(){missing()}",
		"main(){dodge() move(0,0)}\nfunction dodge(){move(0,0)}",
		"main(){}\ntick(){dodge()}\nfunction dodge(){attack(0)}",
		"main(){simultaneously{dodge()\nshoot(0)}}\nfunction dodge(){attack(0)}",
	]:
		var rejected := _parse(source_invalid)
		_check(not rejected.is_ok() and rejected.errors[0].contains("第 "), "有行列地拒绝不合法函数语法：" + source_invalid)
	for name in ["main", "tick", "move", "attack", "shoot", "ready", "distance", "loop", "if", "function", "return", "true", "false", "null"]:
		_check(not _parse("main(){}\nfunction " + name + "(){move(0,0)}").is_ok(), "函数不可声明保留名：" + name)
	_check(_parse("main(){dodge()}\nfunction dodge(){simultaneously{drive.move(0,.1)\nblade.attack(0)}}").is_ok(), "函数体可以包含显式并行动作")


## 深度按真实调用链计算；重复引用共享声明，不把调用图展开成指数级源码。
func _test_graph_limits() -> void:
	for source in ["main(){a()}\nfunction a(){a()}", "main(){}\nfunction a(){b()}\nfunction b(){a()}", "main(){}\nfunction a(){if(gun.ready()){move(0,0)}else{a()}}"]:
		var result := _parse(source)
		_check(not result.is_ok() and result.errors[0].contains("递归"), "拒绝直接、间接和未运行路径中的递归")
	var legal := _chain(ProgramFunctionValidation.MAX_FUNCTION_DEPTH)
	_check(_parse(legal).is_ok(), "允许最大合法调用深度")
	_check(not _parse(_chain(ProgramFunctionValidation.MAX_FUNCTION_DEPTH + 1)).is_ok(), "超过调用深度在解析期拒绝")
	var many := "main(){}\n"
	for i in ProgramFunctionValidation.MAX_FUNCTIONS:
		many += "function f%d(){move(0,0)}\n" % i
	_check(_parse(many).is_ok(), "允许最大函数声明数")
	_check(not _parse(many + "function extra(){move(0,0)}").is_ok(), "额外函数声明有界拒绝")
	var dag := "main(){f0()}\n"
	for i in 15:
		dag += "function f%d(){f%d()\nf%d()}\n" % [i, i + 1, i + 1]
	dag += "function f15(){move(0,0)}"
	var parsed := _parse(dag)
	if _check(parsed.is_ok(), "指数复用调用图仍能以有限声明量解析"):
		var runner := ProgramRunner.create(parsed.value, _world())
		_check(runner.start().is_ok(), "预检不展开重复函数体")
		for unused in 20:
			runner.step()
		_check(runner.state == ProgramRunner.State.RUNNING and runner.world.tick_index == 20, "复用 DAG 每次 step 仍只执行一个逻辑 tick")
		_check(runner._frames.size() <= ProgramRunner.MAX_EXECUTION_FRAMES, "重复函数调用保持有界执行栈")
		runner.cancel()


## 函数调用不消耗额外 tick，函数内完整动作结束后才返回，并恢复调用点后的语句。
func _test_sequential_execution() -> void:
	var source := "main(){\nfirst()\nmove(0,.1)\n}\nfunction first(){\nmove(0,.2)\nsecond()\n}\nfunction second(){\nmove(90,.1)\n}"
	var world := _world()
	var runner := _runner(source, world)
	var highlighted: Array[int] = []
	runner.line_changed.connect(func(line: int) -> void: highlighted.append(line))
	_check(runner.start().is_ok() and world.tick_index == 0, "函数开始只派发首动作，不推进世界")
	_check(runner.current_line == 6, "派发后高亮函数体动作行")
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.1,5)) and runner.current_line == 6, "长动作未完成时不会提前返回函数")
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.2,5)), "函数长动作完整结束")
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.2,4.9)), "进入嵌套函数动作")
	runner.step()
	_check(runner.state == ProgramRunner.State.COMPLETED and world.player.position.is_equal_approx(Vector2(5.3,4.9)), "嵌套返回后继续 main 剩余动作")
	_check(world.tick_index == 4 and highlighted == [2,6,7,10,3], "调用和返回不制造空白 tick，行号按真实调用路径变化")
	var repeated := _runner("main(){step_right()\nstep_right()}\nfunction step_right(){move(0,.1)}", _world())
	repeated.start()
	_step_until_done(repeated)
	_check(repeated.state == ProgramRunner.State.COMPLETED and repeated.world.tick_index == 2 and repeated.world.player.position.is_equal_approx(Vector2(5.2,5)), "同一个函数每次调用都从函数体开头重新执行")


## 函数与原有分支、循环、并行和实时测距组合时仍共用唯一世界时间。
func _test_control_execution() -> void:
	var branched := _runner("main(){loop{dodge()}}\nfunction dodge(){if(gun.ready()){move(90,0)}else{move(270,0)}}", _world())
	_check(branched.start().is_ok(), "loop 可以重复调用带条件的函数")
	for unused in 40:
		branched.step()
	_check(branched.state == ProgramRunner.State.RUNNING and branched.world.tick_index == 40 and branched._frames.size() <= 5, "循环调用不会累积历史函数帧")
	branched.cancel()
	var forever := _runner("main(){patrol()\nmove(0,1)}\nfunction patrol(){loop{move(0,0)}}", _world())
	forever.start()
	for unused in 12:
		forever.step()
	_check(forever.state == ProgramRunner.State.RUNNING and forever.world.player.position == Vector2(5,5), "包含无限 loop 的函数保持执行，不跳到 main 后续语句")
	forever.cancel()
	var parallel := _runner("main(){together()}\nfunction together(){simultaneously{drive.move(0,.1)\nblade.attack(0)}}", _world())
	_check(parallel.start().is_ok(), "函数体派发原子并行组")
	parallel.step()
	_check(parallel.state == ProgramRunner.State.COMPLETED and parallel.world.tick_index == 1 and parallel.world.attack_traces.size() == 1, "函数返回等待整个并行组完成")
	var dynamic := _runner("main(){move(0,1)\nfollow()}\nfunction follow(){move(0,sensor.distance(0)-.75)}", _world())
	dynamic.start()
	_step_until_done(dynamic)
	_check(dynamic.state == ProgramRunner.State.COMPLETED and dynamic.world.player.position.is_equal_approx(Vector2(18.75,5)), "函数派发时读取当前测距值，不缓存声明时的世界")
	var with_tick := _runner("main(){advance()}\nfunction advance(){move(0,.2)}\ntick(){blade.attack(0)}", _world())
	with_tick.start()
	with_tick.step()
	with_tick.step()
	_check(with_tick.world.tick_index == 2 and with_tick.world.player.position.is_equal_approx(Vector2(5.2,5)), "函数主动作与有限 tick 回调共用每帧调度")
	with_tick.cancel()


## 未调用和未选中函数中的错误也先验证；动态失败指向函数内真实动作行。
func _test_preflight_and_errors() -> void:
	var invalid := _runner("main(){move(0,.1)}\nfunction unused(){\nmissing.move(0,.1)\n}", _world())
	_check(not invalid.start().is_ok() and invalid.current_line == 3 and invalid.message.contains("第 3 行"), "未使用函数的无效模块在启动前拒绝")
	invalid.world.step()
	_check(invalid.world.player.position == Vector2(5,5), "函数预检失败不残留前置动作")
	var negative := _runner("main(){move(0,1)\nfail_later()}\nfunction fail_later(){\nmove(0,sensor.distance(0)-14)\n}", _world())
	_check(negative.start().is_ok(), "动态失败函数不提前读取未来位置")
	_step_until_done(negative)
	_check(negative.state == ProgramRunner.State.FAILED and negative.message.contains("第 4 行") and negative.world.player.position.is_equal_approx(Vector2(6,5)), "动态负距离失败保留函数体行号和前置动作结果")
	var blocked := _runner("main(){blocked()}\nfunction blocked(){\nmove(0,100)\n}", _world())
	blocked.start()
	_step_until_done(blocked)
	_check(blocked.state == ProgramRunner.State.FAILED and blocked.message.contains("第 3 行"), "函数内真实地形阻挡保留动作行号")


## 同步高亮中的取消和进行中取消都不能偷偷继续函数或多推进一个 tick。
func _test_cancellation() -> void:
	var reentrant := _runner("main(){\ndodge()\n}\nfunction dodge(){move(0,1)}", _world())
	var cancel_handler := func(line: int) -> void:
		if line == 2:
			reentrant.step()
			reentrant.cancel()
	reentrant.line_changed.connect(cancel_handler)
	_check(not reentrant.start().is_ok() and reentrant.state == ProgramRunner.State.CANCELLED, "用户函数调用点取消可中止进入函数")
	reentrant.world.step()
	_check(reentrant.world.player.position == Vector2(5,5), "调用点同步重入不会排队或推进函数动作")
	reentrant.line_changed.disconnect(cancel_handler)
	var moving := _runner("main(){dodge()}\nfunction dodge(){move(0,1)\nmove(90,1)}", _world())
	moving.start()
	moving.step()
	var position := moving.world.player.position
	var ticks := moving.world.tick_index
	moving.cancel()
	moving.step()
	_check(moving.state == ProgramRunner.State.CANCELLED and moving._frames.is_empty() and moving.world.tick_index == ticks, "取消清除函数帧且后续 step 不推进")
	moving.world.step()
	_check(moving.world.player.position == position, "取消同时撤销函数正在执行的真实动作")


## 外部构造或篡改 AST 不得绕过递归、未定义调用、作用域、空函数与节点预算检查。
func _test_public_ast() -> void:
	for mode in ["duplicate", "reserved", "empty", "null", "missing", "recursive", "tick", "simultaneous", "block_cycle", "budget", "count"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){step_right()}\nfunction step_right(){move(0,.1)}").value
		var function: ProgramAst.FunctionNode = ast.functions[0]
		var user_call := ast.main.body.statements[0] as ProgramAst.UserCallNode
		var cycle: ProgramAst.LoopNode
		match mode:
			"duplicate": ast.functions.append(function)
			"reserved": function.name = "move"
			"empty": function.body.statements.clear()
			"null": ast.functions.append(null)
			"missing": user_call.callee = "missing"
			"recursive": function.body.statements.append(user_call)
			"tick":
				ast.tick = ProgramAst.FunctionNode.new()
				ast.tick.name = "tick"
				ast.tick.body = ProgramAst.BlockNode.new()
				ast.tick.body.statements.append(user_call)
			"simultaneous":
				var parallel := ProgramAst.SimultaneousNode.new()
				parallel.body = ProgramAst.BlockNode.new()
				parallel.body.statements.append(user_call)
				parallel.body.statements.append(function.body.statements[0])
				ast.main.body.statements[0] = parallel
			"block_cycle":
				cycle = ProgramAst.LoopNode.new()
				cycle.body = function.body
				function.body.statements.append(cycle)
			"budget":
				for unused in ProgramParser.MAX_CALLS:
					ast.main.body.statements.append(user_call)
			"count":
				for i in ProgramFunctionValidation.MAX_FUNCTIONS:
					var extra := ProgramAst.FunctionNode.new()
					extra.name = "f%d" % i
					extra.body = function.body
					ast.functions.append(extra)
		var runner := ProgramRunner.create(ast, _world())
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 "), "公开函数 AST 在启动前有界拒绝：" + mode)
		if cycle != null:
			cycle.body = null
	var ast: ProgramAst.ProgramNode = _parse("main(){move(0,0)}").value
	var unknown := ProgramAst.UserCallNode.new()
	unknown.callee = "ghost"
	ast.main.body.statements.append(unknown)
	_check(not ProgramRunner.create(ast, _world()).start().is_ok(), "无函数声明的公开 AST 也不能藏入未知用户调用")


## 生成有限链测试函数深度；每个函数只保存一次，不复制调用目标的语句。
func _chain(count: int) -> String:
	var source := "main(){f0()}\n"
	for i in count:
		var body := "f%d()" % (i + 1) if i < count - 1 else "move(0,0)"
		source += "function f%d(){%s}\n" % [i, body]
	return source


## 使用真实模块行为创建宽阔的内存世界，为动作顺序和测距提供确定性基准。
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
	_check(created.is_ok(), "函数语言建立独立真实世界")
	return created.value as SimulationWorld


## 显式开启函数及旧九关语法；变量与常量没有任何额外入口。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true, true)


## 测试程序编译失败必须计入回归错误，不能替换为其他可执行源码。
func _runner(source: String, world: SimulationWorld) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "函数执行夹具源码可编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, world)


## 有界推进真实动作，避免错误的函数执行逻辑使测试无限运行。
func _step_until_done(runner: ProgramRunner) -> void:
	for unused in 300:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 累计断言并以非零退出码报告失败，日志保留可读的功能原因。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
