extends SceneTree
## 新保存目录与旧目录候选聚合回归；单条迁移前后的只读边界均使用独占测试文件。

var _checks := 0
var _failures := 0
var _root := ""
var _target := ""
var _legacy := ""
var _journal := ""
var _content := ContentRegistry.new()


## 等待类注册结束，不扫描或迁移真实用户的旧关卡。
func _initialize() -> void:
	_run.call_deferred()


## 真实 JSON、坏文件、旧菜单与文件替换分别验证，最终清理仅限当前隔离根。
func _run() -> void:
	_root = "user://tests/player_legacy_library_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_legacy = _root.path_join("legacy/levels")
	_journal = _root.path_join("migration.json")
	_ok(PlayerLevelPaths.register_test_root(_root), "注册独占外部物理根")
	_target = ProjectSettings.globalize_path(_root.path_join("Documents/ProgrammableModule/saves"))
	_ok(_content.load_directories(), "加载真实地图定义")
	_fixture_files()
	_test_aggregation_and_gates()
	_test_stale_and_forged()
	_test_single_migration()
	_test_readonly_and_errors()
	_test_links()
	PlayerLevelPaths.unregister_test_root(_root)
	_cleanup(_root)
	print("旧玩家关卡聚合回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 同名同 ID 的正常项与旧项分目录保存，坏文档和草稿保持原始字节。
func _fixture_files() -> void:
	var normal := _map("shared_id")
	normal.display_name = "同名地图"
	_ok(MapCodec.save_file(normal, _target.path_join("good.json"), _content), "创建新目录正常关卡")
	var old := normal.duplicate_document()
	old.properties.level["creator"] = "旧作者"
	_ok(MapCodec.save_file(old, _legacy.path_join("good.json"), _content), "创建旧目录同名同 ID 关卡")
	var draft := _map("old_draft")
	draft.player_spawn = null
	_ok(MapCodec.save_file(draft, _legacy.path_join("draft.json"), _content, false), "创建旧目录未完成草稿")
	_write(_legacy.path_join("broken.json"), "{broken")
	_write(_legacy.path_join("empty.json"), "")
	var newer := _map("newer").to_dict()
	newer["format_version"] = 99
	_write(_legacy.path_join("newer.json"), JSON.stringify(newer))
	_write(_legacy.path_join("nested/ignored.json"), "ignored")


## 默认不聚合；启用后旧项保留元数据与诊断，但不污染正常文件的可玩状态。
func _test_aggregation_and_gates() -> void:
	var normal := PlayerLevelLibrary.new()
	normal.user_directory = _target
	_ok(normal.refresh(_content), "缺省行为只扫描新目录")
	_check(normal.entries.size() == 1 and not normal.entries[0].needs_migration, "旧目录默认关闭以兼容现有调用")
	var library := _library()
	_ok(library.refresh(_content), "聚合新目录与旧目录直接 JSON")
	_check(library.entries.size() == 6, "保留正常文件、旧图、草稿、坏文件、空文件与新版本文件")
	var current := _find(library, "good.json", false)
	var old := _find(library, "good.json", true)
	_check(current != null and current.playable and current.errors.is_empty(), "旧备份的相同 ID 不影响新目录正常关卡")
	_check(old != null and old.display_name == "同名地图" and old.creator == "旧作者", "旧记录保留地图名称及署名")
	if old != null:
		_check(old.needs_migration and not old.can_edit and not old.can_rename and not old.playable, "旧记录明确需要迁移且不获得普通操作能力")
		var source := library.get_legacy_migration_source(old)
		_check(source.is_ok() and source.value.filename == "good.json" and source.value.fingerprint == FileAccess.get_sha256(old.source_path), "迁移入口返回文件名及真实 SHA256")
		var directory := library.get_entry_directory(old)
		_check(directory.is_ok() and directory.value == ProjectSettings.globalize_path(_legacy), "旧项仅允许安全查看原目录")
		_error(library.rename_entry(old, "不可改名", _content), "旧项拒绝普通改名")
		_error(library.delete_entry(old), "旧项拒绝普通删除")
		_error(library.get_entry_edit_path(old), "旧项拒绝直接编辑")
		old.needs_migration = false
		old.can_edit = true
		_error(library.delete_entry(old), "修改展示字段不能绕过旧目录操作门禁")
		_error(library.get_entry_edit_path(old), "伪造可编辑字段不能获得旧路径编辑权")
	if current != null:
		_error(library.get_legacy_migration_source(current), "正常新目录项无需迁移")
	var broken := _find(library, "broken.json", true)
	var draft := _find(library, "draft.json", true)
	var newer := _find(library, "newer.json", true)
	_check(broken != null and broken.is_corrupt and not broken.errors.is_empty(), "旧坏 JSON 仍保留具体内容诊断")
	_check(draft != null and not draft.errors.is_empty(), "旧未完成草稿保留缺少必要内容诊断")
	_check(newer != null and newer.requires_newer_version, "旧新版本文件保留新版本分类")
	_check(not FileAccess.file_exists(_journal), "聚合刷新不创建迁移记录")


## 记录对象、源路径、当前配置及内容摘要全部绑定刷新时快照，不能以同名或旧菜单转移权限。
func _test_stale_and_forged() -> void:
	var library := _library()
	_ok(library.refresh(_content), "建立旧目录操作快照")
	var entry := _find(library, "good.json", true)
	if entry == null:
		_check(false, "快照中存在旧正常地图")
		return
	var forged := PlayerLevelRecord.new()
	forged.source_path = entry.source_path
	forged.needs_migration = true
	_error(library.get_legacy_migration_source(forged), "伪造同路径对象无法迁移")
	var original_path := entry.source_path
	entry.source_path = _target.path_join("good.json")
	_error(library.get_legacy_migration_source(entry), "篡改旧项路径无法转移迁移权限")
	entry.source_path = original_path
	library.migration_journal = _root.path_join("other_journal.json")
	_error(library.get_legacy_migration_source(entry), "迁移记录配置变更使旧快照失效")
	library.migration_journal = _journal
	var original := FileAccess.get_file_as_string(original_path)
	_write(original_path, original + "\n")
	_error(library.get_legacy_migration_source(entry), "旧文件外部变更拒绝迁移")
	_error(library.get_entry_directory(entry), "旧文件外部变更拒绝使用过期目录菜单")
	_write(original_path, original)
	_ok(library.refresh(_content), "刷新恢复稳定旧文件快照")
	_error(library.get_legacy_migration_source(entry), "刷新后旧记录对象不再有效")


## 用户单条迁移后只隐藏对应旧备份；目标删除或旧源后来改变也不重新显示已完成条目。
func _test_single_migration() -> void:
	var library := _library()
	_ok(library.refresh(_content), "单条迁移前刷新")
	var broken := _find(library, "broken.json", true)
	var source := library.get_legacy_migration_source(broken)
	if not _ok(source, "坏 JSON 同样允许原样迁移"):
		return
	var old_bytes := FileAccess.get_file_as_bytes(broken.source_path)
	var migrated := PlayerLevelMigration.new().migrate_file(_legacy, _target, _journal, source.value.filename, source.value.fingerprint)
	if not _ok(migrated, "仅迁移选中的坏 JSON"):
		return
	var destination: String = migrated.value
	_check(FileAccess.get_file_as_bytes(destination) == old_bytes and FileAccess.get_file_as_bytes(broken.source_path) == old_bytes, "单条复制保持源和目标原始字节")
	_error(library.get_legacy_migration_source(broken), "已经提交迁移的旧菜单不能再次请求迁移")
	_ok(library.refresh(_content), "迁移后聚合刷新")
	_check(_find(library, "broken.json", true) == null and _find(library, destination.get_file(), false) != null, "只移除完成旧备份并显示新目录副本")
	_check(_find(library, "good.json", true) != null and _find(library, "draft.json", true) != null, "未选中的旧地图仍等待单独迁移")
	_check(DirAccess.remove_absolute(destination) == OK, "模拟用户删除新目录已迁移副本")
	_write(_legacy.path_join("broken.json"), "old backup changed")
	_ok(library.refresh(_content), "删除目标后再次刷新")
	_check(_find(library, "broken.json", true) == null and _find(library, destination.get_file(), false) == null, "已完成旧备份不会因目标删除或源修改重新出现")
	var ungranted := _library()
	ungranted.user_directory = ""
	_ok(ungranted.refresh(_content), "未授权新位置仍可只读查看未迁移旧图")
	_check(_find(ungranted, "broken.json", true) == null and _find(ungranted, "good.json", true) != null, "空目标也依据现有迁移记录过滤完成备份")


## 只读刷新不创建目标；非法来源或坏迁移记录明确失败，同时保留已经加载的新目录文件。
func _test_readonly_and_errors() -> void:
	var library := _library()
	library.user_directory = ProjectSettings.globalize_path(_root.path_join("missing/ProgrammableModule/saves"))
	library.migration_journal = _root.path_join("missing_journal.json")
	_ok(library.refresh(_content), "目标目录不存在时仍列出旧候选")
	_check(not DirAccess.dir_exists_absolute(library.user_directory) and not FileAccess.file_exists(library.migration_journal), "只读聚合不创建新目录或日志")
	for unsafe: String in ["res://data/levels", ProjectSettings.globalize_path(_legacy), "user://settings", _root.path_join("settings")]:
		var denied := _library()
		denied.legacy_directory = unsafe
		_error(denied.refresh(_content), "旧来源拒绝不可信目录 " + unsafe)
		_check(_find(denied, "good.json", false) != null, "旧目录拒绝不丢失新目录正常项")
	var bad := _library()
	bad.migration_journal = _root.path_join("bad_journal.json")
	_write(bad.migration_journal, "bad journal")
	_error(bad.refresh(_content), "坏迁移记录报告错误而非猜测完成状态")
	_check(_find(bad, "good.json", false) != null and bad.entries.size() == 1, "坏迁移记录保留新目录项并禁止授权旧项")
	_check(FileAccess.get_file_as_string(bad.migration_journal) == "bad journal", "只读错误检查保留损坏记录原件")


## 文件链接和父目录链接均不能借旧目录展示获得迁移或查看任意外部目标的权限。
func _test_links() -> void:
	var library := _library()
	_ok(library.refresh(_content), "文件替换前建立旧快照")
	var entry := _find(library, "good.json", true)
	var path := _legacy.path_join("good.json")
	var bytes := FileAccess.get_file_as_bytes(path)
	var outside := _root.path_join("protected/map.json")
	_ok(MapCodec.save_file(_map("protected"), outside, _content), "建立被保护链接目标")
	var protected_bytes := FileAccess.get_file_as_bytes(outside)
	DirAccess.remove_absolute(path)
	var folder := DirAccess.open(_legacy)
	var linked := folder.create_link(ProjectSettings.globalize_path(outside), "good.json")
	if linked != OK:
		_write(path, bytes.get_string_from_utf8())
		print("当前平台不支持符号链接，跳过链接专用断言。")
		return
	_error(library.get_legacy_migration_source(entry), "旧文件替换为链接后拒绝迁移")
	_error(library.get_entry_directory(entry), "旧文件替换为链接后拒绝查看目标目录")
	_error(library.refresh(_content), "只读旧目录扫描明确拒绝文件链接")
	_check(FileAccess.get_file_as_bytes(outside) == protected_bytes, "链接目标未改变")
	DirAccess.remove_absolute(path)
	_write(path, bytes.get_string_from_utf8())
	_ok(library.refresh(_content), "恢复普通旧文件")
	entry = _find(library, "good.json", true)
	var moved := _legacy + "_moved"
	_check(DirAccess.rename_absolute(_legacy, moved) == OK, "暂移旧目录进行父链接校验")
	var parent := DirAccess.open(_legacy.get_base_dir())
	if parent.create_link(ProjectSettings.globalize_path(outside.get_base_dir()), "levels") == OK:
		_error(library.get_legacy_migration_source(entry), "父目录替换为链接后拒绝迁移")
		_error(library.get_entry_directory(entry), "父目录替换为链接后拒绝目录菜单")
		_check(FileAccess.get_file_as_bytes(outside) == protected_bytes, "父链接目标仍保持原样")


## 正式类实例仅接受隔离的新旧目录和迁移记录配置。
func _library() -> PlayerLevelLibrary:
	var library := PlayerLevelLibrary.new()
	library.user_directory = _target
	library.legacy_directory = _legacy
	library.migration_journal = _journal
	return library


## 同文件名在新旧目录可同时出现，定位时显式区分迁移状态。
func _find(library: PlayerLevelLibrary, filename: String, legacy: bool) -> PlayerLevelRecord:
	for entry: PlayerLevelRecord in library.entries:
		if entry.source_path.get_file() == filename and entry.needs_migration == legacy:
			return entry
	return null


## 通过真实教学地图构造可玩的独立文件，不复制格式校验实现。
func _map(id: String) -> MapDocument:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content)
	var document: MapDocument = loaded.value.duplicate_document()
	document.id = id
	document.display_name = "测试地图"
	return document


## 特殊内容只写当前独占测试根内的文件。
func _write(path: String, text: String) -> void:
	assert(path.begins_with(_root + "/"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "写入隔离测试文件"):
		file.store_string(text)
		file.close()


## 成功断言附带真实诊断，便于直接定位磁盘或格式异常。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result.is_ok(), message + ": " + "; ".join(result.errors))


## 拒绝分支必须返回错误，不能静默跳过后误报成功。
func _error(result: DataResult, message: String) -> void:
	_check(not result.is_ok(), message)


## 每项检查计入最终退出码，失败不阻断其他独立案例。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 仅递归当前测试根，链接作为自身删除，不跟随到目标目录。
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
