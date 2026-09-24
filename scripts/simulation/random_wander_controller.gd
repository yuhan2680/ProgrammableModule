class_name RandomWanderController
extends RefCounted
## 独立随机源只决定转向和间隔，位移仍走世界的普通动作、真实速度和完整扫掠。

var _properties: Dictionary
var _random := RandomNumberGenerator.new()
var _angle := 0.0
var _next_turn_tick := 0
var _move: MovementCommand


## 正式重试重新随机；可选种子仅用于导入地图重放和隔离的确定性回归。
static func create(configuration: Dictionary) -> RandomWanderController:
	var controller := RandomWanderController.new()
	controller._properties = configuration.duplicate(true)
	if configuration.has("seed"):
		controller._random.seed = int(configuration.seed)
	else:
		controller._random.randomize()
	return controller


## 到期或碰壁时重新抽取方向，每 tick 至多发起一次短移动，不预排固定巡逻路线。
func prepare(world: SimulationWorld, machine: MachineInstance) -> void:
	if _move != null and not _move.is_finished():
		return
	var blocked := _move != null and _move.state == SimulationCommand.State.BLOCKED
	_move = null
	var speed := machine.get_move_speed()
	if not is_finite(speed) or speed <= 0.0:
		return
	if blocked or world.tick_index >= _next_turn_tick:
		_angle = _random.randf_range(0.0, 360.0)
		_next_turn_tick = world.tick_index + _random.randi_range(int(_properties.turn_min_ticks), int(_properties.turn_max_ticks))
	var result := world.request_move(machine.id, _angle, speed * float(_properties.speed_scale) * SimulationWorld.TICK_DURATION)
	if result.is_ok():
		_move = result.value
