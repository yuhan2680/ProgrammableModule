extends SceneTree
## 开放地图视区回归；真实输入检查边界，GPU 双色底反推最终透明度而不读取渐隐参数。

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


## 只有显式指定输出目录才运行 GPU 像素检查，headless 不冒充视觉验证。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 真实编辑器使用独占设置、地图与草稿目录，销毁后检查视口状态完整恢复。
func _run() -> void:
	_temporary = "user://tests/map_editor_edge_fade_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	_game = load("res://scenes/map_editor.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	for child in _game.get_children():
		if child is ColorRect:
			_background = child
			break
	_game._editor.editor_document.changed.connect(_record_change)
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		await _test_view("%dx%d" % [dimensions.x, dimensions.y])
	_game.queue_free()
	await _settle()
	_check(root.transparent_bg == _original_transparent, "销毁编辑器后恢复进入前的视口透明状态")
	_remove_tree(_temporary)
	print("地图编辑器边缘渐隐回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 小地图应完整清晰；放大后仅可见边缘渐隐，查看手势不修改地图或已保存字节。
func _test_view(context: String) -> void:
	var editor := _game._editor
	var view := editor._map_view
	var canvas := editor._canvas
	var model := editor.editor_document
	_load_fixture("small_" + context, Vector2i(8, 6))
	await _settle()
	var region := editor.find_child("MapEditorMapRegion", true, false) as Control
	_check(region != null and view.get_global_rect().is_equal_approx(region.get_global_rect()), "地图视区扩展至原卡片外框，不再保留卡片内边距 " + context)
	_check(view.get_global_rect().encloses(canvas.get_global_rect()) and is_equal_approx(view.zoom, 1.0), "小地图保持完整的一倍原图 " + context)
	_check(not view._h_scroll.visible and not view._v_scroll.visible, "小地图不产生空滚动轨道 " + context)
	await _capture(context + "_small")
	if _gpu_enabled():
		var pair := await _background_pair()
		var outside := Vector2i(view.global_position + Vector2(12, 12))
		_check(_distance(pair[0].get_pixelv(outside), BLUE) < 0.025 and _distance(pair[1].get_pixelv(outside), GREEN) < 0.025, "小地图外直接透出页面背景，没有白色卡片或残影 " + context)
		var canvas_edge := Vector2i(canvas.global_position + Vector2(1, canvas.size.y * 0.5))
		_check(_opacity(pair, canvas_edge) > 0.98, "远离视区边界的小地图自身边缘保持清晰不透明 " + context)
	_load_fixture("overflow_" + context, Vector2i(32, 24))
	await _settle()
	editor._save_document(false)
	var saved_path := model.path
	if not _check(not saved_path.is_empty() and FileAccess.file_exists(saved_path) and not model.is_dirty(), "隔离地图成功保存并建立干净基准 " + context):
		return
	var saved_hash := FileAccess.get_sha256(saved_path)
	var signature := _signature(model)
	var changes := _changes
	view.set_zoom(1.25)
	await _settle()
	_check(view._h_scroll.visible and view._v_scroll.visible and not view.get_global_rect().encloses(canvas.get_global_rect()), "放大地图真实超出四边并显示两条滚动条 " + context)
	_check(is_equal_approx(view._v_scroll.position.y, 0.0) and is_equal_approx(view._v_scroll.size.y, view.usable_rect.size.y), "顶部工具迁出后竖滚动条覆盖整个有效地图高度 " + context)
	await _capture(context + "_overflow")
	if _gpu_enabled():
		await _check_gpu_fade(context)
	# 用真实工具栏信号及滚轮更新比例，原地图坐标应始终落在有效画幅中心。
	var center := view.view_center
	_click(editor._zoom_in_button.get_global_rect().get_center())
	await _settle()
	_check(view.zoom > 1.25 and view.view_center.is_equal_approx(center), "顶部放大按钮保留地图观察中心 " + context)
	var visible_center := view.global_position + view.usable_rect.get_center()
	_click(visible_center, MOUSE_BUTTON_WHEEL_DOWN)
	await _settle()
	_check(is_equal_approx(view.zoom, 1.25) and _map_point(canvas, visible_center).is_equal_approx(center), "新的合成父层不会阻断滚轮或改变画布坐标 " + context)
	view._h_scroll.value += canvas.cell_size * 2.0
	view._v_scroll.value += canvas.cell_size
	await _settle()
	_check(_map_point(canvas, view.global_position + view.usable_rect.get_center()).is_equal_approx(view.view_center), "双向滚动后屏幕中心仍准确对应当前地图观察点 " + context)
	_check(_signature(model) == signature and model.path == saved_path and not model.is_dirty() and model._undo_stack.is_empty() and _changes == changes, "显示、滚轮和滚动条不改地图、路径、dirty、撤销或变更信号 " + context)
	_check(FileAccess.get_sha256(saved_path) == saved_hash, "查看操作没有改写已保存地图字节 " + context)
	# 地图在视区外仍有真实格子，但裁剪外的点击不得作用于它们。
	var outside_top := view.global_position + Vector2(view.usable_rect.size.x * 0.5, -4)
	_click(outside_top, MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(_signature(model) == signature and model._action_depth == 0, "画幅外点击不能擦除被裁剪的地图格子 " + context)
	var edge_point := view.global_position + Vector2(20, view.usable_rect.size.y * 0.5)
	var cell := Vector2i(_map_point(canvas, edge_point).floor())
	_click(edge_point, MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(model.document.get_tile_id(cell).is_empty() and model.document.get_tile_id(cell + Vector2i.RIGHT) == "floor" and model._undo_stack.size() == 1, "渐隐区域仍能准确擦除对应格子，不偏移到邻格 " + context)
	model.undo()
	_check(_signature(model) == signature and not model.is_dirty(), "边缘编辑可一次撤销回已保存地图 " + context)


## 以两个父底色取得的像素差测量四边，不把 shader 数值当作视觉证据。
func _check_gpu_fade(context: String) -> void:
	var editor := _game._editor
	var view := editor._map_view
	var bounds := Rect2(view.global_position + view.usable_rect.position, view.usable_rect.size)
	var pair := await _background_pair()
	for edge in 4:
		var previous := 0.0
		var largest_step := 0.0
		var reversals := 0.0
		var intermediate := 0
		var profile: Array[float] = []
		for distance in range(1, 69):
			var point := _edge_point(bounds, edge, distance)
			var alpha := _opacity(pair, Vector2i(point))
			profile.append(alpha)
			if alpha > 0.03 and alpha < 0.97:
				intermediate += 1
			if distance > 1:
				largest_step = maxf(largest_step, absf(alpha - previous))
				reversals = maxf(reversals, previous - alpha)
			previous = alpha
		_check(profile[0] < 0.04 and profile[67] > 0.98 and intermediate >= 28, "边缘透出真实背景并逐渐恢复不透明：" + str(edge) + " " + context)
		_check(largest_step < 0.065 and reversals < 0.03, "边缘透明变化连续单调，没有硬切或条带：" + str(edge) + " " + context)
		print("编辑器GPU %s 边%d alpha(1/24/48/68)=%.3f/%.3f/%.3f/%.3f 最大阶差=%.4f" % [context, edge, profile[0], profile[23], profile[47], profile[67], largest_step])
	_check(_opacity(pair, Vector2i(bounds.get_center())) > 0.99, "地图中央没有额外透明或白雾 " + context)
	var outside := Vector2i(bounds.position + Vector2(-3, bounds.size.y * 0.5))
	_check(_distance(pair[0].get_pixelv(outside), BLUE) < 0.025 and _distance(pair[1].get_pixelv(outside), GREEN) < 0.025, "裁剪外像素保持原底色，不把纹理或柔边画出边界 " + context)
	await _check_sharp_center(context, bounds)
	# 真正拖出框选预览后仍只有一份透明度，不能让网格和叠层在边缘越叠越浓。
	editor._rectangle_button.pressed.emit()
	var start := bounds.get_center()
	var end := bounds.position + Vector2(100, 18)
	_motion(start)
	_mouse_button(start, MOUSE_BUTTON_LEFT, true)
	_motion(end, end - start, MOUSE_BUTTON_MASK_LEFT)
	await _settle()
	_check(editor._canvas.is_selecting(), "使用真实拖动在渐隐带建立框选预览 " + context)
	await _capture(context + "_edge_selection")
	var selected := await _background_pair()
	var max_error := 0.0
	for y in range(6, 44, 3):
		for x in range(80, int(bounds.size.x) - 80, 11):
			var point := Vector2i(bounds.position + Vector2(x, y))
			max_error = maxf(max_error, absf(_opacity(pair, point) - _opacity(selected, point)))
	_check(max_error < 0.035, "地板、网格和框选预览统一合成渐隐，不因叠层增加透明度 " + context)
	_key(KEY_ESCAPE)
	_mouse_button(end, MOUSE_BUTTON_LEFT, false)
	editor._paint_button.pressed.emit()
	await _settle()
	_check(not editor._canvas.is_selecting() and not editor.editor_document.is_dirty(), "取消边缘预览不提交任何地块修改 " + context)


## 关闭纯显示遮罩取得同场景基准，中心纹理像素必须与原图一致，防止用模糊冒充淡隐。
func _check_sharp_center(context: String, bounds: Rect2) -> void:
	var group := _game._editor._canvas.get_parent() as CanvasGroup
	if not _check(group != null, "地图绘图通过独立合成层呈现 " + context):
		return
	var masked := await _picture()
	var material := group.material
	group.material = null
	await _settle()
	var unmasked := await _picture()
	group.material = material
	await _settle()
	var error := 0.0
	var center := Vector2i(bounds.get_center())
	for y in range(-40, 41, 2):
		for x in range(-40, 41, 2):
			var point := center + Vector2i(x, y)
			error = maxf(error, _distance(masked.get_pixelv(point), unmasked.get_pixelv(point)))
	_check(error < 0.025, "中央格线与材质和无遮罩原图一致，未受到模糊影响 " + context)


## 给定边缘与向内距离，独立构造实际屏幕像素位置。
func _edge_point(bounds: Rect2, edge: int, distance: float) -> Vector2:
	match edge:
		0: return Vector2(bounds.get_center().x, bounds.position.y + distance)
		1: return Vector2(bounds.position.x + distance, bounds.get_center().y)
		2: return Vector2(bounds.end.x - distance, bounds.get_center().y)
		_: return Vector2(bounds.get_center().x, bounds.end.y - distance)


## 内存夹具带默认限时，避免保存时补全旧数据与显示操作的检查混在一起。
func _load_fixture(id: String, dimensions: Vector2i) -> void:
	var document := MapDocument.new()
	document.id = id
	document.display_name = "边缘渐隐验证"
	document.width = dimensions.x
	document.height = dimensions.y
	document.properties = {"level": {"max_ticks": 600, "completion_mode": "reach_or_clear", "player_max_health": 1.0}}
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	_game._editor._managed_save_path = ""
	_game._editor.editor_document.replace_document(document)
	_game._editor._map_view.reset_view()


## 仅更改可见页面的真实底色，不插入覆盖在地图上方的假参考面。
func _background_pair() -> Array[Image]:
	var original := _background.color
	_background.color = BLUE
	await _settle()
	var blue := await _picture()
	_background.color = GREEN
	await _settle()
	var green := await _picture()
	_background.color = original
	await _settle()
	return [blue, green]


## 父底色差等于一减最终透明度乘以参考色差，能识别白色覆盖与真透明。
func _opacity(pair: Array[Image], point: Vector2i) -> float:
	return 1.0 - _distance(pair[0].get_pixelv(point), pair[1].get_pixelv(point)) / _distance(BLUE, GREEN)


## 只比较 RGB，避免操作系统窗口 alpha 影响截图证据。
func _distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## 获取地图内容的稳定签名，显示操作不得悄悄产生同值编辑事务。
func _signature(model: MapEditorDocument) -> String:
	return JSON.stringify(model.document.to_dict(), "", true)


## 统计真实模型变化，以便发现 JSON 未变但仍产生多余保存的实现。
func _record_change() -> void:
	_changes += 1


## 用实际画布变换换算格子坐标，兼容缩放、滚动及新增合成父层。
func _map_point(canvas: MapEditorCanvas, point: Vector2) -> Vector2:
	return (canvas.get_global_transform_with_canvas().affine_inverse() * point) / canvas.cell_size


## 真实点击由移动、按下和抬起组成，避免直接调用回调漏掉命中范围问题。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_motion(point)
	_mouse_button(point, button, true)
	_mouse_button(point, button, false)


## 通过根视口分发鼠标按钮并保留拖动按键掩码。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	if pressed and button <= MOUSE_BUTTON_MIDDLE:
		event.button_mask = 1 << (button - 1)
	root.push_input(event)


## 鼠标移动也经过全局输入路径，框选捕获不会被测试直接赋值替代。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event)


## Escape 依照原生焦点取消尚未提交的选择。
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)


## 等待布局和绘制完成，不依赖固定机器帧率。
func _settle() -> void:
	for frame in 5:
		await process_frame


## 只有桌面显示驱动才提供有效 GPU 像素。
func _gpu_enabled() -> bool:
	return not _capture_directory.is_empty() and DisplayServer.get_name() != "headless"


## 从原根窗口取得当帧画面，不重画或后处理测试图片。
func _picture() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


## 仅保存用户明确开启的隔离 GPU 截图；headless 跳过。
func _capture(filename: String) -> void:
	if not _gpu_enabled():
		return
	var picture := await _picture()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(picture.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存GPU画面 " + filename)


## 聚合独立失败，最终进程状态真实反映回归结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 清理仅限本轮独占目录，绝不接触真实玩家存档。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
