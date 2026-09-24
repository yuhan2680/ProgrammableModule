extends SceneTree
## 第五关底层回归：警报顺序、统一伤害、安全门和命名模块的真实能力与冷却。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()


## 等待初始化结束后运行，测试不访问玩家草稿和存档。
func _initialize() -> void:
	_run.call_deferred()


## 使用独立世界夹具检查可观察结果，避免依赖具体内部字典组织。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "内容加载成功"):
		quit(1)
		return
	_test_order_and_gates()
	_test_atomic_alarm()
	_test_named_actions()
	_test_tick_cooldowns()
	_test_security_validation()
	print("监狱底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 守卫先等待；只摧毁一项不能解锁出口，正确顺序完成后才可通过门。
func _test_order_and_gates() -> void:
	var world := _world(_document())
	if world == null:
		return
	for unused in 10:
		world.step()
	_check(world.get_machine("guard").position == Vector2(3.5, 4.5), "警报之前守卫静止")
	_check(not world.player.is_destroyed() and world.failure_reason.is_empty(), "守卫不在警报之前主动攻击")
	_check(not world.get_object("exit").unlocked and world.get_object("exit").is_blocking(world.tick_index), "出口初始锁定")
	_check(world.request_move("player", 90, 3, "drive").is_ok(), "允许尝试经过锁定出口")
	for unused in 30:
		world.step()
	_check(world.player.position.y > 3.0, "锁定门阻止真实移动路径")
	world = _world(_document())
	world.request_attack("player", 180, "left")
	world.step()
	_check(world.get_machine("guard").is_destroyed(), "命名左侧近战消灭守卫")
	_check(world.get_object("alarm").health == 1.0 and not world.get_object("exit").unlocked, "仅消灭守卫不会摧毁警报或打开门")
	world.request_attack("player", 0, "right")
	world.step()
	_check(world.get_object("alarm").health == 0.0 and not world.get_object("alarm").triggered, "守卫已毁时拆除警报不会执行处决")
	_check(world.get_object("exit").unlocked and not world.get_object("exit").is_blocking(world.tick_index), "全部依赖完成后门解锁")
	world.request_move("player", 90, 3, "drive")
	for unused in 30:
		world.step()
	_check(world.player.position.is_equal_approx(Vector2(5.5, 1.5)) and not world.player.is_destroyed(), "门打开后整台装配可向上通过")
	var retry := _world(_document())
	_check(retry.get_object("alarm").health == 1.0 and not retry.get_object("alarm").triggered and not retry.get_object("exit").unlocked, "新世界恢复警报耐久、触发状态和锁定出口")


## 警报处决在同 tick 全部伤害之后，既禁止下一帧补救，也允许真正同时消灭两个目标。
func _test_atomic_alarm() -> void:
	var world := _world(_document())
	world.request_attack("player", 0, "right")
	world.step()
	_check(world.get_object("alarm").triggered, "先拆除警报立即触发")
	_check(world.player.is_destroyed() and world.failure_reason.contains("警报"), "警报触发当帧摧毁全部玩家模块并保留明确失败原因")
	_check(not world.get_machine("guard").is_destroyed() and not world.get_object("exit").unlocked, "处决并不会伪造守卫死亡或解锁")
	_check(not world.request_attack("player", 180, "left").is_ok(), "处决之后没有下一帧攻击守卫的漏洞")
	world = _world(_document())
	world.request_tick_action("player", "attack", 180, "left")
	world.request_tick_action("player", "attack", 0, "right")
	world.step()
	_check(world.get_machine("guard").is_destroyed() and world.get_object("alarm").health == 0.0, "两个命名近战可在同 tick 向不同方向命中")
	_check(not world.player.is_destroyed() and not world.get_object("alarm").triggered and world.get_object("exit").unlocked, "同 tick 同时摧毁守卫与警报有效，不受提交顺序影响")
	world = _world(_document())
	world.request_tick_action("player", "attack", 0, "right")
	world.request_tick_action("player", "attack", 180, "left")
	world.step()
	_check(not world.player.is_destroyed() and world.get_object("exit").unlocked, "颠倒两个独立模块的提交顺序不改变同时解锁结果")
	var document := _document()
	document.player_spawn.modules[1].module_id = "shooting"
	document.player_spawn.modules[2].module_id = "shooting"
	world = _world(document)
	world.request_tick_action("player", "shoot", 180, "left")
	world.request_tick_action("player", "shoot", 0, "right")
	for unused in 2:
		world.step()
	_check(world.get_machine("guard").is_destroyed() and world.get_object("alarm").health == 0.0, "弹丸伤害同样参与守卫和警报统一提交")
	_check(not world.player.is_destroyed() and world.get_object("exit").unlocked, "双向射击同时命中也可安全解锁")


## 命名选择只改变驱动来源或武器来源，不能退回广播、借用其他模块能力或改变实体占地。
func _test_named_actions() -> void:
	var document := _document()
	document.enemies = []
	document.objects = []
	document.player_spawn.modules = [_module("drive", "movement", 0), _module("second", "movement", 0.5), _module("blade", "melee", -0.5)]
	var world := _world(document)
	_check(world.player.get_move_speed() == 2.0 and world.player.get_move_speed("drive") == 1.0, "广播移动速度相加，命名移动只使用所选驱动")
	_check(world.player.get_move_speed("absent") == 0.0, "不存在的命名驱动不回退到全机速度")
	_check(not world.request_move("player", 0, 1, "absent").is_ok(), "未知模块名称拒绝移动")
	_check(not world.request_move("player", 0, 1, "blade").is_ok(), "近战名称不能借用其他驱动速度")
	_check(not world.request_attack("player", 0, "drive").is_ok(), "移动名称不能借用近战能力")
	_check(not world.request_shoot("player", 0, "blade").is_ok(), "近战名称不能借用射击能力")
	_check(not world.can_attack(world.player, "drive") and world.can_attack(world.player, "blade"), "公开能力查询应用同一命名过滤")
	var move := world.request_move("player", 0, 1, "drive")
	_check(move.is_ok() and move.value.module_id == "drive", "动作句柄记录选中的实例名")
	world.step()
	_check(absf(world.player.position.x - 5.6) < 0.00001, "命名驱动只贡献 0.1 格但带动整个机器参考点")
	world.player.get_module("drive").apply_damage(1.0)
	world.step()
	_check(move.value.state == SimulationCommand.State.CANCELLED and absf(world.player.position.x - 5.6) < 0.00001, "指定驱动失效立即取消，不自动借用另一驱动继续")
	_check(not world.request_move("player", 0, 1, "drive").is_ok(), "已失效模块不能重新接收命名指令")
	_check(world.request_move("player", 0, 1).is_ok(), "显式广播仍可使用其他完好驱动")
	world.step()
	_check(absf(world.player.position.x - 5.7) < 0.00001, "广播兼容剩余可用模块")
	world = _world(_document())
	world.request_attack("player", 180, "left")
	world.step()
	_check(world.attack_traces.size() == 1 and world.player.get_module("right").next_attack_tick == 0, "命名近战只出一条射线，不消耗其他模块冷却")
	world = _world(_document())
	world.request_attack("player", 0)
	world.step()
	_check(world.get_object("alarm").triggered, "不带名称保持全机广播，朝警报攻击会引发真实后果")


## 不同模块可独立行动，广播与命名相交时每个实际模块只取首次调用并共享冷却。
func _test_tick_cooldowns() -> void:
	var world := _world(_document())
	world.request_tick_action("player", "attack", 180, "left")
	world.request_tick_action("player", "attack", 0)
	world.step()
	_check(world.get_object("exit").unlocked and world.attack_traces.size() == 2, "先命名左攻再广播右攻，各模块只执行首次有效方向")
	world = _world(_document())
	world.request_tick_action("player", "attack", 0)
	world.request_tick_action("player", "attack", 180, "left")
	world.step()
	_check(world.get_object("alarm").triggered and not world.get_machine("guard").is_destroyed(), "先广播后命名不能覆盖同一模块本 tick 已提交的方向")
	world = _world(_document())
	world.request_tick_action("player", "attack", 0, "left")
	world.request_tick_action("player", "attack", 180, "left")
	world.step()
	_check(world.get_object("alarm").triggered, "重复命名同一模块保留首次调用")
	world = _world(_document())
	world.request_tick_action("player", "attack", 0)
	world.request_attack("player", 180, "left")
	world.step()
	_check(world.get_object("exit").unlocked, "main 动作仍在 tick 回调前结算，与第四关优先级一致")
	var document := _document()
	document.enemies = []
	document.objects = []
	document.player_spawn.modules = [_module("left", "shooting", -0.5), _module("right", "shooting", 0.5)]
	world = _world(document)
	world.request_tick_action("player", "shoot", 180, "left")
	world.request_tick_action("player", "shoot", 0)
	world.step()
	_check(world.projectiles.size() == 2, "命名加广播只发出每模块一枚弹丸")
	_check(world.projectiles[0].direction == Vector2.LEFT and world.projectiles[1].direction == Vector2.RIGHT, "独立射击保留模块首次调用的左右方向")
	world.request_tick_action("player", "shoot", 90, "left")
	world.request_tick_action("player", "shoot", 270, "right")
	world.step()
	_check(world.projectiles.size() == 2, "下一 tick 冷却中命名调用不额外发射")
	_check(world.player.get_module("left").next_shoot_tick == 11 and world.player.get_module("right").next_shoot_tick == 11, "独立模块共用自身冷却时钟")
	world.stop()
	for unused in 8:
		world.step()
	world.request_tick_action("player", "shoot", 90, "left")
	world.step()
	_check(world.projectiles.size() == 1 and world.projectiles[0].direction == Vector2.UP, "恰好冷却结束时所选射击模块重新发射")


## 检查坏引用、循环、不匹配类型与边界；未知扩展仍原样保存并保持惰性。
func _test_security_validation() -> void:
	var document := _document()
	_check(MapCodec.validate(document, _content, true).is_ok(), "警报与门的有效引用可加载")
	for invalid: Variant in ["missing", "player", 3, true]:
		var bad := document.duplicate_document()
		bad.objects[0].properties.guard_id = invalid
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "警报拒绝不存在或无效守卫引用")
	var unknown := document.duplicate_document()
	unknown.enemies[0].behavior = "custom_script"
	_check(not MapCodec.validate(unknown, _content, true).is_ok(), "警报不能激活未知敌人行为")
	for invalid: Variant in [[], ["guard", "guard"], ["missing"], ["alarm"], true, [false]]:
		var bad := document.duplicate_document()
		bad.objects[1].properties.required_enemy_ids = invalid
		bad.objects[1].properties.required_object_ids = []
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "门拒绝空、重复、错误类型或不存在的敌人依赖")
	for invalid: Variant in [["exit"], ["guard"], ["alarm", "alarm"], ["missing"], 1]:
		var bad := document.duplicate_document()
		bad.objects[1].properties.required_object_ids = invalid
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "门拒绝自引用、重复、错类型或不存在的对象依赖")
	var cycle := document.duplicate_document()
	cycle.objects.append({"id": "other_gate", "type": "security_gate", "position": {"x": 6.5, "y": 2.5}, "properties": {"required_object_ids": ["exit"]}})
	cycle.objects[1].properties.required_object_ids = ["other_gate"]
	_check(not MapCodec.validate(cycle, _content, true).is_ok(), "门与门互相依赖被拒绝，不能创建循环")
	var health := document.duplicate_document()
	health.objects[0].properties.max_health = false
	_check(not MapCodec.validate(health, _content, true).is_ok(), "警报耐久拒绝布尔值")
	var bounds := document.duplicate_document()
	bounds.objects[1].position.x = 0.1
	_check(not MapCodec.validate(bounds, _content, true).is_ok(), "门完整方形占地必须位于地图内")
	var future := document.duplicate_document()
	future.objects = []
	future.enemies[0].behavior = "future_behavior"
	future.enemies[0].properties = {"custom": [1, 2, 3]}
	future.objects.append({"id": "future", "type": "future_object", "position": {"x": 2, "y": 2}, "custom": {"value": true}})
	_check(MapCodec.validate(future, _content, true).is_ok(), "未注册对象和行为仍作为元数据保留")
	var world := _world(future)
	_check(world.get_machine("guard") == null and world.get_object("future") == null, "未知行为不会意外生成运行敌人或对象")
	_check(world.document.to_dict().objects[0].custom.value, "未知对象扩展字段在独立模拟快照中保留")


## 构造有上下出口门和左右目标的全地板夹具，使用生产默认模块。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "prison_fixture"
	document.width = 12
	document.height = 8
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5.5, "y": 4.5}, "modules": [_module("drive", "movement", 0), _module("left", "melee", -0.5), _module("right", "melee", 0.5)]}
	document.enemies = [{"id": "guard", "behavior": "alarm_guard", "position": {"x": 3.5, "y": 4.5}, "modules": [_module("guard_blade", "melee", 0)], "properties": {}}]
	document.objects = [{"id": "alarm", "type": "prison_alarm", "position": {"x": 7.5, "y": 4.5}, "properties": {"max_health": 1, "guard_id": "guard"}}, {"id": "exit", "type": "security_gate", "position": {"x": 5.5, "y": 2.5}, "properties": {"required_enemy_ids": ["guard"], "required_object_ids": ["alarm"]}}]
	return document


## 模块实例名和内容 ID 分开，确保测试覆盖装配命名而非模块种类字符串。
func _module(id: String, kind: String, offset_x: float) -> Dictionary:
	return {"id": id, "module_id": kind, "offset": {"x": offset_x, "y": 0}}


## 通过正式校验和工厂生成世界，夹具错误也记为失败而不继续空值调用。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	if not _check(result.is_ok(), "世界夹具可运行：%s" % result.errors):
		return null
	return result.value


## 统一累计断言，包装脚本同时校验本汇总和引擎错误。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
