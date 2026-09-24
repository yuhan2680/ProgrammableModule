extends SceneTree
## 装配视图回归：真实鼠标与键盘验证抽屉屏障、查看变换及模块编辑仍共享同一模型。

var _checks := 0
var _failures := 0
var _changes := 0
var _temporary := ""
var _game: GameShell


## 等待场景树可添加正式游戏页面后执行，所有文件仅写入独占测试目录。
func _initialize() -> void:
	_run.call_deferred()


## 在真实准备页和工作台页签覆盖查看、编辑及浮层生命周期。
func _run() -> void:
	_temporary = "user://tests/assembly_viewport_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/game.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	var document := _game.catalog.levels[0].document.duplicate_document()
	document.id = "assembly_viewport_fixture"
	document.width = 12
	document.height = 12
	document.dialogue.clear()
	document.player_spawn.position = {"x": 6.5, "y": 6.5}
	document.properties.level.module_limit = 3
	document.properties.level.allowed_modules = ["movement", "radar", "shooting"]
	document.properties.level.allow_named_calls = true
	document.properties.level.goal = null
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	var parsed := LevelDefinition.from_document(document, _game.registry)
	_check(parsed.is_ok(), "构造独占空装配测试地图")
	if parsed.is_ok():
		_game._enter_level(parsed.value)
		_game._dialogue_dialog.hide()
		await _settle()
		_game.session.assembly.changed.connect(_record_change)
		await _test_fixed_view()
		await _test_drawer()
		await _test_view_and_edit()
		await _test_reference_origin()
		await _test_switch_to_fixed()
		await _test_lifecycle()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("装配视图回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 新偏好默认关闭，完整蓝图不响应查看输入，首件仍能在所点半格建立参考点。
func _test_fixed_view() -> void:
	var canvas := _game.assembly_panel.canvas
	_check(not _game.settings.assembly_free_zoom and not canvas.free_zoom_enabled, "未保存过设置时默认使用固定完整蓝图")
	var paper := canvas._paper_rect()
	var origin := _point(canvas, Vector2.ZERO)
	var changes := _changes
	_click(origin, MOUSE_BUTTON_WHEEL_UP)
	_click(origin, MOUSE_BUTTON_WHEEL_DOWN)
	_drag(origin, origin + Vector2(70, -30), MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(canvas._paper_rect().is_equal_approx(paper) and _point(canvas, Vector2.ZERO).is_equal_approx(origin) and not canvas._pan_dragging, "固定模式忽略滚轮与右键拖动，不留下抓手捕获")
	_check(Rect2(Vector2.ZERO, canvas.size).grow(0.1).encloses(paper) and canvas.material == null, "固定模式完整显示图纸外框并关闭边缘淡出")
	_check(_game.session.assembly.modules.is_empty() and _changes == changes, "固定模式的查看输入不会安装模块或写草稿")
	var first_click := _point(canvas, Vector2(1, -1))
	_click(first_click)
	await _settle()
	_check(_game.session.assembly.modules.size() == 1 and _offset(0) == Vector2.ZERO and _point(canvas, Vector2.ZERO).distance_to(first_click) < 1.0, "固定模式首件可在非中心半格放置，保持落点与逻辑零偏移")
	_click(_point(canvas, Vector2.ZERO))
	_key(KEY_DELETE)
	await _settle()
	_game.settings.set_assembly_free_zoom(true)
	await _settle()
	_check(canvas.free_zoom_enabled and canvas.material == null and canvas._drawing_group.material != null, "开启设置立即恢复自由查看及合成后的边缘淡出")
	canvas.reset_view()


## 目录默认只列模块名，统一说明开关与语言切换均不得编辑模型。
func _test_drawer() -> void:
	var panel := _game.assembly_panel
	var canvas := panel.canvas
	var initial := _signature()
	var changes := _changes
	_check(not panel._palette_drawer.is_open() and panel._delete_button.disabled, "空装配默认收起目录并禁用删除")
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_check(panel._palette_drawer.is_open() and panel._palette_button.icon != null, "加号通过实际点击展开玻璃目录")
	_check(not panel._palette_details_visible, "目录说明默认收起")
	for id: String in panel.palette_buttons:
		var button: Button = panel.palette_buttons[id]
		_check(button.is_visible_in_tree() and button.icon != null and not button.text.is_empty(), "目录保留图标与名称：" + id)
		_check(not panel._palette_descriptions[id].is_visible_in_tree() and not panel._palette_reasons[id].is_visible_in_tree(), "默认隐藏说明与常驻原因：" + id)
	_check(panel.palette_buttons["melee"].disabled and not panel.palette_buttons["melee"].get_tooltip().is_empty(), "未解锁模块仍可辨识并保留悬停原因")
	var drawer_bounds := panel._palette_drawer._panel.get_global_rect()
	var details_bounds := panel._palette_details_button.get_global_rect()
	_check(drawer_bounds.position.is_equal_approx(panel._palette_button.get_global_rect().position), "侧栏从加号原位置展开，左上角保持固定")
	_click(details_bounds.get_center())
	await _settle()
	_check(panel._palette_details_visible, "说明按钮统一展开模块说明")
	_check(panel._palette_drawer._panel.get_global_rect().is_equal_approx(drawer_bounds) and panel._palette_details_button.get_global_rect().is_equal_approx(details_bounds), "展开说明不改变侧栏宽高或入口位置，长内容仅内部滚动")
	for label: Label in panel._palette_descriptions.values():
		_check(label.is_visible_in_tree(), "展开后模块说明可见")
	_click(panel._palette_details_button.get_global_rect().get_center())
	await _settle()
	_check(not panel._palette_details_visible, "再次点击统一收起说明")
	_check(panel._palette_drawer._panel.get_global_rect().is_equal_approx(drawer_bounds) and panel._palette_details_button.get_global_rect().is_equal_approx(details_bounds), "收起说明保留相同侧栏边界与空白，不向上缩短")
	var selected := panel.selected_module_id
	_game.settings.set_language("en")
	await _settle()
	_check(panel._palette_drawer.is_open() and panel.selected_module_id == selected, "切换英语保留打开状态与当前模块")
	_check(panel.palette_buttons["movement"].get_tooltip() != "" and panel._palette_details_button.get_tooltip() != "", "英语目录仍提供操作提示")
	_game.settings.set_language("zh_CN")
	await _settle()
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_check(not panel._palette_drawer.is_open() and _signature() == initial and _changes == changes, "再次点击加号关闭目录，全程不写装配草稿")
	# 把真实可放置原点移到抽屉内的模块按钮下，检查选择点击不会穿透成放置。
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	var covered_point: Vector2 = panel.palette_buttons["movement"].get_global_rect().get_center()
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_check(canvas.get_global_rect().has_point(covered_point), "目录模块按钮覆盖蓝图可交互视口")
	_drag(_point(canvas, Vector2.ZERO), covered_point, MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(_point(canvas, Vector2.ZERO).distance_to(covered_point) < 1.0, "可放置原点位于抽屉按钮正下方")
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_click(covered_point)
	await _settle()
	_check(not panel._palette_drawer.is_open() and panel.selected_module_id == "movement" and _signature() == initial and _changes == changes, "选择模块自动关闭目录，按下抬起都不会穿透放置")
	canvas.reset_view()
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_click(_point(canvas, Vector2.ZERO))
	await _settle()
	_check(not panel._palette_drawer.is_open() and _signature() == initial, "外点原点仅关闭目录，不误安装模块")
	_click(_point(canvas, Vector2.ZERO))
	await _settle()
	_check(_game.session.assembly.modules.size() == 1, "关闭目录后下一次左键才安装模块")


## 缩放和平移仅改变观察状态，变换后的放置、拖动、键盘及按钮删除仍准确命中。
func _test_view_and_edit() -> void:
	var panel := _game.assembly_panel
	var canvas := panel.canvas
	var before := _signature()
	var changes := _changes
	var source := _game.session.source
	_check(canvas._paper_rect().size.x > canvas._paper_rect().size.y and canvas.clip_contents, "蓝图为横向矩形且超出视口内容被裁剪")
	_click(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_RIGHT)
	_check(_signature() == before and _changes == changes, "右键单击已有模块不会删除或改草稿")
	var start := _point(canvas, Vector2.ZERO)
	_drag(start, start + Vector2(80, -35), MOUSE_BUTTON_RIGHT)
	await _settle()
	_check(_point(canvas, Vector2.ZERO).distance_to(start + Vector2(80, -35)) < 1.0 and not canvas._pan_dragging, "右拖平移整张图纸，释放后结束抓手")
	var anchor := _point(canvas, Vector2(0.5, 0.5))
	var anchor_offset := canvas.offset_at(canvas.get_global_transform_with_canvas().affine_inverse() * anchor)
	var spacing := _point(canvas, Vector2(0.5, 0)).distance_to(_point(canvas, Vector2.ZERO))
	_click(anchor, MOUSE_BUTTON_WHEEL_UP)
	await _settle()
	_check(_point(canvas, Vector2(0.5, 0)).distance_to(_point(canvas, Vector2.ZERO)) > spacing, "滚轮放大真实显示网格")
	_check(canvas.offset_at(canvas.get_global_transform_with_canvas().affine_inverse() * anchor) == anchor_offset, "缩放保留鼠标下的装配坐标")
	for unused in 32:
		_click(anchor, MOUSE_BUTTON_WHEEL_UP)
	_check(is_equal_approx(canvas._zoom, AssemblyCanvas.MAX_ZOOM), "连续放大限制在最大倍率")
	for unused in 48:
		_click(anchor, MOUSE_BUTTON_WHEEL_DOWN)
	_check(is_equal_approx(canvas._zoom, AssemblyCanvas.MIN_ZOOM), "连续缩小限制在最小倍率")
	_check(_signature() == before and _changes == changes and _game.session.source == source, "缩放、平移及边界钳制不修改模块、草稿或程序")
	canvas.reset_view()
	_drag(_point(canvas, Vector2.ZERO), _point(canvas, Vector2.ZERO) + Vector2(55, 28), MOUSE_BUTTON_RIGHT)
	_click(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_WHEEL_UP)
	_click(_point(canvas, Vector2(0.5, 0)))
	await _settle()
	_check(_game.session.assembly.modules.size() == 2 and _offset(1) == Vector2(0.5, 0), "缩放平移后左键仍安装到正确半格")
	_drag(_point(canvas, Vector2(0.5, 0)), _point(canvas, Vector2(0, 0.5)), MOUSE_BUTTON_LEFT)
	await _settle()
	_check(_offset(1) == Vector2(0, 0.5), "变换后左拖模块仍提交正确偏移")
	var edited := _signature()
	var edited_changes := _changes
	_drag(_point(canvas, Vector2.ZERO), _point(canvas, Vector2.ZERO) + Vector2(-45, 18), MOUSE_BUTTON_RIGHT)
	_check(_signature() == edited and _changes == edited_changes, "从已有模块开始右拖只平移，不移动或删除模块")
	_click(_point(canvas, Vector2(0, 0.5)))
	_key(KEY_DELETE)
	await _settle()
	_check(_game.session.assembly.modules.size() == 1 and _offset(0) == Vector2.ZERO, "选中后 Delete 删除正确模块并保留中心")
	_click(_point(canvas, Vector2.ZERO))
	_check(not panel._delete_button.disabled, "选中模块后侧边删除圆钮启用")
	_click(panel._delete_button.get_global_rect().get_center())
	await _settle()
	_check(_game.session.assembly.modules.is_empty() and panel._delete_button.disabled and _game._confirm_assembly_button.disabled, "圆形删除按钮复用原规则，删除最后模块后禁止确认")
	canvas.grab_focus()
	_key(KEY_DELETE)
	_check(_game.session.assembly.modules.is_empty(), "没有选中模块时 Delete 无副作用")
	# 窗口外释放必须结束查看，后续鼠标移动不能继续推动图纸。
	var outside := Vector2(5, 5)
	_mouse_button(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_RIGHT, true)
	_motion(outside, outside - _point(canvas, Vector2.ZERO), MOUSE_BUTTON_MASK_RIGHT)
	_mouse_button(outside, MOUSE_BUTTON_RIGHT, false)
	var stopped := canvas._pan
	_motion(Vector2(12, 12), Vector2(7, 7))
	_check(not canvas._pan_dragging and canvas._pan == stopped, "右键在画布外释放后不会留下平移捕获")
	canvas.reset_view()
	_click(_point(canvas, Vector2.ZERO))
	await _settle()
	_check(_game.session.assembly.modules.size() == 1, "结束视图操作后仍可正常重新安装中心模块")


## 任意首件点击只建立显示原点，后续编辑与导出仍采用首件为零的相对坐标。
func _test_reference_origin() -> void:
	var panel := _game.assembly_panel
	var canvas := panel.canvas
	_click(_point(canvas, Vector2.ZERO))
	_key(KEY_DELETE)
	await _settle()
	canvas.reset_view()
	var first_click := _point(canvas, Vector2(1, -1))
	var spacing := _point(canvas, Vector2(0.5, 0)).distance_to(_point(canvas, Vector2.ZERO))
	_click(first_click)
	await _settle()
	_check(_game.session.assembly.modules.size() == 1 and _offset(0) == Vector2.ZERO, "蓝图非中心位置安装首件，模型偏移仍为零")
	_check(_point(canvas, Vector2.ZERO).distance_to(first_click) < 1.0, "首件实际显示在点击位置，不跳回纸张中心")
	# 用点击位置和放置前的格距选相邻格，避免依赖新参考点的内部实现。
	_click(first_click + Vector2(spacing, 0))
	await _settle()
	_check(_game.session.assembly.modules.size() == 2 and _offset(1) == Vector2(0.5, 0), "首件右侧相邻半格记录为相对偏移而非纸张绝对坐标")
	var exported := _game.session.assembly.build_document()
	_check(exported.is_ok() and exported.value.player_spawn.modules.size() == 2 and exported.value.player_spawn.modules[0].offset == {"x": 0.0, "y": 0.0} and exported.value.player_spawn.modules[1].offset == {"x": 0.5, "y": 0.0}, "导出地图仅保存逻辑相对坐标，不写入显示原点")
	var before := _signature()
	var changes := _changes
	_drag(_point(canvas, Vector2.ZERO), _point(canvas, Vector2.ZERO) + Vector2(44, 26), MOUSE_BUTTON_RIGHT)
	_click(_point(canvas, Vector2(0.5, 0)), MOUSE_BUTTON_WHEEL_UP)
	await _settle()
	for offset: Vector2 in [Vector2.ZERO, Vector2(0.5, 0), Vector2(-0.5, 0.5)]:
		_check(canvas.offset_at(canvas.pixel_at(offset)) == offset, "离中心装配缩放平移后像素与逻辑偏移可往返：" + str(offset))
	_check(_signature() == before and _changes == changes, "离中心装配的缩放平移不提交模型或草稿")
	_click(_point(canvas, Vector2(0.5, 0)))
	_check(canvas.selected_index == 1 and _signature() == before, "缩放平移后的实际点击正确选中邻件，不改变布局")
	var unchanged_origin := _point(canvas, Vector2.ZERO)
	var unchanged_changes := _changes
	_click(_point(canvas, Vector2(0, 1.5)))
	await _settle()
	_check(_signature() == before and _changes == unchanged_changes and _point(canvas, Vector2.ZERO).is_equal_approx(unchanged_origin), "不相连放置被拒绝后保留所有模块及显示参考点")
	_click(_point(canvas, Vector2(0.5, 0)))
	_key(KEY_DELETE)
	_click(_point(canvas, Vector2.ZERO))
	_key(KEY_DELETE)
	await _settle()
	_check(_game.session.assembly.modules.is_empty(), "变换后的点击与 Delete 可依次清空离中心装配")
	# 模拟新增入口尚未刷新的未解锁选择，面板最终校验拒绝时不能提前重锚。
	var selected_definition := panel.selected_module_id
	var rejected_origin := _point(canvas, Vector2.ZERO)
	var rejected_changes := _changes
	panel.selected_module_id = "melee"
	_click(_point(canvas, Vector2(-1, 1)))
	await _settle()
	_check(_game.session.assembly.modules.is_empty() and _changes == rejected_changes and _point(canvas, Vector2.ZERO).is_equal_approx(rejected_origin), "首件放置被最终权限校验拒绝时既不写草稿也不改变显示原点")
	panel.selected_module_id = selected_definition
	panel.refresh()
	canvas.reset_view()
	var next_click := _point(canvas, Vector2(-1, 1))
	_click(next_click)
	await _settle()
	_check(_game.session.assembly.modules.size() == 1 and _offset(0) == Vector2.ZERO and _point(canvas, Vector2.ZERO).distance_to(next_click) < 1.0, "删空后下一次首件点击重新建立参考点，逻辑偏移仍为零")


## 从正在查看的自由视图关回固定图纸时释放抓手、恢复完整边框且不修改装配。
func _test_switch_to_fixed() -> void:
	var canvas := _game.assembly_panel.canvas
	var before := _signature()
	var changes := _changes
	for unused in 8:
		_click(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_WHEEL_UP)
	var start := _point(canvas, Vector2.ZERO)
	_mouse_button(start, MOUSE_BUTTON_RIGHT, true)
	_motion(start + Vector2(65, 25), Vector2(65, 25), MOUSE_BUTTON_MASK_RIGHT)
	_check(canvas._pan_dragging, "开关测试从实际抓手平移状态开始")
	_game.settings.set_assembly_free_zoom(false)
	_mouse_button(start + Vector2(65, 25), MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not canvas.free_zoom_enabled and not canvas._pan_dragging and canvas.material == null, "关闭设置即时结束自由平移并移除边缘淡出")
	_check(Rect2(Vector2.ZERO, canvas.size).grow(0.1).encloses(canvas._paper_rect()), "关回固定模式后完整外框重新进入视口")
	_check(_signature() == before and _changes == changes and canvas.offset_at(canvas.pixel_at(Vector2.ZERO)) == Vector2.ZERO, "切换显示方式保留全部模块、逻辑原点及草稿")
	_game.settings.set_assembly_free_zoom(true)
	await _settle()
	var spacing := _point(canvas, Vector2(0.5, 0)).distance_to(_point(canvas, Vector2.ZERO))
	_click(_point(canvas, Vector2.ZERO), MOUSE_BUTTON_WHEEL_UP)
	_check(canvas.free_zoom_enabled and _point(canvas, Vector2(0.5, 0)).distance_to(_point(canvas, Vector2.ZERO)) > spacing, "重新开启后滚轮放大恢复生效")
	_game.settings.set_assembly_free_zoom(false)
	await _settle()


## 指引、工作台页签和页面销毁均关闭独立画布层，不留下不可见输入屏障。
func _test_lifecycle() -> void:
	var panel := _game.assembly_panel
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	_key(KEY_ESCAPE)
	await _settle()
	_check(not panel._palette_drawer.is_open(), "Esc 关闭模块抽屉")
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	panel._rules_button.pressed.emit()
	await _settle()
	_check(not panel._palette_drawer.is_open() and panel._rules_menu.is_open(), "装配规则与模块目录互斥显示")
	panel._rules_menu.close_menu(false)
	_click(panel._palette_button.get_global_rect().get_center())
	await _settle()
	var preparation_drawer := panel._palette_drawer
	_game._confirm_assembly_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.PLAY and (not is_instance_valid(preparation_drawer) or not preparation_drawer.is_open()), "确认进入程序页时清理准备页抽屉")
	if _game.workbench == null:
		return
	_game.workbench.set_process(false)
	_game.workbench._tabs.current_tab = 1
	await _settle()
	var workbench_panel := _game.workbench._assembly_panel
	_check(not workbench_panel.canvas.free_zoom_enabled and workbench_panel.canvas.material == null, "新工作台装配页签沿用已关闭的自由缩放设置")
	_game.settings.set_assembly_free_zoom(true)
	_check(workbench_panel.canvas.free_zoom_enabled, "已创建的工作台装配页签也即时接收设置变更")
	_game.settings.set_assembly_free_zoom(false)
	_click(workbench_panel._palette_button.get_global_rect().get_center())
	await _settle()
	_check(workbench_panel._palette_drawer.is_open(), "工作台装配页签使用同一模块抽屉")
	_game.workbench._tabs.current_tab = 0
	await _settle()
	_check(not workbench_panel._palette_drawer.is_open(), "隐藏工作台装配页签立即关闭 CanvasLayer 抽屉")
	_game.workbench._tabs.current_tab = 1
	await _settle()
	_click(workbench_panel._palette_button.get_global_rect().get_center())
	await _settle()
	var workbench_drawer := workbench_panel._palette_drawer
	_game._back_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.LEVELS and (not is_instance_valid(workbench_drawer) or not workbench_drawer.is_open()), "退出关卡时抽屉随所属页面销毁")


## 记录真实模型变更信号，查看操作不能以内容相同为由掩盖多余草稿写入。
func _record_change() -> void:
	_changes += 1


## 直接比较模块完整数据，包括实例名、顺序和位置。
func _signature() -> String:
	return JSON.stringify(_game.session.assembly.modules, "", true)


## 读取已安装模块偏移供实际操作结果断言。
func _offset(index: int) -> Vector2:
	if index >= _game.session.assembly.modules.size():
		return Vector2.INF
	var point: Dictionary = _game.session.assembly.modules[index].offset
	return Vector2(float(point.x), float(point.y))


## 转换真实装配坐标为视口点位，输入仍走窗口分发和遮挡判断。
func _point(canvas: AssemblyCanvas, offset: Vector2) -> Vector2:
	return canvas.get_global_transform_with_canvas() * canvas.pixel_at(offset)


## 完整点击经过 Godot 分发，覆盖浮层吞按下与抬起。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_motion(point)
	_mouse_button(point, button, true)
	_mouse_button(point, button, false)


## 完整拖动同时携带相对位移与正确按钮掩码。
func _drag(from: Vector2, to: Vector2, button: MouseButton) -> void:
	_motion(from)
	_mouse_button(from, button, true)
	_motion(to, to - from, MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(to, button, false)


## 向真实视口发送鼠标事件而非直接发射画布信号。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	if pressed and button <= MOUSE_BUTTON_MIDDLE:
		event.button_mask = 1 << (button - 1)
	root.push_input(event)


## 模拟普通移动与拖动，使光标命中和抓手捕获一并接受验证。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: int = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event)


## 按下与抬起都发送，防止测试留下键盘状态。
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)


## 等待浮层动画和容器布局稳定，使用短等待避免测试阻塞。
func _settle() -> void:
	await create_timer(0.25).timeout


## 汇总失败但继续检查独立行为，完成标记可供统一测试入口识别。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只清除本次独占测试目录，绝不接触玩家作品。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
