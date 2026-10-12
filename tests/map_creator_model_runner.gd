extends SceneTree
## 创作者字段的旧图兼容、事务、校验与真实文件往返；只使用本次独占测试目录。

var _checks: int = 0
var _failures: int = 0
var _root_path: String = ""
var _content := ContentRegistry.new()


## 等待全局类注册完成后开始无界面的模型测试。
func _initialize() -> void:
	_run.call_deferred()


## 顺序覆盖署名编辑和读写边界，清理隔离目录后返回整体结果。
func _run() -> void:
	_root_path = "user://tests/map_creator_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "读取真实内容注册表"):
		_test_legacy_and_transactions()
		_test_validation_and_failure()
		_test_roundtrip_and_clone()
		_test_identity_lengths_and_legacy()
	_cleanup(_root_path)
	print("地图创作者模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 旧地图打开和留空不产生修改；任意署名、清空及复合属性编辑遵循原撤销栈。
func _test_legacy_and_transactions() -> void:
	var source := _map()
	source.properties = {"future": {"keep": ["原文", 2]}}
	var document := MapEditorDocument.new()
	document.replace_document(source)
	var original := document.document.to_dict()
	_check(document.get_creator().is_empty(), "旧图没有虚构署名")
	_ok(document.set_creator("  "), "旧图空白输入有效")
	_check(document.document.to_dict() == original and not document.is_dirty() and not document.can_undo(), "旧图留空不创建 level、不产生历史或脏标记")
	var legacy := LevelDefinition.from_document(source, _content)
	if _ok(legacy, "旧图仍可形成关卡"):
		_check(legacy.value.creator.is_empty(), "旧关卡 creator 默认为空")
	_ok(document.set_creator("  Muna  "), "玩家自填名字可提交")
	_check(document.get_creator() == "Muna" and document.is_dirty(), "仅去除首尾空白并标记修改")
	_check(document.document.properties.future == source.properties.future, "署名修改保留未知地图属性")
	_check(document.undo() and document.document.to_dict() == original and not document.is_dirty(), "撤销署名恢复完整旧文档与保存状态")
	_check(document.redo() and document.get_creator() == "Muna", "重做恢复真实玩家名字")
	document.mark_saved("user://tests/creator_saved.json")
	_ok(document.set_creator("Muna"), "等值输入成功")
	_check(not document.is_dirty(), "等值输入不标记修改")
	_check(document.undo() and document.get_creator().is_empty(), "等值输入没有添加多余撤销步骤")
	_check(document.can_redo(), "撤销后保留重做")
	_ok(document.set_creator(""), "缺失字段重复留空成功")
	_check(document.can_redo(), "无修改输入不清除重做历史")
	_check(document.redo() and document.get_creator() == "Muna", "重复留空后原署名仍可重做")
	var rich_name := "月 🦈&<>%s[b]"
	_ok(document.set_creator(rich_name), "中文、表情和格式形似文本均是普通名字")
	_check(document.get_creator() == rich_name, "署名原文不被翻译、插值或过滤为示例名字")
	document.document.properties.level["future_rule"] = {"keep": true}
	var before_clear := document.document.to_dict()
	_ok(document.set_creator("  "), "已有署名允许清空")
	_check(not document.document.properties.level.has("creator") and document.document.properties.level.future_rule.keep, "清空只移除 creator，其他规则保留")
	_check(document.undo() and document.document.to_dict() == before_clear, "撤销清空恢复署名与所有扩展")
	var before_group := document.document.to_dict()
	document.begin_action()
	_ok(document.set_creator("Another"), "复合编辑提交署名")
	document.set_identity("renamed_creator_map", "新名称")
	document.end_action()
	_check(document.undo() and document.document.to_dict() == before_group, "名称 ID 和署名可组成同一步撤销")
	_check(document.redo() and document.get_creator() == "Another" and document.document.id == "renamed_creator_map", "复合事务重做恢复所有属性")


## 各入口统一拒绝错误类型、超长和多行；失败既不覆盖文件，也不清除可重做内容。
func _test_validation_and_failure() -> void:
	var document := MapEditorDocument.new()
	document.replace_document(_map())
	_ok(document.set_creator("Valid Muna"), "建立有效署名")
	var saved_path := _root_path.path_join("valid.json")
	_ok(MapCodec.save_file(document.document, saved_path, _content), "保存有效文件作为失败保护基线")
	var saved_bytes := FileAccess.get_file_as_bytes(saved_path)
	var before := document.document.to_dict()
	for invalid: String in ["x".repeat(129), "two\nlines", "two\rlines", "tab\tinside", "control" + String.chr(127), "a" + String.chr(0x2028) + "b"]:
		_error(document.set_creator(invalid), "编辑器拒绝超长或非单行署名")
		_check(document.document.to_dict() == before, "非法署名不改变任何地图数据")
	var invalid_values: Array = [null, 5, true, {}, [], "x".repeat(129), "a\nb", "a" + String.chr(128) + "b", "a" + String.chr(0x2029) + "b"]
	for invalid: Variant in invalid_values:
		var invalid_map := document.document.duplicate_document()
		invalid_map.properties.level.creator = invalid
		var result := MapCodec.from_dict(invalid_map.to_dict(), _content, false)
		_error(result, "地图读入拒绝非法 creator 元数据")
		_check(result.errors.has("创作者名字必须为最多 128 字符的单行文本。"), "非法署名返回明确统一诊断")
		_error(LevelDefinition.from_document(invalid_map, _content), "关卡构造拒绝非法署名")
		_error(MapCodec.save_file(invalid_map, saved_path, _content, false), "含非法署名的草稿也不能覆盖文件")
		_check(FileAccess.get_file_as_bytes(saved_path) == saved_bytes, "失败后原始有效文件逐字节不变")
	_ok(document.set_creator("月".repeat(11)), "编辑器最长 11 字符名字有效")
	_check(document.get_creator().length() == 11, "长度按字符而非 UTF-8 字节计算")
	_check(document.undo() and document.get_creator() == "Valid Muna", "撤销有效长名字")
	_error(document.set_creator("invalid\nname"), "有重做记录时非法输入仍失败")
	_check(document.can_redo() and document.redo() and document.get_creator().length() == 11, "失败保留重做历史")
	var malformed := _map()
	malformed.properties.level = ["保留损坏原值"]
	document.replace_document(malformed)
	var malformed_before := document.document.to_dict()
	_error(document.set_creator("Muna"), "损坏 level 元数据不能用空对象覆盖")
	_check(document.document.to_dict() == malformed_before and not document.is_dirty(), "错误元数据保持原样供手动修复")
	_ok(MapCodec.validate(malformed, _content, false), "原有草稿的非对象 level 校验兼容性不变")
	var empty := _map()
	empty.properties.level.creator = ""
	_ok(MapCodec.validate(empty, _content), "外部 JSON 的显式空署名仍兼容")


## 署名随地图跨托管保存、导出、重载和关卡快照传递，源文件和独立克隆不受后续编辑影响。
func _test_roundtrip_and_clone() -> void:
	var document := MapEditorDocument.new()
	document.replace_document(_map())
	var creator := "Muna 小月 🦈"
	_ok(document.set_creator(creator), "建立往返署名")
	document.document.properties.level["future_rule"] = {"text": "保留", "items": [1, 2]}
	document.document.extra["future_top"] = ["保留扩展"]
	var store := PlayerLevelStore.new()
	store.directory = _root_path.path_join("levels")
	var managed := store.save(document.document, _content)
	if not _ok(managed, "普通保存创建托管地图"):
		return
	var persisted: MapDocument = managed.value.document
	_check(persisted.properties.level.creator == creator, "托管副本保留玩家填写署名")
	var external_path := _root_path.path_join("export/map.json")
	_ok(MapCodec.save_file(persisted, external_path, _content, false), "另存为独立导出文件")
	for path: String in [managed.value.path, external_path]:
		var loaded := MapCodec.load_file(path, _content, false)
		if _ok(loaded, "托管与导出文件可重新载入"):
			var reopened := MapEditorDocument.new()
			reopened.replace_document(loaded.value, path)
			_check(reopened.get_creator() == creator and not reopened.is_dirty(), "重新打开回显同一个原文署名且不脏")
			var level := LevelDefinition.from_document(loaded.value, _content, path)
			if _ok(level, "重载地图可构造可玩关卡"):
				_check(level.value.creator == creator, "关卡列表取得动态署名")
				loaded.value.properties.level.creator = "Changed after clone"
				_check(level.value.creator == creator and level.value.document.properties.level.creator == creator, "关卡定义和地图使用独立深拷贝")
			_check(reopened.document.extra.future_top == ["保留扩展"] and reopened.document.properties.level.future_rule.text == "保留", "保存往返保留未知字段")
	var exported_bytes := FileAccess.get_file_as_bytes(external_path)
	persisted.properties.level.creator = "Someone Else"
	_ok(store.save(persisted, _content, managed.value.path), "托管地图可以更新创作者")
	_check(MapCodec.load_file(managed.value.path, _content).value.properties.level.creator == "Someone Else", "更新后的署名真正落盘")
	_check(FileAccess.get_file_as_bytes(external_path) == exported_bytes, "更新托管地图不修改另存为原件")
	var catalog := LevelCatalog.new()
	catalog.user_directory = store.directory
	_ok(catalog.refresh(_content), "真实目录重新扫描署名")
	var found := false
	for level: LevelDefinition in catalog.levels:
		if level.id == persisted.id:
			found = level.creator == "Someone Else"
	_check(found, "玩家关卡目录读取最新创作者，非固定示例值")


## 新输入按三十字符名称及十一字符署名限制，旧长值和组合事务保持完整。
func _test_identity_lengths_and_legacy() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_map())
	for unit in ["英", "x"]:
		_ok(model.set_identity("length_" + unit, unit.repeat(30)), "中英文名称三十字符可提交")
		var before := model.document.to_dict()
		_error(model.set_identity("must_not_change", unit.repeat(31)), "中英文名称三十一字符拒绝")
		_check(model.document.to_dict() == before, "拒绝超长名称也不先提交 ID")
		_ok(model.set_creator(unit.repeat(11)), "中英文署名十一字符可提交")
		before = model.document.to_dict()
		_error(model.set_identity_with_creator("must_not_change", "Valid Name", unit.repeat(12)), "组合事务拒绝十二字符署名")
		_check(model.document.to_dict() == before, "非法署名不先提交合法名称及 ID")
		_error(model.set_identity_with_creator("must_not_change", unit.repeat(31), "Muna"), "组合事务拒绝超长名称")
		_check(model.document.to_dict() == before, "非法名称不先提交合法署名及 ID")
	var before_group := model.document.to_dict()
	_ok(model.set_identity_with_creator("fixed", "修正后名称", "修正后署名"), "修正后一次提交全部身份字段")
	_check(model.undo() and model.document.to_dict() == before_group, "一次撤销还原三字段整个组合")
	var legacy := _map()
	legacy.display_name = "历史长名称".repeat(10)
	legacy.properties.level.creator = " 历史署名".repeat(8) + " "
	var legacy_name := legacy.display_name
	var legacy_creator: String = legacy.properties.level.creator
	model.replace_document(legacy)
	_ok(model.set_identity_with_creator(model.document.id, legacy_name, legacy_creator), "旧长名称与带首尾空白的长署名未修改时可提交")
	_check(not model.is_dirty() and not model.can_undo() and model.get_creator() == legacy_creator, "旧值不自动裁剪也不产生历史")
	_ok(model.set_module_limit(2), "历史长值允许修改其它属性")
	var path := _root_path.path_join("legacy-long.json")
	_ok(MapCodec.save_file(model.document, path, _content), "旧长字段随其它属性正常保存")
	var loaded := MapCodec.load_file(path, _content)
	if _ok(loaded, "旧长字段保存后可重载"):
		_check(loaded.value.display_name == legacy_name and loaded.value.properties.level.creator == legacy_creator, "旧长名称署名逐字符保留")
	_error(model.set_identity_with_creator("legacy_changed", legacy_name + "新", legacy_creator), "编辑旧长名称时仍受新上限约束")
	_error(model.set_creator(legacy_creator + "新"), "编辑旧长署名时仍受新上限约束")
	_ok(model.set_identity_with_creator("legacy_shortened", "缩短的名字", "Muna"), "旧长字段可以一起修正为新长度范围")


## 使用正式第一关的独立地图副本，保留真实可玩规则且不修改内置资源。
func _map() -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var document: MapDocument = loaded.value
	document.id = "creator_fixture"
	document.display_name = "Creator fixture"
	return document


## 仅递归清理本次测试根，任何链接都只删除链接本身。
func _cleanup(path: String) -> void:
	if _root_path.is_empty() or not (path == _root_path or path.begins_with(_root_path + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var entry := folder.get_next()
	while not entry.is_empty():
		var child := path.path_join(entry)
		if folder.is_link(entry) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		entry = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 记录 DataResult 成功以及失败明细，让后续依赖检查可以及时返回。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；无结果"))


## 失败必须附带明确错误，不能把空结果作为拒绝输入。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 统一累计有意义的行为断言，任何失败都会令进程退出码为非零。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
