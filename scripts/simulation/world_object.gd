class_name WorldObject
extends RefCounted
## 每次运行独立的对象状态；血量和开关状态不回写 JSON 或共享定义。

var definition: MapObjectDefinition
var health: float = 0.0
var triggered: bool = false
var unlocked: bool = false


## 为已验证对象建立独立运行实例。
static func create(data: MapObjectDefinition) -> WorldObject:
	var instance := WorldObject.new()
	instance.definition = data
	instance.health = data.max_health
	return instance


## 闸门在指定 tick 开始前落下，暂停不推进 tick，重建世界自动恢复。
func is_blocking(tick: int) -> bool:
	if definition.kind == "security_gate":
		return not unlocked
	return tick >= definition.close_after_ticks if definition.kind == "timed_gate" else health > 0.0


## 使用射线与矩形的精确交点；返回 INF 表示没有命中，端点命中有效。
static func ray_distance(origin: Vector2, direction: Vector2, rect: Rect2, reach: float) -> float:
	var entry := 0.0
	var exit_distance := reach
	for axis in 2:
		if absf(direction[axis]) < 0.000001:
			if origin[axis] < rect.position[axis] or origin[axis] > rect.end[axis]:
				return INF
			continue
		var first: float = (rect.position[axis] - origin[axis]) / direction[axis]
		var last: float = (rect.end[axis] - origin[axis]) / direction[axis]
		entry = maxf(entry, minf(first, last))
		exit_distance = minf(exit_distance, maxf(first, last))
	if entry > exit_distance + 0.000001:
		return INF
	return entry
