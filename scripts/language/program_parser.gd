class_name ProgramParser
extends RefCounted
## 有界递归下降解析器：调用、循环、条件与并行块使用显式语句，不展开源码。
## main 逐关解锁控制结构；可选 tick 回调始终只接受有限短动作。

const MAX_CALLS: int = 512
const MAX_STATEMENTS: int = 1024
const MAX_LOOP_DEPTH: int = 16
const MAX_CONTROL_DEPTH: int = 16
const MAX_EXPRESSION_DEPTH: int = 32
const MAX_EXPRESSION_NODES: int = 2048
const MAX_RADAR_EVENTS: int = 32
const COMPARISONS: Array[String] = ["<", "<=", ">", ">=", "==", "!="]
const CALL_ARITIES: Dictionary = {"move": 2, "attack": 1, "shoot": 1}
const LOCKED_SYNTAX: Array[String] = [
	"simultaneously", "loop", "if", "else", "for", "while", "function", "fun",
	"return", "constant", "variable", "value", "var", "val", "break", "continue",
]

var _tokens: Array[ProgramLexer.Token] = []
var _index: int = 0
var _allowed_calls: PackedStringArray = PackedStringArray()
var _error: String = ""
var _allow_tick: bool = false
var _allow_named_calls: bool = false
var _allow_loops: bool = false
var _allow_conditionals: bool = false
var _allow_simultaneous: bool = false
var _allow_distance: bool = false
var _allow_functions: bool = false
var _allow_variables: bool = false
var _allow_radar: bool = false
var _allow_random: bool = false
var _allow_for: bool = false
var _allow_radar_events: bool = false
var _expression_count: int = 0
var _function_name: String = ""
var _call_count: int = 0
var _statement_count: int = 0


## 将源代码静态编译为独立语法树；整个过程不会创建世界或提交移动指令。
static func parse(source: String, allowed_calls: PackedStringArray = PackedStringArray(["move"]), allow_tick: bool = false, allow_named_calls: bool = false, allow_loops: bool = false, allow_conditionals: bool = false, allow_simultaneous: bool = false, allow_distance: bool = false, allow_functions: bool = false, allow_variables: bool = false, allow_radar: bool = false, allow_random: bool = false, allow_for: bool = false, allow_radar_events: bool = false) -> DataResult:
	var lexed := ProgramLexer.tokenize(source)
	if not lexed.is_ok():
		return lexed
	var parser := ProgramParser.new()
	parser._tokens = lexed.value
	parser._allowed_calls = allowed_calls.duplicate()
	parser._allow_tick = allow_tick
	parser._allow_named_calls = allow_named_calls
	parser._allow_loops = allow_loops
	parser._allow_conditionals = allow_conditionals
	parser._allow_simultaneous = allow_simultaneous
	parser._allow_distance = allow_distance
	parser._allow_functions = allow_functions
	parser._allow_variables = allow_variables
	parser._allow_radar = allow_radar
	parser._allow_random = allow_random
	parser._allow_for = allow_for
	parser._allow_radar_events = allow_radar_events
	var program := parser._parse_program()
	if not parser._error.is_empty():
		return DataResult.failure(parser._error)
	var functions_checked := ProgramFunctionValidation.validate(program)
	if not functions_checked.is_ok():
		return functions_checked
	var bindings_checked := ProgramVariableValidation.validate(program)
	if not bindings_checked.is_ok():
		return bindings_checked
	return DataResult.success(program)


## 解析唯一 main、可选 tick、用户函数和顶层雷达绑定；事件不进入任何函数体。
func _parse_program() -> ProgramAst.ProgramNode:
	var program := ProgramAst.ProgramNode.new()
	_skip_newlines()
	while _peek().kind != ProgramLexer.Kind.END:
		if _is_radar_event_start():
			if program.radar_events.size() >= MAX_RADAR_EVENTS:
				_fail(_peek(), "程序最多允许 %d 个雷达事件绑定。" % MAX_RADAR_EVENTS)
				return null
			var event := _parse_radar_event()
			if event == null:
				return null
			program.radar_events.append(event)
			if _peek().kind not in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.END]:
				_fail(_peek(), "雷达事件绑定之后需要换行。")
				return null
			_skip_newlines()
			continue
		if _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme in ["constant", "variable", "value"]:
			if _statement_count >= MAX_STATEMENTS:
				_fail(_peek(), "程序超过语句节点数量限制。")
				return null
			_statement_count += 1
			_function_name = ""
			var declaration := _parse_binding(true, false) as ProgramAst.DeclarationNode
			if declaration == null:
				return null
			program.globals.append(declaration)
			if _peek().kind not in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.END]:
				_fail(_peek(), "全局声明之后需要换行。")
				return null
			_skip_newlines()
			continue
		var custom := _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "function"
		if custom:
			if not _allow_functions:
				_fail(_peek(), "本关尚未解锁 function 函数。")
				return null
			_advance()
		var entry_token := _expect(ProgramLexer.Kind.IDENTIFIER, "程序需要 main() 入口或 function 名称() 声明。")
		if entry_token == null:
			return null
		if custom:
			if not ProgramFunctionValidation.is_function_name(entry_token.lexeme):
				_fail(entry_token, "函数名必须是非保留的英文标识符，最多 128 个字符。")
				return null
			if program.functions.size() >= ProgramFunctionValidation.MAX_FUNCTIONS:
				_fail(entry_token, "程序最多允许 %d 个用户函数。" % ProgramFunctionValidation.MAX_FUNCTIONS)
				return null
		elif entry_token.lexeme not in ["main", "tick"]:
			_fail(entry_token, "程序需要 main() 入口；用户函数必须使用 function 名称() 声明。" if _allow_functions else "程序需要 main() 入口；不能在入口外执行指令或定义其它函数。")
			return null
		if not custom and entry_token.lexeme == "tick" and not _allow_tick:
			_fail(entry_token, "本关尚未解锁 tick() 回调。")
			return null
		if not custom and ((entry_token.lexeme == "main" and program.main != null) or (entry_token.lexeme == "tick" and program.tick != null)):
			_fail(entry_token, "不能声明第二个入口：%s() 已存在。" % entry_token.lexeme)
			return null
		_function_name = entry_token.lexeme
		if _expect(ProgramLexer.Kind.LEFT_PAREN, "%s 后需要左括号 '('." % _function_name) == null:
			return null
		_skip_newlines()
		if _expect(ProgramLexer.Kind.RIGHT_PAREN, "%s 不接受参数，需要右括号 ')'." % _function_name) == null:
			return null
		_skip_newlines()
		var block := _parse_block()
		if block == null:
			return null
		var function := ProgramAst.FunctionNode.new()
		function.line = entry_token.line
		function.column = entry_token.column
		function.name = _function_name
		function.body = block
		if custom:
			program.functions.append(function)
		elif _function_name == "main":
			program.main = function
			program.line = entry_token.line
			program.column = entry_token.column
		else:
			program.tick = function
		_skip_newlines()
	if program.main == null:
		_fail(_peek(), "程序需要 main() { ... } 入口；其它函数不能替代 main()。")
		return null
	return program


## 识别具名事件前缀，不将已有普通函数名或目标成员扩展为事件语法。
func _is_radar_event_start() -> bool:
	return _index + 2 < _tokens.size() and _peek().kind == ProgramLexer.Kind.IDENTIFIER and _tokens[_index + 1].kind == ProgramLexer.Kind.DOT and _tokens[_index + 2].kind == ProgramLexer.Kind.IDENTIFIER and _tokens[_index + 2].lexeme == "onDetected"


## 事件只有固定的 EnemyPosition 箭头绑定形式，注册期间不求值或执行回调。
func _parse_radar_event() -> ProgramAst.RadarEventNode:
	var receiver := _peek()
	if not _allow_radar_events:
		_fail(receiver, "本关尚未解锁 onDetected 雷达事件。")
		return null
	if not _allow_radar:
		_fail(receiver, "雷达事件需要先解锁 scan 雷达查询。")
		return null
	if not _allow_variables:
		_fail(receiver, "雷达事件需要先解锁常量、变量与赋值。")
		return null
	if not _allow_named_calls:
		_fail(receiver, "雷达事件需要先解锁命名模块调用。")
		return null
	if not is_receiver_name(receiver.lexeme):
		_fail(receiver, "雷达事件模块名必须是非保留的英文标识符，最多 128 个字符。")
		return null
	_advance()
	_advance()
	_advance()
	_skip_newlines()
	if _expect(ProgramLexer.Kind.LEFT_BRACE, "onDetected 后需要 '{ EnemyPosition -> 全局变量 }'，不接受函数括号。") == null:
		return null
	_skip_newlines()
	var payload := _expect(ProgramLexer.Kind.IDENTIFIER, "雷达事件只接受 EnemyPosition -> 全局变量 绑定。")
	if payload == null:
		return null
	if payload.lexeme != "EnemyPosition":
		_fail(payload, "雷达事件只接受 EnemyPosition -> 全局变量 绑定。")
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.ARROW, "EnemyPosition 后需要连续箭头 '->'。") == null:
		return null
	_skip_newlines()
	var binding := _expect(ProgramLexer.Kind.IDENTIFIER, "雷达事件箭头后需要已声明的全局 variable 名称。")
	if binding == null:
		return null
	if not ProgramVariableValidation.is_binding_name(binding.lexeme):
		_fail(binding, "雷达事件绑定名称必须是非保留的英文标识符，最多 128 个字符。")
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RIGHT_BRACE, "雷达事件只允许一个全局变量绑定，不接受动作、赋值或回调代码。") == null:
		return null
	var event := ProgramAst.RadarEventNode.new()
	event.line = receiver.line
	event.column = receiver.column
	event.receiver = receiver.lexeme
	event.binding_name = binding.lexeme
	return event


## 解析有深度上限的代码块；两个语句之间必须换行，注释本身不能分隔语句。
func _parse_block(control_depth: int = 0, simultaneous_body: bool = false) -> ProgramAst.BlockNode:
	var open := _expect(ProgramLexer.Kind.LEFT_BRACE, "%s() 后需要代码块 '{ ... }'." % _function_name)
	if open == null:
		return null
	var block := ProgramAst.BlockNode.new()
	block.line = open.line
	block.column = open.column
	_skip_newlines()
	while _peek().kind != ProgramLexer.Kind.RIGHT_BRACE:
		if _is_radar_event_start():
			_fail(_peek(), "onDetected 雷达事件只能在顶层注册，不能写入 main、tick 或其它代码块。")
			return null
		if _peek().kind == ProgramLexer.Kind.END:
			_fail(_peek(), "代码块缺少右花括号 '}'.")
			return null
		if _statement_count >= MAX_STATEMENTS:
			_fail(_peek(), "程序最多允许 %d 个语句节点（含循环、分支与并行块）。" % MAX_STATEMENTS)
			return null
		_statement_count += 1
		var statement: ProgramAst.StatementNode
		if simultaneous_body and _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme in ["loop", "for", "if", "simultaneously"]:
			_fail(_peek(), "simultaneously 内只接受直接动作，不能包含 loop、for、if 或嵌套并行块。")
			return null
		if _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme in ["constant", "variable", "value"]:
			statement = _parse_binding(true, simultaneous_body)
		elif _peek().kind == ProgramLexer.Kind.IDENTIFIER and _index + 1 < _tokens.size() and _tokens[_index + 1].kind == ProgramLexer.Kind.ASSIGN:
			statement = _parse_binding(false, simultaneous_body)
		elif _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "simultaneously":
			statement = _parse_simultaneous(control_depth)
		elif _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "for":
			statement = _parse_for(control_depth)
		elif _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "loop":
			statement = _parse_loop(control_depth)
		elif _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "if":
			statement = _parse_if(control_depth)
		else:
			if _call_count >= MAX_CALLS:
				_fail(_peek(), "程序最多允许 %d 条调用。" % MAX_CALLS)
				return null
			statement = _parse_call(simultaneous_body)
			_call_count += 1
		if statement == null:
			return null
		block.statements.append(statement)
		# 右花括号可以紧随最后一条调用，但另一条调用必须换行。
		# 内层循环刚闭合时也可能直接到 EOF；此时缺的是外层右括号，不是语句换行。
		if _peek().kind == ProgramLexer.Kind.END:
			_fail(_peek(), "代码块缺少右花括号 '}'.")
			return null
		if _peek().kind not in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.RIGHT_BRACE]:
			_fail(_peek(), "每行只能写一条调用；请换行后再写下一条语句。")
			return null
		_skip_newlines()
	_advance()
	return block


## 并行块只声明一次性动作集合；平坦结构使资源冲突能在所有动作执行前检查。
func _parse_simultaneous(control_depth: int) -> ProgramAst.SimultaneousNode:
	var token := _peek()
	if not _allow_simultaneous:
		_fail(token, "本关尚未解锁 simultaneously 并行块。")
		return null
	if _function_name == "tick":
		_fail(token, "tick() 不能包含需要等待完成的 simultaneously 并行块。")
		return null
	if control_depth >= MAX_CONTROL_DEPTH:
		_fail(token, "控制结构嵌套最多允许 %d 层。" % MAX_CONTROL_DEPTH)
		return null
	_advance()
	_skip_newlines()
	if _peek().kind != ProgramLexer.Kind.LEFT_BRACE:
		_fail(_peek(), "simultaneously 后需要代码块 '{ ... }'，不接受函数括号。")
		return null
	var body := _parse_block(control_depth + 1, true)
	if body == null:
		return null
	if body.statements.size() < 2:
		_fail(token, "simultaneously 代码块至少需要两条动作指令。")
		return null
	var simultaneous := ProgramAst.SimultaneousNode.new()
	simultaneous.line = token.line
	simultaneous.column = token.column
	simultaneous.body = body
	return simultaneous


## loop 只接受无限块形式；禁止空块与 tick 循环，连续纯计算由运行预算保护。
func _parse_loop(control_depth: int) -> ProgramAst.LoopNode:
	var token := _peek()
	if not _allow_loops:
		_fail(token, "本关尚未解锁 loop 循环。")
		return null
	if _function_name == "tick":
		_fail(token, "tick() 必须在每帧有限结束，不能包含 loop 循环。")
		return null
	if control_depth >= MAX_CONTROL_DEPTH:
		_fail(token, "loop 嵌套最多允许 %d 层。" % MAX_LOOP_DEPTH)
		return null
	_advance()
	_skip_newlines()
	if _peek().kind != ProgramLexer.Kind.LEFT_BRACE:
		_fail(_peek(), "loop 后需要代码块 '{ ... }'，不接受次数参数。")
		return null
	var body := _parse_block(control_depth + 1)
	if body == null:
		return null
	if body.statements.is_empty():
		_fail(token, "loop 代码块不能为空；请至少添加一条动作指令。")
		return null
	var loop := ProgramAst.LoopNode.new()
	loop.line = token.line
	loop.column = token.column
	loop.body = body
	return loop


## 有限循环使用显式区间和可选步长；in / step 是上下文关键字，不占用旧变量名称。
func _parse_for(control_depth: int) -> ProgramAst.ForNode:
	var token := _peek()
	if not _allow_for:
		_fail(token, "本关尚未解锁 for 有限循环。")
		return null
	if _function_name == "tick":
		_fail(token, "tick() 不能包含需要等待完成的 for 循环。")
		return null
	if control_depth >= MAX_CONTROL_DEPTH:
		_fail(token, "控制结构嵌套最多允许 %d 层。" % MAX_CONTROL_DEPTH)
		return null
	_advance()
	_skip_newlines()
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "for 后需要括号，例如 for (angle in 0..315 step 45)。") == null:
		return null
	_skip_newlines()
	var name := _expect(ProgramLexer.Kind.IDENTIFIER, "for 需要一个循环变量名称。")
	if name == null:
		return null
	if not ProgramVariableValidation.is_binding_name(name.lexeme):
		_fail(name, "循环变量名称必须是非保留的英文标识符。")
		return null
	_skip_newlines()
	var separator := _expect(ProgramLexer.Kind.IDENTIFIER, "循环变量后需要 in 和区间。")
	if separator == null:
		return null
	if separator.lexeme != "in":
		_fail(separator, "循环变量后需要 in 和区间。")
		return null
	_skip_newlines()
	var first := _parse_expression()
	if first == null:
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RANGE, "for 区间使用两个点 '..' 分隔起点与终点。") == null:
		return null
	_skip_newlines()
	var last := _parse_expression()
	if last == null:
		return null
	_skip_newlines()
	var increment: ProgramAst.ExpressionNode
	if _peek().kind == ProgramLexer.Kind.IDENTIFIER and _peek().lexeme == "step":
		_advance()
		_skip_newlines()
		increment = _parse_expression()
		if increment == null:
			return null
	else:
		var one := ProgramAst.NumberNode.new()
		one.line = token.line
		one.column = token.column
		one.value = 1.0
		one.literal = "1"
		increment = one
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "for 区间后需要右括号 ')'。") == null:
		return null
	_skip_newlines()
	var body := _parse_block(control_depth + 1)
	if body == null:
		return null
	if body.statements.is_empty():
		_fail(token, "for 代码块不能为空；请至少添加一条语句。")
		return null
	var loop := ProgramAst.ForNode.new()
	loop.line = token.line
	loop.column = token.column
	loop.iterator = name.lexeme
	loop.start = first
	loop.end = last
	loop.step = increment
	loop.body = body
	return loop


## 条件支持已解锁的 ready 或数值比较；省略 else 时假分支直接继续后续语句。
func _parse_if(control_depth: int) -> ProgramAst.IfNode:
	var token := _peek()
	if not _allow_conditionals:
		_fail(token, "本关尚未解锁 if / else 条件分支。")
		return null
	if control_depth >= MAX_CONTROL_DEPTH:
		_fail(token, "loop / if 控制结构嵌套最多允许 %d 层。" % MAX_CONTROL_DEPTH)
		return null
	_advance()
	_skip_newlines()
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "if 后需要条件括号，例如 if (gun.ready())。") == null:
		return null
	_skip_newlines()
	var condition := _parse_condition()
	if condition == null:
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "条件后需要关闭 if 的右括号 ')'。") == null:
		return null
	_skip_newlines()
	var then_body := _parse_block(control_depth + 1)
	if then_body == null:
		return null
	if then_body.statements.is_empty():
		_fail(token, "if 与显式 else 代码块都不能为空；请添加至少一条语句。")
		return null
	# 只为寻找可选 else 暂看换行；省略时恢复分隔符，仍要求后续语句另起一行。
	var after_then := _index
	_skip_newlines()
	var else_token := _peek()
	var else_body := ProgramAst.BlockNode.new()
	else_body.line = token.line
	else_body.column = token.column
	if else_token.kind == ProgramLexer.Kind.IDENTIFIER and else_token.lexeme == "else":
		_advance()
		_skip_newlines()
		else_body = _parse_block(control_depth + 1)
		if else_body == null:
			return null
		if else_body.statements.is_empty():
			_fail(else_token, "if 与显式 else 代码块都不能为空；请添加至少一条语句。")
			return null
	else:
		_index = after_then
	var branch := ProgramAst.IfNode.new()
	branch.line = token.line
	branch.column = token.column
	branch.condition = condition
	branch.then_body = then_body
	branch.else_body = else_body
	return branch


## 冷却条件有独立语法节点，只接受一个命名模块及无参 ready()，不引入通用表达式。
func _parse_ready_condition() -> ProgramAst.ReadyNode:
	if not _allow_named_calls:
		_fail(_peek(), "ready() 需要命名模块调用权限；本关尚未解锁。")
		return null
	var receiver := _expect(ProgramLexer.Kind.IDENTIFIER, "条件需要命名射击模块的 ready()，例如 gun.ready()。")
	if receiver == null:
		return null
	if not is_receiver_name(receiver.lexeme):
		_fail(receiver, "模块名必须是非保留的英文标识符，最多 128 个字符。")
		return null
	if _expect(ProgramLexer.Kind.DOT, "ready() 必须指定模块名，例如 gun.ready()。") == null:
		return null
	var name := _expect(ProgramLexer.Kind.IDENTIFIER, "条件需要 ready() 冷却查询。")
	if name == null:
		return null
	if name.lexeme != "ready":
		_fail(name, "当前条件只支持 模块名.ready()，不能使用动作或其它属性。")
		return null
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "ready 后需要空括号 '()'。") == null:
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "ready() 不接受参数。") == null:
		return null
	var condition := ProgramAst.ReadyNode.new()
	condition.line = receiver.line
	condition.column = receiver.column
	condition.receiver = receiver.lexeme
	return condition


## 解析直接或命名调用；成员点只连接一层实例名与能力名，不引入任意属性访问。
func _parse_call(simultaneous_body: bool = false) -> ProgramAst.StatementNode:
	var name := _expect(ProgramLexer.Kind.IDENTIFIER, "代码块内需要已解锁的指令调用。")
	if name == null:
		return null
	var call_start := name
	if _peek().kind == ProgramLexer.Kind.RANGE:
		_fail(_peek(), "模块名后的点号需要指令名，例如 left.attack(180)。")
		return null
	var receiver := ""
	if _peek().kind == ProgramLexer.Kind.DOT:
		if not _allow_named_calls:
			_fail(_peek(), "命名模块调用尚未解锁；本关请直接使用已解锁的指令。")
			return null
		if not is_receiver_name(name.lexeme):
			_fail(name, "模块名必须是非保留的英文标识符，最多 128 个字符。")
			return null
		receiver = name.lexeme
		_advance()
		name = _expect(ProgramLexer.Kind.IDENTIFIER, "模块名后的点号需要指令名，例如 left.attack(180)。")
		if name == null:
			return null
		if _peek().kind == ProgramLexer.Kind.DOT:
			_fail(_peek(), "命名调用只支持 模块名.指令(...)，不支持连续属性访问。")
			return null
	if not CALL_ARITIES.has(name.lexeme) and receiver.is_empty() and _allow_functions:
		if not ProgramFunctionValidation.is_function_name(name.lexeme):
			_fail(name, "这里需要已解锁的动作或非保留的函数名称。")
			return null
		if _function_name == "tick" or simultaneous_body:
			_fail(name, "tick() 和 simultaneously 块内只接受有限动作，不能调用用户函数。")
			return null
		if _expect(ProgramLexer.Kind.LEFT_PAREN, "函数名后需要空括号 '()'。") == null:
			return null
		_skip_newlines()
		if _expect(ProgramLexer.Kind.RIGHT_PAREN, "用户函数不接受参数，需要空括号 '()'。") == null:
			return null
		var user_call := ProgramAst.UserCallNode.new()
		user_call.line = name.line
		user_call.column = name.column
		user_call.callee = name.lexeme
		return user_call
	if not CALL_ARITIES.has(name.lexeme):
		_fail(name, "未知或尚未实现的指令“%s”。" % name.lexeme)
		return null
	if not _allowed_calls.has(name.lexeme):
		_fail(name, "本关尚未解锁指令“%s”。" % name.lexeme)
		return null
	if _function_name == "tick" and name.lexeme not in ["shoot", "attack"]:
		_fail(name, "tick() 每次执行必须立即结束；当前只支持 shoot(角度) 和 attack(角度)。")
		return null
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "指令名后需要左括号 '('.") == null:
		return null
	var call := ProgramAst.CallNode.new()
	call.line = call_start.line
	call.column = call_start.column
	call.callee = name.lexeme
	call.receiver = receiver
	_skip_newlines()
	while _peek().kind != ProgramLexer.Kind.RIGHT_PAREN:
		var number: ProgramAst.ExpressionNode = _parse_expression() if (_allow_distance or _allow_variables or _allow_radar or _allow_random or _allow_for) else _parse_number()
		if number == null:
			return null
		call.arguments.append(number)
		_skip_newlines()
		if _peek().kind != ProgramLexer.Kind.COMMA:
			break
		_advance()
		_skip_newlines()
		if _peek().kind == ProgramLexer.Kind.RIGHT_PAREN:
			_fail(_peek(), "逗号后缺少数字参数。")
			return null
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "参数后需要右括号 ')'；本关参数只接受数字字面量。") == null:
		return null
	if call.arguments.size() != int(CALL_ARITIES[name.lexeme]):
		_fail(name, "%s 需要 %d 个参数。" % [name.lexeme, CALL_ARITIES[name.lexeme]])
		return null
	return call


## 声明与赋值是明确的语句；tick 与原子并行块不接收状态修改。
func _parse_binding(declaration: bool, simultaneous_body: bool) -> ProgramAst.StatementNode:
	var start := _peek()
	if not _allow_variables:
		_fail(start, "本关尚未解锁常量、变量与赋值。")
		return null
	if _function_name == "tick" or simultaneous_body:
		_fail(start, "tick() 和 simultaneously 块内不能声明或修改变量。")
		return null
	var mutable := start.lexeme == "variable"
	if declaration:
		_advance()
	var name := _expect(ProgramLexer.Kind.IDENTIFIER, "声明或赋值需要有效的名称。")
	if name == null:
		return null
	if not ProgramVariableValidation.is_binding_name(name.lexeme):
		_fail(name, "数值名称必须是非保留的英文标识符。")
		return null
	if _expect(ProgramLexer.Kind.ASSIGN, "名称后需要赋值符号 '='。") == null:
		return null
	_skip_newlines()
	var expression := _parse_expression()
	if expression == null:
		return null
	if declaration:
		var binding := ProgramAst.DeclarationNode.new()
		binding.line = start.line
		binding.column = start.column
		binding.name = name.lexeme
		binding.mutable = mutable
		binding.initializer = expression
		return binding
	var assignment := ProgramAst.AssignmentNode.new()
	assignment.line = name.line
	assignment.column = name.column
	assignment.name = name.lexeme
	assignment.expression = expression
	return assignment


## ready 沿用旧语义，数值比较接受已解锁的测距或变量表达式。
func _parse_condition() -> ProgramAst.ConditionNode:
	var named_ready := _index + 2 < _tokens.size() and _tokens[_index + 1].kind == ProgramLexer.Kind.DOT and _tokens[_index + 2].lexeme == "ready"
	if named_ready or not (_allow_distance or _allow_variables or _allow_radar or _allow_random or _allow_for):
		return _parse_ready_condition()
	var start := _peek()
	var left := _parse_expression()
	if left == null:
		return null
	_skip_newlines()
	var operator := _peek()
	if operator.lexeme not in COMPARISONS:
		_fail(operator, "数值条件需要 <、<=、>、>=、== 或 != 比较。")
		return null
	_advance()
	_skip_newlines()
	var right := _parse_expression()
	if right == null:
		return null
	var condition := ProgramAst.ComparisonNode.new()
	condition.line = start.line
	condition.column = start.column
	condition.operator = operator.lexeme
	condition.left = left
	condition.right = right
	return condition


## 加减按从左到右求值，递归深度与总节点预算同时限制外部输入。
func _parse_expression(depth: int = 0) -> ProgramAst.ExpressionNode:
	var left := _parse_primary(depth)
	if left == null:
		return null
	var operators := 0
	while _peek().kind in [ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS]:
		var operator := _peek()
		operators += 1
		if not _reserve_expression(operator, depth + operators):
			return null
		_advance()
		_skip_newlines()
		var right := _parse_primary(depth + operators)
		if right == null:
			return null
		var binary := ProgramAst.BinaryNode.new()
		binary.line = operator.line
		binary.column = operator.column
		binary.operator = operator.lexeme
		binary.left = left
		binary.right = right
		left = binary
	return left


## 成员链只读取固定的雷达结果及坐标字段；深度与节点数共享表达式预算。
func _parse_primary(depth: int) -> ProgramAst.ExpressionNode:
	var value := _parse_atom(depth)
	if value == null:
		return null
	var members := 0
	while _peek().kind == ProgramLexer.Kind.DOT:
		var dot := _peek()
		if not _allow_radar:
			_fail(dot, "本关尚未解锁 scan 雷达查询与目标属性。")
			return null
		members += 1
		if not _reserve_expression(dot, depth + members):
			return null
		_advance()
		var name := _expect(ProgramLexer.Kind.IDENTIFIER, "雷达目标仅支持 Angle()、Position、Distance 与坐标 x/y。")
		if name == null:
			return null
		if name.lexeme not in ["Angle", "Position", "Distance", "x", "y"]:
			_fail(name, "雷达目标仅支持 Angle()、Position、Distance 与坐标 x/y。")
			return null
		if name.lexeme == "Angle" or (name.lexeme == "Distance" and _peek().kind == ProgramLexer.Kind.LEFT_PAREN):
			if _expect(ProgramLexer.Kind.LEFT_PAREN, "Angle 需要空括号 '()'。") == null:
				return null
			_skip_newlines()
			if _expect(ProgramLexer.Kind.RIGHT_PAREN, "雷达目标查询不接受参数。") == null:
				return null
		elif _peek().kind == ProgramLexer.Kind.LEFT_PAREN:
			_fail(_peek(), "Position 和坐标 x/y 是只读属性，不接受函数括号。")
			return null
		var member := ProgramAst.TargetMemberNode.new()
		member.line = name.line
		member.column = name.column
		member.target = value
		member.member = name.lexeme
		value = member
	return value


## 数字、括号、名称、雷达和测距均生成显式节点，不执行用户代码或动态属性。
func _parse_atom(depth: int) -> ProgramAst.ExpressionNode:
	var token := _peek()
	if not _reserve_expression(token, depth):
		return null
	if token.kind == ProgramLexer.Kind.NUMBER or (token.kind in [ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS] and _tokens[mini(_index + 1, _tokens.size() - 1)].kind == ProgramLexer.Kind.NUMBER):
		return _parse_number()
	if token.kind in [ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS]:
		_advance()
		var child := _parse_primary(depth + 1)
		if child == null:
			return null
		if token.kind == ProgramLexer.Kind.PLUS:
			# 单目正号仍经过数值运算节点校验，不能把目标快照当数字返回。
			var positive := ProgramAst.BinaryNode.new()
			positive.line = token.line
			positive.column = token.column
			positive.operator = "+"
			positive.left = ProgramAst.NumberNode.new()
			positive.right = child
			return positive
		var zero := ProgramAst.NumberNode.new()
		zero.line = token.line
		zero.column = token.column
		var negative := ProgramAst.BinaryNode.new()
		negative.line = token.line
		negative.column = token.column
		negative.operator = "-"
		negative.left = zero
		negative.right = child
		return negative
	if token.kind == ProgramLexer.Kind.LEFT_PAREN:
		_advance()
		_skip_newlines()
		var inner := _parse_expression(depth + 1)
		if inner == null:
			return null
		_skip_newlines()
		if _expect(ProgramLexer.Kind.RIGHT_PAREN, "数值表达式缺少右括号 ')'。") == null:
			return null
		return inner
	var name := _expect(ProgramLexer.Kind.IDENTIFIER, "这里需要数字、已声明名称或已解锁查询。")
	if name == null:
		return null
	if name.lexeme in ["random", "randomInt"] and _peek().kind != ProgramLexer.Kind.DOT:
		return _parse_random(name, depth)
	if name.lexeme in ["null", "Null"]:
		if not _allow_radar:
			_fail(name, "本关尚未解锁 scan 雷达查询与无目标值 null。")
			return null
		var empty := ProgramAst.NullNode.new()
		empty.line = name.line
		empty.column = name.column
		return empty
	var receiver := ""
	var named_query := _peek().kind == ProgramLexer.Kind.DOT and _index + 1 < _tokens.size() and _tokens[_index + 1].lexeme in ["distance", "scan"]
	if named_query:
		if not _allow_named_calls:
			_fail(name, "命名模块调用尚未解锁；本关请直接使用已解锁的指令。")
			return null
		if not is_receiver_name(name.lexeme):
			_fail(name, "查询模块名必须是有效的英文标识符。")
			return null
		receiver = name.lexeme
		_advance()
		name = _expect(ProgramLexer.Kind.IDENTIFIER, "模块名后需要已解锁的查询。")
		if name == null:
			return null
	elif (_allow_variables or _allow_for) and _peek().kind != ProgramLexer.Kind.LEFT_PAREN:
		if not ProgramVariableValidation.is_binding_name(name.lexeme):
			_fail(name, "数值名称必须是非保留的英文标识符。")
			return null
		var reference := ProgramAst.NameNode.new()
		reference.name = name.lexeme
		reference.line = name.line
		reference.column = name.column
		return reference
	if name.lexeme == "scan":
		if not _allow_radar:
			_fail(name, "本关尚未解锁 scan 雷达查询。")
			return null
		if _expect(ProgramLexer.Kind.LEFT_PAREN, "scan 后需要空括号 '()'。") == null:
			return null
		_skip_newlines()
		if _expect(ProgramLexer.Kind.RIGHT_PAREN, "scan() 不接受参数。") == null:
			return null
		var scan := ProgramAst.ScanNode.new()
		scan.line = token.line
		scan.column = token.column
		scan.receiver = receiver
		return scan
	if name.lexeme == "distance" and not _allow_distance:
		_fail(name, "本关尚未解锁 distance 测距查询。")
		return null
	if name.lexeme != "distance":
		_fail(name, "表达式只支持已声明名称、distance 或 scan 查询，不能使用动作调用。")
		return null
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "distance 后需要角度括号。") == null:
		return null
	_skip_newlines()
	var angle := _parse_expression(depth + 1)
	if angle == null:
		return null
	_skip_newlines()
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "distance 只接受一个角度参数，随后需要右括号 ')'。") == null:
		return null
	var query := ProgramAst.DistanceNode.new()
	query.line = token.line
	query.column = token.column
	query.receiver = receiver
	query.angle = angle
	return query


## 随机函数使用独立权限和固定参数数量；参数保留表达式，解析时绝不取随机值。
func _parse_random(name: ProgramLexer.Token, depth: int) -> ProgramAst.RandomNode:
	if not _allow_random:
		_fail(name, "本关尚未解锁 random() 与 randomInt(a, b) 随机函数。")
		return null
	if _expect(ProgramLexer.Kind.LEFT_PAREN, "随机函数名后需要参数括号。") == null:
		return null
	var query := ProgramAst.RandomNode.new()
	query.line = name.line
	query.column = name.column
	query.callee = name.lexeme
	var arity := 0 if name.lexeme == "random" else 2
	_skip_newlines()
	while _peek().kind != ProgramLexer.Kind.RIGHT_PAREN:
		if query.arguments.size() >= arity:
			_fail(_peek(), "%s 需要 %d 个参数。" % [name.lexeme, arity])
			return null
		var argument := _parse_expression(depth + 1)
		if argument == null:
			return null
		query.arguments.append(argument)
		_skip_newlines()
		if _peek().kind != ProgramLexer.Kind.COMMA:
			break
		_advance()
		_skip_newlines()
		if _peek().kind == ProgramLexer.Kind.RIGHT_PAREN:
			_fail(_peek(), "逗号后缺少随机函数参数。")
			return null
	if _expect(ProgramLexer.Kind.RIGHT_PAREN, "随机函数参数后需要右括号 ')'。") == null:
		return null
	if query.arguments.size() != arity:
		_fail(name, "%s 需要 %d 个参数。" % [name.lexeme, arity])
		return null
	return query


## 每个表达式节点共享程序预算，长链和深括号都不能无限占用解析栈。
func _reserve_expression(token: ProgramLexer.Token, depth: int) -> bool:
	_expression_count += 1
	if depth >= MAX_EXPRESSION_DEPTH or _expression_count > MAX_EXPRESSION_NODES:
		_fail(token, "数值表达式超过深度或节点数量限制。")
		return false
	return true


## 与现有装配标识符约定一致；仅限制代码引用，不重写或迁移已有 JSON 实例名。
static func is_receiver_name(value: String) -> bool:
	if value.is_empty() or value.length() > 128 or value in LOCKED_SYNTAX or value in ["main", "move", "true", "false", "null", "Null"]:
		return false
	if not ProgramLexer._is_identifier_start(value[0]):
		return false
	for character in value:
		if not ProgramLexer._is_identifier_start(character) and not ProgramLexer._is_digit(character):
			return false
	return true


## 解析带可选正负号的数值，不执行表达式或隐式变量查找。
func _parse_number() -> ProgramAst.NumberNode:
	var start := _peek()
	if start.kind == ProgramLexer.Kind.IDENTIFIER and start.lexeme in ["random", "randomInt"]:
		_fail(start, "本关尚未解锁 random() 与 randomInt(a, b) 随机函数。")
		return null
	var sign := ""
	if start.kind in [ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS]:
		sign = start.lexeme
		_advance()
	var token := _expect(ProgramLexer.Kind.NUMBER, "这里需要数字字面量；变量和表达式尚未解锁。")
	if token == null:
		return null
	var number := ProgramAst.NumberNode.new()
	number.line = start.line
	number.column = start.column
	number.literal = sign + token.lexeme
	number.value = number.literal.to_float()
	return number


## 检查并消费指定 token；统一识别分号与尚未解锁的语法关键字。
func _expect(kind: ProgramLexer.Kind, reason: String) -> ProgramLexer.Token:
	var token := _peek()
	if token.kind == ProgramLexer.Kind.SEMICOLON or (token.kind == ProgramLexer.Kind.IDENTIFIER and token.lexeme in LOCKED_SYNTAX):
		_fail(token, reason)
		return null
	if token.kind != kind:
		_fail(token, reason)
		return null
	_advance()
	return token


## 保存首个带行列的错误，后续失败不会覆盖最接近原因的位置。
func _fail(token: ProgramLexer.Token, reason: String) -> void:
	if not _error.is_empty():
		return
	if token.kind == ProgramLexer.Kind.SEMICOLON:
		reason = "本关不允许分号；请使用换行分隔语句。"
	elif token.kind == ProgramLexer.Kind.IDENTIFIER and token.lexeme in LOCKED_SYNTAX and not (token.lexeme == "for" and _allow_for) and not (token.lexeme == "loop" and _allow_loops) and not (token.lexeme in ["if", "else"] and _allow_conditionals) and not (token.lexeme == "simultaneously" and _allow_simultaneous) and not (token.lexeme == "function" and _allow_functions) and not (token.lexeme in ["constant", "variable", "value"] and _allow_variables):
		reason = "本关尚未解锁“%s”语法。" % token.lexeme
	_error = "第 %d 行，第 %d 列：%s" % [token.line, token.column, reason]


## 跳过允许出现空行的位置，但不掩盖代码块中的语句分隔要求。
func _skip_newlines() -> void:
	while _peek().kind == ProgramLexer.Kind.NEWLINE:
		_advance()


## 查看当前 token；词法分析器始终提供结束标记。
func _peek() -> ProgramLexer.Token:
	return _tokens[_index]


## 前进一个 token，并将游标限制在结束标记处。
func _advance() -> void:
	if _index < _tokens.size() - 1:
		_index += 1
