extends SceneTree
## 新闸门工具覆盖纯文档、真实输入、保存及正常试玩；所有用户文件使用隔离目录。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _game: GameShell
var _temporary := ""
var _capture_dir := ""


## 可选 GPU 证据由真实视口输出，普通 headless 不生成伪截图。
func _initialize() -> void:
	Engine.max_fps = 120
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 顺序验证数据事务与正式编辑器；测试结束清理所有隔离存档。
func _run() -> void:
	_temporary = "user://tests/timed_gate_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "真实模块和地块可加载")
	_test_model()
	_test_deadlines()
	_test_runtime()
	await _test_ui()
	_cleanup(_temporary)
	print("EDITOR_TIMED_GATE_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 全地板地图提供独立起点与远处终点，避免计时前意外通关。
func _document() -> MapDocument:
	var data := MapDocument.new()
	data.id = "gate_editor_test"
	data.display_name = "闸门编辑测试"
	data.width = 10
	data.height = 8
	for y in data.height:
		for x in data.width:
			data.set_tile(Vector2i(x, y), "floor")
	data.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]}
	data.properties = {"level": {"module_limit": 1, "allowed_modules": ["movement"], "goal": {"type": "reach_position", "position": {"x": 8.5, "y": 6.5}, "radius": 0.25}, "max_ticks": 600, "completion_mode": "reach_or_clear"}, "preserved": "keep"}
	return data


## 非法操作不写数据；ID 跨敌人去重，编辑扩展对象仅修改一项并保持历史与文件往返。
func _test_model() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	var original := model.document.to_dict()
	for seconds in [0.0, -1.0, 0.01, 6.01, 10000.0001, 100000.1, NAN, INF]:
		_check(not model.place_timed_gate(Vector2i(3, 3), seconds, _content).is_ok() and model.document.to_dict() == original and not model.can_undo(), "非法秒数无部分写入 " + str(seconds))
	_check(not model.place_timed_gate(Vector2i(-1, 3), 6, _content).is_ok(), "地图外不可放置")
	model.document.set_tile(Vector2i(3, 3), "")
	_check(not model.place_timed_gate(Vector2i(3, 3), 6, _content).is_ok() and model.document.objects.is_empty(), "void 放置不自动铺地板")
	model.replace_document(_document())
	model.document.enemies = [{"id": "timed_gate_1"}]
	var added := model.place_timed_gate(Vector2i(3, 3), 6, _content)
	_check(added.is_ok() and added.value.id == "timed_gate_2" and added.value.properties.close_after_ticks == 60, "新门格心、六秒和跨实体 ID 去重")
	_check(added.value.position == {"x": 3.5, "y": 3.5} and added.value.size == 1, "一整格实际对象几何")
	_check(model._undo_stack.size() == 1 and model.document.cells == _document().cells, "放置一次事务且不改地形")
	var before := model.document.to_dict()
	_check(not model.place_timed_gate(Vector2i(3, 3), 7, _content).is_ok() and model.document.to_dict() == before, "同一位置不能叠放对象")
	_check(model.undo() and model.document.objects.is_empty(), "一次撤销移除闸门")
	_check(model.redo() and model.document.to_dict() == before, "一次重做恢复对象")
	model.document.enemies.clear()
	var gate: Dictionary = model.document.objects[0]
	gate["custom"] = {"future": [1, 2]}
	gate.properties["preserved"] = "gate_extra"
	gate.size = 1.5
	gate.position = {"x": 3.25, "y": 3.25}
	model.replace_document(model.document)
	before = model.document.to_dict()
	_check(MapEditorTimedGate.at_position(model.document, Vector2(2.6, 2.6)) == gate.id, "命中旧非格心多格门的完整矩形")
	_check(model.set_timed_gate_seconds(gate.id, 3.5).is_ok(), "旧门可修改倒计时")
	var expected := before.duplicate(true)
	expected.objects[0].properties.close_after_ticks = 35
	_check(model.document.to_dict() == expected, "修改仅影响倒计时且全部扩展原样保留")
	var history := model._undo_stack.size()
	_check(model.set_timed_gate_seconds(gate.id, 3.5).is_ok() and model._undo_stack.size() == history, "等值提交不增加历史")
	_check(model.undo() and model.document.to_dict() == before and not model.is_dirty(), "撤销恢复保存点和完整旧对象")
	_check(model.redo() and model.document.to_dict() == expected, "重做保留全部对象字段")
	_check(model.set_timed_gate_seconds(gate.id, 0.1).is_ok() and model.document.objects[0].properties.close_after_ticks == 1, "最小0.1秒为一tick")
	# 原格式的巨大倒计时仍可用于没有总时限的旧地图，限时关卡另行覆盖严格比较。
	model.document.properties.level.max_ticks = 0
	_check(model.set_timed_gate_seconds(gate.id, 100000).is_ok() and model.document.objects[0].properties.close_after_ticks == 1000000, "最大秒数遵守既有格式边界")
	_check(model.set_timed_gate_seconds(gate.id, 99999.9).is_ok() and model.document.objects[0].properties.close_after_ticks == 999999, "上边界小数精确转换为整数tick")
	var roundtrip := MapCodec.from_dict(JSON.parse_string(JSON.stringify(model.document.to_dict())), _content, true)
	_check(roundtrip.is_ok() and JSON.parse_string(JSON.stringify(roundtrip.value.to_dict())) == JSON.parse_string(JSON.stringify(model.document.to_dict())), "现有格式完整JSON往返")
	var obstacle := {"id": "obstacle", "type": "destructible", "position": {"x": 7.5, "y": 3.5}, "size": 1, "properties": {"max_health": 1}}
	model.document.objects.append(obstacle)
	_check(not model.place_timed_gate(Vector2i(7, 3), 6, _content).is_ok(), "新门不覆盖其他机关")
	before = model.document.to_dict()
	_check(not model.remove_timed_gate("obstacle").is_ok() and model.document.to_dict() == before, "删除工具不能删障碍物")
	_check(model.remove_timed_gate(gate.id).is_ok() and model.document.objects == [obstacle], "删除仅移除指定闸门")
	_check(model.undo() and model.document.to_dict() == before, "删除也可完整撤销")
	var cap := _document()
	for index in MapValidation.MAX_ENTITIES:
		cap.objects.append({"id": "extension_%d" % index, "type": "future", "position": {"x": 0.5, "y": 0.5}})
	model.replace_document(cap)
	_check(not model.place_timed_gate(Vector2i(3, 3), 6, _content).is_ok() and not model.can_undo(), "对象容量达到上限不能再写入")


## 以整数 tick 覆盖等于、超过与恰好提前一 tick；非法事务和写盘不破坏旧数据。
func _test_deadlines() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	var original := model.document.to_dict()
	for seconds in [60.0, 60.1, 3000.0]:
		model.replace_document(_document())
		_check(not model.place_timed_gate(Vector2i(3, 3), seconds, _content).is_ok() and model.document.to_dict() == original and not model.can_undo(), "不允许新门等于或晚于60秒总时限 " + str(seconds))
	model.replace_document(_document())
	var created := model.place_timed_gate(Vector2i(3, 3), 59.9, _content)
	if not _check(created.is_ok(), "总时限前一tick允许放置"):
		return
	var identity: String = created.value.id
	var before := model.document.to_dict()
	var history := model._undo_stack.size()
	for seconds in [60.0, 60.1, 3000.0]:
		_check(not model.set_timed_gate_seconds(identity, seconds).is_ok() and model.document.to_dict() == before and model._undo_stack.size() == history, "已有门非法改时不改数据和历史 " + str(seconds))
	for seconds in [59.9, 59.8]:
		_check(not model.set_time_limit_seconds(seconds).is_ok() and model.document.to_dict() == before and model._undo_stack.size() == history, "缩短总时间不能等于或早于已有门 " + str(seconds))
	_check(model.set_time_limit_seconds(60.1).is_ok(), "增加总时间允许提交")
	_check(model.undo() and model.document.to_dict() == before, "撤销增加时限恢复原图")
	var filename := _temporary.path_join("deadline.json")
	_check(MapCodec.save_file(model.document, filename, _content, false).is_ok(), "合法倒计时写盘成功")
	var bytes := FileAccess.get_file_as_bytes(filename)
	for ticks in [600, 601, 30000]:
		var candidate := model.document.duplicate_document()
		candidate.objects[0].properties.close_after_ticks = ticks
		_check(not MapCodec.validate(candidate, _content, false).is_ok(), "无出生点要求的草稿校验也拒绝不合理倒计时 " + str(ticks))
		_check(not MapCodec.from_dict(candidate.to_dict(), _content, true).is_ok(), "读取JSON不能绕过总时限校验 " + str(ticks))
		_check(not LevelDefinition.from_document(candidate, _content).is_ok(), "正常游玩/试玩入口拒绝不合理倒计时 " + str(ticks))
		_check(not MapCodec.save_file(candidate, filename, _content, false).is_ok() and FileAccess.get_file_as_bytes(filename) == bytes, "无效保存不能覆盖原文件 " + str(ticks))
	model.replace_document(_document())
	_check(model.set_time_limit_seconds(0.2).is_ok() and model.place_timed_gate(Vector2i(3, 3), 0.1, _content).is_ok(), "小数总时限前一tick合法")
	before = model.document.to_dict()
	_check(not model.set_timed_gate_seconds(model.document.objects[0].id, 0.2).is_ok() and model.document.to_dict() == before, "0.2秒等值判断没有浮点宽容")
	model.replace_document(_document())
	model.document.properties.level.max_ticks = 0
	model.document.properties.level.completion_mode = "goal"
	_check(model.place_timed_gate(Vector2i(3, 3), 100000, _content).is_ok() and MapCodec.validate(model.document, _content, true).is_ok(), "旧不限时地图保留既有格式边界")
	model.document.properties.level.erase("max_ticks")
	_check(MapCodec.validate(model.document, _content, true).is_ok(), "旧图缺少总时限不凭空写入限时")
	model.document.player_spawn = null
	model.document.properties.level.max_ticks = 600
	_check(not MapCodec.validate(model.document, _content, false).is_ok(), "未完成草稿同样检查既有门的时间关系")


## 编辑产生的对象交给真实会话，关闭 tick、暂停和重试全部沿用原模拟规则。
func _test_runtime() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	model.place_timed_gate(Vector2i(3, 3), 0.3, _content)
	var definition := LevelDefinition.from_document(model.document, _content)
	if not _check(definition.is_ok(), "编辑闸门可直接创建正式关卡"):
		return
	var session := GameSession.create(definition.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	session.source = "main() {}"
	_check(session.run().is_ok(), "真实会话从开放闸门开始运行")
	session.step()
	session.pause()
	for index in 10:
		session.step()
	_check(session.world.tick_index == 1 and not session.world.objects[0].is_blocking(1), "暂停冻结闸门倒计时")
	session.resume()
	session.step()
	_check(not session.world.objects[0].is_blocking(session.world.tick_index), "截止前一tick仍开放")
	session.step()
	_check(session.world.objects[0].is_blocking(session.world.tick_index) and session.world.tick_index == 3, "指定tick开始关门")
	session.reset()
	session.run()
	_check(session.world.tick_index == 0 and not session.world.objects[0].is_blocking(0), "重新运行重置闸门")
	_check(model.document.objects[0].properties.close_after_ticks == 3, "世界运行不回写地图对象")


## 真正地图点击可选择、增删门并更改秒数；保存和未保存试玩保留每扇门独立的时间。
func _test_ui() -> void:
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.settings_path = _temporary.path_join("settings.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	root.add_child(_game)
	await _settle()
	var editor := _game._editor
	var model := editor.editor_document
	model.replace_document(_document())
	editor._map_view.reset_view()
	await _settle()
	var field := editor._gate_timer_field
	var original := model.document.to_dict()
	_check(field.text == "6" and not model.is_dirty(), "新门默认六秒且打开表单无数据改动")
	field.grab_focus()
	field.release_focus()
	_check(model.document.to_dict() == original and not model.can_undo(), "只浏览秒表无新增默认对象或历史")
	await _click(editor._gate_add_button)
	_check(editor._canvas.paint_mode == MapEditorCanvas.PaintMode.GATE_ADD and not editor._paint_button.button_pressed, "加号启用互斥放置工具")
	await _click_point(_cell_point(editor, Vector2i(3, 3)))
	_check(model.document.objects.size() == 1 and model.document.objects[0].properties.close_after_ticks == 60, "真实地图点击放置默认门")
	var first: String = model.document.objects[0].id
	_check(editor._canvas.selected_gate_id == first and model._undo_stack.size() == 1, "放置后高亮且只有一次历史")
	await _edit_seconds(editor, "3.5")
	_check(MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 35 and model._undo_stack.size() == 2, "回车修改选中门秒数为单次事务")
	await _click_point(_cell_point(editor, Vector2i(5, 3)))
	var second: String = model.document.objects[1].id
	_check(model.document.objects.size() == 2 and model.document.objects[1].properties.close_after_ticks == 35, "连续放置使用当前秒数")
	await _edit_seconds(editor, "8")
	_check(MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 35 and MapEditorTimedGate.find(model.document, second).properties.close_after_ticks == 80, "不同门倒计时独立修改")
	await _click(editor._paint_button)
	var before := model.document.to_dict()
	var count := model._undo_stack.size()
	await _click_point(_cell_point(editor, Vector2i(3, 3)))
	_check(editor._canvas.selected_gate_id == first and field.text == "3.5" and model.document.to_dict() == before and model._undo_stack.size() == count, "普通画笔点击已有门只读选择，不涂改地板或写历史")
	for text: String in ["0", "-1", "abc", "1e3", "100001", "3.51", "", "NaN", "INF"]:
		await _edit_seconds(editor, text)
		_check(field.text == "59.9" and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 599 and not editor._message_dialog.visible, "非法输入失焦后回填当前最大值且不弹警告 " + text)
		await _edit_seconds(editor, "3.5")
	await _click(field)
	field.text = "不是秒数"
	field.text_changed.emit(field.text)
	count = model._undo_stack.size()
	field.release_focus()
	await _settle()
	_check(field.text == "59.9" and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 599 and model._undo_stack.size() == count + 1 and not editor._message_dialog.visible, "不按回车仅离开输入框也自动回填并提交一次事务")
	await _edit_seconds(editor, "3.5")
	await _click(field)
	field.text = ""
	field.text_changed.emit("")
	_check(field.text.is_empty() and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 35, "输入中的空白保持可编辑且不提前修改门")
	field.text = "3."
	field.text_changed.emit("3.")
	_check(field.text == "3." and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 35, "输入小数点过程中不提前回填或写历史")
	field.release_focus()
	await _settle()
	_check(field.text == "3" and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 30, "合法整秒小数格式失焦后规范显示")
	await _click(field)
	field.text = "4.2"
	field.text_changed.emit("4.2")
	await _click_point(_cell_point(editor, Vector2i(5, 3)))
	_check(field.text == "8" and MapEditorTimedGate.find(model.document, first).properties.close_after_ticks == 42 and MapEditorTimedGate.find(model.document, second).properties.close_after_ticks == 80, "切换选择时待提交输入只能应用于原门")
	await _click(field)
	field.text = "9.1"
	field.text_changed.emit("9.1")
	var filename := _temporary.path_join("gate.json")
	editor._write_document(filename)
	field.release_focus()
	_check(not model.is_dirty() and MapCodec.load_file(filename, editor.registry, true).value.objects[1].properties.close_after_ticks == 91, "未失焦保存提交并写入真实文件")
	editor._load_document(filename)
	await _settle()
	_check(editor._canvas.selected_gate_id.is_empty() and field.text == "6" and model.document.objects.size() == 2, "重新打开保留门并清除旧表单选择")
	await _click(editor._gate_remove_button)
	await _click_point(_cell_point(editor, Vector2i(3, 3)))
	_check(model.document.objects.size() == 1 and model.document.objects[0].id == second and model.document.get_tile_id(Vector2i(3, 3)) == "floor", "删除工具仅移除点击门，底层地板不受影响")
	editor._undo()
	_check(model.document.objects.size() == 2 and not model.is_dirty(), "删除一次撤销恢复保存点")
	editor._redo()
	_check(model.document.objects.size() == 1, "删除可重做")
	await _key(KEY_ESCAPE)
	_check(editor._canvas.paint_mode == MapEditorCanvas.PaintMode.BRUSH and not editor._gate_remove_button.button_pressed, "Esc 退出删除工具恢复画笔")
	editor._start_playtest()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.assembly.modules.is_empty() and _game.session.level.document.objects.size() == 1, "未保存闸门进入正常空装配试玩")
	_game._dialogue_dialog.hide()
	_game._return_to_editor()
	await _settle()
	_check(model.is_dirty() and model.can_undo() and model.document.objects.size() == 1, "返回保留同一未保存对象与历史")
	await _test_ui_deadlines(editor)
	await _test_layout(editor)
	_game.queue_free()
	await _settle()


## 倒计时输入按当前关卡上限修正，实际数据仍禁止等于或超过总时限。
func _test_ui_deadlines(editor: MapEditor) -> void:
	var model := editor.editor_document
	var original := model.document.duplicate_document()
	var original_path := model.path
	model.replace_document(_document())
	editor._map_view.reset_view()
	editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	await _settle()
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(editor._gate_timer_field)
	await _settle()
	var before := model.document.to_dict()
	for text in ["60", "3000"]:
		await _edit_seconds(editor, text)
		_check(not editor._message_dialog.visible and editor._gate_timer_field.text == "59.9" and model.document.to_dict() == before and not model.can_undo(), "新门非法候选回填最大值但不产生地图历史 " + text)
	await _click(editor._gate_add_button)
	await _click_point(_cell_point(editor, Vector2i(3, 3)))
	var identity: String = model.document.objects[0].id
	_check(MapEditorTimedGate.find(model.document, identity).properties.close_after_ticks == 599, "回填的最大倒计时用于下一扇门")
	await _edit_seconds(editor, "6")
	var history := model._undo_stack.size()
	await _edit_seconds(editor, "60")
	_check(not editor._message_dialog.visible and editor._gate_timer_field.text == "59.9" and MapEditorTimedGate.find(model.document, identity).properties.close_after_ticks == 599 and model._undo_stack.size() == history + 1, "选中闸门回填最大值为一次可撤销事务")
	model.undo()
	_check(MapEditorTimedGate.find(model.document, identity).properties.close_after_ticks == 60, "撤销回填可恢复门原倒计时")
	model.redo()
	history = model._undo_stack.size()
	await _edit_seconds(editor, "6000")
	_check(model._undo_stack.size() == history, "已是最大值时再次非法输入不重复写历史")
	scroll.ensure_control_visible(editor._time_limit_field)
	await _settle()
	await _click(editor._time_limit_field)
	editor._time_limit_field.text = "59.9"
	editor._time_limit_field.text_changed.emit("59.9")
	before = model.document.to_dict()
	history = model._undo_stack.size()
	await _key(KEY_ENTER)
	_check(editor._message_dialog.visible and editor._time_limit_field.text == "60" and model.document.to_dict() == before and model._undo_stack.size() == history, "缩短总时限仍不能让已有闸门等于截止时间")
	editor._message_dialog.hide()
	editor._time_limit_field.release_focus()
	await _settle()
	model.replace_document(_document())
	editor._select_gate_tool(MapEditorCanvas.PaintMode.GATE_ADD)
	model.set_time_limit_seconds(50)
	_check(editor._gate_timer_field.text == "49.9" and editor._gate_timer_field.tooltip_text.contains("49.9"), "缩短总时间时新门候选和悬浮最大值同步修正")
	await _click_point(_cell_point(editor, Vector2i(3, 3)))
	_check(not editor._message_dialog.visible and model.document.objects[0].properties.close_after_ticks == 499, "缩短总时间后的连续放置使用新的合法最大值")
	for locale in ["zh_CN", "zh_HK", "en"]:
		_game.settings.set_language(locale)
		await _settle()
		var tooltip := editor._gate_timer_field.tooltip_text
		_check(tooltip.contains("49.9") and tooltip.contains("\n") and (tooltip.contains("Invalid input") if locale == "en" else tooltip.contains("無效輸入") if locale == "zh_HK" else tooltip.contains("无效输入")), "三种语言悬浮规则保留当前最大值与换行 " + locale)
	_game.settings.set_language("zh_CN")
	var shortest := _document()
	shortest.properties.level.max_ticks = 1
	model.replace_document(shortest)
	await _settle()
	before = model.document.to_dict()
	history = model._undo_stack.size()
	_check(editor._gate_add_button.disabled and not editor._gate_timer_field.editable and editor._gate_timer_field.tooltip_text.contains("0.2"), "0.1秒关卡没有合法正倒计时，禁用放置并在悬浮中说明")
	editor._place_timed_gate(Vector2i(3, 3))
	_check(model.document.to_dict() == before and model._undo_stack.size() == history and not editor._message_dialog.visible, "最短关卡不能放置零秒门且没有警告弹窗")
	model.set_time_limit_seconds(0.2)
	_check(not editor._gate_add_button.disabled and editor._gate_timer_field.editable and editor._gate_timer_field.text == "0.1", "提高总时限重新启用输入并收敛到一个tick")
	await _edit_seconds(editor, "0.2")
	_check(editor._gate_timer_field.text == "0.1", "最小可放置关卡回填0.1秒")
	model.set_time_limit_seconds(3600)
	await _edit_seconds(editor, "100000")
	_check(editor._gate_timer_field.text == "3599.9" and editor._gate_timer_field.tooltip_text.contains("3599.9"), "最大关卡限时也严格少一个tick")
	model.replace_document(original, original_path)
	editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	editor._new_gate_seconds = 6
	editor._sync_gate_timer(true)
	await _settle()


## 三种语言和高分屏字号下控件留在卡内，拖动原分隔位置不能改变卡宽或地图内容。
func _test_layout(editor: MapEditor) -> void:
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	var sizes := [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(3840, 2160)]
	for dimensions: Vector2i in sizes:
		var resolution := "%dx%d" % [dimensions.x, dimensions.y]
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(resolution):
			continue
		_game.settings.set_window_resolution(resolution)
		for language in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(language)
			for percentage in [100, 125, 150, 200]:
				_game.settings.set_ui_scale(percentage)
				await _settle(8)
				var row := editor.find_child("MapEditorTimedGateRow", true, false) as Control
				var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
				scroll.ensure_control_visible(row)
				await _settle(8)
				var context: String = resolution + language + str(percentage)
				_check(scroll.get_global_rect().grow(1).encloses(row.get_global_rect()), "闸门控件完整留在卡内 " + context)
				_check(not editor._gate_add_button.get_global_rect().intersects(editor._gate_timer_field.get_global_rect()), "加号和秒表不相交 " + context)
				_check(editor._gate_add_button.get_global_rect().size.x == editor._gate_add_button.get_global_rect().size.y, "加号保持圆形 " + context)
				var field := editor._gate_timer_field
				var text_width := field.get_theme_font("font").get_string_size("100000", HORIZONTAL_ALIGNMENT_LEFT, -1, field.get_theme_font_size("font_size")).x
				var fraction_width := field.get_theme_font("font").get_string_size("99999.9", HORIZONTAL_ALIGNMENT_LEFT, -1, field.get_theme_font_size("font_size")).x
				_check(field.size.x >= maxf(text_width, fraction_width) + 8, "最宽合法秒数和光标完整可见 " + context)
				_check(root.get_visible_rect().grow(1).encloses(editor._properties_card.get_global_rect()), "固定卡片不挤出窗口 " + context)
				var before := editor.editor_document.document.to_dict()
				var history := editor.editor_document._undo_stack.size()
				await _click(editor._gate_add_button)
				await _click(editor._gate_timer_field)
				_check(editor._gate_add_button.button_pressed and editor._gate_timer_field.has_focus(), "高分屏秒表点击仍保留工具 " + context)
				var blank := editor._properties_card.get_global_rect().position + Vector2(18, 6)
				await _click_point(blank)
				_check(not editor._gate_add_button.button_pressed and root.gui_get_focus_owner() == null and editor._canvas.paint_mode == MapEditorCanvas.PaintMode.BRUSH, "高分屏卡片空白结束工具和焦点 " + context)
				_check(editor.editor_document.document.to_dict() == before and editor.editor_document._undo_stack.size() == history, "高分屏空白取消不修改数据 " + context)
				var width := editor._properties_card.size.x
				var point := Vector2(editor._properties_card.global_position.x - 4, editor._properties_card.get_global_rect().get_center().y)
				_mouse(point, true)
				var motion := InputEventMouseMotion.new()
				motion.position = point - Vector2(100, 0)
				motion.button_mask = MOUSE_BUTTON_MASK_LEFT
				root.push_input(motion)
				_mouse(motion.position, false)
				await _settle()
				_check(is_equal_approx(editor._properties_card.size.x, width) and editor.find_child("MapEditorWorkspace", true, false) is HBoxContainer, "拖动卡片边缘不改变宽度 " + context)
				await _capture("timed_gate_%s_%s_%d" % [resolution, language, percentage])
	_game.settings.set_language("zh_CN")
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution("1280x800")
	await _settle(8)
	editor._map_view.set_zoom(2.0)
	await _settle(8)
	var gate_cell := Vector2i(5, 3)
	await _click_point(_cell_point(editor, gate_cell))
	_check(editor._canvas.selected_gate_id == editor.editor_document.document.objects[0].id, "观察倍率改变后仍命中同一门")


## 通过真正回车提交药丸输入，而不是直接调用模型方法。
func _edit_seconds(editor: MapEditor, text: String) -> void:
	await _click(editor._gate_timer_field)
	editor._gate_timer_field.text = text
	editor._gate_timer_field.text_changed.emit(text)
	await _key(KEY_ENTER)
	editor._gate_timer_field.release_focus()
	await _settle()


## 地图格心转换使用真实画布变换，适用于缩放与视口平移。
func _cell_point(editor: MapEditor, cell: Vector2i) -> Vector2:
	return editor._canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2.ONE * 0.5) * editor._canvas.cell_size)


## 点击实际控件矩形的中心并等待布局与失焦回调。
func _click(control: Control) -> void:
	await _click_point(control.get_global_rect().get_center())


## 成对鼠标输入不调用按钮或画布的内部回调。
func _click_point(point: Vector2) -> void:
	_mouse(point, true)
	_mouse(point, false)
	await _settle()


## 用客户区坐标投递左键按下或抬起。
func _mouse(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	root.push_input(event)


## 真实键盘事件保留按下与抬起，覆盖回车及取消。
func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await _settle()


## 等待容器排序与原生焦点提交，不依赖墙钟长时间睡眠。
func _settle(frames: int = 6) -> void:
	for index in frames:
		await process_frame


## 仅真实 GPU 运行保存视口像素，不修改用户屏幕或通过假图片验证布局。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_capture_dir.path_join(filename + ".png"))


## 失败同时计数并输出明确断言，避免脚本零退出码掩盖回归。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 删除本轮测试自己创建的文件，不访问正式设置、关卡或进度。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
