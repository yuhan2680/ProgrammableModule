extends SceneTree
## 限时地图使用真实会话、世界与编辑器验证，所有文件写入独立测试目录。
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 延后测试以确保自动加载的类与场景树就绪。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 校验序列覆盖数据、截止边界、分波、界面输入、保存以及暂停重置。
func _run() -> void:
	_temporary = "user://tests/time_limit_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "真实内容可加载")
	_test_model()
	_test_outcomes()
	_test_enemies()
	await _test_editor()
	_cleanup(_temporary)
	print("地图限时回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 全地板夹具只提供真实移动与射击能力，默认没有终点或敌人。
func _document(ticks: int = 600) -> MapDocument:
	var result := MapDocument.new()
	result.width = 12
	result.height = 8
	for y in 8:
		for x in 12:
			result.set_tile(Vector2i(x, y), "floor")
	result.player_spawn = {"position": {"x": 1.5, "y": 3.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]}
	result.properties = {"level": {"module_limit": 1, "allowed_modules": ["movement", "shooting"], "max_ticks": ticks, "completion_mode": "reach_or_clear"}, "preserved": "keep"}
	return result


## 正秒数按0.1秒精度保存，越界与畸形元数据不能覆盖有效值。
func _test_model() -> void:
	var model := MapEditorDocument.new()
	_check(model.get_time_limit_seconds() == 60, "旧无时限地图默认显示60秒")
	model.replace_document(_document())
	var before := model.document.to_dict()
	for value in [0.0, -1.0, 3600.1, 99999.0, NAN, INF, 0.01]:
		_check(not model.set_time_limit_seconds(value).is_ok() and model.document.to_dict() == before, "非法时限不更改文档 " + str(value))
	_check(model.set_time_limit_seconds(3600).is_ok() and model.document.properties.level.max_ticks == 36000, "最大3600秒转为36000tick")
	_check(model.document.properties.preserved == "keep", "修改时限保留扩展字段")
	_check(model.undo() and model.get_time_limit_seconds() == 60, "撤销恢复60秒")
	_check(model.redo() and model.get_time_limit_seconds() == 3600, "重做恢复最大时限")
	var count := model._undo_stack.size()
	model.set_time_limit_seconds(3600)
	_check(model._undo_stack.size() == count, "重复提交相同值不产生历史")
	var data := _document()
	data.properties.level.max_ticks = 0
	_check(not LevelDefinition.from_document(data, _content).is_ok(), "限时规则不能通过JSON绕过正数限制")
	data.properties.level.max_ticks = 36001
	_check(not LevelDefinition.from_document(data, _content).is_ok(), "JSON也拒绝超3600秒")
	data.properties.level.max_ticks = 600
	data.properties.level.completion_mode = "other"
	_check(not LevelDefinition.from_document(data, _content).is_ok(), "无效目标模式被拒绝")
	data.properties.level.erase("completion_mode")
	data.properties.level.max_ticks = 0
	_check(LevelDefinition.from_document(data, _content).is_ok(), "旧关卡缺省规则保留不限时兼容")


## 会话总从空装配安装真实模块，再通过解析器运行源码。
func _session(document: MapDocument, code: String, module_id: String = "movement") -> GameSession:
	var parsed := LevelDefinition.from_document(document, _content)
	if not _check(parsed.is_ok(), "测试关卡定义有效"):
		return null
	var session := GameSession.create(parsed.value, _content)
	_check(session.assembly.add_module(module_id, Vector2.ZERO, "unit").is_ok(), "真实装配可安装")
	session.source = code
	_check(session.run().is_ok(), "真实程序可以启动")
	return session


## 空程序也持续计时；空场不自动获胜，截止tick到达才算成功。
func _test_outcomes() -> void:
	var session := _session(_document(10), "main() {}")
	_check(session.state == GameSession.State.RUNNING and session.world.tick_index == 0, "无敌人与终点时不自动获胜")
	session.step()
	session.pause()
	for index in 20:
		session.step()
	_check(session.world.tick_index == 1 and session.state == GameSession.State.PAUSED, "暂停冻结倒计时")
	session.resume()
	for index in 8:
		session.step()
	_check(session.state == GameSession.State.RUNNING and session.world.tick_index == 9, "截止前主程序结束仍继续计时")
	session.step()
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 10 and session.message.contains("时间已到"), "截止时失败且不多走一个tick")
	session.reset()
	session.run()
	_check(session.state == GameSession.State.RUNNING and session.world.tick_index == 0, "重试恢复全部时间")
	var document := _document(10)
	document.properties.level.goal = {"type": "reach_position", "position": {"x": 2.75, "y": 3.5}, "radius": 0.25}
	session = _session(document, "main() { move(0, 1) }")
	for index in 10:
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.world.tick_index == 10, "截止tick刚好到达仍通关")
	document.properties.level.max_ticks = 9
	session = _session(document, "main() { move(0, 1) }")
	for index in 10:
		session.step()
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 9, "截止后才能到达则按时失败")


## 真正射击清敌可以替代终点；存活模块、未来波次和同帧玩家死亡不能误胜。
func _test_enemies() -> void:
	var loaded := MapCodec.load_file("res://data/levels/level_004.json", _content, true)
	var document: MapDocument = loaded.value
	document.properties.level.completion_mode = "reach_or_clear"
	document.properties.level.goal = {"type": "reach_position", "position": {"x": 9.5, "y": 2.5}, "radius": 0.25}
	var session := _session(document, "main() {}\ntick() { shoot(0) }", "shooting")
	for index in 200:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.remaining_enemy_count() == 0 and session.world.player.position.x == 1.5, "真实射击清空敌人即通关，无需抵达终点")
	document.properties.level.goal.position = {"x": 2.75, "y": 2.5}
	document.properties.level.max_ticks = 10
	session = _session(document, "main() { move(0, 1) }")
	for index in 10:
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.remaining_enemy_count() == 1, "到达终点即可通关，无需同时清除敌人")
	document.properties.level.erase("goal")
	document.properties.level.max_ticks = 20
	var second: Dictionary = document.enemies[0].duplicate(true)
	second.id = "guard_two"
	second.position = {"x": 9.5, "y": 1.5}
	document.enemies.append(second)
	session = _session(document, "main() {}", "shooting")
	var enemy := session.world.get_machine("guard")
	enemy.modules[0].apply_damage(999)
	session.step()
	_check(session.state == GameSession.State.RUNNING and session.remaining_enemy_count() == 2, "一个模块损毁不等于整台敌人清除")
	enemy.modules[1].apply_damage(999)
	session.step()
	_check(session.state == GameSession.State.RUNNING and session.remaining_enemy_count() == 1, "场上还有另一台敌人时不通关")
	for module in session.world.get_machine("guard_two").modules:
		module.apply_damage(999)
	session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "没有终点也可通过清空全部敌人通关")
	var waves: MapDocument = MapCodec.load_file("res://data/levels/level_012.json", _content, true).value
	waves.properties.level.completion_mode = "reach_or_clear"
	waves.properties.level.erase("goal")
	for entry: Dictionary in waves.enemies:
		entry.properties.spawn_delay_ticks = 50
	session = _session(waves, "main() {}", "shooting")
	for index in 10:
		session.step()
	_check(session.state == GameSession.State.RUNNING and session.remaining_enemy_count() == 8 and session.world.machines.size() == 1, "尚未生成的分波敌人仍算未清除")
	session = _session(document, "main() {}", "shooting")
	for machine in session.world.machines:
		for module in machine.modules:
			module.apply_damage(999)
	session.step()
	_check(session.state == GameSession.State.FAILED, "玩家与最后敌人同时被毁时仍为失败")


## 真实界面直接点击数字区域，覆盖范围、默认值、失焦、保存与中英布局。
func _test_editor() -> void:
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/map_editor.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("drafts")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	var editor := game._editor
	var field := editor._time_limit_field
	_check(field.text == "60", "默认显示60秒")
	_check(editor._player_health_field.text == "1", "玩家耐久默认显示1")
	var legacy_health := editor._player_health_field
	var legacy_document := editor.editor_document.document.to_dict()
	var legacy_history := [editor.editor_document._undo_stack.size(), editor.editor_document._redo_stack.size()]
	_check(not legacy_document.properties.level.has("player_max_health"), "旧示例地图没有显式玩家耐久覆盖")
	legacy_health.grab_focus()
	legacy_health.release_focus()
	await _settle()
	_check(editor.editor_document.document.to_dict() == legacy_document and not editor.editor_document.is_dirty() and [editor.editor_document._undo_stack.size(), editor.editor_document._redo_stack.size()] == legacy_history, "仅聚焦并离开耐久输入不改旧地图、保存点或历史")
	legacy_health.grab_focus()
	editor._commit_module_limit()
	_check(editor.editor_document.document.to_dict() == legacy_document and not editor.editor_document.is_dirty() and [editor.editor_document._undo_stack.size(), editor.editor_document._redo_stack.size()] == legacy_history, "焦点内保存提交入口不把未编辑默认1写为覆盖")
	legacy_health.text_changed.emit("1")
	legacy_health.text_submitted.emit("1")
	_check(editor.editor_document.document.properties.level.get("player_max_health") == 1.0 and editor.editor_document.is_dirty() and editor.editor_document._undo_stack.size() == legacy_history[0] + 1, "主动重新键入同值1会建立显式耐久覆盖及一次历史")
	legacy_health.release_focus()
	editor._undo()
	_check(editor.editor_document.document.to_dict() == legacy_document and not editor.editor_document.is_dirty() and legacy_health.text == "1", "撤销主动同值覆盖恢复旧地图缺省继承")
	for size: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = size
		for locale: String in ["zh_CN", "en"]:
			game.settings.set_language(locale)
			await _settle()
			var row := editor.find_child("MapEditorTimeLimitRow", true, false) as Control
			var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as Control
			_check(scroll.get_global_rect().encloses(row.get_global_rect()), "限时输入在属性卡片内部 " + locale + str(size))
			_check(row.get_global_rect().end.x <= editor._reset_goal_button.global_position.x, "限时与重置按钮不重叠 " + locale + str(size))
			var point_pill := editor._spawn_button.get_parent() as Control
			var timer_pill := editor.find_child("MapEditorTimeLimitPill", true, false) as Control
			_check(absf(point_pill.get_global_rect().get_center().x - timer_pill.get_global_rect().get_center().x) <= 1.0, "时间药丸与起终点药丸左右对称 " + locale + str(size))
			await _check_player_layout(editor, locale, size)
	root.size = Vector2i(1280, 800)
	await _settle()
	var event := InputEventMouseButton.new()
	event.position = field.global_position + field.size * 0.5
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	_check(field.has_focus(), "点击秒表旁空白输入区获得文字光标")
	for text: String in ["0", "99999", "3601", "-3", "abc", "1e3", "1.23"]:
		field.text = text
		field.text_changed.emit(text)
		_check(field.text == "60", "非法输入与粘贴恢复60秒 " + text)
	field.text = ""
	field.release_focus()
	await _settle()
	_check(field.text == "60" and editor.editor_document.document.properties.level.max_ticks == 600, "清空并失焦恢复有效60秒")
	field.grab_focus()
	field.select_all()
	for code in [51, 54, 48, 48]:
		var key := InputEventKey.new()
		key.pressed = true
		key.unicode = code
		root.push_input(key)
		await _settle()
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.keycode = KEY_ENTER
	root.push_input(enter)
	await _settle()
	_check(field.text == "3600" and editor.editor_document.document.properties.level.max_ticks == 36000, "原生键盘输入3600并按回车提交")
	field.release_focus()
	editor._undo()
	_check(field.text == "60", "撤销同步还原限时框")
	editor._redo()
	_check(field.text == "3600", "重做同步恢复限时框")
	field.grab_focus()
	field.text = "120"
	var filename := _temporary.path_join("timed.json")
	editor._write_document(filename)
	field.release_focus()
	editor._load_document(filename)
	await _settle()
	_check(field.text == "120" and not editor.editor_document.is_dirty(), "未失焦时保存仍提交正确值并可重开")
	await _test_health_input(editor, filename)
	editor._module_limit_field.value = 2
	editor._write_document(filename)
	_check(editor.editor_document.get_module_limit() == 2 and not editor.editor_document.is_dirty(), "同排模块数量上限仍可独立修改和保存")
	var size_toggle := editor.find_child("MapEditorSizeCollapse", true, false) as Button
	var scene_toggle := editor.find_child("MapEditorSceneCollapse", true, false) as Button
	var dimensions := editor.find_child("MapEditorDimensions", true, false) as Control
	var paint_tools := editor.find_child("MapEditorPaintTools", true, false) as Control
	var scene_controls := editor.find_child("MapEditorSceneControlsBody", true, false) as Control
	var player_limits := editor.find_child("MapEditorPlayerLimits", true, false) as Control
	var snapshot := editor.editor_document.document.to_dict()
	var history := editor.editor_document._undo_stack.size()
	size_toggle.pressed.emit()
	await _settle()
	_check(not dimensions.is_visible_in_tree() and not paint_tools.is_visible_in_tree() and scene_controls.is_visible_in_tree(), "场景编辑收起尺寸与绘制工具，玩法控制仍可见")
	scene_toggle.pressed.emit()
	await _settle()
	_check(not dimensions.is_visible_in_tree() and not scene_controls.is_visible_in_tree(), "两个分类独立收起各自控制")
	_check(not player_limits.is_visible_in_tree() and not editor._module_limit_field.is_visible_in_tree() and not editor._player_health_field.is_visible_in_tree(), "玩法折叠同时隐藏模块数量与玩家耐久")
	_check(not editor._spawn_button.is_visible_in_tree() and not editor._goal_button.is_visible_in_tree() and not editor._reset_spawn_button.is_visible_in_tree() and not editor._reset_goal_button.is_visible_in_tree() and not field.is_visible_in_tree(), "玩法折叠同时隐藏起终点、重置与限时控件")
	_check(editor._play_button.is_visible_in_tree(), "分类全部折叠后开始测试仍可见")
	_check(size_toggle.icon.resource_path.ends_with("map_editor_expand.svg") and scene_toggle.tooltip_text == "展开分类", "折叠时箭头与悬停提示切换为展开")
	_check(editor.editor_document.document.to_dict() == snapshot and editor.editor_document._undo_stack.size() == history, "折叠不改变地图数据或历史")
	editor._start_playtest()
	await _settle()
	_check(game.session != null and game.session.level.max_ticks == 1200 and game.session.level.completion_mode == "reach_or_clear", "编辑器真实试玩使用保存的限时")
	_check(game.session.assembly.modules.is_empty() and game.session.level.player_max_health == 3.125, "保存的耐久进入全新空装配试玩")
	game._dialogue_dialog.hide()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "actual_drive").is_ok(), "试玩实际安装中心模块")
	_check(game.session.assembly.add_module("movement", Vector2(0.5, 0), "actual_second").is_ok(), "试玩按已保存数量上限安装第二模块")
	game._confirm_assembly()
	await _settle()
	game.workbench.set_process(false)
	game.workbench._code.text = "main() {}"
	game.workbench.header.run_button.pressed.emit()
	_check(game.session.world != null and game.session.world.player.modules.size() == 2 and game.session.world.player.get_module("drive") == null, "运行使用玩家实际两模块装配而非出生模板")
	for module in game.session.world.player.modules:
		_check(module.max_health == 3.125 and module.health == 3.125, "保存耐久应用到实际玩家模块 " + module.id)
	game.session.step()
	_check(game.workbench._object_status.text.contains("119.9"), "状态药丸显示实际剩余秒数")
	game._return_to_editor()
	await _settle()
	_check(not editor.editor_document.is_dirty() and field.text == "120" and editor._player_health_field.text == "3.125", "试玩返回不污染已保存限时与玩家耐久")
	_check(not dimensions.is_visible_in_tree() and not paint_tools.is_visible_in_tree() and not scene_controls.is_visible_in_tree(), "试玩返回保留两个分类的折叠状态")
	size_toggle.pressed.emit()
	scene_toggle.pressed.emit()
	await _settle()
	_check(dimensions.is_visible_in_tree() and paint_tools.is_visible_in_tree() and scene_controls.is_visible_in_tree() and player_limits.is_visible_in_tree() and field.text == "120", "重新展开保留限时和全部分类控件")
	var health := editor._player_health_field
	health.grab_focus()
	health.text = "4.5"
	health.text_changed.emit(health.text)
	_check(editor.editor_document.get_player_max_health() == 3.125, "耐久键入尚未提交时不提前更改地图")
	editor._start_playtest()
	await _settle()
	_check(game.session != null and game.session.level.player_max_health == 4.5 and game.session.assembly.modules.is_empty(), "未失焦的耐久输入在开始测试时提交到新快照")
	game._dialogue_dialog.hide()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "pending_drive").is_ok(), "第二次试玩仍需真实重新装配")
	game._confirm_assembly()
	await _settle()
	game.workbench.set_process(false)
	game.workbench._code.text = "main() {}"
	game.workbench.header.run_button.pressed.emit()
	_check(game.session.world != null and game.session.world.player.get_module("pending_drive").health == 4.5, "开始测试前待提交耐久作用于真实运行模块")
	game._return_to_editor()
	await _settle()
	_check(editor.editor_document.is_dirty() and health.text == "4.5" and field.text == "120", "第二次试玩返回保留未保存耐久和原限时")
	_check(MapCodec.load_file(filename, editor.registry, false).value.properties.level.player_max_health == 3.125, "未保存试玩不会改写磁盘中的耐久")
	editor._undo()
	_check(health.text == "3.125" and not editor.editor_document.is_dirty(), "试玩返回仍可一次撤销耐久到原保存点")
	editor._redo()
	_check(health.text == "4.5" and editor.editor_document.is_dirty(), "试玩返回后重做恢复耐久编辑")
	game.queue_free()
	await _settle()


## 两种语言与窗口尺寸下检查实际字体、翻译和同排数值控件的可见几何。
func _check_player_layout(editor: MapEditor, locale: String, size: Vector2i) -> void:
	var suffix := " " + locale + str(size)
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	var limits := editor.find_child("MapEditorPlayerLimits", true, false) as Control
	var modules := editor._module_limit_field.get_parent() as Control
	var health := editor._player_health_field.get_parent() as Control
	_check(scroll.get_global_rect().encloses(limits.get_global_rect()), "玩家上限整行位于属性可视范围内" + suffix)
	_check(absf(modules.global_position.y - health.global_position.y) <= 1.0 and modules.get_global_rect().end.x <= health.global_position.x, "模块上限与耐久同排且互不重叠" + suffix)
	for group: Control in [modules, health]:
		var caption := group.get_child(0) as Label
		var input := group.get_child(1) as Control
		_check(group.get_global_rect().encloses(caption.get_global_rect()) and group.get_global_rect().encloses(input.get_global_rect()) and caption.get_global_rect().end.x <= input.global_position.x, "上限标签与输入框完整显示且无交叠" + suffix)
		_check(caption.size.x >= caption.get_minimum_size().x and input.size.x >= input.get_combined_minimum_size().x, "上限标签与输入不被压缩裁切" + suffix)
	var point_label := editor.find_child("MapEditorPointLabel", true, false) as Label
	var time_label := editor.find_child("MapEditorTimeLimitLabel", true, false) as Label
	_check(point_label.get_theme_font_size("font_size") == time_label.get_theme_font_size("font_size") and point_label.get_theme_font("font") == time_label.get_theme_font("font"), "起终点与时间限制采用相同实际字体和字号" + suffix)
	var editing_toggle := editor.find_child("MapEditorSizeCollapse", true, false) as Button
	var gameplay_toggle := editor.find_child("MapEditorSceneCollapse", true, false) as Button
	var editing_heading := editing_toggle.get_parent().get_child(0) as Label
	var gameplay_heading := gameplay_toggle.get_parent().get_child(0) as Label
	_check(editing_heading.tr(editing_heading.text) == ("Scene Editing" if locale == "en" else "场景编辑") and gameplay_heading.tr(gameplay_heading.text) == ("Scene Gameplay & Behavior" if locale == "en" else "场景玩法与行为控制"), "新分类标题按当前语言翻译" + suffix)
	for heading: Label in [editing_heading, gameplay_heading]:
		_check(scroll.get_global_rect().encloses(heading.get_global_rect()) and heading.size.x >= heading.get_minimum_size().x, "分类标题完整位于可视范围内" + suffix)
	# 敌人设置增加纵向内容，通过属性区滚动访问底部操作，窗口本身不被撑大。
	var previous_scroll := scroll.scroll_vertical
	scroll.ensure_control_visible(editor._play_button)
	await _settle()
	_check(editor._play_button.is_visible_in_tree() and scroll.get_global_rect().encloses(editor._play_button.get_global_rect()), "展开分类后可滚动到完整的开始测试按钮" + suffix)
	scroll.scroll_vertical = previous_scroll
	await _settle()


## 耐久输入通过真实键盘、提交信号及保存入口校验小数、无效值与事务恢复。
func _test_health_input(editor: MapEditor, filename: String) -> void:
	var field := editor._player_health_field
	var model := editor.editor_document
	var original := model.document.to_dict()
	field.grab_focus()
	field.select_all()
	for code in [48, 46, 49, 50, 53]:
		var key := InputEventKey.new()
		key.pressed = true
		key.unicode = code
		root.push_input(key)
		await _settle()
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.keycode = KEY_ENTER
	root.push_input(enter)
	await _settle()
	_check(field.text == "0.125" and model.get_player_max_health() == 0.125, "原生键盘从0前缀输入小数耐久并回车提交")
	field.release_focus()
	editor._undo()
	_check(field.text == "1" and model.document.to_dict() == original and not model.is_dirty(), "一次撤销耐久恢复原字段缺省和全部元数据")
	editor._redo()
	_check(field.text == "0.125" and model.get_player_max_health() == 0.125, "重做同步耐久小数输入")
	var saved := model.document.to_dict()
	var history := model._undo_stack.size()
	for invalid: String in ["0", "0.", ".", "-1", "abc", "NaN", "INF", "1000000001"]:
		field.grab_focus()
		field.text = invalid
		field.text_changed.emit(invalid)
		field.text_submitted.emit(field.text)
		_check(field.text == "0.125" and model.document.to_dict() == saved and model._undo_stack.size() == history, "非法耐久输入不改有效值或历史 " + invalid)
	field.text = ""
	field.text_changed.emit("")
	field.release_focus()
	await _settle()
	_check(field.text == "0.125" and model.document.to_dict() == saved and model._undo_stack.size() == history, "耐久清空后失焦恢复最近有效值")
	field.grab_focus()
	field.text = "2.75"
	field.text_changed.emit(field.text)
	field.release_focus()
	await _settle()
	_check(field.text == "2.75" and model.get_player_max_health() == 2.75, "耐久合法小数在失焦时提交")
	field.grab_focus()
	field.text = "3.125"
	field.text_changed.emit(field.text)
	editor._write_document(filename)
	var loaded := MapCodec.load_file(filename, editor.registry, false)
	_check(field.has_focus() and loaded.is_ok() and loaded.value.properties.level.player_max_health == 3.125 and not model.is_dirty(), "耐久未失焦时保存提交正确值且建立保存点")
	field.release_focus()
	editor._load_document(filename)
	await _settle()
	_check(field.text == "3.125" and editor._time_limit_field.text == "120" and not model.is_dirty(), "重开文件恢复玩家耐久并保留限时")


## 给原生输入、翻译及容器布局足够帧更新。
func _settle() -> void:
	for index in 3:
		await process_frame


## 只删除本次测试创建的独立目录。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 累计失败并让引擎日志提供具体断言。
func _check(condition: bool, label: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
	return condition
