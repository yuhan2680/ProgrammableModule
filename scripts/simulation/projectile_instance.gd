class_name ProjectileInstance
extends RefCounted
## 纯数据弹丸；伤害等于命中瞬间速度乘以模块定义的伤害比例。

var owner_id: String = ""
var position: Vector2 = Vector2.ZERO
var direction: Vector2 = Vector2.RIGHT
var speed: float = 0.0
var deceleration: float = 0.0
var damage_per_speed: float = 0.0


## 从实际射击模块中心创建弹丸，不引用或修改共享静态定义。
static func create(machine: MachineInstance, module: ModuleInstance, aim: Vector2, profile: Dictionary) -> ProjectileInstance:
	var projectile := ProjectileInstance.new()
	projectile.owner_id = machine.id
	projectile.position = machine.position + module.local_position
	projectile.direction = aim
	projectile.speed = float(profile.projectile_speed)
	projectile.deceleration = float(profile.deceleration)
	projectile.damage_per_speed = float(profile.damage_per_speed)
	return projectile
