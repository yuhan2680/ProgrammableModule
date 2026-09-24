extends SceneTree
## 使用真实十二张教学地图、手工装配和正式会话检查提示的小步修改与纯函数边界。

const NUMBERS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
const STEP_LIMIT := 2400
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _levels: Dictionary = {}


## 等待全局类初始化后开始纯服务回归；不读取或写入任何玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 先加载正式关卡，再检查逐步通关、命名保留、拒绝边界与会话隔离。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "提示测试所需正式模块可以加载"):
		quit(1)
		return
	for number: int in NUMBERS:
		var map := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(map.is_ok(), "第 %d 关正式地图可读取" % number):
			continue
		var defined := LevelDefinition.from_document(map.value, _content, "res://data/levels/level_%03d.json" % number)
		if _check(defined.is_ok(), "第 %d 关规则可实例化" % number):
			_levels[number] = defined.value
	if _levels.size() != NUMBERS.size():
		quit(1)
		return
	_test_all_lessons()
	_test_radar_lesson_hints()
	_test_for_lesson_bindings()
	_test_small_edits_and_comments()
	_test_named_modules_and_functions()
	_test_assembly_and_document_boundaries()
	_test_tutorial_source_scope()
	_test_session_isolation()
	_test_bounded_inputs()
	print("代码提示回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 每关由空 main 逐次补入，最终用独立会话验证真实目标，而非只比较参考字符串。
func _test_all_lessons() -> void:
	for number: int in NUMBERS:
		var session := _session(number, "// 玩家保留的思路\nmain() {\n}\n")
		if session == null:
			continue
		var result := _complete_hints(session, "第 %d 关" % number)
		_check(result and _wins_independently(session), "第 %d 关通过多次提示可完成真实目标" % number)
		_check(session.source.contains("// 玩家保留的思路"), "第 %d 关提示保留原有注释" % number)
		var finished_source := session.source
		var again := CodeHintService.next_hint(session)
		_check(not again.is_ok() and session.source == finished_source, "第 %d 关已有正确解法时不重复填入提示" % number)
		# 用户拿到正式 starter 时，同样至少得到有效下一步或正确程序已可通关的说明。
		var starter := _session(number, _levels[number].starter_program)
		var first := CodeHintService.next_hint(starter)
		_check(first.is_ok() or _wins_independently(starter), "第 %d 关正式初始程序可进入提示流程" % number)


## 第十一关改装雷达后选择 JSON 替代方案，并通过逐步提示完成同一真实目标。
func _test_radar_lesson_hints() -> void:
	var session := _session(11, "// 玩家雷达思路\nmain() {}\nfunction sidestep() {}\n")
	session.assembly.modules[0].module_id = "radar"
	session.assembly.modules[0].id = "eyes"
	_check(_complete_hints(session, "第十一关雷达替代方案") and _wins_independently(session), "雷达装配逐步提示可完成五次真实闪避")
	_check(session.source.contains("eyes.scan()") and not session.source.contains("distance(0)"), "提示读取实际雷达实例，不写无法执行的测距调用")
	_check(session.source.contains("sidestep()") and session.source.contains("// 玩家雷达思路"), "雷达提示仍保留玩家函数名和原注释")


## 有限扫描方案同时包含变量声明与赋值；重复点击不重插绑定，并保留无关玩家代码。
func _test_for_lesson_bindings() -> void:
	var source := "// 保留扫描思路\nconstant untouched = 7\nmain() {\n    variable note = 1 // 我的局部变量\n    note = 2\n    loop {\n    }\n}\n"
	var session := _session(12, source)
	session.assembly.modules[0].id = "eyes"
	session.assembly.modules[1].id = "cannon"
	_check(_complete_hints(session, "第十二关绑定及有限扫描") and _wins_independently(session), "改名双模块和已有 loop 可逐步补齐八方向真实通关方案")
	_check(session.source.count("variable aim = 0") == 1 and session.source.count("aim = angle") == 1, "参考声明和赋值各只补一份，不反复插入重复名称")
	_check(session.source.contains("for (angle in 0..315 step 45)") and session.source.contains("eyes.distance(angle)") and session.source.contains("cannon.shoot(aim)"), "范围循环保留完整语法，测距及射击绑定真实模块名")
	_check(not session.source.contains("else"), "无需 else 的测距条件不会额外生成空分支")
	for preserved in ["// 保留扫描思路", "constant untouched = 7", "variable note = 1 // 我的局部变量", "note = 2"]:
		_check(session.source.contains(preserved), "有限循环方案保留无关声明、赋值和注释：" + preserved)
	var target := "main() {\n    variable aim = 0\n    loop {\n        for (angle in 0..315 step 45) {\n            if (eyes.distance(angle) < 6) {\n                aim = angle\n            }\n        }\n        cannon.shoot(aim)\n    }\n}\n"
	var wrong := target.replace("variable aim = 0", "constant aim = 99 // 初始化备注").replace("aim = angle", "aim = 180 // 扫描备注")
	var first := CodeHintService._next_patch(wrong, target)
	if _check(first.is_ok(), "同名参考常量可修正为可赋值变量"):
		_check(first.value.source == wrong.replace("constant aim = 99", "variable aim = 0"), "仅修改初始化语句，原备注与其他源码保留")
		var second := CodeHintService._next_patch(first.value.source, target)
		if _check(second.is_ok(), "同名参考赋值可在下一步修正"):
			_check(second.value.source == str(first.value.source).replace("aim = 180", "aim = angle"), "一次只修正当前赋值及完整表达式，行内注释仍保留")
			_check(not CodeHintService._next_patch(second.value.source, target).is_ok(), "参考绑定完整后结构补丁结束，不返回重复声明")
	var tree := CodeHintService._read_tree(target)
	_check(tree.is_ok() and tree.value.open_blocks.is_empty(), "轻量源码树完整读取 .. 范围、step 与可省略 else 的嵌套块")


## 一次点击仅填一条动作或结构，原格式、行内备注和已有正确步骤不会被整体重写。
func _test_small_edits_and_comments() -> void:
	var session := _session(1, "// 我的第一段程序\nmain() {\n}\n")
	var hint := CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "空入口可获得第一步"):
		_check(hint.value.source.count("move(") == 1 and hint.value.source.contains("move(0, 4)"), "一次提示只插入第一条完整动作，不泄露整关五步")
		_check(session.source == "// 我的第一段程序\nmain() {\n}\n", "服务仅返回源码，不替 UI 修改会话")
	var notes := "// 保留换行与说明\r\nmain() {\r\n    move(0, 1) // 这里向右\r\n}\r\n"
	session.source = notes
	hint = CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "错误距离可以逐行修正"):
		_check(hint.value.source == notes.replace("move(0, 1)", "move(0, 4)"), "只修改参数行，原行内注释和 CRLF 字节保持原样")
		_check(int(hint.value.line) == 3, "返回的高亮行从一开始并指向实际修改行")
	session.source = "main() {\n    move(90, 3) // 已经写好的第二步\n}\n"
	hint = CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "缺少首步可以插入"):
		_check(hint.value.source.contains("move(0, 4)\n    move(90, 3) // 已经写好的第二步"), "插入缺失首步，保留已写对的后续动作")
	session.source = "main()\n{\n    // 入口采用独立花括号\n}\n"
	hint = CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "换行花括号风格可读"):
		_check(hint.value.source.contains("main()\n{") and hint.value.source.contains("// 入口采用独立花括号"), "保留玩家的入口样式和块内备注")
	session.source = "main() {\n    move(0,4)\n"
	hint = CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "未闭合的入口可以得到修补提示"):
		_check(hint.value.source.count("move(") == 1 and hint.value.source.strip_edges().ends_with("}"), "缺右括号时只配齐结构，不同时增加下一条动作")
	session.source = "main() // 正在输入入口\n"
	hint = CodeHintService.next_hint(session)
	if _check(hint.is_ok(), "仅有入口头时可补齐框架"):
		_check(hint.value.source.count("main()") == 1 and hint.value.source.contains("// 正在输入入口"), "补齐当前入口而不新增重复 main 或移除原注释")
	var loop_session := _session(6, "main() {\n}\n")
	hint = CodeHintService.next_hint(loop_session)
	if _check(hint.is_ok(), "循环教学可以得到结构提示"):
		_check(hint.value.source.contains("loop {") and not hint.value.source.contains("move("), "新增 loop 配齐闭括号但不一次填满内部动作")


## 使用玩家实例名和唯一已声明的函数名，变量、赋值和无关函数留在作品中。
func _test_named_modules_and_functions() -> void:
	var prison := _session(5, "main() {}\n")
	prison.assembly.modules[1].id = "west_blade"
	prison.assembly.modules[2].id = "east_blade"
	_check(_complete_hints(prison, "自定义近战名称") and _wins_independently(prison), "自定义左右模块名的第五关仍能通关")
	_check(prison.source.contains("west_blade.attack(180)") and prison.source.contains("east_blade.attack(0)"), "具名攻击补齐实际模块名和全部参数")
	var radar := _session(11, "main() {\n}\n\nfunction sidestep() {\n    // 保留我的闪避函数名\n}\n")
	radar.assembly.modules[0].id = "eyes"
	radar.assembly.modules[1].id = "feet"
	_check(_complete_hints(radar, "重命名闪避函数") and _wins_independently(radar), "唯一重命名函数可逐步完成五次闪避")
	_check(radar.source.contains("function sidestep()") and radar.source.contains("sidestep()") and not radar.source.contains("dodge()"), "声明与调用同时保留 sidestep，不写不存在的 dodge")
	_check(radar.source.contains("eyes.distance(0)") and radar.source.contains("move(90, 1)") and not radar.source.contains("..."), "条件补齐实际测距模块名、方向和阈值，不留下省略占位符")
	var declarations := "constant warning = 2.5\nvariable observed = 0\nmain() {\n    variable local = 1\n    local = 2\n}\n\nfunction dodge() {\n}\n\nfunction kept() {\n    move(0, 0) // 无关函数保持原样\n}\n"
	var variables := _session(11, declarations)
	_check(_complete_hints(variables, "变量及无关函数") and _wins_independently(variables), "提示能与已有常量、变量及无关函数共存")
	for preserved in ["constant warning = 2.5", "variable observed = 0", "variable local = 1", "local = 2", "function kept() {\n    move(0, 0) // 无关函数保持原样\n}"]:
		_check(variables.source.contains(preserved), "提示保留玩家已有声明或函数：" + preserved.get_slice("\n", 0))


## 不适配的真实装配或相同 ID 的改版地图只返回说明，不猜测会失败的答案。
func _test_assembly_and_document_boundaries() -> void:
	var missing := GameSession.create(_levels[9], _content)
	missing.source = "main() {}"
	missing.assembly.add_module("movement", Vector2.ZERO, "only_drive")
	var original := missing.source
	var hint := CodeHintService.next_hint(missing)
	_check(not hint.is_ok() and "\n".join(hint.errors).contains("测距模块") and missing.source == original, "缺测距能力时提示先安装模块，不写 distance 错误代码")
	var slow := GameSession.create(_levels[2], _content)
	slow.assembly.add_module("movement", Vector2.ZERO, "slow")
	slow.source = "main() {}"
	hint = CodeHintService.next_hint(slow)
	_check(not hint.is_ok() and "\n".join(hint.errors).contains("两个"), "合法但速度不足的装配经完整模拟后拒绝给出必败答案")
	var sideways := _session(9, "main() {}")
	sideways.assembly.modules[1].offset = {"x": 0.5, "y": 0.0}
	hint = CodeHintService.next_hint(sideways)
	_check(not hint.is_ok() and "\n".join(hint.errors).contains("(0,0.5)"), "测距关横向装配无法通过窄道时给出具体修复位置")
	var changed: Dictionary = _levels[1].document.to_dict()
	changed.properties.level.goal.position.x = 2.5
	var decoded := MapCodec.from_dict(changed, _content, true)
	if _check(decoded.is_ok(), "相同 ID 的改版地图仍是合法地图"):
		var definition := LevelDefinition.from_document(decoded.value, _content, "res://data/levels/level_001.json")
		if _check(definition.is_ok(), "改版目标仍是合法关卡定义"):
			var modified := GameSession.create(definition.value, _content)
			modified.assembly.add_module("movement", Vector2.ZERO, "drive")
			modified.source = "main() {}"
			hint = CodeHintService.next_hint(modified)
			_check(not hint.is_ok() and "\n".join(hint.errors).contains("不同"), "不会仅凭 level_001 ID 对改版地图灌入原关答案")
	changed = _levels[1].document.to_dict()
	changed.id = "my_imported_level"
	decoded = MapCodec.from_dict(changed, _content, true)
	if _check(decoded.is_ok(), "自定义关卡 fixture 合法"):
		var definition := LevelDefinition.from_document(decoded.value, _content)
		if _check(definition.is_ok(), "自定义关卡规则可实例化"):
			var imported := GameSession.create(definition.value, _content)
			imported.assembly.add_module("movement", Vector2.ZERO, "drive")
			imported.source = "main() {}"
			hint = CodeHintService.next_hint(imported)
			_check(not hint.is_ok() and "\n".join(hint.errors).contains("导入关卡"), "没有资料的导入关卡返回说明且不写源码")


## 正式教程的完全相同副本仍属于导入或编辑器测试，只有精确的教学资源路径可进入提示。
func _test_tutorial_source_scope() -> void:
	var canonical: LevelDefinition = _levels[1]
	_check(canonical.source_path == "res://data/levels/level_001.json", "教学夹具记录真实正式资源来源")
	for source_path: String in ["", "user://levels/level_001.json", "res://data/maps/imported_level_001.json", "res://data/levels/level_002.json", "res://data/levels/../levels/level_001.json"]:
		var definition := LevelDefinition.from_document(canonical.document, _content, source_path)
		if not _check(definition.is_ok(), "教程完整副本仍可实例化：" + source_path):
			continue
		var clone := GameSession.create(definition.value, _content)
		clone.assembly.add_module("movement", Vector2.ZERO, "drive")
		clone.source = "main() {}"
		_check(clone.level.id == canonical.id and clone.level.document.to_dict() == canonical.document.to_dict(), "拒绝范围测试确实使用相同 ID 和完全相同地图内容")
		var before := _snapshot(clone)
		var hint := CodeHintService.next_hint(clone)
		_check(not hint.is_ok() and "\n".join(hint.errors).contains("仅用于教学关卡"), "非正式来源即使内容完全相同也不能获得提示：" + source_path)
		_check(_snapshot(clone) == before, "拒绝导入或编辑器副本时保留其源码、装配和全部会话状态")


## 成败验证只在克隆中运行，真实失败世界、失败次数和信号均不会发生变化。
func _test_session_isolation() -> void:
	var session := _session(1, "main(){move(0, 0)}")
	_check(session.run().is_ok(), "隔离案例允许正常开始试运行")
	while session.state == GameSession.State.RUNNING:
		session.step()
	_check(session.state == GameSession.State.FAILED, "隔离案例先产生真实失败世界")
	var before := _snapshot(session)
	var notifications: Array[int] = []
	# 用途：监听原会话，克隆验证不应触发原会话任何通知。
	session.changed.connect(func() -> void: notifications.append(1))
	var hint := CodeHintService.next_hint(session)
	_check(hint.is_ok() and _snapshot(session) == before and notifications.is_empty(), "提示不修改原失败世界、源码、装配、失败计数或发出状态信号")
	var running := _session(1, "main(){move(0,4)}")
	_check(running.run().is_ok(), "运行态防护案例可启动")
	for state in [GameSession.State.RUNNING, GameSession.State.PAUSED]:
		if state == GameSession.State.PAUSED:
			running.pause()
		before = _snapshot(running)
		hint = CodeHintService.next_hint(running)
		_check(not hint.is_ok() and _snapshot(running) == before, "运行或暂停时不改写执行中的代码与世界")
	running.stop()
	var won := _session(2, "main(){move(0,8)}")
	_check(won.run().is_ok(), "终态防护案例可启动")
	for unused in STEP_LIMIT:
		if won.state != GameSession.State.RUNNING:
			break
		won.step()
	before = _snapshot(won)
	hint = CodeHintService.next_hint(won)
	_check(won.state == GameSession.State.SUCCEEDED and not hint.is_ok() and _snapshot(won) == before, "已经成功的会话不会再提示或重置终态")


## 超长源码、多余括号和缺会话按有界错误处理，既不无限循环也不清空玩家代码。
func _test_bounded_inputs() -> void:
	_check(not CodeHintService.next_hint(null).is_ok(), "缺会话返回明确失败")
	var session := _session(1, "//" + "x".repeat(65536))
	var source := session.source
	_check(not CodeHintService.next_hint(session).is_ok() and session.source == source, "超过 64 KiB 的源码在模拟前拒绝且原文保持不变")
	session.source = "main() {}\n}\n"
	var hint := CodeHintService.next_hint(session)
	_check(not hint.is_ok() and "\n".join(hint.errors).contains("多余的右花括号"), "不能安全定位的多余括号返回修复说明")
	session.source = "main() {\n" + "move(0,0)\n".repeat(520) + "}\n"
	hint = CodeHintService.next_hint(session)
	_check(not hint.is_ok() and "\n".join(hint.errors).contains("结构较多"), "编辑节点预算防止大型源码不断扫描和扩展")


## 通过最多三十二次小步修改补全，服务调用前后检查原会话未受到副作用。
func _complete_hints(session: GameSession, label: String) -> bool:
	for index in 32:
		var before := _snapshot(session)
		var hint := CodeHintService.next_hint(session)
		if not _check(_snapshot(session) == before, label + "第 %d 次调用保持原会话不变" % (index + 1)):
			return false
		if not hint.is_ok():
			var solved := _wins_independently(session)
			_check(solved, label + "结束提示时已有真实通关解法：" + "\n".join(hint.errors))
			return solved
		if not _check(hint.value is Dictionary and hint.value.source is String and hint.value.message is String and int(hint.value.line) >= 1 and int(hint.value.line) <= str(hint.value.source).count("\n") + 1, label + "返回完整源码、有效高亮行和反馈"):
			return false
		if not _check(hint.value.source != session.source, label + "每次成功都产生实际的一步修改"):
			return false
		session.source = hint.value.source
	return _check(false, label + "应在三十二步内完成而不重复提示")


## 独立执行当前所得程序，验证最终成功而非信任服务内部的参考验证结果。
func _wins_independently(session: GameSession) -> bool:
	var trial := GameSession.create(session.level, _content)
	trial.assembly.modules = session.assembly.modules.duplicate(true)
	trial.source = session.source
	if not trial.run().is_ok():
		trial.stop()
		return false
	for unused in STEP_LIMIT:
		if trial.state != GameSession.State.RUNNING:
			break
		trial.step()
	var result := trial.state == GameSession.State.SUCCEEDED
	trial.stop()
	return result


## 固定各关已有回归验证过的手工装配，之后可改名或偏移以验证绑定与拒绝逻辑。
func _session(number: int, source: String) -> GameSession:
	var session := GameSession.create(_levels[number], _content)
	var modules: Array = []
	match number:
		1, 6:
			modules = [["movement", Vector2.ZERO, "drive"]]
		2:
			modules = [["movement", Vector2.ZERO, "drive"], ["movement", Vector2(0.5, 0), "boost"]]
		3:
			modules = [["movement", Vector2.ZERO, "drive"], ["melee", Vector2(0.5, 0), "blade"]]
		4:
			modules = [["shooting", Vector2.ZERO, "gun"]]
		5:
			modules = [["movement", Vector2.ZERO, "drive"], ["melee", Vector2(-0.5, 0), "left"], ["melee", Vector2(0.5, 0), "right"]]
		7:
			modules = [["movement", Vector2.ZERO, "drive"], ["shooting", Vector2(0.5, 0), "gun"]]
		8:
			modules = [["melee", Vector2.ZERO, "left"], ["movement", Vector2(0.5, 0), "drive"], ["melee", Vector2(1, 0), "right"]]
		9:
			modules = [["rangefinder", Vector2.ZERO, "sensor"], ["movement", Vector2(0, 0.5), "drive"]]
		10:
			modules = [["radar", Vector2.ZERO, "eyes"], ["shooting", Vector2(0.5, 0), "gun"], ["movement", Vector2(0, 0.5), "drive"]]
		11:
			modules = [["rangefinder", Vector2.ZERO, "sensor"], ["movement", Vector2(0.5, 0), "drive"]]
		12:
			modules = [["rangefinder", Vector2.ZERO, "sensor"], ["shooting", Vector2(0.5, 0), "gun"]]
	for module: Array in modules:
		if not _check(session.assembly.add_module(module[0], module[1], module[2]).is_ok(), "第 %d 关手工安装 %s" % [number, module[2]]):
			return null
	session.source = source
	return session


## 用深拷贝比较玩家作品、世界身份、时钟、位置和反馈，不接触持久化文件。
func _snapshot(session: GameSession) -> Dictionary:
	return {"source": session.source, "modules": session.assembly.modules.duplicate(true), "state": session.state, "message": session.message, "line": session.current_line, "world": session.world, "runner": session.runner, "document": session.level.document.to_dict(), "failures": session.consecutive_failures, "tick": session.world.tick_index if session.world != null else -1, "position": session.world.player.position if session.world != null else Vector2.ZERO}


## 汇总检查结果并保留中文失败原因，最终由退出码交给统一测试脚本。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
