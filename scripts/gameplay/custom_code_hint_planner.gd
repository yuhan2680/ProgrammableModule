class_name CustomCodeHintPlanner
extends RefCounted
## 玩家地图只根据实际几何、装配和目标推导有限候选，不读取作者答案或教学关卡编号。
## 候选先在隔离会话中完整通关；搜索不足时返回说明，绝不把未验证方案写给玩家。

const MAX_ROUTE_NODES := 8192
const MAX_ROUTE_ACTIONS := 192
const MAX_CANDIDATES := 24
const MAX_WORLD_ENTITIES := 256
const MAX_WORLD_MODULES := 1024
const MAX_WORLD_CELLS := 16384
const ROUTE_STEP := 0.5
const SEARCH_FAILURE := "未能在本次搜索范围内找到适合当前装配的通关方案。请调整装配或参考关卡指引后重试。"


## 生成并验证与当前地图和真实装配一致的方案，墙钟预算由调用方统一控制。
static func find_source(session: GameSession, deadline: int) -> DataResult:
	if Time.get_ticks_usec() >= deadline or not _within_world_budget(session):
		return DataResult.failure(SEARCH_FAILURE)
	var assembled := session.assembly.build_document()
	if not assembled.is_ok():
		return assembled
	var created := SimulationWorld.create(assembled.value, session.assembly.content)
	if not created.is_ok():
		return created
	var world: SimulationWorld = created.value
	var candidates: Array[String] = []
	var level := session.level
	if world.player.get_move_speed() > 0.0 and level.has_goal and level.goal_type == "reach_position":
		var route := _find_route(world, level.goal_position, level.goal_radius, mini(deadline, Time.get_ticks_usec() + 800000))
		if not route.is_empty():
			candidates.append(_route_source(route, level, world.player))
	# 动态目标优先使用真实雷达查询；固定射线方案仍须通过同一模拟验证。
	candidates.append_array(_combat_sources(session, world, deadline))
	var checked := {}
	for source: String in candidates:
		if Time.get_ticks_usec() >= deadline or checked.size() >= MAX_CANDIDATES:
			break
		if source.is_empty() or checked.has(source) or source.to_utf8_buffer().size() > CodeHintService.MAX_SOURCE_BYTES:
			continue
		checked[source] = true
		# 给每个候选独立的有限时间，避免第一条不合适的循环耗尽所有搜索机会。
		var trial_deadline := mini(deadline, Time.get_ticks_usec() + 700000)
		if CodeHintService._wins(session, source, CodeHintService.MAX_STEPS, trial_deadline):
			return DataResult.success(source)
	return DataResult.failure(SEARCH_FAILURE)


## 建立模拟副本之前限制规划规模，避免合法大地图的复制和目标笛卡尔积阻塞界面。
static func _within_world_budget(session: GameSession) -> bool:
	var document := session.level.document
	if document.cells.size() > MAX_WORLD_CELLS or document.enemies.size() + document.objects.size() > MAX_WORLD_ENTITIES:
		return false
	var module_count := session.assembly.modules.size()
	for enemy: Dictionary in document.enemies:
		module_count += enemy.get("modules", []).size()
		if module_count > MAX_WORLD_MODULES:
			return false
	return module_count <= MAX_WORLD_MODULES


## 半格广度搜索复用模拟的整机扫掠，保留模块真实尺寸、偏移与闸门障碍。
static func _find_route(world: SimulationWorld, target: Vector2, radius: float, deadline: int) -> Array[Vector2]:
	var start := world.player.position
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	var parents := {Vector2i.ZERO: Vector2i.ZERO}
	var cursor := 0
	var directions: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.UP, Vector2i.LEFT, Vector2i.DOWN]
	while cursor < queue.size() and parents.size() <= MAX_ROUTE_NODES and Time.get_ticks_usec() < deadline:
		var cell := queue[cursor]
		cursor += 1
		var origin := start + Vector2(cell) * ROUTE_STEP
		var delta := target - origin
		# 终点允许非半格坐标，最后一小段仍检查完整连续运动路径。
		if delta.length() <= radius or (delta.length() <= 1.0 and world.get_movement_fraction(world.player, origin, delta) >= 1.0):
			var path: Array[Vector2] = []
			if delta.length() > radius:
				path.append(target)
			var trace := cell
			while trace != Vector2i.ZERO:
				path.append(start + Vector2(trace) * ROUTE_STEP)
				trace = parents[trace]
			path.append(start)
			path.reverse()
			return path
		for direction: Vector2i in directions:
			var next := cell + direction
			if parents.has(next):
				continue
			var displacement := Vector2(direction) * ROUTE_STEP
			if world.get_movement_fraction(world.player, origin, displacement) < 1.0:
				continue
			parents[next] = cell
			queue.append(next)
	return []


## 合并同方向相邻位移，保留每次拐弯；输出有限直线动作供逐行补丁使用。
static func _route_source(path: Array[Vector2], level: LevelDefinition, machine: MachineInstance) -> String:
	var move_call := "move"
	if level.has_command_policy and not "move" in level.enabled_commands:
		for module: ModuleInstance in machine.modules:
			if module.get_move_speed() > 0.0:
				move_call = _call(level, module, "move")
				break
	var lines: Array[String] = []
	var direction := Vector2.ZERO
	var distance := 0.0
	for index in range(1, path.size()):
		var delta := path[index] - path[index - 1]
		if delta.length() <= 0.000001:
			continue
		var next_direction := delta.normalized()
		if distance > 0.0 and not next_direction.is_equal_approx(direction):
			lines.append("%s(%s, %s)" % [move_call, _number(_angle(direction)), _number(distance)])
			distance = 0.0
		direction = next_direction
		distance += delta.length()
	if distance > 0.0:
		lines.append("%s(%s, %s)" % [move_call, _number(_angle(direction)), _number(distance)])
	if lines.size() > MAX_ROUTE_ACTIONS:
		return ""
	return _main(lines)


## 从实际攻击模块及目标位置生成雷达跟踪、定向攻击和有限角度扫描候选。
static func _combat_sources(session: GameSession, world: SimulationWorld, deadline: int) -> Array[String]:
	var result: Array[String] = []
	var level := session.level
	var weapons: Array[ModuleInstance] = []
	var radar: ModuleInstance = null
	for module: ModuleInstance in world.player.modules:
		if Time.get_ticks_usec() >= deadline:
			return result
		if module.definition.behavior in ["ShootingModule", "MeleeModule"] and weapons.size() < 4:
			weapons.append(module)
		elif radar == null and module.definition.behavior == "RadarModule":
			radar = module
	if weapons.is_empty():
		return result
	if radar != null and level.allow_radar and level.allow_conditionals:
		var scan := _call(level, radar, "scan") + "()"
		for weapon: ModuleInstance in weapons:
			if Time.get_ticks_usec() >= deadline:
				return result.slice(0, MAX_CANDIDATES)
			var action := "shoot" if weapon.definition.behavior == "ShootingModule" else "attack"
			var attack := _call(level, weapon, action) + "(" + scan + ".Angle())"
			var standing := "if (%s != null) {\n    %s\n}" % [scan, attack]
			result.append_array(_repeat_sources(standing, level))
			if world.player.get_move_speed() > 0.0:
				var reach := 2.0 if action == "shoot" else 1.0
				var pursuing := "if (%s != null) {\n    if (%s.Distance > %s) {\n        move(%s.Angle(), 0.3)\n    } else {\n        %s\n    }\n} else {\n    move(0, 0)\n}" % [scan, scan, _number(reach), scan, attack]
				result.append_array(_repeat_sources(pursuing, level))
	var targets: Array[Vector2] = []
	for object: WorldObject in world.objects:
		if Time.get_ticks_usec() >= deadline:
			return result.slice(0, MAX_CANDIDATES)
		if object.definition.kind not in ["timed_gate", "security_gate"] and targets.size() < 64:
			targets.append(object.definition.rect.get_center())
	for entry: Dictionary in level.document.enemies:
		if targets.size() >= 64 or Time.get_ticks_usec() >= deadline:
			break
		if entry.get("behavior") not in EnemyDefinition.BEHAVIORS:
			continue
		var position := Vector2(float(entry.position.x), float(entry.position.y))
		for module: Dictionary in entry.modules:
			if targets.size() >= 64:
				break
			var offset: Dictionary = module.get("offset", {})
			targets.append(position + Vector2(float(offset.get("x", 0.0)), float(offset.get("y", 0.0))))
	var aimed: Array[String] = []
	for weapon: ModuleInstance in weapons:
		if Time.get_ticks_usec() >= deadline:
			return result.slice(0, MAX_CANDIDATES)
		var action := "shoot" if weapon.definition.behavior == "ShootingModule" else "attack"
		for target: Vector2 in targets:
			var delta := target - (world.player.position + weapon.local_position)
			var line := "%s(%s)" % [_call(level, weapon, action), _number(_angle(delta))]
			if not line in aimed:
				aimed.append(line)
	if not aimed.is_empty() and aimed.size() <= 64:
		result.append_array(_repeat_sources("\n".join(aimed), level))
	# 不借用波次编号；没有雷达时只尝试有限方向，无法验证就返回搜索不足说明。
	var radial: Array[String] = []
	for weapon: ModuleInstance in weapons:
		if Time.get_ticks_usec() >= deadline:
			return result.slice(0, MAX_CANDIDATES)
		var action := "shoot" if weapon.definition.behavior == "ShootingModule" else "attack"
		for angle: int in range(0, 360, 45):
			radial.append("%s(%d)" % [_call(level, weapon, action), angle])
		if radial.size() >= 64:
			break
	result.append_array(_repeat_sources("\n".join(radial), level))
	return result.slice(0, MAX_CANDIDATES)


## 优先使用本关开放的持续入口，并保留有限展开作为权限不足时的候选。
static func _repeat_sources(body: String, level: LevelDefinition) -> Array[String]:
	var sources: Array[String] = []
	if level.allow_loops:
		sources.append(_main(["loop {\n" + _indent(body) + "\n}"]))
	if level.allow_tick:
		sources.append("main() {\n}\ntick() {\n" + _indent(body) + "\n}\n")
	# 展开限制兼顾源码树节点上限；最终解析器仍严格检查本关指令允许列表。
	var repeats := clampi(128 / maxi(1, body.count("\n") + 1), 1, 32)
	var lines: Array[String] = []
	for unused in repeats:
		lines.append(body)
	sources.append(_main(lines))
	return sources


## 命名能力开放时使用真实实例名，否则保留语言已有的广播或唯一来源调用。
static func _call(level: LevelDefinition, module: ModuleInstance, action: String) -> String:
	var named_allowed := level.allow_named_calls and (not level.has_command_policy or "named_" + action in level.enabled_commands)
	return module.id + "." + action if named_allowed else action


## 主入口统一以普通 DSL 文本组装，不读写任何作者程序或教学答案。
static func _main(lines: Array[String]) -> String:
	return "main() {\n" + (_indent("\n".join(lines)) + "\n" if not lines.is_empty() else "") + "}\n"


## 每层只增加四个空格，使逐步补丁保持稳定且可读的源码结构。
static func _indent(source: String) -> String:
	return "    " + source.replace("\n", "\n    ")


## 与模拟角度约定一致：右为零度，上为九十度。
static func _angle(displacement: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(-displacement.y, displacement.x)), 360.0)


## 输出固定精度有限数字，避免科学计数法超出游戏语言的词法范围。
static func _number(value: float) -> String:
	return ("%.6f" % value).rstrip("0").trim_suffix(".") if not is_zero_approx(value) else "0"
