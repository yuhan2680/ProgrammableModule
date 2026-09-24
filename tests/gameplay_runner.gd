extends SceneTree
## 游戏层回归入口：把关卡、装配、草稿和程序会话作为公开 API 验证。
## 所有磁盘数据均写入本次独占的 user://tests 目录，不影响玩家真实进度。

const SOLUTION := "main() {\n    move(0, 4)\n    move(90, 3)\n    move(180, 4)\n    move(90, 3)\n    move(0, 4)\n}\n"

var _content: ContentRegistry
var _builtin: LevelDefinition
var _root_path: String
var _assertions := 0
var _failures := 0
var _current_test := "初始化"


## 在场景树初始化后运行，结束时向包装脚本返回明确退出状态。
func _initialize() -> void:
	call_deferred("_run")


## 按顺序执行用例，准备失败时及时退出，避免级联空值报错。
func _run() -> void:
	_root_path = "user://tests/gameplay_%s" % Time.get_ticks_usec()
	_content = ContentRegistry.new()
	if not _ok(_content.load_directories(), "内置内容可以加载"):
		quit(1)
		return
	var catalog := LevelCatalog.new()
	catalog.user_directory = _root_path.path_join("initial_imports")
	if not _ok(catalog.refresh(_content), "空用户目录下可以加载内置关卡"):
		quit(1)
		return
	if not _expect(catalog.levels.size() == 15 and catalog.levels[14].id == "level_015" and catalog.levels[14].order == 15, "第一至第十五关按顺序完整加载"):
		quit(1)
		return
	_builtin = catalog.levels[0]
	var cases: Array[Callable] = [
		_test_first_level_definition,
		_test_first_level_route,
		_test_level_metadata_validation,
		_test_sandbox_import,
		_test_catalog_errors_are_isolated,
		_test_assembly_starts_empty,
		_test_assembly_limits,
		_test_assembly_allowed_modules,
		_test_assembly_reentrant_capacity,
		_test_assembly_geometry,
		_test_assembly_center_and_edges,
		_test_assembly_center_repair,
		_test_assembly_disconnection_repair,
		_test_assembly_mixed_sizes,
		_test_restored_assembly_rules,
		_test_assembly_names_and_copy,
		_test_assembly_spawn_validation,
		_test_draft_round_trip,
		_test_draft_keys_and_corruption,
		_test_session_requires_assembly,
		_test_session_success,
		_test_session_goal_crossing,
		_test_session_parse_and_goal_failure,
		_test_session_void_failure,
		_test_session_pause_and_reset,
	]
	for test_case in cases:
		_current_test = str(test_case.get_method())
		test_case.call()
	_remove_test_tree(_root_path)
	print("游戏回归完成：%d 个用例，%d 项断言，%d 项失败。" % [cases.size(), _assertions, _failures])
	quit(0 if _failures == 0 else 1)


## 记录可恢复断言，让一次测试显示所有独立失败。
func _expect(condition: bool, message: String) -> bool:
	_assertions += 1
	if not condition:
		_failures += 1
		push_error("[%s] %s" % [_current_test, message])
	return condition


## 检查 DataResult 成功，并把底层校验信息附到断言中。
func _ok(result: DataResult, message: String) -> bool:
	# 依赖脚本编译失败时 Godot 可能返回 null；必须记录失败而非让用例静默中断。
	if result == null:
		return _expect(false, message + "；未返回 DataResult，请检查脚本编译日志。")
	return _expect(result.is_ok(), message + "；" + "; ".join(result.errors))


## 失败结果必须携带可向玩家展示的原因，不能只返回空值。
func _error(result: DataResult, message: String) -> void:
	_expect(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 统一按 JSON 语义比较，消除 Godot 解码时整数变浮点数的差异。
func _json_equal(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))


## 构造足够宽的地板区域，避免一般装配测试被第一关窄路径影响。
func _document(module_limit: int = 2) -> MapDocument:
	var document := MapDocument.new()
	document.id = "test_level"
	document.display_name = "测试关卡"
	document.width = 12
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {
		"position": {"x": 5.5, "y": 5.5},
		"modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}],
	}
	document.properties["level"] = {
		"module_limit": module_limit,
		"allowed_modules": ["movement"],
		"goal": {"position": {"x": 9.5, "y": 5.5}, "radius": 0.2},
		"starter_program": "main() {\n    move(0, 1)\n}\n",
		"description": "用于隔离游戏模型测试的地图。",
	}
	return document


## 从合法地图建立关卡，失败时调用方不再继续创建依赖对象。
func _level(document: MapDocument = null) -> LevelDefinition:
	var result := LevelDefinition.from_document(_document() if document == null else document, _content)
	if not _ok(result, "合法地图可以建立关卡定义"):
		return null
	return result.value as LevelDefinition


## 创建本次独占路径中的文本文件，支持损坏 JSON 用例。
func _write(relative_path: String, source: String) -> String:
	var path := _root_path.path_join(relative_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _expect(file != null, "可创建临时文件 " + relative_path):
		return ""
	file.store_string(source)
	file.close()
	return path


## 为每组草稿用例建立不同目录，隔离正常数据与故意损坏的数据。
func _store(name: String) -> GameDraftStore:
	var draft_store := GameDraftStore.new()
	draft_store.directory = _root_path.path_join(name)
	return draft_store


## 测试需运动时显式模拟玩家安装首个模块，绝不在构造器中恢复隐藏默认布局。
func _install_test_drive(assembly: AssemblyModel) -> bool:
	if not _expect(assembly.modules.is_empty(), "新建的玩家装配必须为空"):
		return false
	return _ok(assembly.add_module("movement", Vector2.ZERO, "drive"), "测试显式安装一个移动模块")


## 验证首关关键设计数据及保留给玩家的未完成程序模板。
func _test_first_level_definition() -> void:
	_expect(_builtin.module_limit == 1, "第一关仅允许一个模块")
	_expect(_builtin.allowed_modules == PackedStringArray(["movement"]), "第一关只提供移动模块")
	_expect(_builtin.has_goal, "第一关配置终点")
	_expect(_builtin.goal_position.distance_to(Vector2(5.5, 1.5)) < 0.0001, "终点为 (5.5, 1.5)")
	var position: Dictionary = _builtin.document.player_spawn["position"]
	_expect(Vector2(position.x, position.y).distance_to(Vector2(1.5, 7.5)) < 0.0001, "出生位置为 (1.5, 7.5)")
	_expect(_builtin.starter_program.contains("main"), "起始程序介绍 main 入口")
	_expect(_builtin.starter_program.count("move(") <= 1, "起始程序不直接填入完整通关答案")
	_expect(_builtin.document.get_tile_id(Vector2i(3, 6)).is_empty(), "S 路径之间保留 void")


## 独立于语言和会话检查五段设计路线，确保地形完整支撑默认模块。
func _test_first_level_route() -> void:
	var result := SimulationWorld.create(_builtin.document, _content)
	if not _ok(result, "第一关可建立模拟世界"):
		return
	var world: SimulationWorld = result.value
	for segment: Vector2 in [Vector2(0, 4), Vector2(90, 3), Vector2(180, 4), Vector2(90, 3), Vector2(0, 4)]:
		var requested := world.request_move(world.player.id, segment.x, segment.y)
		if not _ok(requested, "设计路线可提交 move"):
			return
		var command: MovementCommand = requested.value
		# 每段最多四单位，1000 tick 上限能同时捕获意外死循环。
		for _tick in 1000:
			if command.is_finished():
				break
			world.step()
		_expect(command.state == MovementCommand.State.COMPLETED, "设计路线的每段均可通行")
	_expect(world.player.position.distance_to(Vector2(5.5, 1.5)) < 0.0001, "五段路线精确抵达设计终点")


## 关卡扩展字段必须显式校验，不能借地图 properties 跳过类型检查。
func _test_level_metadata_validation() -> void:
	var document := _document()
	_expect(_level(document) != null, "完整关卡元数据有效")
	document.properties["level"]["module_limit"] = true
	_error(LevelDefinition.from_document(document, _content), "模块数量限制不能是布尔值")
	document = _document()
	document.properties["level"]["allowed_modules"] = ["unknown_module"]
	_error(LevelDefinition.from_document(document, _content), "可用模块必须引用已注册内容")
	document = _document()
	document.properties["level"]["goal"]["radius"] = -1
	_error(LevelDefinition.from_document(document, _content), "终点半径必须为正")
	document = _document()
	document.properties["level"]["goal"]["position"]["x"] = true
	_error(LevelDefinition.from_document(document, _content), "终点位置不能把布尔值当作数字")
	document = _document()
	document.properties["level"]["goal"]["position"]["x"] = 99
	_error(LevelDefinition.from_document(document, _content), "终点不能位于地图外")


## 没有关卡配置的编辑器地图仍可导入为自由测试关卡。
func _test_sandbox_import() -> void:
	var document := _document()
	document.properties.erase("level")
	var level := _level(document)
	if level == null:
		return
	_expect(not level.has_goal, "普通地图以无终点沙盒载入")
	_expect(level.document.id == document.id, "导入保留原地图身份")
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.build_document(), "沙盒显式装配后可以生成运行地图")
	var session := GameSession.create(level, _content)
	if not _install_test_drive(session.assembly):
		return
	session.source = "main() {\n    move(0, 1)\n}\n"
	if _ok(session.run(), "无目标导入地图可以实际执行玩家程序"):
		_finish_session(session)
		_expect(session.state == GameSession.State.EDITING, "沙盒程序结束后回到编辑状态，不错误要求终点")
		_expect(session.world.player.position.distance_to(Vector2(6.5, 5.5)) < 0.0001, "沙盒程序确实完成移动")


## 目录中一个损坏或重复关卡不阻断其他有效关卡，且目录操作没有 UI 副作用。
func _test_catalog_errors_are_isolated() -> void:
	var valid := _document()
	valid.id = "imported_test_level"
	_write("catalog/good.json", JSON.stringify(valid.to_dict()))
	_write("catalog/bad.json", "{ invalid json")
	_write("catalog/duplicate_builtin.json", JSON.stringify(_builtin.document.to_dict()))
	var catalog := LevelCatalog.new()
	catalog.user_directory = _root_path.path_join("catalog")
	var ensured := catalog.ensure_import_directory()
	if _ok(ensured, "可以创建并取得导入目录"):
		_expect(DirAccess.dir_exists_absolute(str(ensured.value)), "返回的导入目录真实存在")
	catalog.refresh(_content)
	var found := false
	var builtin_count := 0
	for level in catalog.levels:
		found = found or level.id == valid.id
		if level.id == _builtin.id:
			builtin_count += 1
	_expect(found, "坏文件不会阻止有效导入关卡出现")
	_expect(builtin_count == 1, "重复 ID 不覆盖或复制内置关卡")
	_expect(not catalog.errors.is_empty(), "坏文件产生可展示的诊断")


## 每次进入关卡都从空白开始，各次工作副本和原始地图模板互不影响。
func _test_assembly_starts_empty() -> void:
	var original := _builtin.document.to_dict()
	var first := AssemblyModel.create(_builtin, _content)
	var second := AssemblyModel.create(_builtin, _content)
	_expect(first.modules.is_empty() and second.modules.is_empty(), "首关即使有地图模板也不会自动预装模块")
	_expect(not _builtin.document.player_spawn.modules.is_empty(), "保留底层地图出生模板，未改变地图格式")
	_ok(first.add_module("movement", Vector2.ZERO), "玩家可以主动添加首个模块")
	_expect(second.modules.is_empty(), "修改一份装配不会污染另一次进入的空草稿")
	_expect(_json_equal(_builtin.document.to_dict(), original), "玩家装配不改写地图出生模板")


## 装配编辑允许临时空机器，但运行必须满足关卡数量与能力限制。
func _test_assembly_limits() -> void:
	var level := _level(_document(1))
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_error(assembly.add_module("movement", Vector2(0.5, 0)), "第一台机器不能超过关卡模块上限")
	_error(assembly.add_module("unknown_module", Vector2(0.5, 0)), "未知模块不能进入装配")
	_ok(assembly.remove_module(0), "可在编辑时删除最后一个模块")
	_expect(assembly.modules.is_empty(), "删除后装配可以暂时为空")
	_error(assembly.validate(), "空装配不能通过运行校验")
	_ok(assembly.add_module("movement", Vector2.ZERO, "drive"), "可向空装配重新放入移动模块")
	_ok(assembly.validate(), "恢复的装配可以通过校验")


## 内容注册成功不等于本关已解锁，模型必须再次执行 allowed_modules 限制。
func _test_assembly_allowed_modules() -> void:
	var variant: Dictionary = _content.get_module("movement").raw.duplicate(true)
	variant["id"] = "locked_movement"
	_write("extra_modules/locked_movement.json", JSON.stringify(variant))
	var content := ContentRegistry.new()
	var loaded := content.load_directories(
		PackedStringArray(["res://data/modules", _root_path.path_join("extra_modules")]),
		PackedStringArray(["res://data/tiles"])
	)
	if not _ok(loaded, "测试内容注册表包含一个尚未解锁的模块变体"):
		return
	var parsed := LevelDefinition.from_document(_document(2), content)
	if not _ok(parsed, "关卡仍只允许普通移动模块"):
		return
	var assembly := AssemblyModel.create(parsed.value, content)
	_error(assembly.add_module("locked_movement", Vector2.ZERO), "已注册但未允许的模块不能在空装配中新增")
	_expect(assembly.modules.is_empty(), "拒绝未解锁模块后仍保持空装配")
	if not _install_test_drive(assembly):
		return
	_error(assembly.add_module("locked_movement", Vector2(0.5, 0)), "有剩余容量时也不能绕过模块解锁限制")
	_expect(assembly.modules.size() == 1, "被拒绝的模块不会消耗装配数量")
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "second"), "允许模块可以填满剩余容量")
	_error(assembly.add_module("movement", Vector2(1, 0), "third"), "填满容量后模型继续拒绝新增")


## changed 是同步信号；回调重新发起新增时也必须看到已提交的容量。
func _test_assembly_reentrant_capacity() -> void:
	var level := _level(_document(1))
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	var observed: Array = [0, null]
	# 用途：模拟界面监听器在第一次变更通知中再次请求添加模块。
	assembly.changed.connect(func() -> void:
		observed[0] += 1
		if observed[0] == 1:
			observed[1] = assembly.add_module("movement", Vector2(0.5, 0), "second")
	)
	_ok(assembly.add_module("movement", Vector2.ZERO, "drive"), "首个模块提交成功")
	_error(observed[1], "同步回调中的新增同样受模块上限限制")
	_expect(assembly.modules.size() == 1 and observed[0] == 1, "拒绝重入新增时不多装模块、不发额外变更信号")
	# 断开捕获自身模型的测试闭包，避免测试人为制造引用环。
	for connection: Dictionary in assembly.changed.get_connections():
		assembly.changed.disconnect(connection.callable)


## 检查半格吸附、装配范围和真实矩形重叠，失败修改应保持原装配。
func _test_assembly_geometry() -> void:
	var level := _level()
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "second"), "相邻模块恰好贴边有效")
	var before: Array = assembly.modules.duplicate(true)
	_error(assembly.move_module(1, Vector2.ZERO), "不能把模块移到已有实体占地")
	_error(assembly.move_module(1, Vector2(0.25, 0)), "图形装配仅接受半格偏移")
	_error(assembly.move_module(1, Vector2(4.5, 0)), "图形装配偏移不能超过四格")
	_expect(_json_equal(assembly.modules, before), "被拒绝的移动不会更改装配")
	_error(assembly.move_module(1, Vector2(1.0, 0)), "半格网格上留缝的位置仍不能接受")
	_ok(assembly.move_module(1, Vector2(0, 0.5)), "可沿中心模块边缘移动到另一个贴边位置")


## 首个模块固定在中心，后续可以从任意已有模块分支，但角点和间隙不连通。
func _test_assembly_center_and_edges() -> void:
	var level := _level(_document(5))
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	_error(assembly.add_module("movement", Vector2(0.5, 0)), "首个模块不能放在非中心网格点")
	_expect(assembly.modules.is_empty(), "拒绝首个非中心放置后仍为空装配")
	if not _install_test_drive(assembly):
		return
	_error(assembly.move_module(0, Vector2(0.5, 0)), "唯一模块不能移离中心")
	_expect(assembly.modules[0].offset == {"x": 0.0, "y": 0.0}, "拒绝移动后中心模块位置保持不变")
	_error(assembly.add_module("movement", Vector2(0.5, 0.5), "corner"), "只接触一个角点的放置不算贴边")
	_error(assembly.add_module("movement", Vector2(1, 0), "gap"), "与已有模块留缝不能添加")
	_error(assembly.add_module("movement", Vector2.ZERO, "overlap"), "重叠不属于贴边连接")
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "right"), "在中心右边贴边新增")
	_ok(assembly.add_module("movement", Vector2(0, 0.5), "branch"), "允许贴中心形成分支，不必贴最后一次新增模块")
	_error(assembly.move_module(2, Vector2(1, 0.5)), "移动时只接触其它模块角点也应失败")
	_ok(assembly.validate(), "有中心的贴边分支通过最终校验")


## 多模块移动可以暂时腾空中心，草稿仍可重命名并通过补回中心修复。
func _test_assembly_center_repair() -> void:
	var level := _level(_document(4))
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "right"), "先添加可承接移动的相邻模块")
	_ok(assembly.move_module(0, Vector2(0.5, 0.5)), "多模块移动目标贴边时允许暂时失去中心")
	_ok(assembly.validate_editing(), "无中心草稿可通过基础编辑检查")
	var missing_center := assembly.validate()
	_error(missing_center, "无中心装配不能完成确认")
	_expect(missing_center.errors[0].contains("机器中心 (0, 0) 必须安装"), "缺中心提供独立且可修复的原因")
	_error(assembly.build_document(), "无中心草稿不能生成运行地图")
	_ok(assembly.rename_module(0, "relocated"), "缺中心时仍能编辑实例名")
	_ok(assembly.add_module("movement", Vector2.ZERO, "replacement"), "可新增另一个实例填回中心，不依赖原始ID")
	_ok(assembly.validate(), "补中心后整个连接图恢复有效")
	_ok(assembly.remove_module(2), "允许再次删除中心实例")
	_expect(assembly.modules.size() == 2, "删除中心不会偷偷补回模板")
	_ok(assembly.validate_editing(), "删除中心后的剩余草稿仍可保存与恢复编辑")
	_error(assembly.validate(), "删除中心后确认继续被拒绝")
	_ok(assembly.add_module("movement", Vector2.ZERO, "new_center"), "删除后可再次补回中心")
	_ok(assembly.validate(), "补回中心后恢复完整装配")


## 删除桥接模块不会自动删除分支，但最终检查必须要求所有模块连回中心。
func _test_assembly_disconnection_repair() -> void:
	var level := _level(_document(4))
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "bridge"), "安装中间桥接模块")
	_ok(assembly.add_module("movement", Vector2(1, 0), "tip"), "通过桥接模块延伸连接链")
	_ok(assembly.remove_module(1), "删除桥接允许留下临时断开的末端")
	_expect(assembly.modules.size() == 2, "删除桥接不会级联移除其它模块")
	_ok(assembly.validate_editing(), "断连草稿通过基础编辑检查")
	var disconnected := assembly.validate()
	_error(disconnected, "有中心但断连的装配不能运行")
	_expect(disconnected.errors[0].contains("贴边连接到中心模块"), "断连错误与缺中心错误可区分")
	_ok(assembly.rename_module(1, "outer_tip"), "断连草稿仍可重命名以便修复")
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "new_bridge"), "补入桥接即可连接原有分支")
	_ok(assembly.validate(), "桥接恢复后从中心可达全部模块")
	_ok(assembly.build_document(), "连接修复后的装配可生成运行地图")


## 连接按内容定义的矩形尺寸计算，不把所有模块硬编码成半格方块。
func _test_assembly_mixed_sizes() -> void:
	var large: Dictionary = _content.get_module("movement").raw.duplicate(true)
	large["id"] = "large_movement"
	large["size"] = {"width": 1.5, "height": 1.5}
	_write("sized_modules/large.json", JSON.stringify(large))
	var content := ContentRegistry.new()
	if not _ok(content.load_directories(PackedStringArray(["res://data/modules", _root_path.path_join("sized_modules")]), PackedStringArray(["res://data/tiles"])), "异尺寸模块由真实JSON内容注册"):
		return
	var document := _document(4)
	document.properties["level"]["allowed_modules"] = ["movement", "large_movement"]
	var parsed := LevelDefinition.from_document(document, content)
	if not _ok(parsed, "测试关卡允许大小两种移动模块"):
		return
	var assembly := AssemblyModel.create(parsed.value, content)
	_error(assembly.add_module("large_movement", Vector2(0.5, 0), "large"), "大模块覆盖原点仍不算中心，中心偏移必须精确为零")
	_ok(assembly.add_module("large_movement", Vector2.ZERO, "large"), "大模块可以作为中心模块")
	_error(assembly.add_module("movement", Vector2(1, 1), "corner"), "不同尺寸模块角点接触仍不能放置")
	_error(assembly.add_module("movement", Vector2(1.5, 0), "gap"), "不同尺寸模块实际留缝时不能放置")
	_error(assembly.add_module("movement", Vector2(0.5, 0), "overlap"), "半格偏移落入大模块内部时属于重叠")
	_ok(assembly.add_module("movement", Vector2(1, 0.5), "small"), "大模块边缘与小模块正长度接触允许放置")
	_ok(assembly.move_module(1, Vector2(-1, -0.5)), "小模块可移到大模块另一侧真实边缘")
	_ok(assembly.validate(), "异尺寸模块通过完整中心连通校验")
	_ok(assembly.build_document(), "异尺寸连接装配具有有效出生占地")
	# 碰撞边界允许浮点比较误差，但接触长度只要求严格大于零，不能另设最小长度。
	content.get_module("large_movement").size = Vector2(1.5, 0.500001)
	var short_contact := AssemblyModel.create(parsed.value, content)
	_ok(short_contact.add_module("large_movement", Vector2.ZERO, "narrow"), "可安装较薄的异尺寸中心模块")
	_ok(short_contact.add_module("movement", Vector2(1, 0.5), "small_overlap"), "很短但正长度的实际边缘接触仍属于连接")
	_ok(short_contact.validate(), "正长度接触不因额外阈值被误判为角点")


## 合法存储的旧草稿仍须重新检查最终规则，恢复编辑不能绕过中心与连通要求。
func _test_restored_assembly_rules() -> void:
	var level := _level(_document(4))
	if level == null:
		return
	var draft_store := _store("layout_repair")
	var cases: Array = [
		[{"id": "off_center", "module_id": "movement", "offset": {"x": 0.5, "y": 0}}],
		[{"id": "center", "module_id": "movement", "offset": {"x": 0, "y": 0}}, {"id": "disconnected", "module_id": "movement", "offset": {"x": 1, "y": 0}}],
	]
	for index in range(cases.size()):
		var level_id := "repair_%d" % index
		_ok(draft_store.save_draft(level_id, "main() {}", cases[index]), "待修复布局可以作为玩家草稿保存")
		var loaded := draft_store.load_draft(level_id)
		if not _ok(loaded, "待修复布局能逐字段恢复"):
			return
		var assembly := AssemblyModel.create(level, _content)
		assembly.modules = loaded.value["modules"].duplicate(true)
		_ok(assembly.validate_editing(), "旧草稿满足基础规则时允许恢复编辑")
		var last_index := assembly.modules.size() - 1
		_ok(assembly.rename_module(last_index, "renamed"), "恢复的不完整草稿允许修改名称")
		var unchanged_offset: Dictionary = assembly.modules[last_index]["offset"]
		_ok(assembly.move_module(last_index, Vector2(float(unchanged_offset.x), float(unchanged_offset.y))), "属性面板提交未变化位置不能阻断不完整草稿的重命名")
		_error(assembly.validate(), "旧草稿不能绕过新中心和连通规则")
		_error(assembly.build_document(), "不完整旧草稿不能生成运行地图")


## 模块命名满足 DSL 标识符要求，构建运行文档不会修改原关卡。
func _test_assembly_names_and_copy() -> void:
	var level := _level()
	if level == null:
		return
	var original := level.document.to_dict()
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.add_module("movement", Vector2(0.5, 0), "second"), "可使用独立模块实例名")
	_error(assembly.rename_module(1, "drive"), "模块实例名不能重复")
	_error(assembly.rename_module(1, "invalid-name"), "DSL 实例名不能包含连字符")
	_error(assembly.rename_module(1, "9drive"), "DSL 实例名不能以数字开头")
	_ok(assembly.rename_module(1, "right_drive"), "字母与下划线构成有效实例名")
	var built := assembly.build_document()
	if _ok(built, "可以构建设计后的地图副本"):
		_expect(built.value.player_spawn["modules"].size() == 2, "运行地图包含两模块装配")
	_expect(_json_equal(level.document.to_dict(), original), "装配修改不会回写关卡文件内容")


## 图形画布上的合法布局也必须在关卡出生地形上得到完整支撑。
func _test_assembly_spawn_validation() -> void:
	var document := _builtin.document.duplicate_document()
	document.properties["level"]["module_limit"] = 2
	var level := _level(document)
	if level == null:
		return
	var assembly := AssemblyModel.create(level, _content)
	if not _install_test_drive(assembly):
		return
	_ok(assembly.add_module("movement", Vector2(0, -0.5), "above"), "有中心且贴边的第二模块可以编辑")
	_ok(assembly.validate(), "该装配通过中心与连通规则，尚未检查出生地形")
	var unsupported := assembly.build_document()
	_error(unsupported, "实际出生时第二模块伸入上方void，不能运行")
	_expect(unsupported.errors[0].contains("void"), "该用例确实由出生地形失败，而非中心或连接规则失败")
	_ok(assembly.move_module(1, Vector2(0.5, 0)), "将第二模块移到中心右侧仍保持贴边")
	_ok(assembly.build_document(), "修复后两模块都获得地板支撑")


## 程序与装配按关卡保存，中文内容和通关状态在往返后保持一致。
func _test_draft_round_trip() -> void:
	var draft_store := _store("drafts")
	var missing := draft_store.load_draft("never_saved")
	if _ok(missing, "缺失草稿是正常情况"):
		_expect(missing.value == null, "缺失草稿返回 null")
	var source := "main() {\n    // 中文注释：向右\n    move(0, 4)\n}\n"
	var modules: Array = _builtin.document.player_spawn["modules"].duplicate(true)
	_ok(draft_store.save_draft(_builtin.id, source, modules), "程序与装配草稿可保存")
	var loaded := draft_store.load_draft(_builtin.id)
	if _ok(loaded, "草稿可重新加载"):
		_expect(loaded.value["source"] == source, "程序文本逐字保留")
		_expect(_json_equal(loaded.value["modules"], modules), "装配数据完整保留")
	_expect(not draft_store.is_completed(_builtin.id), "未通关关卡初始不显示完成")
	_ok(draft_store.mark_completed(_builtin.id), "可记录关卡完成")
	_expect(draft_store.is_completed(_builtin.id), "完成标记可以读取")
	_ok(draft_store.save_draft(_builtin.id, "main() {\n}\n", modules), "通关后仍可修改程序草稿")
	_expect(draft_store.is_completed(_builtin.id), "修改草稿不会抹除通关记录")


## 存档键不会成为任意路径，损坏草稿返回错误而非崩溃。
func _test_draft_keys_and_corruption() -> void:
	var draft_store := _store("unsafe_keys")
	var modules: Array = _builtin.document.player_spawn["modules"].duplicate(true)
	var saved := draft_store.save_draft("../outside", "main() {\n}\n", modules)
	# 实现可以拒绝异常 ID，也可以用哈希存储；两种策略均须保证目录隔离。
	if saved.is_ok():
		var loaded := draft_store.load_draft("../outside")
		_ok(loaded, "哈希键可以安全回读包含路径字符的原始标识")
	_expect(not FileAccess.file_exists(_root_path.path_join("outside.json")), "原始关卡 ID 不会逃逸草稿目录")
	var corrupt_store := _store("corrupt_draft")
	if not _ok(corrupt_store.save_draft("corrupted", "main() {\n}\n", modules), "先创建有效草稿"):
		return
	var directory := DirAccess.open(corrupt_store.directory)
	var files := directory.get_files()
	if not _expect(not files.is_empty(), "草稿文件确实写入专属目录"):
		return
	for filename in files:
		_write("corrupt_draft/" + filename, "{ broken")
	_error(corrupt_store.load_draft("corrupted"), "损坏草稿必须给出诊断")


## 在有限 tick 内执行会话，防止错误调度使自动测试永远不结束。
func _finish_session(session: GameSession) -> void:
	for _tick in 1000:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_expect(false, "程序会话应在 1000 tick 内结束")


## 空装配无法创建运行世界，原地图中保留的模板不能绕过玩家装配步骤。
func _test_session_requires_assembly() -> void:
	var session := GameSession.create(_builtin, _content)
	_expect(session.assembly.modules.is_empty(), "新会话初始没有玩家模块")
	session.source = SOLUTION
	_error(session.run(), "即使程序正确也必须先组装才能运行")
	_expect(session.world == null and session.runner == null, "拒绝空装配时不生成部分运行状态")
	_expect(session.source == SOLUTION and session.assembly.modules.is_empty(), "运行拒绝不会自动填入模板或改写源程序")


## 用玩家实际程序入口通关第一关，完成事件必须只触发一次。
func _test_session_success() -> void:
	var session := GameSession.create(_builtin, _content)
	if not _install_test_drive(session.assembly):
		return
	session.source = SOLUTION
	var observed := [0]
	# 用途：统计会话完成事件，不触发实际存档或界面操作。
	session.completed.connect(func() -> void:
		observed[0] += 1
	)
	if not _ok(session.run(), "五段路线程序可以运行"):
		return
	_finish_session(session)
	_expect(session.state == GameSession.State.SUCCEEDED, "第一关程序运行后成功通关")
	_expect(session.world.player.position.distance_to(_builtin.goal_position) <= _builtin.goal_radius + 0.0001, "成功时机器确实位于终点半径内")
	session.step()
	_expect(observed[0] == 1, "通关事件只触发一次")


## 高速运动可能在一 tick 内越过小终点，游戏层需检查真实移动线段。
func _test_session_goal_crossing() -> void:
	var content := ContentRegistry.new()
	if not _ok(content.load_directories(), "终点扫掠测试使用独立内容注册表"):
		return
	# 仅调整本用例独占的定义，避免影响其他首关测试的一单位每秒速率。
	content.get_module("movement").properties["move_speed"] = 10.0
	var document := _document(1)
	document.properties["level"]["goal"] = {"position": {"x": 6.0, "y": 5.5}, "radius": 0.1}
	var parsed := LevelDefinition.from_document(document, content)
	if not _ok(parsed, "合法的小范围终点可以加载"):
		return
	var session := GameSession.create(parsed.value, content)
	if not _install_test_drive(session.assembly):
		return
	session.source = "main() {\n    move(0, 2)\n}\n"
	if not _ok(session.run(), "可启动高速经过终点的程序"):
		return
	session.step()
	_expect(session.state == GameSession.State.SUCCEEDED, "单 tick 越过终点范围也应成功")
	var final_position := session.world.player.position
	session.step()
	_expect(session.world.player.position == final_position, "通关后取消剩余指令，不继续移动")


## 语法错误与未达目标是不同失败路径，二者都不能错误记录通关。
func _test_session_parse_and_goal_failure() -> void:
	var session := GameSession.create(_builtin, _content)
	if not _install_test_drive(session.assembly):
		return
	session.source = "move(0, 4)\n"
	_error(session.run(), "缺少 main 的程序不能开始运行")
	session.source = "main() {\n    move(0, 1)\n}\n"
	if not _ok(session.run(), "合法但未完成关卡的程序可以启动"):
		return
	_finish_session(session)
	_expect(session.state == GameSession.State.FAILED, "程序结束却未到达终点时报告失败")
	_expect(not session.message.is_empty(), "失败原因可显示给玩家")


## 程序层将底层 BLOCKED 传播为可恢复失败，不能穿过 void。
func _test_session_void_failure() -> void:
	var session := GameSession.create(_builtin, _content)
	if not _install_test_drive(session.assembly):
		return
	session.source = "main() {\n    move(90, 100)\n}\n"
	if not _ok(session.run(), "朝 void 的语法合法程序可开始"):
		return
	_finish_session(session)
	_expect(session.state == GameSession.State.FAILED, "移动受 void 阻挡会终止程序并报告失败")
	_expect(session.world.player.position.y >= 7.25 - 0.0001, "机器模块不会进入出生点上方 void")


## 暂停冻结逻辑时间，重置保留用户程序和装配以便继续迭代。
func _test_session_pause_and_reset() -> void:
	var session := GameSession.create(_builtin, _content)
	if not _install_test_drive(session.assembly):
		return
	session.source = SOLUTION
	var assembly_before: Array = session.assembly.modules.duplicate(true)
	if not _ok(session.run(), "可启动用于暂停测试的程序"):
		return
	for _tick in 5:
		session.step()
	session.pause()
	var position := session.world.player.position
	var tick_index := session.world.tick_index
	for _tick in 5:
		session.step()
	_expect(session.state == GameSession.State.PAUSED, "暂停后进入暂停状态")
	_expect(session.world.tick_index == tick_index and session.world.player.position == position, "暂停时调用 step 不推进时间或位置")
	session.resume()
	session.step()
	_expect(session.world.tick_index == tick_index + 1, "恢复后从原 tick 继续")
	session.reset()
	_expect(session.state == GameSession.State.EDITING, "重置返回可编辑状态")
	_expect(session.source == SOLUTION, "重置不丢失玩家程序")
	_expect(_json_equal(session.assembly.modules, assembly_before), "重置不丢失模块装配")


## 仅清理本次独占目录；检查前缀后递归，避免触碰真实用户存档。
func _remove_test_tree(path: String) -> void:
	if _root_path.is_empty() or not (path == _root_path or path.begins_with(_root_path + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in directory.get_directories():
		_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)
