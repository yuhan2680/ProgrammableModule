extends SceneTree
## 使用真实教学关卡和会话验证随机函数解锁、暂停重试与敌方随机源隔离。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待脚本类可用后开始独立内存验证，不读写玩家存档。
func _initialize() -> void:
	_run.call_deferred()


## 检查逐关权限及真实执行入口，再验证两个不同玩家程序不会扰动敌方随机路线。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "加载正式模块"):
		_finish()
		return
	for number in range(1, 14):
		var path := "res://data/levels/level_%03d.json" % number
		var loaded := MapCodec.load_file(path, _content, true)
		if not _check(loaded.is_ok(), "加载关卡 %d" % number):
			continue
		var defined := LevelDefinition.from_document(loaded.value, _content, path)
		if not _check(defined.is_ok(), "读取关卡权限 %d" % number):
			continue
		var level: LevelDefinition = defined.value
		_check(level.allow_random == (number >= 10), "第十至第十二关显式解锁玩家随机表达式，前九关保持锁定")
		if number == 10:
			_level = level
		# 动作参数直接取随机数，不依赖常变量、雷达或自定义函数。
		var session := GameSession.create(level, _content)
		var module_id: String = "shooting" if number >= 12 else ("movement" if number >= 10 else level.allowed_modules[0])
		_check(session.assembly.add_module(module_id, Vector2.ZERO, "drive").is_ok(), "装配一个已解锁模块")
		session.source = "main() {\n    move(randomInt(0, 359), 0)\n    move(0, random())\n}\n"
		if number >= 12:
			# 第十二关另以射击验证随机参数，不把可选随机工具绑定到移动能力。
			session.source = "main() {\n    shoot(randomInt(0, 359))\n    shoot(random())\n}\n"
		var started := session.run()
		_check(started.is_ok() == (number >= 10), "会话入口按关卡权限允许或拒绝随机调用")
		session.stop()
	if _level != null:
		_test_metadata()
		_test_session()
	_finish()


## 旧地图省略开关时关闭；非法字段在运行前拒绝，未知扩展仍能往返。
func _test_metadata() -> void:
	var legacy := _level.document.duplicate_document()
	legacy.properties.level.erase("allow_random")
	var result := LevelDefinition.from_document(legacy, _content)
	_check(result.is_ok() and not result.value.allow_random, "旧地图不因升级或敌人随机行为隐式解锁")
	for invalid: Variant in [1, "true", null, [], {}]:
		var changed := _level.document.duplicate_document()
		changed.properties.level.allow_random = invalid
		_check(not LevelDefinition.from_document(changed, _content).is_ok(), "随机权限必须是显式布尔值")
	var copy := _level.document.duplicate_document()
	copy.properties.level.custom_extension = {"keep": 17}
	var restored := MapCodec.from_dict(copy.to_dict(), _content, true)
	_check(restored.is_ok(), "新增权限不破坏地图往返")
	if restored.is_ok():
		var defined := LevelDefinition.from_document(restored.value, _content)
		_check(defined.is_ok() and defined.value.allow_random and defined.value.document.properties.level.custom_extension.keep == 17, "权限与未知扩展均保留")
	for page: Dictionary in _level.document.dialogue:
		_check(GameI18n.ENGLISH.has(page.text), "随机教程与现有教程都有英文翻译")
	_check(_level.document.enemies[0].properties.module_health.engine == 18 and not _level.document.enemies[0].properties.has("seed"), "正式耐久和每次独立随机的敌人配置保持不变")


## 按同一逻辑时钟比较不同随机调用数量，暂停与重置沿用真实会话状态机。
func _test_session() -> void:
	var plain := _session(false)
	var drawing := _session(true)
	_check(plain.run().is_ok() and drawing.run().is_ok(), "两个真实会话可启动")
	if plain.runner == null or drawing.runner == null:
		return
	var enemy_equal := true
	for unused in 120:
		plain.step()
		drawing.step()
		enemy_equal = enemy_equal and plain.world.get_machine("wanderer").position == drawing.world.get_machine("wanderer").position
	_check(enemy_equal, "玩家随机调用不会改变同种子的敌人路线")
	drawing.pause()
	var tick_before := drawing.world.tick_index
	var random_state: int = drawing.runner._random.state
	for unused in 5:
		drawing.step()
	_check(drawing.world.tick_index == tick_before and drawing.runner._random.state == random_state, "暂停不会消耗随机数或推进模拟")
	drawing.resume()
	drawing.step()
	_check(drawing.world.tick_index > tick_before and drawing.runner._random.state != random_state, "恢复在原进度继续取随机数")
	var previous_runner := drawing.runner
	var source_before := drawing.source
	var assembly_before := drawing.assembly.modules.duplicate(true)
	drawing.reset()
	_check(drawing.run().is_ok() and drawing.runner != previous_runner, "重试建立独立运行器与随机源")
	_check(drawing.source == source_before and drawing.assembly.modules == assembly_before, "重试保留玩家程序和装配")
	plain.stop()
	drawing.stop()


## 种子只写入测试快照，正式 JSON 与原关卡不变；零距离移动每次仍推进一个 tick。
func _session(use_random: bool) -> GameSession:
	var doc := _level.document.duplicate_document()
	doc.enemies[0].properties.seed = 90217
	var level: LevelDefinition = LevelDefinition.from_document(doc, _content).value
	var session := GameSession.create(level, _content)
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "隔离会话驱动装配有效")
	session.source = "main() {\n    loop {\n        move(0, 0)\n    }\n}\n"
	if use_random:
		session.source = "main() {\n    loop {\n        variable sample = random()\n        move(randomInt(0, 359), 0)\n    }\n}\n"
	return session


## 累计断言并输出实际失败原因，使外层回归能识别脚本和规则问题。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 输出统一完成标记与退出状态。
func _finish() -> void:
	print("随机关卡回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
