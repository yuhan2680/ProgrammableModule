class_name MapEditorDocument
extends RefCounted
## 编辑文档只管理可撤销的数据修改，不依赖界面，也不持有运行中的机器。

signal changed

const HISTORY_LIMIT := 100

var document: MapDocument = MapDocument.new()
var path: String = ""
var _saved_state: String = ""
var _undo_stack: Array[MapDocument] = []
var _redo_stack: Array[MapDocument] = []
var _action_depth: int = 0
var _action_before: MapDocument
var _action_signature: String = ""


# 用途：替换当前文档，并以载入状态建立新的保存点和撤销历史。
func replace_document(value: MapDocument, source_path: String = "") -> void:
	document = value.duplicate_document()
	path = source_path
	_undo_stack.clear()
	_redo_stack.clear()
	_action_depth = 0
	_action_before = null
	_saved_state = _signature()
	changed.emit()


# 用途：比较当前文档与最近保存点，避免撤销回保存点后仍显示未保存。
func is_dirty() -> bool:
	return _signature() != _saved_state


# 用途：在实际写盘成功后更新文件路径和保存点。
func mark_saved(saved_path: String) -> void:
	path = saved_path
	_saved_state = _signature()
	changed.emit()


# 用途：开始一个可嵌套的修改事务，使一次拖动只占用一个撤销步骤。
func begin_action() -> void:
	if _action_depth == 0:
		_action_before = document.duplicate_document()
		_action_signature = _signature()
	_action_depth += 1


# 用途：结束修改事务，仅在实际改变文档时记录历史。
func end_action() -> void:
	if _action_depth == 0:
		return
	_action_depth -= 1
	if _action_depth > 0:
		return
	if _signature() != _action_signature:
		_undo_stack.append(_action_before)
		if _undo_stack.size() > HISTORY_LIMIT:
			_undo_stack.pop_front()
		_redo_stack.clear()
	_action_before = null
	changed.emit()


# 用途：放置地块或以空 ID 擦除地块；地图外的输入不会产生修改。
func paint(cell: Vector2i, tile_id: String) -> void:
	if not document.in_bounds(cell) or document.get_tile_id(cell) == tile_id:
		return
	begin_action()
	document.set_tile(cell, tile_id)
	end_action()
	if _action_depth > 0:
		changed.emit()


## 矩形填充只写入地图边界内的格子；整块操作只有一次历史记录和一次重绘通知。
func paint_rectangle(area: Rect2i, tile_id: String) -> void:
	var bounded := area.abs().intersection(Rect2i(Vector2i.ZERO, Vector2i(document.width, document.height)))
	if not bounded.has_area():
		return
	begin_action()
	for y in range(bounded.position.y, bounded.end.y):
		for x in range(bounded.position.x, bounded.end.x):
			document.set_tile(Vector2i(x, y), tile_id)
	end_action()


# 用途：调整地图范围并删除范围外地块及起终点，整个裁剪仍是一次可撤销操作。
func resize(new_width: int, new_height: int) -> void:
	begin_action()
	document.width = clampi(new_width, 1, 256)
	document.height = clampi(new_height, 1, 256)
	for cell: Vector2i in document.cells.keys():
		if not document.in_bounds(cell):
			document.cells.erase(cell)
			document.cell_extras.erase(cell)
	if document.player_spawn != null:
		var position: Dictionary = document.player_spawn.get("position", {})
		var spawn_cell := Vector2i(floori(float(position.get("x", 0))), floori(float(position.get("y", 0))))
		if not document.in_bounds(spawn_cell):
			document.player_spawn = null
	var goal := position_goal(document)
	if not goal.is_empty() and not document.in_bounds(Vector2i(floori(goal.position.x), floori(goal.position.y))):
		clear_goal()
	end_action()


# 用途：将出生点放到格心；移动已有出生点时保留其模块与扩展字段。
func place_spawn(cell: Vector2i, default_module_id: String) -> void:
	if not document.in_bounds(cell):
		return
	begin_action()
	if document.player_spawn == null:
		document.player_spawn = {
			"position": {},
			"modules": [{"id": "drive", "module_id": default_module_id, "offset": {"x": 0, "y": 0}}],
		}
	var position: Dictionary = document.player_spawn.get("position", {}).duplicate(true)
	position.merge({"x": cell.x + 0.5, "y": cell.y + 0.5}, true)
	document.player_spawn["position"] = position
	end_action()
	if _action_depth > 0:
		changed.emit()


# 用途：清除出生点，以便编辑或保存尚未配置玩家的地图草稿。
func clear_spawn() -> void:
	begin_action()
	document.player_spawn = null
	end_action()


## 读取可在地图上放置的终点；战斗目标和无效元数据不伪装成坐标终点。
static func position_goal(value: MapDocument) -> Dictionary:
	var level: Variant = value.properties.get("level", {})
	if not level is Dictionary:
		return {}
	var goal: Variant = level.get("goal")
	if not goal is Dictionary or goal.get("type", "reach_position") not in ["reach_position", "escape_prison", "escape_alarms"] or not DataValidation.is_position(goal.get("position")):
		return {}
	return goal.duplicate(true)


## 单点写入现有关卡目标字段；移动已有出口时保留条件、半径和扩展属性。
func place_goal(cell: Vector2i) -> DataResult:
	if not document.in_bounds(cell):
		return DataResult.failure("终点需要位于地图内部。")
	var existing: Variant = document.properties.get("level", {})
	if not existing is Dictionary:
		return DataResult.failure("properties.level 必须是对象，请先在元数据中修正。")
	var properties := document.properties.duplicate(true)
	var level: Dictionary = existing.duplicate(true)
	var goal := position_goal(document)
	if goal.is_empty():
		goal = {"type": "reach_position", "radius": 0.25}
	var position: Dictionary = goal.position.duplicate(true) if goal.has("position") else {}
	position.merge({"x": cell.x + 0.5, "y": cell.y + 0.5}, true)
	goal["position"] = position
	level["goal"] = goal
	properties["level"] = level
	apply_metadata({"properties": properties})
	return DataResult.success()


## 仅移除坐标终点，保留出生配置、地形和其他规则；没有终点的战斗目标不受影响。
func clear_goal() -> void:
	if position_goal(document).is_empty():
		return
	var properties := document.properties.duplicate(true)
	properties.level.erase("goal")
	apply_metadata({"properties": properties})


# 用途：统一修改地图标识与显示名，供表单或其它编辑器前端复用。
func set_identity(map_id: String, map_name: String) -> void:
	begin_action()
	document.id = map_id
	document.display_name = map_name
	end_action()


# 用途：读取显式关卡上限；省略规则时与关卡定义一样沿用出生模板数量，至少为一。
func get_module_limit() -> int:
	var level: Variant = document.properties.get("level", {})
	if level is Dictionary and DataValidation.is_integer(level.get("module_limit"), 1, 256):
		return int(level.module_limit)
	var fallback: int = 1
	if document.player_spawn is Dictionary and document.player_spawn.get("modules") is Array:
		fallback = maxi(document.player_spawn.modules.size(), 1)
	return clampi(fallback, 1, 256)


# 用途：把上限作为单次可撤销事务写入关卡规则，保留其它规则和地图扩展属性。
func set_module_limit(limit: Variant) -> DataResult:
	if not DataValidation.is_integer(limit, 1, 256):
		return DataResult.failure("模块数量上限必须为 1..256 的整数。")
	var existing_level: Variant = document.properties.get("level", {})
	if not existing_level is Dictionary:
		# 不用空对象覆盖损坏的原始值，作者可以先在元数据窗口修正它。
		return DataResult.failure("properties.level 必须是对象，请先在元数据中修正。")
	var properties := document.properties.duplicate(true)
	var level: Dictionary = existing_level.duplicate(true)
	level["module_limit"] = int(limit)
	properties["level"] = level
	apply_metadata({"properties": properties})
	return DataResult.success(int(limit))


## 读取玩家每个模块的耐久上限；旧地图未指定时仅在编辑表单中显示默认值一。
func get_player_max_health() -> float:
	var level: Variant = document.properties.get("level", {})
	if level is Dictionary:
		var value: Variant = level.get("player_max_health")
		if DataValidation.is_number(value) and float(value) > 0.0 and float(value) <= 1000000000.0:
			return float(value)
	return 1.0


## 将玩家耐久上限作为单次事务保存，等值整数与小数不改写原数值或撤销历史。
func set_player_max_health(value: Variant) -> DataResult:
	if not DataValidation.is_number(value) or float(value) <= 0.0 or float(value) > 1000000000.0:
		return DataResult.failure("玩家耐久度上限必须为大于 0 且不超过 1000000000 的有限数字。")
	var existing: Variant = document.properties.get("level", {})
	if not existing is Dictionary:
		return DataResult.failure("properties.level 必须是对象，请先在元数据中修正。")
	if DataValidation.is_number(existing.get("player_max_health")) and float(existing.player_max_health) == float(value):
		return DataResult.success(float(value))
	var properties := document.properties.duplicate(true)
	var level: Dictionary = existing.duplicate(true)
	level["player_max_health"] = value
	properties["level"] = level
	apply_metadata({"properties": properties})
	return DataResult.success(float(value))


## 秒数展示复用固定 tick；没有合法正限时的旧地图在编辑器中默认显示60秒。
func get_time_limit_seconds() -> float:
	var level: Variant = document.properties.get("level", {})
	if level is Dictionary and DataValidation.is_integer(level.get("max_ticks"), 1, 36000):
		return int(level.max_ticks) * SimulationWorld.TICK_DURATION
	return 60.0


## 将秒数和限时通关规则作为一次事务保存，保留终点与其他元数据。
func set_time_limit_seconds(seconds: float) -> DataResult:
	if not is_finite(seconds) or seconds <= 0.0 or seconds > 3600.0 or not is_equal_approx(seconds * 10.0, roundf(seconds * 10.0)):
		return DataResult.failure("时间限制须大于 0 且不超过 3600 秒，最多一位小数。")
	var existing: Variant = document.properties.get("level", {})
	if not existing is Dictionary:
		return DataResult.failure("properties.level 必须是对象，请先在元数据中修正。")
	var ticks := roundi(seconds / SimulationWorld.TICK_DURATION)
	if existing.get("completion_mode") == "reach_or_clear" and DataValidation.is_integer(existing.get("max_ticks"), 1, 36000) and int(existing.max_ticks) == ticks:
		return DataResult.success(seconds)
	var properties := document.properties.duplicate(true)
	var level: Dictionary = existing.duplicate(true)
	level["max_ticks"] = roundi(seconds / SimulationWorld.TICK_DURATION)
	level["completion_mode"] = "reach_or_clear"
	properties["level"] = level
	if properties != document.properties:
		apply_metadata({"properties": properties})
	return DataResult.success(seconds)



## 未显式配置的旧地图根据已保存敌人显示开关；读取不改变历史或旧地图运行语义。
func get_enemies_enabled() -> bool:
	var level: Variant = document.properties.get("level", {})
	if level is Dictionary and level.get("enemies_enabled") is bool:
		return level.enemies_enabled
	return not document.enemies.is_empty()


## 仅记录敌人运行开关，关闭后保留所有已放置敌人、模板及扩展属性。
func set_enemies_enabled(enabled: bool) -> DataResult:
	var existing: Variant = document.properties.get("level", {})
	if not existing is Dictionary:
		return DataResult.failure("properties.level 必须是对象，请先在元数据中修正。")
	var properties := document.properties.duplicate(true)
	var level: Dictionary = existing.duplicate(true)
	level["enemies_enabled"] = enabled
	properties["level"] = level
	apply_metadata({"properties": properties})
	return DataResult.success(enabled)


## 返回可独立修改的敌人模板副本；旧地图优先使用真实移动模块作为默认组合。
func get_enemy_template(content: ContentRegistry) -> Dictionary:
	var editor: Variant = document.properties.get("editor", {})
	if editor is Dictionary and editor.get("enemy_template") is Dictionary:
		return editor.enemy_template.duplicate(true)
	return MapEditorEnemyTemplate.default_config(content)


## 原子保存有效模板，不回写已放置敌人的独立模块或耐久配置。
func set_enemy_template(config: Dictionary, content: ContentRegistry) -> DataResult:
	var result := MapValidation.check_enemy_template(config, content)
	if not result.is_ok():
		return result
	var existing: Variant = document.properties.get("editor", {})
	if not existing is Dictionary:
		return DataResult.failure("properties.editor 必须是对象，请先在元数据中修正。")
	var properties := document.properties.duplicate(true)
	var editor: Dictionary = existing.duplicate(true)
	# 只更新本工具拥有的已知字段，元数据中添加的模板扩展也继续保留。
	var template: Dictionary = editor.get("enemy_template", {}).duplicate(true) if editor.get("enemy_template", {}) is Dictionary else {}
	var incoming := config.duplicate(true)
	# JSON 读取的 1.0 与表单输入的 1 语义相同，避免保存重开后无修改却产生历史。
	for field: String in ["module_limit", "module_health"]:
		if DataValidation.is_number(template.get(field)) and float(template[field]) == float(incoming[field]):
			incoming[field] = template[field]
	template.merge(incoming, true)
	var merged := MapValidation.check_enemy_template(template, content)
	if not merged.is_ok():
		return merged
	editor["enemy_template"] = template
	properties["editor"] = editor
	apply_metadata({"properties": properties})
	return DataResult.success(template.duplicate(true))


## 共享预览占地检查后单次提交完整敌人；无效落点不改变文档、保存点或撤销栈。
func place_enemy(position: Vector2, content: ContentRegistry) -> DataResult:
	if not get_enemies_enabled():
		return DataResult.failure("请先启用敌人。")
	if document.enemies.size() >= MapValidation.MAX_ENTITIES:
		return DataResult.failure("地图最多支持 1024 个敌人。")
	var created := MapEditorEnemyTemplate.build_entry(get_enemy_template(content), position, content, _next_enemy_id())
	if not created.is_ok():
		return created
	var placement := MapEditorEnemyTemplate.validate_placement(created.value, document, content)
	if not placement.is_ok():
		return placement
	begin_action()
	document.enemies.append(created.value.duplicate(true))
	end_action()
	return DataResult.success(created.value.duplicate(true))


## 敌人实例名称与敌人、对象共享唯一空间，撤销后重新放置也不会覆盖现有数据。
func _next_enemy_id() -> String:
	var used := {"player": true}
	for entries: Array in [document.enemies, document.objects]:
		for entry: Variant in entries:
			if entry is Dictionary and entry.get("id") is String:
				used[entry.id] = true
	var number := 1
	while used.has("enemy_%d" % number):
		number += 1
	return "enemy_%d" % number


# 用途：提供可独立编辑的元数据副本，包含当前尚未实现玩法的扩展数据。
func metadata_dict() -> Dictionary:
	return {
		"player_spawn": document.player_spawn.duplicate(true) if document.player_spawn != null else null,
		"enemies": document.enemies.duplicate(true),
		"objects": document.objects.duplicate(true),
		"dialogue": document.dialogue.duplicate(true),
		"properties": document.properties.duplicate(true),
		"extra": document.extra.duplicate(true),
	}


# 用途：应用已由调用方校验的元数据；缺少的字段保持原值，避免意外清空。
func apply_metadata(data: Dictionary) -> void:
	begin_action()
	if data.has("player_spawn"):
		document.player_spawn = data.player_spawn.duplicate(true) if data.player_spawn != null else null
	for key: String in ["enemies", "objects", "dialogue", "properties", "extra"]:
		if data.has(key):
			document.set(key, data[key].duplicate(true))
	end_action()


# 用途：判断是否存在可撤销的完整修改事务。
func can_undo() -> bool:
	return not _undo_stack.is_empty() and _action_depth == 0


# 用途：判断是否存在可重做的完整修改事务。
func can_redo() -> bool:
	return not _redo_stack.is_empty() and _action_depth == 0


# 用途：恢复上一个文档快照，重做历史保留当前状态。
func undo() -> bool:
	if not can_undo():
		return false
	_redo_stack.append(document.duplicate_document())
	document = _undo_stack.pop_back()
	changed.emit()
	return true


# 用途：重新应用最近撤销的文档快照。
func redo() -> bool:
	if not can_redo():
		return false
	_undo_stack.append(document.duplicate_document())
	document = _redo_stack.pop_back()
	changed.emit()
	return true


# 用途：生成稳定的数据签名，供事务去重和未保存状态比较使用。
func _signature() -> String:
	return JSON.stringify(document.to_dict(), "", true)
