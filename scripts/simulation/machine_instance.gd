class_name MachineInstance
extends RefCounted
## 机器是模块集合与参考位置，不是游戏中的 Core 模块。

var id: String = ""
var position: Vector2 = Vector2.ZERO
var modules: Array[ModuleInstance] = []


## 广播汇总可用移动模块；命名调用仅使用指定驱动的速度，仍带动整台机器。
func get_move_speed(module_id: String = "") -> float:
	var speed := 0.0
	for module in modules:
		if not module_id.is_empty() and module.id != module_id:
			continue
		speed += module.get_move_speed()
	return speed


## 查询命名模块，供未来 DSL 的 module.operation() 调用使用。
func get_module(instance_id: String) -> ModuleInstance:
	for module in modules:
		if module.id == instance_id:
			return module
	return null



## 机器没有隐藏核心；全部模块失效才算彻底摧毁。
func is_destroyed() -> bool:
	for module in modules:
		if module.available:
			return false
	return true
