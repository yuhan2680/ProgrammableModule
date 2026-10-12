extends SceneTree
## 玩家关卡署名与右键操作使用独占目录，并通过真实鼠标、键盘和目录刷新验证。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""
var _capture_dir := ""
var _opened_folders: Array[String] = []
var _rename_requests: Array[LevelDefinition] = []
var _folder_open_result := OK


## 等待场景树可添加控件，仅在调用者显式请求时生成截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 构建隔离游戏和真实地图，验证本土化、布局、取消、删除和陈旧选择边界。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/player_cards_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var locale := TranslationServer.get_locale()
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	_game.folder_opener = _record_folder_open
	root.add_child(_game)
	await _settle()
	_game._player_level_context_menu.rename_requested.connect(_record_rename)
	DirAccess.make_dir_recursive_absolute(_game.user_levels_directory)
	_add_map("author_muna", "星海练习", "Muna")
	_add_map("author_cn", "可编程模块", "小涵名字不翻译")
	_add_map("author_empty", "无署名地图", "")
	_add_map("author_long", "长署名地图", "创作者姓名".repeat(24))
	_add_map("author_long_title", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "")
	_add_map("author_legacy_title", "旧版超长名字".repeat(24), "")
	_game.drafts.mark_completed("author_muna")
	_game.drafts.mark_completed("level_002")
	_game.catalog.refresh(_game.registry)
	_game._show_level_page()
	await _settle()
	for language in ["zh_CN", "zh_HK", "en"]:
		_game.settings.set_language(language)
		await _settle()
		var prefix := "Player level, by " if language == "en" else "玩家關卡，by " if language == "zh_HK" else "玩家关卡，by "
		_check(_caption("author_muna").text == prefix + "Muna", "署名由实际元数据格式化：" + language + " actual=" + _caption("author_muna").text)
		_check(_caption("author_cn").text == prefix + "小涵名字不翻译", "中文创作者不进入翻译词典：" + language)
		_check((_card("author_cn").get_node("LevelCardTitle") as Label).text == "可编程模块" and (_card("author_cn").get_node("LevelCardTitle") as Label).auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "与词典同名的玩家标题保持原文：" + language)
		_check(_caption("author_empty").text == _game.tr("玩家关卡"), "未填写署名不显示空by后缀：" + language)
		_check(_card("author_muna").get_node_or_null("PlayerLevelCompleted") != null, "完成标记独立保留，不替换署名：" + language)
		_check(not _caption("level_001").is_visible_in_tree() and _caption("level_001").text.is_empty(), "未完成教学关卡不显示说明或状态小字：" + language)
		_check(_caption("level_002").is_visible_in_tree() and TranslationServer.translate(_caption("level_002").text) == _game.tr("✓ 已完成"), "已完成教学关卡仅显示本土化完成状态：" + language)
		_check(_caption("author_muna").is_visible_in_tree() and _caption("author_cn").is_visible_in_tree(), "玩家关卡无论通关与否都保留创作者署名：" + language)
		for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
			root.size = dimensions
			root.content_scale_size = dimensions
			await _settle()
			_check_long_titles(language + str(dimensions))
			var grid := _game.find_child("ImportedLevelGrid", true, false) as Control
			_check(grid.get_global_rect().end.x <= root.get_visible_rect().end.x and _card("author_long").size.x <= 200, "长署名不撑宽七列布局：" + language + str(dimensions))
			var menu := _game._player_level_context_menu
			menu.popup_at(_button("author_muna"), Vector2(dimensions) - Vector2(2, 2), _definition("author_muna"))
			_check(root.get_visible_rect().encloses(menu._panel.get_global_rect()), "三项菜单在窗口边缘完整显示：" + language + str(dimensions))
			for item in menu._items:
				_check(item.size.x >= item.get_combined_minimum_size().x, "菜单行完整显示本土化文字：" + language + item.text)
			menu.close_menu(false)
	_game.settings.set_language("zh_CN")
	await _settle()
	await _test_scroll_layout()
	await _test_menu()
	_game.queue_free()
	await _settle()
	TranslationServer.set_locale(locale)
	_cleanup(_temporary)
	print("玩家关卡署名与删除界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从有效教学快照生成测试地图，保存字段后由正式目录重载为玩家关卡。
func _add_map(identity: String, title: String, author: String) -> void:
	var document := _game.catalog.levels[0].document.duplicate_document()
	document.id = identity
	document.display_name = title
	document.properties.level["creator"] = author
	_check(MapCodec.save_file(document, _map_path(identity), _game.registry).is_ok(), "有效署名地图写入隔离目录：" + identity)


## 长英语和旧超长名字只能在有限字号与两行内显示，不改变七列宽度或放大标题区。
func _check_long_titles(context: String) -> void:
	var normal := _card("author_empty").get_node("LevelCardTitle") as Label
	for identity: String in ["author_long_title", "author_legacy_title"]:
		var title := _card(identity).get_node("LevelCardTitle") as Label
		var font_size := title.get_theme_font_size("font_size")
		_check(font_size >= 10 and font_size < normal.get_theme_font_size("font_size"), "长名称适度缩小字号且保留可读下限：" + context + "/" + identity)
		_check(title.max_lines_visible == 2 and title.size.y <= 44 and title.size.x <= _card(identity).size.x, "长名称限制为两行且不会撑大卡片：" + context + "/" + identity)
		_check(title.tooltip_text == _definition(identity).display_name and title.text == _definition(identity).display_name, "长名称悬停显示完整原文，显示省略不会改写地图：" + context + "/" + identity)
		_check(_card(identity).size.y <= _card("author_muna").size.y, "长标题不会比同排含完成标记卡片更高：" + context + "/" + identity)


## 展开收起和搜索反复改变溢出状态，七列横向位置和宽度始终稳定，滚轮及原生条仍可操作。
func _test_scroll_layout() -> void:
	for index in 10:
		_add_map("scroll_extra_%02d" % index, "滚动测试%02d" % index, "")
	_game._refresh_levels()
	await _settle()
	for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await _settle()
		var scroll := _game.find_child("LevelScroll", true, false) as ScrollContainer
		var bar := scroll.get_v_scroll_bar()
		var grid := _game.find_child("ImportedLevelGrid", true, false) as Control
		var import_button := _game.find_child("ImportLevelButton", true, false) as Button
		var baseline := _horizontal_layout()
		var grid_width := grid.size.x
		var import_rect := import_button.get_global_rect()
		var author_width := _card("author_muna").size.x
		_check(bar.max_value <= bar.page + 1, "折叠列表未溢出，覆盖滚动条从无到有的切换：" + str(dimensions))
		await _click(_game._tutorial_toggle.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		_check(bar.max_value > bar.page, "教学展开后确实产生纵向滚动范围")
		_check_horizontal_layout(baseline, "教学展开：" + str(dimensions))
		await _click(_game._tutorial_toggle.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		_check(not _game._tutorials_expanded, "教学收起后真实展开状态已复位")
		_check_horizontal_layout(baseline, "教学收起：" + str(dimensions))
		await _click(_game._player_toggle.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		_check(bar.max_value > bar.page and _game._players_expanded, "玩家展开后确实产生纵向滚动范围")
		_check_horizontal_layout(baseline, "玩家展开：" + str(dimensions))
		_check(not scroll.get_h_scroll_bar().visible, "七列布局不会额外产生横向滚动条")
		var bar_rect := bar.get_global_rect()
		var sections := _game.find_child("LevelSections", true, false) as Control
		_check(root.get_visible_rect().encloses(bar_rect) and root.get_visible_rect().end.x - bar_rect.end.x <= 12, "纵向条完整位于窗口右侧留白内，并更靠近右边缘")
		_check(bar_rect.position.x >= sections.get_global_rect().end.x, "滚动条不会覆盖关卡名字或展开按钮")
		var thumb := bar.get_theme_stylebox("grabber") as StyleBoxFlat
		var track := bar.get_theme_stylebox("scroll") as StyleBoxFlat
		_check(thumb != null and thumb.bg_color.a <= 0.4 and track != null and track.bg_color.a <= 0.1, "纵向条使用低对比滑块及透明轨道")
		await _wheel(_button("level_001").get_global_rect().get_center())
		_check(scroll.scroll_vertical > 0, "展开后真实滚轮仍能滚动关卡")
		_check_horizontal_layout(baseline, "滚轮滚动：" + str(dimensions))
		scroll.scroll_vertical = 0
		await _settle()
		await _click(Vector2(bar_rect.get_center().x, bar_rect.position.y + bar_rect.size.y * 0.94), MOUSE_BUTTON_LEFT)
		_check(scroll.scroll_vertical > 0, "点击原生滚动条轨道能滚动关卡")
		await _capture("player-level-scroll-expanded.png")
		scroll.scroll_vertical = 0
		await _settle()
		await _click(_game._player_toggle.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
		_check(not _game._players_expanded, "玩家收起后真实展开状态已复位")
		_check_horizontal_layout(baseline, "玩家收起：" + str(dimensions))
		_game._level_header.set_search_open(true, false)
		var search := _game.find_child("LevelSearchInput", true, false) as LineEdit
		search.text = "星海"
		search.text_changed.emit(search.text)
		await _settle()
		_check(bar.max_value <= bar.page + 1 and is_equal_approx(grid.size.x, grid_width), "筛选少量结果不挤压或扩大网格")
		# 筛选后玩家卡会换列，各列整数余数分配可相差一个像素；导入卡和总网格必须完全不动。
		_check(is_equal_approx(import_button.get_global_rect().position.x, import_rect.position.x) and is_equal_approx(import_button.size.x, import_rect.size.x) and absf(_card("author_muna").size.x - author_width) <= 1, "搜索结果保留导入卡位置和玩家卡列宽")
		search.text = ""
		search.text_changed.emit("")
		_game._level_header.set_search_open(false, false)
		await _settle()
		_check_horizontal_layout(baseline, "清空搜索：" + str(dimensions))
	for index in 10:
		DirAccess.remove_absolute(_map_path("scroll_extra_%02d" % index))
	_game._refresh_levels()
	await _settle()


## 对当前可见卡片及其图标记录横向几何，避免纵向滚动造成无关比较失败。
func _horizontal_layout() -> Dictionary:
	var result := {}
	for entry in _game._level_entries:
		var card: Control = entry.control
		if card.is_visible_in_tree():
			var button := card.get_child(0) as Control
			result[entry.definition.id] = Vector4(card.get_global_rect().position.x, card.size.x, button.get_global_rect().position.x, button.size.x)
	return result


## 按身份比较同一列中的卡片，要求展开前后宽度及横坐标严格保持不变。
func _check_horizontal_layout(expected: Dictionary, context: String) -> void:
	var current := _horizontal_layout()
	for identity: String in expected:
		_check(current.has(identity) and (current[identity] as Vector4).is_equal_approx(expected[identity]), "卡片横向布局保持不变：" + context + "/" + identity)


## 滚轮完整按下和抬起同帧通过根视口，不留鼠标捕获，也不直接修改滚动值。
func _wheel(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_WHEEL_DOWN
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
	await _settle()


## 用鼠标完整点击检查右键菜单，避免直接发信号掩盖事件穿透或控件命中错误。
func _test_menu() -> void:
	var menu := _game._player_level_context_menu
	await _click(_button("level_001").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(not menu.is_open(), "教学关卡没有删除入口")
	await _click((_game.find_child("ImportLevelButton", true, false) as Control).get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(not menu.is_open(), "导入加号没有删除入口")
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(menu.is_open() and _game.page == GameShell.Page.LEVELS, "右键玩家图标显示菜单且不会进入关卡")
	_check(menu._delete_button.get_theme_color("font_color") == GameTheme.ERROR and menu._delete_button.text == "删除关卡", "删除菜单项继续使用红色文字")
	_check(menu._items.size() == 3 and menu._rename_button.text == "重命名关卡" and menu._open_folder_button.text == "打开关卡所在文件夹", "菜单按重命名、打开文件夹、删除的顺序提供三项")
	_check(menu._rename_button.get_theme_color("font_color") == GameTheme.TEXT and menu._open_folder_button.get_theme_color("font_color") == GameTheme.TEXT, "重命名和打开文件夹使用普通深色文字")
	_check(root.get_visible_rect().encloses(menu._panel.get_global_rect()), "悬浮菜单位于窗口范围内")
	await _capture("player-level-context-menu.png")
	await _test_file_actions()
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _key(KEY_ESCAPE)
	_check(not menu.is_open() and FileAccess.file_exists(_map_path("author_muna")), "Esc取消保留文件")
	var long_caption := _caption("author_long")
	_check(long_caption.mouse_filter == Control.MOUSE_FILTER_PASS and long_caption.tooltip_text == _game.tr("玩家关卡，by %s") % "创作者姓名".repeat(24), "省略署名可接收悬停并提供完整创作者文本")
	await _click(long_caption.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(menu.is_open(), "署名上的右键继续冒泡到玩家卡片")
	await _key(KEY_ESCAPE)
	await _click((_card("author_muna").get_node("LevelCardTitle") as Control).get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(menu.is_open(), "右键标题也可打开删除菜单")
	await _click(_button("level_001").get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(not menu.is_open() and _game.page == GameShell.Page.LEVELS and FileAccess.file_exists(_map_path("author_muna")), "外部完整点击只关闭，不穿透进入背景关卡")
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_game.settings.set_language("en")
	await _settle()
	_check(not menu.is_open(), "语言切换撤销旧删除选择")
	_game.settings.set_language("zh_CN")
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_game._refresh_levels()
	await _settle()
	menu._activate()
	_check(not menu.is_open() and FileAccess.file_exists(_map_path("author_muna")), "刷新后旧菜单不能删除曾选中文件")
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_game._show_main_page()
	await _settle()
	menu._activate()
	_check(not menu.is_open() and FileAccess.file_exists(_map_path("author_muna")), "换页即失效，不在主菜单执行删除")
	_game._show_level_page()
	await _settle()
	_game._level_header.set_search_open(true, false)
	var search := _game.find_child("LevelSearchInput", true, false) as LineEdit
	search.text = "星海"
	search.text_changed.emit(search.text)
	_game._on_level_sort_changed(true)
	await _settle()
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _click(menu._delete_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(not FileAccess.file_exists(_map_path("author_muna")) and _card("author_muna") == null, "点击红色菜单项移除唯一玩家地图并刷新列表")
	_check(_game._level_header.get_query() == "星海" and _game._unfinished_first, "删除后保留搜索及排序")
	_check(_game.drafts.is_completed("author_muna"), "删除地图保留独立完成记录")
	_check(FileAccess.file_exists(_map_path("author_cn")) and FileAccess.file_exists(_game.catalog.levels[0].source_path), "删除没有触及其他玩家地图和教学原件")
	search.text = ""
	search.text_changed.emit("")
	await _settle()
	var changed_path := _map_path("author_cn")
	await _click(_button("author_cn").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	var content := FileAccess.get_file_as_string(changed_path) + "\n"
	var handle := FileAccess.open(changed_path, FileAccess.WRITE)
	handle.store_string(content)
	handle.close()
	await _key(KEY_UP)
	await _key(KEY_ENTER)
	_check(FileAccess.file_exists(changed_path) and _game._message_dialog.visible, "菜单打开后外部改写地图，删除被拒绝并显示错误")
	_game._message_dialog.hide()
	_game._refresh_levels()
	await _settle()
	await _click(_button("author_empty").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _key(KEY_UP)
	await _key(KEY_ENTER)
	_check(not FileAccess.file_exists(_map_path("author_empty")), "键盘Enter可执行已聚焦的删除项")


## 文件夹操作调用可注入系统入口，重命名验证在标题原位编辑，保留文件供删除测试复用。
func _test_file_actions() -> void:
	var menu := _game._player_level_context_menu
	_check(menu._rename_button.has_focus(), "菜单默认聚焦非破坏性的重命名项")
	await _key(KEY_DOWN)
	_check(menu._open_folder_button.has_focus(), "向下导航聚焦打开目录")
	await _key(KEY_TAB)
	_check(menu._delete_button.has_focus(), "Tab 导航到删除项")
	await _key(KEY_DOWN)
	_check(menu._rename_button.has_focus(), "向下导航循环返回首项")
	await _key(KEY_TAB, true)
	_check(menu._delete_button.has_focus(), "Shift Tab 反向循环到最后一项")
	await _key(KEY_UP)
	_check(menu._open_folder_button.has_focus(), "向上导航回到打开目录")
	await _key(KEY_ENTER)
	_check(not menu.is_open() and _opened_folders == [ProjectSettings.globalize_path(_game.user_levels_directory)], "键盘打开文件夹仅请求该关卡的托管目录")
	_check(FileAccess.file_exists(_map_path("author_muna")) and _game.page == GameShell.Page.LEVELS, "打开文件夹保留地图和当前页面")
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _click(menu._open_folder_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(_opened_folders.size() == 2 and not menu.is_open(), "鼠标点击打开文件夹只发起一次调用并关闭菜单")
	_folder_open_result = ERR_CANT_OPEN
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _click(menu._open_folder_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(_game._message_dialog.visible and FileAccess.file_exists(_map_path("author_muna")), "系统打开文件夹失败提供错误反馈且不改地图")
	_game._message_dialog.hide()
	_folder_open_result = OK
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	await _click(menu._rename_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT)
	_check(not menu.is_open() and _rename_requests.size() == 1 and _rename_requests[0].id == "author_muna", "鼠标重命名只发出该玩家关卡的请求")
	_check(is_instance_valid(_game._rename_input) and _game._rename_input.has_focus() and _game._rename_input.get_parent() == _card("author_muna").get_node("LevelCardTitle"), "重命名在原有标题位置直接编辑且不弹窗")
	_game._cancel_player_level_rename()
	await _settle()
	_check(FileAccess.file_exists(_map_path("author_muna")), "取消重命名不删除玩家地图")
	var requests_before := _opened_folders.size()
	await _click(_button("author_muna").get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_game._refresh_levels()
	await _settle()
	menu._activate_open_folder()
	menu._activate_rename()
	_check(_opened_folders.size() == requests_before and _rename_requests.size() == 1, "刷新后旧菜单不能复用之前的文件夹和重命名选择")


## 记录系统调用参数并模拟操作系统失败，不在自动测试中启动真实文件管理器。
func _record_folder_open(path: String) -> int:
	_opened_folders.append(path)
	return _folder_open_result


## 记录菜单传出的真实目录定义，用于确认卡片选择未发生错位。
func _record_rename(definition: LevelDefinition) -> void:
	_rename_requests.append(definition)


## 根据实际加载定义寻找卡片，避免刷新后的目录索引变化影响选中对象。
func _card(identity: String) -> Control:
	for entry in _game._level_entries:
		if entry.definition.id == identity:
			return entry.control
	return null


## 查找当前目录中的正式对象，以便验证菜单关闭后的选择失效边界。
func _definition(identity: String) -> LevelDefinition:
	for definition in _game.catalog.levels:
		if definition.id == identity:
			return definition
	return null


## 卡片首个控件为正式缩略图按钮，测试不通过私有回调模拟右键。
func _button(identity: String) -> Button:
	return _card(identity).get_child(0) as Button


## 署名与教学说明使用稳定节点名，便于逐个验证实际可见文本。
func _caption(identity: String) -> Label:
	return _card(identity).get_node("LevelCardCaption") as Label


## 地图路径只从本次隔离目录拼接，不接触真实玩家目录。
func _map_path(identity: String) -> String:
	return _game.user_levels_directory.path_join(identity + ".json")


## 整次点击同帧送入根视口，避免桌面物理鼠标在合成按下和抬起之间重算悬停。
func _click(position: Vector2, mouse_button: int) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = mouse_button
		event.pressed = down
		event.button_mask = (MOUSE_BUTTON_MASK_LEFT if mouse_button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if down else 0
		root.push_input(event, true)
	await _settle()


## 键盘事件同样完整经过输入分发，不直接触发菜单信号。
func _key(key: Key, shift: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.shift_pressed = shift
		event.pressed = down
		root.push_input(event, true)
	await _settle()


## 可选GPU截图用于检查浮层质感和署名排版，headless不伪造图片。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename)) == OK, "保存实际关卡界面截图")


## 等待嵌套容器重新计算几何和旧卡片释放。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 失败影响退出码，并输出可定位的行为描述。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 清理仅针对当前进程生成的独占测试目录。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
