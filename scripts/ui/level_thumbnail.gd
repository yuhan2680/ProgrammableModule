class_name LevelThumbnail
extends RefCounted
## 将关卡快照转为 SVG 缩略图。仅用于选关显示，不修改地图、不创建模拟世界。
## 不按关卡 ID 选固定图片，因此导入关卡和刷新后的地图也能得到对应预览。

const SIZE := 160.0
const PADDING := 16.0
const MAX_GRID := 32
const BACKGROUND := Color("F5F8FE")


## 在内存中栅格化 SVG；用双倍分辨率保持高分屏上的矢量图标清晰。
static func create_texture(level: LevelDefinition, content: ContentRegistry) -> Texture2D:
	var image := Image.new()
	if image.load_svg_from_string(build_svg(level, content), 2.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


## 仅绘制地图内容，由按钮统一绘制白底与阴影，避免缩略图内部出现第二圈边缘。
static func build_svg(level: LevelDefinition, content: ContentRegistry) -> String:
	var document := level.document
	var bounds := _content_bounds(level)
	var scale := (SIZE - PADDING * 2.0) / maxf(bounds.size.x, bounds.size.y)
	var origin := (Vector2.ONE * SIZE - bounds.size * scale) / 2.0 - bounds.position * scale
	var elements := PackedStringArray([
		'<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160">',
	])
	# 大型导入地图最多绘制 32×32 个格子，避免每次刷新生成数万 SVG 节点。
	# 小地图保持原格子和正方形比例，大地图按统一比例合并，仅影响缩略显示。
	var stride := maxi(1, ceili(maxf(bounds.size.x, bounds.size.y) / MAX_GRID))
	# 裁切边界可能因居中留白带有半格偏移；分桶仍对齐整数网格，避免地板偏离起终点。
	var grid_origin := bounds.position.floor()
	var cells: Dictionary = {}
	for cell: Vector2i in document.cells:
		var tile := content.get_tile(document.get_tile_id(cell))
		if tile == null:
			continue
		var key := Vector2i(floori((cell.x - grid_origin.x) / stride), floori((cell.y - grid_origin.y) / stride))
		# 合并格子时优先保留可通行路线，细支道不应被同桶墙壁完全盖住。
		cells[key] = bool(cells.get(key, true)) and tile.collision
	var ordered: Array = cells.keys()
	ordered.sort_custom(_cell_before)
	for cell: Vector2i in ordered:
		var world_position := grid_origin + Vector2(cell) * stride
		var position := origin + world_position * scale
		var side := stride * scale
		var gap := minf(1.2, side * 0.1)
		var rectangle := Rect2(position + Vector2.ONE * gap / 2.0, Vector2.ONE * (side - gap))
		elements.append(_rect(rectangle, minf(2.6, side * 0.16), "#AABBD2" if cells[cell] else "#D7E6FA", "#B4CCEA", minf(0.8, side * 0.1)))
	for entry: Dictionary in document.objects:
		var object := MapObjectDefinition.from_entry(entry)
		if object == null:
			continue
		var center := origin + object.rect.get_center() * scale
		# 机关使用最小可辨识符号，缩略图不以符号尺寸代替实际碰撞占地。
		var side := clampf(object.rect.size.x * scale, 19.0, 28.0)
		elements.append(_object_icon(object.kind, center, side))
	for entry: Dictionary in document.enemies:
		if entry.get("behavior") in EnemyDefinition.BEHAVIORS:
			var point: Dictionary = entry.position
			var center := origin + Vector2(float(point.x), float(point.y)) * scale
			elements.append(_guard_icon(center) if entry.get("behavior") == EnemyDefinition.ALARM_GUARD else _enemy_icon(center))
	if document.player_spawn is Dictionary:
		var point: Dictionary = document.player_spawn.position
		var center := origin + Vector2(float(point.x), float(point.y)) * scale
		elements.append(_start_icon(center))
	if level.goal_type in ["reach_position", "escape_prison", "escape_alarms"]:
		var center := origin + level.goal_position * scale
		elements.append(_goal_icon(center))
	elements.append("</svg>")
	return "".join(elements)


## 裁去大块空白，保留全部地形与标记；空地板地图也能生成有效缩略图。
static func _content_bounds(level: LevelDefinition) -> Rect2:
	var document := level.document
	var bounds := Rect2()
	var initialized := false
	for cell: Vector2i in document.cells:
		var rect := Rect2(Vector2(cell), Vector2.ONE)
		bounds = bounds.merge(rect) if initialized else rect
		initialized = true
	if document.player_spawn is Dictionary:
		var position: Dictionary = document.player_spawn.position
		var rect := Rect2(Vector2(float(position.x), float(position.y)) - Vector2.ONE * 0.5, Vector2.ONE)
		bounds = bounds.merge(rect) if initialized else rect
		initialized = true
	if level.goal_type in ["reach_position", "escape_prison", "escape_alarms"]:
		var rect := Rect2(level.goal_position - Vector2.ONE * 0.5, Vector2.ONE)
		bounds = bounds.merge(rect) if initialized else rect
		initialized = true
	for entry: Dictionary in document.objects:
		var object := MapObjectDefinition.from_entry(entry)
		if object != null:
			bounds = bounds.merge(object.rect) if initialized else object.rect
			initialized = true
	for entry: Dictionary in document.enemies:
		if entry.get("behavior") in EnemyDefinition.BEHAVIORS:
			var point: Dictionary = entry.position
			var position := Vector2(float(point.x), float(point.y))
			var marker := Rect2(position - Vector2.ONE * 0.5, Vector2.ONE)
			bounds = bounds.merge(marker) if initialized else marker
			initialized = true
			# 敌人实际装配可伸出参考点，裁切应包含这些模块而不是只包含锚点。
			for module: Dictionary in entry.modules:
				var offset: Dictionary = module.offset
				var center := position + Vector2(float(offset.x), float(offset.y))
				var rect := Rect2(center - Vector2.ONE * 0.5, Vector2.ONE)
				bounds = bounds.merge(rect) if initialized else rect
				initialized = true
	if not initialized:
		return Rect2(Vector2.ZERO, Vector2.ONE * 3.0)
	# 单行直道仍居中显示，极小地图不会被放大成铺满整张图的一个方块。
	var size := bounds.size.max(Vector2.ONE * 3.0)
	return Rect2(bounds.get_center() - size / 2.0, size)


## 使用固定颜色及有限坐标绘制圆角格子，不把 JSON 文本拼接到 XML 属性中。
static func _rect(rect: Rect2, radius: float, fill: String, stroke: String, width: float) -> String:
	return '<rect x="%.3f" y="%.3f" width="%.3f" height="%.3f" rx="%.3f" fill="%s" stroke="%s" stroke-width="%.3f"/>' % [rect.position.x, rect.position.y, rect.size.x, rect.size.y, radius, fill, stroke, width]


## 起点以蓝色模块和右箭头标识，与实际游戏中的模块配色一致。
static func _start_icon(center: Vector2) -> String:
	return '<g transform="translate(%.3f %.3f)"><rect x="-7" y="-7" width="14" height="14" rx="4" fill="#167AF3" stroke="#FFFFFF" stroke-width="1.5"/><path d="m-2-3 3 3-3 3" fill="none" stroke="#C3F2FF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></g>' % [center.x, center.y]


## 位置目标显示绿色完成标记，摧毁目标则使用地图中的紫色障碍物符号。
static func _goal_icon(center: Vector2) -> String:
	return '<g transform="translate(%.3f %.3f)"><circle r="7" fill="#DDF3E9" stroke="#FFFFFF" stroke-width="1.5"/><path d="m-3 0 2 2.5 4-5" fill="none" stroke="#279779" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></g>' % [center.x, center.y]


## 敌人关卡使用珊瑚色双模块标记，与场地中的敌方轮廓颜色保持一致。
static func _enemy_icon(center: Vector2) -> String:
	return '<g transform="translate(%.3f %.3f)"><rect x="-14" y="-7" width="12" height="14" rx="3" fill="#F6CED5" stroke="#D96772"/><rect x="-1" y="-7" width="14" height="14" rx="4" fill="#D96772" stroke="#FFFFFF"/><path d="M2-3H5M8-3H11M3 3H10" stroke="#FFFFFF" stroke-width="1.8" stroke-linecap="round"/></g>' % [center.x, center.y]


## 以可缩放 SVG 符号呈现闸门和破障目标，避免运行时依赖外部位图。
static func _object_icon(kind: String, center: Vector2, side: float) -> String:
	var glyph: String
	if kind == "timed_gate":
		glyph = '<rect x="-12" y="-12" width="24" height="24" rx="6" fill="#FFF1D5" stroke="#E4B260"/><path d="M-7 7V-7H7V7M-3-7V3M3-7V3" fill="none" stroke="#B7812E" stroke-width="2" stroke-linecap="round"/><circle cx="7" cy="-9" r="5" fill="#FFFFFF" stroke="#B7812E" stroke-width="1.4"/><path d="M7-12v3h2" fill="none" stroke="#B7812E" stroke-width="1.3" stroke-linecap="round"/>'
	elif kind in ["prison_alarm", "paired_alarm"]:
		glyph = '<rect x="-12" y="-12" width="24" height="24" rx="6" fill="#FFF1DC" stroke="#E7B76D"/><path d="M-6 5H6L4 1v-5a4 4 0 0 0-8 0v5ZM-1 8H1" fill="#F8D193" stroke="#B77F27" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'
	elif kind == "security_gate":
		glyph = '<rect x="-12" y="-12" width="24" height="24" rx="6" fill="#E7EDF6" stroke="#B0C0D5"/><path d="M-7 7V-7H7V7M-3-7V7M3-7V7" fill="none" stroke="#8399B7" stroke-width="1.6"/><rect x="-4" y="-2" width="8" height="7" rx="2" fill="#F7FAFF" stroke="#5A7294"/><path d="M-2-2v-2a2 2 0 0 1 4 0v2" fill="none" stroke="#5A7294" stroke-width="1.5"/>'
	else:
		glyph = '<rect x="-12" y="-12" width="24" height="24" rx="6" fill="#EAE1F8" stroke="#AF92D6"/><path d="m0-8 7 4v8l-7 4-7-4v-8Zm-7 4 7 4 7-4M0 0v8" fill="#C8B4E5" stroke="#7F60AA" stroke-width="1.6" stroke-linejoin="round"/>'
	return '<g transform="translate(%.3f %.3f) scale(%.3f)">%s</g>' % [center.x, center.y, side / 24.0, glyph]


## 稳定地按行排序，使同一地图得到相同 SVG，便于刷新和维护时比较。
static func _cell_before(left: Vector2i, right: Vector2i) -> bool:
	return left.y < right.y or (left.y == right.y and left.x < right.x)


## 单模块警卫使用独立盾形符号，避免把第五关误画成第四关的双模块敌人。
static func _guard_icon(center: Vector2) -> String:
	return '<g transform="translate(%.3f %.3f)"><rect x="-8" y="-8" width="16" height="16" rx="5" fill="#FCE6EA" stroke="#D96772"/><path d="m0-5 5 2v3c0 3-5 5-5 5S-5 3-5 0v-3Z" fill="#D96772"/><path d="M-2-1H2M0-1V2" stroke="#FFFFFF" stroke-width="1.4" stroke-linecap="round"/></g>' % [center.x, center.y]
