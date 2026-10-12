extends SceneTree
## 指令策略回归直接编译内存源码，不读取玩家存档、不创建世界或场景控件。

var _checks := 0
var _failures := 0
var _calls := PackedStringArray(["move", "attack", "shoot"])


## 延后到项目类完成注册后运行，退出码与稳定标记用于统一测试入口。
func _initialize() -> void:
	_run.call_deferred()


## 按现有二十七种指令、嵌套位置、广播区别和旧接口兼容逐组检查。
func _run() -> void:
	_test_each_command()
	_test_named_and_broadcast()
	_test_hidden_source()
	_test_expression_locations()
	_test_member_aliases()
	_test_legacy_and_validation()
	print("COMMAND_POLICY_PARSER_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 每个开关开启时接受真实语法，关闭时拒绝同一源代码，而不是只检测目录过滤。
func _test_each_command() -> void:
	var cases := [
		["move", "main(){move(0,1)}", ["move"]],
		["attack", "main(){attack(0)}", ["attack"]],
		["shoot", "main(){shoot(0)}", ["shoot"]],
		["tick", "main(){}\ntick(){shoot(0)}", ["tick", "shoot"]],
		["named_calls", "main(){drive.move(0,1)}", ["named_move"]],
		["named_move", "main(){drive.move(0,1)}", ["named_move"]],
		["named_attack", "main(){blade.attack(0)}", ["named_attack"]],
		["named_shoot", "main(){gun.shoot(0)}", ["named_shoot"]],
		["loop", "main(){loop{move(0,1)}}", ["loop", "move"]],
		["if_else", "main(){if(1==1){move(0,1)}}", ["if_else", "move"]],
		["ready", "main(){if(gun.ready()){shoot(0)}}", ["ready", "shoot"]],
		["simultaneously", "main(){simultaneously{move(0,1)\nattack(0)}}", ["simultaneously", "move", "attack"]],
		["distance", "main(){move(distance(0),1)}", ["move", "distance"]],
		["named_distance", "main(){move(sensor.distance(0),1)}", ["move", "named_distance"]],
		["functions", "main(){helper()}\nfunction helper(){move(0,1)}", ["functions", "move"]],
		["constants", "constant heading=0\nmain(){move(heading,1)}", ["constants", "move"]],
		["variables", "variable count=0\nmain(){count=count+1\nmove(count,1)}", ["variables", "move"]],
		["scan", "constant target=scan()\nmain(){}", ["constants", "scan"]],
		["named_scan", "constant target=sensor.scan()\nmain(){}", ["constants", "named_scan"]],
		["radar_angle", "variable target=scan()\nmain(){move(target.Angle(),1)}", ["variables", "scan", "radar_angle", "move"]],
		["radar_position", "variable target=scan()\nmain(){constant point=target.Position\nmove(point.x,point.y)}", ["variables", "scan", "constants", "radar_position", "move"]],
		["radar_distance", "variable target=scan()\nmain(){move(target.Distance,1)}", ["variables", "scan", "radar_distance", "move"]],
		["radar_event", "variable target=null\nsensor.onDetected{EnemyPosition->target}\nmain(){}", ["radar_event"]],
		["random", "main(){move(random(),1)}", ["random", "move"]],
		["random_int", "main(){move(randomInt(0,90),1)}", ["random_int", "move"]],
		["for_range", "main(){for(angle in 0..2 step 1){move(angle,1)}}", ["for_range", "move"]],
	]
	_check(cases.size() + 1 == CommandPermissions.COMMAND_IDS.size(), "矩阵覆盖全部可切换指令和必要入口")
	_check(_parse("main(){}", PackedStringArray(["main"])).is_ok(), "仅开启必要入口仍可编译空 main")
	_error(_parse("main(){}", []), "必要的程序入口", "显式策略不能关闭 main")
	for item in cases:
		var identity: String = item[0]
		var source: String = item[1]
		var policy := _policy(item[2])
		_check(_parse(source, policy).is_ok(), "开启后允许真实语法：" + identity)
		var disabled := CommandPermissions.toggle(policy, identity, false)
		if not _check(disabled.is_ok(), "关闭指令返回有效策略：" + identity):
			continue
		_error(_parse(source, disabled.value), "本关限制使用指令", "关闭后源码不能绕过：" + identity)


## 具名形式与广播形式可以分别关闭，具名总开关仍覆盖所有实例名调用。
func _test_named_and_broadcast() -> void:
	for item in [
		["move", "named_move", "move(0,1)", "drive.move(0,1)"],
		["attack", "named_attack", "attack(0)", "blade.attack(0)"],
		["shoot", "named_shoot", "shoot(0)", "gun.shoot(0)"],
		["distance", "named_distance", "move(distance(0),1)", "move(sensor.distance(0),1)"],
		["scan", "named_scan", "constant target=scan()", "constant target=sensor.scan()"],
	]:
		var broadcast: String = item[0]
		var named: String = item[1]
		var common: Array = ["constants", "move"] if broadcast in ["distance", "scan"] else []
		# move 测距参数仍是广播动作，不能为测试误关其宿主语句。
		var named_ids := _policy(common + [named])
		var broadcast_ids := _policy(common + [broadcast])
		var broadcast_source := str(item[2]) + "\nmain(){}" if broadcast == "scan" else "main(){" + str(item[2]) + "}"
		var named_source := str(item[3]) + "\nmain(){}" if broadcast == "scan" else "main(){" + str(item[3]) + "}"
		_check(_parse(named_source, named_ids).is_ok(), "只开启具名形态无需广播版本：" + named)
		_error(_parse(broadcast_source, named_ids), "本关限制使用指令", "具名权限不开放广播：" + broadcast)
		_check(_parse(broadcast_source, broadcast_ids).is_ok(), "只开启广播形态无需具名权限：" + broadcast)
		_error(_parse(named_source, broadcast_ids), "本关限制使用指令", "广播权限不开放具名：" + named)


## 所有源代码都接受策略检查，未调用函数、tick、死分支和全局初始化同样受限。
func _test_hidden_source() -> void:
	var policy := _policy(["functions", "tick", "if_else", "loop", "simultaneously", "variables", "for_range", "move", "random"])
	for source in [
		"main(){}\nfunction unused(){shoot(0)}",
		"function unused(){shoot(0)}\nmain(){}",
		"main(){}\ntick(){shoot(0)}",
		"main(){if(0==1){shoot(0)}}",
		"main(){if(1==1){move(0,1)}else{shoot(0)}}",
		"main(){loop{if(0==1){shoot(0)}}}",
		"main(){simultaneously{move(0,1)\nshoot(0)}}",
		"main(){for(angle in 0..2){shoot(angle)}}",
		"variable value1=randomInt(0,1)\nmain(){}",
	]:
		_error(_parse(source, policy), "本关限制使用指令", "不执行的源码位置也被静态拒绝：" + source)
	var earliest := _parse("// 注释\nmain(){\n  move(0,1)\n}\nfunction unused(){shoot(0)}", _policy(["functions"]))
	_error(earliest, "第 3 行，第 3 列", "报错位置取源代码最早受限指令，跨 AST 字段仍准确")
	_check(_parse("// shoot(0), sensor.scan(), function unused()\nmain(){}", PackedStringArray(["main"])).is_ok(), "注释中的指令文字不会误触限制")


## 数值加减、条件、范围端点和查询参数中的指令不能通过嵌套表达式规避。
func _test_expression_locations() -> void:
	var policy := _policy(["move", "distance", "if_else", "for_range", "constants", "variables", "loop", "functions"])
	for source in [
		"main(){move((1+(randomInt(0,90)-1)),1)}",
		"main(){move(distance(randomInt(0,90)),1)}",
		"main(){if(randomInt(0,1)==1){move(0,1)}}",
		"main(){if(1==randomInt(0,1)){move(0,1)}}",
		"main(){for(angle in randomInt(0,1)..2){move(angle,1)}}",
		"main(){for(angle in 0..randomInt(1,2)){move(angle,1)}}",
		"main(){for(angle in 0..2 step randomInt(1,2)){move(angle,1)}}",
		"constant value1=1+(randomInt(0,1))\nmain(){}",
		"variable value1=0\nmain(){value1=1+randomInt(0,1)}",
		"main(){}\nfunction unused(){constant value1=randomInt(0,1)\nmove(value1,1)}",
	]:
		_error(_parse(source, policy), "“random_int”", "嵌套表达式仍检查实际查询：" + source)
	var limited := _policy(["move", "random", "random_int"])
	_check(_parse("main(){move(randomInt(random(),90),1)}", limited).is_ok(), "允许时嵌套查询仍按原语法生成 AST")
	limited = CommandPermissions.toggle(limited, "random", false).value
	_error(_parse("main(){move(randomInt(random(),90),1)}", limited), "“random”", "内层 random 不因外层 randomInt 被开启")


## 现有别名共享同一策略；位置向量保存后读取 x/y 也检查目标位置权限。
func _test_member_aliases() -> void:
	var all := _policy(["move", "constants", "variables", "scan", "named_scan", "radar_angle", "radar_position", "radar_distance"])
	for declaration: String in ["constant", "value"]:
		var source := declaration + " value1=0\nmain(){move(value1,1)}"
		_check(_parse(source, _policy(["constants", "move"])).is_ok(), "常量别名由 constants 单独允许：" + declaration)
		_error(_parse(source, _policy(["variables", "move"])), "“constants”", "变量权限不隐式开启常量别名：" + declaration)
	for item in [
		["radar_angle", "target.Angle()"],
		["radar_distance", "target.Distance"],
		["radar_distance", "target.Distance()"],
		["radar_position", "target.Position.x"],
		["radar_position", "target.Position.y"],
	]:
		var source := "variable target=scan()\nmain(){move(" + str(item[1]) + ",1)}"
		_check(_parse(source, all).is_ok(), "既有目标成员在开启时保持语法：" + str(item[1]))
		_error(_parse(source, CommandPermissions.toggle(all, item[0], false).value), "“" + str(item[0]) + "”", "目标成员按自己的权限检查：" + str(item[1]))
	_check(_parse("variable target=scan()\nconstant point=target.Position\nmain(){move(point.x,point.y)}", all).is_ok(), "目标位置可以按旧语义存入只读别名")
	# 此处仅验证源码的成员形态；数值不能当向量的运行时类型检查仍由 Runner 负责。
	for coordinate: String in ["x", "y"]:
		_error(_parse("variable point=0\nmain(){move(point." + coordinate + ",1)}", _policy(["variables", "move"])), "“radar_position”", "无需同一行 Position 前缀，独立坐标成员仍受位置权限限制：" + coordinate)
	_check(_parse("variable target=Null\nmain(){}", _policy(["variables"])).is_ok(), "无目标 null/Null 不是额外扫描指令，保持原有字面量语义")


## nullable 新参数不更改旧解锁；无效显式列表不能偷偷修正或扩大权限。
func _test_legacy_and_validation() -> void:
	var minimal := PackedStringArray(["main", "move"])
	var before := minimal.duplicate()
	_check(_parse("main(){move(0,1)}", minimal).is_ok() and minimal == before, "编译不修改调用方 PackedStringArray")
	var array_ids := Array(minimal)
	_check(_parse("main(){move(0,1)}", array_ids).is_ok() and array_ids == Array(before), "JSON Array 与 Packed 接口语义一致且原数组不变")
	for invalid in [false, "main", {}, ["main", "unknown"], ["main", "move", "move"], ["main", 3], ["main", "named_move"]]:
		_error(_parse("main(){}", invalid), "第 1 行，第 1 列", "非法显式策略拒绝且保留行列格式：" + str(invalid))
	_check(ProgramParser.parse("main(){move(0,1)}").is_ok(), "原二参数与默认接口保持可用")
	_check(_parse("main(){move(0,1)}", null).is_ok(), "显式 null 走原有解析路径")
	var old_disabled := ProgramParser.parse("main(){loop{move(0,1)}}", _calls)
	_error(old_disabled, "尚未解锁", "旧默认开关仍禁止 loop")
	var policy_cannot_unlock := ProgramParser.parse("main(){loop{move(0,1)}}", _calls, false, false, false, false, false, false, false, false, false, false, false, false, _policy(["loop", "move"]))
	_error(policy_cannot_unlock, "尚未解锁", "新策略不能绕过原解析能力开关")
	_check(_parse("main(){loop{move(0,1)}}", null).is_ok(), "无新策略且旧布尔能力开启仍接受旧源码")
	var repeat := _parse("main(){shoot(0)}", minimal)
	_error(repeat, "“shoot”", "策略只作用于本次编译")
	_check(_parse("main(){shoot(0)}", null).is_ok(), "下一次旧编译不继承之前的限制")


## 测试调用显式打开旧语法家族，把新策略作用与旧能力开关分离。
func _parse(source: String, enabled_commands: Variant = null) -> DataResult:
	return ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true, true, true, enabled_commands)


## 夹具只按用户开启的策略补足已声明的依赖，生产解析本身不做此修正。
func _policy(ids: Array) -> PackedStringArray:
	var values := ["main"]
	for identity in ids:
		if identity not in values:
			values.append(identity)
	var checked := CommandPermissions.normalize_enabled(values)
	if not checked.is_ok():
		_check(false, "夹具依赖有效：" + " ".join(checked.errors))
		return PackedStringArray(["main"])
	return checked.value


## 失败必须包含明确原因且带真实行列位置，不能返回无上下文的通用错误。
func _error(result: DataResult, expected: String, description: String) -> void:
	var message := " ".join(result.errors)
	_check(not result.is_ok() and expected in message and "行，第" in message, description + "：" + message)


## 汇总所有检查，出现失败时打印足够定位夹具和规则的信息。
func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("指令策略解析失败：" + description)
	return condition
