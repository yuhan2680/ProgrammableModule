class_name MeleeModule
extends ModuleBehavior
## 近战行为只提供经过验证的能力参数，命中和伤害由世界统一结算。


## 限制射程和伤害范围，拒绝布尔值与非有限数，避免配置污染碰撞计算。
func validate_definition(definition: ModuleDefinition) -> DataResult:
	for field in ["range", "damage"]:
		var value: Variant = definition.properties.get(field)
		var maximum := 256.0 if field == "range" else 1000000000.0
		if not DataValidation.is_number(value) or float(value) <= 0.0 or float(value) > maximum:
			return DataResult.failure("模块 %s 的 properties.%s 必须是大于 0、最多 %s 的有限数字。" % [definition.id, field, maximum])
	if not DataValidation.is_integer(definition.properties.get("cooldown_ticks", 1), 1, 1000000):
		return DataResult.failure("近战模块 cooldown_ticks 必须为 1..1000000 的整数。")
	return DataResult.success()


## 返回静态攻击参数的副本；不可用模块不贡献攻击能力。
func get_attack_profile(module: ModuleInstance) -> Dictionary:
	return module.definition.properties.duplicate(true) if module.available else {}
