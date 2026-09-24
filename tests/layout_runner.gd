extends SceneTree
## 新外观的布局回归：在两种窗口尺寸和语言下检查关键控件仍可见、可操作。

var _checks := 0
var _failures := 0


## 延迟到场景树可添加节点后执行，不触碰正式关卡目录或玩家设置。
func _initialize() -> void:
	_run.call_deferred()


## 用实际页面验证中英切换和最小窗口，滚动画布只检查其可见视口边界。
func _run() -> void:
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	var temporary := "user://tests/layout_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	game.user_levels_directory = temporary.path_join("levels")
	game.drafts_directory = temporary.path_join("solutions")
	game.settings_path = temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	# 一张真实导入地图覆盖不足七列时的占位与列宽，夹具仅写本次测试目录。
	DirAccess.make_dir_recursive_absolute(game.user_levels_directory)
	var imported := game.catalog.levels[0].document.duplicate_document()
	imported.id = "layout_imported_level"
	imported.display_name = "导入布局测试 / Imported Layout Check"
	_expect(MapCodec.save_file(imported, game.user_levels_directory.path_join("layout.json"), game.registry).is_ok(), "创建独占导入布局夹具")
	game.catalog.refresh(game.registry)
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			game.settings.set_language(locale)
			game._show_main_page()
			await _settle()
			for node_name in ["StartGameButton", "MapEditorButton", "SettingsButton", "LeaveGameButton"]:
				_inside(game.find_child(node_name, true, false), "主菜单 " + locale)
			await _level_categories_inside(game, locale + " " + str(dimensions))
			var navigation_message := locale + " " + str(dimensions)
			var browser_back := game.find_child("LevelBackButton", true, false) as Button
			var browser_navigation := game.find_child("LevelNavigation", true, false) as Control
			var expected_back := browser_back.get_global_rect()
			var expected_navigation := browser_navigation.get_global_rect()
			game._show_settings_page()
			await _settle()
			await _settings_layout_matches(game, expected_back, expected_navigation, navigation_message)
			game._back_button.pressed.emit()
			await _settle()
			_expect(game.page == GameShell.Page.MAIN, "设置药丸返回开始页面 " + navigation_message)
			game._enter_level(game.catalog.levels[0])
			game._dialogue_dialog.hide()
			await _settle()
			_level_navigation_matches(game, expected_back, expected_navigation, "第一关组装 " + navigation_message)
			await _command_reference_layout(game, navigation_message)
			_inside(game.assembly_panel.canvas, "装配画布 " + locale)
			_inside(game.assembly_panel._apply_button, "装配应用按钮 " + locale)
			_inside(game.assembly_panel._remove_button, "装配移除按钮 " + locale)
			_inside(game._confirm_assembly_button, "装配确认按钮 " + locale)
			game.session.assembly.add_module("movement", Vector2.ZERO)
			game._confirm_assembly()
			await _settle()
			_level_navigation_matches(game, expected_back, expected_navigation, "第一关编程 " + navigation_message)
			await _program_toolbar_layout(game, navigation_message)
			_expect(not game.workbench._assembly_panel.preparation_mode and game.workbench._assembly_panel.header == null, "工作台装配页签保持原布局 " + navigation_message)
			_inside(game.workbench._code, "代码编辑区 " + locale)
			_inside(game.workbench._run_button, "运行按钮 " + locale)
			_inside(game.workbench._world_scroll, "地图观察区 " + locale)
			await _return_to_level_navigation(game, expected_back, expected_navigation, "第一关返回 " + navigation_message)
			for index in [1, 2, 3, 4, 5, 6, 7, 8]:
				game._enter_level(game.catalog.levels[index])
				game._dialogue_dialog.hide()
				await _settle()
				_level_navigation_matches(game, expected_back, expected_navigation, "第 %d 关组装 " % (index + 1) + navigation_message)
				if index == 3:
					game.session.assembly.add_module("shooting", Vector2.ZERO)
				elif index == 4:
					game.session.assembly.add_module("movement", Vector2.ZERO, "drive")
					game.session.assembly.add_module("melee", Vector2(-0.5, 0), "left")
					game.session.assembly.add_module("melee", Vector2(0.5, 0), "right")
				elif index == 8:
					game.session.assembly.add_module("rangefinder", Vector2.ZERO, "sensor")
					game.session.assembly.add_module("movement", Vector2(0, 0.5), "drive")
				elif index == 7:
					game.session.assembly.add_module("melee", Vector2.ZERO, "left")
					game.session.assembly.add_module("movement", Vector2(0.5, 0), "drive")
					game.session.assembly.add_module("melee", Vector2(1, 0), "right")
				elif index == 6:
					game.session.assembly.add_module("movement", Vector2.ZERO, "drive")
					game.session.assembly.add_module("shooting", Vector2(0.5, 0), "gun")
				elif index == 5:
					game.session.assembly.add_module("movement", Vector2.ZERO, "drive")
				else:
					game.session.assembly.add_module("movement", Vector2.ZERO)
					game.session.assembly.add_module("melee" if index == 2 else "movement", Vector2(0.5, 0))
				game._confirm_assembly()
				await _settle()
				_level_navigation_matches(game, expected_back, expected_navigation, "第 %d 关编程 " % (index + 1) + navigation_message)
				_inside(game.workbench._code, "新关卡代码区 " + locale)
				await _workbench_guide_layout(game.workbench, "第 %d 关 " % (index + 1) + navigation_message)
				_inside(game.workbench._run_button, "新关卡运行按钮 " + locale)
				_inside(game.workbench._world_scroll, "新关卡地图视口 " + locale)
				if index == 5:
					await _staircase_inside_viewport(game.workbench, "第六关完整阶梯 " + locale + " " + str(dimensions))
				await _return_to_level_navigation(game, expected_back, expected_navigation, "第 %d 关返回 " % (index + 1) + navigation_message)
			game._open_editor()
			await _settle()
			_inside(game._editor._canvas.get_parent(), "地图编辑器视口 " + locale)
			_inside(game._back_button, "返回按钮 " + locale)
			await _editor_playtest_navigation(game, expected_back, expected_navigation, navigation_message)
	game._show_main_page()
	game.queue_free()
	await _settle()
	_remove_temporary(temporary)
	print("布局回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 设置与选关复用相同导航位置，两个分组采用左标签、右控件且不会随翻译溢出。
func _settings_layout_matches(game: GameShell, expected_back: Rect2, expected_navigation: Rect2, message: String) -> void:
	_level_navigation_matches(game, expected_back, expected_navigation, "设置 " + message)
	_expect(not game._text_back_button.is_visible_in_tree() and not game._subtitle.is_visible_in_tree() and not game._save_label.is_visible_in_tree(), "设置隐藏重复文字导航、副标题和页脚 " + message)
	var card := game.find_child("SettingsCard", true, false) as Control
	var volume_row := game.find_child("VolumeRow", true, false) as Control
	var language_row := game.find_child("LanguageRow", true, false) as Control
	var ready := card != null and volume_row != null and language_row != null
	_expect(ready, "设置布局及音量、语言行存在 " + message)
	if not ready:
		return
	_inside(card, "设置布局区域 " + message)
	var volume_rect := volume_row.get_global_rect()
	var language_rect := language_row.get_global_rect()
	_expect(absf(volume_rect.position.x - language_rect.position.x) < 1.0 and absf(volume_rect.size.x - language_rect.size.x) < 1.0, "音效和显示的设置行等宽并左对齐 " + message)
	_expect(volume_rect.end.y < language_rect.position.y, "音量与语言分组纵向分开 " + message)
	for pair in [[volume_row, game.settings_panel._volume_slider, "SoundSectionTitle"], [language_row, game.settings_panel._language_option, "DisplaySectionTitle"]]:
		var row: Control = pair[0]
		var control: Control = pair[1]
		var section := game.find_child(pair[2], true, false) as Label
		var labels := row.find_children("*", "Label", true, false)
		var label := labels[0] as Label if not labels.is_empty() else null
		_expect(label != null and section != null, "设置分组与行标签均可辨识 " + message)
		if label == null or section == null:
			continue
		_expect(row.get_global_rect().encloses(label.get_global_rect()) and row.get_global_rect().encloses(control.get_global_rect()), "设置标签和控件完整位于对应行内 " + message)
		_expect(label.get_global_rect().end.x < control.get_global_rect().position.x and absf(label.get_global_rect().get_center().y - control.get_global_rect().get_center().y) < 1.0, "设置行标签在左、操作控件在右且垂直居中 " + message)
		_expect(section.get_global_rect().end.y <= row.get_global_rect().position.y, "分组标题位于对应设置行上方 " + message)
	_expect(not game.settings_panel._status.is_visible_in_tree(), "正常设置不占用错误提示空间 " + message)
	var clear := game.find_child("ClearProgressButton", true, false) as Button
	var more := game.find_child("DisplaySectionTitle", true, false) as Label
	_expect(clear != null and clear.is_visible_in_tree() and TranslationServer.translate(more.text) == game.tr("更多"), "更多分组提供可见清除入口 " + message)
	if clear == null:
		return
	_expect(clear.get_global_rect().position.y >= language_rect.end.y, "清除入口位于语言行下方，纵向溢出交由滚动验证 " + message)
	_expect(clear.get_parent() == language_row.get_parent() and absf(clear.get_global_rect().position.x - language_rect.position.x) < 1.0 and absf(clear.size.x - language_rect.size.x) < 1.0, "语言与清除属于同一组且上下两行等宽对齐 " + message)
	var clear_user := game.find_child("ClearUserLevelsButton", true, false) as Button
	_expect(TranslationServer.translate(clear.text) == game.tr("清除预设进度") and clear_user != null and TranslationServer.translate(clear_user.text) == game.tr("清除用户关卡"), "两种清除操作名称及当前语言完整区分 " + message)
	if clear_user != null:
		_expect(clear_user.get_parent() == language_row.get_parent(), "用户清除保留在更多分组的相同行容器内 " + message)
		_expect(clear_user.get_global_rect().position.y >= clear.get_global_rect().end.y and absf(clear_user.get_global_rect().position.x - language_rect.position.x) < 1.0 and absf(clear_user.size.x - language_rect.size.x) < 1.0, "用户清除在预设清除下方且三行等宽对齐 " + message)
	await _settings_free_zoom_layout(game, message)
	await _clear_modal_layout(game, clear, ClearProgressDialog.WARNING_BODY, "预设 " + message)
	if clear_user != null:
		await _clear_modal_layout(game, clear_user, ClearProgressDialog.USER_LEVELS_WARNING_BODY, "用户 " + message)


## 新缩放开关位于 Tab 下方，滚动后通过真实点击验证中英文标签和输入均可用。
func _settings_free_zoom_layout(game: GameShell, message: String) -> void:
	var tab_row := game.find_child("TabCompletionRow", true, false) as Control
	var zoom_row := game.find_child("AssemblyFreeZoomRow", true, false) as Control
	var label := game.find_child("AssemblyFreeZoomLabel", true, false) as Label
	var tab_toggle := game.settings_panel._tab_completion_toggle
	var zoom_toggle := game.settings_panel._assembly_free_zoom_toggle
	_expect(tab_row != null and zoom_row != null and label != null and zoom_toggle != null, "自由缩放设置行和标签存在 " + message)
	if tab_row == null or zoom_row == null or label == null or zoom_toggle == null:
		return
	_expect(zoom_row.get_parent() == tab_row.get_parent() and zoom_row.get_global_rect().position.y >= tab_row.get_global_rect().end.y, "自由缩放位于 Tab 补全下方且属于同一显示分组 " + message)
	_expect(absf(zoom_toggle.get_global_rect().position.x - tab_toggle.get_global_rect().position.x) < 1.0 and zoom_toggle.size.is_equal_approx(tab_toggle.size), "自由缩放与 Tab 的开关等大且右侧对齐 " + message)
	await _settings_scroll_into_view(game.settings_panel._scroll, zoom_row, "自由缩放 " + message)
	_inside(zoom_row, "滚动后的自由缩放行 " + message)
	_expect(zoom_row.get_global_rect().encloses(label.get_global_rect()) and zoom_row.get_global_rect().encloses(zoom_toggle.get_global_rect()) and label.get_global_rect().end.x < zoom_toggle.get_global_rect().position.x, "翻译标签与开关完整留在行内且不重叠 " + message)
	var previous := game.settings.assembly_free_zoom
	_click_at(zoom_toggle.get_global_rect().get_center())
	await _settle()
	_expect(game.settings.assembly_free_zoom != previous and zoom_toggle.button_pressed == game.settings.assembly_free_zoom, "滚动后的自由缩放开关可通过鼠标点击切换 " + message)
	_click_at(zoom_toggle.get_global_rect().get_center())
	await _settle()
	_expect(game.settings.assembly_free_zoom == previous and zoom_toggle.button_pressed == previous, "再次点击恢复原设置以保持后续检查隔离 " + message)


## 通过实际滚轮把目标完整滚入裁剪视口；到达滚动极限仍不可见时保留失败。
func _settings_scroll_into_view(scroll: ScrollContainer, target: Control, message: String) -> void:
	for attempt in 32:
		var viewport := scroll.get_global_rect()
		var target_rect := target.get_global_rect()
		if viewport.encloses(target_rect):
			break
		var previous := scroll.scroll_vertical
		var direction := MOUSE_BUTTON_WHEEL_DOWN if target_rect.end.y > viewport.end.y else MOUSE_BUTTON_WHEEL_UP
		_click_at(viewport.position + Vector2(8.0, viewport.size.y * 0.5), direction)
		await _settle()
		if scroll.scroll_vertical == previous:
			break
	_expect(scroll.get_global_rect().encloses(target.get_global_rect()), "实际滚轮可以把设置控件完整移入裁剪视口：" + message)


## 使用视口内坐标分发真实点击，避免窗口缩放后二次变换造成假命中或遗漏。
func _click_at(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		if pressed and button <= MOUSE_BUTTON_MIDDLE:
			event.button_mask = 1 << (button - 1)
		root.push_input(event, true)


## 两类确认正文独立检查换行边界，取消只关闭弹层，不在布局测试里执行删除。
func _clear_modal_layout(game: GameShell, action: Button, body: String, message: String) -> void:
	await _settings_scroll_into_view(game.settings_panel._scroll, action, message)
	_inside(action, "滚动后的清除入口 " + message)
	_expect(game.settings_panel._scroll.get_global_rect().grow(1).encloses(action.get_global_rect()), "清除入口滚动后完整位于设置视口内 " + message)
	_click_at(action.get_global_rect().get_center())
	await _settle()
	await create_timer(0.22).timeout
	var dialog := game._clear_progress_dialog
	var panel := game.find_child("ClearProgressPanel", true, false) as Control
	var title := game.find_child("ClearProgressTitle", true, false) as Label
	var warning := game.find_child("ClearProgressBody", true, false) as Label
	var confirm := game.find_child("ConfirmClearProgressButton", true, false) as Button
	var cancel := game.find_child("CancelClearProgressButton", true, false) as Button
	_expect(dialog.is_open() and panel != null and title != null and warning != null and confirm != null and cancel != null, "清除确认弹窗具备标题、完整警告和双按钮 " + message)
	if panel == null or title == null or warning == null or confirm == null or cancel == null:
		dialog.close_dialog()
		return
	_inside(panel, "清除确认弹窗 " + message)
	for control in [title, warning, confirm, cancel]:
		_expect(control.is_visible_in_tree() and panel.get_global_rect().encloses(control.get_global_rect()), "确认弹窗内容完整位于圆角面板内 " + message)
	_expect(TranslationServer.translate(warning.text) == game.tr(body), "中英文确认使用对应清除范围的专属警告 " + message)
	_expect(warning.size.y + 1 >= warning.get_minimum_size().y and warning.get_global_rect().end.y <= minf(confirm.get_global_rect().position.y, cancel.get_global_rect().position.y), "换行警告没有裁切且不与操作按钮重叠 " + message)
	_expect(not confirm.get_global_rect().intersects(cancel.get_global_rect()) and cancel.has_focus(), "确认与取消分开排列，默认焦点落在取消 " + message)
	_click_at(cancel.get_global_rect().get_center())
	await _settle()
	_expect(not dialog.is_open() and game.page == GameShell.Page.SETTINGS, "布局检查取消后回到设置并保留页面 " + message)



## 同时比较按钮与胶囊的全局矩形，防止不同页头仅尺寸一致但切换时发生位移。
func _level_navigation_matches(game: GameShell, expected_back: Rect2, expected_navigation: Rect2, message: String) -> void:
	if game.page == GameShell.Page.ASSEMBLY:
		_preparation_toolbar_layout(game, expected_back, expected_navigation, message)
		return
	if game.page == GameShell.Page.PLAY:
		var header := game.workbench.header
		_expect(header.is_visible_in_tree() and not game._header.is_visible_in_tree() and not game._subtitle.is_visible_in_tree() and not game._save_label.is_visible_in_tree(), "编程使用独立顶部栏并隐藏底部常规保存提示 " + message)
		_expect(game._back_button == header.back_button and header.back_button.get_global_rect().is_equal_approx(expected_back) and header.navigation.get_global_rect().is_equal_approx(expected_navigation), "编程返回药丸与选关导航位置和尺寸一致 " + message)
		_expect(header.back_button.icon != null and header.back_button.text.is_empty() and header.back_button.get_tooltip() == game.tr("返回地图编辑器" if game._editor_playtest else "返回关卡"), "编程返回图标采用当前语言的目标提示 " + message)
		_inside(header.navigation, "编程返回药丸 " + message)
		return
	var navigation := game.find_child("GameNavigation", true, false) as Control
	var back := game.find_child("GameBackButton", true, false) as Button
	var forward := game.find_child("GameForwardButton", true, false) as Button
	var app_icon := game.find_child("HeaderAppIcon", true, false) as Control
	var ready := navigation != null and back != null and forward != null and app_icon != null
	_expect(ready, "关卡页共用胶囊导航节点完整 " + message)
	if not ready:
		return
	_expect(navigation.is_visible_in_tree() and back.is_visible_in_tree() and forward.is_visible_in_tree(), "关卡药丸与两个箭头真实显示 " + message)
	_expect(game._back_button == back and not back.disabled and back.text.is_empty() and back.icon != null, "当前返回引用指向纯箭头按钮 " + message)
	_expect(forward.disabled and forward.text.is_empty() and forward.icon != null, "没有前进历史时禁用右箭头 " + message)
	_expect(not app_icon.is_visible_in_tree(), "关卡页隐藏软件图标 " + message)
	var expected_tooltip := game.tr("返回开始页面" if game.page == GameShell.Page.SETTINGS else "返回地图编辑器" if game._editor_playtest else "返回关卡")
	_expect(TranslationServer.translate(back.get_tooltip()) == expected_tooltip, "纯图标返回按钮保留当前语言的目标说明 " + message)
	_expect(navigation.size.is_equal_approx(Vector2(88, 44)), "关卡药丸保持选关页的 88 × 44 大小 " + message)
	_expect(navigation.get_global_rect().is_equal_approx(expected_navigation), "胶囊与选关页位置及大小完全一致：%s / %s " % [navigation.get_global_rect(), expected_navigation] + message)
	_expect(back.get_global_rect().is_equal_approx(expected_back), "左箭头与选关页位置及大小完全一致：%s / %s " % [back.get_global_rect(), expected_back] + message)
	_inside(navigation, "关卡药丸位于窗口内 " + message)


## 关卡标题与简短目标上下排列，右侧工具和二级菜单在两种语言及窗口下仍完整显示。
func _program_toolbar_layout(game: GameShell, message: String) -> void:
	var workbench := game.workbench
	var header := workbench.header
	_inside(header, "编程顶部栏 " + message)
	var title_rect := header.title_label.get_global_rect()
	var goal_rect := header.goal_label.get_global_rect()
	for label: Label in [header.title_label, header.goal_label]:
		_inside(label, "编程标题与目标 " + str(label.name) + " " + message)
		_expect(header.get_global_rect().grow(1).encloses(label.get_global_rect()), "关卡标题和简短目标完整位于顶部栏 " + message)
	_expect(title_rect.position.x >= header.navigation.get_global_rect().end.x and is_equal_approx(title_rect.position.x, goal_rect.position.x) and title_rect.end.y <= goal_rect.position.y + 1.0, "关卡名字在导航右侧、目标在名字下方且不重叠 " + message)
	var previous := title_rect
	for control: Control in [header.run_button, header.pause_button, header.stop_button, header.reset_button, header.more_button, header.book_button]:
		_inside(control, "编程工具 " + str(control.name) + " " + message)
		var rect := control.get_global_rect()
		_expect(header.get_global_rect().grow(1).encloses(rect) and rect.position.x >= previous.end.x - 1.0, "编程工具按顺序排列且不重叠：" + str(control.name) + " " + message)
		_expect(absf(rect.get_center().y - header.get_global_rect().get_center().y) < 1.0, "编程工具垂直居中：" + str(control.name) + " " + message)
		previous = rect
		if control is Button:
			_expect(control.size.x >= 40 and is_equal_approx(control.size.x, control.size.y) and control.text.is_empty() and not control.get_tooltip().is_empty(), "圆形与药丸图标保留足够命中区和非空本土化悬停说明 " + message)
			_expect(control.icon != null and control.icon.resource_path.ends_with(".svg") and control.icon.get_width() >= 48, "顶部图标使用至少双倍像素密度的 SVG 纹理 " + message)
	_expect(workbench._world_panel.get_global_rect().position.y >= header.get_global_rect().end.y and workbench._tabs.get_global_rect().position.y >= header.get_global_rect().end.y, "地图和程序工作区紧接顶部栏且不重叠 " + message)
	await _workbench_guide_layout(workbench, "第一关 " + message)
	header.more_button.pressed.emit()
	await create_timer(0.25).timeout
	await _settle()
	var menu := workbench._actions_menu
	_expect(menu.is_open() and menu._items.size() == 5, "编程更多菜单包含全部五项操作 " + message)
	_inside(menu._panel, "编程菜单面板 " + message)
	_expect(menu._panel.get_global_rect().position.y >= header.more_button.get_global_rect().end.y and absf(menu._panel.get_global_rect().end.x - header.more_button.get_global_rect().end.x) < 1.0, "编程菜单在更多按钮下方右对齐 " + message)
	for index in range(menu._items.size()):
		var item: Button = menu._items[index]
		_inside(item, "编程菜单项 " + str(index) + " " + message)
		_expect(item.is_visible_in_tree() and menu._panel.get_global_rect().grow(1).encloses(item.get_global_rect()) and item.icon != null, "菜单条目及图标完整可见 " + message)
		if index > 0:
			_expect(item.get_global_rect().position.y >= menu._items[index - 1].get_global_rect().end.y, "编程菜单各行不会重叠 " + message)
	_expect(TranslationServer.translate(menu._items[0].text) == game.tr("关卡说明") and TranslationServer.translate(menu._items[3].text) == game.tr("重置代码"), "菜单操作随当前语言显示 " + message)
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		_expect(menu._items[3].get_theme_color(color_name) == Color("d64646"), "重置代码在各交互状态保持指定红色：" + color_name + " " + message)
	menu.close_menu()
	await _settle()
	_expect(not menu.is_open() and header.more_button.has_focus(), "关闭编程菜单将焦点归还更多按钮 " + message)


## 指引默认折叠；展开后验证双语提示和动态关卡状态没有越出毛玻璃窗口。
func _workbench_guide_layout(workbench: GameWorkbench, message: String) -> void:
	var guide := workbench._guide_menu
	var button := workbench._guide_button
	_inside(button, "地图指引按钮 " + message)
	_expect(not guide.is_open() and not guide.goal_label.is_visible_in_tree() and not workbench._object_status.is_visible_in_tree(), "地图说明默认收到指引窗口中 " + message)
	_expect(workbench._world_panel.get_global_rect().encloses(button.get_global_rect()) and button.get_global_rect().position.x > workbench._world_panel.get_global_rect().get_center().x, "指引按钮位于地图卡片右上区域 " + message)
	button.pressed.emit()
	await create_timer(0.25).timeout
	await _settle()
	_expect(guide.is_open(), "指引按钮展开说明窗口 " + message)
	_inside(guide._panel, "指引毛玻璃窗口 " + message)
	for label: Label in [guide.goal_label, guide.description_label, guide.directions_label, guide.terrain_label]:
		guide._scroll.ensure_control_visible(label)
		await _settle()
		_horizontal_inside(label, guide._scroll, "关卡指引内容 " + str(label.name) + " " + message)
		_expect(label.is_visible_in_tree() and label.get_combined_minimum_size().y <= label.size.y + 1.0 and guide._scroll.get_global_rect().grow(1).encloses(label.get_global_rect()), "指引内容完整换行且可滚动到可见视口 " + message)
	if workbench._object_status.visible:
		guide._scroll.ensure_control_visible(workbench._object_status)
		await _settle()
		_horizontal_inside(workbench._object_status, guide._scroll, "机关或敌人提示 " + message)
		_expect(workbench._object_status.is_visible_in_tree() and guide._scroll.get_global_rect().grow(1).encloses(workbench._object_status.get_global_rect()), "动态关卡状态随指引一起显示并可滚动到达 " + message)
	_expect(not guide._scroll.get_h_scroll_bar().is_visible_in_tree(), "指引窗口不出现横向滚动 " + message)
	guide.close_menu()
	await _settle()
	_expect(not guide.is_open() and button.has_focus(), "关闭指引将焦点归还问号按钮 " + message)


## 装配目录收进玻璃抽屉，准备页工具栏恢复全宽并与其他页面共用导航位置。
func _preparation_toolbar_layout(game: GameShell, expected_back: Rect2, expected_navigation: Rect2, message: String) -> void:
	var panel := game.assembly_panel
	var header := panel.header
	var palette_button := panel.find_child("AssemblyPaletteButton", true, false) as Button
	var delete_button := panel.find_child("AssemblyDeleteButton", true, false) as Button
	var workspace := panel.find_child("AssemblyWorkspaceScroll", true, false) as Control
	var ready := panel.preparation_mode and header != null and palette_button != null and delete_button != null and workspace != null
	_expect(ready, "准备页目录入口、删除入口、工具栏及工作区均存在 " + message)
	if not ready:
		return
	_expect(not game._header.is_visible_in_tree() and not game._save_label.is_visible_in_tree(), "准备页移除全局顶部栏和底部操作栏 " + message)
	_inside(palette_button, "装配模块目录入口 " + message)
	_inside(delete_button, "装配删除入口 " + message)
	_expect(not panel._palette_drawer.is_open(), "模块目录默认收起，不常驻占用左列 " + message)
	_inside(header, "装配顶部工具栏 " + message)
	_expect(header.get_global_rect().position.x == workspace.get_global_rect().position.x and absf(header.size.x - workspace.size.x) < 1.0, "工具栏与装配卡片工作区共享完整宽度 " + message)
	_expect(header.back_button.get_global_rect().is_equal_approx(expected_back) and header.navigation.get_global_rect().is_equal_approx(expected_navigation), "准备页返回药丸与选关导航位置和尺寸一致 " + message)
	_expect(header.get_global_rect().end.y < workspace.get_global_rect().position.y, "工具栏固定在右工作区上方且不覆盖画布 " + message)
	_expect(game._back_button == header.back_button and header.back_button.icon != null and header.back_button.text.is_empty(), "准备页返回引用指向工具栏箭头 " + message)
	_expect(header.navigation.size.is_equal_approx(Vector2(88, 44)) and header.navigation.get_global_rect().position.is_equal_approx(header.get_global_rect().position), "准备导航药丸保留统一尺寸并贴全宽工具栏起点 " + message)
	_expect(header.back_button.get_tooltip() == game.tr("返回地图编辑器" if game._editor_playtest else "返回关卡"), "准备页返回目的地本土化正确 " + message)
	var previous := header.navigation.get_global_rect()
	for control: Control in [header.description_label, header.confirm_button, header.save_button, header.restore_button, header.help_button, header.book_button]:
		if not control.is_visible_in_tree():
			continue
		_inside(control, "准备工具 " + control.name + " " + message)
		var rect := control.get_global_rect()
		_expect(header.get_global_rect().encloses(rect) and rect.position.x >= previous.end.x - 1.0, "工具按顺序排列在同一栏内且无重叠：" + control.name + " " + message)
		_expect(absf(rect.get_center().y - header.get_global_rect().get_center().y) < 1.0, "工具在顶部栏垂直居中：" + control.name + " " + message)
		previous = rect
	_expect(header.confirm_button.size.is_equal_approx(Vector2(40, 40)) and header.book_button.size.is_equal_approx(Vector2(44, 44)), "确认圆形略缩小，手册保持原尺寸 " + message)
	_expect(header.save_button.is_visible_in_tree() == (not game._editor_playtest) and header.restore_button.is_visible_in_tree() == (not game._editor_playtest), "试玩正确隐藏持久化工具并回收其空间 " + message)


## 两种语言和窗口检查宽幅资料窗、模块目录、完整说明及搜索展开后的可用边界。
func _command_reference_layout(game: GameShell, message: String) -> void:
	var menu := game._command_menu
	var book := game.assembly_panel.header.book_button
	book.pressed.emit()
	await create_timer(0.3).timeout
	await _settle()
	_expect(menu.is_open() and not menu._section_buttons.is_empty() and not menu._cards.is_empty(), "书本打开模块指令资料窗 " + message)
	if not menu.is_open() or menu._section_buttons.is_empty() or menu._cards.is_empty():
		return
	var panel_rect := menu._panel.get_global_rect()
	_inside(menu._panel, "指令资料宽幅面板 " + message)
	_expect(panel_rect.size.x >= root.get_visible_rect().size.x * 0.75 and panel_rect.position.y >= book.get_global_rect().end.y, "资料窗横向展开且不遮住外部书本按钮 " + message)
	for control: Control in [menu._sidebar, menu._directory_scroll, menu._scroll, menu.header, menu.header.navigation, menu.header.search_button]:
		_inside(control, "资料窗区域 " + str(control.name) + " " + message)
		_expect(panel_rect.grow(1).encloses(control.get_global_rect()), "资料区域完整位于窗口内：" + str(control.name) + " " + message)
	_expect(menu._sidebar.get_global_rect().end.x < menu._scroll.get_global_rect().position.x and menu.header.get_global_rect().end.y <= menu._scroll.get_global_rect().position.y, "灰色模块目录在左，右侧说明位于工具栏下方 " + message)
	_expect(menu._sidebar.get_global_rect().encloses(menu._directory_scroll.get_global_rect()), "目录滚动区完整留在灰色侧栏内部 " + message)
	for scroll: ScrollContainer in [menu._directory_scroll, menu._scroll]:
		_expect(not scroll.get_h_scroll_bar().is_visible_in_tree(), "目录和资料都不产生横向滚动 " + message)
	var collapsed_heights: Array[float] = []
	for card: CommandReferenceItem in menu._cards:
		_expect(not card.expanded and card.preview.is_visible_in_tree() and not card.details.is_visible_in_tree(), "资料初始仅显示折叠指令预览 " + message)
		_expect(card.get_global_rect().grow(1).encloses(card.header_button.get_global_rect()) and card.header_button.get_global_rect().grow(1).encloses(card.preview.get_global_rect()), "指令预览完整位于可点击头部之内 " + message)
		collapsed_heights.append(card.size.y)
		card.header_button.button_pressed = true
	await create_timer(0.35).timeout
	await _settle()
	for index in range(menu._details.size()):
		var details: Label = menu._details[index]
		var card := menu._cards[index] as CommandReferenceItem
		_expect(card.expanded and details.is_visible_in_tree() and details.size.x <= menu._scroll.size.x and details.get_combined_minimum_size().y <= details.size.y + 1.0, "展开后说明完整换行显示且不裁剪 " + message)
		_expect(card.get_global_rect().grow(1).encloses(details.get_global_rect()) and details.get_global_rect().position.y >= card.header_button.get_global_rect().end.y, "展开说明位于对应指令下方且不越过卡片 " + message)
		card.header_button.button_pressed = false
	await create_timer(0.35).timeout
	await _settle()
	for index in range(menu._cards.size()):
		var card := menu._cards[index] as CommandReferenceItem
		_expect(not card.expanded and absf(card.size.y - collapsed_heights[index]) < 1.0, "收起动画完成后回收说明占用空间 " + message)
	var navigation_before := menu.header.navigation.get_global_rect()
	menu.header.search_button.pressed.emit()
	await create_timer(0.4).timeout
	await _settle()
	_inside(menu.header.search_input, "资料搜索输入框 " + message)
	_inside(menu.header.search_close_button, "收起资料搜索按钮 " + message)
	_expect(menu.header.search_input.has_focus() and menu.header.get_global_rect().grow(1).encloses(menu.header.search_input.get_global_rect()), "搜索展开后完整位于工具栏中并可直接输入 " + message)
	_expect(menu.header.search_close_button.get_global_rect().end.x <= menu.header.search_input.get_global_rect().position.x and menu.header.navigation.get_global_rect().is_equal_approx(navigation_before), "收起入口与搜索框无重叠且左导航不位移 " + message)
	menu.header.search_close_button.pressed.emit()
	await create_timer(0.4).timeout
	await _settle()
	_expect(not menu.header.search_input.is_visible_in_tree() and menu.header.search_button.is_visible_in_tree(), "收起搜索恢复原工具栏 " + message)
	menu.header.back_button.pressed.emit()
	await _settle()
	_expect(not menu.is_open() and book.has_focus(), "返回关闭资料后焦点回到外部书本 " + message)


## 使用当前可见返回按钮结束真实会话，再验证恢复选关页时导航没有跳动。
func _return_to_level_navigation(game: GameShell, expected_back: Rect2, expected_navigation: Rect2, message: String) -> void:
	game._back_button.pressed.emit()
	await _settle()
	_expect(game.page == GameShell.Page.LEVELS and game.session == null, "胶囊返回按钮仍进入选关页并结束关卡会话 " + message)
	var back := game.find_child("LevelBackButton", true, false) as Button
	var navigation := game.find_child("LevelNavigation", true, false) as Control
	var ready := back != null and navigation != null and back.is_visible_in_tree() and navigation.is_visible_in_tree()
	_expect(ready, "返回后选关页胶囊可见 " + message)
	if ready:
		_expect(back.get_global_rect().is_equal_approx(expected_back) and navigation.get_global_rect().is_equal_approx(expected_navigation), "返回选关后导航位置与进入前完全一致 " + message)


## 编辑器和试玩共用相同导航几何，退出试玩恢复同一个编辑器及图标工具栏。
func _editor_playtest_navigation(game: GameShell, expected_back: Rect2, expected_navigation: Rect2, message: String) -> void:
	var editor := game._editor
	var editor_document := editor.editor_document
	var app_icon := game.find_child("HeaderAppIcon", true, false) as Control
	var header := editor._header
	_expect(app_icon != null and not app_icon.is_visible_in_tree() and not game._header.is_visible_in_tree(), "编辑器隐藏软件图标及重复外壳页头 " + message)
	_expect(game._back_button == header.back_button and header.back_button.text.is_empty() and header.back_button.icon != null and header.back_button.get_global_rect().is_equal_approx(expected_back) and header.navigation.get_global_rect().is_equal_approx(expected_navigation), "编辑器图标导航与选关页位置及尺寸完全一致 " + message)
	editor._play_button.pressed.emit()
	game._dialogue_dialog.hide()
	await _settle()
	_expect(game.page == GameShell.Page.ASSEMBLY, "编辑器测试进入组装页 " + message)
	_level_navigation_matches(game, expected_back, expected_navigation, "编辑器试玩组装 " + message)
	_expect(TranslationServer.translate(game._back_button.get_tooltip()) == game.tr("返回地图编辑器"), "试玩返回箭头的说明采用当前语言 " + message)
	game.session.assembly.add_module("movement", Vector2.ZERO)
	game._confirm_assembly()
	await _settle()
	_expect(game.page == GameShell.Page.PLAY, "编辑器测试确认后进入编程页 " + message)
	_level_navigation_matches(game, expected_back, expected_navigation, "编辑器试玩编程 " + message)
	game._back_button.pressed.emit()
	await _settle()
	_expect(game.page == GameShell.Page.EDITOR and game._editor == editor and game._editor.editor_document == editor_document and game.session == null, "试玩药丸返回恢复原编辑器文档并结束会话 " + message)
	_expect(not app_icon.is_visible_in_tree() and not game._header.is_visible_in_tree() and game._back_button == header.back_button and header.back_button.is_visible_in_tree() and header.back_button.get_global_rect().is_equal_approx(expected_back) and header.navigation.get_global_rect().is_equal_approx(expected_navigation), "结束试玩后恢复同一编辑器工具栏及精确导航位置 " + message)


## 等待容器完成两轮尺寸协商，避免检查上一页的布局数据。
func _settle() -> void:
	await process_frame
	await process_frame


## 分类标题、折叠行和独立导入网格在两种窗口与语言下共享可用列宽。
func _level_categories_inside(game: GameShell, message: String) -> void:
	game._show_level_page()
	await _settle()
	var scroll := game.find_child("LevelScroll", true, false) as ScrollContainer
	var sections := game.find_child("LevelSections", true, false) as VBoxContainer
	var tutorial := game.find_child("TutorialSection", true, false) as Control
	var imported := game.find_child("ImportedSection", true, false) as Control
	var grid := game.find_child("LevelGrid", true, false) as GridContainer
	var imported_grid := game.find_child("ImportedLevelGrid", true, false) as GridContainer
	var toggle := game.find_child("TutorialToggleButton", true, false) as Button
	var import_button := game.find_child("ImportLevelButton", true, false) as Button
	var custom := game.find_child("LevelButton_15", true, false) as Button
	var ready := scroll != null and sections != null and tutorial != null and imported != null and grid != null and imported_grid != null and toggle != null and import_button != null and custom != null
	_expect(ready, "教学和导入分类的全部布局节点存在 " + message)
	if not ready:
		return
	_expect(scroll.get_child(0) == sections and tutorial.get_parent() == sections and imported.get_parent() == sections, "两个分类共用纵向滚动容器 " + message)
	var title := _find_translated_label(tutorial, game.tr("教学关卡"))
	var imported_title := _find_translated_label(imported, game.tr("导入关卡"))
	_expect(title != null and imported_title != null, "两个分类标题采用当前语言 " + message)
	if title != null:
		_inside(title, "教学分类标题 " + message)
		_expect(title.get_global_rect().end.x <= toggle.get_global_rect().position.x + 1.0, "更多按钮位于教学标题右侧且无重叠 " + message)
		_expect(absf(title.get_global_rect().get_center().y - toggle.get_global_rect().get_center().y) <= 1.0, "教学标题和更多按钮垂直居中在同一行 " + message)
	if imported_title != null:
		_horizontal_inside(imported_title, scroll, "导入分类标题 " + message)
	_inside(toggle, "展示更多按钮 " + message)
	_expect(absf(toggle.get_global_rect().end.x - tutorial.get_global_rect().end.x) <= 1.0, "更多按钮与教学分类右边缘对齐 " + message)
	_expect(grid.columns == 7 and imported_grid.columns == 7, "两个关卡分类均为七列 " + message)
	_expect(import_button.get_parent().get_parent() == imported_grid and import_button.get_parent().get_index() == 0, "导入入口固定在独立网格第一格 " + message)
	_expect(custom.get_parent().get_parent() == imported_grid and custom.get_parent().get_index() == 1, "真实导入关卡位于加号之后 " + message)
	var cards: Array[Button] = []
	for index in range(15):
		var card := game.find_child("LevelButton_%d" % index, true, false) as Button
		_expect(card != null and card.is_visible_in_tree() == (index < 7), "默认仅前七张教学卡片可见，第 %d 张 " % (index + 1) + message)
		if card == null:
			return
		cards.append(card)
		_expect(card.custom_minimum_size.is_equal_approx(Vector2(104, 104)) and (not card.is_visible_in_tree() or card.size.is_equal_approx(Vector2(104, 104))), "七列入口图标缩小并保持正方形 " + message)
		var icon_style := card.get_theme_stylebox("normal") as StyleBoxFlat
		_expect(icon_style != null and icon_style.corner_radius_top_left >= 34 and icon_style.corner_radius_bottom_right >= 34, "缩小后外框保持更大的饱满圆角 " + message)
		for text_node in card.get_parent().get_children():
			if text_node is Label and text_node.is_visible_in_tree():
				_expect(text_node.get_theme_font_size("font_size") >= 12 and text_node.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "七列名称和状态保留可读字号并正常换行 " + message)
				_expect(text_node.get_combined_minimum_size().y <= text_node.size.y + 1 and text_node.size.x <= card.get_parent().size.x + 1, "中英文名称和完成状态完整容纳在本列 " + message)
		if index < 7:
			_inside(card, "默认教学卡片 %d " % (index + 1) + message)
			_expect(absf(card.get_global_rect().position.y - cards[0].get_global_rect().position.y) <= 1.0, "默认七张教学卡片位于同一行 " + message)
	_check_category_columns(cards, import_button, custom, scroll, message)
	_expect(TranslationServer.translate(toggle.text) == ("Show More (15)" if TranslationServer.get_locale().begins_with("en") else "展示更多（15）"), "折叠按钮总数只包含教学关卡 " + message)
	toggle.pressed.emit()
	await _settle()
	# 切换可能重建列表，重新取当前节点检查真实展开后的几何位置。
	scroll = game.find_child("LevelScroll", true, false) as ScrollContainer
	grid = game.find_child("LevelGrid", true, false) as GridContainer
	imported_grid = game.find_child("ImportedLevelGrid", true, false) as GridContainer
	toggle = game.find_child("TutorialToggleButton", true, false) as Button
	import_button = game.find_child("ImportLevelButton", true, false) as Button
	custom = game.find_child("LevelButton_15", true, false) as Button
	cards.clear()
	for index in range(15):
		var card := game.find_child("LevelButton_%d" % index, true, false) as Button
		_expect(card != null and card.is_visible_in_tree(), "展开后第 %d 张教学卡片可见 " % (index + 1) + message)
		if card == null:
			return
		cards.append(card)
		_horizontal_inside(card, scroll, "展开的教学卡片 %d " % (index + 1) + message)
		if index >= 7:
			_expect(card.get_global_rect().position.y > cards[0].get_global_rect().end.y and absf(card.get_global_rect().position.x - cards[index - 7].get_global_rect().position.x) <= 1.0, "后续教学卡片进入对齐的第二行 " + message)
	_expect(imported_grid.get_global_rect().position.y > grid.get_global_rect().end.y, "导入分类排在完整教学网格下方 " + message)
	_check_category_columns(cards, import_button, custom, scroll, message)
	_expect(TranslationServer.translate(toggle.text) == ("Show Less" if TranslationServer.get_locale().begins_with("en") else "收起"), "展开按钮翻译完整 " + message)
	toggle.pressed.emit()
	await _settle()


## 只比较水平视口，允许正常向下滚动，同时验证稀疏导入网格保留七列宽度。
func _check_category_columns(cards: Array[Button], import_button: Button, custom: Button, scroll: ScrollContainer, message: String) -> void:
	for pair in [[cards[0], import_button], [cards[1], custom]]:
		var tutorial_column: Control = pair[0].get_parent()
		var imported_column: Control = pair[1].get_parent()
		_expect(absf(tutorial_column.size.x - imported_column.size.x) <= 1.0 and absf(tutorial_column.get_global_rect().position.x - imported_column.get_global_rect().position.x) <= 1.0, "稀疏导入网格与教学列同宽且对齐 " + message)
		_horizontal_inside(pair[1], scroll, "导入卡片 " + message)
	_expect(scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED and not scroll.get_h_scroll_bar().is_visible_in_tree(), "分类列表不会出现横向滚动条 " + message)


## 寻找当前显示语言的分类标题，不依赖生产代码新增的标题节点名。
func _find_translated_label(parent: Node, displayed: String) -> Label:
	for label in parent.find_children("*", "Label", true, false):
		if TranslationServer.translate(label.text) == displayed:
			return label
	return null


## 检查卡片水平范围不越过滚动条，纵向边界由滚动容器正常裁切。
func _horizontal_inside(control: Control, scroll: ScrollContainer, message: String) -> void:
	var viewport := scroll.get_global_rect()
	if scroll.get_v_scroll_bar().is_visible_in_tree():
		viewport.size.x -= scroll.get_v_scroll_bar().size.x
	var rect := control.get_global_rect()
	_expect(rect.size.x > 0.0 and rect.position.x >= viewport.position.x - 1.0 and rect.end.x <= viewport.end.x + 1.0, "%s：水平范围 %s 位于 %s 内" % [message, rect, viewport])


## 汇总分类结构与几何断言，失败时保持非零退出状态。
func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 对关键交互控件检查窗口包含关系，打印具体矩形便于定位翻译溢出。
func _inside(control: Control, message: String) -> void:
	_checks += 1
	var rect := control.get_global_rect()
	if rect.size.x <= 0 or rect.size.y <= 0 or not root.get_visible_rect().grow(1).encloses(rect):
		_failures += 1
		push_error("%s：%s 不在 %s 内" % [message, rect, root.get_visible_rect()])


## 有限等待地图自适应与容器协商，验证整个阶梯画布处于真实滚动视口内。
func _staircase_inside_viewport(workbench: GameWorkbench, message: String) -> void:
	var viewport := Rect2()
	var canvas := Rect2()
	var fits := false
	for attempt in 12:
		await process_frame
		viewport = workbench._world_scroll.get_global_rect()
		var vertical := workbench._world_scroll.get_v_scroll_bar()
		var horizontal := workbench._world_scroll.get_h_scroll_bar()
		# 出现滚动条时扣除其占地，避免把被滚动条遮住的地图误判为完整可见。
		if vertical.is_visible_in_tree():
			viewport.size.x -= vertical.size.x
		if horizontal.is_visible_in_tree():
			viewport.size.y -= horizontal.size.y
		canvas = workbench._playfield.get_global_rect()
		fits = canvas.size.x > 0.0 and canvas.size.y > 0.0 and viewport.grow(1).encloses(canvas)
		if attempt >= 2 and fits:
			break
	_checks += 1
	if not fits:
		_failures += 1
		push_error("%s：完整画布 %s 不在实际地图视口 %s 内" % [message, canvas, viewport])


## 仅清理本次独占的测试目录，永不扫描真实 solutions 或 settings 文件。
func _remove_temporary(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	for file in directory.get_files():
		directory.remove(file)
	for child in directory.get_directories():
		_remove_temporary(path.path_join(child))
	DirAccess.remove_absolute(path)
