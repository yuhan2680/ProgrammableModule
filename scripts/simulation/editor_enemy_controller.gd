class_name EditorEnemyController
extends RefCounted
## 编辑器生成的可信自动行为：逐模块瞄准存活玩家，移动与攻击共用普通世界命令。
## 不执行 JSON 内脚本；路径只读查询真实模块占地，所有伤害仍由世界统一结算。

const PATH_STEP := 0.5
const MAX_SEARCH_NODES := 384
const STOP_DISTANCE := 0.75
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]

var _move: MovementCommand
var _path: Array[Vector2] = []
var _path_target := Vector2.ZERO
var _next_search_tick := 0


## 只在逻辑 tick 调用，模块损毁立即移除其能力，暂停不会另行推进控制器。
func prepare(world: SimulationWorld, machine: MachineInstance) -> void:
	if world.player == null or world.player.is_destroyed():
		return
	_attack_with_available_modules(world, machine)
	if _move != null and not _move.is_finished():
		return
	_move = null
	var speed := machine.get_move_speed()
	if not is_finite(speed) or speed <= 0.0:
		_path.clear()
		return
	var target := _movement_target(world.player, machine)
	var delta := target - machine.position
	if delta.length() <= STOP_DISTANCE:
		_path.clear()
		return
	var destination := target - delta.normalized() * STOP_DISTANCE
	if world.get_movement_fraction(machine, machine.position, destination - machine.position) >= 1.0:
		_path.clear()
	else:
		if target.distance_to(_path_target) > 1.0:
			_path.clear()
		while not _path.is_empty() and machine.position.distance_to(_path[0]) < 0.0001:
			_path.pop_front()
		if not _path.is_empty() and world.get_movement_fraction(machine, machine.position, _path[0] - machine.position) < 1.0:
			_path.clear()
		if _path.is_empty():
			if world.tick_index < _next_search_tick:
				return
			_path = _find_path(world, machine, target)
			_path_target = target
			_next_search_tick = world.tick_index + 10
		if _path.is_empty():
			return
		destination = _path[0]
	delta = destination - machine.position
	var distance := minf(delta.length(), speed * SimulationWorld.TICK_DURATION)
	if distance <= 0.000001:
		return
	var requested := world.request_move(machine.id, _angle(delta), distance)
	if requested.is_ok():
		_move = requested.value


## 每个真实武器独立对准最近存活部件；射程、冷却、遮挡、弹丸均沿用原规则。
func _attack_with_available_modules(world: SimulationWorld, machine: MachineInstance) -> void:
	for module in machine.modules:
		if not module.available:
			continue
		var origin := machine.position + module.local_position
		var delta := _nearest_player_center(world.player, origin) - origin
		var attack := module.behavior.get_attack_profile(module)
		if not attack.is_empty() and world.tick_index >= module.next_attack_tick and delta.length() <= float(attack.range):
			world.request_tick_action(machine.id, "attack", _angle(delta), module.id)
		var shoot := module.behavior.get_shoot_profile(module)
		if shoot.is_empty() or world.tick_index < module.next_shoot_tick:
			continue
		# 仅在物理弹丸最大可达距离内开火，远处继续靠真实驱动接近。
		var reach := pow(float(shoot.projectile_speed), 2.0) / (2.0 * float(shoot.deceleration))
		if delta.length() <= reach:
			world.request_tick_action(machine.id, "shoot", _angle(delta), module.id)


## 接近位置以最近存活武器为参考，防止长组合的原点已靠近但末端武器永远够不到玩家。
func _movement_target(player: MachineInstance, machine: MachineInstance) -> Vector2:
	var target := _nearest_player_center(player, machine.position)
	var best_distance := INF
	for module in machine.modules:
		if not module.available:
			continue
		if module.behavior.get_attack_profile(module).is_empty() and module.behavior.get_shoot_profile(module).is_empty():
			continue
		var origin := machine.position + module.local_position
		var center := _nearest_player_center(player, origin)
		var distance := origin.distance_squared_to(center)
		if distance < best_distance:
			best_distance = distance
			target = center - module.local_position
	return target


## 目标位置取存活部件的世界中心，已失效的中心模块不会让瞄准留在空处。
func _nearest_player_center(player: MachineInstance, origin: Vector2) -> Vector2:
	var closest := player.position
	var best_distance := INF
	for module in player.modules:
		if not module.available:
			continue
		var center := player.position + module.local_position
		var distance := origin.distance_squared_to(center)
		if distance < best_distance:
			best_distance = distance
			closest = center
	return closest


## 半格四方向 A* 每次最多搜索固定节点数；完全不通时停留并按逻辑秒重试。
func _find_path(world: SimulationWorld, machine: MachineInstance, target: Vector2) -> Array[Vector2]:
	var start := machine.position
	var open: Array[Vector2i] = [Vector2i.ZERO]
	var costs := {Vector2i.ZERO: 0.0}
	var parents := {}
	var closed := {}
	var best := Vector2i.ZERO
	var best_distance := start.distance_to(target)
	var visited := 0
	while not open.is_empty() and visited < MAX_SEARCH_NODES:
		var next_index := 0
		var next_score := INF
		for index in open.size():
			var key := open[index]
			var score := float(costs[key]) + (start + Vector2(key) * PATH_STEP).distance_to(target)
			if score < next_score:
				next_score = score
				next_index = index
		var current: Vector2i = open.pop_at(next_index)
		closed[current] = true
		visited += 1
		var origin := start + Vector2(current) * PATH_STEP
		var distance := origin.distance_to(target)
		if distance < best_distance:
			best_distance = distance
			best = current
		if distance <= STOP_DISTANCE:
			break
		for direction: Vector2i in DIRECTIONS:
			var next := current + direction
			if closed.has(next):
				continue
			var displacement := Vector2(direction) * PATH_STEP
			if world.get_movement_fraction(machine, origin, displacement) < 1.0:
				continue
			var cost := float(costs[current]) + PATH_STEP
			if costs.has(next) and cost >= float(costs[next]):
				continue
			costs[next] = cost
			parents[next] = current
			if next not in open:
				open.append(next)
	var path: Array[Vector2] = []
	while best != Vector2i.ZERO and parents.has(best):
		path.push_front(start + Vector2(best) * PATH_STEP)
		best = parents[best]
	return path


## 世界角度约定为向右零度、向上九十度，不沿用屏幕顺时针角度。
func _angle(delta: Vector2) -> float:
	return rad_to_deg(atan2(-delta.y, delta.x))
