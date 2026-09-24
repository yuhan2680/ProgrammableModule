extends SceneTree
## 真实设置路由验证配色子页、只读缩略图、重入选择及中英文窗口布局。

const PLAYER_SOURCE := "// 玩家作品必须保留\nmain() {\n    move(0, 4)\n}\n"

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _finished := false
var _original_locale := ""
var _original_size := Vector2i.ZERO
var _original_scale_size := Vector2i.ZERO
var _original_min_size := Vector2i.ZERO
var _original_db := 0.0
var _original_mute := false


## 等待场景树就绪后创建实际游戏界面，不提前访问正式玩家数据。
func _initialize() -> void:
	_run.call_deferred()


## 在独立存档中完成点击、返回、重启和布局检查，并保留全局显示与音量状态。
func _run() -> void:
	_temporary = "user://tests/code_color_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	_original_size = root.size
	_original_scale_size = root.content_scale_size
	_original_min_size = root.min_size
	var master := AudioServer.get_bus_index("Master")
	_original_db = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	create_timer(40.0).timeout.connect(_timeout)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _create_game()
	_check(_game.settings.code_color_mode == "light", "新用户通过真实Shell载入默认浅色")
	_check(_game.settings.storage_path.begins_with(_temporary + "/") and _game.drafts.directory.begins_with(_temporary + "/") and _game.catalog.user_directory.begins_with(_temporary + "/"), "设置、草稿和导入目录全部注入本次独占测试路径")
	_check(_game.drafts.save_draft("color_ui_saved_work", PLAYER_SOURCE, []).is_ok() and _game.drafts.mark_completed("color_ui_saved_work").is_ok(), "在测试目录准备已有玩家代码和通关记录")
	var saved_work := _snapshot_files(_game.drafts.directory)
	if await _open_colors_from_main():
		await _test_default_previews_and_click()
		await _click(_game._back_button)
		_check(_game.page == GameShell.Page.SETTINGS and _game.code_color_panel == null, "颜色子页返回药丸回到设置并释放旧面板")
		if await _open_colors_from_settings():
			_check(_game.code_color_panel._buttons["dark"].button_pressed and not _game.code_color_panel._buttons["light"].button_pressed, "返回后重入子页恢复深色单选标记")
			await _click(_game._back_button)
		await _click(_game._back_button)
		_check(_game.page == GameShell.Page.MAIN, "设置页返回药丸继续回到主菜单")
	_game.queue_free()
	await _settle()
	await _create_game()
	_check(_game.settings.code_color_mode == "dark", "重新创建Shell后从独立配置恢复已点击的深色选择")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			if await _open_colors_from_main():
				_test_color_layout(locale + " " + str(dimensions))
				await _click(_game._back_button)
				await _click(_game._back_button)
	await _test_failed_save_retry()
	await _test_scrollbar_fade()
	_check(_snapshot_files(_game.drafts.directory) == saved_work, "浏览、选择、重入和语言切换都逐字节保留已有玩家代码与进度")
	var restored := _game.drafts.load_draft("color_ui_saved_work")
	_check(restored.is_ok() and restored.value != null and restored.value.source == PLAYER_SOURCE and _game.drafts.is_completed("color_ui_saved_work"), "配色页面不会把缩略示例写入玩家作品或清除通关状态")
	_finish()


## 每次实例化前注入全部可写路径，重启检查复用同一测试配置。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()


## 点击真正的主菜单设置按钮进入设置页，再通过新增颜色行导航。
func _open_colors_from_main() -> bool:
	var settings_button := _game.find_child("SettingsButton", true, false) as Button
	if not _check(_game.page == GameShell.Page.MAIN and settings_button != null, "主菜单提供真实设置入口"):
		return false
	await _click(settings_button)
	return await _open_colors_from_settings()


## 检查颜色入口位于补全与代码提示之间，并由真实鼠标事件进入子页。
func _open_colors_from_settings() -> bool:
	if not _check(_game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "设置入口进入共享设置模型面板"):
		return false
	var panel := _game.settings_panel
	var colors := panel.find_child("CodeColorsButton", true, false) as Button
	var completion := panel.find_child("TabCompletionRow", true, false) as Control
	var hints := panel.find_child("CodeHintsRow", true, false) as Control
	if not _check(colors != null and completion != null and hints != null, "显示分组包含补全、颜色和提示三项"):
		return false
	_check(completion.get_global_rect().end.y <= colors.global_position.y and colors.get_global_rect().end.y <= hints.global_position.y, "颜色入口位于Tab补全和代码提示中间且互不重叠")
	panel._scroll.ensure_control_visible(colors)
	await _settle()
	_inside(colors, "颜色与显示入口")
	_check(colors.icon != null and colors.icon.resource_path.ends_with(".svg"), "颜色行用SVG箭头说明进入子页")
	var expected := "Color & Display" if _game.settings.language == "en" else "颜色与显示"
	_check(colors.tr(colors.text) == expected, "颜色入口按当前语言完整翻译")
	_check(colors.size.x + 1 >= colors.get_minimum_size().x, "颜色入口文字与箭头具有足够横向空间")
	await _click(colors)
	return _check(_game.page == GameShell.Page.CODE_COLORS and _game.code_color_panel != null and _game.code_color_panel.settings == _game.settings, "点击颜色行进入共享模型的颜色子页")


## 只读缩略图呈现两种背景，点击图像本身也能单选深色而不修改示例文字。
func _test_default_previews_and_click() -> void:
	var panel := _game.code_color_panel
	var light := panel._buttons["light"] as Button
	var dark := panel._buttons["dark"] as Button
	var light_preview := panel._previews["light"] as CodeEdit
	var dark_preview := panel._previews["dark"] as CodeEdit
	_check(light.button_pressed and not dark.button_pressed, "首次进入子页仅浅色预览被选中")
	_check(_background(light_preview) == Color("F5F7FB") and _background(dark_preview) == Color("121314"), "两个只读缩略图分别展示原浅色与121314深色背景")
	var light_style := light_preview.get_theme_stylebox("read_only") as StyleBoxFlat
	var dark_style := dark_preview.get_theme_stylebox("read_only") as StyleBoxFlat
	_check(light_style.shadow_size > dark_style.shadow_size and light_style.border_color != dark_style.border_color, "选中状态由缩略图边缘高亮与阴影清楚区分")
	for preview: CodeEdit in [light_preview, dark_preview]:
		_check(not preview.editable and preview.focus_mode == Control.FOCUS_NONE and not preview.context_menu_enabled, "缩略代码不可编辑、不可聚焦且没有编辑菜单")
		_check(not preview.text.contains("玩家作品") and preview.text == light_preview.text, "两个缩略图使用相同展示样例且不读取已保存玩家代码")
		_check(not preview.get_v_scroll_bar().is_visible_in_tree() and not preview.get_h_scroll_bar().is_visible_in_tree(), "缩略代码不出现内部横向或纵向滚动条")
		var surface := preview.get_theme_stylebox("read_only")
		var text_height := preview.size.y - surface.get_margin(SIDE_TOP) - surface.get_margin(SIDE_BOTTOM)
		_check(preview.get_line_count() == 6 and preview.scroll_vertical == 0 and preview.get_line_height() * 6 <= text_height, "按真实字体行高完整显示第六行且无需内部滚动")
	var before_light := light_preview.text
	var before_dark := dark_preview.text
	await _click(light_preview)
	await _type_character()
	_check(light_preview.text == before_light and dark_preview.text == before_dark and not light_preview.has_focus() and not dark_preview.has_focus(), "点击缩略图后键入字符不会编辑任一预览")
	await _click(dark_preview)
	_check(panel.settings.code_color_mode == "dark" and dark.button_pressed and not light.button_pressed, "点击深色缩略图本身立即切换唯一选中项")
	_check(_background(dark_preview) == Color("121314") and _background(light_preview) == Color("F5F7FB"), "选中变化保留两张缩略图各自的模式背景")
	light_style = light_preview.get_theme_stylebox("read_only") as StyleBoxFlat
	dark_style = dark_preview.get_theme_stylebox("read_only") as StyleBoxFlat
	_check(dark_style.shadow_size > light_style.shadow_size, "深色选择把高亮阴影从浅色移至深色缩略图")


## 用真实阻挡文件制造保存失败，恢复目录后点击同一已选模式即可重试并清除错误。
func _test_failed_save_retry() -> void:
	if not await _open_colors_from_main():
		return
	var panel := _game.code_color_panel
	var light_preview := panel._previews["light"] as CodeEdit
	var dark_preview := panel._previews["dark"] as CodeEdit
	await _click(light_preview)
	_check(panel.settings.code_color_mode == "light" and panel.settings.last_error.is_empty(), "重试场景先通过真实点击成功保存浅色")
	var blocker := _temporary.path_join("retry_blocked")
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	if not _check(file != null, "在测试目录创建普通文件以阻挡设置父目录"):
		return
	file.store_string("重试测试的目录占位文件")
	file.close()
	var original_path := panel.settings.storage_path
	var retry_path := blocker.path_join("settings.json")
	panel.settings.storage_path = retry_path
	await _click(dark_preview)
	_check(panel.settings.code_color_mode == "dark" and panel._buttons["dark"].button_pressed and not panel.settings.last_error.is_empty(), "真实写盘失败仍即时选中深色并记录失败")
	_check(panel._status.is_visible_in_tree() and panel._status.text.contains(panel.tr("设置错误")), "配色页面可见地显示本次保存错误")
	_check(not FileAccess.file_exists(retry_path) and FileAccess.get_file_as_string(blocker) == "重试测试的目录占位文件", "失败未创建目标设置且保留阻挡文件")
	var removed := DirAccess.remove_absolute(blocker)
	var created := DirAccess.make_dir_recursive_absolute(blocker) if removed == OK else removed
	if _check(removed == OK and created == OK, "移除普通文件并恢复可写设置目录"):
		# 内存已经是 dark；这次点击必须重试持久化，不能因为选择未变而直接返回。
		await _click(dark_preview)
		_check(panel.settings.code_color_mode == "dark" and panel._buttons["dark"].button_pressed and panel.settings.last_error.is_empty(), "点击同一深色选项成功重试且保持唯一选择")
		_check(not panel._status.visible and panel._status.text.is_empty(), "成功重试后错误文本与错误区域同时收起")
		var saved := DataValidation.read_json_object(retry_path)
		_check(saved.is_ok() and saved.value.get("interface", {}).get("code_color_mode") == "dark", "同一选项重试已把深色值写入实际配置文件")
	panel.settings.storage_path = original_path
	_check(panel.settings.save_settings().is_ok(), "重试完成后恢复本次Shell原有的独立配置目标")
	await _click(_game._back_button)
	await _click(_game._back_button)


## 两页共用原生滚动条淡出，真实滚动仍生效，透明度变化不挤压卡片或右侧留白。
func _test_scrollbar_fade() -> void:
	for colors_page in [false, true]:
		if colors_page:
			_game._show_code_colors_page()
		else:
			_game._show_settings_page()
		await _settle()
		var scroll := _game.code_color_panel._scroll if colors_page else _game.settings_panel._scroll
		var column := _game.code_color_panel._column if colors_page else _game.settings_panel._column
		var card := _game.code_color_panel._card if colors_page else _game.settings_panel._card
		var bar := scroll.get_v_scroll_bar()
		var controller := scroll.get_node_or_null("SettingsScrollFade")
		var context := "颜色子页" if colors_page else "设置页"
		_check(controller is SettingsScrollFade and bar.modulate.a == 0.0, "首次打开默认不显示滚动条 " + context)
		# 扩展测试内容制造真实溢出，也覆盖通常无需滚动的颜色子页。
		column.custom_minimum_size.y = scroll.size.y * 2.0
		await _settle()
		_check(bar.is_visible_in_tree() and bar.max_value > bar.page and bar.modulate.a == 0.0, "内容溢出仍保留透明原生滚动条占位 " + context)
		var initial_card := card.get_global_rect()
		var initial_scroll := scroll.get_global_rect()
		var initial_width := column.size.x
		var initial_left := column.global_position.x
		var initial_bar := bar.get_global_rect()
		_check(bar.global_position.x - column.get_global_rect().end.x >= 23.0, "滚动条与内容之间保留24像素右侧间距 " + context)
		_move_mouse(bar.get_global_rect().get_center())
		await _settle()
		_check(bar.modulate.a == 0.0, "单纯悬停滚动条不会让它显示 " + context)
		var before := bar.value
		_send_wheel(scroll)
		await _settle()
		_check(bar.value > before and bar.modulate.a > 0.98, "滚轮真实移动内容并立即显示滚动条 " + context)
		await create_timer(1.2).timeout
		_check(bar.modulate.a < 0.02 and bar.is_visible_in_tree(), "停止滚动后自动淡出且不移除原生占位 " + context)
		if not colors_page:
			await _test_scroll_inputs(scroll)
		_check(card.get_global_rect() == initial_card and scroll.get_global_rect() == initial_scroll and bar.get_global_rect() == initial_bar and is_equal_approx(column.size.x, initial_width) and is_equal_approx(column.global_position.x, initial_left), "显示与淡出前后卡片、内容宽度和滚动条位置完全稳定 " + context)
		_send_wheel(scroll)
		await _settle()
		_game._show_main_page()
		await create_timer(1.2).timeout
		_check(not is_instance_valid(controller) and _game.page == GameShell.Page.MAIN, "滚动条显示期间关闭页面会安全释放淡出控制器 " + context)


## 原生触控板、键盘和拖动均能滚动；按住滑块超过隐藏时间仍可见，条外松手后正常淡出。
func _test_scroll_inputs(scroll: ScrollContainer) -> void:
	var bar := scroll.get_v_scroll_bar()
	var before := bar.value
	var pan := InputEventPanGesture.new()
	pan.position = _scroll_point(scroll)
	pan.delta = Vector2(0, 2)
	root.push_input(pan)
	await _settle()
	_check(bar.value > before and bar.modulate.a > 0.98, "触控板平移手势真实滚动并显示滚动条")
	# 原生条默认只允许辅助功能聚焦；测试临时启用焦点验证键盘路径，不改变产品的 Tab 顺序。
	var original_focus := bar.focus_mode
	bar.focus_mode = Control.FOCUS_ALL
	bar.grab_focus()
	_check(bar.has_focus(), "键盘夹具让真实原生滚动条取得焦点")
	before = bar.value
	var key := InputEventKey.new()
	# 原生条的默认步长可能为零；End 使用真实边界滚动，不依赖步长设置。
	key.keycode = KEY_END
	key.pressed = true
	root.push_input(key)
	key = key.duplicate()
	key.pressed = false
	root.push_input(key)
	await _settle()
	_check(bar.value > before and bar.modulate.a > 0.98, "原生滚动条键盘操作真实移动内容并保持显示")
	bar.release_focus()
	bar.focus_mode = original_focus
	scroll.scroll_vertical = 0
	await _settle()
	var start := bar.global_position + Vector2(bar.size.x * 0.5, bar.size.y * 0.15)
	var finish := start + Vector2(0, bar.size.y * 0.2)
	_send_left_button(start, true)
	_move_mouse(finish, MOUSE_BUTTON_MASK_LEFT, finish - start)
	await _settle()
	_check(bar.value > 0, "鼠标拖动原生滑块真实移动内容")
	await create_timer(1.2).timeout
	_check(bar.modulate.a > 0.98, "按住拖动超过停顿与淡出时间仍保持可见")
	_send_left_button(Vector2(4, 4), false)
	await _settle()
	_check(bar.modulate.a > 0.98, "滚动条外松手后先保持短暂停顿")
	await create_timer(1.2).timeout
	_check(bar.modulate.a < 0.02, "拖动结束且无后续操作时自动淡出")


## 选择原生条左侧的保留间距作为滚动位置，避免误操作音量或选择器。
func _scroll_point(scroll: ScrollContainer) -> Vector2:
	return Vector2(scroll.get_v_scroll_bar().global_position.x - 12, scroll.get_global_rect().get_center().y)


## 发送真实向下滚轮事件，事件仍交给原生容器执行滚动。
func _send_wheel(scroll: ScrollContainer) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_DOWN
	event.position = _scroll_point(scroll)
	event.global_position = event.position
	event.factor = 1.0
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)


## 鼠标移动与按钮掩码共同驱动原生滑块拖动，悬停时不携带按键状态。
func _move_mouse(position: Vector2, buttons: MouseButtonMask = 0, relative: Vector2 = Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.button_mask = buttons
	root.push_input(event)


## 将鼠标按下和释放分开发送，以便检查持续按住期间以及移出条外松手的表现。
func _send_left_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)


## 在真实逻辑窗口尺寸中检查可见范围、标题分组关系及两张卡片文字没有裁切。
func _test_color_layout(context: String) -> void:
	var panel := _game.code_color_panel
	var title := panel.find_child("CodeColorTitle", true, false) as Label
	var group := panel.find_child("CodeColorGroup", true, false) as Control
	var caption := panel.find_child("CodeColorModeLabel", true, false) as Label
	var status := panel.find_child("CodeColorStatus", true, false) as Label
	if not _check(title != null and group != null and caption != null and status != null, "子页提供标题、颜色分组、选项名与反馈区 " + context):
		return
	_inside(panel._card, "颜色卡片 " + context)
	_inside(_game._back_button, "返回药丸 " + context)
	_inside(group, "颜色选项分组 " + context)
	_check(panel._scroll.get_global_rect().grow(1).encloses(group.get_global_rect()), "颜色分组完整位于滚动视口内 " + context)
	_check(title.get_global_rect().end.y <= group.global_position.y, "页面标题与颜色分组上下分离 " + context)
	_check(not status.visible, "正常保存不出现空错误栏 " + context)
	var light := panel._buttons["light"] as Button
	var dark := panel._buttons["dark"] as Button
	_check(group.get_global_rect().encloses(caption.get_global_rect()) and group.get_global_rect().encloses(light.get_global_rect()) and group.get_global_rect().encloses(dark.get_global_rect()), "标签和两张选择卡都完整位于灰色分组内 " + context)
	_check(caption.get_global_rect().end.x <= light.global_position.x and light.get_global_rect().end.x <= dark.global_position.x, "左侧文案、浅色和深色卡横向分离 " + context)
	var english := panel.settings.language == "en"
	_check(title.tr(title.text) == ("Color & Display" if english else "颜色与显示") and caption.tr(caption.text) == ("Code Editor Appearance" if english else "代码区颜色模式"), "子页标题和选项名按当前语言显示 " + context)
	_label_fits(title, context)
	_label_fits(caption, context)
	for mode: String in ["light", "dark"]:
		var button := panel._buttons[mode] as Button
		var preview := panel._previews[mode] as CodeEdit
		var labels := button.find_children("*", "Label", true, false)
		if not _check(labels.size() == 1, "每张预览具有唯一模式标签 " + mode + " " + context):
			continue
		var label := labels[0] as Label
		var expected := ("Light Mode" if mode == "light" else "Dark Mode") if english else ("浅色模式" if mode == "light" else "深色模式")
		_check(label.tr(label.text) == expected, "模式标签按当前语言显示 " + mode + " " + context)
		_check(button.get_global_rect().grow(1).encloses(preview.get_global_rect()) and button.get_global_rect().grow(1).encloses(label.get_global_rect()) and preview.get_global_rect().end.y <= label.global_position.y, "缩略代码和下方标签完整位于可点击卡片内且不重叠 " + mode + " " + context)
		_label_fits(label, context)


## 按当前字体度量检查单行宽度，换行文案则检查所有排版行都能显示。
func _label_fits(label: Label, context: String) -> void:
	_inside(label, "文字「%s」 %s" % [label.tr(label.text), context])
	_check(label.get_line_count() > 0 and label.get_visible_line_count() >= label.get_line_count(), "文案所有行均可见 " + label.text + " " + context)
	if label.autowrap_mode == TextServer.AUTOWRAP_OFF:
		var font := label.get_theme_font("font")
		var width := font.get_string_size(label.tr(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
		_check(width <= label.size.x + 1, "单行文案没有水平裁切 " + label.text + " " + context)


## 检查控件可见且完整处于逻辑窗口内，不依赖某一固定布局坐标。
func _inside(control: Control, context: String) -> void:
	_check(control.is_visible_in_tree() and control.size.x > 0 and control.size.y > 0 and root.get_visible_rect().grow(1).encloses(control.get_global_rect()), "控件完整可见：" + context)


## 读取真实只读样式背景，避免仅检查普通编辑状态而漏掉预览外观。
func _background(preview: CodeEdit) -> Color:
	return (preview.get_theme_stylebox("read_only") as StyleBoxFlat).bg_color


## 用视口鼠标按下和松开完成一次真实点击，覆盖缩略图到父按钮的事件传递。
func _click(control: Control) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = control.get_global_rect().get_center()
	event.global_position = event.position
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await _settle()


## 发送真实可打印按键，验证用户点击缩略图后无法输入玩家代码。
func _type_character() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_X
	event.unicode = 120
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await _settle()


## 有界等待容器、翻译通知和页面释放完成，不添加依赖真实时间的长等待。
func _settle() -> void:
	for unused in 8:
		await process_frame


## 只读取测试存档目录的完整文件字节，用于验证预览流程没有保存玩家作品。
func _snapshot_files(path: String) -> Dictionary:
	var snapshot := {}
	if not path.begins_with(_temporary + "/"):
		return snapshot
	var directory := DirAccess.open(path)
	if directory == null:
		return snapshot
	for filename in directory.get_files():
		snapshot[filename] = FileAccess.get_file_as_bytes(path.path_join(filename))
	return snapshot


## 记录行为断言并返回结果，使依赖缺失时能够安全跳过后续操作。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 清理只限本次独占目录，不遍历或删除真实用户设置与关卡存档。
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


## 统一释放页面、恢复引擎状态和清理测试文件，汇总后返回明确退出码。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.free()
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_db)
	AudioServer.set_bus_mute(master, _original_mute)
	TranslationServer.set_locale(_original_locale)
	root.min_size = _original_min_size
	root.content_scale_size = _original_scale_size
	root.size = _original_size
	_remove_tree(_temporary)
	print("代码颜色界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 超时也执行同一清理出口，防止界面异常留下测试存档或无限等待。
func _timeout() -> void:
	_check(false, "代码颜色界面回归超时。")
	_finish()
