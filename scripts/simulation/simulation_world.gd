class_name SimulationWorld
extends RefCounted
## 固定 10 Hz 的纯数据世界。收集动作 → 计算位移 → 统一提交 → 发出结果信号。
## 闸门、移动和近战共享模拟时钟；先计算所有提案，再提交位置与伤害。

signal tick_completed(tick_index: int)
signal command_finished(command: MovementCommand)
signal attack_finished(command: AttackCommand)
signal shot_finished(command: ShootCommand)

const TICKS_PER_SECOND: int = 10
const TICK_DURATION: float = 1.0 / TICKS_PER_SECOND

var document: MapDocument
var machines: Array[MachineInstance] = []
var player: MachineInstance
var tick_index: int = 0
var _content: ContentRegistry
var _commands: Dictionary = {}
var _stepping: bool = false
var objects: Array[WorldObject] = []
var failure_reason: String = ""
var attack_traces: Array[Dictionary] = []
var _player_destroyed_module_traces: Array[Dictionary] = []
var _player_destroyed_module_tick: int = -1
var _attack_commands: Dictionary = {}
var _crushed: Dictionary = {}
var projectiles: Array[ProjectileInstance] = []
var _shoot_commands: Dictionary = {}
var _simultaneous_commands: Dictionary = {}
var _tick_actions: Dictionary = {}
var _enemy_controllers: Dictionary = {}
var _enemy_waves: EnemyWaveController


## 从同一地图格式建立独立试玩快照，任何试玩结果都不会回写编辑文档。
static func create(map_document: MapDocument, content: ContentRegistry, behaviors: ModuleBehaviorRegistry = null) -> DataResult:
	var validation := MapCodec.validate(map_document, content, true)
	if not validation.is_ok():
		return validation
	if behaviors == null:
		behaviors = ModuleBehaviorRegistry.create_default()
	var world := SimulationWorld.new()
	world.document = map_document.duplicate_document()
	world._content = content
	var machine_result := MachineFactory.create_machine("player", world.document.player_spawn, world.document, content, behaviors)
	if not machine_result.is_ok():
		return machine_result
	for entry: Dictionary in world.document.objects:
		var definition := MapObjectDefinition.from_entry(entry)
		if definition != null:
			world.objects.append(WorldObject.create(definition))
	world.player = machine_result.value
	var level_rules: Variant = world.document.properties.get("level", {})
	if level_rules is Dictionary and level_rules.has("player_max_health"):
		var health: Variant = level_rules.player_max_health
		if not DataValidation.is_number(health) or float(health) <= 0.0 or float(health) > 1000000000.0:
			return DataResult.failure("关卡 player_max_health 必须为大于 0 且不超过 1000000000 的有限数字。")
		# 此处使用已确认的实际装配；仅覆盖玩家运行实例，旧地图仍继承各模块定义。
		for module: ModuleInstance in world.player.modules:
			module.max_health = float(health)
			module.health = module.max_health
	if world._overlaps_object(world.player):
		return DataResult.failure("机器出生占地与障碍物重叠。")
	world.machines.append(world.player)
	var wave_random := RandomNumberGenerator.new()
	wave_random.randomize()
	var pending_waves: Array[Dictionary] = []
	for entry: Dictionary in world.document.enemies:
		if not world.are_enemies_enabled():
			break
		if entry.get("behavior") not in EnemyDefinition.BEHAVIORS:
			continue
		# 敌人配置先深拷贝，随机方向不会写回世界文档或编辑器。
		entry = entry.duplicate(true)
		var enemy_result := MachineFactory.create_machine(entry.id, entry, world.document, content, behaviors)
		if not enemy_result.is_ok():
			return enemy_result
		if entry.behavior in [EnemyDefinition.ADVANCE_ATTACK, EnemyDefinition.RANDOM_WANDER, EnemyDefinition.WAVE_APPROACH_ATTACK, EnemyDefinition.AUTO_CHASE_ATTACK]:
			# 耐久属于本次世界中的敌人实例；不污染注册表或地图，重试重新应用初值。
			var health_overrides: Dictionary = entry.get("properties", {}).get("module_health", {})
			for module_id: String in health_overrides:
				var module: ModuleInstance = enemy_result.value.get_module(module_id)
				module.max_health = float(health_overrides[module_id])
				module.health = module.max_health
		if entry.behavior == EnemyDefinition.WAVE_APPROACH_ATTACK:
			if entry.properties.has("random_spawn"):
				RandomWaveLayout.apply(enemy_result.value, entry.properties, wave_random)
				var placement := MachineFactory.validate_placement(enemy_result.value, world.document, content)
				if not placement.is_ok():
					return placement
			# 仍在建世界时验证全部未来出生点，只有按序激活后才进入可见机器表。
			if world._overlaps_object(enemy_result.value):
				return DataResult.failure("分波敌人的出生占地与障碍物重叠。")
			pending_waves.append({"machine": enemy_result.value, "properties": entry.properties.duplicate(true)})
		else:
			var added := world.add_machine(enemy_result.value)
			if not added.is_ok():
				return added
		world._enemy_controllers[entry.id] = {"behavior": entry.behavior, "properties": entry.get("properties", {}).duplicate(true), "phase": "approach", "started": false}
		if entry.behavior == EnemyDefinition.RADAR_LUNGE:
			world._enemy_controllers[entry.id].lunge = RadarLungeController.create(entry.properties)
		if entry.behavior == EnemyDefinition.RANDOM_WANDER:
			world._enemy_controllers[entry.id].wander = RandomWanderController.create(entry.properties)
		if entry.behavior == EnemyDefinition.AUTO_CHASE_ATTACK:
			world._enemy_controllers[entry.id].automatic = EditorEnemyController.new()
	if not pending_waves.is_empty():
		world._enemy_waves = EnemyWaveController.create(pending_waves)
		world._enemy_waves.prepare(world)
	world._update_security_gates()
	return DataResult.success(world)


## 关闭仅影响本次世界实例；保留文档中的敌人配置，旧地图默认启用。
func are_enemies_enabled() -> bool:
	return bool(document.properties.get("level", {}).get("enemies_enabled", true))


## 注册由可信装配系统创建的机器；所有机器共用相同地形通行规则。
func add_machine(machine: MachineInstance) -> DataResult:
	if machine == null:
		return DataResult.failure("不能添加空机器。")
	if get_machine(machine.id) != null:
		return DataResult.failure("机器 ID 重复：%s。" % machine.id)
	var validation := MachineFactory.validate_placement(machine, document, _content)
	if not validation.is_ok():
		return validation
	if _overlaps_object(machine):
		return DataResult.failure("机器出生占地与障碍物重叠。")
	machines.append(machine)
	return DataResult.success(machine)


## 通过稳定实例 ID 查找机器，避免解释器持有 UI 节点引用。
func get_machine(machine_id: String) -> MachineInstance:
	for machine in machines:
		if machine.id == machine_id:
			return machine
	return null


## 提交 move(角度, 距离)；0° 向右、90° 向上，距离单位为格。
func request_move(machine_id: String, angle_degrees: Variant, distance: Variant, module_id: String = "") -> DataResult:
	if not _is_finite_number(angle_degrees) or not _is_finite_number(distance):
		return DataResult.failure("move 的角度和距离必须是有限数字，不能是布尔值。")
	if float(distance) < 0.0:
		return DataResult.failure("move 的距离不能小于 0；反向请使用对应角度。")
	var machine := get_machine(machine_id)
	if machine == null:
		return DataResult.failure("move 引用了不存在的机器：%s。" % machine_id)
	if _commands.has(machine_id) or _attack_commands.has(machine_id) or _shoot_commands.has(machine_id) or _simultaneous_commands.has(machine_id):
		return DataResult.failure("机器 %s 仍有移动动作正在执行，请等待完成或取消。" % machine_id)
	var selected := _validate_module_action(machine, "move", module_id)
	if not selected.is_ok():
		return selected
	var speed := machine.get_move_speed(module_id)
	if not is_finite(speed) or speed <= 0.0:
		return DataResult.failure("机器 %s 没有可用的移动能力。" % machine_id)
	var command := MovementCommand.new()
	command.machine_id = machine_id
	command.module_id = module_id
	command.angle_degrees = fposmod(float(angle_degrees), 360.0)
	command.distance = float(distance)
	var radians := deg_to_rad(command.angle_degrees)
	command.direction = Vector2(cos(radians), -sin(radians))
	# 清理三角函数在四个正方向的浮点尾数，防止沿墙移动时缓慢漂移。
	if absf(command.direction.x) < 0.0000001:
		command.direction.x = 0.0
	if absf(command.direction.y) < 0.0000001:
		command.direction.y = 0.0
	_commands[machine_id] = command
	return DataResult.success(command)


## 只读预检并行动作及实际模块占用；不检查位置、冷却或当前通道，以支持整树提前校验。
func validate_simultaneous(machine_id: String, actions: Array[Dictionary]) -> DataResult:
	if actions.size() < 2 or actions.size() > 256:
		return DataResult.failure("simultaneously 必须包含 2..256 条直接动作。")
	var machine := get_machine(machine_id)
	if machine == null:
		return DataResult.failure("simultaneously 引用了不存在的机器：%s。" % machine_id)
	var occupied: Dictionary = {}
	var has_move := false
	for action in actions:
		var callee: Variant = action.get("callee")
		var arguments: Variant = action.get("arguments")
		var module_id: Variant = action.get("module_id", "")
		if callee not in ["move", "attack", "shoot"] or not arguments is Array or not module_id is String:
			return DataResult.failure("simultaneously 仅接受 move、attack、shoot 动作及有效参数。")
		if arguments.size() != (2 if callee == "move" else 1):
			return DataResult.failure("simultaneously 中 %s 的参数数量不正确。" % callee)
		for argument: Variant in arguments:
			if not _is_finite_number(argument):
				return DataResult.failure("simultaneously 的动作参数必须是有限数字，不能是布尔值。")
		if callee == "move" and float(arguments[1]) < 0.0:
			return DataResult.failure("move 的距离不能小于 0；反向请使用对应角度。")
		var selected := _validate_module_action(machine, callee, module_id)
		if not selected.is_ok():
			return selected
		if callee == "move":
			if not is_finite(machine.get_move_speed(module_id)):
				return DataResult.failure("并行动作的移动速度必须是有限数字。")
			if has_move:
				return DataResult.failure("一个 simultaneously 块最多只能有一条 move；移动会带动整台机器。")
			has_move = true
		for actual_id: String in _action_module_ids(machine, callee, module_id):
			if occupied.has(actual_id):
				return DataResult.failure("simultaneously 中模块 %s 被重复使用；广播与命名调用也不能重叠。" % actual_id)
			occupied[actual_id] = true
	return DataResult.success()


## 校验全部动作后一次性预留 main 通道；构造期间不发信号，不会留下半个已提交的块。
func request_simultaneous(machine_id: String, actions: Array[Dictionary]) -> DataResult:
	var validation := validate_simultaneous(machine_id, actions)
	if not validation.is_ok():
		return validation
	if _commands.has(machine_id) or _attack_commands.has(machine_id) or _shoot_commands.has(machine_id) or _simultaneous_commands.has(machine_id):
		return DataResult.failure("机器仍有动作正在执行，请等待完成或取消。")
	var group := SimultaneousCommand.new()
	group.machine_id = machine_id
	for action in actions:
		group.children.append(_make_simultaneous_child(machine_id, action))
	_simultaneous_commands[machine_id] = group
	return DataResult.success(group)


## 从已验证参数建立独立句柄；与普通动作使用相同方向、距离和实际模块选择规则。
func _make_simultaneous_child(machine_id: String, action: Dictionary) -> SimulationCommand:
	var command: SimulationCommand
	if action.callee == "move":
		var move := MovementCommand.new()
		move.angle_degrees = fposmod(float(action.arguments[0]), 360.0)
		move.distance = float(action.arguments[1])
		move.direction = _angle_direction(move.angle_degrees)
		command = move
	elif action.callee == "attack":
		var attack := AttackCommand.new()
		attack.direction = _angle_direction(float(action.arguments[0]))
		command = attack
	else:
		var shot := ShootCommand.new()
		shot.direction = _angle_direction(float(action.arguments[0]))
		command = shot
	command.machine_id = machine_id
	command.module_id = action.get("module_id", "")
	return command


## 把广播展开成真实能力来源；同一实例的任何两个并行动作都算资源冲突。
func _action_module_ids(machine: MachineInstance, callee: String, module_id: String) -> Array[String]:
	var ids: Array[String] = []
	for module in machine.modules:
		if not module.available or (not module_id.is_empty() and module.id != module_id):
			continue
		var capable := module.get_move_speed() > 0.0 if callee == "move" else (not module.behavior.get_attack_profile(module).is_empty() if callee == "attack" else not module.behavior.get_shoot_profile(module).is_empty())
		if capable:
			ids.append(module.id)
	return ids


## 推进一个逻辑 tick；全部动作先读取相同状态，伤害统一提交，避免先手结算优势。
func step() -> void:
	if _stepping:
		return
	_stepping = true
	tick_index += 1
	attack_traces.clear()
	# 警戒快照必须早于任何位移；同 tick 拆掉警报也不能豁免先移动的行为。
	var active_alarms: Array[WorldObject] = []
	var armed_pairs: Array[WorldObject] = []
	var player_tick_start := player.position
	for object in objects:
		if object.health <= 0.0:
			continue
		if object.definition.kind == "prison_alarm":
			active_alarms.append(object)
		elif object.definition.kind == "paired_alarm":
			armed_pairs.append(object)
	if _enemy_waves != null:
		_enemy_waves.prepare(self)
	_prepare_enemy_actions()
	# 闸门在移动前落下，保留原有压住即失败规则。
	for machine in machines:
		if _overlaps_object(machine):
			_crushed[machine.id] = true
			if machine == player:
				failure_reason = "闸门已落下并碰到机器，本次运行失败。"
	var moves: Array[Dictionary] = []
	var ids: Array = _commands.keys()
	ids.sort()
	for machine_id: String in ids:
		moves.append(_prepare_move(get_machine(machine_id), _commands[machine_id]))
	var attacks: Array[Dictionary] = []
	var shots: Array[Dictionary] = []
	ids = _attack_commands.keys()
	ids.sort()
	for machine_id: String in ids:
		attacks.append(_prepare_attack(get_machine(machine_id), _attack_commands[machine_id]))
	ids = _shoot_commands.keys()
	ids.sort()
	for machine_id: String in ids:
		shots.append(_prepare_shoot(get_machine(machine_id), _shoot_commands[machine_id]))
	# 并行子动作共用本次世界快照和统一提交阶段，不借用 tick 回调伪装 main 并发。
	ids = _simultaneous_commands.keys()
	ids.sort()
	for machine_id: String in ids:
		var group: SimultaneousCommand = _simultaneous_commands[machine_id]
		group.state = SimulationCommand.State.RUNNING
		if group.started_tick < 0:
			group.started_tick = tick_index
		for child in group.children:
			if child.is_finished():
				continue
			if child is MovementCommand:
				moves.append(_prepare_move(get_machine(machine_id), child))
			elif child is AttackCommand:
				attacks.append(_prepare_attack(get_machine(machine_id), child))
			else:
				shots.append(_prepare_shoot(get_machine(machine_id), child))
	# tick 回调可和 main 的移动同时提出攻击；相同模块的冷却仍共享。
	var callback_actions: Dictionary = _tick_actions
	_tick_actions = {}
	# 按提交顺序处理命名与广播的重叠调用；每个真实模块的冷却保证先调用者生效。
	ids = callback_actions.keys()
	for key: String in ids:
		var command: SimulationCommand = callback_actions[key]
		if command is AttackCommand:
			attacks.append(_prepare_attack(get_machine(command.machine_id), command))
		else:
			shots.append(_prepare_shoot(get_machine(command.machine_id), command))
	var flying: Array[ProjectileInstance] = projectiles.duplicate()
	for proposal in shots:
		flying.append_array(proposal.projectiles)
	var bullet_proposals: Array[Dictionary] = []
	for projectile in flying:
		bullet_proposals.append(_prepare_projectile(projectile, moves))
	var finished_moves: Array[MovementCommand] = []
	for proposal in moves:
		_commit_move(proposal, finished_moves)
	var damage: Array[Dictionary] = []
	for proposal in attacks:
		damage.append_array(proposal.hits)
	projectiles.clear()
	for proposal in bullet_proposals:
		var projectile: ProjectileInstance = proposal.projectile
		projectile.position = proposal.position
		projectile.speed = proposal.speed
		if not proposal.hit.is_empty():
			damage.append(proposal.hit)
		if proposal.alive:
			projectiles.append(projectile)
	# 所有武器已经生成命中提案，此时才失效模块；互相击中可同时摧毁。
	for hit: Dictionary in damage:
		if hit.has("module"):
			var module: ModuleInstance = hit.module
			module.apply_damage(float(hit.damage))
		else:
			var object: WorldObject = hit.object
			object.health = maxf(0.0, object.health - float(hit.damage))
	if _enemy_waves != null:
		_enemy_waves.commit(self)
	# 先完成整个 tick 的伤害，再判警报：同 tick 消灭守卫并摧毁警报属于有效解法。
	_commit_security(active_alarms)
	_commit_paired_alarms(armed_pairs, player.position != player_tick_start)
	var finished_attacks: Array[AttackCommand] = []
	for proposal in attacks:
		_commit_attack(proposal, finished_attacks)
	var finished_shots: Array[ShootCommand] = []
	for proposal in shots:
		_commit_shoot(proposal, finished_shots)
	if player.is_destroyed() and failure_reason.is_empty():
		failure_reason = "机器的全部模块已被摧毁，本次运行失败。"
	var finished_groups := _finish_simultaneous_commands(finished_moves, finished_attacks, finished_shots)
	# 先释放完成动作，再通知订阅者；回调新提交的动作只在下一 tick 执行。
	for command in finished_moves:
		command.finished.emit(command)
		command_finished.emit(command)
	for command in finished_attacks:
		command.finished.emit(command)
		attack_finished.emit(command)
	for command in finished_shots:
		command.finished.emit(command)
		shot_finished.emit(command)
	for group in finished_groups:
		group.finished.emit(group)
	tick_completed.emit(tick_index)
	_stepping = false


## 全部子动作提交后汇总并行结果，短动作结束不能提前释放仍在移动的整组通道。
func _finish_simultaneous_commands(moves: Array[MovementCommand], attacks: Array[AttackCommand], shots: Array[ShootCommand]) -> Array[SimultaneousCommand]:
	var finished: Array[SimultaneousCommand] = []
	for machine_id: String in _simultaneous_commands.keys():
		var group: SimultaneousCommand = _simultaneous_commands[machine_id]
		var failed_child: SimulationCommand = null
		var all_complete := true
		for child in group.children:
			if not child.is_finished():
				all_complete = false
			elif child.state != SimulationCommand.State.COMPLETED and failed_child == null:
				failed_child = child
		if failed_child != null:
			# 当前 tick 的提案已共同提交；此处取消其余长动作，防止失败后继续占用输入。
			for child in group.children:
				if child.is_finished():
					continue
				child.set_terminal(SimulationCommand.State.CANCELLED, "并行动作中有动作失败，剩余动作已取消。")
				if child is MovementCommand:
					moves.append(child)
				elif child is AttackCommand:
					attacks.append(child)
				else:
					shots.append(child)
			group.set_terminal(failed_child.state, failed_child.message)
		elif all_complete:
			group.set_terminal(SimulationCommand.State.COMPLETED, "并行动作全部完成。")
		if group.is_finished():
			_simultaneous_commands.erase(machine_id)
			finished.append(group)
	return finished


## 显式取消先确定全部子动作和回调终态，再通知观察者，避免看到半个取消中的组。
func _cancel_simultaneous(machine_id: String) -> DataResult:
	var group: SimultaneousCommand = _simultaneous_commands[machine_id]
	_simultaneous_commands.erase(machine_id)
	var children := _cancel_simultaneous_children(group)
	var callbacks := _cancel_tick_actions(machine_id, false)
	for command in callbacks:
		_emit_cancelled_action(command)
	for child in children:
		_emit_cancelled_action(child)
	group.finished.emit(group)
	return DataResult.success(group)


## 先原子记录全部待执行子动作的取消状态；调用方完成其他通道清理后统一发出通知。
func _cancel_simultaneous_children(group: SimultaneousCommand) -> Array[SimulationCommand]:
	var cancelled: Array[SimulationCommand] = []
	group.set_terminal(SimulationCommand.State.CANCELLED, "并行动作已取消。")
	for child in group.children:
		if child.is_finished():
			continue
		child.set_terminal(SimulationCommand.State.CANCELLED, "并行动作已取消。")
		cancelled.append(child)
	return cancelled


## 取消回调输入并结束句柄；批量取消时延后通知，保证订阅者看到一致的全部终态。
func _cancel_tick_actions(machine_id: String = "", notify: bool = true) -> Array[SimulationCommand]:
	var cancelled: Array[SimulationCommand] = []
	for key: String in _tick_actions.keys():
		var command: SimulationCommand = _tick_actions[key]
		if machine_id.is_empty() or command.machine_id == machine_id:
			_tick_actions.erase(key)
			command.set_terminal(SimulationCommand.State.CANCELLED, "回调动作已取消。")
			cancelled.append(command)
	if notify:
		for command in cancelled:
			_emit_cancelled_action(command)
	return cancelled


## 统一发出取消通知，世界级具体信号仍保留原有类型接口。
func _emit_cancelled_action(command: SimulationCommand) -> void:
	command.finished.emit(command)
	if command is MovementCommand:
		command_finished.emit(command)
	elif command is AttackCommand:
		attack_finished.emit(command)
	elif command is ShootCommand:
		shot_finished.emit(command)


## 取消所有等待中和执行中的动作；所有通道先清空并记终态，最后统一通知。
func stop() -> void:
	var pending: Array = _commands.values()
	var attacks: Array = _attack_commands.values()
	var shots: Array = _shoot_commands.values()
	var groups: Array = _simultaneous_commands.values()
	_simultaneous_commands.clear()
	_commands.clear()
	_attack_commands.clear()
	_shoot_commands.clear()
	var callbacks := _cancel_tick_actions("", false)
	projectiles.clear()
	var children: Array[SimulationCommand] = []
	for group: SimultaneousCommand in groups:
		children.append_array(_cancel_simultaneous_children(group))
	for command: MovementCommand in pending:
		command.set_terminal(MovementCommand.State.CANCELLED, "移动已取消。")
	for command: AttackCommand in attacks:
		command.set_terminal(SimulationCommand.State.CANCELLED, "攻击已取消。")
	for command: ShootCommand in shots:
		command.set_terminal(SimulationCommand.State.CANCELLED, "射击已取消。")
	for command in callbacks:
		_emit_cancelled_action(command)
	for child in children:
		_emit_cancelled_action(child)
	for group: SimultaneousCommand in groups:
		group.finished.emit(group)
	for command: MovementCommand in pending:
		_emit_cancelled_action(command)
	for command: AttackCommand in attacks:
		_emit_cancelled_action(command)
	for command: ShootCommand in shots:
		_emit_cancelled_action(command)


## 取消指定机器的移动通道，不影响未来同一世界中其他机器的程序。
func cancel_move(machine_id: String) -> DataResult:
	if get_machine(machine_id) == null:
		return DataResult.failure("无法取消不存在机器的动作：%s。" % machine_id)
	if _simultaneous_commands.has(machine_id):
		return _cancel_simultaneous(machine_id)
	if not _commands.has(machine_id):
		return DataResult.success()
	var command: MovementCommand = _commands[machine_id]
	# 先释放通道，再发送信号；订阅者在回调中重新提交的动作不会被误删。
	_commands.erase(machine_id)
	command.set_terminal(MovementCommand.State.CANCELLED, "移动已取消。")
	command.finished.emit(command)
	command_finished.emit(command)
	return DataResult.success(command)


## 只计算单个动作本 tick 的结果，碰撞时停止在最后一个可通行位置。
func _prepare_move(machine: MachineInstance, command: MovementCommand) -> Dictionary:
	if machine == null:
		return {"machine": null, "command": command, "cancelled": true}
	if _crushed.has(machine.id):
		return {"machine": machine, "command": command, "cancelled": false, "displacement": Vector2.ZERO, "distance": 0.0, "blocked": true, "complete": false}
	var speed := machine.get_move_speed(command.module_id)
	if speed <= 0.0 or not is_finite(speed):
		return {"machine": machine, "command": command, "cancelled": true}
	var remaining := maxf(0.0, command.distance - command.traveled_distance)
	var step_distance := minf(remaining, speed * TICK_DURATION)
	# 任意图内直线都会在地图对角线长度内遇到边界；提前截断极大速度，
	# 保留相同碰撞结果，同时防止 JSON 的有限 double 转为 Vector2 后溢出。
	var maximum_sweep := Vector2(document.width, document.height).length() + 1.0
	step_distance = minf(step_distance, maximum_sweep)
	var displacement := command.direction * step_distance
	var fraction := TerrainCollision.sweep_machine(machine, displacement, document, _content)
	for object in objects:
		if not object.is_blocking(tick_index):
			continue
		for module in machine.modules:
			if module.available:
				fraction = minf(fraction, TerrainCollision.sweep_obstacle(module.get_world_rect(machine.position), displacement, object.definition.rect))
	return {
		"machine": machine,
		"command": command,
		"cancelled": false,
		"displacement": displacement * fraction,
		"distance": step_distance * fraction,
		"blocked": fraction < 1.0,
		"complete": step_distance >= remaining and fraction >= 1.0,
	}


## 对假定参考位置只读扫描真实占地与动态障碍，供可信控制器寻找可行路径，不修改机器。
func get_movement_fraction(machine: MachineInstance, origin: Vector2, displacement: Vector2) -> float:
	if machine == null or not origin.is_finite() or not displacement.is_finite():
		return 0.0
	var fraction := 1.0
	for module in machine.modules:
		if not module.available:
			continue
		var rect := module.get_world_rect(origin)
		if not TerrainCollision.is_rect_supported(rect, document, _content):
			return 0.0
		fraction = minf(fraction, TerrainCollision._sweep_rect(rect, displacement, document, _content))
		for object in objects:
			if object.is_blocking(tick_index):
				fraction = minf(fraction, TerrainCollision.sweep_obstacle(rect, displacement, object.definition.rect))
	return fraction


## 提交位置及动作状态；未完成动作继续占有机器的移动通道。
func _commit_move(proposal: Dictionary, finished_commands: Array[MovementCommand]) -> void:
	var command: MovementCommand = proposal["command"]
	if proposal["cancelled"]:
		command.set_terminal(MovementCommand.State.CANCELLED, "机器或移动能力已不可用。")
	else:
		var machine: MachineInstance = proposal["machine"]
		machine.position += proposal["displacement"]
		command.traveled_distance += float(proposal["distance"])
		command.state = MovementCommand.State.RUNNING
		if proposal["blocked"]:
			command.set_terminal(MovementCommand.State.BLOCKED, "移动被 void、地图边界、地块或关卡障碍物阻挡。")
		elif proposal["complete"]:
			command.traveled_distance = command.distance
			command.set_terminal(MovementCommand.State.COMPLETED, "移动完成。")
	if command.is_finished():
		_commands.erase(command.machine_id)
		finished_commands.append(command)


## GDScript 会把 bool 隐式转换为数字，此处在公开命令边界明确拒绝。
static func _is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## 查找运行对象；目标判定和画布只读取本次世界状态。
func get_object(object_id: String) -> WorldObject:
	for object in objects:
		if object.definition.id == object_id:
			return object
	return null


## 确认实际模块是否有近战能力，不依赖模块内容 ID。
func can_attack(machine: MachineInstance, module_id: String = "") -> bool:
	if machine == null:
		return false
	for module in machine.modules:
		if not module_id.is_empty() and module.id != module_id:
			continue
		if module.available and not module.behavior.get_attack_profile(module).is_empty():
			return true
	return false


## 提交一个消耗一 tick 的全机近战动作，与移动共用机器动作通道。
func request_attack(machine_id: String, angle: Variant, module_id: String = "") -> DataResult:
	if not _is_finite_number(angle):
		return DataResult.failure("attack 的角度必须是有限数字。")
	var machine := get_machine(machine_id)
	var selected := _validate_module_action(machine, "attack", module_id)
	if not selected.is_ok():
		return selected
	if _commands.has(machine_id) or _attack_commands.has(machine_id) or _shoot_commands.has(machine_id) or _simultaneous_commands.has(machine_id):
		return DataResult.failure("机器仍有动作正在执行，请等待完成或取消。")
	var command := AttackCommand.new()
	command.machine_id = machine_id
	command.module_id = module_id
	var radians := deg_to_rad(fposmod(float(angle), 360.0))
	command.direction = Vector2(cos(radians), -sin(radians))
	_attack_commands[machine_id] = command
	return DataResult.success(command)


## 取消解释器所属机器的任意动作，保留旧 cancel_move 供只管理移动的调用方使用。
func cancel_command(machine_id: String) -> DataResult:
	if _simultaneous_commands.has(machine_id):
		return _cancel_simultaneous(machine_id)
	_cancel_tick_actions(machine_id)
	if _shoot_commands.has(machine_id):
		var shot: ShootCommand = _shoot_commands[machine_id]
		_shoot_commands.erase(machine_id)
		shot.set_terminal(SimulationCommand.State.CANCELLED, "射击已取消。")
		shot.finished.emit(shot)
		shot_finished.emit(shot)
		return DataResult.success(shot)
	if not _attack_commands.has(machine_id):
		return cancel_move(machine_id)
	var command: AttackCommand = _attack_commands[machine_id]
	_attack_commands.erase(machine_id)
	command.set_terminal(SimulationCommand.State.CANCELLED, "攻击已取消。")
	command.finished.emit(command)
	attack_finished.emit(command)
	return DataResult.success(command)


## 检查真实模块与当前阻挡对象的正面积交叠；边缘接触不触发压住判定。
func _overlaps_object(machine: MachineInstance) -> bool:
	for object in objects:
		if not object.is_blocking(tick_index):
			continue
		for module in machine.modules:
			if module.available:
				var overlap := module.get_world_rect(machine.position).intersection(object.definition.rect)
				if overlap.size.x > TerrainCollision.EPSILON and overlap.size.y > TerrainCollision.EPSILON:
					return true
	return false


## 每个近战模块只选择射线上最近的单个实体，模块排布决定先受击的部件。
func _prepare_attack(machine: MachineInstance, command: AttackCommand) -> Dictionary:
	var hits: Array[Dictionary] = []
	var traces: Array[Dictionary] = []
	if machine == null or _crushed.has(command.machine_id) or not can_attack(machine, command.module_id):
		return {"command": command, "cancelled": true, "hits": hits, "traces": traces}
	for module in machine.modules:
		if not command.module_id.is_empty() and module.id != command.module_id:
			continue
		var profile := module.behavior.get_attack_profile(module) if module.available else {}
		if profile.is_empty() or tick_index < module.next_attack_tick:
			continue
		module.next_attack_tick = tick_index + int(profile.get("cooldown_ticks", 1))
		var origin := machine.position + module.local_position
		var target := _ray_target(origin, command.direction, float(profile.range), machine.id)
		var endpoint := origin + command.direction * float(target.distance)
		# 原始射线固定在共同读取的 tick 起始状态；显示附着只记录明确的发射与命中实例。
		var trace := {"from": origin, "to": endpoint, "source_machine": machine,
			"source_module_id": module.id, "source_offset": module.local_position}
		if target.has("module"):
			var target_machine: MachineInstance = target.machine
			trace.target_machine = target_machine
			trace.target_module = target.module
			trace.target_offset = endpoint - target_machine.position
		traces.append(trace)
		var hit := _target_damage(target, float(profile.damage))
		if not hit.is_empty():
			hits.append(hit)
	return {"command": command, "cancelled": false, "hits": hits, "traces": traces}


## 伤害已经统一提交，此处仅记录命中反馈；冷却中调用同样完成且不制造命中。
func _commit_attack(proposal: Dictionary, finished: Array[AttackCommand]) -> void:
	var command: AttackCommand = proposal.command
	var controller: Dictionary = _enemy_controllers.get(command.machine_id, {})
	if controller.has("lunge") and controller.lunge.commit_attack(proposal, player, tick_index) and failure_reason.is_empty():
		failure_reason = "被敌人的突袭击中，本次运行失败。"
	if proposal.cancelled:
		command.set_terminal(SimulationCommand.State.CANCELLED, "机器或近战能力已不可用。")
	else:
		command.hit_count = proposal.hits.size()
		for trace: Dictionary in proposal.traces:
			attack_traces.append(_attack_display_trace(trace))
			# 射线只会选中此前可用的模块；记录当 tick 的真实毁坏，供下一 tick 才报错的失败页面解释原因。
			if trace.get("target_machine") == player and trace.has("target_module") and not trace.target_module.available:
				if _player_destroyed_module_tick != tick_index:
					_player_destroyed_module_traces.clear()
					_player_destroyed_module_tick = tick_index
				_player_destroyed_module_traces.append(trace)
		command.set_terminal(SimulationCommand.State.COMPLETED, "攻击命中。" if command.hit_count > 0 else "攻击未命中或模块正在冷却。")
	if _attack_commands.get(command.machine_id) == command:
		_attack_commands.erase(command.machine_id)
	finished.append(command)


## 移动与伤害提交后附着到原命中部位；死亡模块仍保留接触点，静态或落空终点不随发射者平移。
func _attack_display_trace(trace: Dictionary) -> Dictionary:
	var source_machine: MachineInstance = trace.source_machine
	var display_to: Vector2 = trace.to
	if trace.has("target_machine"):
		var target_machine: MachineInstance = trace.target_machine
		display_to = target_machine.position + trace.target_offset
	return {"from": trace.from, "to": trace.to,
		"display_from": source_machine.position + trace.source_offset, "display_to": display_to,
		"source_machine_id": source_machine.id, "source_module_id": trace.source_module_id}


## 只读返回当 tick 或上一 tick 的玩家模块毁坏反馈；按当前位置重新附着，过期不替代当前攻击。
func get_player_defeat_attack_traces() -> Array[Dictionary]:
	var traces: Array[Dictionary] = []
	if _player_destroyed_module_tick < 0 or tick_index - _player_destroyed_module_tick > 1:
		return traces
	for trace: Dictionary in _player_destroyed_module_traces:
		# 每次生成只含坐标与标识符的新字典，不向界面暴露实例引用，也不改写原始命中射线或当前 tick 的反馈。
		traces.append(_attack_display_trace(trace))
	return traces


## 近战与弹丸共用攻击遮挡；墙和 void 拦截，明确放行攻击的栅栏不改变移动碰撞。
func _terrain_ray_limit(origin: Vector2, direction: Vector2, reach: float) -> float:
	var limit := reach
	var endpoint := origin + direction * reach
	var first := Vector2i(origin.min(endpoint).floor())
	var last := Vector2i(origin.max(endpoint).floor())
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			if TerrainCollision.is_cell_attack_blocking(Vector2i(x, y), document, _content):
				limit = minf(limit, WorldObject.ray_distance(origin, direction, Rect2(Vector2(x, y), Vector2.ONE), reach))
	return limit


## 查询实际存活模块的射击能力，不依赖 shooting 内容 ID。
func can_shoot(machine: MachineInstance, module_id: String = "") -> bool:
	if machine == null:
		return false
	for module in machine.modules:
		if not module_id.is_empty() and module.id != module_id:
			continue
		if module.available and not module.behavior.get_shoot_profile(module).is_empty():
			return true
	return false


## 只读查询具名射击模块在下一个将执行的 tick 是否就绪，不预留冷却或提交动作。
## 程序判断发生在 step() 之前，射击提案在 tick_index 加一后检查冷却，因此使用 +1。
func is_shoot_ready(machine_id: String, module_id: String) -> DataResult:
	if module_id.is_empty():
		return DataResult.failure("ready 必须指定射击模块名称。")
	var machine := get_machine(machine_id)
	var selected := _validate_module_action(machine, "shoot", module_id)
	if not selected.is_ok():
		return selected
	return DataResult.success(tick_index + 1 >= machine.get_module(module_id).next_shoot_tick)


## 只读选择测距来源；无名称时必须只有一个可用测距模块，避免多部件读数的歧义。
func validate_distance_source(machine_id: String, module_id: String = "") -> DataResult:
	var machine := get_machine(machine_id)
	if machine == null:
		return DataResult.failure("distance 引用了不存在的机器：%s。" % machine_id)
	if not module_id.is_empty():
		var named := machine.get_module(module_id)
		if named == null:
			return DataResult.failure("命名调用引用了不存在的模块：%s。" % module_id)
		if not named.available:
			return DataResult.failure("模块 %s 已失效，无法执行 distance。" % module_id)
		if named.behavior.get_rangefinder_profile(named).is_empty():
			return DataResult.failure("模块 %s 不具备 distance 能力。" % module_id)
		return DataResult.success(named)
	var selected: ModuleInstance = null
	for module in machine.modules:
		if not module.available or module.behavior.get_rangefinder_profile(module).is_empty():
			continue
		if selected != null:
			return DataResult.failure("distance 检测到多个可用测距模块，请使用模块名称指定来源。")
		selected = module
	if selected == null:
		return DataResult.failure("distance 需要安装可用的测距模块。")
	return DataResult.success(selected)


## 从测距模块的实际中心测量到第一阻挡表面；查询不提交动作、推进时钟或触发信号。
func query_distance(machine_id: String, angle_degrees: Variant, module_id: String = "") -> DataResult:
	if not _is_finite_number(angle_degrees):
		return DataResult.failure("distance 的角度必须是有限数字，不能是布尔值。")
	var selected := validate_distance_source(machine_id, module_id)
	if not selected.is_ok():
		return selected
	var machine := get_machine(machine_id)
	var module: ModuleInstance = selected.value
	var origin := machine.position + module.local_position
	if not origin.is_finite():
		return DataResult.failure("distance 的测距模块位置必须是有限坐标。")
	var direction := _angle_direction(float(angle_degrees))
	var limit := _rangefinder_terrain_distance(origin, direction)
	for object in objects:
		if object.is_blocking(tick_index):
			limit = minf(limit, WorldObject.ray_distance(origin, direction, object.definition.rect, limit))
	for other in machines:
		if other.id == machine_id:
			continue
		for other_module in other.modules:
			if other_module.available:
				limit = minf(limit, WorldObject.ray_distance(origin, direction, other_module.get_world_rect(other.position), limit))
	return DataResult.success(maxf(0.0, limit))


## 只读选择雷达来源；裸调用要求唯一可用部件，命名调用精确校验能力与存活状态。
func validate_radar_source(machine_id: String, module_id: String = "") -> DataResult:
	var machine := get_machine(machine_id)
	if machine == null:
		return DataResult.failure("scan 引用了不存在的机器：%s。" % machine_id)
	if not module_id.is_empty():
		var named := machine.get_module(module_id)
		if named == null:
			return DataResult.failure("命名调用引用了不存在的模块：%s。" % module_id)
		if not named.available:
			return DataResult.failure("模块 %s 已失效，无法执行 scan。" % module_id)
		if named.behavior.get_radar_profile(named).is_empty():
			return DataResult.failure("模块 %s 不具备 scan 能力。" % module_id)
		return DataResult.success(named)
	var selected: ModuleInstance = null
	for module in machine.modules:
		if not module.available or module.behavior.get_radar_profile(module).is_empty():
			continue
		if selected != null:
			return DataResult.failure("scan 检测到多个可用雷达模块，请使用模块名称指定来源。")
		selected = module
	if selected == null:
		return DataResult.failure("scan 需要安装可用的雷达模块。")
	return DataResult.success(selected)


## 返回最近可见敌人的独立扫描快照；无目标返回 null，不提交动作或推进模拟时间。
func query_scan(machine_id: String, module_id: String = "") -> DataResult:
	var selected := validate_radar_source(machine_id, module_id)
	if not selected.is_ok():
		return selected
	var machine := get_machine(machine_id)
	var module: ModuleInstance = selected.value
	var origin := machine.position + module.local_position
	if not origin.is_finite():
		return DataResult.failure("scan 的雷达模块位置必须是有限坐标。")
	var reach := float(module.behavior.get_radar_profile(module).range)
	var nearest: MachineInstance = null
	var nearest_distance := INF
	for other in machines:
		# 当前世界只有玩家与敌方两类：敌方模块不把同阵营的其他敌人当作目标。
		if other == machine or other.is_destroyed() or _crushed.has(other.id):
			continue
		if machine != player and other != player:
			continue
		if not _radar_can_see_position(origin, other.position, reach):
			continue
		var distance := origin.distance_to(other.position)
		if nearest == null or distance < nearest_distance or (distance == nearest_distance and other.id < nearest.id):
			nearest = other
			nearest_distance = distance
	if nearest == null:
		return DataResult.success(null)
	var displacement := nearest.position - origin
	var angle := 0.0 if nearest_distance < 0.000001 else fposmod(rad_to_deg(atan2(-displacement.y, displacement.x)), 360.0)
	return DataResult.success({"enemy_id": nearest.id, "position": nearest.position, "angle": angle, "distance": nearest_distance})


## 有界 DDA 只访问射线穿过的格子；地图边缘直接提供有限上限，不扫描整片包围矩形。
func _rangefinder_terrain_distance(origin: Vector2, direction: Vector2) -> float:
	if origin.x < 0.0 or origin.y < 0.0 or origin.x > document.width or origin.y > document.height:
		return 0.0
	var boundary := Vector2(document.width, document.height).length()
	for axis in 2:
		if direction[axis] > 0.0:
			boundary = minf(boundary, (float(document.width if axis == 0 else document.height) - origin[axis]) / direction[axis])
		elif direction[axis] < 0.0:
			boundary = minf(boundary, -origin[axis] / direction[axis])
	var cell := Vector2i(origin.floor())
	var step_cell := Vector2i(int(signf(direction.x)), int(signf(direction.y)))
	# 累加参数使用双精度 float 数组；Vector2 的单精度在长地图重复累加时会偏离真实表面。
	var delta: Array[float] = [INF, INF]
	var next_crossing: Array[float] = [INF, INF]
	for axis in 2:
		if direction[axis] == 0.0:
			continue
		delta[axis] = absf(1.0 / direction[axis])
		var edge := float(cell[axis] + (1 if step_cell[axis] > 0 else 0))
		next_crossing[axis] = maxf(0.0, (edge - origin[axis]) / direction[axis])
	# 与既有矩形射线一致，沿墙边或角点接触也能测到表面；不让对角线穿过两块墙的接角。
	if _rangefinder_cell_blocked(cell, origin, direction):
		return 0.0
	for unused in document.width + document.height + 4:
		var crossing := minf(next_crossing[0], next_crossing[1])
		if crossing >= boundary:
			return maxf(0.0, boundary)
		var crosses_x := next_crossing[0] <= next_crossing[1] + TerrainCollision.EPSILON
		var crosses_y := next_crossing[1] <= next_crossing[0] + TerrainCollision.EPSILON
		if crosses_x and _rangefinder_cell_blocked(cell + Vector2i(step_cell.x, 0), origin, direction):
			return crossing
		if crosses_y and _rangefinder_cell_blocked(cell + Vector2i(0, step_cell.y), origin, direction):
			return crossing
		if crosses_x:
			cell.x += step_cell.x
			next_crossing[0] += delta[0]
		if crosses_y:
			cell.y += step_cell.y
			next_crossing[1] += delta[1]
		if _rangefinder_cell_blocked(cell, origin, direction):
			return crossing
	return maxf(0.0, boundary)


## 平行射线恰好位于网格线上时，边界两侧的格子都属于被触及的表面。
func _rangefinder_cell_blocked(cell: Vector2i, origin: Vector2, direction: Vector2) -> bool:
	if not TerrainCollision.is_cell_passable(cell, document, _content):
		return true
	var on_vertical_edge := direction.x == 0.0 and absf(origin.x - roundf(origin.x)) <= TerrainCollision.EPSILON
	var on_horizontal_edge := direction.y == 0.0 and absf(origin.y - roundf(origin.y)) <= TerrainCollision.EPSILON
	if on_vertical_edge and not TerrainCollision.is_cell_passable(cell + Vector2i.LEFT, document, _content):
		return true
	if on_horizontal_edge and not TerrainCollision.is_cell_passable(cell + Vector2i.UP, document, _content):
		return true
	return false


## 提交一 tick 射击动作；冷却不导致语法或执行失败。
func request_shoot(machine_id: String, angle: Variant, module_id: String = "") -> DataResult:
	if not _is_finite_number(angle):
		return DataResult.failure("shoot 的角度必须是有限数字。")
	var machine := get_machine(machine_id)
	var selected := _validate_module_action(machine, "shoot", module_id)
	if not selected.is_ok():
		return selected
	if _commands.has(machine_id) or _attack_commands.has(machine_id) or _shoot_commands.has(machine_id) or _simultaneous_commands.has(machine_id):
		return DataResult.failure("机器仍有动作正在执行，请等待完成或取消。")
	var command := ShootCommand.new()
	command.machine_id = machine_id
	command.module_id = module_id
	command.direction = _angle_direction(float(angle))
	_shoot_commands[machine_id] = command
	return DataResult.success(command)


## tick 回调独立于 main 移动；不同命名模块可分别行动，同一实际模块共享冷却。
func request_tick_action(machine_id: String, callee: String, angle: Variant, module_id: String = "") -> DataResult:
	if callee not in ["attack", "shoot"] or not _is_finite_number(angle):
		return DataResult.failure("tick 仅支持有限角度的 attack 或 shoot。")
	var machine := get_machine(machine_id)
	var selected := _validate_module_action(machine, callee, module_id)
	if not selected.is_ok():
		return selected
	var key := machine_id + ":" + callee + ":" + module_id
	if _tick_actions.has(key):
		return DataResult.success(_tick_actions[key])
	var command: SimulationCommand = AttackCommand.new() if callee == "attack" else ShootCommand.new()
	command.machine_id = machine_id
	command.module_id = module_id
	command.direction = _angle_direction(float(angle))
	_tick_actions[key] = command
	return DataResult.success(command)


## 解释器结束主程序后可据此等候最后一发弹丸落定。
func has_pending_projectiles(machine_id: String) -> bool:
	for projectile in projectiles:
		if projectile.owner_id == machine_id:
			return true
	return false


## 固定方向清除正交角度的浮点尾数，保持细小模块的命中稳定。
static func _angle_direction(angle: float) -> Vector2:
	var radians := deg_to_rad(fposmod(angle, 360.0))
	var direction := Vector2(cos(radians), -sin(radians))
	if absf(direction.x) < 0.0000001:
		direction.x = 0.0
	if absf(direction.y) < 0.0000001:
		direction.y = 0.0
	return direction


## 在伤害提交前创建全部弹丸，射击方同 tick 被摧毁也不撤回已发出的攻击。
func _prepare_shoot(machine: MachineInstance, command: ShootCommand) -> Dictionary:
	var spawned: Array[ProjectileInstance] = []
	if machine == null or _crushed.has(command.machine_id) or not can_shoot(machine, command.module_id):
		return {"command": command, "cancelled": true, "projectiles": spawned}
	for module in machine.modules:
		if not command.module_id.is_empty() and module.id != command.module_id:
			continue
		var profile := module.behavior.get_shoot_profile(module) if module.available else {}
		if profile.is_empty() or tick_index < module.next_shoot_tick:
			continue
		module.next_shoot_tick = tick_index + int(profile.cooldown_ticks)
		spawned.append(ProjectileInstance.create(machine, module, command.direction, profile))
	return {"command": command, "cancelled": false, "projectiles": spawned}


## 射击提交只完成动作句柄，弹丸已经加入本 tick 统一的碰撞与伤害计算。
func _commit_shoot(proposal: Dictionary, finished: Array[ShootCommand]) -> void:
	var command: ShootCommand = proposal.command
	if proposal.cancelled:
		command.set_terminal(SimulationCommand.State.CANCELLED, "机器或射击能力已不可用。")
	else:
		command.shot_count = proposal.projectiles.size()
		command.set_terminal(SimulationCommand.State.COMPLETED, "射击完成。" if command.shot_count > 0 else "射击模块正在冷却，本次调用无效果。")
	if _shoot_commands.get(command.machine_id) == command:
		_shoot_commands.erase(command.machine_id)
	finished.append(command)


## 对固定敌人只执行可信的接近与攻击状态机，移动能力损坏后仍保留近战部件的行动。
func _prepare_enemy_actions() -> void:
	var ids: Array = _enemy_controllers.keys()
	ids.sort()
	for machine_id: String in ids:
		var machine := get_machine(machine_id)
		if machine == null or machine.is_destroyed() or _crushed.has(machine_id):
			continue
		var controller: Dictionary = _enemy_controllers[machine_id]
		if controller.behavior == EnemyDefinition.AUTO_CHASE_ATTACK:
			controller.automatic.prepare(self, machine)
			continue
		if controller.behavior == EnemyDefinition.RADAR_LUNGE:
			controller.lunge.prepare(self, machine)
			continue
		if controller.behavior == EnemyDefinition.RANDOM_WANDER:
			controller.wander.prepare(self, machine)
			continue
		if controller.behavior == EnemyDefinition.ALARM_GUARD:
			# 守卫在警报前静止；警报后的处决由统一提交阶段处理，无须伪造攻击距离。
			continue
		var properties: Dictionary = controller.properties
		if controller.behavior == EnemyDefinition.ADVANCE_ATTACK:
			# 每次只提交本 tick 的真实路程；完成或碰墙后释放通道，下一 tick 再尝试。
			# 不积压长动作，驱动失效或地形阻挡也不会阻止独立近战通道出手。
			var speed := machine.get_move_speed()
			if not _commands.has(machine_id) and is_finite(speed) and speed > 0.0:
				request_move(machine_id, properties.move_angle, speed * TICK_DURATION)
			if can_attack(machine):
				request_tick_action(machine_id, "attack", properties.attack_angle)
			continue
		if controller.phase == "approach":
			if not controller.started:
				controller.started = true
				var result := request_move(machine_id, properties.move_angle, properties.move_distance)
				if result.is_ok():
					continue
			if _commands.has(machine_id) and machine.get_move_speed() > 0.0:
				continue
			controller.phase = "attack"
		# 移动取消发生在后续提交阶段；回调通道让残存的近战能力本 tick 即可正常出手。
		if can_attack(machine):
			request_tick_action(machine_id, "attack", properties.attack_angle)


## 雷达使用自身模块中心与配置范围，敌方锁定和玩家扫描遵守同一遮挡语义。
func radar_detects_player(machine_id: String, module_id: String) -> bool:
	var machine := get_machine(machine_id)
	if machine == null or player == null or player.is_destroyed():
		return false
	var module := machine.get_module(module_id)
	if module == null or not module.available:
		return false
	var profile := module.behavior.get_radar_profile(module)
	if profile.is_empty():
		return false
	return _radar_can_see_position(machine.position + module.local_position, player.position, float(profile.range))


## 以实际雷达中心到目标参考点作有界线段查询；仅 radar_block 属性遮挡，不更改世界。
func _radar_can_see_position(origin: Vector2, target: Vector2, maximum_range: float) -> bool:
	if not origin.is_finite() or not target.is_finite() or not is_finite(maximum_range) or maximum_range <= 0.0:
		return false
	var displacement := target - origin
	var reach := displacement.length()
	if not is_finite(reach) or reach > maximum_range:
		return false
	if reach < 0.000001:
		return true
	var direction := displacement / reach
	# 只检查线段包围格及贴边格，保留恰好沿格线的遮挡；避免遍历整张长廊。
	var first := (Vector2i(origin.min(target).floor()) - Vector2i.ONE).max(Vector2i.ZERO)
	var last := Vector2i(origin.max(target).floor()).min(Vector2i(document.width - 1, document.height - 1))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var cell := Vector2i(x, y)
			var tile := _content.get_tile(document.get_tile_id(cell))
			if tile != null and tile.radar_block:
				var hit := WorldObject.ray_distance(origin, direction, Rect2(Vector2(cell), Vector2.ONE), reach)
				if is_finite(hit) and hit < reach:
					return false
	return true


## 公开固定突袭的只读状态，胜负与界面读取同一世界计数，不按经过时间猜测躲避次数。
func get_enemy_attack_status(machine_id: String) -> Dictionary:
	var controller: Dictionary = _enemy_controllers.get(machine_id, {})
	return controller.lunge.snapshot() if controller.has("lunge") else {}


## 返回分波进度；旧地图没有分波时为空，剩余计数包含全部尚未激活的敌人。
func get_enemy_wave_status() -> Dictionary:
	return _enemy_waves.snapshot() if _enemy_waves != null else {}


## 查找地形、关卡对象和其他机器的最近命中；己方模块不会挡住自己的射线。
func _ray_target(origin: Vector2, direction: Vector2, reach: float, owner_id: String) -> Dictionary:
	var target := _terrain_target(origin, direction, reach)
	var limit := float(target.distance)
	for object in objects:
		if not object.is_blocking(tick_index):
			continue
		var distance := WorldObject.ray_distance(origin, direction, object.definition.rect, reach)
		if is_finite(distance) and distance <= limit:
			limit = distance
			target = {"distance": distance, "object": object}
	for machine in machines:
		if machine.id == owner_id:
			continue
		for module in machine.modules:
			if not module.available:
				continue
			var distance := WorldObject.ray_distance(origin, direction, module.get_world_rect(machine.position), reach)
			if is_finite(distance) and (distance < limit or (distance <= limit and not target.get("blocked", false) and not target.has("object") and not target.has("module"))):
				limit = distance
				target = {"distance": distance, "module": module, "machine": machine}
	return target


## 仅可破坏对象和模块会产生伤害；墙壁和闸门只消耗弹丸或挡住近战。
static func _target_damage(target: Dictionary, damage: float) -> Dictionary:
	if target.has("module"):
		return {"module": target.module, "damage": damage}
	if target.has("object") and target.object.definition.kind in ["destructible", "prison_alarm", "paired_alarm"]:
		return {"object": target.object, "damage": damage}
	return {}


## 按真实减速时间扫掠本 tick 弹道；移动模块使用二次运动交点，不能按路程比例近似时间。
func _prepare_projectile(projectile: ProjectileInstance, moves: Array[Dictionary]) -> Dictionary:
	var active_time := minf(TICK_DURATION, projectile.speed / projectile.deceleration)
	var distance := projectile.speed * active_time - 0.5 * projectile.deceleration * active_time * active_time
	var target := _static_projectile_target(projectile.position, projectile.direction, distance)
	var blocked: bool = target.get("blocked", false) or target.has("object")
	var impact_time := active_time
	if blocked:
		var impact_speed := sqrt(maxf(0.0, projectile.speed * projectile.speed - 2.0 * projectile.deceleration * float(target.distance)))
		# 用等价形式避免近距离命中时 v₀ − v 的相消误差。
		impact_time = 2.0 * float(target.distance) / (projectile.speed + impact_speed)
	for machine in machines:
		if machine.id == projectile.owner_id:
			continue
		var velocity := Vector2.ZERO
		for move in moves:
			if move.machine == machine and not move.cancelled:
				velocity = move.displacement / TICK_DURATION
				break
		for module in machine.modules:
			if not module.available:
				continue
			var hit_time := ProjectileCollision.hit_time(projectile, module.get_world_rect(machine.position), velocity, active_time)
			if is_finite(hit_time) and (hit_time < impact_time or (hit_time <= impact_time and not blocked)):
				impact_time = hit_time
				target = {"module": module}
				blocked = true
	var traveled := projectile.speed * impact_time - 0.5 * projectile.deceleration * impact_time * impact_time
	var impact_speed := maxf(0.0, projectile.speed - projectile.deceleration * impact_time)
	var speed := maxf(0.0, projectile.speed - projectile.deceleration * active_time)
	return {"projectile": projectile, "position": projectile.position + projectile.direction * traveled,
		"speed": speed, "alive": not blocked and speed > 0.000001,
		"hit": _target_damage(target, impact_speed * projectile.damage_per_speed) if blocked else {}}


## 弹丸的静态遮挡单独扫描，移动机器在相对运动阶段计算。
func _static_projectile_target(origin: Vector2, direction: Vector2, reach: float) -> Dictionary:
	var target := _terrain_target(origin, direction, reach)
	for object in objects:
		if object.is_blocking(tick_index):
			var distance := WorldObject.ray_distance(origin, direction, object.definition.rect, reach)
			if is_finite(distance) and distance <= float(target.distance):
				target = {"distance": distance, "object": object}
	return target


## 区分射程端点与恰好位于端点的墙，允许最大射程命中而不穿透贴墙目标。
func _terrain_target(origin: Vector2, direction: Vector2, reach: float) -> Dictionary:
	var limit := _terrain_ray_limit(origin, direction, reach + 0.0001)
	return {"distance": minf(reach, limit), "blocked": limit <= reach}


## 对命名调用明确区分不存在、已失效和能力不匹配；广播保留原有能力检查。
func _validate_module_action(machine: MachineInstance, callee: String, module_id: String) -> DataResult:
	if machine == null:
		return DataResult.failure("%s 引用了不存在的机器。" % callee)
	if not module_id.is_empty():
		var module := machine.get_module(module_id)
		if module == null:
			return DataResult.failure("命名调用引用了不存在的模块：%s。" % module_id)
		if not module.available:
			return DataResult.failure("模块 %s 已失效，无法执行 %s。" % [module_id, callee])
	var capable := machine.get_move_speed(module_id) > 0.0 if callee == "move" else (can_attack(machine, module_id) if callee == "attack" else can_shoot(machine, module_id))
	if not capable:
		if not module_id.is_empty():
			return DataResult.failure("模块 %s 不具备 %s 能力。" % [module_id, callee])
		var label := {"move": "移动", "attack": "近战", "shoot": "射击"}
		return DataResult.failure("%s 需要安装可用的%s模块。" % [callee, label[callee]])
	return DataResult.success()


## 警报在统一伤害后判定；守卫仍存活即立即处决，避免利用下一 tick 或移动逃过失败。
func _commit_security(active_alarms: Array[WorldObject]) -> void:
	for alarm in active_alarms:
		if alarm.health > 0.0:
			continue
		var guard := get_machine(alarm.definition.guard_id)
		if guard != null and not guard.is_destroyed():
			alarm.triggered = true
			for module in player.modules:
				module.apply_damage(module.health)
			failure_reason = "警报已触发，守卫仍然存活，机器人被处决。请先摧毁守卫，再处理警报。"
	_update_security_gates()


## 使用 tick 开始时的警戒快照，区分实际移动触发和同 tick 单边摧毁触发。
func _commit_paired_alarms(armed_pairs: Array[WorldObject], player_moved: bool) -> void:
	var reason := ""
	var triggered: Array[WorldObject] = []
	for alarm in armed_pairs:
		var partner := get_object(alarm.definition.partner_id)
		if partner == null:
			continue
		if player_moved:
			reason = "警报已触发：请先解除警报，再移动。"
		elif (alarm.health <= 0.0) != (partner.health <= 0.0):
			reason = "警报已触发：两侧警报器未同时摧毁。"
		else:
			continue
		triggered.append(alarm)
		triggered.append(partner)
	if triggered.is_empty():
		return
	for alarm in triggered:
		alarm.triggered = true
	for module in player.modules:
		module.apply_damage(module.health)
	failure_reason = reason


## 安全门的多个条件必须全部完成；门只依赖可摧毁实体，配置层已拒绝循环引用。
func _update_security_gates() -> void:
	for object in objects:
		if object.definition.kind != "security_gate":
			continue
		var satisfied := true
		# 编辑器关闭敌人时仅免除敌人条件；警报器等其他机关仍需真实完成。
		if are_enemies_enabled():
			for enemy_id in object.definition.required_enemy_ids:
				var enemy := get_machine(enemy_id)
				if enemy == null or not enemy.is_destroyed():
					satisfied = false
		for object_id in object.definition.required_object_ids:
			var target := get_object(object_id)
			if target == null or target.health > 0.0:
				satisfied = false
		object.unlocked = satisfied


## 只读提供残骸显示配置；淡出不删除机器，不参与伤害、扫描或波次完成判断。
func get_enemy_wreck_fade_seconds(machine_id: String) -> float:
	return float(_enemy_controllers.get(machine_id, {}).get("properties", {}).get("wreck_fade_seconds", 0.0))
