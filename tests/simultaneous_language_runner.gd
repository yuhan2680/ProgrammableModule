extends SceneTree
## 第八关语言回归：显式并行 AST、全树原子预检和固定 tick 的等待/取消契约。

var _calls := PackedStringArray(["move", "attack", "shoot"])
const TWO_ATTACKS := "simultaneously {\nleft.attack(180)\nright.attack(0)\n}"
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _callback_runner: ProgramRunner
var _finished_count := 0
var _lines: Array[int] = []


## 等待初始化完成后运行，不读取或修改正式玩家草稿。
func _initialize() -> void:
	_run.call_deferred()


## 使用真实模块和模拟接口验证并行语义，测试失败统一返回非零状态。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "并行语言测试可以加载真实内容"):
		quit(1)
		return
	_test_parser()
	_test_preflight()
	_test_public_ast()
	_test_same_tick()
	_test_wait_all()
	_test_control_flow()
	_test_tick_coexistence()
	_test_cancellation_and_reentry()
	print("并行语言回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 并行是块语句而非函数；权限、深度、调用预算和原始行列均继续生效。
func _test_parser() -> void:
	var source := "main(){\n  simultaneously\n  {\n    left.attack(-180.5)\n    right.attack(+.25)\n  }\n}"
	var parsed := _parse(source)
	if _check(parsed.is_ok(), "第八关开放后接受换行并行块与有符号小数"):
		var node := parsed.value.main.body.statements[0] as ProgramAst.SimultaneousNode
		_check(node != null and node.line == 2 and node.column == 3, "并行保持独立 AST 节点及关键字行列")
		_check(node.body.statements.size() == 2 and node.body.statements[0] is ProgramAst.CallNode, "并行 AST 保留两个子调用，不展开为顺序语句")
		var first := node.body.statements[0] as ProgramAst.CallNode
		_check(first.receiver == "left" and first.line == 4 and first.column == 5 and first.arguments[0].value == -180.5, "子动作保留命名、数字和自己的源码位置")
	var locked := ProgramParser.parse(source, _calls, true, true, true, true)
	_check(not locked.is_ok() and locked.errors[0].contains("尚未解锁") and locked.errors[0].contains("simultaneously"), "旧六参数调用默认锁定并行，前七关不自动升级")
	_check(not ProgramParser.is_receiver_name("simultaneously"), "开放语法后并行关键字仍不可用作模块名")
	var samples: Array[Dictionary] = [
		{"code": "simultaneously{}", "reason": "至少需要两条"},
		{"code": "simultaneously{left.attack(0)}", "reason": "至少需要两条"},
		{"code": "simultaneously(){left.attack(0)\nright.attack(0)}", "reason": "不接受函数括号"},
		{"code": "simultaneously{left.attack(0) right.attack(0)}", "reason": "每行只能写一条"},
		{"code": "simultaneously{left.attack(0);\nright.attack(0)}", "reason": "不允许分号"},
		{"code": "simultaneously{loop{left.attack(0)}\nright.attack(0)}", "reason": "只接受直接动作"},
		{"code": "simultaneously{if(gun.ready()){gun.shoot(0)}else{left.attack(0)}\nright.attack(0)}", "reason": "只接受直接动作"},
		{"code": "simultaneously{" + TWO_ATTACKS + "\nright.attack(0)}", "reason": "只接受直接动作"},
		{"code": "simultaneously{left.attack(0)\nright.attack(0)", "reason": "缺少右花括号"},
	]
	for sample: Dictionary in samples:
		var rejected := _parse("main(){\n" + sample.code + "\n}")
		_check(not rejected.is_ok() and rejected.errors[0].contains(sample.reason) and rejected.errors[0].contains("第 "), "并行语法准确拒绝：" + sample.reason + "；实际：" + "; ".join(rejected.errors))
	var tick := _parse("main(){}\ntick(){" + TWO_ATTACKS + "}")
	_check(not tick.is_ok() and tick.errors[0].contains("tick() 不能包含"), "tick 回调不能使用需要等待的并行块")
	_check(not ProgramParser.parse("main(){" + TWO_ATTACKS + "}", _calls, false, false, false, false, true).is_ok(), "单独开放并行不会绕过命名权限")
	var nonfinite := _parse("main(){simultaneously{attack(" + "9".repeat(400) + ")\nmove(0,1)}}")
	_check(not nonfinite.is_ok() and nonfinite.errors[0].contains("有限"), "并行子调用也拒绝溢出数字字面量")
	var max_depth := "main(){" + "loop{\n".repeat(ProgramParser.MAX_CONTROL_DEPTH - 1) + TWO_ATTACKS + "\n" + "}\n".repeat(ProgramParser.MAX_CONTROL_DEPTH - 1) + "}"
	_check(_parse(max_depth).is_ok(), "并行块和外层控制结构共享允许的 16 层深度")
	_check(not _parse(max_depth.replace("main(){", "main(){loop{\n").trim_suffix("}") + "}\n}").is_ok(), "额外包一层不能越过并行深度上限")
	var budget := "main(){simultaneously{\n" + "attack(0)\n".repeat(ProgramParser.MAX_CALLS) + "}}"
	_check(_parse(budget).is_ok(), "并行调用仍允许 512 条解析预算，不因块结构提前减少")
	_check(not _parse(budget.trim_suffix("}}") + "attack(0)\n}}").is_ok(), "第 513 条调用不能利用并行绕过预算")


## 后置并行错误必须阻止前方动作，验证预检不修改位置、冷却或队列。
func _test_preflight() -> void:
	var samples: Array[String] = [
		"left.attack(0)\nleft.attack(180)",
		"attack(0)\nright.attack(180)",
		"drive.move(0,.1)\ndrive2.move(90,.1)",
		"left.attack(0)\nmissing.attack(0)",
		"left.attack(0)\nright.move(0,1)",
		"left.attack(0)\ndrive.move(0,-1)",
	]
	for sample in samples:
		var world := _world()
		var runner := _runner("main(){\ndrive.move(0,1)\nsimultaneously{\n" + sample + "\n}\n}", world)
		_check(not runner.start().is_ok() and runner.message.contains("第 "), "未来并行块的冲突、错误名称或数字先于首动作拒绝")
		_check(world.tick_index == 0 and world.player.position == Vector2(5, 5), "失败预检不推进世界或移动玩家")
		world.step()
		_check(world.player.position == Vector2(5, 5) and world.attack_traces.is_empty() and world.projectiles.is_empty(), "预检失败之后外部 step 也没有残余已提交动作")
		_check(world.player.get_module("left").next_attack_tick == 0 and world.player.get_module("gun").next_shoot_tick == 0, "预检不消耗任何攻击或射击冷却")
	var unreachable := _runner("main(){loop{move(0,0)}\nsimultaneously{left.attack(0)\nleft.attack(90)}}", _world())
	_check(not unreachable.start().is_ok(), "无限循环之后不可达的并行资源冲突也要预检")
	var branch := _runner("main(){if(gun.ready()){left.attack(0)}else{simultaneously{right.attack(0)\nright.attack(90)}}}", _world())
	_check(not branch.start().is_ok(), "首次不执行的 else 内并行冲突也不能绕过整树预检")


## 工具手工构造 AST 仍经过结构、数字和预算校验，不能注入未知节点或递归环。
func _test_public_ast() -> void:
	for mode in ["null", "empty", "single", "nested", "nan", "tick", "cycle", "budget"]:
		var ast: ProgramAst.ProgramNode = _parse("main(){" + TWO_ATTACKS + "}").value
		var node := ast.main.body.statements[0] as ProgramAst.SimultaneousNode
		match mode:
			"null": node.body = null
			"empty": node.body.statements.clear()
			"single": node.body.statements.pop_back()
			"nested": node.body.statements[0] = ProgramAst.LoopNode.new()
			"nan": (node.body.statements[0] as ProgramAst.CallNode).arguments[0].value = NAN
			"tick":
				ast.tick = ProgramAst.FunctionNode.new()
				ast.tick.name = "tick"
				ast.tick.body = ast.main.body
				ast.main.body = ProgramAst.BlockNode.new()
			"cycle":
				ast.main.body.statements.append(node.body.statements[0])
				node.body = ast.main.body
			"budget":
				for unused in ProgramParser.MAX_CALLS:
					node.body.statements.append(node.body.statements[0])
		var runner := ProgramRunner.create(ast, _world())
		_check(not runner.start().is_ok() and runner.state == ProgramRunner.State.FAILED, "公开 AST 非法并行结构被有界拒绝：" + mode)
		if mode == "cycle":
			node.body = null


## 两个短动作同一 tick 生效，后续语句不能抢先提交或多消耗空白 tick。
func _test_same_tick() -> void:
	var world := _world()
	var runner := _runner("main(){\n" + TWO_ATTACKS + "\ndrive.move(90,.1)\n}", world)
	_lines.clear()
	runner.line_changed.connect(_on_line)
	_check(runner.start().is_ok() and world.tick_index == 0 and world.attack_traces.is_empty(), "并行启动只排队，不立即攻击或推进时间")
	_check(_lines == [2] and runner.current_line == 2, "并行执行统一高亮块入口，不顺序派发子调用")
	runner.step()
	_check(world.tick_index == 1 and world.attack_traces.size() == 2, "同一个世界 tick 包含两个独立模块的近战")
	if world.attack_traces.size() == 2:
		_check(world.attack_traces[0].to.x < world.attack_traces[0].from.x and world.attack_traces[1].to.x > world.attack_traces[1].from.x, "两个攻击各自保留左右方向")
	_check(world.player.position == Vector2(5, 5) and _lines == [2], "并行结束这一 tick 不提前执行后方移动")
	runner.step()
	_check(world.tick_index == 2 and world.player.position.is_equal_approx(Vector2(5, 4.9)) and runner.state == ProgramRunner.State.COMPLETED, "下一次 step 执行后方动作，块边界没有额外等待 tick")
	_check(_lines == [2, 6], "后续动作保持其真实源码行高亮")
	var reverse := _world()
	var reverse_runner := _runner("main(){simultaneously{right.attack(0)\nleft.attack(180)}}", reverse)
	reverse_runner.start()
	reverse_runner.step()
	_check(reverse.tick_index == 1 and reverse.attack_traces.size() == 2 and reverse_runner.state == ProgramRunner.State.COMPLETED, "交换子动作顺序仍在同一 tick 完成")


## 长移动与短攻击同时开始，等待最长动作，短动作不被每帧重复执行。
func _test_wait_all() -> void:
	var world := _world()
	var runner := _runner("main(){simultaneously{drive.move(0,.3)\nleft.attack(180)}\nright.attack(0)}", world)
	runner.start()
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.1, 5)) and world.attack_traces.size() == 1 and runner.state == ProgramRunner.State.RUNNING, "第一 tick 同时移动和攻击，短攻击结束不让整个块提前结束")
	var first_cooldown := world.player.get_module("left").next_attack_tick
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.2, 5)) and world.attack_traces.is_empty() and world.player.get_module("left").next_attack_tick == first_cooldown, "第二 tick 只推进未完成移动，不重放已完成攻击")
	runner.step()
	_check(world.player.position.is_equal_approx(Vector2(5.3, 5)) and world.player.get_module("right").next_attack_tick == 0, "第三 tick 等待长移动完成，后方攻击仍未开始")
	runner.step()
	_check(world.tick_index == 4 and world.attack_traces.size() == 1 and runner.state == ProgramRunner.State.COMPLETED, "等全部子动作完成后下一 tick 才执行右攻击")
	var blocked_world := _world()
	var blocked := _runner("main(){\nsimultaneously{drive.move(180,10)\nright.attack(0)}\nleft.attack(0)\n}", blocked_world)
	blocked.start()
	for unused in 100:
		blocked.step()
	_check(blocked.state == ProgramRunner.State.FAILED and blocked.message.contains("第 2 行") and blocked_world.player.get_module("left").next_attack_tick == 0, "组内移动遇到 void 即失败并指向并行块，不执行后续动作")


## 并行可作为外层循环或条件中的完整动作，结构转换仍不增加模拟时间。
func _test_control_flow() -> void:
	var world := _world()
	var runner := _runner("main(){loop{simultaneously{drive.move(0,0)\nleft.attack(180)}}}", world)
	runner.start()
	for unused in 20:
		runner.step()
	_check(world.tick_index == 20 and world.player.position == Vector2(5, 5) and runner.state == ProgramRunner.State.RUNNING, "零距离并行循环每次 step 恰好一个 tick，不空转或积累新任务")
	runner.cancel()
	var conditional_world := _world()
	var conditional := _runner("main(){if(gun.ready()){simultaneously{left.attack(180)\nright.attack(0)}}else{move(0,0)}}", conditional_world)
	conditional.start()
	conditional.step()
	_check(conditional_world.tick_index == 1 and conditional_world.attack_traces.size() == 2 and conditional.state == ProgramRunner.State.COMPLETED, "条件分支内的并行块按一个动作同 tick 执行")


## 旧 tick 回调可继续共存，但同一个模块的真实冷却必须防止重复生效。
func _test_tick_coexistence() -> void:
	var world := _world()
	var runner := _runner("main(){simultaneously{drive.move(0,.2)\ngun.shoot(0)}}\ntick(){gun.shoot(180)}", world)
	runner.start()
	runner.step()
	_check(world.tick_index == 1 and world.projectiles.size() == 1 and world.projectiles[0].direction == Vector2.RIGHT, "main 并行与回调共享射击冷却，首个 main 方向优先且只发一颗")
	runner.step()
	_check(world.tick_index == 2 and world.projectiles.size() == 1 and world.player.get_module("gun").next_shoot_tick == 11, "后续 tick 回调不能绕过并行射击的十 tick 冷却")
	runner.cancel()


## 行号与世界通知可同步取消或请求重入，整组取消且单步时间上限始终成立。
func _test_cancellation_and_reentry() -> void:
	var source := "main(){simultaneously{drive.move(0,1)\nleft.attack(180)}\nright.attack(0)}"
	for after_steps in [0, 1]:
		var world := _world()
		var runner := _runner(source, world)
		runner.start()
		for unused in after_steps:
			runner.step()
		var position := world.player.position
		runner.cancel()
		runner.step()
		world.step()
		_check(runner.state == ProgramRunner.State.CANCELLED and world.player.position == position and world.attack_traces.is_empty(), "取消排队或运行的组清除所有尚未完成动作")
		_check(world.player.get_module("right").next_attack_tick == 0, "取消并行后不会执行后方语句")
	var line_world := _world()
	_callback_runner = _runner(source, line_world)
	_finished_count = 0
	_callback_runner.finished.connect(_on_finished)
	_callback_runner.line_changed.connect(_cancel_at_line)
	_callback_runner.start()
	line_world.step()
	_check(_callback_runner.state == ProgramRunner.State.CANCELLED and _finished_count == 1 and line_world.player.position == Vector2(5, 5) and line_world.attack_traces.is_empty(), "并行入口高亮取消早于原子提交，没有任何残余子动作")
	_callback_runner.line_changed.disconnect(_cancel_at_line)
	var reentry_world := _world()
	_callback_runner = _runner("main(){loop{simultaneously{drive.move(0,0)\nleft.attack(180)}}}", reentry_world)
	_callback_runner.line_changed.connect(_step_at_line)
	reentry_world.tick_completed.connect(_step_at_tick)
	_callback_runner.start()
	_check(reentry_world.tick_index == 0, "入口行号回调重入 step 不能提前推进时间")
	for unused in 20:
		_callback_runner.step()
	_check(reentry_world.tick_index == 20 and _callback_runner.state == ProgramRunner.State.RUNNING, "并行循环高亮与世界通知重入也每次只推进一个 tick")
	_callback_runner.cancel()
	_callback_runner.line_changed.disconnect(_step_at_line)
	reentry_world.tick_completed.disconnect(_step_at_tick)
	var tick_world := _world()
	_callback_runner = _runner(source, tick_world)
	tick_world.tick_completed.connect(_cancel_at_tick)
	_callback_runner.start()
	_callback_runner.step()
	_check(tick_world.tick_index == 1 and _callback_runner.state == ProgramRunner.State.CANCELLED, "世界提交通知中取消不会重新访问已清空的并行句柄")
	tick_world.tick_completed.disconnect(_cancel_at_tick)
	var stopped_position := tick_world.player.position
	tick_world.step()
	_check(tick_world.player.position == stopped_position, "世界通知取消也清除下一 tick 的长移动")
	_callback_runner = null


## 建立宽阔地板与可区分的命名模块，世界能力和资源冲突均使用生产实现。
func _world() -> SimulationWorld:
	var document := MapDocument.new()
	document.width = 12
	document.height = 10
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5, "y": 5}, "modules": [
		{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}},
		{"id": "drive2", "module_id": "movement", "offset": {"x": 0, "y": -0.5}},
		{"id": "left", "module_id": "melee", "offset": {"x": -0.5, "y": 0}},
		{"id": "right", "module_id": "melee", "offset": {"x": 0.5, "y": 0}},
		{"id": "gun", "module_id": "shooting", "offset": {"x": 0, "y": 0.5}},
	]}
	var created := SimulationWorld.create(document, _content)
	_check(created.is_ok(), "并行语言夹具创建真实五模块世界")
	return created.value as SimulationWorld


## 测试显式开启新语法权限，生产旧关默认参数仍保持关闭。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true)


## 编译有效测试源码后创建独立运行器，意外解析失败作为明确回归失败。
func _runner(source: String, world: SimulationWorld) -> ProgramRunner:
	var parsed := _parse(source)
	_check(parsed.is_ok(), "并行执行夹具源码可静态编译")
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, world)


## 记录真实入口高亮顺序，不使用运行器私有帧判断动作完成。
func _on_line(line: int) -> void:
	_lines.append(line)


## 累计完成事件以防同步取消造成重复终态通知。
func _on_finished(_success: bool, _message: String) -> void:
	_finished_count += 1


## 模拟用户在入口高亮时停止整份程序。
func _cancel_at_line(_line: int) -> void:
	_callback_runner.cancel()


## 模拟界面在世界更新通知中停止运行。
func _cancel_at_tick(_tick: int) -> void:
	_callback_runner.cancel()


## 模拟行号订阅者错误请求递归推进，运行器应自行隔离。
func _step_at_line(_line: int) -> void:
	_callback_runner.step()


## 模拟世界订阅者错误请求递归推进，不能在一帧中执行两次。
func _step_at_tick(_tick: int) -> void:
	_callback_runner.step()


## 累加结果并报告可定位的失败说明，调用方可在夹具失败时提前结束。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
