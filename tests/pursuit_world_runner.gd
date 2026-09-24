extends SceneTree
## 第七关底层回归：持续推进、同帧近战、实例耐久覆盖与具名射击就绪查询。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()


## 延后运行并使用纯数据夹具，不触碰玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 分别覆盖行为、地形、伤害、查询与配置边界。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "加载真实内容成功"):
		quit(1)
		return
	_test_advance_and_attack()
	_test_blocked_and_lost_modules()
	_test_atomic_damage()
	_test_attack_display_contact()
	_test_attack_display_static_endpoints()
	_test_player_defeat_attack_feedback()
	_test_player_defeat_attack_replacement()
	_test_ready_query()
	_test_overrides_and_validation()
	print("追击底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 固定方向推进与近战同 tick 发生；不会先走完有限路程才开始攻击。
func _test_advance_and_attack() -> void:
	var document := _document()
	var original := document.to_dict()
	var world := _world(document)
	var enemy := world.get_machine("pursuer")
	world.player.get_module("gun").health = 20.0
	var finished: Array[MovementCommand] = []
	world.command_finished.connect(func(command: MovementCommand) -> void: finished.append(command))
	for index in 5:
		world.step()
		_check(absf(enemy.position.x - (7.0 - 0.1 * (index + 1))) < 0.00001 and enemy.position.y == 4.5, "敌人每 tick 按真实速度持续左移")
		_check(world.player.get_module("gun").health == 19.0 - index, "移动同时朝固定左侧造成近战伤害")
		var trace := world.attack_traces[0]
		_check(trace.display_from.is_equal_approx(enemy.position + enemy.get_module("blade").local_position) and trace.display_to.is_equal_approx(Vector2(5.75, 4.5)), "移动发射端跟随模块，静止受击部位保持接触")
		_check(world.get_player_defeat_attack_traces().is_empty(), "普通伤害未摧毁玩家模块时不制造失败反馈")
		_check(finished.size() == index + 1 and finished[index].state == SimulationCommand.State.COMPLETED, "每 tick 完成一条短动作，不积压移动")
	_check(document.to_dict() == original and world.document.to_dict() == original, "运行不回写原地图或世界地图配置")
	var frozen_position := enemy.position
	var frozen_health := world.player.get_module("gun").health
	var frozen_cooldown := enemy.get_module("blade").next_attack_tick
	for unused in 20:
		world.is_shoot_ready("player", "gun")
	_check(world.tick_index == 5 and enemy.position == frozen_position and world.player.get_module("gun").health == frozen_health and enemy.get_module("blade").next_attack_tick == frozen_cooldown, "未推进世界时敌人、耐久和冷却均冻结，查询不能暗中驱动时间")
	document = _document()
	document.enemies[0].properties.move_angle = 90
	document.enemies[0].properties.attack_angle = 0
	world = _world(document)
	world.step()
	_check(world.get_machine("pursuer").position.is_equal_approx(Vector2(7, 4.4)), "移动角度独立遵循配置，90 度只向上")
	_check(not world.player.is_destroyed(), "攻击固定朝右，不自动瞄准左侧玩家")
	_check(world.attack_traces.size() == 1 and world.attack_traces[0].to.x > world.attack_traces[0].from.x, "近战方向与移动方向可独立配置")


## void 和阻挡对象使用原扫掠；移动失败不会堆积动作或禁掉幸存近战。
func _test_blocked_and_lost_modules() -> void:
	for use_object in [false, true]:
		var document := _document()
		document.player_spawn.position = {"x": 2.5, "y": 4.5}
		if use_object:
			document.objects = [{"id": "wall", "type": "destructible", "position": {"x": 4.5, "y": 4.5}, "properties": {"max_health": 1000}}]
		else:
			for y in document.height:
				document.set_tile(Vector2i(4, y), "")
		var world := _world(document)
		var enemy := world.get_machine("pursuer")
		var finished: Array[MovementCommand] = []
		var attacked: Array[AttackCommand] = []
		world.command_finished.connect(func(command: MovementCommand) -> void: finished.append(command))
		world.attack_finished.connect(func(command: AttackCommand) -> void: attacked.append(command))
		for unused in 100:
			world.step()
		_check(absf(enemy.position.x - 5.25) < 0.0001, "持续推进不能穿过 void 或实体障碍")
		_check(finished.size() == 100 and finished[-1].state == SimulationCommand.State.BLOCKED, "长时间顶墙仍逐 tick 释放短移动命令")
		_check(attacked.size() == 100 and attacked[-1].state == SimulationCommand.State.COMPLETED, "碰墙后近战通道仍持续工作")
		_check(not world.player.is_destroyed(), "阻挡物同时阻止隔墙近战命中玩家")
		_check(MachineFactory.validate_placement(enemy, world.document, _content).is_ok(), "停止位置完整占地仍由真实模块地形校验通过")
		if use_object:
			_check(world.get_object("wall").health < 1000, "幸存近战可持续攻击面前可破坏对象")
			world.get_object("wall").health = 0
			world.step()
			_check(enemy.position.x < 5.25 and finished[-1].state == SimulationCommand.State.COMPLETED, "障碍消失后下一 tick 可继续推进，不残留阻塞命令")
	var world := _world(_document())
	var enemy := world.get_machine("pursuer")
	var pending := world.request_move("pursuer", 180, 10)
	enemy.get_module("drive").apply_damage(1)
	world.step()
	_check(enemy.position == Vector2(7, 4.5) and world.player.is_destroyed(), "驱动先失效时位置不动，近战仍在同一 tick 出手")
	_check(pending.is_ok() and pending.value.state == SimulationCommand.State.CANCELLED, "驱动失效前排队的移动会取消，不阻塞近战或未来动作")
	world = _world(_document())
	enemy = world.get_machine("pursuer")
	enemy.get_module("blade").apply_damage(1)
	world.step()
	_check(absf(enemy.position.x - 6.9) < 0.00001 and not world.player.is_destroyed(), "近战失效不阻止剩余驱动继续推进")
	enemy.get_module("drive").apply_damage(1)
	var position := enemy.position
	world.step()
	_check(enemy.position == position and world.attack_traces.is_empty(), "全模块被毁后不再移动或攻击")


## 双方本 tick 的命中都先计算；一方先写入伤害不会撤回另一方攻击。
func _test_atomic_damage() -> void:
	var document := _document()
	document.player_spawn.modules = [_module("blade", "melee", 0)]
	document.enemies[0].modules = [_module("blade", "melee", 0)]
	var world := _world(document)
	world.request_attack("player", 0, "blade")
	world.step()
	_check(world.player.is_destroyed() and world.get_machine("pursuer").is_destroyed(), "玩家与持续攻击敌人可以同一 tick 互相摧毁")
	_check(world.attack_traces.size() == 2 and world.failure_reason.contains("全部模块"), "双方都生成真实攻击反馈，玩家死亡仍保留失败语义")
	var defeat_traces := world.get_player_defeat_attack_traces()
	_check(defeat_traces.size() == 1 and defeat_traces[0].source_machine_id == "pursuer", "同时互毁只保留击毁玩家模块的攻击，不混入玩家击毁敌人的轨迹")


## 同 tick 后退或侧移并遭致命攻击时，显示终点跟随原命中模块，原始射线和伤害仍取移动前状态。
func _test_attack_display_contact() -> void:
	for entry in [{"angle": 180, "position": Vector2(5.4, 4.5), "contact": Vector2(6.15, 4.5)}, {"angle": 90, "position": Vector2(5.5, 4.4), "contact": Vector2(6.25, 4.4)}]:
		var document := _document()
		# 通用世界允许偏移模块；用偏移的唯一驱动证明附着的是命中部位，而不是机器中心。
		document.player_spawn.modules = [_module("drive", "movement", 0.5)]
		var world := _world(document)
		if world == null:
			return
		_check(world.request_move("player", entry.angle, 0.1).is_ok(), "受击 tick 可以先提交后退或侧移动作")
		world.step()
		_check(world.player.is_destroyed() and world.player.get_module("drive").health == 0.0, "显示附着不能撤销移动前成立的致命命中")
		_check(world.player.position.is_equal_approx(entry.position), "致命伤害仍在真实移动提交之后生效")
		if not _check(world.attack_traces.size() == 1, "致命 tick 保留一条真实近战反馈"):
			continue
		var trace := world.attack_traces[0]
		_check(trace.from.is_equal_approx(Vector2(7.5, 4.5)) and trace.to.is_equal_approx(Vector2(6.25, 4.5)), "原始射线保留移动前发射点和实际碰撞交点")
		_check(trace.display_from.is_equal_approx(Vector2(7.4, 4.5)), "显示起点附着到同 tick 已移动的发射模块")
		_check(trace.display_to.is_equal_approx(entry.contact), "显示终点保持在已死亡且发生位移的原受击部位")
		_check(not trace.display_to.is_equal_approx(trace.to), "移动后的接触反馈不能复用旧位置造成可见空隙")


## 落空、地形及当 tick 被摧毁的静态对象保持原交点，不能因发射者移动而拉长射程或吸附附近机器。
func _test_attack_display_static_endpoints() -> void:
	for kind in ["miss", "object", "terrain"]:
		var document := _document()
		document.player_spawn.position.x = 2.5
		var endpoint := Vector2(5.5, 4.5)
		if kind == "object":
			document.objects = [{"id": "target", "type": "destructible", "position": {"x": 6.0, "y": 4.5}, "properties": {"max_health": 1}}]
			endpoint.x = 6.5
		elif kind == "terrain":
			document.set_tile(Vector2i(5, 4), "")
			endpoint.x = 6.0
		var world := _world(document)
		if world == null:
			return
		world.step()
		if not _check(world.attack_traces.size() == 1, "落空或静态阻挡均产生一条射线反馈"):
			continue
		var trace := world.attack_traces[0]
		_check(trace.from.is_equal_approx(Vector2(7.5, 4.5)) and trace.display_from.is_equal_approx(Vector2(7.4, 4.5)), "静态终点用例仍具有真实的发射端位移")
		_check(trace.to.is_equal_approx(endpoint) and trace.display_to.is_equal_approx(endpoint), "落空、对象与 void 的显示终点保持真实射程或阻挡交点")
		_check(not world.player.is_destroyed(), "显示终点不能把落空或阻挡变成远处玩家命中")
		_check(world.get_player_defeat_attack_traces().is_empty(), "落空、地形或对象命中均不产生玩家模块毁坏反馈")
		if kind == "object":
			_check(world.get_object("target").health == 0.0, "对象毁坏后仍保留当 tick 的静态命中位置")


## 正式第七关先射击再后退 0.2 格，枪毁坏后仍移动一 tick 才报错；失败反馈必须解释原命中而保留当前落空射线。
func _test_player_defeat_attack_feedback() -> void:
	var loaded := MapCodec.load_file("res://data/levels/level_007.json", _content, true)
	if not _check(loaded.is_ok(), "延迟失败反馈回归可加载正式第七关"):
		return
	var defined := LevelDefinition.from_document(loaded.value, _content)
	if not _check(defined.is_ok(), "延迟失败反馈使用正式关卡规则"):
		return
	var session := GameSession.create(defined.value, _content)
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "延迟失败装配包含仍可后退的驱动")
	_check(session.assembly.add_module("shooting", Vector2(0.5, 0), "gun").is_ok(), "延迟失败装配包含前方射击模块")
	session.source = "main(){\nloop{\nshoot(0)\nmove(180,0.2)\n}\n}"
	if not _check(session.run().is_ok(), "真实延迟失败策略可以启动"):
		return
	for unused in 83:
		session.step()
	var world := session.world
	if not _check(world.tick_index == 83 and not world.player.get_module("gun").available and world.player.get_module("drive").available, "第 83 tick 只击毁前方枪，驱动继续存活"):
		return
	var original_attack := world.attack_traces[0].duplicate(true)
	var defeat_traces := world.get_player_defeat_attack_traces()
	if not _check(defeat_traces.size() == 1, "击毁当 tick 即可读取唯一真实损伤反馈"):
		return
	_check(defeat_traces[0] == original_attack, "击毁当 tick 的反馈与真实攻击完全相同")
	_check(original_attack.source_machine_id == "pursuer" and original_attack.source_module_id == "pursuer_blade", "反馈以明确的发射机器和模块标识关联当前射线")
	var destroyed_position := world.player.position
	# 第一次完成剩余后退，第二次派发失效的 shoot；第二次不能再推进世界。
	session.step()
	session.step()
	if not _check(session.state == GameSession.State.FAILED and world.tick_index == 84, "下一 tick 后退完成后才报 shoot 失效，失败保留第 84 tick"):
		return
	_check(world.player.position.x < destroyed_position.x, "失败画面中的灰色枪确实已经随驱动继续移动")
	var current_traces := world.attack_traces.duplicate(true)
	var gun_rect := world.player.get_module("gun").get_world_rect(world.player.position)
	var contact := Vector2(gun_rect.end.x, gun_rect.get_center().y)
	_check(absf(float(current_traces[0].display_to.x) - contact.x - 0.05) < 0.0001, "当前落空束与灰枪真实相差 0.05 格，保持原模拟结果")
	defeat_traces = world.get_player_defeat_attack_traces()
	if not _check(defeat_traces.size() == 1, "失败时仍可读取上一 tick 的真实击毁反馈"):
		return
	_check(defeat_traces[0].display_to.is_equal_approx(contact), "上一 tick 的命中部位重新附着到当前灰枪边缘，不留下后退造成的空隙")
	var enemy := world.get_machine("pursuer")
	_check(defeat_traces[0].display_from.is_equal_approx(enemy.position + enemy.get_module("pursuer_blade").local_position), "解释损伤的发射端也跟随当前敌方模块")
	_check(defeat_traces[0].from == original_attack.from and defeat_traces[0].to == original_attack.to, "重新投影不改写原始命中射线")
	for value: Variant in defeat_traces[0].values():
		_check(not value is Object, "公开失败反馈不泄漏运行时实例引用")
	defeat_traces[0].display_to = Vector2.ZERO
	_check(world.get_player_defeat_attack_traces()[0].display_to.is_equal_approx(contact), "修改返回字典不会污染内部反馈记录")
	_check(world.attack_traces == current_traces and world.tick_index == 84 and world.player.get_module("drive").health == 1.0, "重复查询不替换当前攻击、不推进世界且不造成伤害")
	world.step()
	_check(world.tick_index == 85 and world.get_player_defeat_attack_traces().is_empty(), "击毁两 tick 后反馈过期，不继续显示历史命中")


## 新的玩家模块毁坏替换旧 tick 的记录，避免失败页面把多次历史攻击累加起来。
func _test_player_defeat_attack_replacement() -> void:
	var document := _document()
	document.player_spawn.modules = [_module("gun", "shooting", 0), _module("drive", "movement", -0.5)]
	var world := _world(document)
	if world == null:
		return
	world.step()
	var first := world.get_player_defeat_attack_traces()
	if not _check(first.size() == 1 and first[0].to.is_equal_approx(Vector2(5.75, 4.5)), "首次摧毁前方枪时记录对应命中点"):
		return
	for unused in 3:
		world.step()
	var latest := world.get_player_defeat_attack_traces()
	_check(world.tick_index == 4 and world.player.is_destroyed(), "第 4 tick 继续摧毁后方驱动")
	_check(latest.size() == 1 and latest[0].to.is_equal_approx(Vector2(5.25, 4.5)), "新毁坏只保留新 tick 的命中，旧枪反馈不累加")
	_check(first[0].to.is_equal_approx(Vector2(5.75, 4.5)), "新事件不回写此前已返回的反馈快照")


## ready 查询针对下一个动作 tick；不能消耗冷却、发射子弹、广播或影响另一模块。
func _test_ready_query() -> void:
	var document := _document()
	document.enemies = []
	document.player_spawn.modules = [_module("gun", "shooting", 0), _module("spare", "shooting", -0.5), _module("drive", "movement", 0.5)]
	var world := _world(document)
	var original := document.to_dict()
	for unused in 20:
		var ready := world.is_shoot_ready("player", "gun")
		_check(ready.is_ok() and ready.value == true, "初始射击模块已就绪，重复查询结果稳定")
	_check(world.tick_index == 0 and world.projectiles.is_empty() and world.player.get_module("gun").next_shoot_tick == 0, "查询不推进世界、不发射、不预留冷却")
	_check(world.request_shoot("player", 0, "gun").is_ok(), "查询后仍可提交射击")
	_check(world.is_shoot_ready("player", "gun").value, "排队动作尚未消耗冷却，查询只读当前状态")
	world.step()
	_check(world.tick_index == 1 and world.player.get_module("gun").next_shoot_tick == 11, "第 1 tick 发射后下一次可射击 tick 为 11")
	for unused in 9:
		_check(not world.is_shoot_ready("player", "gun").value, "下一个执行 tick 仍处于冷却时返回 false")
		world.step()
	_check(world.tick_index == 10 and world.is_shoot_ready("player", "gun").value, "在第 10 tick 结束时查询第 11 tick，就绪边界不延迟一帧")
	_check(world.player.get_module("gun").next_shoot_tick == 11 and world.is_shoot_ready("player", "spare").value and world.player.get_module("spare").next_shoot_tick == 0, "查询不改变自身冷却，另一射击模块始终独立")
	var shot := world.request_shoot("player", 0, "gun")
	world.step()
	_check(shot.is_ok() and shot.value.shot_count == 1 and world.player.get_module("gun").next_shoot_tick == 21, "就绪边界提交的射击在下一 tick 真实发射")
	for query in [["missing", "gun"], ["player", ""], ["player", "missing"], ["player", "drive"]]:
		_check(not world.is_shoot_ready(query[0], query[1]).is_ok(), "查询拒绝未知机器、空名称、未知名称或非射击能力")
	world.player.get_module("gun").apply_damage(1)
	_check(not world.is_shoot_ready("player", "gun").is_ok() and world.is_shoot_ready("player", "spare").value, "损坏的命名模块返回错误，不借用其他射击模块")
	var fresh := _world(document)
	_check(fresh.tick_index == 0 and fresh.is_shoot_ready("player", "gun").value and document.to_dict() == original, "独立世界与地图不受另一世界冷却或伤害污染")


## 覆盖耐久只属于明确选中的敌人实例；旧行为和未知扩展仍兼容。
func _test_overrides_and_validation() -> void:
	var document := _document()
	document.enemies[0].properties.module_health = {"blade": 6, "drive": 0.5}
	var original := document.to_dict()
	var definition := _content.get_module("melee")
	var definition_properties := definition.properties.duplicate(true)
	var world := _world(document)
	var enemy := world.get_machine("pursuer")
	_check(enemy.get_module("blade").max_health == 6 and enemy.get_module("blade").health == 6 and enemy.get_module("drive").health == 0.5, "有效 module_health 覆盖指定实例的初始与最大耐久")
	_check(enemy.get_move_speed() == 1 and enemy.get_module("blade").definition == definition and definition.properties == definition_properties, "耐久覆盖不修改共享模块、移动速度或全局平衡")
	enemy.get_module("blade").apply_damage(2)
	_check(document.to_dict() == original and _world(document).get_machine("pursuer").get_module("blade").health == 6, "伤害不回写 JSON，新建世界恢复覆盖初值")
	var default_world := _world(_document())
	_check(default_world.get_machine("pursuer").get_module("blade").health == 1, "省略覆盖继续使用默认模块耐久")
	for invalid: Variant in [null, [], "bad", true, {"missing": 1}, {"drive": 0}, {"blade": -1}, {"blade": 0.009}, {"blade": 1000001}, {"blade": true}, {"blade": "6"}]:
		var bad := document.duplicate_document()
		bad.enemies[0].properties.module_health = invalid
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "拒绝坏类型、未知实例或越界的敌人耐久覆盖")
	for field in ["move_angle", "attack_angle"]:
		for invalid: Variant in [null, true, "180", []]:
			var bad := document.duplicate_document()
			bad.enemies[0].properties[field] = invalid
			_check(not MapCodec.validate(bad, _content, true).is_ok(), "推进与攻击角度拒绝缺失或非数字")
	_check(MapCodec.validate(document, _content, true).is_ok(), "持续推进不要求有限 move_distance")
	var previous := _document()
	previous.enemies[0].behavior = "approach_attack"
	_check(not MapCodec.validate(previous, _content, true).is_ok(), "旧接近行为仍要求 move_distance")
	previous.enemies[0].properties.move_distance = 0.1
	world = _world(previous)
	world.player.get_module("gun").health = 10
	world.step()
	_check(world.player.get_module("gun").health == 10, "旧接近行为移动阶段仍不攻击")
	world.step()
	_check(world.player.get_module("gun").health == 9 and absf(world.get_machine("pursuer").position.x - 6.9) < 0.00001, "旧接近行为完成有限移动后才静止攻击")
	previous.enemies[0].behavior = "alarm_guard"
	previous.enemies[0].properties = {}
	world = _world(previous)
	world.step()
	_check(world.get_machine("pursuer").position == Vector2(7, 4.5) and not world.player.is_destroyed(), "警报守卫继续静止待命")
	previous.enemies[0].behavior = "future_enemy"
	previous.enemies[0].properties = {"custom": true}
	world = _world(previous)
	_check(world.get_machine("pursuer") == null and world.document.enemies[0].properties.custom, "未知扩展行为保留数据但不执行")


## 全地板、近距离、默认模块夹具让每个模拟结果不依赖第七关平衡数值。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "pursuit_fixture"
	document.width = 14
	document.height = 8
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5.5, "y": 4.5}, "modules": [_module("gun", "shooting", 0)]}
	document.enemies = [{"id": "pursuer", "behavior": "advance_attack", "position": {"x": 7.0, "y": 4.5}, "modules": [_module("drive", "movement", 0), _module("blade", "melee", 0.5)], "properties": {"move_angle": 180, "attack_angle": 180}}]
	return document


## 名称与内容 ID 分开，覆盖命名实例语义。
func _module(id: String, kind: String, offset_x: float) -> Dictionary:
	return {"id": id, "module_id": kind, "offset": {"x": offset_x, "y": 0}}


## 通过生产校验和工厂构造独立世界。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	if not _check(result.is_ok(), "夹具建立世界：%s" % result.errors):
		return null
	return result.value


## 统计断言并提供包装脚本能识别的失败状态。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
