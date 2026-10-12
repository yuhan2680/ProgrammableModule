extends SceneTree
## 以真实测距、条件与移动运行第十六关；只使用独立内存会话，不读写玩家作品。

const SPAWN := Vector2(1.25, 1.5)
const EXIT := Vector2(25.25, 15.5)
const NEIGHBORS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const SOLUTION := """main() {
    variable heading = 0
    loop {
        heading = heading - 90
        if (heading < 0) {
            heading = heading + 360
        }
        if (sensor.distance(heading) < 1) {
            heading = heading + 90
            if (sensor.distance(heading) < 1) {
                heading = heading + 90
                if (sensor.distance(heading) < 1) {
                    heading = heading + 90
                }
            }
        }
        if (heading >= 360) {
            heading = heading - 360
        }
        drive.move(heading, 1)
    }
}
"""

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition


## 等待 Godot 注册全局数据类型后启动独立关卡验证。
func _initialize() -> void:
	_run.call_deferred()


## 先检查正式地图，再验证自适应导航、真实碰撞及暂停重试。
func _run() -> void:
	if not _check(_content.load_directories().is_ok(), "逃脱关卡加载生产内容"):
		_finish()
		return
	var loaded := MapCodec.load_file("res://data/levels/level_016.json", _content, true)
	if not _check(loaded.is_ok(), "第十六关地图合法：" + str(loaded.errors)):
		_finish()
		return
	var defined := LevelDefinition.from_document(loaded.value, _content, "res://data/levels/level_016.json")
	if not _check(defined.is_ok(), "第十六关规则合法：" + str(defined.errors)):
		_finish()
		return
	_level = defined.value
	_test_definition_and_maze()
	_test_prior_permissions()
	_test_adaptive_solution()
	_test_rotated_maze()
	_test_assembly_and_failures()
	_test_pause_and_retry()
	_finish()


## 地图必须是有分叉、死路且全部连通的单格迷宫，不能把大片空地当作迷宫。
func _test_definition_and_maze() -> void:
	_check(_level.id == "level_016" and _level.order == 16 and _level.display_name == "第十六关 · 逃脱", "使用用户确认的第十六关逃脱名称与稳定编号")
	_check(_level.document.width == 27 and _level.document.height == 17, "迷宫保持 27 × 17 尺寸")
	_check(_level.module_limit == 2 and _level.max_ticks == 0, "最多两个模块，探索不额外设置限时")
	_check(_level.goal_type == "reach_position" and _level.goal_position == EXIT and _level.goal_radius <= .25, "右下角实际位置作为唯一通关目标")
	var spawn: Dictionary = _level.document.player_spawn.position
	_check(Vector2(float(spawn.x), float(spawn.y)) == SPAWN, "左上角出生点为两模块单格转弯保留净空")
	_check(_level.document.enemies.is_empty() and _level.document.objects.is_empty(), "逃脱不添加敌人、机关或隐藏战斗门槛")
	_check(_level.starter_program.strip_edges().replace(" ", "").replace("\t", "").replace("\n", "") == "main(){}", "初始程序只有空 main，不提前填入解法")
	var floor_cells := {}
	var closed_boundary := true
	for y in _level.document.height:
		for x in _level.document.width:
			var cell := Vector2i(x, y)
			if TerrainCollision.is_cell_passable(cell, _level.document, _content):
				floor_cells[cell] = true
				if x == 0 or y == 0 or x == 26 or y == 16:
					closed_boundary = false
	_check(closed_boundary and not TerrainCollision.is_cell_passable(Vector2i(-1, 1), _level.document, _content), "外围墙体闭合，地图外继续不可通行")
	_check(floor_cells.has(Vector2i(1, 1)) and floor_cells.has(Vector2i(25, 15)), "起终点分别位于左上和右下通道")
	var visited := {Vector2i(1, 1): 0}
	var queue: Array[Vector2i] = [Vector2i(1, 1)]
	var cursor := 0
	var edges := 0
	var junctions := 0
	var dead_ends := 0
	while cursor < queue.size():
		var cell: Vector2i = queue[cursor]
		cursor += 1
		var neighbors := 0
		for offset: Vector2i in NEIGHBORS:
			var adjacent := cell + offset
			if not floor_cells.has(adjacent):
				continue
			neighbors += 1
			if not visited.has(adjacent):
				visited[adjacent] = int(visited[cell]) + 1
				queue.append(adjacent)
		edges += neighbors
		if neighbors >= 3:
			junctions += 1
		if neighbors == 1:
			dead_ends += 1
	_check(visited.size() == floor_cells.size() and visited.has(Vector2i(25, 15)), "所有通道连通且出口可达，没有隔离区域")
	_check(edges == (floor_cells.size() - 1) * 2, "迷宫通道构成无环连通图，沿墙探索不会困在独立岛中")
	_check(junctions >= 3 and dead_ends >= 5, "存在足够的分叉和死路，需要实际选择方向与回退")
	_check(int(visited.get(Vector2i(25, 15), 0)) > 38, "出口路线需要绕行，不能只向右再向下直达")
	var catalog := LevelCatalog.new()
	catalog.user_directory = "user://tests/escape_no_imported_levels"
	_check(catalog.refresh(_content).is_ok() and catalog.levels.size() == 16 and catalog.levels.back().id == "level_016", "目录收录十六个教学关卡且逃脱排在最后")


## 新关只继承既有能力，前十五关的逐关权限继续从各自数据读取。
func _test_prior_permissions() -> void:
	var prior_loaded := MapCodec.load_file("res://data/levels/level_015.json", _content, true)
	if not _check(prior_loaded.is_ok(), "原第十五关仍可读取"):
		return
	var prior_result := LevelDefinition.from_document(prior_loaded.value, _content)
	if not _check(prior_result.is_ok(), "原第十五关规则仍有效"):
		return
	var prior: LevelDefinition = prior_result.value
	_check(_level.allowed_modules == prior.allowed_modules and _level.allowed_calls == prior.allowed_calls, "逃脱保留所有已解锁模块与动作")
	for flag in ["allow_tick", "allow_named_calls", "allow_loops", "allow_conditionals", "allow_simultaneous", "allow_distance", "allow_functions", "allow_variables", "allow_radar", "allow_random", "allow_for", "allow_radar_events"]:
		_check(_level.get(flag) == prior.get(flag) and bool(_level.get(flag)), "继承第十五关权限：" + flag)
	for number in range(1, 16):
		var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number, _content, true)
		if not _check(loaded.is_ok(), "旧关卡 %d 地图继续合法" % number):
			continue
		var previous := LevelDefinition.from_document(loaded.value, _content)
		if not _check(previous.is_ok(), "旧关卡 %d 规则继续合法" % number):
			continue
		var old: LevelDefinition = previous.value
		_check(old.allow_distance == (number >= 9) and old.allow_variables == (number >= 10) and old.allow_radar_events == (number >= 15), "新迷宫不改变旧关测距、变量或雷达事件的解锁时机")


## 右手法则只查看当下测距并走一个格子，以真实移动到达出口而非注入坐标。
func _test_adaptive_solution() -> void:
	var original := _level.document.to_dict()
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "既有 DSL 能运行右手法则：" + session.message):
		return
	var completions: Array[int] = []
	# 仅捕获独立数组记录完成事件，避免与会话互相持有引用。
	session.completed.connect(func() -> void: completions.append(1))
	_check(session.world.player.position == SPAWN and session.world.tick_index == 0, "程序排队和首次测距不提前移动")
	_run_to_end(session)
	_check(session.state == GameSession.State.SUCCEEDED, "测距与移动两模块真实逃出迷宫：" + session.message)
	_check(session.world.player.position.distance_to(EXIT) <= _level.goal_radius + .00001, "只有实体抵达右下终点才算成功")
	_check(session.world.tick_index > 380 and completions.size() == 1, "弯曲路线真实推进多个逻辑 tick 且只完成一次")
	_check(session.world.tick_index <= 2400, "正式迷宫可在代码提示验证的 2400 tick 预算内完成")
	var final_position := session.world.player.position
	var final_tick := session.world.tick_index
	for unused in 10:
		session.step()
	_check(session.world.player.position == final_position and session.world.tick_index == final_tick and completions.size() == 1, "通关立即停止无限循环，不重复移动或通知")
	_check(_level.document.to_dict() == original and session.source == SOLUTION, "模拟不改地图原件或玩家程序")


## 同一程序在旋转后的陌生迷宫也能通过，排除按关卡 ID 或固定转弯顺序伪解。
func _test_rotated_maze() -> void:
	var original := _level.document.to_dict()
	var document := _level.document.duplicate_document()
	document.id = "escape_rotated_fixture"
	document.cells.clear()
	for cell: Vector2i in _level.document.cells:
		document.set_tile(Vector2i(26 - cell.x, 16 - cell.y), _level.document.get_tile_id(cell))
	var defined := LevelDefinition.from_document(document, _content)
	if not _check(defined.is_ok(), "旋转 180° 的独立迷宫仍合法"):
		return
	var session := _session(SOLUTION, defined.value)
	if not _check(session.run().is_ok(), "不修改源码即可运行旋转变体"):
		return
	_run_to_end(session)
	_check(session.state == GameSession.State.SUCCEEDED, "同一测距右手程序适应不同分叉路线：" + session.message)
	_check(_level.document.to_dict() == original, "变体验证不污染正式迷宫")


## 空装配、数量超限与盲目穿墙必须在现有装配或真实碰撞入口拒绝。
func _test_assembly_and_failures() -> void:
	var empty := GameSession.create(_level, _content)
	_check(empty.assembly.modules.is_empty() and not empty.assembly.build_document().is_ok(), "进入关卡保持空装配，未安装不能确认")
	empty.source = SOLUTION
	_check(not empty.run().is_ok() and empty.world == null, "运行入口不能绕过空装配检查")
	var assembled := _session(SOLUTION)
	var snapshot := assembled.assembly.modules.duplicate(true)
	_check(not assembled.assembly.add_module("movement", Vector2(0, .5), "third").is_ok() and assembled.assembly.modules == snapshot, "第三个模块拒绝且原两模块装配不被修改")
	_check(assembled.assembly.build_document().is_ok(), "推荐横向两模块的完整出生占地合法")
	var unfinished := _session(_level.starter_program)
	_check(unfinished.run().is_ok(), "空 main 可正常尝试运行")
	_run_to_end(unfinished)
	_check(unfinished.state == GameSession.State.FAILED and unfinished.world.player.position == SPAWN, "空程序不能自动解谜或通关")
	var into_wall := _session("main() {\n    drive.move(180, 1)\n}\n")
	if _check(into_wall.run().is_ok(), "撞墙案例通过合法装配和语法入口"):
		_run_to_end(into_wall)
		_check(into_wall.state == GameSession.State.FAILED and into_wall.world.player.position == SPAWN, "左侧实体贴墙，不允许穿出迷宫外墙")
		_check(into_wall.current_line == 2, "碰撞失败定位到玩家移动指令")
	var no_sensor := GameSession.create(_level, _content)
	_check(no_sensor.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "可单独安装移动模块，测距不是硬性通关门槛")
	no_sensor.source = SOLUTION
	_check(not no_sensor.run().is_ok() and (no_sensor.world == null or no_sensor.world.tick_index == 0), "未装 sensor 时测距程序不能凭空获得地图信息")


## 暂停保留解释器方向和半途动作，重试重建起点并保留玩家源码与装配。
func _test_pause_and_retry() -> void:
	var session := _session(SOLUTION)
	if not _check(session.run().is_ok(), "暂停验证启动真实解谜程序"):
		return
	for unused in 23:
		session.step()
	var position := session.world.player.position
	var tick_index := session.world.tick_index
	var line := session.current_line
	session.pause()
	for unused in 20:
		session.step()
	_check(session.state == GameSession.State.PAUSED and session.world.player.position == position and session.world.tick_index == tick_index and session.current_line == line, "暂停冻结途中动作、解释器与逻辑时钟")
	session.resume()
	session.step()
	_check(session.world.tick_index == tick_index + 1 and not session.world.player.position.is_equal_approx(position), "恢复继续当前动作")
	var previous_world := session.world
	session.reset()
	_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null, "重置释放旧运行状态")
	_check(session.source == SOLUTION and session.assembly.modules.size() == 2, "重置保留源码与玩家装配")
	if _check(session.run().is_ok(), "保留的程序可重新启动"):
		_check(session.world != previous_world and session.world.player.position == SPAWN and session.world.tick_index == 0, "重新建立全新起点，不保留上次方向变量")
		_run_to_end(session)
		_check(session.state == GameSession.State.SUCCEEDED, "重试仍以实际导航到达终点")
	session.reset_code()
	_check(session.source == _level.starter_program and session.assembly.modules.size() == 2 and session.world == null, "重置代码只恢复空 main，仍保留装配")


## 通过公开装配接口安装两个共边部件，不使用地图出生模板自动安装。
func _session(source: String, definition: LevelDefinition = null) -> GameSession:
	var session := GameSession.create(_level if definition == null else definition, _content)
	_check(session.assembly.modules.is_empty(), "新会话从空装配开始")
	_check(session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor").is_ok(), "玩家安装原点测距 sensor")
	_check(session.assembly.add_module("movement", Vector2(.5, 0), "drive").is_ok(), "玩家安装右侧共边移动 drive")
	session.source = source
	return session


## 有限测试预算覆盖整棵迷宫沿墙遍历，避免出错程序令回归永远等待。
func _run_to_end(session: GameSession) -> void:
	for unused in 10000:
		if session.state != GameSession.State.RUNNING:
			if session.state == GameSession.State.FAILED and session.source == SOLUTION:
				print("逃脱诊断：tick=", session.world.tick_index, " position=", session.world.player.position, " message=", session.message)
			return
		session.step()
	_check(false, "沿墙导航应在一万逻辑 tick 内结束")


## 集中报告检查结果，命令行退出码与真实失败一致。
func _finish() -> void:
	print("第十六关逃脱回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 记录断言而不中断其余独立用例，保留具体失败信息。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
