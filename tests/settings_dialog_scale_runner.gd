extends "res://tests/window_resolution_ui_runner.gd"
## 独立设置浮层在 Windows 大窗口中随白卡呈现，字号、键盘和全屏彩蛋仍走原有路径。

var _expansions_finished := 0
var _expansions_canceled := 0
var _original_transparent := false


## 所有设置和记录均隔离，清除确认只执行取消，原生 GPU 窗口仅覆盖宿主可容纳的尺寸。
func _run() -> void:
	_temporary = "user://tests/settings_dialog_scale_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_game._clear_progress_dialog.use_native_dialog = false
	_game._about_dialog.easter_expansion_finished.connect(_record_expansion_finished)
	_game._about_dialog.easter_expansion_canceled.connect(_record_expansion_canceled)
	root.content_scale_size = GameWindowController.CONTENT_SIZE
	_set_platform("Windows")
	_game.settings.set_window_resolution("1024x640")
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(3840, 2160)]:
		var resolution := "%dx%d" % [dimensions.x, dimensions.y]
		if not _game.window_controller.available_resolutions.has(resolution):
			print("SKIP 设置浮层原生 GPU 尺寸 " + resolution + "：宿主屏幕不能容纳此客户区。")
			continue
		_game.settings.set_window_resolution(resolution)
		await _settle(12)
		await _open_settings()
		for locale: String in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			for percentage: int in [100, 125, 200]:
				_game.settings.set_ui_scale(percentage)
				await _settle(12)
				var context := "%s %s %d%%" % [resolution, locale, percentage]
				await _check_about(context, percentage == 200)
				await _check_clear(context)
		await _click(_game._back_button)
		_game.settings.set_ui_scale(100)
	await _check_macos()
	await _dispose_game()
	_check(root.transparent_bg == _original_transparent, "销毁浮层后恢复视口透明状态")
	_finish()


## 仅替换公开平台及物理屏幕能力查询，卡片比例和字体仍由生产控制器计算。
func _set_platform(platform: String) -> void:
	_game.window_controller.platform_name = platform
	_game.window_controller.screen_size_provider = _screen_profile
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()


## UHD 能力允许验证独立的 200% 字号，不解除真实宿主的窗口边界限制。
func _screen_profile() -> Vector2i:
	return Vector2i(3840, 2160)


## 入口的八成正文比例不应混入浮层；白卡保存的基础比例只使用一次。
func _factor() -> float:
	return float(_game._menu_card.get_meta("ui_menu_layout_scale", 1.0))


## 通过真实坐标打开关于，观察弹出动画，再遍历焦点和可选全屏扩展与取消。
func _check_about(context: String, check_expansion: bool) -> void:
	var entry := _game.settings_panel.find_child("AboutButton", true, false) as Control
	_game.settings_panel._scroll.ensure_control_visible(entry)
	await _settle(8)
	await _click(entry)
	var dialog := _game._about_dialog
	if not _check(dialog.is_open(), "真实入口打开关于浮层 " + context):
		return
	await _check_opening(dialog._panel, dialog._tween, 0.98, context + " 关于")
	var panel := dialog._panel
	var factor := _factor()
	_check(panel.size.is_equal_approx(Vector2(384, 608)) and panel.scale.is_equal_approx(Vector2.ONE * factor), "关于保留逻辑尺寸并随白卡同比例呈现 " + context)
	_check_centered(panel, context + " 关于")
	var close := dialog._close
	var corner_center := panel.get_global_transform() * Vector2(panel.size.x - 36, 36)
	_check(close.get_global_rect().size.is_equal_approx(Vector2(28, 28) * factor) and close.get_global_rect().get_center().distance_to(corner_center) < 0.1, "比例放大后关闭按钮仍与卡片圆角同心 " + context)
	var icon := dialog._logo
	_check(icon.get_global_rect().size.is_equal_approx(Vector2(104, 104) * factor), "关于图标随基础呈现比例扩大，手动字号不拉伸图标 " + context)
	_check(dialog._scroll.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "关于内容未额外套用设置正文的八成缩放 " + context)
	_check_glass(dialog._glass, 35.0 * factor, context + " 关于")
	_check(close.has_focus(), "关于打开后默认聚焦关闭 " + context)
	var visited: Dictionary = {}
	for step in 6:
		await _key(root, KEY_TAB)
		var focused := root.gui_get_focus_owner() as Control
		_check(is_instance_valid(focused) and dialog.is_ancestor_of(focused), "关于键盘焦点保留在浮层 " + context)
		if is_instance_valid(focused):
			visited[focused.name] = true
			if focused != close:
				_check(dialog._scroll.get_global_rect().grow(1).encloses(focused.get_global_rect()), "比例放大后键盘链接完整滚入可见区域 " + context)
	_check(visited.size() == 6 and close.has_focus(), "关于遍历全部链接后回到关闭 " + context)
	if check_expansion:
		await _check_expansion(dialog, context)
	await _key(root, KEY_ESCAPE)
	_check(not dialog.is_open() and entry.has_focus() and _game.page == GameShell.Page.SETTINGS, "关闭关于后恢复设置入口焦点 " + context)


## 弹出动画始终围绕视口中心，过程能观察到相对缩放与透明度，结束后保留基础比例。
func _check_opening(panel: Control, tween: Tween, initial_scale: float, context: String) -> void:
	var factor := _factor()
	var intermediate := false
	var stable := true
	var deadline := Time.get_ticks_msec() + 2500
	while tween.is_running() and Time.get_ticks_msec() < deadline:
		intermediate = intermediate or (panel.scale.x > factor * initial_scale and panel.scale.x < factor and panel.modulate.a > 0.0 and panel.modulate.a < 1.0)
		stable = stable and panel.get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) <= 1.0 and root.get_visible_rect().grow(1).encloses(panel.get_global_rect())
		await process_frame
	await _settle(8)
	_check(intermediate and stable and not tween.is_running(), "弹出动画平滑等比放大且保持居中与窗口边界 " + context)
	_check(panel.scale.is_equal_approx(Vector2.ONE * factor) and is_equal_approx(panel.modulate.a, 1.0), "弹出结束没有恢复为一倍小浮层 " + context)


## 取消一次中途扩展后旧回调失效，重新完成时全局矩形精确覆盖视口且内容不被再次拉伸。
func _check_expansion(dialog: AboutGameDialog, context: String) -> void:
	var normal := dialog._panel.get_global_rect()
	var factor := _factor()
	var finished_before := _expansions_finished
	var canceled_before := _expansions_canceled
	_check(dialog.begin_easter_expansion(), "关于可开始全屏扩展 " + context)
	await create_timer(0.35).timeout
	_check(dialog._panel.get_global_rect().size.x > normal.size.x and dialog._panel.get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) <= 1.0, "比例浮层向四周居中扩展 " + context)
	await _key(root, KEY_ESCAPE)
	await _settle(8)
	_check(not dialog.is_easter_expanding() and dialog._panel.get_global_rect().is_equal_approx(normal) and dialog._panel.scale.is_equal_approx(Vector2.ONE * factor) and dialog._close.has_focus(), "中途取消恢复原比例卡片与关闭焦点 " + context)
	await create_timer(0.7).timeout
	_check(_expansions_finished == finished_before and _expansions_canceled == canceled_before + 1, "取消扩展不执行迟到的完成回调 " + context)
	var content_size := dialog._layout.size
	_check(dialog.begin_easter_expansion(), "取消后可再次扩展 " + context)
	await create_timer(1.0).timeout
	await _settle(8)
	_check(_expansions_finished == finished_before + 1 and dialog._panel.get_global_rect().is_equal_approx(root.get_visible_rect()), "扩展全局矩形恰好覆盖视口，完成只广播一次 " + context)
	_check(dialog._layout.size.is_equal_approx(content_size) and dialog._panel.scale.is_equal_approx(Vector2.ONE * factor), "全屏扩展保留正文逻辑尺寸和基础比例 " + context)
	await _key(root, KEY_ESCAPE)
	_check(dialog._panel.get_global_rect().is_equal_approx(normal) and dialog._close.has_focus(), "完整展开后取消仍恢复原卡片与焦点 " + context)


## 清除确认通过真实设置入口打开，只切换焦点后选择取消，绝不执行删除。
func _check_clear(context: String) -> void:
	var entry := _game.settings_panel.find_child("ClearProgressButton", true, false) as Control
	_game.settings_panel._scroll.ensure_control_visible(entry)
	await _settle(8)
	await _click(entry)
	var dialog := _game._clear_progress_dialog
	if not _check(dialog.is_open(), "真实入口打开清除确认 " + context):
		return
	await _check_opening(dialog._panel, dialog._tween, 0.97, context + " 清除")
	var panel := dialog._panel
	var factor := _factor()
	_check(panel.scale.is_equal_approx(Vector2.ONE * factor) and is_equal_approx(panel.size.x, 400), "清除确认只使用一次白卡基础比例 " + context)
	if _game.window_controller.effective_ui_scale == 100:
		_check(panel.size.is_equal_approx(Vector2(400, 440)), "基准字号保持原 400×440 清除确认 " + context)
		_check(is_equal_approx(dialog._body.position.y, 132.0), "基准字号保留原 132 像素正文起点 " + context)
	_check_centered(panel, context + " 清除")
	_check_glass(dialog._glass, 47.0 * factor, context + " 清除")
	for control: Control in [dialog._heading, dialog._body, dialog._confirm, dialog._cancel]:
		_check(panel.get_global_rect().grow(1).encloses(control.get_global_rect()) and control.size.y + 1 >= control.get_combined_minimum_size().y, "清除正文及按钮满足原生最小尺寸且不溢出 " + context + " " + control.name)
	_check(dialog._body.get_global_rect().end.y <= dialog._confirm.global_position.y and dialog._confirm.get_global_rect().end.y < dialog._cancel.global_position.y, "手动大字号不重叠清除正文与按钮 " + context)
	_check(dialog._heading.get_global_rect().end.y + 24.0 * factor <= dialog._body.global_position.y + 1.0, "手动大字号标题与正文保留同比例 24 像素间隔 " + context)
	_check(dialog._cancel.has_focus(), "清除打开默认聚焦取消 " + context)
	await _key(root, KEY_TAB)
	_check(dialog._confirm.has_focus(), "清除 Tab 可聚焦确认 " + context)
	await _key(root, KEY_TAB)
	_check(dialog._cancel.has_focus(), "清除 Tab 返回取消 " + context)
	await _key(root, KEY_ENTER)
	_check(not dialog.is_open() and entry.has_focus() and not _game._clear_progress_pending, "取消关闭浮层并恢复入口焦点，不保留清除请求 " + context)


## 标准浮层与内容按实际全局矩形检查，根视口始终覆盖完整模态屏障。
func _check_centered(panel: Control, context: String) -> void:
	_check(root.get_visible_rect().grow(1).encloses(panel.get_global_rect()) and panel.get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) <= 1.0, "独立浮层全局矩形居中且完整留在视口 " + context)


## 毛玻璃材质按实际显示尺寸和圆角采样，不能沿用放大前的像素距离。
func _check_glass(glass: ColorRect, radius: float, context: String) -> void:
	var material := glass.material as ShaderMaterial
	_check((material.get_shader_parameter("panel_size") as Vector2).is_equal_approx(glass.get_global_rect().size) and is_equal_approx(float(material.get_shader_parameter("corner_radius")), radius), "玻璃材质与比例放大的实际矩形和圆角一致 " + context)


## 非 Windows 继续原画幅与一倍逻辑浮层，保存的 200% 不应用到当前字体。
func _check_macos() -> void:
	_set_platform("macOS")
	_game.settings.set_ui_scale(200)
	_game.settings.set_language("zh_CN")
	await _settle(12)
	await _open_settings()
	_check(is_equal_approx(_factor(), 1.0) and _game.window_controller.effective_ui_scale == 100, "macOS 浮层维持基准比例与字体")
	await _check_about("macOS", false)
	await _check_clear("macOS")
	await _click(_game._back_button)


## 仅记录扩展通知数量，不启动彩蛋或调用任何外部系统。
func _record_expansion_finished() -> void:
	_expansions_finished += 1


## 记录主动取消，验证旧完成回调不会在浮层恢复后继续执行。
func _record_expansion_canceled() -> void:
	_expansions_canceled += 1


## 超时统一按失败清理，不把等待动画当作成功。
func _timeout() -> void:
	if _finished:
		return
	_check(false, "设置浮层比例回归超过 90 秒")
	await _dispose_game()
	_finish()


## 输出专用完成标记，再复用全局状态恢复和唯一测试目录清理。
func _finish() -> void:
	if not _finished:
		print("设置独立浮层比例回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	super._finish()
