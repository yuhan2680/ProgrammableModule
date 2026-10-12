extends SceneTree
## 分波状态与地图安全区回归：真实关卡、真实射击和原生布局，不推进暂停的模拟。

const PRESENTATIONS := [
	{"size": Vector2i(1280, 800), "scale": 100},
	{"size": Vector2i(3840, 2160), "scale": 100},
	{"size": Vector2i(3840, 2160), "scale": 150},
	{"size": Vector2i(3840, 2160), "scale": 200},
]
const LOCALES := ["zh_CN", "zh_HK", "en"]
const SOURCE := "main(){shoot(0)}"

var _checks := 0
var _failures := 0
var _finished := false
var _temporary := ""
var _game: GameShell


## 界面动画按真实帧执行；后台模拟由用例独立步进，避免等待布局影响波次。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 覆盖所有现有分波地图，以及不同ID的同类型地图，不将规则绑死在教学关卡名上。
func _run() -> void:
	create_timer(90.0).timeout.connect(_timeout)
	_temporary = "user://tests/wave_status_layout_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()
	for level_id: String in ["level_012", "level_013", "level_014", "level_015"]:
		var level := _find_level(level_id)
		if level != null:
			await _check_level_matrix(level)
	var template := _find_level("level_012")
	if template != null:
		var document := template.document.duplicate_document()
		document.id = "custom_wave_status"
		var result := LevelDefinition.from_document(document, _game.registry, _temporary.path_join("levels/custom_wave_status.json"))
		if _check(result.is_ok(), "不同ID的分波地图仍按真实数据创建关卡"):
			await _set_presentation(PRESENTATIONS[0])
			var workbench := await _enter_program(result.value)
			if workbench != null:
				await _check_languages(workbench, "自定义分波普通")
				await _set_expanded(workbench, true)
				await _check_languages(workbench, "自定义分波全屏")
	await _finish()


## 通过关卡ID找到正式定义，避免目录排序变化让回归误测别的地图。
func _find_level(level_id: String) -> LevelDefinition:
	for level: LevelDefinition in _game.catalog.levels:
		if level.id == level_id:
			_check(level.goal_type == "destroy_waves", "正式关卡保持分波目标：" + level_id)
			return level
	_check(false, "缺少正式分波关卡：" + level_id)
	return null


## 同一世界跨尺寸、缩放、语言和全屏往返，逐项检查可视区域与冻结的运行状态。
func _check_level_matrix(level: LevelDefinition) -> void:
	await _set_presentation(PRESENTATIONS[0])
	var original_map := level.document.to_dict().duplicate(true)
	var workbench := await _enter_program(level)
	if workbench == null:
		return
	var world := workbench.session.world
	var tick := world.tick_index
	var waves := world.get_enemy_wave_status().duplicate(true)
	var modules := workbench.session.assembly.modules.duplicate(true)
	for presentation: Dictionary in PRESENTATIONS:
		await _set_presentation(presentation)
		var context := "%s %s %d%%" % [level.id, presentation.size, presentation.scale]
		await _check_languages(workbench, context + " 普通")
		await _set_expanded(workbench, true)
		await _check_languages(workbench, context + " 全屏")
		await _set_expanded(workbench, false)
		_check(workbench.session.world == world and world.tick_index == tick and world.get_enemy_wave_status() == waves, "布局往返保留同一世界、模拟tick和真实波次：" + context)
		_check(workbench.session.source == SOURCE and workbench.session.assembly.modules == modules, "布局不改代码与实际装配：" + context)
	_check(level.document.to_dict() == original_map, "所有布局检查保留正式地图、敌人及玩法属性：" + level.id)
	_game._back_to_levels()
	await _settle()


## 使用真实空装配入口放置射击模块，正常运行后停在实际冷却状态。
func _enter_program(level: LevelDefinition) -> GameWorkbench:
	_game._enter_level(level)
	_game._dialogue_dialog.hide()
	await _settle()
	if not _check(_game.session.assembly.add_module("shooting", Vector2.ZERO, "gun").is_ok(), "真实装配安装中心射击模块：" + level.id):
		return null
	_game._confirm_assembly()
	await _settle()
	var workbench := _game.workbench
	if not _check(workbench != null and _game.page == GameShell.Page.PLAY, "确认装配进入正式工作台：" + level.id):
		return null
	workbench.set_process(false)
	workbench._code.text = SOURCE
	workbench.header.run_button.pressed.emit()
	if not _check(workbench.session.state == GameSession.State.RUNNING and workbench.session.world != null, "真实程序创建分波世界：" + level.id):
		return null
	for unused in 4:
		if _shooting_cooldown(workbench) > 0:
			break
		workbench.session.step()
	_check(_shooting_cooldown(workbench) > 0, "真实发射产生非零冷却：" + level.id)
	workbench.session.pause()
	await create_timer(0.34).timeout
	return workbench


## 分辨率和字号走同一个Windows设置控制器，屏幕画像只替换只读平台查询。
func _set_presentation(presentation: Dictionary) -> void:
	var dimensions: Vector2i = presentation.size
	_check(_game.settings.set_window_resolution("%dx%d" % [dimensions.x, dimensions.y]).is_ok(), "保存隔离窗口尺寸")
	_check(_game.settings.set_ui_scale(int(presentation.scale)).is_ok(), "保存隔离文字缩放")
	await _settle(8)
	_check(root.size == dimensions and root.get_visible_rect().size.is_equal_approx(Vector2(dimensions)), "实际测试画幅符合声明：%s" % dimensions)
	_check(_game.window_controller.effective_ui_scale == int(presentation.scale), "真实控制器应用所需字号比例")


## 三语切换保留真实当前状态，检查可见文本而不是仅存在于悬停提示的完整原文。
func _check_languages(workbench: GameWorkbench, context: String) -> void:
	for locale: String in LOCALES:
		_game.settings.set_language(locale)
		await _settle(8)
		_check_geometry(workbench, context + " " + locale)
		_check_status(workbench, context + " " + locale)


## 真正点击预览入口并等待原生动画，不能直接篡改expanded状态制造布局通过。
func _set_expanded(workbench: GameWorkbench, expanded: bool) -> void:
	if workbench._preview_layout.expanded == expanded:
		return
	workbench._preview_button.pressed.emit()
	for unused in 360:
		await process_frame
		if not workbench._preview_layout.transitioning:
			await _settle()
			_check(workbench._preview_layout.expanded == expanded, "预览真实动画抵达要求状态")
			return
	_check(false, "分波地图预览动画未完成")


## 检查实际绘图矩形、可见滚动区和顶部浮层；方格比例不能因避让而被拉伸。
func _check_geometry(workbench: GameWorkbench, context: String) -> void:
	var viewport := workbench._world_scroll.get_global_rect()
	var vertical := workbench._world_scroll.get_v_scroll_bar()
	var horizontal := workbench._world_scroll.get_h_scroll_bar()
	if vertical.is_visible_in_tree():
		viewport.size.x -= vertical.size.x
	if horizontal.is_visible_in_tree():
		viewport.size.y -= horizontal.size.y
	var map_rect := workbench._playfield.get_global_rect()
	var document := workbench._playfield.document
	_check(viewport.grow(1.0).encloses(map_rect), "完整地图位于实际可见视口：" + context)
	_check(absf(map_rect.size.x / document.width - map_rect.size.y / document.height) < 0.01, "地图方格等比缩放：" + context)
	var card := workbench._world_panel.get_global_rect()
	for item: Control in [workbench._live_status, workbench._guide_button, workbench._preview_button]:
		var occupied := item.get_global_rect()
		_check(not map_rect.intersects(occupied) and map_rect.position.y >= occupied.end.y + 8.0, "地图与顶部状态/按钮具有可见间隙：%s %s" % [item.name, context])
		_check(card.grow(1.0).encloses(occupied), "顶部状态/按钮留在卡片内：%s %s" % [item.name, context])
	var pill := workbench._live_status
	var label := pill.status_label
	var parsed := label.get_parsed_text()
	var font_size := label.get_theme_font_size("normal_font_size")
	var font := label.get_theme_font("normal_font")
	var text_width := font.get_string_size(parsed, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_check(text_width <= label.size.x + 1.0 and label.get_content_height() <= label.size.y + 1.0, "状态按实际字号完整容纳文字，不依赖隐藏溢出：" + context)
	_check(pill.get_global_rect().end.x <= workbench._guide_button.get_global_rect().position.x + 1.0, "状态药丸没有挤压指引按钮：" + context)


## 进度与冷却直接比较真实世界读数，重复的当前波来袭文字不得保留在可见或悬停文本。
func _check_status(workbench: GameWorkbench, context: String) -> void:
	var pill := workbench._live_status
	var text := pill.status_label.get_parsed_text()
	var tooltip := pill.status_label.tooltip_text
	var status := workbench.session.world.get_enemy_wave_status()
	var progress := workbench.tr("已击毁 %d / %d 波敌人") % [int(status.completed), int(status.total)]
	var cooldown := workbench.tr("射击冷却 %.1f 秒") % (_shooting_cooldown(workbench) * SimulationWorld.TICK_DURATION)
	_check(pill.is_expanded() and pill.is_visible_in_tree(), "运行暂停时状态药丸可见：" + context)
	_check(text.contains(progress) and text.contains(cooldown) and not text.ends_with("…"), "可见状态完整保留真实x/y和射击冷却：%s，实际=%s" % [context, text])
	for arrival: String in ["第 %d 波敌人来袭", "第 %d 波敵人來襲", "Wave %d incoming"]:
		var caption := arrival % int(status.get("current", 1))
		_check(not text.contains(caption) and not tooltip.contains(caption), "重复来袭文案已移除：" + context)
	_check(workbench.session.state == GameSession.State.PAUSED, "本次布局检查维持真实暂停状态：" + context)


## 只读正式射击模块的冷却结束tick，测试不伪造计时或直接写药丸文字。
func _shooting_cooldown(workbench: GameWorkbench) -> int:
	for module: ModuleInstance in workbench.session.world.player.modules:
		if module.available and not module.behavior.get_shoot_profile(module).is_empty():
			return maxi(0, module.next_shoot_tick - workbench.session.world.tick_index - 1)
	return 0


## 等待容器、字号和延迟适配完成，期间不推进已经暂停的游戏时钟。
func _settle(frames: int = 6) -> void:
	for unused in frames:
		await process_frame


## 每条失败保留实际关卡、尺寸、语言及状态，方便定位布局而非只见总体失败。
func _check(condition: bool, context: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
	return condition


## 清理仅限本次独占目录，不触及正式档案、关卡或外部文件。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 正常与超时均释放测试外壳，再输出明确的测试完成标记与退出码。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_cleanup(_temporary)
	print("分波状态布局回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 超时计入失败，不能用引擎帧数耗尽冒充用例成功。
func _timeout() -> void:
	_check(false, "分波状态布局回归超时")
	_finish()
