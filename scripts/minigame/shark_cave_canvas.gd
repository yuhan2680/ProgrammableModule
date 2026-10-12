class_name SharkCaveCanvas
extends Node2D
## 固定低分辨率水下画布；洞壁严格取模拟边界，前景植物只呈现、不参与碰撞或随机模拟。

const SHARK_BODY := preload("res://assets/minigame/shark_body.svg")
const WATER_TOP := Color("2b6688")
const WATER_BOTTOM := Color("1d4868")
const ROCK := Color("101d33")
const EDGE := Color("233a52")
const PLANT_CELL_WIDTH := 38.0
const INTRO_TRAVEL_DISTANCE := 840.0
const INTRO_TRAVEL_TIME := 4.0

var run: SharkCaveRun
var decorative_time := 0.0
var menu_mode := true
var departure_progress: float = 0.0
var departure_active: bool = false
var departure_time: float = 0.0
var intro_active: bool = false
var intro_progress: float = 0.0
var intro_time: float = 0.0
var _menu_preview := SharkCaveRun.new()


## 低分辨率画布只输出整数像素，最终由最近邻采样放大。
func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# 菜单使用独立的稳定预览，不消耗真正一局的随机数或修改玩家分数。
	_menu_preview.start(72143, false)
	for index in 20:
		_menu_preview.advance(0.5, 0.0)
	_menu_preview.pause()


## 水色、远景光带和近景洞壁依次绘制，亮点数量固定避免影响读取通道。
func _draw() -> void:
	_draw_water()
	if run == null:
		return
	_draw_cave()
	_draw_bubbles()
	_draw_octopuses()
	_draw_tunas()
	var position := Vector2(SharkCaveRun.SHARK_X, run.shark_y)
	if menu_mode:
		position = Vector2(166, 183)
	if intro_active and not menu_mode:
		_draw_shark(intro_shark_position(), 0.75, intro_time)
	elif departure_active and not menu_mode:
		var progress := clampf(departure_progress, 0.0, 1.0)
		if progress < 1.0:
			position = departure_shark_position()
			_draw_shark(position, 0.75, decorative_time + departure_time)
	else:
		_draw_shark(position, 1.35 if menu_mode else 0.75)
	# 前景在世界内最后绘制，可挡在鲨鱼前方；菜单与按钮由外层 Control 绘制，不会被植物覆盖。
	_draw_foreground_plants()


## 水体四角颜色由渲染器连续插值，顶部浅蓝到底部深蓝没有色块接缝；其余物体仍用最近邻像素绘制。
func _draw_water() -> void:
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(640, 0), Vector2(640, 360), Vector2(0, 360)]),
		PackedColorArray([WATER_TOP, WATER_TOP, WATER_BOTTOM, WATER_BOTTOM]))
	var drift := int(decorative_time * 5.0) % 180
	for index in 5:
		var x := index * 180 - drift - 100
		draw_colored_polygon(PackedVector2Array([Vector2(x, 0), Vector2(x + 12, 0), Vector2(x + 116, 360), Vector2(x + 83, 360)]), Color(0.42, 0.72, 0.79, 0.035))


## 洞壁直接使用模型同一条折线；最近邻视口负责像素化，模型边界不额外取整。
func _draw_cave() -> void:
	if intro_active and not menu_mode and intro_progress < 1.0:
		_draw_intro_cave()
		return
	var terrain := _menu_preview if menu_mode else run
	# 只截取可见折线，并在真实左右端点垂直闭合；滚动后缓存首末点会变动，不能使用固定离屏闭合点。
	var top_points := PackedVector2Array([Vector2(0, 0), Vector2(0, terrain.ceiling_at(terrain.distance))])
	var bottom_points := PackedVector2Array([Vector2(0, 360), Vector2(0, terrain.floor_at(terrain.distance))])
	for point in terrain.cave_points:
		var x := point.x - terrain.distance
		if x <= 0.0 or x >= 640.0:
			continue
		top_points.append(Vector2(x, point.y))
		bottom_points.append(Vector2(x, point.z))
	top_points.append(Vector2(640, terrain.ceiling_at(terrain.distance + 640.0)))
	bottom_points.append(Vector2(640, terrain.floor_at(terrain.distance + 640.0)))
	top_points.append(Vector2(640, 0))
	bottom_points.append(Vector2(640, 360))
	draw_colored_polygon(top_points, EDGE)
	draw_colored_polygon(bottom_points, EDGE)
	for index in range(1, top_points.size() - 1):
		top_points[index].y -= 3.0
		bottom_points[index].y += 3.0
	draw_colored_polygon(top_points, ROCK)
	draw_colored_polygon(bottom_points, ROCK)
	_draw_rock_details()


## 苔藓和石纹绑定世界坐标随洞壁移动；水中的可穿行植物由独立前景步骤绘制。
func _draw_rock_details() -> void:
	var terrain := _menu_preview if menu_mode else run
	var view_distance := _view_distance(terrain)
	var first := floori(view_distance / 72.0)
	for index in range(first, first + 11):
		var world_x := float(index * 72 + posmod(index * 17, 27))
		var x := roundi(world_x - view_distance)
		var top := roundi(_intro_ceiling_at(world_x) if intro_active and not menu_mode else terrain.ceiling_at(world_x))
		var bottom := roundi(_intro_floor_at(world_x) if intro_active and not menu_mode else terrain.floor_at(world_x))
		var color := Color("25434e") if index % 3 == 0 else Color("24324b")
		if top >= 24:
			draw_rect(Rect2(x, top - 16, 9, 3), color)
			draw_rect(Rect2(x + 5, top - 21, 12, 2), Color("1b2d45"))
		draw_rect(Rect2(x, bottom + 15, 13, 2), Color("2b3850"))


## 稀疏气泡只在水域中显示，暂停时视觉时间保持静止。
func _draw_bubbles() -> void:
	var terrain := _menu_preview if menu_mode else run
	for index in 16:
		var x := posmod(index * 83 + 29 - int(decorative_time * (5 + index % 3)), 640)
		var y := posmod(index * 47 + 11 - int(decorative_time * 7.0), 340) + 10
		var world_x := _view_distance(terrain) + float(x)
		var bounds := Vector2(terrain.ceiling_at(world_x), terrain.floor_at(world_x))
		if intro_active and not menu_mode:
			bounds = intro_cave_bounds_at(float(x))
		if y < bounds.x + 14 or y > bounds.y - 14:
			continue
		var color := Color(0.65, 0.85, 0.85, 0.17 if index % 3 == 0 else 0.09)
		if index % 3 == 0:
			draw_rect(Rect2(x, y, 3, 3), color, false, 1)
		else:
			draw_rect(Rect2(x, y, 1, 1), color)


## 章鱼完全读取本局快照；菜单仅摆放一只不参与触发或碰撞的装饰章鱼。
func _draw_octopuses() -> void:
	if intro_active and not menu_mode:
		return
	if menu_mode:
		var x := 282.0
		var y := _menu_preview.floor_at(_menu_preview.distance + x) - 27.0
		_draw_octopus(Vector2(x, y), decorative_time, SharkCaveRun.OctopusState.IDLE, 0.0)
		return
	for octopus in run.octopuses:
		var center := Vector2(float(octopus.world_x) - run.distance, float(octopus.y))
		var cloud_center := run.ink_center(octopus) - Vector2(run.distance, 0.0)
		var radius := float(octopus.ink_radius)
		var body_scale := float(octopus.get("scale", 1.0))
		# 前向墨云可在本体离屏之后仍留在水道中，必须按两者并集裁剪，不能随本体过早消失。
		if maxf(center.x + 12.0 * body_scale, cloud_center.x + radius) < 0.0 or minf(center.x - 12.0 * body_scale, cloud_center.x - radius) > 640.0:
			continue
		var state := int(octopus.state)
		var timer := float(octopus.timer)
		if state == SharkCaveRun.OctopusState.INK:
			_draw_ink_cloud(cloud_center, radius, timer)
		_draw_octopus(center, run.elapsed + float(octopus.world_x) * 0.012, state, timer, body_scale)


## 逆行鱼只读取模型坐标，朝左游动；入场不生成危险物，暂停和失败时尾鳍也随模拟冻结。
func _draw_tunas() -> void:
	if menu_mode or intro_active:
		return
	for tuna in run.tunas:
		var center := Vector2(float(tuna.world_x) - run.distance, float(tuna.y))
		if center.x < -14.0 or center.x > 654.0:
			continue
		_draw_tuna(center, run.elapsed)


## 二十四像素银蓝金枪鱼约为鲨鱼外观的三分之一，左侧鱼头和右侧叉尾明确标示逆行方向。
func _draw_tuna(center: Vector2, animation_time: float) -> void:
	draw_set_transform(center.round())
	var outline := Color("152e49")
	var back := Color("3c719c")
	var silver := Color("c6dedb")
	var gold := Color("d7c478")
	var beat := roundi(sin(animation_time * 13.0))
	# 鱼鳍和叉尾属于外观；躯干中心与模型的小矩形碰撞区相同。
	draw_colored_polygon(PackedVector2Array([Vector2(5, 0), Vector2(12, -5 + beat), Vector2(10, 0), Vector2(12, 5 - beat)]), outline)
	draw_colored_polygon(PackedVector2Array([Vector2(7, 0), Vector2(11, -3 + beat), Vector2(9, 0), Vector2(11, 3 - beat)]), back)
	draw_colored_polygon(PackedVector2Array([Vector2(-4, -3), Vector2(0, -6), Vector2(2, -3)]), gold)
	draw_colored_polygon(PackedVector2Array([Vector2(-3, 3), Vector2(1, 6), Vector2(2, 3)]), gold)
	draw_rect(Rect2(-7, -4, 11, 8), outline)
	draw_rect(Rect2(-10, -2, 17, 4), outline)
	draw_rect(Rect2(-11, -1, 2, 2), outline)
	draw_rect(Rect2(-7, -3, 10, 3), back)
	draw_rect(Rect2(-9, -1, 15, 2), Color("87afb9"))
	draw_rect(Rect2(-7, 1, 10, 2), silver)
	draw_rect(Rect2(-9, 0, 3, 1), silver)
	draw_rect(Rect2(-8, -1, 2, 2), Color("eef4e7"))
	draw_rect(Rect2(-8, -1, 1, 1), outline)
	draw_rect(Rect2(-4, -1, 1, 3), back)
	draw_rect(Rect2(4, -2, 1, 1), gold)
	draw_rect(Rect2(4, 2, 1, 1), gold)
	draw_set_transform(Vector2.ZERO)


## 墨圆严格贴合模型的右前方碰撞范围；内部墨纹向右流动，不再表现为本体周围的径向爆炸。
func _draw_ink_cloud(center: Vector2, radius: float, timer: float) -> void:
	# 生效首帧即显示完整危险边界，喷流及纹理全部留在边界以内，不制造圆外的假伤害。
	draw_circle(center, radius, Color("594661"))
	draw_circle(center, maxf(0.0, radius - 1.0), Color("30263f"))
	var inner_radius := maxf(0.0, radius - 3.0)
	for index in 7:
		var sweep := fposmod(timer * 0.75 + float(index) * 0.173, 1.0)
		var offset := Vector2(lerpf(-0.72, 0.72, sweep), sin(float(index) * 2.2) * 0.46) * inner_radius
		var puff_radius := minf(4.0, maxf(0.0, radius - offset.length() - 2.0))
		draw_circle(center + offset, puff_radius, Color("3b2b49") if index % 2 == 0 else Color("45334e"))
	# 口端位于圆左沿，短墨线只从左向右推进；每条线都按所在高度的弦长限制在墨圆内部。
	if timer < 0.24:
		var burst := clampf(timer / 0.24, 0.0, 1.0)
		for index in 3:
			var y := float(index - 1) * inner_radius * 0.16
			var half_chord := sqrt(maxf(0.0, inner_radius * inner_radius - y * y))
			var from := Vector2(-half_chord, y)
			var to := Vector2(lerpf(-half_chord, half_chord * 0.55, burst), y)
			draw_line(center + from, center + to, Color("71546f"), 1.0)


## 原创十八像素小章鱼用阶梯矩形绘制，触手只轻摆一像素；预警亮色收缩与喷墨后的暗色明确区分。
func _draw_octopus(center: Vector2, animation_time: float, state: int, state_time: float, body_scale: float = 1.0) -> void:
	var warning := state == SharkCaveRun.OctopusState.WARNING
	var inking := state == SharkCaveRun.OctopusState.INK
	var spent := state == SharkCaveRun.OctopusState.SPENT
	var pulse := warning and posmod(int(state_time * 10.0), 2) == 0
	var ink := Color("483055")
	var body := Color("a277c6")
	var shadow := Color("77568f")
	var shine := Color("d4a8dc")
	if warning:
		body = Color("e1a1b0") if pulse else Color("ae72ad")
		shine = Color("ffe1c6") if pulse else Color("dba7cb")
		shadow = Color("b67d9f")
	elif inking:
		body = Color("8e6da2")
		shine = Color("ba91ba")
	elif spent:
		body = Color("796b98")
		shine = Color("a397b5")
		shadow = Color("655b7e")
	var contraction := 1 if warning else 0
	# 仅缩放章鱼本体和预警标记；墨圆已在外部按模型实际半径绘制，不能再次乘体型倍率。
	draw_set_transform(center.round(), 0.0, Vector2.ONE * clampf(body_scale, 0.4, 1.0))
	for arm in 4:
		var root_x := -6 + arm * 4
		var sway := roundi(sin(animation_time * 4.0 + float(arm) * 1.4))
		var reach := 8 - contraction * 2
		draw_rect(Rect2(root_x - 1, 2, 3, reach - 1), ink)
		draw_rect(Rect2(root_x, 3, 1, reach - 2), body)
		draw_rect(Rect2(root_x + sway - 1, reach, 3, 2), ink)
		draw_rect(Rect2(root_x + sway, reach, 2, 1), body)
		draw_rect(Rect2(root_x + sway, reach - 1, 1, 1), shine)
	draw_rect(Rect2(-3, -10 + contraction, 6, 2), ink)
	draw_rect(Rect2(-5, -8 + contraction, 10, 2), ink)
	draw_rect(Rect2(-7, -6 + contraction, 14, 9 - contraction), ink)
	draw_rect(Rect2(-6, 3, 12, 3), ink)
	draw_rect(Rect2(-3, -8 + contraction, 6, 2), body)
	draw_rect(Rect2(-5, -6 + contraction, 10, 9 - contraction), body)
	draw_rect(Rect2(-4, 3, 8, 2), shadow)
	draw_rect(Rect2(-3, -6 + contraction, 3, 2), shine)
	draw_rect(Rect2(-5, -4 + contraction, 2, 3), shine)
	for eye_x in [-4, 2]:
		draw_rect(Rect2(eye_x, -1, 3, 3), Color("f0e8e5"))
		draw_rect(Rect2(eye_x, 0, 2, 2), Color("322743"))
	# 朝右的小喷口与模型固定喷射方向一致；待机和预警只显示本体，不提前画出墨云。
	draw_rect(Rect2(5, 1, 4, 3), ink)
	draw_rect(Rect2(5, 1, 3, 2), shine if warning else body)
	draw_rect(Rect2(8, 2, 1, 1), Color("543455"))
	if warning:
		var alert := Color("ffe3b8") if pulse else Color("dbabbd")
		draw_rect(Rect2(-1, -17, 2, 4), alert)
		draw_rect(Rect2(-1, -11, 2, 1), alert)
	draw_set_transform(Vector2.ZERO)


## 鳍和尾部独立摆动，主躯干中心始终落在模型坐标上，避免视觉游动影响碰撞判断。
func _draw_shark(center: Vector2, art_scale: float, animation_time: float = -1.0) -> void:
	var anchor := (center - Vector2(58, 25) * art_scale).round()
	var tail_time := decorative_time if animation_time < 0.0 else animation_time
	var beat := roundi(sin(tail_time * 10.0) * 2.0)
	draw_set_transform(anchor, 0, Vector2.ONE * art_scale)
	var tail := PackedVector2Array([Vector2(33, 23), Vector2(24, 23), Vector2(16, 16 + beat), Vector2(10, 8 + beat), Vector2(4, 8 + beat), Vector2(8, 20), Vector2(17, 27), Vector2(10, 33 - beat), Vector2(7, 40 - beat), Vector2(13, 38 - beat), Vector2(24, 30), Vector2(34, 30)])
	draw_colored_polygon(tail, Color("10364e"))
	var tail_inner := PackedVector2Array([Vector2(33, 25), Vector2(23, 25), Vector2(15, 18 + beat), Vector2(9, 11 + beat), Vector2(8, 11 + beat), Vector2(11, 20), Vector2(21, 27), Vector2(12, 35 - beat), Vector2(12, 36 - beat), Vector2(24, 28), Vector2(34, 28)])
	draw_colored_polygon(tail_inner, Color("3ba1b0"))
	draw_texture_rect(SHARK_BODY, Rect2(0, 0, 96, 48), false)
	draw_set_transform(Vector2.ZERO)


## 失败离场只计算视觉位置，先从碰撞点平滑游向通道中线再向右离屏，绝不修改已冻结的模拟坐标。
func departure_shark_position() -> Vector2:
	if run == null:
		return Vector2(SharkCaveRun.SHARK_X, SharkCaveRun.WORLD_SIZE.y * 0.5)
	var progress := clampf(departure_progress, 0.0, 1.0)
	var x := lerpf(SharkCaveRun.SHARK_X, SharkCaveRun.WORLD_SIZE.x + 80.0, progress)
	var world_x := run.distance + x
	var center_y := (run.ceiling_at(world_x) + run.floor_at(world_x)) * 0.5
	var y := lerpf(run.shark_y, center_y, smoothstep(0.0, 0.35, progress))
	return Vector2(x, y)


## 入场只移动观察距离，从开阔海域接近洞口；终点速度衔接初始游玩速度，终点距离严格回到模型值。
func intro_view_distance() -> float:
	var progress := clampf(intro_progress, 0.0, 1.0)
	var easing := 1.0 - SharkCaveRun.INITIAL_SPEED * INTRO_TRAVEL_TIME / INTRO_TRAVEL_DISTANCE
	var travel := progress + easing * progress * (1.0 - progress)
	return (run.distance if run != null else 0.0) - INTRO_TRAVEL_DISTANCE * (1.0 - travel)


## 自动游动先向右进入画面并轻微上下摆动，最后精确落到可操作的初始坐标，不写入真实鲨鱼状态。
func intro_shark_position() -> Vector2:
	var progress := clampf(intro_progress, 0.0, 1.0)
	var initial_y := run.shark_y if run != null else SharkCaveRun.WORLD_SIZE.y * 0.5
	var x := lerpf(58.0, SharkCaveRun.SHARK_X, smoothstep(0.0, 0.45, progress))
	var bob := sin(intro_time * 2.1) * 5.0 * (1.0 - smoothstep(0.65, 1.0, progress))
	return Vector2(x, initial_y + bob)


## 对外提供入场时的可见上下边界，便于验证开阔水域和正式洞穴首帧完全衔接。
func intro_cave_bounds_at(screen_x: float) -> Vector2:
	var world_x := intro_view_distance() + screen_x
	return Vector2(_intro_ceiling_at(world_x), _intro_floor_at(world_x))


## 正常游玩保持真实距离，只有入场影像使用负方向的观察偏移。
func _view_distance(terrain: SharkCaveRun) -> float:
	return intro_view_distance() if intro_active and not menu_mode else terrain.distance


## 洞口之前没有顶壁，进入口缘后逐步出现岩顶；口缘在交接时已完全移出屏幕左边。
func _intro_ceiling_at(world_x: float) -> float:
	if run == null:
		return 0.0
	return run.ceiling_at(world_x) * smoothstep(-120.0, -48.0, world_x)


## 开阔海床由固定世界波形起伏，到洞口后并入真实洞底，既不重新生成地图也不读取随机源。
func _intro_floor_at(world_x: float) -> float:
	if run == null:
		return 326.0
	var phase := float(run.visual_seed % 31) * 0.21
	var seabed := 326.0 + sin(world_x * 0.027 + phase) * 6.0 + sin(world_x * 0.011) * 4.0
	return lerpf(seabed, run.floor_at(world_x), smoothstep(-120.0, -48.0, world_x))


## 绘制向左接近的洞口和海床；没有岩顶时跳过空多边形，避免三角化退化。
func _draw_intro_cave() -> void:
	_draw_intro_wall(true, 0.0, EDGE)
	_draw_intro_wall(true, 3.0, ROCK)
	_draw_intro_wall(false, 0.0, EDGE)
	_draw_intro_wall(false, 3.0, ROCK)
	_draw_rock_details()


## 将视觉洞口采样成单调横向折线并垂直闭合，只绘制有面积的岩层，保持像素硬边。
func _draw_intro_wall(ceiling: bool, inset: float, color: Color) -> void:
	var points := PackedVector2Array()
	for x in range(0, 641, 8):
		var bounds := intro_cave_bounds_at(float(x))
		var y := maxf(0.0, bounds.x - inset) if ceiling else minf(360.0, bounds.y + inset)
		if ceiling and y <= 0.025:
			continue
		if points.is_empty():
			points.append(Vector2(maxi(0, x - 8) if ceiling else 0, 0.0 if ceiling else 360.0))
		points.append(Vector2(x, y))
	if points.size() < 2:
		return
	points.append(Vector2(640, 0.0 if ceiling else 360.0))
	draw_colored_polygon(points, color)


## 返回可见世界范围内的植物描述，供绘制和约束回归共用；查询不消耗任何随机数或修改本局。
func foreground_plant_specs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var terrain := _menu_preview if menu_mode else run
	if terrain == null:
		return result
	var view_distance := _view_distance(terrain)
	var first := floori((view_distance - 24.0) / PLANT_CELL_WIDTH)
	var last := floori((view_distance + 664.0) / PLANT_CELL_WIDTH)
	for cell in range(first, last + 1):
		if _plant_hash(terrain.visual_seed, cell, 0) < 0.18:
			continue
		var world_x := (float(cell) + 0.5) * PLANT_CELL_WIDTH + lerpf(-12.0, 12.0, _plant_hash(terrain.visual_seed, cell, 1))
		var root_y := _intro_floor_at(world_x) if intro_active and not menu_mode else terrain.floor_at(world_x)
		var ceiling_y := _intro_ceiling_at(world_x) if intro_active and not menu_mode else terrain.ceiling_at(world_x)
		var passage := root_y - ceiling_y
		var tall := _plant_hash(terrain.visual_seed, cell, 2) < 0.12
		var height := lerpf(35.0, 60.0, _plant_hash(terrain.visual_seed, cell, 3)) if tall else lerpf(10.0, 22.0, _plant_hash(terrain.visual_seed, cell, 3))
		height = minf(height, passage * 0.45)
		var kind := "kelp" if tall else ("coral" if _plant_hash(terrain.visual_seed, cell, 4) < 0.20 else "grass")
		result.append({"world_x": world_x, "root_y": root_y, "height": height, "kind": kind,
			"width": lerpf(10.0, 20.0, _plant_hash(terrain.visual_seed, cell, 5)),
			"phase": _plant_hash(terrain.visual_seed, cell, 6) * TAU,
			"palette": mini(2, int(_plant_hash(terrain.visual_seed, cell, 7) * 3.0))})
	return result


## 有界整数混合生成稳定外观，世界格与盐分离；不创建随机源，也不读取或推进模型随机状态。
func _plant_hash(seed_value: int, cell: int, salt: int) -> float:
	var value := (seed_value ^ (cell * 374761393) ^ (salt * 668265263)) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	value ^= value >> 16
	return float(value & 0xffff) / 65535.0


## 最后叠加可穿行的海草与珊瑚，根部跟随真实洞底；模拟暂停时所有摆动保持当前帧。
func _draw_foreground_plants() -> void:
	var terrain := _menu_preview if menu_mode else run
	var animation_time := foreground_animation_time()
	for spec in foreground_plant_specs():
		var origin := Vector2(float(spec.world_x) - _view_distance(terrain), float(spec.root_y))
		draw_set_transform(origin.round())
		if spec.kind == "coral":
			_draw_foreground_coral(spec)
		else:
			_draw_foreground_grass(spec, animation_time)
		draw_set_transform(Vector2.ZERO)


## 前景使用表现层连续时钟，入场期间模型为零也能摆动；暂停或终局由外壳冻结同一时钟。
func foreground_animation_time() -> float:
	return decorative_time


## 海草分为低矮草簇和少量高叶；逐段像素摆动随高度增加，根部始终保持固定。
func _draw_foreground_grass(spec: Dictionary, animation_time: float) -> void:
	var palettes := [
		[Color("28584f"), Color("3e8274"), Color("6aab91")],
		[Color("285760"), Color("3c7d87"), Color("67a6ad")],
		[Color("345d4c"), Color("54836c"), Color("83ad83")],
	]
	var colors: Array = palettes[int(spec.palette)]
	var tall: bool = String(spec.kind) == "kelp"
	var count := 3 if tall else 4
	for blade in count:
		var spacing := float(spec.width) / (7.0 if tall else 6.0)
		var base_x := (float(blade) - float(count - 1) * 0.5) * spacing
		var height := float(spec.height) * (1.0 - 0.14 * float(abs(blade - 1)))
		var phase := float(spec.phase) + float(blade) * 1.7
		var lean := sin(phase) * (3.0 if tall else 2.0)
		for step in range(1, ceili(height / 2.0) + 1):
			var rise := minf(height, float(step) * 2.0)
			var weight := rise / height
			var sway := sin(animation_time * 1.65 + phase + weight * 1.8) * (2.0 if tall else 1.0)
			var x := roundf(base_x + (lean + sway) * weight)
			draw_rect(Rect2(x, -rise, 2, minf(2.0, rise)), colors[0])
			draw_rect(Rect2(x, -rise, 1, minf(2.0, rise)), colors[1])
			if tall and step % 5 == 0 and weight < 0.85:
				var side := -1.0 if (int(step / 5) + blade) % 2 == 0 else 1.0
				var leaf_x := x - 5.0 if side < 0.0 else x + 1.0
				draw_rect(Rect2(leaf_x, -rise, 6, 2), colors[1])
				draw_rect(Rect2(leaf_x + 1, -rise - 1, 3, 1), colors[2])
		draw_rect(Rect2(roundf(base_x + lean + sin(animation_time * 1.65 + phase + 1.8) * (2.0 if tall else 1.0)), -height, 1, 2), colors[2])
	draw_rect(Rect2(-3, -1, 7, 2), colors[0])


## 小珊瑚采用静止分叉与低饱和粉紫点缀，细小分支保持低于描述高度且没有碰撞实体。
func _draw_foreground_coral(spec: Dictionary) -> void:
	var height := float(spec.height)
	var half_width := float(spec.width) * 0.5
	var dark := Color("68536f")
	var body := Color("987b93")
	var tip := Color("b4a1ad")
	if int(spec.palette) == 1:
		dark = Color("67565a")
		body = Color("947f78")
		tip = Color("b5a397")
	draw_rect(Rect2(-2, -height, 4, height + 1.0), dark)
	draw_rect(Rect2(-1, -height, 2, height), body)
	for side in [-1, 1]:
		var branch_x := roundf(float(side) * half_width * 0.65)
		var branch_y := -roundf(height * (0.65 if side < 0 else 0.82))
		draw_rect(Rect2(minf(0.0, branch_x), -height * 0.3, absf(branch_x) + 2.0, 3), dark)
		draw_rect(Rect2(branch_x, branch_y, 3, -branch_y - height * 0.3 + 2.0), dark)
		draw_rect(Rect2(branch_x + 1, branch_y, 1, -branch_y - height * 0.3 + 1.0), body)
		draw_rect(Rect2(branch_x - 1, branch_y, 4, 2), body)
		draw_rect(Rect2(branch_x, branch_y, 2, 1), tip)
	draw_rect(Rect2(-2, -height, 4, 2), tip)
