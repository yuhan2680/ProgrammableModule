extends SceneTree
## 玩家关卡保存模型的路径、身份、原子失败和扩展数据回归；不访问真实玩家关卡。

class FailingStore extends PlayerLevelStore:
	## 在碰撞处理完成后模拟写盘失败，检查调用方文档与旧文件均未提前改变。
	func _write_document(_document: MapDocument, _path: String, _registry: ContentRegistry) -> DataResult:
		return DataResult.failure("测试：无法写入托管关卡")


class SequenceStore extends PlayerLevelStore:
	var candidates: Array[String] = []
	var draws: int = 0
	var read_sources: Array[String] = []
	var read_results: Dictionary = {}

	## 只替换采样值，仍由正式分配逻辑读取磁盘、检查格式与处理碰撞。
	func _random_map_id() -> String:
		var index := mini(draws, candidates.size() - 1)
		draws += 1
		return candidates[index] if index >= 0 else ""

	## 记录真实扫描结果而不替换数据，让用例核对两个内置目录和玩家目录均参与分配。
	func _read_ids(path: String, excluded_path: String, builtin: bool) -> DataResult:
		read_sources.append(path)
		var result := super._read_ids(path, excluded_path, builtin)
		if result.is_ok():
			read_results[path] = result.value.duplicate()
		return result


class FailingSequenceStore extends SequenceStore:
	var attempted_document: MapDocument
	var attempted_path: String = ""

	## 记录真实去重后的独立候选文档，再模拟失败，检查它从未提交给调用方或磁盘。
	func _write_document(document: MapDocument, path: String, _registry: ContentRegistry) -> DataResult:
		attempted_document = document
		attempted_path = path
		return DataResult.failure("测试：随机副本写盘失败")


var _checks: int = 0
var _failures: int = 0
var _test_root: String = ""
var _content := ContentRegistry.new()


## 等待脚本注册完成后开始独立模型回归。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖保存生命周期与危险路径，统一清理本次独占目录并返回失败数。
func _run() -> void:
	_test_root = "user://tests/player_level_store_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var previous_issued_ids := PlayerLevelStore._issued_map_ids.duplicate()
	PlayerLevelStore._issued_map_ids.clear()
	_ok(_content.load_directories(), "读取真实模块和地块")
	_test_generated_id_format()
	_test_generated_id_collisions()
	_test_generated_id_exhaustion()
	_test_generated_first_save()
	_test_generated_import_copies()
	_test_generated_failure_preserves_state()
	_test_first_save_and_update()
	_test_unique_copies()
	_test_external_and_builtin_sources()
	_test_malformed_collisions()
	_test_hidden_source()
	_test_failure_preserves_state()
	_test_unsafe_paths_and_links()
	_cleanup(_test_root)
	PlayerLevelStore._issued_map_ids = previous_issued_ids
	print("玩家关卡保存模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 固定输入验证十位 ASCII 数字边界；前导零与重复数字不依赖随机命中概率。
func _test_generated_id_format() -> void:
	for map_id: String in ["map_0000000000", "map_0111100000", "map_7777777777", "map_9999999999"]:
		_check(_generated_pattern(map_id) and PlayerLevelStore.is_generated_map_id(map_id), "新 ID 允许前导零及重复数字：" + map_id)
		var store := _sequence_store("format_" + map_id, [map_id])
		var created := store.create_map_id()
		if _ok(created, "确定性采样分配合法 ID：" + map_id):
			_check(created.value == map_id and store.draws == 1, "合法采样立即保留原十位数字")
		_check(not DirAccess.dir_exists_absolute(store.directory.get_base_dir()), "创建 ID 不生成玩家目录或 JSON")
	for invalid: String in ["map_123456789", "map_12345678901", "Map_0123456789", "map_０１２３４５６７８９", "map_012345678a", "map_0123456789_2", "legacy"]:
		_check(not PlayerLevelStore.is_generated_map_id(invalid), "拒绝非十位 ASCII 数字的新 ID：" + invalid)
	var retry := _sequence_store("invalid_draw", ["map_０１２３４５６７８９", "map_0123456789_2", "map_1000000001"])
	var result := retry.create_map_id()
	if _ok(result, "错误格式采样后继续抽取合法候选"):
		_check(result.value == "map_1000000001" and retry.draws == 3, "错误格式不能作为成功 ID 返回")


## 真正读取文件内容而非文件名，坏结构、隐藏和 BOM 的顶层合法 ID 都参与碰撞重试。
func _test_generated_id_collisions() -> void:
	var issued := _sequence_store("issued_elsewhere", ["map_0606060606"])
	_ok(issued.create_map_id(), "另一存储实例预先分配尚未保存的 ID")
	var store := _sequence_store("new_collisions", ["map_0101010101", "map_0202020202", "map_0303030303", "map_0404040404", "map_0505050505", "map_0606060606", "map_0707070707"])
	_ok(MapCodec.save_file(_map("map_0101010101"), store.directory.path_join("unrelated_filename.JSON"), _content), "文件名无关的地图提供真实 JSON ID")
	_write_text(store.directory.path_join(".hidden.JSON"), "{\"id\":\"map_0202020202\"}")
	_write_text(store.directory.path_join("with_bom.json"), "\ufeff{\"id\":\"map_0303030303\"}")
	_write_text(store.directory.path_join("malformed_map.json"), "{\"id\":\"map_0404040404\",\"width\":\"invalid\",\"cells\":false}")
	_write_text(store.directory.path_join("broken.json"), "{broken syntax")
	var before := _snapshot(store.directory)
	var extra_ids := {"map_0505050505": true}
	var created := store.create_map_id(extra_ids)
	if _ok(created, "磁盘、附加占位及进程已分配 ID 连续冲突后成功"):
		_check(created.value == "map_0707070707" and store.draws == 7, "每个真实占位均重试，不使用文件名或顺序后缀")
	_check(store.read_sources == ["res://data/maps", "res://data/levels", store.directory], "分配读取两个实际内置目录及当前玩家目录")
	var maps: Dictionary = store.read_results.get("res://data/maps", {})
	var levels: Dictionary = store.read_results.get("res://data/levels", {})
	_check(maps.has("movement_lab") and levels.has("level_001") and levels.has("level_016"), "实际内置 JSON 中的地图及首尾教学 ID 被读取")
	var player_ids: Dictionary = store.read_results.get(store.directory, {})
	for occupied: String in ["map_0101010101", "map_0202020202", "map_0303030303", "map_0404040404"]:
		_check(player_ids.has(occupied), "真实玩家文件内容保留 ID 占位：" + occupied)
	_check(_snapshot(store.directory) == before and extra_ids == {"map_0505050505": true}, "创建仅分配身份，既有文件及附加占位字典逐字节不变")
	_check(not DirAccess.dir_exists_absolute(issued.directory.get_base_dir()), "未保存 ID 的跨实例去重不需要创建磁盘目录")


## 每次采样均冲突时在明确上限结束；失败不返回空成功结果或创建任何文件。
func _test_generated_id_exhaustion() -> void:
	var store := _sequence_store("exhaustion", ["map_0808080808"])
	var exhausted := store.create_map_id({"map_0808080808": true})
	_error(exhausted, "抽取上限耗尽返回可显示的明确失败")
	_check(store.draws == PlayerLevelStore.MAX_CANDIDATES, "持续碰撞严格受限，不无限重试")
	_check(exhausted.value == null and not PlayerLevelStore._issued_map_ids.has("map_0808080808"), "失败不发布或占用被拒绝候选")
	_check(not DirAccess.dir_exists_absolute(store.directory.get_base_dir()), "分配失败不创建目录或地图")
	store.candidates = ["map_0909090909"]
	var recovered := store.create_map_id()
	if _ok(recovered, "同一存储实例失败后可再次分配"):
		_check(recovered.value == "map_0909090909", "后续合法采样正常成功")
	var saving := _sequence_store("copy_exhaustion", ["map_1818181818"])
	_ok(MapCodec.save_file(_map("map_1818181818"), saving.directory.path_join("original.json"), _content), "建立持续占用随机副本 ID 的真实地图")
	var draft := _map("map_1818181818")
	var draft_before := draft.to_dict()
	var disk_before := _snapshot(saving.directory)
	var failed_save := saving.save(draft, _content)
	_error(failed_save, "随机副本保存抽取耗尽也返回明确失败")
	_check(saving.draws == PlayerLevelStore.MAX_CANDIDATES and failed_save.value == null, "保存冲突同样有界且不返回候选文档")
	_check(draft.to_dict() == draft_before and _snapshot(saving.directory) == disk_before, "抽取耗尽保留来源内存和全部原地图")


## 首次保存固定新建时的身份；只有文件名被占时调整路径，后续绑定仍使用同一文件。
func _test_generated_first_save() -> void:
	var store := _sequence_store("generated_first", ["map_1111111111"])
	var created := store.create_map_id()
	if not _ok(created, "新地图先分配 ID 再建立草稿"):
		return
	var draft := _map(created.value)
	var before := draft.to_dict()
	var occupied := store.directory.path_join("player_" + draft.id + ".json")
	_write_text(occupied, "existing broken file")
	var occupied_bytes := FileAccess.get_file_as_bytes(occupied)
	var saved := store.save(draft, _content, "", true)
	if not _ok(saved, "首存遇到同名坏 JSON 时仍能保留新建 ID"):
		return
	_check(saved.value.document.id == created.value and draft.to_dict() == before, "首存结果及输入保持首次分配的 ID")
	_check(saved.value.path.get_file() == "player_map_1111111111_2.json", "仅文件名追加后缀，JSON 身份仍为十位数字")
	_check(_generated_pattern(saved.value.document.id) and store.draws == 1, "文件名冲突不触发再次随机分配")
	_check(FileAccess.get_file_as_bytes(occupied) == occupied_bytes, "同名坏 JSON 原件未被覆盖")
	var loaded := MapCodec.load_file(saved.value.path, _content, false)
	if _ok(loaded, "重读首存 JSON 核对持久身份"):
		_check(loaded.value.id == created.value, "落盘 JSON 与最初草稿身份一致")
	saved.value.document.display_name = "Repeated generated save"
	var again := store.save(saved.value.document, _content, saved.value.path, true)
	if _ok(again, "新建地图首存之后按原绑定更新"):
		_check(again.value.path == saved.value.path and again.value.document.id == created.value and _file_count(store.directory) == 2, "重复保存稳定身份和绑定，不增加副本")


## 重复导入十位格式地图通过真实导入校验及写盘，副本重新采样且原件始终只读。
func _test_generated_import_copies() -> void:
	var source := _test_root.path_join("generated_import_source/original.json")
	_ok(MapCodec.save_file(_map("map_1212121212"), source, _content), "建立带十位 ID 的独立外部地图")
	var source_bytes := FileAccess.get_file_as_bytes(source)
	var store := _sequence_store("generated_import", ["map_1212121212", "map_1313131313", "map_1313131313", "map_1414141414"])
	var first := store.import_file(source, _content)
	var second := store.import_file(source, _content)
	var third := store.import_file(source, _content)
	if not _ok(first, "十位格式地图首次导入") or not _ok(second, "同地图第二次导入") or not _ok(third, "同地图第三次导入"):
		return
	_check(first.value.document.id == "map_1212121212" and second.value.document.id == "map_1313131313" and third.value.document.id == "map_1414141414", "重复导入重新随机分配并避开已有副本")
	_check(store.draws == 4, "副本采样避开来源与上一张副本的实际 ID")
	var seen: Dictionary = {}
	for saved: DataResult in [first, second, third]:
		var document: MapDocument = saved.value.document
		_check(_generated_pattern(document.id) and not seen.has(document.id), "每张导入副本均有独立的十位格式 ID")
		seen[document.id] = true
		var loaded := MapCodec.load_file(saved.value.path, _content, true)
		if _ok(loaded, "重新读取可玩的导入副本"):
			_check(loaded.value.id == document.id, "导入副本磁盘身份与成功结果一致")
	_check(_file_count(store.directory) == 3 and FileAccess.get_file_as_bytes(source) == source_bytes, "三次导入创建三张地图且外部原件字节不变")
	var catalog := LevelCatalog.new()
	catalog.user_directory = store.directory
	_ok(catalog.refresh(_content), "正式目录读取全部新格式导入副本")
	_check(catalog.levels.size() == 19, "三张新格式玩家地图及原十六张教学全部保留")


## 新建 ID 被其他文件抢占或随机副本写盘失败，均保留原草稿及完整磁盘状态。
func _test_generated_failure_preserves_state() -> void:
	var store := _sequence_store("generated_failure", ["map_1515151515"])
	var created := store.create_map_id()
	if not _ok(created, "先为失败验证分配未保存身份"):
		return
	var draft := _map(created.value)
	var draft_before := draft.to_dict()
	_ok(MapCodec.save_file(_map(created.value), store.directory.path_join("occupied_by_other.json"), _content), "另一地图在首存前占用新建 ID")
	var disk_before := _snapshot(store.directory)
	var rejected := store.save(draft, _content, "", true)
	_error(rejected, "保留身份的首存碰撞明确拒绝")
	_check(draft.to_dict() == draft_before and _snapshot(store.directory) == disk_before and store.draws == 1, "拒绝首存不改草稿、既有文件或随机身份")
	var failing := FailingSequenceStore.new()
	failing.directory = store.directory
	failing.candidates = ["map_1616161616"]
	var failed := failing.save(draft, _content)
	_error(failed, "随机去重后的写盘失败明确返回")
	_check(failing.attempted_document != null and failing.attempted_document != draft and failing.attempted_document.id == "map_1616161616", "写盘前只构造独立随机候选，未提前覆盖输入身份")
	_check(failed.value == null and draft.to_dict() == draft_before and _snapshot(store.directory) == disk_before, "写盘失败不返回候选保存点或改动内存与磁盘")
	_check(not FileAccess.file_exists(failing.attempted_path), "失败不留下随机候选 JSON 文件")
	var bound := store.save(_map("map_1717171717"), _content, "", true)
	if not _ok(bound, "建立另一个可更新的十位 ID 托管地图"):
		return
	var bound_draft: MapDocument = bound.value.document
	bound_draft.id = created.value
	bound_draft.display_name = "Pending failed rename"
	var bound_before := bound_draft.to_dict()
	disk_before = _snapshot(store.directory)
	_error(store.save(bound_draft, _content, bound.value.path, true), "绑定保存也拒绝其他地图已经使用的 ID")
	_check(bound_draft.to_dict() == bound_before and _snapshot(store.directory) == disk_before, "绑定碰撞失败保留待编辑对象和旧文件字节")
	failing.candidates = ["map_1919191919"]
	failing.draws = 0
	var failed_update := failing.save(bound_draft, _content, bound.value.path)
	_error(failed_update, "绑定更新随机去重后写盘失败仍返回明确错误")
	_check(failing.attempted_document.id == "map_1919191919" and failing.attempted_path == bound.value.path, "失败更新计算新的随机候选并沿用原绑定")
	_check(failed_update.value == null and bound_draft.to_dict() == bound_before and _snapshot(store.directory) == disk_before, "绑定写盘失败不提交随机 ID，也不覆盖任何原文件")


## 首次无路径保存直接创建托管草稿，后续绑定保存原位更新并保留全部未知字段。
func _test_first_save_and_update() -> void:
	var store := _store("first")
	var draft := MapDocument.new()
	draft.extra = {"author": {"version": 9, "notes": ["keep"]}}
	draft.set_tile(Vector2i(1, 1), "floor")
	draft.cell_extras[Vector2i(1, 1)] = {"custom_tile": [1, {"keep": true}]}
	draft.properties = {"custom": {"nested": [4, 5]}}
	var before := draft.to_dict()
	var saved := store.save(draft, _content)
	if not _ok(saved, "没有出生点的首次保存也成功"):
		return
	var path: String = saved.value.path
	var persisted: MapDocument = saved.value.document
	_check(path.get_base_dir() == store.directory and path.get_extension() == "json", "自动写入直接托管 JSON")
	_check(draft.to_dict() == before and persisted != draft, "保存使用独立文档且不修改输入")
	_check(persisted.id == "untitled", "没有冲突时保持地图 ID")
	var loaded := MapCodec.load_file(path, _content, false)
	if _ok(loaded, "草稿可重新载入"):
		# JSON 读取把未知数字转换为浮点数，比较同一 JSON 数值语义而非 GDScript 容器类型。
		_check(JSON.parse_string(JSON.stringify(loaded.value.to_dict())) == JSON.parse_string(JSON.stringify(before)), "顶层、属性与格子未知数据完整往返")
	persisted.display_name = "Updated map"
	persisted.id = "changed_id"
	var updated := store.save(persisted, _content, ProjectSettings.globalize_path(path))
	if _ok(updated, "系统绝对路径绑定允许原位更新及修改 ID"):
		_check(updated.value.path == path and updated.value.document.id == "changed_id", "更新不迁移旧文件也不额外生成副本")
		_check(MapCodec.load_file(path, _content, false).value.display_name == "Updated map", "磁盘读取更新后的名称")
		_check(_file_count(store.directory) == 1, "重复保存只有一张文件")
	_check(store.managed_path(path) == path and store.managed_path(ProjectSettings.globalize_path(path)) == path, "绑定路径统一为 user://")
	_check(store.managed_path(store.directory.path_join("nested/map.json")).is_empty(), "嵌套文件不能绑定直接目录")


## 未绑定的新文档即使 ID 相同也分别保存，重复 ID、文件名与最大长度均有确定性后缀。
func _test_unique_copies() -> void:
	var store := _store("copies")
	var first := store.save(_map("untitled"), _content)
	var second := store.save(_map("untitled"), _content)
	if not _ok(first, "第一张未命名地图成功") or not _ok(second, "第二张未命名地图成功"):
		return
	_check(first.value.path != second.value.path and second.value.document.id == "untitled_2", "新地图获得独立文件与可见 ID")
	var first_bytes := FileAccess.get_file_as_bytes(first.value.path)
	var again := store.save(second.value.document, _content, second.value.path)
	if _ok(again, "已去重文档重复保存成功"):
		_check(again.value.path == second.value.path and again.value.document.id == "untitled_2", "重复保存不不断增加后缀")
	_check(FileAccess.get_file_as_bytes(first.value.path) == first_bytes, "其他未命名地图字节未变")
	var long_id := "a".repeat(128)
	var long_first := store.save(_map(long_id), _content)
	var long_second := store.save(_map(long_id), _content)
	if _ok(long_first, "最大长度 ID 首次保存") and _ok(long_second, "最大长度 ID 冲突后仍保存"):
		_check(long_second.value.document.id.length() == 128 and long_second.value.document.id.ends_with("_2"), "去重后 ID 仍符合长度限制")
	var catalog := LevelCatalog.new()
	catalog.user_directory = store.directory
	_ok(catalog.refresh(_content), "保存结果可被正式目录扫描")
	_check(catalog.levels.size() == 20, "四张有效玩家关卡全部可见且十六张内置保留")


## 内置和外部来源都只生成托管副本；恢复 prior 绑定后更新自身，导出原件不被普通保存改写。
func _test_external_and_builtin_sources() -> void:
	var store := _store("sources")
	var builtin_path := "res://data/levels/level_001.json"
	var builtin_bytes := FileAccess.get_file_as_bytes(builtin_path)
	var source := MapCodec.load_file(builtin_path, _content, false)
	if not _ok(source, "读取内置来源"):
		return
	var saved := store.save(source.value, _content, builtin_path)
	if not _ok(saved, "内置来源自动保存为托管副本"):
		return
	_check(saved.value.document.id == "level_001_2" and source.value.id == "level_001", "副本避免内置 ID 冲突，来源内存不变")
	_check(FileAccess.get_file_as_bytes(builtin_path) == builtin_bytes, "内置地图保持字节不变")
	var external := _test_root.path_join("original/source.json")
	_ok(MapCodec.save_file(_map("external"), external, _content), "建立隔离的外部地图原件")
	var external_bytes := FileAccess.get_file_as_bytes(external)
	var copied := store.save(_map("external"), _content, ProjectSettings.globalize_path(external))
	if not _ok(copied, "外部路径只作为来源，普通保存建立托管文件"):
		return
	_check(copied.value.path != external and copied.value.document.id == "external", "外部副本保持没有冲突的 ID")
	copied.value.document.display_name = "Edit after export"
	_ok(store.save(copied.value.document, _content, copied.value.path), "导出之后仍可使用原托管绑定")
	_check(FileAccess.get_file_as_bytes(external) == external_bytes, "外部原件与导出目标保持字节不变")
	var bound_builtin_id: MapDocument = saved.value.document
	bound_builtin_id.id = "level_002"
	var renamed := store.save(bound_builtin_id, _content, saved.value.path)
	if _ok(renamed, "绑定文档手工改成内置 ID 后仍可安全保存"):
		_check(renamed.value.path == saved.value.path and renamed.value.document.id == "level_002_2", "路径绑定保留且 ID 再次避开内置")


## 坏语法、坏结构、隐藏 JSON 与目录同名都不能被覆盖，有效顶层 ID 继续占位。
func _test_malformed_collisions() -> void:
	var store := _store("malformed")
	_write_text(store.directory.path_join("player_collide.json"), "{broken")
	_write_text(store.directory.path_join("invalid_structure.json"), "{\"id\":\"collide\",\"invalid\":true}")
	_write_text(store.directory.path_join(".hidden.JSON"), "{\"id\":\"collide_2\"}")
	_write_text(store.directory.path_join("with_bom.json"), "\ufeff{\"id\":\"collide_3\"}")
	_write_text(store.directory.path_join("player_collide_4.json"), "keep malformed filename")
	DirAccess.make_dir_recursive_absolute(store.directory.path_join("player_collide_4_2.json"))
	var before := _snapshot(store.directory)
	var saved := store.save(_map("collide"), _content)
	if _ok(saved, "已有坏地图不会阻止保存独立新地图"):
		_check(saved.value.document.id == "collide_4", "坏结构、隐藏和 BOM 地图中的合法 ID 都占位")
		_check(saved.value.path.ends_with("player_collide_4_3.json"), "文件及目录同名均使用下一个空闲文件名")
	for filename in before:
		_check(FileAccess.get_file_as_bytes(store.directory.path_join(filename)) == before[filename], "已有坏文件逐字节保持原样")
	var dot_saved := store.save(_map(".special"), _content)
	if _ok(dot_saved, "以点开头的合法 ID 可保存"):
		_check(not dot_saved.value.path.get_file().begins_with("."), "自动文件名始终可被关卡目录发现")


## 已打开的隐藏托管来源不绑定原位保存，普通保存创建可见副本并保留原件。
func _test_hidden_source() -> void:
	var store := _store("hidden_source")
	var hidden_path := store.directory.path_join(".hidden.json")
	var document := _map("hidden_level")
	_ok(MapCodec.save_file(document, hidden_path, _content), "建立位于托管目录的有效隐藏地图")
	var original_bytes := FileAccess.get_file_as_bytes(hidden_path)
	_check(store.managed_path(hidden_path).is_empty() and store.managed_path(ProjectSettings.globalize_path(hidden_path)).is_empty(), "资源与绝对路径的隐藏地图都不建立普通保存绑定")
	var before := document.to_dict()
	var saved := store.save(document, _content, hidden_path)
	if not _ok(saved, "隐藏来源的普通保存生成可见玩家副本"):
		return
	_check(saved.value.path.get_base_dir() == store.directory and saved.value.path.get_file().begins_with("player_"), "新副本使用可被目录扫描的直接文件名")
	_check(saved.value.document.id == "hidden_level_2" and document.to_dict() == before, "新副本避开隐藏原件 ID 且不修改输入")
	_check(FileAccess.get_file_as_bytes(hidden_path) == original_bytes, "隐藏来源保持原始字节")
	var catalog := LevelCatalog.new()
	catalog.user_directory = store.directory
	_ok(catalog.refresh(_content), "真实关卡目录能够读取隐藏来源的新副本")
	_check(catalog.levels.size() == 17 and catalog.levels[-1].id == "hidden_level_2" and catalog.levels[-1].source_path == saved.value.path, "普通保存后玩家入口可见且隐藏原件仍不显示")
	var updated := store.save(saved.value.document, _content, saved.value.path)
	if _ok(updated, "可见副本之后按正常托管绑定更新"):
		_check(updated.value.path == saved.value.path and updated.value.document.id == "hidden_level_2", "重复保存复用可见副本和稳定 ID")


## 校验和写盘失败保留旧文件、输入对象及 ID；目录不可写时不能伪报成功。
func _test_failure_preserves_state() -> void:
	var store := _store("failure")
	var saved := store.save(_map("good"), _content)
	if not _ok(saved, "建立供失败验证的原地图"):
		return
	var path: String = saved.value.path
	var bytes := FileAccess.get_file_as_bytes(path)
	var invalid: MapDocument = saved.value.document
	invalid.width = 0
	_error(store.save(invalid, _content, path), "无效地图拒绝保存")
	_check(FileAccess.get_file_as_bytes(path) == bytes and invalid.width == 0, "失败不覆盖有效旧文件或修补输入")
	var failing := FailingStore.new()
	failing.directory = store.directory
	var candidate := _map("level_001")
	var before := candidate.to_dict()
	_error(failing.save(candidate, _content, path), "碰撞处理后写盘失败被明确返回")
	_check(candidate.to_dict() == before and FileAccess.get_file_as_bytes(path) == bytes, "失败不把去重 ID 写回输入或改变原字节")
	_write_text(_test_root.path_join("blocked"), "preserve blocker")
	store.directory = _test_root.path_join("blocked/levels")
	_error(store.save(_map("blocked"), _content), "父目录被文件占用时失败")
	_check(FileAccess.get_file_as_string(_test_root.path_join("blocked")) == "preserve blocker", "目录占位原件未被修改")


## 不允许上级路径、资源目录或链接逃出托管范围，所有目标及原地图保持原位。
func _test_unsafe_paths_and_links() -> void:
	var store := PlayerLevelStore.new()
	for path in ["res://data/levels", "user://", "user://levels/../solutions", _test_root.path_join("bad\\levels")]:
		store.directory = path
		_error(store.save(_map("unsafe"), _content), "危险目录拒绝保存：" + path)
	store = _store("links")
	var saved := store.save(_map("safe"), _content)
	if not _ok(saved, "建立链接用例独立目录"):
		return
	var before := _snapshot(store.directory)
	_error(store.save(_map("unsafe"), _content, store.directory.path_join("../escape.json")), "传入绑定包含上级路径时拒绝")
	var target := _test_root.path_join("link_target/original.json")
	_write_text(target, "protected outside target")
	var folder := DirAccess.open(store.directory)
	var link_error := folder.create_link(ProjectSettings.globalize_path(target), "linked.json")
	if link_error != OK:
		print("平台不支持测试符号链接，跳过：%s。" % error_string(link_error))
		return
	_error(store.save(_map("safe"), _content, store.directory.path_join("linked.json")), "已绑定 JSON 链接不能覆盖目标")
	_error(store.save(_map("safe"), _content), "ID 扫描也不跟随其它 JSON 链接")
	_check(folder.is_link("linked.json") and FileAccess.get_file_as_string(target) == "protected outside target", "外部目标与链接均保留")
	folder.remove("linked.json")
	_check(_snapshot(store.directory) == before, "失败没有留下额外地图、临时文件或备份")
	var parent := DirAccess.open(store.directory.get_base_dir())
	if parent.create_link(ProjectSettings.globalize_path(store.directory), "linked_levels") == OK:
		store.directory = store.directory.get_base_dir().path_join("linked_levels")
		_error(store.save(_map("unsafe"), _content), "托管目录的链接不能被遍历")


## 为每个用例提供独占的托管目录，不改变真实 user://levels。
func _store(relative: String) -> PlayerLevelStore:
	var result := PlayerLevelStore.new()
	result.directory = _test_root.path_join(relative).path_join("levels")
	return result


## 为采样替身使用同样隔离目录，磁盘扫描、保存和导入仍调用正式实现。
func _sequence_store(relative: String, candidates: Array[String]) -> SequenceStore:
	var result := SequenceStore.new()
	result.directory = _test_root.path_join(relative).path_join("levels")
	result.candidates = candidates.duplicate()
	return result


## 使用独立正则核对外部契约，避免成功断言只复用被测格式判断函数。
func _generated_pattern(map_id: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^map_[0-9]{10}$")
	return pattern.search(map_id) != null


## 由真实关卡生成可被正式关卡目录发现的地图，不伪造注册表或运行规则。
func _map(map_id: String) -> MapDocument:
	var result := MapCodec.load_file("res://data/levels/level_001.json", _content, false)
	var document: MapDocument = result.value
	document.id = map_id
	document.display_name = "Custom " + map_id
	return document


## 枚举当前直接文件数，确保重复保存不堆积副本或原子写盘残留。
func _file_count(path: String) -> int:
	return DirAccess.open(path).get_files().size()


## 读取全部直接文件的字节快照，包括隐藏 JSON；调用方确保目录中没有链接。
func _snapshot(path: String) -> Dictionary:
	var result: Dictionary = {}
	var folder := DirAccess.open(path)
	folder.include_hidden = true
	for filename in folder.get_files():
		result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 辅助坏文件仅允许写入本次测试根下。
func _write_text(path: String, source: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "测试写入限制在独占目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "测试原件可写入"):
		file.store_string(source)
		file.close()


## 递归清理独占测试目录，只删除链接本身，绝不进入外部链接目标。
func _cleanup(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var filename := folder.get_next()
	while not filename.is_empty():
		var child := path.path_join(filename)
		if folder.is_link(filename) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 将成功结果与明确底层错误一起记录，必要时由调用方停止后续依赖步骤。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；没有结果"))


## 失败路径必须提供明确原因，不能以空返回值掩盖失败。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty(), message)


## 统计全部独立断言，保证任何失败都会产生非零退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
