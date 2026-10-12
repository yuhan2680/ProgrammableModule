extends SceneTree
## 真实地图边缘拖动验证覆盖关系、编辑状态、输入拦截和取消边界，存档仅写入独立测试目录。

const STAIR_PROGRAM := "main() {\n    loop {\n        move(0, 3)\n        move(90, 2)\n    }\n}\n"
var _checks := 0
var _failures := 0
var _temporary := ""
var _events: Array[String] = []


## 真实鼠标事件需要稳定帧率和已完成的界面排版。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 用不同工作区覆盖基准、部分展开、全幅、取消、失焦、重排和离场。
func _run() -> void:
	create_timer(42.0).timeout.connect(_timeout)
	# 原生截图仍走视口注入，但排除桌面系统指针在窗口重排时产生的额外鼠标移动。
	if DisplayServer.get_name() != "headless":
		root.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	_temporary = "user://tests/curtain_preview_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var game: GameShell = load("res://scenes/game.tscn").instantiate()
	game.user_levels_directory = _temporary.path_join("levels")
	game.drafts_directory = _temporary.path_join("solutions")
	game.settings_path = _temporary.path_join("settings.json")
	root.add_child(game)
	await _settle()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740), Vector2i(1920, 1080), Vector2i(2560, 1440)]:
		root.size = dimensions
		await _test_editor_curtain(game)
	await _test_running_curtain(game)
	await _test_leaving_curtain(game)
	await _test_rendered_edge(game)
	game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("地图窗帘覆盖回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 通过正式空装配和确认入口获得原工作台，不替换地图、代码控件或会话。
func _enter_program(game: GameShell) -> GameWorkbench:
	game._enter_level(game.catalog.levels[5])
	game._dialogue_dialog.hide()
	await _settle()
	_check(game.session.assembly.add_module("movement", Vector2.ZERO, "drive").is_ok(), "安装阶梯关卡中心模块")
	game._confirm_assembly()
	await _settle()
	_check(game.workbench != null and game.page == GameShell.Page.PLAY, "真实装配确认进入代码页")
	return game.workbench


## 部分覆盖始终保留原宽度代码，并允许未覆盖区域编辑，已覆盖区域滚轮不穿透。
func _test_editor_curtain(game: GameShell) -> void:
	var workbench := await _enter_program(game)
	if workbench == null:
		return
	var layout := workbench._preview_layout
	var editor := workbench._code
	var source := STAIR_PROGRAM + ("// " + "scrollable line ".repeat(12) + "\n").repeat(90)
	editor.text = source
	editor.set_caret_line(editor.get_line_count() - 1)
	editor.insert_text_at_caret("// undo retained")
	editor.text_changed.emit()
	editor.select(2, 8, 2, 12)
	editor.set_caret_line(2)
	editor.set_caret_column(12)
	editor.grab_focus()
	await _settle()
	var edited_source := editor.text
	var selection := editor.get_selected_text()
	var baseline := workbench._world_panel.get_global_rect()
	var edit_rect := workbench._edit_panel.get_global_rect()
	var code_width := editor.size.x
	_check_baseline_proportions(layout, baseline, edit_rect)
	var assembly := game.session.assembly
	var modules := JSON.stringify(assembly.modules)
	_events.clear()
	layout.transition_started.connect(_record_started)
	layout.transition_finished.connect(_record_finished)
	_check(not layout.split.dragging_enabled, "原生分隔条不再压缩代码")
	var initial_fade: Variant = layout._wipe_material.get_shader_parameter("fade_strength")
	_check(initial_fade == null or is_zero_approx(float(initial_fade)), "默认布局不提前淡化代码左缘")
	await _capture_if_requested("curtain-baseline.png")
	await _start_drag(layout)
	_check(layout.is_dragging() and layout.transitioning and workbench._preview_input_shield.is_visible_in_tree(), "右边缘原生鼠标按下开始覆盖手势与输入屏障")
	if not layout.is_dragging():
		game._back_to_levels()
		await _settle()
		return
	_drag_to(layout, 0.45)
	await _settle()
	_check_progress(layout, 0.45, "地图跟随鼠标覆盖")
	_check(workbench._world_panel.get_global_rect().intersects(edit_rect), "地图真实进入代码基准矩形")
	_check(_rect_close(workbench._edit_panel.get_global_rect(), edit_rect) and absf(editor.size.x - code_width) < 1.5, "拖动不改变代码卡片或编辑器宽度")
	_check(workbench._edit_panel.is_visible_in_tree() and layout._world.get_index() > layout._edit_group.get_index(), "可见代码处于地图下层，覆盖不是整片擦除")
	_check(float(layout._wipe_material.get_shader_parameter("minimum_alpha")) >= 0.30 and float(layout._wipe_material.get_shader_parameter("fade_width")) < editor.size.x * 0.5, "边缘淡化保留三成透明度且只影响有限宽度")
	var frontier := float(layout._wipe_material.get_shader_parameter("curtain_edge"))
	_check(absf(frontier - (workbench._world_panel.get_global_rect().end.x - edit_rect.position.x)) < 1.5, "渐淡边界跟随地图的真实遮盖边缘")
	await _capture_if_requested("curtain-preview.png")
	_release_drag(layout)
	await _settle()
	_check(not layout.transitioning and not layout.expanded and layout.is_covering_code() and editor.editable, "松开保留部分展开并恢复代码编辑")
	_check(not workbench._preview_input_shield.is_visible_in_tree() and not workbench._full_preview_requested, "部分展开不残留全屏结果状态或输入屏障")
	_check(editor == workbench._code and game.session.assembly == assembly and JSON.stringify(assembly.modules) == modules, "拖动复用代码与装配对象且内容不变")
	_check(editor.text == edited_source and editor.get_selected_text() == selection and editor.get_caret_line() == 2 and editor.get_caret_column() == 12, "部分展开保留代码、光标与选区")
	_check(_events == ["start:true", "finish:false"], "部分覆盖有完整手势起止信号")
	# 代码本身可滚动，只有真实遮盖范围内的输入被地图截获。
	editor.set_v_scroll(30.0)
	await _settle()
	var intersection := workbench._world_panel.get_global_rect().intersection(editor.get_global_rect())
	_check(intersection.has_area(), "存在覆盖真实代码内容的滚轮测试区域")
	var scroll_before := editor.get_v_scroll()
	_wheel(intersection.get_center())
	await _settle()
	_check(is_equal_approx(editor.get_v_scroll(), scroll_before), "覆盖地图上的滚轮不会传递到后方代码")
	var uncovered := Vector2(editor.get_global_rect().end.x - 30.0, editor.get_global_rect().get_center().y)
	_wheel(uncovered)
	await _settle()
	_check(editor.get_v_scroll() > scroll_before, "未覆盖代码区域仍可正常滚动")
	await _start_drag(layout)
	_drag_to(layout, 0.75)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape, true)
	await _settle()
	_check_progress(layout, 0.45, "Esc 恢复手势起始部分展开")
	_check(not layout.is_dragging() and not layout.transitioning and editor.editable, "Esc 不遗留输入锁")
	_release_drag(layout)
	await _start_drag(layout)
	_drag_to(layout, 0.8)
	_mouse_button(layout._edge_handle.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT, true)
	_mouse_button(layout._edge_handle.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT, false)
	_release_drag(layout)
	await _settle()
	_check_progress(layout, 0.45, "右键取消恢复部分展开")
	_check(not layout.transitioning, "右键取消不遗留手势")
	await _start_drag(layout)
	_drag_to(layout, 0.8)
	layout.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _settle()
	_check_progress(layout, 0.45, "失焦取消手势")
	_check(not layout.transitioning and editor.editable, "失焦取消后代码恢复编辑")
	_release_drag(layout)
	await _start_drag(layout)
	_drag_to(layout, 0.8)
	var original_size := root.size
	root.size += Vector2i(120, 40)
	await _settle()
	_check_progress(layout, 0.45, "窗口缩放取消旧坐标手势")
	_check(not layout.is_dragging() and not layout.transitioning, "窗口缩放不遗留拖动")
	_release_drag(layout)
	root.size = original_size
	await _settle()
	workbench._preview_button.pressed.emit()
	await _wait_preview(layout)
	_check(layout.expanded and is_equal_approx(layout.get_expand_progress(), 1.0), "原全屏按钮从部分展开继续填满地图")
	_check(not workbench._edit_panel.is_visible_in_tree(), "完全遮盖后代码退出不可见命中范围")
	await _start_drag(layout)
	_drag_to(layout, 0.65)
	_release_drag(layout)
	await _settle()
	_check_progress(layout, 0.65, "全屏可直接拖回部分展开")
	_check(editor.editable and workbench._edit_panel.is_visible_in_tree(), "从全屏拖回显示原代码并恢复编辑")
	await _start_drag(layout)
	_drag_to(layout, 0.0)
	_release_drag(layout)
	await _settle()
	_check_progress(layout, 0.0, "拖回基准位置")
	_check(not layout.is_covering_code() and _rect_close(workbench._world_panel.get_global_rect(), baseline) and _rect_close(workbench._edit_panel.get_global_rect(), edit_rect), "完全拖回恢复两个原卡片矩形")
	_check(editor.has_undo(), "拖动往返保留撤销历史")
	editor.undo()
	_check(editor.text == source, "撤销仍对应拖动前最后一次文字输入")
	editor.redo()
	_check(editor.text == edited_source, "重做仍恢复原输入而非布局变化")
	game._back_to_levels()
	await _settle()


## 可选原生渲染检查保存基准与覆盖帧，常规无头测试不请求屏幕或产生截图。
func _capture_if_requested(filename: String) -> void:
	if OS.get_cmdline_user_args().has("--capture-curtain") and DisplayServer.get_name() != "headless" and root.size.x == 1280:
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../" + filename))


## 代码保留可读宽度，地图填满其左侧空间，两个卡片之间只有固定间距。
func _check_baseline_proportions(layout: WorkbenchPreviewLayout, world_rect: Rect2, edit_rect: Rect2) -> void:
	var bounds := layout.get_global_rect()
	var code_minimum := maxf(430.0, layout._edit.get_combined_minimum_size().x)
	var expected_code := maxf(code_minimum, roundf(bounds.size.x * 0.38))
	var expected_world := bounds.size.x - expected_code - 16.0
	_check(absf(world_rect.size.x - expected_world) < 2.0 and absf(edit_rect.size.x - expected_code) < 2.0, "基准地图填满代码左侧，代码占约38%%且不小于可读下限：%s / %s / %s" % [bounds, world_rect, edit_rect])
	_check(absf(edit_rect.end.x - bounds.end.x) < 1.5 and absf(edit_rect.position.x - world_rect.end.x - 16.0) < 1.5, "代码卡片保持右对齐，地图与代码只有16像素间距")


## 真正渲染后比较同一空白代码位置，防止合成把深色底淡成白光，也覆盖浅色配色切换。
func _test_rendered_edge(game: GameShell) -> void:
	if DisplayServer.get_name() == "headless":
		return
	root.size = Vector2i(1280, 800)
	var workbench := await _enter_program(game)
	if workbench == null:
		return
	workbench._code.text = "main() {\n    // " + "fade_edge_text ".repeat(30) + "\n    // " + "visible_code ".repeat(30) + "\n}\n"
	workbench._code.release_focus()
	var layout := workbench._preview_layout
	for mode: String in ["dark", "light"]:
		game.settings.set_code_color_mode(mode)
		await _settle()
		await _capture_if_requested("curtain-%s-default.png" % mode)
		await RenderingServer.frame_post_draw
		var baseline := root.get_texture().get_image()
		await _start_drag(layout)
		_drag_to(layout, 0.35)
		_release_drag(layout)
		await _settle()
		await RenderingServer.frame_post_draw
		var covered := root.get_texture().get_image()
		var edge := workbench._world_panel.get_global_rect().end.x
		var code_rect := workbench._code.get_global_rect()
		for offset: float in [24.0, 48.0, 72.0]:
			var point := Vector2(edge + offset, code_rect.position.y + code_rect.size.y * 0.65)
			var previous := _sample_patch(baseline, point)
			var current := _sample_patch(covered, point)
			_check(maxf(absf(previous.r - current.r), maxf(absf(previous.g - current.g), absf(previous.b - current.b))) < 0.035, "%s 拉帘附近空白底色保持原色而不发亮：距离 %.0f，前 %s，后 %s" % [mode, offset, previous, current])
		var background := _sample_patch(baseline, code_rect.get_center() + Vector2(80.0, 100.0))
		var near_band := Rect2(Vector2(edge + 24.0, code_rect.position.y + 8.0), Vector2(24.0, 100.0))
		var before_contrast := _patch_contrast(baseline, near_band, background)
		var after_contrast := _patch_contrast(covered, near_band, background)
		_check(before_contrast > 0.002 and after_contrast > before_contrast * 0.15 and after_contrast < before_contrast * 0.9, "%s 真实注释文字靠近地图时渐淡但不消失：前 %.5f，后 %.5f" % [mode, before_contrast, after_contrast])
		var far_band := Rect2(Vector2(edge + 120.0, code_rect.position.y + 8.0), Vector2(24.0, 100.0))
		var far_before := _patch_contrast(baseline, far_band, background)
		var far_after := _patch_contrast(covered, far_band, background)
		_check(far_before > 0.002 and absf(far_before - far_after) < far_before * 0.12, "%s 远离地图的真实文字保持原对比度：前 %.5f，后 %.5f" % [mode, far_before, far_after])
		await _capture_if_requested("curtain-%s-no-glow.png" % mode)
		await _start_drag(layout)
		_drag_to(layout, 0.0)
		_release_drag(layout)
		await _settle()
	root.size = Vector2i(1920, 1080)
	workbench._code.text = STAIR_PROGRAM
	game.settings.set_code_color_mode("dark")
	await _settle()
	if OS.get_cmdline_user_args().has("--capture-curtain"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../curtain-1920-default.png"))
	game._back_to_levels()
	await _settle()


## 从实际视口像素取小块平均值，兼容高分屏截图而避开单像素采样误差。
func _sample_patch(image: Image, point: Vector2) -> Color:
	var scale := Vector2(image.get_size()) / root.get_visible_rect().size
	var center := Vector2i(point * scale)
	var total := Color(0.0, 0.0, 0.0, 0.0)
	for y in range(-2, 3):
		for x in range(-2, 3):
			total += image.get_pixel(clampi(center.x + x, 0, image.get_width() - 1), clampi(center.y + y, 0, image.get_height() - 1))
	return total / 25.0


## 聚合真实注释整块像素相对底色的对比度，不依赖字体某个固定字形的位置。
func _patch_contrast(image: Image, bounds: Rect2, background: Color) -> float:
	var scale := Vector2(image.get_size()) / root.get_visible_rect().size
	var start := Vector2i(bounds.position * scale)
	var finish := Vector2i(bounds.end * scale)
	var total := 0.0
	var samples := 0
	for y in range(maxi(start.y, 0), mini(finish.y, image.get_height())):
		for x in range(maxi(start.x, 0), mini(finish.x, image.get_width())):
			var pixel := image.get_pixel(x, y)
			total += maxf(absf(pixel.r - background.r), maxf(absf(pixel.g - background.g), absf(pixel.b - background.b)))
			samples += 1
	return total / maxf(float(samples), 1.0)


## 运行和暂停期间只改变观察范围，同一世界与执行器不能被拖动重建。
func _test_running_curtain(game: GameShell) -> void:
	var workbench := await _enter_program(game)
	if workbench == null:
		return
	workbench._code.text = STAIR_PROGRAM
	workbench.header.run_button.pressed.emit()
	var world := game.session.world
	var runner := game.session.runner
	var layout := workbench._preview_layout
	_check(world != null and runner != null, "真实程序创建运行世界")
	await _start_drag(layout)
	_drag_to(layout, 0.4)
	_release_drag(layout)
	await _settle()
	_check(game.session.world == world and game.session.runner == runner and game.session.state == GameSession.State.RUNNING and not workbench._code.editable, "运行时拖动保留执行器并遵守编辑锁")
	workbench.header.pause_button.pressed.emit()
	var tick := world.tick_index
	await _start_drag(layout)
	_drag_to(layout, 1.0)
	_release_drag(layout)
	await _settle()
	_check(layout.expanded and game.session.world == world and game.session.runner == runner and world.tick_index == tick and game.session.state == GameSession.State.PAUSED, "暂停拖到全屏不会推进或重建世界")
	game._back_to_levels()
	await _settle()


## 手势中离开页面应释放拖柄和锁，后续鼠标释放不会修改下一页。
func _test_leaving_curtain(game: GameShell) -> void:
	var workbench := await _enter_program(game)
	if workbench == null:
		return
	var layout := workbench._preview_layout
	var reference: WeakRef = weakref(layout)
	await _start_drag(layout)
	_drag_to(layout, 0.6)
	game._back_to_levels()
	await _settle()
	_check(reference.get_ref() == null and game.workbench == null and game.page == GameShell.Page.LEVELS, "拖动中离场释放覆盖层与输入屏障")
	_mouse_button(Vector2(500, 400), MOUSE_BUTTON_LEFT, false)
	await _settle()
	_check(game.page == GameShell.Page.LEVELS and not game._command_menu.is_open(), "迟到的鼠标释放不触发新页面动作")


## 鼠标先移到真实拖柄中点，再通过视口按下，验证实际命中路径。
func _start_drag(layout: WorkbenchPreviewLayout) -> void:
	var point := layout._edge_handle.get_global_rect().get_center()
	_motion(point)
	await process_frame
	_mouse_button(point, MOUSE_BUTTON_LEFT, true)
	await process_frame


## 根据基准右边缘换算目标覆盖比例，仍由生产输入路径解释鼠标事件。
func _drag_to(layout: WorkbenchPreviewLayout, progress: float) -> void:
	if not layout.is_dragging():
		_check(false, "拖柄未开始拖动，不能移动窗帘")
		return
	var normal_right := layout._world_slot.position.x + layout._world_slot.size.x
	var local_point := Vector2(normal_right + (layout.size.x - normal_right) * progress + layout._drag_grab_offset, layout.size.y * 0.5)
	_motion(layout.get_global_transform_with_canvas() * local_point, MOUSE_BUTTON_MASK_LEFT)


## 释放事件走视口输入屏障，让工作台与布局同时完成手势。
func _release_drag(layout: WorkbenchPreviewLayout) -> void:
	_mouse_button(layout._edge_handle.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, false)


## 按控件所在逻辑视口注入鼠标位置，避免高分辨率拉伸把坐标再次缩放。
func _motion(point: Vector2, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.button_mask = mask
	root.push_input(event, true)


## 使用真实按键事件覆盖地图层级和代码编辑器的 GUI 路由。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	if pressed and button <= MOUSE_BUTTON_MIDDLE:
		event.button_mask = 1 << (button - 1)
	root.push_input(event, true)


## 滚轮先更新悬停命中，再发送成对滚动事件。
func _wheel(point: Vector2) -> void:
	_motion(point)
	_mouse_button(point, MOUSE_BUTTON_WHEEL_DOWN, true)
	_mouse_button(point, MOUSE_BUTTON_WHEEL_DOWN, false)


## 等待按钮补间完成但不修改进度制造测试结果。
func _wait_preview(layout: WorkbenchPreviewLayout) -> void:
	for unused in 240:
		await process_frame
		if not layout.transitioning:
			await _settle()
			return
	_check(false, "全屏按钮补间未在规定时间内结束")


## 比例允许鼠标像素舍入，不允许丢失整个手势或还原到错误起点。
func _check_progress(layout: WorkbenchPreviewLayout, expected: float, reason: String) -> void:
	_check(absf(layout.get_expand_progress() - expected) < 0.015, "%s：实际 %.3f，预期 %.3f" % [reason, layout.get_expand_progress(), expected])


## 卡片原矩形在覆盖往返后不应因容器重新挂载而漂移。
func _rect_close(actual: Rect2, expected: Rect2) -> bool:
	return actual.position.distance_to(expected.position) < 1.5 and actual.size.distance_to(expected.size) < 1.5


## 记录起点信号以验证部分展开也有完整输入锁生命周期。
func _record_started(expanding: bool) -> void:
	_events.append("start:" + str(expanding))


## 结束布尔值只代表实际全幅状态，不能把部分覆盖误记成全屏。
func _record_finished(expanded: bool) -> void:
	_events.append("finish:" + str(expanded))


## 留给容器、滚动条与延迟地图适配足够帧数。
func _settle() -> void:
	for unused in 5:
		await process_frame


## 只清理本进程唯一临时目录，绝不遍历真实关卡和用户档案。
func _cleanup(path: String) -> void:
	if _temporary.is_empty() or not path.begins_with(_temporary):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)


## 聚合独立断言，确保某一窗口失败不掩盖其余取消和输入边界。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)


## 脚本错误或无法完成的手势不能无限阻塞回归。
func _timeout() -> void:
	push_error("地图窗帘覆盖回归超过 42 秒总时限。")
	quit(1)
