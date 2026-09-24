class_name RadarModule
extends ModuleBehavior
## 雷达能力来自真实模块，摧毁或停用后不能继续锁定目标。


## 探测范围有明确上限，拒绝非有限数据，避免导入内容制造无界扫描。
func validate_definition(definition: ModuleDefinition) -> DataResult:
	var reach: Variant = definition.properties.get("radar_range")
	if not DataValidation.is_number(reach) or float(reach) <= 0.0 or float(reach) > 512.0:
		return DataResult.failure("雷达模块 radar_range 必须为大于 0、最多 512 的有限数字。")
	return DataResult.success()


## 返回独立能力快照，扫描行为不能改写模块静态配置。
func get_radar_profile(module: ModuleInstance) -> Dictionary:
	return {"range": float(module.definition.properties.radar_range)} if module.available else {}
