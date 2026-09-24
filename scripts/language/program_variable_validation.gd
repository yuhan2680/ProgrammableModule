class_name ProgramVariableValidation
extends RefCounted
## 纯静态名称解析：声明顺序、词法作用域与常量写保护独立于具体世界和运行时取值。

var _function_names: Dictionary = {}
var _statements := 0
var _expressions := 0


## 数值名称与函数使用相同的保留字约束，不能覆盖动作和控制关键字。
static func is_binding_name(value: String) -> bool:
	return ProgramFunctionValidation.is_function_name(value)


## Parser 和 Runner 共用完整名称校验，未选中的分支及未调用函数也必须合法。
static func validate(program: ProgramAst.ProgramNode) -> DataResult:
	var validator := ProgramVariableValidation.new()
	return validator._validate(program)


## 全局按声明顺序校验，所有入口的词法父级均为完整的全局表。
func _validate(program: ProgramAst.ProgramNode) -> DataResult:
	if program == null or program.main == null or program.main.body == null:
		return DataResult.failure("第 1 行，第 1 列：程序缺少有效的 main 入口。")
	for function: ProgramAst.FunctionNode in program.functions:
		if function == null:
			return _failure(program, "程序包含空函数声明。")
		_function_names[function.name] = true
	var globals := ProgramBindingScope.create()
	for declaration: ProgramAst.DeclarationNode in program.globals:
		if declaration == null:
			return _failure(program, "程序包含空的全局声明。")
		var checked := _statement(declaration, globals, false)
		if not checked.is_ok():
			return checked
	var events_checked := _radar_events(program, globals)
	if not events_checked.is_ok():
		return events_checked
	var entries: Array[ProgramAst.FunctionNode] = [program.main]
	if program.tick != null:
		entries.append(program.tick)
	entries.append_array(program.functions)
	for function: ProgramAst.FunctionNode in entries:
		var checked := _block(function.body, ProgramBindingScope.create(globals), function.name == "tick", 0, {})
		if not checked.is_ok():
			return checked
	return DataResult.success()


## 事件只写入注册位置之前的显式全局变量，不受 main 或函数内的同名局部变量影响。
func _radar_events(program: ProgramAst.ProgramNode, globals: ProgramBindingScope) -> DataResult:
	var structure_checked := ProgramFunctionValidation.validate_radar_events(program)
	if not structure_checked.is_ok():
		return structure_checked
	var declarations := {}
	for declaration: ProgramAst.DeclarationNode in program.globals:
		declarations[declaration.name] = declaration
	for event: ProgramAst.RadarEventNode in program.radar_events:
		var binding := globals.resolve(event.binding_name)
		if binding.is_empty():
			return _failure(event, "雷达事件目标“%s”必须是已声明的全局 variable，不能使用局部或未声明名称。" % event.binding_name)
		if not binding.mutable:
			return _failure(event, "雷达事件不能绑定常量“%s”；请使用全局 variable。" % event.binding_name)
		var declaration := declarations[event.binding_name] as ProgramAst.DeclarationNode
		if declaration.line > event.line or (declaration.line == event.line and declaration.column > event.column):
			return _failure(event, "雷达事件目标“%s”必须先声明全局 variable，再注册 onDetected。" % event.binding_name)
	return DataResult.success()


## 有界遍历代码块，兄弟分支和每轮循环的声明都局限在各自子作用域。
func _block(block: ProgramAst.BlockNode, scope: ProgramBindingScope, restricted: bool, depth: int, active: Dictionary) -> DataResult:
	if block == null:
		return DataResult.failure("第 1 行，第 1 列：程序包含空代码块。")
	if depth > ProgramParser.MAX_CONTROL_DEPTH:
		return _failure(block, "控制结构嵌套最多允许 %d 层。" % ProgramParser.MAX_CONTROL_DEPTH)
	if active.has(block.get_instance_id()):
		return _failure(block, "语法树存在循环引用，无法执行。")
	active[block.get_instance_id()] = true
	for statement: ProgramAst.StatementNode in block.statements:
		if statement == null:
			return _failure(block, "程序包含空语句节点。")
		var checked := _statement(statement, scope, restricted)
		if not checked.is_ok():
			return checked
		var children: Array[ProgramAst.BlockNode] = []
		if statement is ProgramAst.ForNode:
			var loop := statement as ProgramAst.ForNode
			if restricted:
				return _failure(loop, "tick() 和 simultaneously 块内不能包含 for 循环。")
			if not is_binding_name(loop.iterator) or _function_names.has(loop.iterator):
				return _failure(loop, "循环变量名称必须是非保留的英文标识符，且不能与函数名相同。")
			for bound: ProgramAst.ExpressionNode in [loop.start, loop.end, loop.step]:
				checked = _expression(bound, scope, 0, {})
				if not checked.is_ok():
					return checked
			var iteration := ProgramBindingScope.create(scope)
			iteration.define(loop.iterator, 0.0, false)
			checked = _block(loop.body, iteration, false, depth + 1, active)
			if not checked.is_ok():
				return checked
		elif statement is ProgramAst.LoopNode:
			children.append((statement as ProgramAst.LoopNode).body)
		elif statement is ProgramAst.IfNode:
			var branch := statement as ProgramAst.IfNode
			if branch.condition is ProgramAst.ComparisonNode:
				var comparison := branch.condition as ProgramAst.ComparisonNode
				for expression: ProgramAst.ExpressionNode in [comparison.left,comparison.right]:
					checked = _expression(expression,scope,0,{})
					if not checked.is_ok():
						return checked
			children.append(branch.then_body)
			children.append(branch.else_body)
		elif statement is ProgramAst.SimultaneousNode:
			children.append((statement as ProgramAst.SimultaneousNode).body)
		for child: ProgramAst.BlockNode in children:
			checked = _block(child,ProgramBindingScope.create(scope),restricted or statement is ProgramAst.SimultaneousNode,depth + 1,active)
			if not checked.is_ok():
				return checked
	active.erase(block.get_instance_id())
	return DataResult.success()


## 初始化表达式先读取外层再声明本层，赋值必须指向已经存在的可变绑定。
func _statement(statement: ProgramAst.StatementNode, scope: ProgramBindingScope, restricted: bool) -> DataResult:
	_statements += 1
	if _statements > ProgramParser.MAX_STATEMENTS:
		return _failure(statement, "程序超过语句节点数量限制。")
	if statement is ProgramAst.DeclarationNode or statement is ProgramAst.AssignmentNode:
		if restricted:
			return _failure(statement, "tick() 和 simultaneously 块内不能声明或修改变量。")
	if statement is ProgramAst.DeclarationNode:
		var declaration := statement as ProgramAst.DeclarationNode
		if not is_binding_name(declaration.name) or _function_names.has(declaration.name):
			return _failure(declaration, "数值名称必须是非保留的英文标识符，且不能与函数名相同。")
		if scope.bindings.has(declaration.name):
			return _failure(declaration, "名称“%s”在当前作用域中重复声明。" % declaration.name)
		var checked := _expression(declaration.initializer,scope,0,{})
		if not checked.is_ok():
			return checked
		scope.define(declaration.name,0.0,declaration.mutable)
	elif statement is ProgramAst.AssignmentNode:
		var assignment := statement as ProgramAst.AssignmentNode
		var binding := scope.resolve(assignment.name)
		if binding.is_empty():
			return _failure(assignment, "名称“%s”尚未声明或不在当前作用域中。" % assignment.name)
		if not binding.mutable:
			return _failure(assignment, "常量“%s”不能重新赋值。" % assignment.name)
		return _expression(assignment.expression,scope,0,{})
	elif statement is ProgramAst.CallNode:
		for expression: ProgramAst.ExpressionNode in (statement as ProgramAst.CallNode).arguments:
			var checked := _expression(expression,scope,0,{})
			if not checked.is_ok():
				return checked
	return DataResult.success()


## 表达式只解析名称与有限树结构；数值、世界能力和溢出仍由执行器统一校验。
func _expression(expression: ProgramAst.ExpressionNode, scope: ProgramBindingScope, depth: int, active: Dictionary) -> DataResult:
	if expression == null:
		return DataResult.failure("第 1 行，第 1 列：数值表达式不能为空。")
	_expressions += 1
	if depth >= ProgramParser.MAX_EXPRESSION_DEPTH or _expressions > ProgramParser.MAX_EXPRESSION_NODES:
		return _failure(expression, "数值表达式超过深度或节点数量限制。")
	if active.has(expression.get_instance_id()):
		return _failure(expression, "数值表达式存在循环引用，无法执行。")
	active[expression.get_instance_id()] = true
	if expression is ProgramAst.NameNode:
		var reference := expression as ProgramAst.NameNode
		if not is_binding_name(reference.name) or scope.resolve(reference.name).is_empty():
			return _failure(reference, "名称“%s”尚未声明或不在当前作用域中。" % reference.name)
	var children: Array[ProgramAst.ExpressionNode] = []
	if expression is ProgramAst.BinaryNode:
		children.append((expression as ProgramAst.BinaryNode).left)
		children.append((expression as ProgramAst.BinaryNode).right)
	elif expression is ProgramAst.RandomNode:
		children.append_array((expression as ProgramAst.RandomNode).arguments)
	elif expression is ProgramAst.DistanceNode:
		children.append((expression as ProgramAst.DistanceNode).angle)
	elif expression is ProgramAst.TargetMemberNode:
		children.append((expression as ProgramAst.TargetMemberNode).target)
	for child: ProgramAst.ExpressionNode in children:
		var checked := _expression(child,scope,depth + 1,active)
		if not checked.is_ok():
			return checked
	active.erase(expression.get_instance_id())
	return DataResult.success()


## 名称解析错误采用统一一基行列，便于代码编辑器准确高亮。
static func _failure(node: ProgramAst.AstNode, reason: String) -> DataResult:
	return DataResult.failure("第 %d 行，第 %d 列：%s" % [node.line,node.column,reason])
