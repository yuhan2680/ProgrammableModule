class_name MapValidation
extends RefCounted
## 地图格式检查不依赖场景树；地形与机器完整占地的关系由运行时检查。

const MAX_DIMENSION: int = 256
const MAX_MODULES: int = 256
const MAX_ENTITIES: int = 1024
const MAX_DIALOGUE: int = 4096


## 校验原始 JSON 地图；成功后调用方可以安全地构造文档。
static func check(data: Dictionary, registry: ContentRegistry, require_spawn: bool) -> DataResult:
	if registry == null:
		return DataResult.failure("地图校验需要内容注册表")
	if not DataValidation.is_json_value(data):
		return DataResult.failure("地图包含非 JSON 值、非有限数字或超过 32 层的嵌套")
	if not DataValidation.is_integer(data.get("format_version"), 1, 1):
		return DataResult.failure("仅支持地图 format_version: 1")
	if not DataValidation.is_id(data.get("id")):
		return DataResult.failure("地图 id 无效")
	if not DataValidation.is_text(data.get("name"), false):
		return DataResult.failure("地图 name 必须是非空字符串")
	for axis in ["width", "height"]:
		if not DataValidation.is_integer(data.get(axis), 1, MAX_DIMENSION):
			return DataResult.failure("地图 %s 必须为 1..256 的整数" % axis)
	if not data.get("properties", {}) is Dictionary:
		return DataResult.failure("地图 properties 必须是对象")
	var level: Variant = data.get("properties", {}).get("level", {})
	if level is Dictionary and level.has("player_max_health"):
		# 即使草稿还没有出生点，也不能把无效耐久写盘；其他关卡扩展保持原有校验边界。
		var health: Variant = level.player_max_health
		if not DataValidation.is_number(health) or float(health) <= 0.0 or float(health) > 1000000000.0:
			return DataResult.failure("关卡 player_max_health 必须为大于 0 且不超过 1000000000 的有限数字。")
	if level is Dictionary and level.has("enemies_enabled") and not level.enemies_enabled is bool:
		return DataResult.failure("关卡 enemies_enabled 必须是布尔值。")
	var editor: Variant = data.get("properties", {}).get("editor", {})
	if editor is Dictionary and editor.has("enemy_template"):
		var template_result := check_enemy_template(editor.enemy_template, registry)
		if not template_result.is_ok():
			return template_result
	var dimensions := Vector2i(int(data.width), int(data.height))
	var tiles := _check_tiles(data.get("tiles"), dimensions, registry)
	if not tiles.is_ok():
		return tiles
	var spawn: Variant = data.get("player_spawn")
	if spawn == null:
		if require_spawn:
			return DataResult.failure("运行地图需要玩家出生点")
	else:
		var spawn_result := _check_machine(spawn, dimensions, registry, "player_spawn", true)
		if not spawn_result.is_ok():
			return spawn_result
	var instance_ids: Dictionary = {}
	for field in ["enemies", "objects"]:
		var entities_result := _check_entities(data.get(field, []), field, dimensions, registry, instance_ids)
		if not entities_result.is_ok():
			return entities_result
	var waves := EnemyDefinition.validate_wave_sequence(data.get("enemies", []))
	if not waves.is_ok():
		return waves
	var references := _check_security_references(data.get("enemies", []), data.get("objects", []))
	if not references.is_ok():
		return references
	return _check_dialogue(data.get("dialogue", []))


## 校验稀疏地块列表，拒绝重复坐标、越界坐标和显式 void。
static func _check_tiles(value: Variant, dimensions: Vector2i, registry: ContentRegistry) -> DataResult:
	if not value is Array or value.size() > dimensions.x * dimensions.y:
		return DataResult.failure("tiles 必须是数组，且长度不得超过地图格子数")
	var occupied: Dictionary = {}
	for index in range(value.size()):
		var entry: Variant = value[index]
		if not entry is Dictionary:
			return DataResult.failure("tiles[%d] 必须是对象" % index)
		if not DataValidation.is_integer(entry.get("x"), 0, dimensions.x - 1) or not DataValidation.is_integer(entry.get("y"), 0, dimensions.y - 1):
			return DataResult.failure("tiles[%d] 的坐标必须是图内整数" % index)
		var cell := Vector2i(int(entry.x), int(entry.y))
		if occupied.has(cell):
			return DataResult.failure("地块坐标重复：(%d, %d)" % [cell.x, cell.y])
		occupied[cell] = true
		if not DataValidation.is_id(entry.get("tile_id")) or registry.get_tile(entry.tile_id) == null:
			return DataResult.failure("tiles[%d] 引用了无效或未知地块；void 应直接省略" % index)
	return DataResult.success()


## 校验机器位置及模块清单；模块偏移使用相对机器中心的地图单位。
static func _check_machine(value: Variant, dimensions: Vector2i, registry: ContentRegistry, label: String, require_modules: bool) -> DataResult:
	if not value is Dictionary:
		return DataResult.failure("%s 必须是对象或空出生点" % label)
	if not _is_in_bounds_position(value.get("position"), dimensions):
		return DataResult.failure("%s.position 必须是图内的有限数值坐标" % label)
	if not require_modules and not value.has("modules"):
		return DataResult.success()
	var instances: Variant = value.get("modules")
	if not instances is Array or instances.is_empty() or instances.size() > MAX_MODULES:
		return DataResult.failure("%s.modules 必须包含 1..256 个模块" % label)
	var used_ids: Dictionary = {}
	for index in range(instances.size()):
		var instance: Variant = instances[index]
		if not instance is Dictionary:
			return DataResult.failure("%s.modules[%d] 必须是对象" % [label, index])
		if not DataValidation.is_id(instance.get("id")):
			return DataResult.failure("%s.modules[%d].id 无效" % [label, index])
		if used_ids.has(instance.id):
			return DataResult.failure("%s 中模块实例 ID 重复：%s" % [label, instance.id])
		used_ids[instance.id] = true
		if not DataValidation.is_id(instance.get("module_id")) or registry.get_module(instance.module_id) == null:
			return DataResult.failure("%s.modules[%d] 引用了未知模块" % [label, index])
		var offset: Variant = instance.get("offset")
		if not DataValidation.is_position(offset):
			return DataResult.failure("%s.modules[%d].offset 必须是有限数值坐标" % [label, index])
		if absf(float(offset.x)) > MAX_DIMENSION or absf(float(offset.y)) > MAX_DIMENSION:
			return DataResult.failure("%s.modules[%d].offset 不得超出 ±256" % [label, index])
	return DataResult.success()


## 保留敌人与物品数据，同时校验其位置和可选实例 ID、模块清单。
static func _check_entities(value: Variant, label: String, dimensions: Vector2i, registry: ContentRegistry, instance_ids: Dictionary) -> DataResult:
	if not value is Array or value.size() > MAX_ENTITIES:
		return DataResult.failure("%s 必须是最多 1024 项的数组" % label)
	for index in range(value.size()):
		var entry: Variant = value[index]
		var entry_label := "%s[%d]" % [label, index]
		var result := _check_machine(entry, dimensions, registry, entry_label, false)
		if not result.is_ok():
			return result
		if label == "enemies":
			var enemy_result := EnemyDefinition.validate(entry, registry)
			if not enemy_result.is_ok():
				return DataResult.failure("%s：%s" % [entry_label, "; ".join(enemy_result.errors)])
			if entry.get("behavior") == EnemyDefinition.WAVE_APPROACH_ATTACK and entry.properties.has("activation_region"):
				var region: Dictionary = entry.properties.activation_region
				if float(region.position.x) + float(region.size.x) > dimensions.x or float(region.position.y) + float(region.size.y) > dimensions.y:
					return DataResult.failure("波次触发区域不得超出地图边界。")
		if label == "objects":
			var object_result := MapObjectDefinition.validate(entry, dimensions)
			if not object_result.is_ok():
				return DataResult.failure("%s：%s" % [entry_label, "; ".join(object_result.errors)])
		if entry.has("id"):
			if not DataValidation.is_id(entry.id):
				return DataResult.failure("%s.id 无效" % entry_label)
			if instance_ids.has(entry.id):
				return DataResult.failure("地图实体 ID 重复：%s" % entry.id)
			instance_ids[entry.id] = true
	return DataResult.success()


## 对话仅保存文本及扩展字段，当前阶段不执行触发条件。
static func _check_dialogue(value: Variant) -> DataResult:
	if not value is Array or value.size() > MAX_DIALOGUE:
		return DataResult.failure("dialogue 必须是最多 4096 项的数组")
	for index in range(value.size()):
		var entry: Variant = value[index]
		if not entry is Dictionary or not DataValidation.is_text(entry.get("text")):
			return DataResult.failure("dialogue[%d].text 必须是字符串" % index)
		if entry.has("speaker") and not DataValidation.is_text(entry.speaker):
			return DataResult.failure("dialogue[%d].speaker 必须是字符串" % index)
	return DataResult.success()


## 检查点坐标；右边界和下边界不属于地图内部。
static func _is_in_bounds_position(value: Variant, dimensions: Vector2i) -> bool:
	return DataValidation.is_position(value) and float(value.x) >= 0.0 and float(value.y) >= 0.0 and float(value.x) < dimensions.x and float(value.y) < dimensions.y


## 在所有实体验证后解析机关引用；门只能依赖可摧毁目标，因此不允许门间环或自引用。
static func _check_security_references(enemies: Array, objects: Array) -> DataResult:
	var enemy_by_id: Dictionary = {}
	var object_by_id: Dictionary = {}
	for enemy: Dictionary in enemies:
		if enemy.has("id"):
			enemy_by_id[enemy.id] = enemy
	for object: Dictionary in objects:
		if object.has("id"):
			object_by_id[object.id] = object
	for object: Dictionary in objects:
		var kind: Variant = object.get("type", "")
		if kind == "prison_alarm":
			var guard_id: String = object.properties.guard_id
			if not enemy_by_id.has(guard_id) or enemy_by_id[guard_id].get("behavior") != EnemyDefinition.ALARM_GUARD:
				return DataResult.failure("监狱警报 %s 的 guard_id 必须引用已注册的 alarm_guard 守卫。" % object.id)
		elif kind == "paired_alarm":
			var partner_id: String = object.properties.partner_id
			if partner_id == object.id:
				return DataResult.failure("联动警报 %s 不能引用自己。" % object.id)
			if not object_by_id.has(partner_id) or object_by_id[partner_id].get("type") != "paired_alarm":
				return DataResult.failure("联动警报 %s 的 partner_id 必须引用另一联动警报。" % object.id)
			if object_by_id[partner_id].properties.partner_id != object.id:
				return DataResult.failure("联动警报 %s 与 %s 必须互相引用。" % [object.id, partner_id])
		elif kind == "security_gate":
			for enemy_id: String in object.properties.get("required_enemy_ids", []):
				if not enemy_by_id.has(enemy_id) or enemy_by_id[enemy_id].get("behavior") not in EnemyDefinition.BEHAVIORS:
					return DataResult.failure("安全门 %s 引用了不存在或未注册的敌人：%s。" % [object.id, enemy_id])
			for object_id: String in object.properties.get("required_object_ids", []):
				if not object_by_id.has(object_id) or object_by_id[object_id].get("type") not in ["destructible", "prison_alarm", "paired_alarm"]:
					return DataResult.failure("安全门 %s 只能依赖可破坏对象，禁止门间循环或自引用：%s。" % [object.id, object_id])
	return DataResult.success()


## 校验编辑器敌人组合的已知字段，保留额外属性；缺省配置由编辑文档提供而非写入旧地图。
static func check_enemy_template(value: Variant, registry: ContentRegistry) -> DataResult:
	if not value is Dictionary or not DataValidation.is_json_value(value):
		return DataResult.failure("敌人组合必须是可保存的对象。")
	if not DataValidation.is_integer(value.get("module_limit"), 1, MAX_MODULES):
		return DataResult.failure("敌人模块数量限制必须为 1..256 的整数。")
	var health: Variant = value.get("module_health")
	if not DataValidation.is_number(health) or float(health) < 0.01 or float(health) > 1000000.0:
		return DataResult.failure("敌人耐久度上限必须为 0.01..1000000 的有限数字。")
	var modules: Variant = value.get("module_ids")
	if not modules is Array or modules.is_empty() or modules.size() > int(value.module_limit):
		return DataResult.failure("敌人组合须至少选择一个模块，且不能超过数量限制。")
	if registry == null:
		return DataResult.failure("敌人组合校验需要内容注册表。")
	for module_id: Variant in modules:
		if not DataValidation.is_id(module_id) or registry.get_module(module_id) == null:
			return DataResult.failure("敌人组合引用了未知模块。")
	return DataResult.success(value.duplicate(true))
