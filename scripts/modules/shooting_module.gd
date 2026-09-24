class_name ShootingModule
extends ModuleBehavior
## 射击只声明能力，弹丸运动和命中仍统一交给固定 tick 世界。


## 限制射击参数，避免极大数值造成无界射线或不可结束的弹丸。
func validate_definition(definition: ModuleDefinition) -> DataResult:
	for field in ["projectile_speed", "deceleration", "damage_per_speed"]:
		var value: Variant = definition.properties.get(field)
		if not DataValidation.is_number(value) or float(value) < 0.01 or float(value) > 256.0:
			return DataResult.failure("射击模块 %s 的 %s 必须为 0.01..256 的有限数字。" % [definition.id, field])
	if not DataValidation.is_integer(definition.properties.get("cooldown_ticks"), 1, 1000000):
		return DataResult.failure("射击模块 cooldown_ticks 必须为 1..1000000 的整数。")
	return DataResult.success()


## 不可用模块不产生弹丸；调用方取得独立参数副本。
func get_shoot_profile(module: ModuleInstance) -> Dictionary:
	return module.definition.properties.duplicate(true) if module.available else {}
