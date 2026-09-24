extends SceneTree
## 通过真实设置路由验证背景选择、导入、删除保护和三语言单排布局。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _finished := false
var _original_locale := ""
var _original_size := Vector2i.ZERO
var _original_scale := Vector2i.ZERO
var _original_minimum := Vector2i.ZERO
var _original_volume := 0.0
var _original_mute := false
var _custom_ids: Array[String] = []


## 等场景树创建后再创建界面和测试专用文件。
func _initialize() -> void:
	_run.call_deferred()


## 只注入独立测试存档，并覆盖用户能实际触发的选择、右键和滚动行为。
func _run() -> void:
	_temporary = "user://tests/menu_background_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	_original_size = root.size
	_original_scale = root.content_scale_size
	_original_minimum = root.min_size
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	create_timer(55.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _create_game()
	_check(_game.settings.menu_background_mode == "default" and _game._main_background.visible, "首次启动保留自带图片背景")
	if not await _open_colors():
		_finish()
		return
	await _test_builtin_choices()
	await _test_import_and_delete()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			await _test_layout("%s %s" % [dimensions, locale])
	var selected_id: String = _game.settings.menu_background_id
	_game.queue_free()
	await _settle()
	await _create_game()
	_check(_game.settings.menu_background_mode == "custom" and _game.settings.menu_background_id == selected_id and _game.settings.custom_backgrounds.size() == 4, "重建游戏恢复自定义选择和删除后的图库")
	_check(_game._main_background.visible and _game._main_background._selected_path == _game.settings.get_menu_background_path(), "主菜单使用持久化的自定义图而不是默认图")
	_check(_game._main_background.blur_sigma == 64.0, "自定义背景沿用现有64像素模糊")
	_finish()


## 所有可能写盘的入口均使用本轮独占目录，不接触真实玩家配置或图片。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	root.add_child(_game)
	await _settle()


## 点击主菜单及设置中的真实按钮进入颜色与显示子页。
func _open_colors() -> bool:
	var settings_button := _game.find_child("SettingsButton", true, false) as Button
	if not _check(settings_button != null, "主菜单有设置入口"):
		return false
	await _click(settings_button)
	if not _check(_game.settings_panel != null, "设置按钮打开设置页"):
		return false
	var colors := _game.settings_panel.find_child("CodeColorsButton", true, false) as Button
	if not _check(colors != null, "设置页提供颜色与显示入口"):
		return false
	_game.settings_panel._scroll.ensure_control_visible(colors)
	await _settle()
	await _click(colors)
	return _check(_game.code_color_panel != null and _game.code_color_panel._background_picker != null, "颜色子页接入背景选择控件")


## 默认和纯色均通过预览按钮选择，返回主菜单时只切换背景而不改变代码区配色。
func _test_builtin_choices() -> void:
	var picker := _game.code_color_panel._background_picker
	_check(picker._buttons.has("default") and picker._buttons.has("solid") and picker._buttons.has("add"), "首次展示默认、纯色和自定义添加三个入口")
	_check(picker._buttons["default"].button_pressed and not picker._buttons["solid"].button_pressed, "首次仅默认背景有选中状态")
	_check_single_row(picker, "初始内置选项")
	_check(not picker._custom_scroll.get_h_scroll_bar().is_visible_in_tree(), "未溢出的三个内置选项无需横向滚动条")
	await _click(picker._buttons["default"], MOUSE_BUTTON_RIGHT)
	_check(not picker._delete_popup.visible, "内置背景不提供右键删除")
	await _click(picker._buttons["solid"])
	_check(_game.settings.menu_background_mode == "solid" and _game.settings.code_color_mode == "light", "纯色选择立即保存且不改变代码区模式")
	await _return_main()
	_check(not _game._main_background.visible and _game._main_background._source_texture == null, "纯色主菜单恢复底层原浅色背景")
	if not await _open_colors():
		return
	picker = _game.code_color_panel._background_picker
	_check(picker._buttons["solid"].button_pressed, "重入颜色页恢复纯色单选标记")
	await _click(picker._buttons["default"])
	await _return_main()
	_check(_game._main_background.visible and _game._main_background._selected_path == "res://assets/backgrounds/main_menu.png", "默认按钮恢复原有自带图片")
	await _open_colors()


## 导入图片接在三个内置项后方，整排溢出时常显横条，保留右键删除保护。
func _test_import_and_delete() -> void:
	var picker := _game.code_color_panel._background_picker
	var initial_height := picker.size.y
	# 测试使用嵌入文件窗口，避免打开操作系统原生选择器而占用用户桌面。
	picker._file_dialog.use_native_dialog = false
	await _click(picker._buttons["add"])
	if not _check(picker._file_dialog.visible, "自定义按钮打开图片选择窗口"):
		return
	var input_directory := _temporary.path_join("input")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(input_directory))
	for index in 5:
		var picture := Image.create(64, 48, false, Image.FORMAT_RGBA8)
		picture.fill(Color.from_hsv(float(index) / 5.0, 0.7, 0.8))
		var source_path := input_directory.path_join("测试背景 %d.png" % index)
		_check(picture.save_png(source_path) == OK, "创建仅供本轮导入的小图片 %d" % index)
		# 信号与文件选择器完成选图时一致，所有路径均来自测试独占目录。
		picker._file_dialog.file_selected.emit(ProjectSettings.globalize_path(source_path))
		picker._file_dialog.hide()
		await _settle()
		var selected_id: String = _game.settings.menu_background_id
		_custom_ids.append(selected_id)
		_check(_game.settings.menu_background_mode == "custom" and picker._buttons.has(selected_id) and picker._buttons[selected_id].button_pressed, "导入后自动选择新增背景 %d" % index)
		var active_button: Button = picker._buttons[selected_id]
		_check(picker._custom_scroll.get_global_rect().grow(1).encloses(active_button.get_global_rect()), "新增背景沿原排自动滚入可视区域 %d" % index)
		_check_single_row(picker, "导入背景 %d" % index)
	var bar := picker._custom_scroll.get_h_scroll_bar()
	_check(bar.is_visible_in_tree() and bar.max_value > bar.page, "内置与自定义选项整排溢出时提供横向滚动条")
	_check(picker.size.y <= initial_height + bar.size.y + 1.0, "新增背景仅增加横条高度，不另起第二排")
	picker._custom_scroll.scroll_horizontal = 0
	await _settle()
	var before := picker._custom_scroll.scroll_horizontal
	var default_left: float = picker._buttons["default"].global_position.x
	for unused in 8:
		await _click(picker._custom_scroll, MOUSE_BUTTON_WHEEL_RIGHT)
	_check(picker._custom_scroll.scroll_horizontal > before and picker._buttons["default"].global_position.x < default_left, "横向滚轮移动包含默认项在内的整排背景选项")
	_move_mouse(Vector2(4, 4))
	await create_timer(1.8).timeout
	_check(bar.is_visible_in_tree() and bar.modulate.a > 0.99 and bar.self_modulate.a > 0.99, "停止滚动并移开鼠标后横向滚动条仍不淡出")
	var active_button: Button = picker._buttons[_custom_ids[4]]
	picker._custom_scroll.ensure_control_visible(active_button)
	await _settle()
	await _click(active_button, MOUSE_BUTTON_RIGHT)
	_check(not picker._delete_popup.visible and _game.settings.custom_backgrounds.size() == 5, "当前使用中的自定义图右键不会出现删除菜单")
	var first_button: Button = picker._buttons[_custom_ids[0]]
	picker._custom_scroll.ensure_control_visible(first_button)
	await _settle()
	await _click(first_button)
	var remove_id := _custom_ids[1]
	var target: Button = picker._buttons[remove_id]
	picker._custom_scroll.ensure_control_visible(target)
	await _settle()
	await _click(target, MOUSE_BUTTON_RIGHT)
	if _check(picker._delete_popup.visible, "未使用的自定义图右键打开删除菜单"):
		var preview: Control = picker._previews[remove_id]
		var popup := picker._delete_popup
		# 原生弹窗会为面板阴影向左上补偿约3像素；仍应紧贴事件点击而非系统光标。
		var shadow := (popup.get_theme_stylebox("panel") as StyleBoxFlat).shadow_size
		var pointer_distance := Vector2(popup.position).distance_to(target.get_global_rect().get_center())
		_check(target.get_global_rect().has_point(Vector2(popup.position)) and pointer_distance <= Vector2.ONE.length() * shadow + 2.0, "右键删除菜单在实际点击的预览位置展开（实际%s，点击%s）" % [popup.position, target.get_global_rect().get_center()])
		_check(popup.size.x <= preview.size.x * 0.5 + 1 and popup.size.y <= preview.size.y * 0.5 + 1, "删除菜单宽高均不超过该预览图一半：菜单%s，预览%s" % [popup.size, preview.size])
		_check(popup.item_count == 1, "小弹窗仅提供删除操作")
		# 嵌入弹窗使用根视口坐标，覆盖真实点击命中与菜单关闭流程。
		await _click_position(Vector2(popup.position) + Vector2(popup.size) * 0.5, MOUSE_BUTTON_LEFT)
		_check(_game.settings.custom_backgrounds.size() == 4 and not picker._buttons.has(remove_id) and not popup.visible, "点击小菜单删除对应背景并关闭菜单")
		popup.hide()
	_check(_game.settings.menu_background_id == _custom_ids[0] and FileAccess.file_exists(_game.settings.get_menu_background_path()), "删除其他背景不改变正在使用的图片")
	_check(picker._custom_scroll.get_h_scroll_bar().is_visible_in_tree() and picker._custom_scroll.get_h_scroll_bar().max_value > picker._custom_scroll.get_h_scroll_bar().page, "删除后整排仍溢出时横条继续常显")
	_check_single_row(picker, "删除背景后")
	_check(DirAccess.open(input_directory).get_files().size() == 5, "删除图库项目不会删除玩家导入的源图片")


## 三种语言和最小窗口中先回到整排起点，检查内置选项和同排自定义内容。
func _test_layout(context: String) -> void:
	var panel := _game.code_color_panel
	var picker := panel._background_picker
	picker._custom_scroll.scroll_horizontal = 0
	await _settle()
	var group := panel.find_child("CodeColorGroup", true, false) as Control
	_check(group != null and group.get_global_rect().end.y <= picker.global_position.y, "代码区和背景组按参考图上下分开 " + context)
	_check(root.get_visible_rect().grow(1).encloses(panel._card.get_global_rect()), "设置卡片处于游戏窗口内 " + context)
	for mode: String in ["light", "dark"]:
		var preview: CodeEdit = panel._previews[mode]
		_check(preview.size.x < 134 and preview.size.y < 94 and not preview.get_v_scroll_bar().is_visible_in_tree(), "缩小代码预览同时保留完整内容 %s %s（实际尺寸%s，竖条%s，行高%d）" % [mode, context, preview.size, preview.get_v_scroll_bar().is_visible_in_tree(), preview.get_line_height()])
	for key: String in ["default", "solid", "add"]:
		var button: Button = picker._buttons[key]
		_check(button.is_visible_in_tree() and root.get_visible_rect().grow(1).encloses(button.get_global_rect()) and picker._custom_scroll.get_global_rect().grow(1).encloses(button.get_global_rect()), "整排起点完整显示内置选项及文案 " + key + " " + context)
	_check(root.get_visible_rect().grow(1).encloses(picker._custom_scroll.get_global_rect()), "完整背景选项的滚动视口留在窗口内 " + context)
	_check_single_row(picker, context)
	var selected: Button = picker._buttons[_game.settings.menu_background_id]
	_check(selected.button_pressed and selected.tooltip_text.contains("测试背景"), "语言切换保留背景选择及用户图片名称 " + context)
	await _test_delete_menu_layout(picker, context)


## 三语言都通过真实右键打开未使用图片菜单，尺寸包含原生弹窗阴影，校验后保留全部数据。
func _test_delete_menu_layout(picker: MenuBackgroundPicker, context: String) -> void:
	var selected_id: String = _game.settings.menu_background_id
	var target_id := ""
	for entry: Dictionary in _game.settings.custom_backgrounds:
		if entry.id != selected_id:
			target_id = entry.id
			break
	if not _check(not target_id.is_empty(), "存在未使用图片供删除菜单布局验证 " + context):
		return
	var target: Button = picker._buttons[target_id]
	picker._custom_scroll.ensure_control_visible(target)
	await _settle()
	await _click(target, MOUSE_BUTTON_RIGHT)
	var popup := picker._delete_popup
	_check(popup.visible and popup.atr(popup.get_item_text(0)) == _game.tr("删除"), "右键菜单显示当前语言的删除操作 " + context)
	var preview: Control = picker._previews[target_id]
	_check(popup.size.x <= preview.size.x * 0.5 + 1 and popup.size.y <= preview.size.y * 0.5 + 1 and root.get_visible_rect().grow(1).encloses(Rect2(Vector2(popup.position), Vector2(popup.size))), "删除菜单含阴影仍在半预览尺寸和窗口边界内 %s：菜单%s，预览%s" % [context, popup.size, preview.size])
	popup.hide()
	await _settle()
	_check(_game.settings.menu_background_id == selected_id and _game.settings.custom_backgrounds.size() == 4, "仅查看删除菜单保留当前选择和全部图片 " + context)


## 默认、纯色、添加按钮和导入图片共享同一个水平容器，并按追加顺序等高排列。
func _check_single_row(picker: MenuBackgroundPicker, context: String) -> void:
	var keys: Array[String] = ["default", "solid", "add"]
	for entry: Dictionary in _game.settings.custom_backgrounds:
		keys.append(entry.id)
	var first: Control = picker._buttons["default"]
	var previous: Control
	var same_row := true
	for key: String in keys:
		var button: Control = picker._buttons[key]
		same_row = same_row and button.get_parent() == first.get_parent() and picker._custom_scroll.is_ancestor_of(button)
		same_row = same_row and absf(button.global_position.y - first.global_position.y) < 1.0 and absf(button.size.y - first.size.y) < 1.0
		if previous != null:
			same_row = same_row and button.global_position.x >= previous.get_global_rect().end.x
		previous = button
	_check(same_row, "默认→纯色→添加→自定义共享同排且依次向右追加 " + context)


## 按原导航路径返回开始页，确保偏好经过真实共享设置生效。
func _return_main() -> void:
	await _click(_game._back_button)
	await _click(_game._back_button)
	_check(_game.page == GameShell.Page.MAIN, "返回操作回到主菜单")


## 从控件的实际几何中心发送鼠标按钮，右键和滚轮走相同输入路由。
func _click(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await _click_position(control.get_global_rect().get_center(), button)


## 真实鼠标按下和松开经过根视口，以覆盖按钮、容器和弹窗的输入分发。
func _click_position(point: Vector2, button: MouseButton) -> void:
	_move_mouse(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()


## 移走鼠标后确认滚动条不依赖悬停保持显示。
func _move_mouse(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


## 有界等待排版、翻译和节点释放完成，避免依赖某一渲染速度。
func _settle() -> void:
	for unused in 8:
		await process_frame


## 记录断言并提供依赖保护，测试失败后仍释放独占资源。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 递归删除只允许本次生成的独占目录，禁止访问真实用户资源目录。
func _remove_tree(path: String) -> void:
	if _temporary.is_empty() or not (path == _temporary or path.begins_with(_temporary + "/")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in directory.get_directories():
		_remove_tree(path.path_join(dirname))
	DirAccess.remove_absolute(path)


## 统一恢复引擎全局状态并返回清晰退出码，不留下测试图片或设置。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.free()
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	TranslationServer.set_locale(_original_locale)
	root.min_size = _original_minimum
	root.content_scale_size = _original_scale
	root.size = _original_size
	_remove_tree(_temporary)
	print("菜单背景界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 超时与正常结束走同一清理路径，防止异常界面挂起整个测试流程。
func _timeout() -> void:
	_check(false, "菜单背景界面回归超时。")
	_finish()
