extends SceneTree
## 玩家雷达语言回归：独立解锁、真实快照、空目标、固定属性和严格数值边界。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


class InvalidScanWorld extends SimulationWorld:
	## 注入不可信查询值，验证解释器公开边界不会执行对象成员或隐式转数值。
	var scan_value: Variant

	## 仅替换只读查询结果，其余模块能力预检仍使用正式世界实现。
	func query_scan(_machine_id: String, _module_id: String = "") -> DataResult:
		return DataResult.success(scan_value)


## 使用内存世界并延迟启动，不读取或写入实际玩家记录。
func _initialize() -> void:
	_run.call_deferred()


## 所有断言使用明确完成标记，失败统一产生非零退出码。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "雷达语言加载真实模块内容"):
		quit(1)
		return
	_test_parser_and_unlocks()
	_test_reserved_module_names()
	_test_real_queries()
	_test_snapshots_and_scopes()
	_test_null_and_types()
	_test_capability_preflight()
	_test_public_ast_and_values()
	print("玩家雷达语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 模块查询与值成员分离：目标属性不偷偷要求命名模块权限，也不开放其他语法。
func _test_parser_and_unlocks() -> void:
	var source := "main(){variable target=scan()\nif(target!=null){move(target.Angle()+90,1)}else{move(0,0)}}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "scan 结果可存入变量并在 null 判断后计算闪避角度"):
		var declaration := parsed.value.main.body.statements[0] as ProgramAst.DeclarationNode
		var branch := parsed.value.main.body.statements[1] as ProgramAst.IfNode
		_check(declaration.initializer is ProgramAst.ScanNode and branch.condition is ProgramAst.ComparisonNode, "扫描与 null 比较保留独立显式 AST")
		_check((branch.condition as ProgramAst.ComparisonNode).right is ProgramAst.NullNode, "null 不伪装成缺失的表达式")
	_check(not ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true).is_ok(), "旧十参数接口默认不开放雷达")
	_check(ProgramParser.parse(source, _calls, false, false, false, true, false, false, false, true, true).is_ok(), "快照成员只依赖雷达与变量权限，不依赖命名调用")
	_check(ProgramParser.parse("main(){if(scan()!=Null){move(scan().Angle(),.1)}else{move(0,0)}}", _calls, false, false, false, true, false, false, false, false, true).is_ok(), "雷达直接查询与 Null 兼容拼写不自动依赖变量")
	_check(not ProgramParser.parse("main(){variable target=scan()}", _calls, false, true, false, false, false, false, false, false, true).is_ok(), "雷达权限不开放变量声明")
	_check(not ProgramParser.parse("main(){move(sensor.scan().Angle(),.1)}", _calls, false, false, false, false, false, false, false, false, true).is_ok(), "命名 scan 仍独立要求命名模块权限")
	_check(not ProgramParser.parse("main(){move(distance(0),.1)}", _calls, false, false, false, false, false, false, false, false, true).is_ok(), "雷达权限不开放测距指令")
	_check(not ProgramParser.parse("main(){if(scan()!=null){move(0,0)}else{move(0,0)}}", _calls, false, false, false, false, false, false, false, false, true).is_ok(), "雷达权限不开放条件分支")
	for member in ["scan().Angle()", "sensor.scan().Position.x", "scan().Position.y", "scan().Distance", "scan().Distance()", "(scan()).Angle()"]:
		_check(_parse("main(){move(0," + member + ")}").is_ok(), "白名单查询表达式可解析：" + member)
	for source_invalid in [
		"main(){variable target=scan(0)}", "main(){move(scan().Angle(1),0)}", "main(){move(scan().Angle,0)}",
		"main(){move(scan().Position(),0)}", "main(){move(scan().Position.x(),0)}", "main(){move(scan().get_script(),0)}",
		"main(){move(scan().health,0)}", "main(){scan()}", "main(){variable scan=1}", "main(){variable Null=1}",
		"main(){variable target=scan()\ntarget.Position=1}", "main(){variable target=scan()\ntarget.Position.x=1}",
		"main(){variable target=scan()\ntarget.Angle()}", "main(){variable target=scan()\nmove(target.call(),0)}",
		"main(){variable target=scan()\nmove(unknown.Angle(),0)}", "main(){variable target=scan()\nmove(target[0],0)}",
	]:
		var result := _parse(source_invalid)
		_check(not result.is_ok() and result.errors[0].contains("第 "), "不支持的调用与属性赋值保留源码错误：" + source_invalid)


## 空目标的两种拼写不能成为装配实例名，失败的添加或改名保留原装配。
func _test_reserved_module_names() -> void:
	var level := LevelDefinition.new()
	level.document = MapDocument.new()
	level.module_limit = 1
	level.allowed_modules = PackedStringArray(["radar"])
	var assembly := AssemblyModel.create(level, _content)
	for name in ["null", "Null"]:
		_check(not AssemblyModel.is_instance_name(name), "装配名称拒绝空目标保留字：" + name)
		_check(not ProgramParser.is_receiver_name(name), "解析器接收者拒绝空目标保留字：" + name)
		_check(not assembly.add_module("radar", Vector2.ZERO, name).is_ok() and assembly.modules.is_empty(), "添加保留名称不会产生无法调用的模块：" + name)
		_check(not _parse("main(){variable target=" + name + ".scan()}").is_ok(), "保留字不能通过显式 scan 接收者调用：" + name)
	if _check(assembly.add_module("radar", Vector2.ZERO, "scan").is_ok(), "模块名 scan 可由显式接收者语法区分，不扩大保留范围"):
		for name in ["null", "Null"]:
			_check(not assembly.rename_module(0, name).is_ok() and assembly.modules[0].id == "scan", "重命名为保留字时保留原有效实例名：" + name)
	_check(ProgramParser.is_receiver_name("scan") and _parse("main(){variable target=scan.scan()}").is_ok(), "scan.scan() 明确调用命名雷达，仍可解析")
	_check(AssemblyModel.is_instance_name("NullSensor") and ProgramParser.is_receiver_name("NullSensor"), "仅拒绝完整保留字，不拒绝包含 Null 的普通名称")


## 动作真正使用雷达角度与位置，查询本身不消耗模拟帧或推进敌人。
func _test_real_queries() -> void:
	var direct := _runner("main(){move(scan().Angle()+90,.1)}")
	_check(direct.start().is_ok() and direct.world.tick_index == 0, "scan 只读取世界，不在启动时消耗 tick")
	_finish(direct)
	_check(direct.state == ProgramRunner.State.COMPLETED and direct.world.player.position.is_equal_approx(Vector2(5,4.9)), "雷达朝右目标加九十度后真实向上移动")
	var named := _runner("main(){constant target=sensor.scan()\nconstant point=target.Position\nmove(target.Angle(),point.x-9+.1)\nmove(90,point.y-5+.1)}")
	named.start()
	_finish(named)
	_check(named.state == ProgramRunner.State.COMPLETED and named.world.player.position.is_equal_approx(Vector2(5.1,4.9)), "具名雷达返回真实位置，坐标能存入常量再读 x/y")
	var distance := _runner("main(){constant target=scan()\nif(target.Distance==target.Distance()){move(0,.1)}else{move(180,.1)}}")
	distance.start()
	_finish(distance)
	_check(distance.state == ProgramRunner.State.COMPLETED and distance.world.player.position.is_equal_approx(Vector2(5.1,5)), "Distance 属性与兼容空括号形式读取同一有限测量值")
	var guarded := _runner("main(){if(scan()!=null){move(0,.1)}else{move(180,.1)}}", false)
	guarded.start()
	_finish(guarded)
	_check(guarded.state == ProgramRunner.State.COMPLETED and guarded.world.player.position.is_equal_approx(Vector2(4.9,5)), "没有敌人时返回 null 并执行真实的 else 动作")


## 变量保存查询时的独立快照；函数局部与每轮扫描沿用已有词法作用域。
func _test_snapshots_and_scopes() -> void:
	var snapshot := _runner("constant target=scan()\nmain(){move(90,1)\nif(target.Angle()==0){move(0,.1)}else{move(180,.1)}\nif(scan().Angle()==0){move(180,.1)}else{move(90,.1)}}")
	snapshot.start()
	_finish(snapshot)
	_check(snapshot.state == ProgramRunner.State.COMPLETED and snapshot.world.player.position.is_equal_approx(Vector2(5.1,3.9)), "旧快照保留角度，新 scan 使用移动后的真实相对方向")
	var copied := _runner("variable target=scan()\nconstant previous=target\nmain(){target=null\nif(target==Null){move(previous.Angle(),.1)}else{move(180,.1)}}")
	copied.start()
	_finish(copied)
	_check(copied.state == ProgramRunner.State.COMPLETED and copied.world.player.position.is_equal_approx(Vector2(5.1,5)), "目标变量改为 null 不会修改此前复制保存的快照")
	var function := _runner("main(){check_target()\ncheck_target()}\nfunction check_target(){variable target=scan()\nif(target!=null){move(target.Angle()+90,.1)}else{move(0,0)}}")
	function.start()
	_finish(function)
	_check(function.state == ProgramRunner.State.COMPLETED and function.world.tick_index == 2 and function.world.player.position.y < 4.81, "每次函数调用重新创建局部雷达变量并扫描一次")
	var repeated := _runner("main(){loop{variable target=scan()\nif(target!=null){move(90,.1)}else{move(0,0)}}}")
	repeated.start()
	for unused in 5:
		repeated.step()
	_check(repeated.state == ProgramRunner.State.RUNNING and repeated.world.tick_index == 5 and repeated.world.player.position.is_equal_approx(Vector2(5,4.5)), "循环内重复声明雷达变量不泄漏作用域，也不增加隐藏 tick")
	repeated.cancel()
	_check(not _parse("main(){constant target=scan()\ntarget=null}").is_ok(), "保存雷达目标的常量仍禁止重新赋值")
	_check(not _parse("main(){variable target=scan()}\nfunction wrong(){move(target.Angle(),0)}").is_ok(), "函数不能越过词法边界读取 main 局部雷达变量")


## null 和坐标不能被隐式转换为动作数字；属性错误明确指向源码而非脚本崩溃。
func _test_null_and_types() -> void:
	for expression in ["scan()", "null", "scan().Position", "scan()+1", "+scan()", "scan().Position+1", "scan().Angle().x", "scan().Position.Angle()", "scan().Position.x.y"]:
		var runner := _runner("main(){move(0," + expression + ")}")
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("第 "), "非数值参数在任何移动前被拒绝：" + expression)
	for condition in ["scan()<null", "scan()==scan()", "1==null", "scan().Position!=null"]:
		var runner := _runner("main(){if(" + condition + "){move(0,.1)}else{move(0,0)}}")
		_check(not runner.start().is_ok() and runner.world.tick_index == 0, "条件不允许隐式跨类型比较：" + condition)
	var missing := _runner("main(){variable target=scan()\nmove(target.Angle(),.1)}", false)
	_check(not missing.start().is_ok() and missing.message.contains("!= null") and missing.world.tick_index == 0, "空目标属性要求先判空，保留易理解的诊断")
	var dynamic := _runner("main(){variable target=scan()\nmove(0,.1)\ntarget=null\nmove(target,1)}")
	dynamic.start()
	_finish(dynamic)
	_check(dynamic.state == ProgramRunner.State.FAILED and dynamic.message.contains("第 4 行") and dynamic.world.player.position.is_equal_approx(Vector2(5.1,5)), "动态变成 null 的参数在实际动作行失败且保留此前位移")
	var numeric := _runner("main(){variable target=1\nmove(target.Angle(),.1)}")
	_check(not numeric.start().is_ok() and numeric.message.contains("类型"), "普通数字变量不能当成雷达快照读取")


## 未调用函数也预检雷达能力；实例不存在、损坏或种类不符不能回退到别的模块。
func _test_capability_preflight() -> void:
	for receiver in ["missing", "drive"]:
		var runner := _runner("main(){move(0,.1)}\nfunction unused(){variable target=" + receiver + ".scan()}")
		_check(not runner.start().is_ok() and runner.world.tick_index == 0 and runner.message.contains("scan"), "未调用函数中无效雷达实例也在首动作前拒绝：" + receiver)
	var broken := _runner("main(){move(0,.1)}\nfunction unused(){variable target=scan()}")
	broken.world.player.get_module("sensor").apply_damage(1.0)
	_check(not broken.start().is_ok() and broken.world.tick_index == 0, "损坏雷达不能从世界存在的其他能力获得回退")
	var no_radar := _runner("main(){if(scan()==null){move(0,.1)}else{move(0,0)}}")
	no_radar.world.player.modules.remove_at(1)
	_check(not no_radar.start().is_ok(), "未安装雷达不能将能力缺失伪装成没有目标")


## 手工 AST 和不可信查询值始终遵守固定字段与深度边界，不执行任意方法。
func _test_public_ast_and_values() -> void:
	for mode in ["member", "cycle", "null_target"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){move(scan().Angle(),.1)}").value
		var call := ast.main.body.statements[0] as ProgramAst.CallNode
		var member := call.arguments[0] as ProgramAst.TargetMemberNode
		match mode:
			"member": member.member = "get_script"
			"cycle": member.target = member
			"null_target": member.target = null
		var runner := ProgramRunner.create(ast, _world())
		_check(not runner.start().is_ok() and runner.world.tick_index == 0, "公开雷达 AST 安全拒绝：" + mode)
		if mode == "cycle":
			member.target = null
	for value: Variant in [true, "enemy", Vector2.ZERO, {"enemy_id":"enemy"}, {"enemy_id":"enemy","position":Vector2(INF,0),"angle":0.0,"distance":1.0}, {"enemy_id":"enemy","position":Vector2.ZERO,"angle":false,"distance":1.0}, {"enemy_id":"enemy","position":Vector2.ZERO,"angle":0.0,"distance":-1.0}, {"enemy_id":"enemy","position":Vector2.ZERO,"angle":0.0,"distance":1.0,"script":"anything"}]:
		var base := _world()
		var invalid := InvalidScanWorld.new()
		invalid.document = base.document
		invalid.player = base.player
		invalid.machines = base.machines
		invalid._content = _content
		invalid.scan_value = value
		var runner := ProgramRunner.create(_parse("main(){variable target=scan()\nmove(0,.1)}").value, invalid)
		_check(not runner.start().is_ok() and invalid.tick_index == 0 and runner.message.contains("scan"), "雷达查询边界拒绝不可信值：" + str(value))


## 专项测试显式开放全部语法，关卡权限由独立开关测试覆盖。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true)


## 创建待运行解释器，任何夹具编译失败都计入断言而不静默替换源码。
func _runner(source: String, enemy: bool = true) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "雷达夹具源码可编译：" + str(parsed.errors))
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, _world(enemy))


## 静止警卫与真实驱动/雷达构成独立地图，使查询结果不依赖 UI 或虚假命令。
func _world(enemy: bool = true) -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y), "floor")
	document.player_spawn = {"position":{"x":5,"y":5},"modules":[
		{"id":"drive","module_id":"movement","offset":{"x":0,"y":0}},
		{"id":"sensor","module_id":"radar","offset":{"x":.5,"y":0}},
	]}
	if enemy:
		document.enemies = [{"id":"enemy", "behavior":"alarm_guard", "position":{"x":9,"y":5}, "modules":[{"id":"blade","module_id":"melee","offset":{"x":0,"y":0}}], "properties":{}}]
	var created := SimulationWorld.create(document, _content)
	_check(created.is_ok(), "雷达测试建立真实独立世界：" + str(created.errors))
	return created.value as SimulationWorld


## 每个有限用例在固定步数内结束，失败与取消都停止推进。
func _finish(runner: ProgramRunner) -> void:
	for unused in 300:
		if runner.state != ProgramRunner.State.RUNNING:
			return
		runner.step()


## 累计断言，失败输出具体行为而非仅比较实现细节。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
