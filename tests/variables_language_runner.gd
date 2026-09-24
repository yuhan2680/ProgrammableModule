extends SceneTree
## 常变量语言回归：词法声明、静态作用域、真实数值执行、函数局部与有界纯计算。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move","attack","shoot"])


## 等待脚本类型初始化后建立独立内存世界，不读写玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 验证解析与执行实际行为，保留旧关权限并使用明确的完成标记。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "变量语言加载真实内容"):
		quit(1)
		return
	_test_parser()
	_test_static_scope()
	_test_values_and_functions()
	_test_blocks_and_loops()
	_test_tick_and_simultaneous()
	_test_errors_and_budget()
	_test_cancel_retry()
	_test_public_ast()
	print("常变量语言回归完成：%d 项检查，%d 项失败。" % [_checks,_failures])
	quit(1 if _failures > 0 else 0)


## 名称读取、声明与赋值分别形成显式节点，单等号不改变原来双等号比较。
func _test_parser() -> void:
	var source := "constant step = .1\nmain(){\n  variable distance_left = step + .1\n  distance_left = distance_left - .1\n  move(0,distance_left)\n}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "顶层常量、局部变量与重新赋值可解析"):
		var ast := parsed.value as ProgramAst.ProgramNode
		_check(ast.globals.size() == 1 and not ast.globals[0].mutable and ast.globals[0].name == "step", "全局常量保留名称、不可变属性与顺序")
		_check(ast.main.body.statements[0] is ProgramAst.DeclarationNode and ast.main.body.statements[1] is ProgramAst.AssignmentNode, "局部声明与赋值有不同 AST 类型")
		var call := ast.main.body.statements[2] as ProgramAst.CallNode
		var name := call.arguments[1] as ProgramAst.NameNode
		_check(name != null and name.name == "distance_left" and name.line == 5 and name.column == 10, "名称表达式保留自身源码位置")
	var tokens := ProgramLexer.tokenize("x = 1\nx == 1")
	_check(tokens.is_ok() and tokens.value[1].kind == ProgramLexer.Kind.ASSIGN and tokens.value[5].kind == ProgramLexer.Kind.EQUAL, "赋值与等值比较是不同 token")
	_check(_parse("value step = .1\nmain(){move(0,step)}").is_ok(), "远端旧文档 value 是 constant 的兼容别名")
	_check(not ProgramParser.parse(source,_calls,true,true,true,true,true,true,true).is_ok(), "旧九参数接口不自动开放常变量")
	_check(ProgramParser.parse("constant step=.1\nmain(){move(0,step+.1)}",_calls,false,false,false,false,false,false,false,true).is_ok(), "纯常变量与加减不依赖函数或测距开关")
	_check(ProgramParser.parse("main(){variable n=1\nif(n==1){move(0,0)}else{move(0,0)}}",_calls,false,false,false,true,false,false,false,true).is_ok(), "变量数值比较仍只需已解锁的 if")
	_check(not ProgramParser.parse("main(){variable n=distance(0)}",_calls,false,false,false,false,false,false,false,true).is_ok(), "变量开关不能绕过测距权限")
	_check(not ProgramParser.parse("main(){variable n=1\nif(n==1){move(0,0)}else{move(0,0)}}",_calls,false,false,false,false,false,false,false,true).is_ok(), "变量开关不能绕过条件权限")
	for source_invalid in ["main(){variable x}","main(){variable x=}","main(){variable x=true}","main(){variable x=\"1\"}","main(){variable x=1;}","main(){variable x=1 variable y=2}","main(){variable x=1\nx+=1}","main(){constant x=1\nx=2}","main(){variable x=helper()}\nfunction helper(){move(0,0)}", "variable x=1 main(){}", "variable x=1\nx=2\nmain(){}"]:
		var rejected := _parse(source_invalid)
		_check(not rejected.is_ok() and rejected.errors[0].contains("第 "), "无效常变量语法有源码诊断：" + source_invalid)
	for name in ["main","tick","move","attack","shoot","distance","ready","function","loop","if","constant","variable","value","true","false","return"]:
		_check(not _parse("main(){variable " + name + "=1}").is_ok(), "数值名称拒绝保留字：" + name)
	_check(_parse("main(){variable upper=\n.1\nmove(0,upper)}").is_ok(), "赋值号之后可自然换行输入表达式")


## 词法作用域拒绝前向局部、泄漏、未定义写入与常量写入，未调用函数同样预检。
func _test_static_scope() -> void:
	for source in [
		"main(){move(0,step)\nvariable step=1}",
		"main(){missing=1}",
		"main(){variable a=missing}",
		"main(){variable a=1\nvariable a=2}",
		"constant a=1\nvariable a=2\nmain(){}",
		"constant a=b\nconstant b=1\nmain(){}",
		"main(){variable local=.1\nhelper()}\nfunction helper(){move(0,local)}",
		"main(){if(1==1){variable local=.1}else{move(0,0)}\nmove(0,local)}",
		"main(){loop{variable local=.1\nmove(0,0)}\nmove(0,local)}",
		"main(){if(1==1){variable local=.1}else{move(0,local)}}",
		"constant a=1\nmain(){helper()}\nfunction helper(){a=2}",
		"main(){}\nfunction unused(){move(0,unknown)}",
		"main(){variable helper=1}\nfunction helper(){move(0,0)}",
	]:
		var rejected := _parse(source)
		_check(not rejected.is_ok() and rejected.errors[0].contains("第 "), "词法名称检查拒绝非法路径：" + source)
	_check(_parse("main(){helper()}\nfunction helper(){move(0,step)}\nconstant step=.1").is_ok(), "函数可以引用写在声明后面的顶层变量，初始化仍在 main 之前")
	_check(_parse("constant step=.1\nmain(){variable step=step+.1\nmove(0,step)}").is_ok(), "局部初始化可先读取同名外层绑定再遮蔽它")
	_check(_parse("main(){variable n=1\nif(n==1){variable n=2\nmove(0,0)}else{variable n=3\nmove(0,0)}}").is_ok(), "兄弟分支和内层作用域允许独立同名变量")


## 真实运动证明名称在执行时取值；函数局部隔离、重新初始化且可更新全局变量。
func _test_values_and_functions() -> void:
	var simple := _runner("constant heading=0\nvariable step=.1\nmain(){move(heading,step)\nstep=step+.1\nmove(heading,step)}")
	_check(simple.start().is_ok() and simple.world.tick_index == 0, "全局初始化与首动作派发不推进世界")
	_finish(simple)
	_check(simple.state == ProgramRunner.State.COMPLETED and simple.world.player.position.is_equal_approx(Vector2(5.3,5)) and simple.world.tick_index == 3, "赋值影响下一次动作，计算本身不消耗 tick")
	var nested := _runner("variable total=0\nmain(){variable step=.4\nhelper()\nhelper()\nmove(0,step)\nmove(0,total)}\nfunction helper(){variable step=.1\nstep=step+.1\ntotal=total+.1\nmove(90,step)}")
	nested.start()
	_finish(nested)
	_check(nested.state == ProgramRunner.State.COMPLETED and nested.world.player.position.is_equal_approx(Vector2(5.6,4.6)), "每次函数调用重新建立局部，不覆盖调用者变量，并保留全局更新")
	var shadow := _runner("constant step=.1\nmain(){variable step=step+.1\nif(step==.2){constant step=.3\nmove(0,step)}else{move(0,0)}\nmove(0,step)}")
	shadow.start()
	_finish(shadow)
	_check(shadow.state == ProgramRunner.State.COMPLETED and shadow.world.player.position.is_equal_approx(Vector2(5.5,5)), "分支退出后恢复外层数值而不泄漏内部常量")
	var dynamic := _runner("main(){variable heading=0\nvariable length=sensor.distance(heading)\nmove(0,1)\nlength=sensor.distance(heading)-.75\nmove(heading,length)}")
	dynamic.start()
	_finish(dynamic)
	_check(dynamic.state == ProgramRunner.State.COMPLETED and dynamic.world.player.position.is_equal_approx(Vector2(18.75,5)), "测距可使用变量角度，重新赋值读取移动后的真实距离")
	var only := _runner("variable count=1\nmain(){count=count+1\nconstant final=count}")
	_check(only.start().is_ok() and only.state == ProgramRunner.State.COMPLETED and only.world.tick_index == 0, "有限的纯计算程序无需多走一个空白 tick 才完成")
	var snapshot := _runner("main(){constant gap=distance(0)\nmove(0,1)\nif(gap>distance(0)){move(90,.1)}else{move(270,.1)}}")
	snapshot.start()
	_finish(snapshot)
	_check(snapshot.state == ProgramRunner.State.COMPLETED and snapshot.world.player.position.is_equal_approx(Vector2(6,4.9)), "常量仅记录声明时的测距值，不随世界变化自动重新计算")


## loop 每轮清理局部声明，外层可变计数保留；条件在每次进入时使用最新值。
func _test_blocks_and_loops() -> void:
	var loop := _runner("main(){variable count=0\nloop{variable step=.1\ncount=count+1\nif(count<3){move(0,step)}else{move(0,0)}}}")
	loop.start()
	for unused in 10:
		loop.step()
	_check(loop.state == ProgramRunner.State.RUNNING and loop.world.tick_index == 10 and loop.world.player.position.is_equal_approx(Vector2(5.2,5)), "循环重建局部、保留外层计数并重新判断条件")
	loop.cancel()
	var finite_compute := _runner("main(){variable count=0\nloop{count=count+1\nif(count<5){constant seen=count}else{move(0,.1)}}}")
	_check(finite_compute.start().is_ok() and finite_compute.world.tick_index == 0, "有限多轮纯计算可在一个调度预算内到达真实动作")
	finite_compute.step()
	_check(finite_compute.world.tick_index == 1 and finite_compute.world.player.position.is_equal_approx(Vector2(5.1,5)), "纯计算轮次不制造隐藏世界时间")
	finite_compute.cancel()


## 有限 tick 与原子并行动作只能读取名称，不接受声明或写入从而改变提交次序。
func _test_tick_and_simultaneous() -> void:
	for source in ["main(){}\ntick(){variable n=1}","variable n=1\nmain(){}\ntick(){n=2}","main(){simultaneously{variable n=1\nshoot(0)}}", "variable n=1\nmain(){simultaneously{n=2\nshoot(0)}}"]:
		_check(not _parse(source).is_ok(), "有限回调或并行体拒绝变量写入")
	var parallel := _runner("constant step=.1\nmain(){variable angle=0\nsimultaneously{drive.move(angle,step)\nblade.attack(angle)}}")
	parallel.start()
	parallel.step()
	_check(parallel.state == ProgramRunner.State.COMPLETED and parallel.world.tick_index == 1 and parallel.world.player.position.is_equal_approx(Vector2(5.1,5)) and parallel.world.attack_traces.size() == 1, "并行组以同一词法环境读取变量后原子派发")
	var callback := _runner("variable angle=0\nmain(){move(0,.1)\nangle=90\nmove(0,.1)}\ntick(){blade.attack(angle)}")
	callback.start()
	callback.step()
	var first: Dictionary = callback.world.attack_traces[0]
	callback.step()
	var second: Dictionary = callback.world.attack_traces[0]
	_check(is_equal_approx(first.from.y,first.to.y) and is_equal_approx(second.from.x,second.to.x) and second.to.y < second.from.y, "tick 读取 main 已提交的最新全局值，并与同一世界 tick 同步")
	callback.cancel()
	_check(not _parse("main(){variable angle=0}\ntick(){attack(angle)}").is_ok(), "tick 不能读取 main 的局部变量")


## 溢出、动态非法距离与无动作循环在有界位置失败，不向世界提交非法命令。
func _test_errors_and_budget() -> void:
	var missing := _runner("main(){move(0,.1)}\nfunction unused(){variable length=missing.distance(0)}")
	_check(not missing.start().is_ok() and missing.world.tick_index == 0 and missing.message.contains("distance"), "未调用函数里的测距初始化也在动作前检查能力")
	var huge := "9".repeat(308)
	var overflow := _runner("constant enormous=" + huge + "+" + huge + "\nmain(){move(0,.1)}")
	_check(not overflow.start().is_ok() and overflow.message.contains("有限") and overflow.world.tick_index == 0, "纯常量初始化溢出在任何移动前拒绝")
	var runtime_overflow := _runner("constant enormous=" + huge + "\nmain(){move(0,.1)\nvariable invalid=enormous+enormous}")
	runtime_overflow.start()
	_finish(runtime_overflow)
	_check(runtime_overflow.state == ProgramRunner.State.FAILED and runtime_overflow.message.contains("第 3 行") and runtime_overflow.message.contains("有限") and runtime_overflow.world.tick_index == 1, "名称参与的非有限结果在实际求值时拒绝，并准确保留已完成动作与行号")
	var dynamic := _runner("main(){variable length=0\nmove(0,.1)\nlength=distance(0)-100\nmove(0,length)}")
	dynamic.start()
	_finish(dynamic)
	_check(dynamic.state == ProgramRunner.State.FAILED and dynamic.message.contains("第 4 行") and dynamic.world.player.position.is_equal_approx(Vector2(5.1,5)), "变量产生负移动距离时准确定位动作，保留前面合法位移")
	var calculate := _runner("main(){variable count=0\nloop{count=count+1}}")
	_check(not calculate.start().is_ok() and calculate.state == ProgramRunner.State.FAILED and calculate.message.contains("预算") and calculate.world.tick_index == 0, "纯赋值无限循环耗尽预算后有界失败而不挂死")
	var through_function := _runner("main(){loop{calculate()}}\nfunction calculate(){constant n=1}")
	_check(not through_function.start().is_ok() and through_function.message.contains("预算"), "纯计算函数不能绕过无动作循环预算")
	var after_move := _runner("main(){move(0,.1)\nloop{constant n=1}}")
	_check(after_move.start().is_ok(), "真实动作之前不误判尚未进入的纯计算循环")
	after_move.step()
	after_move.step()
	_check(after_move.state == ProgramRunner.State.FAILED and after_move.world.tick_index == 1, "动作后遇到计算预算错误不再多推进世界时间")


## 行号通知中的取消不能继续初始化；重新运行使用全新变量存储。
func _test_cancel_retry() -> void:
	var source := "variable count=0\nmain(){count=count+1\nmove(0,count)}"
	for unused in 2:
		var runner := _runner(source)
		runner.start()
		_finish(runner)
		_check(runner.state == ProgramRunner.State.COMPLETED and runner.world.player.position.is_equal_approx(Vector2(6,5)), "重新运行从声明初值开始，不保留上一次全局变量")
	var cancelled := _runner("constant step=.1\nmain(){move(0,step)}")
	var handler := func(line: int) -> void:
		if line == 1:
			cancelled.step()
			cancelled.cancel()
	cancelled.line_changed.connect(handler)
	_check(not cancelled.start().is_ok() and cancelled.state == ProgramRunner.State.CANCELLED and cancelled.world.tick_index == 0, "全局初始化通知内可取消，重入 step 不执行后续移动")
	cancelled.line_changed.disconnect(handler)
	cancelled.world.step()
	_check(cancelled.world.player.position == Vector2(5,5), "初始化取消不残留真实动作队列")


## 手工 AST 不能逃过名称、常量、作用域、循环引用和预算边界。
func _test_public_ast() -> void:
	for mode in ["missing","constant","duplicate","null_global","null_expression","cycle","tick_write","parallel_write","budget"]:
		var ast: ProgramAst.ProgramNode = _parse("constant step=.1\nmain(){variable count=1\ncount=count+1\nmove(0,step)}").value
		var declaration := ast.main.body.statements[0] as ProgramAst.DeclarationNode
		var assignment := ast.main.body.statements[1] as ProgramAst.AssignmentNode
		var cycle: ProgramAst.BinaryNode
		match mode:
			"missing": assignment.name = "absent"
			"constant": assignment.name = "step"
			"duplicate": ast.main.body.statements.insert(1,declaration)
			"null_global": ast.globals.append(null)
			"null_expression": declaration.initializer = null
			"cycle":
				cycle = ProgramAst.BinaryNode.new()
				cycle.operator = "+"
				cycle.left = cycle
				cycle.right = declaration.initializer
				declaration.initializer = cycle
			"tick_write":
				ast.tick = ProgramAst.FunctionNode.new()
				ast.tick.name = "tick"
				ast.tick.body = ProgramAst.BlockNode.new()
				ast.tick.body.statements.append(declaration)
			"parallel_write":
				var parallel := ProgramAst.SimultaneousNode.new()
				parallel.body = ProgramAst.BlockNode.new()
				parallel.body.statements.append(declaration)
				parallel.body.statements.append(ast.main.body.statements[2])
				ast.main.body.statements.append(parallel)
			"budget":
				for unused in ProgramParser.MAX_STATEMENTS:
					ast.main.body.statements.append(assignment)
		var runner := ProgramRunner.create(ast,_world())
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 "), "公开变量 AST 在任何世界动作前有界拒绝：" + mode)
		if cycle != null:
			cycle.left = null


## 所有测试显式开放常变量，避免依赖关卡 UI 的隐式权限。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source,_calls,true,true,true,true,true,true,true,true)


## 源码不能编译时报告夹具失败，后续运行不得静默替换答案。
func _runner(source: String) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "常变量执行夹具源码可编译：" + str(parsed.errors))
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode,_world())


## 使用真实四种模块的内存地图，使运动、测距与近战都经过正式模拟代码。
func _world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y),"floor")
	document.player_spawn = {"position":{"x":5,"y":5},"modules":[
		{"id":"drive","module_id":"movement","offset":{"x":0,"y":0}},
		{"id":"sensor","module_id":"rangefinder","offset":{"x":.5,"y":0}},
		{"id":"gun","module_id":"shooting","offset":{"x":-.5,"y":0}},
		{"id":"blade","module_id":"melee","offset":{"x":0,"y":.5}},
	]}
	var created := SimulationWorld.create(document,_content)
	_check(created.is_ok(), "常变量测试创建独立真实世界")
	return created.value as SimulationWorld


## 测试推进始终有界，合法有限程序应在预算内终止。
func _finish(runner: ProgramRunner) -> void:
	for unused in 300:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 累计断言并使任何失败产生非零退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
