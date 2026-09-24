class_name ModuleInstance
extends RefCounted
## 独立的运行时模块。静态定义共享，位置与可用状态属于当前实例。

var id: String = ""
var definition: ModuleDefinition
var behavior: ModuleBehavior
var local_position: Vector2 = Vector2.ZERO
var available: bool = true
var health: float = 1.0
var max_health: float = 1.0
var next_attack_tick: int = 0
var next_shoot_tick: int = 0


## 返回模块的世界占地；local_position 是相对机器参考点的中心偏移。
func get_world_rect(machine_position: Vector2) -> Rect2:
	return Rect2(machine_position + local_position - definition.size * 0.5, definition.size)


## 通过行为查询移动贡献，调用者不需要依赖具体模块 ID。
func get_move_speed() -> float:
	if not available:
		return 0.0
	return behavior.get_move_speed(self)



## 伤害只修改运行实例；模块被摧毁后同时失去能力与实体占地。
func apply_damage(amount: float) -> void:
	if not available:
		return
	health = maxf(0.0, health - amount)
	if health <= 0.000001:
		health = 0.0
		available = false
