extends SceneTree
## 清除进度的独立存储回归；所有记录和故障注入均限制在独占 user://tests 子目录。

class FailingStore extends GameDraftStore:
	var rename_calls: int = 0
	var fail_rename_at: int = 0
	var remove_calls: int = 0
	var fail_remove_at: int = 0

	## 模拟批量暂存中途磁盘失败，其余改名（包括回滚）使用真实文件系统。
	func _rename_clear_file(source_path: String, destination_path: String) -> Error:
		rename_calls += 1
		if rename_calls == fail_rename_at:
			return ERR_FILE_CANT_WRITE
		return super._rename_clear_file(source_path, destination_path)

	## 模拟最终删除失败，验证不会把残留的恢复文件报告成成功。
	func _remove_clear_file(path: String) -> Error:
		remove_calls += 1
		if remove_calls == fail_remove_at:
			return ERR_FILE_CANT_WRITE
		return super._remove_clear_file(path)


var _test_root: String
var _checks: int = 0
var _failures: int = 0


## 等场景树就绪后执行，允许测试脚本通过标准退出码报告失败。
func _initialize() -> void:
	_run.call_deferred()


## 按独立目录执行清空、边界、回滚和删除失败用例，最后只清理本次创建的文件。
func _run() -> void:
	_test_root = "user://tests/progress_reset_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_test_complete_reset()
	_test_missing_and_invalid_batch()
	_test_invalid_storage()
	_test_symlinks()
	_test_stage_failure_rollback()
	_test_cleanup_failure()
	_remove_test_tree(_test_root)
	print("进度清除回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 真实写入第一至第十二关和导入记录，确认只清空明确内置 ID 的全部已保存数据及既有恢复备份。
func _test_complete_reset() -> void:
	var store := _store("complete/solutions")
	var builtin_ids: Array[String] = []
	var removed_paths: Array[String] = []
	for index in range(1, 13):
		var level_id := "level_%03d" % index
		builtin_ids.append(level_id)
		_seed_record(store, level_id)
		var backup := store.backup_draft(level_id)
		_ok(backup, "内置关卡草稿可以建立真实恢复备份")
		if backup.is_ok() and backup.value is String:
			removed_paths.append(backup.value)
		removed_paths.append(_record_path(store, level_id, "draft"))
		removed_paths.append(_record_path(store, level_id, "progress"))
	_seed_record(store, "imported_level")
	var imported_backup := store.backup_draft("imported_level")
	_ok(imported_backup, "导入关卡恢复备份可以创建")
	var retained: Dictionary = {}
	for kind in ["draft", "progress"]:
		var path := _record_path(store, "imported_level", kind)
		retained[path] = FileAccess.get_file_as_bytes(path)
	if imported_backup.is_ok() and imported_backup.value is String:
		retained[imported_backup.value] = FileAccess.get_file_as_bytes(imported_backup.value)
	var key := "level_001".sha256_text()
	var unrelated_names := [
		"notes.json", "settings.json", key + ".progress.json.extra", key + ".draft.recovery-other.json",
		key + "0.draft.json", key + ".draft.recovery.1.2.bad.json", key + ".draft.recovery..json",
		key + ".draft.recovery.1.2.0123456789abcdef0123456789abcdef.json.extra",
	]
	for filename in unrelated_names:
		var path := store.directory.path_join(filename)
		_write_text(path, "unchanged: " + filename)
		retained[path] = FileAccess.get_file_as_bytes(path)
	for relative_path in ["complete/settings.json", "complete/levels/custom_map.json", "complete/levels/level_001.json"]:
		var path := _test_root.path_join(relative_path)
		_write_text(path, "unchanged independent file")
		retained[path] = FileAccess.get_file_as_bytes(path)
	# 已损坏、无效编码或不再匹配元数据的精确归属文件仍应可清除。
	_write_text(_record_path(store, "level_006", "draft"), "{ damaged draft")
	_write_text(_record_path(store, "level_007", "progress"), "invalid progress")
	builtin_ids.append("level_001")
	_ok(store.clear_level_records(builtin_ids), "十二个预设关卡的草稿、装配、通关和恢复文件一次清空；重复 ID 去重")
	for path in removed_paths:
		_check(not FileAccess.file_exists(path), "已确认清除的记录不留恢复副本：" + path.get_file())
	for level_id in builtin_ids:
		_check(not store.is_completed(level_id), "清空后内置关卡不再显示已完成")
		var loaded := store.load_draft(level_id)
		_check(loaded.is_ok() and loaded.value == null, "清空后内置代码和装配不再自动恢复")
	for path in retained:
		_check(FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path) == retained[path], "导入记录、相似前缀和其它文件保持字节完全不变")
	_check(store.is_completed("imported_level"), "导入关卡通关状态保留")
	_check(_list_directories(store.directory).is_empty(), "成功后不留下清除暂存目录")
	_ok(store.clear_level_records(builtin_ids), "重复清除是成功空操作")


## 无记录时不创建存储目录；整批中任何无效 ID 都必须在首个文件移动前拒绝。
func _test_missing_and_invalid_batch() -> void:
	var missing := _store("missing/solutions")
	_ok(missing.clear_level_records(["level_001"]), "不存在存档目录时清除成功")
	_check(not DirAccess.dir_exists_absolute(missing.directory), "空操作不会创建存档目录")
	var store := _store("invalid_batch")
	_seed_record(store, "level_001")
	var before := _snapshot_files(store.directory)
	_ok(store.clear_level_records([]), "空 ID 列表无副作用")
	_ok(store.clear_level_records(["never_saved"]), "缺失记录不影响其它记录")
	_error(store.clear_level_records(["level_001", ""]), "批次中存在空 ID 时拒绝整批")
	_error(store.clear_level_records(["level_001", "x".repeat(65537)]), "超长 ID 拒绝整批")
	_check(_snapshot_files(store.directory) == before, "无效批次及空操作不移动、不改写任何已有文件")


## 拒绝越界路径、文件占用目录和记录同名目录，且不递归删除任何目录内容。
func _test_invalid_storage() -> void:
	_error(GameDraftStore.new("res://solutions").clear_level_records(["level_001"]), "拒绝资源目录清除")
	_error(GameDraftStore.new("user://../solutions").clear_level_records(["level_001"]), "拒绝上级路径跳转")
	_error(GameDraftStore.new("user://").clear_level_records([]), "空批次仍检查不允许的根路径")
	var occupied := _test_root.path_join("occupied")
	_write_text(occupied, "file blocking storage directory")
	_error(GameDraftStore.new(occupied.path_join("solutions")).clear_level_records(["level_001"]), "目录链被文件占用时返回错误")
	_check(FileAccess.get_file_as_string(occupied) == "file blocking storage directory", "目录冲突不会删除占用文件")
	var store := _store("blocked_record")
	_seed_record(store, "level_001")
	var protected := _record_path(store, "level_002", "draft").path_join("keep.txt")
	_write_text(protected, "protected directory contents")
	var before := _snapshot_files(store.directory)
	_error(store.clear_level_records(["level_001", "level_002"]), "任意候选文件实际为目录时提前拒绝整批")
	_check(_snapshot_files(store.directory) == before, "同名目录错误发生前，其它待清除记录仍完整")
	_check(FileAccess.get_file_as_string(protected) == "protected directory contents", "不递归清除同名目录")


## 如平台允许创建链接，验证存储目录链及记录链接都不会触碰所指向的文件。
func _test_symlinks() -> void:
	var store := _store("linked_record")
	_seed_record(store, "level_001")
	var target := _test_root.path_join("linked_target/keep.txt")
	_write_text(target, "untouched link target")
	var folder := DirAccess.open(store.directory)
	var linked_filename := "level_002".sha256_text() + ".draft.json"
	var link_error := folder.create_link(ProjectSettings.globalize_path(target), linked_filename)
	if link_error != OK:
		print("当前平台未允许创建测试符号链接；链接用例跳过：%s。" % error_string(link_error))
		return
	_error(store.clear_level_records(["level_001", "level_002"]), "候选存档是链接时拒绝整批")
	_check(store.is_completed("level_001"), "链接错误不删除其它有效记录")
	_check(folder.is_link(linked_filename), "记录链接本身也保留原样")
	_check(FileAccess.get_file_as_string(target) == "untouched link target", "未删除或修改链接目标")
	var root_folder := DirAccess.open(_test_root)
	_ok(DataResult.success() if root_folder.create_link(ProjectSettings.globalize_path(store.directory), "linked_directory") == OK else DataResult.failure("无法创建目录链接"), "创建存储目录链测试链接")
	_error(GameDraftStore.new(_test_root.path_join("linked_directory")).clear_level_records(["level_001"]), "拒绝指向其它目录的存储路径")
	_check(store.is_completed("level_001"), "不跟随存储目录链接清除记录")
	var broken_name := "level_003".sha256_text() + ".progress.json"
	_check(folder.create_link(ProjectSettings.globalize_path(target + ".missing"), broken_name) == OK, "建立悬空记录链接")
	_error(store.clear_level_records(["level_001", "level_003"]), "悬空记录链接也被识别并拒绝")
	_check(folder.is_link(broken_name) and store.is_completed("level_001"), "悬空链接失败无磁盘副作用")


## 第二次真实改名前注入失败，首个已移走文件应回滚，所有内容字节一致且无临时副本。
func _test_stage_failure_rollback() -> void:
	var store := FailingStore.new()
	store.directory = _test_root.path_join("rollback")
	_seed_record(store, "level_001")
	_seed_record(store, "level_002")
	_seed_record(store, "imported_level")
	var before := _snapshot_files(store.directory)
	store.fail_rename_at = 2
	_error(store.clear_level_records(["level_001", "level_002"]), "批量暂存中途失败向调用方报告错误")
	_check(store.rename_calls == 3, "首个成功暂存的文件确实执行恢复改名")
	_check(_snapshot_files(store.directory) == before, "暂存失败后所有内置和导入文件逐字节恢复")
	_check(_list_directories(store.directory).is_empty(), "回滚成功后无残留暂存目录")
	store.fail_rename_at = 0
	_ok(store.clear_level_records(["level_001", "level_002"]), "失败排除后可重新清除")
	_check(store.is_completed("imported_level"), "成功重试仍保护导入关卡")


## 最终删除被拒绝时必须返回错误，并把剩余记录恢复至原位，允许修复权限后重试。
func _test_cleanup_failure() -> void:
	var store := FailingStore.new()
	store.directory = _test_root.path_join("cleanup_failure")
	_seed_record(store, "level_001")
	_seed_record(store, "imported_level")
	var imported_before := FileAccess.get_file_as_bytes(_record_path(store, "imported_level", "draft"))
	store.fail_remove_at = 1
	var result := store.clear_level_records(["level_001"])
	_error(result, "删除暂存文件失败不能报告清除成功")
	_check("; ".join(result.errors).contains("原位置"), "失败明确告知其余记录已恢复")
	_check(_list_directories(store.directory).is_empty(), "删除失败后不把未清除的记录遗留在隐藏目录")
	_check(store.is_completed("level_001") and store.load_draft("level_001").value != null, "未删除的草稿与进度恢复原位")
	_check(store.is_completed("imported_level") and FileAccess.get_file_as_bytes(_record_path(store, "imported_level", "draft")) == imported_before, "清理失败不影响导入记录")
	store.fail_remove_at = 0
	_ok(store.clear_level_records(["level_001"]), "失败后再次清除能够处理所有剩余记录")
	_check(not store.is_completed("level_001") and store.load_draft("level_001").value == null, "重试成功后确实不再留下恢复数据")
	var partial := FailingStore.new()
	partial.directory = _test_root.path_join("partial_cleanup")
	_seed_record(partial, "level_001")
	_seed_record(partial, "level_002")
	partial.fail_remove_at = 2
	_error(partial.clear_level_records(["level_001", "level_002"]), "部分文件已删除后发生错误仍报告未完成")
	_check(_snapshot_files(partial.directory).size() == 3 and _list_directories(partial.directory).is_empty(), "部分删除失败后剩余三个文件均恢复原位")
	partial.fail_remove_at = 0
	_ok(partial.clear_level_records(["level_001", "level_002"]), "部分清除也可再次重试完成")
	_check(_snapshot_files(partial.directory).is_empty(), "重试后所有原记录和临时备份均清除")


## 每例注入独占存档目录，不使用 GameDraftStore 的默认真实玩家位置。
func _store(relative_path: String) -> GameDraftStore:
	return GameDraftStore.new(_test_root.path_join(relative_path))


## 建立含实际代码、模块装配及通关标记的完整玩家记录。
func _seed_record(store: GameDraftStore, level_id: String) -> void:
	var modules := [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]
	_ok(store.save_draft(level_id, "main() {\n    move(0, 2)\n}\n", modules), "保存测试代码及装配")
	_ok(store.mark_completed(level_id), "保存测试通关记录")


## 测试按公开磁盘格式定位文件，不读取生产存储模型的私有辅助函数。
func _record_path(store: GameDraftStore, level_id: String, kind: String) -> String:
	return store.directory.path_join("%s.%s.json" % [level_id.sha256_text(), kind])


## 保存直接子文件的原始字节，用于检测失败回滚是否改变有效存档或附带写入其它文件。
func _snapshot_files(path: String) -> Dictionary:
	var result: Dictionary = {}
	var folder := DirAccess.open(path)
	folder.include_hidden = true
	for filename in folder.get_files():
		result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 包含隐藏目录，确保清除操作不能把残留暂存文件藏在测试检查之外。
func _list_directories(path: String) -> PackedStringArray:
	var folder := DirAccess.open(path)
	folder.include_hidden = true
	return folder.get_directories()


## 仅在本次测试目录下创建恶意或损坏输入，不覆盖任何真实玩家文件。
func _write_text(path: String, text: String) -> void:
	_check(path.begins_with(_test_root + "/"), "文件写入被限制在独占测试目录")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "独占测试文件可以写入"):
		file.store_string(text)
		file.close()


## 清理独占测试子树时只移除链接自身，绝不递归进入链接所指向的目录。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var filename := folder.get_next()
	while not filename.is_empty():
		var child_path := path.path_join(filename)
		if folder.is_link(filename) or not folder.current_is_dir():
			DirAccess.remove_absolute(child_path)
		else:
			_remove_test_tree(child_path)
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 成功结果附带底层诊断，避免仅因返回了对象就误认为动作已完成。
func _ok(result: DataResult, message: String) -> void:
	_check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；缺少结果"))


## 所有失败必须含可向界面展示的错误信息。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 汇总断言并继续独立用例，以便一次运行发现完整失败范围。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
