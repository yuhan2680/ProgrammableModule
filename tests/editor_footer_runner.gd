extends SceneTree
## 顶部图标操作与按需红字使用真实点击，保存与试玩均在独占用户目录内完成。

var _checks := 0
var _failures := 0
var _game: GameShell
var _editor: MapEditor
var _temporary := ""
var _capture_dir := ""


## 可选截图来自真实GPU视口，普通无窗口回归只核验实际控件边界。
func _initialize() -> void:
	Engine.max_fps = 120
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 覆盖保存草稿、失败反馈、无终点自由测试、语言与Windows高分屏几何。
func _run() -> void:
	_temporary = "user://tests/footer_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.settings_path = _temporary.path_join("settings.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	_editor = _game._editor
	await _test_actions()
	await _test_geometry()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("EDITOR_FOOTER_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 小地图保留完整可通行地板，终点和出生点由测试按需设置。
func _fixture() -> MapDocument:
	var document := MapDocument.new()
	document.id = "footer_fixture"
	document.display_name = "编辑操作测试"
	document.width = 8
	document.height = 6
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]}
	document.properties = {"level": {"allowed_modules": ["movement"], "module_limit": 1, "max_ticks": 600, "completion_mode": "reach_or_clear"}, "extension": "keep"}
	return document


## 无效测试只出现卡内红字；顶部测试图标与页头保存仍沿原有业务流程执行。
func _test_actions() -> void:
	_check(not _editor._test_feedback.visible, "初始隐藏底部说明和检测提示")
	var document := _fixture()
	document.player_spawn = null
	_editor.editor_document.replace_document(document)
	await _settle()
	await _click(_editor._play_button)
	_check(_game.page == GameShell.Page.EDITOR and _game.session == null and _editor._test_feedback.visible and _editor._test_feedback.text == "此关卡缺乏出生点", "缺少出生点阻止试玩并显示简明原因")
	_check(not _editor._message_dialog.visible and _editor._test_feedback.get_theme_color("font_color") == Color("bb3434"), "测试失败使用指定红色小字，不弹出错误窗口")
	_game.settings.set_language("en")
	await _settle()
	_check(_editor._test_feedback.text == "This level has no player spawn point", "已有检测结果跟随语言切换")
	_game.settings.set_language("zh_CN")
	await _settle()
	await _click(_editor._header.save_button)
	var path := _editor._managed_save_path
	var saved := MapCodec.load_file(path, _editor.registry, false)
	_check(path.begins_with(_temporary.path_join("levels")) and saved.is_ok() and saved.value.player_spawn == null and not _editor.editor_document.is_dirty(), "页头保存按钮沿用普通保存并允许未完成草稿")
	_check(saved.is_ok() and saved.value.properties.extension == "keep", "保存保留全部扩展字段")
	_editor.editor_document.replace_document(_fixture())
	await _settle()
	_check(not _editor._test_feedback.visible, "修改或更换地图清除上次问题，不常驻灰色说明")
	_editor._validate_document()
	await _settle()
	_check(_editor._test_feedback.visible and _editor._test_feedback.text == "此关卡缺乏终点" and not _editor._message_dialog.visible, "主动校验无终点地图显示红字提醒")
	await _click(_editor._play_button)
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and not _game.session.level.has_goal, "缺少终点只提醒，仍进入正常空装配自由测试")
	_game._dialogue_dialog.hide()
	_game._return_to_editor()
	await _settle()
	_check(_editor._test_feedback.visible and _editor._test_feedback.text == "此关卡缺乏终点", "自由测试返回后可查看此前红字提醒")
	_editor.editor_document.place_goal(Vector2i(6, 4))
	await _settle()
	_editor._validate_document()
	await _settle()
	_check(not _editor._test_feedback.visible, "补齐终点后校验成功不显示说明或旧错误")
	document = _fixture()
	document.objects = [{"id": "bad_gate", "type": "timed_gate", "position": {"x": 3.5, "y": 3.5}, "size": 1, "properties": {"close_after_ticks": 600}}]
	_editor.editor_document.replace_document(document)
	await _settle()
	_editor._validate_document()
	await _settle()
	_check(_editor._test_feedback.visible and _editor._test_feedback.text.contains("小于关卡总时间") and not _editor._message_dialog.visible, "不合理闸门在校验时也使用卡内红字")
	_editor.editor_document.replace_document(_fixture())
	await _settle()


## 顶部蓝色圆形测试入口在滚动和缩放后仍可见，页签与错误反馈保留独立空间。
func _test_geometry() -> void:
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	for resolution in ["1280x800", "1920x1080", "3840x2160"]:
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(resolution):
			continue
		_game.settings.set_window_resolution(resolution)
		for language in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(language)
			for percentage in [100, 125, 150, 200]:
				_game.settings.set_ui_scale(percentage)
				await _settle(8)
				var context: String = resolution + language + str(percentage)
				var card := _editor._properties_card
				var bounds := card.get_global_rect()
				var play := _editor._play_button.get_global_rect()
				var save := _editor._header.save_button.get_global_rect()
				_check(bounds.encloses(play) and _editor._header.get_global_rect().encloses(save) and root.get_visible_rect().grow(1).encloses(bounds), "测试位于属性卡片顶部，保存位于页头且均完整显示 " + context)
				var scale := card.get_global_transform().get_scale().x
				_check(play.size.is_equal_approx(Vector2(32, 32) * scale) and _editor._play_button.text.is_empty() and _editor._play_button.icon != null and not _editor._play_button.tooltip_text.is_empty(), "测试为固定32px纯图标圆形入口并保留提示 " + context)
				var glass := _editor._play_button.find_child("BlueConfirmationGlass", true, false) as ColorRect
				var material := glass.material as ShaderMaterial if glass != null else null
				_check(glass != null and material != null and material.shader.resource_path.ends_with("editor_confirm_glass.gdshader") and glass.get_global_rect().is_equal_approx(play) and glass.mouse_filter == Control.MOUSE_FILTER_IGNORE and _editor._play_button.get_theme_color("icon_normal_color") == Color.WHITE, "蓝色玻璃材质覆盖圆形入口，白图标保留且背景不抢点击 " + context)
				_check(_editor.find_child("MapEditorSaveLevel", true, false) == null, "底部不再残留重复保存按钮 " + context)
				var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
				_check(play.end.y <= scroll.global_position.y, "测试图标在滚动表单上方，不占用正文或底部空间 " + context)
				for node_name in ["MapEditorEditTab", "MapEditorGuideTab"]:
					var tab := _editor.find_child(node_name, true, false) as Control
					_check(tab != null and bounds.encloses(tab.get_global_rect()) and not play.intersects(tab.get_global_rect()), "顶部页签与测试图标各有独立命中区 " + context + " " + node_name)
				scroll.scroll_vertical = roundi(scroll.get_v_scroll_bar().max_value)
				await _settle()
				_check(_editor._play_button.get_global_rect() == play and _editor._header.save_button.get_global_rect() == save, "正文滚动不移动顶部测试和页头保存入口 " + context)
				_editor._show_test_feedback(PackedStringArray(["此关卡缺乏出生点"] ))
				await _settle()
				_check(bounds.encloses(_editor._test_feedback.get_global_rect()) and not _editor._test_feedback.get_global_rect().intersects(_editor._play_button.get_global_rect()), "红字自动换行且不覆盖顶部操作 " + context)
				await _capture("footer_%s_%s_%d" % [resolution, language, percentage])
				_editor._clear_test_feedback()
				scroll.scroll_vertical = 0
				await _settle()


## 鼠标输入沿正式GUI路由分派，不直接调用按钮动作。
func _click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.pressed = pressed
		event.button_index = MOUSE_BUTTON_LEFT
		root.push_input(event)
	await _settle()


## 等待原生布局、表单提交和页面切换完成。
func _settle(frames: int = 6) -> void:
	for index in frames:
		await process_frame


## 截图只来自运行中的真实渲染器，不使用模拟图片替代布局检查。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_capture_dir.path_join(filename + ".png"))


## 将断言交给统一回归脚本，同时拒绝有引擎异常的零退出。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 只清理本轮测试自己的用户目录，不访问正式关卡、设置与进度。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
