extends SceneTree
## 独占 user://tests 夹具覆盖原始字节、断点恢复、删除保护及路径边界，不访问正式玩家数据。

class FailCopy extends PlayerLevelMigration:
	var fail_name := "b.json"
	## 只替换最终系统提交，前面仍执行真实临时复制、SHA256 回读和检查点写入。
	func _rename_file(source: String, destination: String) -> Error:
		return ERR_FILE_CANT_WRITE if destination.get_file() == fail_name else super._rename_file(source, destination)


class FailCheckpoint extends PlayerLevelMigration:
	## 模拟文件已发布、完成检查点尚未落盘便失败，重启必须复用同一副本。
	func _write_journal(path: String, data: Dictionary) -> DataResult:
		for entry: Dictionary in data.files.values():
			if entry.done:
				return DataResult.failure("测试：文件发布后检查点失败")
		return super._write_journal(path, data)


class FailJournalRename extends PlayerLevelMigration:
	var journal_name := "journal.json"
	## 检查点替换失败必须保留旧记录和旧文件，不把内存中的完成状态当作成功。
	func _rename_file(source: String, destination: String) -> Error:
		return ERR_FILE_CANT_WRITE if destination.get_file() == journal_name else super._rename_file(source, destination)


class ChangeSource extends PlayerLevelMigration:
	var snapshots := 0
	## 在真实复制后、发布前改变旧文件，验证源指纹变化会阻止发布临时副本。
	func _source_snapshot(directory: String, filename: String) -> DataResult:
		snapshots += 1
		if snapshots == 2:
			var file := FileAccess.open(directory.path_join(filename), FileAccess.WRITE)
			file.store_string("changed during copy")
			file.close()
		return super._source_snapshot(directory, filename)


class WindowsJournalGap extends PlayerLevelMigration:
	var failure_revision := 2
	var failure_slot := "journal.json"
	var remove_destination := true
	## 模拟 Windows 覆盖时先删除旧槽再 MoveFile 失败，或保留旧主槽的普通提交失败。
	func _rename_file(source: String, destination: String) -> Error:
		if destination.get_file() == failure_slot:
			var incoming: Variant = JSON.parse_string(FileAccess.get_file_as_string(source))
			if incoming is Dictionary and int(incoming.get("revision", -1)) == failure_revision:
				if remove_destination:
					DirAccess.remove_absolute(destination)
				return ERR_FILE_CANT_WRITE
		return super._rename_file(source, destination)


var _checks := 0
var _failures := 0
var _temporary := ""
var _physical := ""


## 类注册后执行纯存储回归，不创建游戏界面或正式默认目录。
func _initialize() -> void:
	_run.call_deferred()


## 所有目录来自同一独占测试授权根，结束后撤销授权并清理自身文件。
func _run() -> void:
	_temporary = "user://tests/player_level_migration_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_physical = ProjectSettings.globalize_path(_temporary)
	_check(PlayerLevelPaths.register_test_root(_temporary).is_ok(), "注册独占物理保存根")
	_test_raw_bytes()
	_test_conflicts()
	_test_resume()
	_test_checkpoint_gap()
	_test_source_change()
	_test_journal_failure()
	_test_paths_and_links()
	_test_corrupt_journal()
	_test_empty_source()
	_test_manual_migration()
	_test_manual_after_batch()
	_test_windows_recovery()
	_test_recovery_slot_validation()
	_test_readonly_target()
	_test_completed_files()
	_cleanup(_temporary)
	PlayerLevelPaths.unregister_test_root(_physical)
	print("玩家关卡旧目录迁移回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 不可玩草稿、坏 JSON、BOM、空文件及超常规地图上限的大文件都按字节完整保留。
func _test_raw_bytes() -> void:
	var paths := _paths("raw")
	var payloads := {
		"valid.json": "{\"id\":\"unchanged\",\"extra\":{\"future\":42}}\r\n".to_utf8_buffer(),
		"draft.JSON": "{\"id\":\"draft\",\"player_spawn\":null}".to_utf8_buffer(),
		"broken.json": "{invalid JSON\r\n".to_utf8_buffer(),
		"bom.json": PackedByteArray([239, 187, 191]) + "{\"id\":\"bom\"}\n".to_utf8_buffer(),
		"empty.json": PackedByteArray(),
		".hidden.json": PackedByteArray([0, 255, 10, 13]),
		"large.json": "x".repeat(5 * 1024 * 1024 + 17).to_utf8_buffer(),
	}
	for name: String in payloads:
		_write(paths.source.path_join(name), payloads[name])
	_write(paths.source.path_join("notes.txt"), "leave outside migration".to_utf8_buffer())
	_write(paths.source.path_join("nested/inside.json"), "not recursive".to_utf8_buffer())
	var result := PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == payloads.size(), "首次迁移逐个复制全部直接 JSON")
	for name: String in payloads:
		_check(FileAccess.file_exists(paths.source.path_join(name)) and FileAccess.file_exists(paths.target.path_join(name)) and _read(paths.source.path_join(name)) == payloads[name] and _read(paths.target.path_join(name)) == payloads[name], "旧文件及新副本逐字节一致 " + name)
	_check(not FileAccess.file_exists(paths.target.path_join("notes.txt")) and not DirAccess.dir_exists_absolute(paths.target.path_join("nested")), "不迁移非 JSON，不递归子目录")
	var journal: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal))
	_check(journal.complete and journal.source == ProjectSettings.globalize_path(paths.source) and journal.target == paths.target and journal.files.size() == payloads.size(), "完成记录绑定真实目标并保留逐文件检查点")
	for name: String in payloads:
		DirAccess.remove_absolute(paths.target.path_join(name))
	_write(paths.source.path_join("added_later.json"), "new old-directory file".to_utf8_buffer())
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and _json_files(paths.target).is_empty(), "完整迁移后重新启动不会复活删除文件或重新扫描旧目录")
	_check(FileAccess.file_exists(paths.source.path_join("valid.json")), "完成和删除目标后旧件始终保留")


## 同名相同内容跳过；不同内容及后缀继续冲突均保留原件，ID 不因换文件名而改变。
func _test_conflicts() -> void:
	var paths := _paths("conflict")
	var content := "{\"id\":\"same-id\",\"unknown\":1}".to_utf8_buffer()
	_write(paths.source.path_join("equal.json"), content)
	_write(paths.target.path_join("equal.json"), content)
	_write(paths.source.path_join("conflict.json"), content)
	_write(paths.target.path_join("conflict.json"), "existing target".to_utf8_buffer())
	var expected := "conflict_legacy_" + FileAccess.get_sha256(paths.source.path_join("conflict.json")).left(12) + ".json"
	_write(paths.target.path_join(expected), "occupied suffix".to_utf8_buffer())
	var result := PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 1, "同字节跳过，冲突只新增一份")
	var journal: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal))
	var migrated: String = journal.files["conflict.json"].destination
	_check(migrated.begins_with("conflict_legacy_") and migrated != expected and _read(paths.target.path_join(migrated)) == content, "后缀冲突继续分配且内容和 ID 原样保留")
	_check(_read(paths.target.path_join("conflict.json")) == "existing target".to_utf8_buffer() and _read(paths.target.path_join(expected)) == "occupied suffix".to_utf8_buffer(), "任何已有不同字节副本都不覆盖")
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and _json_files(paths.target).size() == 4, "重新实例化再次迁移不会增加重复 legacy 文件")


## 一份已完成、后一份提交失败时，重启续传未完成项；期间删除已完成项也不复活。
func _test_resume() -> void:
	var paths := _paths("resume")
	_write(paths.source.path_join("a.json"), "first".to_utf8_buffer())
	_write(paths.source.path_join("b.json"), "second".to_utf8_buffer())
	var result := FailCopy.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and result.value == null, "中途提交失败显式返回失败而非复制数量")
	var journal: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal))
	_check(not journal.complete and journal.files["a.json"].done and not journal.files["b.json"].done, "失败记录只标已真正落盘的第一项")
	_check(_json_files(paths.target) == PackedStringArray(["a.json"]) and _temporary_files(paths.target).is_empty(), "失败第二项不发布且清理自己的临时文件")
	var pending_bytes := _read(paths.journal)
	DirAccess.remove_absolute(paths.source.path_join("b.json"))
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _read(paths.journal) == pending_bytes, "尚未迁移的旧源缺失时不能提前写入完成记录")
	_write(paths.source.path_join("b.json"), "second".to_utf8_buffer())
	DirAccess.remove_absolute(paths.target.path_join("a.json"))
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 1 and _json_files(paths.target) == PackedStringArray(["b.json"]), "重试仅补第二项，已提交后删除的第一项不复活")
	_check(_read(paths.source.path_join("a.json")) == "first".to_utf8_buffer() and _read(paths.source.path_join("b.json")) == "second".to_utf8_buffer(), "失败与重试期间旧源均保持原字节")


## 文件发布与检查点之间的故障通过预先记录的目标名恢复，不再次生成冲突后缀。
func _test_checkpoint_gap() -> void:
	var paths := _paths("checkpoint")
	_write(paths.source.path_join("a.json"), "legacy bytes".to_utf8_buffer())
	_write(paths.target.path_join("a.json"), "current bytes".to_utf8_buffer())
	var result := FailCheckpoint.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _json_files(paths.target).size() == 2, "已复制但检查点失败仍明确失败")
	var before := _json_files(paths.target)
	var pending: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal))
	_check(not pending.complete and not pending.files["a.json"].done, "检查点失败不提前标记单项或总完成")
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and _json_files(paths.target) == before, "重启按已有计划识别同字节副本，不重复复制")


## 来源在复制中改变时不发布；恢复原字节后可以沿同一计划继续。
func _test_source_change() -> void:
	var paths := _paths("changed")
	_write(paths.source.path_join("a.json"), "original".to_utf8_buffer())
	var result := ChangeSource.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _json_files(paths.target).is_empty() and _temporary_files(paths.target).is_empty(), "源指纹变化阻止发布并清理临时文件")
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok(), "未恢复来源时不拿新内容冒充原迁移计划")
	_write(paths.source.path_join("a.json"), "original".to_utf8_buffer())
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 1 and _read(paths.target.path_join("a.json")) == "original".to_utf8_buffer(), "恢复原文件后可安全继续")


## 记录的原子提交失败不能覆盖旧记录；计划还未可靠落盘时不提前复制地图。
func _test_journal_failure() -> void:
	var paths := _paths("journal_failure")
	_write(paths.source.path_join("b.json"), "source".to_utf8_buffer())
	var result := FailCopy.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok(), "建立真实未完成检查点")
	var old_bytes := _read(paths.journal)
	result = FailJournalRename.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _read(paths.journal) == old_bytes and _json_files(paths.target).is_empty(), "检查点改名失败保留完整旧记录且不复制地图")
	_check(_temporary_files(paths.journal.get_base_dir()).is_empty(), "检查点提交失败清理临时文件")
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 1, "记录写入恢复后正常续传")


## 所有攻击路径均位于测试树；链接指向测试哨兵，拒绝后核对哨兵未被改写。
func _test_paths_and_links() -> void:
	var paths := _paths("paths")
	_write(paths.source.path_join("a.json"), "source".to_utf8_buffer())
	var migration := PlayerLevelMigration.new()
	_check(not migration.prepare(paths.source + "/../legacy", paths.target, paths.journal).is_ok(), "拒绝来源上级跳转")
	_check(not migration.prepare(paths.source, paths.target + "/../target", paths.journal).is_ok(), "拒绝目标上级跳转")
	_check(not migration.prepare(paths.source, paths.target, paths.journal.get_base_dir() + "/../journal.json").is_ok(), "拒绝记录上级跳转")
	_check(not migration.prepare("res://data/maps", paths.target, paths.journal).is_ok(), "内置资源不能成为旧玩家数据迁移源")
	_check(not migration.prepare(paths.source, paths.target, paths.source.path_join("migration.json")).is_ok(), "记录不能放入来源关卡目录")
	var sentinel := _physical.path_join("paths/sentinel.txt")
	_write(sentinel, "sentinel".to_utf8_buffer())
	var folder := DirAccess.open("user://")
	var link: String = paths.source.path_join("link.json")
	var linked := folder.create_link(sentinel, ProjectSettings.globalize_path(link))
	if linked == OK:
		_check(not migration.prepare(paths.source, paths.target, paths.journal).is_ok(), "拒绝旧 JSON 符号链接")
		DirAccess.remove_absolute(link)
		link = paths.target.path_join("a.json")
		DirAccess.make_dir_recursive_absolute(paths.target)
		_check(folder.create_link(sentinel, link) == OK and not migration.prepare(paths.source, paths.target, paths.journal).is_ok(), "拒绝目标 JSON 符号链接")
		DirAccess.remove_absolute(link)
		_check(folder.create_link(sentinel, ProjectSettings.globalize_path(paths.journal)) == OK and not migration.prepare(paths.source, paths.target, paths.journal).is_ok(), "拒绝记录文件符号链接")
		DirAccess.remove_absolute(paths.journal)
		var linked_source := _temporary.path_join("paths/linked_source")
		_check(folder.create_link(ProjectSettings.globalize_path(paths.source), ProjectSettings.globalize_path(linked_source)) == OK and not migration.prepare(linked_source, paths.target, paths.journal).is_ok(), "拒绝来源目录符号链接")
		DirAccess.remove_absolute(linked_source)
		var linked_target := _physical.path_join("paths/linked_target")
		_check(folder.create_link(paths.target, linked_target) == OK and not migration.prepare(paths.source, linked_target, paths.journal).is_ok(), "拒绝目标目录符号链接")
		DirAccess.remove_absolute(linked_target)
	else:
		print("当前平台未允许创建测试符号链接：", error_string(linked))
	DirAccess.make_dir_recursive_absolute(paths.source.path_join("directory.json"))
	_check(not migration.prepare(paths.source, paths.target, paths.journal).is_ok(), "JSON 同名目录不是可迁移关卡")
	_check(_read(sentinel) == "sentinel".to_utf8_buffer() and _read(paths.source.path_join("a.json")) == "source".to_utf8_buffer(), "全部拒绝路径均未改写哨兵或旧源")


## 损坏记录或路径注入不重置历史，修复须由外层明确处理，不能静默复活全部旧关卡。
func _test_corrupt_journal() -> void:
	var paths := _paths("corrupt")
	_write(paths.source.path_join("a.json"), "source".to_utf8_buffer())
	_write(paths.journal, "{broken".to_utf8_buffer())
	var result := PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _read(paths.journal) == "{broken".to_utf8_buffer() and _json_files(paths.target).is_empty(), "损坏记录原样保留且不当作新迁移")
	var data := {"version": 1, "source": ProjectSettings.globalize_path(paths.source), "target": paths.target, "complete": false, "files": {"a.json": {"sha256": "0".repeat(64), "destination": "../outside.json", "done": false}}}
	_write(paths.journal, JSON.stringify(data).to_utf8_buffer())
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and _json_files(paths.target).is_empty(), "记录内的目标跳转不能越过授权目录")
	data.files.clear()
	data.complete = true
	data.target += "_other"
	_write(paths.journal, JSON.stringify(data).to_utf8_buffer())
	_check(not PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal).is_ok(), "完成记录绑定不同目标时拒绝误用")


## 没有旧目录也记录完成；以后出现的同名旧目录不是再次导入的理由。
func _test_empty_source() -> void:
	var paths := _paths("empty")
	var result := PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and not DirAccess.dir_exists_absolute(paths.source), "无旧来源成功完成且不创建旧目录")
	_write(paths.source.path_join("later.json"), "later".to_utf8_buffer())
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and _json_files(paths.target).is_empty(), "首次空来源完成后也不重复扫描")


## 列表读取不写盘；每次操作只迁移点选源，坏 JSON 同样保留，已完成源不因目标删除而复活。
func _test_manual_migration() -> void:
	var paths := _paths("manual")
	_write(paths.source.path_join("a.json"), "{\"id\":\"unchanged\",\"future\":99}".to_utf8_buffer())
	_write(paths.source.path_join("b.json"), "{broken".to_utf8_buffer())
	var migration := PlayerLevelMigration.new()
	var pending := migration.pending_files(paths.source, paths.target, paths.journal)
	_check(pending.is_ok() and pending.value == PackedStringArray(["a.json", "b.json"]), "只读列表包含旧正常地图与坏 JSON")
	_check(not DirAccess.dir_exists_absolute(paths.target) and not FileAccess.file_exists(paths.journal) and not FileAccess.file_exists(paths.journal + ".recovery"), "启动枚举不创建新目录、主记录或恢复槽")
	pending = migration.pending_files(paths.source, "", paths.journal)
	_check(pending.is_ok() and pending.value.size() == 2 and not DirAccess.dir_exists_absolute(paths.target), "未授权新目录时仍可只读列出旧文件")
	var fingerprint := FileAccess.get_sha256(paths.source.path_join("a.json"))
	var result := migration.migrate_file(paths.source, paths.target, paths.journal, "a.json", fingerprint)
	_check(result.is_ok() and result.value == paths.target.path_join("a.json") and _json_files(paths.target) == PackedStringArray(["a.json"]), "点击一条只迁移对应文件并返回真实目标")
	_check(_read(paths.target.path_join("a.json")) == _read(paths.source.path_join("a.json")), "单条迁移完整保留原字节和未知字段")
	var before := _read(paths.journal)
	pending = migration.pending_files(paths.source, "", paths.journal)
	_check(pending.is_ok() and pending.value == PackedStringArray(["b.json"]) and _read(paths.journal) == before, "已有记录时空目标枚举过滤 done 且仍不写记录")
	result = migration.migrate_file(paths.source, paths.target, paths.journal, "a.json", fingerprint)
	_check(result.is_ok() and _read(paths.journal) == before and _json_files(paths.target).size() == 1, "重复点击已完成项不增加副本或改写记录")
	DirAccess.remove_absolute(paths.target.path_join("a.json"))
	result = migration.migrate_file(paths.source, paths.target, paths.journal, "a.json", fingerprint)
	pending = migration.pending_files(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and not FileAccess.file_exists(paths.target.path_join("a.json")) and pending.value == PackedStringArray(["b.json"]), "新目录删除后重复点击不复活且旧备份不再出现在列表")
	result = migration.migrate_file(paths.source, paths.target, paths.journal, "b.json", "0".repeat(64))
	_check(not result.is_ok() and _read(paths.journal) == before, "列表快照摘要失配时不复制、不改写检查点")
	_check(not migration.migrate_file(paths.source, paths.target, paths.journal, "../b.json", fingerprint).is_ok(), "单条入口拒绝路径跳转")
	result = migration.migrate_file(paths.source, paths.target, paths.journal, "b.json", FileAccess.get_sha256(paths.source.path_join("b.json")))
	_check(result.is_ok() and _read(paths.target.path_join("b.json")) == "{broken".to_utf8_buffer(), "坏 JSON 按字节单条迁移而非解析丢弃")
	_write(paths.source.path_join("c.json"), "old C".to_utf8_buffer())
	_write(paths.target.path_join("c.json"), "new C".to_utf8_buffer())
	pending = migration.pending_files(paths.source, paths.target, paths.journal)
	_check(pending.is_ok() and pending.value == PackedStringArray(["c.json"]), "后来新增的旧目录文件仍可单独迁移")
	result = migration.migrate_file(paths.source, paths.target, paths.journal, "c.json", FileAccess.get_sha256(paths.source.path_join("c.json")))
	_check(result.is_ok() and str(result.value).get_file().begins_with("c_legacy_") and _read(result.value) == "old C".to_utf8_buffer() and _read(paths.target.path_join("c.json")) == "new C".to_utf8_buffer(), "单条迁移同名冲突保留新目录原件并生成稳定后缀")
	_check(migration.pending_files(paths.source, paths.target, paths.journal).value.is_empty() and FileAccess.file_exists(paths.source.path_join("a.json")), "全部单条完成后隐藏旧备份但保留旧文件")


## 旧批量完成标记仅阻止旧批量重复执行，不阻止玩家主动迁移以后出现的新源文件。
func _test_manual_after_batch() -> void:
	var paths := _paths("manual_after_batch")
	_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
	_check(PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal).is_ok(), "建立旧批量完成记录")
	_write(paths.source.path_join("b.json"), "B".to_utf8_buffer())
	var migration := PlayerLevelMigration.new()
	var pending := migration.pending_files(paths.source, paths.target, paths.journal)
	_check(pending.is_ok() and pending.value == PackedStringArray(["b.json"]), "批量完成后新源仍出现在手动迁移列表")
	var result := migration.migrate_file(paths.source, paths.target, paths.journal, "b.json", FileAccess.get_sha256(paths.source.path_join("b.json")))
	_check(result.is_ok() and _read(paths.target.path_join("b.json")) == "B".to_utf8_buffer(), "完成旧批量后仍可手动提交新文件")
	_check(migration.pending_files(paths.source, "", paths.journal).is_ok() and migration.pending_files(paths.source, "", paths.journal).value.is_empty(), "旧 complete 与新手动检查点共同可读")


## 覆盖失败后的最新恢复槽必须保留 done；再次覆盖恢复槽失败前先补主，不能丢最新检查点。
func _test_windows_recovery() -> void:
	for remove_main: bool in [true, false]:
		var paths := _paths("windows_" + str(remove_main))
		_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
		var failure := WindowsJournalGap.new()
		failure.remove_destination = remove_main
		var result := failure.prepare(paths.source, paths.target, paths.journal)
		_check(not result.is_ok() and FileAccess.file_exists(paths.target.path_join("a.json")), "主槽提交失败仍保留已发布地图 " + str(remove_main))
		var recovery: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal + ".recovery"))
		_check(recovery.files["a.json"].done and int(recovery.revision) == 2, "恢复槽保留比主槽更新的 done " + str(remove_main))
		DirAccess.remove_absolute(paths.target.path_join("a.json"))
		failure = WindowsJournalGap.new()
		failure.failure_slot = "journal.json.recovery"
		failure.failure_revision = 3
		result = failure.prepare(paths.source, paths.target, paths.journal)
		var primary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths.journal))
		_check(not result.is_ok() and primary.files["a.json"].done and int(primary.revision) == 2, "覆盖恢复槽前主槽必须已补齐最新 done " + str(remove_main))
		result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
		_check(result.is_ok() and result.value == 0 and not FileAccess.file_exists(paths.target.path_join("a.json")), "两次不同槽覆盖中断后仍不复活已完成关卡 " + str(remove_main))
		_check(_read(paths.journal) == _read(paths.journal + ".recovery"), "恢复成功后两槽为同一完整检查点 " + str(remove_main))
	var paths := _paths("windows_complete")
	_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
	var failure := WindowsJournalGap.new()
	failure.failure_revision = 3
	var result := failure.prepare(paths.source, paths.target, paths.journal)
	_check(not result.is_ok() and not FileAccess.file_exists(paths.journal), "总完成标记主槽删除后提交失败不能误报成功")
	DirAccess.remove_absolute(paths.target.path_join("a.json"))
	_write(paths.source.path_join("later.json"), "later".to_utf8_buffer())
	var before := _read(paths.journal + ".recovery")
	result = PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and result.value == 0 and _json_files(paths.target).is_empty() and _read(paths.journal + ".recovery") == before, "仅恢复槽的 complete 阻止旧批量重新导入")
	var pending := PlayerLevelMigration.new().pending_files(paths.source, "", paths.journal)
	_check(pending.is_ok() and pending.value == PackedStringArray(["later.json"]), "仅恢复槽也能只读过滤已迁移项并展示后来新源")


## 双槽同序号必须字节相同，绑定与完成进度不能互相矛盾；畸形恢复槽保留原件并报错。
func _test_recovery_slot_validation() -> void:
	var paths := _paths("slot_validation")
	_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
	PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal)
	var original := _read(paths.journal)
	var data: Dictionary = JSON.parse_string(original.get_string_from_utf8())
	var changes: Array[Dictionary] = []
	var changed: Dictionary = data.duplicate(true)
	changed.target += "_different"
	changes.append(changed)
	changed = data.duplicate(true)
	changed["extra"] = "same revision but different bytes"
	changes.append(changed)
	changed = data.duplicate(true)
	changed.revision += 1
	changed.complete = false
	changes.append(changed)
	changed = data.duplicate(true)
	changed.revision += 1
	changed.files["a.json"].destination = "changed.json"
	changes.append(changed)
	changed = data.duplicate(true)
	changed.revision = true
	changes.append(changed)
	changed = data.duplicate(true)
	changed.revision = -1
	changes.append(changed)
	changed = data.duplicate(true)
	changed.revision = 1.5
	changes.append(changed)
	for index in changes.size():
		var bytes := JSON.stringify(changes[index]).to_utf8_buffer()
		_write(paths.journal + ".recovery", bytes)
		var result := PlayerLevelMigration.new().pending_files(paths.source, "", paths.journal)
		_check(not result.is_ok() and _read(paths.journal) == original and _read(paths.journal + ".recovery") == bytes, "冲突绑定、完成回退及无效序号不覆盖原记录 " + str(index))
	_write(paths.journal + ".recovery", "{broken".to_utf8_buffer())
	_check(not PlayerLevelMigration.new().prepare(paths.source, paths.target, paths.journal).is_ok() and _read(paths.journal + ".recovery") == "{broken".to_utf8_buffer(), "存在但损坏的恢复槽不能作为缺失覆盖")
	DirAccess.remove_absolute(paths.journal + ".recovery")
	var legacy: Dictionary = data.duplicate(true)
	legacy.erase("revision")
	_write(paths.journal, JSON.stringify(legacy).to_utf8_buffer())
	_check(PlayerLevelMigration.new().pending_files(paths.source, "", paths.journal).is_ok(), "旧无序列号的主记录按 revision 0 兼容读取")
	var sentinel := _physical.path_join("slot_validation/sentinel.txt")
	_write(sentinel, "sentinel".to_utf8_buffer())
	var folder := DirAccess.open("user://")
	if folder.create_link(sentinel, ProjectSettings.globalize_path(paths.journal + ".recovery")) == OK:
		_check(not PlayerLevelMigration.new().pending_files(paths.source, "", paths.journal).is_ok() and _read(sentinel) == "sentinel".to_utf8_buffer(), "恢复槽符号链接必须拒绝且不改哨兵")


## 新目录选择核对在授权配置写入前完成；主槽缺失时仍须读取恢复绑定并明确提示原目录。
func _test_readonly_target() -> void:
	var paths := _paths("readonly_target")
	var migration := PlayerLevelMigration.new()
	var result := migration.check_target(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and not DirAccess.dir_exists_absolute(paths.source) and not DirAccess.dir_exists_absolute(paths.target) and not FileAccess.file_exists(paths.journal), "首次只读目录核对不创建来源、目标或记录")
	_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
	migration.migrate_file(paths.source, paths.target, paths.journal, "a.json", FileAccess.get_sha256(paths.source.path_join("a.json")))
	DirAccess.remove_absolute(paths.journal)
	var recovery := _read(paths.journal + ".recovery")
	var alternative: String = paths.target + "_other"
	result = migration.check_target(paths.source, alternative, paths.journal)
	_check(not result.is_ok() and "".join(result.errors).contains(paths.target), "只有恢复槽时错误目标也明确提示原保存路径")
	_check(not DirAccess.dir_exists_absolute(alternative) and not FileAccess.file_exists(paths.journal) and _read(paths.journal + ".recovery") == recovery, "失败核对不恢复主槽、不创建新目标、不改绑定")
	result = migration.check_target(paths.source, paths.target, paths.journal)
	_check(result.is_ok() and not FileAccess.file_exists(paths.journal), "选择原绑定目录后只读核对成功")


## 生命周期快照仅返回已提交源摘要，并在目标被玩家修改、删除或尚未授权时仍保留迁移事实。
func _test_completed_files() -> void:
	var paths := _paths("completed")
	var migration := PlayerLevelMigration.new()
	var result := migration.completed_files(paths.source, "", paths.journal)
	_check(result.is_ok() and result.value.is_empty() and not DirAccess.dir_exists_absolute(paths.source) and not DirAccess.dir_exists_absolute(paths.target), "无记录的完成快照为空且不创建任何目录")
	_write(paths.source.path_join("a.json"), "A".to_utf8_buffer())
	_write(paths.source.path_join("b.json"), "B".to_utf8_buffer())
	var fingerprint := FileAccess.get_sha256(paths.source.path_join("a.json"))
	migration.migrate_file(paths.source, paths.target, paths.journal, "a.json", fingerprint)
	var failure := FailCopy.new()
	failure.migrate_file(paths.source, paths.target, paths.journal, "b.json", FileAccess.get_sha256(paths.source.path_join("b.json")))
	DirAccess.remove_absolute(paths.journal)
	DirAccess.remove_absolute(paths.target.path_join("a.json"))
	var before := _read(paths.journal + ".recovery")
	result = migration.completed_files(paths.source, "", paths.journal)
	_check(result.is_ok() and result.value.size() == 1 and result.value.has("a.json") and not result.value.has("b.json"), "只从恢复槽返回已完成源，未完成计划不作为可清理源")
	_check(result.value["a.json"] == {"sha256": fingerprint, "destination": "a.json", "target_directory": paths.target}, "完成快照包含原始 SHA、目标文件名与原绑定目录")
	_check(not FileAccess.file_exists(paths.journal) and not FileAccess.file_exists(paths.target.path_join("a.json")) and _read(paths.journal + ".recovery") == before, "新副本已删除时查询不复活关卡或写回主记录")
	result.value["a.json"].sha256 = "0".repeat(64)
	var reloaded := migration.completed_files(paths.source, "", paths.journal)
	_check(reloaded.is_ok() and reloaded.value["a.json"].sha256 == fingerprint, "调用方修改返回快照不会改变持久检查点")
	_write(paths.target.path_join("a.json"), "player edited version".to_utf8_buffer())
	_check(migration.completed_files(paths.source, "", paths.journal).value["a.json"].sha256 == fingerprint, "玩家修改新副本不改变当时已验证的源指纹")
	_check(not migration.completed_files(paths.source, paths.target + "_other", paths.journal).is_ok(), "显式目标不匹配时完成快照仍拒绝绑定混用")


## 每个案例使用分离的来源、目标和检查点，目标以已注册物理目录传入。
func _paths(name: String) -> Dictionary:
	return {"source": _temporary.path_join(name + "/legacy"), "target": _physical.path_join(name + "/target"), "journal": _temporary.path_join(name + "/journal.json")}


## 夹具写入仅发生在当前进程专属测试树。
func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


## 文件内容按字节读取，断言不会掩盖 BOM、换行或坏编码差异。
func _read(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


## 只列直接 JSON，便于判断断点恢复是否创建多余副本。
func _json_files(directory: String) -> PackedStringArray:
	var result := PackedStringArray()
	for name in DirAccess.get_files_at(directory):
		if name.get_extension().to_lower() == "json":
			result.append(name)
	result.sort()
	return result


## 本模块专属临时后缀不能在正常失败后遗留成可见关卡。
func _temporary_files(directory: String) -> PackedStringArray:
	var result := PackedStringArray()
	var folder := DirAccess.open(directory)
	if folder != null:
		folder.include_hidden = true
		for name in folder.get_files():
			if name.ends_with(".migration-tmp"):
				result.append(name)
	return result


## 清理只处理测试树；符号链接只删除链接本身，不递归其指向的目录。
func _cleanup(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for name in folder.get_files():
		folder.remove(name)
	for name in folder.get_directories():
		if folder.is_link(name):
			folder.remove(name)
		else:
			_cleanup(path.path_join(name))
	DirAccess.remove_absolute(path)


## 汇总全部存储断言，失败用非零退出通知总回归。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
