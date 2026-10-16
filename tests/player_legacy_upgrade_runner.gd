extends SceneTree
## 首次提示、明确放弃、迁移后退役和删除失败重试均在独占旧目录内验证。

class FaultUpgrade extends PlayerLegacyUpgrade:
	var fail_remove := ""
	var fail_marker := ""
	var rename_calls := 0
	var mutate_after_remove := ""
	var replacement := ""

	## 模拟单文件删除失败或删除间隔的外部变更，实际删除仍只发生在隔离源目录。
	func _remove_source_path(path: String) -> Error:
		if path.get_file() == fail_remove:
			return ERR_FILE_CANT_WRITE
		var result := DirAccess.remove_absolute(path)
		if result == OK and not mutate_after_remove.is_empty():
			var file := FileAccess.open(mutate_after_remove, FileAccess.WRITE)
			if file != null:
				file.store_string(replacement)
				file.close()
			mutate_after_remove = ""
		return result

	## 模拟 Windows 目标已存在时不能覆盖，并可让指定阶段的标记提交失败。
	func _rename_marker(source: String, destination: String) -> Error:
		rename_calls += 1
		if destination.get_file() == fail_marker:
			return ERR_FILE_CANT_WRITE
		if FileAccess.file_exists(destination):
			return ERR_ALREADY_EXISTS
		return DirAccess.rename_absolute(source, destination)

var _checks := 0
var _failures := 0
var _root := ""


## 延后开始，以新注册的外部测试根代替真实 Documents。
func _initialize() -> void:
	_run.call_deferred()


## 每种生命周期独立配置路径，所有正常和失败分支最终清理各自测试文件。
func _run() -> void:
	_root = "user://tests/player_legacy_upgrade_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_ok(PlayerLevelPaths.register_test_root(_root), "注册独占测试根")
	_test_notice_once()
	_test_empty_and_retired()
	_test_discard_boundaries()
	_test_migrated_retirement()
	_test_failures_and_retry()
	_test_changed_snapshot()
	_test_invalid_paths_and_links()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("旧玩家关卡升级生命周期回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 首次只提示一次；暂不处理或重启都保留旧文件，不创建新目录也不执行迁移。
func _test_notice_once() -> void:
	var upgrade := _upgrade("notice")
	_write(upgrade.source_directory.path_join("a.json"), "{broken")
	_write(upgrade.source_directory.path_join("b.json"), "")
	var initial := upgrade.inspect()
	_check(initial.is_ok() and initial.value.needs_notice and not initial.value.retired and initial.value.pending_count == 2, "首次发现旧图时只提供提示状态")
	_check(not DirAccess.dir_exists_absolute(upgrade.target_directory) and not FileAccess.file_exists(upgrade.journal_path), "检查不创建目标或迁移记录")
	_ok(upgrade.mark_prompted(), "首次提示持久化")
	var marker := FileAccess.get_file_as_bytes(upgrade.state_directory.path_join("prompted.json"))
	var rename_count := upgrade.rename_calls
	_ok(upgrade.mark_prompted(), "重复提示标记是幂等操作")
	_check(upgrade.rename_calls == rename_count and FileAccess.get_file_as_bytes(upgrade.state_directory.path_join("prompted.json")) == marker, "已存在标记不依赖 Windows 覆盖改名")
	var restarted := _upgrade("notice")
	var result := restarted.inspect()
	_check(result.is_ok() and not result.value.needs_notice and not result.value.retired and result.value.pending_count == 2, "重启不再提示但仍保留待迁移状态")
	_check(FileAccess.get_file_as_string(upgrade.source_directory.path_join("a.json")) == "{broken" and FileAccess.file_exists(upgrade.source_directory.path_join("b.json")), "标记提示本身不删除旧地图")


## 空旧目录无需打扰；退役后后来重新出现的文件也不被扫描或删除。
func _test_empty_and_retired() -> void:
	var upgrade := _upgrade("empty")
	DirAccess.make_dir_recursive_absolute(upgrade.source_directory)
	var result := upgrade.inspect()
	_check(result.is_ok() and result.value.retired and not result.value.needs_notice and result.value.pending_count == 0, "空目录直接退役且不提示")
	_check(not DirAccess.dir_exists_absolute(upgrade.source_directory), "只移除空旧目录自身")
	_check(not FileAccess.file_exists(upgrade.state_directory.path_join("prompted.json")), "空目录无需建立提示标记")
	_write(upgrade.source_directory.path_join("later.json"), "later")
	result = _upgrade("empty").inspect()
	_check(result.is_ok() and result.value.retired and result.value.pending_count == 0, "退役标记使重启不再扫描旧目录")
	_ok(upgrade.discard(), "已退役时再次调用放弃不操作旧目录")
	_check(FileAccess.get_file_as_string(upgrade.source_directory.path_join("later.json")) == "later", "退役后新出现旧路径文件保持不变")


## 明确放弃只清理直接 JSON；设置、记录、新目录、非 JSON 和嵌套文件全部保留。
func _test_discard_boundaries() -> void:
	var upgrade := _upgrade("discard")
	_write(upgrade.source_directory.path_join("a.json"), "bad")
	_write(upgrade.source_directory.path_join(".hidden.JSON"), "")
	_write(upgrade.source_directory.path_join("notes.txt"), "notes")
	_write(upgrade.source_directory.path_join("nested/keep.json"), "nested")
	_write(_root.path_join("discard/settings.json"), "settings")
	_write(_root.path_join("discard/solutions/game.json"), "code")
	_write(_root.path_join("discard/profile.json"), "stats")
	_write(upgrade.target_directory.path_join("new.json"), "new map")
	_ok(upgrade.discard(), "明确放弃允许删除坏文件和空 JSON")
	_check(not FileAccess.file_exists(upgrade.source_directory.path_join("a.json")) and not FileAccess.file_exists(upgrade.source_directory.path_join(".hidden.JSON")), "所有直接 JSON 已删除")
	_check(FileAccess.get_file_as_string(upgrade.source_directory.path_join("notes.txt")) == "notes" and FileAccess.get_file_as_string(upgrade.source_directory.path_join("nested/keep.json")) == "nested", "不递归删除非地图资源或子目录")
	_check(FileAccess.get_file_as_string(_root.path_join("discard/settings.json")) == "settings" and FileAccess.get_file_as_string(_root.path_join("discard/solutions/game.json")) == "code" and FileAccess.get_file_as_string(_root.path_join("discard/profile.json")) == "stats", "父级设置统计和代码草稿不受影响")
	_check(FileAccess.get_file_as_string(upgrade.target_directory.path_join("new.json")) == "new map", "新目录永不参与旧目录删除")
	var result := upgrade.inspect()
	_check(result.is_ok() and result.value.retired, "非 JSON 原件保留后仍永久停用旧地图目录")


## 仅全部迁移完成且旧源字节与完成记录一致才自动清理，目标后续修改删除不会复活旧备份。
func _test_migrated_retirement() -> void:
	var upgrade := _upgrade("migrated")
	_write(upgrade.source_directory.path_join("a.json"), "a source")
	_write(upgrade.source_directory.path_join("b.json"), "b source")
	var first := _migrate(upgrade, "a.json")
	_ok(first, "迁移第一张旧图")
	var pending := upgrade.retire_if_migrated()
	_check(pending.is_ok() and not pending.value and FileAccess.file_exists(upgrade.source_directory.path_join("a.json")), "还有未迁移旧图时不清理任何备份")
	var second := _migrate(upgrade, "b.json")
	_ok(second, "迁移第二张旧图")
	_write(str(first.value), "player edited new map")
	_check(DirAccess.remove_absolute(str(second.value)) == OK, "模拟玩家删除已迁移的新副本")
	upgrade.target_directory = ""
	var finished := upgrade.retire_if_migrated()
	_check(finished.is_ok() and finished.value and not DirAccess.dir_exists_absolute(upgrade.source_directory), "无需访问当前目标也可按完成记录清理原字节备份")
	_check(FileAccess.get_file_as_string(str(first.value)) == "player edited new map" and not FileAccess.file_exists(str(second.value)), "清理旧备份不会覆盖修改或复活目标")
	var changed := _upgrade("changed_done")
	_write(changed.source_directory.path_join("a.json"), "original")
	_ok(_migrate(changed, "a.json"), "准备已完成迁移记录")
	_write(changed.source_directory.path_join("a.json"), "changed source")
	_error(changed.retire_if_migrated(), "已完成后旧源内容变化拒绝自动删除")
	_check(FileAccess.get_file_as_string(changed.source_directory.path_join("a.json")) == "changed source" and not FileAccess.file_exists(changed.state_directory.path_join("retired.json")), "变化旧源保留且不误标记退役")
	_ok(changed.discard(), "用户仍可明确放弃变更后的旧图")


## 提交或删除故障不冒充退役，固定清理快照可跨实例重试，未成功提交清理意图时不删除。
func _test_failures_and_retry() -> void:
	var upgrade := _upgrade("partial")
	_write(upgrade.source_directory.path_join("a.json"), "a")
	_write(upgrade.source_directory.path_join("b.json"), "b")
	upgrade.fail_remove = "b.json"
	_error(upgrade.discard(), "第二个文件删除失败明确报告")
	_check(not FileAccess.file_exists(upgrade.source_directory.path_join("a.json")) and FileAccess.file_exists(upgrade.source_directory.path_join("b.json")), "部分完成时剩余原件保留")
	_check(not FileAccess.file_exists(upgrade.state_directory.path_join("retired.json")), "部分删除失败不写退役标记")
	var restarted := _upgrade("partial")
	var resumed := restarted.inspect()
	_check(resumed.is_ok() and resumed.value.retired and not resumed.value.needs_notice, "重启自动依据已授权快照完成剩余删除，不重复询问")
	_check(not DirAccess.dir_exists_absolute(restarted.source_directory), "自动续清理完成才正式退役")
	var migrated := _upgrade("partial_migrated")
	_write(migrated.source_directory.path_join("a.json"), "a")
	_write(migrated.source_directory.path_join("b.json"), "b")
	_ok(_migrate(migrated, "a.json"), "准备首张已迁移旧备份")
	_ok(_migrate(migrated, "b.json"), "准备另一张已迁移旧备份")
	migrated.fail_remove = "b.json"
	_error(migrated.retire_if_migrated(), "全部迁移后的备份清理中断明确失败")
	var migrated_resumed := _upgrade("partial_migrated").inspect()
	_check(migrated_resumed.is_ok() and migrated_resumed.value.retired and not migrated_resumed.value.needs_notice, "重启同样恢复已经授权的迁移完成清理")
	_check(FileAccess.get_file_as_string(migrated.target_directory.path_join("a.json")) == "a" and FileAccess.get_file_as_string(migrated.target_directory.path_join("b.json")) == "b", "自动续清理不触碰新目录地图")
	var blocked := _upgrade("blocked_intent")
	_write(blocked.source_directory.path_join("a.json"), "a")
	blocked.fail_marker = "cleanup.json"
	_error(blocked.discard(), "无法提交清理意图时拒绝删除")
	_check(FileAccess.get_file_as_string(blocked.source_directory.path_join("a.json")) == "a", "清理意图提交失败保留全部源文件")
	var late := _upgrade("late_marker")
	_write(late.source_directory.path_join("a.json"), "a")
	late.fail_marker = "retired.json"
	_error(late.discard(), "文件清理后退役标记提交失败仍返回错误")
	_check(not FileAccess.file_exists(late.state_directory.path_join("retired.json")), "标记失败不能报告已退役")
	late.fail_marker = ""
	var recovered := late.inspect()
	_check(recovered.is_ok() and recovered.value.retired and not recovered.value.needs_notice, "清理中断后空旧目录可安全补交退役标记")


## 删除过程中的源变化被实时阻止，重试不把变更字节纳入首次授权快照。
func _test_changed_snapshot() -> void:
	var upgrade := _upgrade("mutated")
	_write(upgrade.source_directory.path_join("a.json"), "a")
	_write(upgrade.source_directory.path_join("b.json"), "b")
	upgrade.mutate_after_remove = upgrade.source_directory.path_join("b.json")
	upgrade.replacement = "changed"
	_error(upgrade.discard(), "删除第一张后其他旧图变化会中止清理")
	_check(FileAccess.get_file_as_string(upgrade.source_directory.path_join("b.json")) == "changed", "变更旧图不会被继续删除")
	_error(_upgrade("mutated").inspect(), "跨实例启动续清理仍拒绝变更后的旧图")
	_write(upgrade.source_directory.path_join("b.json"), "b")
	_write(upgrade.source_directory.path_join("new.json"), "new")
	_error(_upgrade("mutated").inspect(), "重启续清理不把后来新增文件纳入旧授权")
	_check(FileAccess.get_file_as_string(upgrade.source_directory.path_join("b.json")) == "b" and FileAccess.get_file_as_string(upgrade.source_directory.path_join("new.json")) == "new", "发现新增文件时保留全部剩余原件")
	_check(DirAccess.remove_absolute(upgrade.source_directory.path_join("new.json")) == OK, "测试移除后来新增文件以恢复原快照")
	var completed := _upgrade("mutated").inspect()
	_check(completed.is_ok() and completed.value.retired and not completed.value.needs_notice, "恢复原授权文件集后启动可自动完成清理")


## 任意来源、设置目录、链接以及损坏状态文件都不能获得删除旧图的授权。
func _test_invalid_paths_and_links() -> void:
	for source: String in ["user://solutions", "res://data/levels", "/tmp", _root.path_join("settings")]:
		var invalid := _upgrade("invalid")
		invalid.source_directory = source
		_error(invalid.discard(), "拒绝危险旧来源 " + source)
	var state := _upgrade("bad_state")
	_write(state.source_directory.path_join("a.json"), "a")
	_write(state.state_directory.path_join("retired.json"), "broken")
	_error(state.inspect(), "损坏退役标记不被当作有效完成")
	_error(state.discard(), "损坏退役标记保护旧图")
	_check(FileAccess.get_file_as_string(state.source_directory.path_join("a.json")) == "a", "状态文件损坏时源文件保持不变")
	var overlap := _upgrade("overlap")
	_write(overlap.source_directory.path_join("a.json"), "a")
	overlap.target_directory = ProjectSettings.globalize_path(overlap.source_directory)
	_error(overlap.discard(), "新旧目录重叠时禁止删除")
	var linked := _upgrade("links")
	_write(linked.source_directory.path_join("a.json"), "a")
	var protected_path := _root.path_join("links/protected.json")
	_write(protected_path, "protected")
	var folder := DirAccess.open(linked.source_directory)
	if folder.create_link(ProjectSettings.globalize_path(protected_path), "b.json") == OK:
		_error(linked.discard(), "文件符号链接使清理整体拒绝")
		_check(FileAccess.get_file_as_string(linked.source_directory.path_join("a.json")) == "a" and FileAccess.get_file_as_string(protected_path) == "protected", "链接检查先于任何源文件删除")
		folder.remove("b.json")
		DirAccess.make_dir_recursive_absolute(linked.state_directory)
		var state_folder := DirAccess.open(linked.state_directory)
		if state_folder.create_link(ProjectSettings.globalize_path(protected_path), "prompted.json") == OK:
			_error(linked.mark_prompted(), "提示标记链接不被覆盖")
			_check(FileAccess.get_file_as_string(protected_path) == "protected", "标记链接目标仍保持原件")


## 每个案例使用独立源、新根、迁移日志和状态目录，正式默认路径绝不进入测试。
func _upgrade(case_name: String) -> FaultUpgrade:
	var upgrade := FaultUpgrade.new()
	var directory := _root.path_join(case_name)
	upgrade.source_directory = directory.path_join("legacy/levels")
	upgrade.target_directory = ProjectSettings.globalize_path(directory.path_join("Documents/ProgrammableModule/saves"))
	upgrade.journal_path = directory.path_join("migration.json")
	upgrade.state_directory = directory.path_join("upgrade")
	return upgrade


## 使用真实单文件迁移协议产生已完成证据，不直接伪造 journal 内容。
func _migrate(upgrade: PlayerLegacyUpgrade, filename: String) -> DataResult:
	return PlayerLevelMigration.new().migrate_file(upgrade.source_directory, upgrade.target_directory, upgrade.journal_path, filename, FileAccess.get_sha256(upgrade.source_directory.path_join(filename)))


## 只在独占测试物理树内创建原始文件，用于坏 JSON、空文件和故障样例。
func _write(path: String, value: String) -> void:
	var physical := ProjectSettings.globalize_path(path)
	assert(physical.begins_with(ProjectSettings.globalize_path(_root) + "/"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "写入隔离测试文件"):
		file.store_string(value)
		file.close()


## 成功检查保留完整诊断信息供失败定位。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result.is_ok(), message + ": " + "; ".join(result.errors))


## 拒绝场景必须明确返回错误，不能依靠无操作来冒充成功。
func _error(result: DataResult, message: String) -> void:
	_check(not result.is_ok(), message)


## 记录断言并继续其他案例，最终退出码汇总全部失败。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 清理只接受本轮独占测试根，目录链接直接移除而不跟随。
func _cleanup(path: String) -> void:
	assert(path == _root or path.begins_with(_root + "/"))
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for filename in folder.get_files():
		folder.remove(filename)
	for dirname in folder.get_directories():
		if folder.is_link(dirname):
			folder.remove(dirname)
		else:
			_cleanup(path.path_join(dirname))
	DirAccess.remove_absolute(path)
