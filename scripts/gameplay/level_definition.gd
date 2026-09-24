class_name LevelDefinition
extends RefCounted
## 关卡规则附加于地图 properties.level；没有终点的普通地图可作为沙盒运行。

const DEFAULT_PROGRAM: String = "main() {\n    // 在这里编写移动指令。\n}\n"

var document: MapDocument
var id: String = ""
var display_name: String = ""
var description: String = ""
var source_path: String = ""
var module_limit: int = 1
# 零仅表示旧地图未覆盖耐久；显式配置必须为正数，运行时继续继承各模块定义。
var player_max_health: float = 0.0
var allowed_modules: PackedStringArray = PackedStringArray()
var has_goal: bool = false
var goal_type: String = ""
var goal_object_id: String = ""
var goal_enemy_id: String = ""
var goal_attack_count: int = 0
var goal_alarm_ids: PackedStringArray = PackedStringArray()
var allow_tick: bool = false
var allow_named_calls: bool = false
var allow_loops: bool = false
var allow_conditionals: bool = false
var allow_simultaneous: bool = false
var allow_distance: bool = false
var allow_functions: bool = false
var allow_variables: bool = false
var allow_radar: bool = false
var allow_radar_events: bool = false
var allow_random: bool = false
var allow_for: bool = false
var max_ticks: int = 0
var completion_mode: String = "goal"
var allowed_calls := PackedStringArray(["move"])
var goal_position: Vector2 = Vector2.ZERO
var goal_radius: float = 0.25
var starter_program: String = DEFAULT_PROGRAM
var order: int = 0


## 从独立地图快照读取关卡规则，严格验证类型和内容引用。
static func from_document(map_document: MapDocument, content: ContentRegistry, path: String = "") -> DataResult:
	var map_result := MapCodec.validate(map_document, content, true)
	if not map_result.is_ok():
		return map_result
	var metadata: Variant = map_document.properties.get("level", {})
	if not metadata is Dictionary:
		return DataResult.failure("properties.level 必须是对象。")
	var level := LevelDefinition.new()
	level.document = map_document.duplicate_document()
	level.id = map_document.id
	level.display_name = map_document.display_name
	level.source_path = path
	var limit: Variant = metadata.get("module_limit", maxi(map_document.player_spawn["modules"].size(), 1))
	if not DataValidation.is_integer(limit, 1, 256):
		return DataResult.failure("关卡 module_limit 必须为 1..256 的整数。")
	level.module_limit = int(limit)
	if metadata.has("player_max_health"):
		var health: Variant = metadata.player_max_health
		if not DataValidation.is_number(health) or float(health) <= 0.0 or float(health) > 1000000000.0:
			return DataResult.failure("关卡 player_max_health 必须为大于 0 且不超过 1000000000 的有限数字。")
		level.player_max_health = float(health)
	var sorting: Variant = metadata.get("order", 0)
	if not DataValidation.is_integer(sorting, -1000000, 1000000):
		return DataResult.failure("关卡 order 必须为 -1000000..1000000 的整数。")
	level.order = int(sorting)
	# tick 是逐关解锁的入口，不能因为注册表新增射击模块就改变前三关语言。
	if not metadata.get("allow_tick", false) is bool:
		return DataResult.failure("关卡 allow_tick 必须是布尔值。")
	level.allow_tick = metadata.get("allow_tick", false)
	if not metadata.get("allow_named_calls", false) is bool:
		return DataResult.failure("关卡 allow_named_calls 必须是布尔值。")
	level.allow_named_calls = metadata.get("allow_named_calls", false)
	# 循环单独逐关解锁；旧地图缺省为关闭，不能随解释器升级提前开放语法。
	if not metadata.get("allow_loops", false) is bool:
		return DataResult.failure("关卡 allow_loops 必须是布尔值。")
	level.allow_loops = metadata.get("allow_loops", false)
	# 条件查询逐关开放；缺省关闭，前六关保留原有教学边界。
	if not metadata.get("allow_conditionals", false) is bool:
		return DataResult.failure("关卡 allow_conditionals 必须是布尔值。")
	level.allow_conditionals = metadata.get("allow_conditionals", false)
	# 并行块仅在明确解锁的关卡开放，旧关卡继续保持原有顺序语义。
	if not metadata.get("allow_simultaneous", false) is bool:
		return DataResult.failure("关卡 allow_simultaneous 必须是布尔值。")
	level.allow_simultaneous = metadata.get("allow_simultaneous", false)
	# 测距与数值表达式显式逐关解锁，旧地图不会因新增模块而扩大语言权限。
	if not metadata.get("allow_distance", false) is bool:
		return DataResult.failure("关卡 allow_distance 必须是布尔值。")
	level.allow_distance = metadata.get("allow_distance", false)
	# 语法使用独立开关，跳过关卡编号不会改变旧关卡权限。
	if not metadata.get("allow_functions", false) is bool:
		return DataResult.failure("关卡 allow_functions 必须是布尔值。")
	level.allow_functions = metadata.get("allow_functions", false)
	if not metadata.get("allow_variables", false) is bool:
		return DataResult.failure("关卡 allow_variables 必须是布尔值。")
	level.allow_variables = metadata.get("allow_variables", false)
	# 玩家雷达查询独立解锁，既有敌方雷达配置不会暗中打开玩家指令。
	if not metadata.get("allow_radar", false) is bool:
		return DataResult.failure("关卡 allow_radar 必须是布尔值。")
	level.allow_radar = metadata.get("allow_radar", false)
	# 事件订阅与主动扫描分别解锁；旧关卡仍需自行调用 scan。
	if not metadata.get("allow_radar_events", false) is bool:
		return DataResult.failure("关卡 allow_radar_events 必须是布尔值。")
	level.allow_radar_events = metadata.get("allow_radar_events", false)
	# 随机函数独立解锁；敌人随机行为不会影响玩家或旧地图的语言权限。
	if not metadata.get("allow_random", false) is bool:
		return DataResult.failure("关卡 allow_random 必须是布尔值。")
	level.allow_random = metadata.get("allow_random", false)
	# 有限循环单独解锁；旧关卡不会因解释器升级而提前开放。
	if not metadata.get("allow_for", false) is bool:
		return DataResult.failure("关卡 allow_for 必须是布尔值。")
	level.allow_for = metadata.get("allow_for", false)
	var timeout: Variant = metadata.get("max_ticks", 0)
	if not DataValidation.is_integer(timeout, 0, 36000):
		return DataResult.failure("关卡 max_ticks 必须为 0..36000 的整数；0 表示不限时。")
	level.max_ticks = int(timeout)
	# 编辑器显式启用限时二选一目标；旧关卡缺省保留原有目标规则。
	var completion: Variant = metadata.get("completion_mode", "goal")
	if not completion is String or completion not in ["goal", "reach_or_clear"]:
		return DataResult.failure("completion_mode 必须为 goal 或 reach_or_clear。")
	level.completion_mode = completion
	if completion == "reach_or_clear" and level.max_ticks == 0:
		return DataResult.failure("限时地图必须设置大于 0 且不超过 3600 秒的时间限制。")
	for field in ["description", "starter_program"]:
		if metadata.has(field) and not DataValidation.is_text(metadata[field]):
			return DataResult.failure("关卡 %s 必须为最多 65536 字符的字符串。" % field)
	level.description = metadata.get("description", "在此地图测试你的装配和程序。")
	level.starter_program = metadata.get("starter_program", DEFAULT_PROGRAM)
	var allowed_result := _read_allowed_modules(metadata, map_document, content)
	if not allowed_result.is_ok():
		return allowed_result
	level.allowed_modules = allowed_result.value
	for module_id in level.allowed_modules:
		if content.get_module(module_id).behavior == "MeleeModule" and not "attack" in level.allowed_calls:
			level.allowed_calls.append("attack")
		if content.get_module(module_id).behavior == "ShootingModule" and not "shoot" in level.allowed_calls:
			level.allowed_calls.append("shoot")
	var goal_result := _read_goal(metadata.get("goal"), level, content)
	if not goal_result.is_ok():
		return goal_result
	return DataResult.success(level)


## 未指定可用模块时沿用原出生装配的类型，避免导入地图意外解锁新能力。
static func _read_allowed_modules(metadata: Dictionary, map_document: MapDocument, content: ContentRegistry) -> DataResult:
	var fallback: Array = []
	for instance: Dictionary in map_document.player_spawn["modules"]:
		if not instance["module_id"] in fallback:
			fallback.append(instance["module_id"])
	var raw_allowed: Variant = metadata.get("allowed_modules", fallback)
	if not raw_allowed is Array or raw_allowed.is_empty() or raw_allowed.size() > 256:
		return DataResult.failure("关卡 allowed_modules 必须包含 1..256 个模块 ID。")
	var allowed := PackedStringArray()
	for module_id in raw_allowed:
		if not DataValidation.is_id(module_id) or content.get_module(module_id) == null:
			return DataResult.failure("关卡 allowed_modules 引用了无效或未知模块。")
		if module_id in allowed:
			return DataResult.failure("关卡 allowed_modules 中存在重复 ID：%s。" % module_id)
		allowed.append(module_id)
	return DataResult.success(allowed)


## 终点区域必须完整落在可行走地形上；省略或 null 表示没有胜负目标。
static func _read_goal(raw_goal: Variant, level: LevelDefinition, content: ContentRegistry) -> DataResult:
	if raw_goal == null:
		return DataResult.success()
	if not raw_goal is Dictionary:
		return DataResult.failure("关卡 goal 必须是对象或 null。")
	var kind: Variant = raw_goal.get("type", "reach_position")
	if kind == "destroy_waves":
		var waves := 0
		for entry: Dictionary in level.document.enemies:
			if entry.get("behavior") == EnemyDefinition.WAVE_APPROACH_ATTACK:
				waves += 1
		if waves == 0:
			return DataResult.failure("分波防守目标需要至少一名已注册的分波敌人。")
		level.has_goal = true
		level.goal_type = "destroy_waves"
		return DataResult.success()
	if kind == "dodge_attacks":
		var enemy_id: Variant = raw_goal.get("enemy_id")
		var attack_count: Variant = raw_goal.get("attack_count")
		if not DataValidation.is_id(enemy_id) or not DataValidation.is_integer(attack_count, 1, 1000):
			return DataResult.failure("躲避目标需要有效的 goal.enemy_id 与 1..1000 的整数 goal.attack_count。")
		for entry: Dictionary in level.document.enemies:
			if entry.get("id") == enemy_id and entry.get("behavior") == EnemyDefinition.RADAR_LUNGE:
				level.has_goal = true
				level.goal_type = "dodge_attacks"
				level.goal_enemy_id = enemy_id
				level.goal_attack_count = int(attack_count)
				return DataResult.success()
		return DataResult.failure("躲避目标必须引用本地图中已注册的 radar_lunge 敌人。")
	if kind == "destroy_enemy":
		var enemy_id: Variant = raw_goal.get("enemy_id")
		if not DataValidation.is_id(enemy_id):
			return DataResult.failure("击毁敌人目标需要有效的 goal.enemy_id。")
		for entry: Dictionary in level.document.enemies:
			if entry.get("id") == enemy_id and entry.get("behavior") in EnemyDefinition.BEHAVIORS:
				level.has_goal = true
				level.goal_type = "destroy_enemy"
				level.goal_enemy_id = enemy_id
				return DataResult.success()
		return DataResult.failure("goal.enemy_id 必须引用本地图中具有已注册行为的敌人。")
	if kind == "destroy_object":
		var target_id: Variant = raw_goal.get("object_id")
		if not DataValidation.is_id(target_id):
			return DataResult.failure("摧毁目标需要有效的 goal.object_id。")
		for entry: Dictionary in level.document.objects:
			if entry.get("id") == target_id and entry.get("type") in ["destructible", "prison_alarm", "paired_alarm"]:
				level.has_goal = true
				level.goal_type = "destroy_object"
				level.goal_object_id = target_id
				return DataResult.success()
		return DataResult.failure("goal.object_id 必须引用本地图的可破坏障碍物。")
	if kind == "escape_prison":
		var prison_result := _read_prison_targets(raw_goal, level)
		if not prison_result.is_ok():
			return prison_result
	elif kind == "escape_alarms":
		var alarms_result := _read_paired_targets(raw_goal, level)
		if not alarms_result.is_ok():
			return alarms_result
	elif kind != "reach_position":
		return DataResult.failure("未知的关卡目标类型：%s。" % str(kind))
	if not DataValidation.is_position(raw_goal.get("position")):
		return DataResult.failure("关卡 goal.position 必须是有限数值坐标。")
	var radius: Variant = raw_goal.get("radius", 0.25)
	if not DataValidation.is_number(radius) or float(radius) <= 0.0 or float(radius) > 0.25:
		return DataResult.failure("关卡 goal.radius 必须为大于 0、最多 0.25 的有限数字。")
	var position_data: Dictionary = raw_goal["position"]
	if float(position_data.x) < 0.0 or float(position_data.y) < 0.0 or float(position_data.x) >= level.document.width or float(position_data.y) >= level.document.height:
		return DataResult.failure("关卡终点必须位于地图内部。")
	var point := Vector2(float(position_data.x), float(position_data.y))
	var extent := Vector2.ONE * float(radius)
	if not TerrainCollision.is_rect_supported(Rect2(point - extent, extent * 2.0), level.document, content):
		return DataResult.failure("关卡终点区域包含 void 或不可通行地块。")
	level.has_goal = true
	level.goal_type = kind
	level.goal_position = point
	level.goal_radius = float(radius)
	return DataResult.success()


## 越狱必须引用同一组警卫和警报器，避免导入地图把无关目标当作安全出口条件。
static func _read_prison_targets(raw_goal: Dictionary, level: LevelDefinition) -> DataResult:
	var enemy_id: Variant = raw_goal.get("enemy_id")
	var object_id: Variant = raw_goal.get("object_id")
	if not DataValidation.is_id(enemy_id) or not DataValidation.is_id(object_id):
		return DataResult.failure("越狱目标需要有效的 goal.enemy_id 和 goal.object_id。")
	var found_guard := false
	var found_alarm := false
	for entry: Dictionary in level.document.enemies:
		if entry.get("id") == enemy_id and entry.get("behavior") == EnemyDefinition.ALARM_GUARD:
			found_guard = true
	for entry: Dictionary in level.document.objects:
		if entry.get("id") == object_id and entry.get("type") == "prison_alarm" and entry.get("properties", {}).get("guard_id") == enemy_id:
			found_alarm = true
	if not found_guard or not found_alarm:
		return DataResult.failure("越狱目标必须引用同一组 alarm_guard 警卫和 prison_alarm 警报器。")
	level.goal_enemy_id = enemy_id
	level.goal_object_id = object_id
	return DataResult.success()


## 双警报越狱必须绑定恰好一对互相关联的警报器，避免目标绕过地图的报警条件。
static func _read_paired_targets(raw_goal: Dictionary, level: LevelDefinition) -> DataResult:
	var ids: Variant = raw_goal.get("alarm_ids")
	if not ids is Array or ids.size() != 2:
		return DataResult.failure("双警报越狱目标需要包含两个警报器 ID 的 goal.alarm_ids。")
	if not DataValidation.is_id(ids[0]) or not DataValidation.is_id(ids[1]) or ids[0] == ids[1]:
		return DataResult.failure("goal.alarm_ids 必须是两个不同的有效 ID。")
	for index in range(2):
		var found := false
		for entry: Dictionary in level.document.objects:
			if entry.get("id") == ids[index] and entry.get("type") == "paired_alarm" and entry.get("properties", {}).get("partner_id") == ids[1 - index]:
				found = true
		if not found:
			return DataResult.failure("goal.alarm_ids 必须引用一对互相关联的 paired_alarm 警报器。")
	level.goal_alarm_ids = PackedStringArray(ids)
	return DataResult.success()
