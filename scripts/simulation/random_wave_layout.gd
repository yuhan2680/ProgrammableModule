class_name RandomWaveLayout
extends RefCounted
## 分波的可选全方向出生布局；仅修改世界实例，不执行地图提供的脚本。


## 限定开放场地内的双模块队列，拒绝非有限数值和无法解释的模块布局。
static func validate(entry: Dictionary, config: Variant, content: ContentRegistry) -> DataResult:
	if not config is Dictionary:
		return DataResult.failure("random_spawn 必须为对象。")
	for key: String in ["center", "body_offset"]:
		var point: Variant = config.get(key)
		if not point is Dictionary or not DataValidation.is_number(point.get("x")) or not DataValidation.is_number(point.get("y")) or absf(float(point.x)) > 512 or absf(float(point.y)) > 512:
			return DataResult.failure("随机出生的 %s 必须为有限坐标。" % key)
	if not DataValidation.is_number(config.get("radius")) or float(config.radius) < 1 or float(config.radius) > 512:
		return DataResult.failure("随机出生半径必须为 1..512。")
	if config.has("seed") and not DataValidation.is_integer(config.seed, 0, 2147483647):
		return DataResult.failure("随机出生测试种子必须为非负整数。")
	if not entry.modules is Array or entry.modules.size() != 2:
		return DataResult.failure("随机分波需要一个移动和一个近战模块。")
	if content != null:
		var kinds: Array[String] = []
		for item: Variant in entry.modules:
			if not item is Dictionary:
				return DataResult.failure("随机分波模块必须为对象。")
			var definition := content.get_module(str(item.get("module_id", "")))
			if definition == null:
				return DataResult.failure("随机分波引用了未知模块。")
			kinds.append(definition.behavior)
		if not "MovementModule" in kinds or not "MeleeModule" in kinds:
			return DataResult.failure("随机分波需要一个移动和一个近战模块。")
	return DataResult.success()


## 从连续角度采样一次；模块沿径向共边排列，真实占地仍由 MachineFactory 校验。
static func apply(machine: MachineInstance, properties: Dictionary, rng: RandomNumberGenerator) -> void:
	var config: Dictionary = properties.random_spawn
	if config.has("seed"):
		# 仅回归/提示验证注入；正式地图不保存种子，不共享玩家随机源。
		rng = RandomNumberGenerator.new()
		rng.seed = int(config.seed) + int(properties.wave_order)
	var angle := rng.randf_range(0.0, 360.0)
	var direction := SimulationWorld._angle_direction(angle)
	machine.position = Vector2(float(config.center.x), float(config.center.y)) + direction * float(config.radius)
	var blade: ModuleInstance
	var drive: ModuleInstance
	for module in machine.modules:
		if module.definition.behavior == "MeleeModule":
			blade = module
		else:
			drive = module
	blade.local_position = Vector2(float(config.body_offset.x), float(config.body_offset.y))
	var half_span := (blade.definition.size + drive.definition.size) * 0.5
	var spacing := minf(half_span.x / absf(direction.x) if absf(direction.x) > 0.000001 else INF, half_span.y / absf(direction.y) if absf(direction.y) > 0.000001 else INF)
	# 极小余量只防止浮点数把共边变成重叠，不扩展模块、射线或弹丸碰撞。
	drive.local_position = blade.local_position + direction * (spacing + 0.00001)
	properties.move_angle = fposmod(angle + 180.0, 360.0)
	properties.attack_angle = properties.move_angle
