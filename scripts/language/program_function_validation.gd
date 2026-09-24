class_name ProgramFunctionValidation
extends RefCounted
## 函数表和调用图共用纯静态校验；不展开函数体，也不读取世界或提交动作。

const MAX_FUNCTIONS: int = 32
const MAX_FUNCTION_DEPTH: int = 16
const RESERVED_NAMES: Array[String] = ["main", "tick", "move", "attack", "shoot", "ready", "distance", "true", "false", "null", "Null", "scan", "random", "randomInt"]

var _functions: Dictionary = {}
var _edges: Dictionary = {}
var _statements: int = 0


## 函数标识符独立于装配实例名称，禁止覆盖已有能力与控制结构名称。
static func is_function_name(value: String) -> bool:
	return ProgramParser.is_receiver_name(value) and value not in RESERVED_NAMES


## 完整建表后检查全部函数（包括暂未调用的函数），保证前向引用与统一边界。
static func validate(program: ProgramAst.ProgramNode) -> DataResult:
	var validator := ProgramFunctionValidation.new()
	return validator._validate(program)


## 公开 AST 的事件仅允许有限具名绑定，不接受空节点、重复来源或重复写入目标。
static func validate_radar_events(program: ProgramAst.ProgramNode) -> DataResult:
	if program == null:
		return DataResult.failure("第 1 行，第 1 列：程序缺少有效的 main 入口。")
	if program.radar_events.size() > ProgramParser.MAX_RADAR_EVENTS:
		return _failure(program, "程序最多允许 %d 个雷达事件绑定。" % ProgramParser.MAX_RADAR_EVENTS)
	var receivers := {}
	var bindings := {}
	for event: ProgramAst.RadarEventNode in program.radar_events:
		if event == null:
			return _failure(program, "程序包含空的雷达事件绑定。")
		if not ProgramParser.is_receiver_name(event.receiver):
			return _failure(event, "雷达事件模块名必须是非保留的英文标识符，最多 128 个字符。")
		if not is_function_name(event.binding_name):
			return _failure(event, "雷达事件绑定名称必须是非保留的英文标识符，最多 128 个字符。")
		if receivers.has(event.receiver):
			return _failure(event, "雷达模块“%s”不能重复注册 onDetected 事件。" % event.receiver)
		if bindings.has(event.binding_name):
			return _failure(event, "全局变量“%s”不能被多个雷达事件重复绑定。" % event.binding_name)
		receivers[event.receiver] = true
		bindings[event.binding_name] = true
	return DataResult.success()


## 先检查函数声明，再收集有限语法块中的调用边，最后检查有向图的深度与循环。
func _validate(program: ProgramAst.ProgramNode) -> DataResult:
	if program == null or program.main == null or program.main.body == null:
		return DataResult.failure("第 1 行，第 1 列：程序缺少有效的 main 入口。")
	var events_checked := validate_radar_events(program)
	if not events_checked.is_ok():
		return events_checked
	if program.functions.size() > MAX_FUNCTIONS:
		return _failure(program, "程序最多允许 %d 个用户函数。" % MAX_FUNCTIONS)
	for function: ProgramAst.FunctionNode in program.functions:
		if function == null:
			return _failure(program, "程序包含空函数声明。")
		if not is_function_name(function.name):
			return _failure(function, "函数名必须是非保留的英文标识符，最多 128 个字符。")
		if _functions.has(function.name):
			return _failure(function, "用户函数“%s”重复声明。" % function.name)
		if function.body == null or function.body.statements.is_empty():
			return _failure(function, "用户函数不能为空；请至少添加一条动作指令。")
		_functions[function.name] = function
	var entries: Array[ProgramAst.FunctionNode] = [program.main]
	if program.tick != null:
		entries.append(program.tick)
	entries.append_array(program.functions)
	for function: ProgramAst.FunctionNode in entries:
		_edges[function.name] = []
		var collected := _collect(function.body, function.name, false, 0, {})
		if not collected.is_ok():
			return collected
	var heights := {}
	for function: ProgramAst.FunctionNode in program.functions:
		var checked := _height(function.name, {}, heights)
		if not checked.is_ok():
			return checked
	return DataResult.success(_functions)


## 每个源码块只按真实结构访问，不沿调用引用重走函数体，避免指数级展开。
func _collect(block: ProgramAst.BlockNode, owner: String, simultaneous: bool, depth: int, active: Dictionary) -> DataResult:
	if block == null:
		return DataResult.failure("第 1 行，第 1 列：程序包含空代码块。")
	if depth > ProgramParser.MAX_CONTROL_DEPTH:
		return _failure(block, "控制结构嵌套最多允许 %d 层。" % ProgramParser.MAX_CONTROL_DEPTH)
	if active.has(block.get_instance_id()):
		return _failure(block, "语法树存在循环引用，无法执行。")
	active[block.get_instance_id()] = true
	for statement: ProgramAst.StatementNode in block.statements:
		_statements += 1
		if _statements > ProgramParser.MAX_STATEMENTS:
			return _failure(block, "程序超过语句节点数量限制。")
		if statement == null:
			return _failure(block, "程序包含空语句节点。")
		if statement is ProgramAst.UserCallNode:
			var call := statement as ProgramAst.UserCallNode
			if owner == "tick" or simultaneous:
				return _failure(call, "tick() 和 simultaneously 块内只接受有限动作，不能调用用户函数。")
			if not _functions.has(call.callee):
				return _failure(call, "找不到用户函数“%s”；请使用 function 名称() 声明。" % call.callee)
			_edges[owner].append(call)
		var children: Array[ProgramAst.BlockNode] = []
		if statement is ProgramAst.LoopNode:
			children.append((statement as ProgramAst.LoopNode).body)
		elif statement is ProgramAst.ForNode:
			children.append((statement as ProgramAst.ForNode).body)
		elif statement is ProgramAst.IfNode:
			var branch := statement as ProgramAst.IfNode
			children.append(branch.then_body)
			children.append(branch.else_body)
		elif statement is ProgramAst.SimultaneousNode:
			children.append((statement as ProgramAst.SimultaneousNode).body)
		for child: ProgramAst.BlockNode in children:
			var checked := _collect(child, owner, simultaneous or statement is ProgramAst.SimultaneousNode, depth + 1, active)
			if not checked.is_ok():
				return checked
	active.erase(block.get_instance_id())
	return DataResult.success()


## 三色访问和记忆化最长路径同时拒绝直接/间接递归及过深调用，复杂度与声明图成正比。
func _height(name: String, active: Dictionary, heights: Dictionary) -> DataResult:
	if heights.has(name):
		return DataResult.success(heights[name])
	active[name] = true
	var height := 1
	for call: ProgramAst.UserCallNode in _edges[name]:
		if active.has(call.callee):
			return _failure(call, "用户函数不允许递归调用（%s → %s）。" % [name, call.callee])
		if active.size() >= MAX_FUNCTION_DEPTH:
			return _failure(call, "用户函数调用最多允许 %d 层。" % MAX_FUNCTION_DEPTH)
		var child := _height(call.callee, active, heights)
		if not child.is_ok():
			return child
		height = maxi(height, int(child.value) + 1)
		if height > MAX_FUNCTION_DEPTH:
			return _failure(call, "用户函数调用最多允许 %d 层。" % MAX_FUNCTION_DEPTH)
	active.erase(name)
	heights[name] = height
	return DataResult.success(height)


## 所有公开函数结构错误保留一基源码位置，与 Parser/Runner 的诊断格式一致。
static func _failure(node: ProgramAst.AstNode, reason: String) -> DataResult:
	return DataResult.failure("第 %d 行，第 %d 列：%s" % [node.line, node.column, reason])
