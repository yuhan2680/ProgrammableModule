extends SceneTree
## 只读景物约束回归：检查世界锚定、疏密层次和对真实模拟的隔离，不依赖 GPU 或玩家存档。

const RunScript = preload("res://scripts/minigame/shark_cave_run.gd")
const CanvasScript = preload("res://scripts/minigame/shark_cave_canvas.gd")

var _checks := 0
var _failures := 0


## 等引擎初始化完成后执行独立回归，并把失败数转换为退出状态。
func _initialize() -> void:
	_run.call_deferred()


## 不创建场景窗口，只验证可以观察到的景物规则和模拟不受影响的边界。
func _run() -> void:
	_test_distribution_and_anchoring()
	_test_scroll_and_seed_replay()
	_test_render_queries_do_not_change_simulation()
	_test_visual_departure_is_independent()
	_test_ocean_intro_handoff()
	print("鲨鱼前景景物回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 大量固定种子均有低草为主、少量高草和珊瑚，植株必须生根于真实洞底且留足通道。
func _test_distribution_and_anchoring() -> void:
	var lows := 0
	var highs := 0
	var corals := 0
	var populated_scenes := 0
	var canvas := CanvasScript.new()
	canvas.menu_mode = false
	for seed_value in 64:
		var run := RunScript.new()
		run.start(seed_value, false)
		canvas.run = run
		var specs := canvas.foreground_plant_specs()
		_check(specs.size() <= 24, "种子%d景物查询只保留可见区有限数量" % seed_value)
		if specs.size() >= 8:
			populated_scenes += 1
		var geometry_valid := true
		var range_valid := true
		for spec in specs:
			var x := float(spec.world_x)
			var floor_y := run.floor_at(x)
			var gap := floor_y - run.ceiling_at(x)
			geometry_valid = geometry_valid and is_equal_approx(float(spec.root_y), floor_y) and float(spec.height) <= gap * 0.45 + 0.0001
			if spec.kind == "kelp":
				highs += 1
				range_valid = range_valid and float(spec.height) >= 35.0 and float(spec.height) <= 60.0
			else:
				lows += 1
				range_valid = range_valid and float(spec.height) >= 10.0 and float(spec.height) <= 22.0
				if spec.kind == "coral":
					corals += 1
		_check(geometry_valid, "种子%d所有根部贴洞底且不超过洞高45%%" % seed_value)
		_check(range_valid, "种子%d高低植株符合高度范围" % seed_value)
	_check(populated_scenes >= 60, "多数视野包含足够的矮植被，不出现大面积空景")
	_check(highs > 20 and highs < lows / 3, "高海草确实存在，但数量明显少于矮植株")
	_check(corals > 30 and corals < lows / 2, "珊瑚形成少量颜色点缀，不取代海草主体")
	canvas.free()


## 滚动只改变观察窗口，相同世界位置的高度、根部与种类不闪变；重放同种子可恢复同一景观。
func _test_scroll_and_seed_replay() -> void:
	var run := RunScript.new()
	run.start(731, false)
	var canvas := CanvasScript.new()
	canvas.menu_mode = false
	canvas.run = run
	var initial := canvas.foreground_plant_specs()
	var by_position := {}
	for spec in initial:
		by_position[spec.world_x] = spec
	run.advance(0.5, 0.0)
	var shared := 0
	var stable := true
	for spec in canvas.foreground_plant_specs():
		if by_position.has(spec.world_x):
			shared += 1
			stable = stable and by_position[spec.world_x] == spec
	_check(shared >= 6 and stable, "滚动后的共同世界位置保持相同植株，不随视口重新随机")
	run.pause()
	var paused := canvas.foreground_plant_specs()
	var elapsed := run.elapsed
	run.advance(0.8, 1.0)
	_check(run.elapsed == elapsed and canvas.foreground_plant_specs() == paused, "暂停保持模拟时间及植物锚点")
	run.start(731, false)
	_check(canvas.foreground_plant_specs() == initial, "同种子重新开始恢复原有植物")
	run.start(732, false)
	_check(canvas.foreground_plant_specs() != initial, "不同种子形成不同植株分布和外观")
	# 真实洞穴远处变窄后仍按当前位置洞高限制前景高度，不沿用初始直道的宽松尺寸。
	run.distance = 9000.0
	run._ensure_terrain()
	var capped := true
	for spec in canvas.foreground_plant_specs():
		capped = capped and float(spec.height) <= (run.floor_at(float(spec.world_x)) - run.ceiling_at(float(spec.world_x))) * 0.45 + 0.0001
	_check(capped, "远处窄洞里的高海草仍保留至少55%%通行高度")
	canvas.free()


## 反复查询和改变装饰时间既不动当前状态，也不改变未来地形、章鱼或全局随机序列。
func _test_render_queries_do_not_change_simulation() -> void:
	var observed := RunScript.new()
	var control := RunScript.new()
	observed.start(901)
	control.start(901)
	var canvas := CanvasScript.new()
	canvas.menu_mode = false
	canvas.run = observed
	var before := _snapshot(observed)
	seed(854312)
	var expected := randi()
	seed(854312)
	for index in 120:
		canvas.decorative_time = float(index)
		canvas.foreground_plant_specs()
	_check(_snapshot(observed) == before, "重复景物查询不修改分数、洞壁、章鱼或运行状态")
	_check(randi() == expected, "景物查询不消耗全局随机数")
	for frame in 1200:
		var world_x := observed.distance + RunScript.SHARK_X + 24.0
		var target := (observed.ceiling_at(world_x) + observed.floor_at(world_x)) * 0.5
		var stopping := signf(observed.vertical_velocity) * observed.vertical_velocity * observed.vertical_velocity / (2.0 * RunScript.BRAKING)
		var error := target - observed.shark_y - stopping
		var axis := signf(error) if absf(error) > 3.0 else 0.0
		observed.advance(1.0 / 60.0, axis)
		control.advance(1.0 / 60.0, axis)
		canvas.foreground_plant_specs()
	_check(_snapshot(observed) == _snapshot(control), "有无前景查询的真实模拟保持一致，未来洞壁和章鱼随机序列不受影响")
	canvas.free()


## 失败离场从真实位置开始并平滑向右结束，视觉查询不得恢复模拟或移动冻结的前景植物。
func _test_visual_departure_is_independent() -> void:
	var run := RunScript.new()
	run.start(517)
	run.advance(1.0, -1.0)
	_check(run.state == RunScript.State.OVER, "离场验证使用真实撞壁后的终局")
	var canvas := CanvasScript.new()
	canvas.menu_mode = false
	canvas.run = run
	canvas.departure_active = true
	var before := _snapshot(run)
	var plants := canvas.foreground_plant_specs()
	var start := canvas.departure_shark_position()
	_check(start == Vector2(RunScript.SHARK_X, run.shark_y), "离场第一帧衔接真实撞壁坐标")
	var last_x := start.x
	var moves_right := true
	for frame in 70:
		canvas.departure_progress = float(frame) / 69.0
		canvas.departure_time = float(frame) / 60.0
		var position := canvas.departure_shark_position()
		moves_right = moves_right and position.x >= last_x
		last_x = position.x
	_check(moves_right and last_x > RunScript.WORLD_SIZE.x + 50.0, "离场连续向右游至完全离屏")
	_check(_snapshot(run) == before and canvas.foreground_plant_specs() == plants, "离场动画不修改终局、章鱼计时或前景锚点")
	canvas.free()


## 入场从无顶壁海域接近洞口，最后逐像素对齐真实初始画面，模型和植物随机状态始终不变。
func _test_ocean_intro_handoff() -> void:
	var run := RunScript.new()
	run.start(380)
	run.pause()
	var before := _snapshot(run)
	var canvas := CanvasScript.new()
	canvas.menu_mode = false
	canvas.run = run
	canvas.intro_active = true
	var open_ocean := true
	for x in range(0, 641, 16):
		var bounds := canvas.intro_cave_bounds_at(float(x))
		open_ocean = open_ocean and is_zero_approx(bounds.x) and bounds.y > 300.0 and bounds.y < 350.0
	_check(open_ocean, "入场起点是无岩顶的开阔水域，保留可见起伏海床")
	_check(canvas.foreground_plant_specs().size() >= 6, "开阔海床包含沿视觉世界锚定的前景植被")
	canvas.intro_progress = 0.5
	canvas.intro_time = 2.0
	_check(is_zero_approx(canvas.intro_cave_bounds_at(0).x) and canvas.intro_cave_bounds_at(640).x > 0.0, "入场中段洞口从右边进入画面，左侧仍为开阔水域")
	var monotonic := true
	var last_distance := -INF
	for frame in 61:
		canvas.intro_progress = float(frame) / 60.0
		canvas.intro_time = canvas.intro_progress * 4.0
		canvas.decorative_time = canvas.intro_time
		var distance := canvas.intro_view_distance()
		monotonic = monotonic and distance >= last_distance
		last_distance = distance
		canvas.intro_shark_position()
		canvas.foreground_plant_specs()
	_check(monotonic and is_equal_approx(last_distance, run.distance), "入场观察距离持续前进并精确接回模型初始距离")
	var aligned := true
	for x in range(0, 641, 8):
		var bounds := canvas.intro_cave_bounds_at(float(x))
		aligned = aligned and is_equal_approx(bounds.x, run.ceiling_at(float(x))) and is_equal_approx(bounds.y, run.floor_at(float(x)))
	_check(aligned, "入场终点整个可见洞壁都与真实初始模型边界一致")
	_check(canvas.intro_shark_position() == Vector2(RunScript.SHARK_X, run.shark_y), "控制交接时鲨鱼没有位置跳变")
	var last_plants := canvas.foreground_plant_specs()
	var last_clock := canvas.foreground_animation_time()
	canvas.intro_active = false
	_check(canvas.foreground_plant_specs() == last_plants, "交接前后植物世界位置、根部和外观完全相同")
	_check(is_equal_approx(last_clock, 4.0) and canvas.foreground_animation_time() == last_clock and is_zero_approx(run.elapsed), "海草使用连续表现时钟，交接到零计时模型时不回跳")
	_check(_snapshot(run) == before, "全部入场视觉查询不推进模型、计分、地形或章鱼")
	canvas.free()


## 深复制对外可观察状态，避免比较时字典共享掩盖意外写入。
func _snapshot(run: RefCounted) -> Dictionary:
	return {"state": run.state, "distance": run.distance, "elapsed": run.elapsed, "score": run.score,
		"shark_y": run.shark_y, "velocity": run.vertical_velocity, "speed": run.scroll_speed,
		"terrain": run.cave_points.duplicate(), "octopuses": run.octopuses.duplicate(true),
		"visual_seed": run.visual_seed, "failure": run.fail_reason}


## 汇总约束失败后继续检查，便于一次运行定位全部回归问题。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
