extends SceneTree
## 分页引导编辑模型的旧图兼容、事务隔离与保存回归，只写本次独占测试目录。

var _checks: int = 0
var _failures: int = 0
var _root_path: String = ""
var _content := ContentRegistry.new()


## 在类注册后启动独立数据回归。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖分页模型及真实编解码边界，统一清理文件并返回失败状态。
func _run() -> void:
	_root_path = "user://tests/map_guide_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "载入真实模块与地块"):
		_test_legacy_and_copies()
		_test_transactions_and_blank_pages()
		_test_validation_and_limits()
		_test_portable_characters()
		_test_file_roundtrip()
	_cleanup(_root_path)
	print("地图分页引导模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 旧纯文本不自动转换为 Markdown；只读、重复提交和临时编辑均不改变保存状态。
func _test_legacy_and_copies() -> void:
	var map := _map()
	map.dialogue = [{"text": "*这是原有纯文本*", "speaker": "引导员", "future": {"steps": [1, 2]}}, {"text": "保留显式纯文本", "format": "plain"}]
	var document := MapEditorDocument.new()
	document.replace_document(map)
	var original := document.document.to_dict()
	var pages := document.get_guide_pages()
	_check(pages == map.dialogue, "旧页及未知属性完整读出")
	pages[0].text = "尚未应用的修改"
	pages[0].future.steps.append(3)
	pages.remove_at(1)
	_check(document.document.to_dict() == original and not document.is_dirty() and not document.can_undo(), "弹窗临时副本不影响地图、脏标记或撤销")
	_ok(document.set_guide_pages(document.get_guide_pages()), "不编辑旧页后应用成功")
	_check(document.document.to_dict() == original and not document.is_dirty() and not document.can_undo(), "旧图等值提交不增加格式字段或历史")
	_check(not document.document.dialogue[0].has("format") and document.document.dialogue[1].format == "plain", "缺省及显式 plain 格式保持原样")
	var empty := MapEditorDocument.new()
	empty.replace_document(MapDocument.new())
	_ok(empty.set_guide_pages([]), "无引导的旧草稿保持无引导")
	_check(empty.document.dialogue.is_empty() and not empty.is_dirty() and not empty.can_undo(), "空页数组不制造修改")
	var changed := document.get_guide_pages()
	changed[0].text = "新正文"
	changed[0].format = "markdown"
	var result := document.set_guide_pages(changed)
	if _ok(result, "提交正文编辑"):
		changed[0].future.steps.append(9)
		result.value[0].text = "修改返回值"
		_check(document.document.dialogue[0].text == "新正文" and document.document.dialogue[0].future.steps == [1, 2], "输入和返回数组都不共享文档内存")
	_check(document.undo() and document.document.to_dict() == original, "编辑旧页可撤销至完整原文与格式")
	_ok(document.set_guide_pages(document.get_guide_pages()), "有重做记录时重复提交成功")
	_check(document.can_redo() and document.redo() and document.document.dialogue[0].text == "新正文", "无修改应用不破坏重做记录")


## 全部页面构成一次撤销事务，空白项被过滤但正文空格、Unicode 和 Markdown 原文不被整理。
func _test_transactions_and_blank_pages() -> void:
	var map := _map()
	map.dialogue = []
	map.properties["future"] = {"keep": [1, "原值"]}
	var document := MapEditorDocument.new()
	document.replace_document(map)
	var original := document.document.to_dict()
	var markdown := "  # 第一页 🦈\n\n**粗体** 与 `move(0, 1);`\n- 中文\n- 繁體與 English\n\n```text\n    缩进代码\n```\n  "
	var pages: Array = [{"text": " \t\r\n", "format": "markdown", "discarded": true}, {"text": markdown, "format": "markdown", "future": {"value": ["preserve"]}}, {"text": "", "format": "plain"}, {"text": "第二页\n[link](https://example.invalid/) <raw> [b]", "format": "markdown"}]
	var result := document.set_guide_pages(pages)
	if not _ok(result, "提交多页 Markdown 与空白占位"):
		return
	_check(result.value.size() == 2 and document.document.dialogue.size() == 2, "空白页不会成为真实引导页")
	_check(document.document.dialogue[0].text == markdown, "非空正文首尾空白、换行、Unicode 及 Markdown 完整保留")
	_check(document.document.dialogue[0].future.value == ["preserve"] and document.document.properties == map.properties, "只更新 dialogue，正文扩展和地图规则保留")
	_check(pages.size() == 4 and pages[0].discarded, "过滤不会修改传入数组")
	_check(document.is_dirty() and document.undo(), "多页编辑作为一次事务可撤销")
	_check(document.document.to_dict() == original and not document.is_dirty() and not document.can_undo(), "一次撤销恢复修改前所有页面")
	_check(document.redo() and document.document.dialogue.size() == 2, "一次重做恢复全部页面")
	document.mark_saved(_root_path.path_join("saved.json"))
	_ok(document.set_guide_pages(document.get_guide_pages()), "保存后重复应用成功")
	_check(not document.is_dirty(), "重复提交保留保存点")
	_ok(document.set_guide_pages([{ "text": " \n\t", "format": "markdown" }]), "全部留空可清除引导")
	_check(document.document.dialogue.is_empty() and document.is_dirty(), "清空全部页属于真实修改")
	_check(document.undo() and document.document.dialogue.size() == 2 and not document.is_dirty(), "撤销清空回到保存点")
	var before_group := document.document.to_dict()
	document.begin_action()
	_ok(document.set_guide_pages([{ "text": "单页", "format": "markdown" }]), "分页编辑可嵌套事务")
	document.set_identity("grouped_guide", "另一张地图")
	document.end_action()
	_check(document.undo() and document.document.to_dict() == before_group, "与地图属性组合时仍为一次撤销")


## 新格式是可选枚举，旧页数和文本长度上限不缩减；非法请求保持地图和历史完整。
func _test_validation_and_limits() -> void:
	var document := MapEditorDocument.new()
	var map := _map()
	map.dialogue = [{"text": "保留的原页", "format": "plain"}]
	document.replace_document(map)
	_ok(document.set_guide_pages([{ "text": "可重做内容", "format": "markdown" }]), "建立待重做修改")
	_check(document.undo(), "保留重做基线")
	var before := document.document.to_dict()
	var bad_pages: Array = [["不是对象"], [{}], [{"text": 5}], [{"text": true}], [{"text": "x".repeat(65537)}], [{"text": "正文", "speaker": 5}], [{"text": "正文", "format": "html"}], [{"text": "正文", "format": null}], [{"text": "正文", "format": true}], [{"text": "正文", "future": Vector2.ONE}], [{"text": " ", "format": "html"}]]
	for bad: Array in bad_pages:
		_error(document.set_guide_pages(bad), "无效页及错误扩展被拒绝")
		_check(document.document.to_dict() == before and not document.is_dirty() and document.can_redo(), "失败不改文档、保存点或重做历史")
	var deep: Variant = "过深扩展"
	for _index in range(31):
		deep = {"child": deep}
	_error(document.set_guide_pages([{ "text": "页", "future": deep }]), "独立编辑使用地图根下相同的嵌套上限")
	var too_many: Array = []
	for _index in range(MapValidation.MAX_DIALOGUE + 1):
		too_many.append({"text": "页"})
	_error(document.set_guide_pages(too_many), "超过既有 4096 页上限被拒绝")
	_check(document.document.to_dict() == before and document.can_redo(), "过量页数也保留原图与重做")
	too_many.pop_back()
	_ok(document.set_guide_pages(too_many), "旧格式 4096 页仍可提交，不缩减兼容范围")
	_check(document.document.dialogue.size() == 4096, "所有旧格式页面均保留")
	var long_page: Array = [{"text": "文".repeat(65536), "format": "markdown", "speaker": "旧标题"}]
	_ok(document.set_guide_pages(long_page), "既有 65536 字符正文上限继续有效")
	_check(document.document.dialogue[0].text.length() == 65536, "中文长度按字符而不是 UTF-8 字节")
	for format: Variant in ["bad", null, 1, {}]:
		var invalid := _map()
		invalid.dialogue = [{"text": "页", "format": format}]
		var loaded := MapCodec.from_dict(invalid.to_dict(), _content, false)
		_error(loaded, "JSON 载入入口验证 format")
		_check(loaded.errors.has("dialogue[0].format 必须为 plain 或 markdown"), "格式错误定位真实页索引")
	var legacy_blank := _map()
	legacy_blank.dialogue = [{"text": " "}, {"text": "非空页"}]
	var decoded := MapCodec.from_dict(legacy_blank.to_dict(), _content, false)
	if _ok(decoded, "旧 JSON 空白页保持可载入"):
		_check(decoded.value.dialogue == legacy_blank.dialogue, "Codec 不静默重写旧空白页，过滤只发生在明确编辑提交")


## 普通 emoji 组合和 Markdown 原文不变；新私用字符拒绝提交，旧地图只读及保存继续兼容。
func _test_portable_characters() -> void:
	var ordinary := "🐬 👩🏽‍💻 ❤️ 🇨🇳 1️⃣\n*斜体* [网页](https://example.com/)"
	_check(DataValidation.is_portable_guide_text(ordinary) and DataValidation.filter_guide_text(ordinary) == ordinary, "标准 emoji、肤色、ZWJ、变体和旗帜完整保留")
	var document := MapEditorDocument.new()
	document.replace_document(_map())
	_ok(document.set_guide_pages([{ "text": ordinary, "format": "markdown" }]), "普通 emoji 可提交为引导")
	var baseline := document.document.to_dict()
	var history := document._undo_stack.size()
	for code in [0xE000, 0xF8FF, 0xF0000, 0xFFFFD, 0x100000, 0x10FFFD]:
		var private_text := "非法" + String.chr(code) + "字符"
		_error(document.set_guide_pages([{ "text": private_text, "format": "markdown" }]), "私用区输入拒绝提交：%X" % code)
		_check(document.document.to_dict() == baseline and document._undo_stack.size() == history, "拒绝后有效正文和历史不变")
	_check(DataValidation.filter_guide_text("a\uFE0Fb🐬") == "ab🐬", "苹果标志及附属变体被移除，普通 emoji 保留")
	var legacy := _map()
	legacy.dialogue = [{ "text": "旧正文🐬", "future": {"keep": true} }]
	var decoded := MapCodec.from_dict(legacy.to_dict(), _content, false)
	if not _ok(decoded, "旧私用字符地图保持可载入"):
		return
	document.replace_document(decoded.value)
	_ok(document.set_guide_pages(document.get_guide_pages()), "旧页未修改可原样提交")
	_check(document.document.dialogue == legacy.dialogue and not document.is_dirty() and not document.can_undo(), "兼容提交不删除旧源文或创建历史")
	_error(document.set_guide_pages([{ "text": "改后的正文" }]), "修改后的正文不能再提交平台私用字形")
	var path := _root_path.path_join("legacy.json")
	_ok(MapCodec.save_file(document.document, path, _content, false), "旧地图可保存且不隐式迁移")
	var loaded := MapCodec.load_file(path, _content, false)
	_check(loaded.is_ok() and loaded.value.dialogue == legacy.dialogue, "旧正文及扩展字段完整往返")


## 普通保存和另存为共享原有 dialogue 字段，失败不会覆盖有效文件，重载与快照互不共享数据。
func _test_file_roundtrip() -> void:
	var document := MapEditorDocument.new()
	document.replace_document(_map())
	var pages: Array = [{"text": "# 玩家引导\n\n**原文** 🦈", "format": "markdown", "speaker": "Muna", "future": {"items": [1, "保留"]}}, {"text": "*纯文本不解释*", "format": "plain"}]
	_ok(document.set_guide_pages(pages), "准备真实多页地图")
	var store := PlayerLevelStore.new()
	store.directory = _root_path.path_join("levels")
	var saved := store.save(document.document, _content)
	if not _ok(saved, "普通保存创建有引导的玩家关卡"):
		return
	var export_path := _root_path.path_join("export/map.json")
	_ok(MapCodec.save_file(saved.value.document, export_path, _content, false), "另存为保留分页元数据")
	for path: String in [saved.value.path, export_path]:
		var loaded := MapCodec.load_file(path, _content, false)
		if not _ok(loaded, "重新载入带分页引导的地图"):
			continue
		# JSON 数字统一按解码后的值比较，不因整数和浮点数的序列化写法产生误报。
		_check(JSON.parse_string(JSON.stringify(loaded.value.dialogue)) == JSON.parse_string(JSON.stringify(pages)), "正文、格式、speaker 与未知字段完整往返")
		var reopened := MapEditorDocument.new()
		reopened.replace_document(loaded.value, path)
		_check(not reopened.is_dirty() and reopened.get_guide_pages()[0].text == pages[0].text, "重新打开回显实际保存内容")
		var definition := LevelDefinition.from_document(loaded.value, _content, path)
		if _ok(definition, "游戏关卡可读取同一分页数据"):
			loaded.value.dialogue[0].future.items.append("更改源文档")
			_check(definition.value.document.dialogue[0].future.items.size() == 2, "游戏使用独立地图快照")
	var original_bytes := FileAccess.get_file_as_bytes(export_path)
	var broken := document.document.duplicate_document()
	broken.dialogue[1].format = "invalid"
	_error(MapCodec.save_file(broken, export_path, _content, false), "格式错误保存失败")
	_check(FileAccess.get_file_as_bytes(export_path) == original_bytes, "写盘失败后原有效引导地图逐字节不变")
	var raw := JSON.parse_string(FileAccess.get_file_as_string(export_path)) as Dictionary
	_check(raw.has("dialogue") and not raw.has("guide_pages") and not raw.properties.has("guide_pages"), "格式只复用 dialogue，不生成第二套引导字段")


## 使用内置第一关的独立副本提供可玩地图，不写回任何教学资源。
func _map() -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var map: MapDocument = loaded.value
	map.id = "guide_fixture"
	map.display_name = "Guide fixture"
	return map


## 仅清理本次根下文件，遇到链接只删除链接本身。
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


## 记录成功结果及错误明细，让后续依赖能够提前停止。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；无结果"))


## 任何拒绝输入都必须返回明确诊断。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 累计行为断言，失败统一令退出码非零。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
