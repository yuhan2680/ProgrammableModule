class_name MapCodec
extends RefCounted
## 文件读写与内存文档分离，编辑器和运行时共享相同校验规则。

const KNOWN_FIELDS: Array[String] = [
	"format_version", "id", "name", "width", "height", "tiles",
	"player_spawn", "enemies", "objects", "dialogue", "properties",
]


## 从 JSON 文件载入已校验的地图；草稿可显式允许没有出生点。
static func load_file(path: String, registry: ContentRegistry, require_spawn: bool = true) -> DataResult:
	var source := DataValidation.read_json_object(path)
	if not source.is_ok():
		return source
	var result := from_dict(source.value, registry, require_spawn)
	if not result.is_ok():
		for index in range(result.errors.size()):
			result.errors[index] = "%s：%s" % [path, result.errors[index]]
	return result


## 校验原始地图对象后创建文档，保留顶层及格子层级的未知字段。
static func from_dict(data: Dictionary, registry: ContentRegistry, require_spawn: bool = true) -> DataResult:
	var checked := MapValidation.check(data, registry, require_spawn)
	if not checked.is_ok():
		return checked
	var document := MapDocument.new()
	document.id = data.id
	document.display_name = data.name
	document.width = int(data.width)
	document.height = int(data.height)
	document.extra = data.duplicate(true)
	for field in KNOWN_FIELDS:
		document.extra.erase(field)
	for entry: Dictionary in data.tiles:
		var cell := Vector2i(int(entry.x), int(entry.y))
		document.cells[cell] = entry.tile_id
		var cell_extra: Dictionary = entry.duplicate(true)
		for field in ["x", "y", "tile_id"]:
			cell_extra.erase(field)
		if not cell_extra.is_empty():
			document.cell_extras[cell] = cell_extra
	var spawn: Variant = data.get("player_spawn")
	document.player_spawn = spawn.duplicate(true) if spawn is Dictionary else null
	document.enemies = data.get("enemies", []).duplicate(true)
	document.objects = data.get("objects", []).duplicate(true)
	document.dialogue = data.get("dialogue", []).duplicate(true)
	document.properties = data.get("properties", {}).duplicate(true)
	return DataResult.success(document)


## 校验内存文档的字典键和值，再复用 JSON 格式检查防止非法编辑写出。
static func validate(document: MapDocument, registry: ContentRegistry, require_spawn: bool = true) -> DataResult:
	if document == null:
		return DataResult.failure("地图文档为空")
	for cell in document.cells:
		if not cell is Vector2i or not document.cells[cell] is String:
			return DataResult.failure("地图 cells 必须以 Vector2i 为键、地块 ID 为值")
	for cell in document.cell_extras:
		if not cell is Vector2i or not document.cell_extras[cell] is Dictionary:
			return DataResult.failure("地图 cell_extras 必须以 Vector2i 为键、对象为值")
	if document.player_spawn != null and not document.player_spawn is Dictionary:
		return DataResult.failure("player_spawn 必须是对象或 null")
	return MapValidation.check(document.to_dict(), registry, require_spawn)


## 完整校验并写入同目录临时文件，旧文件仅在新文件可用后替换。
static func save_file(document: MapDocument, path: String, registry: ContentRegistry, require_spawn: bool = true) -> DataResult:
	var checked := validate(document, registry, require_spawn)
	if not checked.is_ok():
		return checked
	if path.is_empty() or path.get_file().is_empty():
		return DataResult.failure("保存路径必须指向文件")
	var source := JSON.stringify(document.to_dict(), "\t", false) + "\n"
	if source.to_utf8_buffer().size() > DataValidation.MAX_FILE_BYTES:
		return DataResult.failure("地图超过 8 MiB 文件大小上限")
	var absolute := ProjectSettings.globalize_path(path)
	var directory := absolute.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		var mkdir_error := DirAccess.make_dir_recursive_absolute(directory)
		if mkdir_error != OK:
			return DataResult.failure("无法创建地图目录：%s" % error_string(mkdir_error))
	var suffix := ".%d.%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var temporary := absolute + suffix + ".tmp"
	var backup := absolute + suffix + ".bak"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return DataResult.failure("无法创建临时地图文件：%s" % error_string(FileAccess.get_open_error()))
	file.store_string(source)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("地图写入失败：%s" % error_string(write_error))
	var verification := load_file(temporary, registry, require_spawn)
	if not verification.is_ok():
		DirAccess.remove_absolute(temporary)
		return DataResult.failure("临时地图校验失败：%s" % "; ".join(verification.errors))
	return _replace_file(temporary, absolute, backup)


## 在同目录内替换文件；替换失败时恢复备份并清理临时文件。
static func _replace_file(temporary: String, destination: String, backup: String) -> DataResult:
	var had_original := FileAccess.file_exists(destination)
	if had_original:
		var backup_error := DirAccess.rename_absolute(destination, backup)
		if backup_error != OK:
			DirAccess.remove_absolute(temporary)
			return DataResult.failure("无法备份原地图：%s" % error_string(backup_error))
	var replace_error := DirAccess.rename_absolute(temporary, destination)
	if replace_error != OK:
		var restore_error := OK
		if had_original:
			restore_error = DirAccess.rename_absolute(backup, destination)
		DirAccess.remove_absolute(temporary)
		if restore_error != OK:
			return DataResult.failure("替换地图及恢复均失败；原文件保留于 %s" % backup)
		return DataResult.failure("无法替换地图，原文件已保留：%s" % error_string(replace_error))
	if had_original:
		var cleanup_error := DirAccess.remove_absolute(backup)
		if cleanup_error != OK:
			push_warning("地图已保存，但无法删除备份：%s" % backup)
	return DataResult.success(destination)
