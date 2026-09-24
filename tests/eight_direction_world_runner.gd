extends SceneTree
## 分波验证使用真实内存世界；未出场敌人不进入查询、绘制或弹丸命中集合。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()


## 延后运行，等待项目全局脚本类型就绪。
func _initialize() -> void:
	_run.call_deferred()


## 先验证数据边界，再覆盖延迟、真实战斗和完整出生占地。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "加载正式模块和地块"):
		_finish()
		return
	_test_validation()
	_test_pending()
	_test_sequence()
	_test_geometry_and_combat()
	_test_failure_and_placement()
	_finish()


## 构造开放场地和八个真实双模块敌人；射线中线位于玩家测距与枪口的中点。
func _data(first_delay: int = 0) -> Dictionary:
	var tiles: Array = []
	for y in range(1, 24):
		for x in range(1, 24):
			tiles.append({"x": x, "y": y, "tile_id": "floor"})
	var enemies: Array = []
	for index in 8:
		var angle := float(index * 45)
		var direction := SimulationWorld._angle_direction(angle)
		var lead := Vector2(12.75, 12.5) + direction * 7.0
		var rear := Vector2(signf(direction.x) * 0.5, signf(direction.y) * 0.5)
		enemies.append({
			"id": "wave_%d" % (index + 1), "behavior": EnemyDefinition.WAVE_APPROACH_ATTACK,
			"position": {"x": lead.x, "y": lead.y},
			"modules": [
				{"id": "blade", "module_id": "melee", "offset": {"x": 0, "y": 0}},
				{"id": "drive", "module_id": "movement", "offset": {"x": rear.x, "y": rear.y}},
			],
			"properties": {"wave_order": index + 1, "spawn_delay_ticks": first_delay if index == 0 else 5,
				"move_angle": angle + 180, "move_distance": 5.6, "attack_angle": angle + 180,
				"module_health": {"blade": 1.0, "drive": 1.0}},
		})
	return {"format_version": 1, "id": "wave_test", "name": "分波测试", "width": 25, "height": 25,
		"tiles": tiles, "player_spawn": {"position": {"x": 12.5, "y": 12.5}, "modules": [
			{"id": "sensor", "module_id": "rangefinder", "offset": {"x": 0, "y": 0}},
			{"id": "gun", "module_id": "shooting", "offset": {"x": 0.5, "y": 0}},
		]}, "enemies": enemies, "objects": [], "dialogue": [], "properties": {}}


## 所有波的参数在载入时校验，坏序号和未注册行为不会被混淆。
func _test_validation() -> void:
	var data := _data()
	_check(MapCodec.from_dict(data, _content, true).is_ok(), "八波合法配置可载入")
	for pair: Array in [["wave_order", 0], ["wave_order", 65], ["wave_order", 1.5], ["wave_order", true], ["spawn_delay_ticks", -1], ["spawn_delay_ticks", 601], ["spawn_delay_ticks", true], ["move_distance", -1], ["move_distance", INF], ["move_angle", false], ["attack_angle", NAN], ["module_health", {"missing": 1}]]:
		var entry: Dictionary = data.enemies[0].duplicate(true)
		entry.properties[pair[0]] = pair[1]
		_check(not EnemyDefinition.validate(entry, _content).is_ok(), "拒绝非法分波参数：" + str(pair))
	for order in [1, 10]:
		var changed := data.duplicate(true)
		changed.enemies[1].properties.wave_order = order
		_check(not MapCodec.from_dict(changed, _content, true).is_ok(), "全图拒绝重复或不连续波次")
	var no_drive := data.duplicate(true)
	no_drive.enemies[0].modules.remove_at(1)
	no_drive.enemies[0].properties.module_health = {}
	_check(not MapCodec.from_dict(no_drive, _content, true).is_ok(), "分波必须有真实移动能力")
	var no_blade := data.duplicate(true)
	no_blade.enemies[0].modules.remove_at(0)
	no_blade.enemies[0].properties.module_health = {}
	_check(not MapCodec.from_dict(no_blade, _content, true).is_ok(), "分波必须有真实近战能力")
	var unknown := data.duplicate(true)
	unknown.enemies[0].behavior = "unregistered_future_behavior"
	unknown.enemies = [unknown.enemies[0]]
	_check(MapCodec.from_dict(unknown, _content, true).is_ok(), "未知行为仍保留元数据语义")
	var shuffled := data.duplicate(true)
	shuffled.enemies.reverse()
	var world := _world(shuffled)
	if world != null:
		_check(world.get_enemy_wave_status().active_enemy_id == "wave_1", "出生顺序按 wave_order，不依赖 JSON 数组顺序")


## 等待出生时所有敌人都不可见；测距、雷达和弹丸都读取相同的世界机器集合。
func _test_pending() -> void:
	var data := _data(60)
	data.player_spawn.modules.append({"id": "radar", "module_id": "radar", "offset": {"x": -0.5, "y": 0}})
	var world := _world(data)
	if world == null:
		return
	var original := world.document.to_dict()
	var before := world.get_enemy_wave_status()
	_check(world.machines.size() == 1 and world.get_machine("wave_1") == null, "未出场敌人不进入绘制/机器查询列表")
	_check(before.total == 8 and before.pending == 8 and not before.all_cleared, "未来波次计入总目标，不能提前通关")
	_check(world.query_scan("player").value == null, "雷达不会扫描到未出场敌人")
	_check(float(world.query_distance("player", 0).value) > 10, "测距不会被未出场敌人挡住")
	for index in 40:
		world.request_tick_action("player", "shoot", 0, "gun")
		world.step()
	_check(world.machines.size() == 1 and world.query_scan("player").value == null, "弹丸飞行不会提前激活或碰撞待生敌人")
	var paused := world.get_enemy_wave_status()
	for unused in 30:
		world.get_enemy_wave_status()
		world.query_distance("player", 0)
		world.query_scan("player")
	_check(world.tick_index == 40 and world.get_enemy_wave_status() == paused, "不 step 即暂停，UI 和查询不能推进出生倒计时")
	before.total = 1
	_check(world.get_enemy_wave_status().total == 8, "只读快照不允许外部篡改真实波数")
	while world.tick_index < 60:
		world.step()
	var enemy := world.get_machine("wave_1")
	_check(enemy != null and enemy.get_module("blade").health == 1 and enemy.get_module("drive").health == 1, "按逻辑 tick 出生，提前经过的旧弹丸不造成虚假伤害")
	_check(world.document.to_dict() == original, "激活和计时不改写地图数据")
	var retry := _world(data)
	if retry != null:
		_check(retry.tick_index == 0 and retry.get_enemy_wave_status().pending == 8, "重建世界恢复全部待生波次和时间")


## 仅整个当前敌人被击毁才进入等待；残存部件不能冒充通关，最后一波才完成。
func _test_sequence() -> void:
	var world := _world(_data())
	if world == null:
		return
	for order in range(1, 9):
		var status := world.get_enemy_wave_status()
		var enemy := world.get_machine("wave_%d" % order)
		if not _check(enemy != null and status.current == order and status.active, "按次序仅激活当前波 %d" % order):
			return
		enemy.get_module("blade").apply_damage(10)
		world.step()
		_check(world.get_enemy_wave_status().completed == order - 1, "只击毁前方模块不计为整波完成")
		enemy.get_module("drive").apply_damage(10)
		world.step()
		status = world.get_enemy_wave_status()
		_check(status.completed == order and not status.active, "两模块确实被毁后统一清波")
		if order == 8:
			_check(status.all_cleared and status.pending == 0 and status.next_spawn_tick == -1, "最后一波完成后无额外敌人或计时")
			continue
		_check(not status.all_cleared and world.get_machine("wave_%d" % (order + 1)) == null, "过渡期仍包含未来目标且不可见")
		for unused in 4:
			world.step()
		_check(world.get_machine("wave_%d" % (order + 1)) == null, "等待时间未满时不会提前出生")
		world.step()
		_check(world.get_machine("wave_%d" % (order + 1)) != null, "等待满五 tick 后激活下一波")


## 八方向都用中心测距与偏置枪口实际发射；不扩大碰撞、不代扣血、不改变模块定义。
func _test_geometry_and_combat() -> void:
	var data := _data()
	var world := _world(data)
	if world == null:
		return
	var seen := {}
	var supported := true
	for unused in 1600:
		for angle in range(0, 360, 45):
			var measured := world.query_distance("player", angle)
			if measured.is_ok() and float(measured.value) < 9.0:
				seen[angle] = true
				if world.is_shoot_ready("player", "gun").value:
					world.request_tick_action("player", "shoot", angle, "gun")
					break
		world.step()
		for machine: MachineInstance in world.machines:
			if not machine.is_destroyed():
				supported = supported and MachineFactory.validate_placement(machine, world.document, _content).is_ok()
		if world.get_enemy_wave_status().all_cleared or world.player.is_destroyed():
			break
	_check(seen.size() == 8, "中心测距能够检测所有八个来敌方向")
	_check(world.get_enemy_wave_status().all_cleared and not world.player.is_destroyed(), "偏置枪口真实弹丸可依次击毁全部八波且玩家存活")
	_check(supported and world.player.position == Vector2(12.5, 12.5), "全程所有真实模块占地合法且玩家未被脚本移动")
	_check(_content.get_module("movement").size == Vector2(0.5, 0.5) and _content.get_module("melee").size == Vector2(0.5, 0.5), "没有扩大共享模块或伤害碰撞范围")


## 不作防御会遭遇真实攻击；未来出生点也必须通过完整地形/障碍检查。
func _test_failure_and_placement() -> void:
	var world := _world(_data())
	if world != null:
		var initial := world.get_machine("wave_1").position
		world.step()
		_check(is_equal_approx(initial.distance_to(world.get_machine("wave_1").position), 0.1), "分波推进仍遵守每 tick 真实移动速度")
		for unused in 100:
			world.step()
		_check(world.player.is_destroyed() and world.get_enemy_wave_status().completed == 0, "不防御时真实近战击毁玩家而非自动清波")
	var data := _data()
	var decoded := MapCodec.from_dict(data, _content, true)
	if decoded.is_ok():
		var doc: MapDocument = decoded.value
		var last: Dictionary = data.enemies[7].position
		doc.set_tile(Vector2i(floori(last.x), floori(last.y)), "")
		_check(not SimulationWorld.create(doc, _content).is_ok(), "未出场敌人的 void 出生点也在建世界时拒绝")
	var blocked := _data()
	blocked.objects.append({"id": "spawn_block", "type": "destructible", "position": blocked.enemies[7].position.duplicate(), "properties": {"max_health": 10}})
	var loaded := MapCodec.from_dict(blocked, _content, true)
	_check(loaded.is_ok() and not SimulationWorld.create(loaded.value, _content).is_ok(), "未来出生占地与实体障碍重叠不能绕过校验")


## 世界入口始终通过正式 JSON 校验与实例工厂，不写入玩家数据。
func _world(data: Dictionary) -> SimulationWorld:
	var decoded := MapCodec.from_dict(data, _content, true)
	if not _check(decoded.is_ok(), "测试地图通过正式格式校验：" + str(decoded.errors)):
		return null
	var built := SimulationWorld.create(decoded.value, _content)
	if not _check(built.is_ok(), "创建独立分波世界：" + str(built.errors)):
		return null
	return built.value


## 断言记录具体失败信息，并由统一日志检查捕获脚本错误。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 输出标准汇总并返回失败状态，便于完整测试入口聚合。
func _finish() -> void:
	print("八方向分波世界回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
