extends SceneTree
## 菜单背景设置回归仅操作本次隔离目录，验证真实图片副本和配置事务。

class SaveFailureSettings extends GameSettings:
	var fail_save: bool = false

	## 模拟配置提交失败，验证图片事务不会改坏现有配置和副本。
	func save_settings() -> DataResult:
		if fail_save:
			return _remember_result(DataResult.failure("测试模拟设置保存失败。"))
		return super.save_settings()

var _checks: int = 0
var _failures: int = 0
var _changes: int = 0
var _test_root: String = ""
var _source: String = ""


## 延迟到引擎初始化完成后运行，所有路径均注入独立测试目录。
func _initialize() -> void:
	_run.call_deferred()


## 保存并恢复全局音量语言，测试结束后仅清理本轮生成的文件。
func _run() -> void:
	_test_root = "user://tests/menu_background_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_source = _test_root.path_join("source/原始 图片.png")
	var original_locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var original_db := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	_make_source(_source)
	_test_legacy_and_unknown_fields()
	_test_import_choose_restart_remove()
	_test_invalid_input_and_missing_files()
	_test_save_failure_rollback()
	_test_path_and_symlink_safety()
	_test_common_image_formats()
	AudioServer.set_bus_volume_db(master, original_db)
	AudioServer.set_bus_mute(master, original_mute)
	TranslationServer.set_locale(original_locale)
	_remove_test_tree(_test_root)
	print("菜单背景设置回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 旧配置默认保留原图片模式且不会自动迁移，后续保存保留所有未知分组。
func _test_legacy_and_unknown_fields() -> void:
	var path := _test_root.path_join("legacy/settings.json")
	var legacy := {"format_version": 1, "audio": {"master_volume": 0.3, "future_audio": [1, true]}, "interface": {"language": "en", "code_color_mode": "dark", "future_interface": {"theme": "retain"}}, "future_root": {"keep": true}}
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.menu_background_mode == "default" and settings.custom_backgrounds.is_empty(), "缺失配置使用默认背景与空自定义列表")
	_check(not FileAccess.file_exists(path) and settings.get_menu_background_path() == GameSettings.DEFAULT_MENU_BACKGROUND_PATH, "读取默认背景不创建配置且指向内置图片")
	_write_text(path, JSON.stringify(legacy))
	var original := FileAccess.get_file_as_bytes(path)
	_check(settings.load_settings().is_ok() and settings.menu_background_mode == "default" and settings.code_color_mode == "dark" and settings.volume == 0.3, "旧配置缺背景字段时只补齐默认值")
	_check(FileAccess.get_file_as_bytes(path) == original, "读取旧配置不改写原文件")
	_check(settings.set_menu_background("solid").is_ok() and settings.get_menu_background_path().is_empty(), "纯色模式不提供图片路径")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var loaded_legacy: Dictionary = JSON.parse_string(JSON.stringify(legacy))
	_check(saved["future_root"] == loaded_legacy["future_root"] and saved["audio"] == loaded_legacy["audio"] and saved["interface"]["future_interface"] == loaded_legacy["interface"]["future_interface"], "背景修改保留顶层、音频及界面扩展字段")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.menu_background_mode == "solid" and reloaded.menu_background_id.is_empty(), "纯色选择跨实例恢复")
	_check(settings.set_menu_background("default").is_ok() and settings.set_code_color_mode("light").is_ok(), "默认背景与独立代码配色可分别修改")
	_check(reloaded.load_settings().is_ok() and reloaded.menu_background_mode == "default" and reloaded.code_color_mode == "light", "其他设置保存不会丢失背景选择")


## 超过四张背景仍完整持久化，来源文件删除后游戏副本可用，当前背景不能删除。
func _test_import_choose_restart_remove() -> void:
	var path := _test_root.path_join("library/settings.json")
	var settings := GameSettings.new(path)
	settings.changed.connect(_on_changed)
	var source_bytes := FileAccess.get_file_as_bytes(_source)
	var ids: Array[String] = []
	for index in 6:
		var before_changes := _changes
		var imported := settings.import_background(_source)
		_check(imported.is_ok(), "第 %d 张自定义背景可导入" % (index + 1))
		if not imported.is_ok():
			continue
		var id: String = imported.value["id"]
		ids.append(id)
		_check(settings.menu_background_mode == "custom" and settings.menu_background_id == id and settings.custom_backgrounds.size() == index + 1, "导入会自动选择并追加独立条目")
		_check(_changes == before_changes + 1 and imported.value["name"] == "原始 图片", "导入仅通知一次且使用原文件显示名")
		var copy_path := settings.get_background_path(id)
		_check(copy_path.begins_with(path.get_base_dir().path_join("backgrounds/")) and copy_path.get_file() == id + ".png" and FileAccess.file_exists(copy_path), "每个副本只使用随机 ID 保存为 PNG")
		_check(copy_path != _source and Image.load_from_file(copy_path).get_size() == Vector2i(32, 24), "副本保持图片尺寸且独立于原始路径")
	_check(ids.size() == 6 and ids[0] != ids[1], "六张同名来源图片拥有不同 ID")
	_check(FileAccess.get_file_as_bytes(_source) == source_bytes, "重复导入始终不修改原始图片")
	if ids.size() < 6:
		return
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.custom_backgrounds.size() == 6 and reloaded.menu_background_id == ids[5], "重新启动恢复超过四张背景以及所选图片")
	var before := FileAccess.get_file_as_bytes(path)
	_check(not settings.remove_background(ids[5]).is_ok() and FileAccess.get_file_as_bytes(path) == before and FileAccess.file_exists(settings.get_background_path(ids[5])), "正在使用的自定义背景不能删除且文件与配置不变")
	_check(not settings.remove_background("default").is_ok() and not settings.remove_background("solid").is_ok(), "默认背景与纯色背景不能删除")
	var deleted_path := settings.get_background_path(ids[0])
	_check(settings.remove_background(ids[0]).is_ok() and settings.custom_backgrounds.size() == 5 and not FileAccess.file_exists(deleted_path), "未使用背景从配置移除后删除游戏副本")
	_check(FileAccess.get_file_as_bytes(_source) == source_bytes, "删除副本绝不删除或改变来源图片")
	_check(settings.set_menu_background("custom", ids[1]).is_ok() and settings.get_menu_background_path() == settings.get_background_path(ids[1]), "可切换到另一张自定义背景")
	_check(settings.set_menu_background("solid").is_ok() and settings.remove_background(ids[1]).is_ok(), "切换纯色后原先使用的背景可以删除")
	_check(reloaded.load_settings().is_ok() and reloaded.custom_backgrounds.size() == 4 and reloaded.menu_background_mode == "solid", "删除与切换的结果可跨实例恢复")
	var external_copy := _test_root.path_join("source/临时来源.png")
	_check(DirAccess.copy_absolute(ProjectSettings.globalize_path(_source), ProjectSettings.globalize_path(external_copy)) == OK, "构造随后删除的来源图片")
	var copied := settings.import_background(external_copy)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(external_copy))
	_check(copied.is_ok() and FileAccess.file_exists(settings.get_menu_background_path()), "导入后源文件移走不影响已选背景")
	# 条目内扩展字段也应保留，不能因为一次模式切换被清理。
	settings.custom_backgrounds[0]["future_crop"] = {"x": 0.25}
	_check(settings.set_menu_background("default").is_ok() and reloaded.load_settings().is_ok() and reloaded.custom_backgrounds[0]["future_crop"] == {"x": 0.25}, "自定义列表条目保留未知扩展字段")


## 无效来源、非法标识与损坏设置不能覆盖有效数据，丢失图片只在显示时回退默认背景。
func _test_invalid_input_and_missing_files() -> void:
	var settings := GameSettings.new(_test_root.path_join("invalid/settings.json"))
	var imported := settings.import_background(_source)
	_check(imported.is_ok(), "无效输入回归建立有效自定义背景")
	if not imported.is_ok():
		return
	var id: String = imported.value["id"]
	var before := FileAccess.get_file_as_bytes(settings.storage_path)
	for mode in ["", "Default", "other"]:
		_check(not settings.set_menu_background(mode).is_ok() and settings.menu_background_id == id, "拒绝未知模式并保留选中背景")
	for invalid_id in ["../source", "res://assets/backgrounds/main_menu.png", "0".repeat(32), "A".repeat(32)]:
		_check(not settings.set_menu_background("custom", invalid_id).is_ok() and settings.get_background_path(invalid_id).is_empty() and not settings.remove_background(invalid_id).is_ok(), "拒绝任意路径、未知及非规范背景 ID")
	_check(not settings.set_menu_background("solid", id).is_ok(), "纯色模式不允许附带自定义 ID")
	var invalid_png := _test_root.path_join("source/invalid.png")
	_write_text(invalid_png, "not an image".repeat(10))
	for source in [invalid_png, _test_root.path_join("missing.png"), _test_root.path_join("background.svg")]:
		_check(not settings.import_background(source).is_ok() and settings.menu_background_id == id and settings.custom_backgrounds.size() == 1, "无效来源不能改变已有背景与列表")
	var oversized_path := _test_root.path_join("source/oversized.png")
	var oversized := FileAccess.open(oversized_path, FileAccess.WRITE)
	oversized.seek(GameSettings.MAX_BACKGROUND_BYTES)
	oversized.store_8(0)
	oversized.close()
	_check(not settings.import_background(oversized_path).is_ok() and settings.last_error.contains("64 MiB"), "文件大小超限在读入和解码前被拒绝")
	var huge_header := FileAccess.get_file_as_bytes(_source).slice(0, 33)
	huge_header[16] = 0x7f
	var huge_path := _test_root.path_join("source/huge_dimensions.png")
	var huge_file := FileAccess.open(huge_path, FileAccess.WRITE)
	huge_file.store_buffer(huge_header)
	huge_file.close()
	_check(not settings.import_background(huge_path).is_ok() and settings.custom_backgrounds.size() == 1, "超大 PNG 尺寸头不会进入图片解码器")
	_check(FileAccess.get_file_as_bytes(settings.storage_path) == before, "无效输入不会覆盖已保存设置")
	var image_path := settings.get_menu_background_path()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(image_path))
	var reloaded := GameSettings.new(settings.storage_path)
	_check(reloaded.load_settings().is_ok() and reloaded.menu_background_mode == "custom" and reloaded.menu_background_id == id and reloaded.get_menu_background_path() == GameSettings.DEFAULT_MENU_BACKGROUND_PATH, "已选副本缺失时保持记录并显示默认背景")
	_check(FileAccess.get_file_as_bytes(settings.storage_path) == before and not reloaded.set_menu_background("custom", id).is_ok(), "读取丢失图片不改盘，重新选择丢失副本给出错误")
	_check(reloaded.set_menu_background("default").is_ok() and reloaded.remove_background(id).is_ok(), "切换后允许移除丢失图片的过期列表项")
	var valid: Dictionary = JSON.parse_string(before.get_string_from_utf8())
	for changes in [{"menu_background_mode": true}, {"menu_background_id": "../outside"}, {"custom_backgrounds": [{"id": "../outside", "name": "bad"}]}, {"custom_backgrounds": [valid["interface"]["custom_backgrounds"][0], valid["interface"]["custom_backgrounds"][0]]}]:
		var broken := valid.duplicate(true)
		broken["interface"].merge(changes, true)
		var text := JSON.stringify(broken)
		_write_text(settings.storage_path, text)
		_check(not reloaded.load_settings().is_ok() and reloaded.menu_background_mode == "default" and reloaded.custom_backgrounds.is_empty(), "背景字段损坏时整体回退默认设置")
		_check(FileAccess.get_file_as_string(settings.storage_path) == text, "损坏背景设置保留原件以供恢复")


## 配置无法提交时，导入不遗留文件，切换不改当前选择，删除不移除有效副本。
func _test_save_failure_rollback() -> void:
	var settings := SaveFailureSettings.new(_test_root.path_join("failure/settings.json"))
	var imported := settings.import_background(_source)
	_check(imported.is_ok(), "失败事务回归建立图片库")
	if not imported.is_ok():
		return
	var id: String = imported.value["id"]
	var copy_path := settings.get_background_path(id)
	_check(settings.set_menu_background("default").is_ok(), "失败删除前切到默认背景")
	settings.changed.connect(_on_changed)
	var previous_changes := _changes
	var original_config := FileAccess.get_file_as_bytes(settings.storage_path)
	var original_copy := FileAccess.get_file_as_bytes(copy_path)
	var directory := DirAccess.open(copy_path.get_base_dir())
	var original_files := directory.get_files()
	settings.fail_save = true
	_check(not settings.set_menu_background("solid").is_ok() and settings.menu_background_mode == "default", "背景切换保存失败后回滚选择")
	_check(not settings.remove_background(id).is_ok() and settings.custom_backgrounds.size() == 1 and FileAccess.get_file_as_bytes(copy_path) == original_copy, "删除保存失败时保留列表与图片")
	_check(not settings.import_background(_source).is_ok() and settings.menu_background_mode == "default" and settings.custom_backgrounds.size() == 1, "导入保存失败时恢复原模式与列表")
	_check(directory.get_files() == original_files and FileAccess.get_file_as_bytes(settings.storage_path) == original_config, "失败导入清理新副本且配置保持逐字节不变")
	_check(_changes == previous_changes and not settings.last_error.is_empty(), "失败事务不通知成功变更并提供错误")
	settings.fail_save = false
	_check(settings.set_menu_background("custom", id).is_ok() and settings.last_error.is_empty(), "之后正常选择清理旧错误")
	var blocker := _test_root.path_join("file_instead_of_directory")
	_write_text(blocker, "不能覆盖")
	var blocked := GameSettings.new(blocker.path_join("settings.json"))
	_check(not blocked.import_background(_source).is_ok() and blocked.custom_backgrounds.is_empty() and FileAccess.get_file_as_string(blocker) == "不能覆盖", "真实同名文件阻挡目录时不覆盖原件")


## 目录与文件符号链接不会被读取或删除，用户来源始终保持不变。
func _test_path_and_symlink_safety() -> void:
	for path in ["res://settings.json", "user://../settings.json", "user://tests/../settings.json"]:
		var invalid := GameSettings.new(path)
		_check(not invalid.import_background(_source).is_ok() and invalid.custom_backgrounds.is_empty(), "危险设置目录不能导入背景")
	var settings := GameSettings.new(_test_root.path_join("links/settings.json"))
	var imported := settings.import_background(_source)
	_check(imported.is_ok(), "符号链接回归建立副本")
	if not imported.is_ok():
		return
	var id: String = imported.value["id"]
	var copy_path := settings.get_background_path(id)
	_check(settings.set_menu_background("default").is_ok(), "链接删除测试切到默认背景")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(copy_path))
	var folder := DirAccess.open(copy_path.get_base_dir())
	var link_error := folder.create_link(ProjectSettings.globalize_path(_source), copy_path.get_file())
	_check(link_error == OK, "构造指向原始图片的替换链接")
	if link_error == OK:
		var source_before := FileAccess.get_file_as_bytes(_source)
		var settings_before := FileAccess.get_file_as_bytes(settings.storage_path)
		_check(settings.get_background_path(id).is_empty() and not settings.remove_background(id).is_ok(), "替换为链接的副本不能读取或删除")
		_check(FileAccess.get_file_as_bytes(_source) == source_before and FileAccess.get_file_as_bytes(settings.storage_path) == settings_before, "链接拒绝后源图与设置均不变")
		folder.remove(copy_path.get_file())
	var unsafe_directory := _test_root.path_join("linked_directory")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(unsafe_directory))
	var parent := DirAccess.open(unsafe_directory)
	_check(parent.create_link(ProjectSettings.globalize_path(_source.get_base_dir()), "backgrounds") == OK, "构造背景目录链接")
	var linked := GameSettings.new(unsafe_directory.path_join("settings.json"))
	_check(not linked.import_background(_source).is_ok() and linked.custom_backgrounds.is_empty(), "背景目录链接不能写入任何副本")


## 常用位图格式统一解码成游戏 PNG 副本，不要求来源已经被 Godot 导入。
func _test_common_image_formats() -> void:
	var settings := GameSettings.new(_test_root.path_join("formats/settings.json"))
	var image := Image.load_from_file(_source)
	var jpg_path := _test_root.path_join("source/photo.jpg")
	var webp_path := _test_root.path_join("source/photo.webp")
	_check(image.save_jpg(jpg_path) == OK and image.save_webp(webp_path) == OK, "构造普通 JPEG 和 WebP 来源")
	for path in [jpg_path, webp_path]:
		var result := settings.import_background(path)
		_check(result.is_ok() and settings.get_menu_background_path().ends_with(".png"), "常见图片格式统一保存为 PNG 副本")
		if result.is_ok():
			_check(Image.load_from_file(settings.get_menu_background_path()).get_size() == image.get_size(), "转换格式保留原始像素尺寸")


## 生成简单有效位图供持久化与事务测试使用，不修改任何项目资源。
func _make_source(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var image := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color("3c82bb"))
	image.fill_rect(Rect2i(0, 0, 16, 12), Color("fcb261"))
	_check(image.save_png(path) == OK, "测试源图可保存到隔离目录")


## 统计背景事务通知，避免失败事件被当作成功选择。
func _on_changed() -> void:
	_changes += 1


## 只写入本轮独占目录中的测试配置和故障素材。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "测试文本可写入隔离目录")
	if file != null:
		file.store_string(source)
		file.close()


## 测试清理不穿过链接，也不递归到本轮目录之外。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for filename in folder.get_files():
		folder.remove(filename)
	for dirname in folder.get_directories():
		if folder.is_link(dirname):
			folder.remove(dirname)
		else:
			_remove_test_tree(path.path_join(dirname))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 汇总有意义的行为断言，并让测试进程在失败时返回非零状态。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
