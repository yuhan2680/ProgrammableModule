class_name ProgramRunner
extends RefCounted
## main 顺序等待动作或并行组，雷达事件每逻辑帧刷新全局，tick 随后提交有限攻击回调。
## 世界仍由 step 单独推进，回调不递归调用执行器，也不直接改变模拟时间。

signal line_changed(line: int)
signal finished(success: bool, message: String)

enum State { READY, RUNNING, COMPLETED, FAILED, CANCELLED }

# 随机整数端点保持在精确整数及引擎支持的有符号 32 位范围内。
const RANDOM_INT_MIN: int = -2147483648
const RANDOM_INT_MAX: int = 2147483647
const MAX_FOR_ITERATIONS: int = 4096
const MAX_NON_ACTION_STEPS: int = 4096
const MAX_EXECUTION_FRAMES: int = (ProgramParser.MAX_CONTROL_DEPTH + 1) * (ProgramFunctionValidation.MAX_FUNCTION_DEPTH + 1)


class ExecutionFrame extends RefCounted:
	## 帧只记录代码块与当前索引；循环回到索引零，不复制 AST 或积累历史迭代。
	var block: ProgramAst.BlockNode
	var index: int = 0
	var repeats: bool = false
	var scope: ProgramBindingScope
	var for_node: ProgramAst.ForNode
	var for_values := PackedFloat64Array()
	var for_index: int = 0


var state: State = State.READY
var current_line: int = 0
var message: String = "程序尚未开始。"
var world: SimulationWorld
var program: ProgramAst.ProgramNode

var _frames: Array[ExecutionFrame] = []
var _functions: Dictionary = {}
var _globals: ProgramBindingScope
var _scope: ProgramBindingScope
var _command: SimulationCommand
var _command_node: ProgramAst.StatementNode
var _finished_emitted: bool = false
var _dispatching: bool = false
var _stepping: bool = false
var _random := RandomNumberGenerator.new()
var _random_seed_valid: bool = true


## 为一个已编译程序和独立世界创建运行器；调用方负责为重试创建新实例。
static func create(parsed_program: ProgramAst.ProgramNode, simulation: SimulationWorld, random_seed: Variant = null) -> ProgramRunner:
	var runner := ProgramRunner.new()
	runner.program = parsed_program
	runner.world = simulation
	# 测试可注入整数种子；正式运行每次独立播种，不读取或改变全局/敌人的随机序列。
	runner._random_seed_valid = random_seed == null or typeof(random_seed) == TYPE_INT
	if typeof(random_seed) == TYPE_INT:
		runner._random.seed = random_seed
	else:
		runner._random.randomize()
	return runner


## 先检查整棵树，再提交 main 首条指令；此方法本身绝不推进世界 tick。
func start() -> DataResult:
	if state != State.READY:
		return DataResult.failure("程序已经开始或结束；重新运行需要新的世界与运行器。")
	var checked := _validate_program()
	if not checked.is_ok():
		_finish(State.FAILED, checked.errors[0])
		return checked
	_globals = ProgramBindingScope.create()
	_scope = _globals
	state = State.RUNNING
	message = "程序执行中。"
	_dispatching = true
	for declaration: ProgramAst.DeclarationNode in program.globals:
		var initialized := _execute_binding(declaration)
		if not initialized.is_ok():
			return _fail_dispatch(initialized.errors[0])
	var refreshed := _refresh_radar_events()
	if not refreshed.is_ok():
		return _fail_dispatch(refreshed.errors[0])
	_dispatching = false
	var main_frame := ExecutionFrame.new()
	main_frame.block = program.main.body
	main_frame.scope = ProgramBindingScope.create(_globals)
	_frames.append(main_frame)
	_maybe_complete()
	if state != State.RUNNING:
		return DataResult.success(self)
	return _dispatch_current()


## 推进至多一个固定逻辑 tick；同步行号和世界事件都不能重入推进时间。
func step() -> void:
	if state != State.RUNNING or _dispatching or _stepping:
		return
	_stepping = true
	_step_once()
	_stepping = false


## 同一逻辑帧先提交 main 与 tick 输入，再且仅再推进一次世界。
func _step_once() -> void:
	# 外部取消不属于新的逻辑帧；先消费终态，避免停止后还刷新事件绑定。
	if _command != null and _command.is_finished():
		_consume_finished_command()
		return
	# main 即使仍在等待移动，也要在本帧 main / tick 读取绑定之前刷新一次。
	var refreshed := _refresh_radar_events()
	if not refreshed.is_ok():
		_fail_tick(refreshed.errors[0])
		return
	if _command == null:
		# 维持旧顺序边界：前一个动作完成后，下一条只能在下次 step 派发。
		var dispatched := _dispatch_current()
		if not dispatched.is_ok() or state != State.RUNNING:
			return
	# 外部取消动作时沿用旧语义：消费终态，不执行回调或多推进一次时间。
	if _command != null and _command.is_finished():
		_consume_finished_command()
		return
	if not _dispatch_tick().is_ok():
		return
	world.step()
	# 订阅者可能在世界通知中取消程序；取消后不得读取旧句柄或继续下一条。
	if state != State.RUNNING:
		return
	if _command != null and _command.is_finished():
		_consume_finished_command()
	_maybe_complete()


## 消费已结束的 main 动作；只记录下一条索引，不在结束回调中连锁执行。
func _consume_finished_command() -> void:
	match _command.state:
		SimulationCommand.State.COMPLETED:
			_frames.back().index += 1
			_command = null
			_command_node = null
			_maybe_complete()
		SimulationCommand.State.CANCELLED:
			_finish(State.CANCELLED, _call_error("动作已被取消，程序停止。"))
		_:
			# 阻挡与拒绝都是失败，不能越过失败语句继续后续路线。
			_finish(State.FAILED, _call_error(_command.message))


## main 结束后保留 tick 与雷达事件；单次射击等待玩家弹丸落地，避免飞行被冻结。
func _maybe_complete() -> void:
	if state != State.RUNNING:
		return
	_normalize_frames()
	if not _frames.is_empty():
		return
	if program.tick != null or not program.radar_events.is_empty() or world.has_pending_projectiles(world.player.id):
		return
	_finish(State.COMPLETED, "程序执行完毕。")


## 取消玩家主动作与本帧已排队回调，不推进时间，也不影响其它机器。
func cancel() -> void:
	if state in [State.COMPLETED, State.FAILED, State.CANCELLED]:
		return
	if state == State.RUNNING and world != null and world.player != null:
		# 即使 main 已结束，tick 仍可能在行号回调之前排入了射击请求。
		world.cancel_command(world.player.id)
	_command = null
	_command_node = null
	_frames.clear()
	_finish(State.CANCELLED, "程序已取消。")


## 对公开 AST 边界整树预检，后面的非法调用也不能让前面的动作抢先执行。
func _validate_program() -> DataResult:
	if not _random_seed_valid:
		return DataResult.failure("第 1 行，第 1 列：运行器的测试随机种子必须为整数。")
	if world == null or world.player == null:
		return DataResult.failure("第 1 行，第 1 列：程序运行需要包含玩家的模拟世界。")
	if program == null or program.main == null or program.main.body == null or program.main.name != "main":
		return DataResult.failure("第 1 行，第 1 列：程序缺少有效的 main 入口。")
	if program.tick != null and (program.tick.body == null or program.tick.name != "tick"):
		return DataResult.failure("第 1 行，第 1 列：程序包含无效的 tick 回调。")
	var functions_checked := ProgramFunctionValidation.validate(program)
	if not functions_checked.is_ok():
		return functions_checked
	_functions = functions_checked.value
	var variables_checked := ProgramVariableValidation.validate(program)
	if not variables_checked.is_ok():
		return variables_checked
	# 公共 AST 可能被工具手工构造：共享预算限制所有路径，活动块集合拒绝循环引用。
	var budget := {"calls": 0, "statements": 0, "expressions": 0}
	var active_blocks := {}
	var events_checked := _validate_radar_events(budget)
	if not events_checked.is_ok():
		return events_checked
	for declaration: ProgramAst.DeclarationNode in program.globals:
		budget.statements += 1
		if budget.statements > ProgramParser.MAX_STATEMENTS:
			return DataResult.failure(_node_error(declaration, "程序超过语句节点数量限制。"))
		var global_checked := _expression_data(declaration.initializer, true, 0, {}, budget)
		if not global_checked.is_ok():
			current_line = declaration.line
			return global_checked
	var main_checked := _validate_block(program.main.body, false, 0, active_blocks, budget)
	if not main_checked.is_ok():
		return main_checked
	if program.tick != null:
		var tick_checked := _validate_block(program.tick.body, true, 0, active_blocks, budget)
		if not tick_checked.is_ok():
			return tick_checked
	for function: ProgramAst.FunctionNode in program.functions:
		var function_checked := _validate_block(function.body, false, 0, active_blocks, budget)
		if not function_checked.is_ok():
			return function_checked
	current_line = 0
	return DataResult.success()


## 事件结构与全局写权限已由名称校验检查；世界能力仍须在任何初始化或动作前预检。
func _validate_radar_events(budget: Dictionary) -> DataResult:
	for event: ProgramAst.RadarEventNode in program.radar_events:
		current_line = event.line
		budget.statements += 1
		if budget.statements > ProgramParser.MAX_STATEMENTS:
			return DataResult.failure(_node_error(event, "程序超过语句节点数量限制。"))
		var checked := world.validate_radar_source(world.player.id, event.receiver)
		if not checked.is_ok():
			return DataResult.failure(_node_error(event, "onDetected 雷达来源校验失败：" + "; ".join(checked.errors)))
	return DataResult.success()


## 固定帧开始只读扫描，始终复制到指定全局；无目标写 null，局部遮蔽和旧快照不受影响。
func _refresh_radar_events() -> DataResult:
	for event: ProgramAst.RadarEventNode in program.radar_events:
		var queried := world.query_scan(world.player.id, event.receiver)
		if not queried.is_ok():
			current_line = event.line
			return DataResult.failure(_node_error(event, "onDetected 雷达查询失败：" + "; ".join(queried.errors)))
		if _value_kind(queried.value) not in ["target", "null"]:
			current_line = event.line
			return DataResult.failure(_node_error(event, "onDetected 必须收到有效的雷达目标快照或 null。"))
		var binding := _globals.resolve(event.binding_name)
		if binding.is_empty() or not binding.mutable:
			current_line = event.line
			return DataResult.failure(_node_error(event, "onDetected 必须更新已声明的全局 variable。"))
		binding.value = queried.value.duplicate(true) if queried.value is Dictionary else null
	return DataResult.success()


## 有界检查整棵语句树；即使语句在无限循环之后不可达，也必须先通过静态与能力校验。
func _validate_block(block: ProgramAst.BlockNode, is_tick: bool, depth: int, active: Dictionary, budget: Dictionary) -> DataResult:
	if active.has(block.get_instance_id()):
		return DataResult.failure(_node_error(block, "语法树存在循环引用，无法执行。"))
	active[block.get_instance_id()] = true
	for statement: ProgramAst.StatementNode in block.statements:
		if statement == null:
			return DataResult.failure(_node_error(block, "程序包含空语句节点。"))
		current_line = statement.line
		budget.statements += 1
		if budget.statements > ProgramParser.MAX_STATEMENTS:
			return DataResult.failure(_node_error(statement, "程序超过语句节点数量限制。"))
		if statement is ProgramAst.ForNode:
			var loop := statement as ProgramAst.ForNode
			if is_tick:
				return DataResult.failure(_node_error(loop, "tick() 不能包含需要等待完成的 for 循环。"))
			if depth >= ProgramParser.MAX_CONTROL_DEPTH:
				return DataResult.failure(_node_error(loop, "控制结构嵌套最多允许 %d 层。" % ProgramParser.MAX_CONTROL_DEPTH))
			if loop.body == null or loop.body.statements.is_empty():
				return DataResult.failure(_node_error(loop, "for 代码块不能为空；请至少添加一条语句。"))
			var range_checked := _for_values(loop, true, budget)
			if not range_checked.is_ok():
				return range_checked
			var nested := _validate_block(loop.body, false, depth + 1, active, budget)
			if not nested.is_ok():
				return nested
		elif statement is ProgramAst.LoopNode:
			var loop := statement as ProgramAst.LoopNode
			if is_tick:
				return DataResult.failure(_node_error(loop, "tick() 必须在每帧有限结束，不能包含 loop 循环。"))
			if depth >= ProgramParser.MAX_CONTROL_DEPTH:
				return DataResult.failure(_node_error(loop, "loop 嵌套最多允许 %d 层。" % ProgramParser.MAX_LOOP_DEPTH))
			if loop.body == null or loop.body.statements.is_empty():
				return DataResult.failure(_node_error(loop, "loop 代码块不能为空；请至少添加一条动作指令。"))
			var nested := _validate_block(loop.body, false, depth + 1, active, budget)
			if not nested.is_ok():
				return nested
		elif statement is ProgramAst.IfNode:
			var branch := statement as ProgramAst.IfNode
			if depth >= ProgramParser.MAX_CONTROL_DEPTH:
				return DataResult.failure(_node_error(branch, "loop / if 控制结构嵌套最多允许 %d 层。" % ProgramParser.MAX_CONTROL_DEPTH))
			var condition_checked := _validate_condition(branch.condition, branch, budget)
			if not condition_checked.is_ok():
				return condition_checked
			if branch.then_body == null or branch.else_body == null or branch.then_body.statements.is_empty():
				return DataResult.failure(_node_error(branch, "if 代码块不能为空，else 分支必须是有效代码块；省略 else 时允许空分支。"))
			# 不按当前冷却值跳过分支：隐藏在另一条路径里的非法动作也不能部分执行。
			for body: ProgramAst.BlockNode in [branch.then_body, branch.else_body]:
				var nested := _validate_block(body, is_tick, depth + 1, active, budget)
				if not nested.is_ok():
					return nested
		elif statement is ProgramAst.SimultaneousNode:
			var checked := _validate_simultaneous(statement as ProgramAst.SimultaneousNode, is_tick, depth, active, budget)
			if not checked.is_ok():
				return checked
		elif statement is ProgramAst.DeclarationNode or statement is ProgramAst.AssignmentNode:
			if is_tick:
				return DataResult.failure(_node_error(statement, "tick() 和 simultaneously 块内不能声明或修改变量。"))
			var expression: ProgramAst.ExpressionNode = (statement as ProgramAst.DeclarationNode).initializer if statement is ProgramAst.DeclarationNode else (statement as ProgramAst.AssignmentNode).expression
			var checked := _expression_data(expression,true,0,{},budget)
			if not checked.is_ok():
				return checked
		elif statement is ProgramAst.UserCallNode:
			budget.calls += 1
			if budget.calls > ProgramParser.MAX_CALLS:
				return DataResult.failure(_node_error(statement, "程序超过调用数量限制。"))
			var call := statement as ProgramAst.UserCallNode
			if is_tick or not _functions.has(call.callee):
				return DataResult.failure(_node_error(call, "用户函数调用无效，或不允许在 tick() 中调用。"))
		elif statement is ProgramAst.CallNode:
			budget.calls += 1
			if budget.calls > ProgramParser.MAX_CALLS:
				return DataResult.failure(_node_error(statement, "程序超过调用数量限制。"))
			var checked := _validate_call(statement as ProgramAst.CallNode, is_tick, budget)
			if not checked.is_ok():
				return checked
		else:
			return DataResult.failure(_node_error(statement, "程序包含未知的语句节点。"))
	active.erase(block.get_instance_id())
	return DataResult.success()


## 整树预检时核对并行子动作及资源占用，后置错误也不能让前置动作部分执行。
func _validate_simultaneous(node: ProgramAst.SimultaneousNode, is_tick: bool, depth: int, active: Dictionary, budget: Dictionary) -> DataResult:
	if is_tick:
		return DataResult.failure(_node_error(node, "tick() 不能包含需要等待完成的 simultaneously 并行块。"))
	if depth >= ProgramParser.MAX_CONTROL_DEPTH:
		return DataResult.failure(_node_error(node, "控制结构嵌套最多允许 %d 层。" % ProgramParser.MAX_CONTROL_DEPTH))
	if node.body == null or node.body.statements.size() < 2:
		return DataResult.failure(_node_error(node, "simultaneously 代码块至少需要两条动作指令。"))
	if active.has(node.body.get_instance_id()):
		return DataResult.failure(_node_error(node, "语法树存在循环引用，无法执行。"))
	for child: ProgramAst.StatementNode in node.body.statements:
		if not child is ProgramAst.CallNode:
			return DataResult.failure(_node_error(node, "simultaneously 内只接受直接动作，不能包含 loop、for、if 或嵌套并行块。"))
	# 复用有界节点与参数校验，不直接把公开 AST 中的任意值传入世界。
	var checked := _validate_block(node.body, false, depth + 1, active, budget)
	if not checked.is_ok():
		return checked
	current_line = node.line
	var actions := _simultaneous_actions(node, true)
	if not actions.is_ok():
		return actions
	var validated := world.validate_simultaneous(world.player.id, actions.value)
	if not validated.is_ok():
		return DataResult.failure(_node_error(node, "simultaneously 并行块无效：" + "; ".join(validated.errors)))
	return DataResult.success()


## for 边界仅在进入时读取一次；预检只检查已知值，绝不执行随机采样或世界查询。
func _for_values(node: ProgramAst.ForNode, preflight: bool, budget: Dictionary) -> DataResult:
	var values: Array[float] = []
	var all_known := true
	for expression: ProgramAst.ExpressionNode in [node.start, node.end, node.step]:
		var result := _expression_data(expression, preflight, 0, {}, budget)
		if not result.is_ok():
			return result
		var numeric := _numeric_data(result.value, expression, preflight)
		if not numeric.is_ok():
			return numeric
		values.append(numeric.value)
		var known: bool = not preflight or result.value.constant
		all_known = all_known and known
		if values.size() == 3 and known and values[2] == 0.0:
			return DataResult.failure(_node_error(expression, "for 的 step 步长不能为 0。"))
	if preflight and not all_known:
		return DataResult.success(PackedFloat64Array())
	var first := values[0]
	var last := values[1]
	var increment := values[2]
	if (first < last and increment < 0.0) or (first > last and increment > 0.0):
		return DataResult.failure(_node_error(node.step, "for 的 step 方向必须朝向区间终点。"))
	var quotient := (last - first) / increment
	if not is_finite(quotient):
		return DataResult.failure(_node_error(node, "for 区间计算超出有限数值范围。"))
	# 直接从起点计算各次值，避免累计误差；浮点小数的近整数商按包含终点处理。
	var nearest := roundf(quotient)
	var exact_end := (nearest >= 1.0 or first == last) and absf(quotient - nearest) <= 0.000000000000008 * maxf(1.0, absf(quotient))
	var count_value := (nearest if exact_end else floorf(quotient)) + 1.0
	if count_value < 1.0 or count_value > MAX_FOR_ITERATIONS:
		return DataResult.failure(_node_error(node, "for 每次进入最多允许 %d 次迭代。" % MAX_FOR_ITERATIONS))
	var count := int(count_value)
	var iterations := PackedFloat64Array()
	for index in count:
		var value := last if exact_end and index == count - 1 else first + increment * float(index)
		if not is_finite(value) or (index > 0 and ((increment > 0.0 and value <= iterations[index - 1]) or (increment < 0.0 and value >= iterations[index - 1]))):
			return DataResult.failure(_node_error(node.step, "for 步长过小或数值范围过大，无法可靠推进迭代。"))
		iterations.append(value)
	return DataResult.success(iterations)


## 同一并行组的表达式全部先读取，成功后才把原子动作集合提交给世界。
func _simultaneous_actions(node: ProgramAst.SimultaneousNode, preflight: bool = false) -> DataResult:
	var actions: Array[Dictionary] = []
	for statement: ProgramAst.StatementNode in node.body.statements:
		var call := statement as ProgramAst.CallNode
		var evaluated := _argument_values(call, preflight, {"expressions": 0})
		if not evaluated.is_ok():
			return evaluated
		actions.append({"callee": call.callee, "arguments": evaluated.value, "module_id": call.receiver, "line": call.line, "column": call.column})
	return DataResult.success(actions)


## 全分支预检只校验查询能力与常量，不用当前距离预测未来动作的动态结果。
func _validate_condition(condition: ProgramAst.ConditionNode, owner: ProgramAst.AstNode, budget: Dictionary) -> DataResult:
	if condition is ProgramAst.ComparisonNode:
		var comparison := condition as ProgramAst.ComparisonNode
		if comparison.operator not in ProgramParser.COMPARISONS:
			return DataResult.failure(_node_error(comparison, "条件包含无效的数值比较符。"))
		var left := _expression_data(comparison.left, true, 0, {}, budget)
		if not left.is_ok():
			return left
		var right := _expression_data(comparison.right, true, 0, {}, budget)
		if not right.is_ok():
			return right
		return _comparison_data(comparison, left.value, right.value, true)
	if not condition is ProgramAst.ReadyNode:
		return DataResult.failure(_node_error(owner, "程序包含无效条件；需要 ready() 或已解锁的数值比较。"))
	return _query_ready(condition as ProgramAst.ReadyNode)


## 冷却查询沿用精确具名语义，任何路径的错误都保留查询处的源码位置。
func _query_ready(ready: ProgramAst.ReadyNode) -> DataResult:
	if not ProgramParser.is_receiver_name(ready.receiver):
		return DataResult.failure(_node_error(ready, "ready() 需要有效的命名射击模块。"))
	var queried := world.is_shoot_ready(world.player.id, ready.receiver)
	if not queried.is_ok():
		return DataResult.failure(_node_error(ready, "ready 查询失败：" + "; ".join(queried.errors)))
	if not queried.value is bool:
		return DataResult.failure(_node_error(ready, "ready 查询必须返回布尔值。"))
	return queried


## 进入分支时重新读取世界；比较不会推进时间，也不会缓存上一次循环的距离。
func _evaluate_condition(branch: ProgramAst.IfNode) -> DataResult:
	current_line = branch.line
	line_changed.emit(current_line)
	if state != State.RUNNING:
		return DataResult.failure(message)
	if branch.condition is ProgramAst.ReadyNode:
		return _query_ready(branch.condition as ProgramAst.ReadyNode)
	if not branch.condition is ProgramAst.ComparisonNode:
		return DataResult.failure(_node_error(branch, "执行中发现无效的条件。"))
	var comparison := branch.condition as ProgramAst.ComparisonNode
	var budget := {"expressions": 0}
	var left := _expression_data(comparison.left, false, 0, {}, budget)
	if not left.is_ok():
		return left
	var right := _expression_data(comparison.right, false, 0, {}, budget)
	if not right.is_ok():
		return right
	return _comparison_data(comparison, left.value, right.value, false)


## 只有数字可排序，雷达快照仅与 null 比较；未知绑定类型延迟到实际求值检查。
func _comparison_data(node: ProgramAst.ComparisonNode, left: Dictionary, right: Dictionary, preflight: bool) -> DataResult:
	if preflight and (left.kind == "unknown" or right.kind == "unknown"):
		return DataResult.success(false)
	if left.kind == "null" or right.kind == "null":
		if node.operator not in ["==", "!="] or left.kind not in ["target", "null"] or right.kind not in ["target", "null"]:
			return DataResult.failure(_node_error(node, "雷达目标只能使用 == null 或 != null 判断是否存在。"))
		var equal: bool = left.value == null and right.value == null
		return DataResult.success(equal if node.operator == "==" else not equal)
	if left.kind != "number" or right.kind != "number":
		return DataResult.failure(_node_error(node, "比较需要有限数字，或使用雷达目标与 null 的存在判断。"))
	var a: float = left.value
	var b: float = right.value
	match node.operator:
		"<": return DataResult.success(a < b)
		"<=": return DataResult.success(a <= b)
		">": return DataResult.success(a > b)
		">=": return DataResult.success(a >= b)
		"==": return DataResult.success(a == b)
		"!=": return DataResult.success(a != b)
	return DataResult.failure(_node_error(node, "条件包含无效的数值比较符。"))


## 验证调用能力及全部表达式；只有纯常量的负距离在启动前拒绝。
func _validate_call(call: ProgramAst.CallNode, is_tick: bool, budget: Dictionary) -> DataResult:
	if not ProgramParser.CALL_ARITIES.has(call.callee) or call.arguments.size() != int(ProgramParser.CALL_ARITIES[call.callee]):
		return DataResult.failure(_node_error(call, "运行器只接受 move(角度, 距离)、attack(角度) 和 shoot(角度)。"))
	if is_tick and call.callee not in ["shoot", "attack"]:
		return DataResult.failure(_node_error(call, "tick() 只支持立即结束的 shoot(角度) 和 attack(角度)。"))
	var evaluated := _argument_values(call, true, budget)
	if not evaluated.is_ok():
		return evaluated
	if not call.receiver.is_empty():
		var selected := _validate_receiver(call)
		if not selected.is_ok():
			return selected
	if call.callee == "move" and world.player.get_move_speed() <= 0.0:
		return DataResult.failure(_node_error(call, "move 需要安装可用的移动模块。"))
	if call.callee == "attack" and not world.can_attack(world.player):
		return DataResult.failure(_node_error(call, "attack 需要安装可用的近战模块。"))
	if call.callee == "shoot" and not world.can_shoot(world.player):
		return DataResult.failure(_node_error(call, "shoot 需要安装可用的射击模块。"))
	return DataResult.success()


## 取出一次派发所需的全部数值；预检以零占位动态值，只用于能力和资源冲突验证。
func _argument_values(call: ProgramAst.CallNode, preflight: bool, budget: Dictionary) -> DataResult:
	var values: Array[float] = []
	for index in call.arguments.size():
		var result := _expression_data(call.arguments[index], preflight, 0, {}, budget)
		if not result.is_ok():
			return result
		var numeric := _numeric_data(result.value, call.arguments[index], preflight)
		if not numeric.is_ok():
			return numeric
		var value: float = numeric.value
		if call.callee == "move" and index == 1 and value < 0.0:
			return DataResult.failure(_node_error(call, "移动距离不能为负数；反向移动请修改角度。"))
		values.append(value)
	return DataResult.success(values)


## 有界读取显式表达式；预检不执行扫描，运行时只返回验证后的值与独立快照。
func _expression_data(expression: ProgramAst.ExpressionNode, preflight: bool, depth: int, active: Dictionary, budget: Dictionary) -> DataResult:
	if expression == null:
		return DataResult.failure("第 %d 行，第 1 列：指令参数必须是有限数字，不能包含空表达式。" % maxi(current_line, 1))
	budget.expressions = int(budget.get("expressions", 0)) + 1
	if depth >= ProgramParser.MAX_EXPRESSION_DEPTH or int(budget.expressions) > ProgramParser.MAX_EXPRESSION_NODES:
		return DataResult.failure(_node_error(expression, "数值表达式超过深度或节点数量限制。"))
	if active.has(expression.get_instance_id()):
		return DataResult.failure(_node_error(expression, "数值表达式存在循环引用，无法执行。"))
	active[expression.get_instance_id()] = true
	var constant := true
	var value: Variant = 0.0
	var kind := "number"
	if expression is ProgramAst.NameNode:
		var reference := expression as ProgramAst.NameNode
		constant = false
		kind = "unknown"
		if not preflight:
			var binding: Dictionary = _scope.resolve(reference.name) if _scope != null else {}
			if binding.is_empty():
				return DataResult.failure(_node_error(reference, "名称“%s”尚未声明或不在当前作用域中。" % reference.name))
			value = binding.value
			kind = _value_kind(value)
	elif expression is ProgramAst.NumberNode:
		value = (expression as ProgramAst.NumberNode).value
	elif expression is ProgramAst.NullNode:
		value = null
		kind = "null"
	elif expression is ProgramAst.RandomNode:
		var sampled := _random_data(expression as ProgramAst.RandomNode, preflight, depth, active, budget)
		if not sampled.is_ok():
			return sampled
		constant = false
		value = sampled.value
	elif expression is ProgramAst.ScanNode:
		var query := expression as ProgramAst.ScanNode
		if not query.receiver.is_empty() and not ProgramParser.is_receiver_name(query.receiver):
			return DataResult.failure(_node_error(query, "scan() 需要有效的雷达模块名称。"))
		var result: DataResult = world.validate_radar_source(world.player.id, query.receiver) if preflight else world.query_scan(world.player.id, query.receiver)
		if not result.is_ok():
			return DataResult.failure(_node_error(query, "scan 查询失败：" + "; ".join(result.errors)))
		constant = false
		kind = "target"
		value = null
		if not preflight:
			kind = _value_kind(result.value)
			if kind not in ["target", "null"]:
				return DataResult.failure(_node_error(query, "scan 查询必须返回有效的雷达目标快照或 null。"))
			value = result.value.duplicate(true) if result.value is Dictionary else null
	elif expression is ProgramAst.TargetMemberNode:
		var member := expression as ProgramAst.TargetMemberNode
		if member.member not in ["Angle", "Position", "Distance", "x", "y"]:
			return DataResult.failure(_node_error(member, "雷达目标仅支持 Angle()、Position、Distance 与坐标 x/y。"))
		var target := _expression_data(member.target, preflight, depth + 1, active, budget)
		if not target.is_ok():
			return target
		var expected := "vector" if member.member in ["x", "y"] else "target"
		if not (preflight and target.value.kind == "unknown") and target.value.kind != expected:
			var reason := "雷达未发现目标；请先使用 != null 判断，再读取目标属性。" if target.value.kind == "null" else "雷达属性类型不匹配；目标支持 Angle()、Position、Distance，坐标仅支持 x/y。"
			return DataResult.failure(_node_error(member, reason))
		constant = false
		kind = "vector" if member.member == "Position" else "number"
		value = Vector2.ZERO if kind == "vector" else 0.0
		if not preflight:
			match member.member:
				"Angle": value = target.value.value.angle
				"Position": value = target.value.value.position
				"Distance": value = target.value.value.distance
				"x": value = (target.value.value as Vector2).x
				"y": value = (target.value.value as Vector2).y
	elif expression is ProgramAst.BinaryNode:
		var binary := expression as ProgramAst.BinaryNode
		if binary.operator not in ["+", "-"]:
			return DataResult.failure(_node_error(binary, "数值表达式只支持加法和减法。"))
		var left := _expression_data(binary.left, preflight, depth + 1, active, budget)
		if not left.is_ok():
			return left
		var right := _expression_data(binary.right, preflight, depth + 1, active, budget)
		if not right.is_ok():
			return right
		for operand: Dictionary in [left.value, right.value]:
			var checked := _numeric_data(operand, binary, preflight)
			if not checked.is_ok():
				return checked
		constant = left.value.constant and right.value.constant
		if not preflight or constant:
			value = float(left.value.value) + float(right.value.value) if binary.operator == "+" else float(left.value.value) - float(right.value.value)
	elif expression is ProgramAst.DistanceNode:
		var query := expression as ProgramAst.DistanceNode
		if not query.receiver.is_empty() and not ProgramParser.is_receiver_name(query.receiver):
			return DataResult.failure(_node_error(query, "distance() 需要有效的测距模块名称。"))
		var angle := _expression_data(query.angle, preflight, depth + 1, active, budget)
		if not angle.is_ok():
			return angle
		var numeric := _numeric_data(angle.value, query.angle, preflight)
		if not numeric.is_ok():
			return numeric
		var result: DataResult = world.validate_distance_source(world.player.id, query.receiver) if preflight else world.query_distance(world.player.id, numeric.value, query.receiver)
		if not result.is_ok():
			return DataResult.failure(_node_error(query, "distance 查询失败：" + "; ".join(result.errors)))
		constant = false
		if not preflight:
			if typeof(result.value) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(result.value)) or float(result.value) < 0.0:
				return DataResult.failure(_node_error(query, "distance 查询必须返回有限非负数字。"))
			value = float(result.value)
	else:
		return DataResult.failure(_node_error(expression, "程序包含未知的数值表达式。"))
	if (not preflight or constant) and _value_kind(value) == "invalid":
		return DataResult.failure(_node_error(expression, "表达式必须返回有限数字、有效雷达快照、坐标或 null。"))
	active.erase(expression.get_instance_id())
	return DataResult.success({"constant": constant, "value": value, "kind": kind})


## 预检只遍历参数并检查静态边界；实际求值按从左至右顺序抽样，不消耗世界时间。
func _random_data(node: ProgramAst.RandomNode, preflight: bool, depth: int, active: Dictionary, budget: Dictionary) -> DataResult:
	if node.callee not in ["random", "randomInt"]:
		return DataResult.failure(_node_error(node, "未知随机函数；仅支持 random() 与 randomInt(a, b)。"))
	var arity := 0 if node.callee == "random" else 2
	if node.arguments.size() != arity:
		return DataResult.failure(_node_error(node, "%s 需要 %d 个参数。" % [node.callee, arity]))
	if node.callee == "random":
		# Godot randf 的闭区间是 [0, 1]；启动预检不能提前消耗一次序列。
		return DataResult.success(0.0 if preflight else _random.randf())
	var endpoints: Array[float] = []
	var all_known := true
	for argument: ProgramAst.ExpressionNode in node.arguments:
		var result := _expression_data(argument, preflight, depth + 1, active, budget)
		if not result.is_ok():
			return result
		var numeric := _numeric_data(result.value, argument, preflight)
		if not numeric.is_ok():
			return numeric
		var endpoint: float = numeric.value
		var known: bool = not preflight or result.value.constant
		all_known = all_known and known
		if known and (endpoint != floor(endpoint) or endpoint < RANDOM_INT_MIN or endpoint > RANDOM_INT_MAX):
			return DataResult.failure(_node_error(argument, "randomInt 的区间端点必须是 -2147483648 到 2147483647 之间的有限整数。"))
		endpoints.append(endpoint)
	if all_known and endpoints[0] > endpoints[1]:
		return DataResult.failure(_node_error(node.arguments[1], "randomInt 的上限 b 不能小于下限 a。"))
	if preflight:
		return DataResult.success(0.0)
	return DataResult.success(float(_random.randi_range(int(endpoints[0]), int(endpoints[1]))))


## 严格识别有限值及固定快照字段，拒绝任意对象、额外属性、字符串和非有限坐标。
static func _value_kind(value: Variant) -> String:
	if value == null:
		return "null"
	if typeof(value) in [TYPE_FLOAT, TYPE_INT]:
		return "number" if is_finite(float(value)) else "invalid"
	if value is Vector2:
		return "vector" if value.is_finite() else "invalid"
	if value is Dictionary:
		if value.size() != 4 or not value.has_all(["enemy_id", "position", "angle", "distance"]):
			return "invalid"
		if not value.enemy_id is String or value.enemy_id.is_empty() or not value.position is Vector2 or not value.position.is_finite():
			return "invalid"
		if typeof(value.angle) not in [TYPE_FLOAT, TYPE_INT] or typeof(value.distance) not in [TYPE_FLOAT, TYPE_INT]:
			return "invalid"
		if not is_finite(float(value.angle)) or not is_finite(float(value.distance)) or float(value.distance) < 0.0:
			return "invalid"
		return "target"
	return "invalid"


## 数字动作与加减从不隐式转换快照、坐标或 null；预检未知绑定暂以零占位。
static func _numeric_data(data: Dictionary, owner: ProgramAst.AstNode, preflight: bool) -> DataResult:
	if preflight and data.kind == "unknown":
		return DataResult.success(0.0)
	if data.kind != "number" or typeof(data.value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(data.value)):
		return DataResult.failure(_node_error(owner, "指令参数与加减运算必须使用有限数字，不能使用雷达目标、坐标或 null。"))
	return DataResult.success(float(data.value))


## 精确验证实例存在、可用及能力；错误保留源码位置，绝不改用其它同类模块。
func _validate_receiver(call: ProgramAst.CallNode) -> DataResult:
	if not ProgramParser.is_receiver_name(call.receiver):
		return DataResult.failure(_node_error(call, "模块名必须是非保留的英文标识符，最多 128 个字符。"))
	var module := world.player.get_module(call.receiver)
	if module == null:
		return DataResult.failure(_node_error(call, "找不到名为“%s”的模块；请检查组装页中的名称，大小写必须一致。" % call.receiver))
	if not module.available:
		return DataResult.failure(_node_error(call, "模块“%s”已不可用，无法执行 %s。" % [call.receiver, call.callee]))
	var capable := false
	match call.callee:
		"move":
			capable = module.get_move_speed() > 0.0
		"attack":
			capable = module.behavior != null and not module.behavior.get_attack_profile(module).is_empty()
		"shoot":
			capable = module.behavior != null and not module.behavior.get_shoot_profile(module).is_empty()
	if not capable:
		return DataResult.failure(_node_error(call, "模块“%s”不支持 %s；请调用具有对应能力的模块。" % [call.receiver, call.callee]))
	return DataResult.success()


## 将 main 当前调用转换为世界命令，在提交前通知界面高亮其源码行。
func _dispatch_current() -> DataResult:
	# 条件高亮也能发出同步信号；保护必须早于寻找动作，以免 if 查询阶段重入 start / step。
	_dispatching = true
	var selected := _next_action()
	if not selected.is_ok():
		if state == State.RUNNING:
			_finish(State.FAILED, selected.errors[0])
		_dispatching = false
		return selected
	var node := selected.value as ProgramAst.StatementNode
	if node == null:
		_maybe_complete()
		_dispatching = false
		return DataResult.success(self)
	_command_node = node
	current_line = node.line
	line_changed.emit(current_line)
	if state != State.RUNNING:
		_dispatching = false
		return DataResult.failure(message)
	var requested: DataResult
	var action_name := "simultaneously"
	if node is ProgramAst.SimultaneousNode:
		var actions := _simultaneous_actions(node as ProgramAst.SimultaneousNode)
		if not actions.is_ok():
			return _fail_dispatch(actions.errors[0])
		requested = world.request_simultaneous(world.player.id, actions.value)
	else:
		var call := node as ProgramAst.CallNode
		action_name = call.callee
		var arguments := _argument_values(call, false, {"expressions": 0})
		if not arguments.is_ok():
			return _fail_dispatch(arguments.errors[0])
		match call.callee:
			"attack":
				requested = world.request_attack(world.player.id, arguments.value[0], call.receiver)
			"shoot":
				requested = world.request_shoot(world.player.id, arguments.value[0], call.receiver)
			_:
				requested = world.request_move(world.player.id, arguments.value[0], arguments.value[1], call.receiver)
	if not requested.is_ok():
		var reason := _node_error(node, action_name + " 指令未接受：" + "; ".join(requested.errors))
		_finish(State.FAILED, reason)
		_dispatching = false
		return DataResult.failure(reason)
	_command = requested.value as SimulationCommand
	_dispatching = false
	return DataResult.success(self)


## 表达式派发失败直接保留查询或运算符的真实行列，不再套上外层动作位置。
func _fail_dispatch(reason: String) -> DataResult:
	_finish(State.FAILED, reason)
	_dispatching = false
	return DataResult.failure(reason)


## 跨越循环或条件结构寻找下一动作，不推进世界；栈与结构预算保护运行时边界。
func _next_action() -> DataResult:
	for unused in MAX_NON_ACTION_STEPS:
		_normalize_frames()
		if _frames.is_empty():
			return DataResult.success()
		var frame: ExecutionFrame = _frames.back()
		_scope = frame.scope
		if frame.index >= frame.block.statements.size():
			return DataResult.failure(_node_error(frame.block, "执行中的代码块不能为空。"))
		var statement: ProgramAst.StatementNode = frame.block.statements[frame.index]
		if statement is ProgramAst.DeclarationNode or statement is ProgramAst.AssignmentNode:
			var updated := _execute_binding(statement)
			if not updated.is_ok():
				return updated
			frame.index += 1
			continue
		if statement is ProgramAst.CallNode or statement is ProgramAst.SimultaneousNode:
			return DataResult.success(statement)
		var body: ProgramAst.BlockNode
		var repeats := false
		var for_values := PackedFloat64Array()
		if statement is ProgramAst.ForNode:
			var loop := statement as ProgramAst.ForNode
			current_line = loop.line
			line_changed.emit(current_line)
			if state != State.RUNNING:
				return DataResult.failure(message)
			var range_result := _for_values(loop, false, {"expressions": 0})
			if not range_result.is_ok():
				return range_result
			for_values = range_result.value
			body = loop.body
		elif statement is ProgramAst.LoopNode:
			body = (statement as ProgramAst.LoopNode).body
			repeats = true
		elif statement is ProgramAst.UserCallNode:
			var call := statement as ProgramAst.UserCallNode
			current_line = call.line
			line_changed.emit(current_line)
			if state != State.RUNNING:
				return DataResult.failure(message)
			if not _functions.has(call.callee):
				return DataResult.failure(_node_error(call, "执行中找不到用户函数“%s”。" % call.callee))
			body = (_functions[call.callee] as ProgramAst.FunctionNode).body
		elif statement is ProgramAst.IfNode:
			var branch := statement as ProgramAst.IfNode
			var evaluated := _evaluate_condition(branch)
			if not evaluated.is_ok():
				return evaluated
			body = branch.then_body if evaluated.value else branch.else_body
			if not evaluated.value and body != null and body.statements.is_empty():
				frame.index += 1
				continue
		else:
			return DataResult.failure(_node_error(frame.block, "执行中发现无效语句节点。"))
		if body == null or body.statements.is_empty() or _frames.size() >= MAX_EXECUTION_FRAMES:
			return DataResult.failure(_node_error(statement, "执行中的控制结构为空或超过嵌套上限。"))
		frame.index += 1
		var nested := ExecutionFrame.new()
		nested.block = body
		nested.repeats = repeats
		nested.scope = ProgramBindingScope.create(_globals if statement is ProgramAst.UserCallNode else frame.scope)
		if statement is ProgramAst.ForNode:
			nested.for_node = statement as ProgramAst.ForNode
			nested.for_values = for_values
			nested.scope.define(nested.for_node.iterator, for_values[0], false)
		_frames.append(nested)
	return DataResult.failure("第 %d 行，第 1 列：连续计算超过预算；请让循环执行移动或攻击动作。" % maxi(current_line, 1))


## 声明与赋值只更新本次运行的作用域，不推进世界；名称和常量写保护在运行时再次检查。
func _execute_binding(statement: ProgramAst.StatementNode) -> DataResult:
	current_line = statement.line
	line_changed.emit(current_line)
	if state != State.RUNNING:
		return DataResult.failure(message)
	if _scope == null:
		return DataResult.failure(_node_error(statement, "执行中缺少变量作用域。"))
	var declaration := statement as ProgramAst.DeclarationNode
	var assignment := statement as ProgramAst.AssignmentNode
	var expression: ProgramAst.ExpressionNode = declaration.initializer if declaration != null else assignment.expression
	var result := _expression_data(expression,false,0,{}, {"expressions":0})
	if not result.is_ok():
		return result
	var value: Variant = result.value.value
	if declaration != null:
		if not ProgramVariableValidation.is_binding_name(declaration.name) or _scope.bindings.has(declaration.name):
			return DataResult.failure(_node_error(declaration, "名称“%s”在当前作用域中重复声明。" % declaration.name))
		_scope.define(declaration.name,value,declaration.mutable)
	else:
		var binding := _scope.resolve(assignment.name)
		if binding.is_empty():
			return DataResult.failure(_node_error(assignment, "名称“%s”尚未声明或不在当前作用域中。" % assignment.name))
		if not binding.mutable:
			return DataResult.failure(_node_error(assignment, "常量“%s”不能重新赋值。" % assignment.name))
		binding.value = value.duplicate(true) if value is Dictionary else value
	return DataResult.success()


## 循环尾部重置同一帧，有限入口结束则出栈；结构转换不制造额外空白 tick。
func _normalize_frames() -> void:
	while not _frames.is_empty():
		var frame: ExecutionFrame = _frames.back()
		if frame.index < frame.block.statements.size():
			return
		if frame.for_node != null and frame.for_index + 1 < frame.for_values.size():
			frame.for_index += 1
			frame.index = 0
			frame.scope = ProgramBindingScope.create(frame.scope.parent)
			frame.scope.define(frame.for_node.iterator, frame.for_values[frame.for_index], false)
			return
		if frame.repeats:
			frame.index = 0
			frame.scope = ProgramBindingScope.create(frame.scope.parent)
			return
		_frames.pop_back()


## 每帧按源码顺序展开有限条件回调；同一 tick 的多次 ready 查询不会自行消耗冷却。
func _dispatch_tick() -> DataResult:
	if program.tick == null:
		return DataResult.success()
	_dispatching = true
	var root := ExecutionFrame.new()
	root.block = program.tick.body
	root.scope = ProgramBindingScope.create(_globals)
	var frames: Array[ExecutionFrame] = [root]
	# 每个语句最多入栈一次、退栈一次；有限预算避免外部篡改 AST 后使回调卡住一帧。
	for unused in ProgramParser.MAX_STATEMENTS * 2 + ProgramParser.MAX_CONTROL_DEPTH + 2:
		if frames.is_empty():
			_dispatching = false
			return DataResult.success()
		var frame: ExecutionFrame = frames.back()
		_scope = frame.scope
		if frame.index >= frame.block.statements.size():
			frames.pop_back()
			continue
		var statement: ProgramAst.StatementNode = frame.block.statements[frame.index]
		frame.index += 1
		if statement is ProgramAst.IfNode:
			var branch := statement as ProgramAst.IfNode
			var evaluated := _evaluate_condition(branch)
			if not evaluated.is_ok():
				return _fail_tick(evaluated.errors[0])
			var body: ProgramAst.BlockNode = branch.then_body if evaluated.value else branch.else_body
			if not evaluated.value and body != null and body.statements.is_empty():
				continue
			if body == null or body.statements.is_empty() or frames.size() > ProgramParser.MAX_CONTROL_DEPTH:
				return _fail_tick(_node_error(branch, "执行中的条件块为空或超过嵌套上限。"))
			var nested := ExecutionFrame.new()
			nested.block = body
			nested.scope = ProgramBindingScope.create(frame.scope)
			frames.append(nested)
			continue
		if not statement is ProgramAst.CallNode:
			return _fail_tick(_node_error(frame.block, "tick() 包含无效或无法有限结束的语句。"))
		var call := statement as ProgramAst.CallNode
		current_line = call.line
		line_changed.emit(current_line)
		if state != State.RUNNING:
			_dispatching = false
			return DataResult.failure(message)
		# 世界按机器、接收模块和动作合并重复输入；具名与广播仍共享每个模块的冷却。
		var arguments := _argument_values(call, false, {"expressions": 0})
		if not arguments.is_ok():
			return _fail_tick(arguments.errors[0])
		var requested := world.request_tick_action(world.player.id, call.callee, arguments.value[0], call.receiver)
		if not requested.is_ok():
			return _fail_tick(_node_error(call, call.callee + " 回调未接受：" + "; ".join(requested.errors)))
	return _fail_tick("第 %d 行，第 1 列：tick() 控制结构超过本次调度预算。" % maxi(current_line, 1))


## 回调失败统一撤销本帧已排队动作；外部取消的终态不可再被失败覆盖。
func _fail_tick(reason: String) -> DataResult:
	if state == State.RUNNING:
		world.cancel_command(world.player.id)
		_command = null
		_finish(State.FAILED, reason)
	_dispatching = false
	return DataResult.failure(reason)


## 标记终态并只发送一次完成信号，重复取消或后续 step 不会重复通知。
func _finish(terminal_state: State, reason: String) -> void:
	if _finished_emitted:
		return
	state = terminal_state
	message = reason
	_finished_emitted = true
	_frames.clear()
	_command_node = null
	finished.emit(state == State.COMPLETED, message)


## 为当前 main 调用附加源码位置，阻挡错误可直接指向程序中的失败行。
func _call_error(reason: String) -> String:
	return _node_error(_command_node, reason)


## 统一运行时错误格式，使其与词法和解析错误的高亮规则一致。
static func _node_error(node: ProgramAst.AstNode, reason: String) -> String:
	return "第 %d 行，第 %d 列：%s" % [node.line, node.column, reason]
