class_name MapObjectDefinition
extends RefCounted
## 可信对象类型的静态配置。未知类型仍作为扩展元数据保存，不执行脚本。

const TYPES := ["timed_gate", "destructible", "prison_alarm", "paired_alarm", "security_gate"]
var id: String
var kind: String
var rect: Rect2
var close_after_ticks: int = 0
var max_health: float = 0.0
var guard_id: String = ""
var partner_id: String = ""
var required_enemy_ids: Array[String] = []
var required_object_ids: Array[String] = []


## 只校验已实现对象；共用 MapValidation 的位置与 ID 唯一性校验。
static func validate(entry: Dictionary, dimensions: Vector2i) -> DataResult:
	if entry.get("type") not in TYPES:
		return DataResult.success()
	if not DataValidation.is_id(entry.get("id")):
		return DataResult.failure("动态对象需要有效的 id。")
	var side: Variant = entry.get("size", 1.0)
	if not DataValidation.is_number(side) or float(side) <= 0.0 or float(side) > 256.0:
		return DataResult.failure("动态对象 size 必须是大于 0、最多 256 的正方形边长。")
	var center := Vector2(float(entry.position.x), float(entry.position.y))
	var rect := Rect2(center - Vector2.ONE * float(side) / 2.0, Vector2.ONE * float(side))
	if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > dimensions.x or rect.end.y > dimensions.y:
		return DataResult.failure("动态对象的完整正方形必须位于地图内。")
	var properties: Variant = entry.get("properties", {})
	if not properties is Dictionary:
		return DataResult.failure("动态对象 properties 必须是对象。")
	if entry.type == "timed_gate":
		if not DataValidation.is_integer(properties.get("close_after_ticks"), 1, 1000000):
			return DataResult.failure("闸门 close_after_ticks 必须是 1..1000000 的整数。")
	elif entry.type == "security_gate":
		var dependencies := 0
		for field in ["required_enemy_ids", "required_object_ids"]:
			var ids: Variant = properties.get(field, [])
			if not ids is Array or ids.size() > 1024:
				return DataResult.failure("安全门 %s 必须是最多 1024 项的 ID 数组。" % field)
			var seen: Dictionary = {}
			for dependency: Variant in ids:
				if not DataValidation.is_id(dependency) or seen.has(dependency):
					return DataResult.failure("安全门 %s 必须包含不重复的有效 ID。" % field)
				seen[dependency] = true
			dependencies += ids.size()
		if dependencies == 0:
			return DataResult.failure("安全门至少需要一个敌人或可破坏对象作为解锁条件。")
	else:
		var health: Variant = properties.get("max_health")
		if not DataValidation.is_number(health) or float(health) <= 0.0 or float(health) > 1000000000.0:
			return DataResult.failure("障碍物 max_health 必须是大于 0、最多 1000000000 的有限数字。")
		if entry.type == "prison_alarm" and not DataValidation.is_id(properties.get("guard_id")):
			return DataResult.failure("监狱警报需要有效的 guard_id。")
		if entry.type == "paired_alarm" and not DataValidation.is_id(properties.get("partner_id")):
			return DataResult.failure("联动警报需要有效的 partner_id。")
	return DataResult.success()


## 将已经验证的对象转换为独立静态描述，未知扩展不生成运行对象。
static func from_entry(entry: Dictionary) -> MapObjectDefinition:
	if entry.get("type") not in TYPES:
		return null
	var definition := MapObjectDefinition.new()
	definition.id = entry.id
	definition.kind = entry.type
	var size := Vector2.ONE * float(entry.get("size", 1.0))
	definition.rect = Rect2(Vector2(float(entry.position.x), float(entry.position.y)) - size / 2.0, size)
	var properties: Dictionary = entry.get("properties", {})
	if definition.kind == "timed_gate":
		definition.close_after_ticks = int(properties.close_after_ticks)
	elif definition.kind in ["destructible", "prison_alarm", "paired_alarm"]:
		definition.max_health = float(properties.max_health)
	if definition.kind == "prison_alarm":
		definition.guard_id = properties.guard_id
	elif definition.kind == "paired_alarm":
		definition.partner_id = properties.partner_id
	elif definition.kind == "security_gate":
		definition.required_enemy_ids.assign(properties.get("required_enemy_ids", []))
		definition.required_object_ids.assign(properties.get("required_object_ids", []))
	return definition
