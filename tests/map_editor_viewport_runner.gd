extends SceneTree
## 地图编辑视口回归：真实鼠标输入验证居中、缩放、滚动、裁剪、指引与文档隔离。

var _checks := 0
var _failures := 0
var _temporary: String
var _game: GameShell


## 等待场景树可安全添加窗口内容，再启动独占存储的界面检查。
func _initialize() -> void:
	_run.call_deferred()


## 先验证显示和坐标变换，再验证新建、打开及试玩保持原编辑器的文档语义。
func _run() -> void:
	_temporary = "user://tests/map_editor_viewport_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(_temporary.path_join("maps"))
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	var editor := _game._editor
	await _test_layout(editor)
	await _test_properties(editor)
	await _test_guide(editor)
	await _test_coordinates(editor)
	await _test_view_history(editor)
	await _test_no_map_pan(editor)
	await _test_document_fit(editor)
	await _test_playtest(editor)
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图编辑器视口回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 小地图保持原生格子大小且位于画幅中央，两种语言与窗口尺寸都能看到全部入口。
func _test_layout(editor: MapEditor) -> void:
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var context := locale + " " + str(dimensions)
			var view := editor._map_view
			_check(view.clip_contents and view.canvas == editor._canvas, "地图使用独立裁剪视口并保留绘制画布 " + context)
			_check(view.get_global_rect().encloses(editor._canvas.get_global_rect()) and _is_centered(view), "默认小地图完整居中显示 " + context)
			_check(is_equal_approx(view.zoom, 1.0) and is_equal_approx(editor._canvas.cell_size, 32.0), "小地图保留一倍和每格32像素 " + context)
			var buttons: Array[Button] = [editor._zoom_in_button, editor._zoom_out_button, editor._guide_button]
			for button in buttons:
				_check(button.is_visible_in_tree() and button.icon != null and button.text.is_empty() and not button.get_tooltip().is_empty() and root.get_visible_rect().encloses(button.get_global_rect()), "视图区SVG入口可见且提供说明：" + str(button.name) + " " + context)
			_check(editor._zoom_out_button.get_global_rect().end.x <= editor._zoom_in_button.global_position.x and editor._zoom_in_button.get_global_rect().end.x <= editor._guide_button.global_position.x, "缩小、放大与问号按顺序排列且互不重叠 " + context)
			_check(not editor._status.is_visible_in_tree() and not _game._save_label.is_visible_in_tree() and not editor._guide_menu.is_open(), "底部状态和说明默认收进指引且外壳不重复显示 " + context)
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()


## 紧凑表单保留真实输入入口；长画笔名称不撑宽卡片，滚动条淡出不挤动表单。
func _test_properties(editor: MapEditor) -> void:
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	var fields := editor.find_child("MapEditorPropertiesFields", true, false) as VBoxContainer
	var card := editor.find_child("MapEditorPropertiesCard", true, false) as PanelContainer
	var bar := scroll.get_v_scroll_bar()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var context := locale + " " + str(dimensions)
			for field: Control in [editor._id_field, editor._name_field, editor._brush, editor._module_limit_field]:
				var label := field.get_parent().get_child(0) as Label
				_check(absf(label.get_global_rect().get_center().y - field.get_global_rect().get_center().y) < 1.0 and label.get_global_rect().end.x < field.global_position.x, "属性标签与输入框同行且不重叠 " + context)
				_check(field.size.y <= 34.0 and scroll.get_global_rect().encloses(field.get_global_rect()), "紧凑输入控件完整显示 " + context)
			_check(absf(editor._width_field.global_position.y - editor._height_field.global_position.y) < 1.0 and editor._width_field.get_global_rect().end.x < editor._height_field.global_position.x, "宽高在同一行且可分别输入 " + context)
			# 新增敌人表单允许纵向滚动；测试按钮必须可滚动到完整可见，而非强制全部内容同屏。
			var original_scroll := scroll.scroll_vertical
			scroll.ensure_control_visible(editor._play_button)
			await _settle()
			_check(scroll.get_global_rect().encloses(editor._play_button.get_global_rect()) and editor._play_button.size.y <= 34.0, "最小窗口滚动后完整显示紧凑测试按钮 " + context)
			scroll.scroll_vertical = original_scroll
			await _settle()
			var before := card.get_global_rect()
			var choice := editor._brush.selected
			editor._brush.add_item("很长的自定义地块名称 / A very long custom imported tile name")
			editor._brush.select(editor._brush.item_count - 1)
			await _settle()
			_check(card.get_global_rect().is_equal_approx(before) and scroll.get_global_rect().encloses(editor._brush.get_global_rect()), "长画笔名称不撑宽属性区或挤压地图 " + context)
			editor._brush.remove_item(editor._brush.item_count - 1)
			editor._brush.select(choice)
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()
	# 上方可达性检查实际移动过滚动条，等待其正常淡出后再验证空闲隐藏状态。
	await create_timer(1.15).timeout
	_check(bar.modulate.a == 0.0, "属性滚动条空闲时隐藏")
	# 扩展内容制造真实溢出，覆盖新增属性或更短画幅时的原生滚动路径。
	fields.custom_minimum_size.y = scroll.size.y + 240.0
	await _settle()
	_check(bar.is_visible_in_tree() and bar.max_value > bar.page, "属性内容溢出后可以原生滚动")
	_check(bar.global_position.x - fields.get_global_rect().end.x >= 18.0, "滚动条与输入区域有独立右侧留白")
	var width := editor._id_field.size.x
	var left := editor._id_field.global_position.x
	var bar_rect := bar.get_global_rect()
	var map_before := _signature(editor)
	var zoom_before := editor._map_view.zoom
	_motion(bar.get_global_rect().get_center())
	await _settle()
	_check(bar.modulate.a == 0.0, "单纯悬停属性滚动条不会显示")
	var scroll_point := Vector2(bar.global_position.x - 9, scroll.get_global_rect().get_center().y)
	_click(scroll_point, MOUSE_BUTTON_WHEEL_DOWN)
	await _settle()
	_check(bar.value > 0 and bar.modulate.a > 0.98, "滚轮实际移动属性并显示滚动条")
	await create_timer(1.15).timeout
	_check(bar.modulate.a < 0.02 and bar.is_visible_in_tree(), "停止滚动后淡出，原生轨道占位仍然保留")
	_check(is_equal_approx(editor._id_field.size.x, width) and is_equal_approx(editor._id_field.global_position.x, left) and bar.get_global_rect().is_equal_approx(bar_rect), "滚动条显隐不造成输入框宽度或位置跳动")
	_check(_signature(editor) == map_before and is_equal_approx(editor._map_view.zoom, zoom_before), "滚动属性不会编辑或缩放地图")
	fields.custom_minimum_size.y = 0
	scroll.scroll_vertical = 0
	await _settle()


## 指引显示原有说明与最新状态，关闭鼠标必须被完整吞掉，不能在地图上绘制。
func _test_guide(editor: MapEditor) -> void:
	var before := _signature(editor)
	var geometry := editor._map_view.get_global_rect()
	_click(editor._guide_button.get_global_rect().get_center())
	await _settle()
	_check(editor._guide_menu.is_open() and editor._status.is_visible_in_tree() and editor._guide_menu.terrain_label.is_visible_in_tree(), "问号打开指引并显示编辑状态与地形说明")
	_check(editor._map_view.get_global_rect().is_equal_approx(geometry), "指引展开不挤压或移动地图画幅")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not editor._guide_menu.is_open() and not editor._status.is_visible_in_tree() and editor._guide_button.has_focus(), "Esc收起指引并恢复问号焦点")
	_click(editor._guide_button.get_global_rect().get_center())
	await _settle()
	_click(_cell_point(editor._canvas, Vector2i.ZERO))
	await _settle()
	_check(not editor._guide_menu.is_open() and _signature(editor) == before and editor.editor_document._undo_stack.is_empty(), "点击地图关闭指引且按下抬起均不穿透成笔画")
	editor._guide_button.pressed.emit()
	editor._header.more_button.pressed.emit()
	_check(editor._actions_menu.is_open() and not editor._guide_menu.is_open(), "打开更多菜单时关闭指引")
	editor._guide_button.pressed.emit()
	_check(editor._guide_menu.is_open() and not editor._actions_menu.is_open(), "打开指引时关闭更多菜单")
	editor._guide_button.pressed.emit()
	_check(not editor._guide_menu.is_open() and _signature(editor) == before, "重复点击问号收起且不修改地图")


## 在真实屏幕格心绘制、拖动、擦除与放出生点，覆盖滚动及非整数比例后的坐标精度。
func _test_coordinates(editor: MapEditor) -> void:
	await _load_fixture(editor, "coordinates", Vector2i(64, 48))
	var view := editor._map_view
	var model := editor.editor_document
	editor._brush.select(editor._brush_ids.find("floor"))
	editor._on_drawing_item_selected(editor._brush.selected)
	view.set_zoom(1.25)
	await _settle()
	var start := Vector2i(29, 23)
	var end := Vector2i(32, 23)
	var before_undo := model._undo_stack.size()
	_drag(_cell_point(editor._canvas, start), _cell_point(editor._canvas, end), MOUSE_BUTTON_LEFT)
	await _settle()
	_check(model.document.cells.size() == 4 and model.document.get_tile_id(start) == "floor" and model.document.get_tile_id(Vector2i(30, 23)) == "floor" and model.document.get_tile_id(end) == "floor", "居中且125%缩放后真实拖动仍准确补齐四个连续格子")
	_check(model._undo_stack.size() == before_undo + 1 and model._action_depth == 0, "整段拖动只提交一次可撤销事务")
	_check(view._h_scroll.is_visible_in_tree() and view._v_scroll.is_visible_in_tree(), "放大到超出画幅时显示横向和纵向滚动条")
	var old_center := view.view_center
	var horizontal := view._h_scroll.get_global_rect().get_center()
	var vertical := view._v_scroll.get_global_rect().get_center()
	var old_horizontal := view._h_scroll.value
	var old_vertical := view._v_scroll.value
	_drag(horizontal, horizontal + Vector2(40, 0), MOUSE_BUTTON_LEFT)
	_drag(vertical, vertical + Vector2(0, 26), MOUSE_BUTTON_LEFT)
	await _settle()
	_check(view._h_scroll.value > old_horizontal and view._v_scroll.value > old_vertical and view.view_center.x > old_center.x and view.view_center.y > old_center.y, "真实左键拖动两个滚动条会改变地图观察位置")
	_check(model._undo_stack.size() == before_undo + 1 and model.document.cells.size() == 4, "滚动条操作不会绘制地块或新增编辑事务")
	_click(_cell_point(editor._canvas, Vector2i(30, 23)), MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(model.document.get_tile_id(Vector2i(30, 23)).is_empty() and model.document.get_tile_id(start) == "floor" and model.document.get_tile_id(end) == "floor", "滚动后右键只擦除屏幕对应的那个格子")
	editor._spawn_button.pressed.emit()
	_click(_cell_point(editor._canvas, end))
	await _settle()
	var spawn: Dictionary = model.document.player_spawn if model.document.player_spawn is Dictionary else {}
	_check(spawn.get("position", {}) == {"x": 32.5, "y": 23.5}, "同一缩放和滚动下出生点准确放到目标格心")
	editor._brush.select(editor._brush_ids.find("floor"))
	editor._on_drawing_item_selected(editor._brush.selected)
	# 滚动条占据右侧及底部空间；缩放锚点是实际地图画幅中心，不包括两条轨道。
	var centered_point: Vector2 = view.get_global_transform_with_canvas() * view.usable_rect.get_center()
	var world_before := _map_point(editor._canvas, centered_point)
	var center_before := view.view_center
	var zoom_before := view.zoom
	_check(world_before.is_equal_approx(center_before), "缩放前有效画幅中心显示当前地图观察坐标")
	_click(centered_point + Vector2(51, 19), MOUSE_BUTTON_WHEEL_UP)
	await _settle()
	var centered_after: Vector2 = view.get_global_transform_with_canvas() * view.usable_rect.get_center()
	var world_after := _map_point(editor._canvas, centered_after)
	_check(is_equal_approx(view.zoom, zoom_before * 1.25) and view.view_center.is_equal_approx(center_before) and world_after.is_equal_approx(world_before), "画布上滚轮按固定比例放大并保持有效画幅中心的地图坐标（比例 %s→%s，地图坐标 %s→%s）" % [zoom_before, view.zoom, world_before, world_after])
	var target := Vector2i(31, 24)
	_click(_cell_point(editor._canvas, target))
	await _settle()
	_check(model.document.get_tile_id(target) == "floor" and model.document.get_tile_id(target + Vector2i.RIGHT).is_empty(), "滚轮缩放后真实点击继续对应准确格子")
	var before := _signature(editor)
	_click(view.get_global_rect().position - Vector2(0, 8) + Vector2(view.size.x * 0.5, 0))
	await _settle()
	_check(_signature(editor) == before and model._action_depth == 0, "放大的画布被视口裁剪，画幅外点击不能修改地图")



## 视图操作不进入文档历史，缩放边界与按钮同步，窗口变化保留手动观察点。
func _test_view_history(editor: MapEditor) -> void:
	var view := editor._map_view
	var model := editor.editor_document
	editor._undo_button.pressed.emit()
	var before := _signature(editor)
	var path := model.path
	var undo_count := model._undo_stack.size()
	var redo_count := model._redo_stack.size()
	var dirty := model.is_dirty()
	_check(undo_count > 0 and redo_count > 0, "视图隔离夹具同时持有撤销和重做历史")
	for index in 50:
		if not editor._zoom_in_button.disabled:
			editor._zoom_in_button.pressed.emit()
	_check(is_equal_approx(view.zoom, 4.0) and not view.can_zoom_in() and editor._zoom_in_button.disabled and not editor._zoom_out_button.disabled, "放大达到四倍边界后禁用按钮")
	for index in 80:
		if not editor._zoom_out_button.disabled:
			editor._zoom_out_button.pressed.emit()
	var minimum := view.zoom
	_click(view.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
	_check(minimum > 0 and minimum <= 0.25 and is_equal_approx(view.zoom, minimum) and not view.can_zoom_out() and editor._zoom_out_button.disabled, "缩小到有效下限后按钮与滚轮均不能越界")
	view.set_zoom(1.25)
	view._h_scroll.value = 0
	view._v_scroll.value = 0
	_check(editor._canvas.position.is_equal_approx(Vector2.ZERO), "两个滚动条到达起点时地图左上边缘与有效画幅对齐")
	view._h_scroll.value = view._h_scroll.max_value
	view._v_scroll.value = view._v_scroll.max_value
	_check(is_equal_approx(view._h_scroll.value, view._h_scroll.max_value - view._h_scroll.page) and is_equal_approx(view._v_scroll.value, view._v_scroll.max_value - view._v_scroll.page), "滚动条末端被地图尺寸限制，不会把地图完全移出画幅")
	view._h_scroll.value = (view._h_scroll.max_value - view._h_scroll.page) * 0.5
	view._v_scroll.value = (view._v_scroll.max_value - view._v_scroll.page) * 0.5
	var center := view.view_center
	root.size = Vector2i(1000, 740)
	await _settle()
	_check(is_equal_approx(view.zoom, 1.25) and view.view_center.is_equal_approx(center), "调整窗口保留手动缩放与观察中心")
	root.size = Vector2i(1280, 800)
	await _settle()
	_check(_signature(editor) == before and model.path == path and model.is_dirty() == dirty and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count, "缩放、滚轮和滚动条不修改地图、路径、dirty及两侧历史")
	editor._redo_button.pressed.emit()
	_check(model.document.get_tile_id(Vector2i(31, 24)) == "floor", "视图操作后仍能重做之前的准确格子修改")


## 地图本身不提供中键或空格手形平移，文字输入仍正常，弹层关闭不会透传笔画。
func _test_no_map_pan(editor: MapEditor) -> void:
	await _load_fixture(editor, "no_map_pan", Vector2i(64, 48))
	var view := editor._map_view
	var model := editor.editor_document
	view.set_zoom(1.25)
	if root.gui_get_focus_owner() != null:
		root.gui_get_focus_owner().release_focus()
	var middle := view.get_global_rect().get_center()
	var center := view.view_center
	var before := _signature(editor)
	_drag(middle, middle + Vector2(73, 41), MOUSE_BUTTON_MIDDLE)
	_motion(middle)
	_space(true)
	_check(view.mouse_default_cursor_shape == Control.CURSOR_ARROW and editor._canvas.mouse_default_cursor_shape == Control.CURSOR_ARROW, "空格不再切换手形或抓取光标")
	_space(false)
	_check(view.view_center.is_equal_approx(center) and _signature(editor) == before and model._undo_stack.is_empty() and model._action_depth == 0, "中键拖动和空格不会平移地图或产生笔画事务")
	# 原生文字框中的空格不应因为地图快捷键残留而失效。
	var field := editor._name_field
	var original_name := field.text
	field.grab_focus()
	field.caret_column = field.text.length()
	await _settle()
	_space(true)
	_space(false)
	await _settle()
	_check(field.text == original_name + " " and _signature(editor) == before, "名称输入框内空格保留原生文字编辑行为")
	field.text = original_name
	field.release_focus()
	editor._header.more_button.pressed.emit()
	await _settle()
	editor._actions_menu._items[2].pressed.emit()
	await _settle()
	var code := editor._metadata_text
	var original_json := code.text
	code.grab_focus()
	code.set_caret_line(0)
	code.set_caret_column(0)
	await _settle()
	_space(true, code.get_viewport())
	_space(false, code.get_viewport())
	await _settle()
	_check(code.text == " " + original_json and _signature(editor) == before, "元数据CodeEdit内空格保留原生文字编辑且不影响地图")
	editor._metadata_dialog.hide()
	await _settle()
	for button: Button in [editor._guide_button, editor._header.more_button]:
		button.pressed.emit()
		await _settle()
		var outside := view.get_global_rect().position + Vector2(20, view.size.y * 0.5)
		_drag(outside, outside + Vector2(20, 10), MOUSE_BUTTON_LEFT)
		await _settle()
		_check(view.view_center.is_equal_approx(center) and _signature(editor) == before and not editor._guide_menu.is_open() and not editor._actions_menu.is_open(), "外部关闭弹层的拖动不会平移或绘制：" + str(button.name))


## 最大地图也能整体适配，打开同尺寸文档及新建均恢复默认视图，尺寸修改仍可撤销。
func _test_document_fit(editor: MapEditor) -> void:
	await _load_fixture(editor, "largest", Vector2i(256, 256))
	var view := editor._map_view
	_check(view.zoom < 0.25 and view.get_global_rect().encloses(editor._canvas.get_global_rect()) and _is_centered(view), "256×256地图初次打开完整适配并居中")
	root.size = Vector2i(1000, 740)
	await _settle()
	_check(view.get_global_rect().encloses(editor._canvas.get_global_rect()) and _is_centered(view), "尚未手动操作的大地图会随较小窗口重新整体适配")
	root.size = Vector2i(1280, 800)
	await _settle()
	view.set_zoom(2.0)
	view.view_center = Vector2(120, 118)
	view.refresh_map()
	editor._load_document(_temporary.path_join("maps/largest.json"))
	await _settle()
	_check(view.zoom < 0.25 and _is_centered(view) and view.view_center.is_equal_approx(Vector2(128, 128)), "重新打开相同尺寸文件也重置手动视点并重新适配")
	await _load_fixture(editor, "small", Vector2i(8, 6))
	_check(is_equal_approx(view.zoom, 1.0) and _is_centered(view), "打开小地图自动恢复一倍和居中")
	var empty_before := _signature(editor)
	_click(view.get_global_rect().position + Vector2(8, view.size.y * 0.5))
	_check(_signature(editor) == empty_before and editor.editor_document._undo_stack.is_empty(), "小地图四周留白点击不产生编辑历史")
	view.set_zoom(2.0)
	editor._width_field.value = 64
	editor._height_field.value = 60
	_find_button(editor, "应用尺寸").pressed.emit()
	await _settle()
	_check(view.zoom < 1.0 and _is_centered(view) and view.get_global_rect().encloses(editor._canvas.get_global_rect()), "应用更大地图尺寸后自动适配新范围")
	editor._undo_button.pressed.emit()
	await _settle()
	_check(editor.editor_document.document.width == 8 and editor.editor_document.document.height == 6 and is_equal_approx(view.zoom, 1.0) and _is_centered(view), "撤销尺寸修改恢复小地图并重新居中")
	view.set_zoom(3.0)
	editor._header.new_button.pressed.emit()
	await _settle()
	_check(editor.editor_document.path.is_empty() and editor.editor_document.document.cells.is_empty() and view.zoom <= 1.0 and _is_centered(view), "新建恢复默认适配视图与空文档")


## 指引打开时开始试玩会收起浮窗，返回同一文档时保留手动视图且不重开指引。
func _test_playtest(editor: MapEditor) -> void:
	editor._load_document(MapEditor.DEFAULT_MAP_PATH)
	await _settle()
	editor._width_field.value = 64
	editor._height_field.value = 48
	_find_button(editor, "应用尺寸").pressed.emit()
	var view := editor._map_view
	view.set_zoom(1.25)
	view._h_scroll.value += 64
	view._v_scroll.value += 32
	var center := view.view_center
	var zoom := view.zoom
	var model := editor.editor_document
	var before := _signature(editor)
	var undo_count := model._undo_stack.size()
	editor._guide_button.pressed.emit()
	editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and not editor._guide_menu.is_open(), "开始试玩关闭指引并进入原有空装配页面")
	if _game.session == null:
		return
	_game._dialogue_dialog.hide()
	_game._back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and _game._editor == editor and editor.editor_document == model and editor._map_view == view, "试玩返回同一编辑器、文档及视图实例")
	_check(is_equal_approx(view.zoom, zoom) and view.view_center.is_equal_approx(center) and not editor._guide_menu.is_open(), "试玩返回保留缩放和滚动位置且指引继续关闭")
	_check(_signature(editor) == before and model._undo_stack.size() == undo_count and model.is_dirty(), "试玩返回保持未保存地图及原尺寸修改历史")


## 每个夹具先通过正式地图编码保存，再经原有打开入口载入，不访问玩家目录。
func _load_fixture(editor: MapEditor, id: String, dimensions: Vector2i) -> void:
	var document := MapDocument.new()
	document.id = id
	document.width = dimensions.x
	document.height = dimensions.y
	var path := _temporary.path_join("maps/" + id + ".json")
	_check(MapCodec.save_file(document, path, editor.registry, false).is_ok(), "保存隔离地图夹具：" + id)
	editor._load_document(path)
	await _settle()


## 比较屏幕矩形中心而不是布局内部变量，确保玩家看到的地图真正居中。
func _is_centered(view: MapEditorViewport) -> bool:
	return view.get_global_rect().get_center().is_equal_approx(view.canvas.get_global_rect().get_center())


## 由画布真实绘制变换计算格心屏幕位置，事件仍通过窗口而非直接调用画布处理器。
func _cell_point(canvas: MapCanvas, cell: Vector2i) -> Vector2:
	return canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2(0.5, 0.5)) * canvas.cell_size)


## 反算画布显示的地图单位，用于检查变换前后的观察锚点是否稳定。
func _map_point(canvas: MapCanvas, screen: Vector2) -> Vector2:
	return (canvas.get_global_transform_with_canvas().affine_inverse() * screen) / canvas.cell_size


## 向真实窗口发送完整点击，使裁剪、弹层优先级和控件命中一同接受回归。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_motion(point)
	_mouse_button(point, button, true)
	_mouse_button(point, button, false)


## 用完整按下、运动和抬起事件构造一笔拖动，事件掩码与实际鼠标一致。
func _drag(from: Vector2, to: Vector2, button: MouseButton) -> void:
	_motion(from)
	_mouse_button(from, button, true)
	var mask := MOUSE_BUTTON_MASK_MIDDLE if button == MOUSE_BUTTON_MIDDLE else MOUSE_BUTTON_MASK_LEFT
	_motion(to, to - from, mask)
	_mouse_button(to, button, false)


## 所有鼠标按键均经真实视口分发，避免信号直调掩盖坐标或事件穿透问题。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	if pressed and button <= MOUSE_BUTTON_MIDDLE:
		event.button_mask = 1 << (button - 1)
	root.push_input(event)


## 运动事件带完整屏幕位置及相对位移，覆盖滚动条拖动及画笔路径处理。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event)


## Esc经过正常输入顺序关闭浮窗，而不是直接调用关闭方法。
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)


## 空格按下与抬起可分别发送，文字框使用所属视口接收真实字符输入。
func _space(pressed: bool, viewport: Viewport = null) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.physical_keycode = KEY_SPACE
	event.unicode = 32
	event.pressed = pressed
	var target := root if viewport == null else viewport
	target.push_input(event)


## 按原有文字查找尺寸按钮，确保测试仍经用户可访问的操作入口提交。
func _find_button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == text:
			return node
	return null


## 使用排序后的完整地图快照，未知扩展字段也包含在视图无副作用检查内。
func _signature(editor: MapEditor) -> String:
	return JSON.stringify(editor.editor_document.document.to_dict(), "", true)


## 等待容器尺寸协商以及延迟视图布局完成。
func _settle() -> void:
	await process_frame
	await process_frame


## 只递归清理本次创建的独占目录，不触及玩家地图或正式作品。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not (path == _temporary or path.begins_with(_temporary + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 继续收集独立失败，并在最终进程状态中报告真实结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
