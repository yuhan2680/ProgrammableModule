extends SceneTree
## 真实工作台核验逐关粘贴限制、原生入口、外部拖放以及手工编辑和提示的保留。

const SOURCE := "main() {\n    \n}\n"
const CLIPBOARD_TEXT := "move(0, 4)"
var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _clipboard_available := false
var _clipboard_before := ""


## 等待场景树就绪后测试原生编辑器，不加载玩家存档。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 同一正式地图分别建立受限、普通与试玩工作台，夹具只改内存副本。
func _run() -> void:
	create_timer(35.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 800)
	GameI18n.install()
	_check(_content.load_directories().is_ok(), "正式注册表可以加载")
	_clipboard_available = DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD)
	if _clipboard_available:
		_clipboard_before = DisplayServer.clipboard_get()
		DisplayServer.clipboard_set(CLIPBOARD_TEXT)
	for playtest in [false, true]:
		var bench := await _make_workbench(true, playtest)
		_check(bench._code is RestrictedCodeEdit, "限制关卡在正式游玩和试玩均选择受限编辑器")
		await _test_blocked_inputs(bench)
		await _test_manual_edits(bench)
		await _test_external_drag(bench, true)
		await _test_drag_run_lock(bench)
		if not playtest:
			await _test_hint(bench)
		bench.queue_free()
		await _settle()
	var ordinary := await _make_workbench(false, false)
	_check(not ordinary._code is RestrictedCodeEdit, "无限制关卡仍使用完整原生编辑器")
	_check(ordinary._code.get_menu().get_item_index(TextEdit.MENU_PASTE) >= 0, "无限制关卡保留粘贴菜单")
	if _clipboard_available:
		await _set_source(ordinary)
		ordinary._code.paste()
		await _settle()
		_check(ordinary._code.text.contains(CLIPBOARD_TEXT), "无限制关卡原生 paste 正常插入剪贴板")
		ordinary._code.undo()
		await _settle()
		_check(ordinary._code.text == SOURCE, "原生粘贴仍只占一次撤销")
		ordinary._code.menu_option(TextEdit.MENU_PASTE)
		await _settle()
		_check(ordinary._code.text.contains(CLIPBOARD_TEXT), "无限制关卡原生菜单动作可以粘贴")
		await _set_source(ordinary)
		await _key(KEY_V, false, true)
		if OS.get_name() == "macOS":
			_check(ordinary._code.text.contains(CLIPBOARD_TEXT), "macOS 普通关卡 Cmd+V 正常")
	await _test_external_drag(ordinary, false)
	ordinary.queue_free()
	await _settle()
	if _clipboard_available:
		DisplayServer.clipboard_set(_clipboard_before)
	print("逐关粘贴限制回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从正式第一关克隆规则并确认一个合法移动模块，全部数据仅驻留内存。
func _make_workbench(restrict_paste: bool, playtest: bool) -> GameWorkbench:
	var loaded := MapCodec.load_file("res://data/levels/level_001.json", _content, true)
	var document: MapDocument = loaded.value
	document.properties["level"]["restrict_code_paste"] = restrict_paste
	document.properties["level"]["allow_code_hints"] = true
	var defined := LevelDefinition.from_document(document, _content, "user://tests/paste_policy_level.json")
	_check(defined.is_ok(), "带粘贴规则的关卡可以建立")
	var session := GameSession.create(defined.value, _content)
	_check(session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "装配合法移动模块")
	var bench := GameWorkbench.new()
	bench.session = session
	bench.registry = _content
	bench.settings = GameSettings.new()
	bench.settings.code_hints = "more"
	bench.allow_draft_save = not playtest
	bench.theme = GameTheme.create_theme()
	bench.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bench)
	bench.set_process(false)
	await _settle()
	await _set_source(bench)
	return bench


## 通过实际快捷键、原生命令与菜单信号校验限制，不仅检查某个键盘事件被吃掉。
func _test_blocked_inputs(bench: GameWorkbench) -> void:
	var edit := bench._code
	_check(edit.get_menu().get_item_index(TextEdit.MENU_PASTE) == -1, "受限编辑器移除原生粘贴菜单项")
	_check(not edit.middle_mouse_paste_enabled and not edit.drag_and_drop_selection_enabled, "关闭中键粘贴和选区拖动")
	_check(edit.get_theme_stylebox("focus") is StyleBoxEmpty and edit.caret_blink, "保留闪烁光标且没有蓝色聚焦描边")
	await _mouse_button(edit.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT, true)
	await _mouse_button(edit.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT, false)
	_check(edit.is_menu_visible(), "真实右键打开原生代码编辑菜单")
	_check(edit.get_menu().get_item_index(TextEdit.MENU_PASTE) == -1 and edit.get_menu().get_item_index(TextEdit.MENU_COPY) >= 0, "菜单打开并更新后仍移除粘贴、保留复制")
	edit.get_menu().hide()
	edit.grab_focus()
	await _settle()
	edit.select(0, 0, 0, 4)
	var version := edit.get_version()
	edit.paste()
	edit.paste(0)
	edit.paste_primary_clipboard()
	edit.menu_option(TextEdit.MENU_PASTE)
	edit.get_menu().id_pressed.emit(TextEdit.MENU_PASTE)
	await _settle()
	_check(edit.text == SOURCE and edit.get_version() == version and edit.get_selected_text() == "main", "直接粘贴与菜单动作不改变文本、版本或选区")
	for modifiers in [[true, false, false, KEY_V], [false, true, false, KEY_V], [false, false, true, KEY_INSERT]]:
		await _key(modifiers[3], modifiers[0], modifiers[1], modifiers[2])
		_check(edit.text == SOURCE and edit.get_version() == version, "Ctrl+V、Cmd+V、Shift+Insert 均无法写入")
	var paste_action := InputEventAction.new()
	paste_action.action = "ui_paste"
	paste_action.pressed = true
	root.push_input(paste_action)
	await _settle()
	_check(edit.text == SOURCE and edit.get_selected_text() == "main", "原生 ui_paste 动作不改变源码与选择")
	await _mouse_button(edit.get_global_rect().get_center(), MOUSE_BUTTON_MIDDLE, true)
	await _mouse_button(edit.get_global_rect().get_center(), MOUSE_BUTTON_MIDDLE, false)
	_check(edit.text == SOURCE, "中键点击不会从选择剪贴板插入内容")


## 限制只约束外来粘贴，真实键入、删除、复制剪切、撤销重做和 Tab 补全仍可使用。
func _test_manual_edits(bench: GameWorkbench) -> void:
	await _set_source(bench)
	await _key(KEY_M, false, false, false, 109)
	await _key(KEY_O, false, false, false, 111)
	_check(bench._code.get_line(1) == "    mo", "粘贴受限时真实键入仍可编辑")
	bench._completion.refresh()
	await _settle()
	await _key(KEY_TAB)
	_check(bench._code.get_line(1) == "    move", "受限编辑器的 Tab 补全仍有效")
	bench._code.undo()
	await _settle()
	_check(bench._code.get_line(1) == "    mo", "受限编辑器保留补全撤销")
	bench._code.redo()
	await _settle()
	_check(bench._code.get_line(1) == "    move", "受限编辑器保留重做")
	await _key(KEY_BACKSPACE)
	_check(bench._code.get_line(1) == "    mov", "受限编辑器可继续删除字符")
	if _clipboard_available:
		bench._code.select(1, 4, 1, 7)
		bench._code.copy()
		_check(DisplayServer.clipboard_get() == "mov", "复制仍写入剪贴板")
		bench._code.cut()
		await _settle()
		_check(bench._code.get_line(1) == "    " and DisplayServer.clipboard_get() == "mov", "剪切仍删除选区并保留剪贴板")
		bench._code.undo()
		await _settle()
		_check(bench._code.get_line(1) == "    mov", "剪切可以撤销")
		DisplayServer.clipboard_set(CLIPBOARD_TEXT)


## 拖拽走真正的 Viewport 投放路径，受限编辑器不能靠原生字符串回退接收代码。
func _test_external_drag(bench: GameWorkbench, restricted: bool) -> void:
	await _set_source(bench)
	var drag_source := Control.new()
	root.add_child(drag_source)
	drag_source.force_drag("external_drop_payload", Label.new())
	await _settle()
	_check(root.gui_is_dragging(), "实际外部文本拖拽已经开始")
	_check(bench._code.editable != restricted, "只有受限关卡在拖拽时暂时只读")
	var point := bench._code.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion)
	await _settle()
	await _mouse_button(point, MOUSE_BUTTON_LEFT, false)
	_check(not root.gui_is_dragging(), "释放鼠标结束真实投放")
	_check((bench._code.text == SOURCE) if restricted else bench._code.text.contains("external_drop_payload"), "限制关卡拒绝拖入代码，普通关卡保留拖入")
	_check(bench._code.editable, "拖拽结束后恢复手工编辑")
	drag_source.queue_free()
	await _settle()


## 拖动期间工作台变为运行锁定，结束拖拽不得恢复过期的可编辑状态。
func _test_drag_run_lock(bench: GameWorkbench) -> void:
	var drag_source := Control.new()
	root.add_child(drag_source)
	drag_source.force_drag("outside", Label.new())
	await _settle()
	bench.session.state = GameSession.State.RUNNING
	bench._sync_session()
	await _mouse_button(Vector2(2, 2), MOUSE_BUTTON_LEFT, false)
	_check(not bench._code.editable, "拖拽中进入运行状态，结束后继续保持代码锁定")
	bench.session.state = GameSession.State.EDITING
	bench._sync_session()
	_check(bench._code.editable, "正常解除运行锁后可继续键入")
	drag_source.queue_free()
	await _settle()


## 系统提示使用独立的程序编辑事务，不依赖剪贴板，因此限粘贴仍可按关卡策略提示和撤销。
func _test_hint(bench: GameWorkbench) -> void:
	await _set_source(bench)
	bench._hint_button.pressed.emit()
	await create_timer(0.15).timeout
	await _settle()
	_check(bench._code.text.contains("move(") and bench.session.source == bench._code.text, "受限编辑器仍接受系统授权的代码提示")
	bench._hint_undo_button.pressed.emit()
	await _settle()
	_check(bench._code.text == SOURCE, "系统代码提示仍可一次撤回")


## 使用原生文本编辑器建立没有历史的起点，不经过文件或玩家档案。
func _set_source(bench: GameWorkbench) -> void:
	bench._code.text = SOURCE
	bench._code.remove_secondary_carets()
	bench._code.deselect()
	bench._code.clear_undo_history()
	bench._code.set_caret_line(1)
	bench._code.set_caret_column(4)
	bench._code.grab_focus()
	await _settle()


## 投递实际按下与松开事件，保留平台键位差异并核验真实输入路径。
func _key(keycode: Key, ctrl := false, meta := false, shift := false, unicode_value := 0) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.meta_pressed = meta
	event.shift_pressed = shift
	event.unicode = unicode_value
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await _settle()


## 通过视口鼠标事件验证中键粘贴和跨控件文本拖拽。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.button_mask = (1 << (button - 1)) if pressed else 0
	event.pressed = pressed
	root.push_input(event)
	await _settle()


## 等待原生编辑器的布局与文本变更信号完成。
func _settle() -> void:
	for unused in 4:
		await process_frame


## 保留失败原因并以非零状态返回。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 避免异步界面异常导致回归无限等待，并恢复测试借用的剪贴板。
func _timeout() -> void:
	if _clipboard_available:
		DisplayServer.clipboard_set(_clipboard_before)
	push_error("逐关粘贴限制回归超过35秒总时限。")
	quit(1)
