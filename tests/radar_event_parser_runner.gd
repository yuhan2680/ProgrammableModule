extends SceneTree
## 雷达事件的词法、权限、固定语法与公开 AST 校验均只使用内存数据，不创建模拟世界。

var _checks: int = 0
var _failures: int = 0
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 延迟执行测试，使 Godot 完成脚本和全局类初始化。
func _initialize() -> void:
	_run.call_deferred()


## 各组检查共享失败计数并提供稳定完成标记，退出码直接反映结果。
func _run() -> void:
	_test_lexer()
	_test_permissions()
	_test_valid_events()
	_test_fixed_syntax()
	_test_binding_rules()
	_test_event_limits()
	_test_public_ast()
	_test_legacy_programs()
	print("雷达事件语法回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 箭头是独立的连续 token；原有负号、比较符、范围与小数词法保持不变。
func _test_lexer() -> void:
	var lexed := ProgramLexer.tokenize("// 注释\r\n  EnemyPosition -> target\n1-2 > -3\n.5 1. 0..315")
	if not _check(lexed.is_ok(), "事件和旧数值词法可共同扫描"):
		return
	var tokens: Array[ProgramLexer.Token] = lexed.value
	_check(tokens[2].kind == ProgramLexer.Kind.ARROW and tokens[2].lexeme == "->", "连续箭头有明确 ARROW 类型")
	_check(tokens[2].line == 2 and tokens[2].column == 17, "CRLF 与前导空白之后箭头位置准确")
	var kinds: Array[int] = []
	for token: ProgramLexer.Token in tokens:
		kinds.append(token.kind)
	_check(kinds.count(ProgramLexer.Kind.MINUS) == 2 and kinds.count(ProgramLexer.Kind.GREATER) == 1, "减法、负号和大于号不被改为箭头")
	_check(kinds.count(ProgramLexer.Kind.RANGE) == 1 and kinds.count(ProgramLexer.Kind.NUMBER) == 7, "范围与两种小数字面量不回归")
	var separated: Array[ProgramLexer.Token] = ProgramLexer.tokenize("- >").value
	_check(separated[0].kind == ProgramLexer.Kind.MINUS and separated[1].kind == ProgramLexer.Kind.GREATER, "带空格的减号与大于号不能合并成箭头")


## 新权限与雷达、变量、具名调用分别判断，事件不会连带开放其它语言功能。
func _test_permissions() -> void:
	var source := "variable target=0\nsensor.onDetected { EnemyPosition -> target }\nmain(){}"
	_check(_parse(source).is_ok(), "四项权限全部开启可声明雷达事件")
	var legacy := ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true, true)
	_check_error(legacy, "尚未解锁 onDetected", "旧十三参数接口默认关闭雷达事件")
	_check_error(_parse_flags(source, true, true, true, false), "尚未解锁 onDetected", "独立事件开关关闭时拒绝注册")
	_check_error(_parse_flags(source, true, true, false, true), "需要先解锁 scan", "事件权限不隐式打开雷达")
	_check_error(_parse_flags("sensor.onDetected { EnemyPosition -> target }\nmain(){}", true, false, true, true), "需要先解锁常量、变量", "事件权限不隐式打开变量")
	_check_error(_parse_flags(source, false, true, true, true), "需要先解锁命名模块调用", "事件权限不隐式打开具名调用")
	_check(ProgramParser.parse("main(){move(0,1)}", _calls, false, false, false, false, false, false, false, false, false, false, false, true).is_ok(), "没有事件的旧代码不因单独打开事件权限而失败")


## 事件保留显式来源、绑定和源码位置；目标成员复用既有快照表达式。
func _test_valid_events() -> void:
	var parsed := _parse("variable target=null\n  sensor.onDetected { EnemyPosition -> target }\nmain(){if(target!=null){move(target.Angle(),target.Distance)}}")
	if _check(parsed.is_ok(), "空值初始化、事件绑定和判空后的目标属性可解析"):
		var ast := parsed.value as ProgramAst.ProgramNode
		_check(ast.radar_events.size() == 1 and ast.globals.size() == 1, "事件独立于全局声明与函数语句保存")
		var event := ast.radar_events[0]
		_check(event.receiver == "sensor" and event.binding_name == "target", "事件只保存具名雷达和已有目标名称")
		_check(event.line == 2 and event.column == 3, "事件诊断位置指向真实雷达实例名")
		_check(ast.main.body.statements.size() == 1 and ast.functions.is_empty(), "注册不产生隐式函数或 main 调用")
	for initializer in ["Null", "0", "scan()", "sensor.scan()"]:
		_check(_parse("variable target=" + initializer + "\nsensor.onDetected{EnemyPosition->target}\nmain(){}").is_ok(), "事件绑定接受合法的全局变量初始值：" + initializer)
	for member in ["target.Angle()", "target.Distance", "target.Distance()", "target.Position.x", "target.Position.y"]:
		_check(_parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){move(" + member + ",0)}").is_ok(), "事件目标复用已有快照成员：" + member)
	_check(_parse("variable target=null\nmain(){}\nsensor.onDetected\n{\n// 固定映射\nEnemyPosition\n->\ntarget\n}\n").is_ok(), "顶层注册允许位于 main 后并按 token 换行和注释")
	_check(_parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){constant point=target.Position\nmove(point.x,point.y)}").is_ok(), "事件目标位置可作为既有二维快照存入常量")


## 固定事件映射拒绝参数、任意回调体、错误载荷、属性写入和非顶层注册。
func _test_fixed_syntax() -> void:
	for declaration in [
		"sensor.onDetected() { EnemyPosition -> target }",
		"sensor.onDetected { }",
		"sensor.onDetected { enemyPosition -> target }",
		"sensor.onDetected { target -> EnemyPosition }",
		"sensor.onDetected { EnemyPosition - > target }",
		"sensor.onDetected { EnemyPosition => target }",
		"sensor.onDetected { EnemyPosition target }",
		"sensor.onDetected { EnemyPosition -> }",
		"sensor.onDetected { EnemyPosition -> target.Position }",
		"sensor.onDetected { EnemyPosition -> target() }",
		"sensor.onDetected { EnemyPosition -> variable target }",
		"sensor.onDetected { EnemyPosition -> target=0 }",
		"sensor.onDetected { EnemyPosition -> target\nshoot(0) }",
		"sensor.onDetected { EnemyPosition -> target\nEnemyPosition -> target }",
		"sensor.onDetected { shoot(0) }",
		"onDetected { EnemyPosition -> target }",
		"sensor.onDetected { EnemyPosition -> target };",
		"sensor.onDetected { EnemyPosition -> target } move(0,0)",
		"sensor.onDetected { EnemyPosition -> target",
	]:
		_check_error(_parse("variable target=null\n" + declaration + "\nmain(){}"), "", "固定事件语法拒绝非法结构：" + declaration)
	for body in [
		"main(){sensor.onDetected{EnemyPosition->target}}",
		"main(){loop{sensor.onDetected{EnemyPosition->target}}}",
		"main(){if(target==null){sensor.onDetected{EnemyPosition->target}}}",
		"main(){for(angle in 0..1){sensor.onDetected{EnemyPosition->target}}}",
		"main(){simultaneously{sensor.onDetected{EnemyPosition->target}}}",
		"main(){}\ntick(){sensor.onDetected{EnemyPosition->target}}",
		"main(){}\nfunction unused(){sensor.onDetected{EnemyPosition->target}}",
	]:
		_check_error(_parse("variable target=null\n" + body), "只能在顶层注册", "任何函数和控制块都不能注册事件：" + body)
	var located := _parse("variable target=null\nsensor.onDetected{\nEnemyPosition - > target\n}\nmain(){}")
	_check_error(located, "第 3 行，第 15 列", "非法箭头位置精确指向不连续减号")
	_check_error(_parse("variable target=null\nmain.onDetected{EnemyPosition->target}\nmain(){}"), "模块名必须", "保留入口名不能作为事件雷达实例")


## 只有注册前显式声明的全局可变名称能接收事件，常量和局部名称均不能替代。
func _test_binding_rules() -> void:
	_check_error(_parse("sensor.onDetected{EnemyPosition->target}\nmain(){}"), "已声明的全局 variable", "缺失目标不会被隐式声明")
	_check_error(_parse("sensor.onDetected{EnemyPosition->target}\nvariable target=null\nmain(){}"), "必须先声明全局 variable", "事件不能前向绑定稍后的全局变量")
	for keyword in ["constant", "value"]:
		_check_error(_parse(keyword + " target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){}"), "不能绑定常量", "事件不能改写全局常量：" + keyword)
	_check_error(_parse("main(){variable target=null}\nsensor.onDetected{EnemyPosition->target}"), "已声明的全局 variable", "main 局部变量不能接收事件")
	_check_error(_parse("function helper(){variable target=null}\nsensor.onDetected{EnemyPosition->target}\nmain(){}"), "已声明的全局 variable", "用户函数局部变量不能接收事件")
	_check_error(_parse("sensor.onDetected{EnemyPosition->helper}\nfunction helper(){move(0,0)}\nmain(){}"), "已声明的全局 variable", "函数名不能代替全局目标")
	_check_error(_parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){target.Distance=1}"), "", "事件目标成员继续只读")
	_check(_parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){variable target=2\nmove(target,0)}").is_ok(), "main 局部遮蔽不会改变事件的全局绑定")
	_check(_parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){target=null}").is_ok(), "事件绑定后仍可通过普通赋值更新全局变量")


## 每个雷达和目标各自唯一，数量限制在解析与静态 AST 边界上保持一致。
func _test_event_limits() -> void:
	var base := "variable first=null\nvariable second=null\nsensor.onDetected{EnemyPosition->first}\n"
	_check_error(_parse(base + "sensor.onDetected{EnemyPosition->second}\nmain(){}"), "不能重复注册", "同一雷达不能注册两个目标")
	_check_error(_parse(base + "other.onDetected{EnemyPosition->first}\nmain(){}"), "不能被多个雷达事件重复绑定", "两个雷达不能写入同一目标")
	_check(_parse(base + "other.onDetected{EnemyPosition->second}\nmain(){}").is_ok(), "独立雷达可以分别绑定独立目标")
	_check(_parse(_many_events(32)).is_ok(), "恰好三十二项事件绑定可解析")
	_check_error(_parse(_many_events(33)), "最多允许 32 个", "第三十三项注册触发事件数量上限")


## 手工构造或修改后的 AST 必须重验结构、重复项和全局可变绑定，不依赖解析器可信性。
func _test_public_ast() -> void:
	for mode in ["null", "empty_receiver", "bad_receiver", "long_receiver", "empty_binding", "bad_binding", "reserved_binding", "duplicate_receiver", "duplicate_binding", "limit"]:
		var ast := _valid_ast()
		match mode:
			"null": ast.radar_events[0] = null
			"empty_receiver": ast.radar_events[0].receiver = ""
			"bad_receiver": ast.radar_events[0].receiver = "sensor.scan()"
			"long_receiver": ast.radar_events[0].receiver = "s".repeat(129)
			"empty_binding": ast.radar_events[0].binding_name = ""
			"bad_binding": ast.radar_events[0].binding_name = "target.Position"
			"reserved_binding": ast.radar_events[0].binding_name = "scan"
			"duplicate_receiver": ast.radar_events.append(ast.radar_events[0])
			"duplicate_binding":
				var event := ProgramAst.RadarEventNode.new()
				event.receiver = "other"
				event.binding_name = "target"
				ast.radar_events.append(event)
			"limit":
				while ast.radar_events.size() <= ProgramParser.MAX_RADAR_EVENTS:
					ast.radar_events.append(ast.radar_events[0])
		_check_error(ProgramFunctionValidation.validate(ast), "", "函数结构校验拒绝事件坏 AST：" + mode)
		_check_error(ProgramVariableValidation.validate(ast), "", "独立变量校验也拒绝事件坏 AST：" + mode)
	for mode in ["missing_global", "constant", "forward", "local_only"]:
		var ast := _valid_ast()
		match mode:
			"missing_global": ast.radar_events[0].binding_name = "unknown"
			"constant": ast.globals[0].mutable = false
			"forward": ast.globals[0].line = 100
			"local_only":
				ast.main.body.statements.append(ast.globals[0])
				ast.globals.clear()
		_check_error(ProgramVariableValidation.validate(ast), "", "公开 AST 不能绕过全局绑定规则：" + mode)


## 前十四关既有合法写法和各自独立权限保留，不扩大关键字保留范围。
func _test_legacy_programs() -> void:
	for source in [
		"main(){move(-90,.5)}",
		"main(){left.attack(180)\nright.shoot(0)}",
		"main(){loop{if(gun.ready()){shoot(0)}else{move(0,.1)}}}",
		"main(){simultaneously{left.attack(180)\nright.attack(0)}}",
		"main(){move(0,sensor.distance(0)-.5)}",
		"variable target=null\nmain(){target=sensor.scan()\nif(target!=Null){shoot(target.Angle())}}",
		"constant size=1\nmain(){helper()}\nfunction helper(){move(randomInt(0,359),random()+size)}",
		"main(){for(angle in 0..315 step 45){shoot(angle)}}",
		"variable EnemyPosition=0\nvariable onDetected=1\nmain(){move(EnemyPosition,onDetected)}",
	]:
		var result := ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true, true)
		_check(result.is_ok(), "事件默认关闭仍保留旧合法代码：" + source)
		if result.is_ok():
			_check(result.value.radar_events.is_empty(), "旧代码不产生隐式雷达事件")
	_check(ProgramParser.parse("main(){move(0,1)}").is_ok(), "最旧单参数接口保持兼容")
	_check(not ProgramParser.parse("main(){variable x=1}").is_ok(), "前期关卡仍禁止变量")
	_check(not ProgramParser.parse("main(){sensor.move(0,1)}").is_ok(), "前期关卡仍禁止具名调用")


## 专项夹具显式打开全部现有能力及新事件权限，不影响正式关卡默认值。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true, true, true)


## 单独切换事件所需四项权限，其他开关不参与注册语法判断。
func _parse_flags(source: String, named: bool, variables: bool, radar: bool, events: bool) -> DataResult:
	return ProgramParser.parse(source, _calls, false, named, false, false, false, false, false, variables, radar, false, false, events)


## 构造独立全局和独立雷达名称，避免重复校验掩盖真正的数量边界。
func _many_events(count: int) -> String:
	var source := ""
	for index in count:
		source += "variable target%d=null\n" % index
	for index in count:
		source += "sensor%d.onDetected{EnemyPosition->target%d}\n" % [index, index]
	return source + "main(){}"


## 每项公开边界测试从单独合法树开始，避免前一个变更污染后一个断言。
func _valid_ast() -> ProgramAst.ProgramNode:
	return _parse("variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){}").value as ProgramAst.ProgramNode


## 失败必须包含源码位置和需要的诊断片段，避免仅因任意脚本失败而误通过。
func _check_error(result: DataResult, fragment: String, label: String) -> void:
	var valid := not result.is_ok() and not result.errors.is_empty()
	if valid:
		valid = result.errors[0].contains("第 ") and (fragment.is_empty() or result.errors[0].contains(fragment))
	_check(valid, label + "：" + str(result.errors))


## 所有断言失败继续收集，以便一次运行看见全部兼容性问题。
func _check(condition: bool, label: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("检查失败：" + label)
	return condition
