class_name MapEditorTimedGate
extends RefCounted
## 限时闸门的编辑查询与校验；沿用既有对象格式，不拥有模拟或编辑历史。

const DEFAULT_SECONDS := 6.0
const MAX_TICKS := 1000000


## 有正关卡限时时预留最后一个tick；不限时旧图仍使用格式允许的上限。
static func maximum_ticks(max_ticks: Variant = 0) -> int:
	if DataValidation.is_integer(max_ticks, 1, 36000):
		return mini(MAX_TICKS, int(max_ticks) - 1)
	return MAX_TICKS


## 按对象 ID 查找限时闸门；只返回副本，防止表单提前修改正式文档。
static func find(document: MapDocument, identity: String) -> Dictionary:
	if document == null or identity.is_empty():
		return {}
	for entry: Dictionary in document.objects:
		if entry.get("type") == "timed_gate" and entry.get("id") == identity:
			return entry.duplicate(true)
	return {}


## 按真实对象矩形命中；兼容元数据建立的非格心或多格闸门。
static func at_position(document: MapDocument, position: Vector2) -> String:
	if document == null:
		return ""
	for entry: Dictionary in document.objects:
		if entry.get("type") != "timed_gate" or not MapObjectDefinition.validate(entry, Vector2i(document.width, document.height)).is_ok():
			continue
		if MapObjectDefinition.from_entry(entry).rect.has_point(position):
			return entry.id
	return ""


## 秒数须精确对应正整数 tick，避免大数的相对误差放过额外小数位。
static func ticks_from_seconds(seconds: float, max_ticks: Variant = 0) -> DataResult:
	var ticks := seconds * SimulationWorld.TICKS_PER_SECOND
	if not is_finite(ticks) or ticks < 1.0 or ticks > MAX_TICKS or absf(ticks - roundf(ticks)) > 0.00001:
		return DataResult.failure("闸门倒计时须为 0.1 到 100000 秒，最多一位小数。")
	var deadline := MapValidation.check_timed_gate_deadline(roundi(ticks), max_ticks)
	if not deadline.is_ok():
		return deadline
	return DataResult.success(roundi(ticks))


## 读取原有合法倒计时；不为未选择或异常对象写入默认值。
static func seconds(entry: Dictionary) -> float:
	var properties: Variant = entry.get("properties", {})
	if properties is Dictionary and DataValidation.is_integer(properties.get("close_after_ticks"), 1, MAX_TICKS):
		return int(properties.close_after_ticks) * SimulationWorld.TICK_DURATION
	return DEFAULT_SECONDS


## 新闸门占一整格且不自动铺地板；已有机关不可被覆盖，失败不更改任何数据。
static func check_placement(document: MapDocument, cell: Vector2i, content: ContentRegistry) -> DataResult:
	if document == null or content == null or not document.in_bounds(cell):
		return DataResult.failure("闸门需要位于地图内。")
	var tile := content.get_tile(document.get_tile_id(cell))
	if tile == null or tile.collision:
		return DataResult.failure("闸门需要位于可通行地块；请先绘制地板。")
	var area := Rect2(Vector2(cell), Vector2.ONE)
	for entry: Dictionary in document.objects:
		if entry.get("type") not in MapObjectDefinition.TYPES or not MapObjectDefinition.validate(entry, Vector2i(document.width, document.height)).is_ok():
			continue
		if area.intersects(MapObjectDefinition.from_entry(entry).rect):
			return DataResult.failure("此位置已有地图对象，请选择空闲地块。")
	if document.objects.size() >= MapValidation.MAX_ENTITIES:
		return DataResult.failure("地图最多支持 1024 个对象。")
	return DataResult.success()
