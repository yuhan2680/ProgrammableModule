extends SceneTree
## 玩家雷达查询回归：真实来源、敌方筛选、最近目标、独立快照与无副作用边界。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()


## 延后到资源初始化后运行；所有夹具只存在于独立的内存世界中。
func _initialize() -> void:
	_run.call_deferred()


## 分别覆盖来源约束、几何、遮挡、稳定选择、阵营和只读性。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "玩家雷达加载正式内容"):
		quit(1)
		return
	_add_tile("scan_screen", false, true)
	_add_tile("scan_clear_wall", true, false)
	_test_sources()
	_test_geometry()
	_test_obstruction()
	_test_target_selection()
	_test_factions_and_liveness()
	_test_snapshot_and_read_only()
	print("玩家雷达底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 无名称时仅接受唯一存活雷达，名称必须实际存在且具备雷达能力。
func _test_sources() -> void:
	var world := _world()
	var radar := world.player.get_module("sensor")
	_check(world.validate_radar_source("player").value == radar, "裸 scan 选择唯一真实雷达实例")
	_check(world.validate_radar_source("player", "sensor").value == radar, "命名 scan 选择指定实例")
	for pair in [["missing", ""], ["player", "missing"], ["player", "drive"]]:
		_check(not world.validate_radar_source(pair[0], pair[1]).is_ok(), "拒绝不存在或不具备雷达能力的来源：" + str(pair))
		_check(not world.query_scan(pair[0], pair[1]).is_ok(), "scan 不绕过来源校验：" + str(pair))
	_expect_no_target(world, "无敌人是成功的空目标，不伪造自身为目标")
	radar.available = false
	_check(not world.query_scan("player").is_ok() and not world.query_scan("player", "sensor").is_ok(), "停用雷达立即失去扫描能力")
	radar.available = true
	radar.apply_damage(1.0)
	_check(not world.query_scan("player").is_ok(), "雷达毁坏后不能沿用旧能力")
	var document := _document()
	document.player_spawn.modules.append(_module("second", "radar", Vector2(-0.5, 0.0)))
	world = _world(document)
	_add_enemy(world, "target", Vector2(20.5, 14.5))
	_check(not world.query_scan("player").is_ok(), "多个可用雷达不能任意选择或合并来源")
	_expect_scan(world, "target", Vector2(20.5, 14.5), 0.0, 8.0, "第一雷达使用自己的中心", "sensor")
	_expect_scan(world, "target", Vector2(20.5, 14.5), 0.0, 8.5, "第二雷达使用独立偏移中心", "second")
	world.player.get_module("second").available = false
	_expect_scan(world, "target", Vector2(20.5, 14.5), 0.0, 8.0, "失效雷达不造成裸调用歧义")
	world.player.position = Vector2(NAN, 14.5)
	_check(not world.query_scan("player").is_ok(), "非有限来源坐标返回错误而不产生非法扫描快照")


## 位置是敌机参考点，距离从实际雷达中心计算，角度保持与动作指令一致。
func _test_geometry() -> void:
	var document := _document()
	document.player_spawn.modules[0].offset = {"x": 0.5, "y": 0.0}
	var world := _world(document)
	var enemy := _add_enemy(world, "target", Vector2(19.0, 14.5), Vector2(0.5, 0.0))
	_expect_scan(world, "target", Vector2(19.0, 14.5), 0.0, 6.0, "使用雷达实际中心到敌方参考点，而非任一部件表面")
	var origin := world.player.position + world.player.get_module("sensor").local_position
	var directions := [Vector2.RIGHT, Vector2.UP, Vector2.LEFT, Vector2.DOWN]
	for index in directions.size():
		enemy.position = origin + directions[index] * 6.0
		_expect_scan(world, "target", enemy.position, float(index * 90), 6.0, "四个正方向角度：%s" % index)
	for pair in [[Vector2(3.0, -4.0), 53.1301023542], [Vector2(-3.0, 4.0), 233.1301023542]]:
		enemy.position = origin + pair[0]
		_expect_scan(world, "target", enemy.position, pair[1], 5.0, "斜向角度以真实矢量计算并归一化")
	enemy.position = origin + Vector2(32.0, 0.0)
	_expect_scan(world, "target", enemy.position, 0.0, 32.0, "雷达半径端点包含")
	enemy.position = origin + Vector2(32.01, 0.0)
	_expect_no_target(world, "参考点超出半径时，部件边缘接近不能扩大扫描范围")
	enemy.position = origin + Vector2(23.0, 23.0)
	_expect_no_target(world, "范围是圆而非包围方形")
	enemy.position = origin
	_expect_scan(world, "target", origin, 0.0, 0.0, "目标重合时返回有限零距离与零角度")
	enemy.position = Vector2(INF, 14.5)
	_expect_no_target(world, "非法目标坐标不会产生非有限扫描结果")


## 屏障只采用 radar_block，普通碰撞墙、身后地块和射线外地块不会误挡。
func _test_obstruction() -> void:
	var world := _world()
	var enemy := _add_enemy(world, "target", Vector2(20.5, 14.5))
	world.document.set_tile(Vector2i(16, 14), "scan_screen")
	_expect_no_target(world, "不碰撞的雷达屏障仍能遮挡目标")
	world.document.set_tile(Vector2i(16, 14), "scan_clear_wall")
	_expect_scan(world, "target", enemy.position, 0.0, 8.0, "普通碰撞地块不冒充 radar_block")
	world.document.set_tile(Vector2i(16, 14), "")
	_expect_scan(world, "target", enemy.position, 0.0, 8.0, "void 的移动不可通行属性不额外改变雷达规则")
	world.document.set_tile(Vector2i(16, 14), "floor")
	for cell in [Vector2i(16, 15), Vector2i(11, 14), Vector2i(21, 14)]:
		world.document.set_tile(cell, "scan_screen")
		_expect_scan(world, "target", enemy.position, 0.0, 8.0, "射线外或端点外屏障不遮挡：" + str(cell))
		world.document.set_tile(cell, "floor")
	enemy.position = Vector2(18.5, 8.5)
	world.document.set_tile(Vector2i(15, 11), "scan_screen")
	_expect_no_target(world, "斜线触及雷达屏障同样阻止扫描")
	world.document.set_tile(Vector2i(15, 11), "floor")
	_check(world.query_scan("player").value is Dictionary, "移除屏障后下一次查询立即恢复")


## 最近目标按当前距离选择，遮挡后换选可见目标，同距离时以稳定 ID 排序。
func _test_target_selection() -> void:
	var world := _world()
	var zeta := _add_enemy(world, "zeta", Vector2(17.5, 14.5))
	var alpha := _add_enemy(world, "alpha", Vector2(7.5, 14.5))
	_expect_scan(world, "alpha", alpha.position, 180.0, 5.0, "同距离选择字典序更早的 ID")
	world.machines.reverse()
	_expect_scan(world, "alpha", alpha.position, 180.0, 5.0, "机器数组顺序不会改变同距离选择")
	zeta.position.x -= 0.125
	_expect_scan(world, "zeta", zeta.position, 0.0, 4.875, "更近目标优先于 ID 顺序")
	world.document.set_tile(Vector2i(15, 14), "scan_screen")
	_expect_scan(world, "alpha", alpha.position, 180.0, 5.0, "最近目标被遮挡后选择下一可见目标")
	world.document.set_tile(Vector2i(15, 14), "floor")
	zeta.get_module("body").available = false
	_expect_scan(world, "alpha", alpha.position, 180.0, 5.0, "已毁最近机器不阻止检测存活敌人")
	alpha.get_module("body").available = false
	_expect_no_target(world, "全部敌机已失效时返回 null")


## 当前玩家与敌人两阵营保持隔离；机器有存活部件才是可扫描目标。
func _test_factions_and_liveness() -> void:
	var world := _world()
	var enemy := _add_enemy(world, "scout", Vector2(20.5, 14.5), Vector2.ZERO, "radar")
	_add_enemy(world, "ally", Vector2(21.5, 14.5))
	var result := world.query_scan("scout", "body")
	_check(result.is_ok() and result.value is Dictionary and result.value.enemy_id == "player", "敌方雷达仅扫描玩家，不把近处同阵营机器当作目标")
	_check(world.radar_detects_player("scout", "body"), "共用可见性帮助函数保留既有敌方锁定")
	world.player.get_module("drive").available = false
	result = world.query_scan("scout", "body")
	_check(result.is_ok() and result.value is Dictionary and result.value.enemy_id == "player", "玩家部分部件失效后仍是有效目标")
	world.player.get_module("sensor").available = false
	result = world.query_scan("scout", "body")
	_check(result.is_ok() and result.value == null and not world.radar_detects_player("scout", "body"), "玩家全部部件失效后双方扫描语义一致")
	world.player.get_module("sensor").available = true
	enemy.get_module("body").available = false
	_check(not world.query_scan("scout", "body").is_ok(), "敌方扫描也不能使用已失效雷达")
	world._crushed["ally"] = true
	_expect_no_target(world, "被碾压机器不作为存活目标，即使旧部件快照尚在")


## 返回值不能反写世界，重复成功和错误查询不消费冷却、命令、时钟或任何信号。
func _test_snapshot_and_read_only() -> void:
	var document := _document()
	var world := _world(document)
	var enemy := _add_enemy(world, "target", Vector2(20.5, 14.5))
	var result := world.query_scan("player")
	if _check(result.is_ok() and result.value is Dictionary, "只读测试取得扫描快照"):
		_check(result.value.size() == 4 and result.value.enemy_id is String and result.value.position is Vector2 and result.value.angle is float and result.value.distance is float, "扫描快照仅公开四项稳定值，没有可修改的实例引用")
		result.value.enemy_id = "changed"
		result.value.position = Vector2.ZERO
		result.value.angle = 99.0
		result.value.distance = -1.0
		_expect_scan(world, "target", enemy.position, 0.0, 8.0, "修改扫描字典不改变真实机器或后续快照")
	var events: Array[String] = []
	world.tick_completed.connect(func(_tick: int): events.append("tick"))
	world.command_finished.connect(func(_command: MovementCommand): events.append("move"))
	world.attack_finished.connect(func(_command: AttackCommand): events.append("attack"))
	world.shot_finished.connect(func(_command: ShootCommand): events.append("shoot"))
	var command: MovementCommand = world.request_move("player", 0, 0.1).value
	var radar := world.player.get_module("sensor")
	radar.next_attack_tick = 42
	radar.next_shoot_tick = 84
	var before := var_to_str([document.to_dict(), world.document.to_dict(), world.player.position, enemy.position, radar.health, radar.available])
	for unused in 50:
		world.query_scan("player")
		world.validate_radar_source("player", "sensor")
		world.query_scan("missing")
		world.query_scan("player", "drive")
	_check(before == var_to_str([document.to_dict(), world.document.to_dict(), world.player.position, enemy.position, radar.health, radar.available]), "扫描不修改源地图、世界快照、机器位置、耐久或状态")
	_check(world.tick_index == 0 and events.is_empty(), "扫描不会推进 tick 或发出模拟信号")
	_check(command.state == SimulationCommand.State.QUEUED and radar.next_attack_tick == 42 and radar.next_shoot_tick == 84, "扫描不执行现有动作或预占攻击及射击冷却")
	_check(world.failure_reason.is_empty() and world.attack_traces.is_empty() and world.projectiles.is_empty(), "扫描不引入伤害、失败或表现事件")
	world.step()
	_check(command.state == SimulationCommand.State.COMPLETED and events == ["move", "tick"], "扫描后原本已排队的移动仍正常完成且只通知一次")
	_expect_scan(world, "target", enemy.position, 0.0, 7.9, "移动后扫描使用更新的实际位置")


## 开放场地中的玩家具有雷达和移动模块，后续目标通过正式工厂加入。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "player_radar_fixture"
	document.display_name = "玩家雷达夹具"
	document.width = 64
	document.height = 48
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 12.5, "y": 14.5}, "modules": [
		_module("sensor", "radar", Vector2.ZERO), _module("drive", "movement", Vector2(0.0, 0.5)),
	]}
	return document


## 使用地图副本和真实世界构造入口，避免测试绕过出生或能力校验。
func _world(document: MapDocument = null) -> SimulationWorld:
	var result := SimulationWorld.create(_document() if document == null else document, _content)
	_check(result.is_ok(), "玩家雷达夹具可运行：" + str(result.errors))
	return result.value as SimulationWorld


## 简单敌机没有自动动作，以便隔离查询与敌人状态机的职责。
func _add_enemy(world: SimulationWorld, id: String, position: Vector2, offset: Vector2 = Vector2.ZERO, kind: String = "movement") -> MachineInstance:
	var result := MachineFactory.create_machine(id, {"position": {"x": position.x, "y": position.y}, "modules": [_module("body", kind, offset)]}, world.document, _content, ModuleBehaviorRegistry.create_default())
	if not _check(result.is_ok(), "敌方实例构造成功：" + str(result.errors)):
		return null
	_check(world.add_machine(result.value).is_ok(), "真实敌机加入独立世界：" + id)
	return result.value as MachineInstance


## 生成与当前地图格式一致的命名模块条目。
func _module(id: String, kind: String, offset: Vector2) -> Dictionary:
	return {"id": id, "module_id": kind, "offset": {"x": offset.x, "y": offset.y}}


## 测试地块只注入本次内存内容，明确区分碰撞属性与雷达遮挡属性。
func _add_tile(id: String, collision: bool, radar_block: bool) -> void:
	var tile := TileDefinition.new()
	tile.id = id
	tile.collision = collision
	tile.radar_block = radar_block
	_content.tiles[id] = tile


## 同时检查目标、坐标、有限数值和角度约定，避免只验证是否非空。
func _expect_scan(world: SimulationWorld, id: String, position: Vector2, angle: float, distance: float, message: String, module_id: String = "") -> void:
	var result := world.query_scan("player", module_id)
	var valid := result.is_ok() and result.value is Dictionary
	if valid:
		var target: Dictionary = result.value
		valid = target.enemy_id == id and target.position == position and is_finite(target.angle) and is_finite(target.distance) and absf(target.angle - angle) < 0.0001 and absf(target.distance - distance) < 0.0001
	_check(valid, "%s；返回 %s；错误 %s" % [message, result.value, result.errors])


## 未发现目标和能力错误不同，空结果必须是成功的 null。
func _expect_no_target(world: SimulationWorld, message: String) -> void:
	var result := world.query_scan("player")
	_check(result.is_ok() and result.value == null, "%s；返回 %s；错误 %s" % [message, result.value, result.errors])


## 汇总独立断言；引擎解析或脚本错误仍由外部测试驱动拒绝。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
