extends SceneTree
## 玩家随机函数回归：独立权限、闭区间、动态参数及与模拟时间和其他随机源隔离。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 等待脚本类型初始化后启动内存测试，不读取或写入玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 汇总解析、取样、调度与公开 AST 边界，任何失败均产生非零退出码。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "随机语言加载真实模块内容"):
		quit(1)
		return
	_test_parser_and_unlocks()
	_test_ranges_and_seed()
	_test_expressions_and_order()
	_test_preflight_and_lazy_execution()
	_test_runtime_errors()
	_test_control_contexts()
	_test_isolation_and_cancel()
	_test_public_ast()
	print("随机语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 随机函数是有独立权限的数值表达式，不暗中开放变量、条件、模块或用户函数。
func _test_parser_and_unlocks() -> void:
	for expression: String in ["random()", "randomInt(-2, 2)", "randomInt(randomInt(0, 1), 2)", "(random()) + .1"]:
		var source := "main(){move(0," + expression + ")}"
		_check(ProgramParser.parse(source, _calls, false, false, false, false, false, false, false, false, false, true).is_ok(), "仅开启随机权限即可在动作参数内使用：" + expression)
		var locked := ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true)
		_check(not locked.is_ok() and locked.errors[0].contains("尚未解锁"), "旧接口末尾省略随机权限仍拒绝：" + expression)
	var legacy := ProgramParser.parse("main(){move(0,random())}")
	_check(not legacy.is_ok() and legacy.errors[0].contains("random"), "旧关数字参数位置给出准确随机未解锁提示")
	_check(ProgramParser.parse("main(){if(random()<.5){move(0,.1)}else{move(180,.1)}}", _calls, false, false, false, true, false, false, false, false, false, true).is_ok(), "随机比较只需随机与条件权限，不依赖变量或测距")
	for source: String in [
		"main(){variable sample=random()}",
		"main(){if(random()<.5){move(0,0)}else{move(0,0)}}",
		"main(){move(distance(0),random())}",
		"main(){move(scan().Angle(),random())}",
		"main(){drive.move(0,random())}",
		"main(){loop{move(0,random())}}",
		"main(){helper()}\nfunction helper(){move(0,random())}",
	]:
		_check(not ProgramParser.parse(source, _calls, false, false, false, false, false, false, false, false, false, true).is_ok(), "随机开关不会越过其他独立权限：" + source)
	for source: String in [
		"main(){move(0,random(1))}", "main(){move(0,randomInt())}",
		"main(){move(0,randomInt(1))}", "main(){move(0,randomInt(0,1,2))}",
		"main(){move(0,randomInt(0,))}", "main(){move(0,randomInt(,1))}",
		"main(){move(0,randomInt(0 1))}", "main(){move(0,random)}",
		"main(){random()}", "main(){randomInt(0,1)}",
		"main(){variable random=1}", "main(){constant randomInt=1}",
		"main(){}\nfunction random(){move(0,0)}",
		"main(){move(0,gun.random())}", "main(){move(0,randomint(0,1))}",
		"main(){move(0,randomInt(missing,1))}",
	]:
		var result := _parse(source)
		_check(not result.is_ok() and result.errors[0].contains("第 "), "非法随机语法或隐藏名称包含源码诊断：" + source)
	var parsed := _parse("main(){move(randomInt(-90,90),random())}")
	if _check(parsed.is_ok(), "随机表达式可解析为显式 AST"):
		var call := parsed.value.main.body.statements[0] as ProgramAst.CallNode
		var integer := call.arguments[0] as ProgramAst.RandomNode
		var fractional := call.arguments[1] as ProgramAst.RandomNode
		_check(integer != null and integer.callee == "randomInt" and integer.arguments.size() == 2, "整数随机节点保留两个端点表达式")
		_check(fractional != null and fractional.callee == "random" and fractional.arguments.is_empty(), "普通随机节点与无参动作明确区分")
	_check(_parse("main(){move(0,randomInt(\n0,\n1\n))}").is_ok(), "随机参数括号内支持自然换行")
	_check(not _parse("main(){move(0," + "randomInt(0,".repeat(40) + "1" + ")".repeat(40) + ")}").is_ok(), "嵌套随机查询遵守表达式深度上限")


## 固定种子只用于回归复现；所有结果都保持闭区间且整数值没有小数部分。
func _test_ranges_and_seed() -> void:
	var source := ""
	for index in 64:
		source += "constant f%d=random()\nconstant n%d=randomInt(-2,2)\n" % [index, index]
	source += "constant low=randomInt(-2147483648,-2147483648)\nconstant high=randomInt(2147483647,2147483647)\nmain(){}"
	var runner := _runner(source, 8123)
	var expected := _seeded(8123)
	if not _check(runner.start().is_ok(), "大量有界随机初始化成功且不提交动作"):
		return
	_check(runner.world.tick_index == 0 and runner.state == ProgramRunner.State.COMPLETED, "随机数计算不消耗逻辑 tick")
	for index in 64:
		var fractional := float(_value(runner, "f%d" % index))
		var integer := float(_value(runner, "n%d" % index))
		_check(fractional >= 0.0 and fractional <= 1.0 and fractional == expected.randf(), "random 保持 [0,1] 且仅按源码取一次样本 %d" % index)
		_check(integer >= -2.0 and integer <= 2.0 and integer == floor(integer) and integer == float(expected.randi_range(-2, 2)), "randomInt 保持闭区间整数及独立可复现序列 %d" % index)
	_check(_value(runner, "low") == -2147483648.0 and _value(runner, "high") == 2147483647.0, "相同端点合法并包含完整 signed32 两端")
	var full_source := ""
	for index in 32:
		full_source += "constant n%d=randomInt(-2147483648,2147483647)\n" % index
	var full := _runner(full_source + "main(){}", 731)
	var full_expected := _seeded(731)
	if _check(full.start().is_ok(), "覆盖完整 signed32 区间，不发生区间宽度溢出"):
		for index in 32:
			var sampled := float(_value(full, "n%d" % index))
			_check(sampled >= -2147483648.0 and sampled <= 2147483647.0 and sampled == floor(sampled) and sampled == float(full_expected.randi_range(-2147483648, 2147483647)), "完整 signed32 区间采样安全 %d" % index)


## 嵌套与动态端点从左到右执行，参数、绑定、加减和条件都使用真实计算值。
func _test_expressions_and_order() -> void:
	var nested := _runner("constant a=randomInt(randomInt(-4,0),randomInt(0,4))\nconstant b=+random()-random()\nmain(){move(0,randomInt(0,0)+.1)}", 73)
	var expected := _seeded(73)
	var lower := expected.randi_range(-4, 0)
	var upper := expected.randi_range(0, 4)
	var result := expected.randi_range(lower, upper)
	var difference := expected.randf() - expected.randf()
	nested.start()
	_finish(nested)
	_check(_value(nested, "a") == float(result) and _value(nested, "b") == difference, "嵌套端点及二元表达式不重复求值且保留从左到右顺序")
	_check(nested.state == ProgramRunner.State.COMPLETED and nested.world.player.position.is_equal_approx(Vector2(5.1, 5)), "随机表达式结果实际进入运动参数")
	var dynamic := _runner("variable lo=0\nvariable hi=0\nmain(){move(randomInt(lo,hi),.1)\nlo=90\nhi=90\nmove(randomInt(lo,hi),.1)}")
	dynamic.start()
	_finish(dynamic)
	_check(dynamic.state == ProgramRunner.State.COMPLETED and dynamic.world.player.position.is_equal_approx(Vector2(5.1,4.9)), "端点从执行时的变量读取，不缓存预检值")
	var conditional := _runner("main(){if(randomInt(-1,-1)<0){move(90,.1)}else{move(270,.1)}}")
	conditional.start()
	_finish(conditional)
	_check(conditional.state == ProgramRunner.State.COMPLETED and conditional.world.player.position.is_equal_approx(Vector2(5,4.9)), "随机数值比较驱动实际条件分支")


## 所有静态遍历均不抽样，未选分支和未调用函数中的合法随机表达式不改变序列。
func _test_preflight_and_lazy_execution() -> void:
	var source := "constant first=random()\nvariable second=0\nmain(){if(1==1){move(0,.1)}else{move(0,random())}\nsecond=random()}\nfunction unused(){move(0,random())}"
	var runner := _runner(source, 1928)
	var expected := _seeded(1928)
	_check(runner._validate_program().is_ok() and runner._validate_program().is_ok(), "同一程序重复整树校验成功且不需要运行变量")
	_check(runner.start().is_ok(), "重复预检后的程序仍正常启动")
	_finish(runner)
	_check(_value(runner, "first") == expected.randf() and _value(runner, "second") == expected.randf(), "重复预检、未选分支和未调用函数都没有消耗随机序列")
	var latent := _runner("constant first=random()\nmain(){move(0,.1)}\nfunction unused(){move(0,randomInt(0,1.5))}", 1928)
	_check(not latent.start().is_ok() and latent.world.tick_index == 0, "未执行函数中的静态非法端点也在任何动作前拒绝")
	var no_module := _runner("main(){move(0,.1)}\nfunction unused(){move(0,randomInt(0,missing.distance(0)))}")
	_check(not no_module.start().is_ok() and no_module.world.tick_index == 0 and no_module.message.contains("distance"), "随机参数内的世界查询能力仍参与全树预检")


## 非整数、越界和动态上下限错误不提交动作，诊断指向对应端点并保留此前合法位移。
func _test_runtime_errors() -> void:
	for endpoints: String in [".1,1", "0,1.5", "2,1", "-2147483649,0", "0,2147483648", "0,null", "scan(),1", "0,scan().Position"]:
		var runner := _runner("main(){move(0,.1)\nmove(0,randomInt(" + endpoints + "))}")
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 2 行"), "静态非法端点阻止程序局部执行：" + endpoints)
	for setup: String in ["variable upper=1.5", "variable upper=-1", "variable upper=2147483648", "variable upper=null"]:
		var source := setup + "\nmain(){move(0,.1)\nmove(0,randomInt(0,upper))}"
		var runner := _runner(source)
		_check(runner.start().is_ok(), "动态上限在真正到达动作时检查：" + setup)
		_finish(runner)
		_check(runner.state == ProgramRunner.State.FAILED and runner.world.tick_index == 1 and runner.world.player.position.is_equal_approx(Vector2(5.1,5)) and runner.message.contains("第 3 行，第 20 列"), "动态非法上限准确定位并保留合法前缀：" + setup)
	var dynamic_lower := _runner("variable lower=.25\nmain(){move(0,.1)\nmove(0,randomInt(lower,1))}")
	dynamic_lower.start()
	_finish(dynamic_lower)
	_check(dynamic_lower.state == ProgramRunner.State.FAILED and dynamic_lower.message.contains("第 3 行，第 18 列"), "动态非法下限准确定位第一个端点")
	var invalid_seed := ProgramRunner.create(_parse("main(){move(0,.1)}").value, _world(), "1")
	_check(not invalid_seed.start().is_ok() and invalid_seed.world.tick_index == 0, "测试种子接口拒绝非整数而不隐式转换")


## 循环、用户函数、tick 与原子动作组允许数值随机，但不因此增加额外动作或时钟。
func _test_control_contexts() -> void:
	var function := _runner("variable total=0\nmain(){roll()\nroll()\nmove(0,total)}\nfunction roll(){constant step=randomInt(0,0)+.1\ntotal=total+step}")
	function.start()
	_finish(function)
	_check(function.state == ProgramRunner.State.COMPLETED and function.world.tick_index == 2 and function.world.player.position.is_equal_approx(Vector2(5.2,5)), "函数内随机绑定保留调用作用域且不制造隐藏 tick")
	var loop := _runner("main(){loop{move(randomInt(0,0),.1)}}")
	loop.start()
	for unused in 5:
		loop.step()
	_check(loop.state == ProgramRunner.State.RUNNING and loop.world.tick_index == 5 and loop.world.player.position.is_equal_approx(Vector2(5.5,5)), "每轮随机表达式重新求值且每步最多推进一个世界 tick")
	loop.cancel()
	var parallel := _runner("main(){simultaneously{drive.move(randomInt(0,0),.1)\nblade.attack(randomInt(90,90))}}")
	parallel.start()
	parallel.step()
	_check(parallel.state == ProgramRunner.State.COMPLETED and parallel.world.tick_index == 1 and parallel.world.player.position.is_equal_approx(Vector2(5.1,5)) and parallel.world.attack_traces.size() == 1, "并行动作全部求值后沿用原子提交")
	var invalid_parallel := _runner("variable upper=-1\nmain(){simultaneously{drive.move(0,.1)\nblade.attack(randomInt(0,upper))}}")
	_check(not invalid_parallel.start().is_ok() and invalid_parallel.world.tick_index == 0 and invalid_parallel.world.player.position == Vector2(5,5), "并行后置随机端点错误不会部分提交前置移动")
	var callback := _runner("main(){}\ntick(){blade.attack(randomInt(90,90))}")
	callback.start()
	callback.step()
	var trace: Dictionary = callback.world.attack_traces[0]
	_check(callback.world.tick_index == 1 and trace.to.y < trace.from.y and is_equal_approx(trace.to.x,trace.from.x), "tick 随机参数驱动真实攻击且只推进一次时间")
	callback.cancel()
	var spin := _runner("main(){loop{constant sample=random()}}")
	_check(not spin.start().is_ok() and spin.message.contains("预算") and spin.world.tick_index == 0, "纯随机无限循环仍受连续计算预算限制")


## 新运行器与全局、其他玩家运行器的序列互不干扰；取消不会继续求值后续表达式。
func _test_isolation_and_cancel() -> void:
	var source := "constant first=random()\nvariable second=0\nmain(){move(0,.1)\nsecond=random()}"
	var first := _runner(source, 587)
	var second := _runner(source, 587)
	first.start()
	var noise := _runner("main(){loop{constant sample=random()\nmove(0,0)}}", 962)
	noise.start()
	for unused in 9:
		noise.step()
	noise.cancel()
	second.start()
	_finish(first)
	_finish(second)
	_check(_value(first, "first") == _value(second, "first") and _value(first, "second") == _value(second, "second"), "其他运行器任意取样不改变当前运行器序列")
	seed(1034)
	var global_expected := randf()
	seed(1034)
	var local := _runner("constant sample=random()\nconstant integer=randomInt(-2,2)\nmain(){}")
	local.start()
	_check(randf() == global_expected, "生产默认独立播种及本地抽样不改变全局随机源")
	var cancelled := _runner(source, 587)
	cancelled.start()
	cancelled.cancel()
	for unused in 5:
		cancelled.step()
	_check(cancelled.state == ProgramRunner.State.CANCELLED and _value(cancelled, "second") == 0.0 and cancelled.world.tick_index == 0, "取消后不会执行后续随机赋值或推进世界")
	var retry := _runner(source, 587)
	retry.start()
	_finish(retry)
	_check(_value(retry, "first") == _value(first, "first") and _value(retry, "second") == _value(first, "second"), "重试使用全新运行器，不继承已取消运行的随机进度")


## 外部构造的 AST 仍检查参数、名称、有限值、深度与循环引用，不能绕过正常源代码校验。
func _test_public_ast() -> void:
	for mode: String in ["name", "arity", "empty", "cycle", "missing_name", "infinite"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){move(0,randomInt(0,1))}").value
		var call := ast.main.body.statements[0] as ProgramAst.CallNode
		var random_node := call.arguments[1] as ProgramAst.RandomNode
		match mode:
			"name": random_node.callee = "eval"
			"arity": random_node.arguments.append(ProgramAst.NumberNode.new())
			"empty": random_node.arguments[0] = null
			"cycle": random_node.arguments[0] = random_node
			"missing_name":
				var reference := ProgramAst.NameNode.new()
				reference.name = "absent"
				random_node.arguments[1] = reference
			"infinite": (random_node.arguments[1] as ProgramAst.NumberNode).value = INF
		var runner := ProgramRunner.create(ast, _world(), 42)
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 "), "非法公开随机 AST 在动作前拒绝：" + mode)
		if mode == "cycle":
			random_node.arguments[0] = null


## 专项夹具明确开放全部语言权限，逐项关卡权限由解析和集成回归独立覆盖。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true)


## 编译失败明确记为测试失败，不静默替换夹具源码。
func _runner(source: String, random_seed: Variant = null) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "随机执行夹具源码可编译：" + str(parsed.errors))
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, _world(), random_seed)


## 真实驱动、攻击、测距和雷达提供独立内存世界，动作仍走正式模拟路径。
func _world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y), "floor")
	document.player_spawn = {"position":{"x":5,"y":5},"modules":[
		{"id":"drive","module_id":"movement","offset":{"x":0,"y":0}},
		{"id":"sensor","module_id":"rangefinder","offset":{"x":.5,"y":0}},
		{"id":"blade","module_id":"melee","offset":{"x":0,"y":.5}},
		{"id":"radar","module_id":"radar","offset":{"x":-.5,"y":0}},
	]}
	var created := SimulationWorld.create(document, _content)
	_check(created.is_ok(), "随机测试创建真实独立世界")
	return created.value as SimulationWorld


## 参考 RNG 使用相同显式种子验证抽样次序，不更改程序内部或全局状态。
func _seeded(value: int) -> RandomNumberGenerator:
	var result := RandomNumberGenerator.new()
	result.seed = value
	return result


## 读取完成后的全局绑定，仅用于断言本次运行产生的值，不改写解释器状态。
func _value(runner: ProgramRunner, name: String) -> Variant:
	var binding: Dictionary = runner._globals.resolve(name) if runner._globals != null else {}
	_check(not binding.is_empty(), "运行已经产生全局绑定：" + name)
	return binding.get("value")


## 每个有限用例在固定步数内结束，取消或失败后立即停止推进。
func _finish(runner: ProgramRunner) -> void:
	for unused in 300:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 汇总断言并给出具体失败行为，供测试包装器检查完成标记与退出码。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
