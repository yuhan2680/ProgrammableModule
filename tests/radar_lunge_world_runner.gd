extends SceneTree
## 雷达突袭底层边界：真实雷达中心、属性遮挡、已锁定目标、取消与实际出手计数。

const ENEMY := "hunter"
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()


## 使用内存内容和地图运行，不保存测试关卡、不读取玩家进度。
func _initialize() -> void:
	_run.call_deferred()


## 独立验证底层能力边界，不重复完整关卡的解法与教学文案测试。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "雷达底层加载真实内容"):
		quit(1)
		return
	_add_tile("radar_screen", false, true)
	_add_tile("clear_wall", true, false)
	_test_radar_geometry()
	_test_radar_obstruction()
	_test_lock_and_real_miss()
	_test_cancelled_attack()
	_test_mid_attack_invalidation()
	_test_cooldown_and_blocked_approach()
	_test_capability_validation()
	print("雷达突袭底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 范围以实际雷达部件中心计，端点包含且只读取当前世界，不改变命令或计时。
func _test_radar_geometry() -> void:
	var world := _world(80)
	var enemy := world.get_machine(ENEMY)
	enemy.position = Vector2(40,40)
	var radar := enemy.get_module("radar")
	var origin := enemy.position + radar.local_position
	for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		world.player.position = origin + direction * 32.0
		_check(world.radar_detects_player(ENEMY,"radar"), "真实雷达半径端点包含：" + str(direction))
		world.player.position = origin + direction * 32.01
		_check(not world.radar_detects_player(ENEMY,"radar"), "半径外目标不会因模块半宽而被错误锁定：" + str(direction))
	world.player.position = origin + Vector2(20,20)
	_check(world.radar_detects_player(ENEMY,"radar"), "斜向探测按圆形距离而非单轴范围")
	world.player.position = origin + Vector2(23,23)
	_check(not world.radar_detects_player(ENEMY,"radar"), "方形包围范围内但圆形半径外拒绝")
	world.player.position = origin
	_check(world.radar_detects_player(ENEMY,"radar"), "目标与雷达中心重合时不除以零")
	world.player.position = Vector2(20.5,20.5)
	for pair in [["missing","radar"], [ENEMY,"missing"], [ENEMY,"engine"], [ENEMY,"blade"], ["player","sensor"]]:
		_check(not world.radar_detects_player(pair[0],pair[1]), "不存在或不具备雷达能力的来源返回 false")
	radar.available = false
	_check(not world.radar_detects_player(ENEMY,"radar"), "雷达失效立即停止探测")
	radar.available = true
	world.player.get_module("drive").available = false
	_check(world.radar_detects_player(ENEMY,"radar"), "玩家仍有一个存活模块时仍可探测参考位置")
	world.player.get_module("sensor").available = false
	_check(not world.radar_detects_player(ENEMY,"radar"), "玩家全部失效后不锁定残留位置")
	world.player.get_module("drive").available = true
	world.player.get_module("sensor").available = true
	var requested := world.request_move("player",0,.1)
	if _check(requested.is_ok(), "只读扫描测试可以预先排队真实移动"):
		var command: MovementCommand = requested.value
		var before := var_to_str([world.tick_index,world.player.position,enemy.position,world.get_enemy_attack_status(ENEMY)])
		for unused in 12:
			world.radar_detects_player(ENEMY,"radar")
		_check(before == var_to_str([world.tick_index,world.player.position,enemy.position,world.get_enemy_attack_status(ENEMY)]) and command.state == SimulationCommand.State.QUEUED, "重复雷达查询不推进世界、改变状态机或消费已有动作")
	var status := world.get_enemy_attack_status(ENEMY)
	status.dodged = 100
	_check(world.get_enemy_attack_status(ENEMY).dodged == 0 and world.get_enemy_attack_status("missing").is_empty(), "状态返回副本，外部不能修改真实闪避次数")


## 只按 radar_block 地块属性遮挡，透明碰撞墙、射线外和目标后方地块不会误挡。
func _test_radar_obstruction() -> void:
	var world := _world()
	_check(world.radar_detects_player(ENEMY,"radar"), "无遮蔽时可锁定目标")
	world.document.set_tile(Vector2i(23,20),"radar_screen")
	_check(not world.radar_detects_player(ENEMY,"radar"), "不碰撞但阻雷达的地块仍遮挡锁定")
	var enemy_start := world.get_machine(ENEMY).position
	for unused in 5:
		world.step()
	_check(world.get_machine(ENEMY).position == enemy_start and world.get_enemy_attack_status(ENEMY).attempts == 0, "雷达被遮挡时不会提交盲目追踪或攻击")
	world.document.set_tile(Vector2i(23,20),"clear_wall")
	_check(world.radar_detects_player(ENEMY,"radar"), "普通碰撞属性不能冒充 radar_block")
	world.document.set_tile(Vector2i(23,20),"floor")
	for cell: Vector2i in [Vector2i(23,21),Vector2i(26,20),Vector2i(19,20)]:
		world.document.set_tile(cell,"radar_screen")
		_check(world.radar_detects_player(ENEMY,"radar"), "射线之外或目标/来源后方的屏障不遮挡：" + str(cell))
		world.document.set_tile(cell,"floor")
	world.player.position = Vector2(20.5,15.5)
	world.document.set_tile(Vector2i(23,17),"radar_screen")
	_check(not world.radar_detects_player(ENEMY,"radar"), "雷达射线接触屏障角点时保守视为遮挡")
	world.document.set_tile(Vector2i(23,17),"floor")
	_check(world.radar_detects_player(ENEMY,"radar"), "移除屏障后的下一次只读查询立刻恢复可见")


## 扫描只锁定一次位置，玩家侧移后敌人仍在原横线真实出手，再按命令结果计数。
func _test_lock_and_real_miss() -> void:
	var world := _world()
	var finished: Array[AttackCommand] = []
	world.attack_finished.connect(func(command: AttackCommand) -> void: finished.append(command))
	world.step()
	_check(world.request_move("player",90,1).is_ok(), "锁定后由正常世界移动让玩家离开原攻击横线")
	for unused in 100:
		if not finished.is_empty():
			break
		world.step()
	if not _check(finished.size() == 1, "本次锁定最终产生且只产生一条真实近战结果"):
		return
	var command := finished[0]
	var status := world.get_enemy_attack_status(ENEMY)
	_check(command.state == SimulationCommand.State.COMPLETED and command.hit_count == 0 and world.attack_traces.size() == 1, "完成的近战确实产生射线并落空")
	_check(status.attempts == 1 and status.dodged == 1 and world.failure_reason.is_empty(), "一次真实落空恰好增加一次尝试和闪避")
	_check(world.player.position.is_equal_approx(Vector2(20.5,19.5)) and is_equal_approx(world.get_machine(ENEMY).position.y,20.5), "追击不在接近过程中重新追踪玩家的新横线")
	_check(is_equal_approx(world.attack_traces[0].from.y,20.5) and is_equal_approx(world.attack_traces[0].to.y,20.5), "实际近战射线仍沿最初锁定横线")
	for unused in 4:
		world.step()
	_check(world.get_enemy_attack_status(ENEMY).attempts == 1 and world.get_enemy_attack_status(ENEMY).dodged == 1, "恢复等待与后续时间不会重复统计同一条攻击")


## 对已排队攻击使用公开取消接口，应释放控制器句柄并恢复，而不是永久卡在 attack。
func _test_cancelled_attack() -> void:
	var world := _world()
	var command := _queue_attack(world)
	if not _check(command != null, "可以在控制器派发和统一提交之间观察已排队近战"):
		return
	_check(world.cancel_command(ENEMY).is_ok() and command.state == SimulationCommand.State.CANCELLED, "公开取消将实际近战命令标记为已取消")
	world.step()
	var status := world.get_enemy_attack_status(ENEMY)
	_check(status.phase == "recover" and status.attempts == 0 and status.dodged == 0, "取消攻击后进入恢复，未出手不能计数")
	var later_attack := false
	for unused in 100:
		world.step()
		if world.get_enemy_attack_status(ENEMY).attempts > 0:
			later_attack = true
			break
	_check(later_attack, "取消攻击恢复后仍能重新锁定并真实出手，不会卡死")


## 能力在攻击已排队之后失效时，同一世界步骤取消动作，不产生幽灵射线和闪避次数。
func _test_mid_attack_invalidation() -> void:
	for module_id in ["radar","blade","engine"]:
		var world := _world()
		var command := _queue_attack(world)
		if not _check(command != null, "能力中断前近战已实际排队：" + module_id):
			continue
		world.get_machine(ENEMY).get_module(module_id).apply_damage(1000)
		world.step()
		var status := world.get_enemy_attack_status(ENEMY)
		_check(command.state == SimulationCommand.State.CANCELLED and world.attack_traces.is_empty(), "排队后 %s 失效会取消近战，不留下射线" % module_id)
		_check(status.attempts == 0 and status.dodged == 0 and world.failure_reason.is_empty(), "排队后 %s 失效不算实际出手或失败" % module_id)


## 冷却空调用与扫掠受阻不同于攻击落空，只有真正的射线提交才能增加统计。
func _test_cooldown_and_blocked_approach() -> void:
	var world := _world()
	var command := _queue_attack(world)
	if _check(command != null, "冷却边界前近战可以排队"):
		world.get_machine(ENEMY).get_module("blade").next_attack_tick = world.tick_index + 50
		world.step()
		_check(command.state == SimulationCommand.State.COMPLETED and world.attack_traces.is_empty(), "排队后进入冷却的动作虽完成但没有真正出手")
		_check(world.get_enemy_attack_status(ENEMY).attempts == 0 and world.get_enemy_attack_status(ENEMY).dodged == 0, "冷却空动作不增加实际攻击或闪避次数")
	var delayed := _world()
	delayed.get_machine(ENEMY).get_module("blade").next_attack_tick = 60
	for unused in 59:
		delayed.step()
	_check(delayed.get_enemy_attack_status(ENEMY).phase == "approach" and delayed.get_enemy_attack_status(ENEMY).attempts == 0, "已经抵达攻击点也要等待真实近战冷却，不重复提交空攻击")
	delayed.step()
	_check(delayed.get_enemy_attack_status(ENEMY).attempts == 1 and not delayed.attack_traces.is_empty(), "冷却截止 tick 到达后立即实际出手")
	var blocked := _world()
	blocked.document.set_tile(Vector2i(23,20),"clear_wall")
	for unused in 100:
		blocked.step()
	_check(blocked.get_enemy_attack_status(ENEMY).attempts == 0 and blocked.get_enemy_attack_status(ENEMY).dodged == 0 and blocked.failure_reason.is_empty(), "看到目标但接近路径被地形阻挡时不会隔墙出手或刷次数")
	_check(blocked.get_machine(ENEMY).position.x >= 24.7499, "完整模块扫掠停在墙壁接触处，不按机器中心穿墙")
	var unrelated := _world()
	var created := MachineFactory.create_machine("other",{"position":{"x":30,"y":30},"modules":[{"id":"blade","module_id":"melee","offset":{"x":0,"y":0}}]},unrelated.document,_content,ModuleBehaviorRegistry.create_default())
	if _check(created.is_ok() and unrelated.add_machine(created.value).is_ok(), "独立机器可以加入同一世界"):
		_check(unrelated.request_attack("other",0).is_ok(), "另一台机器可以提交真实近战")
		unrelated.step()
		_check(unrelated.attack_traces.size() == 1 and unrelated.get_enemy_attack_status(ENEMY).attempts == 0, "其他机器的真实出手不会记到目标敌人名下")


## 雷达范围输入保持严格类型与有限上限，能力快照不能反写共享定义。
func _test_capability_validation() -> void:
	var behavior := RadarModule.new()
	for value in [0,-1,true,"32",NAN,INF,512.01,null]:
		var definition := ModuleDefinition.new()
		definition.properties = {"radar_range":value}
		_check(not behavior.validate_definition(definition).is_ok(), "雷达拒绝错误类型、非有限或越界范围")
	for value in [.01,32,512]:
		var definition := ModuleDefinition.new()
		definition.properties = {"radar_range":value}
		_check(behavior.validate_definition(definition).is_ok(), "合法雷达范围边界接受：" + str(value))
	var world := _world()
	var radar := world.get_machine(ENEMY).get_module("radar")
	var profile := radar.behavior.get_radar_profile(radar)
	profile.range = 9999
	_check(radar.behavior.get_radar_profile(radar).range == 32.0 and _content.get_module("radar").properties.radar_range == 32.0, "能力描述返回独立快照，不能放大真实雷达范围")


## 建立确定性内存场地；敌人在目标右侧准备点，仍通过普通移动完成三格接近。
func _world(size: int = 40) -> SimulationWorld:
	var document := MapDocument.new()
	document.width = size
	document.height = size
	for y in size:
		for x in size:
			document.set_tile(Vector2i(x,y),"floor")
	document.player_spawn = {"position":{"x":20.5,"y":20.5},"modules":[
		{"id":"sensor","module_id":"rangefinder","offset":{"x":0,"y":0}},
		{"id":"drive","module_id":"movement","offset":{"x":.5,"y":0}},
	]}
	document.enemies = [{"id":ENEMY,"position":{"x":25,"y":20.5},"modules":[
		{"id":"blade","module_id":"melee","offset":{"x":-.5,"y":0}},
		{"id":"engine","module_id":"movement","offset":{"x":0,"y":0}},
		{"id":"radar","module_id":"radar","offset":{"x":.5,"y":0}},
	],"behavior":"radar_lunge","properties":{"attack_module_id":"blade","radar_module_id":"radar","attack_angle":180,"stand_off":1.0,"approach_distance":3.0,"recovery_ticks":5}}]
	var created := SimulationWorld.create(document,_content)
	_check(created.is_ok(), "雷达底层创建独立真实世界：" + str(created.errors))
	return created.value as SimulationWorld


## 只在移动已经完成后单独调用真实准备阶段，暴露尚未统一提交的取消边界，不伪造攻击提案。
func _queue_attack(world: SimulationWorld) -> AttackCommand:
	var controller: RadarLungeController = world._enemy_controllers[ENEMY].lunge
	for unused in 100:
		if controller.phase == "approach" and controller._move != null and controller._move.is_finished():
			controller.prepare(world,world.get_machine(ENEMY))
			if controller._attack != null:
				return controller._attack
		world.step()
	return null


## 测试用属性地块仅放入本次内存注册表，不修改实际 JSON 内容。
func _add_tile(id: String, collision: bool, radar_block: bool) -> void:
	var tile := TileDefinition.new()
	tile.id = id
	tile.collision = collision
	tile.radar_block = radar_block
	_content.tiles[id] = tile


## 累计断言并提供明确失败原因，交由统一脚本判断进程结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
