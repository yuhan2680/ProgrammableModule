extends SceneTree
## 玩家地图自动提示使用新构造几何与真实会话回归，不读取或改写用户档案。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()


## 在全局类注册完成后运行独立服务检查。
func _initialize() -> void:
	_run.call_deferred()


## 验证自动绕障、攻击、权限、范围上限以及真实会话隔离。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "加载模块目录")
	_test_route_and_isolation()
	_test_command_policy()
	_test_combat()
	_test_scope_and_limits()
	_test_large_map_budget()
	print("玩家地图自动提示回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 不含作者答案的新地图沿真实障碍绕行；已写注释与失败世界保持不变。
func _test_route_and_isolation() -> void:
	var session := _route_session()
	if session == null:
		return
	session.source = "// 我的路线\nmain() {\n    move(0, 20)\n}\n"
	session.run()
	for unused in 400:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	var before := _snapshot(session)
	var first := CodeHintService.next_hint(session)
	_check(first.is_ok(), "非教学地图可以根据几何自动推导下一步")
	_check(before == _snapshot(session), "推导不改写失败世界、装配、源码、计数或地图")
	session.stop()
	session.source = "// 我的路线\nmain() {\n}\n"
	_check(_complete(session), "通过逐步自动提示绕开 void 到达实际终点")
	_check(session.source.contains("// 我的路线"), "自动提示保留玩家注释")
	var original := session.source
	_check(not CodeHintService.next_hint(session).is_ok() and session.source == original, "已有正确路线不重复插入提示")
	# 同名导入地图不能被 _wins 的教学优化误判为必须攻击。
	session.level.id = "level_013"
	_check(CodeHintService._wins(session, original, 2400, Time.get_ticks_usec() + 3000000), "自动规划不依赖碰巧重名的教学 ID")


## 仅开放具名移动时规划真实驱动调用，全部禁用移动时不绕过解析权限。
func _test_command_policy() -> void:
	var session := _route_session()
	if session == null:
		return
	session.level.has_command_policy = true
	session.level.enabled_commands = PackedStringArray(["main", "named_calls", "named_move"])
	session.level.allow_named_calls = true
	_check(_complete(session) and session.source.contains("drive.move("), "仅具名移动开放时自动路线绑定真实驱动")
	session.source = "main() {}"
	session.level.enabled_commands = PackedStringArray(["main"])
	_check(not CodeHintService.next_hint(session).is_ok(), "指令策略禁止移动后不会返回越权路线")


## 改变来源和敌人位置后仍根据现场推导攻击，不读取原教学参考程序。
func _test_combat() -> void:
	var loaded := MapCodec.load_file("res://data/levels/level_004.json", _content, true)
	if not _check(loaded.is_ok(), "加载攻击测试的底层地形与敌人"):
		return
	var document: MapDocument = loaded.value
	document.id = "custom_directional_battle"
	document.properties.level.allow_code_hints = true
	document.properties.level.starter_program = "main() {}\n"
	document.dialogue.clear()
	var level := LevelDefinition.from_document(document, _content, "user://levels/custom_directional_battle.json")
	if not _check(level.is_ok(), "独立玩家战斗地图可运行"):
		return
	var session := GameSession.create(level.value, _content)
	session.assembly.add_module("shooting", Vector2.ZERO, "my_cannon")
	_check(_complete(session), "自定义敌人关卡的自动射击方案实际通关")
	_check(session.source.contains("shoot("), "自动方案使用真实装配中的射击能力")
	# 带雷达的随机移动场景仍复用隔离随机样本验证。
	loaded = MapCodec.load_file("res://data/levels/level_010.json", _content, true)
	document = loaded.value
	document.id = "custom_radar_battle"
	document.properties.level.allow_code_hints = true
	document.properties.level.starter_program = "main() {}\n"
	level = LevelDefinition.from_document(document, _content, "user://levels/custom_radar_battle.json")
	if not _check(level.is_ok(), "随机敌人的玩家地图可运行"):
		return
	session = GameSession.create(level.value, _content)
	session.assembly.add_module("radar", Vector2.ZERO, "my_eyes")
	session.assembly.add_module("shooting", Vector2(0.5, 0), "my_cannon")
	session.assembly.add_module("movement", Vector2(0, 0.5), "my_drive")
	var plan := CustomCodeHintPlanner.find_source(session, Time.get_ticks_usec() + 3000000)
	_check(plan.is_ok(), "动态敌人地图可自动推导实际雷达跟踪方案")
	if plan.is_ok():
		_check(str(plan.value).contains("my_eyes.scan()") and str(plan.value).contains("my_cannon.shoot("), "雷达和射击使用玩家真实模块名")
		_check(CodeHintService._wins(session, plan.value, 2400, Time.get_ticks_usec() + 3000000), "自动雷达方案通过独立随机样本验证")


## 关闭权限、空来源试玩及装配无法通过的地图均不插入虚假或借来的答案。
func _test_scope_and_limits() -> void:
	var session := _route_session()
	if session == null:
		return
	session.level.allow_code_hints = false
	_check(not CodeHintService.next_hint(session).is_ok(), "自定义地图未允许时拒绝提示")
	session.level.allow_code_hints = true
	session.level.source_path = ""
	_check(not CodeHintService.next_hint(session).is_ok(), "未保存编辑器试玩即使开关开启也不获得提示")
	session.level.source_path = "user://levels/custom_route.json"
	var before := _snapshot(session)
	var started := Time.get_ticks_usec()
	var expired := CustomCodeHintPlanner.find_source(session, started - 1)
	_check(not expired.is_ok() and Time.get_ticks_usec() - started < 300000, "过期预算立即退出有限搜索")
	_check(_snapshot(session) == before, "预算耗尽不改变玩家会话")
	session.level.allowed_modules.append("melee")
	session.assembly.modules.clear()
	session.assembly.add_module("melee", Vector2.ZERO, "blade")
	_check(not CodeHintService.next_hint(session).is_ok(), "没有移动能力时不会编造可通关路线")
	# 双模块偏移太宽无法经过单格通道，几何搜索和实际验证都不缩小占地。
	session = _route_session()
	session.level.allowed_modules.append("movement")
	session.level.module_limit = 3
	_check(session.assembly.add_module("movement", Vector2(0, 0.5), "wide_drive").is_ok(), "增加第二块真实移动模块")
	_check(session.assembly.add_module("movement", Vector2(0, 1), "tall_drive").is_ok(), "增加第三块真实移动模块")
	var planned := CustomCodeHintPlanner.find_source(session, Time.get_ticks_usec() + 3000000)
	_check(not planned.is_ok(), "三块模块纵向占地大于单格缺口时拒绝路线，不缩小碰撞范围")


## 合法但超出提示搜索规模的大敌人列表在建立模拟前退出，不产生无界候选组合。
func _test_large_map_budget() -> void:
	var session := _route_session()
	if session == null:
		return
	var document := session.level.document.duplicate_document()
	for index in 300:
		document.enemies.append({"id": "large_enemy_%d" % index, "position": {"x": 6.5, "y": 1.5},
			"modules": [{"id": "enemy_drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}],
			"behavior": EnemyDefinition.ALARM_GUARD, "properties": {}})
	var defined := LevelDefinition.from_document(document, _content, "user://levels/large_hint_map.json")
	if not _check(defined.is_ok(), "超出搜索规模的大敌人地图仍属于合法地图"):
		return
	session = GameSession.create(defined.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	var started := Time.get_ticks_usec()
	var result := CustomCodeHintPlanner.find_source(session, started + 3000000)
	_check(not result.is_ok() and Time.get_ticks_usec() - started < 300000, "大敌人列表在300毫秒内安全拒绝，不做无界候选展开")


## 构造具有完整隔墙缺口的新玩家地图，程序中不携带任何答案。
func _route_session() -> GameSession:
	var tiles: Array = []
	for y in range(1, 7):
		for x in range(1, 8):
			if x == 4 and y >= 2:
				continue
			tiles.append({"x": x, "y": y, "tile_id": "floor"})
	var raw := {"format_version": 1, "id": "custom_route", "name": "自动路线", "width": 9, "height": 8, "tiles": tiles,
		"player_spawn": {"position": {"x": 1.5, "y": 5.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]},
		"enemies": [], "objects": [], "dialogue": [], "properties": {"level": {"allow_code_hints": true, "module_limit": 2,
			"allowed_modules": ["movement", "melee"], "goal": {"position": {"x": 7.5, "y": 5.5}}, "starter_program": "main() {}\n"}}}
	var decoded := MapCodec.from_dict(raw, _content, true)
	if not _check(decoded.is_ok(), "新构造的路线地图格式有效"):
		return null
	var defined := LevelDefinition.from_document(decoded.value, _content, "user://levels/custom_route.json")
	if not _check(defined.is_ok(), "新构造的路线目标有效"):
		return null
	var session := GameSession.create(defined.value, _content)
	session.assembly.add_module("movement", Vector2.ZERO, "drive")
	return session


## 多次主动提示后独立验证真实目标，服务返回说明时必须已存在正确程序。
func _complete(session: GameSession) -> bool:
	for unused in 40:
		var hint := CodeHintService.next_hint(session)
		if not hint.is_ok():
			return CodeHintService._wins(session, session.source, 2400, Time.get_ticks_usec() + 3000000)
		session.source = hint.value.source
	return false


## 深拷贝所有可变输入并保留真实运行对象身份，以检查隔离边界。
func _snapshot(session: GameSession) -> Dictionary:
	return {"source": session.source, "modules": session.assembly.modules.duplicate(true), "document": session.level.document.to_dict(),
		"state": session.state, "world": session.world, "runner": session.runner, "message": session.message, "failures": session.consecutive_failures,
		"tick": session.world.tick_index if session.world != null else -1, "position": session.world.player.position if session.world != null else Vector2.ZERO}


## 汇总具名断言，失败记录进入引擎日志和退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
