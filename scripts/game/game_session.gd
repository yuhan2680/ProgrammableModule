class_name GameSession
extends RefCounted
## 一次关卡试运行的状态机。它连接装配、解释器和模拟，不持有 UI 或读写存档。

signal changed
signal completed
signal attempt_failed

enum State { EDITING, RUNNING, PAUSED, SUCCEEDED, FAILED }

var level: LevelDefinition
var assembly: AssemblyModel
var source: String = ""
var world: SimulationWorld
var runner: ProgramRunner
var state: State = State.EDITING
var message: String = "组装机器并编写程序，然后点击运行。"
var current_line: int = 0
var consecutive_failures: int = 0
var _attempt_pending: bool = false
var _content: ContentRegistry


## 从关卡建立可修改的工作副本；地图原文件与其他关卡会话不会受到影响。
static func create(definition: LevelDefinition, content: ContentRegistry) -> GameSession:
	var session := GameSession.new()
	session.level = definition
	session._content = content
	session.assembly = AssemblyModel.create(definition, content)
	session.source = definition.starter_program
	return session


## 完整校验程序和装配后，从出生点创建全新世界；失败不会部分执行程序。
func run() -> DataResult:
	if state == State.RUNNING or state == State.PAUSED:
		return DataResult.failure("程序正在运行或暂停，请先停止。")
	_clear_runtime()
	_attempt_pending = true
	var parsed := ProgramParser.parse(source, level.allowed_calls, level.allow_tick, level.allow_named_calls, level.allow_loops, level.allow_conditionals, level.allow_simultaneous, level.allow_distance, level.allow_functions, level.allow_variables, level.allow_radar, level.allow_random, level.allow_for, level.allow_radar_events)
	if not parsed.is_ok():
		_set_failure("\n".join(parsed.errors))
		return parsed
	var assembled := assembly.build_document()
	if not assembled.is_ok():
		_set_failure("装配不能运行：" + "\n".join(assembled.errors))
		return assembled
	var created := SimulationWorld.create(assembled.value, _content)
	if not created.is_ok():
		_set_failure("\n".join(created.errors))
		return created
	world = created.value
	runner = ProgramRunner.create(parsed.value, world)
	state = State.RUNNING
	message = "程序运行中。"
	var started := runner.start()
	current_line = runner.current_line
	if not started.is_ok():
		_set_failure("\n".join(started.errors))
		return started
	_check_outcome(world.player.position)
	changed.emit()
	return DataResult.success(self)


## 只在运行状态推进一个固定 tick；暂停时间不进入模拟累加器。
func step() -> void:
	if state != State.RUNNING or runner == null:
		return
	var previous_position := world.player.position
	# 战斗不能因 main 提前结束就冻结敌人；已发出的子弹和敌人的行动仍使用同一时钟。
	if runner.state == ProgramRunner.State.COMPLETED and (level.completion_mode == "reach_or_clear" or level.goal_type in ["destroy_enemy", "dodge_attacks", "destroy_waves"]):
		world.step()
	else:
		runner.step()
	current_line = runner.current_line
	_check_outcome(previous_position)
	changed.emit()


## 暂停保留当前指令和机器位置，后续 resume 继续同一个动作。
func pause() -> void:
	if state == State.RUNNING:
		state = State.PAUSED
		message = "已暂停，可继续或停止后修改程序。"
		changed.emit()


## 恢复暂停的试运行，不重新提交当前移动指令。
func resume() -> void:
	if state == State.PAUSED:
		state = State.RUNNING
		message = "程序运行中。"
		changed.emit()


## 停止本次运行，保留玩家编写的程序和装配，回到出生预览。
func stop() -> void:
	_clear_runtime()
	state = State.EDITING
	message = "已停止。程序与装配已保留，可修改后再次运行。"
	changed.emit()


## 重置运行状态而不清空玩家的作品，避免测试失败后重新输入全部内容。
func reset() -> void:
	stop()
	message = "已回到初始位置，程序和装配保持不变。"
	changed.emit()


## 显式恢复本关初始代码，同时取消旧程序；不修改装配、关卡定义或持久化进度。
func reset_code() -> void:
	_clear_runtime()
	source = level.starter_program
	state = State.EDITING
	message = "代码已恢复为本关初始程序。"
	changed.emit()


## 根据本 tick 的真实路径检测到达目标，避免高速移动跨过小目标而漏判。
func _check_outcome(previous_position: Vector2) -> void:
	if state != State.RUNNING or world == null:
		return
	if not world.failure_reason.is_empty():
		runner.cancel()
		_set_failure(world.failure_reason)
		return
	if level.completion_mode == "reach_or_clear":
		_check_timed_map_outcome(previous_position)
		return
	if level.goal_type == "destroy_waves":
		var waves := world.get_enemy_wave_status()
		if bool(waves.get("all_cleared", false)):
			state = State.SUCCEEDED
			message = "全部来袭波次已击毁，关卡完成！"
			runner.cancel()
			consecutive_failures = 0
			_attempt_pending = false
			completed.emit()
			return
	if level.goal_type == "dodge_attacks":
		var progress := world.get_enemy_attack_status(level.goal_enemy_id)
		if int(progress.get("dodged", 0)) >= level.goal_attack_count:
			state = State.SUCCEEDED
			message = "已躲过全部攻击，关卡完成！"
			runner.cancel()
			consecutive_failures = 0
			_attempt_pending = false
			completed.emit()
			return
	if level.goal_type == "destroy_enemy":
		var enemy := world.get_machine(level.goal_enemy_id)
		# 玩家死亡优先于胜利：同 tick 互相击毁仍视为本次挑战失败。
		if enemy != null and enemy.is_destroyed():
			state = State.SUCCEEDED
			message = "敌人所有模块已击毁，关卡完成！"
			runner.cancel()
			consecutive_failures = 0
			_attempt_pending = false
			completed.emit()
			return
	if level.goal_type == "destroy_object":
		var target := world.get_object(level.goal_object_id)
		if target != null and target.health <= 0.0:
			state = State.SUCCEEDED
			message = "障碍物已摧毁，关卡完成！"
			runner.cancel()
			consecutive_failures = 0
			_attempt_pending = false
			completed.emit()
			return
	if level.goal_type == "reach_position" or (level.goal_type == "escape_prison" and _prison_targets_cleared()) or (level.goal_type == "escape_alarms" and _paired_targets_cleared()):
		var nearest := Geometry2D.get_closest_point_to_segment(level.goal_position, previous_position, world.player.position)
		if nearest.distance_to(level.goal_position) <= level.goal_radius + 0.000001:
			# 先确定会话终态，再取消尚未走完的动作，程序不能在通关后继续移动。
			state = State.SUCCEEDED
			message = "已安全离开监狱，关卡完成！" if level.goal_type in ["escape_prison", "escape_alarms"] else "已到达终点，关卡完成！"
			runner.cancel()
			consecutive_failures = 0
			_attempt_pending = false
			completed.emit()
			return
	# 截止 tick 先判定所有类型的真实目标；最后一帧完成也应通关。
	if level.max_ticks > 0 and world.tick_index >= level.max_ticks:
		runner.cancel()
		if level.goal_type == "destroy_waves":
			if level.id == "level_015":
				_set_failure("练习时间已结束。请用雷达事件更新目标，沿主通道推进并击毁全部敌人。")
			elif level.id == "level_014":
				_set_failure("练习时间已结束。请沿主通道推进，扫描并击毁两侧支道中的全部敌人。")
			else:
				_set_failure(("练习时间已结束。检查雷达扫描与射击，并在循环中持续警戒。" if level.id == "level_013" else "练习时间已结束。检查八个方向的扫描与射击，并在循环中持续警戒。"))
		elif level.goal_type == "dodge_attacks":
			_set_failure("练习时间已结束。观察敌人的接近，用函数重复检测并闪避。")
		elif level.allow_radar and level.goal_type == "destroy_enemy":
			_set_failure("练习时间已结束。重新扫描敌人，缩短追击步长并靠近后射击。")
		elif level.allow_conditionals:
			_set_failure("练习时间已结束。检查条件判断与后退节奏，再试一次。")
		else:
			_set_failure("练习时间已结束，敌人仍有模块存活。试着在 tick() 中持续向右 shoot(0)。" if level.goal_type == "destroy_enemy" else "练习时间已结束，尚未完成目标。调整程序后再试一次。")
		return
	if runner.state == ProgramRunner.State.FAILED:
		_set_failure(runner.message)
	elif runner.state == ProgramRunner.State.COMPLETED:
		if level.goal_type == "destroy_waves":
			message = ("main() 已结束，仍有敌人来袭。请用 loop 持续扫描并射击。" if level.id == "level_013" else "main() 已结束，仍有敌人来袭。请用 loop 持续扫描八个方向。")
			if level.id == "level_014":
				message = "main() 已结束。请用 loop 交替扫描、射击与前进，清除全部支道中的敌人。"
			return
		if level.goal_type == "dodge_attacks":
			message = "main() 已结束，敌人仍在锁定。请持续检测并闪避。"
			return
		if level.goal_type == "destroy_enemy":
			message = "main() 已结束，敌人仍在行动。请用 loop 持续判断并行动。" if level.allow_conditionals else "main() 已结束，敌人仍在行动。持续射击请使用 tick()。"
			return
		if level.goal_type == "escape_prison":
			_set_failure("出口已解锁，请继续向上到达绿色终点。" if _prison_targets_cleared() else "越狱尚未完成。先解除警卫，再破坏警报器，最后向上离开。")
		elif level.goal_type == "escape_alarms":
			_set_failure("出口已解锁，请继续向上走到终点。" if _paired_targets_cleared() else "同时破坏两个警报器后，再向上逃出监狱。")
		elif level.has_goal:
			_set_failure("程序已执行完，但障碍物尚未摧毁。请靠近目标并检查攻击方向。" if level.goal_type == "destroy_object" else "程序已执行完，但还没有到达终点。调整程序后再试一次。")
		else:
			state = State.EDITING
			message = "程序执行完成。此导入地图没有设置通关目标。"
	elif runner.state == ProgramRunner.State.CANCELLED:
		_set_failure("本次程序执行已取消。")


## 只计算实际参与模拟的已注册敌人；未知扩展条目不冒充场上的敌人。
func total_enemy_count() -> int:
	if not bool(level.document.properties.get("level", {}).get("enemies_enabled", true)):
		return 0
	var total := 0
	for entry: Dictionary in level.document.enemies:
		if entry.get("behavior") in EnemyDefinition.BEHAVIORS:
			total += 1
	return total


## 按地图完整敌人清单计算存活数；待生波次尚无世界实例，也必须算作未清除。
func remaining_enemy_count() -> int:
	if not bool(level.document.properties.get("level", {}).get("enemies_enabled", true)):
		return 0
	var remaining := 0
	for entry: Dictionary in level.document.enemies:
		if entry.get("behavior") not in EnemyDefinition.BEHAVIORS:
			continue
		var enemy := world.get_machine(entry.id) if world != null else null
		if enemy == null or not enemy.is_destroyed():
			remaining += 1
	return remaining


## 自定义限时地图到达终点或清空全部敌人即可完成；原本无敌人不能自动获胜。
func _check_timed_map_outcome(previous_position: Vector2) -> void:
	var reached := false
	if level.goal_type in ["reach_position", "escape_prison", "escape_alarms"]:
		var nearest := Geometry2D.get_closest_point_to_segment(level.goal_position, previous_position, world.player.position)
		reached = nearest.distance_to(level.goal_position) <= level.goal_radius + 0.000001
	var cleared := total_enemy_count() > 0 and remaining_enemy_count() == 0
	# 截止时刻的真实完成优先于超时；玩家死亡已由外层统一先行处理。
	if reached or cleared:
		state = State.SUCCEEDED
		message = "已到达终点，关卡完成！" if reached else "全部敌人已清除，关卡完成！"
		runner.cancel()
		consecutive_failures = 0
		_attempt_pending = false
		completed.emit()
	elif world.tick_index >= level.max_ticks:
		runner.cancel()
		_set_failure("时间已到，未能到达终点或清除全部敌人。")
	elif runner.state == ProgramRunner.State.FAILED:
		_set_failure(runner.message)
	elif runner.state == ProgramRunner.State.COMPLETED:
		# 主程序结束仍推进战斗、弹丸和倒计时，避免提前停止计时绕过失败。
		message = "程序已结束，倒计时仍在继续。"


## 保存可读错误并提取行号，解释器和装配失败都能在同一状态栏展示。
func _set_failure(reason: String) -> void:
	state = State.FAILED
	message = reason
	# 编译失败也属于一次尝试；每次运行最多结算一次，刷新、暂停与主动停止不计数。
	if _attempt_pending:
		_attempt_pending = false
		consecutive_failures = mini(consecutive_failures + 1, 1000000)
		attempt_failed.emit()
	var pattern := RegEx.new()
	pattern.compile("第\\s*(\\d+)\\s*行")
	var matched := pattern.search(reason)
	if matched != null:
		current_line = int(matched.get_string(1))
	changed.emit()


## 释放旧动作与解释器引用；每次运行都从独立地图快照开始。
func _clear_runtime() -> void:
	_attempt_pending = false
	if runner != null:
		runner.cancel()
	runner = null
	world = null
	current_line = 0


## 单独击毁目标不等于越狱；两个目标清除后，仍需在真实运动路径上抵达出口。
func _prison_targets_cleared() -> bool:
	var guard := world.get_machine(level.goal_enemy_id)
	var alarm := world.get_object(level.goal_object_id)
	var guard_cleared := not world.are_enemies_enabled() or (guard != null and guard.is_destroyed())
	return guard_cleared and alarm != null and alarm.health <= 0.0


## 警报器同帧解除后仍需抵达出口；已触发的警报不能被后续伤害补救为胜利。
func _paired_targets_cleared() -> bool:
	if level.goal_alarm_ids.size() != 2:
		return false
	for alarm_id in level.goal_alarm_ids:
		var alarm := world.get_object(alarm_id)
		if alarm == null or alarm.health > 0.0 or alarm.triggered:
			return false
	return true
