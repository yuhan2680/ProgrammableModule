extends SceneTree
## 玩家关卡原位改名通过真实键鼠验证取消、校验、提交与旧目录快照保护。

var _checks := 0
var _failures := 0
var _temporary: String
var _game: GameShell
var _map_path: String
var _capture := ""


## 延后构造场景，截图仅写入显式指定的测试路径。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture = argument.trim_prefix("--capture=")
	_run.call_deferred()


## 用独占地图及游玩记录测试原位输入，取消和非法内容都不得改写地图。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/player_management_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	root.add_child(_game)
	for unused in 600:
		if _game.startup_complete:
			break
		await process_frame
	await _settle()
	var doc := _game.catalog.levels[0].document.duplicate_document()
	doc.id = "rename_ui"
	doc.display_name = "原始关卡"
	doc.properties.level["creator"] = "Muna"
	doc.extra["extension"] = {"keep": [1, "自定义"]}
	var store := PlayerLevelStore.new()
	store.directory = _game.user_levels_directory
	var saved := store.save(doc, _game.registry)
	_check(saved.is_ok(), "创建独立玩家地图")
	if not saved.is_ok():
		quit(1)
		return
	_map_path = saved.value.path
	_check(_game.drafts.save_draft(doc.id, "main() {}", []).is_ok(), "创建本轮程序草稿")
	_check(_game.drafts.mark_completed(doc.id).is_ok(), "创建本轮通关记录")
	var record_bytes := _records()
	var original := FileAccess.get_file_as_bytes(_map_path)
	_game.catalog.refresh(_game.registry)
	_game._show_level_page()
	await _settle()
	await _test_inline_geometry()
	await _test_cancel(original)
	await _test_text_menu(original)
	await _test_invalid_names(original)
	await _test_clipboard(original)
	await _start_rename()
	var longest_name := "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"
	_type_name(longest_name)
	await _key(KEY_ENTER)
	_check(_game._rename_input == null and _player().display_name == longest_name, "三十字符英文名称可以经真实回车完整保存")
	await _start_rename()
	var active := _game._rename_input
	_type_name("新关卡_Muna-É3")
	_check(active.text == "新关卡_Muna-É3", "键入内容替换原有名称而不是追加")
	_game.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	await _settle()
	_check(_game._rename_input == active and active.has_focus() and active.text == "新关卡_Muna-É3", "应用重新获得焦点不刷新或丢弃未确认名称")
	await _key(KEY_ENTER)
	_check(_game._rename_input == null and not _game._message_dialog.visible, "合法名称回车后退出原位编辑，不显示弹窗")
	var renamed := _player()
	_check(renamed.display_name == "新关卡_Muna-É3" and renamed.id == doc.id, "中文与 Unicode 字母、数字和连接符原样保存且 ID 不变")
	_check(renamed.source_path == _map_path and renamed.creator == "Muna", "改名保持文件路径和署名")
	_check(JSON.parse_string(JSON.stringify(renamed.document.extra.get("extension"))) == JSON.parse_string(JSON.stringify(doc.extra.extension)), "改名保留扩展内容")
	_check(_records() == record_bytes and _game.drafts.is_completed(doc.id), "通关和草稿文件字节完全不变")
	var restart := LevelCatalog.new()
	restart.user_directory = _game.user_levels_directory
	restart.refresh(_game.registry)
	var persisted := false
	for entry: LevelDefinition in restart.levels:
		if entry.id == doc.id:
			persisted = entry.display_name == "新关卡_Muna-É3"
	_check(persisted, "重新扫描仍显示保存的新名称")
	await _test_stale_editor()
	_check(_records() == record_bytes, "失败与取消均不写游玩记录")
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("玩家关卡管理界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 输入覆盖标题而不插入额外布局行，最小尺寸及常用窗口下都保持卡片几何。
func _test_inline_geometry() -> void:
	for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		var title := _card().get_node("LevelCardTitle") as Label
		var title_rect := title.get_global_rect()
		var caption := _card().get_node("LevelCardCaption") as Label
		var caption_rect := caption.get_global_rect()
		var card_rect := _card().get_global_rect()
		await _start_rename()
		var edit := _game._rename_input
		_check(is_instance_valid(edit) and edit.has_focus() and edit.get_parent() == title, "重命名直接聚焦原卡片标题：" + str(dimensions))
		if not is_instance_valid(edit):
			return
		_check(edit.text == "原始关卡" and edit.get_selected_text() == "原始关卡", "填入并全选当前名称：" + str(dimensions))
		_check(edit.caret_blink, "原位名称输入光标闪烁")
		_check(edit.get_global_rect().get_center().distance_to(title_rect.get_center()) < 1.0, "输入框仍以原标题中心对齐：%s → %s" % [title_rect, edit.get_global_rect()])
		_check(edit.size.x <= title.size.x + 10 and edit.size.y <= 40, "编辑区域保持单张卡片宽度及紧凑高度")
		_check(title.get_global_rect().is_equal_approx(title_rect) and caption.get_global_rect().is_equal_approx(caption_rect) and _card().get_global_rect().is_equal_approx(card_rect), "编辑前后标题、署名和卡片布局均不跳动")
		_check(root.get_visible_rect().encloses(edit.get_global_rect()), "最小窗口下原位输入框完整可见")
		var borderless := true
		for state in ["normal", "focus"]:
			var style := edit.get_theme_stylebox(state) as StyleBoxFlat
			borderless = borderless and style != null and style.bg_color.a == 0 and style.border_color.a == 0 and style.get_border_width_min() == 0
		_check(borderless, "合法名字只显示选区与光标，输入区域无背景及外边框")
		_check(not _game._message_dialog.visible and not _game._import_dialog.visible, "改名不打开提示或文件弹窗")
		await _capture_state("")
		await _key(KEY_ESCAPE)


## Esc、空白及其他控件都取消；结束后残留提交回调不能再次写盘。
func _test_cancel(original: PackedByteArray) -> void:
	await _start_rename()
	_type_name("取消的新名称")
	await _key(KEY_ESCAPE)
	_check(_game._rename_input == null and _game._rename_target == null and _game.page == GameShell.Page.LEVELS, "Esc 取消编辑并留在关卡页")
	_check((_card().get_node("LevelCardTitle") as Label).self_modulate.a == 1.0, "取消后恢复原有标题可见性")
	_game._confirm_rename_player_level()
	_check(FileAccess.get_file_as_bytes(_map_path) == original, "Esc 后旧确认回调不会写盘")
	await _start_rename()
	var old_edit := _game._rename_input
	_game._cancel_player_level_rename()
	_game._rename_player_level(_player())
	var next_edit := _game._rename_input
	old_edit.text_submitted.emit("过期提交")
	old_edit.text_changed.emit("%")
	await _settle()
	_check(_game._rename_input == next_edit and next_edit.text == "原始关卡" and FileAccess.get_file_as_bytes(_map_path) == original, "旧输入框延迟信号不会确认或污染下一次编辑")
	await _key(KEY_ESCAPE)
	await _start_rename()
	_type_name("空白取消")
	await _click(Vector2(12, root.size.y - 24))
	_check(_game._rename_input == null and FileAccess.get_file_as_bytes(_map_path) == original, "点击页面空白取消，不隐式提交")
	await _start_rename()
	_type_name("切换控件取消")
	await _click(_game._tutorial_toggle.get_global_rect().get_center())
	_check(_game._rename_input == null and FileAccess.get_file_as_bytes(_map_path) == original, "点击其他按钮取消编辑，同时不保存待输入名称")
	_game._toggle_tutorials()
	await _settle()
	await _start_rename()
	_type_name("失焦取消")
	await _key(KEY_TAB)
	_check(_game._rename_input == null and FileAccess.get_file_as_bytes(_map_path) == original, "Tab 离开输入框只取消，不自动提交")


## 文本右键菜单属于当前编辑，Esc 只收起菜单且继续保留原位输入焦点。
func _test_text_menu(original: PackedByteArray) -> void:
	await _start_rename()
	var edit := _game._rename_input
	await _click(edit.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	var menu := edit.get_menu()
	_check(menu.visible and _game._rename_input == edit, "右键名称打开原生文本菜单，不取消重命名")
	await _key(KEY_ESCAPE)
	_check(not menu.visible and _game._rename_input == edit and edit.has_focus(), "Esc 关闭文本菜单后恢复输入焦点，不退出重命名：menu=%s active=%s focus=%s" % [menu.visible, _game._rename_input == edit, edit.has_focus()])
	if _game._rename_input == edit:
		_type_name("文本菜单后继续输入")
		_check(edit.text == "文本菜单后继续输入", "关闭文本菜单后仍能直接键入")
		await _key(KEY_ESCAPE)
	_check(FileAccess.get_file_as_bytes(_map_path) == original, "文本菜单和取消不修改地图")


## 非法原文保留供修改，各种空白、标点及 emoji 均不能通过真实回车落盘。
func _test_invalid_names(original: PackedByteArray) -> void:
	await _start_rename()
	for candidate in ["", " ", "前 后", "前\t后", "前\n后", "空白\u00a0", "隐形\u200b", "关卡%1", "关卡/1", "关卡\\1", "关卡.1", "关卡🌊", "关卡1️⃣", "abcdefghijklmnopqrstuvwxyz12345"]:
		_game._rename_input.text = candidate
		_game._rename_input.text_changed.emit(candidate)
		var supplied := _game._rename_input.text
		await _key(KEY_ENTER)
		_check(is_instance_valid(_game._rename_input) and _game._rename_input.has_focus() and FileAccess.get_file_as_bytes(_map_path) == original, "非法名字回车不能保存：" + candidate.c_escape())
		if not is_instance_valid(_game._rename_input):
			await _start_rename()
			continue
		_check(_game._rename_input.text == supplied and not _game._message_dialog.visible, "非法内容保留供修正，不弹窗或悄悄清洗")
		var style := _game._rename_input.get_theme_stylebox("focus") as StyleBoxFlat
		_check(style != null and style.border_color == GameTheme.ERROR and not _game._rename_input.tooltip_text.is_empty(), "非法名称通过边框和悬停信息说明原因")
	await _capture_state("-invalid")
	await _key(KEY_ESCAPE)


## 真显示环境经系统剪贴板和原生粘贴验证绕过键入过滤的字符仍无法提交，并恢复原剪贴板。
func _test_clipboard(original: PackedByteArray) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var prior_clipboard := DisplayServer.clipboard_get()
	await _start_rename()
	DisplayServer.clipboard_set("复制 % 🌊 名称")
	_game._rename_input.select_all()
	await _key(KEY_V, true)
	_check(_game._rename_input.text == "复制 % 🌊 名称", "系统粘贴确实到达原位输入框")
	var edit := _game._rename_input
	edit.select_all()
	await _click(edit.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	var menu := edit.get_menu()
	menu.set_focused_item(menu.get_item_index(LineEdit.MENU_COPY))
	await _key(KEY_ENTER)
	_check(not menu.visible and _game._rename_input == edit and edit.has_focus() and DisplayServer.clipboard_get() == "复制 % 🌊 名称", "原生复制命令关闭菜单后继续保持编辑及焦点")
	DisplayServer.clipboard_set("粘贴%🌊")
	edit.select_all()
	await _click(edit.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	menu.set_focused_item(menu.get_item_index(LineEdit.MENU_PASTE))
	await _key(KEY_ENTER)
	_check(not menu.visible and _game._rename_input == edit and edit.has_focus() and edit.text == "粘贴%🌊", "原生粘贴命令替换选中名称后继续保持编辑及焦点")
	await _key(KEY_ENTER)
	_check(is_instance_valid(_game._rename_input) and FileAccess.get_file_as_bytes(_map_path) == original, "强行粘贴非法字符后回车仍不能修改地图")
	DisplayServer.clipboard_set("abcdefghijklmnopqrstuvwxyz12345")
	edit.select_all()
	await _key(KEY_V, true)
	await _key(KEY_ENTER)
	_check(is_instance_valid(_game._rename_input) and edit.text == "abcdefghijklmnopqrstuvwxyz12345" and FileAccess.get_file_as_bytes(_map_path) == original, "粘贴三十一个合法字符仍因超过三十字上限被拒绝，且不会静默截断")
	DisplayServer.clipboard_set(prior_clipboard)
	await _key(KEY_ESCAPE)


## 换页以及外部修改都使旧编辑不能覆盖内容；冲突仍在原位提示而非打开弹窗。
func _test_stale_editor() -> void:
	await _start_rename()
	_type_name("不应写入的旧编辑内容")
	_game._show_main_page()
	_game._confirm_rename_player_level()
	await _settle()
	_check(_game._rename_input == null and MapCodec.load_file(_map_path, _game.registry).value.display_name == "新关卡_Muna-É3", "换页后旧确认无效且输入框被释放")
	_game._show_level_page()
	await _settle()
	await _start_rename()
	var external := MapCodec.load_file(_map_path, _game.registry).value as MapDocument
	external.display_name = "外部编辑的新名称"
	_check(MapCodec.save_file(external, _map_path, _game.registry).is_ok(), "模拟编辑期间外部修改地图")
	var changed_bytes := FileAccess.get_file_as_bytes(_map_path)
	_type_name("不能覆盖外部修改")
	await _key(KEY_ENTER)
	_check(is_instance_valid(_game._rename_input) and not _game._rename_input.tooltip_text.is_empty() and not _game._message_dialog.visible, "外部变化在名称框提示问题，保留待编辑内容")
	_check(FileAccess.get_file_as_bytes(_map_path) == changed_bytes, "过期编辑不覆盖外部变化")
	await _key(KEY_ESCAPE)
	_game._rename_player_level(_game.catalog.levels[0])
	_check(_game._rename_input == null, "教学关卡不能经重命名入口修改")


## 经右键菜单选择重命名，完整复现标题命中及菜单关闭后的焦点交接。
func _start_rename() -> void:
	var title := _card().get_node("LevelCardTitle") as Control
	var scroll := _game.find_child("LevelScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(title)
	await _settle()
	await _click(title.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _click(_game._player_level_context_menu._rename_button.get_global_rect().get_center())


## 从当前目录取回同 ID 的新快照，避免误用刷新前对象。
func _player() -> LevelDefinition:
	for entry: LevelDefinition in _game.catalog.levels:
		if entry.id == "rename_ui":
			return entry
	return null


## 通过稳定身份定位标题所在卡片，不依赖刷新后的排序位置。
func _card() -> Control:
	for entry in _game._level_entries:
		if entry.definition.id == "rename_ui":
			return entry.control
	return null


## 对独立游玩目录拍字节快照，改名无需迁移或重写历史记录。
func _records() -> Dictionary:
	var result := {}
	for filename: String in DirAccess.get_files_at(_game.drafts_directory):
		result[filename] = FileAccess.get_file_as_bytes(_game.drafts_directory.path_join(filename))
	return result


## 通过视口输入文字，依靠当前全选状态替换标题，避免直接调用提交回调。
func _type_name(value: String) -> void:
	_game._rename_input.select_all()
	for character in value:
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = character.unicode_at(0)
		root.push_input(event, true)


## 按下与抬起键盘均走真实输入路由；粘贴使用当前平台惯用的快捷键。
func _key(key: Key, command: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = down
		event.meta_pressed = command and OS.get_name() == "macOS"
		event.ctrl_pressed = command and OS.get_name() != "macOS"
		root.push_input(event, true)
		await process_frame
	await _settle()


## 鼠标事件先移动再完整按下与抬起，覆盖真实点击导致的焦点变化。
func _click(position: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = button
		event.pressed = down
		event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if down else 0
		root.push_input(event, true)
		await process_frame
	await _settle()


## 截图只来自真实 GPU 渲染；非法状态单独保存便于检查原位反馈。
func _capture_state(suffix: String) -> void:
	if _capture.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := _capture.get_basename() + suffix + ".png"
	_check(root.get_texture().get_image().save_png(path) == OK, "保存原位重命名截图：" + suffix)


## 等待布局和延迟释放完成，事件本身不依赖硬编码长时间等待。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 记录所有断言，保证异常边界仍有可定位输出。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只清理当前测试生成的独立目录。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	for filename: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory: String in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(directory))
	DirAccess.remove_absolute(path)
