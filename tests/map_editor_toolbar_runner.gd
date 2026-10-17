extends SceneTree
## 地图编辑器图标工具栏回归：真实操作、文件保护、菜单与试玩导航均使用独占存储。

var _checks := 0
var _failures := 0
var _temporary: String
var _game: GameShell


## 延迟到场景树可安全添加控件，再启动独立回归。
func _initialize() -> void:
	_run.call_deferred()


## 先比较中英和两种窗口布局，再验证新入口保持原编辑器数据与试玩语义。
func _run() -> void:
	_temporary = "user://tests/map_editor_toolbar_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	DirAccess.make_dir_recursive_absolute(_temporary.path_join("maps"))
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_game.settings.set_code_color_mode("dark")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			await _test_geometry(locale + " " + str(dimensions))
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()
	var editor := _game._editor
	editor._load_document(MapEditor.DEFAULT_MAP_PATH) # 保存与试玩检查显式使用内置示例夹具。
	await _test_dialog_appearance(editor)
	await _test_menu(editor)
	await _test_menu_focus_modes(editor)
	await _test_save_and_history(editor)
	await _test_history_shortcuts(editor)
	await _test_dirty_safety(editor)
	await _test_playtest(editor)
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图编辑器工具栏回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 使用真实选关页作为导航基准，所有图标入口必须完整位于视口且互不重叠。
func _test_geometry(context: String) -> void:
	_game._show_level_page()
	await _settle()
	var expected_back := (_game.find_child("LevelBackButton", true, false) as Control).get_global_rect()
	var expected_navigation := (_game.find_child("LevelNavigation", true, false) as Control).get_global_rect()
	_game._open_editor()
	await _settle()
	var editor := _game._editor
	_check(editor._file_dialog.use_native_dialog and editor._file_dialog.access == FileDialog.ACCESS_FILESYSTEM, "文件选择器优先使用系统原生窗口并允许选择其他目录 " + context)
	_check(editor._file_dialog.filters.size() == 1 and editor._file_dialog.filters[0].begins_with("*.json"), "原生打开和另存为保持地图 JSON 文件过滤 " + context)
	# 自动回归只操作内嵌后备窗口，不在图形测试主机上弹出无法自动关闭的系统保存面板。
	editor._file_dialog.use_native_dialog = false
	_check((editor._metadata_text.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == Color("121314"), "新建地图编辑器继承已选择的深色代码配色 " + context)
	var header := editor._header
	_check(not _game._header.is_visible_in_tree() and not _game._header_mark.is_visible_in_tree(), "编辑器收起重复页头与软件图标 " + context)
	_check(_game._back_button == header.back_button and header.back_button.get_global_rect().is_equal_approx(expected_back) and header.navigation.get_global_rect().is_equal_approx(expected_navigation), "编辑器导航精确复用选关页位置与尺寸 " + context)
	_check(header.navigation.global_position.is_equal_approx(Vector2(24, 24)) and is_equal_approx(header.navigation.size.y, 44), "导航保持24像素外边距及44像素高度 " + context)
	_check(header.back_button.get_tooltip() == _game.tr("返回开始页面"), "返回悬停说明随当前语言显示目标 " + context)
	var buttons: Array[Button] = [header.back_button, editor._zoom_out_button, editor._zoom_in_button, editor._guide_button, header.new_button, header.save_button, header.undo_button, header.redo_button, header.more_button, header.reload_button]
	for button in buttons:
		_check(button.is_visible_in_tree() and button.text.is_empty() and button.icon != null and not button.get_tooltip().is_empty(), "工具栏入口采用带提示的纯SVG图标：" + str(button.name) + " " + context)
		_check(root.get_visible_rect().grow(1).encloses(button.get_global_rect()) and button.size.x > 0 and button.size.y > 0, "图标按钮完整位于视口：" + str(button.name) + " " + context)
		_check(is_equal_approx(button.size.y, 44.0) and is_equal_approx(button.get_global_rect().get_center().y, header.back_button.get_global_rect().get_center().y), "顶部所有入口同为44像素并沿导航中线对齐：" + str(button.name) + " " + context)
	for index in buttons.size():
		for other in range(index + 1, buttons.size()):
			_check(not buttons[index].get_global_rect().grow(-0.5).intersects(buttons[other].get_global_rect().grow(-0.5)), "图标按钮之间没有重叠：%s / %s %s" % [buttons[index].name, buttons[other].name, context])
	for index in range(1, buttons.size() - 1):
		_check(buttons[index].get_global_rect().end.x <= buttons[index + 1].global_position.x, "操作顺序为缩放、指引、新建保存、历史更多、重载：" + str(buttons[index].name) + " " + context)
	_check(editor._zoom_out_button == header.zoom_out_button and editor._zoom_in_button == header.zoom_in_button and editor._guide_button == header.guide_button, "迁移入口保留编辑器原操作句柄 " + context)
	_check(editor._undo_button == header.undo_button and editor._redo_button == header.redo_button and header.undo_button.disabled and header.redo_button.disabled, "首次载入保留历史句柄且正确禁用空历史 " + context)
	# 改变内部路径不应重新生成可见路径控件，也不能推动页头或占用工作区。
	var original_path := editor.editor_document.path
	var reload_right := header.reload_button.get_global_rect().end.x
	editor.editor_document.path = _temporary.path_join("nested_path_".repeat(12) + "map.json")
	editor._on_document_changed()
	await _settle()
	_check(editor.find_child("MapEditorOpenButton", true, false) == null, "标题下不再创建路径按钮或空白占位行 " + context)
	_check(is_equal_approx(header.reload_button.get_global_rect().end.x, reload_right), "长路径不会推动页头最右侧重载按钮 " + context)
	editor.editor_document.path = original_path
	editor._on_document_changed()
	await _settle()
	var anchor := header.more_button.get_global_rect()
	_press(header.more_button)
	await create_timer(0.23).timeout
	var menu := editor._actions_menu
	_check(menu.is_open() and menu._items.size() == 4, "更多菜单包含打开、另存为、校验与元数据 " + context)
	var panel := menu._panel.get_global_rect()
	_check(root.get_visible_rect().encloses(panel) and absf(panel.end.x - anchor.end.x) < 1 and absf(panel.position.y - anchor.end.y - 8) < 1, "菜单右对齐入口并在其下方完整展开 " + context)
	_check(header.more_button.get_global_rect().is_equal_approx(anchor), "展开菜单不挤动工具栏 " + context)
	var captions := ["打开地图", "另存为", "校验", "元数据 JSON"]
	for index in menu._items.size():
		var item: Button = menu._items[index]
		_check(item.is_visible_in_tree() and item.icon != null and panel.encloses(item.get_global_rect()) and TranslationServer.translate(item.text) == _game.tr(captions[index]), "菜单项目含图标且正确本土化：" + captions[index] + " " + context)
	menu.close_menu()
	await _settle()


## 菜单通过 Esc、重复入口、键盘及外部点击关闭，关闭点击不能穿透到地图。
func _test_menu(editor: MapEditor) -> void:
	var menu := editor._actions_menu
	_press(editor._header.more_button)
	await _settle()
	_check(menu._items[0].has_focus(), "打开菜单时焦点进入第一项")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not menu.is_open() and editor._header.more_button.has_focus(), "Esc关闭菜单并返回入口焦点")
	_press(editor._header.more_button)
	_press(editor._header.more_button)
	_check(not menu.is_open(), "重复点击更多入口关闭同一个菜单")
	_press(editor._header.more_button)
	await _settle()
	_key(KEY_DOWN)
	_key(KEY_DOWN)
	await _settle()
	_check(menu._items[2].has_focus(), "下方向键依次越过另存为后切到校验项目")
	_key(KEY_ENTER)
	await _settle()
	_check(not menu.is_open() and editor._status.text.contains("校验通过"), "键盘确认执行真实地图校验并关闭菜单")
	var before := _signature(editor)
	_press(editor._header.more_button)
	await _settle()
	var point := editor._canvas.global_position + Vector2(16, 16)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event)
	await _settle()
	_check(not menu.is_open() and _signature(editor) == before, "外部点击关闭菜单且完整吞掉笔画点击")
	_press(editor._header.more_button)
	await _settle()
	_press(menu._items[3])
	_check(editor._metadata_dialog.visible and not menu.is_open(), "元数据菜单仍打开原有JSON编辑窗口")
	var metadata := editor.editor_document.metadata_dict()
	metadata.extra["toolbar_regression"] = {"preserved": true}
	editor._metadata_text.text = JSON.stringify(metadata)
	editor._metadata_dialog.confirmed.emit()
	_check(not editor._metadata_dialog.visible and editor.editor_document.document.extra.has("toolbar_regression") and editor.editor_document.is_dirty(), "元数据确认通过既有校验并建立可撤销修改")
	var undo_count := editor.editor_document._undo_stack.size()
	before = _signature(editor)
	_press(editor._header.reload_button)
	_check(_signature(editor) == before and editor.editor_document._undo_stack.size() == undo_count and editor.editor_document.is_dirty() and editor._status.text.contains("内容已重载"), "重载内容更新注册表并保留文档、未保存状态与历史")


## 真实鼠标和键盘往返只改变焦点提示；菜单关闭不能残留蓝框或穿透修改地图。
func _test_menu_focus_modes(editor: MapEditor) -> void:
	var header := editor._header
	var menu := editor._actions_menu
	var more := header.more_button
	var model := editor.editor_document
	var before := _signature(editor)
	var undo_count := model._undo_stack.size()
	var redo_count := model._redo_stack.size()
	var saved_path := model.path
	var levels_before := _snapshot(_game.user_levels_directory)
	var empty_header := header.title_label.get_global_rect().get_center()
	await _click_at(more.get_global_rect().get_center())
	_check(menu.is_open() and menu._items[0].has_focus() and not _focus_hint_visible(menu._items[0]), "鼠标打开更多仍保留可操作焦点，但不显示额外键盘高亮")
	await _click_at(more.get_global_rect().get_center())
	_check(not menu.is_open() and more.has_focus() and not _focus_hint_visible(more), "鼠标再次点击更多关闭菜单后不残留淡蓝焦点描边")
	await _move_pointer(empty_header)
	await _move_pointer(more.get_global_rect().get_center())
	_check(more.is_hovered(), "真实鼠标移入更多按钮仍能触发悬停")
	await _move_pointer(empty_header)
	_check(not more.is_hovered() and more.has_focus() and not _focus_hint_visible(more), "鼠标移出后悬停和蓝框均消失，原生焦点仍保留")
	await _click_at(header.reload_button.get_global_rect().get_center())
	_check(header.reload_button.has_focus() and not more.has_focus() and not _focus_hint_visible(header.reload_button), "点击另一工具栏按钮正确转移焦点且不新增鼠标焦点环")
	_key(KEY_TAB, false, false, true)
	await _settle()
	_check(more.has_focus() and _focus_hint_visible(more), "Shift+Tab从重载返回更多时显示清晰键盘焦点环")
	_key(KEY_ENTER)
	await _settle()
	_check(menu.is_open() and menu._items[0].has_focus() and _focus_hint_visible(menu._items[0]), "键盘打开菜单后第一项显示可见焦点")
	_key(KEY_TAB)
	await _settle()
	_check(menu._items[1].has_focus() and _focus_hint_visible(menu._items[1]), "Tab在菜单内移动并保留键盘焦点提示")
	# 前一测试已建立真实撤销历史，若快捷键泄漏，文档签名会发生变化。
	_check(undo_count > 0, "焦点回归使用可撤销的文档，确保快捷键穿透检查有效")
	_key(KEY_Z, true)
	_key(KEY_S, true)
	_key(KEY_O, true)
	await _settle()
	_check(menu.is_open() and not editor._file_dialog.visible and not editor._dirty_dialog.visible and _signature(editor) == before and model._undo_stack.size() == undo_count and model.path == saved_path and _snapshot(_game.user_levels_directory) == levels_before, "菜单消费编辑快捷键，不撤销、保存或打开背后的地图")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not menu.is_open() and more.has_focus() and _focus_hint_visible(more), "Esc关闭后恢复入口的键盘焦点提示")
	await _move_pointer(empty_header)
	_check(more.has_focus() and not _focus_hint_visible(more), "从Esc改用鼠标后立即隐藏蓝框且保留焦点位置")
	await _click_at(more.get_global_rect().get_center())
	await create_timer(0.23).timeout
	await _click_at(menu._items[2].get_global_rect().get_center())
	_check(not menu.is_open() and editor._status.text.contains("校验通过") and more.has_focus() and not _focus_hint_visible(more), "鼠标执行真实校验后关闭菜单，入口不残留键盘描边")
	await _click_at(more.get_global_rect().get_center())
	# 选择已有地板，右键若穿透会将它擦除，避免在空白格上得到无效通过。
	var cell := Vector2i.ZERO
	for candidate: Vector2i in model.document.cells:
		cell = candidate
		break
	var map_point := editor._canvas.get_global_transform_with_canvas() * ((Vector2(cell) + Vector2(0.5, 0.5)) * editor._canvas.cell_size)
	_check(not model.document.get_tile_id(cell).is_empty() and not menu._panel.get_global_rect().has_point(map_point), "外点关闭用例命中菜单外已有地板，误穿透会产生可观测修改")
	await _click_at(map_point, MOUSE_BUTTON_RIGHT)
	_check(not menu.is_open() and more.has_focus() and not _focus_hint_visible(more), "鼠标外点关闭后归还入口焦点但不显示蓝框")
	_check(_signature(editor) == before and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count and model.path == saved_path, "焦点、悬停和菜单外点完整保留地图、路径与双向历史")


## 弹窗统一使用浅色圆角外壳；元数据编辑框继续独立响应代码配色。
func _test_dialog_appearance(editor: MapEditor) -> void:
	for dimensions in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		for locale in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			for index in [1, 3]:
				await _menu_item(editor, index)
				await _settle()
				var dialog: AcceptDialog = editor._file_dialog if index == 1 else editor._metadata_dialog
				var context := "%s %s %s" % [dimensions, locale, dialog.title]
				_check(dialog.is_embedded() and dialog.transparent_bg and dialog.get_theme_stylebox("panel") is StyleBoxEmpty, "正文不再重复绘制圆角或留下不透明方角 " + context)
				if index == 3:
					_check_metadata_geometry(editor, context)
				var frame := dialog.get_theme_stylebox("embedded_border", "Window") as StyleBoxFlat
				var icon := dialog.get_theme_icon("close")
				var close_position := Vector2(dialog.position) + Vector2(dialog.size.x - dialog.get_theme_constant("close_h_offset"), -dialog.get_theme_constant("close_v_offset")) + icon.get_size() / 2.0
				var top := float(dialog.position.y) - frame.expand_margin_top
				var right := float(dialog.position.x + dialog.size.x) + frame.expand_margin_right
				_check(absf(close_position.y - top - (right - close_position.x)) < 1.0, "关闭按钮与顶部及右侧保持相同留白 " + context)
				for pressed in [true, false]:
					var click := InputEventMouseButton.new()
					click.position = close_position
					click.global_position = close_position
					click.button_index = MOUSE_BUTTON_LEFT
					click.pressed = pressed
					root.push_input(click, true)
				await _settle()
				_check(not dialog.visible, "点击修正后的关闭位置关闭真实窗口 " + context)
				dialog.hide()
	root.size = Vector2i(1280, 800)
	_game.settings.set_language("zh_CN")
	await _settle()
	await _test_metadata_scrolling(editor)
	await _menu_item(editor, 3)
	await _settle()
	var code := editor._metadata_text
	var before := _signature(editor)
	var original := code.text
	code.set_caret_line(1)
	code.set_caret_column(0)
	code.begin_complex_operation()
	code.insert_text_at_caret("  ")
	code.end_complex_operation()
	code.select(1, 0, 1, 2)
	code.scroll_vertical = 6
	await _settle()
	var source := code.text
	var version := code.get_version()
	var caret := Vector2i(code.get_caret_column(), code.get_caret_line())
	var scroll := code.scroll_vertical
	for mode in ["light", "dark", "light"]:
		_game.settings.set_code_color_mode(mode)
		await _settle()
		var palette: Dictionary = GameTheme.CODE_DARK if mode == "dark" else GameTheme.CODE_LIGHT
		_check((code.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == palette.background and code.get_theme_color("font_color") == palette.text and code.get_theme_color("line_number_color") == palette.line_number, "元数据背景、正文与行号跟随共享配色 " + mode)
		_check(code.text == source and code.get_version() == version and Vector2i(code.get_caret_column(), code.get_caret_line()) == caret and code.get_selected_text() == "  " and is_equal_approx(code.scroll_vertical, scroll), "换色保留JSON原文、版本、光标、选区和滚动 " + mode)
		var syntax := code.syntax_highlighter as CodeHighlighter
		_check(syntax.has_keyword_color("true") and syntax.has_keyword_color("false") and syntax.has_color_region('"') and not syntax.has_keyword_color("move"), "元数据使用JSON高亮而非游戏程序指令 " + mode)
	code.undo()
	_check(code.text == original, "配色往返之后仍能撤销之前的JSON编辑")
	code.redo()
	_check(code.text == source and _signature(editor) == before, "文本重做仍可用，换色没有应用地图元数据")
	editor._metadata_dialog.hide()
	await _settle()


## 首次打开和语言往返均检查标题外框、编辑区与底部操作，避免只检查客户区而遗漏越界。
func _check_metadata_geometry(editor: MapEditor, context: String) -> void:
	var dialog := editor._metadata_dialog
	_check(dialog.size == Vector2i(456, 342), "元数据窗口保持原尺寸的60%，首次换行也不会撑大 " + context)
	var frame := dialog.get_theme_stylebox("embedded_border", "Window") as StyleBoxFlat
	var outer := Rect2(Vector2(dialog.position), Vector2(dialog.size)).grow_individual(frame.expand_margin_left, frame.expand_margin_top, frame.expand_margin_right, frame.expand_margin_bottom)
	_check(root.get_visible_rect().grow(1).encloses(outer), "元数据标题、关闭入口和完整窗口均位于逻辑视口内 " + context)
	var client := Rect2(Vector2.ZERO, Vector2(dialog.size)).grow(1)
	var controls: Array[Control] = [editor._metadata_text, dialog.get_ok_button(), dialog.get_cancel_button()]
	for control in controls:
		_check(control.is_visible_in_tree() and control.size.x > 0 and control.size.y > 0 and client.encloses(control.get_global_rect()), "元数据编辑区和确认取消操作完整位于窗口内：%s %s" % [control.get_class(), context])
	for index in controls.size():
		for other in range(index + 1, controls.size()):
			_check(not controls[index].get_global_rect().grow(-0.5).intersects(controls[other].get_global_rect().grow(-0.5)), "元数据编辑区与底部按钮互不覆盖：%s / %s %s" % [controls[index].get_class(), controls[other].get_class(), context])


## 用小逻辑视口和数百行JSON验证内部滚动，文本增长不能扩大弹窗或提前修改地图。
func _test_metadata_scrolling(editor: MapEditor) -> void:
	var original_scale_size := root.content_scale_size
	var original_size := root.size
	root.content_scale_size = Vector2i(640, 480)
	await _settle()
	editor._open_metadata()
	await _settle()
	_check_metadata_geometry(editor, "640×480逻辑视口")
	var initial_size := editor._metadata_dialog.size
	var before := _signature(editor)
	var rows: Array[Dictionary] = []
	for index in 400:
		rows.append({"id": index, "description": "元数据滚动回归 %d" % index})
	var code := editor._metadata_text
	code.text = JSON.stringify({"extra": {"scroll_regression": rows}}, "\t", true)
	await _settle()
	_check(code.get_line_count() > 400 and editor._metadata_dialog.size == initial_size, "数百行JSON只增长编辑内容，不撑大元数据窗口")
	_check_metadata_geometry(editor, "长JSON与小逻辑视口")
	var vertical := code.get_v_scroll_bar()
	_check(vertical.is_visible_in_tree() and vertical.max_value > vertical.page, "长JSON显示CodeEdit内部垂直滚动条")
	code.scroll_vertical = vertical.max_value
	await _settle()
	_check(code.scroll_vertical > 0 and is_equal_approx(vertical.value, vertical.max_value - vertical.page) and code.get_last_full_visible_line() >= code.get_line_count() - 2, "编辑区可独立滚动到JSON末尾")
	_check(editor._metadata_dialog.size == initial_size and _signature(editor) == before, "滚动至末尾保留窗口大小且没有应用地图修改")
	editor._metadata_dialog.hide()
	root.content_scale_size = original_scale_size
	root.size = original_size
	await _settle()


## 另存为和保存均写入独占目录，历史按钮必须同步保存点及真实文档变化。
func _test_save_and_history(editor: MapEditor) -> void:
	var original := FileAccess.get_file_as_bytes(MapEditor.DEFAULT_MAP_PATH)
	var first := _temporary.path_join("maps/first.json")
	await _menu_item(editor, 1)
	_check(editor._file_dialog.visible and editor._file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE and editor.editor_document.path == MapEditor.DEFAULT_MAP_PATH, "另存为先选择路径且不提前改写当前文档路径")
	_select_file(editor, first)
	_check(FileAccess.file_exists(first) and editor.editor_document.path == first and not editor.editor_document.is_dirty(), "另存为成功后更新路径及保存点")
	var first_bytes := FileAccess.get_file_as_bytes(first)
	editor._name_field.grab_focus()
	editor._name_field.text = "工具栏保存回归"
	_press(editor._header.save_button)
	var managed_path := editor.editor_document.path
	var saved := MapCodec.load_file(managed_path, editor.registry, false)
	_check(saved.is_ok() and saved.value.display_name == "工具栏保存回归" and not editor.editor_document.is_dirty() and not editor._file_dialog.visible and ProjectSettings.globalize_path(managed_path).get_base_dir() == ProjectSettings.globalize_path(_game.user_levels_directory), "保存图标提交尚未失焦名称并直接写入玩家目录")
	_check(FileAccess.get_file_as_bytes(first) == first_bytes, "普通保存不会覆盖先前另存为的外部文件")
	editor._name_field.release_focus()
	var initial_limit := editor.editor_document.get_module_limit()
	editor._module_limit_field.value = initial_limit + 1
	_check(not editor._header.undo_button.disabled and editor._header.redo_button.disabled and editor.editor_document.is_dirty(), "编辑规则后撤销可用且重做禁用")
	_check(editor._header.title_label.text.ends_with(" *"), "移除路径行后标题星号仍提示未保存修改")
	_press(editor._header.undo_button)
	_check(editor.editor_document.get_module_limit() == initial_limit and not editor.editor_document.is_dirty() and not editor._header.redo_button.disabled, "撤销恢复保存点、规则和未修改状态")
	_check(not editor._header.title_label.text.ends_with(" *"), "撤销到保存点同步移除标题星号")
	_press(editor._header.redo_button)
	_check(editor.editor_document.get_module_limit() == initial_limit + 1 and editor.editor_document.is_dirty() and editor._header.redo_button.disabled, "重做恢复规则修改及未保存状态")
	await _menu_item(editor, 1)
	var second := _temporary.path_join("maps/second.json")
	_select_file(editor, second)
	_check(FileAccess.file_exists(second) and editor.editor_document.path == second and not editor.editor_document.is_dirty() and FileAccess.get_file_as_bytes(first) == first_bytes, "再次另存为保留原文件并建立新文件保存点")
	var second_bytes := FileAccess.get_file_as_bytes(second)
	editor.editor_document.set_identity(editor.editor_document.document.id, "导出后继续保存")
	_press(editor._header.save_button)
	_check(editor.editor_document.path == managed_path and not editor.editor_document.is_dirty() and FileAccess.get_file_as_bytes(second) == second_bytes and DirAccess.get_files_at(_game.user_levels_directory).size() == 1, "另存为后普通保存继续更新同一个玩家关卡，导出副本保持原样")
	_check(FileAccess.get_file_as_bytes(MapEditor.DEFAULT_MAP_PATH) == original, "所有保存入口均未改动内置示例地图")


## 两种平台修饰键都执行地图历史，文本编辑器获得焦点时仍保留自己的原生历史。
func _test_history_shortcuts(editor: MapEditor) -> void:
	var model := editor.editor_document
	var initial := model.get_module_limit()
	editor._module_limit_field.value = initial + 1
	editor._header.more_button.grab_focus()
	await _settle()
	_key(KEY_Z, true)
	await _settle()
	_check(model.get_module_limit() == initial and not model.is_dirty() and not editor._header.redo_button.disabled, "Ctrl+Z撤销真实地图修改并恢复保存点")
	_key(KEY_Z, true, false, true)
	await _settle()
	_check(model.get_module_limit() == initial + 1 and model.is_dirty(), "Ctrl+Shift+Z重做同一个地图事务")
	_key(KEY_Z, false, true)
	await _settle()
	_check(model.get_module_limit() == initial and not model.is_dirty(), "Command+Z撤销真实地图修改并恢复保存点")
	_key(KEY_Z, false, true, true)
	await _settle()
	_check(model.get_module_limit() == initial + 1 and model.is_dirty(), "Command+Shift+Z重做同一个地图事务")
	_key(KEY_Z, true)
	_key(KEY_Y, true)
	await _settle()
	_check(model.get_module_limit() == initial + 1 and model.is_dirty(), "Ctrl+Y兼容重做被撤销的地图事务")
	_key(KEY_Z, true)
	await _settle()
	var before := _signature(editor)
	var undo_count := model._undo_stack.size()
	var redo_count := model._redo_stack.size()
	var field := editor._name_field
	var original := field.text
	field.grab_focus()
	field.caret_column = field.text.length()
	await _settle()
	_type_character(field.get_viewport(), "x")
	await _settle()
	_check(field.text == original + "x", "名称输入通过原生键盘输入建立独立文本历史")
	var mac := OS.has_feature("macos")
	_key(KEY_Z, not mac, mac)
	await _settle()
	_check(field.text == original, "名称输入框的本平台撤销快捷键只撤销输入文字")
	_key(KEY_Z, not mac, mac, true)
	await _settle()
	_check(field.text == original + "x" and _signature(editor) == before and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count, "名称输入框原生重做不消耗地图撤销或重做记录")
	_key(KEY_Z, not mac, mac)
	await _settle()
	editor._header.more_button.grab_focus()
	await _menu_item(editor, 3)
	var code := editor._metadata_text
	var json_before := code.text
	code.grab_focus()
	code.set_caret_line(0)
	code.set_caret_column(0)
	await _settle()
	_type_character(code.get_viewport(), "x")
	await _settle()
	_check(code.text == "x" + json_before, "元数据CodeEdit通过原生键盘输入建立独立文本历史")
	_key(KEY_Z, not mac, mac, false, code.get_viewport())
	await _settle()
	_check(code.text == json_before, "元数据CodeEdit原生撤销恢复JSON文字")
	_key(KEY_Z, not mac, mac, true, code.get_viewport())
	await _settle()
	_check(code.text == "x" + json_before and _signature(editor) == before and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count, "元数据CodeEdit原生重做保留地图内容及两侧历史")
	editor._metadata_dialog.hide()
	await _settle()


## 新建、打开、快捷键及返回继续经过原有未保存保护，取消不损失历史。
func _test_dirty_safety(editor: MapEditor) -> void:
	var saved_path := editor.editor_document.path
	editor._module_limit_field.value = editor.editor_document.get_module_limit() + 1
	var before := _signature(editor)
	var undo_count := editor.editor_document._undo_stack.size()
	_press(editor._header.new_button)
	_check(editor._dirty_dialog.visible and _signature(editor) == before, "新建图标先保护未保存文档")
	_cancel_dirty(editor)
	_check(editor.editor_document.path == saved_path and editor.editor_document._undo_stack.size() == undo_count and _signature(editor) == before, "取消新建完整保留路径、文档与历史")
	await _menu_item(editor, 0)
	_check(editor._dirty_dialog.visible and not editor._file_dialog.visible, "更多菜单的打开地图不能绕过未保存保护")
	_cancel_dirty(editor)
	await _settle()
	editor._header.more_button.grab_focus()
	_key(KEY_O, true)
	await _settle()
	_check(editor._dirty_dialog.visible and _signature(editor) == before, "Ctrl+O同样保护未保存文档")
	editor._dirty_dialog.hide()
	editor._dirty_dialog.confirmed.emit()
	_check(editor._file_dialog.visible and editor._file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE, "确认打开后使用原有地图文件选择器")
	_select_file(editor, saved_path)
	_check(not editor.editor_document.is_dirty() and editor.editor_document._undo_stack.is_empty(), "打开选中文件后建立真实载入保存点")
	_press(editor._header.new_button)
	_check(editor.editor_document.path.is_empty() and editor.editor_document.document.cells.is_empty() and editor._header.undo_button.disabled and editor._header.redo_button.disabled, "无修改时新建立即建立全void空文档及空历史")
	_press(editor._header.save_button)
	_check(not editor._file_dialog.visible and not editor.editor_document.is_dirty() and FileAccess.file_exists(editor.editor_document.path) and ProjectSettings.globalize_path(editor.editor_document.path).get_base_dir() == ProjectSettings.globalize_path(_game.user_levels_directory), "空路径文档的保存图标直接写入玩家目录且不要求选路径")
	await _menu_item(editor, 0)
	_check(editor._file_dialog.visible and editor._file_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE, "未修改地图可直接从更多菜单打开文件")
	_select_file(editor, saved_path)
	editor._module_limit_field.value = editor.editor_document.get_module_limit() + 1
	before = _signature(editor)
	_press(editor._header.back_button)
	_check(_game._editor_discard_dialog.visible and _game.page == GameShell.Page.EDITOR, "新返回箭头继续执行外壳的地图放弃确认")
	_game._editor_discard_dialog.get_cancel_button().pressed.emit()
	_game._editor_discard_dialog.hide()
	_check(_game._editor == editor and _signature(editor) == before and editor.editor_document.is_dirty(), "取消返回保留同一编辑器及未保存内容")


## 从新工具栏进入正常试玩，返回后保持同一文档、菜单关闭及两侧历史可用。
func _test_playtest(editor: MapEditor) -> void:
	editor.editor_document.paint(Vector2i.ZERO, "floor")
	editor.editor_document.paint(Vector2i(0, 1), "floor")
	_press(editor._header.undo_button)
	var model := editor.editor_document
	var before := _signature(editor)
	var path := model.path
	var undo_count := model._undo_stack.size()
	var redo_count := model._redo_stack.size()
	var navigation := editor._header.navigation.get_global_rect()
	var formal_source := "main() {\n    // 不应被试玩读取或改写\n}\n"
	_check(_game.drafts.save_draft(model.document.id, formal_source, []).is_ok(), "创建同ID隔离草稿用于检测试玩写入")
	var drafts_before := _snapshot(_game.drafts.directory)
	_press(editor._header.more_button)
	editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and not editor._actions_menu.is_open(), "开始测试关闭编辑器弹层并进入正常组装页")
	if _game.session == null:
		return
	_game._dialogue_dialog.hide()
	_check(_game.session.assembly.modules.is_empty() and _game.session.assembly.content == editor.registry and JSON.stringify(_game.session.level.document.to_dict(), "", true) == before, "试玩使用当前独立地图快照和注册表并从空装配开始")
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO).is_ok(), "试玩可以通过正常装配模型添加移动模块")
	_game._confirm_assembly_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.PLAY and _game.workbench != null, "确认装配后进入正常编程页")
	if _game.workbench == null:
		return
	_game._save_current_draft(true)
	_game._save_timer.timeout.emit()
	_game._back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY, "试玩编程返回先进入模块组装")
	_game._back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and _game._editor == editor and editor.editor_document == model and _game.session == null, "试玩返回同一个编辑器模型并结束会话")
	_check(_signature(editor) == before and model.path == path and model.is_dirty() and model._undo_stack.size() == undo_count and model._redo_stack.size() == redo_count, "试玩返回完整保留内容、路径、未保存标记和双向历史")
	_check(_game._back_button == editor._header.back_button and editor._header.navigation.get_global_rect().is_equal_approx(navigation) and not _game._header.is_visible_in_tree(), "试玩返回恢复原工具栏及相同导航几何")
	_check(_snapshot(_game.drafts.directory) == drafts_before, "试玩保存回调与返回未改写同ID正式草稿")
	_press(editor._header.redo_button)
	_check(model.document.get_tile_id(Vector2i(0, 1)) == "floor", "试玩返回后重做仍执行原来的地图笔画")
	_press(editor._header.undo_button)
	_check(_signature(editor) == before, "试玩返回后撤销仍恢复测试前内容")


## 展开真实菜单后点击指定项目，避免测试直接调用编辑器业务方法。
func _menu_item(editor: MapEditor, index: int) -> void:
	_press(editor._header.more_button)
	await _settle()
	_press(editor._actions_menu._items[index])


## 只有当前可见且启用的按钮才可触发操作，隐藏或禁用回归不能被信号掩盖。
func _press(button: Button) -> void:
	var usable := button != null and button.is_visible_in_tree() and not button.disabled
	_check(usable, "真实按钮入口可用：" + (str(button.name) if button != null else "null"))
	if usable:
		button.pressed.emit()


## 按实际文件选择信号完成读写；路径一律由独占用户目录提供。
func _select_file(editor: MapEditor, path: String) -> void:
	editor._file_dialog.file_selected.emit(path)
	editor._file_dialog.hide()


## 通过原生取消信号关闭保护对话框，不执行待处理的破坏操作。
func _cancel_dirty(editor: MapEditor) -> void:
	editor._dirty_dialog.get_cancel_button().pressed.emit()
	editor._dirty_dialog.hide()


## 点击经过真实窗口输入，正确换算缩放坐标，并配对按下与抬起。
func _click_at(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await _move_pointer(point)
	var window_point := root.get_final_transform() * point
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = window_point
		event.global_position = window_point
		event.button_index = button
		event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await _settle()


## 更新实际鼠标状态，使悬停和输入模式检查不依赖直接触发信号。
func _move_pointer(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	Input.parse_input_event(event)
	await _settle()


## 按钮须同时持有焦点并绘制非透明底色或描边，才算存在可见焦点提示。
func _focus_hint_visible(button: Button) -> bool:
	if not button.has_focus() or not button.is_visible_in_tree():
		return false
	var style := button.get_theme_stylebox("focus") as StyleBoxFlat
	return style != null and ((style.draw_center and style.bg_color.a > 0.01) or (style.border_color.a > 0.01 and (style.border_width_left + style.border_width_top + style.border_width_right + style.border_width_bottom) > 0))


## 输入经过真实视口，覆盖菜单的输入优先级与编辑器快捷键路由。
func _key(code: Key, control: bool = false, meta: bool = false, shift: bool = false, viewport: Viewport = null) -> void:
	var target := root if viewport == null else viewport
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.ctrl_pressed = control
		event.meta_pressed = meta
		event.shift_pressed = shift
		event.pressed = pressed
		target.push_input(event)


## 真实字符按键经过控件所在视口，确保检查的是原生输入历史而非程序赋值。
func _type_character(viewport: Viewport, character: String) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_X
		event.physical_keycode = KEY_X
		event.unicode = character.unicode_at(0)
		event.pressed = pressed
		viewport.push_input(event)


## 比较排序后的完整地图快照，未知扩展和规则同样包含在检查范围内。
func _signature(editor: MapEditor) -> String:
	return JSON.stringify(editor.editor_document.document.to_dict(), "", true)


## 读取测试草稿原始字节，保证试玩不存在隐式保存副作用。
func _snapshot(path: String) -> Dictionary:
	var result: Dictionary = {}
	var directory := DirAccess.open(path)
	if directory != null:
		for filename in directory.get_files():
			result[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return result


## 等待控件完成尺寸协商及隐藏窗口焦点切换。
func _settle() -> void:
	await process_frame
	await process_frame


## 只清理由本次运行创建的唯一用户目录，绝不访问正式玩家文件。
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


## 累计失败并继续收集独立证据，完成时使用非零退出状态报告失败。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
