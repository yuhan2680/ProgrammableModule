class_name TerrainCollision
extends RefCounted
## 纯数据地形碰撞：未指定、越界或未知地块均不可通行。
## 不使用显示像素，也不依赖 Godot 物理节点，便于固定 tick 与无窗口测试。

const EPSILON: float = 0.000001


## 检查整个模块矩形是否获得可通行地块支撑，边缘接触允许。
static func is_rect_supported(rect: Rect2, document: MapDocument, content: ContentRegistry) -> bool:
	if not rect.position.is_finite() or not rect.size.is_finite() or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	if rect.position.x < -EPSILON or rect.position.y < -EPSILON:
		return false
	if rect.end.x > document.width + EPSILON or rect.end.y > document.height + EPSILON:
		return false
	var first := Vector2i(floori(rect.position.x + EPSILON), floori(rect.position.y + EPSILON))
	var last := Vector2i(ceili(rect.end.x - EPSILON) - 1, ceili(rect.end.y - EPSILON) - 1)
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			if not is_cell_passable(Vector2i(x, y), document, content):
				return false
	return true


## 统一通行规则；不以 floor 等具体 ID 分支，新增地块直接使用属性。
static func is_cell_passable(cell: Vector2i, document: MapDocument, content: ContentRegistry) -> bool:
	if not document.in_bounds(cell):
		return false
	var tile_id := document.get_tile_id(cell)
	if tile_id.is_empty():
		return false
	var tile := content.get_tile(tile_id)
	return tile != null and not tile.collision


## 攻击遮挡独立于移动碰撞；未指定、未知和越界地块仍阻挡全部攻击。
static func is_cell_attack_blocking(cell: Vector2i, document: MapDocument, content: ContentRegistry) -> bool:
	if not document.in_bounds(cell):
		return true
	var tile := content.get_tile(document.get_tile_id(cell))
	return tile == null or tile.attack_block


## 返回整台机器在位移路径中可安全前进的比例，逐模块扫描避免跨过 void。
static func sweep_machine(machine: MachineInstance, displacement: Vector2, document: MapDocument, content: ContentRegistry) -> float:
	var fraction := 1.0
	for module in machine.modules:
		if not module.available:
			continue
		var rect := module.get_world_rect(machine.position)
		if not is_rect_supported(rect, document, content):
			return 0.0
		fraction = minf(fraction, _sweep_rect(rect, displacement, document, content))
	return fraction


## 扫描矩形扫过的网格包围区域并求最早碰撞，不用离散小步近似。
static func _sweep_rect(rect: Rect2, displacement: Vector2, document: MapDocument, content: ContentRegistry) -> float:
	var fraction := _bounds_fraction(rect, displacement, Vector2(document.width, document.height))
	var end_rect := Rect2(rect.position + displacement * fraction, rect.size)
	var swept_bounds := rect.merge(end_rect)
	# 先裁剪到地图，极大距离也不会导致遍历地图之外的无限 void。
	var first := Vector2i(maxi(0, floori(swept_bounds.position.x)), maxi(0, floori(swept_bounds.position.y)))
	var last := Vector2i(mini(document.width - 1, floori(swept_bounds.end.x)), mini(document.height - 1, floori(swept_bounds.end.y)))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			if is_cell_passable(Vector2i(x, y), document, content):
				continue
			var entry := _entry_fraction(rect, displacement, Rect2(Vector2(x, y), Vector2.ONE))
			fraction = minf(fraction, entry)
	return clampf(fraction, 0.0, 1.0)


## 地图以外全部是 void；直接计算边界接触时间，避免生成边界碰撞体。
static func _bounds_fraction(rect: Rect2, displacement: Vector2, map_size: Vector2) -> float:
	var fraction := 1.0
	for axis in range(2):
		if displacement[axis] > 0.0:
			fraction = minf(fraction, (map_size[axis] - rect.end[axis]) / displacement[axis])
		elif displacement[axis] < 0.0:
			fraction = minf(fraction, -rect.position[axis] / displacement[axis])
	return clampf(fraction, 0.0, 1.0)


## 扫描模块与动态正方形的碰撞；已有正面积交叠立即受阻，贴边仍可离开。
static func sweep_obstacle(rect: Rect2, displacement: Vector2, obstacle: Rect2) -> float:
	if rect.intersects(obstacle):
		return 0.0
	return _entry_fraction(rect, displacement, obstacle)


## 用 Minkowski 扩张与 slab 相交求 swept AABB；只接触边缘或角点不算穿入。
static func _entry_fraction(rect: Rect2, displacement: Vector2, obstacle: Rect2) -> float:
	var center := rect.get_center()
	var lower := obstacle.position - rect.size * 0.5
	var upper := obstacle.end + rect.size * 0.5
	var entry := -INF
	var exit_time := INF
	for axis in range(2):
		var speed: float = displacement[axis]
		if absf(speed) < EPSILON:
			if center[axis] <= lower[axis] + EPSILON or center[axis] >= upper[axis] - EPSILON:
				return 1.0
			continue
		var first_time: float = (lower[axis] - center[axis]) / speed
		var second_time: float = (upper[axis] - center[axis]) / speed
		entry = maxf(entry, minf(first_time, second_time))
		exit_time = minf(exit_time, maxf(first_time, second_time))
	if entry >= exit_time or exit_time <= 0.0 or entry >= 1.0:
		return 1.0
	return maxf(0.0, entry)
