class_name MachineFactory
extends RefCounted
## 将经过地图格式验证的装配数据转换为运行时机器，并检查真实占地。


## 创建机器及模块；未知行为、重叠模块和出生点悬空都返回明确错误。
static func create_machine(machine_id: String, spawn: Dictionary, document: MapDocument, content: ContentRegistry, behaviors: ModuleBehaviorRegistry) -> DataResult:
	var machine := MachineInstance.new()
	machine.id = machine_id
	machine.position = _read_vector(spawn["position"])
	for module_data: Dictionary in spawn["modules"]:
		var definition := content.get_module(module_data["module_id"])
		if definition == null:
			return DataResult.failure("机器 %s 引用了未知模块：%s。" % [machine_id, module_data["module_id"]])
		var behavior_result := behaviors.create_behavior(definition)
		if not behavior_result.is_ok():
			return behavior_result
		var module := ModuleInstance.new()
		module.id = module_data["id"]
		module.definition = definition
		module.behavior = behavior_result.value
		module.max_health = float(definition.properties.get("max_health", 1.0))
		module.health = module.max_health
		module.local_position = _read_vector(module_data.get("offset", {"x": 0.0, "y": 0.0}))
		machine.modules.append(module)
	var validation := validate_placement(machine, document, content)
	if not validation.is_ok():
		return validation
	return DataResult.success(machine)


## 逐模块检查地形和相互重叠；机器外包围盒中的空洞不会被当成实体。
static func validate_placement(machine: MachineInstance, document: MapDocument, content: ContentRegistry) -> DataResult:
	if machine.id.is_empty() or not machine.position.is_finite() or machine.modules.is_empty():
		return DataResult.failure("机器需要有效 ID、有限位置与至少一个模块。")
	var occupied: Array[Rect2] = []
	var module_ids: Dictionary = {}
	for module in machine.modules:
		if module == null or module.definition == null or module.behavior == null:
			return DataResult.failure("机器 %s 包含未初始化的模块。" % machine.id)
		if module.id.is_empty() or module_ids.has(module.id):
			return DataResult.failure("机器 %s 的模块实例 ID 为空或重复：%s。" % [machine.id, module.id])
		module_ids[module.id] = true
		if not module.available:
			continue
		var rect := module.get_world_rect(machine.position)
		if not TerrainCollision.is_rect_supported(rect, document, content):
			return DataResult.failure("机器 %s 的模块 %s 出生占地包含 void、不可通行地块或地图外区域。" % [machine.id, module.id])
		# 同一机器的重叠只取决于装配偏移，避免平移后浮点舍入把共边误判成重叠。
		var local_rect := module.get_world_rect(Vector2.ZERO)
		for other_rect in occupied:
			if local_rect.intersects(other_rect):
				return DataResult.failure("机器 %s 的模块 %s 与其他模块重叠。" % [machine.id, module.id])
		occupied.append(local_rect)
	return DataResult.success()


## 地图坐标使用格为单位，保留小数以支持半格模块布局。
static func _read_vector(data: Dictionary) -> Vector2:
	return Vector2(float(data["x"]), float(data["y"]))
