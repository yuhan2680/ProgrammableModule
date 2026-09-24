class_name MapDocument
extends RefCounted
## 稀疏地图：cells 中不存在的位置始终为不可通行的 void。

var id: String = "untitled"
var display_name: String = "新地图"
var width: int = 12
var height: int = 10
var cells: Dictionary = {}
var player_spawn: Variant = null
var enemies: Array = []
var objects: Array = []
var dialogue: Array = []
var properties: Dictionary = {}
var extra: Dictionary = {}
var cell_extras: Dictionary = {}


## 判断格子是否位于地图矩形边界内。
func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


## 返回显式地块 ID；空字符串代表 void，包括越界位置。
func get_tile_id(cell: Vector2i) -> String:
	if not in_bounds(cell):
		return ""
	return cells.get(cell, "")


## 设置或擦除格子；擦除同时删除该格子的扩展元数据。
func set_tile(cell: Vector2i, tile_id: String) -> void:
	if not in_bounds(cell):
		return
	if tile_id.is_empty() or tile_id == "void":
		cells.erase(cell)
		cell_extras.erase(cell)
	else:
		cells[cell] = tile_id


## 生成可序列化快照，稳定地按行排列稀疏地块并保留未知字段。
func to_dict() -> Dictionary:
	var result: Dictionary = extra.duplicate(true)
	result.merge({
		"format_version": 1, "id": id, "name": display_name,
		"width": width, "height": height, "tiles": [],
		"player_spawn": player_spawn.duplicate(true) if player_spawn is Dictionary else null,
		"enemies": enemies.duplicate(true), "objects": objects.duplicate(true),
		"dialogue": dialogue.duplicate(true), "properties": properties.duplicate(true),
	}, true)
	var ordered: Array = cells.keys()
	ordered.sort_custom(_cell_before)
	for cell: Vector2i in ordered:
		var entry: Dictionary = cell_extras.get(cell, {}).duplicate(true)
		entry.merge({"x": cell.x, "y": cell.y, "tile_id": cells[cell]}, true)
		result["tiles"].append(entry)
	return result


## 创建深拷贝，保证编辑草稿与运行时快照不会互相修改。
func duplicate_document() -> MapDocument:
	var result := MapDocument.new()
	result.id = id
	result.display_name = display_name
	result.width = width
	result.height = height
	result.cells = cells.duplicate(true)
	result.player_spawn = player_spawn.duplicate(true) if player_spawn is Dictionary else null
	result.enemies = enemies.duplicate(true)
	result.objects = objects.duplicate(true)
	result.dialogue = dialogue.duplicate(true)
	result.properties = properties.duplicate(true)
	result.extra = extra.duplicate(true)
	result.cell_extras = cell_extras.duplicate(true)
	return result


## 为地图保存提供确定性的从上到下、从左到右排序。
static func _cell_before(left: Vector2i, right: Vector2i) -> bool:
	return left.y < right.y or (left.y == right.y and left.x < right.x)
