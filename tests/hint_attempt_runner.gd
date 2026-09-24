extends SceneTree
## 提示失败次数使用真实会话结算；存档仅写本次独占的 user://tests 目录。

const SOLUTION := "main(){\nmove(0,4)\nmove(90,3)\nmove(180,4)\nmove(90,3)\nmove(0,4)\n}"
const MAX_STEPS := 1000
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _level: LevelDefinition
var _temporary := ""


## 全局脚本就绪后运行测试，不启动游戏 UI 或读取玩家正式进度。
func _initialize() -> void:
	_run.call_deferred()


## 独立验证单次结算、主动操作、成功清零、兼容存档及定向清除。
func _run() -> void:
	_temporary = "user://tests/hint_attempt_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if not _check(_content.load_directories().is_ok(), "提示次数测试可以加载正式内容"):
		_finish()
		return
	_level = _load_level(1)
	if _level == null:
		_finish()
		return
	_test_compile_and_settlement()
	_test_real_world_failure()
	_test_active_controls()
	_test_success_reset()
	_test_persistence_round_trip()
	_test_corrupt_records()
	_test_clear_teaching_progress()
	_finish()


## 编译、装配和执行预检失败都只结算一次，刷新与重复 step 不制造新尝试。
func _test_compile_and_settlement() -> void:
	var session := _session()
	var events: Array[int] = []
	session.attempt_failed.connect(func() -> void: events.append(1))
	_check(session.consecutive_failures == 0, "新会话连续失败次数为零")
	for source in ["main(){", "main(){missing(0)}", "main(){move(0,-1)}"]:
		session.source = source
		var before := session.consecutive_failures
		var result := session.run()
		_check(not result.is_ok() and session.state == GameSession.State.FAILED, "源码或参数预检失败得到真实失败状态")
		_check(session.consecutive_failures == before + 1 and events.size() == before + 1, "一次失败的 run 仅增加一次计数和一次信号")
		for unused in 10:
			session.step()
		_check(session.consecutive_failures == before + 1 and events.size() == before + 1, "失败后的重复 step 不会重复结算")
	var empty := GameSession.create(_level, _content)
	empty.source = SOLUTION
	_check(not empty.run().is_ok() and empty.consecutive_failures == 1, "合法源码但空装配的失败也只算本次一次尝试")
	session.source = "main(){}"
	session.run()
	_check(session.state == GameSession.State.FAILED and session.consecutive_failures == 4 and events.size() == 4, "main 立即结束但未达成目标时也只计一次失败")
	session.consecutive_failures = 1000000
	session.source = "main(){"
	session.run()
	_check(session.consecutive_failures == 1000000 and events.size() == 5, "计数达到上限时保持有界，但新的失败仍发出一次结算信号")


## 真实地形阻挡与敌方近战都触发会话失败，不通过直接修改失败状态伪造结算。
func _test_real_world_failure() -> void:
	var blocked := _session()
	blocked.source = "main(){move(180,1)}"
	var blocked_events: Array[int] = []
	blocked.attempt_failed.connect(func() -> void: blocked_events.append(1))
	if _check(blocked.run().is_ok(), "朝真实 void 移动可以启动并交给模拟判定"):
		_advance_to_terminal(blocked)
		_check(blocked.state == GameSession.State.FAILED and blocked.world.tick_index > 0 and blocked.consecutive_failures == 1 and blocked_events.size() == 1, "实际移动被地形阻挡只结算一次失败")
		var tick := blocked.world.tick_index
		for unused in 10:
			blocked.step()
		_check(blocked.world.tick_index == tick and blocked.consecutive_failures == 1 and blocked_events.size() == 1, "真实失败后的重复 step 既不推进世界也不重复计数")
	var combat_level := _load_level(11)
	if combat_level == null:
		return
	var combat := _session(combat_level)
	combat.source = "main(){}"
	var combat_events: Array[int] = []
	combat.attempt_failed.connect(func() -> void: combat_events.append(1))
	if _check(combat.run().is_ok(), "真实雷达敌人场地中空 main 仍让敌人持续行动"):
		_advance_to_terminal(combat)
		_check(combat.state == GameSession.State.FAILED and not combat.world.failure_reason.is_empty() and combat.world.get_enemy_attack_status(combat_level.goal_enemy_id).get("attempts", 0) == 1, "第一轮真实近战命中产生世界失败原因")
		_check(combat.consecutive_failures == 1 and combat_events.size() == 1, "世界失败与解释器取消不会对同次近战失败重复计数")
		for unused in 10:
			combat.step()
		_check(combat.consecutive_failures == 1 and combat_events.size() == 1, "世界失败终态重复观察仍只保留一次结算")


## 编辑、暂停、停止与各种重置保留已有次数，主动结束运行不计作失败。
func _test_active_controls() -> void:
	var session := _session()
	session.source = "main(){"
	session.run()
	var events: Array[int] = []
	session.attempt_failed.connect(func() -> void: events.append(1))
	session.source = SOLUTION
	_check(session.consecutive_failures == 1, "编辑源码不会清空已有失败次数")
	for operation in ["stop", "reset", "reset_code"]:
		session.call(operation)
		_check(session.consecutive_failures == 1 and events.is_empty() and session.state == GameSession.State.EDITING, "编辑状态主动操作保留次数且不发失败信号：" + operation)
		session.source = SOLUTION
		if not _check(session.run().is_ok(), "主动操作前可以开始真实移动"):
			continue
		session.step()
		_check(not session.run().is_ok() and session.consecutive_failures == 1 and events.is_empty(), "运行中重复点击开始被拒绝但不计作新失败")
		var world := session.world
		var position := world.player.position
		var tick := world.tick_index
		session.pause()
		for unused in 10:
			session.step()
		_check(session.state == GameSession.State.PAUSED and world.tick_index == tick and world.player.position == position and session.consecutive_failures == 1 and events.is_empty(), "暂停冻结世界但不清零或增加失败次数")
		_check(not session.run().is_ok() and session.consecutive_failures == 1 and events.is_empty(), "暂停中重复开始不计作失败")
		session.resume()
		session.call(operation)
		_check(session.state == GameSession.State.EDITING and session.world == null and session.runner == null and session.consecutive_failures == 1 and events.is_empty(), "主动终止真实运行保留次数并释放旧尝试：" + operation)
		for unused in 3:
			session.step()
		_check(events.is_empty() and session.consecutive_failures == 1, "主动结束后的刷新不把旧尝试补记为失败")
	_check(not session.assembly.add_module("movement", Vector2(0.5,0), "extra").is_ok() and session.consecutive_failures == 1 and events.is_empty(), "装配编辑被限制拒绝不等于点击运行失败")


## 成功信号观察到的计数已经清零，之后的终态刷新不重复通知或恢复旧次数。
func _test_success_reset() -> void:
	var session := _session()
	session.consecutive_failures = 3
	session.source = SOLUTION
	var failures: Array[int] = []
	var completed_counts: Array[int] = []
	session.attempt_failed.connect(func() -> void: failures.append(1))
	var on_completed := func() -> void: completed_counts.append(session.consecutive_failures)
	session.completed.connect(on_completed)
	if _check(session.run().is_ok(), "带已有失败次数的第一关解法可以启动"):
		_advance_to_terminal(session)
		_check(session.state == GameSession.State.SUCCEEDED and session.consecutive_failures == 0 and completed_counts == [0] and failures.is_empty(), "真实到达终点在发出一次成功信号前清零失败次数")
		for unused in 10:
			session.step()
		_check(completed_counts == [0] and failures.is_empty() and session.consecutive_failures == 0, "通关后重复 step 不重发成功或结算失败")
	session.completed.disconnect(on_completed)
	session.reset()
	session.source = "main(){"
	session.run()
	_check(session.consecutive_failures == 1 and failures.size() == 1, "通关后下一次失败从一重新累计")


## 旧版本进度与新会话可往返次数，各关独立且不改变草稿或已通关标志。
func _test_persistence_round_trip() -> void:
	var store := GameDraftStore.new(_temporary.path_join("round_trip"))
	_check(store.get_failure_streak("new") == 0 and not FileAccess.file_exists(_progress_path(store,"new")), "没有记录时读取零且不创建文件")
	var old := {"format_version":1, "level_id":_level.id, "completed":true, "custom":{"keep":"原字段"}}
	var old_source := JSON.stringify(old, "  ") + "\n"
	if not _write(_progress_path(store,_level.id),old_source):
		return
	_check(store.get_failure_streak(_level.id) == 0 and store.is_completed(_level.id) and FileAccess.get_file_as_string(_progress_path(store,_level.id)) == old_source, "旧进度缺少次数字段时兼容为零，不改写原文件")
	_check(store.save_failure_streak(_level.id,2).is_ok() and store.save_failure_streak("other",5).is_ok(), "两个关卡分别保存失败次数")
	var reloaded := GameDraftStore.new(store.directory)
	_check(reloaded.get_failure_streak(_level.id) == 2 and reloaded.get_failure_streak("other") == 5 and reloaded.is_completed(_level.id) and not reloaded.is_completed("other"), "新存储实例恢复各关次数并保留各自通关状态")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_progress_path(store,_level.id)))
	_check(data.get("custom") == old.custom, "保存失败次数保留进度扩展字段")
	var session := _session()
	session.consecutive_failures = reloaded.get_failure_streak(_level.id)
	session.source = "main(){"
	session.run()
	_check(session.consecutive_failures == 3 and reloaded.save_failure_streak(_level.id,session.consecutive_failures).is_ok(), "重建会话恢复次数后，新失败从持久化值继续累加")
	_check(GameDraftStore.new(store.directory).get_failure_streak(_level.id) == 3 and store.is_completed(_level.id), "再次打开仍有最新失败次数，重玩失败不会撤销曾经通关")
	_check(store.save_failure_streak(_level.id,1000000).is_ok(), "持久化接受明确的最大计数边界")
	var before := FileAccess.get_file_as_string(_progress_path(store,_level.id))
	for invalid in [-1,1000001]:
		_check(not store.save_failure_streak(_level.id,invalid).is_ok() and FileAccess.get_file_as_string(_progress_path(store,_level.id)) == before, "拒绝越界新计数且保留原记录字节")
	_check(store.mark_completed(_level.id).is_ok() and store.get_failure_streak(_level.id) == 0 and store.is_completed(_level.id), "记录通关会同时清零失败次数")
	_check(store.get_failure_streak("other") == 5, "一关通关不清零其他关卡的失败次数")
	_check(not store.save_failure_streak("",1).is_ok() and store.get_failure_streak("") == 0, "无效空关卡标识不能写入或恢复次数")


## 格式损坏、类型错误或越界次数均不能被新失败覆盖，原始字节仍可用于恢复。
func _test_corrupt_records() -> void:
	var store := GameDraftStore.new(_temporary.path_join("corrupt"))
	var fixtures: Array[String] = ["{broken JSON", "[]"]
	for field in ["format_version", "level_id", "completed"]:
		var data := {"format_version":1,"level_id":"bad","completed":false,"failure_streak":2}
		data[field] = {"format_version":2,"level_id":"mismatch","completed":1}[field]
		fixtures.append(JSON.stringify(data))
	for count in [-1,1.5,1000001,"3",true,null]:
		fixtures.append(JSON.stringify({"format_version":1,"level_id":"bad","completed":false,"failure_streak":count}))
	for source in fixtures:
		var path := _progress_path(store,"bad")
		if not _write(path,source):
			continue
		_check(store.get_failure_streak("bad") == 0 and FileAccess.get_file_as_string(path) == source, "损坏进度只读返回零且不自行修复文件")
		_check(not store.save_failure_streak("bad",3).is_ok() and FileAccess.get_file_as_string(path) == source, "保存新失败不能覆盖损坏的原进度或计数字段")


## 清除教学进度会删除其计数文件，未选中的用户关卡及其他文件原样保留。
func _test_clear_teaching_progress() -> void:
	var store := GameDraftStore.new(_temporary.path_join("clear"))
	var builtin_ids: Array[String] = [_level.id,"level_002"]
	for id in builtin_ids:
		_check(store.save_failure_streak(id,4).is_ok() and store.save_draft(id,"main(){}",[]).is_ok(), "准备教学关卡计数与草稿")
	_check(store.mark_completed("imported").is_ok() and store.save_failure_streak("imported",7).is_ok() and store.save_draft("imported","// 用户关卡\nmain(){}",[]).is_ok(), "准备应保留的用户关卡记录")
	var imported_progress := FileAccess.get_file_as_string(_progress_path(store,"imported"))
	var imported_draft := FileAccess.get_file_as_string(store.directory.path_join("imported".sha256_text() + ".draft.json"))
	_check(store.clear_level_records(builtin_ids).is_ok(), "通过正式清除接口删除指定教学进度")
	for id in builtin_ids:
		_check(store.get_failure_streak(id) == 0 and not store.is_completed(id) and not FileAccess.file_exists(_progress_path(store,id)), "教学记录清除后次数回到零且旧计数文件不存在")
		var loaded := store.load_draft(id)
		_check(loaded.is_ok() and loaded.value == null, "清除教学进度同时移除该关代码装配草稿")
	_check(store.get_failure_streak("imported") == 7 and store.is_completed("imported") and FileAccess.get_file_as_string(_progress_path(store,"imported")) == imported_progress, "清除教学记录不会改变用户关卡计数与通关状态")
	_check(FileAccess.get_file_as_string(store.directory.path_join("imported".sha256_text() + ".draft.json")) == imported_draft, "清除教学记录不会改变用户关卡草稿字节")
	_check(store.clear_level_records(builtin_ids).is_ok(), "重复清除不存在的教学记录仍可安全完成")


## 从正式 JSON 建立只读定义，加载失败时阻止依赖该定义的后续用例。
func _load_level(number: int) -> LevelDefinition:
	var loaded := MapCodec.load_file("res://data/levels/level_%03d.json" % number,_content,true)
	if not _check(loaded.is_ok(), "第 %d 关正式地图可加载" % number):
		return null
	var defined := LevelDefinition.from_document(loaded.value,_content)
	if not _check(defined.is_ok(), "第 %d 关正式规则可建立" % number):
		return null
	return defined.value as LevelDefinition


## 每次通过公开接口安装中心移动模块，不用出生模板跳过空装配规则。
func _session(definition: LevelDefinition = null) -> GameSession:
	var session := GameSession.create(_level if definition == null else definition,_content)
	_check(session.assembly.add_module("movement",Vector2.ZERO,"drive").is_ok(), "提示次数测试手动安装中心移动模块")
	return session


## 只推进有界逻辑步，真实失败或成功后立刻停止主动运行。
func _advance_to_terminal(session: GameSession) -> void:
	for unused in MAX_STEPS:
		if session.state != GameSession.State.RUNNING:
			return
		session.step()
	_check(false, "测试会话应在一千步内结束")


## 使用既有哈希文件格式准备旧版或损坏记录，不借此访问测试目录之外的文件。
func _progress_path(store: GameDraftStore, level_id: String) -> String:
	return store.directory.path_join(level_id.sha256_text() + ".progress.json")


## 仅向本次测试的独立目录写入夹具，失败时记录断言而不继续解引用文件。
func _write(path: String, source: String) -> bool:
	if not _check(DirAccess.make_dir_recursive_absolute(path.get_base_dir()) == OK, "创建提示次数测试夹具目录"):
		return false
	var file := FileAccess.open(path,FileAccess.WRITE)
	if not _check(file != null, "提示次数夹具文件可以创建"):
		return false
	file.store_string(source)
	file.close()
	return true


## 只递归删除本次独占目录，不跟随符号链接访问其他存档。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for folder in directory.get_directories():
		if directory.is_link(folder):
			directory.remove(folder)
		else:
			_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)


## 无论准备失败或检查结束，都清理测试文件并返回统一完成标记。
func _finish() -> void:
	_cleanup(_temporary)
	print("提示次数回归完成：%d 项检查，%d 项失败。" % [_checks,_failures])
	quit(1 if _failures > 0 else 0)


## 累计可定位断言，任何失败都使测试进程返回非零状态。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
