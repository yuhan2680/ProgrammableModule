class_name EnemyDefinition
extends RefCounted
## 只有明确注册的固定行为会运行；未知敌人字段继续作为地图元数据保留。

const BEHAVIOR := "approach_attack"
const ALARM_GUARD := "alarm_guard"
const ADVANCE_ATTACK := "advance_attack"
const RADAR_LUNGE := "radar_lunge"
const RANDOM_WANDER := "random_wander"
const WAVE_APPROACH_ATTACK := "wave_approach_attack"
const AUTO_CHASE_ATTACK := "auto_chase_attack"
const BEHAVIORS := [BEHAVIOR, ALARM_GUARD, ADVANCE_ATTACK, RADAR_LUNGE, RANDOM_WANDER, WAVE_APPROACH_ATTACK, AUTO_CHASE_ATTACK]


## 仅运行注册过的可信行为；持续推进使用方向，不要求有限的总路程。
static func validate(entry: Dictionary, content: ContentRegistry = null) -> DataResult:
	if entry.get("behavior") not in BEHAVIORS:
		return DataResult.success()
	if not DataValidation.is_id(entry.get("id")) or entry.id == "player":
		return DataResult.failure("运行敌人需要有效且非 player 的 id。")
	if not entry.has("modules"):
		return DataResult.failure("运行敌人需要 modules 装配。")
	var properties: Variant = entry.get("properties", {})
	if not properties is Dictionary:
		return DataResult.failure("运行敌人 properties 必须是对象。")
	if entry.behavior == AUTO_CHASE_ATTACK:
		return _validate_module_health(entry, properties.get("module_health", {}))
	if entry.behavior == WAVE_APPROACH_ATTACK:
		return _validate_wave_attack(entry, properties, content)
	if entry.behavior == ALARM_GUARD:
		return DataResult.success()
	if entry.behavior == RANDOM_WANDER:
		return _validate_random_wander(entry, properties, content)
	if entry.behavior == RADAR_LUNGE:
		return _validate_radar_lunge(entry, properties, content)
	for field in ["move_angle", "attack_angle"]:
		if not DataValidation.is_number(properties.get(field)):
			return DataResult.failure("敌人的 %s 必须是有限数字。" % field)
	if entry.behavior == ADVANCE_ATTACK:
		return _validate_module_health(entry, properties.get("module_health", {}))
	var distance: Variant = properties.get("move_distance")
	if not DataValidation.is_number(distance) or float(distance) < 0.0 or float(distance) > 512.0:
		return DataResult.failure("敌人 move_distance 必须为 0..512 的有限数字。")
	return DataResult.success()


## 固定突袭仅引用真实近战与雷达实例，使用有界准备路程和模拟恢复时间。
static func _validate_radar_lunge(entry: Dictionary, properties: Dictionary, content: ContentRegistry) -> DataResult:
	if not entry.modules is Array:
		return DataResult.failure("雷达突袭敌人需要 modules 数组。")
	var modules := {}
	var has_drive := content == null
	for module: Variant in entry.modules:
		if module is Dictionary and DataValidation.is_id(module.get("id")):
			modules[module.id] = module
			if content != null and module.get("module_id") is String:
				var definition := content.get_module(module.module_id)
				has_drive = has_drive or (definition != null and definition.behavior == "MovementModule")
	for field: String in ["attack_module_id", "radar_module_id"]:
		var id: Variant = properties.get(field)
		if not DataValidation.is_id(id) or not modules.has(id):
			return DataResult.failure("雷达突袭敌人的 %s 必须引用自身已有模块。" % field)
		if content != null:
			var definition := content.get_module(str(modules[id].get("module_id", "")))
			var expected := "MeleeModule" if field == "attack_module_id" else "RadarModule"
			if definition == null or definition.behavior != expected:
				return DataResult.failure("雷达突袭敌人的 %s 必须绑定 %s 能力。" % [field, expected])
	if properties.attack_module_id == properties.radar_module_id or not has_drive:
		return DataResult.failure("雷达突袭敌人需要独立的移动、近战和雷达模块。")
	if not DataValidation.is_number(properties.get("attack_angle")):
		return DataResult.failure("雷达突袭敌人的 attack_angle 必须是有限数字。")
	for field: String in ["stand_off", "approach_distance"]:
		var value: Variant = properties.get(field)
		if not DataValidation.is_number(value) or float(value) < 0.5 or float(value) > 32.0:
			return DataResult.failure("雷达突袭敌人的 %s 必须为 0.5..32 的有限数字。" % field)
	if not DataValidation.is_integer(properties.get("recovery_ticks"), 1, 600):
		return DataResult.failure("雷达突袭敌人的 recovery_ticks 必须为 1..600 的整数。")
	return DataResult.success()


## 已注册行为可覆盖已有实例耐久；限制只作用于敌人实例，不修改共享模块定义。
static func _validate_module_health(entry: Dictionary, values: Variant) -> DataResult:
	if not values is Dictionary or values.size() > 256:
		return DataResult.failure("敌人 module_health 必须为最多 256 项的对象。")
	var module_ids: Dictionary = {}
	if not entry.modules is Array:
		return DataResult.failure("运行敌人 modules 必须为数组。")
	for module: Variant in entry.modules:
		if module is Dictionary and module.get("id") is String:
			module_ids[module.id] = true
	for module_id: Variant in values:
		if not module_id is String or not module_ids.has(module_id):
			return DataResult.failure("敌人 module_health 引用了不存在的模块实例：%s。" % module_id)
		var health: Variant = values[module_id]
		if not DataValidation.is_number(health) or float(health) < 0.01 or float(health) > 1000000.0:
			return DataResult.failure("敌人 module_health.%s 必须为 0.01..1000000 的有限数字。" % module_id)
	return DataResult.success()


## 随机游走仅允许有界转向时间、速度比例和可复现实验种子，耐久仍属于敌方实例。
static func _validate_random_wander(entry: Dictionary, properties: Dictionary, content: ContentRegistry) -> DataResult:
	var health := _validate_module_health(entry, properties.get("module_health", {}))
	if not health.is_ok():
		return health
	for field: String in ["turn_min_ticks", "turn_max_ticks"]:
		if not DataValidation.is_integer(properties.get(field), 1, 600):
			return DataResult.failure("游走敌人的 %s 必须为 1..600 的整数。" % field)
	if properties.turn_min_ticks > properties.turn_max_ticks:
		return DataResult.failure("游走敌人的最短转向间隔不能超过最长间隔。")
	if not DataValidation.is_number(properties.get("speed_scale")) or float(properties.speed_scale) <= 0.0 or float(properties.speed_scale) > 1.0:
		return DataResult.failure("游走敌人的 speed_scale 必须大于 0 且不超过 1。")
	if properties.has("seed") and not DataValidation.is_integer(properties.seed, 0, 2147483647):
		return DataResult.failure("游走敌人的 seed 必须为 0..2147483647 的整数。")
	if content != null:
		var has_drive := false
		for module: Variant in entry.modules:
			if not module is Dictionary:
				return DataResult.failure("运行敌人的模块必须为对象。")
			var definition := content.get_module(str(module.get("module_id", "")))
			has_drive = has_drive or (definition != null and definition.behavior == "MovementModule")
		if not has_drive:
			return DataResult.failure("游走敌人至少需要一个移动模块。")
	return DataResult.success()


## 分波敌人沿有限真实路径接近再攻击；波次序号和等待只使用逻辑 tick。
static func _validate_wave_attack(entry: Dictionary, properties: Dictionary, content: ContentRegistry) -> DataResult:
	var health := _validate_module_health(entry, properties.get("module_health", {}))
	if not health.is_ok():
		return health
	if not DataValidation.is_integer(properties.get("wave_order"), 1, 64):
		return DataResult.failure("分波敌人的 wave_order 必须为 1..64 的整数。")
	if not DataValidation.is_integer(properties.get("spawn_delay_ticks"), 0, 600):
		return DataResult.failure("分波敌人的 spawn_delay_ticks 必须为 0..600 的整数。")
	for field: String in ["move_angle", "attack_angle"]:
		if not DataValidation.is_number(properties.get(field)):
			return DataResult.failure("分波敌人的 %s 必须是有限数字。" % field)
	if not DataValidation.is_number(properties.get("move_distance")) or float(properties.move_distance) < 0.0 or float(properties.move_distance) > 512.0:
		return DataResult.failure("分波敌人的 move_distance 必须为 0..512 的有限数字。")
	if properties.has("wreck_fade_seconds") and (not DataValidation.is_number(properties.wreck_fade_seconds) or float(properties.wreck_fade_seconds) <= 0.0 or float(properties.wreck_fade_seconds) > 30.0):
		return DataResult.failure("残骸淡出时长必须为 0..30 秒内的正数。")
	if properties.has("activation_region"):
		var region: Variant = properties.activation_region
		if not region is Dictionary or not DataValidation.is_position(region.get("position")) or not DataValidation.is_position(region.get("size")):
			return DataResult.failure("波次触发区域需要有限坐标 position 和 size。")
		if float(region.position.x) < 0.0 or float(region.position.y) < 0.0 or float(region.size.x) <= 0.0 or float(region.size.y) <= 0.0 or float(region.position.x) + float(region.size.x) > 256.0 or float(region.position.y) + float(region.size.y) > 256.0:
			return DataResult.failure("波次触发区域必须为地图范围内的正尺寸矩形。")
	if properties.has("random_spawn"):
		var radial := RandomWaveLayout.validate(entry, properties.random_spawn, content)
		if not radial.is_ok():
			return radial
	if content != null:
		var has_drive := false
		var has_melee := false
		for module: Variant in entry.modules:
			if not module is Dictionary:
				return DataResult.failure("分波敌人的模块必须为对象。")
			var definition := content.get_module(str(module.get("module_id", "")))
			has_drive = has_drive or (definition != null and definition.behavior == "MovementModule")
			has_melee = has_melee or (definition != null and definition.behavior == "MeleeModule")
		if not has_drive or not has_melee:
			return DataResult.failure("分波敌人需要真实移动和近战模块。")
	return DataResult.success()


## 地图中的分波序列必须从 1 连续编号，避免重复、空缺或隐式排序造成漏波。
static func validate_wave_sequence(entries: Array) -> DataResult:
	var orders := {}
	for entry: Variant in entries:
		if not entry is Dictionary or entry.get("behavior") != WAVE_APPROACH_ATTACK:
			continue
		var properties: Variant = entry.get("properties", {})
		if not properties is Dictionary or not DataValidation.is_integer(properties.get("wave_order"), 1, 64):
			return DataResult.failure("分波敌人需要有效的 wave_order。")
		var order := int(properties.wave_order)
		if orders.has(order):
			return DataResult.failure("分波敌人 wave_order 不可重复：%d。" % order)
		orders[order] = true
	for order in range(1, orders.size() + 1):
		if not orders.has(order):
			return DataResult.failure("分波敌人 wave_order 必须从 1 连续编号。")
	return DataResult.success()
