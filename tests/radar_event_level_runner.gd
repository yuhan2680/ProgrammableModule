extends SceneTree
## 第十五关：真实通道推进、栅栏射击与十波结算，不通过代扣血验证通关。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _source := ""

## 类注册完成后运行独立数据会话，不触碰玩家存档。
func _initialize() -> void:
	_run.call_deferred()

## 覆盖关卡流程、旧遮挡默认值、非法输入和代码提示。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "注册表加载")
	var loaded := MapCodec.load_file("res://data/levels/level_015.json", _content, true)
	if not _check(loaded.is_ok(), "地图合法：" + str(loaded.errors)):
		_finish()
		return
	var definition := LevelDefinition.from_document(loaded.value, _content, "res://data/levels/level_015.json")
	if not _check(definition.is_ok(), "关卡定义合法"):
		_finish()
		return
	_level = definition.value
	var hint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_015.json"))
	_source = hint.source.replace("{{radar}}", "radar").replace("{{gun}}", "gun").replace("{{drive}}", "drive")
	_test_definition()
	_test_battle()
	_test_pause_reset_and_wrong_program()
	_test_validation()
	_test_hint()
	await _test_ui()
	_finish()

## 地图比例、十条侧道和权限由正式数据核对，不硬编码到模拟。
func _test_definition() -> void:
	_check(_level.order == 15 and _level.module_limit == 3 and _level.goal_type == "destroy_waves", "用户确认的三模块十波目标")
	_check(_level.allow_radar and _level.allow_random and _level.allow_for and _level.allow_simultaneous and _level.allow_functions, "继承前关能力")
	_check(_level.document.enemies.size() == 10 and _level.document.width == 18 and _level.document.height == 35, "纵向鱼骨地图与十波")
	for y in range(1, 34):
		var main_width := 0
		for x in range(7, 11):
			if TerrainCollision.is_cell_passable(Vector2i(x, y), _level.document, _content):
				main_width += 1
		_check(main_width == 4, "主路连续四格宽")
		_check(not TerrainCollision.is_cell_passable(Vector2i(6, y), _level.document, _content) and not TerrainCollision.is_cell_passable(Vector2i(11, y), _level.document, _content), "两侧墙或栅栏不计入四格可通行范围")
	var bars := 0
	for cell in _level.document.cells:
		if _level.document.get_tile_id(cell) == "iron_bars":
			bars += 1
	_check(bars == 10, "左右各五条支道有独立栅栏")
	for entry in _level.document.enemies:
		_check(entry.properties.module_health == {"blade": 2.8, "engine": 2.8} and entry.properties.wreck_fade_seconds == 3.0, "每个敌人两模块耐久2.8和残骸淡出")
	var parsed := ProgramParser.new().parse(_level.starter_program, _level.allowed_calls, _level.allow_tick, _level.allow_named_calls, _level.allow_loops, _level.allow_conditionals, _level.allow_simultaneous, _level.allow_distance, _level.allow_functions, _level.allow_variables, _level.allow_radar, _level.allow_random, _level.allow_for, _level.allow_radar_events)
	_check(parsed.is_ok() and not _level.starter_program.contains("shoot"), "初始程序保留空框架")

## 每次重新建立空装配，并通过公开装配接口安装三种模块。
func _session() -> GameSession:
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "进入关卡不预装")
	_check(session.assembly.add_module("radar", Vector2.ZERO, "radar").is_ok(), "雷达居中")
	_check(session.assembly.add_module("shooting", Vector2(.5, 0), "gun").is_ok(), "右侧射击")
	_check(session.assembly.add_module("movement", Vector2(-.5, 0), "drive").is_ok(), "左侧移动")
	_check(not session.assembly.add_module("movement", Vector2(0, .5), "extra").is_ok(), "不能安装第四个模块")
	session.source = _source
	return session

## 只靠正式移动和弹丸完成十波，同时验证待生敌人不可探测、受损整机不算清波。
func _test_battle() -> void:
	var session := _session()
	var original := _level.document.to_dict()
	if not _check(session.run().is_ok(), "真实程序开始"):
		return
	_check(session.world.get_enemy_wave_status().pending == 10 and session.world.machines.size() == 1, "进入触发区域之前十波均待生")
	_check(session.world.query_scan("player", "radar").value == null, "雷达不扫描待生敌人")
	var seen := {}
	var partial := false
	for unused in 2400:
		var status := session.world.get_enemy_wave_status()
		if status.active:
			var enemy := session.world.get_machine(status.active_enemy_id)
			if not seen.has(enemy.id):
				seen[enemy.id] = true
				_check(enemy.modules.all(func(m: ModuleInstance) -> bool: return is_equal_approx(m.max_health, 2.8)), "运行实例耐久为2.8")
				_check(session.world.player.position.y <= enemy.position.y + .01, "推进到支道才激活")
			if enemy.modules.any(func(m: ModuleInstance) -> bool: return not m.available):
				partial = true
				_check(not enemy.is_destroyed() and status.completed == seen.size() - 1, "只毁一个部件不清波")
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "正式雷达程序通关：" + session.message)
	_check(seen.size() == 10 and partial and session.world.get_enemy_wave_status().all_cleared, "所有波次实际出场并击毁")
	_check(session.world.player.position.y < 6 and session.world.player.position.y > 4 and is_equal_approx(session.world.player.position.x, 9), "必须沿主通道真实推进至末组支道")
	_check(session.world.player.modules.all(func(m: ModuleInstance) -> bool: return m.available), "推荐布局正常存活")
	for machine in session.world.machines:
		if machine.id == "player":
			continue
		_check(machine.position.x < 6 or machine.position.x > 11, "敌人不能穿过栅栏")
	_check(_level.document.to_dict() == original, "运行不改写地图")
	session.stop()

## 暂停冻结位置与触发进度；重试清空波次；原地射击无法自动完成关卡。
func _test_pause_reset_and_wrong_program() -> void:
	var session := _session()
	_check(session.run().is_ok(), "暂停流程启动")
	for unused in 40:
		session.step()
	var snapshot := session.world.get_enemy_wave_status()
	var position := session.world.player.position
	session.pause()
	for unused in 20:
		session.step()
	_check(session.world.tick_index == 40 and session.world.player.position == position and session.world.get_enemy_wave_status() == snapshot, "暂停不移动或触发新波次")
	session.resume()
	session.step()
	_check(session.world.tick_index == 41, "恢复同一世界")
	session.reset()
	_check(session.source == _source and session.assembly.modules.size() == 3 and session.run().is_ok(), "重试保留装配和程序")
	_check(session.world.get_enemy_wave_status().pending == 10 and session.world.tick_index == 0, "重试恢复所有待生波次")
	session.stop()
	session.source = "main() { loop { gun.shoot(0) } }"
	_check(session.run().is_ok(), "原地射击对照运行")
	for unused in 2401:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.FAILED and session.world.get_enemy_wave_status().completed == 0 and session.message.contains("推进"), "不前进不会生成或自动清除敌人")
	session.stop()

## 独立权限默认关闭，错误配置拒绝，所有旧教学关卡保持事件锁定。
func _test_validation() -> void:
	_check(_level.allow_radar_events, "第十五关解锁雷达事件")
	_check(_source.contains(".onDetected") and not _source.contains(".scan()"), "参考解法只用事件自动更新目标")
	for number in range(1, 15):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		var old: LevelDefinition = LevelDefinition.from_document(loaded.value, _content).value
		_check(not old.allow_radar_events, "前十四关不提前开放事件")
		var old_session := GameSession.create(old, _content)
		old_session.source = _source
		var parsed := old_session.run()
		_check(not parsed.is_ok(), "旧关卡真实运行入口拒绝雷达事件")
	for value in [null, 0, 1, "true", [], {}]:
		var doc := _level.document.duplicate_document()
		doc.properties.level.allow_radar_events = value
		_check(not LevelDefinition.from_document(doc, _content).is_ok(), "非法事件权限拒绝")
	var doc := _level.document.duplicate_document()
	doc.properties.level.erase("allow_radar_events")
	_check(not LevelDefinition.from_document(doc, _content).value.allow_radar_events, "缺省事件权限关闭")

## 提示使用真实三模块方案，只在正式教学来源生效。
func _test_hint() -> void:
	var session := _session()
	session.source = _level.starter_program
	for unused in 16:
		var result := CodeHintService.next_hint(session)
		if not result.is_ok():
			_check(result.errors[0].contains("已经能够完成"), "提示逐步补齐：" + str(result.errors))
			break
		session.source = result.value.source
	_check(session.source.contains("move(90, 0.1)") and session.source.contains("shoot(target.Angle())"), "包含扫描射击和短步推进")
	_check(session.run().is_ok(), "提示实际可运行")
	for unused in 2400:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.SUCCEEDED, "提示实际完成所有波次")
	session.stop()
	var imported := LevelDefinition.from_document(_level.document, _content, "user://levels/level_015.json")
	_check(not CodeHintService.next_hint(GameSession.create(imported.value, _content)).is_ok(), "导入同名关卡不开放教学提示")

## 通过真实选关与装配入口核对事件教学、双语状态及高分辨率工作台。
func _test_ui() -> void:
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	var directory := "user://tests/radar_event_ui_%d" % Time.get_ticks_usec()
	game.user_levels_directory = directory.path_join("levels")
	game.drafts_directory = directory.path_join("drafts")
	game.settings_path = directory.path_join("settings.json")
	root.add_child(game)
	await process_frame
	game.settings.set_code_hints("more")
	game.settings.set_code_color_mode("dark")
	game.settings.set_language("zh_CN")
	game._enter_level(game.catalog.levels[14])
	await process_frame
	_check(game.session.level.id == "level_015" and game.session.assembly.modules.is_empty(), "选关进入第十五关空装配")
	game._dialogue_dialog.hide()
	game.session.assembly.add_module("radar", Vector2.ZERO, "eyes")
	game.session.assembly.add_module("shooting", Vector2(.5,0), "gun")
	game.session.assembly.add_module("movement", Vector2(-.5,0), "drive")
	game._confirm_assembly()
	await process_frame
	var bench := game.workbench
	if not _check(bench != null, "三模块进入编程工作台"):
		game.queue_free()
		return
	bench.set_process(false)
	_check(bench._hint_button.visible and bench._code.get_theme_stylebox("normal").bg_color == Color("121314"), "保留正式教学提示与深色代码区")
	_check(bench._entry_hint.text.contains("onDetected") and bench._goal_text().contains("雷达事件"), "页头和目标明确事件主题")
	game.settings.set_language("en")
	await process_frame
	_check(game.tr(game.session.level.display_name) == "Level 15 · Automatic Targeting", "关卡名字本土化")
	for page: Dictionary in game.session.level.document.dialogue:
		_check(game.tr(page.text) != page.text, "教程每页都有英语翻译")
	game.settings.set_language("zh_CN")
	bench._code.text = _source.replace("radar.", "eyes.")
	bench._run_button.pressed.emit()
	for unused in 42:
		game.session.step()
	_check(game.session.state == GameSession.State.RUNNING and game.session.world.get_enemy_wave_status().spawned == 1, "实际界面事件程序激活并攻击首波")
	_check(not bench._object_status.text.contains("下一波将在") and bench._object_status.text.contains("/ 10"), "药丸只显示十波进度和射击状态")
	game.session.pause()
	var snapshot: Variant = game.session.runner._globals.resolve("target").value
	var tick := game.session.world.tick_index
	for unused in 4:
		game.session.step()
	_check(game.session.world.tick_index == tick and game.session.runner._globals.resolve("target").value == snapshot, "暂停同时冻结事件目标与世界")
	bench.header.reset_button.pressed.emit()
	_check(game.session.world == null and game.session.source.contains("eyes.onDetected") and game.session.assembly.modules.size() == 3, "重置保留事件代码与装配，清空旧运行")
	game.queue_free()
	await process_frame

## 统一累计失败，保留可定位原因。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition

## 使用与统一测试入口一致的完成标记。
func _finish() -> void:
	print("第十五关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
