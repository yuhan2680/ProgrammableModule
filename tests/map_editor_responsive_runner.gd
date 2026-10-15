extends SceneTree
## 使用真实属性栏与字体控制器验证长翻译重排，独立设置目录不触碰玩家数据。

var _checks := 0
var _failures := 0
var _fixture: Control
var _editor: MapEditor
var _fonts: GameFontScale
var _temporary := ""
var _capture_directory := ""


## 在场景树可用后建立隔离窗口，截图仅走真实 GPU 视口。
func _initialize() -> void:
	Engine.max_fps = 120
	_run.call_deferred()


## 五语、三个字号和不同窄幅共同验证同一套布局，不为单一翻译设置特殊断点。
func _run() -> void:
	_temporary = "user://tests/editor_responsive_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	GameI18n.install()
	var old_locale := TranslationServer.get_locale()
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 800)
	_fixture = Control.new()
	_fixture.theme = GameTheme.create_theme()
	root.add_child(_fixture)
	_fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = GameTheme.BACKGROUND
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixture.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fonts = GameFontScale.new()
	_fonts.scope = _fixture
	_fixture.add_child(_fonts)
	_editor = MapEditor.new()
	_editor.settings = GameSettings.new(_temporary.path_join("settings.json"))
	_editor.player_levels_directory = _temporary.path_join("levels")
	_fixture.add_child(_editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	var document := _editor.editor_document.document.to_dict()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740), Vector2i(800, 640)]:
		root.size = dimensions
		await _settle()
		var expected_width := _editor._properties_card.size.x
		for language: String in ["zh_CN", "zh_HK", "es", "en", "ja"]:
			TranslationServer.set_locale(language)
			for percentage: int in [100, 150, 200]:
				_fonts.set_percentage(percentage)
				await _settle()
				var context := "%s %dx%d %d%%" % [language, dimensions.x, dimensions.y, percentage]
				_check_geometry(expected_width, context)
				await _check_accessibility(context)
				_check(_editor.editor_document.document.to_dict() == document and not _editor.editor_document.can_undo(), "语言、字号和重排均不提交编辑事务 " + context)
				if language == "ja" and percentage in [100, 200] and dimensions.x in [1280, 1000]:
					await _capture("editor_%s_%d_top" % [str(dimensions.x), percentage], _editor._name_field)
					await _capture("editor_%s_%d_gameplay" % [str(dimensions.x), percentage], _editor._restrict_code_paste_switch)
					await _capture("editor_%s_%d_enemy" % [str(dimensions.x), percentage], _editor._enemy_panel.health_field)
	await _check_editing()
	_fixture.queue_free()
	await _settle()
	TranslationServer.set_locale(old_locale)
	_cleanup(_temporary)
	print("地图属性响应式回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 卡片不能因长文本反向撑开；每个实际标签与点击区域保留完整边界且互不重叠。
func _check_geometry(expected_width: float, context: String) -> void:
	var card := _editor._properties_card
	_check(root.get_visible_rect().grow(1).encloses(card.get_global_rect()) and card.size.x <= 460.5, "属性白卡留在窗口且宽度有界 " + context + " " + str(card.get_global_rect()))
	_check(absf(card.size.x - expected_width) < 1.1, "长翻译与大字号只增高不撑宽卡片 " + context)
	var fields := _editor.find_child("MapEditorPropertiesFields", true, false) as Control
	for row: ResponsivePropertyRow in _rows(_editor):
		var controls: Array[Control] = []
		for child in row.get_children():
			if child is Control and child.visible:
				controls.append(child)
		var bounds := row.get_global_rect().grow(1.1)
		for index in controls.size():
			var child := controls[index]
			_check(bounds.encloses(child.get_global_rect()), "关联控件完整留在本行 " + context + " " + str(child.get_path()) + " " + str(child.get_rect()) + " / " + str(row.size))
			if child is Label and index + 1 < controls.size():
				var next := controls[index + 1]
				if child.get_global_rect().end.x <= next.global_position.x:
					_check(absf(child.get_global_rect().get_center().y - next.get_global_rect().get_center().y) <= 1.1, "多行标签与对应控件垂直居中 " + context + " " + child.text)
			for other_index in range(index + 1, controls.size()):
				_check(not child.get_global_rect().grow(-0.1).intersects(controls[other_index].get_global_rect()), "相邻栏目无交叠 " + context + " " + str(row.get_path()))
			if child is Label:
				var label := child as Label
				var base := roundi(GameTheme.base_font_size(label, "font_size") * GameTheme.font_scale(label))
				_check(not label.clip_text and label.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and label.max_lines_visible == -1, "标签完整换行而非裁切或省略 " + context)
				_check(label.get_theme_font_size("font_size") >= roundi(base * 0.85) and label.get_theme_font_size("font_size") <= base, "标签仅适度缩小并保留字号偏好 " + context)
				_check(label.get_line_count() <= label.get_visible_line_count(), "换行后全部文字行可见 " + context + " " + label.text)
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	_check(scroll.get_v_scroll_bar().global_position.x - fields.get_global_rect().end.x >= 17.9, "重排后滚动条与正文仍有独立留白 " + context)
	for button: Button in [_editor._play_button, _editor._save_level_button]:
		_check(card.get_global_rect().grow(1).encloses(button.get_global_rect()) and root.get_visible_rect().grow(1).encloses(button.get_global_rect()) and not scroll.get_global_rect().intersects(button.get_global_rect()), "底部操作常驻且避开滚动正文 " + context + " " + str(button.name))
	if GameTheme.font_scale(_editor) >= 2.0:
		var player := _editor.find_child("MapEditorPlayerLimits", true, false) as ResponsivePropertyRow
		var enemy := _editor.find_child("MapEditorEnemyLimits", true, false) as ResponsivePropertyRow
		_check(player.stacked and enemy.stacked, "大字号多栏数值组自动改为一栏 " + context)


## 真实滚动逐项到达表单底部，增加行高不应让任何字段被固定操作区遮住。
func _check_accessibility(context: String) -> void:
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	for field: Control in [_editor._id_field, _editor._creator_field, _editor._height_field, _editor._brush, _editor._gate_timer_field, _editor._time_limit_field, _editor._allow_code_hints_switch, _editor._restrict_code_paste_switch, _editor._module_limit_field, _editor._player_health_field, _editor._enemy_panel.health_field]:
		scroll.ensure_control_visible(field)
		await _settle(2)
		_check(scroll.get_global_rect().grow(1).encloses(field.get_global_rect()), "滚动后字段完整可达 " + context + " " + str(field.name))


## 在聚焦编辑中切换语言、字号和宽度，不重建节点、不改文本选区，提交仍是一次可撤销事务。
func _check_editing() -> void:
	var field := _editor._name_field
	var identity := field.get_instance_id()
	var original := _editor.editor_document.document.display_name
	field.grab_focus()
	field.text = "responsive draft"
	field.text_changed.emit(field.text)
	field.caret_column = 6
	field.select(2, 6)
	root.size = Vector2i(1280, 800)
	_fonts.set_percentage(100)
	TranslationServer.set_locale("en")
	await _settle()
	_check(_editor._name_field.get_instance_id() == identity and field.has_focus() and field.text == "responsive draft" and field.caret_column == 6 and field.get_selection_from_column() == 2 and field.get_selection_to_column() == 6, "重排保留原输入实例、焦点、草稿与选区")
	_check(_editor.editor_document.document.display_name == original and not _editor.editor_document.can_undo(), "重排期间未提交正在输入的名称")
	field.text_submitted.emit(field.text)
	await _settle()
	_check(_editor.editor_document.document.display_name == "responsive draft" and _editor.editor_document._undo_stack.size() == 1, "重排后正常提交仍只有一次事务")
	_editor._undo()
	_check(_editor.editor_document.document.display_name == original, "撤销仍恢复重排前的文档名称")


## 递归取得新容器，断言基于最终矩形而非布局算法分支。
func _rows(node: Node) -> Array[ResponsivePropertyRow]:
	var rows: Array[ResponsivePropertyRow] = []
	if node is ResponsivePropertyRow:
		rows.append(node)
	for child in node.get_children():
		rows.append_array(_rows(child))
	return rows


## 等待容器排序、文本换行及滚动裁剪同步完成。
func _settle(frames: int = 12) -> void:
	for index in frames:
		await process_frame


## 截取 GPU 实际窗口；无渲染模式保留相同几何断言但不伪造图片。
func _capture(filename: String, field: Control) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	if field == _editor._name_field:
		scroll.scroll_vertical = 0
	else:
		scroll.ensure_control_visible(field)
		scroll.scroll_vertical += 42
	await _settle()
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	root.get_texture().get_image().save_png(_capture_directory.path_join(filename + ".png"))


## 汇总失败，继续检查其他语言，便于定位局部溢出。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	return condition


## 仅递归清理本进程专属测试目录。
func _cleanup(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for filename in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(dirname))
	DirAccess.remove_absolute(path)
