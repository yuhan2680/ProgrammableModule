extends SceneTree
## 通过真实悬停、点击和键盘事件验证原生提示生命周期与玻璃绘制层。

var _checks := 0
var _failures := 0
var _glass: CanvasLayer


## 延迟到场景树允许添加节点后启动测试。
func _initialize() -> void:
	_run.call_deferred()


## 测试独占目录隔离设置和草稿，沿实际装配与编程页面检查悬停行为。
func _run() -> void:
	root.size = Vector2i(1280, 800)
	root.gui_embed_subwindows = true
	var temporary := "user://tests/glass_tooltip_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = temporary.path_join("levels")
	game.drafts_directory = temporary.path_join("solutions")
	game.settings_path = temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	_glass = game.get_node("GlassTooltips") as CanvasLayer
	await _verify_catalog_positions(game)
	game._enter_level(game.catalog.levels[0])
	game._dialogue_dialog.hide()
	await _settle()
	var confirm := game._confirm_assembly_button
	_check(confirm.disabled and confirm.get_tooltip().contains("\n"), "空装配确认保留禁用状态及多行原因")
	await _verify_hover(confirm, "禁用确认")
	await _click(confirm)
	_check(game.page == GameShell.Page.ASSEMBLY and game.session.assembly.modules.is_empty(), "点击禁用确认不会进入编程或改变装配")
	await _cancel_hover()
	game.session.assembly.add_module("movement", Vector2.ZERO)
	game._confirm_assembly()
	await _settle()
	var workbench := game.workbench
	var source := workbench._code.text
	var session_source := game.session.source
	workbench._code.grab_focus()
	for locale: String in ["zh_CN", "en"]:
		game.settings.set_language(locale)
		await _settle()
		var header := workbench.header
		for point: Vector2 in [header.title_label.get_global_rect().get_center(), header.goal_label.get_global_rect().get_center(), header.get_global_rect().position + Vector2(96, 22)]:
			await _hover(point)
			_check(_native_tooltip(root) == null and not _glass.visible, "标题、目标和页头空白均无提示 " + locale)
		await _verify_hover(header.book_button, "书本 " + locale)
		_check(workbench._code.has_focus(), "悬停书本不会夺走代码焦点 " + locale)
		await _cancel_hover()
		await _verify_hover(workbench._guide_button, "指引 " + locale)
		_check(workbench._code.has_focus(), "悬停指引不会夺走代码焦点 " + locale)
		await _click(workbench._guide_button)
		_check(workbench._guide_menu.is_open() and _native_tooltip(root) == null and not _glass.visible, "点击指引仍打开原菜单并清除提示 " + locale)
		for pressed in [true, false]:
			var escape := InputEventKey.new()
			escape.keycode = KEY_ESCAPE
			escape.pressed = pressed
			root.push_input(escape)
		await _settle()
		_check(not workbench._guide_menu.is_open() and workbench._guide_button.has_focus(), "Esc 关闭指引并恢复按钮焦点 " + locale)
		workbench._code.grab_focus()
	_check(workbench._code.text == source and game.session.source == session_source, "悬停、点击、关闭和语言切换不改变玩家源程序")
	await _verify_hover(workbench.header.book_button, "销毁前提示")
	game.queue_free()
	await _settle()
	_check(_native_tooltip(root) == null, "销毁页面树后不残留原生提示")
	_remove_temporary(temporary)
	print("玻璃提示回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 从原生提示读取实际翻译与几何，避免直接调用玻璃层方法制造通过结果。
func _verify_hover(control: Control, message: String) -> void:
	await _hover(control.get_global_rect().get_center())
	var popup := _native_tooltip(root)
	_check(popup != null and popup.is_embedded() and _glass.visible, "原生悬停显示嵌入提示及玻璃层：" + message)
	if popup == null or not _glass.visible:
		return
	var native_label: Label
	for child in popup.get_children(true):
		if child is Label and child.theme_type_variation == &"TooltipLabel":
			native_label = child
	var label := _glass.find_child("GlassTooltipText", true, false) as Label
	_check(native_label != null and label != null, "原生标签和玻璃文字同时存在：" + message)
	if native_label == null or label == null:
		return
	_check(label.text == native_label.atr(native_label.text) and label.text == control.atr(control.get_tooltip()), "玻璃逐字保留原生本土化提示：" + message)
	var color := label.get_theme_color("font_color")
	_check(maxf(color.r, maxf(color.g, color.b)) < 0.25 and color.a == 1.0, "提示文字使用不透明黑色：" + message)
	_check(label.size.is_equal_approx(native_label.size) and label.size.y + 1 >= label.get_minimum_size().y, "提示沿用原生尺寸且多行文字不裁切：" + message)
	var popup_to_root := root.get_screen_transform().affine_inverse() * popup.get_screen_transform()
	var original_size := native_label.size * popup_to_root.get_scale().abs()
	var visible_size := label.get_global_rect().size
	_check(visible_size.is_equal_approx(original_size * 0.7), "单行、多行及中英提示的实际显示宽高统一缩至原来的七成：" + message)
	var surface := _glass.find_child("TooltipGlassSurface", true, false) as ColorRect
	_check(surface != null, "提示保留独立毛玻璃背景：" + message)
	if surface != null:
		_check(surface.get_global_transform().get_scale().is_equal_approx(label.get_global_transform().get_scale()), "背景、圆角、阴影与文字同步缩小，不留下原尺寸外框：" + message)
	_check(label.mouse_filter == Control.MOUSE_FILTER_IGNORE and label.focus_mode == Control.FOCUS_NONE, "提示文字不接管鼠标或焦点：" + message)
	_verify_position(popup, label, control.get_global_rect().get_center(), message)


## 复现右侧第七关长提示，并以同一页面覆盖窗口拉伸和中英文长度变化。
func _verify_catalog_positions(game: GameShell) -> void:
	var original_size := root.size
	var original_content_size := root.content_scale_size
	var original_scale_mode := root.content_scale_mode
	var original_language := game.settings.language
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(2560, 1600), Vector2i(1000, 740)]:
		await _cancel_hover()
		root.content_scale_size = Vector2i(1280, 800) if dimensions.x > 1000 else dimensions
		root.size = dimensions
		for locale: String in ["zh_CN", "en"]:
			game.settings.set_language(locale)
			game._show_level_page()
			await _settle()
			var seventh := game.find_child("LevelButton_6", true, false) as Button
			_check(seventh != null and seventh.is_visible_in_tree(), "默认七列中的第七关可真实悬停 " + locale + " " + str(dimensions))
			if seventh == null:
				continue
			await _verify_hover(seventh, "右侧第七关 " + locale + " " + str(dimensions))
			if dimensions == Vector2i(2560, 1600):
				_check(root.get_screen_transform().get_scale().x > 1.5, "高分辨率用例实际采用放大的屏幕变换 " + locale)
				await _verify_corners(game, seventh.get_tooltip(), locale)
	await _cancel_hover()
	root.content_scale_size = original_content_size
	root.content_scale_mode = original_scale_mode
	root.size = original_size
	game.settings.set_language(original_language)
	await _settle()


## 角落按钮只提供真实命中区与同一长文案，提示仍由引擎延时生成，不能手工定位。
func _verify_corners(game: GameShell, tooltip: String, locale: String) -> void:
	var probe := Button.new()
	probe.name = "TooltipCornerProbe"
	probe.tooltip_text = tooltip
	probe.size = Vector2(32, 32)
	game.add_child(probe)
	var bounds := root.get_visible_rect()
	for point: Vector2 in [bounds.position + Vector2(18, 18), bounds.end - Vector2(18, 18)]:
		probe.global_position = point - probe.size * 0.5
		await _settle()
		await _verify_hover(probe, "拉伸窗口角落 " + locale + " " + str(point))
	await _cancel_hover()
	probe.queue_free()
	await _settle()


## 根据实际玻璃绘制变换检查可见卡片，不依赖定位函数内部算法或原生窗口原点。
func _verify_position(popup: PopupPanel, label: Label, pointer: Vector2, message: String) -> void:
	var native_panel: Panel
	for child in popup.get_children(true):
		if child is Panel:
			native_panel = child
	_check(native_panel != null, "可读取提示的真实卡片范围：" + message)
	if native_panel == null:
		return
	var visual_root := label.get_parent() as Control
	var card := visual_root.get_global_transform() * native_panel.get_rect()
	var bounds := root.get_visible_rect()
	_check(bounds.grow(1.0).encloses(card), "缩小后的卡片完整位于可见视口：%s，卡片 %s，视口 %s" % [message, card, bounds])
	var nearest := Vector2(clampf(pointer.x, card.position.x, card.end.x), clampf(pointer.y, card.position.y, card.end.y))
	_check(pointer.distance_to(nearest) <= 24.0, "悬浮卡片始终贴近实际鼠标：%s，鼠标 %s，卡片 %s" % [message, pointer, card])
	_check(not card.has_point(pointer), "卡片避开鼠标当前位置：" + message)
	if pointer.x + card.size.x + 24.0 > bounds.end.x:
		_check(card.end.x <= pointer.x, "右侧空间不足时紧邻鼠标向左展开：" + message)
	if pointer.y + card.size.y + 24.0 > bounds.end.y:
		_check(card.end.y <= pointer.y, "下方空间不足时紧邻鼠标向上展开：" + message)


## 先离开旧控件，再等待项目原生延时，禁止以手动创建窗口代替悬停。
func _hover(point: Vector2) -> void:
	await _cancel_hover()
	_motion(point)
	await create_timer(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec", 0.5)) + 0.1).timeout
	await _settle()


## 真实鼠标移出必须取消原生提示并隐藏玻璃，不能留下透明输入窗口。
func _cancel_hover() -> void:
	var bounds := root.get_visible_rect()
	_motion(Vector2(bounds.position.x + 2, bounds.end.y - 2))
	await _settle()
	_check(_native_tooltip(root) == null and not _glass.visible, "鼠标移出后提示与玻璃共同清除")


## 用视口局部坐标注入鼠标移动，走引擎原生 GUI 命中与提示计时器。
func _motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


## 鼠标按下与释放均交给视口，以覆盖提示存在时的真实按钮输入。
func _click(control: Control) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = control.get_global_rect().get_center()
		event.global_position = event.position
		root.push_input(event, true)
	await _settle()


## 搜索包含内部节点的真实窗口树，只识别当前可见的原生 TooltipPanel。
func _native_tooltip(node: Node) -> PopupPanel:
	if node is PopupPanel and node.visible and node.theme_type_variation == &"TooltipPanel":
		return node
	for child in node.get_children(true):
		var found := _native_tooltip(child)
		if found != null:
			return found
	return null


## 等待延迟布局、提示同步和节点销毁完成。
func _settle() -> void:
	await process_frame
	await process_frame


## 汇总检查并使失败影响退出码。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只清理本次独占的测试目录，不访问正式玩家数据。
func _remove_temporary(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_temporary(path.path_join(child))
	DirAccess.remove_absolute(path)
