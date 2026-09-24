extends SceneTree
## 第八关底层回归：并行动作原子入队、真实模块资源、联动警报和固定 tick 结算。

var _checks: int = 0
var _failures: int = 0
var _content := ContentRegistry.new()


## 等待脚本类导入完成后运行；仅建立内存世界，不触碰任何玩家记录。
func _initialize() -> void:
	_run.call_deferred()


## 通过公共命令和世界结果验证规则，不依赖内部队列的存储组织。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "内容加载成功"):
		quit(1)
		return
	_test_atomic_pairs()
	_test_movement_alarm()
	_test_group_wait()
	_test_validation_and_atomic_request()
	_test_cancel()
	_test_tick_overlap()
	_test_projectile_pairs()
	_test_pair_validation()
	print("并行动作底层回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 两个方向必须同 tick 清除；对象列表和动作顺序不改变结算，重建后警报重新生效。
func _test_atomic_pairs() -> void:
	for reversed in [false, true]:
		var document := _document()
		var actions := _pair_actions()
		if reversed:
			document.objects.reverse()
			actions.reverse()
		var world := _world(document)
		if world == null:
			return
		var accepted := world.request_simultaneous("player", actions)
		if not _check(accepted.is_ok() and accepted.value is SimultaneousCommand, "真实并行块生成独立组句柄"):
			return
		var group: SimultaneousCommand = accepted.value
		_check(group.children.size() == 2 and group.started_tick == -1, "提交时两个子动作均未执行")
		_check(world.tick_index == 0 and world.get_object("left_alarm").health == 1.0, "入队不提前推进世界或造成伤害")
		world.step()
		_check(group.state == SimulationCommand.State.COMPLETED and group.started_tick == 1, "两条短动作同一固定 tick 完成整个块")
		_check(world.get_object("left_alarm").health == 0 and world.get_object("right_alarm").health == 0, "双侧警报均被真正命中")
		_check(not world.player.is_destroyed() and world.failure_reason.is_empty(), "同 tick 同时拆除不会误报失败")
		_check(not world.get_object("left_alarm").triggered and not world.get_object("right_alarm").triggered, "两侧触发标志保持关闭")
		_check(world.get_object("exit").unlocked, "两侧清除后才解锁出口")
		_check(world.attack_traces.size() == 2, "两个具名模块各产生自己方向的射线")
		world.request_move("player", 90, 3)
		for unused in 30:
			world.step()
		_check(world.player.position.is_equal_approx(Vector2(5.5, 1.5)), "拆除以后正常沿真实路径逃离")
		var retry := _world(document)
		_check(retry.get_object("left_alarm").health == 1 and retry.get_object("right_alarm").health == 1, "重建世界恢复两个警报耐久")
		_check(not retry.get_object("exit").unlocked and not retry.get_object("left_alarm").triggered, "重建恢复门和触发状态")
	for side in ["left", "right"]:
		var world := _world(_document())
		world.request_attack("player", 180 if side == "left" else 0, side)
		world.step()
		_check(world.player.is_destroyed() and world.failure_reason.contains("同时摧毁"), "单边先毁当帧失败，不能下一 tick 补救")
		_check(world.get_object("left_alarm").triggered and world.get_object("right_alarm").triggered, "单边失败时两侧均记录联动触发")
		_check(not world.get_object("exit").unlocked, "单边拆除不会解锁出口")


## 警戒取移动前快照；真实位移、零距离和被挡住而没有位移的调用应严格区分。
func _test_movement_alarm() -> void:
	var world := _world(_document())
	world.request_move("player", 90, 0.1)
	world.step()
	_check(world.player.is_destroyed() and world.failure_reason.contains("移动"), "警报存活时真实移动立即失败")
	_check(world.get_object("left_alarm").health == 1 and world.get_object("right_alarm").health == 1, "移动失败不伪造警报损坏")
	world = _world(_document())
	var moving_actions := _pair_actions()
	moving_actions.append(_action("move", [90.0, 0.1], "drive"))
	world.request_simultaneous("player", moving_actions)
	world.step()
	_check(world.get_object("left_alarm").health == 0 and world.get_object("right_alarm").health == 0, "同 tick 移动与两次攻击都按实际提案结算")
	_check(world.player.is_destroyed() and world.failure_reason.contains("移动"), "即便同 tick 全部击毁，警戒期间移动仍失败")
	world = _world(_document())
	world.request_move("player", 90, 0)
	world.step()
	_check(not world.player.is_destroyed() and world.failure_reason.is_empty(), "零距离消耗 tick 但没有实际位移，不触发警报")
	var document := _document()
	document.objects[2].position.y = 3.75
	world = _world(document)
	world.request_move("player", 90, 1)
	world.step()
	_check(world.player.position == Vector2(5.5, 4.5) and not world.player.is_destroyed(), "贴紧阻挡物而完全没有移动时不触发位移警报")
	_check(world.failure_reason.is_empty(), "普通受阻由动作句柄报告，不误称机关触发")


## 混合长短动作只有一个世界时钟；短动作不会重放，main 通道等待最长动作。
func _test_group_wait() -> void:
	var world := _world(_plain_document())
	var actions := _pair_actions()
	actions.append(_action("move", [0.0, 0.3], "drive"))
	var accepted := world.request_simultaneous("player", actions)
	if not _check(accepted.is_ok(), "接受不同模块的移动加双向攻击"):
		return
	var group: SimultaneousCommand = accepted.value
	var notifications: Array[int] = []
	group.finished.connect(func(_group: SimulationCommand): notifications.append(world.tick_index))
	world.step()
	_check(world.tick_index == 1 and absf(world.player.position.x - 5.6) < 0.00001, "一个 group step 仅推进一个逻辑 tick 和一次移动")
	_check(not group.is_finished() and group.children[0].is_finished() and group.children[1].is_finished(), "两次攻击完成但整组等待移动")
	_check(not world.request_move("player", 0, 1).is_ok() and not world.request_attack("player", 0).is_ok() and not world.request_simultaneous("player", _pair_actions()).is_ok(), "任何普通或并行 main 请求均不能插入活动组")
	_check(world.validate_simultaneous("player", _pair_actions()).is_ok(), "只读整树预检不因当前通道忙而拒绝未来的块")
	world.step()
	_check(world.attack_traces.is_empty() and not group.is_finished(), "已完成的攻击不在剩余移动 tick 重放")
	world.step()
	_check(group.state == SimulationCommand.State.COMPLETED and notifications == [3], "恰好最长子动作完成时通知一次整组")
	_check(absf(world.player.position.x - 5.8) < 0.00001, "并行保持原有准确距离")
	_check(world.request_attack("player", 0).is_ok(), "全部完成后才能提交后续 main 动作")


## 无效后半段不能留下前半段动作；广播按真实实例展开，严格拒绝参数和重复机身位移。
func _test_validation_and_atomic_request() -> void:
	var invalid_cases: Array[Array] = [
		[_action("attack", [180.0], "left"), _action("attack", [0.0], "missing")],
		[_action("attack", [180.0], "left"), _action("attack", [0.0], "left")],
		[_action("attack", [180.0], "left"), _action("attack", [0.0])],
		[_action("attack", [180.0]), _action("attack", [0.0], "right")],
		[_action("move", [0.0, 1.0], "drive"), _action("move", [90.0, 1.0], "drive")],
		[_action("attack", [180.0], "left"), _action("shoot", [0.0], "right")],
		[_action("attack", [180.0], "left"), _action("move", [0.0, -1.0], "drive")],
		[_action("attack", [180.0], "left"), _action("attack", [true], "right")],
		[_action("attack", [180.0], "left"), _action("attack", [INF], "right")],
		[_action("attack", [180.0], "left"), _action("move", [0.0], "drive")],
		[_action("attack", [180.0], "left"), {"callee": "eval", "arguments": [0], "module_id": "right"}],
		[_action("attack", [180.0], "left"), {"callee": "attack", "arguments": [0], "module_id": 3}],
		[_action("attack", [180.0], "left")],
		[],
	]
	for invalid in invalid_cases:
		var world := _world(_document())
		var actions: Array[Dictionary] = []
		actions.assign(invalid)
		_check(not world.validate_simultaneous("player", actions).is_ok(), "静态预检拒绝错误并行结构或资源冲突")
		_check(not world.request_simultaneous("player", actions).is_ok(), "正式提交同样拒绝无效整组")
		world.step()
		_check(world.tick_index == 1 and world.attack_traces.is_empty() and world.player.position == Vector2(5.5, 4.5), "被拒绝组没有任何部分执行")
		_check(world.get_object("left_alarm").health == 1 and not world.player.is_destroyed(), "拒绝不会产生冷却、伤害或警报副作用")
		_check(world.player.get_module("left").next_attack_tick == 0, "失败预检和提交都不消耗冷却")
		_check(world.request_attack("player", 180, "left").is_ok(), "被拒绝请求不占用 main 通道")
	var world := _world(_plain_document())
	var original := world.request_move("player", 0, 0.2)
	_check(not world.request_simultaneous("player", _pair_actions()).is_ok(), "已有普通动作时整组拒绝")
	world.step()
	_check(not original.value.is_finished() and world.attack_traces.is_empty(), "拒绝并行请求不取消或偷改已有普通动作")
	var two_drives := _plain_document()
	two_drives.player_spawn.modules[2].module_id = "movement"
	world = _world(two_drives)
	_check(not world.validate_simultaneous("player", [_action("move", [0.0, 1.0], "drive"), _action("move", [90.0, 1.0], "right")]).is_ok(), "即使不同驱动也不能对同一机身发出两个并行移动")
	_check(world.validate_simultaneous("player", [_action("move", [0.0, 100.0], "drive"), _action("attack", [0.0], "left")]).is_ok(), "预检不按当前占地提前否定未来的路径")


## 停止、单机取消、子动作失败都释放整组；外部观察者只收到一次终态。
func _test_cancel() -> void:
	for method in ["cancel_command", "cancel_move", "stop"]:
		var world := _world(_plain_document())
		var actions := _pair_actions()
		actions.append(_action("move", [0.0, 2.0], "drive"))
		var group: SimultaneousCommand = world.request_simultaneous("player", actions).value
		var notifications: Array[int] = []
		group.finished.connect(func(_group: SimulationCommand): notifications.append(1))
		var callback: SimulationCommand = world.request_tick_action("player", "attack", 90, "left").value
		var consistent_notifications: Array[bool] = []
		var inspect_cancelled := func(_command: SimulationCommand):
			var all_cancelled := group.state == SimulationCommand.State.CANCELLED and callback.state == SimulationCommand.State.CANCELLED
			for child in group.children:
				all_cancelled = all_cancelled and child.state == SimulationCommand.State.CANCELLED
			consistent_notifications.append(all_cancelled)
		callback.finished.connect(inspect_cancelled)
		for child in group.children:
			child.finished.connect(inspect_cancelled)
		if method == "stop":
			world.stop()
		else:
			world.call(method, "player")
		_check(group.state == SimulationCommand.State.CANCELLED and notifications.size() == 1, "取消路径结束整个组且仅通知一次")
		_check(callback.state == SimulationCommand.State.CANCELLED, "取消整组也清理待执行的 tick 输入句柄")
		_check(consistent_notifications.size() == 4 and not consistent_notifications.has(false), "任意 child 或 tick 取消回调都只能观察到整组和全部输入的终态")
		callback.finished.disconnect(inspect_cancelled)
		for child in group.children:
			child.finished.disconnect(inspect_cancelled)
		for child in group.children:
			_check(child.state == SimulationCommand.State.CANCELLED, "尚未开始的每个子句柄均取消")
		world.step()
		_check(world.player.position == Vector2(5.5, 4.5) and world.attack_traces.is_empty(), "取消以后 step 不执行残留动作")
		_check(world.request_move("player", 0, 0.1).is_ok(), "取消后 main 通道重新可用")
	var world := _world(_plain_document())
	var actions := _pair_actions()
	actions.append(_action("move", [0.0, 2.0], "drive"))
	var group: SimultaneousCommand = world.request_simultaneous("player", actions).value
	world.step()
	world.player.get_module("drive").apply_damage(1)
	world.step()
	_check(group.state == SimulationCommand.State.CANCELLED, "长动作能力失效传播为整组失败")
	var failed_position := world.player.position
	world.step()
	_check(world.player.position == failed_position and world.attack_traces.is_empty(), "失败后的组不会继续移动或重播已完成武器动作")
	_check(world.request_attack("player", 0, "right").is_ok(), "失败组释放通道，剩余可用模块可接受显式新请求")


## main 并行块保持已有优先级，tick 的广播重叠共享真实模块冷却，不能追加同帧伤害。
func _test_tick_overlap() -> void:
	var world := _world(_plain_document())
	world.request_tick_action("player", "attack", 90)
	world.request_simultaneous("player", _pair_actions())
	world.step()
	_check(world.attack_traces.size() == 2, "回调广播不能使并行双近战每模块重复出手")
	_check(world.attack_traces[0].to.x < world.attack_traces[0].from.x and world.attack_traces[1].to.x > world.attack_traces[1].from.x, "main 并行动作方向先于 tick 回调生效")
	var document := _plain_document()
	document.player_spawn.modules[1].module_id = "shooting"
	document.player_spawn.modules[2].module_id = "shooting"
	world = _world(document)
	world.request_tick_action("player", "shoot", 90)
	world.request_simultaneous("player", [_action("shoot", [180.0], "left"), _action("shoot", [0.0], "right")])
	world.step()
	_check(world.projectiles.size() == 2, "并行射击加回调广播只生成两枚弹丸")
	_check(world.player.get_module("left").next_shoot_tick == 11 and world.player.get_module("right").next_shoot_tick == 11, "并行不更改每个射击模块的冷却时钟")


## 弹丸与近战共用伤害提交阶段；距离导致跨 tick 命中时不能误判为安全并行。
func _test_projectile_pairs() -> void:
	var document := _document()
	document.player_spawn.modules[1].module_id = "shooting"
	document.player_spawn.modules[2].module_id = "shooting"
	document.objects[1].position.x = 7.5
	var world := _world(document)
	world.request_simultaneous("player", [_action("shoot", [180.0], "left"), _action("shoot", [0.0], "right")])
	for unused in 2:
		world.step()
	_check(world.get_object("left_alarm").health == 0 and world.get_object("right_alarm").health == 0, "等距双向弹丸在同 tick 造成双侧伤害")
	_check(not world.player.is_destroyed() and world.get_object("exit").unlocked, "真正同 tick 命中的弹丸同样可解除警报")
	document.objects[1].position.x = 8.5
	world = _world(document)
	world.request_simultaneous("player", [_action("shoot", [180.0], "left"), _action("shoot", [0.0], "right")])
	for unused in 2:
		world.step()
	_check(world.player.is_destroyed() and world.failure_reason.contains("同时摧毁"), "同时发射但不同 tick 抵达不能绕过联动警报")


## 类型解析严格验证成对引用和耐久，保留未知扩展字段及旧机关规则。
func _test_pair_validation() -> void:
	var document := _document()
	_check(MapCodec.validate(document, _content, true).is_ok(), "合法 reciprocal paired_alarm 和安全门依赖可通过")
	for invalid: Variant in ["missing", "left_alarm", "exit", "player", 3, true, ""]:
		var bad := document.duplicate_document()
		bad.objects[0].properties.partner_id = invalid
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "成对警报拒绝自引用、缺失、错类型或无效引用")
	var asymmetric := document.duplicate_document()
	asymmetric.objects.append({"id": "third", "type": "paired_alarm", "position": {"x": 2.5, "y": 2.5}, "properties": {"max_health": 1, "partner_id": "right_alarm"}})
	asymmetric.objects[0].properties.partner_id = "third"
	_check(not MapCodec.validate(asymmetric, _content, true).is_ok(), "仅有单向链条的警报拒绝载入")
	for invalid: Variant in [false, 0, -1, INF, "1"]:
		var bad := document.duplicate_document()
		bad.objects[0].properties.max_health = invalid
		_check(not MapCodec.validate(bad, _content, true).is_ok(), "联动警报耐久必须是有限正数")
	var extra := document.duplicate_document()
	extra.objects[0].properties.extra_note = {"future": [1, 2]}
	var decoded := MapCodec.from_dict(extra.to_dict(), _content, true)
	_check(decoded.is_ok() and decoded.value.objects[0].properties.extra_note.future == [1, 2], "format_version 1 和未知机关扩展字段保持兼容")


## 出生点左侧 2 格、右侧 3 格，半格偏移的近战在右侧射程端点恰好命中。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "simultaneous_fixture"
	document.display_name = "并行动作夹具"
	document.width = 12
	document.height = 8
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 5.5, "y": 4.5}, "modules": [_module("drive", "movement", 0), _module("left", "melee", -0.5), _module("right", "melee", 0.5)]}
	document.objects = [
		{"id": "left_alarm", "type": "paired_alarm", "position": {"x": 3.5, "y": 4.5}, "properties": {"max_health": 1, "partner_id": "right_alarm"}},
		{"id": "right_alarm", "type": "paired_alarm", "position": {"x": 8.5, "y": 4.5}, "properties": {"max_health": 1, "partner_id": "left_alarm"}},
		{"id": "exit", "type": "security_gate", "position": {"x": 5.5, "y": 2.5}, "properties": {"required_object_ids": ["left_alarm", "right_alarm"]}},
	]
	return document


## 无机关的同结构地图供纯调度测试使用，避免报警终止掩盖长动作生命周期。
func _plain_document() -> MapDocument:
	var document := _document()
	document.objects = []
	return document


## 生成一个有明确实例名的模块，名称与内容类型保持分离。
func _module(id: String, kind: String, offset_x: float) -> Dictionary:
	return {"id": id, "module_id": kind, "offset": {"x": offset_x, "y": 0}}


## 构造并行动作输入；附带行列不会被当成执行参数或改写。
func _action(callee: String, arguments: Array, module_id: String = "") -> Dictionary:
	return {"callee": callee, "arguments": arguments, "module_id": module_id, "line": 3, "column": 5}


## 生产能力下的双方向近战，不使用 tick 回调模拟新语法。
func _pair_actions() -> Array[Dictionary]:
	return [_action("attack", [180.0], "left"), _action("attack", [0.0], "right")]


## 通过正式验证及工厂建立每次独立运行，失败夹具也计入汇总。
func _world(document: MapDocument) -> SimulationWorld:
	var result := SimulationWorld.create(document, _content)
	if not _check(result.is_ok(), "底层夹具可运行：%s" % result.errors):
		return null
	return result.value


## 累计明确断言，任何引擎异常仍由外层 test.ps1 视为失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
