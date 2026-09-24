class_name CodeHintService
extends RefCounted
## JSON 教学方案先用独立会话通关验证，再返回一次可撤销的小步源码修改。
## 不持有 UI、不写存档，也不改变传入会话的源码、装配、世界或状态。

const HINT_DIRECTORY := "res://data/hints"
const MAX_STEPS := 2400
const MAX_SOURCE_BYTES := 65536
const MAX_NODES := 512
const MAX_CHECK_USEC := 3000000


## 根据实际关卡与装配返回下一条完整代码；返回行号从 1 开始，失败仅提供可操作说明。
static func next_hint(session: GameSession) -> DataResult:
	if session == null or session.level == null or session.assembly == null:
		return DataResult.failure("请先进入关卡并确认装配，再使用代码提示。")
	if session.state == GameSession.State.RUNNING or session.state == GameSession.State.PAUSED:
		return DataResult.failure("请先停止程序，再使用代码提示。")
	if session.state == GameSession.State.SUCCEEDED:
		return DataResult.failure("这一关已经完成，无需继续补充提示。")
	if session.source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return DataResult.failure("代码超过提示处理范围，请先缩短到 64 KiB 以内。")
	var data_result := _load_hint(session)
	if not data_result.is_ok():
		return data_result
	var data: Dictionary = data_result.value
	var layout := session.assembly.validate()
	if not layout.is_ok():
		return DataResult.failure(str(data.assembly_help) + "\n" + "\n".join(layout.errors))
	var bound := _bind_source(data, session)
	if not bound.is_ok():
		return bound
	var target: String = bound.value
	var deadline := Time.get_ticks_usec() + MAX_CHECK_USEC
	# 先验证完整方案，不能把不适合当前实际装配的半成品代码写给玩家。
	if not _wins(session, target, int(data.max_steps), deadline):
		if Time.get_ticks_usec() >= deadline:
			return DataResult.failure("本次提示验证已达到时间上限，请稍后重试。")
		return DataResult.failure("当前装配尚不能通过这份提示方案。\n" + str(data.assembly_help))
	# 已有不同但正确的解法也应保留，不为贴近参考格式而重写作品。
	if not session.source.strip_edges().is_empty() and _wins(session, session.source, int(data.max_steps), deadline):
		return DataResult.failure("当前程序已经能够完成关卡，无需继续补充提示。")
	if Time.get_ticks_usec() >= deadline:
		return DataResult.failure("本次提示验证已达到时间上限，请稍后重试。")
	return _next_patch(session.source, target)


## 严格限定正式教学来源及完整地图内容；导入副本与编辑器快照不凭相同 ID 获得提示。
static func _load_hint(session: GameSession) -> DataResult:
	var identity := session.level.id
	var canonical_path := "res://data/levels/" + identity + ".json"
	if not identity in ["level_001", "level_002", "level_003", "level_004", "level_005", "level_006", "level_007", "level_008", "level_009", "level_010", "level_011", "level_012", "level_013", "level_014", "level_015"] or session.level.source_path != canonical_path:
		return DataResult.failure("代码提示仅用于教学关卡，不支持导入关卡或编辑器测试。")
	var path := HINT_DIRECTORY.path_join(identity + ".json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_SOURCE_BYTES:
		return DataResult.failure("此关提示资料暂时不可用，请查看关卡说明。")
	var raw: Variant = JSON.parse_string(file.get_as_text())
	if not raw is Dictionary or not DataValidation.is_integer(raw.get("format_version"), 1, 1) or raw.get("level_id") != identity or not raw.get("source") is String or not raw.get("assembly_help") is String or not raw.get("bindings") is Array or not DataValidation.is_integer(raw.get("max_steps"), 1, MAX_STEPS):
		return DataResult.failure("此关提示资料格式无效，请查看关卡说明。")
	var canonical := MapCodec.load_file(canonical_path, session.assembly.content, true)
	if not canonical.is_ok() or canonical.value.to_dict() != session.level.document.to_dict():
		return DataResult.failure("当前地图与原教学关卡不同，不能直接使用原关提示。请查看当前地图的目标与说明。")
	return _select_plan(raw, session)


## 同一教学关的 JSON 可提供不同模块方案，只选择能绑定到实际装配的方案。
static func _select_plan(data: Dictionary, session: GameSession) -> DataResult:
	var alternatives: Variant = data.get("alternatives", [])
	if not alternatives is Array or alternatives.size() > 16:
		return DataResult.failure("此关提示资料格式无效，请查看关卡说明。")
	var candidates: Array[Dictionary] = [data]
	for alternative: Variant in alternatives:
		if not alternative is Dictionary or not alternative.get("source") is String or not alternative.get("assembly_help") is String or not alternative.get("bindings") is Array:
			return DataResult.failure("此关提示资料格式无效，请查看关卡说明。")
		var merged := data.duplicate(true)
		merged.source = alternative.source
		merged.assembly_help = alternative.assembly_help
		merged.bindings = alternative.bindings
		candidates.append(merged)
	for candidate: Dictionary in candidates:
		if _bind_source(candidate, session).is_ok():
			return DataResult.success(candidate)
	return DataResult.success(data)


## 角色按真实行为及水平位置绑定到玩家实例名，十一关保留唯一已有自定义函数名。
static func _bind_source(data: Dictionary, session: GameSession) -> DataResult:
	var result: String = data.source
	for binding: Variant in data.bindings:
		if not binding is Dictionary or not binding.get("role") is String or not binding.get("behavior") is String or not DataValidation.is_integer(binding.get("index"), 0, 255):
			return DataResult.failure("此关提示的模块绑定无效，请查看关卡说明。")
		var matches: Array[Dictionary] = []
		for module: Dictionary in session.assembly.modules:
			var definition := session.assembly.content.get_module(module.module_id)
			if definition != null and definition.behavior == binding.behavior:
				matches.append(module)
		matches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if float(a.offset.x) != float(b.offset.x):
				return float(a.offset.x) < float(b.offset.x)
			if float(a.offset.y) != float(b.offset.y):
				return float(a.offset.y) < float(b.offset.y)
			return str(a.id) < str(b.id)
		)
		if int(binding.index) >= matches.size():
			return DataResult.failure(str(data.assembly_help))
		result = result.replace("{{" + str(binding.role) + "}}", str(matches[int(binding.index)].id))
	if data.has("function_name"):
		var expression := RegEx.new()
		expression.compile("(?m)^\\s*function\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\s*\\)")
		var matches := expression.search_all(_without_comments(session.source))
		var name: String = str(data.function_name)
		if matches.size() == 1:
			name = matches[0].get_string(1)
		result = result.replace("{{function}}", name)
	if result.contains("{{"):
		return DataResult.failure("提示中仍有无法绑定的模块或函数，请先检查装配名称。")
	return DataResult.success(result)


## 独立克隆装配后通过普通 GameSession 跑完真实目标；每次验证均有 tick 与墙钟上限。
static func _wins(session: GameSession, source: String, max_steps: int, deadline: int) -> bool:
	# 本关没有环境自动击毁机制；完全没有动作的半成品不可能清波。
	# 避免为反复 scan 的未完成 loop 跑满调度预算，阻塞下一条教学提示。
	if session.level.id in ["level_013", "level_014", "level_015"]:
		var action := RegEx.new()
		action.compile("\\b(move|attack|shoot)\\s*\\(")
		if action.search(_without_comments(source)) == null:
			return false
	if Time.get_ticks_usec() >= deadline:
		return false
	var seeds: Array[int] = []
	for entry: Dictionary in session.level.document.enemies:
		if entry.get("properties", {}).has("random_spawn"):
			# 一次完整十波已经覆盖十个不同角度，保持提示验证在原有三秒预算内。
			seeds = [73]
			break
		if entry.get("behavior") == EnemyDefinition.RANDOM_WANDER:
			# 隔离验证固定三条轨迹，避免同一段源码在每次点击时随机变成“正确/错误”。
			# 正式关卡不写种子，实际游玩和重试仍使用新的独立随机源。
			seeds = [19, 73, 211]
			break
	if seeds.is_empty():
		seeds.append(-1)
	for sample_seed: int in seeds:
		if Time.get_ticks_usec() >= deadline:
			return false
		var level := session.level
		if sample_seed >= 0:
			var document := level.document.duplicate_document()
			for entry: Dictionary in document.enemies:
				if entry.get("behavior") == EnemyDefinition.RANDOM_WANDER or entry.get("properties", {}).has("random_spawn"):
					if entry.properties.has("random_spawn"):
						entry.properties.random_spawn.seed = sample_seed
					else:
						entry.properties.seed = sample_seed
			var defined := LevelDefinition.from_document(document, session.assembly.content)
			if not defined.is_ok():
				return false
			level = defined.value
		var trial := GameSession.create(level, session.assembly.content)
		trial.assembly.modules = session.assembly.modules.duplicate(true)
		trial.source = source
		if not trial.run().is_ok():
			trial.stop()
			return false
		for unused in max_steps:
			if trial.state != GameSession.State.RUNNING or Time.get_ticks_usec() >= deadline:
				break
			trial.step()
		var won := trial.state == GameSession.State.SUCCEEDED
		trial.stop()
		if not won:
			return false
	return true


## 提示以结构节点逐步对齐，保留未参与参考方案的顶层声明、函数及所有注释。
static func _next_patch(source: String, target: String) -> DataResult:
	var parsed := _read_tree(source)
	if not parsed.is_ok():
		return parsed
	var existing: Dictionary = parsed.value
	if not existing.open_blocks.is_empty():
		var block: Dictionary = existing.open_blocks[-1]
		var closing := "\n" + _indent_at(source, int(block.start)) + "}"
		return _patch(source, source.length(), source.length(), closing, "已补齐当前代码块的右花括号。")
	var reference := _read_tree(target)
	if not reference.is_ok():
		return DataResult.failure("参考程序结构无法读取，请查看关卡说明。")
	for expected: Dictionary in reference.value.children:
		if not expected.block:
			# 事件需要全局可变绑定；只补对应名称，保留其他顶层声明和注释。
			var binding := _binding_name(str(expected.text))
			if not binding.is_empty():
				var present: Dictionary = {}
				for current: Dictionary in existing.children:
					if not current.block and _binding_name(str(current.text)) == binding:
						present = current
						break
				if present.is_empty():
					return _patch(source, 0, 0, str(expected.text) + "\n", "已补充全局变量，供雷达事件更新。")
				if _normal(str(present.text)) != _normal(str(expected.text)):
					return _patch(source, int(present.start), int(present.end), str(expected.text), "已修正这一行的指令与完整参数。")
			continue
		var found: Dictionary = {}
		for current: Dictionary in existing.children:
			if _root_key(str(current.text)) == _root_key(str(expected.text)):
				found = current
				break
		if found.is_empty():
			if str(expected.text).contains(".onDetected"):
				# 事件是完整的一条绑定注册，不向玩家留下空回调框架。
				var event_line := str(expected.text) + " " + str(expected.children[0].text) + " }\n"
				var insertion := 0
				for current: Dictionary in existing.children:
					if not current.block:
						insertion = maxi(insertion, int(current.end))
				return _patch(source, insertion, insertion, "\n" + event_line, "已补充雷达事件，目标变量已填写完整。")
			var text := ("\n" if not source.is_empty() and not source.ends_with("\n") else "") + "\n" + str(expected.text) + "\n}\n"
			return _patch(source, source.length(), source.length(), text, "已补充一个入口或函数框架，继续点击可填写其中的一步。")
		if not found.block:
			return _patch(source, int(found.start), int(found.end), str(expected.text) + "\n}", "已补齐当前入口或函数的代码框架。")
		var patched := _patch_block(source, found, expected)
		if patched != null:
			return patched
	return DataResult.failure("参考步骤已经齐全。请检查额外代码或函数中的错误，或运行程序验证。")


## 在匹配的代码块中处理第一处差异；完整参数一次写入，缺少结构只增加对应框架。
static func _patch_block(source: String, current: Dictionary, expected: Dictionary) -> DataResult:
	var wanted: Array = expected.children
	var reference_bindings := {}
	for child: Dictionary in wanted:
		var name := _binding_name(str(child.text))
		if not name.is_empty():
			reference_bindings[name] = true
	var actual: Array[Dictionary] = []
	for child: Dictionary in current.children:
		# 仅把本层参考方案确实用到的绑定纳入比较；玩家无关声明与赋值仍原文保留。
		if _kind(str(child.text)) in ["variable", "constant", "value", "assignment"] and not reference_bindings.has(_binding_name(str(child.text))):
			continue
		actual.append(child)
	for index in wanted.size():
		var entry: Dictionary = wanted[index]
		if index >= actual.size():
			return _insert_node(source, current, entry, int(current.close_start), index + 1 < wanted.size() and _kind(str(wanted[index + 1].text)) == "else")
		var present: Dictionary = actual[index]
		var binding := _binding_name(str(entry.text))
		if not binding.is_empty() and _binding_name(str(present.text)) != binding:
			# 缺少初始化或赋值时插入该行，不能拿变量行覆盖已有动作或整块控制结构。
			return _insert_node(source, current, entry, int(present.start), false)
		if bool(entry.block) != bool(present.block) or (entry.block and _kind(str(entry.text)) != _kind(str(present.text))):
			if entry.block:
				return _insert_node(source, current, entry, int(present.start), index + 1 < wanted.size() and _kind(str(wanted[index + 1].text)) == "else")
			return DataResult.failure("请先整理这段多余的控制结构，再使用逐步代码提示；已有代码会保留。")
		if _normal(str(entry.text)) != _normal(str(present.text)):
			# 当前这一句已是稍后的正确步骤时，插入缺失步骤，避免覆盖正确内容。
			var later := false
			for following in range(index + 1, wanted.size()):
				later = later or _normal(str(present.text)) == _normal(str(wanted[following].text))
			if later:
				return _insert_node(source, current, entry, int(present.start), index + 1 < wanted.size() and _kind(str(wanted[index + 1].text)) == "else")
			return _patch(source, int(present.start), int(present.end), str(entry.text), "已修正这一行的指令与完整参数。")
		if entry.block:
			var nested := _patch_block(source, present, entry)
			if nested != null:
				return nested
	if actual.size() > wanted.size():
		var extra: Dictionary = actual[wanted.size()]
		if extra.block:
			return DataResult.failure("请先检查这段额外的控制结构；提示不会整块删除你的代码。")
		return _patch(source, int(extra.start), int(extra.end), "// 原代码保留：" + str(extra.text), "已停用这一条多余动作，原代码保留在注释中。")
	return null


## 新结构配齐闭括号，if 同时提供必要的 else 空框架，不填入多条答案动作。
static func _insert_node(source: String, parent: Dictionary, node: Dictionary, offset: int, add_else: bool) -> DataResult:
	var indent := _indent_at(source, int(parent.start)) + "    "
	var code := str(node.text)
	if node.block:
		code += "\n" + indent + "}"
		if add_else:
			code += "\n" + indent + "else {\n" + indent + "}"
	# 在当前代码首字符之前插入；原缩进留在左边，新行再恢复原行的缩进。
	var before := _indent_at(source, offset)
	var prefix := "" if offset > 0 and source[offset - 1] in [" ", "\t", "\n", "\r"] else "\n" + indent
	if before != indent and prefix.is_empty():
		prefix = indent.trim_prefix(before) if indent.begins_with(before) else indent
	var text := prefix + code + "\n" + before
	return _patch(source, offset, offset, text, "已补充下一步代码，函数名与参数已填写完整。")


## 按原始字符区间替换一条逻辑行，自动兼容 Windows 换行并返回实际高亮行。
static func _patch(source: String, start: int, finish: int, replacement: String, message: String) -> DataResult:
	if source.contains("\r\n"):
		replacement = replacement.replace("\r\n", "\n").replace("\n", "\r\n")
	var result := source.substr(0, start) + replacement + source.substr(finish)
	if result.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return DataResult.failure("补充后代码会超过 64 KiB，请先缩短代码。")
	return DataResult.success({"source": result, "line": source.substr(0, start).count("\n") + 1, "message": message})


## 读取仅用于源码编辑的轻量括号树，保留所有原文区间；真实语言是否合法仍由会话验证。
static func _read_tree(source: String) -> DataResult:
	var root := {"children": [], "open_blocks": []}
	var stack: Array[Dictionary] = [root]
	var pieces: Array[Dictionary] = []
	var start := -1
	var cursor := 0
	while cursor < source.length():
		var letter := source[cursor]
		if letter == "/" and cursor + 1 < source.length() and source[cursor + 1] == "/":
			if start >= 0:
				_add_piece(pieces, source, start, cursor)
				start = -1
			while cursor < source.length() and source[cursor] not in ["\n", "\r"]:
				cursor += 1
			continue
		if letter in ["\n", "\r"]:
			if start >= 0:
				_add_piece(pieces, source, start, cursor)
				start = -1
		elif letter == "{":
			if start < 0 and not pieces.is_empty() and not str(pieces[-1].text).ends_with("{") and str(pieces[-1].text) != "}":
				start = int(pieces[-1].start)
				pieces.pop_back()
			_add_piece(pieces, source, cursor if start < 0 else start, cursor + 1)
			start = -1
		elif letter == "}":
			if start >= 0:
				_add_piece(pieces, source, start, cursor)
			_add_piece(pieces, source, cursor, cursor + 1)
			start = -1
		elif start < 0 and letter not in [" ", "\t"]:
			start = cursor
		if pieces.size() > MAX_NODES:
			return DataResult.failure("代码结构较多，请先缩短代码后再使用提示。")
		cursor += 1
	if start >= 0:
		_add_piece(pieces, source, start, source.length())
	for piece: Dictionary in pieces:
		if str(piece.text) == "}":
			if stack.size() <= 1:
				return DataResult.failure("请先删除多余的右花括号，再使用代码提示。")
			var block := stack.pop_back() as Dictionary
			block.close_start = piece.start
			block.close_end = piece.end
		else:
			var node := {"text": piece.text, "start": piece.start, "end": piece.end, "block": str(piece.text).ends_with("{"), "children": [], "close_start": -1, "close_end": -1}
			stack[-1].children.append(node)
			if node.block:
				stack.append(node)
	for index in range(1, stack.size()):
		root.open_blocks.append(stack[index])
	return DataResult.success(root)


## 记录不含尾部空白和注释的源码片段，语法归一化不改变原始替换位置。
static func _add_piece(pieces: Array[Dictionary], source: String, start: int, finish: int) -> void:
	while finish > start and source[finish - 1] in [" ", "\t", "\r", "\n"]:
		finish -= 1
	if finish > start:
		pieces.append({"text": _without_comments(source.substr(start, finish - start)).strip_edges(), "start": start, "end": finish})


## 忽略空白比较逻辑步骤，避免将玩家已有的紧凑格式改成参考排版。
static func _normal(text: String) -> String:
	return text.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")


## 获取代码结构类型，动作名称和函数名仍在完整文本比较中严格检查。
static func _kind(text: String) -> String:
	var value := text.strip_edges()
	for kind: String in ["function", "main", "tick", "loop", "for", "if", "else", "simultaneously", "variable", "constant", "value"]:
		if value == kind or value.begins_with(kind + " ") or value.begins_with(kind + "(") or value.begins_with(kind + "{"):
			return kind
	var assignment := RegEx.new()
	assignment.compile("^[A-Za-z_][A-Za-z0-9_]*\\s*=(?!=)")
	if assignment.search(value) != null:
		return "assignment"
	return "action"


## 只读取声明或赋值的目标名称，用于本层参考步骤匹配，不求值也不改写无关绑定。
static func _binding_name(text: String) -> String:
	var kind := _kind(text)
	if kind not in ["variable", "constant", "value", "assignment"]:
		return ""
	var expression := RegEx.new()
	expression.compile("^(?:(?:variable|constant|value)\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*=(?!=)")
	var matched := expression.search(text.strip_edges())
	return matched.get_string(1) if matched != null else ""


## 顶层函数按真实名称定位，避免把玩家另一个独立函数当作待覆盖的目标。
static func _root_key(text: String) -> String:
	var normalized := _normal(text)
	return normalized.get_slice("(", 0)


## 只删除注释的临时副本，用于识别函数声明；注释原文不会写回或丢失。
static func _without_comments(source: String) -> String:
	var lines := source.split("\n")
	for index in lines.size():
		lines[index] = lines[index].get_slice("//", 0)
	return "\n".join(lines)


## 读取当前物理行的缩进；紧凑代码内没有独立缩进时返回空串。
static func _indent_at(source: String, offset: int) -> String:
	var beginning := source.rfind("\n", offset - 1) + 1 if offset > 0 else 0
	var segment := source.substr(beginning, offset - beginning)
	return segment if segment.strip_edges().is_empty() else ""
