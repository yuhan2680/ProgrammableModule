class_name ProgramCompletion
extends RefCounted
## 只读的行内补全策略：复用语言词法与关卡权限，不修改代码或执行模拟。

const ACTION_BEHAVIORS: Dictionary = {
	"move": "MovementModule", "attack": "MeleeModule", "shoot": "ShootingModule",
}


## 返回光标后可以接受的标识符后缀；行列均沿用 CodeEdit 的零起点字符位置。
static func suggest(source: String, line: int, column: int, level: LevelDefinition, assembly: AssemblyModel) -> String:
	if level == null or source.to_utf8_buffer().size() > ProgramLexer.MAX_SOURCE_BYTES:
		return ""
	var lines := source.split("\n")
	if line < 0 or line >= lines.size() or column < 1 or column > lines[line].length():
		return ""
	var current: String = lines[line]
	if column < current.length() and _is_identifier_part(current[column]):
		return ""
	var start := column
	while start > 0 and _is_identifier_part(current[start - 1]):
		start -= 1
	var prefix := current.substr(start, column - start)
	if prefix.is_empty() or not ProgramLexer._is_identifier_start(prefix[0]):
		return ""
	var offset := column
	for previous in range(line):
		offset += lines[previous].length() + 1
	var lexed := ProgramLexer.tokenize(source.left(offset))
	if not lexed.is_ok():
		return ""
	var tokens: Array[ProgramLexer.Token] = lexed.value
	tokens.pop_back() # END 不参与当前补全位置判断。
	if tokens.is_empty():
		return ""
	var word: ProgramLexer.Token = tokens.pop_back()
	# 注释会被词法器整体跳过；精确位置检查也阻止沿用上一行的单词。
	if word.kind != ProgramLexer.Kind.IDENTIFIER or word.lexeme != prefix or word.line != line + 1 or word.column != start + 1:
		return ""
	var receiver_result := _read_receiver(tokens, level, assembly)
	if not receiver_result.is_ok():
		return ""
	var receiver: String = receiver_result.value
	var context := _read_context(tokens, level, assembly)
	if context.is_empty():
		return ""
	context["event_globals"] = _binding_scopes(tokens)[0] if context.kind == "event_target" else {}
	context["functions"] = _function_declarations(source) if level.allow_functions else {}
	context["bindings"] = _visible_bindings(source, tokens, str(context.get("function", "")), level.allow_variables, level.allow_for) if level.allow_variables or level.allow_for else {}
	context["radar_bindings"] = _visible_radar_bindings(source, tokens, str(context.get("function", "")), level, assembly) if level.allow_variables and level.allow_radar else {}
	var candidates := _candidates(context, receiver, level, assembly)
	# 完整单词保持原样；固定顺序保证同样的输入不会随机改变候选。
	if prefix in candidates:
		return ""
	for candidate in candidates:
		if candidate.begins_with(prefix):
			return candidate.substr(prefix.length())
	return ""


## 从光标向前读取成员来源；仅识别具名绑定或零参数 scan，不接纳任意函数返回值。
static func _read_receiver(tokens: Array[ProgramLexer.Token], level: LevelDefinition, assembly: AssemblyModel) -> DataResult:
	var parts := PackedStringArray()
	while not tokens.is_empty() and tokens.back().kind == ProgramLexer.Kind.DOT:
		tokens.pop_back()
		if tokens.is_empty():
			return DataResult.failure("不完整的成员来源。")
		if tokens.back().kind == ProgramLexer.Kind.IDENTIFIER:
			parts.insert(0, tokens.pop_back().lexeme)
			continue
		if tokens.size() < 3 or tokens.back().kind != ProgramLexer.Kind.RIGHT_PAREN or tokens[tokens.size() - 2].kind != ProgramLexer.Kind.LEFT_PAREN or tokens[tokens.size() - 3].lexeme != "scan":
			return DataResult.failure("成员来源不是扫描结果。")
		for unused in range(3):
			tokens.pop_back()
		var module_name := ""
		if not tokens.is_empty() and tokens.back().kind == ProgramLexer.Kind.DOT:
			tokens.pop_back()
			if tokens.is_empty() or tokens.back().kind != ProgramLexer.Kind.IDENTIFIER:
				return DataResult.failure("扫描模块名称不完整。")
			module_name = tokens.pop_back().lexeme
		if not level.allow_radar:
			return DataResult.failure("雷达查询尚未开放。")
		if module_name.is_empty():
			if _radar_count(level, assembly) != 1:
				return DataResult.failure("扫描需要唯一的雷达来源。")
		elif not level.allow_named_calls or _receiver_behavior(module_name, level, assembly) != "RadarModule":
			return DataResult.failure("扫描模块不可用。")
		# @ 不属于 DSL 标识符，内部标记不会与玩家绑定名混淆。
		parts.insert(0, "@scan" if module_name.is_empty() else "@scan:" + module_name)
	return DataResult.success(".".join(parts))


## 跟踪未闭合的括号和块，允许正在输入的半成品，而不要求整个程序能编译。
static func _read_context(tokens: Array[ProgramLexer.Token], level: LevelDefinition, assembly: AssemblyModel) -> Dictionary:
	var stack: Array[Dictionary] = []
	var declared := PackedStringArray()
	var previous: ProgramLexer.Token = null
	var closed_paren := ""
	var closed_declaration := false
	var closed_block := ""
	for index in range(tokens.size()):
		var token: ProgramLexer.Token = tokens[index]
		if token.kind == ProgramLexer.Kind.NEWLINE:
			continue
		match token.kind:
			ProgramLexer.Kind.LEFT_PAREN:
				var owner := previous.lexeme if previous != null and previous.kind == ProgramLexer.Kind.IDENTIFIER else "("
				stack.append({"brace": false, "owner": owner, "index": index, "declaration": stack.is_empty() and _declaration_name(tokens, index) == owner})
			ProgramLexer.Kind.RIGHT_PAREN:
				if stack.is_empty() or stack.back().brace:
					return {}
				var closed: Dictionary = stack.pop_back()
				closed_paren = closed.owner
				closed_declaration = closed.declaration
			ProgramLexer.Kind.LEFT_BRACE:
				var owner := ""
				if previous != null and previous.kind == ProgramLexer.Kind.RIGHT_PAREN:
					owner = "@function:" + closed_paren if closed_declaration else closed_paren
				elif previous != null and previous.kind == ProgramLexer.Kind.IDENTIFIER:
					owner = previous.lexeme
					if owner == "onDetected" and stack.is_empty():
						var radar_name := _event_receiver(tokens, index, level, assembly)
						if not radar_name.is_empty():
							owner = "@radar:" + radar_name
				if not _block_allowed(owner, stack, level):
					return {}
				if owner in ["main", "tick"]:
					declared.append(owner)
				stack.append({"brace": true, "owner": owner, "index": index})
			ProgramLexer.Kind.RIGHT_BRACE:
				if stack.is_empty() or not stack.back().brace:
					return {}
				closed_block = stack.pop_back().owner
		if token.kind != ProgramLexer.Kind.RIGHT_BRACE:
			closed_block = ""
		previous = token
	var function_name := ""
	var parallel := false
	var parentheses: Array[Dictionary] = []
	for frame in stack:
		if frame.brace:
			if frame.owner in ["main", "tick"]:
				function_name = frame.owner
			elif str(frame.owner).begins_with("@function:"):
				function_name = str(frame.owner).trim_prefix("@function:")
			if frame.owner == "simultaneously":
				parallel = true
		else:
			parentheses.append(frame)
	if stack.size() == 1 and str(stack[0].owner).begins_with("@radar:"):
		return _event_body_context(tokens, stack[0].index)
	var binding_context := _binding_expression_context(tokens, function_name, parallel, level)
	if not binding_context.is_empty():
		return binding_context
	if not parentheses.is_empty():
		return _for_header_context(tokens, parentheses, function_name, parallel, level) if parentheses.front().owner == "for" else _expression_context(tokens, parentheses, function_name, level)
	var starts_statement: bool = tokens.is_empty() or tokens.back().kind in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.LEFT_BRACE]
	if closed_block == "if" and level.allow_conditionals and not starts_statement:
		return {"kind": "else", "function": function_name}
	if not starts_statement:
		return {}
	return {"kind": "entry" if stack.is_empty() else "statement", "function": function_name, "parallel": parallel, "declared": declared, "following_if": closed_block == "if" and level.allow_conditionals}


## 阻止回调中的等待块、并行嵌套和手工输入的未解锁代码块产生误导候选。
static func _block_allowed(owner: String, stack: Array[Dictionary], level: LevelDefinition) -> bool:
	if stack.is_empty():
		return owner == "main" or (owner == "tick" and level.allow_tick) or (owner.begins_with("@function:") and level.allow_functions) or (owner.begins_with("@radar:") and _radar_events_allowed(level))
	var in_tick := false
	for frame in stack:
		if not frame.brace or frame.owner == "simultaneously" or str(frame.owner).begins_with("@radar:"):
			return false
		in_tick = in_tick or frame.owner == "tick"
	match owner:
		"if", "else":
			return level.allow_conditionals
		"loop":
			return level.allow_loops and not in_tick
		"for":
			return level.allow_for and not in_tick
		"simultaneously":
			return level.allow_simultaneous and not in_tick
	return false


## 数值补全只在等待一个操作数的位置出现；ready 只占据完整 if 条件的开头。
static func _expression_context(tokens: Array[ProgramLexer.Token], parentheses: Array[Dictionary], function_name: String, level: LevelDefinition) -> Dictionary:
	if function_name.is_empty():
		return {}
	var outer: Dictionary = parentheses.front()
	var owner: String = outer.owner
	if owner == "if":
		if not level.allow_conditionals:
			return {}
	elif owner not in level.allowed_calls or not ProgramParser.CALL_ARITIES.has(owner) or (function_name == "tick" and owner == "move"):
		return {}
	for index in range(1, parentheses.size()):
		var frame: Dictionary = parentheses[index]
		if not _numeric_operand_allowed(tokens, frame.index, frame.owner, level):
			return {}
	var previous: ProgramLexer.Token = null
	for index in range(tokens.size() - 1, -1, -1):
		if tokens[index].kind != ProgramLexer.Kind.NEWLINE:
			previous = tokens[index]
			break
	if previous == null or previous.kind not in [ProgramLexer.Kind.LEFT_PAREN, ProgramLexer.Kind.COMMA, ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS, ProgramLexer.Kind.LESS, ProgramLexer.Kind.LESS_EQUAL, ProgramLexer.Kind.GREATER, ProgramLexer.Kind.GREATER_EQUAL, ProgramLexer.Kind.EQUAL, ProgramLexer.Kind.NOT_EQUAL]:
		return {}
	var ready_allowed: bool = owner == "if" and parentheses.size() == 1 and previous == tokens[outer.index]
	return {"kind": "expression", "function": function_name, "ready": ready_allowed, "radar_value": owner == "if", "null_value": owner == "if" and previous.kind in [ProgramLexer.Kind.EQUAL, ProgramLexer.Kind.NOT_EQUAL]}


## for 头按范围边界区分 in、step 与数值输入，不向回调或并行块泄露新语法。
static func _for_header_context(tokens: Array[ProgramLexer.Token], parentheses: Array[Dictionary], function_name: String, parallel: bool, level: LevelDefinition) -> Dictionary:
	if not level.allow_for or function_name.is_empty() or function_name == "tick" or parallel:
		return {}
	var start: int = parentheses.front().index + 1
	var header: Array[ProgramLexer.Token] = []
	for index in range(start, tokens.size()):
		if tokens[index].kind != ProgramLexer.Kind.NEWLINE:
			header.append(tokens[index])
	if header.is_empty() or not ProgramVariableValidation.is_binding_name(header[0].lexeme):
		return {}
	if header.size() == 1:
		return {"kind": "for_in", "function": function_name}
	if header[1].lexeme != "in":
		return {}
	var range_index := -1
	var step_index := -1
	var depth := 0
	for index in range(2, header.size()):
		var token: ProgramLexer.Token = header[index]
		if token.kind == ProgramLexer.Kind.LEFT_PAREN:
			depth += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_PAREN:
			depth -= 1
		elif depth == 0 and token.lexeme == "..":
			if range_index >= 0:
				return {}
			range_index = index
		elif depth == 0 and token.lexeme == "step" and range_index >= 0 and index > range_index + 1 and _ends_numeric_operand(header[index - 1]):
			step_index = index
			break
	for index in range(1, parentheses.size()):
		var frame: Dictionary = parentheses[index]
		if not _numeric_operand_allowed(tokens, frame.index, frame.owner, level):
			return {}
	var previous: ProgramLexer.Token = header.back()
	var awaiting_value := header.size() == 2 or previous.lexeme == ".." or step_index == header.size() - 1 or previous.kind in [ProgramLexer.Kind.LEFT_PAREN, ProgramLexer.Kind.COMMA, ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS]
	if awaiting_value:
		return {"kind": "expression", "function": function_name, "ready": false, "radar_value": false}
	if range_index >= 0 and step_index < 0 and parentheses.size() == 1 and _ends_numeric_operand(previous):
		return {"kind": "for_step", "function": function_name}
	return {}


## 只识别已经结束的数值项，以免把加减号后的 step 变量误认成步长关键字。
static func _ends_numeric_operand(token: ProgramLexer.Token) -> bool:
	return token.kind in [ProgramLexer.Kind.NUMBER, ProgramLexer.Kind.IDENTIFIER, ProgramLexer.Kind.RIGHT_PAREN]


## 关卡控制可用语言；具体实例能力仅由本次装配引用的真实注册表定义提供。
static func _candidates(context: Dictionary, receiver: String, level: LevelDefinition, assembly: AssemblyModel) -> PackedStringArray:
	var candidates := PackedStringArray()
	var kind: String = context.kind
	if kind == "entry":
		if receiver.is_empty():
			if not "main" in context.declared:
				candidates.append("main")
			if level.allow_tick and not "tick" in context.declared:
				candidates.append("tick")
			if level.allow_functions:
				candidates.append("function")
			if level.allow_variables:
				candidates.append_array(PackedStringArray(["constant", "variable", "value"]))
			if _radar_events_allowed(level) and assembly != null:
				var names := PackedStringArray()
				for instance in assembly.modules:
					if instance is Dictionary and instance.get("id") is String and _receiver_behavior(instance.id, level, assembly) == "RadarModule":
						names.append(instance.id)
				names.sort()
				candidates.append_array(names)
		elif _radar_events_allowed(level) and _receiver_behavior(receiver, level, assembly) == "RadarModule":
			candidates.append("onDetected")
		return candidates
	if kind in ["event_payload", "event_target"]:
		if not receiver.is_empty() or not _radar_events_allowed(level):
			return candidates
		if kind == "event_payload":
			return PackedStringArray(["EnemyPosition"])
		var globals: Dictionary = context.get("event_globals", {})
		var names: Array = globals.keys()
		names.sort()
		for name: String in names:
			if bool(globals[name]):
				candidates.append(name)
		return candidates
	if kind == "else":
		return PackedStringArray(["else"]) if receiver.is_empty() else candidates
	if kind in ["for_in", "for_step"]:
		return PackedStringArray(["in" if kind == "for_in" else "step"]) if receiver.is_empty() else candidates
	var bindings: Dictionary = context.get("bindings", {})
	if context.get("binding_assignment", false):
		var target: String = context.get("binding_target", "")
		if not bindings.has(target) or not bool(bindings[target]):
			return candidates
	var methods := PackedStringArray()
	if kind == "expression":
		if level.allow_radar and context.get("radar_value", false) and _has_radar(level, assembly):
			methods.append("scan")
		if level.allow_distance:
			methods.append("distance")
		if context.ready and level.allow_named_calls and level.allow_conditionals:
			methods.append("ready")
	else:
		for action in ProgramParser.CALL_ARITIES:
			if action in level.allowed_calls and not (context.function == "tick" and action == "move"):
				methods.append(action)
	if not receiver.is_empty():
		if kind == "expression" and level.allow_radar:
			var parts := receiver.split(".")
			var direct_scan := str(parts[0]).begins_with("@scan")
			var value_types: Dictionary = context.get("radar_bindings", {})
			var value_type: String = "snapshot" if direct_scan else value_types.get(parts[0], "")
			if direct_scan or (level.allow_variables and bindings.has(parts[0])):
				if parts.size() == 1 and value_type == "snapshot":
					candidates.append_array(PackedStringArray(["Angle", "Position", "Distance"]))
				if (parts.size() == 1 and value_type == "vector") or (parts.size() == 2 and value_type == "snapshot" and parts[1] == "Position"):
					candidates.append_array(PackedStringArray(["x", "y"]))
				if parts.size() > 1:
					return candidates
		if not level.allow_named_calls or not ProgramParser.is_receiver_name(receiver):
			return candidates
		var behavior := _receiver_behavior(receiver, level, assembly)
		for method in methods:
			if _supports_method(behavior, method):
				candidates.append(method)
		return candidates
	for method in methods:
		if method != "ready" and (method != "scan" or _radar_count(level, assembly) == 1):
			candidates.append(method)
	# 随机数是独立数值函数，不属于任何模块，也不能被补成单独动作。
	if kind == "expression" and level.allow_random:
		candidates.append_array(PackedStringArray(["random", "randomInt"]))
	if kind == "expression" and level.allow_radar and context.get("null_value", false):
		candidates.append_array(PackedStringArray(["null", "Null"]))
	if kind == "statement" and not context.parallel:
		if context.get("following_if", false):
			candidates.append("else")
		if level.allow_loops and context.function != "tick":
			candidates.append("loop")
		if level.allow_for and context.function != "tick":
			candidates.append("for")
		if level.allow_conditionals:
			candidates.append("if")
		if level.allow_simultaneous and context.function != "tick":
			candidates.append("simultaneously")
		if level.allow_functions and context.function != "tick":
			var functions: Dictionary = context.functions
			var function_names: Array = functions.keys()
			function_names.sort()
			for function_name: String in function_names:
				if not _would_recurse(function_name, context.function, functions):
					candidates.append(function_name)
	if (level.allow_variables or level.allow_for) and receiver.is_empty():
		var names: Array = bindings.keys()
		names.sort()
		if kind == "expression":
			for name: String in names:
				candidates.append(name)
		elif kind == "statement" and level.allow_variables and not context.parallel and context.function != "tick":
			candidates.append_array(PackedStringArray(["constant", "variable", "value"]))
			for name: String in names:
				if bool(bindings[name]):
					candidates.append(name)
	if level.allow_named_calls and assembly != null:
		var names := PackedStringArray()
		for instance in assembly.modules:
			if not instance is Dictionary or not instance.get("id") is String:
				continue
			var name: String = instance.id
			var behavior := _receiver_behavior(name, level, assembly)
			for method in methods:
				if _supports_method(behavior, method) and not name in names:
					names.append(name)
		# 名称排序不依赖装配插入顺序，避免重排部件后同样前缀换候选。
		names.sort()
		candidates.append_array(names)
	return candidates


## 查询当前关卡允许的真实实例类型；坏草稿、未知名称或未注册类型均不作猜测。
static func _receiver_behavior(receiver: String, level: LevelDefinition, assembly: AssemblyModel) -> String:
	if assembly == null or assembly.content == null or not ProgramParser.is_receiver_name(receiver):
		return ""
	for instance in assembly.modules:
		if not instance is Dictionary or instance.get("id") != receiver:
			continue
		var module_id: Variant = instance.get("module_id")
		if not module_id is String or not module_id in level.allowed_modules:
			return ""
		var definition := assembly.content.get_module(module_id)
		return definition.behavior if definition != null else ""
	return ""


## 将已实现的指令映射到模块行为，避免移动模块收到射击或测距方法的建议。
static func _supports_method(behavior: String, method: String) -> bool:
	if method == "ready":
		return behavior == "ShootingModule"
	if method == "distance":
		return behavior == "RangefinderModule"
	if method == "scan":
		return behavior == "RadarModule"
	return not behavior.is_empty() and ACTION_BEHAVIORS.get(method, "") == behavior


## 补全按 DSL 的 ASCII 标识符边界切词，不能从数字或中文的一部分生成指令。
static func _is_identifier_part(character: String) -> bool:
	return ProgramLexer._is_identifier_start(character) or ProgramLexer._is_digit(character)


## 只接受 function 名称() 的声明头，避免把普通调用或保留字当作新的可调用函数。
static func _declaration_name(tokens: Array[ProgramLexer.Token], left_paren_index: int) -> String:
	var words: Array[ProgramLexer.Token] = []
	for index in range(left_paren_index - 1, -1, -1):
		if tokens[index].kind != ProgramLexer.Kind.NEWLINE:
			words.push_front(tokens[index])
			if words.size() == 2:
				break
	if words.size() != 2 or words[0].lexeme != "function" or words[1].kind != ProgramLexer.Kind.IDENTIFIER:
		return ""
	return words[1].lexeme if ProgramFunctionValidation.is_function_name(words[1].lexeme) else ""


## 扫描完整源码中的顶层无参声明，支持后置定义；词法器自动忽略注释中的伪函数。
static func _function_declarations(source: String) -> Dictionary:
	var lexed := ProgramLexer.tokenize(source)
	if not lexed.is_ok():
		return {}
	var compact: Array[ProgramLexer.Token] = []
	for token: ProgramLexer.Token in lexed.value:
		if token.kind != ProgramLexer.Kind.NEWLINE:
			compact.append(token)
	var functions := {}
	var duplicates := PackedStringArray()
	var depth := 0
	var owner := ""
	var pending := ""
	for index in range(compact.size()):
		var token := compact[index]
		if depth == 0 and token.lexeme == "function" and index + 4 < compact.size():
			var name := compact[index + 1].lexeme
			if ProgramFunctionValidation.is_function_name(name) and compact[index + 2].kind == ProgramLexer.Kind.LEFT_PAREN and compact[index + 3].kind == ProgramLexer.Kind.RIGHT_PAREN and compact[index + 4].kind == ProgramLexer.Kind.LEFT_BRACE:
				pending = name
				if functions.has(name):
					duplicates.append(name)
				functions[name] = PackedStringArray()
		if token.kind == ProgramLexer.Kind.LEFT_BRACE:
			if depth == 0:
				owner = pending
				pending = ""
			depth += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_BRACE:
			depth = maxi(0, depth - 1)
			if depth == 0:
				owner = ""
		elif not owner.is_empty() and token.kind == ProgramLexer.Kind.IDENTIFIER and index + 1 < compact.size() and compact[index + 1].kind == ProgramLexer.Kind.LEFT_PAREN:
			if index == 0 or compact[index - 1].kind != ProgramLexer.Kind.DOT:
				functions[owner].append(token.lexeme)
	for name in duplicates:
		functions.erase(name)
	return functions


## 不建议自身调用或已有调用链中会返回当前函数的名字，减少必然递归的补全。
static func _would_recurse(candidate: String, current: String, functions: Dictionary) -> bool:
	var pending := PackedStringArray([candidate])
	var visited := {}
	while not pending.is_empty():
		var name := pending[pending.size() - 1]
		pending.remove_at(pending.size() - 1)
		if name == current:
			return true
		if visited.has(name):
			continue
		visited[name] = true
		if functions.has(name):
			pending.append_array(functions[name])
	return false


## 识别声明或赋值右侧的半成品数值式；回调、并行和只读常量不会产生写入建议。
static func _binding_expression_context(tokens: Array[ProgramLexer.Token], function_name: String, parallel: bool, level: LevelDefinition) -> Dictionary:
	if not level.allow_variables or function_name == "tick" or parallel:
		return {}
	var statement := _current_statement(tokens)
	if statement.size() < 2:
		return {}
	var declaration := statement[0].lexeme in ["constant", "variable", "value"]
	var target_index := 1 if declaration else 0
	var equals_index := target_index + 1
	if equals_index >= statement.size() or statement[equals_index].kind != ProgramLexer.Kind.ASSIGN:
		return {}
	var target := statement[target_index].lexeme
	if not ProgramVariableValidation.is_binding_name(target) or (not declaration and function_name.is_empty()):
		return {}
	var previous: ProgramLexer.Token = statement.back()
	if previous.kind not in [ProgramLexer.Kind.ASSIGN, ProgramLexer.Kind.LEFT_PAREN, ProgramLexer.Kind.COMMA, ProgramLexer.Kind.PLUS, ProgramLexer.Kind.MINUS]:
		return {}
	# 只检查仍未闭合的数值参数，已完成的 scan()/random() 等结果可继续参加运算。
	var open_parentheses: Array[int] = []
	for index in range(equals_index + 1, statement.size()):
		if statement[index].kind == ProgramLexer.Kind.LEFT_PAREN:
			open_parentheses.append(index)
		elif statement[index].kind == ProgramLexer.Kind.RIGHT_PAREN and not open_parentheses.is_empty():
			open_parentheses.pop_back()
	for index in open_parentheses:
		var owner := statement[index - 1].lexeme if index > 0 and statement[index - 1].kind == ProgramLexer.Kind.IDENTIFIER else "("
		if not _numeric_operand_allowed(statement, index, owner, level):
			return {}
	return {"kind": "expression", "function": function_name, "ready": false, "binding_assignment": not declaration, "binding_target": target, "radar_value": previous.kind == ProgramLexer.Kind.ASSIGN, "null_value": previous.kind == ProgramLexer.Kind.ASSIGN}


## 数值函数仅在尚有参数空位时提供候选；random 无参数，randomInt 不属于模块方法。
static func _numeric_operand_allowed(tokens: Array[ProgramLexer.Token], left_index: int, owner: String, level: LevelDefinition) -> bool:
	if owner == "(":
		return true
	var arity := 0
	if owner == "distance" and level.allow_distance:
		arity = 1
	elif owner == "randomInt" and level.allow_random:
		if left_index >= 2 and tokens[left_index - 2].kind == ProgramLexer.Kind.DOT:
			return false
		arity = 2
	else:
		return false
	var depth := 0
	var parameter := 0
	for index in range(left_index + 1, tokens.size()):
		match tokens[index].kind:
			ProgramLexer.Kind.LEFT_PAREN:
				depth += 1
			ProgramLexer.Kind.RIGHT_PAREN:
				depth -= 1
			ProgramLexer.Kind.COMMA:
				if depth == 0:
					parameter += 1
	return parameter < arity


## 当前语句由括号外的换行或代码块边界分隔；跨行参数不会被误切成新语句。
static func _current_statement(tokens: Array[ProgramLexer.Token]) -> Array[ProgramLexer.Token]:
	var current: Array[ProgramLexer.Token] = []
	var parentheses := 0
	for token: ProgramLexer.Token in tokens:
		if token.kind == ProgramLexer.Kind.NEWLINE:
			if parentheses == 0:
				current.clear()
			continue
		if token.kind in [ProgramLexer.Kind.LEFT_BRACE, ProgramLexer.Kind.RIGHT_BRACE]:
			current.clear()
			continue
		current.append(token)
		if token.kind == ProgramLexer.Kind.LEFT_PAREN:
			parentheses += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_PAREN:
			parentheses = maxi(0, parentheses - 1)
	return current


## 函数可见全部全局初始化项，顶层只可见此前声明；当前局部按真实词法块逐层覆盖。
static func _visible_bindings(source: String, tokens: Array[ProgramLexer.Token], function_name: String, allow_variables: bool = true, allow_for: bool = false) -> Dictionary:
	var scopes := _binding_scopes(tokens, allow_variables, allow_for)
	var visible: Dictionary = scopes[0].duplicate()
	if not function_name.is_empty():
		var lexed := ProgramLexer.tokenize(source)
		if lexed.is_ok():
			visible = _binding_scopes(lexed.value, allow_variables, allow_for)[0].duplicate()
	for index in range(1, scopes.size()):
		visible.merge(scopes[index], true)
	return visible


## 只在完整声明结束后引入名称，退出代码块时释放局部；注释由词法器先行忽略。
static func _binding_scopes(tokens: Array[ProgramLexer.Token], allow_variables: bool = true, allow_for: bool = false) -> Array[Dictionary]:
	var scopes: Array[Dictionary] = [{}]
	var statement: Array[ProgramLexer.Token] = []
	var parentheses := 0
	for token: ProgramLexer.Token in tokens:
		if token.kind == ProgramLexer.Kind.LEFT_BRACE:
			var iterator := _for_binding_name(statement) if allow_for else ""
			statement.clear()
			var local := {}
			if not iterator.is_empty():
				local[iterator] = false
			scopes.append(local)
			continue
		if token.kind == ProgramLexer.Kind.RIGHT_BRACE:
			if allow_variables:
				_commit_binding(statement, scopes[scopes.size() - 1])
			statement.clear()
			if scopes.size() > 1:
				scopes.pop_back()
			continue
		if token.kind in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.END]:
			if parentheses == 0:
				if allow_for and not _for_binding_name(statement).is_empty():
					continue
				if allow_variables:
					_commit_binding(statement, scopes[scopes.size() - 1])
				statement.clear()
			continue
		statement.append(token)
		if token.kind == ProgramLexer.Kind.LEFT_PAREN:
			parentheses += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_PAREN:
			parentheses = maxi(0, parentheses - 1)
	return scopes


## 迭代名称只在完整 for 头后的代码块内可见，离开块即由普通词法作用域回收。
static func _for_binding_name(statement: Array[ProgramLexer.Token]) -> String:
	if statement.size() < 8 or statement[0].lexeme != "for" or statement[1].kind != ProgramLexer.Kind.LEFT_PAREN or statement[2].kind != ProgramLexer.Kind.IDENTIFIER or statement[3].lexeme != "in" or statement.back().kind != ProgramLexer.Kind.RIGHT_PAREN:
		return ""
	var has_range := false
	for token in statement:
		has_range = has_range or token.lexeme == ".."
	return statement[2].lexeme if has_range and ProgramVariableValidation.is_binding_name(statement[2].lexeme) else ""


## 声明至少包含名称、等号和完整数值末项；尚在输入的自身声明不抢占外层同名变量。
static func _commit_binding(statement: Array[ProgramLexer.Token], bindings: Dictionary) -> void:
	if statement.size() < 4 or statement[0].lexeme not in ["constant", "variable", "value"]:
		return
	var name := statement[1].lexeme
	if statement[1].kind != ProgramLexer.Kind.IDENTIFIER or not ProgramVariableValidation.is_binding_name(name) or statement[2].kind != ProgramLexer.Kind.ASSIGN:
		return
	var last: ProgramLexer.Token = statement.back()
	if last.kind not in [ProgramLexer.Kind.NUMBER, ProgramLexer.Kind.IDENTIFIER, ProgramLexer.Kind.RIGHT_PAREN]:
		return
	bindings[name] = statement[0].lexeme == "variable"


## 无具名 scan 建议也要求装配中存在已解锁的真实雷达，不能靠未知或禁用模块补齐。
static func _has_radar(level: LevelDefinition, assembly: AssemblyModel) -> bool:
	return _radar_count(level, assembly) > 0


## 多雷达装配要求明确来源，裸 scan 候选只在来源唯一时提供。
static func _radar_count(level: LevelDefinition, assembly: AssemblyModel) -> int:
	if assembly == null:
		return 0
	var count := 0
	for instance in assembly.modules:
		if instance is Dictionary and instance.get("id") is String and _receiver_behavior(instance.id, level, assembly) == "RadarModule":
			count += 1
	return count


## 从完整全局与光标前局部推断扫描结果类型；函数之间不借用调用方的局部名称。
static func _visible_radar_bindings(source: String, tokens: Array[ProgramLexer.Token], function_name: String, level: LevelDefinition, assembly: AssemblyModel) -> Dictionary:
	var globals := {}
	var event_targets := _radar_event_targets(source, level, assembly)
	if not function_name.is_empty():
		var lexed := ProgramLexer.tokenize(source)
		if lexed.is_ok():
			globals = _radar_binding_scopes(lexed.value, {}, true, level, assembly)[0]
			globals.merge(event_targets, true)
	var scopes := _radar_binding_scopes(tokens, globals, false, level, assembly, not function_name.is_empty())
	var visible := {}
	for scope in scopes:
		visible.merge(scope, true)
	return visible


## 只跟踪扫描快照及位置向量；函数保留完整初始化及事件全局表，局部分支改写不泄漏到外层。
static func _radar_binding_scopes(tokens: Array[ProgramLexer.Token], globals: Dictionary, globals_only: bool, level: LevelDefinition, assembly: AssemblyModel, preserve_globals: bool = false) -> Array[Dictionary]:
	var scopes: Array[Dictionary] = [globals.duplicate()]
	var statement: Array[ProgramLexer.Token] = []
	var parentheses := 0
	for token in tokens:
		if token.kind == ProgramLexer.Kind.LEFT_BRACE:
			var iterator := _for_binding_name(statement) if level.allow_for else ""
			statement.clear()
			var local := {}
			if not iterator.is_empty():
				local[iterator] = ""
			scopes.append(local)
			continue
		if token.kind == ProgramLexer.Kind.RIGHT_BRACE:
			if (not globals_only or scopes.size() == 1) and not (preserve_globals and scopes.size() == 1):
				_commit_radar_binding(statement, scopes, level, assembly)
			statement.clear()
			if scopes.size() > 1:
				scopes.pop_back()
			continue
		if token.kind in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.END]:
			if parentheses == 0:
				if level.allow_for and not _for_binding_name(statement).is_empty():
					continue
				if (not globals_only or scopes.size() == 1) and not (preserve_globals and scopes.size() == 1):
					_commit_radar_binding(statement, scopes, level, assembly)
				statement.clear()
			continue
		statement.append(token)
		if token.kind == ProgramLexer.Kind.LEFT_PAREN:
			parentheses += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_PAREN:
			parentheses = maxi(0, parentheses - 1)
	return scopes


## 完整声明或赋值结束后更新类型，数字遮蔽雷达名称时必须停止推荐快照成员。
static func _commit_radar_binding(statement: Array[ProgramLexer.Token], scopes: Array[Dictionary], level: LevelDefinition, assembly: AssemblyModel) -> void:
	if statement.size() < 3:
		return
	var declaration := statement[0].lexeme in ["constant", "variable", "value"]
	var name_index := 1 if declaration else 0
	if statement.size() <= name_index + 2 or statement[name_index + 1].kind != ProgramLexer.Kind.ASSIGN:
		return
	var name := statement[name_index].lexeme
	if not ProgramVariableValidation.is_binding_name(name):
		return
	var visible := {}
	for scope in scopes:
		visible.merge(scope, true)
	if not declaration and not visible.has(name):
		return
	var expression: Array[ProgramLexer.Token] = []
	for index in range(name_index + 2, statement.size()):
		expression.append(statement[index])
	var value_type := _radar_expression_type(expression, visible, level, assembly)
	if not declaration and value_type == "null" and visible.get(name) == "snapshot":
		value_type = "snapshot"
	if not declaration:
		for index in range(scopes.size() - 2, -1, -1):
			if scopes.back().has(name):
				break
			if scopes[index].has(name):
				# 分支或循环可能改变外层值，离开块后不能重新假定它仍是旧快照。
				# 函数中的全局写入只使当前函数视图失效，不把未执行函数当成初始化。
				var invalidated_scope := maxi(index, 1) if scopes.size() > 1 else 0
				scopes[invalidated_scope][name] = ""
				break
	scopes.back()[name] = value_type


## 显式识别 scan、快照复制和 Position；未知表达式不猜测类型或暴露任意成员。
static func _radar_expression_type(expression: Array[ProgramLexer.Token], visible: Dictionary, level: LevelDefinition, assembly: AssemblyModel) -> String:
	if expression.size() >= 3 and expression[expression.size() - 2].kind == ProgramLexer.Kind.DOT and expression.back().lexeme == "Position":
		var origin: Array[ProgramLexer.Token] = expression.slice(0, expression.size() - 2)
		return "vector" if _radar_source_type(origin, visible, level, assembly) == "snapshot" else ""
	return _radar_source_type(expression, visible, level, assembly)


## 基础雷达来源只接受名称、null 或完整零参数扫描，检查工作量不随成员链递归增长。
static func _radar_source_type(expression: Array[ProgramLexer.Token], visible: Dictionary, level: LevelDefinition, assembly: AssemblyModel) -> String:
	if expression.is_empty():
		return ""
	if expression.size() == 1:
		if expression[0].lexeme in ["null", "Null"]:
			return "null"
		return str(visible.get(expression[0].lexeme, ""))
	if expression.size() == 3 and expression[0].lexeme == "scan" and expression[1].kind == ProgramLexer.Kind.LEFT_PAREN and expression[2].kind == ProgramLexer.Kind.RIGHT_PAREN:
		return "snapshot" if level.allow_radar and _radar_count(level, assembly) == 1 else ""
	if expression.size() == 5 and expression[1].kind == ProgramLexer.Kind.DOT and expression[2].lexeme == "scan" and expression[3].kind == ProgramLexer.Kind.LEFT_PAREN and expression[4].kind == ProgramLexer.Kind.RIGHT_PAREN:
		return "snapshot" if level.allow_radar and level.allow_named_calls and _receiver_behavior(expression[0].lexeme, level, assembly) == "RadarModule" else ""
	return ""


## 事件需要独立权限、雷达查询、具名来源和全局变量能力，不能由单一开关隐式解锁。
static func _radar_events_allowed(level: LevelDefinition) -> bool:
	return level.allow_radar_events and level.allow_radar and level.allow_named_calls and level.allow_variables


## 顶层事件头只接受真实雷达实例名加固定成员，不允许空来源或普通函数返回值。
static func _event_receiver(tokens: Array[ProgramLexer.Token], brace_index: int, level: LevelDefinition, assembly: AssemblyModel) -> String:
	if not _radar_events_allowed(level):
		return ""
	var header: Array[ProgramLexer.Token] = []
	for index in range(brace_index - 1, -1, -1):
		if tokens[index].kind == ProgramLexer.Kind.NEWLINE and header.size() < 3:
			continue
		if tokens[index].kind in [ProgramLexer.Kind.NEWLINE, ProgramLexer.Kind.LEFT_BRACE, ProgramLexer.Kind.RIGHT_BRACE]:
			break
		header.push_front(tokens[index])
	if header.size() != 3 or header[0].kind != ProgramLexer.Kind.IDENTIFIER or header[1].kind != ProgramLexer.Kind.DOT or header[2].lexeme != "onDetected":
		return ""
	return header[0].lexeme if _receiver_behavior(header[0].lexeme, level, assembly) == "RadarModule" else ""


## 事件体只有固定载荷和箭头目标两个补全位置，不能扩展成可执行任意语句的处理器。
static func _event_body_context(tokens: Array[ProgramLexer.Token], brace_index: int) -> Dictionary:
	var body: Array[ProgramLexer.Token] = []
	for index in range(brace_index + 1, tokens.size()):
		if tokens[index].kind != ProgramLexer.Kind.NEWLINE:
			body.append(tokens[index])
	if body.is_empty():
		return {"kind": "event_payload"}
	if body.size() == 2 and body[0].lexeme == "EnemyPosition" and body[1].lexeme == "->":
		return {"kind": "event_target"}
	return {}


## 完整事件绑定使目标具备快照成员提示；仅接受事件前已声明的可变全局和真实雷达。
static func _radar_event_targets(source: String, level: LevelDefinition, assembly: AssemblyModel) -> Dictionary:
	var targets := {}
	if not _radar_events_allowed(level):
		return targets
	var lexed := ProgramLexer.tokenize(source)
	if not lexed.is_ok():
		return targets
	var tokens: Array[ProgramLexer.Token] = lexed.value
	var depth := 0
	for index in range(tokens.size()):
		var token: ProgramLexer.Token = tokens[index]
		if token.kind == ProgramLexer.Kind.LEFT_BRACE:
			if depth == 0 and not _event_receiver(tokens, index, level, assembly).is_empty():
				var body: Array[ProgramLexer.Token] = []
				for body_index in range(index + 1, tokens.size()):
					if tokens[body_index].kind == ProgramLexer.Kind.RIGHT_BRACE:
						break
					if tokens[body_index].kind != ProgramLexer.Kind.NEWLINE:
						body.append(tokens[body_index])
					if body.size() > 3:
						break
				if body.size() == 3 and body[0].lexeme == "EnemyPosition" and body[1].lexeme == "->" and body[2].kind == ProgramLexer.Kind.IDENTIFIER:
					var globals := _binding_scopes(tokens.slice(0, index))[0]
					if globals.get(body[2].lexeme, false):
						targets[body[2].lexeme] = "snapshot"
			depth += 1
		elif token.kind == ProgramLexer.Kind.RIGHT_BRACE:
			depth = maxi(0, depth - 1)
	return targets
