class_name RadarLungeController
extends RefCounted
## 固定突袭只提交普通世界动作：锁定一次位置、移到准备点、接近、出手、恢复。
## 不瞬移、不持续修正已锁定的位置，学习者可以用测距条件重复避开同一种动作。

var properties: Dictionary
var phase := "tracking"
var dodged := 0
var attempts := 0
var next_scan_tick := 0
var _move: MovementCommand
var _attack: AttackCommand
var _destination := Vector2.ZERO


## 配置使用本控制器独占副本，重试由新的世界重新建立计数及锁定位置。
static func create(configuration: Dictionary) -> RadarLungeController:
	var controller := RadarLungeController.new()
	controller.properties = configuration.duplicate(true)
	return controller


## 每个 tick 至多提交一个动作；抵达一格前方后的下一 tick 立即攻击，不添加隐藏蓄力。
func prepare(world: SimulationWorld, machine: MachineInstance) -> void:
	var blade := machine.get_module(properties.attack_module_id)
	var radar := machine.get_module(properties.radar_module_id)
	if blade == null or radar == null or not blade.available or not radar.available or machine.get_move_speed() <= 0.0:
		world.cancel_command(machine.id)
		_move = null
		_attack = null
		phase = "tracking"
		return
	if _attack != null:
		# 外部取消不会经过攻击提交，完成的句柄必须释放，才能开始下一轮锁定。
		if _attack.is_finished():
			_attack = null
			_recover(world.tick_index)
		return
	if _move != null:
		if not _move.is_finished():
			return
		var completed := _move.state == SimulationCommand.State.COMPLETED
		_move = null
		if not completed:
			_recover(world.tick_index)
			return
		if phase == "tracking":
			phase = "approach"
			_start_move(world, machine, _destination)
			return
		if phase == "approach":
			if world.tick_index < blade.next_attack_tick:
				return
			phase = "attack"
			var requested := world.request_attack(machine.id, properties.attack_angle, blade.id)
			if requested.is_ok():
				_attack = requested.value
			else:
				_recover(world.tick_index)
			return
	# 攻击模块有较长冷却的导入内容也能在抵达后等待，不误计空调用为成功闪避。
	if phase == "approach":
		if world.tick_index >= blade.next_attack_tick:
			var requested := world.request_attack(machine.id, properties.attack_angle, blade.id)
			if requested.is_ok():
				phase = "attack"
				_attack = requested.value
		return
	if world.tick_index < next_scan_tick:
		return
	if not world.radar_detects_player(machine.id, radar.id):
		phase = "tracking"
		return
	var direction := SimulationWorld._angle_direction(float(properties.attack_angle))
	var locked_position := world.player.position
	_destination = locked_position - direction * float(properties.stand_off) - blade.local_position
	var staging := _destination - direction * float(properties.approach_distance)
	phase = "tracking"
	_start_move(world, machine, staging)


## 位移始终走世界的完整扫掠和驱动能力校验，受阻后恢复而不是隔墙出手。
func _start_move(world: SimulationWorld, machine: MachineInstance, target: Vector2) -> void:
	var delta := target - machine.position
	var angle := rad_to_deg(atan2(-delta.y, delta.x))
	var requested := world.request_move(machine.id, angle, delta.length())
	if requested.is_ok():
		_move = requested.value
	else:
		_recover(world.tick_index)


## 只统计本控制器真实发出的近战；取消或冷却空调用不计分，命中任一玩家部件即失败。
func commit_attack(proposal: Dictionary, player: MachineInstance, tick: int) -> bool:
	if _attack == null or proposal.command != _attack:
		return false
	_attack = null
	var hit_player := false
	if not proposal.cancelled and not proposal.traces.is_empty():
		attempts += 1
		for hit: Dictionary in proposal.hits:
			if hit.has("module") and hit.module in player.modules:
				hit_player = true
		if not hit_player and not player.is_destroyed():
			dodged += 1
	_recover(tick)
	return hit_player


## 恢复只记录逻辑 tick 截止点，暂停会与整个世界一起冻结。
func _recover(tick: int) -> void:
	phase = "recover"
	next_scan_tick = tick + int(properties.recovery_ticks)


## UI 读取副本，不能通过状态药丸修改计数或敌人动作。
func snapshot() -> Dictionary:
	return {"phase": phase, "dodged": dodged, "attempts": attempts, "next_scan_tick": next_scan_tick}
