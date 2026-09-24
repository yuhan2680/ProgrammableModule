extends SceneTree
## 第九关测距底层回归：实际中心、精确表面、动态阻挡与无副作用查询。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()


## 延后运行以等待资源初始化；所有地图和机器只存在于内存中。
func _initialize() -> void:
	_run.call_deferred()


## 分别覆盖输入边界、几何精度、动态状态与查询期间的动作保留。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "内容加载成功"):
		quit(1)
		return
	_test_capability()
	_test_center_and_terrain()
	_test_arbitrary_angles()
	_test_objects_and_machines()
	_test_read_only()
	_test_large_map()
	print("测距底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 裸调用只有唯一来源时有效；命名、已损坏及非法参数不能被静默转换。
func _test_capability() -> void:
	var world := _world(_document())
	if world == null:
		return
	_check(world.validate_distance_source("player").value == world.player.get_module("sensor"), "裸调用选择唯一测距实例")
	_check(world.validate_distance_source("player", "sensor").is_ok(), "命名来源可以明确选择测距部件")
	for invalid: Variant in [null, true, false, "0", Vector2.ZERO, [], {}, NAN, INF, -INF]:
		_check(not world.query_distance("player", invalid).is_ok(), "拒绝非有限数字及隐式类型转换")
	_check(not world.query_distance("missing", 0).is_ok(), "不存在的机器返回可显示错误")
	_check(not world.query_distance("player", 0, "missing").is_ok(), "不存在的命名实例返回错误")
	_check(not world.query_distance("player", 0, "drive").is_ok(), "移动部件不能冒充测距能力")
	world.player.get_module("sensor").apply_damage(1.0)
	_check(not world.query_distance("player", 0).is_ok() and not world.query_distance("player", 0, "sensor").is_ok(), "已损坏的唯一部件不能继续测距")
	var document := _document()
	document.player_spawn.modules.append(_module("other_sensor", "rangefinder", Vector2(-0.5, 0)))
	world = _world(document)
	_check(not world.query_distance("player", 0).is_ok(), "多个可用来源必须命名，不能任意挑选或合并距离")
	_expect_distance(world, 0, 8.5, "命名调用只使用指定的实际中心", "sensor")
	_expect_distance(world, 0, 9.0, "另一测距部件的偏移独立影响距离", "other_sensor")
	world.player.get_module("other_sensor").apply_damage(1.0)
	_expect_distance(world, 0, 8.5, "失效部件不造成裸调用歧义")
	var altered := _document()
	altered.player_spawn.modules[0].module_id = "melee"
	world = _world(altered)
	_check(not world.query_distance("player", 0).is_ok(), "没有测距模块的旧装配保持能力限制")


## 检测距离取传感器中心而非机器中心或边缘，void、未知地块与 collision 都属于墙。
func _test_center_and_terrain() -> void:
	var document := _document()
	document.player_spawn.modules[0].offset = {"x": 0.5, "y": 0.0}
	var world := _world(document)
	if world == null:
		return
	_expect_distance(world, 0, 8.0, "偏移后的测距中心到右地图边界")
	_expect_distance(world, 90, 3.5, "90 度向上")
	_expect_distance(world, 180, 4.0, "180 度向左")
	_expect_distance(world, 270, 6.5, "270 度向下")
	_expect_distance(world, -90, 6.5, "负角度与标准方向一致")
	_expect_distance(world, 720, 8.0, "多圈角度归一化后得到相同读数")
	world.document.set_tile(Vector2i(7, 3), "")
	_expect_distance(world, 0, 3.0, "空地块的近表面阻挡测距")
	world.document.set_tile(Vector2i(6, 3), "unknown_extension")
	_expect_distance(world, 0, 2.0, "未知地块按不可通行处理")
	var wall := TileDefinition.new()
	wall.id = "range_test_wall"
	wall.collision = true
	wall.radar_block = false
	_content.tiles[wall.id] = wall
	world.document.set_tile(Vector2i(5, 3), wall.id)
	_expect_distance(world, 0, 1.0, "collision 属性决定测距遮挡，不使用 radar_block")
	world.document.set_tile(Vector2i(5, 3), "floor")
	world.document.set_tile(Vector2i(6, 3), "floor")
	world.document.set_tile(Vector2i(7, 3), "floor")
	_content.tiles.erase(wall.id)
	world.request_move("player", 0, 0.5)
	for unused in 5:
		world.step()
	_expect_distance(world, 0, 7.5, "动作完成后读数跟随实际当前位置")
	_check(document.get_tile_id(Vector2i(7, 3)) == "floor", "测距夹具与运行地图仍为独立快照")


## 用独立矩形遍历作为小地图基准，覆盖斜线、拐角和沿网格边缘的接触。
func _test_arbitrary_angles() -> void:
	var world := _world(_document())
	if world == null:
		return
	for cell in [Vector2i(5, 3), Vector2i(4, 2), Vector2i(2, 6), Vector2i(5, 5), Vector2i(1, 1), Vector2i(7, 7)]:
		world.document.set_tile(cell, "")
	for angle in range(-360, 721, 7):
		var expected := _brute_terrain_distance(world, float(angle))
		_expect_distance(world, angle, expected, "任意角度 DDA 与独立表面交点一致：%s" % angle)
	_expect_distance(world, 45, sqrt(0.5), "对角线先接触侧面墙的角点，不穿过墙角")
	world = _world(_document())
	world.player.position.x = 4.0
	world.document.set_tile(Vector2i(3, 1), "")
	_expect_distance(world, 90, 1.5, "沿整数 X 竖直射线会检测左侧相邻墙面")
	world = _world(_document())
	world.player.position.y = 4.0
	world.document.set_tile(Vector2i(7, 3), "")
	_expect_distance(world, 0, 3.5, "沿整数 Y 水平射线会检测上侧相邻墙面")


## 已关闭的门、未毁障碍和他机可用部件阻挡；自身机身、已打开或已损坏部分忽略。
func _test_objects_and_machines() -> void:
	var document := _document()
	document.objects = [
		{"id": "crate", "type": "destructible", "position": {"x": 8.0, "y": 3.5}, "size": 1.0, "properties": {"max_health": 1}},
		{"id": "gate", "type": "timed_gate", "position": {"x": 6.0, "y": 3.5}, "size": 1.0, "properties": {"close_after_ticks": 2}},
		{"id": "security", "type": "security_gate", "position": {"x": 10.0, "y": 3.5}, "size": 1.0, "properties": {"required_object_ids": ["crate"]}},
	]
	var world := _world(document)
	if world == null:
		return
	_expect_distance(world, 0, 4.0, "打开的限时门不遮挡，测到其后箱子表面")
	world.step()
	_expect_distance(world, 0, 4.0, "查询不预测下一 tick 的门状态")
	world.step()
	_expect_distance(world, 0, 2.0, "限时门实际落下后立即成为第一表面")
	world.get_object("gate").definition.close_after_ticks = 100
	world.get_object("crate").health = 0.0
	_expect_distance(world, 0, 6.0, "已毁物体不遮挡，尚未解锁的安全门仍遮挡")
	world.step()
	_expect_distance(world, 0, 8.5, "安全门解锁后读到地图边界")
	var enemy_result := MachineFactory.create_machine("other", {"position": {"x": 7.0, "y": 3.5}, "modules": [_module("body", "movement", Vector2(0.5, 0))]}, world.document, _content, ModuleBehaviorRegistry.create_default())
	if not _check(enemy_result.is_ok() and world.add_machine(enemy_result.value).is_ok(), "增加具有实际局部偏移的其他机器"):
		return
	_expect_distance(world, 0, 3.75, "测到其他机器部件的近边缘而非机器参考点")
	world.get_machine("other").position.x = 6.0
	_expect_distance(world, 0, 2.75, "测距使用其他机器当前的位置")
	world.get_machine("other").get_module("body").apply_damage(1.0)
	_expect_distance(world, 0, 8.5, "其他机器已损坏部件不再阻挡")
	_expect_distance(world, 270, 6.5, "自身下面的移动模块不遮挡自己的传感器")
	var definition := MapObjectDefinition.new()
	definition.id = "touching"
	definition.kind = "destructible"
	definition.max_health = 1.0
	definition.rect = Rect2(Vector2(3.5, 3.0), Vector2.ONE)
	world.objects.append(WorldObject.create(definition))
	_expect_distance(world, 0, 0.0, "表面恰好接触传感器中心时返回零而非负数或无穷")


## 重复查询及错误查询不得改动世界、冷却、动作队列、源文档或发出模拟信号。
func _test_read_only() -> void:
	var document := _document()
	var world := _world(document)
	if world == null:
		return
	var events: Array[String] = []
	world.tick_completed.connect(func(_tick: int): events.append("tick"))
	world.command_finished.connect(func(_command: MovementCommand): events.append("move"))
	world.attack_finished.connect(func(_command: AttackCommand): events.append("attack"))
	world.shot_finished.connect(func(_command: ShootCommand): events.append("shoot"))
	var command: MovementCommand = world.request_move("player", 0, 0.1).value
	var source_before := JSON.stringify(document.to_dict())
	var world_before := JSON.stringify(world.document.to_dict())
	world.player.get_module("sensor").next_attack_tick = 42
	world.player.get_module("sensor").next_shoot_tick = 84
	for unused in 100:
		world.query_distance("player", 0)
		world.validate_distance_source("player", "sensor")
		world.query_distance("player", false)
	_check(world.tick_index == 0 and events.is_empty(), "重复查询不推进时钟、不发送任意模拟信号")
	_check(world.player.position == Vector2(3.5, 3.5) and command.state == SimulationCommand.State.QUEUED, "已排队动作在查询期间保持未执行")
	_check(world.player.get_module("sensor").next_attack_tick == 42 and world.player.get_module("sensor").next_shoot_tick == 84, "查询不预留或消耗冷却")
	_check(world.player.get_module("sensor").health == 1.0 and world.failure_reason.is_empty() and world.attack_traces.is_empty() and world.projectiles.is_empty(), "查询不改变耐久、结果或视觉事件")
	_check(JSON.stringify(document.to_dict()) == source_before and JSON.stringify(world.document.to_dict()) == world_before, "查询不修改源文档或世界静态快照")
	world.step()
	_check(command.state == SimulationCommand.State.COMPLETED and events == ["move", "tick"], "查询后原命令正常完成且只发出一次原有通知")
	_expect_distance(world, 0, 8.4, "读到查询后正常移动的结果")


## 长射线仅跨越线上的格子；整个地图没有命中对象时仍稳定返回有限边界距离。
func _test_large_map() -> void:
	var document := _document()
	document.width = 256
	document.height = 256
	for x in 256:
		document.set_tile(Vector2i(x, 3), "floor")
	var world := _world(document)
	if world == null:
		return
	_expect_distance(world, 0, 252.5, "长直线读到有限地图边界，不在任意固定量程被截断")
	world.document.set_tile(Vector2i(255, 3), "")
	_expect_distance(world, 0, 251.5, "最远一格的空洞仍可精确检测")
	world.document.cells.clear()
	for cell_index in 256:
		world.document.set_tile(Vector2i(cell_index, cell_index), "floor")
		if cell_index > 0:
			world.document.set_tile(Vector2i(cell_index - 1, cell_index), "floor")
			world.document.set_tile(Vector2i(cell_index, cell_index - 1), "floor")
	_expect_distance(world, 315, 252.5 * sqrt(2.0), "长对角线累计精度保持到远端地图边界")


## 独立小地图几何基准，不调用被测 DDA 或改变世界状态。
func _brute_terrain_distance(world: SimulationWorld, angle: float) -> float:
	var origin := world.player.position + world.player.get_module("sensor").local_position
	var radians := deg_to_rad(fposmod(angle, 360.0))
	var direction := Vector2(cos(radians), -sin(radians))
	var result := Vector2(world.document.width, world.document.height).length() + 1.0
	for y in range(-1, world.document.height + 1):
		for x in range(-1, world.document.width + 1):
			if not TerrainCollision.is_cell_passable(Vector2i(x, y), world.document, _content):
				result = minf(result, WorldObject.ray_distance(origin, direction, Rect2(Vector2(x, y), Vector2.ONE), result))
	return result


## 开放地图使用一个中心测距模块及下方移动模块，便于区分自身忽略与实际模块偏移。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "rangefinder_fixture"
	document.display_name = "测距夹具"
	document.width = 12
	document.height = 10
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 3.5, "y": 3.5}, "modules": [_module("sensor", "rangefinder", Vector2.ZERO), _module("drive", "movement", Vector2(0, 0.5))]}
	return document


## 创建具有独立实例名称与世界尺寸无关局部偏移的模块输入。
func _module(id: String, kind: String, offset: Vector2) -> Dictionary:
	return {"id": id, "module_id": kind, "offset": {"x": offset.x, "y": offset.y}}


## 生产工厂负责运行前校验，不绕过正式装配与地图格式。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	if not _check(result.is_ok(), "测距夹具可运行：%s" % result.errors):
		return null
	return result.value


## 同时断言成功、有限非负以及与物理表面距离一致，错误也包含具体读数。
func _expect_distance(world: SimulationWorld, angle: float, expected: float, label: String, module_id: String = "") -> void:
	var result := world.query_distance("player", angle, module_id)
	_check(result.is_ok() and result.value is float and is_finite(result.value) and result.value >= 0.0 and absf(result.value - expected) < 0.0001, "%s；实际 %s，预期 %.8f，错误 %s" % [label, result.value, expected, result.errors])


## 收集明确断言；引擎脚本异常另由测试驱动视为失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
