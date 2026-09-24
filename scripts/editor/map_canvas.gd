class_name MapCanvas
extends Control
## 画布仅负责呈现和发出绘制意图，所有文档修改由编辑器模型执行。

signal stroke_started
signal cell_requested(cell: Vector2i, erase: bool)
signal stroke_finished

const ATTACK_BEAM_COLOR := Color("951616")
const ATTACK_PULSE_SLOW := 0.75
const ATTACK_PULSE_FAST := 2.5
const ATTACK_WARNING_DISTANCE := 4.0
const VOID_STONE: Texture2D = preload("res://assets/tiles/void_stone.png")
const VOID_STONE_SPAN := 8.0
# 抵消源图偏暗的均色，再与原浅蓝灰底混合，保留轻微石纹起伏。
const VOID_STONE_TINT := Color(1.1507, 1.1420, 1.1243, 0.45)
const FLOOR_TILE_PATH := "res://assets/tiles/floor.svg"
const FLOOR_SCRATCHED: Texture2D = preload("res://assets/tiles/floor_scratched.png")
# 两套重绘纹理每格约 157 个像素，覆盖编辑器最高倍率的 128 像素格子。
const FLOOR_TEXTURE_SPAN := 8.0
# 细划痕保持清晰，但降低混合强度，让道路继续明亮、平缓。
const FLOOR_TEXTURE_TINT := Color(1.4, 1.4, 1.4, 0.24)

var document: MapDocument
var registry: ContentRegistry
var world: SimulationWorld
var cell_size: float = 32.0
var editing_enabled: bool = true
var _drag_button: int = 0
var _last_cell := Vector2i(-1, -1)
var _textures: Dictionary = {}
var _void_surface: CanvasTexture
var _floor_surface: CanvasTexture
var _floor_interior := PackedVector2Array()
var _attack_visual_world: SimulationWorld
var _attack_phases: Array[float] = []
var _wreck_ages: Dictionary = {}
var wreck_animation_enabled := false:
	set(value):
		wreck_animation_enabled = value
		_sync_attack_animation()
var show_defeat_attack_feedback := false
var attack_animation_enabled := false:
	set(value):
		attack_animation_enabled = value
		_sync_attack_animation()


# 用途：使画布接收鼠标输入，并在鼠标离开画布后仍能结束拖动。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)
	_sync_attack_animation()


# 用途：依据地图尺寸更新滚动区域大小并请求重绘。
func refresh() -> void:
	if document != null:
		custom_minimum_size = Vector2(document.width, document.height) * cell_size
	_sync_attack_animation()
	queue_redraw()


## 根据真实攻击及残骸决定是否刷新；暂停冻结显示时间，换世界清空所有相位。
func _sync_attack_animation() -> void:
	if _attack_visual_world != world:
		_attack_visual_world = world
		_attack_phases.clear()
		_wreck_ages.clear()
	var count := world.attack_traces.size() if world != null else 0
	while _attack_phases.size() < count:
		_attack_phases.append(0.0)
	_attack_phases.resize(count)
	if world != null:
		for machine: MachineInstance in world.machines:
			if machine != world.player and machine.is_destroyed() and world.get_enemy_wreck_fade_seconds(machine.id) > 0.0 and not _wreck_ages.has(machine.id):
				_wreck_ages[machine.id] = 0.0
	set_process(is_visible_in_tree() and ((attack_animation_enabled and count > 0) or _has_fading_wrecks()))


## 亮暗相位按显示帧连续累积，距离变化只改变频率，不推进世界或修改攻击反馈。
func _process(delta: float) -> void:
	if world == null or not is_visible_in_tree():
		return
	if wreck_animation_enabled:
		for machine_id: String in _wreck_ages:
			_wreck_ages[machine_id] = minf(float(_wreck_ages[machine_id]) + delta, world.get_enemy_wreck_fade_seconds(machine_id))
	for index in (mini(_attack_phases.size(), world.attack_traces.size()) if attack_animation_enabled else 0):
		var trace := world.attack_traces[index]
		var rate := _attack_pulse_rate(trace.get("display_to", trace.to))
		_attack_phases[index] = fposmod(_attack_phases[index] + delta * TAU * rate, TAU)
	_sync_attack_animation()
	queue_redraw()


## 只在仍有可见残骸时保留帧刷新，已消失残骸不会无限重绘。
func _has_fading_wrecks() -> bool:
	if world == null or not wreck_animation_enabled:
		return false
	for machine_id: String in _wreck_ages:
		if float(_wreck_ages[machine_id]) < world.get_enemy_wreck_fade_seconds(machine_id):
			return true
	return false


## 整机被毁才淡出；部分损坏、旧关卡及玩家的显示保持原语义。
func enemy_wreck_opacity(machine: MachineInstance) -> float:
	if world == null or machine == world.player or not _wreck_ages.has(machine.id):
		return 1.0
	var duration := world.get_enemy_wreck_fade_seconds(machine.id)
	return 1.0 - clampf(float(_wreck_ages[machine.id]) / duration, 0.0, 1.0) if duration > 0.0 else 1.0


## 用光束前端到存活玩家模块实际矩形的最近距离调整警示频率，包含模块偏移与大小。
func _attack_pulse_rate(tip: Vector2) -> float:
	if world == null or world.player == null:
		return ATTACK_PULSE_SLOW
	var gap := INF
	for module in world.player.modules:
		if not module.available:
			continue
		var rect := module.get_world_rect(world.player.position)
		var nearest := Vector2(clampf(tip.x, rect.position.x, rect.end.x), clampf(tip.y, rect.position.y, rect.end.y))
		gap = minf(gap, tip.distance_to(nearest))
	if not is_finite(gap):
		return ATTACK_PULSE_SLOW
	return lerpf(ATTACK_PULSE_FAST, ATTACK_PULSE_SLOW, smoothstep(0.0, ATTACK_WARNING_DISTANCE, gap))


# 用途：内容重载后清空图片缓存，使磁盘上修改的贴图及时显示。
func clear_texture_cache() -> void:
	_textures.clear()
	queue_redraw()


# 用途：结束尚未完成的笔画，供切换文档或进入测试前调用。
func finish_stroke() -> void:
	if _drag_button != 0:
		_drag_button = 0
		stroke_finished.emit()


# 用途：捕获画布外的鼠标松开事件，防止一次绘制事务一直保持打开。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed and event.button_index == _drag_button:
		finish_stroke()


# 用途：将左键绘制与右键擦除转换为不依赖具体地图模型的编辑信号。
func _on_gui_input(event: InputEvent) -> void:
	if not editing_enabled or document == null:
		return
	if event is InputEventMouseButton:
		if event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			return
		if event.pressed:
			finish_stroke()
			_drag_button = event.button_index
			_last_cell = Vector2i(floori(event.position.x / cell_size), floori(event.position.y / cell_size))
			stroke_started.emit()
			cell_requested.emit(_last_cell, _drag_button == MOUSE_BUTTON_RIGHT)
		else:
			finish_stroke()
		accept_event()
	elif event is InputEventMouseMotion and _drag_button != 0:
		var cell := Vector2i(floori(event.position.x / cell_size), floori(event.position.y / cell_size))
		_paint_line(_last_cell, cell)
		_last_cell = cell
		accept_event()


# 用途：补齐快速拖动时跳过的网格，保证一笔绘制的地块连续。
func _paint_line(from: Vector2i, to: Vector2i) -> void:
	var delta := to - from
	var count: int = maxi(absi(delta.x), absi(delta.y))
	for index: int in range(1, count + 1):
		var cell := Vector2i((Vector2(from) + Vector2(delta) * float(index) / float(count)).round())
		cell_requested.emit(cell, _drag_button == MOUSE_BUTTON_RIGHT)


# 用途：绘制显式地块、void 网格，以及编辑出生点或运行中的机器。
func _draw() -> void:
	if document == null or registry == null:
		return
	var extent := Vector2(document.width, document.height) * cell_size
	_draw_void_surface(extent)
	for cell: Vector2i in document.cells:
		var definition: TileDefinition = registry.get_tile(document.get_tile_id(cell))
		if definition == null:
			continue
		var rect := Rect2(Vector2(cell) * cell_size, Vector2.ONE * cell_size)
		draw_rect(rect, Color("FBFCFE") if not definition.collision else GameTheme.VOID)
		var texture := _get_texture(definition.texture)
		if texture != null:
			draw_texture_rect(texture, rect, false)
			if definition.texture == FLOOR_TILE_PATH:
				_draw_floor_surface(cell)
	for x: int in range(document.width + 1):
		draw_line(Vector2(x * cell_size, 0), Vector2(x * cell_size, extent.y), Color(0.52, 0.61, 0.75, 0.12))
	for y: int in range(document.height + 1):
		draw_line(Vector2(0, y * cell_size), Vector2(extent.x, y * cell_size), Color(0.52, 0.61, 0.75, 0.12))
	_draw_objects()
	if world != null:
		for machine: MachineInstance in world.machines:
			var opacity := enemy_wreck_opacity(machine)
			if opacity <= 0.0:
				continue
			for module: ModuleInstance in machine.modules:
				_draw_module(machine.position + module.local_position, module.definition, Color(1, 1, 1, opacity) if module.available else Color(0.5, 0.5, 0.5, 0.3 * opacity))
				if machine != world.player:
					_draw_enemy_health(module, machine.position, opacity)
			_draw_anchor(machine.position, Color("E4F3FF") if machine == world.player else Color(Color("D96772"), opacity))
		_draw_projectiles()
	elif document.player_spawn != null:
		var spawn: Dictionary = document.player_spawn
		var position_data: Dictionary = spawn.get("position", {})
		var position := Vector2(float(position_data.get("x", 0)), float(position_data.get("y", 0)))
		for item: Dictionary in spawn.get("modules", []):
			var definition := registry.get_module(str(item.get("module_id", "")))
			if definition == null:
				continue
			var offset: Dictionary = item.get("offset", {})
			_draw_module(position + Vector2(float(offset.get("x", 0)), float(offset.get("y", 0))), definition, Color(1, 1, 1, 0.86))
		_draw_anchor(position, GameTheme.SUCCESS)
	if world == null:
		_draw_enemy_preview()
	draw_rect(Rect2(Vector2.ZERO, extent), GameTheme.LINE, false, 1)


## 在地块下方连续铺浅色石纹，纹理固定在地图坐标中，缩放时不滑动或逐格重复。
func _draw_void_surface(extent: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, extent), GameTheme.VOID)
	if _void_surface == null:
		_void_surface = CanvasTexture.new()
		_void_surface.diffuse_texture = VOID_STONE
		_void_surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_void_surface.texture_repeat = CanvasItem.TEXTURE_REPEAT_MIRROR
	var uv_extent := Vector2(document.width, document.height) / VOID_STONE_SPAN
	var corners := PackedVector2Array([Vector2.ZERO, Vector2(extent.x, 0), extent, Vector2(0, extent.y)])
	var uv := PackedVector2Array([Vector2.ZERO, Vector2(uv_extent.x, 0), uv_extent, Vector2(0, uv_extent.y)])
	# 单次绘制覆盖任意地图，不按格子创建纹理或节点；原地块底色仍完全覆盖石纹。
	draw_polygon(corners, PackedColorArray([VOID_STONE_TINT]), uv, _void_surface)


## 只为原白地板填入高亮划痕；自定义地块图片不受影响，也不以贴图判断通行规则。
func _draw_floor_surface(cell: Vector2i) -> void:
	if _floor_surface == null:
		_floor_surface = CanvasTexture.new()
		_floor_surface.diffuse_texture = FLOOR_SCRATCHED
		_floor_surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_floor_surface.texture_repeat = CanvasItem.TEXTURE_REPEAT_MIRROR
		# 沿原 64 像素 SVG 描边内侧裁切，石纹不会覆盖圆角外部或边框。
		var centers := [Vector2(10.5, 10.5), Vector2(53.5, 10.5), Vector2(53.5, 53.5), Vector2(10.5, 53.5)]
		for corner in 4:
			for segment in 5:
				var angle := PI + float(corner) * PI * 0.5 + float(segment) * PI * 0.125
				_floor_interior.append((centers[corner] + Vector2.from_angle(angle) * 8.25) / 64.0)
	var uv := PackedVector2Array()
	for point in _floor_interior:
		uv.append((Vector2(cell) + point) / FLOOR_TEXTURE_SPAN)
	draw_set_transform(Vector2(cell) * cell_size, 0, Vector2.ONE * cell_size)
	draw_polygon(_floor_interior, PackedColorArray([FLOOR_TEXTURE_TINT]), uv, _floor_surface)
	draw_set_transform(Vector2.ZERO)


## 编辑器与准备阶段只读取敌人装配快照，不创建 AI 或偷偷推进战斗。
func _draw_enemy_preview() -> void:
	for entry: Dictionary in document.enemies:
		if not entry.get("behavior") in EnemyDefinition.BEHAVIORS:
			continue
		var point: Dictionary = entry.position
		var position := Vector2(float(point.x), float(point.y))
		for item: Dictionary in entry.modules:
			var definition := registry.get_module(str(item.module_id))
			if definition == null:
				continue
			var offset: Dictionary = item.offset
			var center := position + Vector2(float(offset.x), float(offset.y))
			_draw_module(center, definition, Color(1, 0.87, 0.87))
			var rect := Rect2((center - definition.size * 0.5) * cell_size, definition.size * cell_size)
			draw_rect(rect, Color("D96772"), false, 1.5)
		_draw_anchor(position, Color("D96772"))


## 每个敌方模块单独展示耐久，玩家能看见打坏移动模块后仍存活的近战模块。
func _draw_enemy_health(module: ModuleInstance, machine_position: Vector2, opacity: float = 1.0) -> void:
	var rect := module.get_world_rect(machine_position)
	rect = Rect2(rect.position * cell_size, rect.size * cell_size)
	if not module.available:
		draw_line(rect.position, rect.end, Color(Color("A6AEBB"), opacity), 1.5, true)
		return
	draw_rect(rect, Color("D96772"), false, 1.5)
	var ratio := clampf(module.health / module.max_health, 0.0, 1.0)
	var bar := Rect2(rect.position - Vector2(0, 5), Vector2(rect.size.x, 3))
	draw_rect(bar, Color("E7D7DD"))
	bar.size.x *= ratio
	draw_rect(bar, Color("D96772"))


## 子弹的坐标和速度来自模拟层；尾迹长短只用于显示，不改变命中和伤害。
func _draw_projectiles() -> void:
	for bullet in world.projectiles:
		var center: Vector2 = bullet.position * cell_size
		var trail: Vector2 = bullet.direction * minf(0.3, bullet.speed * 0.025) * cell_size
		draw_line(center - trail, center, Color("E8AA37"), 3.0, true)
		draw_circle(center, 3.0, Color("FFD77A"))


# 用途：按模块实际占地绘制中心对齐的图像和边框。
func _draw_module(position: Vector2, definition: ModuleDefinition, tint: Color) -> void:
	var rect := Rect2((position - definition.size / 2.0) * cell_size, definition.size * cell_size)
	draw_rect(rect, GameTheme.ACCENT * tint)
	var texture := _get_texture(definition.texture)
	if texture != null:
		draw_texture_rect(texture, rect, false, tint)
	draw_rect(rect, Color("98C6FF") * tint, false, 1.5)


# 用途：标记机器坐标原点，帮助核对出生位置和连续移动的位置。
func _draw_anchor(position: Vector2, color: Color) -> void:
	var center := position * cell_size
	draw_line(center - Vector2(5, 0), center + Vector2(5, 0), color, 1.5)
	draw_line(center - Vector2(0, 5), center + Vector2(0, 5), color, 1.5)


# 用途：缓存内容定义指定的纹理，资源缺失时让画布使用基础色块。
func _get_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not _textures.has(path):
		if path == FLOOR_TILE_PATH:
			var floor_frame := _load_floor_frame()
			if floor_frame != null:
				_textures[path] = floor_frame
				return floor_frame
		var result := ContentTextureLoader.load_texture(path)
		_textures[path] = result.value as Texture2D if result.is_ok() else null
	return _textures[path] as Texture2D


## 从矢量原图绘制高分辨率地板边框，避免放大时仍拉伸 64 像素边框；导出包回退到导入资源。
func _load_floor_frame() -> Texture2D:
	var texture: Texture2D
	if FileAccess.file_exists(FLOOR_TILE_PATH):
		var image := Image.new()
		if image.load_svg_from_buffer(FileAccess.get_file_as_bytes(FLOOR_TILE_PATH), 4.0) != OK or image.is_empty():
			return null
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	else:
		var result := ContentTextureLoader.load_texture(FLOOR_TILE_PATH)
		if not result.is_ok():
			return null
		texture = result.value as Texture2D
	var surface := CanvasTexture.new()
	surface.diffuse_texture = texture
	surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return surface


## 编辑器从静态定义预览，运行时从独立对象状态绘制，画布不参与胜负或倒计时。
func _draw_objects() -> void:
	var display_objects: Array[WorldObject] = []
	if world != null:
		display_objects = world.objects
	else:
		for entry: Dictionary in document.objects:
			var definition := MapObjectDefinition.from_entry(entry)
			if definition != null:
				display_objects.append(WorldObject.create(definition))
	for object in display_objects:
		var definition := object.definition
		var rect := Rect2(definition.rect.position * cell_size, definition.rect.size * cell_size)
		var closed := object.is_blocking(world.tick_index if world != null else 0)
		if definition.kind in ["destructible", "prison_alarm", "paired_alarm"] and object.health <= 0:
			draw_arc(rect.get_center(), cell_size * 0.22, 0, TAU, 32, GameTheme.SUCCESS, 2.0, true)
			continue
		var path := "res://assets/objects/obstacle.svg"
		if definition.kind == "timed_gate":
			path = "res://assets/objects/gate_closed.svg" if closed else "res://assets/objects/gate_open.svg"
		elif definition.kind in ["prison_alarm", "paired_alarm"]:
			path = "res://assets/objects/prison_alarm.svg"
		elif definition.kind == "security_gate":
			path = "res://assets/objects/security_gate_closed.svg" if closed else "res://assets/objects/security_gate_open.svg"
		var texture := _get_texture(path)
		if texture != null:
			draw_texture_rect(texture, rect, false)
	if world != null:
		var traces := _attack_traces_for_display()
		for index in traces.size():
			var phase := _attack_phases[index] if index < _attack_phases.size() else 0.0
			_draw_attack_beam(traces[index], phase)


## 失败画面保留刚刚摧毁玩家部件的真实接触；其他时刻始终显示当前 tick 的攻击。
func _attack_traces_for_display() -> Array[Dictionary]:
	var traces: Array[Dictionary] = world.attack_traces.duplicate()
	if not show_defeat_attack_feedback:
		return traces
	for contact: Dictionary in world.get_player_defeat_attack_traces():
		# 只替换同一个发射模块的后续光束，不干扰其他攻击者或伪造新命中。
		for index in range(traces.size() - 1, -1, -1):
			var trace := traces[index]
			if trace.get("source_machine_id") == contact.source_machine_id and trace.get("source_module_id") == contact.source_module_id:
				traces.remove_at(index)
		contact["defeat_contact"] = true
		traces.append(contact)
	return traces


## 从发射模块向外扩散，横向柔化光束边缘，纵向完整保留至实际命中点。
func _draw_attack_beam(trace: Dictionary, phase: float) -> void:
	var start: Vector2 = trace.get("display_from", trace.from) * cell_size
	var end: Vector2 = trace.get("display_to", trace.to) * cell_size
	var length := start.distance_to(end)
	if length < 0.1:
		return
	var brightness := lerpf(0.60, 1.0, (cos(phase) + 1.0) * 0.5)
	# 最后一帧保留清楚的致命攻击反馈，避免失败后停在光束暗相。
	if trace.get("defeat_contact", false) or (world.player != null and world.player.is_destroyed()):
		brightness = 1.0
	brightness *= _attack_trace_opacity(trace)
	if brightness <= 0.0:
		return
	var normal := (end - start).orthogonal() / length
	var source_radius := maxf(cell_size * 0.025, 0.9)
	var tip_radius := source_radius + length * 0.115
	_draw_attack_cone(start, end, normal, source_radius * 2.0, tip_radius * 1.65, 0.12 * brightness)
	_draw_attack_cone(start, end, normal, source_radius, tip_radius, 0.98 * brightness)


## 用连续插值的横向透明度形成柔和扩散光，不把射程末端渐隐成视觉上的空隙。
func _draw_attack_cone(start: Vector2, end: Vector2, normal: Vector2, source_radius: float, tip_radius: float, alpha: float) -> void:
	const STRIPS := 20
	for index in STRIPS:
		var lower := -1.0 + 2.0 * float(index) / STRIPS
		var upper := -1.0 + 2.0 * float(index + 1) / STRIPS
		var lower_color := Color(ATTACK_BEAM_COLOR, alpha * (1.0 - smoothstep(0.15, 1.0, absf(lower))))
		var upper_color := Color(ATTACK_BEAM_COLOR, alpha * (1.0 - smoothstep(0.15, 1.0, absf(upper))))
		draw_polygon(PackedVector2Array([
			start + normal * source_radius * lower,
			end + normal * tip_radius * lower,
			end + normal * tip_radius * upper,
			start + normal * source_radius * upper,
		]), PackedColorArray([lower_color, lower_color, upper_color, upper_color]))


## 同 tick 击毁的敌人可能留下最后一道光束；它与残骸一起淡出，旧关卡反馈保持不变。
func _attack_trace_opacity(trace: Dictionary) -> float:
	if world == null:
		return 1.0
	var source := world.get_machine(str(trace.get("source_machine_id", "")))
	return enemy_wreck_opacity(source) if source != null else 1.0
