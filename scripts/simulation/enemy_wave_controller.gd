class_name EnemyWaveController
extends RefCounted
## 未激活的敌人只保留独立实例，不进入世界机器表，不参与绘制、查询或伤害。

var _waves: Array[Dictionary] = []
var _spawned := 0
var _completed := 0
var _active_id := ""
var _next_spawn_tick := -1


## 已验证序列按显式波次排序，数组顺序不影响出生次序或存档地图。
static func create(waves: Array[Dictionary]) -> EnemyWaveController:
	var controller := EnemyWaveController.new()
	controller._waves = waves.duplicate()
	controller._waves.sort_custom(_earlier_wave)
	if not controller._waves.is_empty():
		controller._next_spawn_tick = int(controller._waves[0].properties.spawn_delay_ticks)
	return controller


## 比较数据中的有限波次编号，不依赖地图 ID 或机器名称排序。
static func _earlier_wave(first: Dictionary, second: Dictionary) -> bool:
	return int(first.properties.wave_order) < int(second.properties.wave_order)


## 只在 tick 开始激活当前波，真实出生占地受地图和当时机关状态约束。
func prepare(world: SimulationWorld) -> void:
	if not _active_id.is_empty() or _spawned >= _waves.size() or world.tick_index < _next_spawn_tick:
		return
	if not world.failure_reason.is_empty() or world.player.is_destroyed():
		return
	# 空间条件和时间条件同时满足才激活；没有该字段的旧关卡完全沿用原时序。
	var properties: Dictionary = _waves[_spawned].properties
	if properties.has("activation_region"):
		var region: Dictionary = properties.activation_region
		var area := Rect2(Vector2(region.position.x, region.position.y), Vector2(region.size.x, region.size.y))
		if not area.has_point(world.player.position):
			return
	var machine: MachineInstance = _waves[_spawned].machine
	var added := world.add_machine(machine)
	if not added.is_ok():
		world.failure_reason = "敌人出生位置不可用：" + "; ".join(added.errors)
		return
	_active_id = machine.id
	_spawned += 1
	_next_spawn_tick = -1


## 统一伤害提交后才确认整台敌人被毁；残存模块、取消或受阻都不算清波。
func commit(world: SimulationWorld) -> void:
	if _active_id.is_empty():
		return
	var machine := world.get_machine(_active_id)
	if machine == null or not machine.is_destroyed():
		return
	_active_id = ""
	_completed += 1
	if _spawned < _waves.size():
		_next_spawn_tick = world.tick_index + int(_waves[_spawned].properties.spawn_delay_ticks)


## 状态返回独立字典；尚未出场的波次仍计入总数，不能提前判定完成。
func snapshot() -> Dictionary:
	var total := _waves.size()
	return {
		"total": total, "completed": _completed, "defeated": _completed,
		"spawned": _spawned, "current": mini(_completed + 1, total),
		"active_enemy_id": _active_id, "active": not _active_id.is_empty(),
		"pending": total - _spawned, "next_spawn_tick": _next_spawn_tick,
		"all_cleared": total > 0 and _completed == total,
	}
