extends SceneTree
## 独占测试目录验证可见缓存/进度、只迁移一次、原字节保留与跨目录清除回滚。

class FailCommit extends PlayerRuntimeMigration:
	var blocked_name := ""
	## 注入最终提交失败，仍执行真实复制和回读。
	func _rename_file(source: String, destination: String) -> Error:
		return ERR_FILE_CANT_WRITE if destination.get_file() == blocked_name else super._rename_file(source, destination)


class FailClear extends GameDraftStore:
	var fail_on := 2
	var calls := 0
	## 模拟第二个目录暂存失败，验证第一个目录的原件也会归还。
	func _rename_clear_file(source: String, destination: String) -> Error:
		calls += 1
		return ERR_FILE_CANT_WRITE if calls == fail_on else super._rename_clear_file(source, destination)


var _root := ""
var _checks := 0
var _failures := 0


## 类加载完成后运行隔离数据测试。
func _initialize() -> void:
	_run.call_deferred()


## 全部读写都限制于本次 user://tests 目录，结束后撤销授权并清除自身夹具。
func _run() -> void:
	_root = "user://tests/runtime_storage_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(PlayerLevelPaths.register_test_root(_root).is_ok(), "注册隔离物理根")
	_test_path_boundaries()
	_test_split_storage()
	_test_migration()
	_test_existing_destination()
	_test_retry()
	_test_marker_retry()
	_test_links()
	PlayerRuntimePaths.clear_configuration()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("缓存与进度存储回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 每个用例拥有独立的可见根和旧版目录，返回经过真实路径授权的布局。
func _layout(name: String) -> Dictionary:
	var base := _root.path_join(name)
	var saves := ProjectSettings.globalize_path(base.path_join("ProgrammableModule/saves"))
	var configured := PlayerRuntimePaths.configure_from_saves(saves, true)
	_check(configured.is_ok(), "配置测试布局：" + name + " " + "; ".join(configured.errors))
	var result: Dictionary = configured.value
	result["base"] = base
	result["saves"] = saves
	result["legacy"] = base.path_join("old/solutions")
	result["profile"] = base.path_join("old/player_profile.json")
	result["marker"] = base.path_join("old/runtime_migrated.json")
	return result


## 普通路径、任意绝对路径、相邻近似目录及用户目录逃逸都不能获得运行数据权限。
func _test_path_boundaries() -> void:
	var fallback := PlayerRuntimePaths.configure_from_saves("user://levels")
	_check(fallback.is_ok() and fallback.value.cache_directory == "user://Cache" and fallback.value.progress_directory == "user://Progress", "非桌面回退路径保持 user:// 根规范")
	var layout := _layout("paths")
	_check(not DirAccess.dir_exists_absolute(layout.cache_directory), "配置不创建实际目录")
	_check(not PlayerRuntimePaths.configure_from_saves("/tmp/ProgrammableModule/saves").is_ok(), "任意绝对根拒绝")
	_check(not PlayerRuntimePaths.open_directory(layout.cache_directory + "_other", true).is_ok(), "前缀近似目录拒绝")
	_check(not PlayerRuntimePaths.open_directory(layout.cache_directory.path_join("extra"), true).is_ok(), "绝对子目录未被泛化授权")
	_check(not PlayerRuntimePaths.validate_file("user://tests/../outside.json").is_ok(), "拒绝上级跳转")
	_check(PlayerLevelPaths._configured_external_root.is_empty(), "缓存授权不改变地图活动根")
	var wrong_profile := PlayerProfileStore.new(layout.cache_directory.path_join("player_profile.json"))
	_check(not wrong_profile.load_profile().is_ok(), "档案不能写进绝对 Cache")
	_check(not GameDraftStore.new("", "").save_draft("id", "", []).is_ok(), "空路径占位不能写入")


## 草稿和通关分别落盘，清除只触及指定 ID，并在跨目录暂存失败时同时恢复。
func _test_split_storage() -> void:
	var layout := _layout("split")
	var store := GameDraftStore.new(layout.cache_directory, layout.progress_directory)
	_check(store.save_draft("alpha", "main() {}", []).is_ok(), "草稿写入 Cache")
	_check(store.mark_completed("alpha").is_ok(), "完成写入 Progress")
	_check(store.save_failure_streak("alpha", 2).is_ok(), "连续失败与完成共享进度文件")
	_check(store.load_draft("alpha").value.source == "main() {}" and store.is_completed("alpha") and store.get_failure_streak("alpha") == 2, "分离后可读回全部数据")
	_check(FileAccess.file_exists(layout.cache_directory.path_join("alpha".sha256_text() + ".draft.json")), "实际草稿路径正确")
	_check(not FileAccess.file_exists(layout.cache_directory.path_join("alpha".sha256_text() + ".progress.json")), "Cache 没有通关记录")
	_check(store.save_draft("keep", "retain", []).is_ok() and store.mark_completed("keep").is_ok(), "建立另一关卡夹具")
	var failing := FailClear.new(layout.cache_directory, layout.progress_directory)
	_check(not failing.clear_level_records(["alpha"]).is_ok(), "第二目录暂存故障返回失败")
	_check(store.load_draft("alpha").value.source == "main() {}" and store.is_completed("alpha"), "两边原件均恢复")
	_check(store.backup_draft("alpha").is_ok(), "绝对 Cache 可生成恢复备份")
	_check(store.clear_level_records(["alpha"]).is_ok(), "双目录清理成功")
	_check(store.load_draft("alpha").value == null and not store.is_completed("alpha"), "目标关卡两边都已清理")
	_check(store.load_draft("keep").value.source == "retain" and store.is_completed("keep"), "其他关卡不受影响")
	var catalog := LevelCatalog.new()
	catalog.user_directory = str(layout.base).path_join("ProgrammableModule/Progress")
	_check(not catalog.clear_user_levels(store).is_ok() and store.is_completed("keep"), "资源别名和绝对 Progress 重叠也阻止地图清理")
	catalog.user_directory = str(layout.base).path_join("ProgrammableModule/Cache")
	_check(not catalog.clear_user_levels(store).is_ok() and store.load_draft("keep").value != null, "资源别名和绝对 Cache 重叠也阻止地图清理")
	var profile := PlayerProfileStore.new(layout.profile_path)
	_check(profile.load_profile().is_ok() and profile.set_username("Tester").is_ok(), "档案写入授权 Progress")
	var uid := profile.get_uid()
	var restored := PlayerProfileStore.new(layout.profile_path)
	_check(restored.load_profile().is_ok() and restored.get_uid() == uid and restored.get_username() == "Tester", "档案重启读取身份稳定")


## 损坏旧 JSON 和恢复备份仍按字节迁入，未知文件保留源位置；清除新记录后重启不复活。
func _test_migration() -> void:
	var layout := _layout("migration")
	var old := GameDraftStore.new(layout.legacy)
	_check(old.save_draft("alpha", "old code", []).is_ok() and old.mark_completed("alpha").is_ok(), "准备旧版双记录")
	var backup := old.backup_draft("alpha")
	_check(backup.is_ok(), "准备旧草稿恢复文件")
	var broken: String = layout.legacy.path_join("broken".sha256_text() + ".draft.json")
	_write(broken, PackedByteArray([255, 0, 1, 200]))
	_write(layout.legacy.path_join("unknown.json"), "unknown".to_utf8_buffer())
	var profile := PlayerProfileStore.new(layout.profile)
	_check(profile.load_profile().is_ok() and profile.set_username("OldPlayer").is_ok(), "准备旧玩家档案")
	var migration := _migration(layout)
	var initial_result := migration.migrate()
	_check(initial_result.is_ok(), "首次迁移成功：" + "; ".join(initial_result.errors))
	_check(FileAccess.get_sha256(broken) == FileAccess.get_sha256(layout.cache_directory.path_join(broken.get_file())), "损坏 JSON 原始字节保留")
	_check(FileAccess.get_sha256(backup.value) == FileAccess.get_sha256(layout.cache_directory.path_join(str(backup.value).get_file())), "恢复备份原始字节保留")
	_check(not FileAccess.file_exists(layout.cache_directory.path_join("unknown.json")), "未知 JSON 不复制")
	_check(FileAccess.get_sha256(layout.profile) == FileAccess.get_sha256(layout.profile_path), "旧身份与统计完整复制")
	_check(FileAccess.file_exists(layout.marker) and FileAccess.file_exists(layout.progress_directory.path_join(PlayerRuntimeMigration.DESTINATION_MARKER)), "两份完成标记已持久化")
	var current := GameDraftStore.new(layout.cache_directory, layout.progress_directory)
	_check(current.is_completed("alpha") and current.load_draft("alpha").value.source == "old code", "新目录读取已迁移记录")
	_check(current.clear_level_records(["alpha"]).is_ok() and migration.migrate().is_ok(), "清除之后再次启动")
	_check(not current.is_completed("alpha") and current.load_draft("alpha").value == null, "旧目录仍有文件但不复活进度")
	_check(old.is_completed("alpha"), "迁移不删除旧源")
	_cleanup(layout.progress_directory)
	_check(migration.migrate().is_ok() and not current.is_completed("alpha"), "Progress 整目录删除也不从旧源复活")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(layout.marker))
	_check(migration.migrate().is_ok() and not current.is_completed("alpha"), "单独用户检查点丢失由目标标记保护")


## 新版已保存数据优先，不覆盖冲突内容；坏目标占位必须在创建默认档案前报告。
func _test_existing_destination() -> void:
	var layout := _layout("conflict")
	var old := GameDraftStore.new(layout.legacy)
	old.save_draft("alpha", "old", [])
	var fresh := GameDraftStore.new(layout.cache_directory, layout.progress_directory)
	fresh.save_draft("alpha", "new", [])
	_check(_migration(layout).migrate().is_ok() and fresh.load_draft("alpha").value.source == "new", "已有新文件保持原样")
	layout = _layout("blocked")
	old = GameDraftStore.new(layout.legacy)
	old.mark_completed("alpha")
	var blocked: String = layout.progress_directory.path_join("alpha".sha256_text() + ".progress.json")
	DirAccess.make_dir_recursive_absolute(blocked)
	_check(not _migration(layout).migrate().is_ok() and not FileAccess.file_exists(layout.marker), "目标被目录占位则迁移失败且无完成标记")
	DirAccess.remove_absolute(blocked)
	_check(_migration(layout).migrate().is_ok(), "移除占位后可重试")
	layout = _layout("corrupt_profile")
	_write(layout.profile, "{broken profile".to_utf8_buffer())
	_check(_migration(layout).migrate().is_ok(), "损坏旧档案仍原样迁入")
	var profile := PlayerProfileStore.new(layout.profile_path)
	_check(not profile.load_profile().is_ok() and FileAccess.get_file_as_string(layout.profile_path) == "{broken profile", "损坏档案不生成默认 UID 或覆盖原件")



## 复制提交失败不伤旧源，已复制项可复用，再次执行补齐剩余项。
func _test_retry() -> void:
	var layout := _layout("retry")
	var old := GameDraftStore.new(layout.legacy)
	old.save_draft("alpha", "draft", [])
	old.mark_completed("alpha")
	var migration := FailCommit.new(layout.cache_directory, layout.progress_directory, layout.legacy, layout.profile, layout.marker)
	migration.blocked_name = "alpha".sha256_text() + ".progress.json"
	_check(not migration.migrate().is_ok() and not FileAccess.file_exists(layout.marker), "发布失败不写完成标记")
	_check(old.is_completed("alpha") and old.load_draft("alpha").value.source == "draft", "失败保持旧源可用")
	migration.blocked_name = ""
	_check(migration.migrate().is_ok(), "发布失败可重试成功")


## 写入第一份完成标记后第二份故障，重启补标记且不扫描已弃用的旧源。
func _test_marker_retry() -> void:
	var layout := _layout("marker_retry")
	var migration := FailCommit.new(layout.cache_directory, layout.progress_directory, layout.legacy, layout.profile, layout.marker)
	migration.blocked_name = PlayerRuntimeMigration.DESTINATION_MARKER
	_check(not migration.migrate().is_ok() and FileAccess.file_exists(layout.marker), "第二标记失败仍保留第一份成功检查点")
	var old := GameDraftStore.new(layout.legacy)
	old.mark_completed("late")
	migration.blocked_name = ""
	_check(migration.migrate().is_ok() and not GameDraftStore.new(layout.cache_directory, layout.progress_directory).is_completed("late"), "补检查点不迁入完成后新增旧记录")
	_write(layout.marker, "broken".to_utf8_buffer())
	_check(not migration.migrate().is_ok(), "损坏检查点不被默默重建")


## Unix 链接夹具验证目录和文件都不会被读取、覆盖或清理。
func _test_links() -> void:
	if OS.get_name() == "Windows":
		return
	var layout := _layout("links")
	var target := _root.path_join("link_target")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target))
	_write(target.path_join("keep.json"), "keep".to_utf8_buffer())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(layout.legacy))
	var source: String = layout.legacy.path_join("alpha".sha256_text() + ".draft.json")
	var output: Array = []
	var status := OS.execute("/bin/ln", ["-s", ProjectSettings.globalize_path(target.path_join("keep.json")), ProjectSettings.globalize_path(source)], output)
	_check(status == 0 and not _migration(layout).migrate().is_ok(), "迁移拒绝旧存档文件链接")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(source))
	DirAccess.make_dir_recursive_absolute(layout.cache_directory.get_base_dir())
	status = OS.execute("/bin/ln", ["-s", ProjectSettings.globalize_path(target), layout.cache_directory], output)
	_check(status == 0 and not GameDraftStore.new(layout.cache_directory, layout.progress_directory).save_draft("alpha", "", []).is_ok(), "草稿拒绝目录链接")
	_check(not _migration(layout).migrate().is_ok(), "迁移拒绝目标目录链接")
	DirAccess.remove_absolute(layout.cache_directory)
	_check(FileAccess.get_file_as_string(target.path_join("keep.json")) == "keep", "链接目标内容未变")


## 为指定布局构造正常迁移器，不触及正式旧目录。
func _migration(layout: Dictionary) -> PlayerRuntimeMigration:
	return PlayerRuntimeMigration.new(layout.cache_directory, layout.progress_directory, layout.legacy, layout.profile, layout.marker)


## 夹具保留任意二进制字节，以验证迁移不会先解析并丢弃坏 JSON。
func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


## 记录全部断言并在退出时汇总失败。
func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)


## 仅递归自身测试目录且不跟随符号链接。
func _cleanup(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var filename := folder.get_next()
	while not filename.is_empty():
		var child := path.path_join(filename)
		if folder.current_is_dir() and not folder.is_link(filename):
			_cleanup(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
