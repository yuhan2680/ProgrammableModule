extends SceneTree
## 有限 for 循环回归：独立解锁、区间语义、迭代作用域与有界真实动作调度。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 延迟建立测试世界，避免读取真实存档或依赖任何场景节点。
func _initialize() -> void:
	_run.call_deferred()


## 验证语法、数值边界、作用域、真实运动和公开 AST 防御后汇总退出。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "有限循环加载真实模块内容"):
		quit(1)
		return
	_test_parser()
	_test_scope()
	_test_range_values()
	_test_dynamic_entry()
	_test_control_and_time()
	_test_errors()
	_test_ast_and_cancel()
	print("有限 for 循环语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 两个点与小数词法保持独立，新权限不自动解锁旧控制结构或常变量声明。
func _test_parser() -> void:
	var tokens := ProgramLexer.tokenize("0..315 0.1..0.3 .5 1. sensor.distance(0)")
	if _check(tokens.is_ok(), "区间与旧小数、具名查询词法共存"):
		_check(tokens.value[0].lexeme == "0" and tokens.value[1].kind == ProgramLexer.Kind.RANGE and tokens.value[2].lexeme == "315", "无空格区间保留独立双点 token")
		_check(tokens.value[3].lexeme == "0.1" and tokens.value[4].kind == ProgramLexer.Kind.RANGE and tokens.value[5].lexeme == "0.3", "小数区间不会把双点吃进数字")
	var source := "main(){for(angle in 0..315 step 45){attack(angle)}}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "标准角度 for 可解析"):
		var loop := parsed.value.main.body.statements[0] as ProgramAst.ForNode
		_check(loop != null and loop.iterator == "angle" and loop.start is ProgramAst.NumberNode and loop.step is ProgramAst.NumberNode, "有限区间及循环变量保留显式 ForNode")
	_check(not ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true).is_ok(), "旧 Parser 接口默认锁定 for")
	_check(_only_for("main(){for(i in 0..2){move(i+1,0)}}").is_ok(), "仅 for 权限支持只读迭代变量及基础数值表达式")
	for rejected: String in [
		"main(){for(i in 0..1){variable n=i}}",
		"main(){for(i in 0..1){loop{move(i,0)}}}",
		"main(){for(i in 0..1){if(i==0){move(0,0)}else{move(0,0)}}}",
		"main(){for(i in 0..randomInt(0,1)){move(i,0)}}",
		"main(){for(i in 0..distance(0)){move(i,0)}}",
	]:
		_check(not _only_for(rejected).is_ok(), "for 不越过其他语法或查询权限：" + rejected)
	for rejected: String in [
		"main(){for(i 0..2){move(0,0)}}", "main(){for(i in 0,2){move(0,0)}}",
		"main(){for(i in 0..2 step){move(0,0)}}", "main(){for(i in 0..2){}}",
		"main(){for move in 0..2{move(0,0)}}", "main(){for(move in 0..2){move(0,0)}}",
		"main(){}\ntick(){for(i in 0..2){attack(i)}}",
		"main(){simultaneously{for(i in 0..2){attack(i)}\nmove(0,0)}}",
	]:
		var result := _parse(rejected)
		_check(not result.is_ok() and result.errors[0].contains("第 "), "非法有限循环保留源码诊断：" + rejected)
	_check(_parse("constant step=2\nmain(){for(i in 0..step step step){move(i,0)}}").is_ok(), "step 是上下文关键字，旧变量名称继续可用")
	_check(_parse("main(){for(\nangle in\n0..\n90 step\n45\n)\n{attack(angle)}}").is_ok(), "for 头部与花括号之间支持自然换行")


## 迭代变量只读、不泄漏，每轮创建新局部；函数只读取自己的词法全局。
func _test_scope() -> void:
	for rejected: String in [
		"main(){for(i in 0..2){i=3}}",
		"main(){for(i in 0..2){constant i=3}}",
		"main(){for(i in 0..2){move(0,0)}\nmove(i,0)}",
		"main(){for(i in 0..i){move(0,0)}}",
		"main(){for(i in missing..2){move(0,0)}}",
		"main(){for(i in 0..2){helper()}}\nfunction helper(){move(i,0)}",
		"main(){for(helper in 0..2){move(0,0)}}\nfunction helper(){move(0,0)}",
		"main(){}\nfunction unused(){for(i in 0..2){absent()}}",
		"main(){}\nfunction cycle(){for(i in 0..2){cycle()}}",
	]:
		_check(not _parse(rejected).is_ok(), "循环作用域或调用图拒绝非法路径：" + rejected)
	var shadow := _runner("constant i=90\nmain(){for(i in 0..0){move(i,.1)}\nmove(i,.1)}")
	shadow.start()
	_finish(shadow)
	_check(shadow.state == ProgramRunner.State.COMPLETED and shadow.world.player.position.is_equal_approx(Vector2(5.1,4.9)), "for 结束后恢复同名外层常量")
	var locals := _runner("variable total=0\nmain(){for(i in 0..2){constant local=i\ntotal=total+local\nmove(0,0)}}")
	locals.start()
	_finish(locals)
	_check(locals.state == ProgramRunner.State.COMPLETED and _value(locals,"total") == 3.0 and locals.world.tick_index == 3, "每轮局部重新声明且外层变量保留累计")
	var outer_bound := _runner("constant i=2\nvariable total=0\nmain(){for(i in i..3){total=total+i\nmove(0,0)}}")
	outer_bound.start()
	_finish(outer_bound)
	_check(_value(outer_bound,"total") == 5.0, "区间初始化读取外层同名值，再声明迭代变量")


## 区间两端包含，默认步长为一；小数不会因为累积误差多走或漏走一次。
func _test_range_values() -> void:
	for fixture: Dictionary in [
		{"header":"0..3", "sum":6.0, "ticks":4},
		{"header":"3..0 step -1", "sum":6.0, "ticks":4},
		{"header":"0..0.3 step .1", "sum":.6, "ticks":4},
		{"header":".3..0 step -.1", "sum":.6, "ticks":4},
		{"header":"0..1 step 2", "sum":0.0, "ticks":1},
		{"header":"2..2 step -3", "sum":2.0, "ticks":1},
		{"header":"0..5 step 2", "sum":6.0, "ticks":3},
		{"header":"0..0.0000000000000001 step 100", "sum":0.0, "ticks":1},
	]:
		var runner := _runner("variable total=0\nmain(){for(i in " + str(fixture.header) + "){total=total+i\nmove(0,0)}}")
		runner.start()
		_finish(runner)
		_check(runner.state == ProgramRunner.State.COMPLETED and is_equal_approx(float(_value(runner,"total")),float(fixture.sum)) and runner.world.tick_index == int(fixture.ticks), "闭区间的真实次数与数值：" + str(fixture.header))
	var cap := _runner("main(){for(i in 0..4095){move(0,0)}}")
	_check(cap.start().is_ok(), "单次 for 允许恰好 4096 次迭代")
	for unused in 4096:
		cap.step()
	_check(cap.state == ProgramRunner.State.COMPLETED and cap.world.tick_index == 4096, "最大合法区间按帧完成而不展开成源码")


## 上下限和步长只在进入循环时计算一次，改变外层绑定不回写已开始的区间。
func _test_dynamic_entry() -> void:
	var runner := _runner("variable end=2\nvariable step=1\nvariable total=0\nmain(){for(i in 0..end step step){end=0\nstep=20\ntotal=total+i\nmove(0,0)}}")
	runner.start()
	_finish(runner)
	_check(runner.state == ProgramRunner.State.COMPLETED and runner.world.tick_index == 3 and _value(runner,"total") == 3.0, "循环体修改上限与步长变量不会改变进入时的快照")
	var random_source := "variable total=0\nvariable tail=0\nmain(){for(i in randomInt(0,1)..randomInt(2,3) step randomInt(1,1)){total=total+i\nmove(0,0)}\ntail=random()}\nfunction unused(){for(j in 0..randomInt(0,3)){move(0,0)}}"
	var seeded := _runner(random_source, 731)
	var expected := RandomNumberGenerator.new()
	expected.seed = 731
	var first := expected.randi_range(0,1)
	var last := expected.randi_range(2,3)
	expected.randi_range(1,1)
	var tail := expected.randf()
	var sum := 0.0
	for index in range(first,last+1):
		sum += index
	_check(seeded._validate_program().is_ok() and seeded.start().is_ok(), "随机范围可重复预检而不消耗随机序列")
	_finish(seeded)
	_check(_value(seeded,"total") == sum and _value(seeded,"tail") == tail and seeded.world.tick_index == last-first+1, "区间随机表达式只取一次且未调用函数不消耗随机序列")


## for 与已有循环、函数、分支、原子组组合时，仍每次 step 最多推进一个世界 tick。
func _test_control_and_time() -> void:
	var octants := _runner("main(){for(angle in 0..315 step 45){blade.attack(angle)}}")
	octants.start()
	for index in 8:
		var before := octants.world.tick_index
		octants.step()
		_check(octants.world.tick_index == before+1 and octants.world.attack_traces.size() == 1, "八方攻击每轮恰好一个真实动作 tick %d" % index)
		var trace: Dictionary = octants.world.attack_traces[0]
		var heading := Vector2(cos(deg_to_rad(index*45.0)), -sin(deg_to_rad(index*45.0)))
		_check((trace.to-trace.from).normalized().is_equal_approx(heading), "迭代角度决定真实攻击方向 %d" % index)
	_check(octants.state == ProgramRunner.State.COMPLETED, "最后一次 for 动作结束即正常退出")
	var nested := _runner("main(){for(i in 0..1){for(j in 0..1){simultaneously{move(0,.1)\nattack(90)}}}}")
	nested.start()
	_finish(nested)
	_check(nested.state == ProgramRunner.State.COMPLETED and nested.world.tick_index == 4 and nested.world.player.position.is_equal_approx(Vector2(5.4,5)), "嵌套 for 与并行组保持原子动作及顺序等待")
	var branch := _runner("main(){for(i in 0..2){if(i==0){move(0,.1)}else{move(90,.1)}}}")
	branch.start()
	_finish(branch)
	_check(branch.state == ProgramRunner.State.COMPLETED and branch.world.tick_index == 3 and branch.world.player.position.is_equal_approx(Vector2(5.1,4.8)), "每轮分支读取当前迭代变量并恢复正确循环帧")
	var functions := _runner("main(){twice()\ntwice()}\nfunction twice(){for(i in 0..1){move(0,.1)}}")
	functions.start()
	_finish(functions)
	_check(functions.state == ProgramRunner.State.COMPLETED and functions.world.tick_index == 4 and functions.world.player.position.is_equal_approx(Vector2(5.4,5)), "每次函数调用重建有限循环执行帧")
	var repeat := _runner("main(){loop{for(i in 0..1){move(0,.1)}}}")
	repeat.start()
	for unused in 6:
		repeat.step()
	_check(repeat.world.tick_index == 6 and repeat.world.player.position.is_equal_approx(Vector2(5.6,5)), "外层 loop 每次重新进入有限 for")
	repeat.cancel()
	var scan := _runner("variable aim=0\nmain(){loop{for(angle in 0..315 step 45){if(sensor.distance(angle)<6){aim=angle}}\ngun.shoot(aim)}}")
	_check(scan.start().is_ok() and scan.world.tick_index == 0, "有限扫描可省略 else，在一次真实动作前完成八个角度检测")
	scan.step()
	_check(scan.state == ProgramRunner.State.RUNNING and scan.world.tick_index == 1 and scan.world.projectiles.size() == 1, "扫描循环使用最后检测方向提交真实射击，不需要占位 else")
	scan.cancel()
	var budget := _runner("main(){for(i in 0..4095){for(j in 0..4095){constant v=i+j}}}")
	_check(not budget.start().is_ok() and budget.world.tick_index == 0 and budget.message.contains("预算"), "嵌套纯计算 for 仍受连续计算预算约束，不阻塞一帧")


## 常量错误在任何动作前拒绝，动态错误在进入处定位，且后续动作不会部分执行。
func _test_errors() -> void:
	for header: String in ["0..2 step 0", "0..2 step -1", "2..0", "0..4096", "0..1 step .00001", "null..2", "0..scan()", "0..2 step scan().Position", "10000000000000000..10000000000000004 step 1"]:
		var runner := _runner("main(){move(0,.1)\nfor(i in " + header + "){move(0,.1)}}")
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 2 行"), "静态非法区间在任何动作前拒绝：" + header)
	for initial: String in ["0", "-1", ".00001", "null"]:
		var runner := _runner("variable stride=" + initial + "\nmain(){move(0,.1)\nfor(i in 0..2 step stride){move(0,.1)}}")
		_check(runner.start().is_ok(), "动态步长延后到真正进入时检查：" + initial)
		_finish(runner)
		_check(runner.state == ProgramRunner.State.FAILED and runner.world.tick_index == 1 and runner.world.player.position.is_equal_approx(Vector2(5.1,5)) and runner.message.contains("第 3 行"), "动态非法步长保留合法前缀位移：" + initial)
	var missing_sensor := _runner("main(){move(0,.1)}\nfunction unused(){for(i in 0..missing.distance(0)){move(0,0)}}")
	_check(not missing_sensor.start().is_ok() and missing_sensor.world.tick_index == 0, "未调用 for 边界中的模块能力同样整树预检")


## 公开 AST 的篡改不能跳过循环结构限制，取消和重试不继续旧循环。
func _test_ast_and_cancel() -> void:
	for mode: String in ["null_bound", "cycle", "bad_name", "empty", "tick", "nonfinite"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){for(i in 0..2){move(i,0)}}").value
		var loop := ast.main.body.statements[0] as ProgramAst.ForNode
		match mode:
			"null_bound": loop.start = null
			"cycle": loop.body.statements.append(loop)
			"bad_name": loop.iterator = "random"
			"empty": loop.body.statements.clear()
			"tick":
				ast.tick = ProgramAst.FunctionNode.new()
				ast.tick.name = "tick"
				ast.tick.body = ast.main.body
			"nonfinite": (loop.step as ProgramAst.NumberNode).value = INF
		var runner := ProgramRunner.create(ast,_world())
		_check(not runner.start().is_ok() and runner.world.tick_index == 0, "非法公开 for AST 运行前拒绝：" + mode)
		if mode == "cycle":
			loop.body.statements.pop_back()
	var cancelled := _runner("main(){for(i in 0..3){move(0,.1)}}")
	cancelled.start()
	cancelled.step()
	cancelled.cancel()
	cancelled.step()
	_check(cancelled.state == ProgramRunner.State.CANCELLED and cancelled.world.tick_index == 1 and cancelled.world.player.position.is_equal_approx(Vector2(5.1,5)), "中途取消不继续剩余迭代")
	var retry := _runner("main(){for(i in 0..3){move(0,.1)}}")
	retry.start()
	_finish(retry)
	_check(retry.state == ProgramRunner.State.COMPLETED and retry.world.tick_index == 4, "重试建立完整新有限循环")


## 专项测试默认显式开放所有语法，关卡权限由单独测试限定。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source,_calls,true,true,true,true,true,true,true,true,true,true,true)


## 只打开有限循环能力，验证它不会依赖变量解锁或附带开启其他指令。
func _only_for(source: String) -> DataResult:
	return ProgramParser.parse(source,_calls,false,false,false,false,false,false,false,false,false,false,true)


## 编译失败也计入断言，不静默替换夹具代码。
func _runner(source: String, random_seed: Variant = null) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "for 执行夹具可解析：" + str(parsed.errors))
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode,_world(),random_seed)


## 模块能力与动作使用独立内存世界，地图不存在敌人或时间目标干扰。
func _world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y),"floor")
	document.player_spawn = {"position":{"x":5,"y":5},"modules":[
		{"id":"drive","module_id":"movement","offset":{"x":0,"y":0}},
		{"id":"blade","module_id":"melee","offset":{"x":0,"y":.5}},
		{"id":"sensor","module_id":"rangefinder","offset":{"x":.5,"y":0}},
		{"id":"radar","module_id":"radar","offset":{"x":-.5,"y":0}},
		{"id":"gun","module_id":"shooting","offset":{"x":0,"y":-.5}},
	]}
	var result := SimulationWorld.create(document,_content)
	_check(result.is_ok(), "for 测试创建真实模拟世界")
	return result.value as SimulationWorld


## 只读已生成的全局绑定，验证计算结果而不改写执行器作用域。
func _value(runner: ProgramRunner, name: String) -> Variant:
	var binding: Dictionary = runner._globals.resolve(name) if runner._globals != null else {}
	_check(not binding.is_empty(), "运行已生成全局值：" + name)
	return binding.get("value")


## 有限测试在明确步数内停止，不允许失败和取消后的继续执行。
func _finish(runner: ProgramRunner) -> void:
	for unused in 100:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 累计断言并使用具体错误原因供包装脚本识别。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
