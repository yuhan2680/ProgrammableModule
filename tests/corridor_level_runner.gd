extends SceneTree
## 第十四关：真实通道推进、栅栏射击与十波结算，不通过代扣血验证通关。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _source := ""

## 类注册完成后运行独立数据会话，不触碰玩家存档。
func _initialize() -> void:
	_run.call_deferred()

## 覆盖关卡流程、旧遮挡默认值、非法输入和代码提示。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "注册表加载")
	var loaded := MapCodec.load_file("res://data/levels/level_014.json", _content, true)
	if not _check(loaded.is_ok(), "地图合法：" + str(loaded.errors)):
		_finish()
		return
	var definition := LevelDefinition.from_document(loaded.value, _content, "res://data/levels/level_014.json")
	if not _check(definition.is_ok(), "关卡定义合法"):
		_finish()
		return
	_level = definition.value
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_014.json"))
	_source = hint.source.replace("{{radar}}", "radar").replace("{{gun}}", "gun").replace("{{drive}}", "drive")
	_test_definition()
	_test_battle()
	_test_pause_reset_and_wrong_program()
	_test_bars()
	_test_validation()
	_test_hint()
	_finish()

## 地图比例、十条侧道和权限由正式数据核对，不硬编码到模拟。
func _test_definition() -> void:
	_check(_level.order == 14 and _level.module_limit == 3 and _level.goal_type == "destroy_waves", "用户确认的三模块十波目标")
	_check(_level.allow_radar and _level.allow_random and _level.allow_for and _level.allow_simultaneous and _level.allow_functions, "继承前关能力")
	_check(_level.document.enemies.size() == 10 and _level.document.width == 18 and _level.document.height == 35, "纵向鱼骨地图与十波")
	for y in range(1, 34):
		var main_width := 0
		for x in range(7, 11):
			if TerrainCollision.is_cell_passable(Vector2i(x, y), _level.document, _content):
				main_width += 1
		_check(main_width == 4, "主路连续四格宽")
		_check(not TerrainCollision.is_cell_passable(Vector2i(6, y), _level.document, _content) and not TerrainCollision.is_cell_passable(Vector2i(11, y), _level.document, _content), "两侧墙或栅栏不计入四格可通行范围")
	var bars := 0
	for cell in _level.document.cells:
		if _level.document.get_tile_id(cell) == "iron_bars":
			bars += 1
	_check(bars == 10, "左右各五条支道有独立栅栏")
	for entry in _level.document.enemies:
		_check(entry.properties.module_health == {"blade": 2.7, "engine": 2.7} and entry.properties.wreck_fade_seconds == 3.0, "每个敌人两模块耐久2.7和残骸淡出")
	var parsed := ProgramParser.new().parse(_level.starter_program, _level.allowed_calls, _level.allow_tick, _level.allow_named_calls, _level.allow_loops, _level.allow_conditionals, _level.allow_simultaneous, _level.allow_distance, _level.allow_functions, _level.allow_variables, _level.allow_radar, _level.allow_random, _level.allow_for)
	_check(parsed.is_ok() and not _level.starter_program.contains("shoot"), "初始程序保留空框架")

## 每次重新建立空装配，并通过公开装配接口安装三种模块。
func _session() -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "进入关卡不预装")
	_check(session.assembly.add_module("radar", Vector2.ZERO, "radar").is_ok(), "雷达居中")
	_check(session.assembly.add_module("shooting", Vector2(.5, 0), "gun").is_ok(), "右侧射击")
	_check(session.assembly.add_module("movement", Vector2(-.5, 0), "drive").is_ok(), "左侧移动")
	_check(not session.assembly.add_module("movement", Vector2(0, .5), "extra").is_ok(), "不能安装第四个模块")
	session.source = _source
	return session

## 只靠正式移动和弹丸完成十波，同时验证待生敌人不可探测、受损整机不算清波。
func _test_battle() -> void:
	var session := _session()
	var original := _level.document.to_dict()
	if not _check(session.run().is_ok(), "真实程序开始"):
		return
	_check(session.world.get_enemy_wave_status().pending == 10 and session.world.machines.size() == 1, "进入触发区域之前十波均待生")
	_check(session.world.query_scan("player", "radar").value == null, "雷达不扫描待生敌人")
	var seen := {}
	var partial := false
	for unused in 2400:
		var status := session.world.get_enemy_wave_status()
		if status.active:
			var enemy := session.world.get_machine(status.active_enemy_id)
			if not seen.has(enemy.id):
				seen[enemy.id] = true
				_check(enemy.modules.all(func(m: ModuleInstance) -> bool: return is_equal_approx(m.max_health, 2.7)), "运行实例耐久为2.7")
				_check(session.world.player.position.y <= enemy.position.y + .01, "推进到支道才激活")
			if enemy.modules.any(func(m: ModuleInstance) -> bool: return not m.available):
				partial = true
				_check(not enemy.is_destroyed() and status.completed == seen.size() - 1, "只毁一个部件不清波")
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "正式雷达程序通关：" + session.message)
	_check(seen.size() == 10 and partial and session.world.get_enemy_wave_status().all_cleared, "所有波次实际出场并击毁")
	_check(session.world.player.position.y < 6 and session.world.player.position.y > 4 and is_equal_approx(session.world.player.position.x, 9), "必须沿主通道真实推进至末组支道")
	_check(session.world.player.modules.all(func(m: ModuleInstance) -> bool: return m.available), "推荐布局正常存活")
	for machine in session.world.machines:
		if machine.id == "player":
			continue
		_check(machine.position.x < 6 or machine.position.x > 11, "敌人不能穿过栅栏")
	_check(_level.document.to_dict() == original, "运行不改写地图")
	session.stop()

## 暂停冻结位置与触发进度；重试清空波次；原地射击无法自动完成关卡。
func _test_pause_reset_and_wrong_program() -> void:
	var session := _session()
	_check(session.run().is_ok(), "暂停流程启动")
	for unused in 40:
		session.step()
	var snapshot := session.world.get_enemy_wave_status()
	var position := session.world.player.position
	session.pause()
	for unused in 20:
		session.step()
	_check(session.world.tick_index == 40 and session.world.player.position == position and session.world.get_enemy_wave_status() == snapshot, "暂停不移动或触发新波次")
	session.resume()
	session.step()
	_check(session.world.tick_index == 41, "恢复同一世界")
	session.reset()
	_check(session.source == _source and session.assembly.modules.size() == 3 and session.run().is_ok(), "重试保留装配和程序")
	_check(session.world.get_enemy_wave_status().pending == 10 and session.world.tick_index == 0, "重试恢复所有待生波次")
	session.stop()
	session.source = "main() { loop { gun.shoot(0) } }"
	_check(session.run().is_ok(), "原地射击对照运行")
	for unused in 2401:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.FAILED and session.world.get_enemy_wave_status().completed == 0 and session.message.contains("推进"), "不前进不会生成或自动清除敌人")
	session.stop()

## 建立最小真实栅栏试验场，双方同受地形约束，敌人静止便于核对攻击语义。
func _bar_world(tile: String, module_id: String) -> SimulationWorld:
	var doc := MapDocument.new()
	doc.id = "bar_test"
	doc.width = 8
	doc.height = 5
	for y in 5:
		for x in 8:
			doc.set_tile(Vector2i(x,y), "floor")
	doc.set_tile(Vector2i(3,2), tile)
	doc.player_spawn = {"position":{"x":2.5,"y":2.5},"modules":[{"id":"tool","module_id":module_id,"offset":{"x":0,"y":0}}]}
	doc.enemies = [{"id":"guard","behavior":"alarm_guard","position":{"x":4.5,"y":2.5},"modules":[{"id":"engine","module_id":"movement","offset":{"x":0,"y":0}}],"properties":{}}]
	var created := SimulationWorld.create(doc, _content)
	_check(created.is_ok(), "栅栏试验场合法")
	return created.value

## 使用实际动作验证栅栏放行双向攻击但拦截双向移动，实墙和 void 仍挡住攻击。
func _test_bars() -> void:
	for tile in ["iron_bars", "wall", ""]:
		var melee := _bar_world(tile, "melee")
		_check(melee.request_attack("player", 0).is_ok(), "真实近战请求")
		melee.step()
		_check(melee.get_machine("guard").is_destroyed() == (tile == "iron_bars"), "近战仅穿过栅栏：" + tile)
		var shooting := _bar_world(tile, "shooting")
		_check(shooting.request_shoot("player", 0).is_ok(), "真实射击请求")
		for unused in 20:
			shooting.step()
		_check(shooting.get_machine("guard").is_destroyed() == (tile == "iron_bars"), "弹丸仅穿过栅栏：" + tile)
		if not tile.is_empty():
			var radar := _bar_world(tile, "radar")
			_check((radar.query_scan("player", "tool").value != null) == (tile == "iron_bars"), "雷达穿栅栏但受墙遮挡")
	var edge_radar := _bar_world("floor", "radar")
	edge_radar.player.position.y = 2.0
	edge_radar.get_machine("guard").position.y = 2.0
	edge_radar.document.set_tile(Vector2i(3, 1), "wall")
	_check(edge_radar.query_scan("player", "tool").value == null, "雷达恰好沿格线也保留上侧墙的遮挡")
	edge_radar.document.set_tile(Vector2i(3, 1), "floor")
	edge_radar.document.set_tile(Vector2i(3, 2), "wall")
	_check(edge_radar.query_scan("player", "tool").value == null, "雷达恰好沿格线也保留下侧墙的遮挡")
	var movement := _bar_world("iron_bars", "movement")
	var player_move: MovementCommand = movement.request_move("player", 0, 5).value
	var enemy_move: MovementCommand = movement.request_move("guard", 180, 5).value
	for unused in 20:
		movement.step()
	_check(player_move.state == SimulationCommand.State.BLOCKED and enemy_move.state == SimulationCommand.State.BLOCKED, "玩家和敌人的长距离移动均被栅栏阻挡")
	_check(is_equal_approx(movement.player.position.x, 2.75) and is_equal_approx(movement.get_machine("guard").position.x, 4.25), "真实模块停在栅栏两侧而不穿越")
	var ranged := _bar_world("iron_bars", "rangefinder")
	_check(is_equal_approx(float(ranged.query_distance("player", 0, "tool").value), .5), "测距仍读取不可通行的栅栏")

## 新字段采用严格布尔或有限矩形输入，旧内容与代码构造地块默认继承碰撞行为。
func _test_validation() -> void:
	var old: Dictionary = _content.get_tile("wall").raw.duplicate(true)
	old.erase("attack_block")
	_check(ContentRegistry._parse_tile(old).value.attack_block, "缺少字段的旧墙仍挡攻击")
	var code_wall := TileDefinition.new()
	code_wall.collision = true
	_check(code_wall.attack_block, "代码创建的旧墙仍挡攻击")
	code_wall.collision = false
	_check(not code_wall.attack_block, "未显式覆盖时随碰撞字段变化")
	for bad in [null, 0, "false", []]:
		old.attack_block = bad
		_check(not ContentRegistry._parse_tile(old).is_ok(), "非法攻击遮挡被拒绝")
	for bad in [null, [], {}, {"position":{"x":NAN,"y":0},"size":{"x":1,"y":1}}, {"position":{"x":0,"y":0},"size":{"x":true,"y":1}}, {"position":{"x":0,"y":0},"size":{"x":0,"y":1}}, {"position":{"x":17,"y":1},"size":{"x":2,"y":1}}]:
		var doc := _level.document.duplicate_document()
		doc.enemies[0].properties.activation_region = bad
		_check(not MapCodec.validate(doc, _content, true).is_ok(), "非法或出界触发区域被拒绝")

## 提示使用真实三模块方案，只在正式教学来源生效。
func _test_hint() -> void:
	var session := _session()
	session.source = _level.starter_program
	for unused in 16:
		var result := CodeHintService.next_hint(session)
		if not result.is_ok():
			_check(result.errors[0].contains("已经能够完成"), "提示逐步补齐：" + str(result.errors))
			break
		session.source = result.value.source
	_check(session.source.contains("move(90, 0.1)") and session.source.contains("shoot(target.Angle())"), "包含扫描射击和短步推进")
	_check(session.run().is_ok(), "提示实际可运行")
	for unused in 2400:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "提示实际完成所有波次")
	session.stop()
	var imported := LevelDefinition.from_document(_level.document, _content, "user://levels/level_014.json")
	_check(not CodeHintService.next_hint(GameSession.create(imported.value, _content)).is_ok(), "导入同名关卡不开放教学提示")

## 统一累计失败，保留可定位原因。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition

## 使用与统一测试入口一致的完成标记。
func _finish() -> void:
	print("第十四关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
