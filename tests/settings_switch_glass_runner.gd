extends SceneTree
## 正式设置、地图属性和指令弹层的玻璃开关回归；输入经原生 Button，存档完全隔离。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_dir := ""
var _game: GameShell
var _editor: MapEditor
var _finished := false
var _original_locale := ""


## 仅显式指定目录时记录真实 GPU 画面，headless 不伪造截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 依次使用真实页面验证事件、模型回填、不同渐隐祖先及锁定语义。
func _run() -> void:
	Engine.max_fps = 120
	_original_locale = TranslationServer.get_locale()
	_temporary = "user://tests/settings_switch_glass_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	create_timer(100.0).timeout.connect(_timeout)
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("profile.json")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	var settings_button := _game.find_child("SettingsButton", true, false) as Control
	await _click(settings_button.get_global_rect().get_center())
	await create_timer(0.55).timeout
	if not _check(_game.settings_panel != null, "真实菜单进入设置页"):
		await _finish()
		return
	var panel := _game.settings_panel
	for switch: SettingsSwitch in [panel._tab_completion_toggle, panel._assembly_free_zoom_toggle]:
		await _check_input(switch, panel._scroll, switch.name)
		var restored := GameSettings.new(_game.settings_path)
		_check(restored.load_settings().is_ok() and restored.tab_completion == _game.settings.tab_completion and restored.assembly_free_zoom == _game.settings.assembly_free_zoom, "真实开关操作保存两个独立偏好 " + switch.name)
	await _check_fade(panel._tab_completion_toggle, panel._scroll, "settings")
	await _check_cancel(panel._tab_completion_toggle, panel._scroll)
	await _check_scaled()
	_game.queue_free()
	await _settle()
	_game = null
	await _check_editor()
	await _finish()


## 悬停保持白色；按住拉伸、释放原生切换，快速重复点击与空格不多发模型事件。
func _check_input(switch: SettingsSwitch, scroll: ScrollContainer, context: String) -> void:
	await _reveal(switch, scroll)
	var events := {"count": 0}
	var counter := func(_value: bool) -> void: events.count += 1
	switch.toggled.connect(counter)
	var initial := switch.button_pressed
	var idle_rect: Rect2 = switch.call("get_thumb_rect")
	var point := switch.get_global_rect().get_center()
	_motion(point)
	await create_timer(0.20).timeout
	_check(_amount(switch) < 0.01 and events.count == 0, "悬停不激活玻璃或切换 " + context)
	await _capture(context + "_idle")
	_mouse(point, true)
	await create_timer(0.25).timeout
	var held: Rect2 = switch.call("get_thumb_rect")
	_check(_amount(switch) > 0.75 and held.size.x > idle_rect.size.x + 1.0, "按住拉长并进入玻璃 " + context)
	_check(switch.button_pressed == initial and events.count == 0, "按住尚未释放不提交模型 " + context)
	_check(Rect2(Vector2.ZERO, switch.size).grow(2.0).encloses(held), "开关拉伸不溢出本身命中布局 " + context)
	await _capture(context + "_held")
	_mouse(point, false)
	await process_frame
	_check(switch.button_pressed != initial and events.count == 1, "一次释放仅提交一次原生切换 " + context)
	_check(_amount(switch) > 0.05, "模型同步后仍有连续玻璃退场 " + context)
	await create_timer(0.65).timeout
	_check(_settled(switch), "开关完成后回到正确端点和白色轮廓 " + context)
	for index in 5:
		await _click(point)
	await create_timer(0.65).timeout
	_check(switch.button_pressed == initial and events.count == 6 and _settled(switch), "快速反向切换端点一致且信号无重复 " + context)
	switch.grab_focus()
	_key(KEY_SPACE, true)
	await create_timer(0.18).timeout
	_check(_amount(switch) > 0.50, "空格按住有同等玻璃反馈 " + context)
	_key(KEY_SPACE, false)
	await create_timer(0.65).timeout
	_check(switch.button_pressed != initial and events.count == 7 and _settled(switch), "空格原生切换恰好一次并完成轮廓 " + context)
	switch.toggled.disconnect(counter)


## 取消、隐藏和禁用只终止装饰，不产生意外切换或延后的幽灵交互。
func _check_cancel(switch: SettingsSwitch, scroll: ScrollContainer) -> void:
	await _reveal(switch, scroll)
	var before := switch.button_pressed
	var point := switch.get_global_rect().get_center()
	_mouse(point, true)
	await create_timer(0.20).timeout
	var outside := point + Vector2(-140, 0)
	_motion(outside, outside - point, MOUSE_BUTTON_MASK_LEFT)
	_mouse(outside, false)
	await create_timer(0.65).timeout
	_check(switch.button_pressed == before and _settled(switch), "拖出开关释放取消点击并收回玻璃")
	_mouse(point, true)
	await create_timer(0.15).timeout
	switch.hide()
	await _settle()
	_check(_amount(switch) < 0.01, "隐藏按住开关立即清除玻璃")
	_mouse(point, false)
	switch.show()
	await _settle()
	_check(switch.button_pressed == before and _settled(switch), "重新显示不重放被取消点击")
	point = switch.get_global_rect().get_center()
	_mouse(point, true)
	await create_timer(0.15).timeout
	switch.disabled = true
	await _settle()
	_mouse(point, false)
	await _click(point)
	await create_timer(0.40).timeout
	_check(switch.button_pressed == before and _amount(switch) < 0.01, "中途禁用并继续点击不改值也不保留玻璃")
	switch.disabled = false
	switch.grab_focus()
	_key(KEY_SPACE, true)
	await create_timer(0.12).timeout
	switch.release_focus()
	_key(KEY_SPACE, false)
	await _settle()
	_check(_amount(switch) < 0.01, "失去键盘焦点立即取消旧交互")
	# 无信号赋值代表打开页面或撤销后的模型同步，不应伪装成用户操作。
	switch.set_pressed_no_signal(not before)
	await _settle()
	_check(_settled(switch), "无信号外部回填直接同步视觉端点")
	switch.set_pressed_no_signal(before)
	await _settle()


## Windows 屏幕画像覆盖大字号和高分辨率；真实 GPU 只使用宿主能容纳的物理窗口。
func _check_scaled() -> void:
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()
	for resolution: String in ["1280x800", "3840x2160"]:
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(resolution):
			print("SKIP 开关 GPU 尺寸 " + resolution + "：宿主尺寸不足，headless 覆盖几何。")
			continue
		_game.settings.set_window_resolution(resolution)
		_game.settings.set_ui_scale(200)
		_game.settings.set_language("ja")
		await _settle()
		for switch: SettingsSwitch in [_game.settings_panel._tab_completion_toggle, _game.settings_panel._assembly_free_zoom_toggle]:
			await _reveal(switch, _game.settings_panel._scroll)
			var initial := switch.button_pressed
			var point := switch.get_global_rect().get_center()
			_mouse(point, true)
			await create_timer(0.24).timeout
			var surface := switch.get("_surface") as Control
			var center := switch.get_global_transform_with_canvas() * (switch.call("get_thumb_rect") as Rect2).get_center()
			_check(_amount(switch) > 0.7 and surface.get_global_rect().get_center().distance_to(center) < 1.0, "日语200%设置的玻璃位置及真实输入正确 " + resolution + " " + switch.name)
			await _capture(resolution + "_200_" + switch.name)
			_mouse(point, false)
			await create_timer(0.65).timeout
			_check(switch.button_pressed != initial and _settled(switch), "高分辨率释放正确提交并回到端点 " + resolution + " " + switch.name)


## 编辑器的三个开关复用同一显示能力且各自只新增一个撤销事务。
func _check_editor() -> void:
	root.size = Vector2i(1280, 900)
	root.content_scale_size = root.size
	root.theme = GameTheme.create_theme()
	var background := ColorRect.new()
	background.color = GameTheme.BACKGROUND
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor = MapEditor.new()
	_editor.player_levels_directory = _temporary.path_join("levels")
	root.add_child(_editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	var model := _editor.editor_document
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	for switch: SettingsSwitch in [_editor._allow_code_hints_switch, _editor._restrict_code_paste_switch, _editor._enemy_panel.enable_switch]:
		var snapshot := model.document.to_dict()
		await _reveal(switch, scroll)
		var point := switch.get_global_rect().get_center()
		_mouse(point, true)
		await create_timer(0.22).timeout
		_check(_amount(switch) > 0.7, "地图属性开关支持按住玻璃 " + switch.name)
		await _capture(switch.name + "_held")
		_mouse(point, false)
		await create_timer(0.65).timeout
		_check(model.document.to_dict() != snapshot and _settled(switch), "属性模型更新且视觉同步 " + switch.name)
		_check(model.undo() and model.document.to_dict() == snapshot, "一次点击可用一次撤销完整恢复 " + switch.name)
		await _settle()
		_check(_settled(switch), "撤销回填不制造新玻璃交互 " + switch.name)
	await _check_fade(_editor._allow_code_hints_switch, scroll, "editor")
	model.mark_saved(_temporary.path_join("saved.json"))
	_editor._sync_code_policy_controls()
	var locked := _editor._restrict_code_paste_switch
	await _reveal(locked, scroll)
	var snapshot := model.document.to_dict()
	await _click(locked.get_global_rect().get_center())
	await create_timer(0.30).timeout
	_check(locked.disabled and _amount(locked) < 0.01 and model.document.to_dict() == snapshot, "保存后禁用粘贴开关不接受点击或显示玻璃")
	await _reveal(_editor._command_button, scroll)
	await _click(_editor._command_button.get_global_rect().get_center())
	await _settle()
	var menu := _editor._command_menu
	_check(menu.is_open(), "原生加号打开指令管理浮层")
	menu.select_section("movement")
	await _settle()
	var command: SettingsSwitch = menu._command_switches.move
	await _check_input(command, menu._scroll, "command")
	await _check_fade(command, menu._scroll, "command")
	menu.close_menu(false)
	await _settle()
	_check(_amount(command) < 0.01, "关闭弹层后没有外部玻璃残留")


## 用临时首尾留白让同一真实开关到达双端渐隐带；不替换正式控件或遮罩。
func _check_fade(switch: SettingsSwitch, scroll: ScrollContainer, context: String) -> void:
	var padding: MarginContainer
	for child: Node in scroll.get_children():
		if child is MarginContainer:
			padding = child
			break
	var spacers: Array[Control] = []
	var original_top := padding.get_theme_constant("margin_top") if padding != null else 0
	var original_bottom := padding.get_theme_constant("margin_bottom") if padding != null else 0
	var previous := scroll.scroll_vertical
	if padding != null:
		padding.add_theme_constant_override("margin_top", original_top + roundi(scroll.size.y * 2))
		padding.add_theme_constant_override("margin_bottom", original_bottom + roundi(scroll.size.y * 2))
	else:
		# 指令分类只有两行时用首尾空白建立滚动行程，真实开关与遮罩仍原样保留。
		var column: VBoxContainer
		for child: Node in scroll.get_children():
			if child is VBoxContainer:
				column = child
		if not _check(column != null, "指令目录保持真实纵向列表"):
			return
		for index in 2:
			var spacer := Control.new()
			spacer.custom_minimum_size.y = scroll.size.y * 2
			column.add_child(spacer)
			if index == 0:
				column.move_child(spacer, 0)
			spacers.append(spacer)
	await _settle()
	await _reveal(switch, scroll)
	var point := switch.get_global_rect().get_center()
	_mouse(point, true)
	await create_timer(0.25).timeout
	for edge: String in ["top", "bottom"]:
		var values: Array[float] = []
		var boundary := scroll.get_global_rect().position.y if edge == "top" else scroll.get_global_rect().end.y
		for distance: float in [80.0, 12.0, -35.0]:
			var desired := boundary + distance if edge == "top" else boundary - distance
			var center := switch.get_global_transform_with_canvas() * (switch.call("get_thumb_rect") as Rect2).get_center()
			scroll.scroll_vertical += roundi((center.y - desired) / scroll.get_global_transform_with_canvas().get_scale().y)
			await _settle()
			center = switch.get_global_transform_with_canvas() * (switch.call("get_thumb_rect") as Rect2).get_center()
			_check(absf(center.y - desired) <= 1.2, "原生滚动到达真实渐隐位置 " + context + " " + edge + " " + str(distance))
			var surface := switch.get("_surface") as Control
			_check(surface != null and surface.get_global_rect().get_center().distance_to(center) < 1.2, "浮层随实际滚动保持中心对齐 " + context + " " + edge + " " + str(distance))
			if DisplayServer.get_name() != "headless" and not _capture_dir.is_empty():
				var active := await _capture(context + "_" + edge + "_fade_" + str(int(distance)))
				surface.self_modulate.a = 0.0
				var background := await _capture(context + "_" + edge + "_fade_" + str(int(distance)) + "_background")
				surface.self_modulate.a = 1.0
				values.append(_pixel_difference(surface, active, background))
		if values.size() == 3:
			_check(values[0] > 0.008 and values[1] > 0.0001 and values[1] < values[0] * 0.95 and values[2] < 0.006, "GPU 渐隐连续且滚出后没有残留 " + context + " " + edge + " " + str(values))
	_mouse(point, false)
	if padding != null:
		padding.add_theme_constant_override("margin_top", original_top)
		padding.add_theme_constant_override("margin_bottom", original_bottom)
	for spacer: Control in spacers:
		spacer.queue_free()
	scroll.scroll_vertical = previous
	await create_timer(0.65).timeout


## 只读取显示端点与交互量，避免复制动画公式或依赖 Tween 结构。
func _settled(switch: SettingsSwitch) -> bool:
	return _amount(switch) < 0.01 and absf(float(switch.get("thumb_progress")) - (1.0 if switch.button_pressed else 0.0)) < 0.001


## 通过公开交互强度检查原生输入是否触发材质。
func _amount(switch: SettingsSwitch) -> float:
	return float(switch.get("interaction_amount"))


## 原生滚动将控件放入清晰区域，保留正式控件和父级变换。
func _reveal(control: Control, scroll: ScrollContainer) -> void:
	var desired := scroll.global_position.y + scroll.get_global_rect().size.y * 0.5
	scroll.scroll_vertical += roundi((control.get_global_rect().get_center().y - desired) / scroll.get_global_transform_with_canvas().get_scale().y)
	await _settle()


## 独立绘制层开关前后逐像素比较，排除只有内部状态而没有实际玻璃的实现。
func _pixel_difference(surface: Control, active: Image, background: Image) -> float:
	var bounds := Rect2i(root.get_final_transform() * surface.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, active.get_size()))
	var total := 0.0
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var a := active.get_pixel(x, y)
			var b := background.get_pixel(x, y)
			total += Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
	return total / maxf(bounds.get_area(), 1.0)


## 输入经根视口分发，不直接调用生产回调或发信号。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: MouseButtonMask = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event, true)


## 按住与释放可分开观察，不改变 Button 原生提交时机。
func _mouse(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event, true)


## 一次真实点击包含移动、按下、释放及最短布局同步。
func _click(point: Vector2) -> void:
	_motion(point)
	_mouse(point, true)
	_mouse(point, false)
	await process_frame


## 空格使用真实焦点按钮处理而非调用私有事件。
func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	root.push_input(event, true)


## 布局按帧等待，动画使用明确墙钟时长。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 截图仅从已完成 GPU 绘制的视口取得。
func _capture(filename: String) -> Image:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return null
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	var image := root.get_texture().get_image()
	_check(image.save_png(_capture_dir.path_join(filename + ".png")) == OK, "保存真实截图 " + filename)
	return image


## 累积断言以报告多个独立场景，而不在首个问题后停止。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 任何异常等待都明确返回失败，不让测试永久挂起。
func _timeout() -> void:
	if not _finished:
		_check(false, "玻璃开关回归超时")
		await _finish()


## 退出时只清理测试自身路径并恢复语言。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.queue_free()
	if is_instance_valid(_editor):
		_editor.queue_free()
	await _settle()
	TranslationServer.set_locale(_original_locale)
	_cleanup(_temporary)
	print("玻璃开关回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 递归仅在本轮独占测试树内清理，真实保存根永不参与。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary) or not DirAccess.dir_exists_absolute(path):
		return
	for filename: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory: String in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(directory))
	DirAccess.remove_absolute(path)
