class_name GameSettings
extends RefCounted
## 设置模型独立于界面：有效修改立即应用，保存失败通过结果及 last_error 报告。

signal changed

const DEFAULT_VOLUME: float = 1.0
const DEFAULT_LANGUAGE: String = "zh_CN"
const DEFAULT_TAB_COMPLETION: bool = true
const DEFAULT_ASSEMBLY_FREE_ZOOM: bool = false
const DEFAULT_WINDOW_RESOLUTION: String = "1280x800"
const SUPPORTED_WINDOW_RESOLUTIONS: Array[String] = ["1024x640", "1152x720", "1280x800", "1440x900", "1600x1000", "1920x1200", "maximized"]
const DEFAULT_CODE_HINTS: String = "normal"
const DEFAULT_CODE_COLOR_MODE: String = "light"
const DEFAULT_MENU_BACKGROUND_MODE: String = "default"
const DEFAULT_MENU_BACKGROUND_PATH: String = "res://assets/backgrounds/main_menu.png"
const SUPPORTED_MENU_BACKGROUND_MODES: Array[String] = ["default", "solid", "custom"]
const BACKGROUND_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const MAX_BACKGROUND_BYTES: int = 64 * 1024 * 1024
const MAX_BACKGROUND_PIXELS: int = 64000000
const MAX_BACKGROUND_DIMENSION: int = 16384
const MAX_CUSTOM_BACKGROUNDS: int = 256
const SUPPORTED_CODE_HINTS: Array[String] = ["none", "normal", "more"]
const SUPPORTED_CODE_COLOR_MODES: Array[String] = ["light", "dark"]
# 保留旧存档的 en 语言代码；语言自名只负责显示，不触发配置迁移。
const SUPPORTED_LANGUAGES: Array[String] = ["zh_CN", "zh_HK", "en"]
const LANGUAGE_LABELS: Array[String] = ["简体中文", "繁體中文", "English"]
const MAX_CONFIG_BYTES: int = 65536

var storage_path: String = "user://settings.json"
var volume: float = DEFAULT_VOLUME
var language: String = DEFAULT_LANGUAGE
var tab_completion: bool = DEFAULT_TAB_COMPLETION
var assembly_free_zoom: bool = DEFAULT_ASSEMBLY_FREE_ZOOM
var window_resolution: String = DEFAULT_WINDOW_RESOLUTION
var code_hints: String = DEFAULT_CODE_HINTS
var code_color_mode: String = DEFAULT_CODE_COLOR_MODE
var menu_background_mode: String = DEFAULT_MENU_BACKGROUND_MODE
var menu_background_id: String = ""
var custom_backgrounds: Array[Dictionary] = []
var last_error: String = ""
var _config: Dictionary = {}


## 允许注入独立用户目录，测试不能读取或修改玩家的真实设置。
func _init(path: String = "user://settings.json") -> void:
	storage_path = path


## 载入配置并应用；缺失文件使用默认值，损坏文件保留原件并返回错误。
func load_settings() -> DataResult:
	_reset_defaults()
	var path_result := _validate_path()
	if not path_result.is_ok():
		return _finish_load(path_result)
	if not FileAccess.file_exists(storage_path):
		return _finish_load(DataResult.success(self))
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		return _finish_load(DataResult.failure("无法读取设置文件：%s。" % error_string(FileAccess.get_open_error())))
	if file.get_length() > MAX_CONFIG_BYTES:
		file.close()
		return _finish_load(DataResult.failure("设置文件超过 64 KiB，已使用默认设置。"))
	var source := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(source) != OK:
		return _finish_load(DataResult.failure("设置文件损坏，已使用默认设置。\n第 %d 行：%s" % [parser.get_error_line(), parser.get_error_message()]))
	if not parser.data is Dictionary or not DataValidation.is_json_value(parser.data):
		return _finish_load(DataResult.failure("设置文件必须是包含有限数值的 JSON 对象。"))
	var loaded: Dictionary = parser.data
	if not DataValidation.is_integer(loaded.get("format_version"), 1, 1):
		return _finish_load(DataResult.failure("设置文件版本不受支持，已使用默认设置。"))
	if not loaded.get("audio") is Dictionary or not loaded.get("interface") is Dictionary:
		return _finish_load(DataResult.failure("设置文件缺少有效的 audio 或 interface 对象，已使用默认设置。"))
	var volume_value: Variant = loaded["audio"].get("master_volume")
	var language_value: Variant = loaded["interface"].get("language")
	# 旧版配置没有补全字段，首次使用新功能时保持默认开启，不改写原文件。
	var completion_value: Variant = loaded["interface"].get("tab_completion", DEFAULT_TAB_COMPLETION)
	var hints_value: Variant = loaded["interface"].get("code_hints", DEFAULT_CODE_HINTS)
	# 旧版文件继续使用浅色代码区；读取仅补齐内存默认值，不写回配置。
	var color_mode_value: Variant = loaded["interface"].get("code_color_mode", DEFAULT_CODE_COLOR_MODE)
	# 旧配置缺省关闭自由缩放，读取不会自动迁移或覆盖原文件。
	var free_zoom_value: Variant = loaded["interface"].get("assembly_free_zoom", DEFAULT_ASSEMBLY_FREE_ZOOM)
	# 旧配置沿用默认窗口尺寸，只补内存值；具体窗口操作由显示层处理。
	var resolution_value: Variant = loaded["interface"].get("window_resolution", DEFAULT_WINDOW_RESOLUTION)
	var validation := _validate_values(volume_value, language_value, completion_value, hints_value, color_mode_value, free_zoom_value, resolution_value)
	var background_mode: Variant = loaded["interface"].get("menu_background_mode", DEFAULT_MENU_BACKGROUND_MODE)
	var background_id: Variant = loaded["interface"].get("menu_background_id", "")
	var backgrounds: Variant = loaded["interface"].get("custom_backgrounds", [])
	if validation.is_ok():
		validation = _validate_background_values(background_mode, background_id, backgrounds)
	if not validation.is_ok():
		return _finish_load(DataResult.failure("设置文件内容无效，已使用默认设置。\n" + "\n".join(validation.errors)))
	volume = float(volume_value)
	language = language_value
	tab_completion = completion_value
	assembly_free_zoom = free_zoom_value
	window_resolution = resolution_value
	code_hints = hints_value
	code_color_mode = color_mode_value
	menu_background_mode = background_mode
	menu_background_id = background_id
	custom_backgrounds.assign(backgrounds.duplicate(true))
	_config = loaded.duplicate(true)
	return _finish_load(DataResult.success(self))


## 将当前设置写入同目录临时文件，回读成功后才替换已有配置。
func save_settings() -> DataResult:
	var validation := _validate_values(volume, language, tab_completion, code_hints, code_color_mode, assembly_free_zoom, window_resolution)
	if validation.is_ok():
		validation = _validate_background_values(menu_background_mode, menu_background_id, custom_backgrounds)
	if validation.is_ok():
		validation = _validate_path()
	if not validation.is_ok():
		return _remember_result(validation)
	var next_config := _config.duplicate(true)
	next_config["format_version"] = 1
	# 只更新已知字段，保留顶层与设置分组中未来版本添加的内容。
	var audio_data: Dictionary = next_config.get("audio", {}).duplicate(true)
	audio_data["master_volume"] = volume
	next_config["audio"] = audio_data
	var interface_data: Dictionary = next_config.get("interface", {}).duplicate(true)
	interface_data["language"] = language
	interface_data["tab_completion"] = tab_completion
	interface_data["assembly_free_zoom"] = assembly_free_zoom
	interface_data["window_resolution"] = window_resolution
	interface_data["code_hints"] = code_hints
	interface_data["code_color_mode"] = code_color_mode
	interface_data["menu_background_mode"] = menu_background_mode
	interface_data["menu_background_id"] = menu_background_id
	interface_data["custom_backgrounds"] = custom_backgrounds.duplicate(true)
	next_config["interface"] = interface_data
	var source := JSON.stringify(next_config, "\t", false) + "\n"
	if source.to_utf8_buffer().size() > MAX_CONFIG_BYTES:
		return _remember_result(DataResult.failure("设置文件超过 64 KiB，无法保存。"))
	var absolute := ProjectSettings.globalize_path(storage_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if directory_error != OK:
		return _remember_result(DataResult.failure("无法创建设置目录：%s。" % error_string(directory_error)))
	var suffix := ".%d.%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var temporary := absolute + suffix + ".tmp"
	var backup := absolute + suffix + ".bak"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _remember_result(DataResult.failure("无法创建临时设置文件：%s。" % error_string(FileAccess.get_open_error())))
	file.store_string(source)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return _remember_result(DataResult.failure("设置保存失败：%s。" % error_string(write_error)))
	var checked := DataValidation.read_json_object(temporary)
	if not checked.is_ok() or checked.value != JSON.parse_string(source):
		DirAccess.remove_absolute(temporary)
		return _remember_result(DataResult.failure("设置回读校验失败，原配置保持不变。"))
	var result := _replace_config(temporary, absolute, backup)
	if result.is_ok():
		_config = next_config
	return _remember_result(result)


## 使用线性 0..1 音量；零音量真正静音，不接受布尔值或非有限数值。
func set_volume(value: Variant) -> DataResult:
	var validation := _validate_values(value, language, tab_completion, code_hints, code_color_mode, assembly_free_zoom, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	volume = float(value)
	_apply_runtime()
	var result := save_settings()
	changed.emit()
	return result


## 支持简体中文与 English，切换时通过 TranslationServer 通知现有控件。
func set_language(value: Variant) -> DataResult:
	var validation := _validate_values(volume, value, tab_completion, code_hints, code_color_mode, assembly_free_zoom, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	language = value
	_apply_runtime()
	var result := save_settings()
	changed.emit()
	return result


## 补全偏好立即通知编辑器，磁盘写入失败时仍保留本次选择并返回明确错误。
func set_tab_completion(value: Variant) -> DataResult:
	var validation := _validate_values(volume, language, value, code_hints, code_color_mode, assembly_free_zoom, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	tab_completion = value
	var result := save_settings()
	changed.emit()
	return result


## 自由缩放仅改变装配图的查看方式；有效开关即时通知界面，保存失败仍保留当前选择。
func set_assembly_free_zoom(value: Variant) -> DataResult:
	var validation := _validate_values(volume, language, tab_completion, code_hints, code_color_mode, value, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	assembly_free_zoom = value
	var result := save_settings()
	changed.emit()
	return result


## 分辨率只保存预设标识；有效选择即时通知显示层，写盘失败仍保留本次内存选择。
func set_window_resolution(value: Variant) -> DataResult:
	var validation := _validate_values(volume, language, tab_completion, code_hints, code_color_mode, assembly_free_zoom, value)
	if not validation.is_ok():
		return _remember_result(validation)
	window_resolution = value
	var result := save_settings()
	changed.emit()
	return result


## 代码提示的数量独立于 Tab 补全；即时通知界面，保存失败也保留当前选择。
func set_code_hints(value: Variant) -> DataResult:
	var validation := _validate_values(volume, language, tab_completion, value, code_color_mode, assembly_free_zoom, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	code_hints = value
	var result := save_settings()
	changed.emit()
	return result


## 代码区配色独立保存；有效选择即时通知编辑器，写盘失败仍保留当前外观。
func set_code_color_mode(value: Variant) -> DataResult:
	var validation := _validate_values(volume, language, tab_completion, code_hints, value, assembly_free_zoom, window_resolution)
	if not validation.is_ok():
		return _remember_result(validation)
	code_color_mode = value
	var result := save_settings()
	changed.emit()
	return result


## 背景选择在成功持久化后才通知界面；失败保留此前的背景与列表。
func set_menu_background(mode: String, id: String = "") -> DataResult:
	var validation := _validate_background_values(mode, id, custom_backgrounds)
	if not validation.is_ok():
		return _remember_result(validation)
	if mode == "custom" and get_background_path(id).is_empty():
		return _remember_result(DataResult.failure("自定义背景文件不存在或无法安全读取，请重新添加。"))
	return _commit_background(mode, id, custom_backgrounds)


## 图片解码成功后以独立 PNG 副本保存，配置提交失败会撤销新副本，原始图片始终只读。
func import_background(source_path: String) -> DataResult:
	var validation := _validate_background_values(menu_background_mode, menu_background_id, custom_backgrounds)
	if not validation.is_ok():
		return _remember_result(validation)
	if custom_backgrounds.size() >= MAX_CUSTOM_BACKGROUNDS:
		return _remember_result(DataResult.failure("自定义背景最多允许 256 张，请先删除未使用的背景。"))
	var directory_result := _background_directory()
	if not directory_result.is_ok():
		return _remember_result(directory_result)
	var image_result := _read_background_image(source_path)
	if not image_result.is_ok():
		return _remember_result(image_result)
	var directory: String = directory_result.value
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if directory_error != OK:
		return _remember_result(DataResult.failure("无法创建背景目录：%s。" % error_string(directory_error)))
	# 文件名只来自随机 ID，玩家的文件名和配置扩展字段不参与磁盘路径。
	var id := Crypto.new().generate_random_bytes(16).hex_encode()
	var destination := directory.path_join(id + ".png")
	if FileAccess.file_exists(destination) or DirAccess.dir_exists_absolute(destination):
		return _remember_result(DataResult.failure("无法生成独立的背景文件，请重试。"))
	var image: Image = image_result.value
	var save_error := image.save_png(destination)
	if save_error != OK:
		_remove_import_copy(destination)
		return _remember_result(DataResult.failure("无法保存背景图片：%s。" % error_string(save_error)))
	var name := source_path.get_file().get_basename().strip_edges().left(128)
	if name.is_empty():
		name = "自定义背景"
	var entry := {"id": id, "name": name}
	var next_backgrounds: Array[Dictionary] = custom_backgrounds.duplicate(true)
	next_backgrounds.append(entry)
	var result := _commit_background("custom", id, next_backgrounds)
	if not result.is_ok():
		_remove_import_copy(destination)
		return result
	return _remember_result(DataResult.success(entry.duplicate(true)))


## 只删除未使用的已登记副本；先保存新列表，写盘失败时不会删除任何图片。
func remove_background(id: String) -> DataResult:
	if not _valid_background_id(id) or _background_index(id) < 0:
		return _remember_result(DataResult.failure("只能删除已添加的自定义背景。"))
	if menu_background_mode == "custom" and menu_background_id == id:
		return _remember_result(DataResult.failure("正在使用的背景不能删除，请先切换到其他背景。"))
	var directory_result := _background_directory()
	if not directory_result.is_ok():
		return _remember_result(directory_result)
	var directory: String = directory_result.value
	var folder := DirAccess.open(directory)
	var filename := id + ".png"
	if folder != null and (folder.is_link(filename) or folder.dir_exists(filename)):
		return _remember_result(DataResult.failure("背景文件不能是符号链接或文件夹，未删除任何图片。"))
	var next_backgrounds: Array[Dictionary] = custom_backgrounds.duplicate(true)
	next_backgrounds.remove_at(_background_index(id))
	var result := _commit_background(menu_background_mode, menu_background_id, next_backgrounds)
	if not result.is_ok():
		return result
	var path := directory.path_join(filename)
	if FileAccess.file_exists(path):
		var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if remove_error != OK:
			return _remember_result(DataResult.failure("背景已从列表移除，但无法清理图片副本：%s。" % error_string(remove_error)))
	return _remember_result(DataResult.success())


## 纯色不返回纹理路径；已选图片丢失时显示内置背景，不改写用户选择或配置文件。
func get_menu_background_path() -> String:
	if menu_background_mode == "solid":
		return ""
	if menu_background_mode == "custom":
		var path := get_background_path(menu_background_id)
		if not path.is_empty():
			return path
	return DEFAULT_MENU_BACKGROUND_PATH


## 只有已登记、安全且存在的副本可以供显示层读取，未知 ID 不能构造任意路径。
func get_background_path(id: String) -> String:
	if not _valid_background_id(id) or _background_index(id) < 0:
		return ""
	var directory_result := _background_directory()
	if not directory_result.is_ok():
		return ""
	var directory: String = directory_result.value
	var folder := DirAccess.open(directory)
	var filename := id + ".png"
	if folder == null or folder.is_link(filename) or not folder.file_exists(filename):
		return ""
	return directory.path_join(filename)


## 背景事务与原有音量等即时设置分开处理，避免失败后产生指向未保存副本的选择。
func _commit_background(mode: String, id: String, entries: Array[Dictionary]) -> DataResult:
	var previous_mode := menu_background_mode
	var previous_id := menu_background_id
	var previous_entries: Array[Dictionary] = custom_backgrounds.duplicate(true)
	menu_background_mode = mode
	menu_background_id = id
	custom_backgrounds = entries.duplicate(true)
	var result := save_settings()
	if not result.is_ok():
		menu_background_mode = previous_mode
		menu_background_id = previous_id
		custom_backgrounds = previous_entries
		return result
	changed.emit()
	return result


## 读取时严格校验模式、随机 ID 与列表，保留各条目未知的 JSON 扩展字段。
func _validate_background_values(mode: Variant, id: Variant, entries: Variant) -> DataResult:
	if not mode is String or not mode in SUPPORTED_MENU_BACKGROUND_MODES:
		return DataResult.failure("开始菜单背景必须为默认、纯色或自定义。")
	if not id is String or (mode != "custom" and not id.is_empty()):
		return DataResult.failure("背景标识与当前背景模式不匹配。")
	if not entries is Array or entries.size() > MAX_CUSTOM_BACKGROUNDS:
		return DataResult.failure("自定义背景列表无效，最多允许 256 张。")
	var ids: Dictionary = {}
	for entry: Variant in entries:
		if not entry is Dictionary or not _valid_background_id(entry.get("id")):
			return DataResult.failure("自定义背景包含无效的标识。")
		var entry_id: String = entry["id"]
		var name: Variant = entry.get("name")
		if ids.has(entry_id) or not name is String or name.strip_edges().is_empty() or name.length() > 128 or not DataValidation.is_json_value(entry):
			return DataResult.failure("自定义背景名称或列表内容无效。")
		ids[entry_id] = true
	if mode == "custom" and (not _valid_background_id(id) or not ids.has(id)):
		return DataResult.failure("选择的自定义背景不在背景列表中。")
	return DataResult.success()


## 固定长度的小写十六进制 ID 不含任何路径符号，内置背景也不会被当作可删除项。
func _valid_background_id(id: Variant) -> bool:
	if not id is String or id.length() != 32:
		return false
	for character: String in id:
		if not character in "0123456789abcdef":
			return false
	return true


## 按稳定 ID 查找图片，显示名称重复不影响各张图片的选择或删除。
func _background_index(id: String) -> int:
	for index in custom_backgrounds.size():
		if custom_backgrounds[index].get("id") == id:
			return index
	return -1


## 副本必须位于设置旁的 backgrounds 目录，逐段拒绝符号链接以免误删外部文件。
func _background_directory() -> DataResult:
	var validation := _validate_path()
	if not validation.is_ok():
		return validation
	var directory := storage_path.get_base_dir().path_join("backgrounds")
	var folder := DirAccess.open("user://")
	if folder == null:
		return DataResult.failure("无法访问背景保存目录。")
	for segment: String in directory.trim_prefix("user://").split("/"):
		if folder.is_link(segment):
			return DataResult.failure("背景保存目录不能包含符号链接。")
		if not folder.dir_exists(segment):
			if folder.file_exists(segment):
				return DataResult.failure("背景保存目录被同名文件占用。")
			return DataResult.success(directory)
		if folder.change_dir(segment) != OK:
			return DataResult.failure("无法访问背景保存目录。")
	return DataResult.success(directory)


## 解码前限制文件大小及常见签名；只导入位图，解码后再限制尺寸和像素总量。
func _read_background_image(source_path: String) -> DataResult:
	var extension := source_path.get_extension().to_lower()
	if not extension in BACKGROUND_EXTENSIONS:
		return DataResult.failure("请选择 PNG、JPEG、WebP、BMP 或 TGA 图片。")
	var file := FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		return DataResult.failure("无法读取背景图片：%s。" % error_string(FileAccess.get_open_error()))
	if file.get_length() > MAX_BACKGROUND_BYTES:
		file.close()
		return DataResult.failure("背景图片不能超过 64 MiB。")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if not _valid_image_header(bytes, extension):
		return DataResult.failure("背景图片格式无效或文件已损坏。")
	var image := Image.new()
	var decode_error: Error = ERR_FILE_UNRECOGNIZED
	match extension:
		"png": decode_error = image.load_png_from_buffer(bytes)
		"jpg", "jpeg": decode_error = image.load_jpg_from_buffer(bytes)
		"webp": decode_error = image.load_webp_from_buffer(bytes)
		"bmp": decode_error = image.load_bmp_from_buffer(bytes)
		"tga": decode_error = image.load_tga_from_buffer(bytes)
	if decode_error != OK or image.is_empty():
		return DataResult.failure("无法解码背景图片，请选择有效的图片文件。")
	if image.get_width() > MAX_BACKGROUND_DIMENSION or image.get_height() > MAX_BACKGROUND_DIMENSION or image.get_width() * image.get_height() > MAX_BACKGROUND_PIXELS:
		return DataResult.failure("背景图片尺寸过大：单边不能超过 16384 像素，总像素不能超过 6400 万。")
	image.convert(Image.FORMAT_RGBA8)
	return DataResult.success(image)


## 在调用图片解码器前拦截明显空文件、错误类型和超大 PNG 头，避免无效输入触发底层日志。
func _valid_image_header(bytes: PackedByteArray, extension: String) -> bool:
	if bytes.size() < 18:
		return false
	match extension:
		"png":
			if bytes.size() < 33 or bytes.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]):
				return false
			var width := (int(bytes[16]) << 24) | (int(bytes[17]) << 16) | (int(bytes[18]) << 8) | int(bytes[19])
			var height := (int(bytes[20]) << 24) | (int(bytes[21]) << 16) | (int(bytes[22]) << 8) | int(bytes[23])
			return width > 0 and height > 0 and width <= MAX_BACKGROUND_DIMENSION and height <= MAX_BACKGROUND_DIMENSION and width * height <= MAX_BACKGROUND_PIXELS
		"jpg", "jpeg": return bytes[0] == 255 and bytes[1] == 216 and bytes[2] == 255
		"webp": return bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP"
		"bmp": return bytes[0] == 66 and bytes[1] == 77
		"tga": return bytes[1] <= 1 and bytes[2] in [1, 2, 3, 9, 10, 11] and bytes[16] in [8, 15, 16, 24, 32]
	return false


## 仅撤销本次刚创建的导入副本，不接触用户选择的原始图片。
func _remove_import_copy(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 将默认状态恢复到内存，读取失败时不部分采用损坏文件中的其它字段。
func _reset_defaults() -> void:
	volume = DEFAULT_VOLUME
	language = DEFAULT_LANGUAGE
	tab_completion = DEFAULT_TAB_COMPLETION
	assembly_free_zoom = DEFAULT_ASSEMBLY_FREE_ZOOM
	window_resolution = DEFAULT_WINDOW_RESOLUTION
	code_hints = DEFAULT_CODE_HINTS
	code_color_mode = DEFAULT_CODE_COLOR_MODE
	menu_background_mode = DEFAULT_MENU_BACKGROUND_MODE
	menu_background_id = ""
	custom_backgrounds = []
	_config = {}
	last_error = ""


## 统一结束载入：先应用完整设置，再让界面读取当前值和错误状态。
func _finish_load(result: DataResult) -> DataResult:
	_apply_runtime()
	_remember_result(result)
	changed.emit()
	return result


## Master 总线使用线性值转换后的分贝，零值单独静音以避免负无限分贝。
func _apply_runtime() -> void:
	GameI18n.install()
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, volume == 0.0)
		AudioServer.set_bus_volume_db(master, linear_to_db(volume) if volume > 0.0 else -80.0)
	TranslationServer.set_locale(language)


## 配置只允许安全的用户路径，避免注入路径跳出用户设置目录。
func _validate_path() -> DataResult:
	if not storage_path.begins_with("user://") or not DataValidation.is_resource_path(storage_path):
		return DataResult.failure("设置路径必须是安全的 user:// 文件路径。")
	return DataResult.success()


## 在所有公开入口复用真实类型与值域校验。
func _validate_values(volume_value: Variant, language_value: Variant, completion_value: Variant, hints_value: Variant, color_mode_value: Variant, free_zoom_value: Variant, resolution_value: Variant) -> DataResult:
	if not DataValidation.is_number(volume_value) or float(volume_value) < 0.0 or float(volume_value) > 1.0:
		return DataResult.failure("主音量必须是 0..1 的有限数字。")
	if not language_value is String or not language_value in SUPPORTED_LANGUAGES:
		return DataResult.failure("语言必须为简体中文（zh_CN）、繁體中文（zh_HK）或 English（en）。")
	if not completion_value is bool:
		return DataResult.failure("Tab 补全必须为布尔值。")
	if not hints_value is String or not hints_value in SUPPORTED_CODE_HINTS:
		return DataResult.failure("代码提示必须为无、一般或多。")
	if not color_mode_value is String or not color_mode_value in SUPPORTED_CODE_COLOR_MODES:
		return DataResult.failure("代码颜色必须为浅色（light）或深色（dark）。")
	if not free_zoom_value is bool:
		return DataResult.failure("装配图尺寸自由缩放必须为布尔值。")
	if not resolution_value is String or not resolution_value in SUPPORTED_WINDOW_RESOLUTIONS:
		return DataResult.failure("窗口分辨率必须为预设尺寸或最大化。")
	return DataResult.success()


## 记录最近一次错误，成功后清除旧提示，避免界面显示过期失败。
func _remember_result(result: DataResult) -> DataResult:
	last_error = "\n".join(result.errors)
	return result


## 替换失败时恢复旧设置；原配置在验证成功前始终保持完整。
func _replace_config(temporary: String, destination: String, backup: String) -> DataResult:
	var had_original := FileAccess.file_exists(destination)
	if had_original:
		var backup_error := DirAccess.rename_absolute(destination, backup)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary)
			return DataResult.failure("无法备份原设置：%s。" % error_string(backup_error))
	var replace_error := DirAccess.rename_absolute(temporary, destination)
	if replace_error != OK:
		var restore_error := OK
		if had_original:
			restore_error = DirAccess.rename_absolute(backup, destination)
		DirAccess.remove_absolute(temporary)
		if restore_error != OK:
			return DataResult.failure("设置替换和恢复均失败；原配置保留于：%s。" % backup)
		return DataResult.failure("设置替换失败，原配置已保留。")
	if had_original and DirAccess.remove_absolute(backup) != OK:
		push_warning("设置已保存，但无法删除备份：%s。" % backup)
	return DataResult.success(destination)
