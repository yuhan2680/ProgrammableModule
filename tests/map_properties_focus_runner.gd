extends SceneTree
## 实际 GUI 输入覆盖空白失焦、输入提交、按钮单次操作与浮层隔离，使用独占存储。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _editor: MapEditor
var _scroll: ScrollContainer


## 延迟创建编辑器，避免初始化期间发送输入。
func _initialize() -> void:
	_run.call_deferred()


## 在常用窗口与最小窗口内检查全部可聚焦属性控件，退出后清理测试目录。
func _run() -> void:
	Engine.max_fps = 120
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_temporary = "user://tests/map_properties_focus_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	_editor = _game._editor
	_scroll = _editor.find_child("MapEditorPropertiesScroll", true, false)
	await _test_read_only_id()
	await _test_text_fields()
	await _test_numbers()
	await _test_interactions()
	await _test_gate_tools()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		await _test_all_controls()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图属性失焦回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 只读 ID 仍可原生选中复制；键入、删除、剪切和粘贴不能改动显示值、地图或历史。
func _test_read_only_id() -> void:
	var field := _editor._id_field
	var model := _editor.editor_document
	var identity := model.document.id
	var before := model.document.to_dict()
	var history := model._undo_stack.size()
	_check(not field.editable and field.selecting_enabled and field.text == identity, "地图 ID 只读且保留原生文本选择")
	await _show(field)
	await _replace(field, "manual_id")
	_check(field.has_focus() and field.text == identity, "实际键入不能替换只读 ID，仍可聚焦查看")
	_key(KEY_A, true)
	_check(field.get_selected_text() == identity, "只读 ID 可用原生全选快捷键选择完整原文")
	_key(KEY_BACKSPACE)
	_key(KEY_DELETE)
	_check(field.text == identity, "退格和删除快捷键不能擦除只读 ID")
	if DisplayServer.get_name() != "headless":
		var previous_clipboard := DisplayServer.clipboard_get()
		DisplayServer.clipboard_set("只读 ID 复制检查")
		_key(KEY_A, true)
		_key(KEY_C, true)
		_check(DisplayServer.clipboard_get() == identity, "原生复制快捷键把只读 ID 原文送入系统剪贴板")
		_key(KEY_X, true)
		_check(field.text == identity, "原生剪切快捷键不能删除只读 ID")
		DisplayServer.clipboard_set("map_0000000000")
		_key(KEY_A, true)
		_key(KEY_V, true)
		_check(field.text == identity, "系统剪贴板粘贴不能替换只读 ID")
		DisplayServer.clipboard_set(previous_clipboard)
	# 只读检查失败时恢复候选原值，避免非法空 ID 弹窗遮挡后续独立交互回归。
	if field.text != identity:
		field.text = identity
	_key(KEY_ENTER)
	_click(_blank())
	await _settle()
	_check(root.gui_get_focus_owner() == null and model.document.to_dict() == before and model._undo_stack.size() == history and not model.is_dirty(), "只读 ID 回车和空白失焦不更改文档或制造撤销历史")


## 实际键入署名、名称和副标题；空白失焦须提交一次，未编辑失焦不制造撤销记录。
func _test_text_fields() -> void:
	var identity := _editor.editor_document.document.id
	var cases := [[_editor._name_field, "FocusMap"], [_editor._subtitle_field, "Focus subtitle"], [_editor._creator_field, "Muna"]]
	for entry in cases:
		var field: LineEdit = entry[0]
		await _show(field)
		await _replace(field, entry[1])
		await _settle()
		_check(field.has_focus() and field.text == entry[1], "输入过程中仍正常聚焦和键入：" + entry[1])
		_click(_blank())
		await _settle()
		_check(root.gui_get_focus_owner() == null, "点击卡片留白真正释放输入焦点：" + entry[1])
	_check(_editor.editor_document.document.display_name == "FocusMap" and _editor.editor_document.document.id == identity, "失焦提交名称并保留自动分配的 ID")
	_check(_editor.editor_document.get_subtitle() == "Focus subtitle", "失焦仍提交玩家实际输入的副标题")
	_check(_editor.editor_document.get_creator() == "Muna", "失焦提交玩家实际输入的署名")
	_editor._save_document(false)
	var before := _editor.editor_document.document.to_dict()
	await _show(_editor._creator_field)
	_click(_editor._creator_field.get_global_rect().get_center())
	_click(_blank())
	await _settle()
	_check(_editor.editor_document.document.to_dict() == before and not _editor.editor_document.is_dirty(), "不修改输入直接失焦保持保存点和原文档")
	_check(MapCodec.load_file(_editor.editor_document.path, _editor.registry, false).value.properties.level.creator == "Muna", "普通保存使用已失焦提交的署名")


## 所有数字输入沿原规则提交或恢复；尺寸仍需主动应用，空白点击不代替应用按钮。
func _test_numbers() -> void:
	await _show(_editor._time_limit_field)
	await _replace(_editor._time_limit_field, "120.5")
	_click(_blank())
	await _settle()
	_check(not _editor._time_limit_field.has_focus() and is_equal_approx(_editor.editor_document.get_time_limit_seconds(), 120.5), "时间限制输入失焦且保存小数")
	await _show(_editor._player_health_field)
	await _replace(_editor._player_health_field, "2.5")
	_click(_blank())
	await _settle()
	_check(not _editor._player_health_field.has_focus() and is_equal_approx(_editor.editor_document.get_player_max_health(), 2.5), "玩家耐久输入失焦并提交")
	await _show(_editor._module_limit_field)
	await _replace(_editor._module_limit_field.get_line_edit(), "4")
	_click(_blank())
	await _settle()
	_check(not _editor._module_limit_field.get_line_edit().has_focus() and _editor.editor_document.get_module_limit() == 4, "SpinBox 内层模块数量输入失焦并提交：text=%s value=%s model=%s focus=%s" % [_editor._module_limit_field.get_line_edit().text, _editor._module_limit_field.value, _editor.editor_document.get_module_limit(), root.gui_get_focus_owner()])
	var width := _editor.editor_document.document.width
	await _show(_editor._width_field)
	await _replace(_editor._width_field.get_line_edit(), "16")
	_click(_blank())
	await _settle()
	_check(not _editor._width_field.get_line_edit().has_focus() and int(_editor._width_field.value) == 16 and _editor.editor_document.document.width == width, "宽度失焦保留候选尺寸，不自动裁剪地图：text=%s value=%s width=%s focus=%s" % [_editor._width_field.get_line_edit().text, _editor._width_field.value, _editor.editor_document.document.width, root.gui_get_focus_owner()])
	await _show(_editor._time_limit_field)
	await _replace(_editor._time_limit_field, "invalid")
	_click(_blank())
	await _settle()
	_check(not _editor._time_limit_field.has_focus() and _editor._time_limit_field.text == "120.5", "无效时间失焦恢复有效值且不重新抢焦点")
	var enemy := _editor._enemy_panel
	await _show(enemy.enable_switch)
	if not _editor.editor_document.get_enemies_enabled():
		_click(enemy.enable_switch.get_global_rect().get_center())
		await _settle()
	await _show(enemy.limit_field)
	await _replace(enemy.limit_field, "2")
	_click(_blank())
	await _settle()
	_check(not enemy.limit_field.has_focus() and int(enemy._config.module_limit) == 2, "敌人模块数量失焦提交")
	await _show(enemy.health_field)
	await _replace(enemy.health_field, "3.25")
	_click(_blank())
	await _settle()
	_check(not enemy.health_field.has_focus() and is_equal_approx(enemy._config.module_health, 3.25), "敌人耐久失焦提交")
	await _show(enemy.health_field)
	await _replace(enemy.health_field, "oops")
	_click(_blank())
	await _settle()
	_check(not enemy.health_field.has_focus() and enemy.health_field.text == "3.25", "敌人非法数字失焦恢复原值")


## 同一输入框、键盘导航、按钮和模态窗口保持原生交互；地图点击仍能绘图。
func _test_interactions() -> void:
	await _show(_editor._creator_field)
	_click(_editor._creator_field.get_global_rect().get_center())
	await _settle()
	_click(_editor._creator_field.get_global_rect().position + Vector2(12, 12))
	await _settle()
	_check(_editor._creator_field.has_focus(), "点击同一输入框内部不打断输入或光标定位")
	_click(_editor._creator_field.get_global_rect().get_center())
	_move(Vector2(500, 50))
	await _settle()
	_check(_editor._creator_field.has_focus(), "点入输入框后立即移开鼠标仍保持编辑焦点")
	_key(KEY_TAB)
	await _settle()
	_check(root.gui_get_focus_owner() != null and root.gui_get_focus_owner() != _editor._creator_field, "Tab 仍将焦点交给下一个控件")
	_click(_blank())
	await _settle()
	_check(root.gui_get_focus_owner() == null, "键盘聚焦的属性按钮也可通过空白点击释放")
	await _show(_editor._rectangle_button)
	var calls := [0]
	_editor._rectangle_button.pressed.connect(func() -> void: calls[0] += 1)
	_click(_editor._rectangle_button.get_global_rect().get_center())
	await _settle()
	_check(calls[0] == 1 and _editor._canvas.paint_mode == MapEditorCanvas.PaintMode.RECTANGLE, "属性按钮点击只执行一次，空白处理不吞输入")
	_click(_blank())
	await _settle()
	_check(not _editor._rectangle_button.has_focus(), "属性按钮点击后再点空白不残留焦点")
	await _show(_editor._creator_field)
	_click(_editor._creator_field.get_global_rect().get_center())
	_click(Vector2(500, 50))
	await _settle()
	_check(not _editor._creator_field.has_focus(), "页面标题旁的空白也取消属性输入焦点")
	_click(_editor._creator_field.get_global_rect().get_center())
	await _settle()
	_click(Vector2(5, 5))
	await _settle()
	_check(not _editor._creator_field.has_focus(), "编辑器外侧的页面留白也取消属性输入焦点")
	_editor._open_metadata()
	await _settle()
	_editor._metadata_text.grab_focus()
	_click(_blank())
	await _settle()
	_check(_editor._metadata_dialog.visible and _editor._metadata_text.has_focus(), "元数据模态窗口阻止背景点击夺走正文焦点")
	_editor._metadata_dialog.hide()
	await _settle()
	await _show(_editor._creator_field)
	_click(_editor._creator_field.get_global_rect().get_center())
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	var canvas := _editor._canvas
	var point := canvas.get_global_transform() * (Vector2(12.5, 10.5) * canvas.cell_size)
	_click(point)
	await _settle()
	_check(not _editor._creator_field.has_focus(), "点击地图时属性输入焦点退出")
	_check(not _editor.editor_document.document.get_tile_id(Vector2i(12, 10)).is_empty(), "取消属性焦点不阻止同一次地图绘制")


## 空白结束闸门工具，输入和地图点击保留工具；取消不增删对象或产生历史。
func _test_gate_tools() -> void:
	var model := _editor.editor_document
	var original := model.document.duplicate_document()
	var original_path := model.path
	var fixture := MapDocument.new()
	fixture.id = "gate_focus"
	fixture.display_name = "闸门工具失焦测试"
	fixture.width = 10
	fixture.height = 8
	fixture.properties = {"level": {"max_ticks": 600}}
	for y in fixture.height:
		for x in fixture.width:
			fixture.set_tile(Vector2i(x, y), "floor")
	model.replace_document(fixture)
	_editor._map_view.reset_view()
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.RECTANGLE)
	await _show(_editor._gate_add_button)
	_click(_editor._gate_add_button.get_global_rect().get_center())
	await _settle()
	_check(_editor._gate_add_button.button_pressed and _editor._canvas.paint_mode == MapEditorCanvas.PaintMode.GATE_ADD, "加号点击确实启用放置工具")
	await _replace(_editor._gate_timer_field, "3.5")
	_check(_editor._gate_add_button.button_pressed and _editor._gate_timer_field.has_focus(), "编辑秒表仍保留放置工具")
	_click(_blank())
	await _settle()
	_check(not _editor._gate_add_button.button_pressed and root.gui_get_focus_owner() == null and _editor._canvas.paint_mode == MapEditorCanvas.PaintMode.RECTANGLE, "卡片空白同时取消加号高亮和焦点并恢复原地形工具")
	_check(is_equal_approx(_editor._new_gate_seconds, 3.5) and model.document.to_dict() == fixture.to_dict() and not model.can_undo(), "空白提交新门秒数但不写对象和历史")
	_click(_editor._gate_remove_button.get_global_rect().get_center())
	await _settle()
	_editor._gate_remove_button.release_focus()
	_click(_blank())
	await _settle()
	_check(not _editor._gate_remove_button.button_pressed and _editor._canvas.paint_mode == MapEditorCanvas.PaintMode.RECTANGLE, "没有键盘焦点时卡片空白仍结束删除工具")
	_click(_editor._gate_add_button.get_global_rect().get_center())
	await _settle()
	var canvas := _editor._canvas
	var point := canvas.get_global_transform_with_canvas() * (Vector2(3.5, 3.5) * canvas.cell_size)
	_click(point)
	await _settle()
	_check(model.document.objects.size() == 1 and _editor._gate_add_button.button_pressed and canvas.paint_mode == MapEditorCanvas.PaintMode.GATE_ADD, "地图点击正常放置并保留连续放置工具")
	var before := model.document.to_dict()
	var history := model._undo_stack.size()
	_click(_blank())
	await _settle()
	_check(not _editor._gate_add_button.button_pressed and canvas.selected_gate_id.is_empty() and model.document.to_dict() == before and model._undo_stack.size() == history, "放置后空白只取消选择工具，不删除已放置门或制造历史")
	model.replace_document(original, original_path)
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	await _settle()


## 遍历真实属性树的输入与按钮，包含内层数值框和敌人模块药丸，不靠逐控件特判。
func _test_all_controls() -> void:
	var controls: Array[Control] = []
	_collect(_editor._properties_card, controls)
	var before := _editor.editor_document.document.to_dict()
	for control in controls:
		if not control.is_visible_in_tree() or control.focus_mode == Control.FOCUS_NONE:
			continue
		if control is BaseButton and control.disabled:
			continue
		await _show(control)
		control.grab_focus()
		await _settle()
		_check(control.has_focus(), "属性控件仍可键盘聚焦：" + control.name)
		_click(_blank())
		await _settle()
		_check(root.gui_get_focus_owner() == null, "各属性控件点击空白释放：" + control.name)
	_check(_editor.editor_document.document.to_dict() == before, "遍历空白失焦不更改地图数据")


## 收集当前属性树，排除属于独立浮层的控件。
func _collect(node: Node, controls: Array[Control]) -> void:
	for child in node.get_children(true):
		if child is CanvasLayer or child is Window:
			continue
		if child is Control:
			controls.append(child)
		_collect(child, controls)


## 滚入真实控件，等待容器与边缘渐隐调整完成。
func _show(control: Control) -> void:
	if _scroll.is_ancestor_of(control):
		_scroll.ensure_control_visible(control)
	await _settle()


## 固定卡片上边留白，不会点击输入框、折叠标题或地图格子。
func _blank() -> Vector2:
	return _editor._properties_card.get_global_rect().position + Vector2(18, 6)


## 通过原生键盘替换文本，包含真实 text_changed 和光标处理。
func _replace(field: LineEdit, text: String) -> void:
	_click(field.get_global_rect().get_center())
	# SpinBox 的原生编辑开始通知是延迟的，按用户先点入再键入的顺序发送。
	await _settle()
	_key(KEY_A, true)
	for index in text.length():
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.unicode = text.unicode_at(index)
			event.pressed = pressed
			root.push_input(event, true)
	await _settle()


## 完整点击用于验证实际焦点转移而非直接调用实现。
func _click(point: Vector2) -> void:
	_move(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event, true)


## 单独移动鼠标只更新悬停，不能取消正在编辑的输入焦点。
func _move(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)


## 键盘输入沿正式焦点路由分派。
func _key(key: Key, modifier: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		event.ctrl_pressed = modifier and not OS.has_feature("macos")
		event.meta_pressed = modifier and OS.has_feature("macos")
		root.push_input(event, true)


## 等待原生布局、失焦提交和延迟回调完成。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 将失败输出与完成标记交给统一测试脚本识别。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 删除本测试独占路径，不触碰玩家保存或草稿。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in folder.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
