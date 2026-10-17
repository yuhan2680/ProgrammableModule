extends SceneTree
## 真实外壳的可见缓存与进度集成，所有旧源、授权替身和新目录均位于独占测试根。

class TestShell extends GameShell:
	var storage_requests := 0
	var notices: Array[String] = []

	## 拦截真实系统授权窗口，验证门禁而不抢占桌面或访问正式 Documents。
	func _request_player_storage() -> void:
		storage_requests += 1

	## 捕获可重试错误，避免测试创建模态窗口影响后续入口。
	func _show_player_storage_problem() -> void:
		storage_requests += 1

	## 捕获普通错误而不显示原生提示。
	func _show_message(title_text: String, body: String) -> void:
		notices.append(title_text + "\n" + body)

class RetryMigration extends PlayerRuntimeMigration:
	var blocked := true
	var calls := 0

	## 注入独占源与目标，保留真实模型用于故障解除后的迁移。
	func _init(cache: String, progress: String, solutions: String, profile_file: String, marker: String) -> void:
		super(cache, progress, solutions, profile_file, marker)

	## 首次模拟无写入的磁盘故障，重试使用真实复制和检查点流程。
	func migrate() -> DataResult:
		calls += 1
		return DataResult.failure("测试：运行数据暂时无法读取。") if blocked else super.migrate()

var _checks := 0
var _failures := 0
var _root := ""
const LEVEL_ID := "level_001"
const SOURCE := "main() {\n}\n"


## 延后创建外壳，测试根使用进程与时钟组合避免并行运行互相污染。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 覆盖成功、门禁与恢复、损坏旧档、一次迁移和已有显式注入五条集成路径。
func _run() -> void:
	_root = "user://tests/player_runtime_shell_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_ok(PlayerLevelPaths.register_test_root(_root), "注册运行数据独占测试根")
	await _test_successful_migration()
	await _test_failed_migration_retry()
	await _test_invalid_profile_retry()
	await _test_cleared_records_do_not_return()
	await _test_explicit_paths_stay_isolated()
	PlayerRuntimePaths.clear_configuration()
	PlayerLevelPaths.clear_external_root()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("玩家运行数据外壳回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 真实旧草稿、完成事实和档案各自进入 Cache / Progress，原文件原样保留。
func _test_successful_migration() -> void:
	var game := _external_shell("success")
	var old := _seed_legacy(game.runtime_storage_migration)
	await _mount(game)
	var migration := game.runtime_storage_migration
	_check(game._runtime_storage_ready, "迁移和档案载入都成功才开启正式运行存储")
	_check(game.drafts.directory == migration.cache_directory and game.drafts.progress_directory == migration.progress_directory, "草稿与完成状态使用两个独立可见目录")
	_check(game.profile.storage_path == migration.progress_directory.path_join("player_profile.json"), "玩家统计落入 Progress 下的独立档案")
	_check(game.profile.get_uid() == old.uid and game.profile.get_first_run_date() == "2026-9-14", "迁移保留旧玩家 UID 与首次运行日期")
	_check(game.profile.get_statistics().code_hint_uses == 3, "已保存的玩家统计完整继承")
	_check(game.drafts.is_completed(LEVEL_ID), "正式外壳读取迁移后的教学完成事实")
	var draft := game.drafts.load_draft(LEVEL_ID)
	_check(draft.is_ok() and draft.value != null and draft.value.source == SOURCE, "正式外壳读取迁移后的玩家代码草稿")
	_check(FileAccess.file_exists(_record(migration.cache_directory, "draft")) and not FileAccess.file_exists(_record(migration.cache_directory, "progress")), "Cache 只有草稿而不混入完成记录")
	_check(FileAccess.file_exists(_record(migration.progress_directory, "progress")) and not FileAccess.file_exists(_record(migration.progress_directory, "draft")), "Progress 只有完成记录而不混入草稿")
	_check(FileAccess.get_file_as_bytes(migration.legacy_profile) == old.profile_bytes and FileAccess.get_file_as_bytes(_record(migration.legacy_solutions, "draft")) == old.draft_bytes, "迁移保留旧档案与玩家代码原始备份")
	_check(FileAccess.file_exists(migration.marker_path), "外壳只在完整迁移后产生完成标记")
	_check(game.settings.storage_path == _root.path_join("success/settings.json"), "设置仍使用隔离的原有用户数据位置")
	await _release(game)


## 失败不创建新档、不恢复旧写入；修复后原待执行入口只恢复一次。
func _test_failed_migration_retry() -> void:
	var game := _external_shell("failure")
	var normal := game.runtime_storage_migration
	var migration := RetryMigration.new(normal.cache_directory, normal.progress_directory, normal.legacy_solutions, normal.legacy_profile, normal.marker_path)
	game.runtime_storage_migration = migration
	var old := _seed_legacy(migration)
	await _mount(game)
	_check(not game._runtime_storage_ready and migration.calls == 1, "首次迁移故障保持运行存储门禁")
	_check(game.profile.storage_path.is_empty() and game.drafts.directory.is_empty(), "迁移失败使用不可写占位模型，不退回旧存档路径")
	_check(not FileAccess.file_exists(migration.progress_directory.path_join("player_profile.json")) and not FileAccess.file_exists(migration.marker_path), "失败不能创建默认档案或伪造迁移完成")
	_check(FileAccess.get_file_as_bytes(migration.legacy_profile) == old.profile_bytes, "失败不重写原玩家 UID 或日期")
	game._show_settings_page()
	_check(game.page == GameShell.Page.SETTINGS, "运行存储失败仍允许进入设置")
	game._enter_level(game.catalog.levels[0])
	_check(game.session == null and not game._runtime_storage_ready and game.storage_requests > 0, "失败时正式关卡入口等待保存权限而不生成会话")
	game._shark_discovered = true
	game._shark_best_score = 77
	game._persist_shark_statistics()
	game._flush_activity_statistics()
	_check(FileAccess.get_file_as_bytes(migration.legacy_profile) == old.profile_bytes and not FileAccess.file_exists(migration.progress_directory.path_join("player_profile.json")), "失败期间统计刷新不写旧档也不创建新档")
	var resumed := [0]
	_check(not game._ensure_runtime_storage(func() -> void: resumed[0] += 1), "运行入口将继续操作挂到重试流程")
	migration.blocked = false
	game._retry_player_storage()
	_check(game._runtime_storage_ready and migration.calls == 2 and resumed[0] == 1, "修复后重试真实迁移且待执行操作仅恢复一次")
	_check(game.profile.get_uid() == old.uid and game.drafts.is_completed(LEVEL_ID), "重试载入旧玩家身份与教学完成事实")
	_check(not game._player_storage_continuation.is_valid(), "成功后清理待执行回调避免重复恢复")
	await _release(game)


## 损坏档案可以保留原字节迁移，但不能成为创建默认身份的理由；修复新档后可重试。
func _test_invalid_profile_retry() -> void:
	var game := _external_shell("invalid")
	var migration := game.runtime_storage_migration
	var old := _seed_legacy(migration)
	var broken := "{invalid legacy profile"
	_write(migration.legacy_profile, broken)
	await _mount(game)
	var target := migration.progress_directory.path_join("player_profile.json")
	_check(not game._runtime_storage_ready, "迁移文件成功但档案损坏时仍保持运行门禁")
	_check(FileAccess.get_file_as_string(target) == broken and FileAccess.get_file_as_string(migration.legacy_profile) == broken, "新旧两处损坏原件都不会被默认档案覆盖")
	game._persist_shark_statistics()
	_check(FileAccess.get_file_as_string(target) == broken, "损坏档案在普通统计回调后保持原样")
	_write(target, old.profile_bytes.get_string_from_utf8())
	game._retry_player_storage()
	_check(game._runtime_storage_ready and game.profile.get_uid() == old.uid, "修复可见档案后重试恢复原身份")
	_check(FileAccess.get_file_as_string(migration.legacy_profile) == broken, "重试只使用新数据，不修改旧损坏备份")
	await _release(game)


## 清除新目录的教学记录并重置统计后，重启不再读取仍存在的旧备份。
func _test_cleared_records_do_not_return() -> void:
	var game := _external_shell("cleared")
	var old := _seed_legacy(game.runtime_storage_migration)
	await _mount(game)
	var migration := game.runtime_storage_migration
	_ok(game.drafts.clear_level_records([LEVEL_ID]), "同时清除 Cache 草稿与 Progress 通关记录")
	_ok(game.profile.reset_profile(), "在可见 Progress 目录重置玩家档案")
	var new_uid := game.profile.get_uid()
	_check(new_uid != old.uid and game.profile.get_first_run_date() == "2026-9-14", "重置更新 UID 但保留本机首次运行日期")
	_check(not FileAccess.file_exists(_record(migration.cache_directory, "draft")) and not FileAccess.file_exists(_record(migration.progress_directory, "progress")), "清除已实际作用于两个不同目录")
	_check(FileAccess.file_exists(_record(migration.legacy_solutions, "progress")) and FileAccess.get_file_as_bytes(migration.legacy_profile) == old.profile_bytes, "清除新数据不会删除旧备份")
	await _release(game)
	var restarted := _external_shell("cleared")
	await _mount(restarted)
	_check(restarted._runtime_storage_ready and restarted.profile.get_uid() == new_uid, "重启保留新玩家身份而不恢复旧档案")
	var draft := restarted.drafts.load_draft(LEVEL_ID)
	_check(not restarted.drafts.is_completed(LEVEL_ID) and draft.is_ok() and draft.value == null, "一次迁移标记防止重启复活旧完成状态和代码")
	_check(restarted.profile.get_statistics().code_hint_uses == 0, "旧统计不会在重启后重新写回")
	await _release(restarted)


## 旧回归与独立调用者只注入 user 路径时，不解析真实文稿或启动任何自动迁移。
func _test_explicit_paths_stay_isolated() -> void:
	var game := _shell("explicit")
	game.user_levels_directory = _root.path_join("explicit/levels")
	game.drafts_directory = _root.path_join("explicit/solutions")
	game.profile_path = _root.path_join("explicit/profile.json")
	await _mount(game)
	_check(game._runtime_storage_ready and game.runtime_storage_migration == null and game.player_save_location == null, "显式测试路径不触发运行迁移或正式授权解析")
	_check(game.drafts.directory == game.drafts_directory and game.profile.storage_path == game.profile_path, "显式草稿与档案路径保持调用方隔离边界")
	_check(game.storage_requests == 0 and not DirAccess.dir_exists_absolute(_root.path_join("explicit/Documents")), "隔离调用不会创建模拟外部目录或请求系统权限")
	await _release(game)


## 构造真实外壳但注入设置、旧地图与固定活动时钟，所有潜在副作用限制在测试树。
func _shell(case_name: String) -> TestShell:
	var game := TestShell.new()
	var base := _root.path_join(case_name)
	game.name = "PlayerRuntimeTestShell"
	game.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game.settings_path = base.path_join("settings.json")
	game.profile_clock = func() -> float: return 0.0
	game.player_saves_source = base.path_join("legacy/levels")
	game.player_saves_journal = base.path_join("level_migration.json")
	game.legacy_upgrade_native_dialog_handler = func(_title: String, _body: String, _buttons: PackedStringArray, callback: Callable) -> int:
		callback.call(0)
		return OK
	return game


## 显式运行迁移注入强制采用正式 Cache / Progress 分流，物理位置仍为注册测试根。
func _external_shell(case_name: String) -> TestShell:
	var game := _shell(case_name)
	var base := _root.path_join(case_name)
	var location := PlayerSaveLocation.new(base.path_join("location.json"))
	location.platform_name = "macOS"
	location.sandboxed = false
	location.documents_directory = ProjectSettings.globalize_path(base.path_join("Documents"))
	location.allow_registered_test_roots = true
	game.player_save_location = location
	var storage_base := location.documents_directory.path_join("ProgrammableModule")
	game.runtime_storage_migration = PlayerRuntimeMigration.new(storage_base.path_join("Cache"), storage_base.path_join("Progress"), base.path_join("legacy/solutions"), base.path_join("legacy/player_profile.json"), base.path_join("runtime_migration.json"))
	return game


## 使用真实旧版模型生成有效文件，只改写测试档案的固定日期与统计以便精确核验。
func _seed_legacy(migration: PlayerRuntimeMigration) -> Dictionary:
	var store := GameDraftStore.new(migration.legacy_solutions)
	_ok(store.save_draft(LEVEL_ID, SOURCE, []), "准备真实旧版代码草稿")
	_ok(store.mark_completed(LEVEL_ID), "准备真实旧版教学完成记录")
	var profile := PlayerProfileStore.new(migration.legacy_profile)
	var generated := profile._new_profile("")
	_ok(generated, "生成隔离旧玩家档案")
	var data: Dictionary = generated.value
	data.first_run_date = "2026-09-14"
	data.statistics.code_hint_uses = 3
	_write(migration.legacy_profile, JSON.stringify(data, "\t") + "\n")
	return {"uid": data.uid, "profile_bytes": FileAccess.get_file_as_bytes(migration.legacy_profile), "draft_bytes": FileAccess.get_file_as_bytes(_record(migration.legacy_solutions, "draft"))}


## 记录文件名沿用现有稳定 ID 哈希，不读取真实玩家内容。
func _record(directory: String, kind: String) -> String:
	return directory.path_join("%s.%s.json" % [LEVEL_ID.sha256_text(), kind])


## 等待真实异步启动和延后通知结束，使门禁断言检查最终状态。
func _mount(game: TestShell) -> void:
	root.add_child(game)
	for unused in 600:
		if game.startup_complete:
			break
		await process_frame
	_check(game.startup_complete, "隔离运行数据外壳完成启动")
	for unused in 4:
		await process_frame


## 节点退出先落完其已有活动状态，再撤销本次模拟目录授权。
func _release(game: TestShell) -> void:
	game.queue_free()
	for unused in 6:
		await process_frame
	PlayerRuntimePaths.clear_configuration()
	PlayerLevelPaths.clear_external_root()


## 只对注册测试树及其物理映射写入测试夹具，正式目录不可进入本 helper。
func _write(path: String, value: String) -> void:
	var physical_root := ProjectSettings.globalize_path(_root)
	assert(path.begins_with(_root + "/") or path.begins_with(physical_root + "/"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "写入运行数据隔离夹具")
	if file != null:
		file.store_string(value)
		file.close()


## 失败显示模型返回的具体原因，帮助区分存储协议与外壳接线问题。
func _ok(result: DataResult, message: String) -> void:
	_check(result.is_ok(), message + ": " + "; ".join(result.errors))


## 汇总所有独立检查并在结尾返回非零状态。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 清理严格限制于测试根，遇到链接只删除链接本身而不递归目标。
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
