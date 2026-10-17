extends SceneTree
## 地图代码规则回归覆盖布尔边界、首次保存锁定、历史与真实表单，存档完全隔离。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""
var _capture_directory := ""


## 延迟运行以等待全局类注册，并允许显式保存真实 GPU 截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 先验证纯数据生命周期，再走真实编辑器保存、重新打开与元数据入口。
func _run() -> void:
	_temporary = "user://tests/level_code_policy_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "内容目录可加载")
	_test_defaults_and_validation()
	_test_history_and_lock()
	await _test_editor()
	_cleanup(_temporary)
	print("LEVEL_CODE_POLICY_EDITOR_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 建立包含真实出生点和作者扩展的可玩地图，不依赖玩家文件。
func _document() -> MapDocument:
	var document := MapDocument.new()
	document.id = "custom_code_policy"
	document.display_name = "代码规则回归"
	document.width = 8
	document.height = 6
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]}
	document.properties = {"level": {"module_limit": 1, "author_extension": {"keep": [1, 2]}}, "custom": {"keep": true}}
	return document


## 旧地图保持默认及原数据；提示权限按真实来源判断，所有布尔值在保存边界严格校验。
func _test_defaults_and_validation() -> void:
	var document := _document()
	var model := MapEditorDocument.new()
	model.replace_document(document)
	_check(not model.get_allow_code_hints() and not model.get_restrict_code_paste() and not model.is_code_paste_policy_locked(), "新建默认关闭提示和粘贴限制")
	_check(not model.is_dirty() and model.document.to_dict() == document.to_dict(), "只读默认值不增加字段或dirty")
	var level := LevelDefinition.from_document(document, _content, "user://levels/custom_code_policy.json")
	_check(level.is_ok() and not level.value.can_use_code_hints() and not level.value.restrict_code_paste, "旧玩家图默认无提示且允许粘贴")
	var tutorial := document.duplicate_document()
	tutorial.id = "level_001"
	var formal := LevelDefinition.from_document(tutorial, _content, "res://data/levels/level_001.json")
	_check(formal.is_ok() and formal.value.can_use_code_hints(), "真实教学来源保留原提示权限")
	var renamed := LevelDefinition.from_document(tutorial, _content, "user://levels/level_001.json")
	_check(renamed.is_ok() and not renamed.value.can_use_code_hints(), "玩家图不能借教学ID获得提示")
	for field: String in ["allow_code_hints", "restrict_code_paste"]:
		for value: Variant in [null, 1, 0, "true", [], {}]:
			var invalid := document.duplicate_document()
			invalid.properties.level[field] = value
			_check(not MapCodec.validate(invalid, _content, false).is_ok(), "地图草稿拒绝非法布尔字段 %s=%s" % [field, value])
			_check(not LevelDefinition.from_document(invalid, _content).is_ok(), "关卡入口拒绝非法布尔字段 %s=%s" % [field, value])
	_check(not model.set_allow_code_hints("true").is_ok() and not model.set_restrict_code_paste(1).is_ok() and not model.is_dirty(), "模型拒绝非布尔开关且没有部分修改")
	_check(model.set_allow_code_hints(true).is_ok() and model.set_restrict_code_paste(true).is_ok(), "创建期可独立开启两项")
	level = LevelDefinition.from_document(model.document, _content, "user://levels/custom_code_policy.json")
	_check(level.is_ok() and level.value.can_use_code_hints() and level.value.restrict_code_paste, "可玩关卡携带启用提示和禁止粘贴规则")
	var preview := LevelDefinition.from_document(model.document, _content)
	_check(preview.is_ok() and not preview.value.can_use_code_hints(), "无正式来源的临时快照不开放正式提示")
	_check(model.document.properties.level.author_extension == document.properties.level.author_extension and model.document.properties.custom == document.properties.custom, "规则修改保留所有无关扩展")


## 保存后的规则不受撤销、重做、删除元数据或伪造事务影响，提示仍可修改。
func _test_history_and_lock() -> void:
	var model := MapEditorDocument.new()
	model.replace_document(_document())
	model.set_allow_code_hints(true)
	model.set_restrict_code_paste(true)
	_check(model.undo() and not model.get_restrict_code_paste(), "首次保存前可撤销限制")
	_check(model.redo() and model.get_restrict_code_paste(), "首次保存前可重做限制")
	model.mark_saved(_temporary.path_join("simulated_saved.json"))
	_check(model.is_code_paste_policy_locked() and not model.is_dirty(), "成功保存标记锁定当前限制且建立保存点")
	_check(not model.set_restrict_code_paste(false).is_ok() and not model.is_dirty(), "模型拒绝改动保存后的限制且保持clean")
	_check(model.undo() and model.get_restrict_code_paste() and not model.is_dirty(), "撤销保存前开关历史也不解除锁定")
	_check(model.undo() and model.get_restrict_code_paste() and not model.get_allow_code_hints(), "历史中的其它元数据仍可撤销")
	_check(model.redo() and model.get_allow_code_hints() and model.get_restrict_code_paste(), "重做正常恢复其它元数据且保留粘贴规则")
	var before := model.document.to_dict()
	var metadata := model.metadata_dict()
	metadata.properties.level.erase("restrict_code_paste")
	_check(not model.apply_metadata(metadata).is_ok() and model.document.to_dict() == before, "元数据不能移除已开启的粘贴限制")
	metadata.properties.erase("level")
	_check(not model.apply_metadata(metadata).is_ok() and model.document.to_dict() == before, "删除整段level不能绕过限制")
	model.begin_action()
	model.document.properties.level.restrict_code_paste = false
	model.document.properties.level["other_change"] = 12
	model.end_action()
	_check(model.get_restrict_code_paste() and model.document.properties.level.other_change == 12, "嵌套编辑事务保留无关改动并恢复锁定规则")
	_check(model.set_allow_code_hints(false).is_ok() and not model.get_allow_code_hints(), "已有地图仍允许单独更改提示")
	var legacy := MapEditorDocument.new()
	legacy.replace_document(_document(), "user://levels/legacy.json")
	_check(legacy.is_code_paste_policy_locked() and not legacy.get_restrict_code_paste() and not legacy.is_dirty(), "旧图重新打开时缺省允许粘贴且立即锁定")
	_check(not legacy.set_restrict_code_paste(true).is_ok() and not legacy.document.properties.level.has("restrict_code_paste"), "旧图不能后加限制，也不强写缺省字段")
	_check(legacy.set_allow_code_hints(true).is_ok() and legacy.undo() and not legacy.is_dirty(), "旧图提示可编辑和撤销，不生成粘贴字段")


## 真实表单核验分类位置、失败保存、另存为、打开旧图和灰色禁用状态。
func _test_editor() -> void:
	root.size = Vector2i(1280, 900)
	root.content_scale_size = root.size
	root.theme = GameTheme.create_theme()
	RenderingServer.set_default_clear_color(GameTheme.BACKGROUND)
	var editor := MapEditor.new()
	editor.player_levels_directory = _temporary.path_join("levels")
	root.add_child(editor)
	editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _settle()
	_check(not editor._restrict_code_paste_switch.disabled and not editor._restrict_code_paste_label.has_theme_color_override("font_color") and editor.editor_document.path.is_empty(), "默认空白地图的标签与开关可编辑，允许首次配置限制")
	_check(editor._load_document(MapEditor.DEFAULT_MAP_PATH), "显式打开旧地图夹具")
	_check(editor._restrict_code_paste_switch.disabled and editor._restrict_code_paste_label.has_theme_color_override("font_color"), "显式打开已有地图的标签与开关都禁用变灰")
	editor._new_document()
	var model := editor.editor_document
	_check(not editor._restrict_code_paste_switch.disabled and not editor._restrict_code_paste_label.has_theme_color_override("font_color"), "新建恢复可编辑的默认标签和开关")
	for control: Control in [editor._allow_code_hints_switch, editor._restrict_code_paste_switch]:
		_check(control.get_parent().get_parent().name == "MapEditorSceneControlsBody", "新开关位于玩法与行为控制而非场景编辑")
		_check(not control.button_pressed, "新图两个开关默认关闭")
	editor._allow_code_hints_switch.button_pressed = true
	editor._restrict_code_paste_switch.button_pressed = true
	_check(model.get_allow_code_hints() and model.get_restrict_code_paste(), "真实开关立即写入地图事务")
	DirAccess.make_dir_recursive_absolute(_temporary)
	var blocked := _temporary.path_join("blocked")
	var blocker := FileAccess.open(blocked, FileAccess.WRITE)
	blocker.store_string("must remain a file")
	blocker.close()
	editor.player_levels_directory = blocked.path_join("cannot_create")
	editor._save_player_level()
	_check(not model.is_code_paste_policy_locked() and not editor._restrict_code_paste_switch.disabled and model.is_dirty(), "保存失败保持创建期与可编辑状态")
	editor._message_dialog.hide()
	editor.player_levels_directory = _temporary.path_join("levels")
	editor._save_player_level()
	var saved_path := model.path
	_check(model.is_code_paste_policy_locked() and editor._restrict_code_paste_switch.disabled and not model.is_dirty(), "首次成功保存后立即锁定开关")
	_check(editor._restrict_code_paste_label.get_theme_color("font_color") == Color("A1A7B0") and editor._restrict_code_paste_switch.button_pressed, "锁定标签变灰且保留开启位置")
	var saved := MapCodec.load_file(saved_path, _content, false)
	_check(saved.is_ok() and saved.value.properties.level.allow_code_hints and saved.value.properties.level.restrict_code_paste, "真实保存文件包含两项布尔规则")
	editor._new_document()
	_check(editor._load_document(saved_path) and editor._restrict_code_paste_switch.disabled and editor._restrict_code_paste_switch.button_pressed, "二次打开保存地图仍显示灰色开启且不能修改")
	editor._restrict_code_paste_switch.toggled.emit(false)
	_check(model.get_restrict_code_paste() and editor._restrict_code_paste_switch.button_pressed and not model.is_dirty(), "手工发出禁用开关信号也不能改限制")
	editor._message_dialog.hide()
	var metadata := model.metadata_dict()
	metadata.properties.level.restrict_code_paste = false
	editor._metadata_text.text = JSON.stringify(metadata)
	editor._apply_metadata()
	_check(model.get_restrict_code_paste() and not model.is_dirty(), "真实元数据弹窗不能绕过锁定")
	editor._message_dialog.hide()
	editor._allow_code_hints_switch.button_pressed = false
	_check(not model.get_allow_code_hints() and model.get_restrict_code_paste(), "二次打开仍可关闭提示而不影响粘贴规则")
	await _test_layout(editor)
	editor._new_document()
	editor._restrict_code_paste_switch.button_pressed = true
	var export_path := _temporary.path_join("export.json")
	editor._write_document(export_path)
	_check(model.is_code_paste_policy_locked() and editor._restrict_code_paste_switch.disabled and FileAccess.file_exists(export_path), "首次另存为成功也锁定限制")
	editor._new_document()
	editor._write_document(blocked.path_join("export.json"))
	_check(not model.is_code_paste_policy_locked() and not editor._restrict_code_paste_switch.disabled, "另存为失败不会锁定新图")
	editor._message_dialog.hide()
	editor.queue_free()
	await _settle()


## 真实多语言布局在窄窗口中留足文字与开关间距，截图只记录隔离测试地图。
func _test_layout(editor: MapEditor) -> void:
	GameI18n.install()
	var scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	for language: String in ["zh_CN", "zh_HK", "es", "en"]:
		TranslationServer.set_locale(language)
		await _settle()
		for toggle: SettingsSwitch in [editor._allow_code_hints_switch, editor._restrict_code_paste_switch]:
			var label := toggle.get_parent().get_child(0) as Label
			_check(label.global_position.x + label.size.x <= toggle.global_position.x, "标签不与开关重叠 " + language)
			_check(toggle.global_position.x + toggle.size.x <= editor._properties_card.get_global_rect().end.x, "开关未越出卡片 " + language)
		var width_with_rules := editor._properties_card.size.x
		editor._allow_code_hints_switch.get_parent().hide()
		editor._restrict_code_paste_switch.get_parent().hide()
		await _settle()
		_check(is_equal_approx(width_with_rules, editor._properties_card.size.x), "新增开关不撑宽原有属性卡片 " + language)
		editor._allow_code_hints_switch.get_parent().show()
		editor._restrict_code_paste_switch.get_parent().show()
		await _settle()
		scroll.ensure_control_visible(editor._restrict_code_paste_switch)
		await _settle()
		if not _capture_directory.is_empty() and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute(_capture_directory)
			root.get_texture().get_image().save_png(_capture_directory.path_join("editor-code-policy-locked-%s.png" % language))
	TranslationServer.set_locale("zh_CN")


## 等待容器重排与信号回填完成，不依赖未渲染的即时坐标。
func _settle() -> void:
	for frame in 5:
		await process_frame


## 递归只清理本次独立目录，不触碰实际用户文件。
func _cleanup(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var folder := DirAccess.open(path)
	for directory in folder.get_directories():
		_cleanup(path.path_join(directory))
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


## 汇总所有断言并保留明确的测试完成标记。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
