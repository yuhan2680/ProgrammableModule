extends SceneTree
## 以真实按钮、视口输入与渲染验证书本入口和资料窗的连续开合，存储全部隔离。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""
var _capture_dir := ""


## 可选截图只来自本轮 Godot 测试窗口，不访问用户正在运行的应用。
func _initialize() -> void:
	Engine.max_fps = 120
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 覆盖两种页头、真实输入、反向动画及页面退出，最后检查共用资料窗的编辑器子类。
func _run() -> void:
	_temporary = "user://tests/command_book_motion_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	await _test_mouse_motion(_game.assembly_panel.header.book_button, "assembly")
	await _test_keyboard_and_reversal(_game.assembly_panel.header.book_button)
	await _test_resize_and_exit()
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	_check(_game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "测试装配使用真实模块规则")
	_game._confirm_assembly()
	await _settle()
	_game.workbench.set_process(false)
	var source := "main() {\n    move(0, 1)\n}\n"
	_game.workbench._code.text = source
	await _test_mouse_motion(_game.workbench.header.book_button, "program")
	_check(_game.workbench._code.text == source and _game.session.assembly.modules.size() == 1, "查阅资料不修改当前源码或装配")
	await _test_plain_anchor()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("COMMAND_BOOK_MOTION_TESTS: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 鼠标打开先翻书再展开窗口，关闭按相反顺序，真实渲染轮廓必须与圆形按钮同心。
func _test_mouse_motion(button: Button, label: String) -> void:
	var menu := _game._command_menu
	_check(button.has_method("set_book_open") and is_zero_approx(float(button.get("book_progress"))), label + "：闲置入口是合上的书")
	_check(button.get_theme_stylebox("focus") is StyleBoxEmpty and button.focus_mode == Control.FOCUS_ALL, label + "：默认不显示蓝圈且仍支持键盘聚焦")
	_check(button.size.is_equal_approx(Vector2(44, 44)), label + "：书本保持原有44像素圆形命中区域")
	button.disabled = true
	_click(button.get_global_rect().get_center())
	await process_frame
	_check(not menu.is_open() and is_zero_approx(float(button.get("book_progress"))), label + "：禁用按钮不能打开窗口或翻书")
	button.disabled = false
	await _capture(label + "_closed.png")
	await _check_ink_center(button, label + "：合书")
	_click(button.get_global_rect().get_center())
	_check(menu.is_open() and bool(button.get("book_open")), label + "：真实鼠标点击只开启一次资料窗口")
	_check(button.get_theme_stylebox("focus") is StyleBoxEmpty, label + "：鼠标聚焦不会恢复蓝色描边")
	_check(await _wait_between(button, "book_progress", 0.02, 0.96), label + "：存在真实翻页中间帧")
	_check(float(menu.get("_motion_progress")) < 0.02, label + "：书页尚未展开时窗口保持收拢")
	await _capture(label + "_book_turning.png")
	_check(await _wait_between(menu, "_motion_progress", 0.04, 0.94), label + "：窗口存在连续展开的中间帧")
	var intermediate := menu._panel.get_global_rect()
	var layout_size := menu._panel.size
	_check(float(button.get("book_progress")) > 0.98, label + "：窗口展开前书页已打开")
	await _capture(label + "_window_opening.png")
	await _wait_open(menu)
	var expanded := menu._panel.get_global_rect()
	_check(menu._panel.scale.is_equal_approx(Vector2.ONE) and menu._panel.size.is_equal_approx(layout_size), label + "：动画结束尺寸准确且不反复挤压排版")
	_check(intermediate.position.x > expanded.position.x and intermediate.end.y < expanded.end.y and intermediate.size.x < expanded.size.x, label + "：窗口从书本附近向左、向下扩大")
	_check(expanded.position.y >= button.get_global_rect().end.y and root.get_visible_rect().encloses(expanded), label + "：展开窗口避开入口并完整位于视口内")
	_check(menu.catalog.entries.size() == 27 and menu._cards.size() > 0, label + "：完整资料内容依旧可浏览")
	await _capture(label + "_window_open.png")
	await _check_ink_center(button, label + "：开书")
	_click(menu.header.back_button.get_global_rect().get_center())
	_check(not menu.is_open() and menu._overlay.visible and bool(button.get("book_open")), label + "：关闭先收回窗口，书本暂不合上")
	_check(await _wait_between(menu, "_motion_progress", 0.06, 0.94), label + "：关闭存在反向收回中间帧")
	var shrinking := menu._panel.get_global_rect()
	_check(shrinking.position.x > expanded.position.x and shrinking.end.y < expanded.end.y and menu._panel.size.is_equal_approx(layout_size), label + "：关闭沿打开的相反方向且保持稳定排版")
	await _capture(label + "_window_closing.png")
	await _wait_closed(menu, button)
	_check(not menu._overlay.visible and is_zero_approx(float(button.get("book_progress"))), label + "：窗口彻底收回后书本恢复合上")
	_check(button.get_theme_stylebox("focus") is StyleBoxEmpty, label + "：鼠标关闭后返回入口无蓝圈")
	await _capture(label + "_closed_after.png")


## 键盘操作保留可见焦点和两级 Esc，快速反向点击不能遗留浮层或吞掉下一次打开。
func _test_keyboard_and_reversal(button: Button) -> void:
	var menu := _game._command_menu
	button.grab_focus()
	_key(KEY_ENTER)
	await _wait_open(menu)
	_check(menu.is_open(), "回车仍通过原生按钮打开资料窗")
	_key(KEY_TAB)
	_check(root.gui_get_focus_owner() != null and menu._overlay.is_ancestor_of(root.gui_get_focus_owner()), "Tab 焦点留在打开的资料窗内")
	_click(menu.header.search_button.get_global_rect().get_center())
	await create_timer(0.4).timeout
	_check(menu.header.search_input.has_focus(), "动画完成后搜索仍可编辑")
	menu.header.search_input.text = "move"
	menu.header.search_input.text_changed.emit("move")
	_key(KEY_ESCAPE)
	await create_timer(0.4).timeout
	_check(menu.is_open() and not menu.header._search_open and menu.header.get_query().is_empty(), "第一次 Esc 只收起搜索")
	_key(KEY_ESCAPE)
	_check(not menu.is_open() and button.has_focus(), "第二次 Esc 关闭资料窗并归还焦点")
	await _wait_closed(menu, button)
	_check(not button.get_theme_stylebox("focus") is StyleBoxEmpty, "键盘关闭保留明确的键盘焦点提示")
	_click(button.get_global_rect().get_center())
	await process_frame
	_click(button.get_global_rect().get_center())
	_check(not menu.is_open(), "翻书尚未结束时再次点击可取消打开")
	await process_frame
	_click(button.get_global_rect().get_center())
	await _wait_open(menu)
	_check(menu.is_open() and is_equal_approx(float(button.get("book_progress")), 1), "关闭途中重新点击可重新展开，不受旧回调干扰")
	var modules := JSON.stringify(_game.session.assembly.modules)
	_click(_game.assembly_panel.header.back_button.get_global_rect().get_center())
	_check(not menu.is_open() and _game.page == GameShell.Page.ASSEMBLY, "外部导航位置点击只关闭资料窗，不穿透退出关卡")
	await _wait_closed(menu, button)
	_check(JSON.stringify(_game.session.assembly.modules) == modules, "外部点击和反向动画不修改装配")


## 动画中调整窗口和离开关卡，检查实时锚点、输入屏障与旧补间回调都能正确清理。
func _test_resize_and_exit() -> void:
	var button: Button = _game.assembly_panel.header.book_button
	var menu := _game._command_menu
	_click(button.get_global_rect().get_center())
	await _wait_between(menu, "_motion_progress", 0.02, 0.94)
	root.size = Vector2i(1000, 740)
	await _settle()
	await _wait_open(menu)
	_check(menu.is_open() and root.get_visible_rect().encloses(menu._panel.get_global_rect()), "展开途中缩小窗口后资料仍在真实视口内")
	_check(menu._panel.get_global_rect().position.y >= button.get_global_rect().end.y, "缩放后重新跟随书本锚点")
	await _capture("resized_1000.png")
	menu.close_menu()
	_game._show_level_page()
	await create_timer(0.55).timeout
	_check(not menu.is_open() and not menu._overlay.visible and _game.page == GameShell.Page.LEVELS, "收回途中离开页面会立即释放浮层，旧动画不再出现")
	root.size = Vector2i(1280, 800)
	await _settle()
	_game._enter_level(_game.catalog.levels[0])
	_game._dialogue_dialog.hide()
	await _settle()
	button = _game.assembly_panel.header.book_button
	_click(button.get_global_rect().get_center())
	await process_frame
	_game._show_level_page()
	await create_timer(0.55).timeout
	_check(not menu.is_open() and not menu._overlay.visible, "翻书途中离开页面也不会留下输入屏障")


## 地图编辑器使用普通加号入口，共用父类改动不能破坏白名单开关和立即关闭约定。
func _test_plain_anchor() -> void:
	var anchor := Button.new()
	anchor.position = Vector2(1160, 480)
	anchor.size = Vector2(44, 44)
	root.add_child(anchor)
	var menu := CommandRestrictionMenu.new()
	root.add_child(menu)
	menu.show_commands(anchor, _game.registry, PackedStringArray(["main", "move"]))
	await _settle()
	_check(menu.is_open() and menu._command_switches.has("main") and menu._command_switches.main.disabled, "普通入口继续显示必需指令且不允许禁用 main")
	menu.select_section("movement")
	await _settle()
	_check(menu._command_switches.has("move") and menu._command_switches.move.button_pressed, "管理子类仍显示实际允许的移动指令")
	menu.close_menu(false)
	_check(not menu.is_open() and not menu._overlay.visible, "编辑器管理窗口仍立即关闭，不强加书本动画")
	menu.queue_free()
	anchor.queue_free()
	await _settle()


## 对实际渲染中的深色图案求边界，排除背景和圆角按钮，防止 SVG 留白造成视觉偏心。
func _check_ink_center(button: Button, label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var rectangle := Rect2i(button.get_global_rect())
	var lower := rectangle.end
	var upper := rectangle.position
	var pixels := 0
	for y in range(rectangle.position.y, rectangle.end.y):
		for x in range(rectangle.position.x, rectangle.end.x):
			var color := image.get_pixel(x, y)
			if maxf(color.r, maxf(color.g, color.b)) < 0.42:
				lower = lower.min(Vector2i(x, y))
				upper = upper.max(Vector2i(x, y))
				pixels += 1
	var ink_center := (Vector2(lower) + Vector2(upper) + Vector2.ONE) * 0.5
	_check(pixels > 30 and ink_center.distance_to(button.get_global_rect().get_center()) <= 1.5, label + "：像素轮廓中心与按钮圆心偏差不超过1.5像素")


## 在有界真实帧内观察中途状态，避免仅检查端点或依赖固定机器帧率。
func _wait_between(object: Object, property: String, low: float, high: float) -> bool:
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		var value := float(object.get(property))
		if value > low and value < high:
			return true
		await process_frame
	return false


## 只等待资料窗自身动画结束，超时作为失败而非无限等待。
func _wait_open(menu: CommandReferenceMenu) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		if menu.is_open() and not bool(menu.get("_motion_active")) and float(menu.get("_motion_progress")) > 0.99:
			await _settle()
			return
		await process_frame
	_check(false, "资料窗应在有限时间内完成展开")


## 等待收窗与合书的完整顺序，确认不只是逻辑关闭而视觉仍然残留。
func _wait_closed(menu: CommandReferenceMenu, button: Button) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		if not menu._overlay.visible and is_zero_approx(float(button.get("book_progress"))):
			await _settle()
			return
		await process_frame
	_check(false, "资料窗和书本应在有限时间内完成收回")


## 鼠标按下与抬起都经过真实视口，能发现动画浮层的点击穿透或吞事件问题。
func _click(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)


## 原生键盘事件覆盖回车、Tab 与 Esc，不直接调用按钮信号代替交互。
func _key(key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		root.push_input(event, true)


## 等待容器布局和延后回调，不延长正在测试的开合动画。
func _settle() -> void:
	for frame in 4:
		await process_frame


## 截图保存到显式指定的测试目录，方便复核真实图标、动画与最终窗口比例。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename)) == OK, "保存真实窗口截图：" + filename)


## 汇总失败项并保留非零退出码供外部回归脚本识别。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 递归清理仅限本次独占目录，绝不触及玩家正式资料或地图。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
