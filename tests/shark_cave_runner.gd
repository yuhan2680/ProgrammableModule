extends SceneTree
## 鲨鱼彩蛋的纯模型回归，不创建界面、不读取玩家文件或主游戏状态。

const CaveRun = preload("res://scripts/minigame/shark_cave_run.gd")

## 测试记录真实候选尝试，不更改生成规则或补偿被窄水道过滤的章鱼。
class SpawnAudit extends CaveRun:
	var attempts: Array[float] = []

	## 先记录槽位再调用正式生成，用于比较各难度阶段的实际跳过率。
	func _spawn_octopus(world_x: float, side: int, octopus_scale: float) -> void:
		attempts.append(world_x)
		super._spawn_octopus(world_x, side, octopus_scale)


## 概率测试仅计数成功抽签，不放入实体，隔离出生地形过滤和三只上限。
class TunaRollAudit extends CaveRun:
	var successful_rolls: int = 0

	## 由正式五十分抽签入口调用，测试只记录选中次数，避免活鱼上限影响样本。
	func _spawn_tuna() -> void:
		successful_rolls += 1


## 自然长游计数实际抽中后通过空间过滤的来鱼，不改变正式抽签或出生行为。
class TunaLiveAudit extends CaveRun:
	var spawn_attempts: int = 0
	var spawned: int = 0

	## 分别记录候选与真实加入的实体，避免只验证概率却遗漏过强的通路过滤。
	func _spawn_tuna() -> void:
		spawn_attempts += 1
		var before := tunas.size()
		super._spawn_tuna()
		spawned += tunas.size() - before


var _checks: int = 0
var _failures: int = 0
var _tuna_route_memory: Dictionary = {}


## 引擎准备后统一执行模型检查，退出码与失败数保持一致。
func _initialize() -> void:
	_run.call_deferred()


## 验证独立随机、运动终态和大量洞穴的几何可通过性。
func _run() -> void:
	_test_ready_and_safe_start()
	_test_random_isolation_and_replay()
	_test_movement_and_time_steps()
	_test_collisions()
	_test_pause_restart_and_score()
	_test_generated_caves()
	_test_first_bend_requires_steering()
	_test_speed_steps()
	_test_visual_seed()
	_test_octopus_generation()
	_test_narrow_water_rejection()
	_test_octopus_phases_and_collision()
	_test_high_speed_ink_avoidance()
	_test_tuna_probability_and_rng()
	_test_tuna_spawn_safety()
	_test_tuna_motion_and_collision()
	_test_high_speed_tuna_avoidance()
	_test_minimum_water_tuna_avoidance()
	_test_long_run()
	_test_octopus_long_run()
	print("鲨鱼洞穴模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 初始菜单不推进，并为开始后的数秒预留宽阔平直通道。
func _test_ready_and_safe_start() -> void:
	var run := CaveRun.new()
	_check(run.state == CaveRun.State.READY and run.score == 0 and run.distance == 0.0, "新实例待机且没有分数")
	var preview := run.cave_points.duplicate()
	run.advance(1.0, 1.0)
	run.pause()
	run.resume()
	_check(run.state == CaveRun.State.READY and run.cave_points == preview and run.elapsed == 0.0, "未开始时推进和暂停无副作用")
	run.start(12)
	_check(run.state == CaveRun.State.RUNNING, "开始进入运行状态")
	_check(run.shark_rect() == Rect2(Vector2(90.0, 169.0), Vector2(44.0, 22.0)), "碰撞身体采用固定屏幕中心和半尺寸")
	var safe := true
	for x in range(0, int(CaveRun.SAFE_RUNWAY) + 1, 4):
		safe = safe and is_equal_approx(run.ceiling_at(float(x)), 58.0) and is_equal_approx(run.floor_at(float(x)), 302.0)
	_check(safe, "前720像素为244像素高的安全直道")
	for index in 40:
		run.advance(0.1, 0.0)
	_check(run.state == CaveRun.State.RUNNING and run.shark_y == 180.0 and run.elapsed > 3.99, "开始四秒不操作不会突然碰撞")


## 固定种子可重放，普通开始独立随机，查询与推进都不改变全局随机序列。
func _test_random_isolation_and_replay() -> void:
	seed(913527)
	var expected_global := randi()
	seed(913527)
	var first := CaveRun.new()
	first.start(127)
	var second := CaveRun.new()
	second.start(127)
	_check(first.cave_points == second.cave_points, "同种子生成相同初始地形")
	for frame in 1800:
		var direction := sin(float(frame) * 0.005) * 0.1
		first.advance(1.0 / 60.0, direction)
		second.advance(1.0 / 60.0, direction)
		first.ceiling_at(first.distance + 200.0)
		first.floor_at(first.distance + 400.0)
	_check(_snapshot(first) == _snapshot(second), "同种子同输入得到相同运动、分数与地形")
	_check(randi() == expected_global, "新建、随机化、推进和只读查询不消耗全局随机")
	second.start(128)
	first.start(127)
	_check(first.cave_points != second.cave_points, "不同种子可生成不同洞穴")
	while first.cave_points[-1].x < 2400.0:
		first._append_point()
	var original := first.cave_points.duplicate()
	first.start()
	while first.cave_points[-1].x < 2400.0:
		first._append_point()
	var changed := first.cave_points != original
	first.start()
	while first.cave_points[-1].x < 2400.0:
		first._append_point()
	_check(changed or first.cave_points != original, "正式重开通过独立随机源产生新洞穴")


## 输入渐进加速、松手制动，帧长拆分与低帧率均不能绕过小步运动。
func _test_movement_and_time_steps() -> void:
	var run := CaveRun.new()
	run.start(1)
	run.advance(0.05, -1.0)
	_check(run.shark_y < 180.0 and run.vertical_velocity < 0.0, "上键向上游动")
	run.advance(0.1, 1.0)
	_check(run.vertical_velocity > 0.0, "下键可以反向控制")
	run.advance(0.2, 0.0)
	var stopped_y := run.shark_y
	_check(is_zero_approx(run.vertical_velocity), "松手制动到静止")
	run.advance(0.1, 0.0)
	_check(is_equal_approx(run.shark_y, stopped_y), "无输入时不会持续漂移或下坠")
	var before := _snapshot(run)
	for invalid_delta in [-1.0, 0.0, INF, NAN]:
		run.advance(invalid_delta, 1.0)
	_check(_snapshot(run) == before, "无效时间不污染运行状态")
	run.advance(0.01, NAN)
	_check(is_finite(run.shark_y) and is_finite(run.vertical_velocity), "无效方向安全视为松手")
	var coarse := CaveRun.new()
	var fine := CaveRun.new()
	coarse.start(271)
	fine.start(271)
	coarse.advance(0.5, 0.1)
	for frame in 60:
		fine.advance(CaveRun.MAX_STEP, 0.1)
	_check(is_equal_approx(coarse.distance, fine.distance) and is_equal_approx(coarse.shark_y, fine.shark_y), "一次长帧与相同120Hz小步保持一致")
	var capped := CaveRun.new()
	capped.start(1)
	capped.advance(1000000.0, 0.0)
	_check(capped.elapsed <= CaveRun.MAX_FRAME_DELTA + 0.00001 and capped.state == CaveRun.State.RUNNING, "异常长卡顿最多补算一秒，不瞬间快进")
	_check(capped.scroll_speed >= CaveRun.INITIAL_SPEED and capped.scroll_speed <= CaveRun.MAX_SPEED, "推进速度保持难度范围")


## 上下岩壁、鼻端及身体覆盖范围内的尖点全部使用同一真实边界判定。
func _test_collisions() -> void:
	for direction in [-1.0, 1.0]:
		var run := CaveRun.new()
		run.start(19)
		run.advance(1.0, direction)
		_check(run.state == CaveRun.State.OVER, "持续向%s会在一秒内撞壁" % ("上" if direction < 0.0 else "下"))
		_check(run.elapsed < 1.0 and run.vertical_velocity == 0.0, "撞壁的小步立即结束，不继续穿行")
	var nose := CaveRun.new()
	nose.start(3)
	for index in nose.cave_points.size():
		var point: Vector3 = nose.cave_points[index]
		if point.x == 128.0:
			point.y = 176.0
			nose.cave_points[index] = point
	_check(nose.ceiling_at(CaveRun.SHARK_X) < nose.shark_y - CaveRun.SHARK_HALF_SIZE.y, "尖点夹具在中心仍有空间")
	nose.advance(CaveRun.MAX_STEP, 0.0)
	_check(nose.state == CaveRun.State.OVER, "中心未触壁但鼻端覆盖尖点仍会失败")
	var bottom := CaveRun.new()
	bottom.start(3)
	for index in bottom.cave_points.size():
		var point: Vector3 = bottom.cave_points[index]
		if point.x == 112.0:
			point.z = 188.0
			bottom.cave_points[index] = point
	bottom.advance(CaveRun.MAX_STEP, 0.0)
	_check(bottom.state == CaveRun.State.OVER, "身体中段下方的短尖点也参与碰撞")


## 暂停和结束冻结整局，恢复只接受暂停状态，重开完整重置而不继承旧动量。
func _test_pause_restart_and_score() -> void:
	var run := CaveRun.new()
	run.start(371)
	run.advance(1.0, 0.0)
	_check(run.score == int(floor(run.distance / 10.0)) and run.score > 0, "分数由真实累计距离计算")
	run.pause()
	var paused := _snapshot(run)
	run.advance(1.0, -1.0)
	run.pause()
	_check(_snapshot(run) == paused, "重复暂停与暂停期间输入不改变任何本局数据")
	run.resume()
	run.advance(0.1, 0.0)
	_check(run.state == CaveRun.State.RUNNING and run.distance > float(paused["distance"]), "继续后从原距离恢复")
	run.advance(1.0, -1.0)
	var over := _snapshot(run)
	run.advance(1.0, 1.0)
	run.pause()
	run.resume()
	_check(run.state == CaveRun.State.OVER and _snapshot(run) == over, "失败后不再推进、计分或恢复")
	run.start(371)
	var fresh := CaveRun.new()
	fresh.start(371)
	_check(_snapshot(run) == _snapshot(fresh), "重开清空分数、时间、速度及全部旧地形")


## 跨512个种子检查完整难度区间：可见折线、最小空隙及跟得上的最大斜率。
func _test_generated_caves() -> void:
	for seed_value in 512:
		var run := CaveRun.new()
		run.start(seed_value)
		while run.cave_points[-1].x < 22000.0:
			run._append_point()
		var bounded := true
		var slopes_valid := true
		var body_passable := true
		for index in range(1, run.cave_points.size()):
			var previous: Vector3 = run.cave_points[index - 1]
			var point: Vector3 = run.cave_points[index]
			var span := point.x - previous.x
			bounded = bounded and point.y >= CaveRun.WALL_MARGIN - 0.0001 and point.z <= CaveRun.WORLD_SIZE.y - CaveRun.WALL_MARGIN + 0.0001 and point.z - point.y >= CaveRun.MIN_GAP - 0.0001
			slopes_valid = slopes_valid and is_equal_approx(span, CaveRun.POINT_SPACING) and absf(point.y - previous.y) / span <= CaveRun.MAX_WALL_SLOPE + 0.0001 and absf(point.z - previous.z) / span <= CaveRun.MAX_WALL_SLOPE + 0.0001
			# 每点中线两侧再扣去整个身体宽度可能引入的岩壁起伏，仍须保有操作余量。
			var half_clearance := (point.z - point.y) * 0.5 - CaveRun.SHARK_HALF_SIZE.y - CaveRun.MAX_WALL_SLOPE * CaveRun.SHARK_HALF_SIZE.x
			body_passable = body_passable and half_clearance > 35.0
		_check(bounded, "种子%d的岩层与最小通道高度受限" % seed_value)
		_check(slopes_valid, "种子%d的上下洞壁斜率受限" % seed_value)
		_check(body_passable, "种子%d在鲨鱼完整宽度下仍有安全路径" % seed_value)
	_check(CaveRun.MAX_WALL_SLOPE * CaveRun.MAX_SPEED < CaveRun.VERTICAL_SPEED * 1.5 * 0.65, "4.5倍速度下最陡岩壁的变化仍明显慢于补偿后的竖直速度")


## 首弯在玩家观察数秒后要求真实操作；随机朝上或朝下而不是永远维持安全中线。
func _test_first_bend_requires_steering() -> void:
	var survival: Array[float] = []
	var upper_wall_hits := 0
	var lower_wall_hits := 0
	for seed_value in 512:
		var run := CaveRun.new()
		run.start(seed_value)
		for frame in 120:
			run.advance(0.25, 0.0)
			if run.state == CaveRun.State.OVER:
				break
		survival.append(run.elapsed)
		_check(run.state == CaveRun.State.OVER and run.elapsed > 8.0 and run.elapsed < 30.0, "种子%d的首弯有观察时间且需要实际躲避" % seed_value)
		var nose_x := run.distance + CaveRun.SHARK_X + CaveRun.SHARK_HALF_SIZE.x
		if run.ceiling_at(nose_x) >= 168.0:
			upper_wall_hits += 1
		else:
			lower_wall_hits += 1
	_check(upper_wall_hits > 150 and lower_wall_hits > 150, "首弯两种随机朝向均需学习上下控制")
	survival.sort()
	print("首弯无输入回归：512种子，最早%.3f秒，中位%.3f秒，最晚%.3f秒；上壁%d次、下壁%d次。" % [survival[0], survival[256], survival[-1], upper_wall_hits, lower_wall_hits])


## 仅用键盘可产生的上、松手、下三值追踪中线，确认最高难度仍可通行且缓冲有界。
func _test_long_run() -> void:
	for seed_value in [0, 1, 19, 71, 127, 512, 4096, 65535]:
		var run := CaveRun.new()
		# 本组只隔离验证原始洞壁；下方独立长游保留默认章鱼并主动绕墨。
		run.start(seed_value, false)
		var bounded := true
		var last_score := 0
		var score_monotonic := true
		for frame in 21600:
			var look_x := run.distance + CaveRun.SHARK_X + 24.0
			var target_y := (run.ceiling_at(look_x) + run.floor_at(look_x)) * 0.5
			# 用松手制动距离预判停止位置；3px死区避免为微小偏差高频反向按键。
			var stopping_distance := signf(run.vertical_velocity) * run.vertical_velocity * run.vertical_velocity / (2.0 * CaveRun.BRAKING * run.control_multiplier())
			var error_y := target_y - run.shark_y - stopping_distance
			var direction := signf(error_y) if absf(error_y) > 3.0 else 0.0
			run.advance(1.0 / 60.0, direction)
			bounded = bounded and run.cave_points.size() <= 70 and run.cave_points[0].x <= run.distance and run.cave_points[-1].x >= run.distance + CaveRun.WORLD_SIZE.x
			score_monotonic = score_monotonic and run.score >= last_score
			last_score = run.score
			if run.state == CaveRun.State.OVER:
				break
		_check(run.state == CaveRun.State.RUNNING and run.distance > CaveRun.DIFFICULTY_DISTANCE * 2.0, "种子%d仅用上下键及松手游过封顶难度" % seed_value)
		_check(bounded, "种子%d长游地形缓冲最多70点且覆盖视口" % seed_value)
		_check(score_monotonic and is_equal_approx(run.scroll_speed, CaveRun.MAX_SPEED), "种子%d分数单调且后期速度封顶" % seed_value)


## 获取所有可观察数据的独立快照，发现暂停或重开时遗留的隐式状态变化。
func _snapshot(run: RefCounted) -> Dictionary:
	return {"state": run.state, "distance": run.distance, "score": run.score, "elapsed": run.elapsed, "shark_y": run.shark_y, "vertical_velocity": run.vertical_velocity, "scroll_speed": run.scroll_speed, "cave_points": run.cave_points.duplicate(), "octopuses": run.octopuses.duplicate(true), "fail_reason": run.fail_reason, "visual_seed": run.visual_seed, "tunas": run.tunas.duplicate(true), "next_tuna_score": run._next_tuna_score, "tuna_rng": run._tuna_random.state}


## 植物种子只派生不采样，固定局可重现，重开独立变化且不会改动玩法随机序列。
func _test_visual_seed() -> void:
	var run := CaveRun.new()
	run.start(341)
	var expected_seed: int = run.visual_seed
	var terrain_state: int = run._random.state
	var hazard_state: int = run._hazard_random.state
	for index in 100:
		var read_seed: int = run.visual_seed
		_check(read_seed == expected_seed and read_seed >= 0, "显示层反复读取稳定非负植物种子")
	_check(run._random.state == terrain_state and run._hazard_random.state == hazard_state, "读取植物种子不消耗玩法随机源")
	run.start(341)
	_check(run.visual_seed == expected_seed and run._random.state == terrain_state and run._hazard_random.state == hazard_state, "同种子重开还原植物与玩法序列")
	run.start(342)
	_check(run.visual_seed != expected_seed, "不同固定局的植物种子不同")
	run.start()
	var random_seed: int = run.visual_seed
	run.start()
	_check(run.visual_seed >= 0 and run.visual_seed != random_seed, "正式随机重开换一组植物且保持非负种子")


## 每150分乘上一档1.15，跨越阈值当帧更新，1650分与更高分数均封顶4.5倍。
func _test_speed_steps() -> void:
	for score_value in [0, 149, 150, 299, 300, 1199, 1200, 1499, 1500, 1649, 1650, 1950, 9000]:
		var run := CaveRun.new()
		run.start(4, false)
		run.distance = float(score_value) * 10.0 + 0.1
		run._ensure_terrain()
		run.shark_y = (run.ceiling_at(run.distance + CaveRun.SHARK_X) + run.floor_at(run.distance + CaveRun.SHARK_X)) * 0.5
		run.advance(CaveRun.MAX_STEP, 0.0)
		var expected := minf(92.0 * pow(1.15, floorf(float(score_value) / 150.0)), 414.0)
		_check(is_equal_approx(run.scroll_speed, expected), "%d分对应规定速度档位" % score_value)
	var boundary := CaveRun.new()
	boundary.start(11, false)
	boundary.distance = 1499.8
	boundary._ensure_terrain()
	boundary.shark_y = (boundary.ceiling_at(1612.0) + boundary.floor_at(1612.0)) * 0.5
	boundary.advance(CaveRun.MAX_STEP, 0.0)
	_check(boundary.score == 150 and is_equal_approx(boundary.scroll_speed, 105.8), "跨过150分的小步立即更新到105.8")


## 大量种子分别检查候选疏散与真实水道过滤；记录三个难度阶段，窄段不补位。
func _test_octopus_generation() -> void:
	var total_count := 0
	var upper_count := 0
	var small_count := 0
	var large_count := 0
	var stage_attempts := [0, 0, 0]
	var stage_actual := [0, 0, 0]
	for seed_value in 64:
		var planner := CaveRun.new()
		planner.start(seed_value)
		planner._pending_octopuses.clear()
		planner._next_octopus_segment = CaveRun.OCTOPUS_START_X
		var last_slot := -INF
		var planned_valid := true
		for group in 40:
			planner._pending_octopuses.clear()
			planner._plan_octopus_segment()
			planned_valid = planned_valid and planner._pending_octopuses.size() in [2, 3]
			for candidate in planner._pending_octopuses:
				var candidate_x := float(candidate["world_x"])
				planned_valid = planned_valid and candidate_x - last_slot >= 142.666
				last_slot = candidate_x
		_check(planned_valid, "种子%d每500px仅2至3候选，跨段间距不低于142.66px" % seed_value)
		var run := SpawnAudit.new()
		run.start(seed_value)
		_check(run.octopuses.is_empty(), "开局与首弯预览不提前生成章鱼")
		var seen: Dictionary = {}
		var groups: Dictionary = {}
		var valid_geometry := true
		var bounded := true
		var previous_x := -INF
		var spacing_valid := true
		for index in 80:
			run.distance = float(index) * 250.0
			run._ensure_terrain()
			run._ensure_octopuses()
			bounded = bounded and run.octopuses.size() <= 8 and run._pending_octopuses.size() <= 3
			for octopus in run.octopuses:
				var world_x := float(octopus["world_x"])
				if seen.has(world_x):
					continue
				seen[world_x] = true
				total_count += 1
				upper_count += int(int(octopus["side"]) < 0)
				var radius := float(octopus["ink_radius"])
				var body_scale := float(octopus["scale"])
				small_count += int(body_scale < 0.55)
				large_count += int(body_scale > 0.85)
				var center := run.ink_center(octopus)
				var band := run._wall_band(world_x - 12.0 * body_scale - CaveRun.SHARK_HALF_SIZE.x - 8.0, center.x + radius + CaveRun.SHARK_HALF_SIZE.x + 8.0)
				var free_height := band.y - center.y - radius if int(octopus["side"]) < 0 else center.y - radius - band.x
				valid_geometry = valid_geometry and world_x >= CaveRun.OCTOPUS_START_X and body_scale >= 0.4 and body_scale <= 1.0 and radius >= 18.0 * body_scale - 0.0001 and radius <= 28.0 * body_scale + 0.0001
				valid_geometry = valid_geometry and center.x - radius >= world_x + 8.0 * body_scale - 0.01 and center.y - radius >= band.x and center.y + radius <= band.y and free_height >= 79.999 and band.y - band.x >= CaveRun.OCTOPUS_MIN_WATER_HEIGHT - 0.001
				var group := int(floor((world_x - CaveRun.OCTOPUS_START_X) / 500.0))
				groups[group] = int(groups.get(group, 0)) + 1
				if group < 37:
					stage_actual[_density_stage(group)] += 1
				spacing_valid = spacing_valid and world_x - previous_x >= 142.666
				previous_x = world_x
		var density_valid := true
		for group in range(0, 37):
			density_valid = density_valid and int(groups.get(group, 0)) <= 3
		for candidate_x in run.attempts:
			var group := int(floor((candidate_x - CaveRun.OCTOPUS_START_X) / 500.0))
			if group < 37:
				stage_attempts[_density_stage(group)] += 1
		_check(valid_geometry, "种子%d前向墨圆整段共同水带至少%dpx且对侧净空80px" % [seed_value, CaveRun.OCTOPUS_MIN_WATER_HEIGHT])
		_check(density_valid and spacing_valid, "种子%d窄段跳过后不补位，实际密度不超过候选且分散间距保持" % seed_value)
		_check(bounded, "种子%d章鱼最多8只、待生最多3只且长期有界" % seed_value)
	_check(total_count > 300 and upper_count > total_count / 3 and upper_count < total_count * 2 / 3, "宽水道中仍有足量随机上下侧章鱼")
	_check(small_count > total_count / 5 and large_count > total_count / 5, "过滤后仍保留足量0.4至1倍大小差异")
	for stage in 3:
		var segment_count: int = [7, 8, 22][stage] * 64
		print("章鱼密度%s：%d候选，%d实际，每50分%.3f只，跳过率%.2f%%。" % [["初段", "中段", "封顶段"][stage], stage_attempts[stage], stage_actual[stage], float(stage_actual[stage]) / segment_count, (1.0 - float(stage_actual[stage]) / stage_attempts[stage]) * 100.0])
		_check(stage_actual[stage] < stage_attempts[stage], "三个阶段都会真实过滤不够宽的水道%d" % stage)
	var with_hazards := CaveRun.new()
	var replay := CaveRun.new()
	var without_hazards := CaveRun.new()
	with_hazards.start(991)
	replay.start(991)
	without_hazards.start(991, false)
	for index in 40:
		for run in [with_hazards, without_hazards, replay]:
			run.distance = float(index) * 250.0
			run._ensure_terrain()
			run._ensure_octopuses()
	_check(with_hazards.cave_points == without_hazards.cave_points and without_hazards.octopuses.is_empty(), "章鱼独立随机源不改变同种子洞壁")
	_check(_snapshot(with_hazards) == _snapshot(replay), "固定种子可重现过滤后的章鱼、体型与前向墨云")


## 以完整500px段划分初、中、封顶区域，便于量化平衡而不混入未完全生成的尾段。
func _density_stage(group: int) -> int:
	return 0 if group < 7 else (1 if group < 15 else 2)


## 点位虽宽但前向喷墨路线上有窄瓶颈时也不生成，且不会把过滤目标补在隔壁。
func _test_narrow_water_rejection() -> void:
	for seed_value in 16:
		var run := CaveRun.new()
		run.start(seed_value)
		run._spawn_octopus(240.0, -1, 1.0)
		_check(run.octopuses.size() == 1, "宽直道可放置单只前向章鱼%d" % seed_value)
		var first := run.octopuses[0]
		var fixed_center := run.ink_center(first)
		var rng_state: int = run._hazard_random.state
		run.shark_y += 50.0
		run.distance += 30.0
		first["timer"] = 0.1
		_check(run.ink_center(first) == fixed_center and run._hazard_random.state == rng_state, "墨云世界圆心不追踪鲨鱼、时间或查询且不消耗随机%d" % seed_value)
		run.start(seed_value)
		for index in run.cave_points.size():
			var point := run.cave_points[index]
			if point.x == 288.0:
				run.cave_points[index] = Vector3(point.x, 180.0, 302.0)
		_check(run.floor_at(240.0) - run.ceiling_at(240.0) > 200.0, "瓶颈夹具章鱼中心仍然宽阔%d" % seed_value)
		run._spawn_octopus(240.0, -1, 1.0)
		_check(run.octopuses.is_empty(), "前向墨云范围有窄瓶颈时整只跳过%d" % seed_value)
		run.start(seed_value)
		for index in run.cave_points.size():
			var point := run.cave_points[index]
			run.cave_points[index] = Vector3(point.x, 100.0, 100.0 + CaveRun.OCTOPUS_MIN_WATER_HEIGHT - 5.0)
		run._spawn_octopus(240.0, 1, 0.4)
		_check(run.octopuses.is_empty(), "低于宽度门槛的窄水道即使最小体型也不刷章鱼%d" % seed_value)


## 近距且同高才先预警后喷墨；远Y、撤离、暂停与真实墨圆碰撞分别验证。
func _test_octopus_phases_and_collision() -> void:
	var far := CaveRun.new()
	far.start(1)
	far.octopuses.append(_octopus_fixture(152.0, 110.0))
	far.advance(0.6, 0.0)
	_check(far.octopuses[0]["state"] == CaveRun.OctopusState.IDLE and far.state == CaveRun.State.RUNNING, "横向很近但Y差70px仍不警告或喷墨")
	var far_x := CaveRun.new()
	far_x.start(1)
	far_x.octopuses.append(_octopus_fixture(412.0, 180.0))
	far_x.advance(1.0, 0.0)
	_check(far_x.octopuses[0]["state"] == CaveRun.OctopusState.IDLE, "同高但物理距离过远不喷墨")
	var retreat := CaveRun.new()
	retreat.start(1)
	retreat.octopuses.append(_octopus_fixture(200.0, 198.0))
	retreat.advance(0.01, 0.0)
	_check(retreat.octopuses[0]["state"] == CaveRun.OctopusState.WARNING, "近距Y差18px开始短预警")
	retreat.advance(0.12, -1.0)
	_check(retreat.octopuses[0]["state"] == CaveRun.OctopusState.IDLE and float(retreat.octopuses[0]["timer"]) == 0.0 and retreat.fail_reason.is_empty(), "预警期间按上键离开同高区域可取消喷墨")
	var run := CaveRun.new()
	run.start(1)
	run.octopuses.append(_octopus_fixture(200.0, 198.0))
	run.advance(0.15, 0.0)
	_check(run.octopuses[0]["state"] == CaveRun.OctopusState.WARNING and run.state == CaveRun.State.RUNNING, "接近后保留0.20秒预警，不立即失败")
	run.pause()
	var paused := _snapshot(run)
	run.advance(1.0, 1.0)
	_check(_snapshot(run) == paused, "暂停冻结章鱼警告计时与位置")
	run.resume()
	run.advance(0.08, 0.0)
	_check(run.octopuses[0]["state"] == CaveRun.OctopusState.INK and run.fail_reason.is_empty(), "短预警完成才产生墨雾，尚未接触保持安全")
	run.pause()
	var ink_paused := _snapshot(run)
	run.advance(1.0, -1.0)
	_check(_snapshot(run) == ink_paused, "暂停也冻结已喷墨雾的寿命和碰撞状态")
	run.resume()
	run.advance(0.30, -1.0)
	for index in 22:
		run.advance(0.1, 0.0)
	_check(run.octopuses[0]["state"] == CaveRun.OctopusState.SPENT and run.state == CaveRun.State.RUNNING, "避开真实墨圆后，两秒墨雾自行散去且不会重喷")
	var hit := CaveRun.new()
	hit.start(2)
	hit.octopuses.append(_octopus_fixture(212.0, 180.0))
	hit.advance(1.0, 0.0)
	_check(hit.state == CaveRun.State.OVER and hit.fail_reason == "ink" and hit.elapsed >= 0.20, "真实墨圆接触身体才失败并记录ink原因")
	var stopped := _snapshot(hit)
	hit.advance(1.0, -1.0)
	_check(stopped == _snapshot(hit), "墨汁失败后章鱼、分数与时间冻结")
	hit.start(2)
	_check(hit.fail_reason.is_empty() and hit.octopuses.is_empty(), "重开清空墨汁失败原因及旧危险物")
	hit.advance(1.0, -1.0)
	_check(hit.fail_reason == "wall", "碰岩壁保留独立wall原因")
	var corner := CaveRun.new()
	corner.start(2)
	var fixture := _octopus_fixture(118.0, 211.0)
	fixture["state"] = CaveRun.OctopusState.INK
	fixture["ink_radius"] = 28.0
	corner.octopuses.append(fixture)
	_check(not corner._touches_ink(), "矩形角落外的墨圆不会按方框误判")
	corner.octopuses[0]["world_x"] = 117.0
	corner.octopuses[0]["ink_radius"] = 29.0
	_check(corner._touches_ink(), "墨圆真正触及矩形角落时可命中")
	var forward := CaveRun.new()
	forward.start(2)
	forward.distance = 22.0
	var directional := _octopus_fixture(152.0, 180.0)
	directional["state"] = CaveRun.OctopusState.INK
	forward.octopuses.append(directional)
	_check(forward.ink_center(directional).x - float(directional["ink_radius"]) == 160.0, "前向墨云左沿固定在章鱼右侧8px")
	forward.advance(0.01, 0.0)
	_check(forward.state == CaveRun.State.RUNNING and not forward._touches_ink(), "鲨鱼鼻端通过章鱼本体时安全，不存在以本体为中心的墨伤害")
	forward.advance(0.05, 0.0)
	_check(forward.state == CaveRun.State.OVER and forward.fail_reason == "ink", "继续向右实际触及前方墨云才失败")
	for speed_bucket in 9:
		var fast := CaveRun.new()
		fast.start(3)
		fast.distance = float(speed_bucket * 1500)
		fast._ensure_terrain()
		for index in fast.cave_points.size():
			var point: Vector3 = fast.cave_points[index]
			fast.cave_points[index] = Vector3(point.x, 58.0, 302.0)
		fast._next_octopus_segment = fast.distance + 2000.0
		fast._pending_octopuses.clear()
		fast.octopuses.clear()
		fast.scroll_speed = minf(92.0 * pow(1.15, float(speed_bucket)), CaveRun.MAX_SPEED)
		fast.octopuses.append(_octopus_fixture(fast.distance + CaveRun.SHARK_X + 100.0, 180.0))
		fast.advance(1.0, 0.0)
		_check(fast.state == CaveRun.State.OVER and fast.fail_reason == "ink", "速度档%d下同高靠近能及时喷墨并通过真实碰撞命中" % speed_bucket)


## 构造只改变危险物位置的夹具，所有状态变化与失败仍调用正式推进和碰撞。
func _octopus_fixture(world_x: float, y: float) -> Dictionary:
	return {"world_x": world_x, "y": y, "state": CaveRun.OctopusState.IDLE, "timer": 0.0, "ink_radius": 28.0, "side": -1, "scale": 1.0}


## 宽直道三倍速连续绕过两朵已生效墨云，不能靠从不触发章鱼来代替实际躲墨验证。
func _test_high_speed_ink_avoidance() -> void:
	var run := CaveRun.new()
	run.start(37)
	run.distance = 12000.0
	run.scroll_speed = 92.0 * pow(1.15, 8.0)
	run.cave_points = [Vector3(11900.0, 58.0, 302.0), Vector3(16000.0, 58.0, 302.0)]
	run._pending_octopuses.clear()
	run._next_octopus_segment = 18000.0
	var input_directions: Dictionary = {}
	for side in [-1, 1]:
		var octopus := _octopus_fixture(run.distance + CaveRun.SHARK_X + 200.0, 180.0)
		octopus["side"] = side
		octopus["state"] = CaveRun.OctopusState.INK
		run.octopuses.append(octopus)
		var overlapping_frames := 0
		var passed := false
		for frame in 120:
			var axis := _octopus_steering(run)
			input_directions[axis] = true
			run.advance(1.0 / 60.0, axis)
			var body := run.shark_rect()
			body.position.x += run.distance
			var center := run.ink_center(octopus)
			if body.end.x >= center.x - 28.0 and body.position.x <= center.x + 28.0:
				overlapping_frames += 1
				_check(octopus["state"] == CaveRun.OctopusState.INK and not run._touches_ink(), "三倍速横向经过实际活跃墨圆时用上下键保持几何分离")
			if body.position.x > center.x + 32.0:
				passed = true
				break
			if run.state == CaveRun.State.OVER:
				break
		_check(passed and overlapping_frames > 8 and run.state == CaveRun.State.RUNNING and run.scroll_speed >= 276.0, "三倍速在墨雾散去前完整绕过%s侧前向墨云" % ("上" if side < 0 else "下"))
	_check(input_directions.has(-1.0) and input_directions.has(1.0) and input_directions.has(0.0) and input_directions.size() == 3, "绕墨只使用真实键盘上、下、松手三种输入并实际改变方向")


## 正式危险物默认开启，用离散上下键提前走向章鱼对侧，验证最高速下整段可通过。
func _test_octopus_long_run() -> void:
	for seed_value in [0, 1, 19, 71, 127, 512, 4096, 65535]:
		var run := TunaLiveAudit.new()
		run.start(seed_value)
		var bounded := true
		var max_tunas := 0
		var recent: Array[Dictionary] = []
		for frame in 21600:
			var axis := _octopus_steering(run)
			recent.append({"x": run.distance, "y": run.shark_y, "v": run.vertical_velocity, "axis": axis, "fish": run.tunas.duplicate(true)})
			if recent.size() > 18:
				recent.remove_at(0)
			run.advance(1.0 / 60.0, axis)
			bounded = bounded and run.octopuses.size() <= 8 and run.tunas.size() <= CaveRun.TUNA_MAX_COUNT
			max_tunas = maxi(max_tunas, run.tunas.size())
			if run.state == CaveRun.State.OVER:
				print("章鱼路径诊断：seed=%d distance=%.2f y=%.2f v=%.2f nearby=%s" % [seed_value, run.distance, run.shark_y, run.vertical_velocity, str(run.octopuses)])
				print("来鱼输入诊断：", recent)
				break
		_check(run.state == CaveRun.State.RUNNING and run.elapsed > 359.0 and is_equal_approx(run.scroll_speed, CaveRun.MAX_SPEED), "种子%d开启章鱼后用真实上下键游过360秒（4.5倍速），失败原因%s" % [seed_value, run.fail_reason])
		_check(bounded, "种子%d正式长游章鱼与金枪鱼缓冲有界" % seed_value)
		_check(run.spawned >= 3, "种子%d自然长游确实出现多条金枪鱼而非全被过滤" % seed_value)
		print("金枪鱼自然长游：seed=%d，%.2f秒，抽中%d，实际%d，同时最多%d。" % [seed_value, run.elapsed, run.spawn_attempts, run.spawned, max_tunas])


## 仅按可见洞壁与章鱼位置给出上、松手、下三值，供长游及GPU画面采样复用。
func _octopus_steering(run: CaveRun) -> float:
	var key := run.get_instance_id()
	if not _tuna_route_memory.has(key) or run.distance < float(_tuna_route_memory[key]["distance"]):
		_tuna_route_memory[key] = {"distance": run.distance, "routes": {}}
	_tuna_route_memory[key]["distance"] = run.distance
	var routes: Dictionary = _tuna_route_memory[key]["routes"]
	var look_x := run.distance + CaveRun.SHARK_X + 24.0
	var target_y := (run.ceiling_at(look_x) + run.floor_at(look_x)) * 0.5
	var body_band: Vector2 = run._wall_band(look_x - CaveRun.SHARK_HALF_SIZE.x - 24.0, look_x + CaveRun.SHARK_HALF_SIZE.x)
	for octopus in run.octopuses:
		if int(octopus["state"]) not in [CaveRun.OctopusState.WARNING, CaveRun.OctopusState.INK]:
			continue
		var ahead := run.ink_center(octopus).x - (run.distance + CaveRun.SHARK_X)
		if ahead < -float(octopus["ink_radius"]) - CaveRun.SHARK_HALF_SIZE.x - 8.0 or ahead > 210.0:
			continue
		if int(octopus["side"]) < 0:
			target_y = maxf(target_y, float(octopus["y"]) + float(octopus["ink_radius"]) + CaveRun.SHARK_HALF_SIZE.y + 6.0)
		else:
			target_y = minf(target_y, float(octopus["y"]) - float(octopus["ink_radius"]) - CaveRun.SHARK_HALF_SIZE.y - 6.0)
	for tuna in run.tunas:
		var ahead := float(tuna["world_x"]) - (run.distance + CaveRun.SHARK_X)
		if ahead < -CaveRun.TUNA_HALF_SIZE.x - CaveRun.SHARK_HALF_SIZE.x - 10.0 or ahead > 360.0:
			continue
		var intercept_time := maxf(ahead, 0.0) / (run.scroll_speed + CaveRun.TUNA_SPEED)
		var fish_y := run._tuna_lane_y(float(tuna["world_x"]) - CaveRun.TUNA_SPEED * intercept_time, float(tuna["lane"]))
		var clearance := CaveRun.TUNA_HALF_SIZE.y + CaveRun.SHARK_HALF_SIZE.y + 12.0
		# 在可见来鱼接近时选择一次绕行侧，并保持到鱼身通过，避免来回改主意横穿碰撞盒。
		var lane := float(tuna["lane"])
		if not routes.has(lane):
			var braking_position := run.shark_y + signf(run.vertical_velocity) * run.vertical_velocity * run.vertical_velocity / (2.0 * CaveRun.BRAKING * run.control_multiplier())
			var future_x := float(tuna["world_x"]) - CaveRun.TUNA_SPEED * intercept_time
			# 从鼻端初次相遇到尾端通过都要能绕行，不能只检查两条鱼中心重合的瞬间。
			# 同时覆盖完整身体、下方目标夹取的24像素前瞻和10像素安全边距。
			var encounter_span := (CaveRun.SHARK_HALF_SIZE.x + CaveRun.TUNA_HALF_SIZE.x) * run.scroll_speed / (run.scroll_speed + CaveRun.TUNA_SPEED)
			var future_band := run._wall_band(future_x - encounter_span - CaveRun.SHARK_HALF_SIZE.x, future_x + encounter_span + CaveRun.SHARK_HALF_SIZE.x + 24.0)
			var choose_below := braking_position >= fish_y
			if fish_y - clearance < future_band.x + CaveRun.SHARK_HALF_SIZE.y + 10.0:
				choose_below = true
			elif fish_y + clearance > future_band.y - CaveRun.SHARK_HALF_SIZE.y - 10.0:
				choose_below = false
			routes[lane] = 1 if choose_below else -1
		if int(routes[lane]) > 0:
			target_y = maxf(target_y, fish_y + clearance)
		else:
			target_y = minf(target_y, fish_y - clearance)
	target_y = clampf(target_y, body_band.x + CaveRun.SHARK_HALF_SIZE.y + 10.0, body_band.y - CaveRun.SHARK_HALF_SIZE.y - 10.0)
	var braking := signf(run.vertical_velocity) * run.vertical_velocity * run.vertical_velocity / (2.0 * CaveRun.BRAKING * run.control_multiplier())
	var error_y := target_y - run.shark_y - braking
	return signf(error_y) if absf(error_y) > 3.0 else 0.0


## 概率阈值精确且每槽只抽一次；统计大量真实私有随机样本，不把空间过滤当作概率变化。
func _test_tuna_probability_and_rng() -> void:
	var run := CaveRun.new()
	run.start(811)
	var rng_state: int = run._tuna_random.state
	for pair in [[0, 0.0], [499, 0.0], [500, 0.08], [999, 0.08], [1000, 0.15], [90000, 0.15]]:
		_check(is_equal_approx(run.tuna_spawn_chance(int(pair[0])), float(pair[1])), "金枪鱼概率边界%d正确" % int(pair[0]))
	_check(run._tuna_random.state == rng_state, "概率查询不采样或改变下一次抽签")
	for threshold in [500, 1000]:
		var audit := TunaRollAudit.new()
		audit.start(72819)
		audit.score = threshold
		for index in 20000:
			audit._next_tuna_score = threshold
			audit._maybe_spawn_tuna()
		var frequency := float(audit.successful_rolls) / 20000.0
		_check(absf(frequency - audit.tuna_spawn_chance(threshold)) < 0.012, "二万次私有抽签实测%d分概率接近规定值" % threshold)
		print("金枪鱼概率回归：%d分，20000次，选中%d次（%.3f%%）。" % [threshold, audit.successful_rolls, frequency * 100.0])
		var after_roll: int = audit._tuna_random.state
		var successful := audit.successful_rolls
		for index in 100:
			audit._maybe_spawn_tuna()
		_check(audit._tuna_random.state == after_roll and audit.successful_rolls == successful, "同一50分槽不重复抽签%d" % threshold)
	var jump := TunaRollAudit.new()
	jump.start(62)
	jump.score = 6000
	var probe := RandomNumberGenerator.new()
	probe.state = jump._tuna_random.state
	probe.randf()
	jump._maybe_spawn_tuna()
	_check(jump._next_tuna_score == 6050 and jump._tuna_random.state == probe.state and jump.successful_rolls <= 1, "跨越大量旧分数槽只尝试当前一次，不补发鱼群")
	run.score = 499
	run._maybe_spawn_tuna()
	_check(run.tunas.is_empty() and run._tuna_random.state == rng_state, "500分前没有金枪鱼，也不提前抽签")
	seed(641257)
	var expected := randi()
	seed(641257)
	var terrain_rng: int = run._random.state
	var octopus_rng: int = run._hazard_random.state
	for index in 50:
		run.tunas.clear()
		run._spawn_tuna()
		run._advance_tunas(0.01)
	_check(run._random.state == terrain_rng and run._hazard_random.state == octopus_rng and randi() == expected, "金枪鱼生成、移动和查询不消耗地形、章鱼或全局随机序列")
	var replay := CaveRun.new()
	run.start(341)
	replay.start(341)
	for candidate in [run, replay]:
		candidate._spawn_tuna()
		candidate._advance_tunas(0.2)
	_check(_snapshot(run) == _snapshot(replay), "同种子金枪鱼体型、泳道和逆向位置可重现")


## 只读出生校验拒绝狭道、墨云集群和相邻来鱼，成功时只放屏外一条且总数不超过三。
func _test_tuna_spawn_safety() -> void:
	var run := CaveRun.new()
	run.start(72)
	var terrain_rng: int = run._random.state
	var tuna_rng: int = run._tuna_random.state
	var x := run.distance + CaveRun.WORLD_SIZE.x + CaveRun.TUNA_SPAWN_MARGIN
	_check(run._tuna_spawn_is_clear(x), "宽阔屏外水道允许单条金枪鱼出现")
	_check(run._random.state == terrain_rng and run._tuna_random.state == tuna_rng, "出生通路查询只读，不影响随机序列")
	run._spawn_tuna()
	_check(run.tunas.size() == 1 and run.tuna_rect(run.tunas[0]).position.x > run.distance + CaveRun.WORLD_SIZE.x, "一次成功只生成一条，完整鱼身位于右侧屏外")
	_check(run.tuna_rect(run.tunas[0]).size.is_equal_approx(CaveRun.SHARK_HALF_SIZE * 2.0 / 3.0), "金枪鱼长和高均为玩家碰撞身体三分之一")
	run._spawn_tuna()
	_check(run.tunas.size() == 1, "相邻来鱼不在同一段水道叠放")
	run.tunas = [{"world_x": -1000.0, "y": 180.0, "lane": 0.0}, {"world_x": -500.0, "y": 180.0, "lane": 0.0}, {"world_x": 0.0, "y": 180.0, "lane": 0.0}]
	run.score = 1000
	for seed_value in 64:
		run._tuna_random.seed = seed_value
		run._next_tuna_score = 1000
		run._maybe_spawn_tuna()
		_check(run.tunas.size() == 3, "已有三条时成功抽签也不能突破同时数量上限")
	run.tunas.remove_at(0)
	run._maybe_spawn_tuna()
	_check(run.tunas.size() == 2 and run._next_tuna_score == 1050, "释放位置不会补发本槽已丢弃的机会")
	run.start(72)
	run.octopuses.append(_octopus_fixture(650.0, 90.0))
	_check(not run._tuna_spawn_is_clear(x), "迎面路径邻近未喷墨章鱼也留出组合障碍安全距离")
	run.octopuses[0]["state"] = CaveRun.OctopusState.INK
	_check(not run._tuna_spawn_is_clear(x), "已喷墨圆附近不生成会占据逃生通道的金枪鱼")
	run.octopuses.clear()
	for index in run.cave_points.size():
		var point := run.cave_points[index]
		if point.x == 560.0:
			run.cave_points[index] = Vector3(point.x, 210.0, 302.0)
	_check(run.floor_at(x) - run.ceiling_at(x) > 200.0 and not run._tuna_spawn_is_clear(x), "出生点虽宽但迎面路径含窄瓶颈时也拒绝")
	var aligned_count := 0
	for seed_value in 64:
		run.start(seed_value)
		run.distance = 6000.0
		run._ensure_terrain()
		run.octopuses.clear()
		run._spawn_tuna()
		if run.tunas.is_empty():
			continue
		aligned_count += 1
		for frame in 120:
			run._advance_tunas(1.0 / 60.0)
			var body := run.tuna_rect(run.tunas[0])
			var band := run._wall_band(body.position.x, body.end.x)
			_check(body.position.y >= band.x and body.end.y <= band.y, "固定泳道沿随机洞穴左游时完整鱼身不进入岩壁")
	_check(aligned_count >= 8, "大量种子中既有可出现水道，也可持续检查真实弯道对齐")


## 前后运动、暂停、复位和4.5倍速迎面碰撞均走正式小步，不通过直接写失败状态模拟。
func _test_tuna_motion_and_collision() -> void:
	var run := CaveRun.new()
	run.start(51)
	run.tunas.append({"world_x": 412.0, "y": 180.0, "lane": 0.0})
	run.advance(0.2, 0.0)
	_check(is_equal_approx(float(run.tunas[0]["world_x"]), 399.2) and is_equal_approx(float(run.tunas[0]["world_x"]) - run.distance, 380.8), "金枪鱼世界坐标向左64px/s，屏幕相对接近速度包含玩家前进")
	run.pause()
	var paused := _snapshot(run)
	run.advance(1.0, 1.0)
	_check(_snapshot(run) == paused, "暂停冻结金枪鱼位置、抽签状态和失败判定")
	run.resume()
	run.advance(1.0, 0.0)
	run.advance(1.0, 0.0)
	_check(run.state == CaveRun.State.OVER and run.fail_reason == "tuna", "真实逆向矩形接触触发独立tuna失败原因")
	var ended := _snapshot(run)
	run.advance(1.0, -1.0)
	_check(_snapshot(run) == ended, "失败后金枪鱼和概率槽完全冻结")
	run.start(51)
	_check(run.tunas.is_empty() and run.fail_reason.is_empty() and run._next_tuna_score == 500, "重试清空所有来鱼、原因和已消耗概率槽")
	var left := CaveRun.new()
	var right := CaveRun.new()
	left.start(22)
	right.start(22)
	for candidate in [left, right]:
		candidate.tunas.append({"world_x": 412.0, "y": 180.0, "lane": -0.15})
	right.shark_y = 240.0
	left._advance_tunas(0.2)
	right._advance_tunas(0.2)
	_check(left.tunas == right.tunas, "金枪鱼泳道不追踪鲨鱼高度")
	for bucket in 14:
		var fast := _wide_tuna_run(bucket)
		fast.tunas.append({"world_x": fast.distance + CaveRun.SHARK_X + 100.0, "y": 180.0, "lane": 0.0})
		fast.advance(1.0, 0.0)
		_check(fast.state == CaveRun.State.OVER and fast.fail_reason == "tuna" and fast.elapsed < 0.5, "速度档%d长帧不能穿过迎面金枪鱼" % bucket)
	_check((CaveRun.MAX_SPEED + CaveRun.TUNA_SPEED) * CaveRun.MAX_STEP < CaveRun.TUNA_HALF_SIZE.x * 2.0, "4.5倍速单步相对位移仍小于金枪鱼宽度，持续碰撞不会跳过鱼身")


## 构造指定净高的平直运动夹具，默认宽直道，关闭额外候选但保留正式危险物推进与碰撞。
func _wide_tuna_run(bucket: int = 13, water_height: float = 244.0) -> CaveRun:
	var run := CaveRun.new()
	run.start(721)
	run.distance = float(bucket * 1500)
	run.score = bucket * 150
	run.scroll_speed = minf(92.0 * pow(1.15, float(bucket)), CaveRun.MAX_SPEED)
	var ceiling := 180.0 - water_height * 0.5
	var floor_y := 180.0 + water_height * 0.5
	run.cave_points = [Vector3(run.distance - 100.0, ceiling, floor_y), Vector3(run.distance + 5000.0, ceiling, floor_y)]
	run.octopuses.clear()
	run._pending_octopuses.clear()
	run._next_octopus_segment = run.distance + 6000.0
	run._next_tuna_score = 1000000
	return run


## 最高4.5倍速度真实避开已在迎面路径上的来鱼，横向经过时不得依赖关闭碰撞或等待消失。
func _test_high_speed_tuna_avoidance() -> void:
	for lane in [-0.03, 0.03]:
		var run := _wide_tuna_run()
		var world_x := run.distance + CaveRun.SHARK_X + 300.0
		run.tunas.append({"world_x": world_x, "y": run._tuna_lane_y(world_x, lane), "lane": lane})
		var overlap_frames := 0
		var passed := false
		for frame in 90:
			run.advance(1.0 / 60.0, _octopus_steering(run))
			var body := run.shark_rect()
			body.position.x += run.distance
			var fish := run.tuna_rect(run.tunas[0])
			if body.end.x >= fish.position.x and body.position.x <= fish.end.x:
				overlap_frames += 1
				_check(not body.intersects(fish, true), "4.5倍速水平相遇期间通过真实上下输入保持矩形分离")
			if body.position.x > fish.end.x + 4.0:
				passed = true
				break
			if run.state == CaveRun.State.OVER:
				break
		_check(passed and overlap_frames >= 4 and run.state == CaveRun.State.RUNNING and is_equal_approx(run.scroll_speed, CaveRun.MAX_SPEED), "4.5倍速成功绕过迎面金枪鱼lane%.2f" % lane)


## 出生允许的最窄118像素水带内，从与三个极限泳道来鱼同高的劣势位置真实二值绕行。
func _test_minimum_water_tuna_avoidance() -> void:
	var all_inputs: Dictionary = {}
	for lane in [-0.24, 0.0, 0.24]:
		var run := _wide_tuna_run(13, 118.0)
		var stationary := _wide_tuna_run(13, 118.0)
		var world_x := run.distance + CaveRun.SHARK_X + 300.0
		var fish_y := run._tuna_lane_y(world_x, lane)
		_check(is_equal_approx(run.floor_at(world_x) - run.ceiling_at(world_x), 118.0) and run._tuna_spawn_is_clear(world_x), "泳道%.2f在恰好118像素的出生净空边界有效" % lane)
		for candidate in [run, stationary]:
			candidate.shark_y = fish_y
			candidate.tunas.append({"world_x": world_x, "y": fish_y, "lane": lane})
		# 同高不操作必然命中，排除夹具本身就自动错身的无效通过。
		stationary.advance(1.0, 0.0)
		_check(stationary.state == CaveRun.State.OVER and stationary.fail_reason == "tuna", "窄水带泳道%.2f同高不操作会发生真实鱼身碰撞" % lane)
		var overlap_frames := 0
		var passed := false
		var input_is_binary := true
		for frame in 90:
			var axis := _octopus_steering(run)
			input_is_binary = input_is_binary and axis in [-1.0, 0.0, 1.0]
			all_inputs[axis] = true
			run.advance(1.0 / 60.0, axis)
			var body := run.shark_rect()
			body.position.x += run.distance
			var fish := run.tuna_rect(run.tunas[0])
			if body.end.x >= fish.position.x and body.position.x <= fish.end.x:
				overlap_frames += 1
				var band := run._wall_band(body.position.x, body.end.x)
				_check(not body.intersects(fish, true) and body.position.y > band.x and body.end.y < band.y, "窄水带泳道%.2f4.5倍速真实水平相遇时同时避开鱼身和上下岩壁" % lane)
			if body.position.x > fish.end.x + 4.0:
				passed = true
				break
			if run.state == CaveRun.State.OVER:
				break
		_check(passed and overlap_frames >= 4 and run.state == CaveRun.State.RUNNING and run.fail_reason.is_empty() and is_equal_approx(run.scroll_speed, CaveRun.MAX_SPEED), "窄水带泳道%.2f从同高位置以4.5倍速完成真实绕行" % lane)
		_check(input_is_binary and absf(run.shark_y - fish_y) > CaveRun.SHARK_HALF_SIZE.y + CaveRun.TUNA_HALF_SIZE.y, "窄水带泳道%.2f只靠上、下、松手实际形成鱼身避让高度" % lane)
	_check(all_inputs.has(-1.0) and all_inputs.has(1.0) and all_inputs.size() <= 3, "最窄水带的极限泳道分别要求上避和下避，不依赖单向安全路线")


## 累计每项断言，失败时保留明确用例名称方便定位。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
