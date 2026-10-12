class_name PlayerProfileStore
extends RefCounted
## 本机玩家档案独立保存，用户名修改不能改变 UID，统计和关卡文件互不影响。

signal changed

const DEFAULT_USERNAME: String = "Player"
const MAX_USERNAME_LENGTH: int = DataValidation.MAX_EDITOR_CREATOR_LENGTH
const MAX_PROFILE_BYTES: int = 4 * 1024 * 1024
const MAX_COUNTER: int = 1000000000000
const MAX_LEVEL_RECORDS: int = 8192
const HINT_RANK := {"none": 0, "normal": 1, "more": 2}
const HINT_WEIGHT := {"none": 1.0, "normal": 0.5, "more": 0.3}

var storage_path: String = "user://player_profile.json"
var last_error: String = ""
var _config: Dictionary = {}
var _loaded: bool = false
var _writable: bool = false
var _fingerprint: String = ""


## 允许测试注入专用路径，默认只访问本机玩家档案文件。
func _init(path: String = "user://player_profile.json") -> void:
	storage_path = path


## 初次载入生成并落盘 UID；损坏或新版文件原样保留，普通修改不能覆盖它。
func load_profile() -> DataResult:
	var checked := _validate_path()
	if not checked.is_ok():
		_writable = false
		return _remember_result(checked)
	if not FileAccess.file_exists(storage_path):
		var fresh := _new_profile("")
		if not fresh.is_ok():
			return _remember_result(fresh)
		return _commit(fresh.value, true)
	var loaded := _read_profile()
	if not loaded.is_ok():
		_writable = false
		return _remember_result(loaded)
	_config = loaded.value.duplicate(true)
	_fingerprint = FileAccess.get_sha256(storage_path)
	_loaded = true
	_writable = true
	changed.emit()
	return _remember_result(DataResult.success(self))


## 未能载入有效档案时仍显示默认用户名，不伪造可保存的身份。
func get_username() -> String:
	return str(_config.get("username", DEFAULT_USERNAME))


## UID 只通过载入或确认重置产生，界面不提供写入入口。
func get_uid() -> String:
	return str(_config.get("uid", ""))


## 返回深拷贝，外部展示和计算不能直接修改持久统计。
func get_statistics() -> Dictionary:
	var statistics: Dictionary = _config.get("statistics", _empty_statistics()).duplicate(true)
	# Godot 的 JSON 数字回读为浮点；公开统计保持统一类型，重启前后可稳定比较。
	for key: String in ["code_hint_uses", "successes", "failures", "shark_best_score"]:
		statistics[key] = int(statistics.get(key, 0))
	for key: String in ["fastest_seconds", "longest_seconds", "play_seconds"]:
		statistics[key] = float(statistics.get(key, 0.0))
	# 旧版本一已有非零成绩代表曾进入彩蛋，缺省标记不改写旧档案。
	statistics["shark_discovered"] = bool(statistics.get("shark_discovered", statistics["shark_best_score"] > 0))
	statistics["level_ledger"] = statistics.get("level_ledger", {}).duplicate(true)
	return statistics


## 新通过率只使用可定位到关卡的记录，无法还原的旧汇总不混入首通权重。
func get_weighted_pass_rate() -> float:
	var attempts := 0
	var weight := 0.0
	var ledger: Dictionary = _config.get("statistics", {}).get("level_ledger", {})
	for record: Dictionary in ledger.values():
		attempts += int(record["failures"])
		if record["completed"]:
			attempts += 1
			weight += float(record["success_weight"])
	return weight / attempts if attempts > 0 else -1.0


## 空白用户名恢复 Player，非法输入拒绝提交，成功写盘后才通知界面。
func set_username(value: String) -> DataResult:
	var name := DEFAULT_USERNAME if value.strip_edges().is_empty() else value
	if not is_username(name):
		return _remember_result(DataResult.failure("用户名须为最多 11 个字符的普通单行文字，不能含表情或特殊字符。"))
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	if name == get_username():
		return _remember_result(DataResult.success(self))
	var next := _config.duplicate(true)
	next["username"] = name
	return _commit(next)


## 每次真实应用代码提示只增加一次累计使用数，不依赖关卡分类。
func record_hint_use() -> DataResult:
	return _increment_counter("code_hint_uses")


## 调用方只在真实装配、编译或运行失败事件调用，手动停止不经过此入口。
func record_failure(level_id: String = "", hint_mode: String = "none") -> DataResult:
	var context := _validate_level_context(level_id, hint_mode)
	if not context.is_ok():
		return _remember_result(context)
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	var next := _config.duplicate(true)
	var statistics: Dictionary = next["statistics"]
	if int(statistics["failures"]) >= MAX_COUNTER:
		return _remember_result(DataResult.failure("玩家统计计数已达到档案上限。"))
	if not level_id.is_empty():
		var prepared := _prepare_level_record(statistics, level_id, hint_mode)
		if not prepared.is_ok():
			return _remember_result(prepared)
		var record: Dictionary = prepared.value
		if not record["completed"]:
			if int(record["failures"]) >= MAX_COUNTER:
				return _remember_result(DataResult.failure("玩家统计计数已达到档案上限。"))
			record["failures"] = int(record["failures"]) + 1
	statistics["failures"] = int(statistics["failures"]) + 1
	return _commit(next)


## 成功通关记录包含装配和编程的活动耗时，模拟 tick 不能代替用户时间。
func record_completion(seconds: float, level_id: String = "", hint_mode: String = "none", enemy_count: Variant = 0) -> DataResult:
	if not is_finite(seconds) or seconds < 0.0:
		return _remember_result(DataResult.failure("通关耗时必须是非负有限秒数。"))
	var context := _validate_level_context(level_id, hint_mode, enemy_count)
	if not context.is_ok():
		return _remember_result(context)
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	var next := _config.duplicate(true)
	var statistics: Dictionary = next["statistics"]
	if int(statistics["successes"]) >= MAX_COUNTER:
		return _remember_result(DataResult.failure("通关计数已达到档案上限。"))
	if not level_id.is_empty():
		var prepared := _prepare_level_record(statistics, level_id, hint_mode)
		if not prepared.is_ok():
			return _remember_result(prepared)
		var record: Dictionary = prepared.value
		if not record["completed"]:
			record["completed"] = true
			record["enemy_count"] = int(enemy_count)
			record["success_weight"] = _completion_weight(record["hint_mode"], int(enemy_count))
	var first := int(statistics["successes"]) == 0
	statistics["successes"] = int(statistics["successes"]) + 1
	statistics["fastest_seconds"] = seconds if first else minf(float(statistics["fastest_seconds"]), seconds)
	statistics["longest_seconds"] = seconds if first else maxf(float(statistics["longest_seconds"]), seconds)
	return _commit(next)


## 关卡经历的最高辅助档立即持久化，退出重启或改回低档不能降低首通权重。
func record_level_hint_mode(level_id: String, mode: String) -> DataResult:
	var context := _validate_level_context(level_id, mode)
	if not context.is_ok() or level_id.is_empty():
		return _remember_result(context if not context.is_ok() else DataResult.failure("关卡统计标识无效。"))
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	var ledger: Dictionary = _config["statistics"].get("level_ledger", {})
	if ledger.has(level_id):
		var current: Dictionary = ledger[level_id]
		if current["completed"] or int(HINT_RANK[current["hint_mode"]]) >= int(HINT_RANK[mode]):
			return _remember_result(DataResult.success(self))
	var next := _config.duplicate(true)
	var prepared := _prepare_level_record(next["statistics"], level_id, mode)
	return _commit(next) if prepared.is_ok() else _remember_result(prepared)


## 来源域与地图 ID 一起标识首通，旧裸 ID 仍兼容既有模型调用。
static func is_level_key(value: Variant) -> bool:
	if not value is String:
		return false
	var separator: int = value.find(":")
	if separator < 0:
		return DataValidation.is_id(value)
	return value.left(separator) in ["tutorial", "official", "player"] and DataValidation.is_id(value.substr(separator + 1))


## 身份沿用有来源域的合法地图 ID，档位和整机数在转换前严格验证真实类型。
func _validate_level_context(level_id: String, mode: String, enemy_count: Variant = 0) -> DataResult:
	if not level_id.is_empty() and not is_level_key(level_id):
		return DataResult.failure("关卡统计标识无效。")
	if not HINT_RANK.has(mode):
		return DataResult.failure("关卡统计辅助档位无效。")
	if not DataValidation.is_integer(enemy_count, 0, MAX_COUNTER):
		return DataResult.failure("关卡统计敌人数量无效。")
	return DataResult.success()


## 在候选快照中创建有界逐关记录，并保留其中未知扩展；成功前只允许提高辅助档。
func _prepare_level_record(statistics: Dictionary, level_id: String, mode: String) -> DataResult:
	if not statistics.has("level_ledger"):
		statistics["level_ledger"] = {}
	var ledger: Dictionary = statistics["level_ledger"]
	if not ledger.has(level_id):
		if ledger.size() >= MAX_LEVEL_RECORDS:
			return DataResult.failure("玩家逐关统计已达到档案上限。")
		ledger[level_id] = {"failures": 0, "completed": false, "success_weight": 0.0, "hint_mode": mode, "enemy_count": 0}
	var record: Dictionary = ledger[level_id]
	if not record["completed"] and int(HINT_RANK[mode]) > int(HINT_RANK[record["hint_mode"]]):
		record["hint_mode"] = mode
	return DataResult.success(record)


## 首通权重为辅助系数乘以关卡完整敌方机器数量系数，模块数量不参与计算。
static func _completion_weight(mode: String, enemy_count: int) -> float:
	var enemy_weight := 1.0
	if enemy_count == 0:
		enemy_weight = 0.4
	elif enemy_count <= 4:
		enemy_weight = 0.6
	elif enemy_count <= 8:
		enemy_weight = 0.85
	return float(HINT_WEIGHT[mode]) * enemy_weight


## 累加应用活动时间；零增量不写盘，非法数值或累计溢出不改变已有统计。
func record_play_time(seconds: Variant) -> DataResult:
	if not DataValidation.is_number(seconds) or float(seconds) < 0.0:
		return _remember_result(DataResult.failure("累积游戏时间必须是非负有限秒数。"))
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	if float(seconds) == 0.0:
		return _remember_result(DataResult.success(self))
	var next := _config.duplicate(true)
	var statistics: Dictionary = next["statistics"]
	var total := float(statistics.get("play_seconds", 0.0)) + float(seconds)
	if not is_finite(total):
		return _remember_result(DataResult.failure("累积游戏时间已超出可保存范围，原档案保持不变。"))
	statistics["play_seconds"] = total
	return _commit(next)


## 首次进入彩蛋即持久解锁未知统计，即使尚未得分；重复发现不写盘。
func record_shark_discovery() -> DataResult:
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	if get_statistics()["shark_discovered"]:
		return _remember_result(DataResult.success(self))
	var next := _config.duplicate(true)
	next["statistics"]["shark_discovered"] = true
	return _commit(next)


## 彩蛋成绩只保存真实最高值，正分同时解锁发现标记，低分不覆盖最高分。
func record_shark_score(score: int) -> DataResult:
	if score < 0 or score > MAX_COUNTER:
		return _remember_result(DataResult.failure("最高分必须是有效的非负整数。"))
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	var best := int(_config["statistics"].get("shark_best_score", 0))
	var discovered := bool(get_statistics()["shark_discovered"])
	if score <= best and (score == 0 or discovered):
		return _remember_result(DataResult.success(self))
	var next := _config.duplicate(true)
	next["statistics"]["shark_best_score"] = maxi(best, score)
	if score > 0:
		next["statistics"]["shark_discovered"] = true
	return _commit(next)


## 仅在系统确认后调用：替换整个玩家档案并生成新 UID，不触及地图、进度或草稿。
func reset_profile() -> DataResult:
	var fresh := _new_profile(get_uid())
	if not fresh.is_ok():
		return _remember_result(fresh)
	return _commit(fresh.value, true)


## 输入预处理按 Unicode 字符过滤和限长，粘贴内容中的表情不会占用正常文字额度。
static func sanitize_username(value: String) -> String:
	var output := ""
	for character: String in value:
		if _is_username_character(character):
			output += character
			if output.length() >= MAX_USERNAME_LENGTH:
				break
	return output


## 校验完整用户名，允许普通中外文字和标点，禁止空白名称与表情码点。
static func is_username(value: Variant) -> bool:
	if not value is String or value.strip_edges().is_empty() or value.length() > MAX_USERNAME_LENGTH:
		return false
	for character: String in value:
		if not _is_username_character(character):
			return false
	return true


## UID 接受 10..13 位十进制数字，可重复数字但首位不能为零。
static func is_uid(value: Variant) -> bool:
	if not value is String or value.length() < 10 or value.length() > 13 or value.begins_with("0"):
		return false
	for character: String in value:
		if not character in "0123456789":
			return false
	return true


## 使用现有普通文字分类，补上私用区禁令以避免 Apple 等平台专属字符。
static func _is_username_character(character: String) -> bool:
	return not DataValidation.is_private_use_character(character.unicode_at(0)) and DataValidation.is_level_subtitle(character)


## 首次使用和重置生成相同格式的新档案，独立随机源不影响游戏随机行为。
func _new_profile(previous_uid: String) -> DataResult:
	var random := RandomNumberGenerator.new()
	random.randomize()
	for _attempt in range(32):
		var uid := str(random.randi_range(1, 9))
		for _digit in range(12):
			uid += str(random.randi_range(0, 9))
		if uid != previous_uid:
			return DataResult.success({"format_version": 1, "uid": uid, "username": DEFAULT_USERNAME, "statistics": _empty_statistics()})
	return DataResult.failure("无法生成新的玩家 UID，原档案保持不变。")


## 没有成功完成记录时耗时为零，由显示层转换为空记录提示。
static func _empty_statistics() -> Dictionary:
	return {"code_hint_uses": 0, "play_seconds": 0.0, "successes": 0, "failures": 0, "fastest_seconds": 0.0, "longest_seconds": 0.0, "shark_best_score": 0, "shark_discovered": false, "level_ledger": {}}


## 普通操作先载入并复核磁盘指纹，避免覆盖损坏文件或另一个进程的新档案。
func _prepare_mutation() -> DataResult:
	if not _loaded:
		var loaded := load_profile()
		if not loaded.is_ok():
			return loaded
	if not _writable:
		return _remember_result(DataResult.failure("玩家档案未成功载入，原文件保持不变。"))
	var checked := _validate_path()
	if not checked.is_ok():
		return _remember_result(checked)
	if _fingerprint.is_empty() or FileAccess.get_sha256(storage_path) != _fingerprint:
		return _remember_result(DataResult.failure("玩家档案已在外部改变，请重新载入后再试；原文件保持不变。"))
	return DataResult.success()


## 有界计数增长保留顶层和统计对象中的未知扩展字段。
func _increment_counter(key: String) -> DataResult:
	var ready := _prepare_mutation()
	if not ready.is_ok():
		return ready
	var next := _config.duplicate(true)
	var statistics: Dictionary = next["statistics"]
	if int(statistics[key]) >= MAX_COUNTER:
		return _remember_result(DataResult.failure("玩家统计计数已达到档案上限。"))
	statistics[key] = int(statistics[key]) + 1
	return _commit(next)


## 专用上限防止异常档案占用大量内存，载入失败不修改当前有效内存快照。
func _read_profile() -> DataResult:
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取玩家档案：%s。" % error_string(FileAccess.get_open_error()))
	if file.get_length() > MAX_PROFILE_BYTES:
		file.close()
		return DataResult.failure("玩家档案超过 4 MiB，原文件保持不变。")
	var source := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(source) != OK or not parser.data is Dictionary:
		return DataResult.failure("玩家档案 JSON 损坏，原文件保持不变。")
	var checked := _validate_config(parser.data)
	return DataResult.success(parser.data) if checked.is_ok() else checked


## 身份与统计先完整验证，非法版本、类型或非有限值不能通过单项修改被修复覆盖。
func _validate_config(data: Dictionary) -> DataResult:
	if not DataValidation.is_json_value(data) or not DataValidation.is_integer(data.get("format_version"), 1, 1):
		return DataResult.failure("玩家档案版本或 JSON 内容无效，原文件保持不变。")
	if not is_uid(data.get("uid")) or not is_username(data.get("username")) or not data.get("statistics") is Dictionary:
		return DataResult.failure("玩家档案身份信息无效，原文件保持不变。")
	var statistics: Dictionary = data["statistics"]
	for key: String in ["code_hint_uses", "successes", "failures"]:
		if not DataValidation.is_integer(statistics.get(key), 0, MAX_COUNTER):
			return DataResult.failure("玩家统计计数无效，原文件保持不变。")
	for key: String in ["fastest_seconds", "longest_seconds"]:
		if not DataValidation.is_number(statistics.get(key)) or float(statistics[key]) < 0.0:
			return DataResult.failure("玩家通关耗时无效，原文件保持不变。")
	# 新统计为版本 1 的可选字段；旧档案读取默认零，不因缺省值改写磁盘原文。
	if not DataValidation.is_number(statistics.get("play_seconds", 0.0)) or float(statistics.get("play_seconds", 0.0)) < 0.0:
		return DataResult.failure("玩家累积游戏时间无效，原文件保持不变。")
	if not DataValidation.is_integer(statistics.get("shark_best_score", 0), 0, MAX_COUNTER):
		return DataResult.failure("玩家最高分无效，原文件保持不变。")
	if statistics.has("shark_discovered") and not statistics["shark_discovered"] is bool:
		return DataResult.failure("玩家隐藏统计状态无效，原文件保持不变。")
	var ledger := _validate_level_ledger(statistics.get("level_ledger", {}))
	if not ledger.is_ok():
		return ledger
	if float(statistics["fastest_seconds"]) > float(statistics["longest_seconds"]):
		return DataResult.failure("玩家通关耗时范围无效，原文件保持不变。")
	if int(statistics["successes"]) == 0 and (float(statistics["fastest_seconds"]) != 0.0 or float(statistics["longest_seconds"]) != 0.0):
		return DataResult.failure("没有成功记录的玩家档案不能包含通关耗时。")
	return DataResult.success()


## 逐关记录数量、身份、计数、枚举与首通权重均有边界，旧档案缺失账本合法。
func _validate_level_ledger(value: Variant) -> DataResult:
	if not value is Dictionary or value.size() > MAX_LEVEL_RECORDS:
		return DataResult.failure("玩家逐关统计记录无效，原文件保持不变。")
	for level_id: Variant in value:
		var record: Variant = value[level_id]
		if not is_level_key(level_id) or not record is Dictionary:
			return DataResult.failure("玩家逐关统计记录无效，原文件保持不变。")
		if not DataValidation.is_integer(record.get("failures"), 0, MAX_COUNTER) or not record.get("completed") is bool or not HINT_RANK.has(record.get("hint_mode")) or not DataValidation.is_integer(record.get("enemy_count"), 0, MAX_COUNTER):
			return DataResult.failure("玩家逐关统计记录无效，原文件保持不变。")
		if not DataValidation.is_number(record.get("success_weight")) or float(record["success_weight"]) < 0.0 or float(record["success_weight"]) > 1.0:
			return DataResult.failure("玩家逐关统计记录无效，原文件保持不变。")
		var expected := _completion_weight(record["hint_mode"], int(record["enemy_count"])) if record["completed"] else 0.0
		if not is_equal_approx(float(record["success_weight"]), expected) or (not record["completed"] and int(record["enemy_count"]) != 0):
			return DataResult.failure("玩家逐关统计记录无效，原文件保持不变。")
	return DataResult.success()


## 只接受安全 user:// 文件路径，逐段拒绝符号链接及目录占位，不访问其他玩家文件。
func _validate_path() -> DataResult:
	if not storage_path.begins_with("user://") or not DataValidation.is_resource_path(storage_path):
		return DataResult.failure("玩家档案路径必须是安全的 user:// 文件路径。")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问玩家数据目录。")
	var segments := storage_path.trim_prefix("user://").split("/")
	for index in range(segments.size()):
		var segment: String = segments[index]
		if folder.is_link(segment):
			return DataResult.failure("玩家档案路径不能包含符号链接。")
		if index == segments.size() - 1:
			return DataResult.failure("玩家档案文件路径被目录占用。") if folder.dir_exists(segment) else DataResult.success()
		if not folder.dir_exists(segment):
			return DataResult.failure("玩家档案目录被文件占用。") if folder.file_exists(segment) else DataResult.success()
		if folder.change_dir(segment) != OK:
			return DataResult.failure("无法访问玩家档案目录。")
	return DataResult.failure("玩家档案路径无效。")


## 验证、回读和替换全部成功后才更新内存，写入失败保留 UID、用户名和统计。
func _commit(next: Dictionary, explicit_replacement: bool = false) -> DataResult:
	var checked := _validate_path()
	if checked.is_ok():
		checked = _validate_config(next)
	if checked.is_ok() and not explicit_replacement:
		checked = _prepare_mutation()
	if not checked.is_ok():
		return _remember_result(checked)
	var source := JSON.stringify(next, "\t", false) + "\n"
	if source.to_utf8_buffer().size() > MAX_PROFILE_BYTES:
		return _remember_result(DataResult.failure("玩家档案超过 4 MiB，原文件保持不变。"))
	var absolute := ProjectSettings.globalize_path(storage_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if directory_error != OK:
		return _remember_result(DataResult.failure("无法创建玩家档案目录：%s。" % error_string(directory_error)))
	var suffix := ".%d.%d.%s" % [OS.get_process_id(), Time.get_ticks_usec(), Crypto.new().generate_random_bytes(8).hex_encode()]
	var temporary := absolute + suffix + ".tmp"
	var backup := absolute + suffix + ".bak"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _remember_result(DataResult.failure("无法创建临时玩家档案：%s。" % error_string(FileAccess.get_open_error())))
	file.store_string(source)
	file.flush()
	var write_error := file.get_error()
	file.close()
	var readback := DataValidation.read_json_object(temporary)
	if write_error != OK or not readback.is_ok() or readback.value != JSON.parse_string(source):
		DirAccess.remove_absolute(temporary)
		return _remember_result(DataResult.failure("玩家档案写入或回读失败，原文件保持不变。"))
	# 临时文件验证期间也可能发生外部写入，普通更新必须再次比较指纹。
	if not explicit_replacement and FileAccess.get_sha256(storage_path) != _fingerprint:
		DirAccess.remove_absolute(temporary)
		return _remember_result(DataResult.failure("玩家档案已在外部改变，原文件保持不变。"))
	var saved := _replace_file(temporary, absolute, backup)
	if not saved.is_ok():
		return _remember_result(saved)
	_config = next.duplicate(true)
	_fingerprint = FileAccess.get_sha256(storage_path)
	_loaded = true
	_writable = true
	changed.emit()
	return _remember_result(DataResult.success(self))


## Windows 不保证覆盖式改名，先保留原件，替换失败则恢复，恢复失败保留备份路径。
func _replace_file(temporary: String, destination: String, backup: String) -> DataResult:
	var had_original := FileAccess.file_exists(destination)
	if had_original:
		var backup_error := _rename_file(destination, backup)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary)
			return DataResult.failure("无法备份原玩家档案，原文件保持不变。")
	var replace_error := _rename_file(temporary, destination)
	if replace_error != OK:
		var restore_error := _rename_file(backup, destination) if had_original else OK
		DirAccess.remove_absolute(temporary)
		if restore_error != OK:
			return DataResult.failure("玩家档案替换与恢复均失败，原件保留于：%s。" % backup)
		return DataResult.failure("玩家档案替换失败，原文件保持不变。")
	if had_original and DirAccess.remove_absolute(backup) != OK:
		push_warning("玩家档案已保存，但无法删除临时备份：%s。" % backup)
	return DataResult.success(destination)


## 将系统改名集中在可注入边界，测试能验证真实备份和恢复流程。
func _rename_file(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


## 成功清除旧错误，失败保留具体原因供设置页面显示。
func _remember_result(result: DataResult) -> DataResult:
	last_error = "\n".join(result.errors)
	return result
