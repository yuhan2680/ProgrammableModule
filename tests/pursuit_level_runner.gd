extends SceneTree
## 第七关通过正式地图、装配和会话验证条件判断、持续追击与边退边射。

const SOLUTION := "main() {\n    loop {\n        if (gun.ready()) {\n            gun.shoot(0)\n        } else {\n            move(180, 0.1)\n        }\n    }\n}\n"
const MAX_STEPS := 350
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待场景树就绪后读取正式 JSON，避免测试用替代地图掩盖内容集成问题。
func _initialize() -> void:
	_run.call_deferred()


## 每组用例建立独立会话，汇总日志与返回码供统一测试入口判断结果。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "第七关所需内容可以加载"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_007.json", _content, true)
	if not _check(loaded.is_ok(), "第七关正式地图通过完整格式和占地校验"):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "第七关条件解锁和胜利目标有效"):
		quit(1)
		return
	_level = defined.value
	_test_design()
	_test_compilation()
	_test_solution()
	_test_failures()
	_test_preflight()
	_test_pause_stop_retry()
	_test_unlocks_and_metadata()
	_test_deadline()
	print("第七关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 核对文档要求的双模块、六格间距、水平窄路和持续接近攻击，避免沿用第四关。
func _test_design() -> void:
	_check(_level.id == "level_007" and _level.order == 7, "第七关具有稳定 ID 和顺序")
	_check(_level.module_limit == 2 and _level.allow_conditionals and _level.allow_loops, "第七关限制两个模块并开放条件与循环")
	_check(_level.allow_tick and _level.allow_named_calls and _level.allowed_modules == PackedStringArray(["movement", "melee", "shooting"]), "之前已学能力继续开放")
	_check(_level.goal_type == "destroy_enemy" and _level.goal_enemy_id == "pursuer", "胜利依赖击毁目标机器的全部模块")
	_check(_level.document.enemies.size() == 1 and _level.document.objects.is_empty(), "追击练习只有一台目标敌人，没有隐藏机关")
	var enemy: Dictionary = _level.document.enemies[0]
	var spawn: Dictionary = _level.document.player_spawn.position
	_check(is_equal_approx(float(enemy.position.x) - float(spawn.x), 6.0) and is_equal_approx(float(enemy.position.y), float(spawn.y)), "敌人在玩家出生点右侧六格且处于同一水平线")
	_check(enemy.behavior == "advance_attack" and is_equal_approx(float(enemy.properties.move_angle), 180.0) and is_equal_approx(float(enemy.properties.attack_angle), 180.0), "敌人使用持续向左推进并攻击的注册行为")
	_check(not enemy.properties.has("move_distance"), "第七关追击不沿用有限距离后停下的行为")
	var horizontal := not _level.document.cells.is_empty()
	for cell: Vector2i in _level.document.cells:
		horizontal = horizontal and cell.y == floori(float(spawn.y)) and _level.document.get_tile_id(cell) == "floor"
	_check(horizontal, "全部地板只占同一行，地图没有上下移动路线")
	_check(enemy.modules.size() == 2 and enemy.modules[0].module_id == "melee" and enemy.modules[1].module_id == "movement" and float(enemy.modules[0].offset.x) < float(enemy.modules[1].offset.x), "敌方前方近战与后方驱动采用真实独立模块")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("shooting", Vector2(-0.5, 0), "extra").is_ok(), "装配模型拒绝第三个模块")
	_check(session.assembly.build_document().is_ok(), "双模块水平共边装配的完整出生占地有效")


## 初始程序不预填条件或动作，玩家编写后生成显式条件语法树而非源码替换。
func _test_compilation() -> void:
	_check(_level.starter_program.contains("loop") and not _level.starter_program.contains("move(") and not _level.starter_program.contains("shoot(") and not _level.starter_program.contains("ready(") and not _level.starter_program.contains("//"), "第七关初始代码只留空循环框架，不预填答案或答案注释")
	var starter := _parse(_level.starter_program)
	_check(not starter.is_ok() and "\n".join(starter.errors).contains("loop 代码块不能为空"), "未填写动作的初始框架继续给出空循环诊断")
	var parsed := _parse(SOLUTION)
	if not _check(parsed.is_ok(), "具名就绪查询可以在循环条件中编译"):
		return
	var loop_node: ProgramAst.LoopNode = parsed.value.main.body.statements[0]
	_check(loop_node.body.statements.size() == 1 and loop_node.body.statements[0] is ProgramAst.IfNode, "循环内保留显式 IfNode")
	var branch: ProgramAst.IfNode = loop_node.body.statements[0]
	_check(branch.condition is ProgramAst.ReadyNode and branch.condition.receiver == "gun" and branch.line == 3, "条件保存命名模块和准确源码行")
	_check(branch.then_body.statements.size() == 1 and branch.else_body.statements.size() == 1, "真假分支各自保留动作，不展开成同一顺序队列")


## 实际冷却反复选择两个分支，保持水平退行和真实弹丸命中，击毁敌人后停止。
func _test_solution() -> void:
	var document_before := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "双模块条件退射程序可以启动"):
		return
	var spawn := session.world.player.position
	var enemy_spawn := session.world.get_machine("pursuer").position
	_check(session.world.tick_index == 0 and session.world.projectiles.is_empty(), "运行入口只准备程序，不提前推进或开火")
	var finished: Array[int] = []
	# 用途：确认无限循环获胜后只提交一次关卡完成信号。
	session.completed.connect(func() -> void: finished.append(1))
	var horizontal := true
	var bounded := true
	var supported := true
	var saw_shot := false
	var saw_retreat := false
	var saw_damage := false
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			break
		var before := session.world.tick_index
		var position_before := session.world.player.position
		session.step()
		bounded = bounded and session.world.tick_index - before <= 1
		horizontal = horizontal and is_equal_approx(session.world.player.position.y, spawn.y) and is_equal_approx(session.world.get_machine("pursuer").position.y, enemy_spawn.y)
		saw_shot = saw_shot or not session.world.projectiles.is_empty()
		saw_retreat = saw_retreat or session.world.player.position.x < position_before.x
		for module in session.world.player.modules:
			supported = supported and TerrainCollision.is_rect_supported(module.get_world_rect(session.world.player.position), session.world.document, _content)
		for module in session.world.get_machine("pursuer").modules:
			saw_damage = saw_damage or module.health < module.max_health
	_check(saw_shot and saw_retreat and saw_damage, "真实就绪和冷却分支分别射击与后退，敌方模块受到弹丸伤害")
	_check(horizontal and bounded and supported, "战斗保持水平和实际地板占地，每次 step 至多推进一个 tick")
	_check(session.state == GameSession.State.SUCCEEDED and session.world.get_machine("pursuer").is_destroyed(), "边退边射击毁全部敌方模块后通关")
	_check(not session.world.player.is_destroyed() and session.world.player.position.x < spawn.x, "玩家通过真实退行保持存活")
	_check(session.world.get_machine("pursuer").position.x < enemy_spawn.x - 4.5, "敌人会越过第四关四点五格的停步距离继续追击")
	_check(session.runner.state == ProgramRunner.State.CANCELLED, "通关会取消仍处于无限循环的解释器")
	var final_tick := session.world.tick_index
	var final_position := session.world.player.position
	for unused in 10:
		session.step()
	_check(finished.size() == 1 and session.world.tick_index == final_tick and session.world.player.position == final_position, "胜利后世界停止且完成信号不重复")
	_check(session.source == SOLUTION and JSON.stringify(_level.document.to_dict()) == document_before, "战斗不污染玩家源码或静态关卡耐久")
	var named := _session(SOLUTION.replace("move(180", "drive.move(180"))
	if _check(named.run().is_ok(), "第五关学过的具名移动可放入 else 分支"):
		_finish(named)
		_check(named.state == GameSession.State.SUCCEEDED, "具名驱动退射也通过同一战场")


## 站立射击和只后退无法完成目标，保证玩家必须观察追击和冷却而非套用第四关。
func _test_failures() -> void:
	for source in ["main(){}\ntick(){shoot(0)}", "main(){\nloop{\nmove(180,0.1)\n}\n}", SOLUTION.replace("gun.shoot(0)", "gun.shoot(90)")]:
		var session := _session(source)
		if not _check(session.run().is_ok(), "错误策略可以启动供玩家观察实际结果"):
			continue
		_finish(session)
		_check(session.state == GameSession.State.FAILED and not session.world.get_machine("pursuer").is_destroyed(), "站立、只退或错误射击方向无法击败追击者")
		_check(session.source == source and session.assembly.modules.size() == 2, "失败保留玩家的源代码和装配")
	for gun_offset in [Vector2(0.5, 0), Vector2(-0.5, 0)]:
		var dual := GameSession.create(_level, _content)
		_check(dual.assembly.add_module("shooting", Vector2.ZERO, "first").is_ok() and dual.assembly.add_module("shooting", gun_offset, "second").is_ok(), "两种水平双射击装配均合法")
		dual.source = "main(){}\ntick(){shoot(0)}"
		if _check(dual.run().is_ok(), "双射击站立策略可以实际尝试"):
			_finish(dual)
			_check(dual.state == GameSession.State.FAILED and dual.world.player.is_destroyed(), "两个站立射击模块也会被追击者击败，不能靠堆火力跳过退行")


## 名称、能力和未选中的分支均在第一条动作之前预检，不允许部分执行错误程序。
func _test_preflight() -> void:
	var cases := [
		{"source": SOLUTION.replace("gun.ready()", "Gun.ready()"), "line": 3},
		{"source": SOLUTION.replace("gun.ready()", "drive.ready()"), "line": 3},
		{"source": SOLUTION.replace("move(180, 0.1)", "missing.move(180, 0.1)"), "line": 6},
		{"source": SOLUTION.replace("move(180, 0.1)", "gun.move(180, 0.1)"), "line": 6},
	]
	for entry: Dictionary in cases:
		var session := _session(entry.source)
		_check(not session.run().is_ok() and session.state == GameSession.State.FAILED and session.current_line == entry.line, "错误名称或能力定位到条件或动作源代码行")
		_check(session.world == null or (session.world.tick_index == 0 and session.world.projectiles.is_empty()), "即使错误只在首次未选中的 else 分支，也不能提前射击")
		_check(session.source == entry.source and session.assembly.modules.size() == 2, "预检失败不丢失编辑内容")


## 暂停冻结整个战场，停止、重试和重置代码清除控制流状态但保留手工装配。
func _test_pause_stop_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停回归可以启动条件程序"):
		return
	session.step()
	var old_world := session.world
	var old_runner := session.runner
	var before := _runtime_snapshot(session)
	session.pause()
	for unused in 8:
		session.step()
	_check(session.state == GameSession.State.PAUSED and _runtime_snapshot(session) == before, "暂停冻结玩家、敌人、冷却、弹丸及源码行")
	session.resume()
	session.step()
	_check(session.world == old_world and old_world.tick_index == 2 and session.world.player.position.x < float(_level.document.player_spawn.position.x), "恢复沿原条件分支继续后退，而非重新射击或重置")
	var assembly := JSON.stringify(session.assembly.modules)
	session.stop()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null and old_runner.state == ProgramRunner.State.CANCELLED, "停止解除世界并取消条件执行栈")
	_check(session.source == SOLUTION and JSON.stringify(session.assembly.modules) == assembly, "停止保留源码和两个命名模块")
	if not _check(session.run().is_ok(), "停止后同一条件程序可重新运行"):
		return
	_check(session.world != old_world and session.world.tick_index == 0 and session.world.projectiles.is_empty(), "重试使用全新世界、零时间和无残余弹丸")
	_check(session.world.is_shoot_ready(session.world.player.id, "gun").value == true, "重试恢复射击模块就绪状态")
	for module in session.world.get_machine("pursuer").modules:
		_check(module.available and is_equal_approx(module.health, module.max_health), "重试恢复每个敌方模块完整耐久")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "暂停停止后的完整重试仍可通关")
	session.reset_code()
	_check(session.source == _level.starter_program and session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "重置代码恢复空框架并释放已完成世界")
	_check(JSON.stringify(session.assembly.modules) == assembly, "重置代码不替换玩家的双模块装配")
	_check(not session.run().is_ok(), "重置后空循环需要玩家重新补写，不能自动重用旧答案")


## 条件必须逐关显式开放，缺省兼容旧地图；失败校验不修改输入快照。
func _test_unlocks_and_metadata() -> void:
	for index in range(1, 7):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, _content, true)
		if not _check(loaded.is_ok(), "条件兼容检查可以加载第 %d 关" % index):
			continue
		var defined := LevelDefinition.from_document(loaded.value, _content)
		if not _check(defined.is_ok(), "前六关元数据仍有效"):
			continue
		var previous: LevelDefinition = defined.value
		_check(not previous.allow_conditionals, "前六关不会提前开放 if 条件")
		var conditional := "main(){\nif(gun.ready()){\nshoot(0)\n}else{\nshoot(180)\n}\n}"
		_check(not ProgramParser.parse(conditional, previous.allowed_calls, previous.allow_tick, previous.allow_named_calls, previous.allow_loops, previous.allow_conditionals).is_ok(), "前六关在编译时拒绝条件语法")
		_check(previous.allow_tick == (index >= 4) and previous.allow_named_calls == (index >= 5) and previous.allow_loops == (index >= 6), "原有能力开放顺序保持不变")
	var original := JSON.stringify(_level.document.to_dict())
	for value in [0, 1, "true", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_conditionals = value
		var snapshot := JSON.stringify(document.to_dict())
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "条件开关拒绝非布尔值 " + str(value))
		_check(JSON.stringify(document.to_dict()) == snapshot, "条件开关校验失败不改写输入")
	var legacy := _level.document.duplicate_document()
	legacy.properties.level.erase("allow_conditionals")
	var parsed := LevelDefinition.from_document(legacy, _content)
	_check(parsed.is_ok() and not parsed.value.allow_conditionals, "省略条件权限的旧格式默认关闭")
	_check(JSON.stringify(_level.document.to_dict()) == original, "兼容性负例不污染生产地图")


## 小时限快照验证超时取消条件程序，并且提示不再推荐第四关站立射击答案。
func _test_deadline() -> void:
	var document := _level.document.duplicate_document()
	document.properties.level.max_ticks = 2
	var defined := LevelDefinition.from_document(document, _content)
	if not _check(defined.is_ok(), "条件关卡可使用作者配置的有限练习时长"):
		return
	var session := GameSession.create(defined.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	session.assembly.add_module("shooting", Vector2(0.5, 0), "gun")
	session.source = SOLUTION
	if not _check(session.run().is_ok(), "短时限条件练习可以运行"):
		return
	_finish(session)
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 2 and session.runner.state == ProgramRunner.State.CANCELLED, "到达配置时限后失败并取消剩余循环")
	_check(not session.message.contains("shoot(0)") and not session.message.contains("tick()"), "第七关超时不再推荐第四关的站立开火代码")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 2, "超时仍保留源程序和装配")


## 统一按当前关卡的全部能力开关编译，避免测试入口比正式会话额外解锁能力。
func _parse(source: String) -> DataResult:
	return ProgramParser.parse(source, _level.allowed_calls, _level.allow_tick, _level.allow_named_calls, _level.allow_loops, _level.allow_conditionals)


## 每次通过公开装配入口手动安装，不能利用地图出生模板绕过空装配约定。
func _session(source: String) -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "第七关每次新会话先空装配")
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "玩家可安装中心驱动")
	_check(session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "玩家可安装水平共边的具名射击模块")
	session.source = source
	return session


## 记录可观察的运行状态，不依赖解释器私有栈结构判断暂停是否冻结。
func _runtime_snapshot(session: GameSession) -> String:
	var state: Array = [session.world.tick_index, session.world.player.position, session.world.get_machine("pursuer").position, session.current_line]
	for module in session.world.player.modules:
		state.append([module.health, module.next_shoot_tick])
	for projectile in session.world.projectiles:
		state.append([projectile.position, projectile.speed])
	return var_to_str(state)


## 为所有失败与胜利尝试提供明确步进上限，避免无限循环导致测试进程卡住。
func _finish(session: GameSession) -> void:
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第七关会话应在有限练习时长内结束")


## 统一累计断言并输出可定位的失败描述，测试退出码与日志结果保持一致。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
