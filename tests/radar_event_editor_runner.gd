extends SceneTree
## 雷达事件的只读编辑辅助回归：真实关卡权限、装配、候选、资料和深浅语法色均不写玩家存档。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _levels: Array[LevelDefinition] = []


## 等待类和场景树就绪后开始，避免导入过程中查询未注册资源。
func _initialize() -> void:
	_run.call_deferred()


## 加载十五个正式关卡后检查独立解锁与固定事件语法，最后以失败数返回进程结果。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "真实模块注册表可读取"):
		quit(1)
		return
	for number in range(1, 16):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(loaded.is_ok(), "第 %d 关可读取" % number):
			quit(1)
			return
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "第 %d 关权限可读取" % number):
			quit(1)
			return
		_levels.append(defined.value)
	_test_permissions_and_sources()
	_test_event_positions()
	_test_global_candidates_and_members()
	_test_command_reference()
	_test_syntax_colors()
	print("雷达事件编辑辅助回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 前十四关和每个依赖权限独立关闭时都不泄露事件入口，来源必须是实际已允许雷达。
func _test_permissions_and_sources() -> void:
	for index in range(14):
		var old := _levels[index]
		_check(not old.allow_radar_events, "第 %d 关没有事件权限" % (index + 1))
		var previous := _assembly(old)
		for source in ["dish.onD|", "dish.onDetected { EnemyP| }", "variable target = null\ndish.onDetected { EnemyPosition -> ta| }"]:
			_expect(source, "", old, previous, "前十四关不提供事件候选")
	var level := _levels[14]
	var assembly := _assembly(level)
	_check(level.allow_radar_events, "第十五关显式开放雷达事件")
	_expect("di|", "sh", level, assembly, "顶层补全实际雷达实例名")
	_expect("dish.onD|", "etected", level, assembly, "只补 onDetected 标识符后缀")
	for source in ["dish.onDetected|", "dish.on|Detected", "unknown.onD|", "drive.onD|", "gun.onD|", "onD|", "scan().onD|", "// dish.onD|", "dish.onDetected { // EnemyP|\n}"]:
		_expect(source, "", level, assembly, "错误来源、完整词、中间位置和注释没有事件补全")
	_expect("dish.onD|", "", level, null, "没有装配不能凭名字猜测雷达")
	for flag in ["allow_radar_events", "allow_radar", "allow_named_calls", "allow_variables"]:
		var previous: bool = level.get(flag)
		level.set(flag, false)
		_expect("dish.onD|", "", level, assembly, "事件入口独立检查 " + flag)
		_expect("dish.onDetected { EnemyP| }", "", level, assembly, "事件载荷独立检查 " + flag)
		level.set(flag, previous)
	var modules := level.allowed_modules.duplicate()
	level.allowed_modules.erase("radar")
	_expect("dish.onD|", "", level, assembly, "未允许的雷达草稿不产生事件候选")
	level.allowed_modules = modules
	assembly.modules[0].id = "observer"
	_expect("dish.onD|", "", level, assembly, "改名后旧实例立即失效")
	_expect("observer.onD|", "etected", level, assembly, "改名后采用真实雷达名称")


## 固定事件体只补载荷和箭头目标，函数、回调、控制块及事件内都不能建议任意处理器代码。
func _test_event_positions() -> void:
	var level := _levels[14]
	var assembly := _assembly(level)
	_expect("dish.onDetected { EnemyP| }", "osition", level, assembly, "固定载荷只在事件体开头补全")
	_expect("dish.onDetected\n{\n // 载荷\n EnemyP|\n}", "osition", level, assembly, "换行和注释保留事件位置")
	for source in ["main(){dish.onD|}", "tick(){dish.onD|}", "function patrol(){dish.onD|}", "main(){loop{dish.onD|}}", "dish.onDetected { mo| }", "dish.onDetected { if| }", "dish.onDetected { EnemyPosition -> EnemyP| }", "dish.onDetected { EnemyPosition -> target\nEnemyP| }", "dish.onDetected { if(1){EnemyP|} }", "EnemyP|", "main(){move(EnemyP|,1)}", "main(){dish.onDetected { EnemyP| }}", "dish.onDetected() { EnemyP| }"]:
		_expect(source, "", level, assembly, "非法事件位置或任意处理器语句不产生候选")
	var bound := "variable target = null\ndish.onDetected { EnemyPosition -> target }\n"
	_expect(bound + "main(){mo|}", "ve", level, assembly, "完整事件前置后仍保留普通动作补全")
	_expect(bound + "function patrol(){sh|}", "oot", level, assembly, "事件不破坏独立函数补全")


## 箭头只写此前全局变量，事件快照成员保留已有词法遮蔽和只读属性边界。
func _test_global_candidates_and_members() -> void:
	var level := _levels[14]
	var assembly := _assembly(level)
	var declarations := "constant fixed = null\nvalue saved = null\nvariable target = null\nmain(){variable local = null}\n"
	_expect(declarations + "dish.onDetected { EnemyPosition -> ta| }", "rget", level, assembly, "箭头建议已声明全局 variable")
	for prefix in ["fi", "sa", "lo", "fu", "nu", "EnemyP"]:
		_expect(declarations + "dish.onDetected { EnemyPosition -> " + prefix + "| }", "", level, assembly, "箭头不建议常量、局部、关键字或固定载荷")
	_expect("dish.onDetected { EnemyPosition -> la| }\nvariable later = null", "", level, assembly, "后置全局声明不能作为事件目标候选")
	_expect("// variable fake = null\ndish.onDetected { EnemyPosition -> fa| }", "", level, assembly, "注释伪声明不成为全局目标")
	_expect("variable pending =\ndish.onDetected { EnemyPosition -> pe| }", "", level, assembly, "未完成声明不成为事件目标")
	var bound := "variable target = null\ndish.onDetected { EnemyPosition -> target }\n"
	_expect(bound + "main(){shoot(target.An|)}", "gle", level, assembly, "事件写入的 null 全局提供 Angle 成员")
	_expect(bound + "main(){variable point = target.Po|}", "sition", level, assembly, "事件目标提供 Position 成员")
	_expect(bound + "main(){move(0,target.Di|)}", "stance", level, assembly, "事件目标提供 Distance 成员")
	_expect(bound + "main(){variable point = target.Position\nmove(point.x|,1)}", "", level, assembly, "完整单字坐标不会额外填入括号或答案")
	_expect(bound + "main(){variable target = 0\nshoot(target.An|)}", "", level, assembly, "同名数值局部遮蔽全局目标成员")
	_expect(bound + "main(){target = 0\nshoot(target.An|)}", "", level, assembly, "用户显式数值赋值后不猜测它仍是当前快照")
	_expect(bound + "constant copied = target\nmain(){shoot(copied.An|)}", "", level, assembly, "初始化复制的 null 不随事件目标一起刷新")
	_expect(bound + "main(){variable copied = target\nshoot(copied.An|)}", "gle", level, assembly, "运行中复制事件目标可获得快照成员提示")
	_expect("variable target = null\nmain(){shoot(target.An|)}", "", level, assembly, "没有事件或扫描的 null 不伪造快照成员")
	_expect("variable target = null\nunknown.onDetected { EnemyPosition -> target }\nmain(){shoot(target.An|)}", "", level, assembly, "无效事件来源不伪造快照成员")
	_expect("variable target = null\n// dish.onDetected { EnemyPosition -> target }\nmain(){shoot(target.An|)}", "", level, assembly, "注释事件不伪造快照成员")


## 资料按独立权限归入雷达目录，目录与搜索一致隐藏旧关事件，并核实中英文短示例。
func _test_command_reference() -> void:
	var catalog := CommandCatalog.new()
	_check(catalog.load_directory().is_ok(), "事件加入后全部资料仍通过严格 JSON 校验")
	var event := {}
	for entry in catalog.entries:
		if entry.id == "radar_event":
			event = entry
	if not _check(not event.is_empty(), "指令集合包含雷达事件资料"):
		return
	_check(event.syntax.contains("radar.onDetected { EnemyPosition -> target }") and event.syntax.contains("variable target = null"), "资料给出简短固定绑定示例")
	_check(CommandCatalog.localized(event, "title", "en") == "Radar Detection Event", "英文标题来自资料词典")
	_check(CommandCatalog.localized(event, "description", "en").contains("Each simulation tick") and CommandCatalog.localized(event, "description", "en").contains("null"), "英文解释最新快照和空目标")
	_check(CommandCatalog.localized(event, "description", "zh_CN").contains("全局变量") and CommandCatalog.localized(event, "description", "zh_CN").contains("局部变量"), "中文解释作用域和绑定边界")
	var menu := CommandReferenceMenu.new()
	for index in range(15):
		menu._level = _levels[index]
		var expected := index == 14
		_check(CommandCatalog.is_available(event, _levels[index], _content) == expected, "第 %d 关指令资料按事件权限解锁" % (index + 1))
		_check(_has_event(menu._listed_entries(catalog.entries)) == expected, "第 %d 关目录只在解锁后显示事件资料" % (index + 1))
		_check(_has_event(menu._listed_entries(catalog.search("onDetected", _content, "en"))) == expected, "第 %d 关英文搜索与目录采用相同可见性" % (index + 1))
	menu.free()


## 深浅模式都检查最终字符色，确保点号后的事件成员也使用明确语法色而不只是登记关键字。
func _test_syntax_colors() -> void:
	var edit := CodeEdit.new()
	edit.text = "dish.onDetected { EnemyPosition -> target }\n// onDetected EnemyPosition"
	root.add_child(edit)
	for mode in ["light", "dark"]:
		GameTheme.style_code(edit, mode)
		var palette: Dictionary = GameTheme.CODE_DARK if mode == "dark" else GameTheme.CODE_LIGHT
		var syntax := edit.syntax_highlighter as CodeHighlighter
		_check(syntax.get_keyword_color("onDetected") == palette.keyword, mode + " 事件声明登记关键字颜色")
		_check(syntax.get_keyword_color("EnemyPosition") == palette.query, mode + " 固定载荷登记查询颜色")
		_check(_color_at(syntax.get_line_syntax_highlighting(0), 6) == palette.keyword, mode + " 点号后的 onDetected 实际字符正确上色")
		_check(_color_at(syntax.get_line_syntax_highlighting(0), 20) == palette.query, mode + " EnemyPosition 实际字符正确上色")
		_check(_color_at(syntax.get_line_syntax_highlighting(1), 6) == palette.comment, mode + " 注释中的事件词继续使用注释色")
	edit.free()


## 从高亮的分段颜色表读取具体字符，验证编辑器真正使用的颜色结果。
func _color_at(highlights: Dictionary, column: int) -> Color:
	var current := Color.TRANSPARENT
	var starts: Array = highlights.keys()
	starts.sort()
	for start: int in starts:
		if start > column:
			break
		current = highlights[start].get("color", Color.TRANSPARENT)
	return current


## 检查视图过滤结果中的稳定 ID，不依赖已翻译标题或资料次序。
func _has_event(entries: Array) -> bool:
	for entry: Dictionary in entries:
		if entry.id == "radar_event":
			return true
	return false


## 在内存中建立真实注册行为的装配快照，补全不执行装配或模拟状态修改。
func _assembly(level: LevelDefinition) -> AssemblyModel:
	var assembly := AssemblyModel.create(level, _content)
	for entry in [["dish", "radar"], ["drive", "movement"], ["gun", "shooting"]]:
		if entry[1] in level.allowed_modules:
			assembly.modules.append({"id": entry[0], "module_id": entry[1], "offset": {"x": 0, "y": 0}})
	return assembly


## 用竖线标记光标后比较唯一返回后缀，确保辅助功能不会插入完整事件代码。
func _expect(marked: String, expected: String, level: LevelDefinition, assembly: AssemblyModel, description: String) -> void:
	var caret := marked.find("|")
	var before := marked.left(caret).split("\n")
	var source := marked.erase(caret, 1)
	var actual := ProgramCompletion.suggest(source, before.size() - 1, before[before.size() - 1].length(), level, assembly)
	_check(actual == expected, "%s：%s → '%s'，实际 '%s'" % [description, marked.replace("\n", "↵"), expected, actual])


## 汇总断言并报告输入语境，失败返回非零状态供总回归入口识别。
func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("失败：" + description)
	return condition
