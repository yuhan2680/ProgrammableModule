extends SceneTree
## 真正编辑器多选、悬停走字、文件往返和装配流程回归，所有存储隔离。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _capture_dir := ""


## 可选真实 GPU 截图，延迟构建正式编辑器。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 覆盖多选输入、布局、历史、语言以及自定义关卡两种游玩入口。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/module_restriction_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	var editor := _game._editor
	editor._load_document(MapEditor.DEFAULT_MAP_PATH) # 此回归需要有出生点的既有地图夹具。
	var model := editor.editor_document
	var choice := editor._restriction_choice
	var picker := editor._restriction_picker
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	_check(choice != null and not model.is_dirty() and not model.can_undo(), "旧图打开有禁止模块字段且不制造修改")
	_check(choice.is_ancestor_of(choice._caption) and choice._clip.clip_contents, "长名称绘制在独立裁剪区")
	scroll.ensure_control_visible(choice)
	await _settle()
	_click(choice.get_global_rect().get_center())
	await _settle()
	_check(picker.is_open() and picker._ids.size() == editor.registry.modules.size(), "真实下拉只列出目录全部模块，没有清空项")
	_check(is_equal_approx(picker._panel.size.x, choice.size.x) and is_equal_approx(picker._panel.position.x, choice.global_position.x), "展开列表与预览框等宽且左右对齐")
	for id in model.get_restricted_modules(editor.registry):
		var index := picker._ids.find(id)
		picker._scroll.ensure_control_visible(picker._items[index])
		await _settle()
		_click(picker._items[index].get_global_rect().get_center())
		await _settle()
	_check(picker.is_open() and model.get_restricted_modules(editor.registry).is_empty() and choice._caption.text == "不限制", "逐项取消全部限制才显示不限制，菜单保持打开")
	for id: String in ["radar", "rangefinder"]:
		var index := picker._ids.find(id)
		picker._scroll.ensure_control_visible(picker._items[index])
		await _settle()
		_click(picker._items[index].get_global_rect().get_center())
		await _settle()
		_check(picker.is_open() and id in model.get_restricted_modules(editor.registry), "真实点击连续多选：" + id)
	_check(model.get_restricted_modules(editor.registry).size() == 2 and choice._caption.text.contains(", "), "字段显示两个实际名字并以逗号分隔")
	await _test_lock_animation(picker)
	var before := model.document.to_dict()
	_key(KEY_S, true)
	await _settle()
	_check(model.document.to_dict() == before and model.path == MapEditor.DEFAULT_MAP_PATH, "多选菜单内保存快捷键不泄漏")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not picker.is_open() and choice.has_focus(), "Esc关闭菜单并恢复入口焦点")
	await _test_focus_modes(editor, choice, picker)
	model.undo()
	_check(model.get_restricted_modules(editor.registry).size() == 1, "最后一次勾选可独立撤销")
	model.redo()
	_check(model.get_restricted_modules(editor.registry).size() == 2, "重做恢复多选")
	editor._save_document(false)
	var saved_path := model.path
	_check(saved_path.begins_with(_temporary) and not model.is_dirty(), "普通保存将禁止列表写入隔离玩家关卡")
	editor._load_document(saved_path)
	await _settle()
	_check(model.get_restricted_modules(editor.registry).size() == 2 and not model.is_dirty(), "保存后重开同步显示两个禁止模块")
	var width := choice.size.x
	model.set_restricted_modules(editor.registry.modules.keys(), editor.registry)
	await _settle()
	_check(is_equal_approx(choice.size.x, width) and choice._overflow, "全部模块长文本仍保持原字段宽度")
	var data := model.document.to_dict()
	for language: String in ["en", "zh_HK", "zh_CN"]:
		_game.settings.set_language(language)
		await _settle()
		_check(choice.size.x <= 320 and model.document.to_dict() == data, "三语显示不会撑宽卡片或改写模块 ID：" + language)
	_game.settings.set_language("zh_CN")
	await _settle()
	scroll.ensure_control_visible(choice)
	await _settle()
	_move(choice.get_global_rect().get_center())
	await create_timer(1.1).timeout
	_check(choice._offset < 0 and choice._caption.position.x < 0 and choice._repeat.position.x > choice._caption.position.x and choice._repeat.visible, "超长名字从右往左走字，后续副本从右侧接续")
	_move(Vector2(10, 700))
	await _settle()
	_check(is_zero_approx(choice._offset) and not choice._repeat.visible and not choice.is_processing(), "鼠标离开后走字归零并停止处理")
	model.set_restricted_modules(["radar", "rangefinder"], editor.registry)
	await _settle()
	if not _capture_dir.is_empty() and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		await RenderingServer.frame_post_draw
		_check(root.get_texture().get_image().save_png(_capture_dir.path_join("restrictions-editor.png")) == OK, "保存真实属性字段截图")
		_click(choice.get_global_rect().get_center())
		await _settle()
		await RenderingServer.frame_post_draw
		_check(root.get_texture().get_image().save_png(_capture_dir.path_join("restrictions-picker.png")) == OK, "保存真实多选菜单截图")
		_key(KEY_ESCAPE)
		await _settle()
	var snapshot := model.document.to_dict()
	editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and not "radar" in _game.session.level.allowed_modules, "未保存限制进入试玩真实装配")
	_check(_game.assembly_panel.palette_buttons.radar.disabled and _game.assembly_panel.palette_buttons.rangefinder.disabled and not _game.assembly_panel.palette_buttons.movement.disabled, "真实装配目录禁用受限模块并保留未受限项")
	_game._dialogue_dialog.hide()
	if _game.session != null:
		_check(not _game.session.assembly.add_module("radar", Vector2.ZERO).is_ok(), "试玩装配无法选择受限模块")
		_check(_game.session.assembly.add_module("movement", Vector2.ZERO).is_ok(), "试玩保留未受限模块")
		_game._confirm_assembly_button.pressed.emit()
		await _settle()
		_check(_game.page == GameShell.Page.PLAY, "未受限装配正常进入编程")
	_game._return_to_editor()
	await _settle()
	_check(model.document.to_dict() == snapshot and not picker.is_open(), "返回编辑器保留限制和历史，浮层不残留")
	editor._new_document()
	_check(model.document.properties.level.restricted_modules == [] and choice._caption.text == "不限制", "新建地图默认不限制，不沿用前一地图禁止项")
	var definition := LevelDefinition.from_document(MapCodec.load_file(saved_path, editor.registry, true).value, editor.registry, saved_path)
	var blocked_draft := [{"id": "old_sensor", "module_id": "radar", "offset": {"x": 0.0, "y": 0.0}}]
	_check(_game.drafts.save_draft(definition.value.id, "main() {}", blocked_draft).is_ok(), "创建此前保存的雷达装配草稿")
	_game._enter_level(definition.value)
	await _settle()
	_game._dialogue_dialog.hide()
	_game._message_dialog.hide()
	_check(_game._saved_modules.is_empty() and _game.session.assembly.modules.is_empty() and _game._draft_needs_recovery, "旧受限装配草稿被拒绝，原文件保留供恢复")
	_game._restore_saved_assembly()
	_check(_game.session.assembly.modules.is_empty(), "主动恢复入口也不能安装受限旧装配")
	_check(_game.page == GameShell.Page.ASSEMBLY and not _game.session.assembly.add_module("rangefinder", Vector2.ZERO).is_ok(), "已保存玩家关卡正式游玩同样禁止受限模块")
	_game._return_to_editor()
	await _settle()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("模块限制界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 真实鼠标关闭/移动不留下蓝框，键盘关闭保留焦点提示，外部完整点击不穿透地图。
func _test_focus_modes(editor: MapEditor, choice: ModuleRestrictionChoice, picker: ModuleRestrictionPicker) -> void:
	var before := editor.editor_document.document.to_dict()
	_check(choice.has_focus() and choice.is_keyboard_focus_visible() and not choice.get_theme_stylebox("focus") is StyleBoxEmpty, "Esc收起后仍保留键盘焦点及可见提示")
	_move(Vector2(10, 700))
	await _settle()
	_check(choice.has_focus() and not choice.is_keyboard_focus_visible() and choice.get_theme_stylebox("focus") is StyleBoxEmpty, "仅移动鼠标就移除蓝框，不必点击其他按钮")
	_click(choice.get_global_rect().get_center())
	await _settle()
	_check(picker.is_open() and not choice.is_keyboard_focus_visible(), "鼠标重新打开菜单不显示键盘蓝框")
	_click(Vector2(500, 350))
	await _settle()
	_check(not picker.is_open() and not choice.has_focus() and choice.get_theme_stylebox("focus") is StyleBoxEmpty, "鼠标在地图空白处收起菜单后真正失焦且无残留蓝框")
	_check(editor.editor_document.document.to_dict() == before, "收起菜单的鼠标按下抬起不会穿透并绘制地图")
	choice.grab_focus()
	_key(KEY_ENTER)
	await _settle()
	_check(picker.is_open() and choice.is_keyboard_focus_visible(), "入口仍可用键盘回车打开菜单并恢复焦点提示")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not picker.is_open() and choice.has_focus() and choice.is_keyboard_focus_visible(), "键盘 Esc 关闭后可继续从入口导航")
	_move(choice.get_global_rect().get_center())
	await _settle()
	_check(choice.get_theme_stylebox("focus") is StyleBoxEmpty, "键盘关闭后移回预览框也立即去除蓝框")


## 动画显示真实限制状态，重复同步不重播，快速切换平滑反向且不改变菜单尺寸。
func _test_lock_animation(picker: ModuleRestrictionPicker) -> void:
	var index := picker._ids.find("radar")
	var lock := picker._locks[index]
	var original_size := picker._panel.size
	await create_timer(0.25).timeout
	_check(lock.locked and is_zero_approx(lock._openness), "受限模块显示完全锁上的锁头")
	_click(picker._items[index].get_global_rect().get_center())
	await create_timer(0.08).timeout
	_check(not lock.locked and lock._openness > 0 and lock._openness < 1, "取消限制时锁梁正在平滑抬起")
	_click(picker._items[index].get_global_rect().get_center())
	await create_timer(0.25).timeout
	_check(lock.locked and is_zero_approx(lock._openness), "动画途中重新限制可平滑反向并完全锁上")
	_click(picker._items[index].get_global_rect().get_center())
	await create_timer(0.25).timeout
	_check(not lock.locked and is_equal_approx(lock._openness, 1.0), "未受限模块显示完全开启的锁头")
	_click(picker._items[index].get_global_rect().get_center())
	await create_timer(0.25).timeout
	_check(picker._panel.size == original_size, "锁头开合不改变菜单布局")


## 真实鼠标移动用于验证进入和离开悬停，而不是直接调用内部动画。
func _move(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


## 完整按下抬起交给原生 GUI 输入处理。
func _click(point: Vector2) -> void:
	_move(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event, true)


## 键盘事件经过浮层与编辑器实际处理链。
func _key(key: Key, modifier: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		event.ctrl_pressed = modifier
		root.push_input(event, true)


## 等待容器和延迟焦点更新。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 汇总检查并返回明确失败状态。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 清理本轮独占目录。
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
