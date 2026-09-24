extends SceneTree
## 窗口分辨率持久化回归：只操作独占用户测试目录，不创建或调整系统窗口。

var _checks: int = 0
var _failures: int = 0
var _changed_count: int = 0
var _test_root: String = ""


## 等待引擎完成初始化后检查设置的真实读写与变更通知。
func _initialize() -> void:
	_run.call_deferred()


## 依次验证兼容性、完整校验和失败保护，结束时恢复设置模型触及的全局状态。
func _run() -> void:
	_test_root = "user://tests/window_resolution_settings_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
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
	print("窗口分辨率设置回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 缺少配置时默认 1280×800，全部预设与最大化均能跨实例往返且保留其他偏好。
func _test_defaults_and_round_trip() -> void:
	var path := _test_root.path_join("round_trip/settings.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	var before_changes := _changed_count
	_check(settings.window_resolution == "1280x800", "新实例使用默认 1280×800")
	_check(settings.load_settings().is_ok() and settings.window_resolution == "1280x800", "缺失配置可以使用默认窗口尺寸")
	_check(_changed_count == before_changes + 1, "载入默认设置只通知一次")
	_check(not FileAccess.file_exists(path), "载入缺失配置不创建文件")
	_check(settings.set_volume(0.4).is_ok() and settings.set_language("en").is_ok(), "建立独立音量与语言偏好")
	_check(settings.set_tab_completion(false).is_ok() and settings.set_assembly_free_zoom(true).is_ok(), "建立独立补全与装配缩放偏好")
	_check(settings.set_code_hints("more").is_ok() and settings.set_code_color_mode("dark").is_ok() and settings.set_menu_background("solid").is_ok(), "建立独立提示、配色与背景偏好")
	for resolution in ["1024x640", "1152x720", "1280x800", "1440x900", "1600x1000", "1920x1200", "maximized"]:
		before_changes = _changed_count
		_check(settings.set_window_resolution(resolution).is_ok(), "允许预设或最大化：" + resolution)
		_check(_changed_count == before_changes + 1, "每次合法分辨率选择只通知一次")
		var reloaded := GameSettings.new(path)
		_check(reloaded.load_settings().is_ok() and reloaded.window_resolution == resolution, "分辨率跨实例恢复：" + resolution)
		_check(reloaded.volume == 0.4 and reloaded.language == "en" and not reloaded.tab_completion and reloaded.assembly_free_zoom and reloaded.code_hints == "more" and reloaded.code_color_mode == "dark" and reloaded.menu_background_mode == "solid", "切换分辨率保留全部已有设置")
		var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(saved["format_version"] == 1 and saved["interface"]["window_resolution"] is String and saved["interface"]["window_resolution"] == resolution, "窗口预设写入版本 1 的 interface 字符串字段")


## 旧配置仅补内存默认值，显式保存分辨率后未知扩展字段仍原样保留。
func _test_legacy_and_unknown_fields() -> void:
	var path := _test_root.path_join("legacy.json")
	var legacy := {
		"format_version": 1,
		"audio": {"master_volume": 0.6, "future_audio": {"device": "保留设备"}},
		"interface": {"language": "zh_HK", "tab_completion": false, "assembly_free_zoom": true, "code_hints": "none", "code_color_mode": "dark", "future_interface": ["保留字体", 2]},
		"future_root": {"nested": [true, null, "保留"]},
	}
	_write_text(path, JSON.stringify(legacy))
	var before := FileAccess.get_file_as_bytes(path)
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.window_resolution == "1280x800", "旧配置缺少分辨率字段时使用默认尺寸")
	_check(settings.volume == 0.6 and settings.language == "zh_HK" and not settings.tab_completion and settings.assembly_free_zoom and settings.code_hints == "none" and settings.code_color_mode == "dark", "旧配置已有偏好照常载入")
	_check(FileAccess.get_file_as_bytes(path) == before, "旧配置载入不会自动改写文件")
	_check(settings.set_window_resolution("1600x1000").is_ok(), "旧配置可以保存新的窗口尺寸")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved["future_root"] == original["future_root"], "保存分辨率保留未知顶层扩展")
	_check(saved["audio"]["future_audio"] == original["audio"]["future_audio"] and saved["interface"]["future_interface"] == original["interface"]["future_interface"], "保存分辨率保留未知分组扩展")
	_check(settings.set_volume(0.2).is_ok() and settings.set_language("zh_CN").is_ok() and settings.set_tab_completion(true).is_ok() and settings.set_assembly_free_zoom(false).is_ok() and settings.set_code_hints("normal").is_ok() and settings.set_code_color_mode("light").is_ok() and settings.set_menu_background("solid").is_ok(), "既有设置入口仍可修改")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.window_resolution == "1600x1000", "修改其他偏好不会覆盖已保存分辨率")


## 非字符串和任意尺寸不可入库；其他设置入口也不能绕过已有分辨率状态校验。
func _test_invalid_inputs_and_public_entries() -> void:
	var path := _test_root.path_join("invalid_inputs.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	_check(settings.set_window_resolution("1440x900").is_ok(), "先保存有效窗口预设")
	var before := FileAccess.get_file_as_bytes(path)
	var before_changes := _changed_count
	for value in [true, false, 0, 1280, 1280.0, null, [], {}, Vector2i(1280, 800), "", "1280×800", "1280X800", "1280x720", "1920x1080", "1280x800 ", "MAXIMIZED", "fullscreen", StringName("1280x800")]:
		var result := settings.set_window_resolution(value)
		_check(not result.is_ok(), "拒绝非法尺寸或类型：%s" % str(value))
		_check(settings.window_resolution == "1440x900" and settings.last_error == "窗口分辨率必须为预设尺寸或最大化。", "非法值保留当前分辨率并给出稳定错误")
	_check(_changed_count == before_changes, "非法选择不通知设置变化")
	_check(FileAccess.get_file_as_bytes(path) == before, "非法选择逐字节保留有效配置")
	settings.window_resolution = "invalid"
	_check(not settings.set_volume(0.2).is_ok() and settings.volume == 1.0, "音量入口拒绝已有无效分辨率")
	_check(not settings.set_language("en").is_ok() and settings.language == "zh_CN", "语言入口拒绝已有无效分辨率")
	_check(not settings.set_tab_completion(false).is_ok() and settings.tab_completion, "补全入口拒绝已有无效分辨率")
	_check(not settings.set_assembly_free_zoom(true).is_ok() and not settings.assembly_free_zoom, "装配缩放入口拒绝已有无效分辨率")
	_check(not settings.set_code_hints("none").is_ok() and settings.code_hints == "normal", "代码提示入口拒绝已有无效分辨率")
	_check(not settings.set_code_color_mode("dark").is_ok() and settings.code_color_mode == "light", "配色入口拒绝已有无效分辨率")
	_check(not settings.set_menu_background("solid").is_ok() and settings.menu_background_mode == "default", "背景事务失败时恢复此前背景")
	_check(not settings.save_settings().is_ok(), "直接保存拒绝已有无效分辨率")
	_check(_changed_count == before_changes and FileAccess.get_file_as_bytes(path) == before, "无效内存状态不能通知或覆盖磁盘")
	settings.window_resolution = "1440x900"
	settings.volume = -1.0
	_check(not settings.set_window_resolution("1280x800").is_ok() and settings.window_resolution == "1440x900", "分辨率入口同样验证其他设置字段")
	settings.volume = 1.0
	_check(settings.set_window_resolution("1280x800").is_ok() and settings.last_error.is_empty(), "后续有效选择可以清除旧错误")


## 任一坏分辨率值触发完整默认回退，读取失败不能部分应用其他已解析字段。
func _test_invalid_files() -> void:
	var invalid_values: Array = [true, false, 0, 1.5, null, [], {}, "", "1280x720", "MAXIMIZED", "fullscreen"]
	for index in invalid_values.size():
		var path := _test_root.path_join("invalid_file_%d.json" % index)
		var config := {"format_version": 1, "audio": {"master_volume": 0.2}, "interface": {"language": "en", "tab_completion": false, "assembly_free_zoom": true, "code_hints": "more", "code_color_mode": "dark", "menu_background_mode": "solid", "window_resolution": invalid_values[index]}}
		_write_text(path, JSON.stringify(config))
		var before := FileAccess.get_file_as_bytes(path)
		var settings := GameSettings.new(path)
		settings.window_resolution = "maximized"
		settings.changed.connect(_on_changed)
		var before_changes := _changed_count
		_check(not settings.load_settings().is_ok() and not settings.last_error.is_empty(), "坏分辨率配置明确返回错误")
		_check(settings.window_resolution == "1280x800" and settings.volume == 1.0 and settings.language == "zh_CN" and settings.tab_completion and not settings.assembly_free_zoom and settings.code_hints == "normal" and settings.code_color_mode == "light" and settings.menu_background_mode == "default", "坏字段使整份设置使用默认值")
		_check(_changed_count == before_changes + 1, "坏文件回退后只通知一次")
		_check(FileAccess.get_file_as_bytes(path) == before, "坏配置原文保持不变")
	var background_path := _test_root.path_join("bad_background.json")
	_write_text(background_path, JSON.stringify({"format_version": 1, "audio": {"master_volume": 0.3}, "interface": {"language": "en", "window_resolution": "maximized", "menu_background_mode": "unknown"}}))
	var settings := GameSettings.new(background_path)
	_check(not settings.load_settings().is_ok() and settings.window_resolution == "1280x800", "其他字段损坏也不能部分应用有效窗口预设")


## 目录写入失败和配置超限均保留即时分辨率并通知一次，同时保护原文件。
func _test_save_failure() -> void:
	var blocker := _test_root.path_join("blocked")
	_write_text(blocker, "保留路径占位文件")
	var blocked := GameSettings.new(blocker.path_join("settings.json"))
	blocked.changed.connect(_on_changed)
	var before_changes := _changed_count
	_check(not blocked.set_window_resolution("maximized").is_ok() and not blocked.last_error.is_empty(), "无法创建目录时明确报告保存失败")
	_check(blocked.window_resolution == "maximized" and _changed_count == before_changes + 1, "保存失败仍保留本次最大化选择并通知一次")
	_check(FileAccess.get_file_as_string(blocker) == "保留路径占位文件", "写盘失败不能覆盖路径占位文件")
	var path := _test_root.path_join("size_limit.json")
	var compact := {"format_version": 1, "audio": {"master_volume": 0.5}, "interface": {"language": "en"}, "future": ""}
	var base_size := JSON.stringify(compact).to_utf8_buffer().size()
	compact["future"] = "x".repeat(GameSettings.MAX_CONFIG_BYTES - base_size - 1)
	_write_text(path, JSON.stringify(compact))
	var before := FileAccess.get_file_as_bytes(path)
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.window_resolution == "1280x800", "接近大小上限的旧配置可正常载入")
	settings.changed.connect(_on_changed)
	before_changes = _changed_count
	_check(not settings.set_window_resolution("1920x1200").is_ok() and not settings.last_error.is_empty(), "加入分辨率导致配置超限时返回失败")
	_check(settings.window_resolution == "1920x1200" and _changed_count == before_changes + 1, "超限仍保留并通知本次内存选择")
	_check(FileAccess.get_file_as_bytes(path) == before, "超限写盘失败逐字节保留原配置")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.window_resolution == "1280x800" and reloaded.volume == 0.5 and reloaded.language == "en", "失败后仍能载入磁盘上的原有效设置")


## 累计设置变更信号，验证合法选择和完整载入只通知一次。
func _on_changed() -> void:
	_changed_count += 1


## 将夹具写入本次独占测试目录，无法创建时记录失败。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "测试夹具可写入独占目录")
	if file != null:
		file.store_string(source)
		file.close()


## 只递归清理当前测试拥有的路径，拒绝访问其他用户目录。
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


## 累计所有断言，失败后继续检查并在结束时返回非零状态。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
