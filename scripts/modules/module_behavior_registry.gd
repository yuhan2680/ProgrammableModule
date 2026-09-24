class_name ModuleBehaviorRegistry
extends RefCounted
## 受信任代码注册行为工厂，内容作者使用 script_type 选择行为。

var _scripts: Dictionary = {}


## 建立当前内置行为集合；增加新行为只需在此注册或由启动代码注册。
static func create_default() -> ModuleBehaviorRegistry:
	var registry := ModuleBehaviorRegistry.new()
	registry.register_behavior("MovementModule", preload("res://scripts/modules/movement_module.gd"))
	registry.register_behavior("MeleeModule", preload("res://scripts/modules/melee_module.gd"))
	registry.register_behavior("ShootingModule", preload("res://scripts/modules/shooting_module.gd"))
	registry.register_behavior("RangefinderModule", preload("res://scripts/modules/rangefinder_module.gd"))
	registry.register_behavior("RadarModule", preload("res://scripts/modules/radar_module.gd"))
	return registry


## 注册一个唯一的行为名称，避免覆盖已有 Mod 或内置行为。
func register_behavior(behavior_name: String, behavior_script: GDScript) -> DataResult:
	if behavior_name.is_empty() or behavior_script == null:
		return DataResult.failure("行为名称与脚本不能为空。")
	if _scripts.has(behavior_name):
		return DataResult.failure("行为 %s 已注册，不能重复注册。" % behavior_name)
	if not behavior_script.can_instantiate():
		return DataResult.failure("行为 %s 的脚本不能实例化。" % behavior_name)
	var instance: Variant = behavior_script.new()
	if not instance is ModuleBehavior:
		return DataResult.failure("行为 %s 必须继承 ModuleBehavior。" % behavior_name)
	_scripts[behavior_name] = behavior_script
	return DataResult.success()


## 按定义创建独立行为实例并验证参数；未知行为只返回错误。
func create_behavior(definition: ModuleDefinition) -> DataResult:
	if not _scripts.has(definition.behavior):
		return DataResult.failure("模块 %s 引用了未注册的 script_type：%s。" % [definition.id, definition.behavior])
	var behavior: ModuleBehavior = _scripts[definition.behavior].new()
	var validation := behavior.validate_definition(definition)
	if not validation.is_ok():
		return validation
	return DataResult.success(behavior)
