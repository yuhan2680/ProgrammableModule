extends SceneTree
## 第十一关使用正式装配与会话入口验证指引、语言和全尺寸状态；仅写独立测试存档。

var _checks := 0
var _failures := 0
var _temporary := ""


## 保持真实 UI 帧并统一超时，模拟逻辑由测试主动推进。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 从空装配进入函数教学工作台，确认继承常变量且玩家雷达已开放。
func _run() -> void:
	create_timer(18.0).timeout.connect(_timeout)
	_temporary = "user://tests/functions_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	game.settings.set_language("zh_CN")
	var level: LevelDefinition = null
	for entry: LevelDefinition in game.catalog.levels:
		if entry.id == "level_011":
			level = entry
	_check(game.catalog.levels[9].id == "level_010", "目录包含真实第十关并排在十一关之前")
	if not _check(level != null, "真实目录发现第十一关"):
		game.queue_free()
		await _settle()
		_finish()
		return
	_check(level.display_name == "第十一关 · 巧能躲避", "选关名称使用用户指定本土化")
	_check("radar" in level.allowed_modules and level.allow_radar, "玩家雷达及扫描在第十一关完整解锁")
	_check(level.allow_functions and level.allow_variables, "真实关卡明确解锁函数与继承的常变量")
	for page: Dictionary in level.document.dialogue:
		_check(GameI18n.ENGLISH.has(page.text), "每页函数教学都有英文翻译")
	game._enter_level(level)
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.modules.is_empty(), "函数教学仍从空装配开始")
	var radar_button := game.find_child("Module_radar", true, false) as Button
	_check(radar_button != null and not radar_button.disabled, "正式装配目录雷达按钮可点击，不再灰显锁定")
	_check(game.session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "安装中心测距模块")
	_check(game.session.assembly.add_module("movement", Vector2(0.5, 0), "drive").is_ok(), "安装右侧移动模块")
	game._confirm_assembly()
	await _settle()
	var workbench := game.workbench
	if not _check(workbench != null, "确认装配后进入函数工作台"):
		game.queue_free()
		await _settle()
		_finish()
		return
	workbench.set_process(false)
	var highlighter := workbench._code.syntax_highlighter as CodeHighlighter
	_check(highlighter != null and highlighter.has_keyword_color("function"), "function 使用统一语法高亮")
	_check(highlighter != null and highlighter.has_keyword_color("constant") and highlighter.has_keyword_color("variable") and highlighter.has_keyword_color("value"), "常量、变量与旧别名使用统一语法高亮")
	_check(workbench._entry_hint.text.contains("function"), "编辑区提示以函数教学为主")
	_check(workbench._goal_text().contains("躲过"), "指引目标为闪避而非击毁敌人或抵达终点")
	_check(workbench._object_status.text == "已躲过 0 / 5 次攻击 · 等待开始", "未运行时显示零次闪避及准备状态")
	_check(not workbench._live_status.is_expanded(), "未运行时不自动弹出状态药丸")
	workbench._code.text = "constant waiting=0\nvariable idle=waiting\nmain(){\nloop{\nidle=waiting\nmove(0,idle)\n}\n}\nfunction dodge(){constant step=1\nmove(90,step)}"
	workbench._run_program()
	if not _check(game.session.state == GameSession.State.RUNNING and game.session.world != null, "含常变量与函数局部的程序通过正式运行入口"):
		game.queue_free()
		await _settle()
		_finish()
		return
	_check(workbench._live_status.is_expanded(), "运行时显示同一敌人状态药丸")
	var status: Dictionary = game.session.world.get_enemy_attack_status(level.goal_enemy_id)
	_check(status.get("dodged", -1) == 0, "初始状态来自真实世界零次闪避")
	game.session.pause()
	var paused_status := workbench._object_status.text
	game.session.step()
	_check(workbench._object_status.text == paused_status, "暂停时状态文字与真实模拟一同冻结")
	game.settings.set_language("en")
	await _settle()
	_check(workbench._object_status.text.begins_with("Dodged 0 / 5 attacks"), "运行状态在语言切换后即时显示英文")
	game.settings.set_language("zh_CN")
	await _settle()
	game.session.resume()
	var phases := {}
	for unused in 900:
		if game.session.state != GameSession.State.RUNNING:
			break
		game.session.step()
		status = game.session.world.get_enemy_attack_status(level.goal_enemy_id)
		phases[str(status.get("phase", ""))] = true
	_check(phases.has("approach"), "真实敌人接近阶段在工作台持续刷新")
	_check(game.session.state == GameSession.State.FAILED, "不闪避的真实程序会被突袭命中")
	_check(game.session.message == "被敌人的突袭击中，本次运行失败。", "失败消息使用本关突袭反馈")
	workbench._preview_button.pressed.emit()
	await _settle()
	_check(workbench._live_status.is_expanded(), "全尺寸立即使用同一药丸显示本次失败")
	_check(workbench._live_status.status_label.tooltip_text == game.session.message or workbench._live_status.status_label.get_parsed_text() == game.session.message, "失败药丸保留完整本关结果文本")
	game.session.reset()
	_check(workbench._object_status.text == "已躲过 0 / 5 次攻击 · 等待开始", "重置后闪避与敌人阶段重新准备")
	_check(not workbench._live_status.is_expanded(), "全尺寸重置同时收回结果药丸")
	game.queue_free()
	await _settle()
	_finish()


## 留给布局、翻译通知与节点释放完整的 UI 帧。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 输出统一测试汇总，便于标准测试入口捕获失败。
func _finish() -> void:
	_cleanup(_temporary)
	print("函数教学界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 异常等待必须终止当前测试，不影响玩家设置与草稿。
func _timeout() -> void:
	push_error("函数教学界面回归超时。")
	quit(1)


## 清理当前测试独占目录，不跟随符号链接。
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


## 累计真实观察结果并保留可定位的失败描述。
func _check(condition: bool, description: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("失败：" + description)
	return condition
