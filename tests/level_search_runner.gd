extends SceneTree
## 选关搜索回归：以实际页面、可见名称和输入事件覆盖搜索、动画与会话边界。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary: String


## 等待场景树可接受节点后开始，测试内容全部放入独占目录。
func _initialize() -> void:
	_run.call_deferred()


## 顺序验证名称匹配、刷新与导航，再在中英文和最小窗口下检查动画及几何。
func _run() -> void:
	_temporary = "user://tests/level_search_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.size = Vector2i(1280, 800)
	root.add_child(_game)
	await _settle()
	DirAccess.make_dir_recursive_absolute(_game.user_levels_directory)
	_add_import("a_import", "星海练习 / Nebula Lab")
	_add_import("b_import", "循环练习 / Loop Workshop")
	_game.catalog.refresh(_game.registry)
	_game.settings.set_language("zh_CN")
	_game._show_level_page()
	await _settle()
	await _test_matching_and_state()
	await _test_sorting_and_state()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			_game._show_level_page()
			await _settle()
			await _test_header_animation(locale + " " + str(dimensions))
	_game._show_main_page()
	_game.queue_free()
	await _settle()
	_remove_temporary(_temporary)
	print("关卡搜索回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 写入有效自定义关卡，名称独立于文件名、稳定 ID 和说明内容。
func _add_import(identity: String, title: String) -> void:
	var imported := _game.catalog.levels[0].document.duplicate_document()
	imported.id = identity
	imported.display_name = title
	var level_properties: Dictionary = imported.properties.get("level", {})
	level_properties["description"] = "仅说明隐藏词 description_only_marker"
	imported.properties["level"] = level_properties
	_check(MapCodec.save_file(imported, _game.user_levels_directory.path_join(identity + ".json"), _game.registry).is_ok(), "搜索导入夹具保存成功：" + identity)


## 搜索只匹配当前语言的名称，筛选不会改写装配、折叠偏好或任何关卡原件。
func _test_matching_and_state() -> void:
	var header := _game._level_header
	var settings_before := FileAccess.get_file_as_string(_game.settings_path)
	var map_before := JSON.stringify(_game.catalog.levels[0].document.to_dict())
	_check(not _game._header.is_visible_in_tree() and header.is_visible_in_tree(), "选关页隐藏含软件图标的旧页头")
	_check(_visible_ids().size() == 9 and not _game._tutorials_expanded, "默认七张教学和两张导入卡片可见")
	await _activate(_button("LevelSearchButton"), "点击搜索图标")
	await create_timer(0.36).timeout
	var input := _input_field()
	_check(input.is_visible_in_tree() and input.has_focus(), "展开搜索框后自动取得输入焦点")
	await _test_unicode_input()
	_set_query("  循环  ")
	await _settle()
	_expect_ids(["level_006", "b_import"], "去除首尾空白后匹配中文名称并包含第六关")
	_check(not _button("TutorialToggleButton").is_visible_in_tree(), "搜索结果不受展示更多限制，筛选时隐藏展开按钮")
	_check(_button("ImportLevelButton").is_visible_in_tree() and _button("ImportLevelButton").get_parent().get_index() == 0, "搜索时保留独立分类内的导入入口")
	_check(not _empty_state().is_visible_in_tree(), "命中任一分类时不显示全局空结果提示")
	_set_query("左右为")
	await _settle()
	_expect_ids(["level_008"], "名称搜索揭示默认折叠的第八关，不依赖先点展示更多")
	_set_query("description_only_marker")
	await _settle()
	_expect_ids([], "关卡说明不参与名称搜索")
	_check(_empty_state().is_visible_in_tree(), "无结果时给出可见提示")
	_set_query("蜿蜒")
	_expect_ids(["level_009"], "名称搜索可揭示默认折叠的第九关")
	_set_query("巧能躲避")
	_expect_ids(["level_011"], "名称搜索可揭示第十一关并保留真实关卡 ID")
	_set_query("第十关")
	_expect_ids(["level_010"], "第十关已有真实地图并可按名称搜索")
	_set_query("八方来敌")
	_expect_ids(["level_012"], "第十二关按本土化名称搜索，并揭示默认折叠卡片")
	_set_query("level_006")
	await _settle()
	_expect_ids([], "内部关卡 ID 不参与名称搜索")
	_set_query("  nEbUlA  ")
	await _settle()
	_expect_ids(["a_import"], "用户关卡按原始显示名称搜索，英文字母忽略大小写")
	_set_query("   ")
	await _settle()
	_check(_visible_ids().size() == 9 and _button("TutorialToggleButton").is_visible_in_tree(), "只有空白的查询恢复默认折叠列表")
	await _activate(_button("TutorialToggleButton"), "搜索框打开时展开全部教学")
	_check(_game._tutorials_expanded and _visible_ids().size() == 17, "空查询仍可展开第一至第十五关共十五张教学卡片")
	_set_query("星海")
	await _settle()
	_expect_ids(["a_import"], "只匹配导入名称时教学卡片全部隐藏")
	await _activate(_button("LevelSearchCloseButton"), "收回搜索框")
	await create_timer(0.28).timeout
	_check(header.get_query().is_empty() and _game._tutorials_expanded and _visible_ids().size() == 17, "关闭搜索清除筛选并恢复此前全部展开状态")
	await _activate(_button("TutorialToggleButton"), "恢复折叠偏好")
	header.set_search_open(true, false)
	_set_query("阶梯")
	await _settle()
	input.grab_focus()
	_game._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _settle()
	_check(_game._level_header == header and _input_field() == input and input.has_focus(), "聚焦刷新复用搜索组件并保留输入焦点")
	_expect_ids(["level_006"], "聚焦刷新保留查询和筛选结果")
	_add_import("c_import", "阶梯新地图")
	await _activate(_button("LevelMoreButton"), "打开刷新二级菜单")
	await create_timer(0.24).timeout
	await _activate(_button("LevelRefreshMenuItem"), "刷新新增的匹配地图")
	_expect_ids(["level_006", "c_import"], "刷新将新增关卡纳入当前查询")
	_check(_game._level_header == header and header.get_query() == "阶梯", "手动刷新不重建搜索栏或丢失输入")
	await _activate(_card_by_id("level_006"), "从搜索结果进入第六关")
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level.id == "level_006", "搜索结果仍进入正常空装配流程")
	_check(not header.is_visible_in_tree() and not _game._header.is_visible_in_tree() and _game.assembly_panel.header.is_visible_in_tree() and _game.session.assembly.modules.is_empty(), "搜索页头不泄露到装配页且不预装模块")
	_game._dialogue_dialog.hide()
	await _activate(_game._back_button, "从关卡返回搜索结果")
	_check(_game._level_header == header and _input_field().is_visible_in_tree() and header.get_query() == "阶梯", "游玩返回保留同一个展开搜索框与查询")
	_expect_ids(["level_006", "c_import"], "游玩返回仍显示查询结果")
	_set_query("循环阶梯")
	_game.settings.set_language("en")
	await _settle()
	_expect_ids([], "切换英文会重新筛选，中文名称不再匹配英文关卡标题")
	_set_query("lOoP sTaIrCaSe")
	await _settle()
	_expect_ids(["level_006"], "英文当前标题搜索支持大小写混合")
	_game.settings.set_language("zh_CN")
	await _settle()
	_expect_ids([], "切回中文即时按中文标题重新筛选")
	_set_query("射击与躲避")
	await _settle()
	_expect_ids(["level_007"], "第七关搜索使用修改后的中文本土化名称")
	_set_query("边退边射")
	await _settle()
	_expect_ids([], "旧关卡名称和现有说明中的词语不参与匹配")
	header.set_search_open(false, false)
	await _settle()
	_check(_visible_ids().size() == 10 and not _game._tutorials_expanded, "清除查询后恢复七张教学与三张导入")
	_check(FileAccess.get_file_as_string(_game.settings_path) == settings_before, "查询与展开动画不写入设置，语言恢复后的设置内容不变")
	_check(JSON.stringify(_game.catalog.levels[0].document.to_dict()) == map_before, "搜索与刷新未修改内置地图内容")


## 为独占存档标记少量通关，验证未通关优先独立排序两栏并兼容折叠、搜索及返回。
func _test_sorting_and_state() -> void:
	var completed_ids: Array[String] = ["level_001", "level_003", "a_import"]
	var original_catalog: Array[String] = []
	for definition: LevelDefinition in _game.catalog.levels:
		original_catalog.append(definition.id)
	var settings_before := FileAccess.get_file_as_string(_game.settings_path)
	for identity in completed_ids:
		_check(not _game.drafts.is_completed(identity) and _game.drafts.mark_completed(identity).is_ok(), "隔离夹具写入通关状态：" + identity)
	_game._show_level_page()
	await _settle()
	await _activate(_button("LevelMoreButton"), "打开排序菜单")
	await create_timer(0.24).timeout
	await _activate(_button("LevelSortMenuItem"), "展开排列方式子菜单")
	await create_timer(0.24).timeout
	var original_order := _button("LevelSortDefaultMenuItem")
	var unfinished := _button("LevelSortUncompletedMenuItem")
	_check(not _game._unfinished_first and original_order.button_pressed and not unfinished.button_pressed, "首次排序子菜单只勾选默认顺序")
	await _activate(unfinished, "选择未通关优先")
	_check(_game._unfinished_first and unfinished.button_pressed and not original_order.button_pressed and not _game._level_header._actions_menu.is_open(), "选择排序后单选勾选更新且菜单自动收起")
	var tutorial_order: Array[String] = ["level_002", "level_004", "level_005", "level_006", "level_007", "level_008", "level_009", "level_010", "level_011", "level_012", "level_013", "level_014", "level_015", "level_001", "level_003"]
	_check(_grid_level_ids("LevelGrid") == tutorial_order, "教学按未通关与已通关稳定分区，组内维持原顺序")
	_check(_grid_level_ids("LevelGrid", true) == tutorial_order.slice(0, 7), "默认七张按排序后次序选取，包含默认折叠的第八关")
	_check(_grid_level_ids("ImportedLevelGrid") == ["b_import", "c_import", "a_import"] and _button("ImportLevelButton").get_parent().get_index() == 0, "导入分类独立排序且加号仍占第一格")
	_game._level_header.set_search_open(true, false)
	_set_query("第")
	await _settle()
	_check(_grid_level_ids("LevelGrid", true) == tutorial_order, "搜索揭示全部匹配教学关卡并沿用未通关排序")
	await _activate(_button("LevelMoreButton"), "排序搜索中打开刷新菜单")
	await create_timer(0.24).timeout
	await _activate(_button("LevelRefreshMenuItem"), "排序搜索中刷新目录")
	_check(_game._unfinished_first and _game._level_header.get_query() == "第" and _grid_level_ids("LevelGrid", true) == tutorial_order, "刷新保留排序选择、查询和结果顺序")
	await _activate(_card_by_id("level_006"), "从排序结果进入第六关")
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level.id == "level_006", "排序后的卡片仍进入其对应关卡")
	_game._dialogue_dialog.hide()
	await _activate(_game._back_button, "从关卡返回排序结果")
	_check(_game._unfinished_first and _game._level_header.get_query() == "第" and _grid_level_ids("LevelGrid", true) == tutorial_order, "游玩返回保留排序及搜索状态")
	_game._level_header.set_search_open(false, false)
	await _settle()
	await _activate(_button("LevelMoreButton"), "再次打开排序菜单")
	await create_timer(0.24).timeout
	await _activate(_button("LevelSortMenuItem"), "重新查看排列方式")
	await create_timer(0.24).timeout
	_check(_button("LevelSortUncompletedMenuItem").button_pressed and not _button("LevelSortDefaultMenuItem").button_pressed, "重新打开子菜单显示当前未通关优先勾选")
	await _activate(_button("LevelSortDefaultMenuItem"), "选择默认顺序")
	_check(not _game._unfinished_first and _grid_level_ids("LevelGrid", true) == ["level_001", "level_002", "level_003", "level_004", "level_005", "level_006", "level_007"], "取消排序恢复教学原顺序及默认前七张")
	_check(_grid_level_ids("ImportedLevelGrid") == ["a_import", "b_import", "c_import"], "取消排序同时恢复导入分类原顺序")
	var final_catalog: Array[String] = []
	for definition: LevelDefinition in _game.catalog.levels:
		final_catalog.append(definition.id)
	_check(final_catalog == original_catalog and FileAccess.get_file_as_string(_game.settings_path) == settings_before, "界面排序不改目录顺序或持久设置文件")
	# 仅删除此函数在当前独占目录里创建的三份进度，让后续布局检查保持初始状态。
	for identity in completed_ids:
		DirAccess.remove_absolute(_game.drafts._path(identity, "progress"))
	_game._show_level_page()
	await _settle()


## 按网格的真实子节点顺序读取关卡，略过导入入口与占位控件。
func _grid_level_ids(grid_name: String, visible_only: bool = false) -> Array[String]:
	var result: Array[String] = []
	var grid := _game.find_child(grid_name, true, false) as GridContainer
	for column in grid.get_children():
		for child in column.get_children():
			if child is Button and str(child.name).begins_with("LevelButton_"):
				if visible_only and not child.is_visible_in_tree():
					continue
				var index := str(child.name).trim_prefix("LevelButton_").to_int()
				result.append(_game.catalog.levels[index].id)
	return result


## 中文提交经真实视口键盘事件进入 LineEdit，再用退格逐字删除，验证原生输入会触发筛选。
func _test_unicode_input() -> void:
	var input := _input_field()
	input.grab_focus()
	for character in "循环":
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.unicode = character.unicode_at(0)
			event.pressed = pressed
			root.push_input(event)
	await _settle()
	_check(input.text == "循环" and _game._level_header.get_query() == "循环", "Unicode 键盘事件真实提交中文搜索文本")
	_expect_ids(["level_006", "b_import"], "中文键盘输入自动触发名称筛选，无需手动发射文本信号")
	for expected: String in ["循", ""]:
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = KEY_BACKSPACE
			event.physical_keycode = KEY_BACKSPACE
			event.pressed = pressed
			root.push_input(event)
		await _settle()
		_check(input.text == expected, "原生退格逐个删除中文字符：" + expected)
	_check(_game._level_header.get_query().is_empty() and _visible_ids().size() == 9, "退格清空输入后自动恢复默认关卡列表")


## 检查两种语言和窗口下非线性伸缩始终固定右侧，并验证中途反向和 Esc。
func _test_header_animation(context: String) -> void:
	var header := _game._level_header
	header.set_search_open(false, false)
	await _settle()
	var area := _game.find_child("LevelSearchArea", true, false) as Control
	var collapsed := area.get_global_rect()
	_assert_header_geometry(false, context)
	await _assert_menu_geometry(context + " 收起搜索")
	_check(_button("LevelForwardButton").disabled, "没有前进目标时前进图标禁用 " + context)
	header.set_search_open(true, false)
	await _settle()
	var expanded := area.get_global_rect()
	_assert_header_geometry(true, context)
	await _assert_menu_geometry(context + " 展开搜索")
	_check(expanded.size.x > collapsed.size.x + 120.0 and absf(expanded.end.x - collapsed.end.x) < 1.0, "搜索向左展开，固定右边缘 " + context)
	header.set_search_open(false, false)
	await _settle()
	header.set_search_open(true)
	await create_timer(0.10).timeout
	var intermediate := area.get_global_rect()
	var fraction := (intermediate.size.x - collapsed.size.x) / maxf(1.0, expanded.size.x - collapsed.size.x)
	_check(fraction > 0.40 and fraction < 0.98, "展开存在先快后慢的中间状态 " + context)
	_check(absf(intermediate.end.x - collapsed.end.x) < 1.0, "动画中右边缘保持固定 " + context)
	header.set_search_open(false)
	await create_timer(0.05).timeout
	header.set_search_open(true)
	await create_timer(0.37).timeout
	_check(absf(area.size.x - expanded.size.x) < 1.0 and _input_field().is_visible_in_tree(), "快速开关反向后到达正确展开终态 " + context)
	_assert_header_geometry(true, context)
	_set_query("unlikely_no_match_8821")
	_input_field().grab_focus()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape)
	escape.pressed = false
	root.push_input(escape)
	await create_timer(0.29).timeout
	await _settle()
	_check(header.get_query().is_empty() and not _input_field().is_visible_in_tree(), "输入框内 Esc 清除查询并收回搜索 " + context)
	_check(absf(area.size.x - collapsed.size.x) < 1.0 and _button("LevelSearchButton").is_visible_in_tree(), "收回后恢复圆形搜索入口尺寸 " + context)
	_check(_visible_ids().size() == 10 and not _empty_state().is_visible_in_tree(), "取消搜索后清除无结果状态 " + context)
	_assert_header_geometry(false, context)


## 检查导航、标题、搜索和更多图标保持同一行，展开输入框没有遮住其他入口。
func _assert_header_geometry(open: bool, context: String) -> void:
	var names := ["LevelBackButton", "LevelForwardButton", "LevelBrowserTitle", "LevelMoreButton"]
	names.append_array(["LevelSearchCloseButton", "LevelSearchInput"] if open else ["LevelSearchButton"])
	var controls: Array[Control] = []
	for node_name: String in names:
		var control := _game.find_child(node_name, true, false) as Control
		_check(control != null and control.is_visible_in_tree(), "页头控件可见：" + node_name + " " + context)
		if control == null:
			continue
		controls.append(control)
		var rect := control.get_global_rect()
		_check(rect.size.x > 0 and rect.size.y > 0 and root.get_visible_rect().grow(1).encloses(rect), "页头控件完整位于窗口：" + node_name + " " + context)
	for index in range(controls.size()):
		for other in range(index + 1, controls.size()):
			_check(not controls[index].get_global_rect().grow(-0.5).intersects(controls[other].get_global_rect().grow(-0.5)), "页头控件互不重叠：%s / %s %s" % [controls[index].name, controls[other].name, context])
	var back := _button("LevelBackButton").get_global_rect()
	var more := _button("LevelMoreButton").get_global_rect()
	_check(absf(back.get_center().y - more.get_center().y) < 1.0, "导航与更多图标垂直居中对齐 " + context)
	_check(more.size.is_equal_approx(Vector2(44, 44)), "更多按钮保留与搜索一致的圆形命中区 " + context)


## 两种搜索状态下弹层均锚定更多按钮下方，中英文项目完整可见且不挤占页头布局。
func _assert_menu_geometry(context: String) -> void:
	var header := _game._level_header
	var more := _button("LevelMoreButton")
	var before := more.get_global_rect()
	await _activate(more, "打开菜单检查几何 " + context)
	await create_timer(0.24).timeout
	var panel := _game.find_child("LevelActionsPanel", true, false) as Control
	_check(header._actions_menu.is_open() and panel != null and panel.is_visible_in_tree(), "二级菜单完整展开 " + context)
	if panel != null:
		var bounds := panel.get_global_rect()
		_check(root.get_visible_rect().encloses(bounds), "二级菜单位于窗口范围 " + context)
		_check(absf(bounds.end.x - before.end.x) < 1.0 and absf(bounds.position.y - before.end.y - 8.0) < 1.0, "二级菜单右对齐更多按钮并向下间隔 8 像素 " + context)
		_check(not bounds.intersects(before) and more.get_global_rect().is_equal_approx(before), "二级菜单悬浮显示，不遮挡或推移更多入口 " + context)
		var refresh := _button("LevelRefreshMenuItem")
		var imported := _button("LevelImportMenuItem")
		var sort := _button("LevelSortMenuItem")
		for item in [refresh, imported, sort]:
			_check(item != null and item.is_visible_in_tree() and bounds.encloses(item.get_global_rect()) and item.icon != null, "菜单文字与 SVG 图标处于面板内 " + context)
		_check(not refresh.get_global_rect().intersects(imported.get_global_rect()) and not imported.get_global_rect().intersects(sort.get_global_rect()), "三行菜单操作互不重叠 " + context)
		var english := TranslationServer.get_locale().begins_with("en")
		_check(TranslationServer.translate(refresh.text) == ("Refresh" if english else "刷新"), "刷新菜单项目随当前语言翻译 " + context)
		_check(TranslationServer.translate(imported.text) == ("Import Level" if english else "导入关卡"), "导入菜单项目随当前语言翻译 " + context)
		_check(TranslationServer.translate(sort.text) == ("Sort Order" if english else "排列方式"), "排序菜单项目随当前语言翻译 " + context)
	await _activate(_button("LevelSortMenuItem"), "展开排列方式检查边界 " + context)
	await create_timer(0.24).timeout
	var submenu := _game.find_child("LevelSortPanel", true, false) as Control
	_check(submenu != null and submenu.is_visible_in_tree() and root.get_visible_rect().encloses(submenu.get_global_rect()), "排列方式子菜单完整位于窗口 " + context)
	if submenu != null and panel != null:
		_check(not submenu.get_global_rect().intersects(panel.get_global_rect()), "排列方式子菜单不遮住主菜单选项 " + context)
		for item_name in ["LevelSortDefaultMenuItem", "LevelSortUncompletedMenuItem"]:
			var item := _button(item_name)
			_check(item != null and item.is_visible_in_tree() and submenu.get_global_rect().encloses(item.get_global_rect()), "排序单选项目完整可见 " + context)
	for close_submenu in [true, false]:
		for pressed in [true, false]:
			var escape := InputEventKey.new()
			escape.keycode = KEY_ESCAPE
			escape.physical_keycode = KEY_ESCAPE
			escape.pressed = pressed
			root.push_input(escape)
		await _settle()
		if close_submenu:
			_check(header._actions_menu.is_open() and not submenu.is_visible_in_tree(), "子菜单 Esc 只退回主菜单 " + context)
		else:
			_check(not header._actions_menu.is_open(), "再次 Esc 正常关闭全部菜单 " + context)


## 文本更新走 LineEdit 的实际输入信号，不直接调用筛选实现。
func _set_query(query: String) -> void:
	var input := _input_field()
	input.text = query
	input.text_changed.emit(query)


## 经视口处理键盘操作，隐藏或禁用按钮不能被测试当作有效入口。
func _activate(button: Button, message: String) -> void:
	var usable := button != null and button.is_visible_in_tree() and not button.disabled
	_check(usable, message + "：入口可见且可操作")
	if not usable:
		return
	button.grab_focus()
	await process_frame
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = &"ui_accept"
		event.pressed = pressed
		root.push_input(event)
	await _settle()


## 从当前目录和卡片可见性读取结果，避免把占位或加号算作关卡。
func _visible_ids() -> Array[String]:
	var ids: Array[String] = []
	for index in range(_game.catalog.levels.size()):
		var button := _button("LevelButton_%d" % index)
		if button != null and button.is_visible_in_tree():
			ids.append(_game.catalog.levels[index].id)
	return ids


## 按稳定关卡 ID 寻找实际卡片，避免导入排序变化导致测试点错关卡。
func _card_by_id(identity: String) -> Button:
	for index in range(_game.catalog.levels.size()):
		if _game.catalog.levels[index].id == identity:
			return _button("LevelButton_%d" % index)
	return null


## 比较玩家可见的结果集合，消息包含真实结果以便定位错误分类或翻译。
func _expect_ids(expected: Array, message: String) -> void:
	var actual := _visible_ids()
	actual.sort()
	expected.sort()
	_check(actual == expected, "%s：实际 %s，期望 %s" % [message, actual, expected])


## 根据稳定节点名读取按钮，页面刷新后始终返回当前节点。
func _button(node_name: String) -> Button:
	return _game.find_child(node_name, true, false) as Button


## 搜索框是常驻组件，查询辅助保持只依赖公共节点名。
func _input_field() -> LineEdit:
	return _game.find_child("LevelSearchInput", true, false) as LineEdit


## 无结果提示统一位于搜索列表，便于同时覆盖教学与导入分类。
func _empty_state() -> Control:
	return _game.find_child("SearchEmptyState", true, false) as Control


## 等待布局协商和延迟释放完成，避免读取上一页的卡片矩形。
func _settle() -> void:
	await process_frame
	await process_frame


## 汇总断言并使失败明确影响进程退出码。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只递归删除当前测试创建的独占目录，绝不扫描玩家实际关卡或存档。
func _remove_temporary(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_temporary(path.path_join(child))
	DirAccess.remove_absolute(path)
