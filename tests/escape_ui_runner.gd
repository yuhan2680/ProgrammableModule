extends SceneTree
## 第十六关通过真实选关、说明与装配入口验证三语界面，并独立验证改名模块的逐步提示。

const LEVEL_PATH := "res://data/levels/level_016.json"
const HINT_PATH := "res://data/hints/level_016.json"
const PLAYER_NOTE := "// 我的迷宫笔记：每次只走一格"
const PLAYER_DECLARATION := "constant player_note = 42"

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _level: LevelDefinition


## 使用真实 UI 帧处理翻译与布局，模拟通过有限步数主动推进。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 只创建隔离存档，在正式目录发现新关后依次验证搜索、装配与提示。
func _run() -> void:
	create_timer(45.0).timeout.connect(_timeout)
	_temporary = "user://tests/escape_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	for entry: LevelDefinition in _game.catalog.levels:
		if entry.id == "level_016":
			_level = entry
	if not _check(_level != null, "正式选关目录包含第十六关逃脱"):
		await _finish()
		return
	var original_map := FileAccess.get_file_as_bytes(LEVEL_PATH)
	var original_document := _level.document.to_dict()
	await _test_languages_and_search()
	await _test_assembly_and_preview()
	_test_renamed_hints()
	_check(FileAccess.get_file_as_bytes(LEVEL_PATH) == original_map and _level.document.to_dict() == original_document, "搜索、装配与提示均未修改正式地图或关卡快照")
	await _finish()


## 当前语言的完整标题、说明和每页对话均可翻译，折叠中的第十六关也可直接搜索进入。
func _test_languages_and_search() -> void:
	var cases := [
		{"locale": "zh_CN", "title": "第十六关 · 逃脱", "query": "逃脱"},
		{"locale": "zh_HK", "title": "第十六關 · 逃脫", "query": "逃脫"},
		{"locale": "en", "title": "Level 16 · Escape", "query": "Level 16"},
	]
	for entry: Dictionary in cases:
		_game.settings.set_language(entry.locale)
		_game._show_level_page()
		await _settle()
		_game._level_header.set_search_open(true, false)
		var input := _game.find_child("LevelSearchInput", true, false) as LineEdit
		input.text = entry.query
		input.text_changed.emit(entry.query)
		await _settle()
		_check(_visible_ids() == ["level_016"], "按当前语言搜索只显示逃脱关：" + str(entry.locale))
		var card := _card()
		if not _check(card != null and card.is_visible_in_tree(), "搜索结果提供真实可点击卡片：" + str(entry.locale)):
			continue
		var displayed_titles: Array[String] = []
		for child in card.get_parent().get_children():
			if child is Label:
				displayed_titles.append(str(TranslationServer.translate(child.text)))
		_check(str(entry.title) in displayed_titles, "卡片显示正确的本土化关名：" + str(entry.locale))
		_check(card.tooltip_text.contains(_translated(_level.description, str(entry.locale))), "悬停说明完整使用当前语言：" + str(entry.locale))
		card.pressed.emit()
		await _settle()
		_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level == _level and _game.session.assembly.modules.is_empty(), "点击逃脱卡片进入真实空装配：" + str(entry.locale))
		var displayed_pages := _level.document.dialogue.duplicate(true)
		displayed_pages.append(WorkbenchProgramGuide.page(_level))
		for page: Dictionary in displayed_pages:
			_check(_game._dialogue_dialog.visible, "关卡说明没有漏页：" + str(entry.locale))
			var expected := _translated(str(page.text), str(entry.locale))
			_check(str(TranslationServer.translate(_game._dialogue_dialog.get_label().text)) == expected, "当前可见说明页采用完整翻译：" + str(entry.locale))
			_game._dialogue_dialog.confirmed.emit()
			await _settle()
		_check(not _game._dialogue_dialog.visible, "读完全部说明后直接回到装配：" + str(entry.locale))
	_game.settings.set_language("zh_CN")
	await _settle()


## 两个半格模块安装后通过实际确认按钮进入工作台，整个迷宫与右下终点都在地图视口内。
func _test_assembly_and_preview() -> void:
	var session := _game.session
	_check(session.assembly.modules.is_empty() and session.level.module_limit == 2 and _game._confirm_assembly_button.disabled, "初次进入只允许两个模块且空装配不能确认")
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "从原点安装 sensor 测距模块")
	_check(session.assembly.add_module("movement", Vector2(.5, 0), "drive").is_ok(), "在右侧安装 drive 移动模块")
	var before := session.assembly.modules.duplicate(true)
	_check(not session.assembly.add_module("radar", Vector2(0, .5), "third").is_ok() and session.assembly.modules == before, "第三个模块被数量上限拒绝且原装配保留")
	_check(not _game._confirm_assembly_button.disabled, "合法两模块装配启用正式确认按钮")
	_game._confirm_assembly_button.pressed.emit()
	await _settle()
	var bench := _game.workbench
	if not _check(bench != null, "通过确认按钮进入第十六关编程工作台"):
		return
	bench.set_process(false)
	_check(bench._code.text == _level.starter_program and session.world == null, "初次编程只显示空 main，不自动开始或写入解法")
	_check(WorkbenchProgramGuide.entry_text(_level) == "distance(角度) 测量前方距离，边探路边移动。", "第十六关系统引导讲解测距寻路，不沿用继承权限中的雷达战斗说明")
	var maze_help := "用 variable 记录方向，用 if 和 distance 判断岔路。\n每次前进一格，遇到死路掉头；用 loop 持续探路。\n保持整机通过单格通道；Ctrl+Enter 运行。"
	var visible_help := false
	for child in bench._tabs.get_child(0).get_children():
		if child is Label and child.text == maze_help:
			visible_help = child.is_visible_in_tree()
	_check(not visible_help, "代码底部不再占用常驻教学提示区域")
	var canvas := bench._playfield
	_check(canvas.is_visible_in_tree() and canvas.document.width == 27 and canvas.document.height == 17, "工作台显示真实 27 × 17 地图")
	_check(canvas.level == _level and canvas.level.goal_type == "reach_position" and canvas.level.goal_position == Vector2(25.25, 15.5), "绿色出口标记使用正式关卡的右下目标位置")
	var extent := Vector2(27, 17) * canvas.cell_size
	var viewport := bench._world_scroll.get_global_rect()
	_check(viewport.grow(1).encloses(Rect2(canvas.global_position, extent)), "迷宫整张地图适配可见视口，起终点没有被裁切")
	var exit_pixel := canvas.global_position + _level.goal_position * canvas.cell_size
	_check(viewport.has_point(exit_pixel) and not bench._run_button.disabled, "右下实际目标可见且完整装配可以运行")


## 仅补两个缺失步骤以控制成本，正式提示仍须先真实验证完整方案，并绑定玩家改名后的模块。
func _test_renamed_hints() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(HINT_PATH))
	var solution: String = str(data.source).replace("{{sensor}}", "eyes").replace("{{drive}}", "swim")
	var partial := solution.replace("    variable heading = 0\n", "").replace("        swim.move(heading, 1)\n", "")
	var session := GameSession.create(_level, _game.registry)
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "eyes").is_ok() and session.assembly.add_module("movement", Vector2(.5, 0), "swim").is_ok(), "提示验证使用玩家自定义名称 eyes 与 swim")
	# 从空 main 连点两次，确认初始化和空循环骨架也能正常取得下一步。
	session.source = _level.starter_program
	for index in 2:
		var opening := CodeHintService.next_hint(session)
		if not _check(opening.is_ok(), "从空 main 请求第 %d 次提示不超时：%s" % [index + 1, str(opening.errors)]):
			return
		session.source = str(opening.value.source)
	_check(session.source.contains("variable heading = 0") and session.source.contains("loop") and not session.source.contains(".move("), "前两次提示只加入方向初始化与循环框架")
	session.source = PLAYER_NOTE + "\n" + PLAYER_DECLARATION + "\n" + partial
	var original_modules := session.assembly.modules.duplicate(true)
	for index in 2:
		var original_source := session.source
		var result := CodeHintService.next_hint(session)
		if not _check(result.is_ok(), "第十六关正式提示可补第 %d 个缺失步骤：%s" % [index + 1, str(result.errors)]):
			return
		_check(session.source == original_source and session.world == null and session.state == GameSession.State.EDITING, "提示试算不运行或重写玩家当前会话")
		var next_source: String = result.value.source
		_check(next_source != original_source and next_source.contains(PLAYER_NOTE) and next_source.contains(PLAYER_DECLARATION), "逐步提示保留玩家注释和额外声明")
		_check(next_source.contains("eyes.distance(") and not next_source.contains("{{") and not next_source.contains("sensor.distance("), "提示按实际装配绑定改名测距模块")
		if index == 0:
			_check(next_source.contains("variable heading = 0") and not next_source.contains("swim.move("), "首次只补方向初始化，不一次填入后续动作")
		else:
			_check(next_source.contains("swim.move(heading, 1)"), "第二次补入改名移动模块的一步动作")
		session.source = next_source
	var completed_source := session.source
	if not _check(session.run().is_ok(), "按提示补齐的玩家程序通过真实运行入口：" + session.message):
		return
	for unused in 2400:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.world.player.position.distance_to(_level.goal_position) <= _level.goal_radius + .00001, "改名模块与保留注释的提示方案真实逃出迷宫：" + session.message)
	_check(session.source == completed_source and session.assembly.modules == original_modules, "验证完成后仍保留玩家源码和装配")
	_check(not CodeHintService.next_hint(session).is_ok(), "已通关会话不再追加提示")
	_check(not _game.drafts.is_completed(_level.id), "独立提示试算与通关不会替玩家写入正式进度")


## 翻译应来自正式词典，未收录的新增长说明不能悄悄退回中文。
func _translated(source: String, locale: String) -> String:
	if locale == "en":
		_check(GameI18n.ENGLISH.has(source), "英文词典完整收录第十六关文案")
		return str(GameI18n.ENGLISH.get(source, source))
	if locale == "zh_HK":
		_check(GameI18nHK.MESSAGES.has(source), "繁体词典完整收录第十六关文案")
		return str(GameI18nHK.MESSAGES.get(source, source))
	return source


## 按目录真实 ID 收集可见卡片，避免把导入入口或占位节点算成关卡。
func _visible_ids() -> Array[String]:
	var ids: Array[String] = []
	for index in _game.catalog.levels.size():
		var button := _game.find_child("LevelButton_%d" % index, true, false) as Button
		if button != null and button.is_visible_in_tree():
			ids.append(_game.catalog.levels[index].id)
	return ids


## 通过稳定 ID 查找当前树中的逃脱入口，刷新后不复用旧按钮。
func _card() -> Button:
	for index in _game.catalog.levels.size():
		if _game.catalog.levels[index].id == "level_016":
			return _game.find_child("LevelButton_%d" % index, true, false) as Button
	return null


## 给翻译通知、容器尺寸与弹窗信号留出有限真实帧。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 清理严格属于本脚本的独占存档目录，不跟随符号链接。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for folder in directory.get_directories():
		if directory.is_link(folder):
			directory.remove(folder)
		else:
			_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)


## 正常结束先释放 UI 再清理测试目录，最终标记与退出码反映真实失败数。
func _finish() -> void:
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_cleanup(_temporary)
	print("第十六关界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 防止界面异常等待被误当作回归通过。
func _timeout() -> void:
	push_error("第十六关界面回归超时。")
	quit(1)


## 累计独立行为断言并保留失败上下文。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("失败：" + message)
	return condition
