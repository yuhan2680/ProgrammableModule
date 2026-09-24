extends SceneTree
## 关卡与战斗回归：覆盖原三关、射击、敌人、同时伤害及配置边界。

const FIRST := "main() {\nmove(0, 4)\nmove(90, 3)\nmove(180, 4)\nmove(90, 3)\nmove(0, 4)\n}\n"
const SECOND := "main() {\nmove(0, 8)\n}\n"
const THIRD := "main() {\nmove(0, 3)\nattack(0)\n}\n"
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _levels: Array[LevelDefinition] = []


## 使用独立测试进程，不读写真实玩家草稿与进度。
func _initialize() -> void:
	_run.call_deferred()


## 读取真实关卡并通过公开模型验证设计约束。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "内容注册表加载成功"):
		quit(1)
		return
	for index in range(1, 4):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % index, _content, true)
		if not _check(loaded.is_ok(), "关卡 JSON 可加载"):
			quit(1)
			return
		var parsed := LevelDefinition.from_document(loaded.value, _content)
		if not _check(parsed.is_ok(), "关卡规则有效"):
			quit(1)
			return
		_levels.append(parsed.value)
		_check(parsed.value.order == index and parsed.value.id == "level_%03d" % index, "稳定 ID 与关卡顺序")
	_test_first()
	_test_gate()
	_test_melee()
	_test_attack_boundaries()
	_test_attack_commit()
	_test_data_validation()
	_combat_test_cooldown_and_flight()
	_combat_test_speed_damage_and_sweep()
	_combat_test_nearest_and_simultaneous()
	_combat_test_blocking()
	_combat_test_enemy()
	_combat_test_validation()
	print("关卡与战斗回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 第一关路线保持不变，并验证早期关卡尚未解锁攻击。
func _test_first() -> void:
	_check(_levels[0].module_limit == 1, "第一关限制一个模块")
	for y in [1, 4, 7]:
		for x in range(1, 6):
			_check(_levels[0].document.get_tile_id(Vector2i(x, y)) == "floor", "S 路线三排上下对齐")
	var first := _session(0, ["movement"], FIRST)
	_check(first.run().is_ok(), "第一关程序可启动")
	_finish(first)
	_check(first.state == GameSession.State.SUCCEEDED, "第一关通关不回归")
	for index in [0, 1]:
		var locked := _session(index, ["movement"], "main() {\nattack(0)\n}")
		_check(not locked.run().is_ok() and locked.message.contains("尚未解锁") and locked.current_line == 2, "前两关攻击保持锁定并定位源码行")
		_check(not locked.assembly.add_module("melee", Vector2(0.5, 0)).is_ok(), "前两关禁止安装近战模块")


## 水平通道中单模块被挡、双模块及时过闸；暂停和重置使用模拟时间。
func _test_gate() -> void:
	for cell: Vector2i in _levels[1].document.cells:
		_check(cell.y == 3, "第二关地板只有同一水平行，没有上下绕路")
	var one := _session(1, ["movement"], SECOND)
	_check(one.run().is_ok(), "单驱动允许尝试")
	_finish(one)
	_check(one.state == GameSession.State.FAILED and one.current_line == 2, "单驱动被已落下闸门阻挡并定位 move 行")
	_check(one.world.player.position.x < 7.0 and one.world.get_object("speed_gate").is_blocking(one.world.tick_index), "单驱动停在闸门之前")
	var two := _session(1, ["movement", "movement"], SECOND)
	_check(two.run().is_ok(), "双驱动允许启动")
	for unused in 34:
		two.step()
	_check(not two.world.get_object("speed_gate").is_blocking(two.world.tick_index), "第 34 tick 闸门仍打开")
	two.pause()
	for unused in 20:
		two.step()
	_check(two.world.tick_index == 34, "暂停不推进闸门倒计时")
	two.resume()
	two.step()
	_check(two.world.tick_index == 35 and two.world.get_object("speed_gate").is_blocking(35), "第 35 tick 闸门落下")
	_check(two.state == GameSession.State.RUNNING, "完全通过闸门的双驱动不受身后落闸影响")
	_finish(two)
	_check(two.state == GameSession.State.SUCCEEDED and two.world.tick_index == 40, "双驱动水平向右八格四秒通关")
	two.reset()
	_check(two.world == null and two.assembly.modules.size() == 2 and two.source == SECOND, "重置保留程序装配，释放旧世界")
	two.run()
	_check(two.world.tick_index == 0 and not two.world.get_object("speed_gate").is_blocking(0), "重新运行恢复打开的闸门")
	two.stop()
	# 提前落闸，测试正压在闸门内时立即失败，不允许先移动出去。
	var crushed_level := _clone_level(1)
	crushed_level.document.objects[0].properties.close_after_ticks = 30
	var crushed := _session_for(crushed_level, ["movement", "movement"], SECOND)
	crushed.run()
	_finish(crushed)
	_check(crushed.state == GameSession.State.FAILED and crushed.world.tick_index == 30 and crushed.message.contains("碰到机器"), "落闸时正面积交叠立即失败")
	# 没有移动命令也必须检测落闸，验证规则属于世界而非解释器。
	var idle := SimulationWorld.create(_levels[1].document, _content).value as SimulationWorld
	idle.player.position = Vector2(7.5, 3.5)
	for unused in 35:
		idle.step()
	_check(not idle.failure_reason.is_empty(), "原地等待的机器也会被闸门压住")
	# 使用实际内容变体提高速度，已落下的闸门仍检查完整扫掠路径。
	var fast := SimulationWorld.create(_levels[1].document, _content).value as SimulationWorld
	for unused in 35:
		fast.step()
	var saved_speed: Variant = _content.get_module("movement").properties.move_speed
	_content.get_module("movement").properties.move_speed = 10000.0
	var move := fast.request_move("player", 0, 8).value as MovementCommand
	fast.step()
	_content.get_module("movement").properties.move_speed = saved_speed
	_check(move.state == MovementCommand.State.BLOCKED and fast.player.position.x < 7, "高速移动不能穿透已落下闸门")


## 第三关必须安装近战并摧毁障碍，移动到目标附近不会自动胜利。
func _test_melee() -> void:
	var level := _levels[2]
	_check(level.module_limit == 2 and level.allowed_modules == PackedStringArray(["movement", "melee"]), "第三关解锁近战且上限为两个")
	_check(level.goal_type == "destroy_object", "第三关使用摧毁目标，未伪造绿色终点")
	var target: Dictionary = level.document.objects[0]
	_check(float(target.position.x) - float(level.document.player_spawn.position.x) == 5.0 and target.position.y == level.document.player_spawn.position.y, "障碍物中心正好在右侧五格")
	var original := JSON.stringify(level.document.to_dict())
	var missing := _session(2, ["movement"], THIRD)
	_check(not missing.run().is_ok() and missing.current_line == 3 and missing.world.tick_index == 0, "缺少近战在整程序预检时拒绝，前面的 move 不会偷偷执行")
	var session := _session(2, ["movement", "melee"], THIRD)
	_check(session.run().is_ok(), "移动加近战程序可以启动")
	for unused in 30:
		session.step()
	_check(session.state == GameSession.State.RUNNING and session.world.get_object("training_obstacle").health == 1, "移动靠近目标不通关、不提前结算下一行攻击")
	session.pause()
	session.step()
	_check(session.world.tick_index == 30, "攻击前暂停保持 tick")
	session.resume()
	session.step()
	_check(session.state == GameSession.State.SUCCEEDED and session.world.tick_index == 31, "下一 tick 攻击摧毁障碍物通关")
	_check(session.world.get_object("training_obstacle").health == 0, "命中真正改变对象运行血量")
	session.reset()
	session.run()
	_check(session.world.get_object("training_obstacle").health == 1, "重试恢复障碍物耐久")
	session.stop()
	_check(JSON.stringify(level.document.to_dict()) == original, "成功与重试不修改静态地图")
	for program in ["main(){attack(0)}", "main(){\nmove(0,3)\nattack(90)\n}", "main(){move(0,3)}", "main(){move(0,5)}"]:
		var failed := _session(2, ["movement", "melee"], program)
		_check(failed.run().is_ok(), "允许尝试射程、方向或路线错误的程序")
		_finish(failed)
		_check(failed.state == GameSession.State.FAILED and failed.world.get_object("training_obstacle").health == 1, "远距离、错误方向、只靠近或撞入障碍均不能通关")


## 验证射程边界、真实模块偏移、墙体遮挡、动作独占与取消。
func _test_attack_boundaries() -> void:
	var calls := PackedStringArray(["move", "attack"])
	for source in ["main(){attack()}", "main(){attack(0,1)}", "main(){attack(true)}"]:
		_check(not ProgramParser.parse(source, calls).is_ok(), "attack 严格要求一个数值参数")
	var parsed := ProgramParser.parse("main(){\n  attack(-360)\n}", calls)
	_check(parsed.is_ok() and parsed.value.main.body.statements[0].line == 2 and parsed.value.main.body.statements[0].column == 3, "attack AST 保留准确行列与有符号角度")
	for advance in [1.99, 2.0]:
		var session := _session(2, ["movement", "melee"], "main(){}")
		var world := SimulationWorld.create(session.assembly.build_document().value, _content).value as SimulationWorld
		world.player.position += Vector2(advance, 0)
		var attack := world.request_attack("player", 0).value as AttackCommand
		_check(not world.request_move("player", 0, 1).is_ok() and not world.request_attack("player", 0).is_ok(), "攻击与移动共享独占动作通道")
		_check(world.get_object("training_obstacle").health == 1, "提交攻击不立即造成伤害")
		world.step()
		_check(attack.hit_count == (1 if advance == 2.0 else 0), "射程从偏移半格的近战中心到障碍表面，恰好二格命中，超出不命中")
		_check(attack.state == AttackCommand.State.COMPLETED, "挥空与命中均正常完成一次动作")
	var session := _session(2, ["movement", "melee"], THIRD)
	var assembled: MapDocument = session.assembly.build_document().value
	var world := SimulationWorld.create(assembled, _content).value as SimulationWorld
	world.player.position += Vector2(3, 0)
	var cancelled := world.request_attack("player", 0).value as AttackCommand
	world.cancel_command("player")
	world.step()
	_check(cancelled.state == AttackCommand.State.CANCELLED and world.get_object("training_obstacle").health == 1, "取消后不能产生迟到伤害")
	_check(not world.request_attack("player", true).is_ok() and not world.request_attack("player", INF).is_ok(), "世界 API 拒绝布尔值和无穷角度")
	# 隔着 void 的射线不会攻击目标；对象本身仍保留地板支撑。
	world.document.cells.erase(Vector2i(5, 2))
	var blocked := world.request_attack("player", 0).value as AttackCommand
	world.step()
	_check(blocked.hit_count == 0 and world.get_object("training_obstacle").health == 1, "void 阻挡攻击射线")
	# 对象被摧毁后原地板重新可通过。
	world.document.cells[Vector2i(5, 2)] = "floor"
	world.request_attack("player", 0)
	world.step()
	var through := world.request_move("player", 0, 3).value as MovementCommand
	for unused in 31:
		world.step()
	_check(through.state == MovementCommand.State.COMPLETED, "已摧毁的障碍物不再阻挡移动")


## 校验可扩展 JSON 与旧格式兼容，坏动态配置不能保存或运行。
func _test_data_validation() -> void:
	for value in [0, -1, true, 1.5, 1000001]:
		var invalid := _levels[1].document.duplicate_document()
		invalid.objects[0].properties.close_after_ticks = value
		_check(not MapCodec.validate(invalid, _content, true).is_ok(), "非法落闸 tick 被拒绝")
	for value in [0, -1, true, "1"]:
		var invalid := _levels[2].document.duplicate_document()
		invalid.objects[0].properties.max_health = value
		_check(not MapCodec.validate(invalid, _content, true).is_ok(), "非法耐久被拒绝")
	var invalid := _levels[2].document.duplicate_document()
	invalid.properties.level.goal.object_id = "missing"
	_check(not LevelDefinition.from_document(invalid, _content).is_ok(), "目标不能引用不存在对象")
	invalid = _levels[0].document.duplicate_document()
	invalid.properties.level.goal.type = "not_implemented"
	_check(not LevelDefinition.from_document(invalid, _content).is_ok(), "未知目标类型不能悄悄按终点执行")
	invalid = _levels[2].document.duplicate_document()
	invalid.player_spawn.position = invalid.objects[0].position.duplicate()
	_check(LevelDefinition.from_document(invalid, _content).is_ok(), "编辑器关卡校验不把出生模板当成玩家实际装配")
	_check(not SimulationWorld.create(invalid, _content).is_ok(), "确认实际出生占地时拒绝与障碍重叠")
	var extended := _levels[2].document.duplicate_document()
	extended.objects.append({"id": "future_item", "type": "future_type", "position": {"x": 2, "y": 2}, "custom": [1, {"key": "保留"}]})
	var roundtrip := MapCodec.from_dict(extended.to_dict(), _content, true)
	_check(roundtrip.is_ok() and JSON.stringify(roundtrip.value.to_dict()) == JSON.stringify(extended.to_dict()), "未知对象与自定义扩展数据无损往返")
	var behaviors := ModuleBehaviorRegistry.create_default()
	var melee := _content.get_module("melee")
	var original := melee.properties.duplicate(true)
	for field in ["range", "damage"]:
		melee.properties[field] = true
		_check(not behaviors.create_behavior(melee).is_ok(), "近战行为拒绝布尔能力参数")
		melee.properties = original.duplicate(true)


## 复制关卡以调整测试计时，避免改变其它用例的输入。
func _clone_level(index: int) -> LevelDefinition:
	return LevelDefinition.from_document(_levels[index].document.duplicate_document(), _content).value


## 使用真实内置关卡创建会话。
func _session(index: int, types: Array, source: String) -> GameSession:
	return _session_for(_levels[index], types, source)


## 显式安装共边模块，不绕过空装配与确认流程。
func _session_for(level: LevelDefinition, types: Array, source: String) -> GameSession:
	var session := GameSession.create(level, _content)
	_check(session.assembly.modules.is_empty(), "新会话从空装配开始")
	for index in types.size():
		_check(session.assembly.add_module(types[index], Vector2(index * 0.5, 0)).is_ok(), "通过公开 API 安装共边模块")
	session.source = source
	return session


## 有界推进会话，防止错误配置让自动化无限等待。
func _finish(session: GameSession) -> void:
	for unused in 1000:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "关卡应在 1000 tick 内结束")


## 统一收集失败，依赖失败时调用方可以及时结束测试。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 两台机器同 tick 攻击共享同一快照，信号回调只观察完整提交后的伤害结果。
func _test_attack_commit() -> void:
	var session := _session(2, ["movement", "melee"], THIRD)
	var document: MapDocument = session.assembly.build_document().value
	document.objects[0].properties.max_health = 2
	var world := SimulationWorld.create(document, _content).value as SimulationWorld
	world.player.position += Vector2(3, 0)
	var spawn: Dictionary = document.player_spawn.duplicate(true)
	# 新战斗会命中其它机器的实体模块；两台机器共边摆放并各自瞄准障碍，避免旧重叠夹具互相挡住射线。
	spawn.position = {"x": 4.5, "y": 3.0}
	var another := MachineFactory.create_machine("another", spawn, document, _content, ModuleBehaviorRegistry.create_default())
	_check(another.is_ok() and world.add_machine(another.value).is_ok(), "第二台独立机器可参与同 tick 命令")
	var first := world.request_attack("player", 0).value as AttackCommand
	var second := world.request_attack("another", rad_to_deg(atan2(0.5, 1.0))).value as AttackCommand
	var observations: Array = []
	# 用途：记录外部订阅者看到的提交后状态，并尝试重入 step 检查守卫。
	first.finished.connect(func(_command: SimulationCommand) -> void:
		observations.append(world.get_object("training_obstacle").health)
		world.step()
	)
	world.step()
	_check(first.hit_count == 1 and second.hit_count == 1 and world.get_object("training_obstacle").health == 0, "同 tick 多命中累计伤害")
	_check(observations == [0.0] and world.tick_index == 1, "伤害完全提交后通知，回调不能重入推进 tick")
	# stop 清空攻击通道，后续新命令可正常申请，旧句柄不会复活。
	var pending := world.request_attack("player", 0).value as AttackCommand
	world.stop()
	_check(pending.state == AttackCommand.State.CANCELLED and world.request_move("player", 0, 0).is_ok(), "stop 释放攻击与移动通道")


## 从实际 JSON 数据边界构造测试地图，复用真实地图类型与字段校验。
func _combat_document(module_id: String = "shooting") -> Variant:
	var tiles: Array = []
	for y in range(8):
		for x in range(20):
			tiles.append({"x": x, "y": y, "tile_id": "floor"})
	var data := {"format_version": 1, "id": "combat_test", "name": "战斗测试",
		"width": 20, "height": 8, "tiles": tiles,
		"player_spawn": {"position": {"x": 1.5, "y": 3.5}, "modules": [_combat_module(module_id, module_id)]}}
	var parsed := MapCodec.from_dict(data, _content, true)
	_check(parsed.is_ok(), "战斗地图 JSON 数据合法")
	return parsed.value


## 以下战斗用例复用本入口的依赖图，兼容 Godot 4.5 的全局脚本类型加载。
## 创建统一格式的模块实例 JSON，偏移可覆盖以测试单个部件遮挡。
func _combat_module(id: String, module_id: String, x: float = 0.0, y: float = 0.0) -> Dictionary:
	return {"id": id, "module_id": module_id, "offset": {"x": x, "y": y}}


## 使用可信工厂添加静止靶机，不额外启动 AI。
func _combat_target(world: SimulationWorld, id: String, position: Vector2, modules: Array) -> MachineInstance:
	var spawn := {"position": {"x": position.x, "y": position.y}, "modules": modules}
	var result := MachineFactory.create_machine(id, spawn, world.document, _content, ModuleBehaviorRegistry.create_default())
	_check(result.is_ok(), "靶机装配可构造")
	var machine: MachineInstance = result.value
	_check(world.add_machine(machine).is_ok(), "靶机占地可添加")
	return machine


## 验证一 tick 射击、冷却空调用、连续减速、最终消失及取消队列。
func _combat_test_cooldown_and_flight() -> void:
	var world := SimulationWorld.create(_combat_document(), _content).value as SimulationWorld
	var first := world.request_shoot("player", 0).value as ShootCommand
	world.step()
	_check(first.state == SimulationCommand.State.COMPLETED and first.shot_count == 1, "射击一个 tick 完成并发弹")
	_check(world.has_pending_projectiles("player") and world.projectiles.size() == 1, "飞行弹丸独立于已完成命令")
	var bullet := world.projectiles[0]
	_check(is_equal_approx(bullet.position.x, 2.28) and is_equal_approx(bullet.speed, 7.6), "首 tick 使用匀减速距离和末速")
	var second := world.request_shoot("player", 0).value as ShootCommand
	world.step()
	_check(second.state == SimulationCommand.State.COMPLETED and second.shot_count == 0, "冷却中调用成功但不发弹")
	var previous_speed := bullet.speed
	for unused in 18:
		world.step()
		_check(bullet.speed <= previous_speed, "弹丸速度单调递减")
		previous_speed = bullet.speed
	_check(world.projectiles.is_empty() and is_equal_approx(bullet.position.x, 9.5), "速度归零时在八格射程处消失")
	var ready := world.request_shoot("player", 0).value as ShootCommand
	world.step()
	_check(ready.shot_count == 1, "冷却结束后可再次射击")
	world.stop()
	_check(world.projectiles.is_empty(), "停止释放飞行弹丸")
	world.request_tick_action("player", "shoot", 0)
	world.cancel_command("player")
	world.step()
	_check(world.projectiles.is_empty(), "取消会清除待执行 tick 攻击")


## 以真实弹道验证近处伤害较高、远处伤害较低和高速扫掠不漏命中。
func _combat_test_speed_damage_and_sweep() -> void:
	var near_world := SimulationWorld.create(_combat_document(), _content).value as SimulationWorld
	var near := _combat_target(near_world, "near", Vector2(2.5, 3.5), [_combat_module("drive", "movement")])
	near.modules[0].health = 10.0
	near_world.request_shoot("player", 0)
	for unused in 12:
		near_world.step()
	var near_damage := 10.0 - near.modules[0].health
	_check(near_damage > 1.4 and near_damage < 1.6, "近距离伤害采用命中速度而非初速")
	var far_world := SimulationWorld.create(_combat_document(), _content).value as SimulationWorld
	var far := _combat_target(far_world, "far", Vector2(5.2, 3.5), [_combat_module("drive", "movement")])
	far.modules[0].health = 10.0
	far_world.request_shoot("player", 0)
	for unused in 12:
		far_world.step()
	var far_damage := 10.0 - far.modules[0].health
	_check(far_damage > 0.0 and far_damage < near_damage, "弹丸远距离减速导致更低伤害")
	var world := SimulationWorld.create(_combat_document(), _content).value as SimulationWorld
	var moving := _combat_target(world, "moving", Vector2(3.3, 3.0), [_combat_module("drive", "movement")])
	var bullet := ProjectileInstance.new()
	bullet.owner_id = "player"
	bullet.position = Vector2(1.5, 3.5)
	bullet.direction = Vector2.RIGHT
	bullet.speed = 40.0
	bullet.deceleration = 4.0
	bullet.damage_per_speed = 1.0
	world.projectiles.append(bullet)
	moving.modules[0].definition = _content.get_module("movement")
	world.request_move("moving", 270, 1.0)
	world.step()
	_check(moving.modules[0].available, "弹丸不会命中本 tick 未穿过弹道的模块")
	var swept_world := SimulationWorld.create(_combat_document(), _content).value as SimulationWorld
	var swept := _combat_target(swept_world, "swept", Vector2(3.0, 3.5), [_combat_module("drive", "movement")])
	bullet = ProjectileInstance.new()
	bullet.owner_id = "player"
	bullet.position = Vector2(1.5, 3.5)
	bullet.speed = 40.0
	bullet.deceleration = 4.0
	bullet.damage_per_speed = 1.0
	swept_world.projectiles.append(bullet)
	swept_world.step()
	_check(swept.is_destroyed() and swept_world.projectiles.is_empty(), "四格每 tick 的高速弹丸扫掠命中半格模块")


## 验证近战不穿透模块，剩余模块继续生效；双方同时攻击不会偏袒遍历顺序。
func _combat_test_nearest_and_simultaneous() -> void:
	var world := SimulationWorld.create(_combat_document("melee"), _content).value as SimulationWorld
	var enemy := _combat_target(world, "enemy", Vector2(3.0, 3.5), [_combat_module("drive", "movement", -0.5), _combat_module("blade", "melee")])
	world.request_attack("player", 0)
	world.step()
	_check(not enemy.get_module("drive").available and enemy.get_module("blade").available, "近战每源仅摧毁最近的移动模块")
	_check(enemy.get_move_speed() == 0.0 and not enemy.is_destroyed(), "移动部件受损停止移动但敌机尚存活")
	world.request_attack("enemy", 180)
	world.step()
	_check(world.player.is_destroyed() and not world.failure_reason.is_empty(), "残存近战部件仍能击毁玩家")
	var edge_world := SimulationWorld.create(_combat_document("melee"), _content).value as SimulationWorld
	var edge := _combat_target(edge_world, "edge", Vector2(3.75, 3.5), [_combat_module("drive", "movement")])
	edge_world.request_attack("player", 0)
	edge_world.step()
	_check(edge.is_destroyed(), "近战恰好两格的模块表面可以命中")
	world = SimulationWorld.create(_combat_document("melee"), _content).value as SimulationWorld
	enemy = _combat_target(world, "enemy", Vector2(3.0, 3.5), [_combat_module("blade", "melee")])
	var a := world.request_attack("player", 0).value as AttackCommand
	var b := world.request_attack("enemy", 180).value as AttackCommand
	world.step()
	_check(a.hit_count == 1 and b.hit_count == 1 and enemy.is_destroyed() and world.player.is_destroyed(), "双方同 tick 近战同时结算伤害")
	world = SimulationWorld.create(_combat_document("melee"), _content).value as SimulationWorld
	enemy = _combat_target(world, "enemy", Vector2(2.0, 3.5), [_combat_module("gun", "shooting")])
	world.request_attack("player", 0)
	var shot := world.request_shoot("enemy", 180).value as ShootCommand
	world.step()
	_check(shot.shot_count == 1 and enemy.is_destroyed() and world.player.is_destroyed(), "射击源同 tick 被近战摧毁仍成功开火")


## 障碍物和 void 都挡住弹丸，背后模块不会受到穿透伤害。
func _combat_test_blocking() -> void:
	var document: Variant = _combat_document()
	document.objects.append({"id": "wall", "type": "destructible", "position": {"x": 3.5, "y": 3.5}, "size": 1.0, "properties": {"max_health": 10.0}})
	var world := SimulationWorld.create(document, _content).value as SimulationWorld
	var enemy := _combat_target(world, "enemy", Vector2(4.5, 3.5), [_combat_module("drive", "movement")])
	world.request_shoot("player", 0)
	for unused in 12:
		world.step()
	_check(world.get_object("wall").health < 10.0 and enemy.modules[0].health == 1.0, "前方障碍物吸收弹丸并保护后方模块")
	document = _combat_document()
	document.cells.erase(Vector2i(3, 3))
	world = SimulationWorld.create(document, _content).value as SimulationWorld
	enemy = _combat_target(world, "enemy", Vector2(4.5, 3.5), [_combat_module("drive", "movement")])
	world.request_shoot("player", 0)
	for unused in 12:
		world.step()
	_check(enemy.modules[0].health == 1.0 and world.projectiles.is_empty(), "弹丸不会穿过 void")


## 固定敌人按模拟 tick 接近四点五格，随后攻击；重建世界恢复模块健康。
func _combat_test_enemy() -> void:
	var document: Variant = _combat_document()
	document.enemies.append({"id": "guard", "position": {"x": 7.5, "y": 3.5}, "modules": [_combat_module("drive", "movement", -0.5), _combat_module("blade", "melee")], "behavior": "approach_attack", "properties": {"move_angle": 180, "move_distance": 4.5, "attack_angle": 180}})
	var world := SimulationWorld.create(document, _content).value as SimulationWorld
	var enemy := world.get_machine("guard")
	for unused in 45:
		world.step()
	_check(enemy.position.is_equal_approx(Vector2(3.0, 3.5)) and not world.player.is_destroyed(), "敌人先完成四点五格移动")
	world.step()
	_check(world.player.is_destroyed(), "敌人下一 tick 执行向左近战")
	var retry := SimulationWorld.create(document, _content).value as SimulationWorld
	_check(retry.tick_index == 0 and retry.player.modules[0].health == 1.0 and retry.get_machine("guard").position.x == 7.5, "重试恢复初始时间位置与模块健康")
	for unused in 100:
		if not retry.player.is_destroyed():
			retry.request_tick_action("player", "shoot", 0)
		retry.step()
		if retry.get_machine("guard").is_destroyed():
			break
	_check(retry.get_machine("guard").is_destroyed() and not retry.player.is_destroyed(), "每 tick 射击能够击毁第四关双模块敌人")
	print("combat balance win tick=%d" % retry.tick_index)


## 拒绝无效已注册行为参数，未知扩展继续无损保存而不执行。
func _combat_test_validation() -> void:
	var document: Variant = _combat_document()
	var enemy := {"id": "guard", "position": {"x": 7.5, "y": 3.5}, "modules": [_combat_module("drive", "movement")], "behavior": "approach_attack", "properties": {"move_angle": true, "move_distance": 4.5, "attack_angle": 180}}
	document.enemies.append(enemy)
	_check(not MapCodec.validate(document, _content, true).is_ok(), "敌人角度拒绝布尔值")
	document.enemies[0].properties.move_angle = 180
	document.enemies[0].id = "player"
	_check(not MapCodec.validate(document, _content, true).is_ok(), "敌人不能占用 player ID")
	document.enemies[0].id = "guard"
	document.enemies[0].behavior = "future_custom_behavior"
	_check(MapCodec.validate(document, _content, true).is_ok(), "未知敌人行为保留为扩展")
	var world := SimulationWorld.create(document, _content).value as SimulationWorld
	_check(world.get_machine("guard") == null, "未知敌人行为不会隐式执行")
	var definition := ModuleDefinition.new()
	definition.id = "invalid_shooting"
	definition.properties = {"projectile_speed": 8.0, "deceleration": 0.0, "damage_per_speed": 1.0, "cooldown_ticks": 1}
	var behavior := ShootingModule.new()
	_check(not behavior.validate_definition(definition).is_ok(), "零减速被拒绝，弹丸必须结束")
	definition.properties.deceleration = 8.0
	definition.properties.cooldown_ticks = false
	_check(not behavior.validate_definition(definition).is_ok(), "冷却参数拒绝布尔值")
	var raw: Dictionary = _content.get_module("movement").raw.duplicate(true)
	raw.properties.max_health = false
	_check(not ContentRegistry._parse_module(raw).is_ok(), "所有模块的健康上限拒绝布尔值")
	raw.properties.max_health = 2.5
	_check(ContentRegistry._parse_module(raw).is_ok(), "旧模块可通过可选健康属性扩展耐久")


