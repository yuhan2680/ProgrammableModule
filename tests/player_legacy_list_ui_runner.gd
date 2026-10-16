extends SceneTree
## 旧目录条目只通过专用菜单请求迁移，所有夹具都是内存快照，不读取真实玩家文件。

var _checks := 0
var _failures := 0
var _capture_directory := ""
var _fixture: Control
var _panel: PlayerLevelListPanel
var _legacy: PlayerLevelRecord
var _broken_legacy: PlayerLevelRecord
var _normal: PlayerLevelRecord
var _requests: Array[Dictionary] = []


## 延后构造界面，截图仅在显式传入目录且使用实际 GPU 时保存。
func _initialize() -> void:
	Engine.max_fps = 120
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 同名新旧条目共存，依次验证状态、鼠标键盘路由、菜单隔离及翻译布局。
func _run() -> void:
	var original_locale := TranslationServer.get_locale()
	GameI18n.install()
	TranslationServer.set_locale("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_fixture = Control.new()
	_fixture.theme = GameTheme.create_theme()
	root.add_child(_fixture)
	_fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color.WHITE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixture.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_legacy = _record("user://levels/shared.json", "同名关卡", true)
	# 刻意保留旧能力值，验证显示层不会仅依赖资料库预先清空它们。
	_legacy.can_edit = true
	_legacy.can_rename = true
	_broken_legacy = _record("user://levels/broken.json", "旧损坏文件", true)
	_broken_legacy.is_corrupt = true
	_broken_legacy.errors = PackedStringArray(["文件损坏"])
	_normal = _record("user://tests/legacy_ui/current/shared.json", "同名关卡", false)
	_panel = PlayerLevelListPanel.new()
	_panel.set_entries([_legacy, _normal, _broken_legacy])
	_panel.migration_requested.connect(_record_request.bind("migrate"))
	_panel.open_folder_requested.connect(_record_request.bind("folder"))
	_panel.edit_requested.connect(_record_request.bind("edit"))
	_panel.delete_requested.connect(_record_request.bind("delete"))
	_panel.rename_requested.connect(func(entry: PlayerLevelRecord, _name: String) -> void: _record_request(entry, "rename"))
	_fixture.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	_test_statuses()
	await _test_legacy_mouse_and_keyboard()
	await _test_normal_actions()
	await _test_translation_and_refresh()
	_fixture.queue_free()
	await _settle()
	TranslationServer.set_locale(original_locale)
	print("旧目录关卡列表界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 构造纯内存列表记录，路径只承担行标识而不授予磁盘权限。
func _record(path: String, title: String, legacy: bool) -> PlayerLevelRecord:
	var entry := PlayerLevelRecord.new()
	entry.source_path = path
	entry.display_name = title
	entry.creator = "作者"
	entry.needs_migration = legacy
	entry.can_edit = not legacy
	entry.can_rename = not legacy
	entry.playable = not legacy
	return entry


## 目录状态优先于文件诊断，颜色精确且同名不同路径不会覆盖彼此。
func _test_statuses() -> void:
	_check(_panel._rows.size() == 3, "同名的新旧目录记录分别保留")
	for entry in [_legacy, _broken_legacy]:
		var status := _panel._rows[entry.source_path].status as Label
		_check(status.text == "目录错误", "旧目录优先显示目录错误：" + entry.source_path)
		_check(status.get_theme_color("font_color") == Color("ff2c2c"), "旧目录状态色准确为 #ff2c2c")
	_check((_panel._rows[_normal.source_path].status as Label).text == "状态正常", "正常目录条目保持正常状态")
	_check((_panel._rows[_normal.source_path].status as Label).get_theme_color("font_color") == GameTheme.TEXT, "正常目录状态不染红")
	_check(_row(_broken_legacy).tooltip_text.contains("文件损坏"), "旧文件的内容诊断仍保留在悬停提示")


## 真实右键、点击及键盘只触发旧目录允许的两个动作，编辑快捷方式全部无效。
func _test_legacy_mouse_and_keyboard() -> void:
	await _open_menu(_legacy)
	_check_legacy_menu()
	await _capture("legacy-list-context")
	await _click_control(_panel.find_child("ListMigratePlayerLevelButton", true, false) as Control)
	_check(_requests.size() == 1 and _requests[0].action == "migrate" and _requests[0].entry == _legacy, "迁移按钮准确发出选中旧条目")
	_check(not _panel.is_context_menu_open(), "迁移请求前先关闭菜单")
	await _open_menu(_broken_legacy)
	await _click_control(_panel.find_child("ListOpenLegacyPlayerLevelFolderButton", true, false) as Control)
	_check(_requests.size() == 2 and _requests[1].action == "folder" and _requests[1].entry == _broken_legacy, "打开旧目录沿原文件夹信号传递正确记录")
	var count := _requests.size()
	await _click_control(_row(_legacy), MOUSE_BUTTON_LEFT, true)
	_row(_legacy).grab_focus()
	for code in [KEY_ENTER, KEY_F2, KEY_DELETE, KEY_BACKSPACE]:
		await _key(code)
	_check(_requests.size() == count and not _panel.is_editing(), "旧条目双击、回车、F2、Delete、Backspace 均不能编辑改名或删除")
	_panel._begin_rename(_legacy)
	_check(not _panel.is_editing(), "旧记录即使保留旧 can_rename 值也不能进入原位编辑")
	_row(_legacy).grab_focus()
	await _key(KEY_MENU)
	_check(_panel.is_context_menu_open(), "菜单键打开旧条目的专用菜单")
	_check_legacy_menu()
	for action in ["rename", "edit", "delete"]:
		_panel._context_menu._activate(action)
	_check(_requests.size() == count and _panel.is_context_menu_open(), "过期或伪造普通动作不能作用于旧目录记录")
	await _key(KEY_DOWN)
	await _key(KEY_ENTER)
	_check(_requests.size() == count + 1 and _requests.back().action == "folder" and _requests.back().entry == _legacy, "方向键和回车可执行第二个旧目录动作")
	await _open_menu(_legacy)
	await _key(KEY_ESCAPE)
	_check(not _panel.is_context_menu_open() and _requests.size() == count + 1, "Esc 只关闭旧目录菜单")
	await _open_menu(_legacy)
	await _click(Vector2(24, 24), MOUSE_BUTTON_LEFT)
	_check(not _panel.is_context_menu_open() and _requests.size() == count + 1, "菜单外点击只关闭，不发出后台操作")


## 切回正常条目恢复完整四项菜单，原操作仍可用且不存在旧目录专用入口。
func _test_normal_actions() -> void:
	await _open_menu(_normal)
	var menu := _panel._context_menu
	_check(menu._items.size() == 4, "正常条目保留四项原菜单")
	_check(_panel.find_child("ListMigratePlayerLevelButton", true, false) == null and _panel.find_child("ListOpenLegacyPlayerLevelFolderButton", true, false) == null, "普通菜单不残留旧目录项目")
	var count := _requests.size()
	menu._activate("migrate")
	_check(_requests.size() == count and menu.is_open(), "正常条目拒绝过期迁移动作")
	await _click_control(_panel.find_child("ListRenamePlayerLevelButton", true, false) as Control)
	_check(_panel.is_editing() and _panel._rename_entry == _normal, "正常条目仍可进入原位重命名")
	await _key(KEY_ESCAPE)
	for pair in [["ListDeletePlayerLevelButton", "delete"], ["ListEditPlayerLevelButton", "edit"], ["ListOpenPlayerLevelFolderButton", "folder"]]:
		await _open_menu(_normal)
		await _click_control(_panel.find_child(pair[0], true, false) as Control)
		_check(_requests.back().action == pair[1] and _requests.back().entry == _normal, "正常菜单保持原操作：" + pair[1])
	await _open_menu(_legacy)
	_check_legacy_menu()
	menu.close_menu(false)


## 五种翻译在较窄窗口保持完整菜单，换语言或换快照都会关闭旧引用。
func _test_translation_and_refresh() -> void:
	root.size = Vector2i(800, 600)
	root.content_scale_size = root.size
	for locale in ["zh_CN", "zh_TW", "en", "es", "ja"]:
		TranslationServer.set_locale(locale)
		await _settle()
		await _open_menu(_legacy)
		var menu := _panel._context_menu
		_check(menu._items.size() == 2, "翻译后仍只有两个迁移动作：" + locale)
		_check(root.get_visible_rect().encloses(menu._panel.get_global_rect()), "窄屏菜单完整留在窗口内：" + locale)
		for button in menu._items:
			_check(button.size.x >= button.get_combined_minimum_size().x and menu._panel.get_global_rect().encloses(button.get_global_rect()), "翻译文字和按钮不溢出菜单：" + locale)
		menu.close_menu(false)
	TranslationServer.set_locale("zh_CN")
	await _settle()
	await _open_menu(_legacy)
	TranslationServer.set_locale("en")
	await _settle()
	_check(not _panel.is_context_menu_open(), "语言变化关闭旧尺寸菜单")
	await _open_menu(_legacy)
	var count := _requests.size()
	_panel.set_entries([_normal])
	await _settle()
	_panel._context_menu._activate("migrate")
	_check(not _panel.is_context_menu_open() and _requests.size() == count and _panel._rows.size() == 1, "刷新移除旧项后不能发出迟到迁移请求")


## 旧目录菜单真实节点集合只有两个可执行按钮，不把普通项藏起来冒充独立菜单。
func _check_legacy_menu() -> void:
	var menu := _panel._context_menu
	_check(menu._items.size() == 2 and menu._panel.find_children("*", "Button", true, false).size() == 2, "旧目录菜单只有两个真实按钮")
	_check(menu._items[0].text == "迁移到正确的目录" and menu._items[1].text == "打开旧关卡所在文件夹", "旧目录两项文字及顺序准确")
	_check(not menu._items[0].disabled and not menu._items[1].disabled, "旧目录两个动作均可用")
	for name in ["ListRenamePlayerLevelButton", "ListDeletePlayerLevelButton", "ListEditPlayerLevelButton", "ListOpenPlayerLevelFolderButton"]:
		_check(_panel.find_child(name, true, false) == null, "旧目录菜单无普通操作：" + name)
	for button in menu._items:
		var focus := button.get_theme_stylebox("focus") as StyleBoxFlat
		_check(focus != null and focus.border_color.a == 0, "菜单焦点不增加蓝色边框")


## 直接使用当前快照的源路径找行，避免同名关卡选择错误。
func _row(entry: PlayerLevelRecord) -> Button:
	return _panel._rows[entry.source_path].button as Button


## 行滚入可交互区域后发送真实右键事件。
func _open_menu(entry: PlayerLevelRecord) -> void:
	_panel._scroll.ensure_control_visible(_row(entry))
	await _settle()
	await _click_control(_row(entry), MOUSE_BUTTON_RIGHT)
	_check(_panel.is_context_menu_open() and _panel._context_menu._entry == entry, "右键打开对应记录的菜单：" + entry.source_path)


## 收集界面意图而不执行磁盘写入，验证请求的记录身份。
func _record_request(entry: PlayerLevelRecord, action: String) -> void:
	_requests.append({"entry": entry, "action": action})


## 控件点击采用完整画布变换，适用于列表正文和独立 CanvasLayer 菜单。
func _click_control(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT, double_click: bool = false) -> void:
	_check(is_instance_valid(control), "待点击控件存在")
	if is_instance_valid(control):
		await _click(control.get_global_transform_with_canvas() * (control.size * 0.5), button, double_click)


## 鼠标按下和抬起经真实输入路由发出，菜单外点击验证不会穿透。
func _click(position: Vector2, button: MouseButton, double_click: bool = false) -> void:
	if DisplayServer.get_name() != "headless":
		root.warp_mouse(position)
		await _settle()
	var window_position := root.get_final_transform() * position
	var motion := InputEventMouseMotion.new()
	motion.position = window_position
	motion.global_position = window_position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = window_position
		event.global_position = window_position
		event.button_index = button
		event.pressed = down
		event.double_click = down and double_click
		event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if down else 0
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle()


## 键盘经聚焦控件处理，检查菜单导航和旧条目的快捷键限制。
func _key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event, true)
	await _settle()


## 只保存实际渲染结果，普通无头验证不生成截图。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存旧目录菜单实际截图")


## 等待布局、延后刷新与释放完成。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 累计失败并保留具体交互场景，结束时以退出码告知结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
