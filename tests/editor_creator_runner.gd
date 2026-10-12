extends SceneTree
## 创作者输入回归覆盖真实编辑器表单、未失焦保存、历史和三语布局，存储全部隔离。

var _checks := 0
var _failures := 0
var _temporary: String
var _game: GameShell
var _capture_dir := ""


## 延迟初始化，并允许显式要求输出真实 GPU 截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 进入正式编辑器，测试署名提交、文件往返和窄窗口布局。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/editor_creator_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	var editor := _game._editor
	var model := editor.editor_document
	var field := editor._creator_field
	_check(field != null and field.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED and field.max_length == 0 and editor._name_field.max_length == 0, "名称与署名输入完整保留原文，由提交校验限制长度")
	_check(field.text.is_empty() and not model.is_dirty(), "无署名的旧地图打开后仍为空且不会被自动修改")
	field.grab_focus()
	field.text = "Muna"
	editor._save_document(false)
	var path := model.path
	var saved := MapCodec.load_file(path, editor.registry, false)
	_check(saved.is_ok() and saved.value.properties.level.creator == "Muna" and not model.is_dirty(), "输入仍有焦点时普通保存也提交Muna署名")
	_check(path.begins_with(_game.user_levels_directory + "/"), "署名地图保存到既有玩家关卡目录")
	field.release_focus()
	model.undo()
	_check(model.get_creator().is_empty() and model.is_dirty() and field.text.is_empty(), "创作者修改可以撤销并同步表单")
	model.redo()
	_check(model.get_creator() == "Muna" and not model.is_dirty() and field.text == "Muna", "重做回到保存点恢复署名及未修改状态")
	field.grab_focus()
	field.text = "月 Muna 🌙 %"
	field.text_submitted.emit(field.text)
	_check(model.get_creator() == "月 Muna 🌙 %", "回车提交中文、空格、emoji和百分号原文")
	field.release_focus()
	editor._file_dialog.use_native_dialog = false
	editor._save_document(true)
	var export_path := _temporary.path_join("exports/creator.json")
	editor._file_dialog.file_selected.emit(export_path)
	editor._file_dialog.hide()
	var exported := MapCodec.load_file(export_path, editor.registry, false)
	_check(exported.is_ok() and exported.value.properties.level.creator == model.get_creator(), "另存为JSON完整保留创作者")
	editor._new_document()
	_check(field.text == _game.profile.get_username() and model.get_creator() == _game.profile.get_username() and model.get_creator() != "月 Muna 🌙 %", "新建使用当前玩家名，不继承上一张地图的署名")
	editor._load_document(export_path)
	_check(field.text == "月 Muna 🌙 %" and not model.is_dirty(), "重新打开恢复创作者且不产生虚假修改")
	field.grab_focus()
	field.text = ""
	editor._save_document(false)
	saved = MapCodec.load_file(model.path, editor.registry, false)
	_check(saved.is_ok() and not saved.value.properties.level.has("creator"), "清空署名保存后删除可选字段，不保留上一次名字")
	field.release_focus()
	model.set_creator("Muna")
	await _test_layout(editor)
	_game.settings.set_language("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _settle()
	await _capture()
	await _test_read_only_identity(editor)
	await _test_invalid_creator(editor)
	await _test_identity_lengths(editor)
	await _test_identity_metadata(editor)
	# 返回保护同样提交尚未失焦的名字，不会把作者遗漏在退出保存之外。
	field.grab_focus()
	field.text = "离开前的新署名"
	_game._go_back()
	await _settle()
	_check(model.get_creator() == "离开前的新署名" and _game._editor_discard_dialog.visible, "返回动作提交待编辑署名并触发未保存保护")
	_game._editor_discard_dialog.hide()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("创作者编辑界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 程序篡改只读显示值不能借名称提交改写文档 ID，合法名称、署名和副标题仍可提交并保存。
func _test_read_only_identity(editor: MapEditor) -> void:
	var model := editor.editor_document
	var identity := model.document.id
	var path := model.path
	_check(not editor._id_field.editable and editor._id_field.text == identity, "打开旧地图后 ID 原样显示且保持只读")
	for candidate in ["manually_changed_id", " invalid / id "]:
		_set_identity_text(editor._id_field, candidate)
		_set_identity_text(editor._name_field, "ID保护 " + str(candidate.length()))
		_set_identity_text(editor._creator_field, "Muna")
		_set_identity_text(editor._subtitle_field, "只读ID下仍可修改副标题")
		_check(editor._commit_identity(), "篡改显示 ID 不会阻止其它合法身份字段提交：" + candidate)
		_check(model.document.id == identity and model.document.display_name == "ID保护 " + str(candidate.length()) and model.get_creator() == "Muna" and model.get_subtitle() == "只读ID下仍可修改副标题", "身份提交使用文档 ID 且保留名称、署名和副标题修改")
		_check(editor._id_field.text == identity, "合法提交后只读 ID 显示恢复文档原值")
		model.undo()
		_check(model.document.id == identity, "撤销合法名称修改仍保留原 ID")
		model.redo()
		_check(model.document.id == identity, "重做合法名称修改仍保留原 ID")
	editor._save_document(false)
	var saved := MapCodec.load_file(model.path, editor.registry, false)
	_check(saved.is_ok() and saved.value.id == identity and model.path == path and not model.is_dirty(), "篡改显示字段后保存仍写入原 ID 和同一托管文件")
	await _settle()


## 非法署名不能被静默丢弃后继续保存、另存为、试玩或退出。
func _test_invalid_creator(editor: MapEditor) -> void:
	editor._save_document(false)
	var model := editor.editor_document
	var field := editor._creator_field
	var path := model.path
	var saved_hash := FileAccess.get_sha256(path)
	var save_results: Array[bool] = []
	var play_requests: Array[bool] = []
	editor.save_finished.connect(func(success: bool) -> void: save_results.append(success))
	editor.playtest_requested.connect(func(_definition: LevelDefinition, _content: ContentRegistry) -> void: play_requests.append(true))
	var invalid := "Mu" + String.chr(0x2028) + "na"
	field.grab_focus()
	field.text = invalid
	editor._save_document(false)
	_check(save_results == [false] and FileAccess.get_sha256(path) == saved_hash, "非法署名保存明确失败且不改写已有文件")
	_check(field.text == invalid and model.get_creator() == "Muna", "非法输入保留供修正，旧署名保持完整")
	editor._message_dialog.hide()
	editor._save_document(true)
	_check(save_results == [false, false] and not editor._file_dialog.visible, "非法署名另存为失败且不打开文件选择")
	editor._message_dialog.hide()
	editor._request_action("new")
	_check(model.path == path and field.text == invalid and not editor._dirty_dialog.visible, "非法署名阻止新建覆盖待修正输入")
	editor._message_dialog.hide()
	editor._start_playtest()
	_check(play_requests.is_empty() and _game.page == GameShell.Page.EDITOR, "非法署名不会以旧数据进入试玩")
	editor._message_dialog.hide()
	_game._go_back()
	_check(_game.page == GameShell.Page.EDITOR and not _game._editor_discard_dialog.visible and field.text == invalid, "非法署名返回时保持编辑器与原输入")
	editor._message_dialog.hide()
	field.text = "Muna"
	_check(editor._commit_identity(), "修正后可正常提交")
	field.release_focus()
	await _settle()


## 真实输入保留完整长文本，组合校验失败阻止保存、导出、试玩和返回；旧值仍可无损往返。
func _test_identity_lengths(editor: MapEditor) -> void:
	var model := editor.editor_document
	var name := editor._name_field
	var creator := editor._creator_field
	for unit in ["月", "x"]:
		name.grab_focus()
		_set_identity_text(name, unit.repeat(30))
		_set_identity_text(creator, unit.repeat(11))
		_check(editor._commit_identity() and model.document.display_name == unit.repeat(30) and model.get_creator() == unit.repeat(11), "中英文名称30字符、署名11字符可一起提交")
		editor._save_document(false)
		var path := model.path
		var saved_hash := FileAccess.get_sha256(path)
		var old_id := model.document.id
		_set_identity_text(name, unit.repeat(31))
		_set_identity_text(creator, "Muna")
		_check(not editor._commit_identity(), "超长名称提交被拒绝")
		_check(model.document.id == old_id and model.document.display_name == unit.repeat(30) and model.get_creator() == unit.repeat(11), "超长名称不能部分写入 ID 和署名")
		_check(name.text.length() == 31 and name.text == unit.repeat(31), "超长粘贴原文不截断为合法名称")
		editor._message_dialog.hide()
		model.set_module_limit(3)
		_check(name.text == unit.repeat(31) and editor._id_field.text == old_id and creator.text == "Muna", "失焦后修改其它属性保留待修正名称署名和只读 ID")
		editor._save_document(false)
		_check(FileAccess.get_sha256(path) == saved_hash and editor._message_dialog.visible, "无效名称普通保存不覆盖有效文件")
		editor._message_dialog.hide()
		editor._file_dialog.use_native_dialog = false
		editor._save_document(true)
		_check(not editor._file_dialog.visible and FileAccess.get_sha256(path) == saved_hash, "无效名称另存为不打开系统选择窗口")
		editor._message_dialog.hide()
		editor._start_playtest()
		_check(_game.page == GameShell.Page.EDITOR, "无效名称不能使用旧数据开始试玩")
		editor._message_dialog.hide()
		_game._go_back()
		_check(_game.page == GameShell.Page.EDITOR and not _game._editor_discard_dialog.visible and name.text == unit.repeat(31), "无效名称阻止返回并保留原文")
		editor._message_dialog.hide()
		_set_identity_text(name, unit.repeat(30))
		_set_identity_text(creator, unit.repeat(12))
		_check(not editor._commit_identity() and creator.text == unit.repeat(12), "十二字符署名保持原文且提交失败")
		_check(model.document.id == old_id and model.get_creator() == unit.repeat(11), "超长署名不能部分提交 ID 或替换旧署名")
		editor._message_dialog.hide()
		editor._save_document(false)
		_check(FileAccess.get_sha256(path) == saved_hash, "无效署名普通保存不覆盖原文件")
		editor._message_dialog.hide()
		_set_identity_text(creator, "Muna")
		_check(editor._commit_identity(), "修正后可提交保存")
		editor._save_document(false)
		_check(not model.is_dirty(), "修正后的有效字段正常保存")
	name.release_focus()
	creator.release_focus()
	var legacy := model.document.duplicate_document()
	legacy.display_name = "历史长名称".repeat(8)
	legacy.properties.level.creator = "  历史长署名".repeat(5) + "  "
	model.replace_document(legacy, model.path)
	_check(name.text == legacy.display_name and creator.text == legacy.properties.level.creator, "旧长名称和署名在表单里完整回显")
	editor._on_document_changed()
	_check(editor._commit_identity() and not model.is_dirty() and not model.can_undo(), "同步与未修改提交不会裁剪旧长字段")
	model.set_module_limit(2)
	editor._save_document(false)
	var loaded := MapCodec.load_file(model.path, editor.registry, false)
	_check(loaded.is_ok() and loaded.value.display_name == legacy.display_name and loaded.value.properties.level.creator == legacy.properties.level.creator, "修改其它属性并保存仍完整保留历史长值")
	_set_identity_text(name, "已修正地图")
	_set_identity_text(creator, "Muna")
	_check(editor._commit_identity(), "旧长字段可改为新长度内的正常值")
	await _settle()


## 元数据入口先处理待提交身份，避免保留的非法名称输入遮住新署名后又覆盖它。
func _test_identity_metadata(editor: MapEditor) -> void:
	var model := editor.editor_document
	var name := editor._name_field
	var creator := editor._creator_field
	var before := model.document.to_dict()
	name.grab_focus()
	_set_identity_text(name, "x".repeat(31))
	_check(not editor._commit_identity(), "建立待修正的超长名称输入")
	editor._message_dialog.hide()
	editor._open_metadata()
	_check(not editor._metadata_dialog.visible and editor._message_dialog.visible, "无效名称阻止打开元数据窗口并显示原因")
	_check(model.document.to_dict() == before and name.text == "x".repeat(31), "元数据入口拒绝时不覆盖模型或待修正原文")
	editor._message_dialog.hide()
	_set_identity_text(name, "元数据测试")
	editor._open_metadata()
	_check(editor._metadata_dialog.visible and model.document.display_name == "元数据测试", "修正名称后元数据入口先提交合法身份再打开")
	var metadata: Dictionary = JSON.parse_string(editor._metadata_text.text)
	metadata.properties.level.creator = "NewCreator"
	editor._metadata_text.text = JSON.stringify(metadata)
	editor._metadata_dialog.confirmed.emit()
	await _settle()
	_check(not editor._metadata_dialog.visible and model.get_creator() == "NewCreator" and creator.text == "NewCreator" and name.text == "元数据测试", "元数据修改署名后模型与身份表单同步")
	_check(editor._commit_identity() and model.get_creator() == "NewCreator", "再次提交身份不会用旧表单署名覆盖元数据修改")


## 模拟文本输入的正式变化信号，不用 max_length 截断掩盖完整粘贴的错误。
func _set_identity_text(field: LineEdit, value: String) -> void:
	field.text = value
	field.text_changed.emit(value)


## 三种语言和两种窗口中，署名在名称下方且保留同一药丸视觉与有限宽度。
func _test_layout(editor: MapEditor) -> void:
	var field := editor._creator_field
	var identity := editor.find_child("MapEditorIdentityRow", true, false) as Control
	var row := editor.find_child("MapEditorCreatorRow", true, false) as Control
	var section := editor.find_child("MapEditorSceneSize", true, false) as Control
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var context := locale + str(dimensions)
			var expected_caption := "Creator" if locale == "en" else "創作者" if locale == "zh_HK" else "创作者"
			_check(_game.tr("创作者") == expected_caption, "创作者字段名称采用正确的界面语言 " + context)
			_check(field.text == "Muna" and editor.editor_document.get_creator() == "Muna", "切换语言和尺寸不翻译创作者 " + context)
			_check(row.get_global_rect().position.y >= identity.get_global_rect().end.y and row.get_global_rect().end.y <= section.get_global_rect().position.y, "创作者行位于名称ID下方与场景编辑上方 " + context)
			_check(root.get_visible_rect().encloses(field.get_global_rect()) and is_equal_approx(field.size.y, editor._name_field.size.y), "输入框完整可见且高度与名称一致 " + context)
			var style := field.get_theme_stylebox("normal") as StyleBoxFlat
			var name_style := editor._name_field.get_theme_stylebox("normal") as StyleBoxFlat
			_check(style.bg_color == name_style.bg_color and style.corner_radius_top_left == name_style.corner_radius_top_left, "创作者输入沿用浅底及同一圆角 " + context)


## 截图只在真实渲染器与显式绝对输出路径下进行。
func _capture() -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	_check(_capture_dir.is_absolute_path(), "截图输出要求绝对路径")
	if not _capture_dir.is_absolute_path():
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join("editor-creator.png")) == OK, "保存真实编辑器创作者截图")


## 等待容器协商与文本回填完成。
func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


## 收集有意义的断言并返回明确非零退出码。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 仅递归清理由本轮分配的独立测试目录。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	for filename in folder.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in folder.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
