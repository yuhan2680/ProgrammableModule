extends SceneTree
## 玩家耐久回归使用真实编辑事务、JSON、装配和会话，文件仅写入独占测试目录。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 延后运行以等待 Godot 完成脚本类初始化。
func _initialize() -> void:
	_run.call_deferred()


## 分层验证输入、存储和真实受击，并保留可由测试包装器识别的完成标记。
func _run() -> void:
	_temporary = "user://tests/player_health_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if not _check(_content.load_directories().is_ok(), "真实模块与地块内容可加载"):
		quit(1)
		return
	_test_editor_transactions()
	_test_invalid_input()
	_test_json_round_trip()
	_test_legacy_inheritance()
	_test_actual_assembly()
	_test_damage_and_retry()
	_cleanup(_temporary)
	print("玩家耐久回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 全地板夹具保留出生模板和扩展字段；真实会话仍要求玩家重新装配。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "player_health_fixture"
	document.display_name = "玩家耐久夹具"
	document.width = 12
	document.height = 8
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5.5, "y": 4.5}, "modules": [_module("template_drive", "movement", Vector2.ZERO)], "custom_spawn": "保留"}
	document.properties = {
		"level": {"module_limit": 3, "allowed_modules": ["movement", "shooting", "melee"], "max_ticks": 600, "completion_mode": "reach_or_clear", "custom_rule": {"nested": ["保留", 2]}},
		"custom_map": {"author": "测试"},
	}
	document.extra = {"future_extension": {"enabled": true}}
	return document


## 名称和类型独立构建，以验证设置作用于玩家确认的模块实例。
func _module(instance_id: String, module_id: String, offset: Vector2) -> Dictionary:
	return {"id": instance_id, "module_id": module_id, "offset": {"x": offset.x, "y": offset.y}}


## 编辑事务需要恢复未设置的旧状态，也不能因数字类型相同值产生脏标记。
func _test_editor_transactions() -> void:
	var editor := MapEditorDocument.new()
	_check(editor.get_player_max_health() == 1.0, "空白文档显示默认玩家耐久1")
	editor.replace_document(_document(), _temporary.path_join("editor.json"))
	var original := editor.document.to_dict()
	_check(editor.get_player_max_health() == 1.0 and not editor.is_dirty(), "旧地图缺省显示1，读取不标记修改")
	_check(not editor.document.properties.level.has("player_max_health"), "读取默认值不向旧地图补写覆盖")
	_check(editor.set_player_max_health(2.5).is_ok(), "小数耐久可以提交")
	_check(editor.get_player_max_health() == 2.5 and editor.is_dirty(), "有效提交更新数值并标记未保存")
	var edited := editor.document.to_dict()
	var without_override: Dictionary = edited.duplicate(true)
	without_override.properties.level.erase("player_max_health")
	_check(without_override == original, "修改只写玩家耐久，保留模板、关卡和扩展字段")
	_check(editor.undo() and editor.document.to_dict() == original and not editor.is_dirty(), "一次撤销恢复完整旧地图与保存点")
	_check(not editor.can_undo(), "一次耐久修改只产生一次撤销")
	_check(editor.redo() and editor.document.to_dict() == edited and editor.get_player_max_health() == 2.5, "重做恢复小数耐久和原扩展字段")
	_check(editor.undo() and editor.set_player_max_health(1).is_ok(), "可以显式提交与显示默认值相同的1")
	_check(editor.document.properties.level.has("player_max_health") and editor.is_dirty(), "显式1与继承模块定义有区别，需要保存覆盖")
	_check(editor.undo() and not editor.document.properties.level.has("player_max_health"), "撤销显式1重新恢复继承语义")

	var integer_document := _document()
	integer_document.properties.level.player_max_health = 2
	editor.replace_document(integer_document)
	_check(editor.set_player_max_health(3.0).is_ok() and editor.undo(), "建立待重做的真实耐久修改")
	var history_before := [editor._undo_stack.size(), editor._redo_stack.size()]
	var saved_document := JSON.stringify(editor.document.to_dict())
	for same: Variant in [2, 2.0, 2]:
		_check(editor.set_player_max_health(same).is_ok(), "相同整数或小数形式重复提交成功")
	_check(JSON.stringify(editor.document.to_dict()) == saved_document and typeof(editor.document.properties.level.player_max_health) == TYPE_INT, "相同数值不转换原JSON数字类型")
	_check([editor._undo_stack.size(), editor._redo_stack.size()] == history_before and not editor.is_dirty(), "重复提交不产生历史、清除重做或改变保存点")
	_check(editor.redo() and editor.get_player_max_health() == 3.0, "相同值提交后仍可重做先前修改")
	for value: Variant in [0.00001, 1.25, 1000000000]:
		_check(editor.set_player_max_health(value).is_ok() and editor.get_player_max_health() == float(value), "正小数及最大耐久可完整保存 " + str(value))
		_check(LevelDefinition.from_document(editor.document, _content).is_ok(), "正小数及最大耐久通过运行关卡校验 " + str(value))

	var draft := _document()
	draft.player_spawn = null
	draft.properties.erase("level")
	editor.replace_document(draft)
	_check(editor.set_player_max_health(4.25).is_ok() and editor.document.player_spawn == null, "没有出生点或关卡元数据也可先编辑玩家耐久")
	_check(editor.document.properties.level.player_max_health == 4.25 and editor.document.properties.custom_map == draft.properties.custom_map, "新建关卡规则保留地图扩展字段")
	_check(editor.undo() and editor.document.to_dict() == draft.to_dict(), "未完成草稿可完整撤销耐久修改")


## 非数字、无穷和越界值不能经编辑器或直接JSON元数据绕过验证。
func _test_invalid_input() -> void:
	var editor := MapEditorDocument.new()
	var document := _document()
	document.properties.level.player_max_health = 2.5
	editor.replace_document(document)
	editor.set_player_max_health(3)
	editor.undo()
	var original := JSON.stringify(editor.document.to_dict())
	var history_before := [editor._undo_stack.size(), editor._redo_stack.size()]
	for value: Variant in [null, true, false, "2", "", [], {}, 0, 0.0, -1, -0.1, 1000000001.0, NAN, INF, -INF]:
		_check(not editor.set_player_max_health(value).is_ok(), "拒绝非法编辑耐久 " + str(value))
		_check(JSON.stringify(editor.document.to_dict()) == original and not editor.is_dirty() and [editor._undo_stack.size(), editor._redo_stack.size()] == history_before, "非法输入保留原文档、保存点和重做历史 " + str(value))
		var invalid := document.duplicate_document()
		invalid.properties.level.player_max_health = value
		_check(not MapCodec.validate(invalid, _content, true).is_ok() and not MapCodec.from_dict(invalid.to_dict(), _content, true).is_ok(), "地图和JSON对象入口拒绝非法耐久 " + str(value))
		_check(not LevelDefinition.from_document(invalid, _content).is_ok(), "关卡入口拒绝非法JSON耐久 " + str(value))
		_check(not SimulationWorld.create(invalid, _content).is_ok(), "直接世界入口也拒绝非法耐久 " + str(value))
		invalid.player_spawn = null
		_check(not MapCodec.validate(invalid, _content, false).is_ok(), "没有出生点的草稿也拒绝非法耐久 " + str(value))
	_check(editor.redo() and editor.get_player_max_health() == 3.0, "全部非法提交后原重做记录仍可恢复")
	for malformed: Variant in [null, [], true, "broken"]:
		var broken := _document()
		broken.properties.level = malformed
		editor.replace_document(broken)
		var before := editor.document.to_dict()
		_check(editor.get_player_max_health() == 1.0, "畸形关卡元数据的显示回退可安全读取")
		_check(not editor.set_player_max_health(4).is_ok() and editor.document.to_dict() == before and not editor.is_dirty() and not editor.can_undo(), "有效数字不能覆盖损坏的关卡元数据")


## 通过真实文件往返检查小数、扩展字段与旧地图未设置覆盖的兼容性。
func _test_json_round_trip() -> void:
	var editor := MapEditorDocument.new()
	editor.replace_document(_document())
	editor.set_player_max_health(7.125)
	var path := _temporary.path_join("health.json")
	if not _check(MapCodec.save_file(editor.document, path, _content, true).is_ok(), "小数耐久地图可写入独占JSON文件"):
		return
	editor.mark_saved(path)
	var loaded := MapCodec.load_file(path, _content, true)
	if not _check(loaded.is_ok(), "保存的耐久地图可重新读取"):
		return
	var reopened := MapEditorDocument.new()
	reopened.replace_document(loaded.value, path)
	_check(reopened.get_player_max_health() == 7.125 and not reopened.is_dirty(), "重开JSON恢复精确小数和干净保存点")
	_check(_json_equal(loaded.value.to_dict(), editor.document.to_dict()), "JSON往返保留地图、模板、规则和全部扩展字段")
	_check(LevelDefinition.from_document(loaded.value, _content).is_ok(), "重开文件可以作为真实关卡载入")
	var saved_text := FileAccess.get_file_as_string(path)
	for value: Variant in [null, true, "7.125", [], {}, 0, -1, 1000000001.0, NAN, INF]:
		var invalid := editor.document.duplicate_document()
		invalid.properties.level.player_max_health = value
		_check(not MapCodec.save_file(invalid, path, _content).is_ok() and FileAccess.get_file_as_string(path) == saved_text, "非法耐久保存失败并保留已有有效文件 " + str(value))
	var invalid_data := editor.document.to_dict()
	invalid_data.properties.level.player_max_health = "7.125"
	var invalid_path := _temporary.path_join("invalid.json")
	var invalid_file := FileAccess.open(invalid_path, FileAccess.WRITE)
	if _check(invalid_file != null, "创建非法类型JSON读取夹具"):
		invalid_file.store_string(JSON.stringify(invalid_data))
		invalid_file.close()
		_check(not MapCodec.load_file(invalid_path, _content).is_ok(), "从实际JSON文件读取也拒绝字符串耐久")
	var session := _session(loaded.value)
	if session != null:
		_check(session.world.player.get_module("actual_drive").max_health == 7.125 and session.world.player.get_module("actual_drive").health == 7.125, "文件重开后实际装配获得保存的耐久")
	var legacy := _document()
	legacy.properties.level.erase("completion_mode")
	legacy.properties.level.erase("max_ticks")
	var legacy_path := _temporary.path_join("legacy.json")
	if _check(MapCodec.save_file(legacy, legacy_path, _content).is_ok(), "旧无耐久字段地图仍可保存"):
		var legacy_loaded := MapCodec.load_file(legacy_path, _content)
		_check(legacy_loaded.is_ok() and not legacy_loaded.value.properties.level.has("player_max_health"), "保存再打开不会向旧地图注入耐久覆盖")
	var draft := _document()
	draft.player_spawn = null
	draft.properties.level.player_max_health = 4.25
	var draft_path := _temporary.path_join("draft.json")
	if _check(MapCodec.save_file(draft, draft_path, _content, false).is_ok(), "尚未放置出生点的耐久草稿可保存"):
		var draft_loaded := MapCodec.load_file(draft_path, _content, false)
		_check(draft_loaded.is_ok() and draft_loaded.value.player_spawn == null and draft_loaded.value.properties.level.player_max_health == 4.25, "草稿往返保留空出生点与耐久设置")


## 独立注册表的非1定义证明省略字段会继承，自定义覆盖不污染静态定义。
func _test_legacy_inheritance() -> void:
	var content := ContentRegistry.new()
	if not _check(content.load_directories().is_ok(), "旧地图兼容性使用独立内容注册表"):
		return
	content.get_module("movement").properties.max_health = 7.0
	content.get_module("shooting").properties.max_health = 9.0
	var document := _document()
	document.properties.level.erase("completion_mode")
	document.properties.level.erase("max_ticks")
	var before := document.to_dict()
	var editor := MapEditorDocument.new()
	editor.replace_document(document)
	_check(editor.get_player_max_health() == 1.0, "旧地图编辑器默认显示1，运行继承另由模块定义决定")
	var legacy := _session(document, content, true)
	if legacy == null:
		return
	_check(legacy.world.player.get_module("actual_drive").health == 7.0 and legacy.world.player.get_module("actual_drive").max_health == 7.0, "缺省字段继承自定义移动模块7点耐久")
	_check(legacy.world.player.get_module("actual_gun").health == 9.0 and legacy.world.player.get_module("actual_blade").health == 1.0, "同一旧装配各模块分别继承定义")
	_check(document.to_dict() == before and editor.document.to_dict() == before and not editor.is_dirty(), "运行旧地图不回写默认覆盖或改变编辑状态")
	_check(editor.set_player_max_health(1).is_ok(), "作者可显式选择统一1点耐久")
	var explicit := _session(editor.document, content, true)
	if explicit != null:
		for module in explicit.world.player.modules:
			_check(module.max_health == 1.0 and module.health == 1.0, "显式1覆盖每个实际模块的不同定义 " + module.id)
	_check(content.get_module("movement").properties.max_health == 7.0 and content.get_module("shooting").properties.max_health == 9.0, "运行覆盖不修改共享静态耐久定义")
	var second_legacy := _session(document, content, true)
	if second_legacy != null:
		_check(second_legacy.world.player.get_module("actual_drive").health == 7.0 and second_legacy.world.player.get_module("actual_gun").health == 9.0, "显式覆盖会话之后的新旧地图仍正确继承")


## 玩家装配与出生模板不同，覆盖全部实际模块但保留敌方实例与静态内容。
func _test_actual_assembly() -> void:
	var document := _combat_document()
	document.properties.level.player_max_health = 2.75
	var before := document.to_dict()
	var definition_properties := {}
	for module_id: String in ["movement", "shooting", "melee"]:
		definition_properties[module_id] = _content.get_module(module_id).properties.duplicate(true)
	var session := _session(document, _content, true)
	if session == null:
		return
	_check(session.world.player.modules.size() == 3 and session.world.player.get_module("template_drive") == null, "世界采用实际三模块装配，未使用出生模板")
	for module in session.world.player.modules:
		_check(module.max_health == 2.75 and module.health == 2.75, "实际玩家每个类型都取得相同覆盖 " + module.id)
		_check(module.definition.properties == definition_properties[module.definition.id], "运行实例保留共享内容属性 " + module.id)
	var enemy := session.world.get_machine("attacker")
	_check(enemy.get_module("enemy_blade").health == 6.0 and enemy.get_module("enemy_blade").max_health == 6.0, "玩家覆盖不改变敌方显式6点耐久")
	_check(enemy.get_module("enemy_drive").health == 1.0 and enemy.get_module("enemy_drive").max_health == 1.0, "玩家覆盖不改变敌方默认模块耐久")
	_check(document.to_dict() == before and session.level.document.to_dict() == before, "组装和运行不回写原地图或关卡快照")
	for module_id: String in definition_properties:
		_check(_content.get_module(module_id).properties == definition_properties[module_id], "玩家和敌方实例不污染共享定义 " + module_id)


## 真实敌人连续近战体现耐久差异，暂停冻结伤害，失败重试恢复完整初值。
func _test_damage_and_retry() -> void:
	var ordinary := _session(_combat_document())
	if ordinary == null:
		return
	ordinary.step()
	_check(ordinary.state == GameSession.State.FAILED and ordinary.world.tick_index == 1 and ordinary.world.player.is_destroyed(), "默认1点耐久在第一次真实敌方近战后失败")
	var document := _combat_document()
	document.properties.level.player_max_health = 2.5
	var original := document.to_dict()
	var durable := _session(document)
	if durable == null:
		return
	var assembly_before: Array = durable.assembly.modules.duplicate(true)
	var source_before := durable.source
	durable.step()
	_check(durable.state == GameSession.State.RUNNING and durable.world.player.get_module("actual_drive").health == 1.5 and not durable.world.attack_traces.is_empty(), "2.5点耐久受到同一次真实近战后仍能运行")
	durable.pause()
	for unused in 5:
		durable.step()
	_check(durable.state == GameSession.State.PAUSED and durable.world.tick_index == 1 and durable.world.player.get_module("actual_drive").health == 1.5, "暂停冻结逻辑时间和受击耐久")
	durable.resume()
	durable.step()
	_check(durable.state == GameSession.State.RUNNING and durable.world.player.get_module("actual_drive").health == 0.5, "第二次真实伤害保留小数耐久")
	durable.step()
	_check(durable.state == GameSession.State.FAILED and durable.world.tick_index == 3 and durable.world.player.is_destroyed(), "第三次近战耗尽2.5点耐久并触发真实会话失败")
	_check(document.to_dict() == original and durable.level.document.to_dict() == original, "受击和失败不把剩余耐久写入地图配置")
	durable.reset()
	_check(durable.state == GameSession.State.EDITING and durable.world == null and durable.source == source_before and durable.assembly.modules == assembly_before, "失败后重置保留程序与真实装配")
	if not _check(durable.run().is_ok(), "保留装配可直接重试同一地图"):
		return
	_check(durable.world.tick_index == 0 and durable.world.player.get_module("actual_drive").max_health == 2.5 and durable.world.player.get_module("actual_drive").health == 2.5 and durable.world.player.get_module("actual_drive").available, "重试恢复玩家最大耐久、当前耐久与可用状态")
	_check(durable.world.get_machine("attacker").get_module("enemy_blade").health == 6.0, "重试仍保留独立敌方耐久")
	durable.step()
	_check(durable.state == GameSession.State.RUNNING and durable.world.player.get_module("actual_drive").health == 1.5, "重试后的真实伤害继续使用保存的耐久规则")


## 近距离固定方向敌人通过世界原生推进与近战出手，每次造成定义中的1点伤害。
func _combat_document() -> MapDocument:
	var document := _document()
	document.enemies = [{
		"id": "attacker", "behavior": "advance_attack", "position": {"x": 7.0, "y": 4.5},
		"modules": [_module("enemy_blade", "melee", Vector2.ZERO), _module("enemy_drive", "movement", Vector2(0.5, 0))],
		"properties": {"move_angle": 180, "attack_angle": 180, "module_health": {"enemy_blade": 6}},
	}]
	return document


## 正常会话从空装配开始，必须安装中心与贴边模块并通过真实运行入口。
func _session(document: MapDocument, content: ContentRegistry = null, mixed: bool = false) -> GameSession:
	if content == null:
		content = _content
	var parsed := LevelDefinition.from_document(document, content)
	if not _check(parsed.is_ok(), "夹具通过关卡定义校验：%s" % parsed.errors):
		return null
	var session := GameSession.create(parsed.value, content)
	_check(session.assembly.modules.is_empty(), "会话从空装配开始")
	if not _check(session.assembly.add_module("movement", Vector2.ZERO, "actual_drive").is_ok(), "玩家实际安装中心移动模块"):
		return null
	if mixed:
		if not _check(session.assembly.add_module("shooting", Vector2(0.5, 0), "actual_gun").is_ok(), "玩家实际贴边安装射击模块"):
			return null
		if not _check(session.assembly.add_module("melee", Vector2(0, -0.5), "actual_blade").is_ok(), "玩家实际贴边安装近战模块"):
			return null
	session.source = "main() {}"
	if not _check(session.run().is_ok(), "有效装配通过正常程序入口构建世界"):
		return null
	return session


## 清理范围严格限定本次测试目录，避免触及真实地图或玩家记录。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not (path == _temporary or path.begins_with(_temporary + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in directory.get_directories():
		_cleanup(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## JSON解析统一使用浮点数字，文件往返只比较相同数据而非内存数字类型。
func _json_equal(left: Variant, right: Variant) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))


## 汇总断言并输出错误，让包装器与进程退出码同时识别回归失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
