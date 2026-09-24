extends SceneTree
## 通过真实设置控件验证窗口尺寸策略；用户文件始终隔离，GPU 运行额外检查原生最大化及画幅边缘。

const LABELS := {"zh_CN": "分辨率", "zh_HK": "解像度", "en": "Resolution"}
const MAX_LABELS := {"zh_CN": "最大化", "zh_HK": "最大化", "en": "Maximized"}

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _finished := false
var _original_locale := ""
var _original_volume := 0.0
var _original_mute := false


## 可选截图参数只控制证据输出，普通 headless 回归不伪造图像。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 顺序覆盖设置布局、真实输入、持久化和系统窗口；超时也报告失败并清理独占目录。
func _run() -> void:
	_temporary = "user://tests/window_resolution_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	create_timer(90.0).timeout.connect(_timeout)
	root.gui_embed_subwindows = true
	_check_area_limits()
	await _create_game()
	if DisplayServer.get_name() != "headless":
		_check(root.unresizable, "启动后禁止拖动改变窗口尺寸")
	_check(root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND, "启动使用 EXPAND 画幅避免比例黑边")
	_check(root.content_scale_size == Vector2i(1280, 800) and root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "逻辑画幅与 Canvas Items 缩放保持稳定")
	if not await _open_settings():
		await _dispose_game()
		_finish()
		return
	_check_layout()
	await _choose_resolution("1024x640", true)
	_check_fixed("1024x640")
	_check(root.get_screen_transform().get_scale().x < 1.0, "1024 窗口真实使用小于 1 的画幅缩放")
	await _capture("settings_1024x640")
	await _choose_resolution("1280x800", false)
	_check_fixed("1280x800")
	await _check_languages()
	await _check_availability()
	await _check_position_preserved()
	await _choose_resolution("1024x640", true)
	var stored := GameSettings.new(_game.settings_path)
	_check(stored.load_settings().is_ok() and stored.window_resolution == "1024x640", "真实选择已经写入独立配置")
	await _dispose_game()
	await _create_game()
	_check(_game.settings.window_resolution == "1024x640", "重建游戏从保存文件恢复窗口偏好")
	_check_fixed("1024x640")
	await _capture("main_menu_restored_1024")
	if not await _open_settings():
		await _dispose_game()
		_finish()
		return
	var restored_option := _option()
	_check(restored_option != null and restored_option.selected == GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find("1024x640"), "重建后的设置选中保存尺寸")
	if DisplayServer.get_name() != "headless":
		await _check_native_maximize()
		await _check_wide_fill()
	else:
		print("SKIP headless 无原生桌面，不检查系统最大化或 GPU 像素。")
	await _check_fast_switch()
	await _dispose_game()
	_finish()


## 纯计算明确包含相等边界，过小显示区域仍保留最大化入口。
func _check_area_limits() -> void:
	var exact := GameWindowController.resolutions_for_area(Vector2i(1280, 800))
	_check(exact.has("1280x800") and not exact.has("1440x900"), "可用区域恰好 1280×800 时包含自身且排除更大尺寸")
	_check(GameWindowController.resolutions_for_area(Vector2i(800, 600)) == PackedStringArray(["maximized"]), "小屏幕仅提供最大化")
	_check(GameWindowController.resolution_size("1024x640") == Vector2i(1024, 640), "预设值转换为准确客户区尺寸")


## 实例使用真实游戏入口，但设置、草稿和用户关卡均指向本轮临时目录。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	root.add_child(_game)
	await _settle(12)


## 真实点击开始菜单入口，不直接调用设置页构建方法。
func _open_settings() -> bool:
	var button := _game.find_child("SettingsButton", true, false) as Control
	if not _check(button != null and button.is_visible_in_tree(), "主菜单设置按钮存在且可见"):
		return false
	await _click(button)
	return _check(_game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "真实设置按钮打开设置页面")


## 分辨率必须是显示分组首行，并沿用原选项控件和分隔线布局。
func _check_layout() -> void:
	var panel := _game.settings_panel
	if not _check(panel != null, "设置面板存在"):
		return
	var row := panel.find_child("WindowResolutionRow", true, false) as Control
	var tab := panel.find_child("TabCompletionRow", true, false) as Control
	var option := _option()
	if not _check(row != null and tab != null and option != null, "分辨率行和原有 Tab 补全行存在"):
		return
	_check(row.get_parent() == tab.get_parent() and row.get_index() == 0 and row.get_global_rect().end.y < tab.global_position.y, "分辨率位于显示分组最上方")
	_check(panel.find_child("WindowResolutionDivider", true, false) != null and row.get_global_rect().encloses(option.get_global_rect()), "分辨率行具有分隔线且选项不超出行边界")
	_check(option.item_count == GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.size(), "选项数量与模型允许值一致")
	_check(option.get_item_text(2) == "1280 × 800" and option.get_theme_icon("arrow").resource_path.ends_with("settings_language_toggle.svg"), "尺寸文字和箭头沿用设置样式")


## 当前设置页面只读取原生选项，不缓存跨页面已销毁控件。
func _option() -> OptionButton:
	return _game.settings_panel.find_child("WindowResolutionOption", true, false) as OptionButton if _game.settings_panel != null else null


## 鼠标或空格打开真实 PopupMenu，再由方向键和回车提交选择，不直接发射选择信号。
func _choose_resolution(value: String, mouse_open: bool) -> void:
	var option := _option()
	if not _check(option != null, "分辨率选择器可达 " + value):
		return
	var index := GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.find(value)
	if not _check(index >= 0 and not option.is_item_disabled(index), "目标尺寸可选择 " + value):
		return
	if mouse_open:
		await _click(option)
	else:
		option.grab_focus()
		await _key(root, KEY_SPACE)
	var popup := option.get_popup()
	# 原生弹层的窗口焦点和首次鼠标进入可能迟于 visible，待稳定后再发方向键。
	await _settle(8)
	if not _check(popup.visible, "真实输入打开分辨率菜单 " + value):
		return
	for attempt in option.item_count * 2:
		var current := popup.get_focused_item()
		if current == index:
			break
		# 按目标方向直接移动，不依赖 PopupMenu 在最后一项后循环回首项。
		await _key(root, KEY_UP if current > index else KEY_DOWN)
		var focused := popup.get_focused_item()
		_check(focused < 0 or not option.is_item_disabled(focused), "方向键跳过不可用尺寸 " + value)
	if not _check(popup.get_focused_item() == index, "方向键聚焦目标尺寸 " + value):
		popup.hide()
		return
	await _key(root, KEY_ENTER)
	await _settle(12)
	_check(_game.settings.window_resolution == value and not popup.visible, "回车选择立即保存并关闭菜单 " + value)
	_check(option.selected == index, "原生选项与模型保持同步 " + value)


## 固定尺寸验证客户区、模式及缩放限制，避免只检查设置文本而遗漏系统窗口。
func _check_fixed(value: String) -> void:
	if DisplayServer.get_name() != "headless":
		_check(root.mode == Window.MODE_WINDOWED, "预设尺寸使用普通窗口 " + value)
	_check(root.size == GameWindowController.resolution_size(value), "客户区尺寸准确 " + value + " actual=" + str(root.size))
	if DisplayServer.get_name() != "headless":
		_check(root.unresizable, "预设尺寸禁止任意拖动缩放 " + value)
	_check_fill_geometry(value)


## 画幅比例必须跟随客户区扩展，不能继续保持会产生黑边的固定比例可见区域。
func _check_fill_geometry(context: String) -> void:
	var visible_size := root.get_visible_rect().size
	var ratio := float(root.size.x) / root.size.y
	_check(absf(visible_size.x / visible_size.y - ratio) < 0.015, "逻辑可见区域覆盖客户区比例 " + context)
	_check(_game.get_global_rect().grow(1).encloses(root.get_visible_rect()), "游戏根控件铺满可见区域 " + context)


## 切换三种语言即时刷新标签与最大化文本，数值选项不参加语言改写。
func _check_languages() -> void:
	for locale: String in LABELS:
		_game.settings.set_language(locale)
		await _settle()
		var option := _option()
		var label := _game.settings_panel.find_child("WindowResolutionLabel", true, false) as Label
		_check(label.atr(label.text) == LABELS[locale], "分辨率标签按当前语言显示 " + locale)
		_check(option.atr(option.get_item_text(option.item_count - 1)) == MAX_LABELS[locale], "最大化选项按当前语言显示 " + locale)
		_check(option.get_item_text(0) == "1024 × 640" and option.selected == 2, "切换语言保留尺寸及当前选择 " + locale)
		await _capture("settings_1280x800_" + locale)
	_game.settings.set_language("zh_CN")
	await _settle()


## 模拟外层显示器能力通知，检查禁用与恢复，不从设置 UI 修改系统窗口。
func _check_availability() -> void:
	var panel := _game.settings_panel
	var available := PackedStringArray(["1024x640", "1280x800", "maximized"])
	panel.set_available_window_resolutions(available)
	for index in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.size():
		var value: String = GameSettings.SUPPORTED_WINDOW_RESOLUTIONS[index]
		_check(_option().is_item_disabled(index) == not available.has(value), "屏幕能力禁用状态准确 " + value)
	await _choose_resolution("1024x640", true)
	await _choose_resolution("1280x800", false)
	panel.set_available_window_resolutions(_game.window_controller.available_resolutions)
	for index in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS.size():
		_check(_option().is_item_disabled(index) == not _game.window_controller.available_resolutions.has(GameSettings.SUPPORTED_WINDOW_RESOLUTIONS[index]), "恢复真实屏幕可用列表 " + str(index))


## 音量、语言和装配显示偏好不应重新居中或修改用户已经移动的窗口。
func _check_position_preserved() -> void:
	root.position += Vector2i(11, 7)
	await _settle()
	var before_position := root.position
	var before_size := root.size
	_game.settings.set_volume(0.37)
	_game.settings.set_tab_completion(false)
	_game.settings.set_assembly_free_zoom(true)
	_game.settings.set_language("en")
	await _settle(12)
	_check(root.position == before_position and root.size == before_size, "其他设置变化保留用户窗口位置与尺寸")
	_check(_game.settings.window_resolution == "1280x800", "其他偏好不更改分辨率")
	_game.settings.set_language("zh_CN")


## GPU 运行才检验操作系统最大化，随后通过同一菜单恢复固定窗口。
func _check_native_maximize() -> void:
	await _choose_resolution("maximized", true)
	await create_timer(0.6).timeout
	await _settle(8)
	_check(root.mode == Window.MODE_MAXIMIZED, "原生窗口实际进入最大化")
	_check(root.unresizable and _game.settings.window_resolution == "maximized", "最大化提交后恢复拖动限制")
	_check_fill_geometry("native_maximized")
	await _capture("settings_native_maximized")
	await _choose_resolution("1024x640", false)
	_check_fixed("1024x640")


## 模拟系统恢复出宽屏客户区，检查 EXPAND 真实渲染；该尺寸仅是测试注入，不是玩家可选项。
func _check_wide_fill() -> void:
	_game.settings.set_menu_background("solid")
	_game._show_main_page()
	var usable := DisplayServer.screen_get_usable_rect(root.current_screen).size
	var width := mini(1600, usable.x - 64)
	root.size = Vector2i(width, width / 2)
	await _settle(12)
	_check(root.unresizable, "宽屏测试没有解除玩家窗口尺寸限制")
	_check_fill_geometry("wide_2_to_1")
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	_check(screenshot != null and not screenshot.is_empty(), "GPU 提供真实宽屏图像")
	if screenshot != null and not screenshot.is_empty():
		for point: Vector2i in [Vector2i(2, screenshot.get_height() / 2), Vector2i(screenshot.get_width() - 3, screenshot.get_height() / 2), Vector2i(screenshot.get_width() / 2, 2), Vector2i(screenshot.get_width() / 2, screenshot.get_height() - 3)]:
			var pixel := screenshot.get_pixelv(point)
			var target := GameTheme.BACKGROUND
			_check(Vector3(pixel.r - target.r, pixel.g - target.g, pixel.b - target.b).length() < 0.06, "宽屏真实图像边缘为页面底色而非黑边 " + str(point))
	await _capture("main_menu_wide_solid")
	_game.settings.set_menu_background("default")
	await _settle(30)
	await _capture("main_menu_wide_background")
	_game.settings.set_window_resolution("1280x800")
	await _settle(12)
	await _open_settings()


## 同一帧最大化后立即改选固定尺寸，旧延迟回调不得覆盖新窗口状态。
func _check_fast_switch() -> void:
	_game.settings.set_window_resolution("maximized")
	_game.settings.set_window_resolution("1024x640")
	await _settle(20)
	_check(_game.settings.window_resolution == "1024x640", "快速切换最终模型保留最后选择")
	_check_fixed("1024x640")


## Canvas 变换给出逻辑视口命中点；push_input(true) 不能再次逆用根窗口的物理缩放。
func _click(control: Control) -> void:
	if not _check(control != null, "真实点击目标存在"):
		return
	var point := control.get_global_transform_with_canvas() * (control.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	await _settle()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()


## 原生弹窗由根视口路由键盘事件；完整按下与释放验证真实选择生命周期。
func _key(viewport: Viewport, keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		viewport.push_input(event, true)
	await _settle()


## 等待容器、系统窗口和延迟回调完成；不使用虚构布局作为输入依据。
func _settle(frames: int = 4) -> void:
	for frame in frames:
		await process_frame


## 只保存真实 GPU 画面，目录由测试调用者显式指定。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(screenshot.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存截图 " + filename)


## 重建前完整释放旧游戏及窗口控制器，避免两份设置订阅竞争同一个窗口。
func _dispose_game() -> void:
	if is_instance_valid(_game):
		_game.queue_free()
	await _settle()
	_game = null


## 累计检查并给出具体失败原因，最终统一退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 超时不是成功，仍输出标准结束标记并尝试清理测试文件。
func _timeout() -> void:
	if _finished:
		return
	_check(false, "窗口分辨率界面回归超过 90 秒")
	await _dispose_game()
	_finish()


## 恢复进程全局语言及音量，清除独占临时目录，并输出可核对的总数。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	TranslationServer.set_locale(_original_locale)
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	_remove_tree(_temporary)
	print("窗口分辨率界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 删除范围只限本轮唯一测试目录，绝不清理玩家目录或其他运行的测试。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
