class_name AssemblyModel
extends RefCounted
## 玩家装配草稿只保存相对布局；所有成功修改发出 changed，失败不改原装配。

signal changed

const GRID_STEP: float = 0.5
const MAX_OFFSET: float = 4.0
const CONTACT_EPSILON: float = 0.000001
const RESERVED_NAMES: Array[String] = [
	"main", "move", "distance", "simultaneously", "loop", "if", "else", "for", "while",
	"function", "fun", "return", "constant", "variable", "var", "val", "break",
	"continue", "true", "false", "null", "Null",
]

var modules: Array = []
var level: LevelDefinition
var content: ContentRegistry


## 每次进入关卡建立空装配；地图中的出生模板只供底层格式与地图编辑器使用。
static func create(level_definition: LevelDefinition, registry: ContentRegistry) -> AssemblyModel:
	var model := AssemblyModel.new()
	model.level = level_definition
	model.content = registry
	# 玩家必须主动放置模块，或由 UI 在明确点击“载入上次装配”后恢复草稿。
	# 不把关卡模板隐式复制进来，避免再次进入时跳过独立组装流程。
	return model


## 添加模块并自动生成不冲突的实例名；成功值为新增模块索引。
func add_module(module_id: String, offset: Vector2, instance_id: String = "") -> DataResult:
	var candidate := modules.duplicate(true)
	var name := instance_id if not instance_id.is_empty() else _next_name(module_id)
	candidate.append({"id": name, "module_id": module_id, "offset": {"x": offset.x, "y": offset.y}})
	var added_index := candidate.size() - 1
	var result := _commit(candidate, added_index, true)
	if result.is_ok():
		result.value = added_index
	return result


## 移动模块中心，偏移必须落在半格网格上；相邻边缘接触允许。
func move_module(index: int, offset: Vector2) -> DataResult:
	if index < 0 or index >= modules.size():
		return DataResult.failure("选择的模块不存在。")
	var candidate := modules.duplicate(true)
	if not candidate[index] is Dictionary:
		return DataResult.failure("选择的模块数据无效。")
	var position_data: Dictionary = candidate[index].get("offset", {}).duplicate(true) if candidate[index].get("offset") is Dictionary else {}
	var unchanged := DataValidation.is_position(position_data) and Vector2(float(position_data["x"]), float(position_data["y"])) == offset
	position_data.merge({"x": offset.x, "y": offset.y}, true)
	candidate[index]["offset"] = position_data
	# 属性面板重命名时也会提交原位置；无位移不能阻断无中心或断连草稿的修复。
	return _commit(candidate, -1 if unchanged else index)


## 删除允许留下空装配、缺失中心或断开分支，由玩家继续修复而不自动补模块。
func remove_module(index: int) -> DataResult:
	if index < 0 or index >= modules.size():
		return DataResult.failure("选择的模块不存在。")
	var candidate := modules.duplicate(true)
	candidate.remove_at(index)
	return _commit(candidate)


## 修改程序可引用的模块实例名，失败时保持原名称。
func rename_module(index: int, name: String) -> DataResult:
	if index < 0 or index >= modules.size():
		return DataResult.failure("选择的模块不存在。")
	var candidate := modules.duplicate(true)
	if not candidate[index] is Dictionary:
		return DataResult.failure("选择的模块数据无效。")
	candidate[index]["id"] = name
	return _commit(candidate)


## 检查可运行装配的规则，不在编辑阶段要求它已经放在出生地形上。
func validate() -> DataResult:
	var editing := validate_editing()
	if not editing.is_ok():
		return editing
	if modules.is_empty():
		return DataResult.failure("请至少安装一个模块后再运行。")
	return _validate_connected_layout(modules, editing.value)


## 读取和恢复草稿只检查基础编辑规则，允许空装配、缺失中心及待修复的断连。
func validate_editing() -> DataResult:
	return _validate_editing(modules)


## 将布局应用到地图副本并验证出生占地，保证运行不会改写关卡原件。
func build_document() -> DataResult:
	var validation := validate()
	if not validation.is_ok():
		return validation
	var document := level.document.duplicate_document()
	document.player_spawn["modules"] = modules.duplicate(true)
	var world_result := SimulationWorld.create(document, content)
	if not world_result.is_ok():
		return world_result
	return DataResult.success(document)


## 实例名必须可被程序标识符引用，不能含中文、空格、点号或连字符。
static func is_instance_name(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 128:
		return false
	if value in RESERVED_NAMES:
		return false
	var letters := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
	if not value[0] in letters:
		return false
	for character in value:
		if not character in letters + "0123456789":
			return false
	return true


## 先检查基础编辑规则；仅新增或移动需要额外检查本次目标的贴边关系。
func _commit(candidate: Array, placement_index: int = -1, adding: bool = false) -> DataResult:
	var validation := _validate_editing(candidate)
	if not validation.is_ok():
		return validation
	if placement_index >= 0:
		var placement := _validate_placement(candidate, validation.value, placement_index, adding)
		if not placement.is_ok():
			return placement
	modules = candidate
	changed.emit()
	return DataResult.success()


## 基础编辑校验允许无中心和断连草稿，成功值包含后续连接检查复用的真实矩形。
func _validate_editing(candidate: Array) -> DataResult:
	if level == null or level.document == null or content == null:
		return DataResult.failure("装配需要有效关卡和内容注册表。")
	if candidate.size() > level.module_limit:
		return DataResult.failure("此关最多允许 %d 个模块。" % level.module_limit)
	if not DataValidation.is_json_value(candidate):
		return DataResult.failure("装配包含无效扩展数据或非有限数字。")
	var used_names: Dictionary = {}
	var occupied: Array[Rect2] = []
	for index in range(candidate.size()):
		var instance: Variant = candidate[index]
		if not instance is Dictionary or not is_instance_name(instance.get("id")):
			return DataResult.failure("模块 %d 的名称必须是非保留的英文标识符：字母或下划线开头，后续仅含字母、数字、下划线。" % (index + 1))
		var instance_name: String = instance["id"]
		if used_names.has(instance_name):
			return DataResult.failure("模块名称重复：%s。" % instance_name)
		used_names[instance_name] = true
		var module_id: Variant = instance.get("module_id")
		if not DataValidation.is_id(module_id) or not module_id in level.allowed_modules:
			return DataResult.failure("模块 %s 的类型未在此关解锁。" % instance_name)
		var definition := content.get_module(module_id)
		if definition == null:
			return DataResult.failure("模块定义不存在：%s。" % module_id)
		var raw_offset: Variant = instance.get("offset")
		if not DataValidation.is_position(raw_offset):
			return DataResult.failure("模块 %s 的偏移必须是有限数字。" % instance_name)
		for axis in ["x", "y"]:
			var coordinate := float(raw_offset[axis])
			if absf(coordinate) > MAX_OFFSET or coordinate / GRID_STEP != round(coordinate / GRID_STEP):
				return DataResult.failure("模块偏移须位于 -4..4，并以 0.5 格为步长。")
		var offset := Vector2(float(raw_offset.x), float(raw_offset.y))
		var rect := Rect2(offset - definition.size * 0.5, definition.size)
		for other in occupied:
			if rect.intersects(other):
				return DataResult.failure("模块 %s 与其他模块重叠。" % instance_name)
		occupied.append(rect)
	return DataResult.success(occupied)


## 第一个模块必须居中，其余目标只需与任意已有模块贴边，允许分支与修复操作。
func _validate_placement(candidate: Array, rectangles: Array[Rect2], index: int, adding: bool) -> DataResult:
	if candidate.size() == 1:
		if not _is_center(candidate[index]):
			return DataResult.failure("首个模块必须放在机器中心 (0, 0)。" if adding else "只有一个模块时，它必须留在机器中心 (0, 0)。")
		return DataResult.success()
	for other_index in range(rectangles.size()):
		if other_index != index and _share_edge(rectangles[index], rectangles[other_index]):
			return DataResult.success()
	return DataResult.failure("模块必须与至少一个已有模块贴边相接，不能只接触角点或留有空隙。")


## 从中心模块遍历实际贴边图，最终运行装配必须全部连接到同一个中心。
func _validate_connected_layout(candidate: Array, rectangles: Array[Rect2]) -> DataResult:
	var center_index := -1
	for index in range(candidate.size()):
		if _is_center(candidate[index]):
			center_index = index
			break
	if center_index < 0:
		return DataResult.failure("机器中心 (0, 0) 必须安装一个模块，请补回中心模块。")
	var visited: Dictionary = {center_index: true}
	var pending: Array[int] = [center_index]
	var cursor := 0
	while cursor < pending.size():
		var current := pending[cursor]
		cursor += 1
		for next in range(rectangles.size()):
			if not visited.has(next) and _share_edge(rectangles[current], rectangles[next]):
				visited[next] = true
				pending.append(next)
	if visited.size() != candidate.size():
		return DataResult.failure("所有模块必须通过贴边连接到中心模块，请连接断开的模块。")
	return DataResult.success()


## 中心是机器参考点的精确零偏移，不根据历史实例名或模块外包围盒猜测。
static func _is_center(instance: Dictionary) -> bool:
	return float(instance["offset"]["x"]) == 0.0 and float(instance["offset"]["y"]) == 0.0


## 矩形一对边重合且另一轴有正长度交集才算贴边，角点、间隙和重叠均不算。
static func _share_edge(left: Rect2, right: Rect2) -> bool:
	var overlap_x := minf(left.end.x, right.end.x) - maxf(left.position.x, right.position.x)
	var overlap_y := minf(left.end.y, right.end.y) - maxf(left.position.y, right.position.y)
	if overlap_x > 0.0 and overlap_y > 0.0:
		return false
	# 仅给边界位置保留浮点容差；模块真实大小来自定义，不能写死半格占地。
	var vertical_edge := absf(left.end.x - right.position.x) <= CONTACT_EPSILON or absf(right.end.x - left.position.x) <= CONTACT_EPSILON
	var horizontal_edge := absf(left.end.y - right.position.y) <= CONTACT_EPSILON or absf(right.end.y - left.position.y) <= CONTACT_EPSILON
	return (vertical_edge and overlap_y > 0.0) or (horizontal_edge and overlap_x > 0.0)


## 用可读前缀生成唯一名称，已有模块重命名后也不会产生冲突。
func _next_name(module_id: String) -> String:
	var prefix := "drive" if module_id == "movement" else module_id
	if not is_instance_name(prefix):
		prefix = "module"
	var used: Dictionary = {}
	for instance in modules:
		if instance is Dictionary:
			used[instance.get("id", "")] = true
	if not used.has(prefix):
		return prefix
	var suffix := 2
	while used.has("%s_%d" % [prefix, suffix]):
		suffix += 1
	return "%s_%d" % [prefix, suffix]
