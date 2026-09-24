extends SceneTree
## 返回开始页的保存确认走真实窗口输入与原写盘流程，测试文件只进入独立 user://tests 目录。

var _checks := 0
var _failures := 0
var _game: GameShell
var _editor: MapEditor
var _temporary := ""


## 延后创建实际编辑器，并控制无界面回归的帧率。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 覆盖当前地图名、模态输入、三个分支和首次保存的取消及完成。
func _run() -> void:
	_temporary = "user://tests/editor_exit_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	await _test_layout_and_modal()
	await _test_existing_save()
	await _test_discard()
	await _test_first_save_cancel()
	await _test_first_save_success()
	await _test_validation_failure()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图退出确认回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 每个分支替换为内存夹具，绝不沿用示例地图的 res 路径作为保存目标。
func _fixture(path: String = "") -> void:
	if _game.page != GameShell.Page.EDITOR:
		_game._open_editor()
		await _settle()
	_editor = _game._editor
	var focused := root.gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	_editor._file_dialog.use_native_dialog = false
	_editor._file_dialog.current_dir = ProjectSettings.globalize_path(_temporary)
	var document := MapDocument.new()
	document.id = "exit_fixture"
	document.display_name = "移动模块试验场"
	document.width = 12
	document.height = 10
	document.properties = {"level": {"module_limit": 1, "max_ticks": 600, "completion_mode": "reach_or_clear"}}
	for y in 10:
		for x in 12:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}}]}
	if not path.is_empty():
		_check(path.begins_with(_temporary) and MapCodec.save_file(document, path, _editor.registry, false).is_ok(), "夹具基线只保存到本次测试目录")
	_editor.editor_document.replace_document(document, path)
	_editor._map_view.reset_view()
	_editor.editor_document.paint(Vector2i(11, 9), "")
	await _settle()


## 真实表单名在返回时提交，长中英标题换行，按钮顺序和模态输入与视觉一致。
func _test_layout_and_modal() -> void:
	await _fixture()
	var model := _editor.editor_document
	_editor._name_field.grab_focus()
	_editor._name_field.text = "刚刚输入的地图名字"
	_game._go_back()
	await _settle()
	var dialog := _game._editor_discard_dialog
	_check(dialog.visible and dialog._message.text.contains("刚刚输入的地图名字") and model.document.display_name == "刚刚输入的地图名字", "退出提示采用尚未失焦的最新地图名")
	_check(dialog._warning.texture != null and dialog._warning.texture.resource_path.ends_with(".svg"), "警告三角采用独立SVG资源")
	_check(dialog._glass.material is ShaderMaterial and dialog._glass.get_viewport() == _editor.get_viewport(), "玻璃在编辑器同一视口采样，内容独立清晰绘制")
	_check(dialog._panel.get_global_rect().size.distance_to(Vector2(266.0, 285.6)) < 0.1, "普通地图名的弹窗实际显示尺寸缩小至原来的七成")
	var before := _signature(model)
	var history := model._undo_stack.size()
	var map_point := _cell_point(Vector2i.ZERO)
	_check(not dialog._panel.get_global_rect().has_point(map_point), "模态点击测试命中弹窗外的真实地板")
	_click(map_point, MOUSE_BUTTON_RIGHT)
	_key(KEY_Z, true)
	_key(KEY_N, true)
	_key(KEY_S, true)
	await _settle()
	_check(dialog.visible and _signature(model) == before and model._undo_stack.size() == history, "弹窗外点击和编辑快捷键不会穿透修改地图或历史")
	_check(not _editor._dirty_dialog.visible and not _editor._file_dialog.visible, "模态期间不能另开新建确认或保存选择器")
	_check(dialog.get_cancel_button().has_focus(), "默认焦点选择取消，回车不会意外放弃地图")
	_check(not _focus_border_visible(dialog._cancel_button), "打开窗口的默认取消焦点不会留下蓝色描边")
	_move(dialog._cancel_button.get_global_rect().get_center())
	await _settle()
	_check(dialog._cancel_button.is_hovered(), "真实鼠标移入确实触发取消按钮的悬停状态")
	_move(map_point)
	await _settle()
	_check(not dialog._cancel_button.is_hovered() and dialog._cancel_button.has_focus() and not _focus_border_visible(dialog._cancel_button), "真实鼠标移入取消再移到面板外后悬停与描边消失，安全默认焦点仍保留")
	_key(KEY_ENTER)
	await _settle()
	_check(not dialog.visible and _game._editor == _editor and _signature(model) == before and model._undo_stack.size() == history, "鼠标移开后回车仍只取消，不保存或放弃地图")
	_game._go_back()
	await _settle()
	_key(KEY_TAB)
	await _settle()
	_check(dialog._save_button.has_focus(), "Tab从取消循环到保存")
	_check(_focus_border_visible(dialog._save_button), "键盘Tab导航仍显示清晰的蓝色焦点提示")
	_key(KEY_TAB)
	await _settle()
	_check(dialog._discard_button.has_focus(), "Tab在三个操作之间按可见顺序移动")
	_key(KEY_TAB)
	await _settle()
	_check(dialog._cancel_button.has_focus(), "Tab焦点被限制在模态窗口内")
	_move(dialog._cancel_button.get_global_rect().get_center())
	await _settle()
	_move(dialog._message.get_global_rect().get_center())
	await _settle()
	_check(dialog._cancel_button.has_focus() and not _focus_border_visible(dialog._cancel_button), "键盘导航后改用真实鼠标移入移出会清除焦点描边")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not dialog.visible and _game._editor == _editor and _signature(model) == before and model._undo_stack.size() == history, "Esc等同取消并保留同一文档与撤销历史")
	_click(map_point, MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(model.document.get_tile_id(Vector2i.ZERO).is_empty(), "关闭后同位置真实右键可以擦除，证明遮挡测试未绕过画布")
	for dimensions in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			var map_name := "这是一个非常长而且需要自动换行的地图名称，不能省略后半段的名字" if locale == "zh_CN" else "A very long map name that must wrap onto a second line without truncating its final words"
			_editor._name_field.release_focus()
			model.set_identity("exit_fixture", map_name)
			_game._go_back()
			await _settle()
			var panel_rect := dialog._panel.get_global_rect()
			var viewport_rect := Rect2(Vector2.ZERO, Vector2(dimensions))
			_check(viewport_rect.encloses(panel_rect) and dialog._message.text.contains(map_name) and dialog._message.get_line_count() >= 2, "中英文长地图名自动换行且面板完整位于视口内 " + locale + str(dimensions))
			var buttons: Array[Button] = [dialog._save_button, dialog._discard_button, dialog._cancel_button]
			for index in buttons.size():
				var button_rect := buttons[index].get_global_rect()
				_check(panel_rect.encloses(button_rect) and is_equal_approx(button_rect.get_center().x, panel_rect.get_center().x), "三个药丸均在面板内居中 " + str(index) + locale + str(dimensions))
			_check(buttons[0].get_global_rect().end.y <= buttons[1].global_position.y and buttons[1].get_global_rect().end.y <= buttons[2].global_position.y, "保存、不保存、取消竖向依次排列且无重叠")
			if locale == "zh_CN":
				_check(buttons[0].text == "保存" and buttons[1].text == "不保存" and buttons[2].text == "取消", "中文严格使用保存、不保存、取消")
			else:
				_check(buttons[0].tr(buttons[0].text) == "Save" and buttons[2].tr(buttons[2].text) == "Cancel" and buttons[1].tr(buttons[1].text).contains("Save"), "按钮支持英文而自定义地图名不翻译")
			_click(dialog._cancel_button.get_global_rect().get_center())
			await _settle()
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game.settings.set_language("zh_CN")
	await _settle()


## 已有路径的保存必须真实写盘并清除dirty后才能离开编辑器。
func _test_existing_save() -> void:
	var path := _temporary.path_join("existing.json")
	await _fixture(path)
	var model := _editor.editor_document
	model.set_identity("exit_saved", "已经保存的地图")
	var before := _signature(model)
	_game._go_back()
	await _settle()
	_click(_game._editor_discard_dialog._save_button.get_global_rect().get_center())
	await _settle()
	var saved := MapCodec.load_file(path, _game.registry, false)
	_check(_game.page == GameShell.Page.MAIN and not _game._editor_exit_save_pending and not model.is_dirty(), "已有路径保存完成才返回主菜单，并结束一次退出请求")
	_check(saved.is_ok() and JSON.parse_string(JSON.stringify(saved.value.to_dict(), "", true)) == JSON.parse_string(before), "写盘结果包含全部最新名称及地块编辑")


## 不保存仅放弃本次内存编辑，不写文件或触发保存路径选择。
func _test_discard() -> void:
	var path := _temporary.path_join("discard.json")
	await _fixture(path)
	var baseline := FileAccess.get_file_as_string(path)
	_game._go_back()
	await _settle()
	_click(_game._editor_discard_dialog._discard_button.get_global_rect().get_center())
	await _settle()
	_check(_game.page == GameShell.Page.MAIN and FileAccess.get_file_as_string(path) == baseline, "不保存返回开始页且原文件逐字不变")


## 首次保存取消文件选择后仍可继续编辑，后续手工保存不能继承旧退出意图。
func _test_first_save_cancel() -> void:
	await _fixture()
	var model := _editor.editor_document
	var before := _signature(model)
	var history := model._undo_stack.size()
	_game._go_back()
	await _settle()
	_click(_game._editor_discard_dialog._save_button.get_global_rect().get_center())
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and _game._editor_exit_save_pending and _editor._file_dialog.visible and model.path.is_empty(), "首次保存只打开文件选择器，不提前离开或清除dirty")
	_editor._file_dialog.hide()
	_editor._file_dialog.canceled.emit()
	await _settle()
	_check(not _game._editor_exit_save_pending and model.is_dirty() and _signature(model) == before and model._undo_stack.size() == history, "取消路径选择保留草稿和历史并撤销退出意图")
	_editor._save_document(false)
	await _settle()
	var path := _temporary.path_join("manual_after_cancel.json")
	_editor._file_dialog.hide()
	_editor._file_dialog.file_selected.emit(path)
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and not model.is_dirty() and model.path == path and FileAccess.file_exists(path), "取消后普通保存成功仍停留编辑器")


## 新地图选定实际目标路径后写盘成功，才完成保存并退出。
func _test_first_save_success() -> void:
	await _fixture()
	var model := _editor.editor_document
	_game._go_back()
	await _settle()
	_click(_game._editor_discard_dialog._save_button.get_global_rect().get_center())
	await _settle()
	var path := _temporary.path_join("first_saved.json")
	_editor._file_dialog.hide()
	_editor._file_dialog.file_selected.emit(path)
	await _settle()
	_check(_game.page == GameShell.Page.MAIN and not model.is_dirty() and FileAccess.file_exists(path), "首次选定保存路径并成功写盘后返回主菜单")


## 校验失败不能覆盖有效地图或遗留退出标志，修正后普通保存仍留在编辑器。
func _test_validation_failure() -> void:
	var path := _temporary.path_join("validation.json")
	await _fixture(path)
	var baseline := FileAccess.get_file_as_string(path)
	var model := _editor.editor_document
	model.set_identity("", "需要修正标识的草稿")
	var before := _signature(model)
	var history := model._undo_stack.size()
	_game._go_back()
	await _settle()
	_click(_game._editor_discard_dialog._save_button.get_global_rect().get_center())
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and not _game._editor_exit_save_pending and _editor._message_dialog.visible, "非法地图提示校验失败并立即清除退出意图")
	_check(model.is_dirty() and _signature(model) == before and model._undo_stack.size() == history and FileAccess.get_file_as_string(path) == baseline, "保存失败保留文档、dirty、历史和原有效文件")
	_editor._message_dialog.hide()
	model.set_identity("repaired", "修正后的草稿")
	_editor._save_document(false)
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and not model.is_dirty() and FileAccess.get_file_as_string(path) != baseline, "失败后修正并手动保存，不会意外返回开始页")


## 将实际格心换算为视口位置，覆盖真实地图输入分派。
func _cell_point(cell: Vector2i) -> Vector2:
	return _editor._canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2(0.5, 0.5)) * _editor._canvas.cell_size)


## 完整文档签名用于比较取消前后的未知字段及地图内容。
func _signature(model: MapEditorDocument) -> String:
	return JSON.stringify(model.document.to_dict(), "", true)


## 鼠标按下和松开都经视口分发，不直接调用按钮业务方法。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)


## 悬停与移出经实际视口输入分派，避免只调用信号漏掉输入设备切换。
func _move(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


## 检查控件真正用于绘制的焦点样式，兼容透明描边与无描边实现。
func _focus_border_visible(button: Button) -> bool:
	var style := button.get_theme_stylebox("focus") as StyleBoxFlat
	return style != null and style.border_color.a > 0.01 and (style.border_width_left + style.border_width_top + style.border_width_right + style.border_width_bottom) > 0


## 普通按键和编辑快捷键走相同输入管线，验证模态窗口阻断穿透。
func _key(code: Key, command: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = pressed
		event.ctrl_pressed = command
		root.push_input(event, true)


## 等待容器、焦点、翻译和页面释放完成。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 失败继续记录，以便一次定位独立回归。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("失败：" + message)


## 只递归删除本次进程独占的测试目录，绝不触碰玩家存档。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for folder in directory.get_directories():
		_cleanup(path.path_join(folder))
	DirAccess.remove_absolute(path)
