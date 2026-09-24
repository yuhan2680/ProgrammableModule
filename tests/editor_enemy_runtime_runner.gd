extends SceneTree
## 自定义敌人运行回归只用内存夹具，不读写玩家存档或正式关卡。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()


## 自动加载完成后再运行真实数据与固定 tick 世界。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖可信配置、独立耐久、追击、逐部件武器、地形与启停会话。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "加载真实模块与地块")
	_test_validation_and_health()
	_test_chase_and_capabilities()
	_test_shooting()
	_test_pathfinding()
	_test_disabled_and_session()
	_test_disabled_legacy_maps()
	print("编辑器敌人运行回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 全地板夹具设置高玩家耐久，便于观察持续动作而不在首击终局。
func _document(types: Array[String] = ["movement", "melee", "shooting"]) -> MapDocument:
	var document := MapDocument.new()
	document.width = 20
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 2.5, "y": 6.5}, "modules": [_module("player_drive", "movement")]}
	document.properties = {"level": {"player_max_health": 1000, "module_limit": 1, "allowed_modules": ["movement"], "completion_mode": "reach_or_clear", "max_ticks": 600}}
	var modules: Array[Dictionary] = []
	var health := {}
	for index in types.size():
		var id := "unit_%d" % index
		modules.append(_module(id, types[index], Vector2(index * 0.5, 0)))
		health[id] = 2.8
	document.enemies = [{"id": "custom_enemy", "behavior": EnemyDefinition.AUTO_CHASE_ATTACK, "position": {"x": 12.5, "y": 6.5}, "modules": modules, "properties": {"module_health": health}}]
	return document


## 装配条目保持普通模块与中心偏移格式，不注入解释器源码。
func _module(id: String, type: String, offset: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"id": id, "module_id": type, "offset": {"x": offset.x, "y": offset.y}}


## 世界创建失败清楚报告，避免后续空引用掩盖原始配置错误。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	if not _check(result.is_ok(), "真实世界创建 " + str(result.errors)):
		return null
	return result.value


## 新行为只接受有限耐久且兼容无附加配置；旧可信行为规则不能被放宽。
func _test_validation_and_health() -> void:
	var document := _document()
	var before := document.to_dict()
	var world := _world(document)
	if world == null:
		return
	for module in world.get_machine("custom_enemy").modules:
		_check(module.max_health == 2.8 and module.health == 2.8, "每模块应用独立耐久")
	world.get_machine("custom_enemy").modules[0].apply_damage(1.0)
	var retried := _world(document)
	_check(retried.get_machine("custom_enemy").modules[0].health == 2.8, "新世界恢复耐久")
	_check(world.player.modules[0].health == 1000 and _content.get_module("movement").properties.get("max_health", 1.0) == 1.0, "敌人耐久不影响玩家与共享定义")
	_check(document.to_dict() == before and world.document.to_dict() == before, "运行与损伤不回写地图")
	for value: Variant in [0, -1, true, "2.8", NAN, INF, 1000001, 0.001]:
		var entry: Dictionary = document.enemies[0].duplicate(true)
		entry.properties.module_health.unit_0 = value
		_check(not EnemyDefinition.validate(entry, _content).is_ok(), "拒绝非法耐久 " + str(value))
	var entry: Dictionary = document.enemies[0].duplicate(true)
	entry.properties.module_health.missing = 1
	_check(not EnemyDefinition.validate(entry, _content).is_ok(), "耐久不能引用虚构模块")
	entry = document.enemies[0].duplicate(true)
	entry.erase("properties")
	_check(EnemyDefinition.validate(entry, _content).is_ok(), "新行为缺省属性仍可运行")
	document.enemies = [entry]
	_check(_world(document) != null, "缺省属性世界创建不依赖 properties 字段")
	entry.behavior = EnemyDefinition.BEHAVIOR
	_check(not EnemyDefinition.validate(entry, _content).is_ok(), "旧有限接近行为仍要求原角度配置")


## 追踪当前玩家位置且无凭空能力，移动与武器损坏分别失效。
func _test_chase_and_capabilities() -> void:
	var document := _document(["movement"])
	var world := _world(document)
	var enemy := world.get_machine("custom_enemy")
	world.request_move("player", 90, 2)
	for index in 20:
		world.step()
	_check(enemy.position.x < 12.5 and enemy.position.y < 6.5, "敌人随玩家移动实时修正追击方向")
	_check(world.player.modules[0].health == 1000 and world.projectiles.is_empty() and world.attack_traces.is_empty(), "无武器机器接近但不制造伤害")
	var frozen := enemy.position
	enemy.modules[0].apply_damage(100)
	world.step()
	_check(enemy.position == frozen, "唯一驱动失效后停止移动")
	document = _document(["melee"])
	document.enemies[0].position = {"x": 4.0, "y": 6.5}
	world = _world(document)
	world.step()
	_check(world.get_machine("custom_enemy").position == Vector2(4, 6.5) and world.player.modules[0].health == 999, "静止近战模块按真实射程攻击")
	world.get_machine("custom_enemy").modules[0].apply_damage(100)
	world.step()
	_check(world.player.modules[0].health == 999 and world.attack_traces.is_empty(), "武器损毁后不继续攻击")
	document = _document(["movement", "melee"])
	document.enemies[0].position = {"x": 3.5, "y": 6.5}
	world = _world(document)
	enemy = world.get_machine("custom_enemy")
	enemy.modules[0].apply_damage(100)
	world.step()
	_check(enemy.position == Vector2(3.5, 6.5) and world.player.modules[0].health == 999, "驱动损毁仍保留幸存近战能力")
	document = _document(["movement", "melee"])
	world = _world(document)
	enemy = world.get_machine("custom_enemy")
	enemy.modules[1].apply_damage(100)
	world.step()
	_check(enemy.position.x < 12.5 and world.attack_traces.is_empty(), "武器损毁不取消幸存驱动")


	document = _document(["movement", "melee"])
	document.player_spawn.position = {"x": 5.5, "y": 6.5}
	document.enemies[0].position = {"x": 9.5, "y": 6.5}
	document.enemies[0].modules[1].offset.x = 3.0
	world = _world(document)
	for index in 110:
		world.step()
	_check(world.get_machine("custom_enemy").position.x < 4.5 and world.player.modules[0].health < 1000, "长组合根据武器中心接近，不因原点已靠近而停在射程外")
	document = _document(["radar", "rangefinder"])
	world = _world(document)
	for index in 20:
		world.step()
	_check(world.get_machine("custom_enemy").position == Vector2(12.5, 6.5) and world.player.modules[0].health == 1000 and world.projectiles.is_empty(), "无移动和武器的感应器组合仅作为被动机器存在")


## 发射真实减速弹丸，命中与冷却沿用世界；多个武器分别对准最近存活玩家部件。
func _test_shooting() -> void:
	var document := _document(["shooting"])
	document.enemies[0].position = {"x": 6.5, "y": 6.5}
	var world := _world(document)
	var shots: Array[ShootCommand] = []
	world.shot_finished.connect(func(command: ShootCommand) -> void: shots.append(command))
	world.step()
	_check(shots.size() == 1 and shots[0].shot_count == 1 and world.projectiles.size() == 1, "首 tick 产生真正弹丸而非直接扣血")
	_check(world.player.modules[0].health == 1000, "远程伤害等待弹丸到达")
	for index in 9:
		world.step()
	_check(shots.size() == 1 and world.player.modules[0].health < 1000, "弹丸真实飞行命中且冷却中不再开火")
	world.step()
	_check(shots.size() == 2 and world.get_machine("custom_enemy").position == Vector2(6.5, 6.5), "十 tick 冷却后开火，无驱动不移动")
	world.get_machine("custom_enemy").modules[0].apply_damage(100)
	for index in 12:
		world.step()
	_check(shots.size() == 2, "射击部件失效后不产生新弹丸")
	document = _document(["shooting", "shooting"])
	document.player_spawn.position = {"x": 5, "y": 5}
	document.player_spawn.modules = [_module("top", "movement", Vector2(0, -2)), _module("bottom", "movement", Vector2(0, 2))]
	document.enemies[0].position = {"x": 8, "y": 5}
	document.enemies[0].modules = [_module("unit_0", "shooting", Vector2(0, -2)), _module("unit_1", "shooting", Vector2(0, 1))]
	world = _world(document)
	shots = []
	world.shot_finished.connect(func(command: ShootCommand) -> void: shots.append(command))
	world.step()
	_check(shots.size() == 2 and shots[0].direction.is_equal_approx(Vector2.LEFT) and shots[1].direction.y > 0.1, "两个武器按各自位置独立瞄准最近存活目标")
	world.player.get_module("top").apply_damage(1000)
	for index in 10:
		world.step()
	_check(shots.size() == 4 and shots[2].direction.y > 0.5, "原目标失效后下次开火改瞄存活部件")


## 全高 void 禁止穿越，带出口的墙体通过真实逐 tick 路径绕行而非瞬移。
func _test_pathfinding() -> void:
	var document := _document(["movement"])
	for y in document.height:
		document.set_tile(Vector2i(8, y), "")
	var world := _world(document)
	var enemy := world.get_machine("custom_enemy")
	var supported := true
	for index in 60:
		world.step()
		supported = supported and MachineFactory.validate_placement(enemy, world.document, _content).is_ok()
	_check(enemy.position.x >= 9.25 and supported, "持续追击不能穿过 void，所有 tick 保持真实占地支撑")
	document = _document(["movement"])
	document.player_spawn.position = {"x": 2.5, "y": 3.5}
	document.enemies[0].position = {"x": 10.5, "y": 3.5}
	for y in 8:
		document.set_tile(Vector2i(6, y), "")
	world = _world(document)
	enemy = world.get_machine("custom_enemy")
	var maximum_y := enemy.position.y
	var speed_valid := true
	supported = true
	for index in 240:
		var before := enemy.position
		world.step()
		maximum_y = maxf(maximum_y, enemy.position.y)
		speed_valid = speed_valid and enemy.position.distance_to(before) <= 0.10001
		supported = supported and MachineFactory.validate_placement(enemy, world.document, _content).is_ok()
	_check(maximum_y >= 8.25 and enemy.position.distance_to(world.player.position) < 1.0, "有界寻路能绕过长墙靠近玩家")
	_check(speed_valid and supported, "绕路各步遵守真实速度与占地，没有瞬移穿墙")
	document = _document(["movement"])
	document.objects = [{"id": "block", "type": "destructible", "position": {"x": 8.5, "y": 6.5}, "properties": {"max_health": 1000}}]
	world = _world(document)
	enemy = world.get_machine("custom_enemy")
	var avoided_object := true
	for index in 130:
		world.step()
		avoided_object = avoided_object and not enemy.modules[0].get_world_rect(enemy.position).intersects(world.get_object("block").definition.rect)
	_check(avoided_object and enemy.position.x < 8, "自动路径也绕开真实动态障碍")


## 禁用保留数据但不生成实例，不提前清场获胜；暂停和重试属于同一会话时钟。
func _test_disabled_and_session() -> void:
	var document := _document()
	document.properties.level.enemies_enabled = false
	var before := document.to_dict()
	var world := _world(document)
	_check(not world.are_enemies_enabled() and world.machines.size() == 1 and world.get_machine("custom_enemy") == null, "关闭后世界仅生成玩家")
	for index in 30:
		world.step()
	_check(world.player.modules[0].health == 1000 and world.projectiles.is_empty(), "关闭后无幽灵攻击或弹丸")
	_check(document.to_dict() == before and world.document.to_dict() == before, "关闭仍保留敌人位置组合与属性")
	var parsed := LevelDefinition.from_document(document, _content)
	_check(parsed.is_ok(), "禁用地图仍可建立正式试玩会话")
	var session := GameSession.create(parsed.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	session.source = "main() {}"
	_check(session.run().is_ok() and session.state == GameSession.State.RUNNING, "关闭敌人无终点不会在启动时自动获胜")
	_check(session.total_enemy_count() == 0 and session.remaining_enemy_count() == 0, "关闭敌人不虚报存活或待生敌人")
	session.step()
	_check(session.state == GameSession.State.RUNNING, "零敌人不会触发清场通关")
	session.stop()
	document = _document(["movement"])
	parsed = LevelDefinition.from_document(document, _content)
	session = GameSession.create(parsed.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	session.source = "main() {}"
	_check(session.run().is_ok(), "启用敌人正常启动")
	session.step()
	var location := session.world.get_machine("custom_enemy").position
	session.pause()
	for index in 20:
		session.step()
	_check(session.world.tick_index == 1 and session.world.get_machine("custom_enemy").position == location, "会话暂停冻结追击与世界 tick")
	session.resume()
	session.step()
	_check(session.world.get_machine("custom_enemy").position != location, "恢复后继续追击")
	session.world.get_machine("custom_enemy").modules[0].apply_damage(1)
	session.stop()
	session.run()
	_check(session.world.tick_index == 0 and session.world.get_machine("custom_enemy").position == Vector2(12.5, 6.5) and session.world.get_machine("custom_enemy").modules[0].health == 2.8, "重试恢复位置耐久与控制器")
	session.world.get_machine("custom_enemy").modules[0].apply_damage(100)
	session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "启用后实际清除全部敌人照常通关")


## 关闭敌人也不生成待生波次，既有安全门只免除敌人条件，仍要拆除警报器并抵达出口。
func _test_disabled_legacy_maps() -> void:
	var loaded := MapCodec.load_file("res://data/levels/level_012.json", _content, true)
	if not _check(loaded.is_ok(), "加载真实分波地图"):
		return
	var document: MapDocument = loaded.value
	document.properties.level.enemies_enabled = false
	var count := document.enemies.size()
	var world := _world(document)
	for index in 30:
		world.step()
	_check(world.machines.size() == 1 and world.get_enemy_wave_status().is_empty() and world.document.enemies.size() == count, "关闭保留全部波次但不构造波次控制器或延迟生成敌人")
	loaded = MapCodec.load_file("res://data/levels/level_005.json", _content, true)
	if not _check(loaded.is_ok(), "加载真实越狱地图"):
		return
	document = loaded.value
	document.properties.level.enemies_enabled = false
	world = _world(document)
	_check(not world.get_object("exit_gate_1").unlocked, "关闭敌人不能绕过未拆除的警报器条件")
	world.request_attack("player", 0, "right")
	world.step()
	_check(world.get_object("alarm").health == 0 and world.get_object("exit_gate_1").unlocked and world.failure_reason.is_empty(), "真实拆除警报后门忽略未生成守卫并正常解锁")
	var parsed := LevelDefinition.from_document(document, _content)
	if not _check(parsed.is_ok(), "关闭守卫的越狱关卡仍可建立会话"):
		return
	var session := GameSession.create(parsed.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	session.assembly.add_module("melee", Vector2(0.5, 0), "blade")
	session.source = "main() {\n blade.attack(0)\n drive.move(90, 5)\n}"
	var started := session.run()
	if not _check(started.is_ok(), "真实装配与程序可启动禁敌越狱地图 " + str(started.errors)):
		return
	for index in 60:
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.world.player.position.y <= 1.75, "关闭敌人后仍按拆除机关和实际到达出口通关，不被缺失守卫卡住")


## 汇总每项断言并输出可定位的失败，脚本退出码供测试入口使用。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
