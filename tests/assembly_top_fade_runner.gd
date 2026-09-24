extends SceneTree
## 真实装配页顶部渐隐回归；可选 GPU 双底色探针验证纸面、模块、选框和拖动预览一次透明合成。

const BLUE := Color(0.12, 0.32, 0.65)
const GREEN := Color(0.10, 0.65, 0.20)
var _checks := 0
var _failures := 0
var _changes := 0
var _temporary := ""
var _capture_directory := ""
var _original_transparent := false
var _game: GameShell
var _background: ColorRect


## 只有显式指定截图目录且存在真实显示驱动时才读取 GPU 像素。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 同一真实外壳覆盖两个窗口尺寸，所有设置与草稿仅使用本轮独占目录。
func _run() -> void:
	_temporary = "user://tests/assembly_top_fade_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	root.add_child(_game)
	await _settle()
	for child in _game.get_children():
		if child is ColorRect:
			_background = child
			break
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		var context := "%dx%d" % [dimensions.x, dimensions.y]
		var reference := await _settings_alpha(context)
		await _test_assembly(context, reference)
	_game.queue_free()
	await _settle()
	_check(root.transparent_bg == _original_transparent, "销毁页面恢复进入测试前的视口透明状态")
	_remove_tree(_temporary)
	print("装配顶部渐隐回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从真实设置行取得像素参考；独立于装配 shader 的参数和实现。
func _settings_alpha(context: String) -> Array[float]:
	var reference: Array[float] = []
	if not _gpu_enabled():
		return reference
	_game._show_settings_page()
	await _settle()
	var panel := _game.settings_panel
	var row := panel.find_child("VolumeRow", true, false) as Control
	var boundary := _game._back_button.get_global_rect().end.y
	panel._scroll.scroll_vertical += roundi(row.global_position.y - boundary + 8.0)
	await _settle()
	var pair := await _background_pair(context + "_settings")
	for offset in range(1, 45):
		reference.append(_opacity(pair, Vector2i(roundi(row.global_position.x + 12.0), ceili(boundary) + offset)))
	_game._show_main_page()
	await _settle()
	_check(root.transparent_bg == _original_transparent, "离开参考设置页恢复视口状态 " + context)
	return reference


## 实际安装、选择、缩放和右拖后，在顶部渐隐带内继续操作同一装配模型。
func _test_assembly(context: String, reference: Array[float]) -> void:
	_game.settings.set_assembly_free_zoom(false)
	var document := _game.catalog.levels[0].document.duplicate_document()
	document.id = "assembly_top_fade_" + context
	document.width = 12
	document.height = 12
	document.dialogue.clear()
	document.player_spawn.position = {"x": 6.5, "y": 6.5}
	document.properties.level.module_limit = 3
	document.properties.level.allowed_modules = ["movement"]
	document.properties.level.goal = null
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	var parsed := LevelDefinition.from_document(document, _game.registry)
	if not _check(parsed.is_ok(), "构造独占装配地图 " + context):
		return
	_game._enter_level(parsed.value)
	_game._dialogue_dialog.hide()
	await _settle()
	var canvas := _game.assembly_panel.canvas
	_game.session.assembly.changed.connect(_record_change)
	_click(_point(canvas, Vector2.ZERO))
	_click(_point(canvas, Vector2.ZERO))
	await _settle()
	if not _check(_game.session.assembly.modules.size() == 1 and canvas.selected_index == 0, "实际点击安装并选中模块 " + context):
		return
	_check(_game._save_current_draft(true), "保存基准草稿 " + context)
	var draft_path := _game.drafts._path(document.id, "draft")
	var draft_hash := FileAccess.get_sha256(draft_path)
	var signature := JSON.stringify(_game.session.assembly.modules, "", true)
	var changes := _changes
	_game.settings.set_assembly_free_zoom(true)
	await _settle()
	for step in 8:
		_click(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_WHEEL_UP)
	var from := _point(canvas, Vector2.ZERO)
	var target := canvas.global_position + Vector2(canvas.size.x * 0.5, 24.0)
	_drag(from, target, MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(_point(canvas, Vector2.ZERO).distance_to(target) < 1.0 and canvas._paper_rect().position.y < 0.0, "滚轮放大及右拖将模块和蓝图移入顶部渐隐区 " + context)
	_check(canvas.material == null and canvas._drawing_group.material != null and root.transparent_bg, "自由模式启用独立合成层和完整透明精度 " + context)
	await _capture(context + "_selected_top")
	if _gpu_enabled():
		await _check_gpu_layers(canvas, context, reference, false)
	var cell := canvas._cell_pixels()
	var ghost_point := target + Vector2(cell * 2.0, 0)
	_mouse_button(target, MOUSE_BUTTON_LEFT, true)
	_motion(ghost_point, ghost_point - target, MOUSE_BUTTON_MASK_LEFT)
	await _settle()
	_check(canvas._drag_index == 0 and canvas._drag_preview == Vector2(1.0, 0.0), "淡出中的模块仍能按原命中规则拖出预览 " + context)
	await _capture(context + "_ghost_top")
	if _gpu_enabled():
		await _check_gpu_layers(canvas, context, reference, true)
	_key(KEY_ESCAPE)
	_mouse_button(ghost_point, MOUSE_BUTTON_LEFT, false)
	_game.settings.set_assembly_free_zoom(false)
	await _settle()
	var paper := canvas._paper_rect()
	_check(Rect2(Vector2.ZERO, canvas.size).grow(0.1).encloses(paper) and not canvas.free_zoom_enabled and canvas._drag_index < 0, "关闭自由查看恢复完整图纸并取消拖动 " + context)
	_check(root.transparent_bg == _original_transparent, "固定模式释放透明精度请求 " + context)
	var origin := _point(canvas, Vector2.ZERO)
	_click(origin, MOUSE_BUTTON_WHEEL_UP)
	_drag(origin, origin + Vector2(60, -20), MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(canvas._paper_rect().is_equal_approx(paper) and _point(canvas, Vector2.ZERO).is_equal_approx(origin), "固定模式保持完整白框且忽略查看手势 " + context)
	await _capture(context + "_fixed")
	if _gpu_enabled():
		var pair := await _background_pair(context + "_fixed")
		_check(_opacity(pair, Vector2i(origin)) > 0.98, "固定模式模块与纸张保持不透明 " + context)
		var inset := 12.0 * canvas._paper_scale()
		var frame := Rect2(canvas.global_position + paper.position, paper.size).grow(-inset)
		for point: Vector2 in [Vector2(frame.get_center().x, frame.position.y), Vector2(frame.get_center().x, frame.end.y), Vector2(frame.position.x, frame.get_center().y), Vector2(frame.end.x, frame.get_center().y)]:
			_check(_has_white_frame(pair[0], Vector2i(point)), "固定图纸四边的原始白框均实际可见 " + context + str(point))
	_check(JSON.stringify(_game.session.assembly.modules, "", true) == signature and _changes == changes, "查看、取消预览与开关均不修改模块及模型信号 " + context)
	_check(FileAccess.get_sha256(draft_path) == draft_hash and not _game._draft_edited, "查看操作保留已保存草稿字节且不安排新保存 " + context)
	_game.settings.set_assembly_free_zoom(true)
	await _settle()
	_click(_game._back_button.get_global_rect().get_center())
	await _settle()
	_check(_game.page == GameShell.Page.LEVELS and root.transparent_bg == _original_transparent, "从自由装配页实际返回后恢复原视口状态 " + context)


## 用改变父底色后的像素差反推透明度；同一行所有不透明图层必须只经过同一次渐隐。
func _check_gpu_layers(canvas: AssemblyCanvas, context: String, reference: Array[float], ghost: bool) -> void:
	var suffix := "ghost" if ghost else "selected"
	var pair := await _background_pair(context + "_" + suffix)
	var origin := _point(canvas, Vector2.ZERO)
	var cell := canvas._cell_pixels()
	var paper_x := roundi(origin.x - cell * 2.0)
	var top := roundi(canvas.global_position.y)
	var largest_step := 0.0
	var layer_error := 0.0
	var settings_error := 0.0
	var intermediate := 0
	var previous := 0.0
	var profile: Array[float] = []
	for offset in range(1, 53):
		var alpha := _opacity(pair, Vector2i(paper_x, top + offset))
		profile.append(alpha)
		if alpha > 0.03 and alpha < 0.97:
			intermediate += 1
		if offset > 1:
			largest_step = maxf(largest_step, absf(alpha - previous))
		previous = alpha
		if offset <= reference.size():
			settings_error = maxf(settings_error, absf(alpha - reference[offset - 1]))
		if absf(float(top + offset) - origin.y) < cell * 0.5 - 2.0:
			# 原件中心、选框竖边及预览都叠在纸面上，逐层淡出会让这些位置明显更不透明。
			var samples := [roundi(origin.x), roundi(origin.x - cell * 0.5)]
			if ghost:
				samples.append(roundi(origin.x + cell * 2.0))
			for x: int in samples:
				layer_error = maxf(layer_error, absf(alpha - _opacity(pair, Vector2i(x, top + offset))))
	_check(profile[0] < 0.03 and profile[23] > 0.46 and profile[23] < 0.56 and profile[47] > 0.98, "顶部透出底色，约24像素半透明、48像素恢复完整内容 " + context + suffix)
	_check(intermediate >= 32 and largest_step < 0.06, "顶部渐隐连续且没有裁切跳变 " + context + suffix)
	_check(settings_error < 0.035 and not reference.is_empty(), "装配与真实设置行使用一致的可见渐隐曲线 " + context + suffix)
	_check(layer_error < 0.035, "纸面、模块、选框及拖动预览整体淡出，无逐层叠浓 " + context + suffix)
	var outside: Color = pair[0].get_pixel(ceili(canvas.global_position.x) - 3, top + 24)
	_check(_color_distance(outside, BLUE) < 0.03, "画布外原底色保持清晰，没有白雾遮罩 " + context + suffix)
	var corner := Vector2i(roundi(canvas.global_position.x) + 8, top + 24)
	if canvas._paper_rect().has_point(Vector2(8, 24)):
		_check(_opacity(pair, corner) < profile[23] and _opacity(pair, corner) >= 0.0, "顶部与侧边在角落连续合并透明度 " + context + suffix)
	print("装配GPU证据 %s %s：alpha(1/24/48)=%.3f/%.3f/%.3f，设置差 %.4f，图层差 %.4f，最大阶差 %.4f。" % [context, suffix, profile[0], profile[23], profile[47], settings_error, layer_error, largest_step])


## 两帧使用完全相同场景和输入，只切换正式页面背景的颜色。
func _background_pair(prefix: String) -> Array[Image]:
	var original := _background.color
	var card: PanelContainer
	var original_style: StyleBox
	var probe_style: StyleBoxFlat
	if _game.page == GameShell.Page.ASSEMBLY:
		# 装配画布的实际父底色来自白卡，全局背景在卡后；只替换卡的底色才能测到透明合成。
		card = _game.assembly_panel._editor_card
		original_style = card.get_theme_stylebox("panel")
		probe_style = original_style.duplicate() as StyleBoxFlat
		card.add_theme_stylebox_override("panel", probe_style)
		probe_style.bg_color = BLUE
	_background.color = BLUE
	await _settle()
	var blue := await _capture(prefix + "_blue")
	if probe_style != null:
		probe_style.bg_color = GREEN
	_background.color = GREEN
	await _settle()
	var green := await _capture(prefix + "_green")
	if card != null:
		card.add_theme_stylebox_override("panel", original_style)
	_background.color = original
	await _settle()
	return [blue, green]


## 已知父底色差乘以一减最终透明度，能区分透明遮罩和白色覆盖。
func _opacity(pair: Array[Image], point: Vector2i) -> float:
	return 1.0 - _color_distance(pair[0].get_pixelv(point), pair[1].get_pixelv(point)) / _color_distance(BLUE, GREEN)


## 只比较 RGB，避免操作系统窗口 alpha 对像素证据产生影响。
func _color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## 在预期边框附近容许亚像素抗锯齿，但蓝纸和浅蓝细格不能冒充白框。
func _has_white_frame(picture: Image, point: Vector2i) -> bool:
	var reference := picture.get_pixel(point.x - 5, point.y - 5)
	for y in range(point.y - 2, point.y + 3):
		for x in range(point.x - 2, point.x + 3):
			var color := picture.get_pixel(x, y)
			if color.r > reference.r + 0.18 and color.g > 0.60 and color.b > 0.75:
				return true
	return false


## 记录模型真实变更，不以内容相同掩盖多余的编辑或草稿提交。
func _record_change() -> void:
	_changes += 1


## 所有编辑和查看输入均通过真实根视口分发。
func _point(canvas: AssemblyCanvas, offset: Vector2) -> Vector2:
	return canvas.get_global_transform_with_canvas() * canvas.pixel_at(offset)


## 点击同时发送移动、按下和松开，以保留原生命中语义。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_motion(point)
	_mouse_button(point, button, true)
	_mouse_button(point, button, false)


## 拖动携带正确的按键掩码，右键只改变观察状态。
func _drag(from: Vector2, to: Vector2, button: MouseButton) -> void:
	_motion(from)
	_mouse_button(from, button, true)
	_motion(to, to - from, MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(to, button, false)


## 通过根窗口发送按键事件，不直接调用画布回调。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	if pressed and button <= MOUSE_BUTTON_MIDDLE:
		event.button_mask = 1 << (button - 1)
	root.push_input(event)


## 鼠标拖动测试保留相对位移及全局坐标。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event)


## Escape 走原画布焦点路径取消未提交预览。
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)


## 等待输入、容器布局和绘制请求被场景树处理。
func _settle() -> void:
	for frame in 5:
		await process_frame


## 无显示驱动时只验证交互与生命周期，不把 headless 空白图冒充 GPU 证据。
func _gpu_enabled() -> bool:
	return not _capture_directory.is_empty() and DisplayServer.get_name() != "headless"


## 可选画面直接来自真实根视口，保存后继续用于像素断言。
func _capture(filename: String) -> Image:
	if not _gpu_enabled():
		return null
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(picture.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存GPU画面 " + filename)
	return picture


## 累积独立失败，让一次运行报告两个窗口尺寸的完整结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 仅清理本轮明确建立的测试目录，绝不读写真实玩家存档。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
