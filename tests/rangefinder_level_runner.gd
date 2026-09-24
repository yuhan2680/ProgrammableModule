extends SceneTree
## 使用真实第九关验证测距导航、实体占地、逐关解锁与重复运行，不读写玩家存档。

const SOLUTION := "main() {\n    loop {\n        move(0, distance(0) - 0.5)\n        move(90, distance(90) - 0.5)\n        move(180, distance(180) - 0.5)\n        move(90, distance(90) - 0.5)\n    }\n}\n"
const SPAWN := Vector2(2.5, 18.5)
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 在全局类完成初始化之后运行真实关卡回归。
func _initialize() -> void:
	_run.call_deferred()


## 加载生产定义并依次检查教学流程、失败边界和状态恢复。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "测距教学内容加载成功"):
		quit(1)
		return
	var loaded := MapCodec.load_file("res://data/levels/level_009.json", _content, true)
	if not _check(loaded.is_ok(), "第九关生产地图合法：" + str(loaded.errors)):
		quit(1)
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "第九关生产规则合法：" + str(defined.errors)):
		quit(1)
		return
	_level = defined.value
	_test_design_and_unlocks()
	_test_solution()
	_test_dynamic_measurement()
	_test_footprint_and_failures()
	_test_pause_and_retry()
	_test_validation()
	print("第九关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 新关卡完整收录、空装配与两模块上限保持真实数据驱动，旧八关不提前解锁。
func _test_design_and_unlocks() -> void:
	_check(_level.id == "level_009" and _level.order == 9 and _level.module_limit == 2, "第九关稳定 ID、排序和两模块上限")
	_check(_level.display_name == "第九关 · 蜿蜒穿行", "使用玩家指定的第九关名称")
	_check(_level.allow_distance and _level.allow_named_calls and _level.allow_loops and _level.allow_conditionals and _level.allow_simultaneous and _level.allow_tick, "开放测距并保留之前已学能力")
	_check(_level.allowed_modules == PackedStringArray(["movement", "melee", "shooting", "rangefinder"]), "新增测距而不移除已学模块")
	_check(_level.goal_type == "reach_position" and _level.goal_position == Vector2(21.5, 2.5), "蛇形隧道以真实终点作为目标")
	_check(_level.document.enemies.is_empty() and _level.document.objects.is_empty(), "本关只教学探路，不额外加入战斗或机关")
	_check(_level.document.get_tile_id(Vector2i(10, 17)).is_empty(), "通道之间仍是 void，不填平隧道")
	_check(_level.document.dialogue.size() == 7, "完整七页装配、测距与留余量引导")
	_check(not _level.starter_program.contains("distance") and not _level.starter_program.contains("move") and not _level.starter_program.contains("loop"), "初始 main 框架不预填答案")
	var session := _session(SOLUTION)
	_check(not session.assembly.add_module("movement", Vector2(0, 1)).is_ok(), "公开装配接口拒绝第三个模块")
	_check(session.assembly.build_document().is_ok(), "推荐上下相连布局通过完整出生占地校验")
	var catalog := LevelCatalog.new()
	catalog.user_directory = "user://tests/rangefinder_level_missing_imports"
	_check(catalog.refresh(_content).is_ok() and catalog.levels.size() == 15 and catalog.levels[14].id == "level_015", "隔离导入目录时可加载第一至第十五关共十五个教学关卡")
	for number in range(1, 9):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(loaded.is_ok(), "旧关卡 %d 地图仍合法" % number):
			continue
		var previous := LevelDefinition.from_document(loaded.value, _content)
		if not _check(previous.is_ok(), "旧关卡规则仍合法"):
			continue
		var prior: LevelDefinition = previous.value
		_check(not prior.allow_distance and not "rangefinder" in prior.allowed_modules, "前八关没有提前开放测距模块与语法")
		_check(not ProgramParser.parse("main(){move(0, distance(0))}", prior.allowed_calls, prior.allow_tick, prior.allow_named_calls, prior.allow_loops, prior.allow_conditionals, prior.allow_simultaneous, prior.allow_distance).is_ok(), "旧关卡拒绝新测距表达式")


## 测距循环走完五段水平通道，终点通知唯一且不会修改地图或玩家程序。
func _test_solution() -> void:
	var before := JSON.stringify(_level.document.to_dict())
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "测距循环可以启动"):
		return
	var completions: Array[int] = []
	# 用途：记录终点事件，不捕获会话对象，避免形成引用环。
	session.completed.connect(func() -> void: completions.append(1))
	_check(session.world.tick_index == 0 and session.world.player.position == SPAWN, "读取和排队不提前消耗世界时间或移动")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "真实测距循环到达终点：" + session.message)
	_check(session.world.player.position.distance_to(_level.goal_position) <= _level.goal_radius + 0.00001, "通过实际位置到达或经过终点才算完成")
	_check(session.world.tick_index > 1000 and completions.size() == 1, "长蛇路线真实执行全部通道并只通关一次")
	var final_tick := session.world.tick_index
	for unused in 8:
		session.step()
	_check(session.world.tick_index == final_tick and completions.size() == 1, "通关后自动停止循环且不重复计时或通知")
	_check(JSON.stringify(_level.document.to_dict()) == before and session.source == SOLUTION, "运行不污染关卡快照和玩家源码")
	var named := _session(SOLUTION.replace("distance(", "sensor.distance("))
	if _check(named.run().is_ok(), "具名 sensor.distance 可执行同一路线"):
		_finish(named)
		_check(named.state == GameSession.State.SUCCEEDED, "具名测距从传感器实际中心完成导航")


## 缩短通道后复用原程序仍能导航，排除按关卡 ID 或固定路程伪造测量。
func _test_dynamic_measurement() -> void:
	var document := _level.document.duplicate_document()
	document.id = "rangefinder_shorter_tunnel"
	document.width = 22
	document.cells.clear()
	for y in [2, 3, 6, 7, 10, 11, 14, 15, 18, 19]:
		for x in range(2, 20):
			document.set_tile(Vector2i(x, y), "floor")
	for x in [18, 19]:
		for y in range(14, 20):
			document.set_tile(Vector2i(x, y), "floor")
		for y in range(6, 12):
			document.set_tile(Vector2i(x, y), "floor")
	for x in [2, 3]:
		for y in range(10, 16):
			document.set_tile(Vector2i(x, y), "floor")
		for y in range(2, 8):
			document.set_tile(Vector2i(x, y), "floor")
	document.properties.level.goal.position.x = 19.5
	var defined := LevelDefinition.from_document(document, _content)
	if not _check(defined.is_ok(), "缩短的独立地图仍是合法关卡"):
		return
	var session := _session(SOLUTION, Vector2(0, 0.5), defined.value)
	if not _check(session.run().is_ok(), "不修改程序即可开始较短通道"):
		return
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "同一测距循环适应不同通道长度：" + session.message)
	_check(session.world.player.position.distance_to(Vector2(19.5, 2.5)) <= 0.25001, "变体到达自己的终点而非旧坐标")
	_check(_level.goal_position == Vector2(21.5, 2.5) and _level.document.width == 24, "变体不污染生产地图")
	var condition := _session("main(){\nif(distance(0) > distance(90)){\nmove(0, distance(0) - 0.5)\n}else{\nmove(180,0)\n}\n}")
	if _check(condition.run().is_ok(), "数值比较可以读取真实方向测距"):
		_finish(condition)
		_check(condition.state == GameSession.State.FAILED and condition.world.player.position.is_equal_approx(Vector2(21.5, 18.5)), "条件选择更长的右侧通道，单段完成仍不能冒充通关")


## 缺测距、错误名称和未预留实体空间分别通过正常诊断与碰撞失败。
func _test_footprint_and_failures() -> void:
	var no_clearance := _session("main(){move(0, distance(0))}")
	if _check(no_clearance.run().is_ok(), "不留余量的路线仍允许玩家尝试"):
		_finish(no_clearance)
		_check(no_clearance.state == GameSession.State.FAILED and no_clearance.world.player.position.x < 22.0, "细射线不是实体通行保证，模块边缘碰墙就失败")
	var sideways := _session(SOLUTION, Vector2(0.5, 0))
	if _check(sideways.run().is_ok(), "横向布局在出生点合法"):
		_finish(sideways)
		_check(sideways.state == GameSession.State.FAILED and sideways.world.player.position.x < 21.5, "改变布局后原半格余量不再够用，完整占地校验仍生效")
	for invalid in ["main(){move(0, missing.distance(0))}", "main(){move(0, drive.distance(0))}", "main(){distance(0)}"]:
		var session := _session(invalid)
		_check(not session.run().is_ok() and session.state == GameSession.State.FAILED, "无效接收者或独立查询拒绝执行")
		_check(session.current_line > 0 and session.message.contains("列"), "测距诊断保留行列定位")
		_check(session.world == null or session.world.tick_index == 0, "错误在执行前拒绝，机器不提前行动")
	var missing := GameSession.create(_level, _content)
	_check(missing.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "无测距案例仍有合法移动装配")
	missing.source = SOLUTION
	_check(not missing.run().is_ok() and missing.state == GameSession.State.FAILED, "没有测距模块无法读取 distance")
	var unfinished := _session(_level.starter_program)
	if _check(unfinished.run().is_ok(), "空入口框架可尝试"):
		_finish(unfinished)
		_check(unfinished.state == GameSession.State.FAILED and unfinished.world.player.position == SPAWN, "没填写导航代码不会自动通过隧道")


## 暂停冻结正在执行的测距移动，重置和再次运行创建新世界并保留作品。
func _test_pause_and_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停案例启动"):
		return
	for unused in 23:
		session.step()
	var position := session.world.player.position
	var ticks := session.world.tick_index
	session.pause()
	for unused in 20:
		session.step()
	_check(session.world.player.position == position and session.world.tick_index == ticks, "暂停冻结位置、查询所见世界及世界 tick")
	session.resume()
	session.step()
	_check(session.world.tick_index == ticks + 1 and session.world.player.position.x > position.x, "恢复继续当前移动而非重新量整段")
	var first_world := session.world
	session.reset()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "重置释放旧运行世界和解释器")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 2 and session.assembly.modules[0].id == "sensor", "重置保留源码与具名装配")
	if not _check(session.run().is_ok(), "重置后可重新运行"):
		return
	_check(session.world != first_world and session.world.player.position == SPAWN and session.world.tick_index == 0, "重新测距来自全新起点世界")
	_finish(session)
	_check(session.state == GameSession.State.SUCCEEDED, "重置后仍能实际通关")
	session.reset_code()
	_check(session.source == _level.starter_program and session.assembly.modules.size() == 2 and session.world == null, "重置代码只恢复教学框架，装配保留")


## 测距权限严格读取布尔值，旧数据缺省关闭且无效输入保持未修改。
func _test_validation() -> void:
	for value in [0, 1, "true", [], {}, null]:
		var document := _level.document.duplicate_document()
		document.properties.level.allow_distance = value
		var before := JSON.stringify(document.to_dict())
		_check(not LevelDefinition.from_document(document, _content).is_ok(), "测距权限拒绝非布尔值")
		_check(JSON.stringify(document.to_dict()) == before, "拒绝坏数据不改写调用方快照")
	var legacy := _level.document.duplicate_document()
	legacy.properties.level.erase("allow_distance")
	var defined := LevelDefinition.from_document(legacy, _content)
	_check(defined.is_ok() and not defined.value.allow_distance, "省略测距权限的旧地图默认不解锁")


## 仅通过公开装配接口手动安装测距与移动模块，不读取或预装历史草稿。
func _session(source: String, drive_offset: Vector2 = Vector2(0, 0.5), definition: LevelDefinition = null) -> GameSession:
	var session := GameSession.create(_level if definition == null else definition, _content)
	_check(session.assembly.modules.is_empty(), "进入第九关仍从空装配开始")
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "中心手动安装测距 sensor")
	_check(session.assembly.add_module("movement", drive_offset, "drive").is_ok(), "共边手动安装移动 drive")
	session.source = source
	return session


## 给整条长蛇路线足够真实 tick，同时避免解释器异常造成无限等待。
func _finish(session: GameSession) -> void:
	for unused in 2000:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "第九关测试应在两千个逻辑 tick 内结束")


## 汇总每项检查并让命令行可以判断真实失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
