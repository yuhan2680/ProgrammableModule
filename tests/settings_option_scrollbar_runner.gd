extends SceneTree
## 独立原生下拉菜单回归，不加载语言词典、不读写玩家设置或存档。

const OPTION_GLASS := preload("res://scripts/ui/settings_option_glass.gd")

var _checks := 0
var _failures := 0
var _finished := false
var _holder: Control
var _option: OptionButton
var _glass: CanvasLayer
var _selection_count := 0


## 创建隔离菜单夹具，使用原生键盘与鼠标事件验证菜单的全部输入路径。
func _initialize() -> void:
	Engine.max_fps = 120
	root.gui_embed_subwindows = true
	root.size = Vector2i(1280, 800)
	_run.call_deferred()


## 短菜单覆盖分数缩放，长菜单覆盖淡出、拖动、点击选项和关闭后再次打开。
func _run() -> void:
	create_timer(45.0).timeout.connect(_timeout)
	_make_fixture()
	await _settle(6)
	for scale_factor: float in [0.8, 0.88, 1.0, 1.25, 1.6]:
		_holder.scale = Vector2.ONE * scale_factor
		for font_size: int in [16, 32]:
			await _check_short_menu(font_size, scale_factor)
	_holder.scale = Vector2.ONE
	await _check_long_menu()
	_holder.queue_free()
	await _settle(6)
	_finish()


## 真实主题留白与主界面相同；背景使用彩色条纹，便于可选 GPU 截图观察玻璃边界。
func _make_fixture() -> void:
	var background := ColorRect.new()
	background.color = Color("e5e7eb")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	_holder = Control.new()
	_holder.position = Vector2(120, 120)
	_holder.size = Vector2(600, 550)
	root.add_child(_holder)
	var theme := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color.WHITE
	panel.set_content_margin_all(18.0)
	panel.set_corner_radius_all(23)
	theme.set_stylebox("panel", "PopupMenu", panel)
	theme.set_color("font_color", "PopupMenu", Color("242a35"))
	_holder.theme = theme
	_option = OptionButton.new()
	_option.name = "LanguageOption"
	_option.position = Vector2(100, 100)
	_option.size = Vector2(224, 40)
	_option.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_option.get_popup().auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_option.item_selected.connect(_on_selected)
	_holder.add_child(_option)
	_glass = OPTION_GLASS.new()
	_glass.option = _option
	_holder.add_child(_glass)


## 无实际溢出的三项和四项语言列表均不应显示多余滚动条，完整保留选项内容。
func _check_short_menu(font_size: int, scale_factor: float) -> void:
	var popup := _option.get_popup()
	popup.max_size = Vector2i.ZERO
	popup.add_theme_font_size_override("font_size", font_size)
	for count: int in [3, 4]:
		_option.clear()
		for label: String in ["简体中文", "繁體中文", "Español", "English"].slice(0, count):
			_option.add_item(label)
		await _open()
		var bar := _find_scroll(popup).get_v_scroll_bar()
		var context := "%s 缩放 / %d 字号 / %d 项" % [scale_factor, font_size, count]
		_check(popup.visible and _glass.visible, "原生语言弹窗正常打开 " + context)
		_check(not bar.visible, "短列表不出现滚动条 " + context + " overflow=" + str(bar.max_value - bar.page))
		_check(popup.item_count == count and popup.get_item_text(2) == "Español", "语言选项完整且不被翻译 " + context)
		await _key(KEY_ESCAPE)
		_check(not popup.visible and not _glass.visible, "短菜单 Esc 正常关闭 " + context)


## 测量真正可命中的原生滚动条，验证尺寸调整不改变原生内容范围和选择行为。
func _check_long_menu() -> void:
	var popup := _option.get_popup()
	popup.add_theme_font_size_override("font_size", 16)
	popup.max_size = Vector2i(400, 190)
	_option.clear()
	for index in 32:
		_option.add_item("Option %02d" % index, index)
	_option.set_item_disabled(1, true)
	await _open()
	var scroll := _find_scroll(popup)
	var bar := scroll.get_v_scroll_bar()
	_check(bar.visible and bar.max_value > bar.page, "真正溢出的长菜单保留原生滚动条")
	_check_geometry(popup, scroll, bar)
	var range_before := Vector2(bar.max_value, bar.page)
	await create_timer(1.1).timeout
	_check(is_zero_approx(bar.modulate.a), "闲置原生滚动条自动隐藏")
	await _key(KEY_DOWN)
	_check(popup.get_focused_item() == 2, "方向键保留跳过禁用项的原生规则")
	for index in 32:
		if popup.get_focused_item() == popup.item_count - 1:
			break
		await _key(KEY_DOWN)
	_check(popup.get_focused_item() == 31 and bar.value > 0.0 and bar.modulate.a > 0.99, "方向键推动内容滚动并显示原生条")
	_check(range_before.is_equal_approx(Vector2(bar.max_value, bar.page)), "条变短没有修改内容范围或可见页数")
	_check_geometry(popup, scroll, bar)
	await create_timer(1.1).timeout
	_check(is_zero_approx(bar.modulate.a) and popup.visible, "停止键盘滚动后隐藏滑块但保留菜单")
	var bottom_value := bar.value
	await _mouse(popup, scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_UP, true)
	await _mouse(popup, scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_UP, false)
	_check(bar.value < bottom_value and bar.modulate.a > 0.99, "原生滚轮照常滚动并恢复条的可见度")
	var selection_before := _selection_count
	var click := bar.get_global_rect().position + Vector2(bar.size.x * 0.5, 8.0)
	await _mouse(popup, click, MOUSE_BUTTON_LEFT, true)
	var helper := scroll.get_node("SettingsOptionScrollbar")
	var fade: Node = helper.get("_fade")
	_check(bool(fade.get("_dragging")) and bar.modulate.a > 0.99, "移动后的真实条区域可收到鼠标按下")
	await create_timer(1.1).timeout
	_check(bar.modulate.a > 0.99 and popup.visible, "按住原生条时不会提前淡出或选中菜单")
	await _mouse(popup, click + Vector2(-25, 30), MOUSE_BUTTON_LEFT, false)
	_check(not bool(fade.get("_dragging")) and _selection_count == selection_before, "移出滚动条松手仍清理拖动且不触发选项")
	await create_timer(1.1).timeout
	_check(is_zero_approx(bar.modulate.a), "拖动结束后原生条正常隐藏")
	await _key(KEY_ESCAPE)
	_check(not popup.visible and not _glass.visible and _selection_count == selection_before, "Esc 保留选择且同时关闭玻璃")
	await _open()
	var drag_start := bar.get_global_rect().position + Vector2(bar.size.x * 0.5, 16)
	var value_before_drag := bar.value
	await _mouse(popup, drag_start, MOUSE_BUTTON_LEFT, true)
	await _motion(popup, drag_start + Vector2(0, 55), Vector2(0, 55))
	_check(bar.value > value_before_drag + 5.0, "直接拖动新位置的原生滑块能够移动菜单内容")
	await _mouse(popup, drag_start + Vector2(-30, 55), MOUSE_BUTTON_LEFT, false)
	_check(not bool(fade.get("_dragging")) and _selection_count == selection_before, "拖动滑块不提交任何选项")
	await _key(KEY_DOWN)
	var selected := popup.get_focused_item()
	await _key(KEY_ENTER)
	_check(_option.selected == selected and _selection_count == selection_before + 1 and not popup.visible, "回车提交原生选项一次并关闭弹窗")
	await _open()
	await _mouse(popup, bar.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, true)
	popup.hide()
	await _settle()
	_check(not bool(fade.get("_dragging")) and is_zero_approx(bar.modulate.a), "关闭时清理尚未收到松手的滚动状态")
	await _mouse(popup, Vector2.ZERO, MOUSE_BUTTON_LEFT, false)
	await _open()
	for index in popup.item_count:
		if popup.get_focused_item() == 0:
			break
		await _key(KEY_UP)
	var first_item := scroll.get_global_rect().position + Vector2(32, 12)
	await _mouse(popup, first_item, MOUSE_BUTTON_LEFT, true)
	await _mouse(popup, first_item, MOUSE_BUTTON_LEFT, false)
	_check(_option.selected == 0 and _selection_count == selection_before + 2 and not popup.visible, "鼠标点击原生首项仍正常选择且只提交一次")
	await _open()
	await _mouse(popup, Vector2(-30, -30), MOUSE_BUTTON_LEFT, true)
	await _mouse(popup, Vector2(-30, -30), MOUSE_BUTTON_LEFT, false)
	_check(not popup.visible and not _glass.visible and _selection_count == selection_before + 2, "点击弹层外部照常关闭且不提交选项")
	await _open()
	_holder.hide()
	await _settle(6)
	_check(not popup.visible and not _glass.visible, "设置页面隐藏后弹层与玻璃同时关闭")
	_holder.show()
	await _open()
	root.size += Vector2i(8, 8)
	await _settle(8)
	_check(not popup.visible and not _glass.visible, "窗口调整大小不残留旧弹层")


## 检查实际原生条矩形向右贴近卡片且两端均留空；样式不依靠绘制偏移伪装。
func _check_geometry(popup: PopupMenu, scroll: ScrollContainer, bar: VScrollBar) -> void:
	var rect := bar.get_global_rect()
	_check(absf(float(popup.size.x) / popup.content_scale_factor - rect.end.x - 8.0) < 1.1, "原生条真实位置位于卡片右侧 8 像素留白 " + str(rect))
	_check(absf(bar.position.y - 6.0) < 0.1 and absf(bar.size.y - scroll.size.y + 12.0) < 0.1, "原生条上下各缩短 6 像素 " + str(bar.get_rect()))
	_check(scroll.get_global_rect().encloses(rect), "原生条真实命中矩形留在滚动容器剪裁区域内")


## 计数真实提交信号，以检查滚动操作不会误选并验证一次操作只提交一次。
func _on_selected(_index: int) -> void:
	_selection_count += 1


## 从真实按钮启动原生菜单，不直接调用内部滚动方法。
func _open() -> void:
	_option.grab_focus()
	await _key(KEY_SPACE)
	await _settle(8)


## 在根视口路由真实键盘事件，保留嵌入菜单的焦点与关闭逻辑。
func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		root.push_input(event, true)
	await _settle(2)


## 将实际条或内容坐标转换到根视口后注入，验证显示坐标与真实命中同位。
func _mouse(popup: PopupMenu, local_point: Vector2, button: MouseButton, pressed: bool) -> void:
	var point := root.get_screen_transform().affine_inverse() * popup.get_screen_transform() * local_point
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	root.push_input(event, true)
	await _settle(3)


## 按真实滑块位置拖动，不直接写入滚动值，保证条的显示和输入坐标一致。
func _motion(popup: PopupMenu, local_point: Vector2, relative: Vector2) -> void:
	var transform := root.get_screen_transform().affine_inverse() * popup.get_screen_transform()
	var event := InputEventMouseMotion.new()
	event.position = transform * local_point
	event.global_position = event.position
	event.relative = relative * transform.get_scale()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event, true)
	await _settle(3)


## 仅观察引擎创建的原生内部节点，不重建菜单或替换其输入处理。
func _find_scroll(node: Node) -> ScrollContainer:
	if node is ScrollContainer:
		return node
	for child in node.get_children(true):
		var found := _find_scroll(child)
		if found != null:
			return found
	return null


## 等待真实容器、弹窗和延迟尺寸回调完成，避免测试依赖某个布局帧。
func _settle(frames: int = 4) -> void:
	for frame in frames:
		await process_frame


## 汇总断言并保留具体失败条件，便于跨平台排查原生弹层行为。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 超时显式失败，防止失去窗口焦点时测试被误认为完成。
func _timeout() -> void:
	if not _finished:
		_check(false, "原生滚动条测试超时")
		_finish()


## 只输出该独立夹具的验证结果，不改变任何真实玩家数据。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	print("SETTINGS_OPTION_SCROLLBAR_TESTS: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
