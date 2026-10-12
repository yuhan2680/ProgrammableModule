extends SceneTree
## 真实入口转场回归：检查满屏顺序、原生内容、输入锁、中断、缩窗与 Windows 4K 字号。

var _game: GameShell
var _temporary := ""
var _checks := 0
var _failures := 0
var _capture_directory := ""
var _quit_requests := 0


## 截图只来自实际 GPU 视口，普通 headless 不产生伪造画面。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 独占设置与玩家目录，不写入真实玩家文件；结束时恢复全局语言与音量。
func _run() -> void:
	_temporary = "user://tests/menu_page_transition_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var volume := AudioServer.get_bus_volume_db(master)
	var muted := AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	root.add_child(_game)
	await _settle()
	for profile: Dictionary in [
		{"platform": "macOS", "size": Vector2i(1280, 800), "font": 100},
		{"platform": "Windows", "size": Vector2i(1920, 1080), "font": 125},
		{"platform": "Windows", "size": Vector2i(3840, 2160), "font": 200},
	]:
		_game.window_controller.platform_name = profile.platform
		_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
		_game.window_controller._refresh_screen()
		var resolution := "%dx%d" % [profile.size.x, profile.size.y]
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(resolution):
			print("SKIP 转场 GPU %s：宿主可用客户区不能容纳；4K 由 headless 验证。" % resolution)
			continue
		_game.settings.set_window_resolution(resolution)
		_game.settings.set_ui_scale(profile.font)
		_game.window_controller._on_settings_changed()
		for destination: GameShell.Page in [GameShell.Page.LEVELS, GameShell.Page.EDITOR]:
			await _check_route(destination, "%s_%s_%d_%d" % [profile.platform, resolution, profile.font, destination])
	_game.window_controller.platform_name = "Windows"
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution("1280x800")
	_game.window_controller._on_settings_changed()
	await _check_resize()
	await _check_cancel(false)
	await _check_cancel(true)
	await _check_keyboard()
	await _check_settings_unchanged()
	await _check_close()
	_game.queue_free()
	await _settle()
	AudioServer.set_bus_volume_db(master, volume)
	AudioServer.set_bus_mute(master, muted)
	TranslationServer.set_locale(locale)
	_remove_tree(_temporary)
	print("主菜单页面转场回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 两个真实按钮都必须经过扩展与揭开阶段，菜单控件保持原字号及原有几何比例。
func _check_route(destination: GameShell.Page, context: String) -> void:
	_game._show_main_page()
	await _settle()
	var card := _game._menu_card
	var original := card.get_global_rect()
	var title := _game.find_child("MainMenuTitle", true, false) as Label
	var old_title_size := title.get_global_rect().size
	var old_font_size := title.get_theme_font_size("font_size")
	await _capture(context + "_before")
	_click(_game.find_child("StartGameButton" if destination == GameShell.Page.LEVELS else "MapEditorButton", true, false) as Control)
	if not _check(_game._menu_transitioning and _game.page == GameShell.Page.MAIN and _game._menu_page_transition != null, "点击后先留在主菜单播放扩展 " + context):
		return
	var presentation := _game._menu_page_transition
	_check(presentation._surface.get_global_rect().is_equal_approx(original), "首帧表面与原白卡完全重合 " + context)
	_check(title == presentation._content.find_child("MainMenuTitle", true, false), "动画使用原有文字节点 " + context)
	var previous_area := original.get_area()
	var growing := true
	var native_content := true
	var fully_covered := false
	var faded_early := false
	var partial_fade := false
	var new_page_fade := false
	var recorded_growth := false
	var recorded_reveal := false
	var deadline := Time.get_ticks_msec() + 3000
	# 信号重复激活也必须走同一守卫，鼠标与键盘则由正常输入路径验证。
	_game._open_page_from_main(GameShell.Page.EDITOR if destination == GameShell.Page.LEVELS else GameShell.Page.LEVELS)
	_key(KEY_ESCAPE)
	_key(KEY_TAB)
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		if _game.page == GameShell.Page.MAIN:
			var bounds := presentation._surface.get_global_rect()
			growing = growing and bounds.get_area() >= previous_area - 1.0 and root.get_visible_rect().grow(1).encloses(bounds)
			previous_area = bounds.get_area()
			native_content = native_content and title.get_theme_font_size("font_size") == old_font_size and title.get_global_rect().size.is_equal_approx(old_title_size)
			partial_fade = partial_fade or (presentation._content.modulate.a > 0.0 and presentation._content.modulate.a < 1.0)
			faded_early = faded_early or (presentation.expansion_progress < 1.0 and presentation._content.modulate.a == 0.0)
			if presentation.expansion_progress > 0.45 and not recorded_growth:
				recorded_growth = true
				await _capture(context + "_expanding")
		else:
			_key(KEY_ESCAPE)
			_key(KEY_ENTER)
			fully_covered = fully_covered or (presentation._surface.get_global_rect().is_equal_approx(root.get_visible_rect()) and presentation._overlay.modulate.a == 1.0)
			new_page_fade = new_page_fade or (presentation._overlay.modulate.a > 0.0 and presentation._overlay.modulate.a < 1.0)
			if presentation._overlay.modulate.a < 0.70 and presentation._overlay.modulate.a > 0.20 and not recorded_reveal:
				recorded_reveal = true
				await _capture(context + "_revealing")
		await process_frame
	await _settle()
	_check(_game.page == destination and not _game._menu_transitioning and _game._menu_page_transition == null, "只进入首次点击的目标并释放浮层 " + context)
	_check(growing and previous_area > original.get_area() * 1.1, "白卡连续扩展且始终在窗口内 " + context)
	_check(native_content and partial_fade and faded_early, "原字号内容渐隐并在铺满前消失 " + context)
	_check(fully_covered and new_page_fade, "先铺满不透明白卡再揭开新页面 " + context)
	_check(_game.find_child("MainMenuPageTransition", true, false) == null and not _game._main_background.visible, "完成后不残留菜单遮挡或图片背景 " + context)
	await _capture(context + "_complete")
	if destination == GameShell.Page.EDITOR:
		_check(_game._editor != null and not _game._editor.editor_document.is_dirty(), "编辑器通过正常入口建立未修改文档 " + context)
		_click(_game._editor._header.back_button)
	else:
		_check(_game.catalog.levels.size() == 16 and _game.session == null, "开始游戏仍读取目录并进入选关 " + context)
		_click(_game._level_header._back_button)
	await _settle()
	_check(_game.page == GameShell.Page.MAIN and _game._menu_card.visible, "结束后原生返回按钮可正常使用 " + context)


## 动画中途缩小客户区，白卡最终仍铺满当前窗口而不是原来的缓存尺寸。
func _check_resize() -> void:
	_game._show_main_page()
	await _settle()
	_click(_game.find_child("StartGameButton", true, false) as Control)
	await create_timer(0.12).timeout
	_game.settings.set_window_resolution("1024x640")
	var covered_current_size := false
	var deadline := Time.get_ticks_msec() + 3000
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		if _game.page != GameShell.Page.MAIN:
			covered_current_size = covered_current_size or _game._menu_page_transition._surface.get_global_rect().is_equal_approx(root.get_visible_rect())
		await process_frame
	_check(covered_current_size, "缩窗后白卡仍先铺满当前客户区")
	await _wait_transition()
	_check(_game.page == GameShell.Page.LEVELS and root.size == Vector2i(1024, 640), "扩展途中缩窗仍完成正常目的页")
	_check(root.get_visible_rect().grow(1).encloses(_game._level_header.get_global_rect()), "缩窗后导航留在当前画幅内")
	_game.settings.set_window_resolution("1280x800")


## 两段动画都能由同步导航安全中断，取消回调与临时原生内容不能影响后来页面。
func _check_cancel(during_reveal: bool) -> void:
	_game._show_main_page()
	await _settle()
	_click(_game.find_child("MapEditorButton", true, false) as Control)
	if during_reveal:
		var deadline := Time.get_ticks_msec() + 2000
		while _game.page == GameShell.Page.MAIN and Time.get_ticks_msec() < deadline:
			await process_frame
	else:
		await create_timer(0.10).timeout
	_game._show_main_page()
	await create_timer(0.8).timeout
	_check(_game.page == GameShell.Page.MAIN and not _game._menu_transitioning and _game._menu_page_transition == null, "中断后没有迟到的页面跳转 " + str(during_reveal))
	_check(_game._menu_card.visible and _game.find_child("MainMenuTitle", true, false).modulate.a == 1.0, "中断后菜单完全可见 " + str(during_reveal))
	_check(_game.find_child("MainMenuPageTransition", true, false) == null, "中断释放临时呈现层 " + str(during_reveal))


## 键盘激活与鼠标共用入口动画，动画期间的焦点与按键不能触发其它页面。
func _check_keyboard() -> void:
	var button := _game.find_child("StartGameButton", true, false) as Button
	button.grab_focus()
	_key(KEY_ENTER)
	_check(_game._menu_transitioning and _game.page == GameShell.Page.MAIN and root.gui_get_focus_owner() == null, "键盘激活先播放动画并释放旧焦点")
	await _wait_transition()
	_check(_game.page == GameShell.Page.LEVELS, "键盘入口最终抵达选关页")


## 设置继续复用固定白卡淡出淡入，不受新增的主入口扩展影响。
func _check_settings_unchanged() -> void:
	_game._show_main_page()
	await _settle()
	var card := _game._menu_card
	var bounds := card.get_global_rect()
	_click(_game.find_child("SettingsButton", true, false) as Control)
	_check(_game._menu_transitioning and _game._menu_page_transition == null, "设置仍走既有内容渐隐入口")
	await _wait_transition()
	_check(_game.page == GameShell.Page.SETTINGS and _game._menu_card == card and card.get_global_rect().is_equal_approx(bounds), "设置复用同一张原位白卡")


## 系统关闭也取消正在扩展的旧入口，测试替身不退出实际测试进程。
func _check_close() -> void:
	_game._show_main_page()
	await _settle()
	_game.quit_handler = func() -> void: _quit_requests += 1
	_click(_game.find_child("MapEditorButton", true, false) as Control)
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await create_timer(0.8).timeout
	_check(_quit_requests == 1 and not _game._menu_transitioning and _game._menu_page_transition == null and _game.page == GameShell.Page.MAIN, "系统关闭取消动画，不能在退出后迟到地打开编辑器")


## 完整鼠标输入交给根视口，使用 Canvas 坐标避免被根窗口再次缩放。
func _click(control: Control) -> void:
	var point := control.get_global_transform_with_canvas() * (control.size * 0.5)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)


## 键盘按下与释放经过原生按钮，不直接发出按钮信号绕过输入锁。
func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.pressed = pressed
		root.push_input(event, true)


## 等真实 Tween 结束而不是猜测若干帧，超时记为失败。
func _wait_transition() -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while _game._menu_transitioning and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not _game._menu_transitioning, "转场在限定时间内完成")
	await _settle()


## 原生容器跨帧完成布局后再读取几何，兼容不同帧率。
func _settle() -> void:
	for frame in 8:
		await process_frame


## 保存实际渲染帧，便于核对扩展和揭开过程中没有文字纹理拉伸。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(root.get_texture().get_image().save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存转场实际画面 " + filename)


## 汇总失败同时继续剩余独立验证，退出码供完整回归脚本判断。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 递归清理范围只限本轮生成的测试目录。
func _remove_tree(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	for filename in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)
