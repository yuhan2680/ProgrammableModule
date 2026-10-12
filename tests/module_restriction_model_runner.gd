extends SceneTree
## 禁止模块的旧图兼容、编辑事务、JSON 边界及装配绕过校验，文件仅写入独占目录。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 等全局类加载后运行隔离测试。
func _initialize() -> void:
	_run.call_deferred()


## 使用真实目录、地图存储和装配模型验证整条规则链。
func _run() -> void:
	_temporary = "user://tests/module_restrictions_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "真实模块目录加载成功")
	var source := _map()
	var editor := MapEditorDocument.new()
	editor.replace_document(source)
	var before := editor.document.to_dict()
	var legacy := LevelDefinition.from_document(source, _content)
	_check(legacy.is_ok() and legacy.value.allowed_modules == PackedStringArray(["movement"]), "没有新字段的旧图继续继承出生模板")
	_check(editor.get_restricted_modules(_content).size() == _content.modules.size() - 1 and not editor.is_dirty(), "读取旧图禁止项只是投影，不改文档")
	source.properties.level.allowed_modules = ["movement", "radar", "rangefinder"]
	editor.replace_document(source)
	before = editor.document.to_dict()
	_check(not "radar" in editor.get_restricted_modules(_content), "旧允许列表在表单中正确显示")
	_check(editor.set_restricted_modules(["radar", "rangefinder"], _content).is_ok(), "两个禁止模块可一次提交")
	_check(not editor.document.properties.level.has("allowed_modules") and editor.document.properties.level.custom.keep and editor.document.extra.keep, "显式修改转换旧允许列表并保留扩展")
	_check(editor.undo() and editor.document.to_dict() == before and not editor.is_dirty(), "一次撤销完整还原旧策略及保存点")
	_check(editor.redo() and "radar" in editor.get_restricted_modules(_content), "重做恢复禁止列表")
	var after := editor.document.to_dict()
	_check(editor.set_restricted_modules(["rangefinder", "radar"], _content).is_ok() and editor.document.to_dict() == after, "相同集合不同顺序不制造历史")
	_check(editor.undo() and editor.document.to_dict() == before and editor.can_redo(), "等值提交未增加撤销步骤")
	editor.redo()
	for invalid: Variant in [null, "radar", [1], ["unknown"], ["radar", "radar"], ["RADAR"]]:
		_check(not editor.set_restricted_modules(invalid, _content).is_ok() and editor.document.to_dict() == after, "非法禁止列表原子失败：%s" % str(invalid))
		var raw := _map().to_dict()
		raw.player_spawn = null
		raw.properties.level.restricted_modules = invalid
		_check(not MapCodec.from_dict(raw, _content, false).is_ok(), "无出生点草稿也拒绝非法禁止列表")
	var oversized: Array = []
	oversized.resize(257)
	oversized.fill("radar")
	_check(not MapValidation.check_restricted_modules(oversized, _content).is_ok(), "超限数组拒绝")
	var broken := _map()
	broken.properties.level = "损坏原文"
	editor.replace_document(broken)
	_check(not editor.set_restricted_modules([], _content).is_ok() and editor.document.properties.level == "损坏原文", "损坏关卡对象不能被表单覆盖")
	editor.replace_document(_map())
	editor.set_restricted_modules(["radar", "rangefinder"], _content)
	var definition := LevelDefinition.from_document(editor.document, _content)
	_check(definition.is_ok() and not "radar" in definition.value.allowed_modules and "shooting" in definition.value.allowed_modules, "关卡从完整目录扣除禁止项")
	if definition.is_ok():
		var assembly := AssemblyModel.create(definition.value, _content)
		_check(not assembly.add_module("radar", Vector2.ZERO).is_ok() and assembly.modules.is_empty(), "装配添加受限模块失败且不改草稿")
		_check(assembly.add_module("movement", Vector2.ZERO).is_ok() and assembly.build_document().is_ok(), "未受限模块可确认并生成世界")
		assembly.modules = [_module("blocked", "radar")]
		_check(not assembly.validate_editing().is_ok() and not assembly.validate().is_ok() and not assembly.build_document().is_ok(), "直接注入或载入旧草稿无法绕过任何装配校验")
		var session := GameSession.create(definition.value, _content)
		session.assembly.modules = [_module("blocked", "radar")]
		_check(not session.run().is_ok(), "真实运行入口拒绝受限装配")
	var store := PlayerLevelStore.new()
	store.directory = _temporary.path_join("levels")
	var saved := store.save(editor.document, _content)
	_check(saved.is_ok(), "普通玩家关卡存储保存禁止列表")
	if saved.is_ok():
		var reopened := MapCodec.load_file(saved.value.path, _content, true)
		_check(reopened.is_ok() and reopened.value.properties.level.restricted_modules == editor.document.properties.level.restricted_modules, "真实 JSON 往返保留模块 ID 与禁止集合")
		var catalog := LevelCatalog.new()
		catalog.user_directory = store.directory
		var loaded := catalog.refresh(_content)
		_check(loaded.is_ok() and catalog.levels.any(func(item: LevelDefinition) -> bool: return item.id == saved.value.document.id and not "radar" in item.allowed_modules), "玩家关卡目录的正式关卡保留禁止规则")
	var intersected := editor.document.duplicate_document()
	intersected.properties.level.allowed_modules = ["movement", "radar"]
	var intersection := LevelDefinition.from_document(intersected, _content)
	_check(intersection.is_ok() and intersection.value.allowed_modules == PackedStringArray(["movement"]), "手工同时提供两个字段时仍扣除禁止项")
	intersected.properties.level.allowed_modules = ["unknown"]
	_check(not LevelDefinition.from_document(intersected, _content).is_ok(), "禁止列表不能掩盖损坏的允许列表")
	editor.set_restricted_modules([], _content)
	var unlimited := LevelDefinition.from_document(editor.document, _content)
	_check(unlimited.is_ok() and unlimited.value.allowed_modules.size() == _content.modules.size(), "不限制允许全部当前模块")
	var extra := ModuleDefinition.new()
	extra.id = "future_sensor"
	extra.display_name = "扩展传感器"
	extra.behavior = "RadarModule"
	_content.modules[extra.id] = extra
	unlimited = LevelDefinition.from_document(editor.document, _content)
	_check(unlimited.is_ok() and extra.id in unlimited.value.allowed_modules, "不限制自动包含后来加入注册表的模块")
	editor.set_restricted_modules(_content.modules.keys(), _content)
	var all_blocked := LevelDefinition.from_document(editor.document, _content)
	_check(all_blocked.is_ok() and all_blocked.value.allowed_modules.is_empty() and not AssemblyModel.create(all_blocked.value, _content).validate().is_ok(), "全部禁止可保存编辑，但不存在可确认装配")
	_cleanup(_temporary)
	print("模块限制模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 全地板地图只以旧出生模板解锁移动模块，扩展字段用于验证事务保真。
func _map() -> MapDocument:
	var document := MapDocument.new()
	document.id = "module_restrictions_fixture"
	document.display_name = "模块限制测试"
	document.width = 12
	document.height = 8
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5.5, "y": 4.5}, "modules": [_module("drive", "movement")]}
	document.properties = {"level": {"module_limit": 3, "custom": {"keep": true}}}
	document.extra = {"keep": "原文"}
	return document


## 草稿实例用稳定 ID 和合法中心偏移，避免其他装配错误掩盖禁止规则。
func _module(id: String, type: String) -> Dictionary:
	return {"id": id, "module_id": type, "offset": {"x": 0.0, "y": 0.0}}


## 收集断言并明确返回失败状态。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只删除本轮独占测试目录，不触碰任何玩家文件。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in folder.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
