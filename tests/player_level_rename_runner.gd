extends SceneTree
## 玩家关卡重命名与打开目录的模型回归；所有来源和存档均位于独占测试目录。

class FailingCatalog extends LevelCatalog:
	var write_attempts := 0

	## 模拟系统拒绝地图写盘，验证卡片与来源快照不会提前更新。
	func _write_user_level(_document: MapDocument, _path: String, _content: ContentRegistry) -> DataResult:
		write_attempts += 1
		return DataResult.failure("测试：无法写入重命名地图")


var _checks := 0
var _failures := 0
var _test_root := ""
var _content := ContentRegistry.new()


## 延后测试启动，等待项目全局脚本类初始化。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖正常名称往返、对象授权、外部替换、权限失败与目录安全检查。
func _run() -> void:
	_test_root = "user://tests/player_level_rename_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if _ok(_content.load_directories(), "载入真实内容注册表"):
		_test_name_validation()
		_test_roundtrip_and_directory()
		_test_legacy_title()
		_test_invalid_names_and_ownership()
		_test_external_replacement()
		_test_failed_write()
		_test_protected_paths()
	_cleanup(_test_root)
	print("玩家关卡重命名模型回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 验证共享名称规则允许多语言文字和数字，但拒绝粘贴进入的空白、符号、表情及不可见字符。
func _test_name_validation() -> void:
	_check(DataValidation.MAX_PLAYER_NAME_LENGTH == 30 and DataValidation.MAX_EDITOR_CREATOR_LENGTH == 11, "关卡名称限制三十字符，创作者限制十一字符")
	_check("甲".repeat(30).length() == 30 and "𠀀".repeat(30).length() == 30, "普通与增补平面汉字按字符计数，不按字节或UTF16单元计数")
	for value in ["测试003", "Muna_关卡-01", "Échappée", "日本語カタカナ", "탈출", "Απόδραση", "Побег", "Escape१२٣４", "𠀀", "a".repeat(DataValidation.MAX_PLAYER_NAME_LENGTH), "甲".repeat(30), "𠀀".repeat(DataValidation.MAX_PLAYER_NAME_LENGTH)]:
		var result := LevelCatalog.validate_player_level_name(value)
		if _ok(result, "允许多语言文字、十进制数字及规定连接符"):
			_check(result.value == value, "有效名称逐字保留，不做修剪或大小写转换")
	for value in _invalid_names():
		_error(LevelCatalog.validate_player_level_name(value), "共享规则拒绝非法名称：" + value.left(24).c_escape())


## 使用旧版本可读取的空格、符号与表情标题，确认升级后仍可加载并改成合法名称。
func _test_legacy_title() -> void:
	var directory := _test_root.path_join("legacy/levels")
	var path := directory.path_join("legacy.json")
	var document := _map("legacy")
	document.display_name = "旧".repeat(128) + " % 🦈 "
	document.properties.level.creator = "作".repeat(DataValidation.MAX_CREATOR_LENGTH)
	_ok(MapCodec.save_file(document, path, _content), "旧名称仍可保存到兼容地图格式")
	var catalog := _catalog(directory)
	var selected := _find(catalog, "legacy")
	if not _check(selected != null and selected.display_name == document.display_name, "旧名称读取不被新重命名规则过滤"):
		return
	_ok(catalog.rename_user_level(selected, "甲".repeat(30), _content), "旧长名称可以改为恰好三十字符的合法名称")
	_check(selected.id == "legacy" and selected.source_path == path and selected.display_name == "甲".repeat(30), "旧地图更名仍保持身份与位置")
	_check(selected.creator == document.properties.level.creator and selected.creator.length() == 128, "旧署名继续使用格式兼容上限，重命名不截断作者")


## 收集键盘或粘贴可输入的非法边界，包含不可见字符与复合表情，供前后端同规则验证。
func _invalid_names() -> Array[String]:
	return [
		"", " ", " 前缀", "后缀 ", "中间 空格", "\t", "行\n换行", "行\r回车", "不换行 空格", "窄 空格", "全角　空格",
		"百分%比", "斜/线", "反\\斜线", "冒:号", "点.号", "引\"号", "问?号", "星*号", "竖|线", "尖<括>", "逗，号", "圆(括)",
		"鲨鱼🦈", "笑脸☺", "家庭👨‍👩‍👧‍👦", "键帽1️⃣", "旗帜🇨🇳", "信息ℹ", "修饰👍🏽", "选择\uFE0F", "连接\u200D", "零宽\u200B", "方向\u202E", "字节序\uFEFF",
		"填充\u115F", "填充\u1160", "填充\u3164", "填充\uFFA0", "控制" + String.chr(1), "控制" + String.chr(127), "x".repeat(DataValidation.MAX_PLAYER_NAME_LENGTH + 1), "甲".repeat(31), "𠀀".repeat(31), "x".repeat(DataValidation.MAX_TEXT_LENGTH + 1)
	]


## 名称修改保持ID、文件路径、署名、引导、扩展与正式游玩记录，并立即更新目录授权。
func _test_roundtrip_and_directory() -> void:
	var directory := _test_root.path_join("roundtrip/levels")
	var path := directory.path_join("owned.json")
	var document := _map("rename_owned")
	document.properties.level.creator = "Muna"
	document.properties.level.custom = {"version": 3}
	document.properties.custom = ["保留", 4]
	document.extra = {"package": {"nested": true}}
	document.dialogue = [{"text": "# 关卡引导\n保留 **正文**", "format": "markdown", "extension": "keep"}]
	document.cell_extras[document.cells.keys()[0]] = {"custom_tile": [1, 2]}
	_ok(MapCodec.save_file(document, path, _content), "保存完整元数据夹具")
	var other := directory.path_join("other.json")
	var other_document := _map("other")
	other_document.display_name = "新的标题"
	_ok(MapCodec.save_file(other_document, other, _content), "另一张地图允许使用相同标题")
	var export_path := _test_root.path_join("roundtrip/download/owned.json")
	_ok(MapCodec.save_file(document, export_path, _content), "下载原件与托管副本分别保存")
	var record := _test_root.path_join("roundtrip/solutions/rename_owned.json")
	_write_text(record, "{\"completed\":true,\"program\":\"main() {}\",\"assembly\":[]}")
	var protected: Dictionary = {}
	for item: String in [other, export_path, record, "res://data/levels/level_001.json"]:
		protected[item] = FileAccess.get_file_as_bytes(item)
	var original := document.to_dict()
	var catalog := _catalog(directory)
	var selected := _find(catalog, "rename_owned")
	var located := catalog.get_user_level_directory(selected)
	if _ok(located, "当前玩家卡片允许取得所在目录"):
		_check(located.value == ProjectSettings.globalize_path(directory), "目录接口返回真实绝对目录而非文件或外部来源")
	# 卡片快照属于展示数据，外部改动它不应混入重命名写盘。
	selected.document.properties.level.creator = "Injected temporary edit"
	selected.document.extra["unrelated"] = true
	var renamed := catalog.rename_user_level(selected, "新的标题", _content)
	if not _ok(renamed, "重命名保留合法原文并允许与其他地图同名"):
		return
	_check(renamed.value.path == path and renamed.value.level_id == "rename_owned" and renamed.value.name == "新的标题", "成功结果保持原路径和稳定ID")
	_check(selected.id == "rename_owned" and selected.source_path == path and selected.display_name == "新的标题" and selected.document.display_name == "新的标题", "原卡片与文档标题立即同步")
	var loaded := MapCodec.load_file(path, _content)
	if _ok(loaded, "真实磁盘读取新标题"):
		original.name = "新的标题"
		_check(_json_equal(loaded.value.to_dict(), original), "只修改名称，署名、引导与全部扩展字段保持原始磁盘内容")
	_check(selected.creator == "Muna" and selected.document.properties.level.creator == "Muna", "重命名不会写入卡片内存中无关的临时改动")
	for item: String in protected:
		_check(FileAccess.get_file_as_bytes(item) == protected[item], "其他地图、下载原件与正式记录字节保持不变：" + item.get_file())
	_check(DirAccess.get_files_at(directory).size() == 2, "没有更换文件名、新副本或原子写盘残留")
	var unchanged := FileAccess.get_file_as_bytes(path)
	_ok(catalog.rename_user_level(selected, "新的标题", _content), "重复提交相同名称成功且无需改写")
	_check(FileAccess.get_file_as_bytes(path) == unchanged, "相同名称提交完全保留文件字节")
	_ok(catalog.rename_user_level(selected, "再次重命名", _content), "不刷新时也能根据更新后的文件快照再次重命名")
	_ok(catalog.refresh(_content), "重命名后刷新目录")
	selected = _find(catalog, "rename_owned")
	_check(selected != null and selected.display_name == "再次重命名" and selected.source_path == path, "重新载入仍以同一ID和路径显示最新标题")
	_ok(catalog.rename_user_level(selected, "最后标题", _content), "刷新后的对象继续可重命名")
	_ok(catalog.delete_user_level(selected), "重命名成功后文件摘要授权仍支持安全删除")
	_check(not FileAccess.file_exists(path) and FileAccess.file_exists(record), "重命名后删除只删地图，仍不触及同ID记录")


## 空名称、超长名称和非当前目录实际对象均不得改变玩家地图。
func _test_invalid_names_and_ownership() -> void:
	var directory := _test_root.path_join("ownership/levels")
	var path := directory.path_join("owned.json")
	_ok(MapCodec.save_file(_map("owned"), path, _content), "建立授权测试地图")
	var catalog := FailingCatalog.new()
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "加载非法名称测试目录")
	var selected := _find(catalog, "owned")
	var before := FileAccess.get_file_as_bytes(path)
	var original_name := selected.display_name
	var original_document := selected.document.to_dict()
	var record := _test_root.path_join("ownership/solutions/owned.json")
	_write_text(record, "{\"completed\":true,\"program\":\"main() {}\"}")
	var record_bytes := FileAccess.get_file_as_bytes(record)
	for name in _invalid_names():
		_error(catalog.rename_user_level(selected, name, _content), "直接模型调用也拒绝非法名称：" + name.left(24).c_escape())
		_check(catalog.write_attempts == 0 and FileAccess.get_file_as_bytes(path) == before, "非法输入不进入写盘边界且原文件字节不变")
		_check(selected.display_name == original_name and _json_equal(selected.document.to_dict(), original_document), "非法输入保留卡片与文档状态")
		_check(FileAccess.get_file_as_bytes(record) == record_bytes, "非法重命名保留同ID通关与程序记录")
	_error(catalog.rename_user_level(selected, "Valid", null), "缺少内容注册表不能写入重命名")
	for foreign: LevelDefinition in [null, _find(catalog, "level_001")]:
		_error(catalog.rename_user_level(foreign, "Changed", _content), "空对象或内置教学对象不能重命名")
		_error(catalog.get_user_level_directory(foreign), "空对象或教学对象不能通过玩家入口打开目录")
	var forged: LevelDefinition = LevelDefinition.from_document(selected.document, _content, path).value
	catalog.levels.append(forged)
	_error(catalog.rename_user_level(forged, "Forged", _content), "同ID同路径伪造对象没有重命名授权")
	_error(catalog.get_user_level_directory(forged), "手工添加对象也不能获取玩家目录授权")
	catalog.levels.erase(forged)
	for false_path in ["res://data/levels/level_001.json", directory.path_join("../outside.json"), ProjectSettings.globalize_path(path)]:
		selected.source_path = false_path
		_error(catalog.rename_user_level(selected, "Changed", _content), "修改卡片来源路径后不能重命名")
		_error(catalog.get_user_level_directory(selected), "修改来源路径不能打开越界目录")
	selected.source_path = path
	selected.id = "changed_identity"
	_error(catalog.rename_user_level(selected, "Changed", _content), "修改卡片ID后不能重命名")
	selected.id = "owned"
	catalog.user_directory = _test_root.path_join("other/levels")
	_error(catalog.rename_user_level(selected, "Changed", _content), "目录配置改变后旧授权失效")
	_error(catalog.get_user_level_directory(selected), "目录配置改变后不能打开旧目录")
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "刷新重建当前授权")
	_error(catalog.rename_user_level(selected, "Changed", _content), "刷新前对象不能再次操作地图")
	_error(catalog.get_user_level_directory(selected), "刷新前对象不能作为打开目录入口")
	_check(FileAccess.get_file_as_bytes(path) == before, "全部无效请求保留原始地图字节")


## 外部替换即使保留ID也不能被旧卡片覆盖；只读目录查询不依赖内容摘要。
func _test_external_replacement() -> void:
	var directory := _test_root.path_join("replacement/levels")
	var path := directory.path_join("source.json")
	_ok(MapCodec.save_file(_map("replacement"), path, _content), "建立外部替换测试地图")
	var catalog := _catalog(directory)
	var selected := _find(catalog, "replacement")
	var replacement := selected.document.duplicate_document()
	replacement.display_name = "External replacement"
	_ok(MapCodec.save_file(replacement, path, _content), "模拟外部工具修改同ID地图")
	var before := FileAccess.get_file_as_bytes(path)
	_error(catalog.rename_user_level(selected, "OldRename", _content), "旧文件摘要阻止覆盖外部新内容")
	_check(FileAccess.get_file_as_bytes(path) == before and selected.display_name != "OldRename", "过期重命名保留磁盘与卡片原状态")
	_ok(catalog.get_user_level_directory(selected), "仅打开同一实际目录无需拒绝正文已改变的地图")
	_ok(catalog.refresh(_content), "外部变化后重新刷新授权")
	selected = _find(catalog, "replacement")
	_ok(catalog.rename_user_level(selected, "FreshRename", _content), "重新选择刷新后的地图可以重命名")
	_check(DirAccess.remove_absolute(path) == OK, "测试移除独占来源文件")
	_error(catalog.rename_user_level(selected, "Missing", _content), "来源被移除时不重新创建地图")
	_error(catalog.get_user_level_directory(selected), "来源缺失时目录入口明确报错")
	DirAccess.make_dir_recursive_absolute(path)
	_error(catalog.rename_user_level(selected, "Directory", _content), "同名目录不能误作可修改地图")
	_error(catalog.get_user_level_directory(selected), "同名目录不能被当成原玩家文件")
	_check(DirAccess.dir_exists_absolute(path), "失败保留替换后的目录")


## 注入写盘失败时保持文件、标题及快照，允许以后刷新或删除同一原始地图。
func _test_failed_write() -> void:
	var directory := _test_root.path_join("failure/levels")
	var path := directory.path_join("source.json")
	var document := _map("failure")
	document.display_name = "Original"
	_ok(MapCodec.save_file(document, path, _content), "建立写盘失败测试地图")
	var catalog := FailingCatalog.new()
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "加载写盘失败目录")
	var selected := _find(catalog, "failure")
	var original := selected.display_name
	var before := FileAccess.get_file_as_bytes(path)
	_ok(catalog.rename_user_level(selected, original, _content), "合法等值名称成功")
	_check(catalog.write_attempts == 0 and FileAccess.get_file_as_bytes(path) == before, "等值名称不访问写盘边界")
	_error(catalog.rename_user_level(selected, "New_title", _content), "操作系统拒绝写入时返回错误")
	_check(catalog.write_attempts == 1 and FileAccess.get_file_as_bytes(path) == before and selected.display_name == original and selected.document.display_name == original, "失败不提前修改文件、内存标题或文档")
	_ok(catalog.get_user_level_directory(selected), "失败后仍可打开原地图目录")
	_ok(catalog.delete_user_level(selected), "写盘失败后保留原摘要授权，原地图仍可正常删除")


## 非托管目录、文件链接和父目录链接在重命名及只读目录入口处均被拒绝。
func _test_protected_paths() -> void:
	var protected_directory := _test_root.path_join("protected/settings")
	var protected_path := protected_directory.path_join("settings.json")
	_ok(MapCodec.save_file(_map("protected"), protected_path, _content), "建立错误目录配置测试夹具")
	var catalog := _catalog(protected_directory)
	var selected := _find(catalog, "protected")
	var bytes := FileAccess.get_file_as_bytes(protected_path)
	_error(catalog.rename_user_level(selected, "No", _content), "设置目录不能通过玩家关卡入口修改")
	_error(catalog.get_user_level_directory(selected), "设置目录不能伪装成玩家关卡目录")
	_check(FileAccess.get_file_as_bytes(protected_path) == bytes, "受保护目录中的文件保持不变")
	var directory := _test_root.path_join("links/levels")
	var path := directory.path_join("owned.json")
	var external := _test_root.path_join("links/external/source.json")
	_ok(MapCodec.save_file(_map("linked"), path, _content), "建立链接来源地图")
	_ok(MapCodec.save_file(_map("linked"), external, _content), "建立链接外部目标地图")
	var external_bytes := FileAccess.get_file_as_bytes(external)
	catalog = _catalog(directory)
	selected = _find(catalog, "linked")
	DirAccess.remove_absolute(path)
	var folder := DirAccess.open(directory)
	var link_error := folder.create_link(ProjectSettings.globalize_path(external), "owned.json")
	if link_error != OK:
		print("平台不支持测试符号链接，跳过：%s。" % error_string(link_error))
		return
	_error(catalog.rename_user_level(selected, "No", _content), "读取后被换成符号链接的文件不能重命名")
	_error(catalog.get_user_level_directory(selected), "文件链接不能获得玩家目录入口")
	_check(folder.is_link("owned.json") and FileAccess.get_file_as_bytes(external) == external_bytes, "符号链接及外部原件字节保持不变")
	folder.remove("owned.json")
	_ok(MapCodec.save_file(_map("linked"), path, _content), "恢复普通地图文件")
	_ok(catalog.refresh(_content), "刷新恢复地图授权")
	selected = _find(catalog, "linked")
	var moved := directory + "_original"
	_check(DirAccess.rename_absolute(directory, moved) == OK, "临时移走独占地图目录")
	var parent := DirAccess.open(directory.get_base_dir())
	if parent.create_link(ProjectSettings.globalize_path(moved), "levels") == OK:
		_error(catalog.rename_user_level(selected, "No", _content), "父目录被替换为链接时拒绝重命名")
		_error(catalog.get_user_level_directory(selected), "父目录链接不能由打开目录入口跟随")
		_check(FileAccess.get_file_as_bytes(moved.path_join("owned.json")) == FileAccess.get_file_as_bytes(external), "目录链接目标保持原始内容")


## 创建独立目录实例并刷新正式玩家关卡定义。
func _catalog(directory: String) -> LevelCatalog:
	var catalog := LevelCatalog.new()
	catalog.user_directory = directory
	_ok(catalog.refresh(_content), "真实目录加载测试地图")
	return catalog


## 用真实教学资源构造合法地图，覆盖导入后实际使用的数据规则。
func _map(id: String) -> MapDocument:
	var document: MapDocument = MapCodec.load_file("res://data/levels/level_001.json", _content).value
	document.id = id
	document.display_name = "Player_" + id
	return document


## 按稳定ID查找正式目录对象，避免依赖扫描排序。
func _find(catalog: LevelCatalog, id: String) -> LevelDefinition:
	for level: LevelDefinition in catalog.levels:
		if level.id == id:
			return level
	return null


## 按JSON数值语义比较完整地图，忽略整数经过JSON读取后的浮点表示。
func _json_equal(left: Dictionary, right: Dictionary) -> bool:
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))


## 记录夹具仅能写入本次测试独占目录。
func _write_text(path: String, source: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "记录夹具只写独占目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "记录夹具可写入"):
		file.store_string(source)
		file.close()


## 递归清理测试目录，链接只删除本身而不进入外部目标。
func _cleanup(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var name := folder.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if folder.is_link(name) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_cleanup(child)
		name = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 记录成功结果，同时呈现底层错误以定位失败原因。
func _ok(result: DataResult, message: String) -> bool:
	return _check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；没有结果"))


## 失败操作必须返回明确原因和空结果，不能假报修改成功。
func _error(result: DataResult, message: String) -> void:
	_check(result != null and not result.is_ok() and not result.errors.is_empty() and result.value == null, message)


## 汇总全部检查，任意断言失败都会导致测试进程非零退出。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
