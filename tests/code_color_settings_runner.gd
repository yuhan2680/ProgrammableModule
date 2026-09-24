extends SceneTree
## 代码颜色偏好独立回归：仅操作本次 user://tests 子目录并恢复全局设置。

var _checks: int = 0
var _failures: int = 0
var _changed_count: int = 0
var _test_root: String = ""


## 等待引擎初始化后检查真实配置文件与设置变更通知。
func _initialize() -> void:
	_run.call_deferred()


## 依次验证兼容性、严格校验和写盘失败，结束时恢复音量与语言。
func _run() -> void:
	_test_root = "user://tests/code_color_settings_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var original_db := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	_test_defaults_and_round_trip()
	_test_legacy_and_unknown_fields()
	_test_invalid_inputs_and_public_entries()
	_test_invalid_files()
	_test_save_failure()
	AudioServer.set_bus_volume_db(master, original_db)
	AudioServer.set_bus_mute(master, original_mute)
	TranslationServer.set_locale(original_locale)
	_remove_test_tree(_test_root)
	print("代码颜色设置回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 默认浅色不会创建文件；两种合法模式均按真实字符串写盘并跨实例恢复。
func _test_defaults_and_round_trip() -> void:
	var path := _test_root.path_join("round_trip/settings.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	var before_changes := _changed_count
	_check(settings.load_settings().is_ok(), "缺失配色配置可以使用默认值")
	_check(settings.code_color_mode == "light", "代码颜色默认浅色")
	_check(_changed_count == before_changes + 1, "载入默认设置只通知一次")
	_check(not FileAccess.file_exists(path), "缺失配置读取时不创建磁盘文件")
	_check(settings.set_volume(0.4).is_ok() and settings.set_language("en").is_ok(), "建立独立的音量和语言偏好")
	_check(settings.set_tab_completion(false).is_ok() and settings.set_code_hints("more").is_ok(), "建立独立的补全和提示偏好")
	for mode in ["dark", "light"]:
		before_changes = _changed_count
		_check(settings.set_code_color_mode(mode).is_ok(), "合法配色可以保存：" + mode)
		_check(_changed_count == before_changes + 1, "每次合法配色选择只通知一次")
		var reloaded := GameSettings.new(path)
		_check(reloaded.load_settings().is_ok() and reloaded.code_color_mode == mode, "重新实例化后保留配色：" + mode)
		_check(reloaded.volume == 0.4 and reloaded.language == "en" and not reloaded.tab_completion and reloaded.code_hints == "more", "切换配色保留其他设置")
		var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(saved["format_version"] == 1 and saved["interface"]["code_color_mode"] is String and saved["interface"]["code_color_mode"] == mode, "配色使用版本1的interface字符串字段")


## 旧配置的缺失字段只补内存默认值，后续修改继续保留所有未知扩展。
func _test_legacy_and_unknown_fields() -> void:
	var path := _test_root.path_join("legacy.json")
	var legacy := {
		"format_version": 1,
		"audio": {"master_volume": 0.6, "future_audio": {"device": "保留设备"}},
		"interface": {"language": "en", "tab_completion": false, "code_hints": "none", "future_interface": ["保留字体", 2]},
		"future_root": {"nested": [true, null, "保留"]},
	}
	_write_text(path, JSON.stringify(legacy))
	var before := FileAccess.get_file_as_bytes(path)
	# JSON 数字读回为浮点值；扩展字段应与同样解析后的原文件比较，而非整数字面量。
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.code_color_mode == "light", "旧配置没有颜色字段时使用浅色")
	_check(settings.volume == 0.6 and settings.language == "en" and not settings.tab_completion and settings.code_hints == "none", "旧配置的已有设置照常载入")
	_check(FileAccess.get_file_as_bytes(path) == before, "载入旧配置不自动改写原文件")
	_check(settings.set_code_color_mode("dark").is_ok(), "旧配置可以保存新的深色偏好")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved["future_root"] == original["future_root"], "配色保存保留顶层未知字段")
	_check(saved["audio"]["future_audio"] == original["audio"]["future_audio"] and saved["interface"]["future_interface"] == original["interface"]["future_interface"], "配色保存保留设置分组内未知字段")
	_check(settings.set_volume(0.2).is_ok() and settings.set_language("zh_CN").is_ok() and settings.set_tab_completion(true).is_ok() and settings.set_code_hints("normal").is_ok(), "既有设置入口可以继续修改")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.code_color_mode == "dark", "修改其他偏好不覆盖已保存的代码颜色")


## 非字符串和未知模式不能改内存或文件，所有公开入口均检查完整设置状态。
func _test_invalid_inputs_and_public_entries() -> void:
	var path := _test_root.path_join("invalid_inputs.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	_check(settings.set_code_color_mode("dark").is_ok(), "非法输入测试先保存深色配置")
	var before := FileAccess.get_file_as_bytes(path)
	var before_changes := _changed_count
	for value in [true, false, 0, 1, 0.0, null, [], {}, "", "Dark", "LIGHT", "深色", "auto", "dark ", StringName("dark")]:
		_check(not settings.set_code_color_mode(value).is_ok(), "拒绝非法颜色类型或值：%s" % str(value))
		_check(settings.code_color_mode == "dark" and not settings.last_error.is_empty(), "非法颜色保留当前选择并给出错误")
	_check(_changed_count == before_changes, "非法选择不发出设置变更通知")
	_check(FileAccess.get_file_as_bytes(path) == before, "非法选择不覆盖有效配置")
	# 公开属性被外部写坏时，其他入口也不能把无效配色写回磁盘。
	settings.code_color_mode = "invalid"
	_check(not settings.set_volume(0.2).is_ok() and settings.volume == 1.0, "音量入口验证当前配色后才修改音量")
	_check(not settings.set_language("en").is_ok() and settings.language == "zh_CN", "语言入口验证当前配色后才修改语言")
	_check(not settings.set_tab_completion(false).is_ok() and settings.tab_completion, "补全入口验证当前配色后才修改补全")
	_check(not settings.set_code_hints("none").is_ok() and settings.code_hints == "normal", "提示入口验证当前配色后才修改提示")
	_check(not settings.save_settings().is_ok(), "直接保存也拒绝无效的内存配色")
	_check(_changed_count == before_changes and FileAccess.get_file_as_bytes(path) == before, "完整校验拒绝操作时既不通知也不写盘")
	settings.code_color_mode = "dark"
	settings.volume = -1.0
	_check(not settings.set_code_color_mode("light").is_ok() and settings.code_color_mode == "dark", "配色入口也验证其他设置字段")
	settings.volume = 1.0
	_check(settings.set_code_color_mode("light").is_ok() and settings.last_error.is_empty(), "随后有效选择会清除此前错误")


## 坏颜色字段触发完整默认回退，文件原文和加载通知行为保持可预测。
func _test_invalid_files() -> void:
	var invalid_values: Array = [true, false, 0, 1.5, null, [], {}, "", "Dark", "auto"]
	for index in range(invalid_values.size()):
		var path := _test_root.path_join("invalid_file_%d.json" % index)
		var config := {"format_version": 1, "audio": {"master_volume": 0.2}, "interface": {"language": "en", "tab_completion": false, "code_hints": "more", "code_color_mode": invalid_values[index]}}
		_write_text(path, JSON.stringify(config))
		var before := FileAccess.get_file_as_bytes(path)
		var settings := GameSettings.new(path)
		settings.code_color_mode = "dark"
		settings.changed.connect(_on_changed)
		var before_changes := _changed_count
		_check(not settings.load_settings().is_ok() and not settings.last_error.is_empty(), "坏颜色配置返回读取失败")
		_check(settings.code_color_mode == "light" and settings.volume == 1.0 and settings.language == "zh_CN" and settings.tab_completion and settings.code_hints == "normal", "坏颜色配置使用完整默认值而不部分载入")
		_check(_changed_count == before_changes + 1, "坏配置回退仍只通知一次当前默认设置")
		_check(FileAccess.get_file_as_bytes(path) == before, "坏颜色字段不会导致原文件被改写")


## 真实目录和大小限制失败均反馈错误，保留即时选择且不覆盖已有有效文件。
func _test_save_failure() -> void:
	var blocker := _test_root.path_join("blocked")
	_write_text(blocker, "保留路径占位文件")
	var blocked := GameSettings.new(blocker.path_join("settings.json"))
	blocked.changed.connect(_on_changed)
	var before_changes := _changed_count
	_check(not blocked.set_code_color_mode("dark").is_ok() and not blocked.last_error.is_empty(), "目录无法创建时反馈颜色保存失败")
	_check(blocked.code_color_mode == "dark" and _changed_count == before_changes + 1, "保存失败仍保留即时选择并通知一次")
	_check(FileAccess.get_file_as_string(blocker) == "保留路径占位文件", "失败不会覆盖阻挡路径中的已有文件")
	# 接近上限的紧凑旧文件可正常读取；加入字段与保存缩进后超过上限。
	var path := _test_root.path_join("size_limit.json")
	var compact := {"format_version": 1, "audio": {"master_volume": 0.5}, "interface": {"language": "en"}, "future": ""}
	var base_size := JSON.stringify(compact).to_utf8_buffer().size()
	compact["future"] = "x".repeat(GameSettings.MAX_CONFIG_BYTES - base_size - 1)
	_write_text(path, JSON.stringify(compact))
	var before := FileAccess.get_file_as_bytes(path)
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.code_color_mode == "light", "接近大小上限的旧配置仍可正常载入")
	settings.changed.connect(_on_changed)
	before_changes = _changed_count
	_check(not settings.set_code_color_mode("dark").is_ok() and not settings.last_error.is_empty(), "新增设置导致超限时明确报告保存失败")
	_check(settings.code_color_mode == "dark" and _changed_count == before_changes + 1, "超限保存失败也保留并通知本次配色选择")
	_check(FileAccess.get_file_as_bytes(path) == before, "超限保存失败逐字节保留原有效配置")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.code_color_mode == "light" and reloaded.volume == 0.5 and reloaded.language == "en", "失败后磁盘仍可载入原有配置")


## 统计变更信号以验证一次选择或完整载入只通知一次。
func _on_changed() -> void:
	_changed_count += 1


## 将测试夹具写入本次独占目录，无法创建时记录失败。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "测试夹具可写入独占目录")
	if file != null:
		file.store_string(source)
		file.close()


## 只递归删除当前测试拥有的目录，拒绝清理其他用户路径。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for filename in folder.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in folder.get_directories():
		_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## 累计检查结果，发生失败时保持执行并在结束时返回非零状态。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
