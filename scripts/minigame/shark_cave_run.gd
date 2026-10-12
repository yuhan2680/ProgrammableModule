class_name SharkCaveRun
extends RefCounted
## 彩蛋的独立连续模拟：洞壁、碰撞、计分只存在于本次游玩，不接触主游戏或存档。

enum State { READY, RUNNING, PAUSED, OVER }
enum OctopusState { IDLE, WARNING, INK, SPENT }

const WORLD_SIZE := Vector2(640.0, 360.0)
const SHARK_X: float = 112.0
const SHARK_HALF_SIZE := Vector2(22.0, 11.0)
const POINT_SPACING: float = 16.0
const SAFE_RUNWAY: float = 720.0
const MIN_GAP: float = 118.0
const WALL_MARGIN: float = 24.0
const MAX_WALL_SLOPE: float = 0.35
const INITIAL_SPEED: float = 92.0
const MAX_SPEED: float = INITIAL_SPEED * 4.5
const SPEED_SCORE_STEP: int = 150
const SPEED_MULTIPLIER: float = 1.15
const VERTICAL_SPEED: float = 168.0
const ACCELERATION: float = 1100.0
const BRAKING: float = 1400.0
const MAX_STEP: float = 1.0 / 120.0
const MAX_FRAME_DELTA: float = 1.0
const LOOK_AHEAD: float = 320.0
const KEEP_BEHIND: float = 96.0
const DIFFICULTY_DISTANCE: float = 8000.0
const OCTOPUS_START_X: float = 1200.0
const OCTOPUS_SEGMENT: float = 500.0
const OCTOPUS_TRIGGER_DISTANCE: float = 96.0
const OCTOPUS_TRIGGER_Y: float = 20.0
const OCTOPUS_WARNING_TIME: float = 0.20
const INK_LIFETIME: float = 2.0
const INK_MIN_RADIUS: float = 18.0
const INK_MAX_RADIUS: float = 28.0
const INK_FORWARD_OFFSET: float = 8.0
const OCTOPUS_MIN_WATER_HEIGHT: float = 150.0
const INK_PASSAGE_HEIGHT: float = 80.0
const TUNA_HALF_SIZE := SHARK_HALF_SIZE / 3.0
const TUNA_SPEED: float = 64.0
const TUNA_MAX_COUNT: int = 3
const TUNA_SCORE_INTERVAL: int = 50
const TUNA_SPAWN_MARGIN: float = 80.0
const TUNA_MIN_SPACING: float = 320.0
const TUNA_MIN_WATER_HEIGHT: float = 118.0
const TUNA_CLUSTER_MARGIN: float = 140.0

var state: State = State.READY
var distance: float = 0.0
var score: int = 0
var elapsed: float = 0.0
var shark_y: float = WORLD_SIZE.y * 0.5
var vertical_velocity: float = 0.0
var scroll_speed: float = INITIAL_SPEED
var cave_points: Array[Vector3] = []
var octopuses: Array[Dictionary] = []
var tunas: Array[Dictionary] = []
var fail_reason: String = ""
var visual_seed: int = 0

var _random := RandomNumberGenerator.new()
var _hazard_random := RandomNumberGenerator.new()
var _tuna_random := RandomNumberGenerator.new()
var _next_tuna_score: int = 500
var _hazards_enabled: bool = true
var _next_octopus_segment: float = OCTOPUS_START_X
var _pending_octopuses: Array[Dictionary] = []
var _target_center: float = WORLD_SIZE.y * 0.5
var _target_gap: float = 244.0
var _target_until: float = SAFE_RUNWAY
var _first_bend_pending: bool = true


## 菜单也能显示安全的洞穴预览，但尚未开始计分或推进。
func _init() -> void:
	start()
	state = State.READY


## 每次开始清空旧局，并使用独立随机源；非负种子仅供可重复的自动测试。
func start(seed_value: int = -1, hazards_enabled: bool = true) -> void:
	if seed_value < 0:
		_random.randomize()
		_hazard_random.randomize()
		_tuna_random.randomize()
	else:
		_random.seed = seed_value
		_hazard_random.seed = seed_value ^ 0x5eed123
		_tuna_random.seed = seed_value ^ 0x74756e61
	# 植物仅借用不消耗随机序列的派生种子，显示数量不会反过来改变地形或章鱼。
	visual_seed = int((_random.seed ^ 0x52454546) & 0x7fffffff)
	state = State.RUNNING
	distance = 0.0
	score = 0
	elapsed = 0.0
	shark_y = WORLD_SIZE.y * 0.5
	vertical_velocity = 0.0
	scroll_speed = INITIAL_SPEED
	_target_center = WORLD_SIZE.y * 0.5
	_target_gap = 244.0
	_target_until = SAFE_RUNWAY
	_first_bend_pending = true
	_hazards_enabled = hazards_enabled
	_next_octopus_segment = OCTOPUS_START_X
	_pending_octopuses.clear()
	octopuses.clear()
	tunas.clear()
	_next_tuna_score = 500
	fail_reason = ""
	cave_points.clear()
	cave_points.append(Vector3(-POINT_SPACING * 2.0, 58.0, 302.0))
	_ensure_terrain()
	_ensure_octopuses()


## 上下输入连续控制速度，松手平滑减速；卡顿最多补算一秒且始终以小步检测碰撞。
func advance(delta: float, axis: float) -> void:
	if state != State.RUNNING or not is_finite(delta) or delta <= 0.0:
		return
	var remaining := minf(delta, MAX_FRAME_DELTA)
	var direction := clampf(axis, -1.0, 1.0) if is_finite(axis) else 0.0
	while remaining > 0.0000001 and state == State.RUNNING:
		var step := minf(remaining, MAX_STEP)
		_advance_step(step, direction)
		remaining -= step


## 暂停仅改变本局状态，位置、随机源和分数都冻结。
func pause() -> void:
	if state == State.RUNNING:
		state = State.PAUSED


## 只有暂停中的有效一局可以继续，结束后必须重新开始。
func resume() -> void:
	if state == State.PAUSED:
		state = State.RUNNING


## 读取与绘制共用的洞顶折线，高度查询不会消耗随机数或生成地形。
func ceiling_at(world_x: float) -> float:
	return _wall_at(world_x, true)


## 读取与绘制共用的洞底折线，屏幕坐标须先加上推进距离。
func floor_at(world_x: float) -> float:
	return _wall_at(world_x, false)


## 返回屏幕内鲨鱼身体的碰撞矩形，装饰尾鳍不扩大实际碰撞。
func shark_rect() -> Rect2:
	return Rect2(Vector2(SHARK_X, shark_y) - SHARK_HALF_SIZE, SHARK_HALF_SIZE * 2.0)


## 墨云固定在章鱼右前方；各阶段只读同一世界圆心，不跟随鲨鱼或喷射计时移动。
func ink_center(octopus: Dictionary) -> Vector2:
	var offset := float(octopus["ink_radius"]) + INK_FORWARD_OFFSET * float(octopus.get("scale", 1.0))
	return Vector2(float(octopus["world_x"]) + offset, float(octopus["y"]))


## 超过原三倍速度后同比提高上下速度、加速和制动，低速手感不变，最高速时仍能跟上岩壁。
func control_multiplier() -> float:
	return maxf(1.0, scroll_speed / (INITIAL_SPEED * 3.0))


## 金枪鱼碰撞盒是鲨鱼的三分之一线性尺寸，使用世界坐标以便画布与模型共用。
func tuna_rect(tuna: Dictionary) -> Rect2:
	return Rect2(Vector2(float(tuna["world_x"]), float(tuna["y"])) - TUNA_HALF_SIZE, TUNA_HALF_SIZE * 2.0)


## 每五十分只抽一次的概率表；查询本身不采样，也不会修改下一次出现时机。
func tuna_spawn_chance(score_value: int) -> float:
	return 0.0 if score_value < 500 else (0.08 if score_value < 1000 else 0.15)


## 固定小步限制每次水平与竖直位移，任何一次接触即停止本局后续推进。
func _advance_step(delta: float, axis: float) -> void:
	var multiplier := control_multiplier()
	var limit := VERTICAL_SPEED * multiplier
	var target_speed := axis * limit
	var acceleration := (BRAKING if is_zero_approx(axis) else ACCELERATION) * multiplier
	vertical_velocity = clampf(move_toward(vertical_velocity, target_speed, acceleration * delta), -limit, limit)
	shark_y += vertical_velocity * delta
	distance += scroll_speed * delta
	elapsed += delta
	_ensure_terrain()
	_ensure_octopuses()
	score = int(floor(distance / 10.0))
	# 跨过150分档的同一小步立即更新显示和下一次推进速度，1650分起达到4.5倍封顶。
	scroll_speed = minf(INITIAL_SPEED * pow(SPEED_MULTIPLIER, floorf(float(score) / float(SPEED_SCORE_STEP))), MAX_SPEED)
	if _touches_wall():
		state = State.OVER
		fail_reason = "wall"
		vertical_velocity = 0.0
		return
	_advance_octopuses(delta)
	if _touches_ink():
		state = State.OVER
		fail_reason = "ink"
		vertical_velocity = 0.0
		return
	_advance_tunas(delta)
	if _touches_tuna():
		state = State.OVER
		fail_reason = "tuna"
		vertical_velocity = 0.0


## 每500px仅安排2至3个均匀候选，跨段也至少相隔142px；狭窄处跳过而不向邻近位置补放。
func _plan_octopus_segment() -> void:
	var count := _hazard_random.randi_range(2, 3)
	var slot_width := OCTOPUS_SEGMENT / float(count)
	for index in count:
		var world_x := _next_octopus_segment + (float(index) + 0.5) * slot_width
		world_x += _hazard_random.randf_range(-12.0, 12.0)
		var side := -1 if _hazard_random.randi_range(0, 1) == 0 else 1
		var octopus_scale := _hazard_random.randf_range(0.4, 1.0)
		_pending_octopuses.append({"world_x": world_x, "side": side, "scale": octopus_scale})
	_next_octopus_segment += OCTOPUS_SEGMENT


## 先等完整邻近洞壁生成再放置章鱼，离屏数据及时清理；测试可显式关闭独立危险物。
func _ensure_octopuses() -> void:
	if not _hazards_enabled:
		return
	while true:
		if _pending_octopuses.is_empty():
			_plan_octopus_segment()
		var candidate := _pending_octopuses[0]
		var world_x := float(candidate["world_x"])
		var furthest_ink := (INK_MAX_RADIUS * 2.0 + INK_FORWARD_OFFSET) * float(candidate["scale"])
		if world_x + furthest_ink + SHARK_HALF_SIZE.x + 8.0 > cave_points[-1].x:
			break
		_pending_octopuses.remove_at(0)
		_spawn_octopus(world_x, int(candidate["side"]), float(candidate["scale"]))
	while not octopuses.is_empty() and ink_center(octopuses[0]).x + float(octopuses[0]["ink_radius"]) < distance - KEEP_BEHIND:
		octopuses.remove_at(0)


## 覆盖动物、前向墨云与鲨鱼横宽的共同水带须足够宽；对侧至少留80px可用水域（含鱼体高度），窄段直接空过。
func _spawn_octopus(world_x: float, side: int, octopus_scale: float) -> void:
	var radius := _hazard_random.randf_range(INK_MIN_RADIUS, INK_MAX_RADIUS) * octopus_scale
	var left := world_x - 12.0 * octopus_scale - SHARK_HALF_SIZE.x - 8.0
	var right := world_x + radius * 2.0 + INK_FORWARD_OFFSET * octopus_scale + SHARK_HALF_SIZE.x + 8.0
	var band := _wall_band(left, right)
	if band.y - band.x < maxf(OCTOPUS_MIN_WATER_HEIGHT, radius * 2.0 + 2.0 + INK_PASSAGE_HEIGHT):
		return
	var center_y := band.x + radius + 2.0 if side < 0 else band.y - radius - 2.0
	octopuses.append({"world_x": world_x, "y": center_y, "state": OctopusState.IDLE, "timer": 0.0, "ink_radius": radius, "side": side, "scale": octopus_scale})


## 只有靠近的章鱼先预警再喷墨，墨雾两秒后失效；暂停和终局不会调用此计时。
func _advance_octopuses(delta: float) -> void:
	if not _hazards_enabled:
		return
	var shark_center := Vector2(distance + SHARK_X, shark_y)
	for octopus in octopuses:
		var center := Vector2(float(octopus["world_x"]), float(octopus["y"]))
		var phase := int(octopus["state"])
		if phase == OctopusState.IDLE:
			if _octopus_is_near(center, shark_center):
				octopus["state"] = OctopusState.WARNING
				octopus["timer"] = 0.0
		elif phase == OctopusState.WARNING:
			if not _octopus_is_near(center, shark_center):
				octopus["state"] = OctopusState.IDLE
				octopus["timer"] = 0.0
				continue
			octopus["timer"] = float(octopus["timer"]) + delta
			if float(octopus["timer"]) >= OCTOPUS_WARNING_TIME:
				octopus["state"] = OctopusState.INK
				octopus["timer"] = float(octopus["timer"]) - OCTOPUS_WARNING_TIME
		elif phase == OctopusState.INK:
			octopus["timer"] = float(octopus["timer"]) + delta
			if float(octopus["timer"]) >= INK_LIFETIME:
				octopus["state"] = OctopusState.SPENT
				octopus["timer"] = 0.0


## 同时满足物理近距和近似同高才激怒章鱼，鲨鱼在远处或另一侧通过不会喷墨。
func _octopus_is_near(center: Vector2, shark_center: Vector2) -> bool:
	return center.x >= shark_center.x - SHARK_HALF_SIZE.x and absf(center.y - shark_center.y) <= OCTOPUS_TRIGGER_Y and center.distance_to(shark_center) <= OCTOPUS_TRIGGER_DISTANCE


## 按真实身体矩形与墨圆的最近点判定，预警和已散去的墨不会造成失败。
func _touches_ink() -> bool:
	if not _hazards_enabled:
		return false
	var body := shark_rect()
	body.position.x += distance
	for octopus in octopuses:
		if int(octopus["state"]) != OctopusState.INK:
			continue
		var center := ink_center(octopus)
		var nearest := center.clamp(body.position, body.end)
		var radius := float(octopus["ink_radius"])
		if center.distance_squared_to(nearest) <= radius * radius:
			return true
	return false


## 金枪鱼始终向左沿固定洞穴泳道移动，不追踪玩家；每步同样冻结于暂停和终局。
func _advance_tunas(delta: float) -> void:
	if not _hazards_enabled:
		return
	for tuna in tunas:
		tuna["world_x"] = float(tuna["world_x"]) - TUNA_SPEED * delta
		tuna["y"] = _tuna_lane_y(float(tuna["world_x"]), float(tuna["lane"]))
	for index in range(tunas.size() - 1, -1, -1):
		if float(tunas[index]["world_x"]) + TUNA_HALF_SIZE.x < distance - KEEP_BEHIND:
			tunas.remove_at(index)
	_maybe_spawn_tuna()


## 跨过分数槽只尝试当前一次；槽位立即消耗，数量满、窄路或抽签落空都不会积攒补发。
func _maybe_spawn_tuna() -> void:
	if not _hazards_enabled or score < _next_tuna_score:
		return
	_next_tuna_score = (int(floor(float(score) / float(TUNA_SCORE_INTERVAL))) + 1) * TUNA_SCORE_INTERVAL
	var selected := _tuna_random.randf() < tuna_spawn_chance(score)
	if selected and tunas.size() < TUNA_MAX_COUNT:
		_spawn_tuna()


## 屏外生成单鱼，空间检查失败时直接放弃本次机会，不产生待生队列。
func _spawn_tuna() -> void:
	var world_x := distance + WORLD_SIZE.x + TUNA_SPAWN_MARGIN
	if not _tuna_spawn_is_clear(world_x):
		return
	var lane := _tuna_random.randf_range(-0.24, 0.24)
	tunas.append({"world_x": world_x, "y": _tuna_lane_y(world_x, lane), "lane": lane})


## 只读检查整段迎面路径与障碍组合，避免把新鱼塞进章鱼或其它来鱼的逃生通道。
func _tuna_spawn_is_clear(world_x: float) -> bool:
	if tunas.size() >= TUNA_MAX_COUNT:
		return false
	var encounter_time := (world_x - distance - SHARK_X) / (scroll_speed + TUNA_SPEED)
	var approach_left := world_x - TUNA_SPEED * encounter_time - TUNA_CLUSTER_MARGIN
	for other in tunas:
		if absf(float(other["world_x"]) - world_x) < TUNA_MIN_SPACING:
			return false
	for octopus in octopuses:
		if int(octopus["state"]) == OctopusState.SPENT:
			continue
		var center := ink_center(octopus)
		var radius := float(octopus["ink_radius"])
		if center.x + radius >= approach_left and center.x - radius <= world_x + TUNA_CLUSTER_MARGIN:
			return false
	var sample_x := approach_left
	while sample_x <= world_x + TUNA_HALF_SIZE.x:
		var half_span := SHARK_HALF_SIZE.x + TUNA_HALF_SIZE.x + 8.0
		var band := _wall_band(sample_x - half_span, sample_x + half_span)
		if band.y - band.x < TUNA_MIN_WATER_HEIGHT:
			return false
		sample_x += POINT_SPACING
	return true


## 固定泳道比例只跟随洞壁；鱼身两端的真实折线约束可避免小鱼进入岩层。
func _tuna_lane_y(world_x: float, lane: float) -> float:
	var band := _wall_band(world_x - TUNA_HALF_SIZE.x, world_x + TUNA_HALF_SIZE.x)
	var y := (band.x + band.y) * 0.5 + (band.y - band.x) * lane
	return clampf(y, band.x + TUNA_HALF_SIZE.y + 2.0, band.y - TUNA_HALF_SIZE.y - 2.0)


## 小步内逆向相对位移小于完整碰撞盒尺寸，使用真实矩形接触，长帧也不能穿过来鱼。
func _touches_tuna() -> bool:
	if not _hazards_enabled:
		return false
	var body := shark_rect()
	body.position.x += distance
	for tuna in tunas:
		if body.intersects(tuna_rect(tuna), true):
			return true
	return false


## 返回区间内最高洞顶和最低洞底，生成、碰撞及公平性检查共用真实折线。
func _wall_band(left: float, right: float) -> Vector2:
	var ceiling := maxf(ceiling_at(left), ceiling_at(right))
	var floor_y := minf(floor_at(left), floor_at(right))
	for point in cave_points:
		if point.x > right:
			break
		if point.x >= left:
			ceiling = maxf(ceiling, point.y)
			floor_y = minf(floor_y, point.z)
	return Vector2(ceiling, floor_y)


## 只保留可见区前后的小段洞壁，长时间游玩不积累离屏地形。
func _ensure_terrain() -> void:
	var ahead_limit := distance + WORLD_SIZE.x + LOOK_AHEAD
	while cave_points[-1].x < ahead_limit:
		_append_point()
	while cave_points.size() > 2 and cave_points[1].x < distance - KEEP_BEHIND:
		cave_points.remove_at(0)


## 通过缓慢追踪随机目标形成宽阔起伏；斜率和洞高受限，避免无解尖刺。
func _append_point() -> void:
	var previous := cave_points[-1]
	var next_x := previous.x + POINT_SPACING
	if next_x <= SAFE_RUNWAY:
		cave_points.append(Vector3(next_x, 58.0, 302.0))
		return
	var difficulty := clampf((next_x - SAFE_RUNWAY) / DIFFICULTY_DISTANCE, 0.0, 1.0)
	if next_x >= _target_until:
		if _first_bend_pending:
			# 第一处弯道随机朝上或朝下，保留长提前量，让玩家在安全直道后实际练习躲避。
			# 持续同一目标640px才能以既有小斜率完成收窄；不会直接移动岩壁或鲨鱼。
			_first_bend_pending = false
			_target_gap = _random.randf_range(148.0, 158.0)
			var edge_center := WALL_MARGIN + _target_gap * 0.5 + _random.randf_range(0.0, 8.0)
			_target_center = edge_center if _random.randi_range(0, 1) == 0 else WORLD_SIZE.y - edge_center
			_target_until = next_x + 640.0
		else:
			_target_gap = _random.randf_range(lerpf(148.0, MIN_GAP, difficulty), lerpf(210.0, 178.0, difficulty))
			var half_gap := _target_gap * 0.5
			_target_center = _random.randf_range(WALL_MARGIN + half_gap, WORLD_SIZE.y - WALL_MARGIN - half_gap)
			_target_until = next_x + _random.randf_range(144.0, 288.0)
	var center := (previous.y + previous.z) * 0.5
	var gap := previous.z - previous.y
	# 每 16px 中线最多移动 4px、洞高最多改变 3px，单侧斜率至多 5.5/16。
	center = move_toward(center, _target_center, 4.0)
	gap = move_toward(gap, _target_gap, 3.0)
	# 分别向合法目标追踪时若洞高增加，轻微夹紧中线，保证两侧始终留有岩层。
	center = clampf(center, WALL_MARGIN + gap * 0.5, WORLD_SIZE.y - WALL_MARGIN - gap * 0.5)
	cave_points.append(Vector3(next_x, center - gap * 0.5, center + gap * 0.5))


## 折线插值对绘图与碰撞保持一致，缓冲外只延续端点，避免越界读取。
func _wall_at(world_x: float, ceiling: bool) -> float:
	if cave_points.is_empty():
		return 0.0 if ceiling else WORLD_SIZE.y
	if not is_finite(world_x) or world_x <= cave_points[0].x:
		return cave_points[0].y if ceiling else cave_points[0].z
	if world_x >= cave_points[-1].x:
		return cave_points[-1].y if ceiling else cave_points[-1].z
	var index := clampi(int(floor((world_x - cave_points[0].x) / POINT_SPACING)), 0, cave_points.size() - 2)
	var left := cave_points[index]
	var right := cave_points[index + 1]
	var weight := clampf((world_x - left.x) / (right.x - left.x), 0.0, 1.0)
	return lerpf(left.y, right.y, weight) if ceiling else lerpf(left.z, right.z, weight)


## 矩形左右端加所有覆盖顶点就是折线极值，鼻端或中段擦到岩壁都算碰撞。
func _touches_wall() -> bool:
	var left := distance + SHARK_X - SHARK_HALF_SIZE.x
	var right := distance + SHARK_X + SHARK_HALF_SIZE.x
	var ceiling := maxf(ceiling_at(left), ceiling_at(right))
	var floor_y := minf(floor_at(left), floor_at(right))
	for point in cave_points:
		if point.x > right:
			break
		if point.x >= left:
			ceiling = maxf(ceiling, point.y)
			floor_y = minf(floor_y, point.z)
	return shark_y - SHARK_HALF_SIZE.y <= ceiling or shark_y + SHARK_HALF_SIZE.y >= floor_y
