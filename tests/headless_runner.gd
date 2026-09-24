extends SceneTree
## 无界面回归入口：覆盖内容验证、地图编辑事务和确定性移动。

var _content: ContentRegistry
var _assertions := 0
var _failures := 0
var _current_test := "初始化"
var _fixture_index := 0
var _test_root := ""


## 等待 SceneTree 完成初始化后开始测试，退出码可供 CI 使用。
func _initialize() -> void:
	call_deferred("_run")


## 顺序执行相互独立的用例，并在结束时清理本次测试的临时文件。
func _run() -> void:
	_test_root = "user://tests/programmable_module_%s" % Time.get_ticks_usec()
	_content = ContentRegistry.new()
	var loaded := _content.load_directories()
	if not _expect_ok(loaded, "默认内容能够加载"):
		quit(1)
		return
	var cases: Array[Callable] = [
		_test_default_content,
		_test_invalid_definitions,
		_test_invalid_maps,
		_test_draft_maps,
		_test_round_trip,
		_test_failed_save_preserves_original,
		_test_editor_history,
		_test_editor_save_reload,
		_test_editor_module_limit,
		_test_move_speed_and_exact_distance,
		_test_stacked_modules,
		_test_angle_direction,
		_test_void_and_map_boundary,
		_test_spawn_footprint,
		_test_separated_module_footprints,
		_test_high_speed_gap,
		_test_extreme_finite_speed,
		_test_diagonal_corner,
		_test_other_machine_void,
		_test_invalid_and_busy_commands,
		_test_command_completion_signal,
		_test_cancellation,
	]
	for test_case in cases:
		_current_test = str(test_case.get_method())
		test_case.call()
	_remove_test_tree(_test_root)
	print("回归完成：%d 个用例，%d 项断言，%d 项失败。" % [cases.size(), _assertions, _failures])
	quit(0 if _failures == 0 else 1)


## 记录断言但继续执行后续用例，方便一次看到全部回归结果。
func _expect(condition: bool, description: String) -> bool:
	_assertions += 1
	if not condition:
		_failures += 1
		push_error("[%s] %s" % [_current_test, description])
	return condition


## 检查成功结果并附带底层错误，失败时调用者必须停止依赖该值的测试。
func _expect_ok(result: DataResult, description: String) -> bool:
	return _expect(result.is_ok(), "%s；错误：%s" % [description, "; ".join(result.errors)])


## 检查失败结果确实携带可呈现给编辑器的原因。
func _expect_error(result: DataResult, description: String) -> void:
	_expect(not result.is_ok() and not result.errors.is_empty(), description)


## 在足够小的容差内比较世界坐标，避免把浮点舍入当成玩法错误。
func _expect_position(actual: Vector2, expected: Vector2, description: String) -> void:
	_expect(actual.distance_to(expected) < 0.0001, "%s：实际 %s，预期 %s" % [description, actual, expected])


## JSON 解析会把整数读成浮点数，因此按归一化 JSON 值比较扩展数据。
func _json_equal(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))


## 创建完整地板和一个默认移动模块，具体序列化字段交由生产模型生成。
func _filled_document(width: int = 8, height: int = 6, spawn: Vector2 = Vector2(0.5, 2.5)) -> MapDocument:
	var document := MapDocument.new()
	document.id = "regression_map"
	document.display_name = "回归测试地图"
	document.width = width
	document.height = height
	for y in height:
		for x in width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {
		"position": {"x": spawn.x, "y": spawn.y},
		"modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}}],
	}
	return document


## 创建运行时并统一报告建图失败，允许每个用例安全提前返回。
func _world(document: MapDocument, content: ContentRegistry = null) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content if content == null else content)
	if not _expect_ok(result, "合法地图可创建运行世界"):
		return null
	return result.value as SimulationWorld


## 发起移动并检查命令对象是否存在。
func _move(world: SimulationWorld, angle: Variant, distance: Variant) -> MovementCommand:
	var result := world.request_move(world.player.id, angle, distance)
	if not _expect_ok(result, "合法移动可进入命令队列"):
		return null
	return result.value as MovementCommand


## 有限步执行直到命令完成或受阻，防止回归测试因死循环永远挂起。
func _finish(world: SimulationWorld, command: MovementCommand) -> void:
	for _index in 1000:
		if command.state not in [MovementCommand.State.QUEUED, MovementCommand.State.RUNNING]:
			return
		world.step()
	_expect(false, "命令应在 1000 tick 内结束")


## 将测试 JSON 写入本次独占目录，不覆盖任何用户地图。
func _write_fixture(relative_path: String, data: Dictionary) -> String:
	var path := _test_root.path_join(relative_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _expect(file != null, "可以创建临时 JSON：%s" % path):
		return ""
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return path


## 使用原始定义构造独立内容包，以覆盖真实 JSON 加载路径。
func _registry_for_modules(definitions: Array[Dictionary]) -> DataResult:
	_fixture_index += 1
	var relative_directory := "content_%d/modules" % _fixture_index
	for index in definitions.size():
		_write_fixture(relative_directory.path_join("definition_%d.json" % index), definitions[index])
	var registry := ContentRegistry.new()
	var result := registry.load_directories(
		PackedStringArray([_test_root.path_join(relative_directory)]),
		PackedStringArray(["res://data/tiles"])
	)
	if result.is_ok():
		result.value = registry
	return result


## 通过内容定义提高速度，确保穿透测试覆盖单 tick 跨越多个格子的情况。
func _fast_content(speed: float = 100.0) -> ContentRegistry:
	var definition: Dictionary = _content.get_module("movement").raw.duplicate(true)
	definition["properties"]["move_speed"] = speed
	var result := _registry_for_modules([definition])
	if not _expect_ok(result, "高速移动模块 JSON 可以加载"):
		return null
	return result.value as ContentRegistry


## 检查仓库交付的最小内容符合首个可运行版本的约定。
func _test_default_content() -> void:
	_expect(_content.get_module("movement") != null, "提供移动模块")
	_expect(_content.get_tile("floor") != null, "提供地板地块")
	_expect(_content.get_tile("void") == null, "void 是缺省区域，不需要注册为地块")
	var module := _content.get_module("movement")
	_expect_position(module.size, Vector2(0.5, 0.5), "默认模块占地 0.5×0.5")
	_expect(float(module.properties["move_speed"]) > 0.0, "移动速度为正数")
	_expect(not _content.get_tile("floor").collision, "地板允许机器通行")


## 验证内容包拒绝重复 ID、损坏资源、类型错误和未知版本。
func _test_invalid_definitions() -> void:
	var original: Dictionary = _content.get_module("movement").raw.duplicate(true)
	_expect_error(_registry_for_modules([original, original.duplicate(true)]), "重复模块 ID 必须失败")
	var changed := original.duplicate(true)
	changed["texture"] = "res://assets/does_not_exist.svg"
	_expect_error(_registry_for_modules([changed]), "缺失贴图必须在内容加载阶段报错")
	changed = original.duplicate(true)
	changed["size"]["width"] = true
	_expect_error(_registry_for_modules([changed]), "模块宽度不能把布尔值当作数字")
	changed = original.duplicate(true)
	changed["properties"]["move_speed"] = true
	_expect_error(_registry_for_modules([changed]), "移动速度不能把布尔值当作数字")
	changed = original.duplicate(true)
	changed["properties"]["move_speed"] = -1.0
	_expect_error(_registry_for_modules([changed]), "负数速度必须失败")
	changed = original.duplicate(true)
	changed["format_version"] = 999
	_expect_error(_registry_for_modules([changed]), "不支持的定义版本必须失败")


## 从生产序列化生成变体，验证地图边界、引用和精确类型。
func _test_invalid_maps() -> void:
	var document := _filled_document()
	var original := document.to_dict()
	_expect_ok(MapCodec.from_dict(original, _content), "标准地图 JSON 可以加载")
	var changed := original.duplicate(true)
	changed["format_version"] = 999
	_expect_error(MapCodec.from_dict(changed, _content), "未知地图版本必须失败")
	changed = original.duplicate(true)
	changed["tiles"].append(changed["tiles"][0].duplicate(true))
	_expect_error(MapCodec.from_dict(changed, _content), "重复地块坐标必须失败")
	changed = original.duplicate(true)
	changed["tiles"][0]["tile_id"] = "missing_tile"
	_expect_error(MapCodec.from_dict(changed, _content), "未知地块 ID 必须失败")
	changed = original.duplicate(true)
	changed["tiles"][0]["x"] = true
	_expect_error(MapCodec.from_dict(changed, _content), "地块坐标不能把布尔值当作整数")
	changed = original.duplicate(true)
	changed["tiles"][0]["x"] = document.width
	_expect_error(MapCodec.from_dict(changed, _content), "地图边界外的地块必须失败")
	changed = original.duplicate(true)
	changed["player_spawn"]["modules"][0]["module_id"] = "missing_module"
	_expect_error(MapCodec.from_dict(changed, _content), "未知模块 ID 必须失败")
	changed = original.duplicate(true)
	changed["player_spawn"]["position"]["x"] = false
	_expect_error(MapCodec.from_dict(changed, _content), "出生位置不能把布尔值当作数字")


## 无出生点地图可以作为草稿保存，但不能进入模拟。
func _test_draft_maps() -> void:
	var draft := _filled_document()
	draft.player_spawn = null
	_expect_ok(MapCodec.validate(draft, _content, false), "草稿允许缺少出生点")
	_expect_error(MapCodec.validate(draft, _content, true), "可运行地图要求出生点")
	_expect_error(SimulationWorld.create(draft, _content), "运行时拒绝无出生点地图")
	var path := _test_root.path_join("draft.json")
	DirAccess.make_dir_recursive_absolute(_test_root)
	_expect_ok(MapCodec.save_file(draft, path, _content, false), "可存储草稿")
	_expect_ok(MapCodec.load_file(path, _content, false), "可重新加载草稿")


## 未实现系统的数据和未知顶层字段必须经过保存加载完整保留。
func _test_round_trip() -> void:
	var data := _filled_document().to_dict()
	data["future_system"] = {"enabled": true, "nested": [1, "值", {"version": 3}]}
	data["properties"] = {"designer_note": "保留地图属性"}
	data["objects"] = [{"id": "future_door", "position": {"x": 4.5, "y": 3.5}, "properties": {"open": false}}]
	data["dialogue"] = [{"speaker": "教程", "text": "移动到地板上。"}]
	var decoded := MapCodec.from_dict(data, _content)
	if not _expect_ok(decoded, "保留字段合法地图可以解析"):
		return
	var path := _test_root.path_join("round_trip.json")
	DirAccess.make_dir_recursive_absolute(_test_root)
	if not _expect_ok(MapCodec.save_file(decoded.value, path, _content), "地图可以写入 JSON"):
		return
	var reloaded := MapCodec.load_file(path, _content)
	if not _expect_ok(reloaded, "地图可以重新加载"):
		return
	var actual: Dictionary = reloaded.value.to_dict()
	for key in ["future_system", "properties", "objects", "dialogue", "tiles", "player_spawn"]:
		_expect(_json_equal(actual[key], data[key]), "%s 在往返后没有丢失或更改" % key)


## 验证无效修改不能破坏磁盘上最后一份有效地图。
func _test_failed_save_preserves_original() -> void:
	var document := _filled_document()
	var path := _test_root.path_join("preserve_original.json")
	DirAccess.make_dir_recursive_absolute(_test_root)
	if not _expect_ok(MapCodec.save_file(document, path, _content), "初始地图保存成功"):
		return
	var original := FileAccess.get_file_as_string(path)
	document.cells[Vector2i(2, 2)] = "unknown_tile"
	_expect_error(MapCodec.save_file(document, path, _content), "无效地图保存被拒绝")
	_expect(FileAccess.get_file_as_string(path) == original, "保存失败后原文件逐字保持不变")


## 检查笔划事务、撤销重做和缩图语义，不依赖 UI 节点。
func _test_editor_history() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_filled_document(), "user://example.json")
	_expect(not model.is_dirty(), "加载地图初始为未修改状态")
	model.begin_action()
	model.paint(Vector2i(4, 1), "")
	model.paint(Vector2i(5, 1), "")
	model.end_action()
	_expect(model.is_dirty(), "笔划修改标记为待保存")
	_expect(model.document.get_tile_id(Vector2i(4, 1)) == "", "擦除地块恢复 void")
	_expect(model.undo(), "可以撤销整次笔划")
	_expect(model.document.get_tile_id(Vector2i(4, 1)) == "floor" and model.document.get_tile_id(Vector2i(5, 1)) == "floor", "一次撤销恢复笔划全部格子")
	_expect(not model.is_dirty(), "撤销回加载内容后恢复未修改状态")
	_expect(model.redo(), "可以重做笔划")
	model.resize(3, 2)
	_expect(model.document.width == 3 and model.document.height == 2, "修改地图尺寸生效")
	_expect(model.document.player_spawn == null, "缩图清除范围外出生点")
	for cell: Vector2i in model.document.cells:
		_expect(model.document.in_bounds(cell), "缩图移除范围外地块")


## 通过编辑器模型修改后保存，验证元数据与实际画布同时持久化。
func _test_editor_save_reload() -> void:
	var document := _filled_document()
	document.extra["future_system"] = {"priority": 9}
	var model := MapEditorDocument.new()
	model.replace_document(document)
	model.paint(Vector2i(5, 4), "")
	model.set_identity("edited_map", "编辑后地图")
	var path := _test_root.path_join("edited_map.json")
	DirAccess.make_dir_recursive_absolute(_test_root)
	if not _expect_ok(MapCodec.save_file(model.document, path, _content, false), "编辑器文档可保存"):
		return
	model.mark_saved(path)
	_expect(not model.is_dirty(), "保存后清除修改标记")
	var loaded := MapCodec.load_file(path, _content, false)
	if not _expect_ok(loaded, "编辑后地图可再次加载"):
		return
	var reloaded: MapDocument = loaded.value
	_expect(reloaded.id == "edited_map" and reloaded.display_name == "编辑后地图", "地图身份修改被保存")
	_expect(reloaded.get_tile_id(Vector2i(5, 4)) == "", "擦除操作在磁盘往返后仍是 void")
	_expect(_json_equal(reloaded.extra.get("future_system"), {"priority": 9}), "编辑不丢弃未知字段")


## 模块上限的公开编辑接口拒绝非法值，且更新与撤销都保留作者其它规则。
func _test_editor_module_limit() -> void:
	var document := _filled_document()
	document.player_spawn.modules.append({"id": "drive_2", "module_id": "movement", "offset": {"x": 0.5, "y": 0}})
	document.properties = {"level": {"allowed_modules": ["movement"], "future_rule": {"mode": "keep"}}, "author_data": [1, 2]}
	var model := MapEditorDocument.new()
	model.replace_document(document)
	var before := JSON.stringify(model.document.to_dict(), "", true)
	_expect(model.get_module_limit() == 2, "未显式配置上限时沿用出生模板数量")
	for invalid in [0, 257, -1, 1.5, true, "3", INF, NAN]:
		_expect_error(model.set_module_limit(invalid), "模块上限拒绝非法数值或类型")
	_expect(before == JSON.stringify(model.document.to_dict(), "", true) and not model.can_undo(), "非法上限不修改地图或撤销历史")
	_expect_ok(model.set_module_limit(256), "模块上限支持关卡规则的最大值")
	_expect(model.get_module_limit() == 256 and model.is_dirty(), "合法上限标记地图待保存")
	_expect(_json_equal(model.document.properties.level.future_rule, {"mode": "keep"}) and _json_equal(model.document.properties.author_data, [1, 2]), "编辑上限保留关卡及地图扩展属性")
	_expect(model.undo() and before == JSON.stringify(model.document.to_dict(), "", true), "撤销恢复未配置上限的原始字段状态")
	_expect(model.redo() and model.get_module_limit() == 256, "重做恢复上限")
	document.properties.level = "作者待修复的数据"
	model.replace_document(document)
	_expect_error(model.set_module_limit(4), "损坏的level对象不能被上限控件静默覆盖")
	_expect(model.document.properties.level == "作者待修复的数据" and not model.is_dirty(), "拒绝时保留损坏原文供元数据编辑器修复")


## 单个模块每 tick 按速度前进，并准确截断最后一步到请求距离。
func _test_move_speed_and_exact_distance() -> void:
	var world := _world(_filled_document())
	if world == null:
		return
	var start := world.player.position
	var speed := float(_content.get_module("movement").properties["move_speed"])
	var command := _move(world, 0.0, 2.37)
	if command == null:
		return
	_expect_position(world.player.position, start, "入队不会立即更新位置")
	world.step()
	_expect_position(world.player.position, start + Vector2(minf(speed * 0.1, 2.37), 0.0), "每 tick 按固定 0.1 秒移动")
	_expect(world.tick_index == 1, "世界以整数 tick 计数")
	_finish(world, command)
	_expect(command.state == MovementCommand.State.COMPLETED, "可通行路径完成移动")
	_expect_position(world.player.position, start + Vector2(2.37, 0.0), "终点精确匹配非整 tick 距离")
	_expect(absf(command.traveled_distance - 2.37) < 0.0001, "命令报告实际移动距离")


## 两个相邻移动模块的能力贡献相加，被禁用模块不再贡献速度。
func _test_stacked_modules() -> void:
	var document := _filled_document()
	document.player_spawn["modules"].append({"id": "second_drive", "module_id": "movement", "offset": {"x": 0.5, "y": 0.0}})
	var world := _world(document)
	if world == null:
		return
	var start := world.player.position
	var speed := float(_content.get_module("movement").properties["move_speed"])
	var command := _move(world, 0.0, 3.0)
	if command == null:
		return
	world.step()
	_expect_position(world.player.position, start + Vector2(speed * 0.2, 0.0), "两个模块速度相加")
	world.player.modules[1].available = false
	var previous := world.player.position
	world.step()
	_expect_position(world.player.position, previous + Vector2(speed * 0.1, 0.0), "禁用模块后速度实时减少")


## 设计角度中 90° 朝上，映射到 Godot 世界负 Y 方向。
func _test_angle_direction() -> void:
	var world := _world(_filled_document())
	if world == null:
		return
	var command := _move(world, 90.0, 1.0)
	if command == null:
		return
	_finish(world, command)
	_expect_position(world.player.position, Vector2(0.5, 1.5), "90° 向上移动一单位")
	_expect(command.state == MovementCommand.State.COMPLETED, "向上移动正常完成")


## 未指定地块与地图外均不可通行，并允许模块恰好贴住边界。
func _test_void_and_map_boundary() -> void:
	var document := _filled_document()
	document.set_tile(Vector2i(2, 2), "")
	var world := _world(document)
	if world == null:
		return
	var command := _move(world, 0.0, 4.0)
	if command == null:
		return
	_finish(world, command)
	_expect(command.state == MovementCommand.State.BLOCKED, "地板内的 void 阻止移动")
	_expect_position(world.player.position, Vector2(1.75, 2.5), "整个模块在 void 前停止")
	world = _world(_filled_document(8, 6, Vector2(0.25, 2.5)))
	if world == null:
		return
	command = _move(world, 90.0, 0.7)
	if command == null:
		return
	_finish(world, command)
	_expect(command.state == MovementCommand.State.COMPLETED, "贴地图边缘平行移动不被误挡")
	command = _move(world, 180.0, 1.0)
	if command == null:
		return
	_finish(world, command)
	_expect(command.state == MovementCommand.State.BLOCKED, "地图边界同样属于不可通行区域")
	_expect(absf(world.player.position.x - 0.25) < 0.0001, "边界处不允许向外推进")


## 出生时也检查完整模块占地，不能只检查中心点。
func _test_spawn_footprint() -> void:
	var document := _filled_document(4, 3, Vector2(1.9, 1.5))
	document.cells.clear()
	document.set_tile(Vector2i(1, 1), "floor")
	_expect_error(SimulationWorld.create(document, _content), "中心在地板但边缘进入 void 的出生点无效")
	document = _filled_document(4, 3, Vector2(0.1, 1.5))
	_expect_error(SimulationWorld.create(document, _content), "模块边缘越出地图的出生点无效")
	document = _filled_document()
	document.player_spawn["modules"].append({"id": "overlapping_drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}})
	_expect_error(SimulationWorld.create(document, _content), "模块占地重叠的装配必须失败")


## 分离模块之间的空隙没有实体占地，不能被整机包围盒误判。
func _test_separated_module_footprints() -> void:
	var document := _filled_document(5, 3, Vector2(2.5, 1.5))
	document.cells.clear()
	document.set_tile(Vector2i(1, 1), "floor")
	document.set_tile(Vector2i(3, 1), "floor")
	document.player_spawn["modules"] = [
		{"id": "left", "module_id": "movement", "offset": {"x": -1.0, "y": 0.0}},
		{"id": "right", "module_id": "movement", "offset": {"x": 1.0, "y": 0.0}},
	]
	var world := _world(document)
	if world == null:
		return
	var command := _move(world, 90.0, 0.2)
	if command == null:
		return
	_finish(world, command)
	_expect(command.state == MovementCommand.State.COMPLETED, "只有真实模块占地参与碰撞")
	_expect_position(world.player.position, Vector2(2.5, 1.3), "间隙跨 void 的机器可以沿自身地板移动")


## 单 tick 跨越整格的高速移动仍必须停在途中空洞的第一接触点。
func _test_high_speed_gap() -> void:
	var content := _fast_content()
	if content == null:
		return
	var document := _filled_document(8, 3, Vector2(0.5, 1.5))
	document.set_tile(Vector2i(2, 1), "")
	var world := _world(document, content)
	if world == null:
		return
	var command := _move(world, 0.0, 6.0)
	if command == null:
		return
	world.step()
	_expect(command.state == MovementCommand.State.BLOCKED, "高速命令不能跨过中间空洞")
	_expect_position(world.player.position, Vector2(1.75, 1.5), "高速扫掠停在准确接触位置")


## 有限但极大的 double 输入不能在 Vector2 转换时溢出或绕过地图边界。
func _test_extreme_finite_speed() -> void:
	var content := _fast_content(1.0e100)
	if content == null:
		return
	var world := _world(_filled_document(8, 3, Vector2(0.5, 1.5)), content)
	if world == null:
		return
	var command := _move(world, 0.0, 1.0e100)
	if command == null:
		return
	world.step()
	_expect(command.state == MovementCommand.State.BLOCKED, "极大有限速度仍受地图边界阻挡")
	_expect(world.player.position.is_finite(), "极大输入不会污染位置为无穷或 NaN")
	_expect_position(world.player.position, Vector2(7.75, 1.5), "极大位移停在模块恰好贴住边界的位置")


## 对角扫掠必须检测中途碰到的 void 角，不能只检查最终占地。
func _test_diagonal_corner() -> void:
	var content := _fast_content()
	if content == null:
		return
	var document := _filled_document(5, 5, Vector2(0.5, 2.5))
	document.set_tile(Vector2i(1, 1), "")
	var world := _world(document, content)
	if world == null:
		return
	var command := _move(world, 45.0, 2.0)
	if command == null:
		return
	world.step()
	_expect(command.state == MovementCommand.State.BLOCKED, "对角线不能切入 void 角")
	_expect_position(world.player.position, Vector2(0.75, 2.25), "对角扫掠停在首次接触点")


## 通过公开接口新增的机器也必须使用同一套 void 通行规则。
func _test_other_machine_void() -> void:
	var document := _filled_document()
	document.set_tile(Vector2i(2, 3), "")
	var world := _world(document)
	if world == null:
		return
	var spawn: Dictionary = document.player_spawn.duplicate(true)
	spawn["position"]["y"] = 3.5
	var created := MachineFactory.create_machine("second", spawn, world.document, _content, ModuleBehaviorRegistry.create_default())
	if not _expect_ok(created, "可装配第二台机器"):
		return
	var machine: MachineInstance = created.value
	if not _expect_ok(world.add_machine(machine), "可将机器加入世界"):
		return
	var requested := world.request_move(machine.id, 0.0, 4.0)
	if not _expect_ok(requested, "可向非玩家机器发出移动命令"):
		return
	var command: MovementCommand = requested.value
	_finish(world, command)
	_expect(command.state == MovementCommand.State.BLOCKED, "非玩家机器同样不能进入 void")
	_expect_position(machine.position, Vector2(1.75, 3.5), "第二台机器停在自身路径的 void 前")


## 命令边界拒绝无效输入，忙碌时不覆盖正在执行的命令。
func _test_invalid_and_busy_commands() -> void:
	var world := _world(_filled_document())
	if world == null:
		return
	_expect_error(world.request_move("unknown_machine", 0.0, 1.0), "未知机器 ID 必须失败")
	_expect_error(world.request_move(world.player.id, true, 1.0), "角度不能是布尔值")
	_expect_error(world.request_move(world.player.id, INF, 1.0), "无限角度必须失败")
	_expect_error(world.request_move(world.player.id, 0.0, NAN), "非数值距离必须失败")
	_expect_error(world.request_move(world.player.id, 0.0, -1.0), "负数距离必须失败")
	var command := _move(world, 0.0, 1.0)
	if command == null:
		return
	_expect_error(world.request_move(world.player.id, 90.0, 1.0), "已有命令时拒绝并发覆盖")
	_finish(world, command)
	_expect_position(world.player.position, Vector2(1.5, 2.5), "被拒绝命令不会改变原命令路线")


## 结束信号只发出一次，订阅者能观察到本 tick 已提交的最终位置。
func _test_command_completion_signal() -> void:
	var world := _world(_filled_document())
	if world == null:
		return
	var command := _move(world, 0.0, 0.01)
	if command == null:
		return
	var observed: Array = [0, Vector2.ZERO, 0]
	# 用途：保存命令完成回调观察到的状态，验证通知发生在位置提交之后。
	command.finished.connect(func(_completed: MovementCommand) -> void:
		observed[0] += 1
		observed[1] = world.player.position
	)
	# 用途：独立统计世界级通知，供未来解释器或界面订阅者使用。
	world.command_finished.connect(func(_completed: MovementCommand) -> void:
		observed[2] += 1
	)
	world.step()
	world.step()
	_expect(observed[0] == 1 and observed[2] == 1, "每个完成命令只发出一次两级结束通知")
	_expect_position(observed[1], Vector2(0.51, 2.5), "回调可观察到完成后位置")
	world.stop()
	_expect(observed[0] == 1, "停止世界不会重复通知已经完成的命令")


## 停止世界取消待执行命令，停止后的 tick 不再改变机器位置。
func _test_cancellation() -> void:
	var world := _world(_filled_document())
	if world == null:
		return
	var command := _move(world, 0.0, 3.0)
	if command == null:
		return
	world.step()
	var stopped_at := world.player.position
	world.stop()
	_expect(command.state == MovementCommand.State.CANCELLED, "停止模拟取消运行中的命令")
	world.step()
	_expect_position(world.player.position, stopped_at, "停止后不继续推进机器")
	_expect_ok(world.request_move(world.player.id, 0.0, 1.0), "取消后释放移动通道，可以接受后续命令")


## 只递归清理本次测试的独占目录，永远不触碰其他 user:// 数据。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in directory.get_directories():
		_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)
