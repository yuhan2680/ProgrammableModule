extends SceneTree
## 档案模型回归只使用隔离目录，验证身份稳定、统计持久与真实替换失败回滚。

class FailingProfile:
	extends PlayerProfileStore
	var fail_replace: bool = false

	## 故障只注入临时文件替换，不阻止原件备份或恢复。
	func _rename_file(source: String, destination: String) -> Error:
		if fail_replace and source.ends_with(".tmp"):
			return ERR_CANT_CREATE
		return super._rename_file(source, destination)

class DateProfile:
	extends FailingProfile
	var local_date := "2026-09-14"
	var external_source := ""

	## 注入本机日期或读后外部变更，不修改操作系统时钟或真实玩家文件。
	func _current_local_date() -> String:
		if not external_source.is_empty():
			var file := FileAccess.open(storage_path, FileAccess.WRITE)
			file.store_string(external_source)
			file.close()
			external_source = ""
		return local_date

var _checks: int = 0
var _failures: int = 0
var _directory: String = ""
var _changes: int = 0


## 延迟执行以保证 user:// 初始化完成，全部测试结束后清理专用夹具。
func _initialize() -> void:
	_run.call_deferred()


## 同时检查成功路径与损坏、冲突、替换故障三种不可覆盖边界。
func _run() -> void:
	_directory = "user://tests/player_profile_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_directory))
	_test_username_and_uid()
	_test_persistence()
	_test_first_run_date()
	_test_first_run_migration()
	_test_first_run_date_failures()
	_test_weighted_rate()
	_test_weighted_migration_and_limits()
	_test_weighted_namespace_and_rollback()
	_test_activity_statistics()
	_test_shark_discovery()
	_test_legacy_activity_statistics()
	_test_invalid_profiles()
	_test_atomic_rollback()
	_test_external_changes()
	_test_path_boundaries()
	_cleanup(_directory)
	print("玩家档案回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 各语言正常姓名保留，输入与粘贴均拒绝表情、平台专属字形和不可见控制码。
func _test_username_and_uid() -> void:
	for name: String in ["Player", "小海豚", "Éléonore", "YWＭKerman", "玩家 1", "O'Neill", "名前・太郎"]:
		_check(PlayerProfileStore.is_username(name), "普通 Unicode 姓名可用：%s" % name)
	for name: String in ["", "   ", "abcdefghijkl", "Player🐬", "Apple", "a\nb", "a\tb", "a\u200db", "x❤️", "x1️⃣", "x" + String.chr(0xF0000), "x" + String.chr(0x100000)]:
		_check(not PlayerProfileStore.is_username(name), "非法或超长姓名不能直接提交：%s" % name)
	_check(PlayerProfileStore.sanitize_username("🐬小海😀豚\n 玩家") == "小海豚 玩家", "过滤普通及 Apple 表情，同时保留正常文字与空格")
	_check(PlayerProfileStore.sanitize_username("1234567890🐬甲乙丙") == "1234567890甲", "先过滤再按 11 个 Unicode 字符截断")
	_check(PlayerProfileStore.sanitize_username("👨‍👩‍👧‍👦🇨🇳👍🏽❤️") == "", "组合表情、旗帜和肤色不能残留不可见组成字符")
	for uid: String in ["1111111111", "12222222222", "122222222222", "9000000000000"]:
		_check(PlayerProfileStore.is_uid(uid), "UID 支持 10..13 位、零和重复数字")
	for uid: String in ["0123456789", "123456789", "12345678901234", "123456789a", "１２３４５６７８９０", "-1234567890", ""]:
		_check(not PlayerProfileStore.is_uid(uid), "UID 拒绝前导零、非法长度和非 ASCII 数字")
	var generated: Dictionary = {}
	var generator := PlayerProfileStore.new(_directory.path_join("unused.json"))
	for _index in range(128):
		var result := generator._new_profile("")
		var uid: String = result.value.uid if result.is_ok() else ""
		_check(result.is_ok() and uid.length() == 13 and PlayerProfileStore.is_uid(uid), "每个新 UID 均为首位非零的 13 位随机数字")
		generated[uid] = true
	_check(generated.size() == 128, "独立新档案没有观察到重复 UID")
	_check(not FileAccess.file_exists(generator.storage_path), "纯生成身份不提前创建未提交档案")


## 首次生成、改名和重启保持身份，真实事件计数与最小最大耗时独立持久化。
func _test_persistence() -> void:
	var path := _directory.path_join("profile.json")
	var store := PlayerProfileStore.new(path)
	store.changed.connect(_on_changed)
	_check(store.load_profile().is_ok() and FileAccess.file_exists(path), "第一次载入完成 UID 持久化")
	var uid := store.get_uid()
	_check(PlayerProfileStore.is_uid(uid) and store.get_username() == "Player", "新档案使用默认姓名和只读随机身份")
	_check(store.get_statistics() == {"code_hint_uses": 0, "play_seconds": 0.0, "successes": 0, "failures": 0, "fastest_seconds": 0.0, "longest_seconds": 0.0, "shark_best_score": 0, "shark_discovered": false, "level_ledger": {}}, "新档案统计全部归零且未知栏目默认未发现")
	var event_count := _changes
	_check(store.set_username("小海豚").is_ok() and store.get_uid() == uid, "用户名变化不改变 UID")
	_check(_changes == event_count + 1, "只有成功提交发出变更通知")
	var before := FileAccess.get_file_as_bytes(path)
	event_count = _changes
	_check(not store.set_username("小海豚🐬").is_ok() and FileAccess.get_file_as_bytes(path) == before and store.get_username() == "小海豚", "非法改名保留磁盘和内存")
	_check(_changes == event_count, "非法改名不发出成功通知")
	_check(store.record_hint_use().is_ok() and store.record_hint_use().is_ok() and store.record_failure().is_ok(), "提示和真实失败各记录一次")
	_check(store.record_completion(75.5).is_ok() and store.record_completion(1427.0).is_ok() and store.record_completion(60.0).is_ok(), "活动墙钟耗时作为成功记录写盘")
	var stats := store.get_statistics()
	_check(stats.code_hint_uses == 2 and stats.failures == 1 and stats.successes == 3, "成功与失败可以计算 75% 的通过率")
	_check(stats.fastest_seconds == 60.0 and stats.longest_seconds == 1427.0, "最小和最大耗时取成功记录的实际秒数")
	stats["successes"] = 999
	_check(store.get_statistics().successes == 3, "外部改动返回字典不能修改档案")
	before = FileAccess.get_file_as_bytes(path)
	_check(not store.record_completion(INF).is_ok() and not store.record_completion(NAN).is_ok() and not store.record_completion(-1.0).is_ok() and FileAccess.get_file_as_bytes(path) == before, "非法耗时不污染统计")
	var restarted := PlayerProfileStore.new(path)
	_check(restarted.load_profile().is_ok() and restarted.get_uid() == uid and restarted.get_username() == "小海豚" and restarted.get_statistics() == store.get_statistics(), "重启后身份、姓名和统计全部稳定")
	_check(store.set_username("   ").is_ok() and store.get_username() == "Player" and store.get_uid() == uid, "清空姓名恢复默认 Player 并保留 UID")
	var extension: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	extension["extension"] = {"flag": "keep"}
	extension.statistics["unknown_stat"] = {"later": 42}
	_write(path, JSON.stringify(extension))
	_check(store.load_profile().is_ok() and store.record_failure().is_ok(), "载入未来扩展字段后仍能更新已知统计")
	var updated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var expected: Dictionary = JSON.parse_string(JSON.stringify(extension))
	_check(updated.extension == expected.extension and updated.statistics.unknown_stat == expected.statistics.unknown_stat, "普通统计更新保留顶层和统计未知字段")
	var map_path := _directory.path_join("map.json")
	_write(map_path, "{\"id\":\"map_keep\"}")
	var map_bytes := FileAccess.get_file_as_bytes(map_path)
	_check(store.reset_profile().is_ok() and store.get_uid() != uid and PlayerProfileStore.is_uid(store.get_uid()), "确认重置创建新 UID")
	_check(store.get_username() == "Player" and store.get_statistics().successes == 0 and store.get_statistics().failures == 0 and store.get_statistics().code_hint_uses == 0 and not JSON.parse_string(FileAccess.get_file_as_string(path)).has("extension"), "重置清除姓名、全部统计与旧档案扩展")
	_check(FileAccess.get_file_as_bytes(map_path) == map_bytes, "删除玩家档案不删除或修改关卡")


## 首次日期按本机日历持久化，改名、统计、跨日重启及删除档案都不重新计日。
func _test_first_run_date() -> void:
	var path := _directory.path_join("first_run.json")
	var store := DateProfile.new(path)
	_check(store.get_first_run_date().is_empty(), "未载入档案的首次日期安全显示为空")
	_check(store.load_profile().is_ok() and store.get_first_run_date() == "2026-9-14", "首次运行显示不补零的本机年月日")
	_check(JSON.parse_string(FileAccess.get_file_as_string(path)).first_run_date == "2026-09-14", "首次日期以规范 YYYY-MM-DD 落盘")
	var uid := store.get_uid()
	store.local_date = "2026-12-31"
	_check(store.set_username("FirstDay").is_ok() and store.record_hint_use().is_ok() and store.record_completion(15.0).is_ok() and store.get_first_run_date() == "2026-9-14", "改名和统计不会将首次日期更新成当前日期")
	var restarted := DateProfile.new(path)
	restarted.local_date = "2027-01-01"
	var bytes := FileAccess.get_file_as_bytes(path)
	_check(restarted.load_profile().is_ok() and restarted.get_first_run_date() == "2026-9-14" and FileAccess.get_file_as_bytes(path) == bytes, "跨日重启恢复已保存日期且不会重写已完整档案")
	_check(restarted.reset_profile().is_ok() and restarted.get_uid() != uid and restarted.get_first_run_date() == "2026-9-14" and restarted.get_statistics().successes == 0, "删除玩家档案更换身份并清空统计但保留本机首次日期")
	var direct_reset := DateProfile.new(path)
	direct_reset.local_date = "2030-02-01"
	_check(direct_reset.reset_profile().is_ok() and direct_reset.get_first_run_date() == "2026-9-14", "未先载入就确认重置也从旧档保留首次日期")
	for good: String in ["0001-01-01", "2000-02-29", "2024-02-29", "2400-02-29", "9999-12-31"]:
		_check(PlayerProfileStore._is_first_run_date(good), "合法公历日期接受：" + good)
	for bad: Variant in [null, 20260914, true, [], {}, "", "2026-9-14", "2026-09-1", "0000-01-01", "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32", "2026-04-31", "2026-02-29", "1900-02-29", "2100-02-29", "２０２６-09-14", "2026-09-14T00:00:00", "2026-09-14 ", " 026-09-14"]:
		_check(not PlayerProfileStore._is_first_run_date(bad), "首次日期拒绝错误类型、非规范格式和不存在的日期")


## 老档案以首次升级启动当天补写日期，只新增字段并完整保留旧身份、统计和未知扩展。
func _test_first_run_migration() -> void:
	var path := _directory.path_join("first_run_legacy.json")
	var generator := DateProfile.new(path)
	var legacy: Dictionary = generator._new_profile("").value
	legacy.erase("first_run_date")
	legacy.username = "Legacy"
	legacy.statistics.code_hint_uses = 17
	legacy.statistics.future_stat = {"saved": [1, true, "future"]}
	legacy.future_root = {"preserve": "unchanged"}
	_write(path, JSON.stringify(legacy))
	var store := DateProfile.new(path)
	store.local_date = "2026-10-15"
	store.changed.connect(_on_changed)
	var before_events := _changes
	_check(store.load_profile().is_ok() and store.get_first_run_date() == "2026-10-15", "缺少首次日期的旧档案按升级后首次启动日记录")
	_check(_changes == before_events + 1, "迁移只在原子落盘成功后通知一次")
	var migrated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(migrated.first_run_date == "2026-10-15" and migrated.uid == legacy.uid and migrated.username == "Legacy", "升级仅增加日期而不更换 UID 或姓名")
	migrated.erase("first_run_date")
	_check(migrated == JSON.parse_string(JSON.stringify(legacy)), "迁移保留原有全部统计和未知扩展")
	var bytes := FileAccess.get_file_as_bytes(path)
	store.local_date = "2026-11-01"
	_check(store.load_profile().is_ok() and store.get_first_run_date() == "2026-10-15" and FileAccess.get_file_as_bytes(path) == bytes, "升级后的第二次启动不覆盖首次升级日期")
	store.local_date = "2026-11-30"
	_check(store.reset_profile().is_ok() and store.get_first_run_date() == "2026-10-15", "升级后再删除档案仍保留首次升级日期")


## 日期迁移写盘失败、磁盘变更和坏日期均不覆盖有效原件，也不能把未落盘日期当作成功显示。
func _test_first_run_date_failures() -> void:
	var path := _directory.path_join("first_run_failure.json")
	var fresh := DateProfile.new(path)
	fresh.fail_replace = true
	_check(not fresh.load_profile().is_ok() and fresh.get_first_run_date().is_empty() and not FileAccess.file_exists(path), "首次创建落盘失败不显示尚未保存的日期")
	var legacy: Dictionary = fresh._new_profile("").value
	legacy.erase("first_run_date")
	legacy.username = "Before"
	_write(path, JSON.stringify(legacy))
	var bytes := FileAccess.get_file_as_bytes(path)
	var store := DateProfile.new(path)
	store.fail_replace = true
	store.changed.connect(_on_changed)
	var before_events := _changes
	_check(not store.load_profile().is_ok() and store.get_first_run_date().is_empty() and FileAccess.get_file_as_bytes(path) == bytes and _changes == before_events, "旧档迁移失败完整恢复原文、不显示伪日期、不发成功信号")
	_check(not store.record_hint_use().is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "迁移未完成时普通统计不能绕过失败保护")
	store.fail_replace = false
	store.local_date = "2026-10-16"
	_check(store.load_profile().is_ok() and store.get_first_run_date() == "2026-10-16" and store.get_username() == "Before", "迁移故障解除后以首次成功记录日期继续")
	bytes = FileAccess.get_file_as_bytes(path)
	store.fail_replace = true
	store.local_date = "2035-01-01"
	_check(not store.reset_profile().is_ok() and store.get_first_run_date() == "2026-10-16" and FileAccess.get_file_as_bytes(path) == bytes, "删除档案写入失败继续保留原首次日期和文件")
	_write(path, JSON.stringify(legacy))
	var conflict := DateProfile.new(path)
	var external := legacy.duplicate(true)
	external.username = "External"
	conflict.external_source = JSON.stringify(external)
	_check(not conflict.load_profile().is_ok() and conflict.get_first_run_date().is_empty() and JSON.parse_string(FileAccess.get_file_as_string(path)).username == "External" and not JSON.parse_string(FileAccess.get_file_as_string(path)).has("first_run_date"), "读取旧档后发生外部写入时迁移不能覆盖外部档案")
	for bad: Variant in [null, true, 20260914, "2026-02-29", "2026-9-14", "2026-99-01"]:
		var invalid := legacy.duplicate(true)
		invalid.first_run_date = bad
		_write(path, JSON.stringify(invalid))
		bytes = FileAccess.get_file_as_bytes(path)
		var broken := DateProfile.new(path)
		_check(not broken.load_profile().is_ok() and broken.get_first_run_date().is_empty() and not broken.record_hint_use().is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "已存在的坏日期拒绝载入和普通改写")
	var folder := DirAccess.open(_directory)
	var leftovers: Array[String] = []
	for name: String in folder.get_files():
		if name.begins_with("first_run_failure.json."):
			leftovers.append(name)
	_check(leftovers.is_empty(), "日期迁移成功、失败和冲突均不遗留临时文件")


## 权重覆盖所有档位和敌人数边界，失败只影响首通前的分母，重复挑战不改变该关账本。
func _test_weighted_rate() -> void:
	var path := _directory.path_join("weighted.json")
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok() and store.get_weighted_pass_rate() == -1.0, "全新档案没有可计算的逐关通过率")
	var total := 0.0
	var successes := 0
	for mode: String in ["none", "normal", "more"]:
		for enemy_count: int in [0, 1, 4, 5, 8, 9, 20]:
			var level_id := "weighted_%s_%d" % [mode, enemy_count]
			var hint_weight := 1.0 if mode == "none" else 0.5 if mode == "normal" else 0.3
			var enemy_weight := 0.4 if enemy_count == 0 else 0.6 if enemy_count <= 4 else 0.85 if enemy_count <= 8 else 1.0
			var expected := hint_weight * enemy_weight
			_check(store.record_completion(10.0, level_id, mode, enemy_count).is_ok(), "全部提示档位与整机数量边界可记录首通")
			total += expected
			successes += 1
			_check(is_equal_approx(store.get_statistics().level_ledger[level_id].success_weight, expected) and is_equal_approx(store.get_weighted_pass_rate(), total / successes), "新率为成功权重之和除以成功与失败总次数")
	var retry := PlayerProfileStore.new(_directory.path_join("weighted_retry.json"))
	_check(retry.load_profile().is_ok() and retry.record_failure("once", "none").is_ok() and retry.get_weighted_pass_rate() == 0.0, "首通前真实失败计入分母，零次成功显示0%")
	_check(retry.record_completion(75.0, "once", "none", 0).is_ok() and is_equal_approx(retry.get_weighted_pass_rate(), 0.2), "none零敌人一次失败后首通为40%除以2次")
	var ledger: Dictionary = retry.get_statistics().level_ledger.duplicate(true)
	_check(retry.record_failure("once", "more").is_ok() and retry.record_completion(40.0, "once", "more", 20).is_ok() and retry.get_statistics().level_ledger == ledger and is_equal_approx(retry.get_weighted_pass_rate(), 0.2), "首次成功后该关的失败、重通及档位变化均不改变新率")
	_check(retry.get_statistics().fastest_seconds == 40.0 and retry.get_statistics().longest_seconds == 75.0 and retry.record_hint_use().is_ok() and retry.record_play_time(1.0).is_ok(), "重复挑战仍更新耗时，累计提示和游戏时间继续记录")
	var assisted := PlayerProfileStore.new(_directory.path_join("weighted_assisted.json"))
	_check(assisted.load_profile().is_ok() and assisted.record_level_hint_mode("assisted", "more").is_ok() and assisted.get_weighted_pass_rate() == -1.0, "仅进入关卡和提高辅助档不伪造成功或失败")
	var bytes := FileAccess.get_file_as_bytes(assisted.storage_path)
	_check(assisted.record_level_hint_mode("assisted", "none").is_ok() and FileAccess.get_file_as_bytes(assisted.storage_path) == bytes, "辅助档降低或重复同步幂等，不擦除已经历的more")
	var restarted := PlayerProfileStore.new(assisted.storage_path)
	_check(restarted.load_profile().is_ok() and restarted.record_completion(30.0, "assisted", "none", 0).is_ok() and is_equal_approx(restarted.get_weighted_pass_rate(), 0.12) and restarted.get_statistics().level_ledger.assisted.hint_mode == "more", "more改为none并重启仍按最高辅助档记录12%")
	bytes = FileAccess.get_file_as_bytes(restarted.storage_path)
	for bad: Variant in [true, -1, 0.5, "9", INF, NAN]:
		_check(not restarted.record_completion(1.0, "invalid", "none", bad).is_ok() and FileAccess.get_file_as_bytes(restarted.storage_path) == bytes, "非法整机数量在写盘前拒绝")
	_check(not restarted.record_failure("bad/id", "none").is_ok() and not restarted.record_completion(1.0, "ok", "invalid", 0).is_ok() and not restarted.record_level_hint_mode("", "normal").is_ok() and FileAccess.get_file_as_bytes(restarted.storage_path) == bytes, "非法关卡身份与提示枚举不能污染统计")
	_check(restarted.reset_profile().is_ok() and restarted.get_statistics().level_ledger.is_empty() and restarted.get_weighted_pass_rate() == -1.0, "明确重置清空逐关账本与新率")


## 旧汇总无法分关回填；迁移只补缺省视图，有界账本保留扩展且拒绝非法数据。
func _test_weighted_migration_and_limits() -> void:
	var path := _directory.path_join("weighted_legacy.json")
	var legacy: Dictionary = PlayerProfileStore.new()._new_profile("").value
	legacy.statistics.erase("level_ledger")
	legacy.statistics.successes = 3
	legacy.statistics.failures = 1
	legacy.statistics.fastest_seconds = 2.0
	legacy.statistics.longest_seconds = 8.0
	legacy.extension = "keep"
	_write(path, JSON.stringify(legacy))
	var bytes := FileAccess.get_file_as_bytes(path)
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok() and store.get_uid() == legacy.uid and store.get_statistics().successes == 3 and store.get_statistics().failures == 1 and store.get_weighted_pass_rate() == -1.0 and FileAccess.get_file_as_bytes(path) == bytes, "旧计数保留但不伪造分关权重，读取不改磁盘和身份")
	_check(store.record_completion(5.0, "new_level", "none", 0).is_ok() and is_equal_approx(store.get_weighted_pass_rate(), 0.4) and store.get_statistics().successes == 4, "迁移后新率从可定位的首次成功单独开始，历史挑战计数仍保留")
	var valid: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	valid.statistics.level_ledger.new_level.future = {"keep": [true, 42]}
	_write(path, JSON.stringify(valid))
	_check(store.load_profile().is_ok() and store.record_failure("another", "normal").is_ok() and JSON.parse_string(FileAccess.get_file_as_string(path)).statistics.level_ledger.new_level.future == JSON.parse_string(JSON.stringify(valid)).statistics.level_ledger.new_level.future, "逐关记录的未知扩展字段随其他事件完整保留")
	for key: String in ["failures", "completed", "hint_mode", "enemy_count", "success_weight"]:
		var invalid := valid.duplicate(true)
		invalid.statistics.level_ledger.new_level[key] = "invalid"
		_check(not store._validate_config(invalid).is_ok(), "逐关字段严格验证真实类型：" + key)
	var invalid_weight := valid.duplicate(true)
	invalid_weight.statistics.level_ledger.new_level.success_weight = 1.0
	_check(not store._validate_config(invalid_weight).is_ok(), "磁盘成功权重须匹配已存档位和完整敌人数量")
	var many: Dictionary = PlayerProfileStore.new()._new_profile("").value
	for index in PlayerProfileStore.MAX_LEVEL_RECORDS:
		many.statistics.level_ledger["bounded_%d" % index] = {"failures": 0, "completed": false, "success_weight": 0.0, "hint_mode": "none", "enemy_count": 0}
	_check(store._validate_config(many).is_ok() and JSON.stringify(many).to_utf8_buffer().size() < PlayerProfileStore.MAX_PROFILE_BYTES, "8192条正常逐关记录在4MiB边界内合法")
	_write(path, JSON.stringify(many))
	_check(store.load_profile().is_ok(), "正常大量逐关记录可真实回读")
	bytes = FileAccess.get_file_as_bytes(path)
	_check(not store.record_failure("beyond_limit", "none").is_ok() and not store.record_level_hint_mode("beyond_limit", "none").is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "账本满时拒绝新关卡并保留有效原件")
	_check(store.record_failure("bounded_0", "none").is_ok(), "账本满仍能更新已有关卡")
	var extra := many.duplicate(true)
	extra.statistics.level_ledger["too_many"] = extra.statistics.level_ledger.bounded_0.duplicate(true)
	_check(not store._validate_config(extra).is_ok(), "磁盘账本超出条数上限拒绝载入")


## 同名地图按来源域独立统计，已有嵌套记录的失败替换也不能泄漏候选改动。
func _test_weighted_namespace_and_rollback() -> void:
	for key: String in ["level_012", "tutorial:level_012", "official:level_012", "player:level_012", "player:" + "a".repeat(128)]:
		_check(PlayerProfileStore.is_level_key(key), "裸ID与三个有界来源域键均合法")
	for key: Variant in [null, true, "", "unknown:level_012", "tutorial:", "tutorial:void", "tutorial:bad/id", "tutorial:level:012", "player:" + "a".repeat(129)]:
		_check(not PlayerProfileStore.is_level_key(key), "非法来源域、后缀与非字符串键拒绝")
	var path := _directory.path_join("weighted_namespace.json")
	var store := FailingProfile.new(path)
	_check(store.load_profile().is_ok() and store.record_completion(5.0, "tutorial:same", "none", 9).is_ok() and store.record_failure("player:same", "none").is_ok() and store.record_completion(10.0, "official:same", "more", 0).is_ok(), "同名教学、正式与玩家关卡均独立记录")
	_check(store.get_statistics().level_ledger.size() == 3 and not store.get_statistics().level_ledger["player:same"].completed and is_equal_approx(store.get_weighted_pass_rate(), 1.12 / 3.0), "同名玩家失败不会被冻结的教学首通吞掉")
	var snapshot := store.get_statistics()
	var bytes := FileAccess.get_file_as_bytes(path)
	store.changed.connect(_on_changed)
	var events := _changes
	store.fail_replace = true
	_check(not store.record_failure("player:same", "normal").is_ok() and not store.record_completion(1.0, "player:same", "more", 9).is_ok() and not store.record_level_hint_mode("player:same", "more").is_ok(), "已有未首通记录的失败、首通与辅助提高均覆盖真实替换故障")
	_check(store.get_statistics() == snapshot and FileAccess.get_file_as_bytes(path) == bytes and _changes == events, "深复制保证既有failure计数、辅助档及成功标志不泄漏到原内存")
	store.fail_replace = false
	_check(store.record_completion(12.0, "player:same", "none", 0).is_ok() and is_equal_approx(store.get_weighted_pass_rate(), 1.52 / 4.0), "失败写盘恢复后仍可按正确原记录完成首通")


## 游戏时间累加和最高分更新独立持久化，零增量、低分与非法值不能额外写盘。
func _test_activity_statistics() -> void:
	var path := _directory.path_join("activity.json")
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok() and store.record_play_time(12.5).is_ok() and store.record_play_time(47.5).is_ok(), "有效活动秒数累计成功")
	store.changed.connect(_on_changed)
	var uid := store.get_uid()
	var before := FileAccess.get_file_as_bytes(path)
	var events := _changes
	_check(is_equal_approx(store.get_statistics().play_seconds, 60.0) and store.get_statistics().shark_best_score == 0, "累积秒数保持浮点，未游玩最高分默认零")
	_check(store.record_play_time(0.0).is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "零增量不写盘或发送变更通知")
	for bad in [true, false, null, "60", [], {}, -0.1, INF, NAN]:
		_check(not store.record_play_time(bad).is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "非法游戏时间拒绝且保留整个档案")
	_check(store.record_shark_score(80).is_ok() and store.record_shark_score(120).is_ok() and store.get_statistics().shark_best_score == 120, "最高分只向上更新")
	before = FileAccess.get_file_as_bytes(path)
	events = _changes
	for score: int in [0, 80, 120]:
		_check(store.record_shark_score(score).is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "重复和较低成绩不写盘或通知")
	for score: int in [-1, PlayerProfileStore.MAX_COUNTER + 1]:
		_check(not store.record_shark_score(score).is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "非法最高分不影响现有成绩")
	var reloaded := PlayerProfileStore.new(path)
	_check(reloaded.load_profile().is_ok() and reloaded.get_uid() == uid and reloaded.get_statistics().play_seconds == 60.0 and reloaded.get_statistics().shark_best_score == 120, "活动时间与最高分重启后恢复，UID 不改变")
	_check(store.record_play_time(1e308).is_ok(), "有限大值仍按统一有限数值规则处理")
	before = FileAccess.get_file_as_bytes(path)
	events = _changes
	_check(not store.record_play_time(1e308).is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "累计溢出不覆盖已有有效档案")
	_check(store.reset_profile().is_ok() and store.get_uid() != uid and store.get_statistics().play_seconds == 0.0 and store.get_statistics().shark_best_score == 0, "确认重置同时清空活动时间和最高分并换 UID")
	_check(not store.get_statistics().shark_discovered, "重置清空最高分同时恢复未发现状态")


## 零分发现独立持久化，重复事件不写盘，正分兼容入口可以原子解锁。
func _test_shark_discovery() -> void:
	var path := _directory.path_join("discovery.json")
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok() and store.get_statistics().shark_discovered is bool and not store.get_statistics().shark_discovered, "新档案公开布尔发现状态且默认隐藏")
	store.changed.connect(_on_changed)
	var uid := store.get_uid()
	var before := FileAccess.get_file_as_bytes(path)
	var events := _changes
	_check(store.record_shark_score(0).is_ok() and not store.get_statistics().shark_discovered and FileAccess.get_file_as_bytes(path) == before and _changes == events, "仅保存零分不能代表玩家触发彩蛋")
	_check(store.record_shark_discovery().is_ok() and store.get_statistics().shark_discovered and store.get_statistics().shark_best_score == 0 and store.get_uid() == uid and _changes == events + 1, "首次零分发现原子落盘并只发送一次更新")
	before = FileAccess.get_file_as_bytes(path)
	events = _changes
	_check(store.record_shark_discovery().is_ok() and FileAccess.get_file_as_bytes(path) == before and _changes == events, "重复发现幂等且不改磁盘与通知")
	var restarted := PlayerProfileStore.new(path)
	_check(restarted.load_profile().is_ok() and restarted.get_statistics().shark_discovered and restarted.get_statistics().shark_best_score == 0 and restarted.get_uid() == uid, "零分解锁跨重启保持且不改变 UID")
	_check(store.reset_profile().is_ok() and not store.get_statistics().shark_discovered and store.get_statistics().shark_best_score == 0 and store.get_uid() != uid, "重置完整清空发现状态与最高分")
	_check(store.record_shark_score(50).is_ok() and store.get_statistics().shark_discovered, "非零成绩兼容入口同时解锁未知栏目")
	var hidden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	hidden.statistics.shark_discovered = false
	_write(path, JSON.stringify(hidden))
	_check(store.load_profile().is_ok() and not store.get_statistics().shark_discovered and store.record_shark_score(1).is_ok() and store.get_statistics().shark_discovered and store.get_statistics().shark_best_score == 50, "实际非零低分也可解锁但不能覆盖已有最高成绩")


## 版本一旧档案缺少新字段时只补显示默认，成功变更仍保留旧身份及所有扩展字段。
func _test_legacy_activity_statistics() -> void:
	var path := _directory.path_join("legacy_activity.json")
	var legacy: Dictionary = PlayerProfileStore.new()._new_profile("").value
	legacy.username = "Legacy"
	legacy.statistics.erase("play_seconds")
	legacy.statistics.erase("shark_best_score")
	legacy.statistics.erase("shark_discovered")
	legacy.statistics.erase("level_ledger")
	legacy.statistics.code_hint_uses = 7
	legacy.statistics.successes = 1
	legacy.statistics.fastest_seconds = 5.0
	legacy.statistics.longest_seconds = 9.0
	legacy.statistics.future_stat = {"keep": [true, 42]}
	legacy.future_root = "保留"
	_write(path, JSON.stringify(legacy))
	var bytes := FileAccess.get_file_as_bytes(path)
	var uid: String = legacy.uid
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok() and store.get_uid() == uid and store.get_username() == "Legacy", "旧版本一档案兼容载入，不更换身份")
	var stats := store.get_statistics()
	_check(stats.play_seconds == 0.0 and stats.shark_best_score == 0 and not stats.shark_discovered and stats.shark_discovered is bool and stats.play_seconds is float and stats.shark_best_score is int and FileAccess.get_file_as_bytes(path) == bytes, "读取新默认字段不改写旧文件")
	_check(store.record_play_time(7200.0).is_ok() and store.record_shark_score(456).is_ok() and store.get_uid() == uid, "旧档案直接使用新统计入口，身份保持不变")
	var updated: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(updated.future_root == "保留" and updated.statistics.future_stat == JSON.parse_string(JSON.stringify(legacy)).statistics.future_stat and updated.statistics.code_hint_uses == 7 and updated.statistics.successes == 1 and updated.statistics.fastest_seconds == 5.0, "新统计写盘保留原统计及全部未知扩展")
	var scored := legacy.duplicate(true)
	scored.statistics.shark_best_score = 456
	_write(path, JSON.stringify(scored))
	bytes = FileAccess.get_file_as_bytes(path)
	_check(store.load_profile().is_ok() and store.get_statistics().shark_discovered and store.get_statistics().shark_best_score == 456 and store.record_shark_discovery().is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "旧档案已有非零最高分推定已发现，读取和重复发现均不改写原文")
	for bad in [null, "true", 0, 1, [], {}]:
		var invalid := legacy.duplicate(true)
		invalid.statistics.shark_discovered = bad
		_write(path, JSON.stringify(invalid))
		bytes = FileAccess.get_file_as_bytes(path)
		var broken := PlayerProfileStore.new(path)
		_check(not broken.load_profile().is_ok() and not broken.record_shark_discovery().is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "发现状态只接受布尔值且非法档案不能被普通发现覆盖")
	for key: String in ["play_seconds", "shark_best_score"]:
		for bad in [true, null, "1", -1.0]:
			var invalid := legacy.duplicate(true)
			invalid.statistics[key] = bad
			_write(path, JSON.stringify(invalid))
			bytes = FileAccess.get_file_as_bytes(path)
			var broken := PlayerProfileStore.new(path)
			_check(not broken.load_profile().is_ok() and not broken.record_play_time(10.0).is_ok() and not broken.record_shark_score(20).is_ok() and FileAccess.get_file_as_bytes(path) == bytes, "新字段非法时拒绝载入和普通覆盖")
	var noninteger := legacy.duplicate(true)
	noninteger.statistics.shark_best_score = 12.5
	_check(not store._validate_config(noninteger).is_ok(), "磁盘最高分不能含小数")


## 损坏或不受支持的档案禁止普通事件覆盖，显式重置则允许恢复新档案。
func _test_invalid_profiles() -> void:
	var path := _directory.path_join("invalid.json")
	var generator := PlayerProfileStore.new()
	var valid: Dictionary = generator._new_profile("").value
	var bad_sources: Array[String] = ["{invalid", "[]"]
	for key: String in ["uid", "username", "format_version", "statistics"]:
		var document := valid.duplicate(true)
		match key:
			"uid": document.uid = "0123456789012"
			"username": document.username = "🐬"
			"format_version": document.format_version = 2
			"statistics": document.statistics.failures = true
		bad_sources.append(JSON.stringify(document))
	var wrong_time := valid.duplicate(true)
	wrong_time.statistics.longest_seconds = 1.0
	bad_sources.append(JSON.stringify(wrong_time))
	for source: String in bad_sources:
		_write(path, source)
		var before := FileAccess.get_file_as_bytes(path)
		var store := PlayerProfileStore.new(path)
		_check(not store.load_profile().is_ok(), "损坏或无效档案返回明确载入错误")
		_check(not store.record_failure().is_ok() and not store.record_hint_use().is_ok() and not store.set_username("Safe").is_ok() and FileAccess.get_file_as_bytes(path) == before, "普通改名和统计事件不能覆盖无效原件")
		_check(store.reset_profile().is_ok() and store.get_username() == "Player" and PlayerProfileStore.is_uid(store.get_uid()), "明确重置后才能替换坏档案")
	_write(path, "x".repeat(PlayerProfileStore.MAX_PROFILE_BYTES + 1))
	var store := PlayerProfileStore.new(path)
	_check(not store.load_profile().is_ok() and FileAccess.get_file_as_bytes(path).size() == PlayerProfileStore.MAX_PROFILE_BYTES + 1, "超大档案被拒绝但不截断原件")


## 注入改名失败覆盖真实备份恢复路径，失败不能提前发信号或提交新 UID。
func _test_atomic_rollback() -> void:
	var path := _directory.path_join("rollback.json")
	var store := FailingProfile.new(path)
	_check(store.load_profile().is_ok() and store.set_username("Before").is_ok() and store.record_completion(80.0).is_ok(), "故障夹具先落盘有效档案")
	var uid := store.get_uid()
	var stats := store.get_statistics()
	var bytes := FileAccess.get_file_as_bytes(path)
	store.changed.connect(_on_changed)
	var events := _changes
	store.fail_replace = true
	_check(not store.set_username("After").is_ok() and store.get_username() == "Before" and FileAccess.get_file_as_bytes(path) == bytes, "改名替换失败恢复旧磁盘并保留内存")
	_check(not store.record_failure().is_ok() and store.get_statistics() == stats and FileAccess.get_file_as_bytes(path) == bytes, "统计替换失败不增加失败数")
	_check(not store.record_play_time(60.0).is_ok() and not store.record_shark_score(123).is_ok() and store.get_statistics() == stats and FileAccess.get_file_as_bytes(path) == bytes, "活动时间和最高分替换失败都保留原磁盘与统计")
	_check(not store.record_shark_discovery().is_ok() and not store.get_statistics().shark_discovered and store.get_statistics() == stats and FileAccess.get_file_as_bytes(path) == bytes, "发现状态替换失败保持未解锁并恢复原文件")
	_check(not store.record_failure("rollback_level", "normal").is_ok() and not store.record_completion(1.0, "rollback_level", "more", 9).is_ok() and not store.record_level_hint_mode("rollback_level", "more").is_ok() and store.get_statistics() == stats and store.get_weighted_pass_rate() == -1.0 and FileAccess.get_file_as_bytes(path) == bytes, "带逐关账本的失败、首通与档位写入失败均原子回滚")
	_check(not store.reset_profile().is_ok() and store.get_uid() == uid and store.get_username() == "Before" and store.get_statistics() == stats and FileAccess.get_file_as_bytes(path) == bytes, "重置替换失败保留旧 UID 与整个档案")
	_check(_changes == events, "磁盘替换失败不会通知成功")
	store.fail_replace = false
	_check(store.record_failure().is_ok() and store.get_statistics().failures == 1, "故障消失后原档案仍可正常继续统计")
	var folder := DirAccess.open(_directory)
	var leftovers: Array[String] = []
	for name: String in folder.get_files():
		if name.begins_with("rollback.json."):
			leftovers.append(name)
	_check(leftovers.is_empty(), "成功和可恢复失败均清理临时备份")


## 同目录外部更新会阻止陈旧实例覆盖，而显式载入保留新内容后可继续编辑。
func _test_external_changes() -> void:
	var path := _directory.path_join("external.json")
	var store := PlayerProfileStore.new(path)
	_check(store.load_profile().is_ok(), "外部变更夹具初始化")
	var uid := store.get_uid()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	data.username = "External"
	data["unknown"] = 3
	_write(path, JSON.stringify(data))
	var before := FileAccess.get_file_as_bytes(path)
	_check(not store.record_hint_use().is_ok() and not store.set_username("Overwritten").is_ok() and FileAccess.get_file_as_bytes(path) == before and store.get_uid() == uid, "指纹冲突不覆盖外部新档案")
	_check(store.load_profile().is_ok() and store.get_username() == "External" and store.record_hint_use().is_ok(), "重新载入后按外部新内容提交")
	_check(JSON.parse_string(FileAccess.get_file_as_string(path)).unknown == 3, "重新载入保留外部扩展")


## 非用户路径、上级路径和同名目录都不能变成档案写入目标。
func _test_path_boundaries() -> void:
	for path: String in ["res://profile_forbidden.json", "user://../profile_forbidden.json", "user://", "user://tests//profile.json", "user://tests/./profile.json"]:
		var store := PlayerProfileStore.new(path)
		_check(not store.load_profile().is_ok() and not store.reset_profile().is_ok(), "非法注入路径在写盘前拒绝")
	var occupied := _directory.path_join("occupied.json")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(occupied))
	var store := PlayerProfileStore.new(occupied)
	_check(not store.load_profile().is_ok() and not store.reset_profile().is_ok() and DirAccess.dir_exists_absolute(occupied), "目录占位不被档案覆盖或删除")


## 用普通文件写入构造损坏和扩展夹具，不经过待测模型验证。
func _write(path: String, source: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(source)
	file.close()


## 计数提交信号以确认失败没有伪造 UI 成功更新。
func _on_changed() -> void:
	_changes += 1


## 报告所有失败而不中断后续边界回归。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只递归删除本 runner 创建的测试目录，不访问玩家正式档案或关卡。
func _cleanup(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for name: String in folder.get_directories():
		_cleanup(path.path_join(name))
	for name: String in folder.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
