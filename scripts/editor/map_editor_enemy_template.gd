class_name MapEditorEnemyTemplate
extends RefCounted
## 纯数据敌人模板在悬停预览与实际放置间共用，不持有画布、模拟世界或编辑历史。

const AUTO_BEHAVIOR := "auto_chase_attack"
const GRID_STEP := 0.5


## 从真实注册表查找移动能力；内容扩展改名后仍能得到有效默认项。
static func default_config(content: ContentRegistry) -> Dictionary:
	var ids: Array[String] = []
	if content != null:
		var ordered: Array = content.modules.keys()
		ordered.sort()
		for module_id: String in ordered:
			if content.get_module(module_id).behavior == "MovementModule":
				ids.append(module_id)
				break
		if ids.is_empty() and not ordered.is_empty():
			ids.append(ordered[0])
	return {"module_limit": 1, "module_health": 1.0, "module_ids": ids}


## 将组合依次横向共边排列，首件为原点；每次创建独立耐久和模块实例以免模板修改回写敌人。
static func build_entry(config: Dictionary, position: Vector2, content: ContentRegistry, enemy_id: String = "enemy_preview") -> DataResult:
	var checked := MapValidation.check_enemy_template(config, content)
	if not checked.is_ok():
		return checked
	if not DataValidation.is_id(enemy_id) or enemy_id == "player":
		return DataResult.failure("敌人需要有效且非 player 的 ID。")
	if not position.is_finite() or not _on_grid(position):
		return DataResult.failure("敌人位置必须为有限的半格坐标。")
	var modules: Array = []
	var health: Dictionary = {}
	var offset := 0.0
	var previous_width := 0.0
	var behaviors := ModuleBehaviorRegistry.create_default()
	for index in range(config.module_ids.size()):
		var module_id: String = config.module_ids[index]
		var definition := content.get_module(module_id)
		var behavior := behaviors.create_behavior(definition)
		if not behavior.is_ok():
			return behavior
		if index > 0:
			offset += (previous_width + definition.size.x) * 0.5
		if offset > MapValidation.MAX_DIMENSION:
			return DataResult.failure("敌人组合宽度超过地图格式允许的偏移范围。")
		var instance_id := "module_%d" % (index + 1)
		modules.append({"id": instance_id, "module_id": module_id, "offset": {"x": offset, "y": 0.0}})
		health[instance_id] = float(config.module_health)
		previous_width = definition.size.x
	return DataResult.success({
		"id": enemy_id,
		"position": {"x": position.x, "y": position.y},
		"behavior": AUTO_BEHAVIOR,
		"modules": modules,
		"properties": {"module_health": health, "wreck_fade_seconds": 3.0},
	})


## 以全部实际模块矩形检查地板与碰撞；允许贴边，不让中心合法却悬空的组合落地。
static func validate_placement(entry: Dictionary, document: MapDocument, content: ContentRegistry) -> DataResult:
	if document == null or content == null:
		return DataResult.failure("敌人放置需要地图和内容注册表。")
	var candidate := _machine_rects(entry, content)
	if not candidate.is_ok():
		return candidate
	var position := Vector2(float(entry.position.x), float(entry.position.y))
	if not _on_grid(position):
		return DataResult.failure("敌人位置必须为有限的半格坐标。")
	var rects: Array = candidate.value
	for index in range(rects.size()):
		var rect: Rect2 = rects[index]
		if not TerrainCollision.is_rect_supported(rect, document, content):
			return DataResult.failure("敌人完整占地必须位于地图内的可通行地板上。")
		for previous in range(index):
			if _overlap(rect, rects[previous]):
				return DataResult.failure("敌人的模块不能相互重叠。")
	var occupied: Array[Rect2] = []
	var machines: Array = document.enemies.duplicate()
	if document.player_spawn is Dictionary:
		machines.append(document.player_spawn)
	for machine: Variant in machines:
		# 旧地图允许没有模块的扩展敌人，此类元数据不伪造碰撞范围。
		if not machine is Dictionary or not machine.has("modules"):
			continue
		var other := _machine_rects(machine, content)
		if not other.is_ok():
			return other
		occupied.append_array(other.value)
	for object: Variant in document.objects:
		if not object is Dictionary or object.get("type") not in MapObjectDefinition.TYPES:
			continue
		if not DataValidation.is_position(object.get("position")):
			return DataResult.failure("场景对象需要有限位置。")
		var valid_object := MapObjectDefinition.validate(object, Vector2i(document.width, document.height))
		if not valid_object.is_ok():
			return valid_object
		# 闸门开始时可能开放，但其实体区域仍保留，避免闭合时夹住初始敌人。
		occupied.append(MapObjectDefinition.from_entry(object).rect)
	for rect: Rect2 in rects:
		for obstacle: Rect2 in occupied:
			if _overlap(rect, obstacle):
				return DataResult.failure("敌人不能与起点模块、已有敌人或场景障碍物重叠。")
	return DataResult.success(entry.duplicate(true))


## 安全读取真实定义尺寸，避免外部元数据的坏类型在预览阶段触发脚本异常。
static func _machine_rects(entry: Dictionary, content: ContentRegistry) -> DataResult:
	if not DataValidation.is_position(entry.get("position")):
		return DataResult.failure("机器位置必须是有限坐标。")
	var instances: Variant = entry.get("modules")
	if not instances is Array or instances.is_empty() or instances.size() > MapValidation.MAX_MODULES:
		return DataResult.failure("机器必须包含 1..256 个模块。")
	var center := Vector2(float(entry.position.x), float(entry.position.y))
	var rects: Array[Rect2] = []
	var ids := {}
	for instance: Variant in instances:
		if not instance is Dictionary or not DataValidation.is_id(instance.get("id")) or ids.has(instance.id):
			return DataResult.failure("模块实例 ID 必须有效且不重复。")
		if not DataValidation.is_id(instance.get("module_id")) or not DataValidation.is_position(instance.get("offset")):
			return DataResult.failure("模块需要有效的类型和有限偏移。")
		var definition := content.get_module(instance.module_id)
		if definition == null:
			return DataResult.failure("机器引用了未知模块。")
		ids[instance.id] = true
		var offset := Vector2(float(instance.offset.x), float(instance.offset.y))
		if absf(offset.x) > MapValidation.MAX_DIMENSION or absf(offset.y) > MapValidation.MAX_DIMENSION:
			return DataResult.failure("模块偏移不得超出地图格式允许的范围。")
		rects.append(Rect2(center + offset - definition.size * 0.5, definition.size))
	return DataResult.success(rects)


## 半格检查用绝对误差，防止较大坐标的近似比较放宽吸附条件。
static func _on_grid(position: Vector2) -> bool:
	return position.is_finite() and absf(position.x / GRID_STEP - roundf(position.x / GRID_STEP)) <= TerrainCollision.EPSILON and absf(position.y / GRID_STEP - roundf(position.y / GRID_STEP)) <= TerrainCollision.EPSILON


## 消除共边相加产生的微小舍入误差，仅正面积交叠才属于碰撞。
static func _overlap(left: Rect2, right: Rect2) -> bool:
	var intersection := left.intersection(right)
	return intersection.size.x > TerrainCollision.EPSILON and intersection.size.y > TerrainCollision.EPSILON
