class_name MovementModule
extends ModuleBehavior
## 移动行为只提供能力参数；整个机器的位移由模拟世界统一结算。


## 拒绝缺失、非有限或非正速度，避免坏 Mod 配置污染模拟。
func validate_definition(definition: ModuleDefinition) -> DataResult:
	var speed: Variant = definition.properties.get("move_speed")
	if not (speed is float or speed is int):
		return DataResult.failure("模块 %s 的 properties.move_speed 必须是数字。" % definition.id)
	if not is_finite(float(speed)) or float(speed) <= 0.0:
		return DataResult.failure("模块 %s 的 properties.move_speed 必须是有限正数。" % definition.id)
	return DataResult.success()


## 速度来自 JSON；不可用的模块不再为机器贡献移动能力。
func get_move_speed(module: ModuleInstance) -> float:
	if not module.available:
		return 0.0
	return float(module.definition.properties["move_speed"])

