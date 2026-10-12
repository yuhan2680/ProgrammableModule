extends SceneTree
## 副标题的字符规则、原子事务及保存往返使用独占文件目录，旧描述和目标不能被覆盖。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 全局类就绪后再读取真实地图夹具。
func _initialize() -> void:
	_run.call_deferred()


## 依次覆盖单行文字、长度、非法输入、事务与真实文件往返。
func _run() -> void:
	_temporary = "user://tests/map_subtitle_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "读取目录"):
		_test_characters()
		_test_transactions()
		_test_roundtrip()
	_cleanup(_temporary)
	print("地图副标题模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 中英文按字符计数；表情组合和不可见字符均不能绕过纯文本校验。
func _test_characters() -> void:
	for text: String in ["", "限时目标：清除全部敌人。", "Stage 2: move(angle, 3) & survive!", "Étage 2 — café", "中文 Japanese 日本語 한글 123", "预算 ￥20，a+b=3，完成率 100%", "ASCII ^ | ` ~ "]:
		_check(DataValidation.is_level_subtitle(text) and DataValidation.filter_level_subtitle(text) == text, "普通文字和标点保留原文 " + text)
	for unit: String in ["中", "x"]:
		_check(DataValidation.is_level_subtitle(unit.repeat(70)), "七十字符合法 " + unit)
		_check(not DataValidation.is_level_subtitle(unit.repeat(71)) and DataValidation.filter_level_subtitle(unit.repeat(71)) == unit.repeat(70), "七十一字符截到七十 " + unit)
	for invalid: String in ["😀", "⚠️", "ℹ", "⤴", "‼", "©", "👨‍👩‍👧‍👦", "🇨🇳", "👍🏽", "1️⃣", "\n", "\r", "\t", String.chr(127), String.chr(0x2028), String.chr(0x200B), String.chr(0x202E), String.chr(0xE000)]:
		_check(not DataValidation.is_level_subtitle("a" + invalid + "b"), "拒绝表情、控制码或不可见字元")
		_check(DataValidation.is_level_subtitle(DataValidation.filter_level_subtitle("a" + invalid + "b")), "过滤后始终满足同一规则")
	_check(DataValidation.filter_level_subtitle("😀".repeat(70) + "中".repeat(70)) == "中".repeat(70), "先去除表情，合法文字不会被表情挤占额度")
	for value: Variant in [null, true, 7, [], {}]:
		_check(not DataValidation.is_level_subtitle(value), "错误类型不可作为副标题")


## 旧图留空无修改，副标题和名称署名一次撤销；错误输入保持重做和全部字段。
func _test_transactions() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_map())
	var original := model.document.to_dict()
	_ok(model.set_subtitle(" "), "旧图留空可提交")
	_check(model.get_subtitle().is_empty() and model.document.to_dict() == original and not model.is_dirty() and not model.can_undo(), "缺省空副标题不创建字段或历史")
	_ok(model.set_identity_with_subtitle("subtitle_changed", "新关卡", "作者", "限时目标：完成测试。"), "四字段一起更新")
	_check(model.get_subtitle() == "限时目标：完成测试。" and model._undo_stack.size() == 1, "复合修改只占一个历史步骤")
	_check(model.document.properties.level.description == original.properties.level.description and model.document.properties.level.goal == original.properties.level.goal, "副标题不替换描述或真实通关目标")
	_check(model.undo() and model.document.to_dict() == original and not model.is_dirty(), "一次撤销完整恢复原图及保存状态")
	var before := model.document.to_dict()
	var failed := model.set_identity_with_subtitle("must_not_change", "不应写入", "作者", "😀")
	_check(not failed.is_ok() and model.document.to_dict() == before and model.can_redo(), "非法副标题不部分提交其它字段或清除重做")
	_check(model.redo() and model.get_subtitle() == "限时目标：完成测试。", "非法输入之后仍可重做原事务")
	var history := model._undo_stack.size()
	_ok(model.set_subtitle(model.get_subtitle()), "等值提交成功")
	_check(model._undo_stack.size() == history, "等值提交不新增撤销步骤")
	_ok(model.set_subtitle(""), "允许清空")
	_check(not model.document.properties.level.has("subtitle") and model.get_subtitle().is_empty(), "清空仅移除可选副标题")
	var broken := _map()
	broken.properties.level = ["保持原值"]
	model.replace_document(broken)
	before = model.document.to_dict()
	_check(not model.set_subtitle("不可覆盖").is_ok() and model.document.to_dict() == before, "损坏规则对象不能被副标题覆盖")


## 普通保存、导出、重新打开和关卡快照携带原文；无效 JSON 不能覆盖已有有效文件。
func _test_roundtrip() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_map())
	_ok(model.set_subtitle("副标题 <文字> 70：不要翻译。"), "写入有效副标题")
	var store := PlayerLevelStore.new()
	store.directory = _temporary.path_join("levels")
	var managed := store.save(model.document, _content)
	if not _ok(managed, "托管保存"):
		return
	var export_path := _temporary.path_join("export/map.json")
	_ok(MapCodec.save_file(managed.value.document, export_path, _content), "导出真实文件")
	for path: String in [managed.value.path, export_path]:
		var loaded := MapCodec.load_file(path, _content)
		if _ok(loaded, "重新打开文件"):
			var reopened := MapEditorDocument.new()
			reopened.replace_document(loaded.value, path)
			_check(reopened.get_subtitle() == model.get_subtitle() and not reopened.is_dirty(), "表单数据原文回填且不脏")
			var level := LevelDefinition.from_document(loaded.value, _content, path)
			if _ok(level, "构造正式关卡"):
				_check(level.value.subtitle == model.get_subtitle(), "运行关卡读取同一副标题")
	var saved_hash := FileAccess.get_sha256(export_path)
	for invalid: Variant in ["x".repeat(71), "😀", "two\nlines", 42, null, []]:
		var copy: MapDocument = managed.value.document.duplicate_document()
		copy.properties.level.subtitle = invalid
		_check(not MapCodec.from_dict(copy.to_dict(), _content, false).is_ok(), "非法副标题 JSON 不能载入")
		_check(not MapCodec.save_file(copy, export_path, _content, false).is_ok() and FileAccess.get_sha256(export_path) == saved_hash, "非法草稿不覆盖有效导出文件")


## 内置第一关仅深拷贝作夹具，正式文件不被测试修改。
func _map() -> MapDocument:
	var result := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var document: MapDocument = result.value
	document.id = "subtitle_fixture"
	document.extra["future"] = {"keep": true}
	return document


## 清理只限本次独占目录，链接仅移除自身。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary) or _temporary.is_empty():
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
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


## 成功检查保留统一 DataResult 诊断。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result.is_ok(), message + "；" + "; ".join(result.errors))


## 任一断言失败均输出原因并令整体测试返回非零。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
