class_name ModuleBehavior
extends RefCounted
## 模块行为的扩展基类；JSON 只选择已由程序注册的行为，不执行任意脚本。


## 验证该行为独有的配置；新行为可覆盖以提供带字段名的错误。
func validate_definition(_definition: ModuleDefinition) -> DataResult:
	return DataResult.success()


## 提供移动能力的模块覆盖此方法；其他模块默认不贡献速度。
func get_move_speed(_module: ModuleInstance) -> float:
	return 0.0


## 攻击行为覆盖此接口；默认空字典表示没有攻击能力。
func get_attack_profile(_module: ModuleInstance) -> Dictionary:
	return {}



## 射击行为返回初速、减速度、伤害比例与冷却参数，其他行为不产生弹丸。
func get_shoot_profile(_module: ModuleInstance) -> Dictionary:
	return {}


## 测距行为声明只读射线查询能力；空字典表示该部件不能提供距离。
func get_rangefinder_profile(_module: ModuleInstance) -> Dictionary:
	return {}


## 雷达提供范围配置；玩家只读扫描与已注册敌人的目标锁定共用真实部件能力。
func get_radar_profile(_module: ModuleInstance) -> Dictionary:
	return {}
