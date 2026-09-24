extends SceneTree
## 雷达事件运行时回归：真实世界查询、固定步调度、快照作用域及停止重试边界。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _calls := PackedStringArray(["move", "attack", "shoot"])


class ObservedWorld extends SimulationWorld:
	## 仅记录公开查询次数；正常结果仍通过正式几何和存活判断产生。
	var scan_count := 0
	var invalid_scan := false

	## 错误返回分支单独验证语言边界，常规测试始终调用真实世界实现。
	func query_scan(machine_id: String, module_id: String = "") -> DataResult:
		scan_count += 1
		if invalid_scan:
			return DataResult.success({"position": Vector2.ZERO})
		return super.query_scan(machine_id, module_id)


## 延迟到脚本和资源初始化完成，所有状态只存在于独立内存世界。
func _initialize() -> void:
	_run.call_deferred()


## 汇总启动、等待、消失、作用域、能力和兼容性；脚本错误由外部驱动另行检查。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "雷达事件加载正式内容"):
		quit(1)
		return
	_test_start_and_fixed_steps()
	_test_main_and_tick_order()
	_test_visibility_and_liveness()
	_test_snapshots_and_scopes()
	_test_preflight_and_source_loss()
	_test_cancel_and_retry()
	_test_random_and_legacy_tick()
	print("雷达事件运行时回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 全局先初始化，事件首帧先于 main；持续移动期间每次 step 只扫描和推进一次。
func _test_start_and_fixed_steps() -> void:
	var world := _world()
	var enemy := _add_enemy(world, "enemy", Vector2(18.5, 14.5))
	var runner := _runner("variable target=null\nconstant before=target\nvariable first=0\nsensor.onDetected { EnemyPosition -> target }\nmain(){first=target.Distance\nmove(target.Angle(),1)}", world)
	var ticks: Array[int] = []
	world.tick_completed.connect(func(tick: int): ticks.append(tick))
	_check(runner.start().is_ok(), "事件在 main 首次读取目标之前提供快照")
	_check(world.tick_index == 0 and ticks.is_empty() and world.scan_count == 1, "start 仅刷新一次，不推进世界或发出 tick 通知")
	_check(_value(runner, "before") == null and _value(runner, "first") == 6.0, "全局初始化先于事件，main 读取事件刷新后的 Distance")
	_check(world.player.position == Vector2(12.5,14.5), "start 只提交首动作，没有隐藏移动")
	var old_snapshot: Dictionary = _value(runner, "target")
	_check(world.request_move(enemy.id, 90, 1).is_ok(), "敌人通过真实移动命令改变位置")
	for index in 4:
		var observed_position := enemy.position
		var old_tick := world.tick_index
		runner.step()
		_check(world.tick_index == old_tick + 1 and world.scan_count == index + 2, "等待 main 移动时每 step 恰好扫描一次和推进一个 tick：%d" % index)
		_check(_value(runner, "target").position == observed_position, "事件读取本帧世界推进之前的目标位置：%d" % index)
	_check(enemy.position.y < 14.5 and old_snapshot.position == Vector2(18.5,14.5), "真实移动更新新目标快照，原快照不随世界变更")
	_check(ticks == [1,2,3,4], "事件没有制造额外模拟 tick")
	runner.cancel()


## 每帧先刷新再派发 main 和 tick，空 main 及 main 完成后都继续监听。
func _test_main_and_tick_order() -> void:
	var world := _world()
	var enemy := _add_enemy(world, "enemy", Vector2(18.5,14.5))
	var runner := _runner("variable target=null\nvariable after=0\nsensor.onDetected { EnemyPosition -> target }\nmain(){move(0,0)\nafter=target.Position.y\nmove(0,0)}\ntick(){if(target!=null){gun.shoot(target.Angle())}}", world)
	var directions: Array[Vector2] = []
	world.shot_finished.connect(func(command: ShootCommand): directions.append(command.direction))
	_check(runner.start().is_ok(), "事件与 tick 可以共享只读目标")
	enemy.position = Vector2(12.5,8.5)
	runner.step()
	_check(not directions.is_empty() and directions[0].is_equal_approx(Vector2.UP), "tick 读取本 step 刷新后的目标角度")
	enemy.position = Vector2(12.5,9.5)
	runner.step()
	_check(_value(runner, "after") == 9.5, "下一个 main 动作前的赋值读取本 step 新快照")
	_check(runner.state == ProgramRunner.State.RUNNING and world.tick_index == 2 and world.scan_count == 3, "main 结束仍保留事件与 tick，不重复刷新")
	runner.cancel()
	var idle := _runner("variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){}", _world())
	_check(idle.start().is_ok() and idle.state == ProgramRunner.State.RUNNING, "仅事件和空 main 也保持运行")
	idle.step()
	_check(idle.world.tick_index == 1 and _value(idle, "target") == null, "事件没有目标仍按固定步推进，不伪造完成")
	idle.cancel()


## 出现、失去、再次可见和整机毁灭都来自真实几何、范围和部件状态。
func _test_visibility_and_liveness() -> void:
	var world := _world()
	var runner := _runner("variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){}", world)
	_check(runner.start().is_ok() and _value(runner, "target") == null, "无敌人时事件写 null")
	var enemy := _add_enemy(world, "enemy", Vector2(18.5,14.5))
	runner.step()
	_check(_value(runner, "target").position == enemy.position, "目标在运行后加入会在下一固定步出现")
	world.document.set_tile(Vector2i(15,14), "wall")
	runner.step()
	_check(_value(runner, "target") == null, "墙壁遮挡立即清除旧目标，避免残留锁定")
	world.document.set_tile(Vector2i(15,14), "iron_bars")
	runner.step()
	_check(_value(runner, "target") is Dictionary, "铁栅栏不阻断雷达事件")
	enemy.position = Vector2(44.5,14.5)
	runner.step()
	_check(_value(runner, "target").distance == 32.0, "真实雷达范围端点仍可被事件检测")
	enemy.position.x += 0.01
	runner.step()
	_check(_value(runner, "target") == null, "离开圆形范围后不保留旧快照")
	enemy.position = Vector2(18.5,14.5)
	runner.step()
	_check(_value(runner, "target") is Dictionary, "重新进入范围后恢复目标")
	enemy.get_module("body").apply_damage(100)
	runner.step()
	_check(_value(runner, "target") == null, "目标最后一个真实部件毁灭后清空全局目标")
	_check(world.tick_index == 7 and world.scan_count == 8, "所有可见性变化只在既有固定步刷新")
	runner.cancel()


## 事件只更新全局单元，main 的同名局部和此前复制的目标快照保持各自值。
func _test_snapshots_and_scopes() -> void:
	var world := _world()
	var enemy := _add_enemy(world, "enemy", Vector2(18.5,14.5))
	var runner := _runner("variable target=null\nvariable saved_x=0\nvariable local_value=0\nsensor.onDetected { EnemyPosition -> target }\nmain(){constant old=target\nvariable target=7\nmove(0,0)\nsaved_x=old.Position.x\nlocal_value=target\nmove(0,0)}", world)
	_check(runner.start().is_ok(), "事件目标允许被 main 局部同名变量遮蔽")
	runner.step()
	enemy.position = Vector2(20.5,14.5)
	runner.step()
	_check(_value(runner, "target").position.x == 20.5, "事件持续更新指定全局，不依赖当前局部作用域")
	_check(_value(runner, "local_value") == 7.0 and _value(runner, "saved_x") == 18.5, "事件不会改写局部遮蔽或常量保存的旧快照")
	var changed: Dictionary = _value(runner, "target")
	changed.position = Vector2.ZERO
	runner.step()
	_check(enemy.position == Vector2(20.5,14.5) and _value(runner, "target").position == enemy.position, "绑定快照不引用世界，下次事件得到独立的新快照")
	runner.cancel()


## 全树能力检查先于初始化、随机采样和任何动作，运行中的来源损毁也不能换用另一雷达。
func _test_preflight_and_source_loss() -> void:
	for source_name in ["missing", "drive", "sensor"]:
		var world := _world()
		if source_name == "sensor":
			world.player.get_module("sensor").apply_damage(100)
		var runner := _runner("variable target=null\n" + source_name + ".onDetected { EnemyPosition -> target }\nmain(){move(0,1)}", world)
		_check(not runner.start().is_ok() and runner.message.contains("第 2 行，第 1 列"), "无效事件雷达在首动作前给出事件位置：" + source_name)
		_check(world.tick_index == 0 and world.scan_count == 0 and world._commands.is_empty() and runner._globals == null, "事件能力失败不查询、不初始化、不排队动作：" + source_name)
	var invalid_later := _world()
	var invalid_runner := _runner("variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){move(0,1)}\nfunction unused(){missing.shoot(0)}", invalid_later)
	_check(not invalid_runner.start().is_ok() and invalid_later.scan_count == 0 and invalid_later._commands.is_empty(), "后续未调用函数非法时，完整 AST 预检阻止首次事件和动作")
	var world := _world(true)
	_add_enemy(world, "enemy", Vector2(18.5,14.5))
	var runner := _runner("variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){move(0,1)}", world)
	_check(runner.start().is_ok(), "多雷达时事件精确选择具名来源")
	runner.step()
	var position := world.player.position
	world.player.get_module("sensor").apply_damage(100)
	runner.step()
	_check(runner.state == ProgramRunner.State.FAILED and runner.message.contains("第 2 行，第 1 列"), "运行中来源毁灭在事件位置报错，不替换为仍存活的雷达")
	_check(world.tick_index == 1 and world.player.position == position and world._commands.is_empty(), "事件失败撤销等待中的主动作，不多推进 tick")
	var malformed := _world()
	malformed.invalid_scan = true
	var bad := _runner("variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){move(0,1)}", malformed)
	_check(not bad.start().is_ok() and bad.message.contains("onDetected") and malformed._commands.is_empty(), "事件同 scan 一样拒绝不完整快照且不派发动作")


## 不调用 step 就冻结，取消和外部终态不触发额外扫描；重试新建独立绑定与世界。
func _test_cancel_and_retry() -> void:
	var source := "variable target=null\nsensor.onDetected { EnemyPosition -> target }\nmain(){move(0,1)}"
	var world := _world()
	var enemy := _add_enemy(world, "enemy", Vector2(18.5,14.5))
	var runner := _runner(source, world)
	runner.start()
	var snapshot: Dictionary = _value(runner, "target")
	enemy.position.x += 1.0
	_check(world.tick_index == 0 and world.scan_count == 1 and _value(runner, "target").position == snapshot.position, "暂停期间不派发 step，事件与世界都冻结")
	runner.cancel()
	for unused in 3:
		runner.step()
	_check(runner.state == ProgramRunner.State.CANCELLED and world.tick_index == 0 and world.scan_count == 1 and world._commands.is_empty(), "取消后重复 step 不刷新事件、不执行原动作")
	var retried_world := _world()
	var retried := _runner(source, retried_world)
	_check(retried.start().is_ok() and _value(retried, "target") == null and retried_world.tick_index == 0, "新 runner 重试不继承旧目标或时钟")
	_check(_value(runner, "target").position == snapshot.position, "新运行初始化不修改旧 runner 的快照")
	retried_world.cancel_command("player")
	retried.step()
	_check(retried.state == ProgramRunner.State.CANCELLED and retried_world.scan_count == 1 and retried_world.tick_index == 0, "外部取消命令后先消费终态，不额外刷新或推进")
	var completed_world := _world()
	var completed := _runner(source.replace("move(0,1)", "move(0,0)"), completed_world)
	completed.start()
	completed_world.step()
	completed.step()
	_check(completed_world.scan_count == 1 and completed_world.tick_index == 1, "外部已完成命令只消费终态，不在同次 step 扫描或推进")
	completed.step()
	_check(completed_world.scan_count == 2 and completed_world.tick_index == 2, "下一正常固定步恢复事件刷新")
	completed.cancel()


## 无事件旧 tick 调度不变；事件查询和预检不消费 Runner 私有随机序列。
func _test_random_and_legacy_tick() -> void:
	var globals := "variable target=null\nvariable sampled=random()\n"
	var body := "main(){move(randomInt(0,0),0)\nsampled=random()\nmove(0,0)}\ntick(){gun.shoot(randomInt(0,359))}"
	var events := _runner(globals + "sensor.onDetected { EnemyPosition -> target }\n" + body, _world(), 8123)
	var legacy := _runner(globals + body, _world(), 8123)
	_check(events.start().is_ok() and legacy.start().is_ok(), "相同种子下事件与旧 tick 程序均可启动")
	_check(_value(events, "sampled") == _value(legacy, "sampled"), "事件预检和首次查询不消费全局随机初始化样本")
	for unused in 5:
		events.step()
		legacy.step()
	_check(events.world.tick_index == 5 and legacy.world.tick_index == 5, "旧 tick 和事件 tick 使用相同单步时钟")
	_check(_value(events, "sampled") == _value(legacy, "sampled") and events._random.state == legacy._random.state, "事件刷新不改变 main 与 tick 的随机采样顺序")
	_check((legacy.world as ObservedWorld).scan_count == 0 and (events.world as ObservedWorld).scan_count == 6, "无事件的旧程序不引入查询，事件程序按启动加每帧刷新")
	events.cancel()
	legacy.cancel()


## 显式开放已有语法和尾部独立事件权限；夹具编译失败始终计入断言。
func _runner(source: String, world: SimulationWorld, seed_value: Variant = null) -> ProgramRunner:
	var parsed := ProgramParser.parse(source, _calls, true, true, true, true, true, true, true, true, true, true, true, true)
	_check(parsed.is_ok(), "事件夹具源码可编译：" + str(parsed.errors))
	return ProgramRunner.create(parsed.value as ProgramAst.ProgramNode, world, seed_value)


## 真实创建后只包裹查询计数；没有敌人控制器或对象需要复制，动作仍由正式世界执行。
func _world(second_radar: bool = false) -> ObservedWorld:
	var document := MapDocument.new()
	document.width = 64
	document.height = 32
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x,y), "floor")
	document.player_spawn = {"position":{"x":12.5,"y":14.5}, "modules":[
		_module("sensor", "radar", Vector2.ZERO),
		_module("drive", "movement", Vector2(0,.5)),
		_module("gun", "shooting", Vector2(.5,0)),
	]}
	if second_radar:
		document.player_spawn.modules.append(_module("backup", "radar", Vector2(-.5,0)))
	var created := SimulationWorld.create(document, _content)
	_check(created.is_ok(), "事件夹具通过真实地图与装配校验：" + str(created.errors))
	var base: SimulationWorld = created.value
	var world := ObservedWorld.new()
	world.document = base.document
	world.player = base.player
	world.machines = base.machines
	world._content = _content
	return world


## 敌人使用正式工厂和世界注册；测试可提交真实移动，查询仍检查实际存活部件。
func _add_enemy(world: SimulationWorld, id: String, position: Vector2) -> MachineInstance:
	var created := MachineFactory.create_machine(id, {"position":{"x":position.x,"y":position.y}, "modules":[_module("body", "movement", Vector2.ZERO)]}, world.document, _content, ModuleBehaviorRegistry.create_default())
	_check(created.is_ok(), "事件测试敌人可构造：" + str(created.errors))
	_check(world.add_machine(created.value).is_ok(), "事件测试敌人通过正式世界注册")
	return created.value as MachineInstance


## 生成当前地图格式的具名模块描述，不改变共享内容定义。
func _module(id: String, kind: String, offset: Vector2) -> Dictionary:
	return {"id":id, "module_id":kind, "offset":{"x":offset.x,"y":offset.y}}


## 只读取得本次运行的全局绑定，便于核对行为与作用域隔离。
func _value(runner: ProgramRunner, name: String) -> Variant:
	return runner._globals.resolve(name).value


## 累计独立断言，失败给出具体语义并让驱动返回非零状态。
func _check(condition: bool, reason: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
	return condition
