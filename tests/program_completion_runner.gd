extends SceneTree
## 行内补全的纯策略回归：使用全部真实教学关卡权限，禁止查询或修改玩家存档。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()
var _levels: Array[LevelDefinition] = []


## 等待类注册完成后执行纯数据测试。
func _initialize() -> void:
	_run.call_deferred()


## 加载真实关卡，覆盖逐关解锁、上下文边界与具名类型，再统一报告结果。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "真实注册表可用于补全"):
		quit(1)
		return
	for number in range(1, 13):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(loaded.is_ok(), "第 %d 关地图可读取" % number):
			quit(1)
			return
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "第 %d 关规则可读取" % number):
			quit(1)
			return
		_levels.append(defined.value)
	_test_level_unlocks()
	_test_editing_boundaries()
	_test_contexts()
	_test_named_methods()
	_test_independent_flags_and_purity()
	_test_user_functions()
	_test_numeric_bindings()
	_test_radar_bindings()
	_test_direct_radar_members_and_flow()
	_test_random_functions()
	_test_for_ranges()
	print("补全候选回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 每关都读取实际能力开关，不能靠关卡序号或注册表新增内容隐式提前解锁。
func _test_level_unlocks() -> void:
	for index in range(_levels.size()):
		var level := _levels[index]
		var assembly := _assembly(level)
		_expect("ma|", "in", level, assembly, "所有关卡提供 main")
		_expect("fun|", "ction" if level.allow_functions else "", level, assembly, "function 按独立权限解锁")
		_expect("co|", "nstant" if level.allow_variables else "", level, assembly, "constant 按独立权限解锁")
		_expect("main(){var|}", "iable" if level.allow_variables else "", level, assembly, "variable 按独立权限解锁")
		_expect("main(){}\nti|", "ck" if level.allow_tick else "", level, assembly, "tick 按本关权限")
		for entry in [["mo", "ve", "move"], ["at", "tack", "attack"], ["sh", "oot", "shoot"]]:
			_expect("main(){\n" + entry[0] + "|\n}", entry[1] if entry[2] in level.allowed_calls else "", level, assembly, "动作按本关 allowed_calls")
		_expect("main(){\nfo|\n}", "r" if level.allow_for else "", level, assembly, "for 按独立权限解锁")
		_expect("main(){\nlo|\n}", "op" if level.allow_loops else "", level, assembly, "loop 按本关权限")
		_expect("main(){\ni|\n}", "f" if level.allow_conditionals else "", level, assembly, "if 按本关权限")
		_expect("main(){\nsi|\n}", "multaneously" if level.allow_simultaneous else "", level, assembly, "并行按本关权限")
		var expression_call := "move(0," if "move" in level.allowed_calls else "shoot("
		_expect("main(){" + expression_call + "di|)}", "stance" if level.allow_distance else "", level, assembly, "测距按本关权限")
		_expect("main(){" + expression_call + "ra|)}", "ndom" if level.allow_random else "", level, assembly, "随机小数按本关独立权限")
		_expect("main(){" + expression_call + "randomI|)}", "nt" if level.allow_random else "", level, assembly, "随机整数按本关独立权限")
		_expect("main(){dr|}", "ive" if level.allow_named_calls and "movement" in level.allowed_modules else "", level, assembly, "只提供已解锁的实际装配名称")


## 只补光标位置的未完成单词，不触碰注释、字符串、已有后缀或数值字面量。
func _test_editing_boundaries() -> void:
	var level := _levels[0]
	var assembly := _assembly(level)
	for source in ["main(){|}", "main(){move|}", "main(){moo|}", "main(){m|ove}", "main(){1mo|}", "main(){3.mo|}", "main(){MO|}", "main(){中文mo|}", "main(){// mo|\n}", "main(){\nmo // mo|\n}", "main(){\"mo|\"}", "main(){'mo|'}", "main(){/* mo| */}", "main(){unknown.mo|}", "main(){move(0, mo|)}"]:
		_expect(source, "", level, assembly, "不适合补全的位置保持为空")
	_expect("main(){mo|()}", "ve", level, assembly, "已有函数括号只补缺少的字母")
	_expect("main(){\n\tmo|\n}", "ve", level, assembly, "制表符缩进按源码字符计算位置")
	_expect("// 上一行注释里的 mo\nmain(){\n mo|\n}", "ve", level, assembly, "上一行注释不干扰当前指令")
	_expect("main(){\n // shoot { }\n mo|\n}", "ve", level, assembly, "注释里的括号不改变当前语法块")
	_expect("main(){\r\n\tmo|\r\n}", "ve", level, assembly, "CRLF 文本保留准确行列")
	_check(ProgramCompletion.suggest("mo", -1, 2, level, assembly).is_empty(), "负行号安全拒绝")
	_check(ProgramCompletion.suggest("mo", 0, 3, level, assembly).is_empty(), "越界列号安全拒绝")
	_check(ProgramCompletion.suggest("mo", 3, 2, level, assembly).is_empty(), "越界行号安全拒绝")
	_check(ProgramCompletion.suggest("main(){mo", 0, 9, null, assembly).is_empty(), "缺少关卡不会猜测解锁")
	var oversized := "//" + "x".repeat(ProgramLexer.MAX_SOURCE_BYTES) + "\nmain(){mo"
	_check(ProgramCompletion.suggest(oversized, 1, 9, level, assembly).is_empty(), "超出语言源码上限时有界拒绝")


## 代码块与表达式分别提供语法，tick 和并行块不会建议会被解析器拒绝的控制结构。
func _test_contexts() -> void:
	var level := _levels[8]
	var assembly := _assembly(level)
	var accepted := {
		"main(){}\nti|": "ck",
		"tick(){}\nma|": "in",
		"main(){loop{\nmo|\n}}": "ve",
		"main(){if(gun.ready()){\nsh|\n}}": "oot",
		"main(){if(gun.ready()){shoot(0)} el|}": "se",
		"main(){if(gun.ready()){shoot(0)}\n// 分支\nel|}": "se",
		"main(){if(gun.ready()){shoot(0)}\nmo|}": "ve",
		"main(){}\ntick(){sh|}": "oot",
		"main(){}\ntick(){at|}": "tack",
		"main(){}\ntick(){i|}": "f",
		"main(){simultaneously{\nmo|\n}}": "ve",
		"main(){move(0,di|)}": "stance",
		"main(){move(0, 3-di|)}": "stance",
		"main(){move(0, (di|))}": "stance",
		"main(){move(0, distance(di|))}": "stance",
		"main(){if(di|)}": "stance",
		"main(){if(distance(0) > di|)}": "stance",
		"main(){move(\n0,\n di|\n)}": "stance",
	}
	for source: String in accepted:
		_expect(source, accepted[source], level, assembly, "合法上下文产生精确后缀")
	for source in ["mo|", "main(){}\nma|", "tick(){}\nti|", "main(){ma|}", "main(){ti|}", "main(){}\ntick(){mo|}", "main(){}\ntick(){lo|}", "main(){}\ntick(){si|}", "main(){simultaneously{lo|}}", "main(){simultaneously{i|}}", "main(){simultaneously{si|}}", "main(){el|}", "main(){move(0,1) mo|}", "main(){di|}", "main(){move(0,1 di|)}", "main(){move(0,distance(0) di|)}", "main(){move(0,sh|)}", "main(){if(mo|)}", "main(){if(re|)}", "main(){unknown(di|)}", "main(){}\ntick(){move(0,di|)}", "main(){if((gun.r|))}", "main(){if(1+gun.r|)}"]:
		_expect(source, "", level, assembly, "非法或不匹配的上下文不提供提示")
	_expect("main(){loop{mo|}}", "", _levels[0], _assembly(_levels[0]), "手工输入锁定的 loop 块不会启用其内部建议")


## 命名补全来自真实模块实例，查询与动作按行为区分，重命名与删除立即反映。
func _test_named_methods() -> void:
	var level := _levels[8]
	var assembly := _assembly(level)
	for entry in [["main(){drive.mo|}", "ve"], ["main(){blade.at|}", "tack"], ["main(){gun.sh|}", "oot"], ["main(){if(gun.re|)}", "ady"], ["main(){move(0,sensor.di|)}", "stance"], ["main(){if(sen|)}", "sor"], ["main(){if(gu|)}", "n"], ["main(){move(0,sen|)}", "sor"], ["main(){bl|}", "ade"]]:
		_expect(entry[0], entry[1], level, assembly, "实际实例支持对应方法或名称")
	for source in ["main(){drive.sh|}", "main(){gun.mo|}", "main(){sensor.at|}", "main(){if(drive.re|)}", "main(){if(sensor.re|)}", "main(){gun.re|}", "main(){move(0,gun.re|)}", "main(){move(0,gun.di|)}", "main(){move(0,unknown.di|)}", "main(){unknown.mo|}", "main(){drive.extra.mo|}", "main(){gun . nope.sh|}", "main(){if(bl|)}", "main(){move(0,gu|)}", "main(){sen|}"]:
		_expect(source, "", level, assembly, "不能为错误模块或场合猜测方法")
	assembly.modules[0].id = "engine"
	_expect("main(){dr|}", "", level, assembly, "重命名后旧名称不再补全")
	_expect("main(){en|}", "gine", level, assembly, "重命名后补全新名称")
	assembly.modules.remove_at(0)
	_expect("main(){engine.mo|}", "", level, assembly, "已移除模块不再提供方法")
	assembly.modules.append({"id": "broken", "module_id": "unknown"})
	assembly.modules.append({"id": "bad-name", "module_id": "shooting"})
	assembly.modules.append(null)
	_expect("main(){br|}", "", level, assembly, "坏草稿中的未知类型不提供名称")
	_expect("main(){bad|}", "", level, assembly, "不合法的实例标识符不会被补全")
	_expect("main(){mo|}", "ve", level, null, "缺少装配时仍可提示关卡解锁的广播动作")
	_expect("main(){gun.sh|}", "", level, null, "缺少装配时不能编造命名模块")
	var custom := LevelDefinition.new()
	custom.allowed_modules = PackedStringArray(["custom_motor"])
	custom.allow_named_calls = true
	var custom_content := ContentRegistry.new()
	var motor := ModuleDefinition.new()
	motor.id = "custom_motor"
	motor.behavior = "MovementModule"
	custom_content.modules[motor.id] = motor
	var custom_assembly := AssemblyModel.create(custom, custom_content)
	custom_assembly.modules = [{"id": "engine", "module_id": motor.id}]
	_expect("main(){engine.mo|}", "ve", custom, custom_assembly, "自定义模块 ID 根据已注册行为获得方法，而非硬编码内置 ID")


## 自定义关卡的开关相互独立，重复查询不修改关卡、装配或任何源码数据。
func _test_independent_flags_and_purity() -> void:
	var level := LevelDefinition.new()
	level.allowed_modules = PackedStringArray(["movement", "melee", "shooting", "rangefinder"])
	level.allowed_calls = PackedStringArray(["move", "shoot"])
	var assembly := _assembly(level)
	level.allow_conditionals = true
	_expect("main(){if(gun.re|)}", "", level, assembly, "条件开关不会隐式启用具名查询")
	level.allow_named_calls = true
	_expect("main(){if(gun.re|)}", "ady", level, assembly, "条件和具名均允许后可提示 ready")
	_expect("main(){blade.at|}", "", level, assembly, "已装配近战也不能绕过 allowed_calls")
	level.allow_distance = true
	level.allow_conditionals = false
	_expect("main(){move(0,sen|)}", "sor", level, assembly, "测距独立于条件解锁")
	_expect("main(){if(di|)}", "", level, assembly, "测距不会隐式开放 if")
	level.allow_named_calls = false
	_expect("main(){move(0,di|)}", "stance", level, assembly, "广播测距独立于具名解锁")
	_expect("main(){move(0,sensor.di|)}", "", level, assembly, "测距不会隐式开放具名方法")
	level.allow_named_calls = true
	level.allowed_modules = PackedStringArray(["movement"])
	_expect("main(){gun.sh|}", "", level, assembly, "旧草稿不能绕过新的模块允许列表")
	var before_modules := JSON.stringify(assembly.modules)
	var before_calls := level.allowed_calls.duplicate()
	for unused in range(20):
		_expect("main(){mo|}", "ve", level, assembly, "重复建议稳定")
	_check(JSON.stringify(assembly.modules) == before_modules and level.allowed_calls == before_calls, "建议不会改变装配与关卡规则")


## 构造只供补全读取的命名实例；故意不运行模拟或写入正式装配草稿。
func _assembly(level: LevelDefinition) -> AssemblyModel:
	var assembly := AssemblyModel.create(level, _content)
	for entry in [["drive", "movement"], ["blade", "melee"], ["gun", "shooting"], ["sensor", "rangefinder"], ["dish", "radar"]]:
		if entry[1] in level.allowed_modules:
			assembly.modules.append({"id": entry[0], "module_id": entry[1], "offset": {"x": 0, "y": 0}})
	return assembly


## 以竖线标出测试光标，精确换算成 CodeEdit 的零起点行列。
func _expect(marked: String, expected: String, level: LevelDefinition, assembly: AssemblyModel, description: String) -> void:
	var caret := marked.find("|")
	var before := marked.left(caret).split("\n")
	var source := marked.erase(caret, 1)
	var actual := ProgramCompletion.suggest(source, before.size() - 1, before[before.size() - 1].length(), level, assembly)
	_check(actual == expected, "%s：%s → '%s'，实际 '%s'" % [description, marked.replace("\n", "↵"), expected, actual])


## 汇总断言并在失败时保留具体输入，方便定位回归。
func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("失败：" + description)
	return condition


## 自定义函数从完整声明收集，前后置均可用，函数体保留合法指令且阻止递归建议。
func _test_user_functions() -> void:
	var level: LevelDefinition = _levels[10]
	var assembly := _assembly(level)
	var declared := "function dodge() { move(90,1) }\n"
	_expect(declared + "main(){do|}", "dge", level, assembly, "已声明函数名可从 main 补全")
	_expect("main(){do|}\n" + declared, "dge", level, assembly, "后置声明也能在 main 提供函数名")
	_expect("function dodge(){mo|}\nmain(){}", "ve", level, assembly, "函数体内动作建议保持可用")
	_expect("function dodge(){if(di|)}\nmain(){}", "stance", level, assembly, "函数体条件中可以补全测距")
	_expect("function dodge(){loop{mo|}}\nmain(){}", "ve", level, assembly, "函数内嵌套循环仍可补全动作")
	_expect(declared + "function check(){do|}\nmain(){}", "dge", level, assembly, "函数可补全另外的已声明函数")
	_expect("main(){}\nfunction dodge(){move(0,0)}\nfun|", "ction", level, assembly, "定义过函数仍可提示新声明关键词")
	for source in [declared + "main(){}\ntick(){do|}", declared + "main(){simultaneously{do|}}", declared + "main(){move(0,do|)}", declared + "main(){if(do|)}", declared + "do|", "main(){do|}", "// function dodge() {}\nmain(){do|}", "function main(){}\nmain(){ma|}", "function dodge(value){}\nmain(){do|}", "function dodge(){do|}\nmain(){}", "function dodge(){check()}\nfunction check(){do|}\nmain(){}", declared + declared + "main(){do|}", "main(){function dodge(){}\ndo|}"]:
		_expect(source, "", level, assembly, "不合法的函数引用与递归调用不产生建议")
	_expect(declared + "main(){do|}", "", _levels[8], _assembly(_levels[8]), "旧关手工声明函数也不会启用补全")


## 常变量建议遵守声明顺序、独立函数和子块作用域，读取与赋值候选严格区分。
func _test_numeric_bindings() -> void:
	var level: LevelDefinition = _levels[10]
	var assembly := _assembly(level)
	var accepted := {
		"val|": "ue",
		"constant step = 1\nmain(){move(0,st|)}": "ep",
		"main(){move(0,st|)}\nconstant step = 1": "ep",
		"constant step = 1\nconstant twice = st|\nmain(){}": "ep",
		"main(){variable direction=90\ndir|}": "ection",
		"main(){variable direction=90\ndirection=dir|}": "ection",
		"main(){constant step=1\nvariable direction=st|}": "ep",
		"main(){variable direction=90\nif(distance(0)>1){move(dir|,1)}}": "ection",
		"constant global_step=1\nfunction dodge(){move(0,global_|)}\nmain(){}": "step",
		"constant step=1\nmain(){variable step=st|}": "ep",
		"variable direction=90\nmain(){}\ntick(){shoot(dir|)}": "ection",
		"variable direction=90\nmain(){simultaneously{shoot(dir|)}}": "ection",
		"main(){variable reading = di|}": "stance",
		"main(){variable reading = (di|)}": "stance",
	}
	for source: String in accepted:
		_expect(source, accepted[source], level, assembly, "可见数值名称和声明产生正确后缀")
	for source in ["main(){move(0,st|)\nconstant step=1}", "constant first=fut|\nconstant future_value=2\nmain(){}", "main(){variable local=1}\nfunction dodge(){move(0,lo|)}", "main(){loop{variable local=1}\nmove(0,lo|)}", "main(){if(distance(0)>1){variable local=1}else{move(0,lo|)}}", "// variable phantom=1\nmain(){move(0,ph|)}", "main(){constant step=1\nst|}", "main(){constant step=1\nstep=di|}", "main(){variable step=st|}", "main(){}\ntick(){var|}", "main(){simultaneously{co|}}", "variable direction=90\nmain(){}\ntick(){direction=dir|}", "variable direction=90\nmain(){simultaneously{direction=dir|}}", "main(){variable step=1\nloop{constant step=2\nst|}}"]:
		_expect(source, "", level, assembly, "不可见名称、常量写入和禁用块不会产生建议")
	_expect("constant step=1\nmain(){move(0,st|)}", "", _levels[8], _assembly(_levels[8]), "旧关手工声明不能启用变量建议")
	var custom := LevelDefinition.new()
	custom.allow_variables = true
	_expect("constant step=1\nmain(){move(0,st|)}", "ep", custom, null, "数值名称补全不依赖测距或条件权限")


## 雷达候选同时检查真实装配、独立权限及词法作用域，只对扫描快照显示目标成员。
func _test_radar_bindings() -> void:
	var level: LevelDefinition = _levels[10]
	var assembly := _assembly(level)
	var accepted := {
		"main(){variable target=sc|}": "an",
		"main(){variable target=dish.sc|}": "an",
		"main(){if(sc| != null){move(0,0)}}": "an",
		"main(){variable target=scan()\nif(target != nu|){move(0,0)}}": "ll",
		"main(){variable target=scan()\nif(target != Nu|){move(0,0)}}": "ll",
		"main(){variable target=scan()\nmove(target.An|,1)}": "gle",
		"main(){variable target=scan()\nvariable position=target.Po|}": "sition",
		"main(){variable target=scan()\nif(target.Di| > 2){move(0,0)}}": "stance",
		"main(){variable target=dish.scan()\nvariable copy=target\nmove(copy.An|,1)}": "gle",
		"constant target=scan()\nfunction dodge(){move(target.An|,1)}\nmain(){}": "gle",
		"function dodge(){move(target.An|,1)}\nconstant target=scan()\nmain(){}": "gle",
		"main(){variable target=0\ntarget=scan()\nmove(target.An|,1)}": "gle",
		"main(){variable target=scan()\ntarget=null\nif(target != null){move(target.An|,1)}}": "gle",
	}
	for source: String in accepted:
		_expect(source, accepted[source], level, assembly, "已解锁雷达与扫描绑定提供准确后缀")
	for source in ["main(){sc|}", "main(){move(sc|,1)}", "main(){variable target=drive.sc|}", "main(){variable target=missing.sc|}", "main(){variable target=scan()\nmove(target.re|,1)}", "main(){variable target=1\nmove(target.An|,1)}", "main(){variable target=scan()\nloop{constant target=1\nmove(target.An|,1)}}", "main(){variable target=scan()}\nfunction dodge(){move(target.An|,1)}", "main(){loop{variable target=scan()}\nmove(target.An|,1)}", "main(){variable target=1\nif(distance(0)>1){target=scan()}\nmove(target.An|,1)}", "main(){variable target=scan()\ntarget=2\nmove(target.An|,1)}", "main(){variable target=drive.scan()\nmove(target.An|,1)}", "main(){variable target=scan()\nvariable position=target.Position\nmove(position.An|,1)}"]:
		_expect(source, "", level, assembly, "动作、错类、未知接收者和失效作用域不泄漏雷达建议")
	var source := "main(){variable target=scan()\nvariable position=target.Position\nmove(0,1)}"
	var lexed := ProgramLexer.tokenize(source.left(source.find("move")))
	_check(lexed.is_ok(), "向量推断输入可词法化")
	if lexed.is_ok():
		var tokens: Array[ProgramLexer.Token] = lexed.value
		tokens.pop_back()
		var value_types := ProgramCompletion._visible_radar_bindings(source, tokens, "main", level, assembly)
		_check(value_types.get("target") == "snapshot" and value_types.get("position") == "vector", "快照与复制的位置向量分开识别")
		var context := {"kind": "expression", "function": "main", "ready": false, "bindings": {"target": true, "position": true}, "radar_bindings": value_types}
		_check(ProgramCompletion._candidates(context, "target.Position", level, assembly) == PackedStringArray(["x", "y"]), "嵌套 Position 只提供坐标成员")
		_check(ProgramCompletion._candidates(context, "position", level, assembly) == PackedStringArray(["x", "y"]), "复制向量只提供坐标成员")
	assembly.modules.append({"id": "second", "module_id": "radar", "offset": {"x": 0.5, "y": 0}})
	_expect("main(){variable target=sc|}", "", level, assembly, "多个雷达不建议歧义的裸扫描")
	_expect("main(){variable target=dish.sc|}", "an", level, assembly, "多个雷达保留明确命名来源的扫描")
	_expect("main(){variable dish=1\nvariable target=dish.sc|}", "an", level, assembly, "数值绑定不遮蔽实际模块的明确扫描调用")
	assembly.modules.pop_back()
	var named := level.allow_named_calls
	level.allow_named_calls = false
	_expect("main(){variable target=scan()\nmove(target.An|,1)}", "gle", level, assembly, "快照读取与具名模块权限独立")
	_expect("main(){variable target=dish.sc|}", "", level, assembly, "关闭具名权限不建议命名扫描")
	level.allow_named_calls = named
	level.allow_radar = false
	_expect("main(){variable target=sc|}", "", level, assembly, "雷达开关关闭后不建议扫描")
	_expect("main(){variable target=scan()\nmove(target.An|,1)}", "", level, assembly, "手工写入 scan 不能绕过关卡开关")
	level.allow_radar = true
	for index in range(assembly.modules.size() - 1, -1, -1):
		if assembly.modules[index].get("module_id") == "radar":
			assembly.modules.remove_at(index)
	_expect("main(){variable target=sc|}", "", level, assembly, "移除实际雷达后不建议扫描")
	_expect("main(){variable target=scan()\nmove(target.An|,1)}", "", level, assembly, "没有实际扫描来源时不编造目标成员")
	_expect("main(){if(sc| != null){move(0,0)}}", "", _levels[8], _assembly(_levels[8]), "旧教学仍不开放 scan")


## 直接扫描返回值可继续补全成员，条件内类型改写不能让退出后的旧快照建议复活。
func _test_direct_radar_members_and_flow() -> void:
	var level: LevelDefinition = _levels[10]
	var assembly := _assembly(level)
	for entry in [["main(){move(scan().An|,1)}", "gle"], ["main(){variable position=scan().Po|}", "sition"], ["main(){move(0,dish.scan().Di|)}", "stance"], ["main(){if(scan().Di| > 1){move(0,0)}}", "stance"]]:
		_expect(entry[0], entry[1], level, assembly, "直接扫描结果提供合法快照成员")
	for source in ["main(){move(drive.scan().An|,1)}", "main(){move(missing.scan().An|,1)}", "main(){move(scan(1).An|,1)}", "main(){move(dodge().An|,1)}", "main(){move(scan().Position.An|,1)}", "main(){variable target=scan()\nif(distance(0)>1){target=1}else{target=2}\nmove(target.An|,1)}", "main(){variable target=scan()\nif(distance(0)>1){target=1}\nmove(target.An|,1)}", "main(){variable target=scan()\nloop{target=1}\nmove(target.An|,1)}"]:
		_expect(source, "", level, assembly, "错类来源和分支后不确定类型不提供目标成员")
	_expect("main(){variable target=scan()\nif(distance(0)>1){variable target=1}\nmove(target.An|,1)}", "gle", level, assembly, "新声明仅遮蔽外层，不使外层快照失效")
	_expect("main(){variable target=scan()\nif(distance(0)>1){target=1}\ntarget=scan()\nmove(target.An|,1)}", "gle", level, assembly, "分支后明确重新扫描可以恢复快照类型")
	var lexed := ProgramLexer.tokenize("scan().Position.")
	if _check(lexed.is_ok(), "直接扫描坐标链可词法化"):
		var tokens: Array[ProgramLexer.Token] = lexed.value
		tokens.pop_back()
		var receiver := ProgramCompletion._read_receiver(tokens, level, assembly)
		_check(receiver.is_ok() and tokens.is_empty(), "完整读取 scan().Position 成员来源，不残留调用括号")
		if receiver.is_ok():
			var context := {"kind": "expression", "function": "main", "ready": false, "bindings": {}}
			_check(ProgramCompletion._candidates(context, receiver.value, level, assembly) == PackedStringArray(["x", "y"]), "直接扫描的 Position 链仅提供 x/y")
	var vector_source := "main(){variable position=scan().Position\nmove(0,1)}"
	var vector_lexed := ProgramLexer.tokenize(vector_source.left(vector_source.find("move")))
	if vector_lexed.is_ok():
		var vector_tokens: Array[ProgramLexer.Token] = vector_lexed.value
		vector_tokens.pop_back()
		var inferred := ProgramCompletion._visible_radar_bindings(vector_source, vector_tokens, "main", level, assembly)
		_check(inferred.get("position") == "vector", "直接扫描提取 Position 后保存的变量保留向量类型")
	var variables_before := level.allow_variables
	var named_before := level.allow_named_calls
	level.allow_variables = false
	level.allow_named_calls = false
	_expect("main(){move(scan().An|,1)}", "gle", level, assembly, "直接扫描成员不要求变量或具名模块权限")
	_expect("main(){move(dish.scan().An|,1)}", "", level, assembly, "具名扫描成员仍检查模块调用权限")
	level.allow_variables = variables_before
	level.allow_named_calls = named_before
	level.allow_radar = false
	_expect("main(){move(scan().An|,1)}", "", level, assembly, "直接结果链也不能绕过雷达解锁")
	level.allow_radar = true


## 随机补全只出现在已解锁的数值位置，不依赖装配，也不冒充动作或模块方法。
func _test_random_functions() -> void:
	var level := LevelDefinition.new()
	level.allow_random = true
	var accepted := {
		"main(){move(0,ra|)}": "ndom",
		"main(){move(randomI|,1)}": "nt",
		"main(){move(randomInt(ra|,5),1)}": "ndom",
		"main(){move(randomInt(1,randomI|),1)}": "nt",
		"main(){move(randomInt(randomInt(0,1),ra|),1)}": "ndom",
		"main(){move(0,(ra|))}": "ndom",
		"main(){move(0,randomI|())}": "nt",
	}
	for source: String in accepted:
		_expect(source, accepted[source], level, null, "随机数不依赖变量、雷达、测距或模块权限")
	for source in ["ra|", "main(){ra|}", "main(){randomI|}", "main(){move(0,random|)}", "main(){move(0,random(ra|))}", "main(){move(0,randomInt(1,2,ra|))}", "main(){move(0,unknown(ra|))}", "main(){move(0,drive.randomInt(1,ra|))}", "main(){move(0,ra|ndom)}", "main(){// ra|\n}", "main(){if(ra|)}", "main(){variable n=ra|}"]:
		_expect(source, "", level, null, "错误参数、动作位置、注释和锁定语法不产生随机候选")
	level.allow_distance = true
	for source in ["main(){move(0,1-ra|)}", "main(){move(0,random()-ra|)}", "main(){move(0,randomInt(0,1)+ra|)}"]:
		_expect(source, "ndom", level, null, "已有数值表达式权限允许随机函数参与加减")
	level.allow_distance = false
	level.allow_conditionals = true
	_expect("main(){if(ra| < 0.5)}", "ndom", level, null, "条件独立解锁后支持随机比较")
	level.allow_variables = true
	for source in ["constant n=ra|\nmain(){}", "main(){variable n=randomI|}", "main(){variable n=1\nn=ra|}", "main(){constant n=randomInt(0,ra|)}", "main(){constant n=random()+ra|}", "main(){constant n=randomInt(0,1)+ra|}"]:
		_expect(source, "nt" if source.contains("randomI|") else "ndom", level, null, "绑定右侧和已完成随机函数之后可继续补全")
	for source in ["main(){constant n=random(ra|)}", "main(){constant n=randomInt(0,1,ra|)}", "main(){constant n=drive.randomInt(0,ra|)}", "main(){constant n=unknown(ra|)}"]:
		_expect(source, "", level, null, "绑定中的错误函数参数不补全")
	level.allow_named_calls = true
	level.allowed_modules = PackedStringArray(["movement"])
	var assembly := _assembly(level)
	_expect("main(){move(0,drive.ra|)}", "", level, assembly, "具名移动模块不提供随机方法")
	level.allow_random = false
	_expect("main(){move(0,ra|)}", "", level, assembly, "关闭开关即时移除随机小数建议")
	_expect("main(){constant n=randomI|}", "", level, assembly, "变量解锁不等于随机整数解锁")


## 范围遍历独立解锁，头部关键词、迭代值作用域与只读约束共同控制建议。
func _test_for_ranges() -> void:
	var level := LevelDefinition.new()
	level.allow_for = true
	var accepted := {
		"main(){fo|}": "r",
		"main(){for(angle i|)}": "n",
		"main(){for(angle in 0..315 st|)}": "ep",
		"main(){for(angle in 0..315 step 45){move(an|,1)}}": "gle",
		"main(){for(angle in 0..315 step 45)\n// 块头换行\n{move(an|,1)}}": "gle",
		"main(){for(angle in 0..315){for(inner in an|..315){move(0,1)}}}": "gle",
		"main(){for(angle in 0..315){for(inner in 0..an|){move(0,1)}}}": "gle",
		"main(){for(angle in 0..315){for(inner in 0..315 step an|){move(0,1)}}}": "gle",
		"main(){for(angle in 0..315){for(inner in 0..315){move(inn|,an)}}}": "er",
		"main(){for(angle in 0..315){for(inner in 0..315){move(0,1)}\nmove(an|,1)}}": "gle",
	}
	for source: String in accepted:
		_expect(source, accepted[source], level, null, "for 的关键词与只读迭代值不依赖变量或模块权限")
	for source in ["fo|", "main(){move(fo|,1)}", "main(){for(an|)}", "main(){for(angle in an|..315){move(0,1)}}", "main(){for(angle in 0..315){ang|}}", "main(){for(angle in 0..315){angle=an|}}", "main(){for(angle in 0..315){move(0,1)}\nmove(an|,1)}", "main(){for(angle in 0..315){for(inner in 0..315){move(0,1)}\nmove(inn|,1)}}", "main(){// fo|\n}", "main(){for(angle in 0..315){var|}}"]:
		_expect(source, "", level, null, "不猜测新变量名称，不泄露局部迭代值或写权限")
	level.allow_tick = true
	level.allow_simultaneous = true
	level.allowed_calls.append("shoot")
	for source in ["main(){}\ntick(){fo|}", "main(){simultaneously{fo|}}", "main(){}\ntick(){for(angle i|)}", "main(){simultaneously{for(angle i|)}}"]:
		_expect(source, "", level, null, "tick 与并行块不补全范围遍历")
	level.allow_variables = true
	var global := "variable angle=1\nconstant step=2\n"
	_expect(global + "main(){for(angle in 0..315){angle=st|}}", "", level, null, "只读迭代值遮蔽同名可写外层变量")
	_expect(global + "main(){for(angle in st|..315){move(0,1)}}", "ep", level, null, "step 在数值位置仍可以是旧变量名")
	_expect(global + "main(){for(angle in 0..step st| 45){move(0,1)}}", "ep", level, null, "同名上界变量不妨碍后续步长关键词")
	_expect(global + "main(){for(angle in 0..315){move(0,1)}\nang|}", "le", level, null, "离开迭代块后恢复外层可写变量")
	level.allow_functions = true
	_expect("main(){for(angle in 0..315){move(0,1)}}\nfunction check(){move(an|,1)}", "", level, null, "函数不能读到调用方的迭代值")
	level.allow_random = true
	_expect("main(){for(angle in randomI|..315){move(0,1)}}", "nt", level, null, "已解锁的随机数可补全范围边界")
	_expect("main(){for(angle in 0..randomInt(1,300) st|){move(0,1)}}", "ep", level, null, "完整嵌套函数之后支持 step")
	level.allow_radar = true
	level.allow_named_calls = true
	level.allowed_modules = PackedStringArray(["movement", "radar"])
	var assembly := _assembly(level)
	_expect("main(){variable target=scan()\nfor(target in 0..315){move(target.An|,1)}}", "", level, assembly, "同名迭代值遮蔽雷达快照，不补全快照属性")
	level.allow_for = false
	_expect("main(){fo|}", "", level, null, "其它能力不会隐式开放 for")
	_expect("main(){for(angle i|)}", "", level, null, "锁定的 for 头也没有 in 提示")
	_expect("main(){for(angle in 0..315){move(an|,1)}}", "", level, null, "手工输入锁定块不开放内部迭代值")
