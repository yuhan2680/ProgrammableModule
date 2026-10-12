extends SceneTree
## 指令策略回归只修改隔离文档，验证旧图零写入、依赖事务及 JSON 保存边界。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 等待全局脚本类就绪后开始，所有临时 JSON 均使用进程独占目录。
func _initialize() -> void:
	_run.call_deferred()


## 分别覆盖协议、旧图投影、单次修改、撤销和真实编解码，不执行玩家程序。
func _run() -> void:
	_temporary = "user://tests/command_permissions_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "真实内容注册表可加载")
	_test_validation()
	_test_legacy_maps()
	_test_transactions()
	_test_dependencies()
	_test_flag_projection()
	_test_codec()
	_cleanup(_temporary)
	print("COMMAND_PERMISSIONS_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 已有合法教学地图作为数据夹具，保留地形、出生和未知扩展，不另造宽松格式。
func _document() -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	_check(loaded.is_ok(), "第一关可用于合法数据夹具")
	var document: MapDocument = loaded.value
	document.properties["foreign"] = {"text": "keep", "nested": [1, 2, 3]}
	document.properties.level["foreign_rule"] = {"value": 7}
	document.extra["foreign_top"] = "unchanged"
	return document


## 固定目录与实际资料保持一一对应，未知资料 ID 不能借助 JSON 注册执行能力。
func _test_validation() -> void:
	var catalog := CommandCatalog.new()
	_check(catalog.load_directory().is_ok() and catalog.entries.size() == 27, "指令资料仍包含既有 27 项")
	var ids := PackedStringArray()
	for entry: Dictionary in catalog.entries:
		ids.append(entry.id)
	_check(ids == PackedStringArray(CommandPermissions.COMMAND_IDS), "固定权限 ID 与既有资料稳定顺序一致")
	for value in [null, {}, "main", [1], ["main", "unknown_call"], ["main", "main"], [], ["move"], ["main", "ready"], ["main", "radar_event"], ["main", "named_move"]]:
		_check(not MapValidation.check_enabled_commands(value).is_ok(), "指令 JSON 拒绝类型、未知、重复、主入口或依赖缺失 " + str(value))
	_check(MapValidation.check_enabled_commands(["main"]).is_ok(), "只保留必要 main 入口是合法策略")
	_check(MapValidation.check_enabled_commands(Array(CommandPermissions.COMMAND_IDS)).is_ok(), "全部指令闭包可以通过 JSON 验证")
	var incomplete := CommandPermissions.normalize_enabled(["main", "named_move"])
	_check(incomplete.is_ok() and incomplete.value == PackedStringArray(["main", "named_calls", "named_move"]), "显式开启具名移动只补齐总开关，不自动打开广播 move")


## 正式教学地图读取前后内容及旧开关完全相同，编辑器仅返回投影不补写字段。
func _test_legacy_maps() -> void:
	for index in range(1, 17):
		var path := "res://data/levels/level_%03d.json" % index
		var bytes := FileAccess.get_file_as_bytes(path)
		var loaded := MapCodec.load_file(path, _content)
		if not _check(loaded.is_ok(), "旧教学地图可载入 " + path):
			continue
		var document: MapDocument = loaded.value
		var original := document.to_dict()
		var model := MapEditorDocument.new()
		model.replace_document(document, path)
		var ids := model.get_enabled_commands(_content)
		var level := LevelDefinition.from_document(document, _content, path)
		_check(level.is_ok() and not level.value.has_command_policy and level.value.enabled_commands == ids, "旧地图保持无显式策略并得到相同投影 " + path)
		_check(not model.is_dirty() and model._undo_stack.is_empty() and model.document.to_dict() == original, "打开指令设置不改变旧文档或历史 " + path)
		_check(FileAccess.get_file_as_bytes(path) == bytes and not document.properties.level.has("enabled_commands"), "旧 JSON 原件字节与字段保持不变 " + path)
		if level.is_ok():
			for flag: String in CommandPermissions.FLAG_COMMANDS:
				_check(level.value.get(flag) == document.properties.level.get(flag, false), "旧权限布尔值不因新策略投影扩大 " + path + " " + flag)
	var odd := _document()
	odd.properties.level["allow_radar_events"] = true
	var read := LevelDefinition.from_document(odd, _content)
	_check(read.is_ok() and read.value.allow_radar_events and not read.value.allow_radar and not read.value.has_command_policy, "不完整旧权限组合仍按原有布尔字段读取，不擅自补齐")


## 一次点击保存完整新策略与依赖，失败和重复等值提交均不能产生部分修改。
func _test_transactions() -> void:
	var original := _document()
	var model := MapEditorDocument.new()
	model.replace_document(original, "user://levels/unchanged.json")
	var before := model.document.to_dict()
	_check(model.set_command_enabled("tick", true, _content).is_ok(), "启用 tick 提交成功")
	_check(model._undo_stack.size() == 1 and model.is_dirty(), "首次显式开关只创建一个撤销事务")
	_check(model.document.properties.level.enabled_commands is Array and model.document.properties.level.allow_tick == true, "新策略数组与旧家族开关同一事务保存")
	_check(model.document.properties.foreign == original.properties.foreign and model.document.properties.level.foreign_rule == original.properties.level.foreign_rule and model.document.extra == original.extra, "修改指令策略保留嵌套扩展及顶层未知字段")
	_check(model.path == "user://levels/unchanged.json", "指令策略不更改文件绑定")
	var selected := model.document.to_dict()
	_check(model.undo() and model.document.to_dict() == before and not model.is_dirty(), "一次撤销精确恢复旧图和保存点")
	_check(model.redo() and model.document.to_dict() == selected, "一次重做恢复完整指令策略")
	var count := model._undo_stack.size()
	_check(model.set_command_enabled("tick", true, _content).is_ok() and model._undo_stack.size() == count, "重复提交相同显式开关不创建历史")
	for identity in ["main", "unknown"]:
		_check(not model.set_command_enabled(identity, false, _content).is_ok() and model.document.to_dict() == selected and model._undo_stack.size() == count, "无效关闭不改写任何元数据 " + identity)
	_check(not model.set_enabled_commands(["main", "bogus"], _content).is_ok() and model.document.to_dict() == selected, "无效列表不覆盖有效策略")
	model.document.properties["level"] = "broken"
	var broken := model.document.to_dict()
	_check(not model.set_command_enabled("tick", true, _content).is_ok() and model.document.to_dict() == broken, "损坏元数据不能通过空对象覆盖修复")


## 自动前提与关闭后的传递依赖均按完整策略验证，广播与具名调用保持独立。
func _test_dependencies() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	_check(model.set_enabled_commands(["main"], _content).is_ok(), "建立只含主入口的新策略")
	var count := model._undo_stack.size()
	var selected := model.set_command_enabled("ready", true, _content)
	_check(selected.is_ok() and selected.value == PackedStringArray(["main", "named_calls", "if_else", "ready"]), "ready 原子开启条件和具名总开关")
	_check(model._undo_stack.size() == count + 1 and model.undo() and model.get_enabled_commands(_content) == PackedStringArray(["main"]), "ready 多项变化仍只有一次撤销")
	model.set_command_enabled("radar_event", true, _content)
	var ids := model.get_enabled_commands(_content)
	_check(ids == PackedStringArray(["main", "named_calls", "variables", "scan", "radar_event"]), "雷达事件只补齐固定的变量、扫描与具名权限")
	model.set_command_enabled("radar_position", true, _content)
	model.set_command_enabled("named_move", true, _content)
	ids = model.get_enabled_commands(_content)
	_check("move" not in ids and "named_move" in ids, "具名移动与广播移动可独立选择")
	count = model._undo_stack.size()
	model.set_command_enabled("named_calls", false, _content)
	ids = model.get_enabled_commands(_content)
	_check("radar_event" not in ids and "named_move" not in ids and "scan" in ids and "radar_position" in ids, "关闭具名总开关只移除依赖它的指令")
	_check(model._undo_stack.size() == count + 1, "关闭多个依赖项同一事务记录")
	model.set_command_enabled("variables", false, _content)
	ids = model.get_enabled_commands(_content)
	_check("radar_position" not in ids and "scan" in ids and "main" in ids, "关闭变量会移除目标属性而不限制主动扫描")
	model.set_command_enabled("radar_distance", true, _content)
	_check("variables" in model.get_enabled_commands(_content), "启用雷达距离会补齐变量家族")
	model.set_command_enabled("scan", false, _content)
	_check("radar_distance" not in model.get_enabled_commands(_content) and "variables" in model.get_enabled_commands(_content), "关闭扫描只关闭依赖查询，不删去独立变量权限")
	model.set_command_enabled("named_scan", true, _content)
	_check("named_scan" in model.get_enabled_commands(_content) and "scan" not in model.get_enabled_commands(_content), "具名扫描不自动强迫开放广播扫描")


## 家族开关由实际策略派生，两个随机函数或两种声明不会被旧布尔值合并成全开放。
func _test_flag_projection() -> void:
	var document := _document()
	document.properties.level["enabled_commands"] = ["main", "random_int", "constants", "named_calls", "named_move"]
	# 手工元数据遗留 false 不覆盖新的显式权限，但读取仍保留原始元数据字节。
	for flag: String in CommandPermissions.FLAG_COMMANDS:
		document.properties.level[flag] = false
	var before := document.to_dict()
	var result := LevelDefinition.from_document(document, _content)
	_check(result.is_ok() and result.value.has_command_policy, "合法显式策略可构造真实关卡定义")
	if result.is_ok():
		var level: LevelDefinition = result.value
		_check(level.allow_random and level.allow_variables and level.allow_named_calls, "已开启子指令派生必要的旧解析能力")
		_check(not level.allow_tick and not level.allow_radar and not level.allow_functions and not level.allow_for, "未选家族不因其它指令打开")
		_check("random" not in level.enabled_commands and "variables" not in level.enabled_commands and "move" not in level.enabled_commands, "广播动作、随机函数和变量声明仍按 ID 分别限制")
	_check(document.to_dict() == before, "构造运行定义不回写派生布尔值")
	var reverse: Array = CommandPermissions.COMMAND_IDS.duplicate()
	reverse.reverse()
	var model := MapEditorDocument.new()
	model.replace_document(document)
	_check(model.set_enabled_commands(reverse, _content).is_ok() and model.document.properties.level.enabled_commands == CommandPermissions.COMMAND_IDS, "显式编辑按固定目录顺序序列化所有指令")


## 正式保存和草稿都校验策略；坏数组不能覆盖有效文件，重新载入保留扩展和新规则。
func _test_codec() -> void:
	DirAccess.make_dir_recursive_absolute(_temporary)
	var path := _temporary.path_join("commands.json")
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	model.set_enabled_commands(["main", "random_int"], _content)
	_check(MapCodec.save_file(model.document, path, _content).is_ok(), "新指令策略可通过正式原子保存")
	var bytes := FileAccess.get_file_as_bytes(path)
	var loaded := MapCodec.load_file(path, _content)
	# JSON 本身不保留 GDScript 的 int/float 区别，以写盘实际表达比对完整嵌套扩展。
	var expected_properties: Dictionary = JSON.parse_string(JSON.stringify(model.document.properties))
	var expected_extra: Dictionary = JSON.parse_string(JSON.stringify(model.document.extra))
	_check(loaded.is_ok() and loaded.value.properties == expected_properties and loaded.value.extra == expected_extra, "保存再载入保留策略和未知扩展")
	model.document.properties.level["enabled_commands"] = ["main", "unknown"]
	_check(not MapCodec.save_file(model.document, path, _content).is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "坏策略不能覆盖已经保存的有效地图")
	model.document.player_spawn = null
	_check(not MapCodec.validate(model.document, _content, false).is_ok(), "未完成草稿也拒绝未知指令策略")
	model.document.properties.level["enabled_commands"] = ["main"]
	_check(MapCodec.validate(model.document, _content, false).is_ok(), "没有出生点的有效 main 策略仍可作为草稿保存")


## 累计明确失败并输出完整原因，包装脚本同时检查完成标记和引擎日志。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 删除仅限本次进程的独占目录，不接触玩家地图、教学资源或真实配置。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
