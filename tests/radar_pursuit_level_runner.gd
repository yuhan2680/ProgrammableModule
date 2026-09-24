extends SceneTree
## 第十关同时验证随机运动的真实边界、复习权限、常变量可选和普通会话生命周期。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _source := ""


## 延后加载全局类，全部验证使用独立内存世界，不读取玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 先检验地图与行为，再以多种种子检查真实命中通关和提示隔离。
func _run() -> void:
	_check(_content.load_directories().is_ok(), "加载正式内容")
	var path := "res://data/levels/level_010.json"
	var map := MapCodec.load_file(path, _content, true)
	if not _check(map.is_ok(), "第十关正式地图可读取"):
		_finish()
		return
	var defined := LevelDefinition.from_document(map.value, _content, path)
	if not _check(defined.is_ok(), "第十关规则可加载"):
		_finish()
		return
	_level = defined.value
	_source = str(JSON.parse_string(FileAccess.get_file_as_string("res://data/hints/level_010.json")).source).replace("{{radar}}", "eyes").replace("{{gun}}", "gun")
	_test_definition()
	_test_validation()
	_test_wander()
	_test_solutions()
	_test_session()
	_test_hints()
	_finish()


## 权限来自关卡数据；仅摧毁目标决定通关，不强制要求使用绑定语法。
func _test_definition() -> void:
	_check(_level.order == 10 and _level.id == "level_010" and _level.display_name == "第十关 · 猎人游戏", "正式编号与顺序补齐第十关")
	_check(_level.module_limit == 3 and _level.allowed_modules == PackedStringArray(["movement", "shooting", "radar"]), "本次复习提供雷达、移动和射击，限制三个模块")
	_check(_level.allow_radar and _level.allow_variables and _level.allow_loops and _level.allow_conditionals and _level.allow_simultaneous and not _level.allow_functions, "雷达和常变量可选开放，函数仍留给十一关")
	_check(_level.goal_type == "destroy_enemy" and _level.max_ticks == 1200 and not _level.document.enemies[0].properties.has("seed"), "目标为击毁随机敌人，正式游玩不固定路线")
	_check(not _level.starter_program.contains("scan") and not _level.starter_program.contains("shoot"), "初始代码不预填答案")
	var session := GameSession.create(_level, _content)
	_check(session.assembly.modules.is_empty(), "进入关卡仍从空装配开始")
	session = _session(0, _source)
	_check(not session.assembly.add_module("movement", Vector2(-0.5, 0), "extra").is_ok(), "第四个模块被真实装配规则拒绝")
	_check(GameI18n.ENGLISH.has(_level.display_name) and GameI18n.ENGLISH.has(_level.description), "标题和介绍都有英文文案")
	for page: Dictionary in _level.document.dialogue:
		_check(GameI18n.ENGLISH.has(page.text), "复习指引各页均可切换英文")


## 无效随机配置在建世界之前拒绝，不执行任意行为或隐式转换布尔类型。
func _test_validation() -> void:
	var entry: Dictionary = _level.document.enemies[0].duplicate(true)
	for pair: Array in [["speed_scale", 0], ["speed_scale", 1.1], ["speed_scale", true], ["speed_scale", NAN], ["turn_min_ticks", 0], ["turn_max_ticks", 601], ["turn_max_ticks", 0.5], ["seed", -1], ["seed", true], ["seed", 2147483648], ["module_health", {"missing": 20}], ["module_health", {"engine": -1}]]:
		var changed := entry.duplicate(true)
		changed.properties[pair[0]] = pair[1]
		_check(not EnemyDefinition.validate(changed, _content).is_ok(), "拒绝无效游走配置：" + str(pair))
	var reversed := entry.duplicate(true)
	reversed.properties.turn_min_ticks = 40
	_check(not EnemyDefinition.validate(reversed, _content).is_ok(), "拒绝倒置的转向时间范围")
	for modules: Variant in [[], [false], [{"id": "engine", "module_id": "radar"}]]:
		var changed := entry.duplicate(true)
		changed.modules = modules
		changed.properties.module_health = {}
		_check(not EnemyDefinition.validate(changed, _content).is_ok(), "缺少真实驱动或非对象模块不会导致脚本异常")
	var unknown := entry.duplicate(true)
	unknown.behavior = "unregistered_script"
	_check(EnemyDefinition.validate(unknown, _content).is_ok(), "未知敌人行为仍作为扩展元数据保留")


## 相同种子可复现，不同种子不同路；扫掠检查覆盖边界、void、实体障碍和损坏后停止。
func _test_wander() -> void:
	var doc := _document(7)
	var original := doc.to_dict()
	var first := _world(doc)
	var second := _world(doc)
	var different := _world(_document(8))
	var headings := {}
	var diverged := false
	var safe := true
	var identical := true
	for unused in 1200:
		var before := first.get_machine("wanderer").position
		first.step()
		second.step()
		different.step()
		var enemy := first.get_machine("wanderer")
		var delta := enemy.position - before
		if delta.length() > 0.001:
			headings[roundi(rad_to_deg(delta.angle()))] = true
		safe = safe and delta.length() <= 0.07501 and MachineFactory.validate_placement(enemy, doc, _content).is_ok()
		identical = identical and enemy.position == second.get_machine("wanderer").position
		diverged = diverged or enemy.position != different.get_machine("wanderer").position
	_check(safe, "每一步遵守真实速度和完整占地，不穿地图边界")
	_check(identical and diverged and headings.size() > 30, "固定种子可重放，不同种子及不定时转向形成不同路线")
	_check(doc.to_dict() == original and first.document.to_dict() == original, "随机运动和实例耐久不改写地图")
	_check(first.player.modules[2].max_health == 1.0, "18 点敌人耐久不污染同种玩家驱动")
	for use_objects in [false, true]:
		var barrier := _document(19)
		for y in range(1, 13):
			if use_objects:
				barrier.objects.append({"id": "wall_%d" % y, "type": "destructible", "position": {"x": 8.5, "y": y + 0.5}, "properties": {"max_health": 1000}})
			else:
				barrier.set_tile(Vector2i(8, y), "")
		var world := _world(barrier)
		var stayed_right := true
		for unused in 1500:
			world.step()
			stayed_right = stayed_right and world.get_machine("wanderer").position.x >= 9.2499
		_check(stayed_right, "随机转向不能穿越整列障碍或 void")
	var enemy := first.get_machine("wanderer")
	enemy.get_module("engine").apply_damage(100)
	var stopped := enemy.position
	for unused in 20:
		first.step()
	_check(enemy.is_destroyed() and enemy.position == stopped, "真实驱动被毁后不再游走")
	var retry := _world(_document(7))
	_check(retry.get_machine("wanderer").get_module("engine").health == 18, "新世界恢复敌人耐久")
	var fresh_a := _world(_level.document)
	var fresh_b := _world(_level.document)
	fresh_a.step()
	fresh_b.step()
	_check(fresh_a.get_machine("wanderer").position != fresh_b.get_machine("wanderer").position, "正式无种子重试创建独立随机路线")


## 跨种子运行不含绑定和含 value/variable 的完整解法，通关必须来自真实弹道与伤害。
func _test_solutions() -> void:
	var with_variables := _source.replace("main() {", "value step = 0.3\nmain() {").replace("    loop {", "    loop {\n        variable target = eyes.scan()").replace("eyes.scan() != null", "target != null").replace("eyes.scan().Angle()", "target.Angle()").replace("eyes.scan().Distance", "target.Distance").replace(", 0.3)", ", step)")
	var slowest := 0
	for sample in 64:
		for source: String in [_source, with_variables]:
			var session := _session(sample, source)
			var before := session.level.document.to_dict()
			var run := session.run()
			if not _check(run.is_ok(), "随机轨迹 %d 的复习程序可以运行" % sample):
				continue
			var start := session.world.player.position
			var traveled := 0.0
			for unused in 1200:
				if session.state != GameSession.State.RUNNING:
					break
				var previous := session.world.player.position
				session.step()
				traveled += previous.distance_to(session.world.player.position)
			slowest = maxi(slowest, session.world.tick_index)
			_check(session.state == GameSession.State.SUCCEEDED and session.world.get_machine("wanderer").is_destroyed(), "两种写法均真实击毁敌人，种子 %d：%s" % [sample, session.message])
			_check(traveled > 1 and start != session.world.player.position and session.level.document.to_dict() == before, "玩家实际追击且试运行未改写地图")
	print("第十关 64 种轨迹 × 2 种写法，最慢通关 %.1f 秒。" % (slowest * 0.1))


## 暂停、重置、超时和重试沿用原会话，失败不能误算通关或清掉作品。
func _test_session() -> void:
	var session := _session(3, _source)
	_check(session.run().is_ok(), "会话正常启动")
	for unused in 12:
		session.step()
	session.pause()
	var before := session.world.get_machine("wanderer").position
	var tick := session.world.tick_index
	for unused in 50:
		session.step()
	_check(session.world.tick_index == tick and session.world.get_machine("wanderer").position == before, "暂停同时冻结随机敌人、时钟和射击")
	session.resume()
	session.step()
	_check(session.world.tick_index == tick + 1, "恢复后继续原时钟")
	var modules := session.assembly.modules.duplicate(true)
	session.reset()
	_check(session.source == _source and session.assembly.modules == modules and session.consecutive_failures == 0, "手动重置保留代码和装配，不计失败")
	session.source = "main(){move(0,0)}"
	_check(session.run().is_ok(), "无射击的等待程序可开始")
	for unused in 1200:
		if session.state != GameSession.State.RUNNING:
			break
		session.step()
	_check(session.state == GameSession.State.FAILED and session.world.tick_index == 1200 and session.message.contains("重新扫描"), "未击毁敌人会限时失败并给出追击反馈")
	_check(session.consecutive_failures == 1, "一次超时只计一次失败")


## 多轨迹提示验证重复调用稳定，且不能推进真实世界或偷偷固定正式敌人路线。
func _test_hints() -> void:
	var session := GameSession.create(_level, _content)
	session.assembly.modules = _session(0, _source).assembly.modules.duplicate(true)
	session.source = _level.starter_program
	var original := _level.document.to_dict()
	var a := CodeHintService.next_hint(session)
	var b := CodeHintService.next_hint(session)
	_check(a.is_ok() and b.is_ok() and a.value == b.value, "随机关卡同一次提示稳定且只添加下一步")
	_check(_level.document.to_dict() == original and session.source == _level.starter_program and session.world == null, "隔离验证不写入正式种子或修改会话")
	session.source = _source
	_check(not CodeHintService.next_hint(session).is_ok(), "已有跨轨迹正确解法不被重复修改")


## 每个测试复制关卡后只设置测试种子，不回写正式资源。
func _document(sample_seed: int) -> MapDocument:
	var doc := _level.document.duplicate_document()
	doc.enemies[0].properties.seed = sample_seed
	return doc


## 使用普通世界入口建立固定种子夹具，失败明确记录并停止依赖步骤。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	_check(result.is_ok(), "创建合法随机世界：" + str(result.errors))
	return result.value


## 按指引手工搭建三模块，不绕过玩家装配约束。
func _session(sample_seed: int, source: String) -> GameSession:
	var defined := LevelDefinition.from_document(_document(sample_seed), _content)
	var session := GameSession.create(defined.value, _content)
	session.assembly.add_module("radar", Vector2.ZERO, "eyes")
	session.assembly.add_module("shooting", Vector2(0.5, 0), "gun")
	session.assembly.add_module("movement", Vector2(0, 0.5), "drive")
	session.source = source
	return session


## 断言保留实际失败原因，统一入口同时检查退出码和日志。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 输出统一回归标记，任何失败都返回非零状态。
func _finish() -> void:
	print("第十关追猎回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
