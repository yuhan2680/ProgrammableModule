extends SceneTree
## 敌人编辑通过真实侧栏、地图输入与试玩入口回归，所有存档都隔离到测试目录。

var _checks := 0
var _failures := 0
var _game: GameShell
var _editor: MapEditor
var _temporary := ""


## 场景树就绪后再创建实际游戏界面。
func _initialize() -> void:
	_run.call_deferred()


## 检查关闭状态、组合配置、地图放置、撤销及同一文档的试玩往返。
func _run() -> void:
	_temporary = "user://tests/editor_enemy_ui_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.settings_path = _temporary.path_join("settings.json")
	root.add_child(_game)
	await _settle()
	_editor = _game._editor
	var model := _editor.editor_document
	var document := MapDocument.new()
	document.id = "enemy_ui"
	document.display_name = "敌人编辑回归"
	document.width = 12
	document.height = 10
	document.properties = {"level": {"module_limit": 3, "max_ticks": 600, "completion_mode": "reach_or_clear"}}
	for y in 10:
		for x in 12:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0.0, "y": 0.0}}]}
	model.replace_document(document)
	_editor._map_view.reset_view()
	await _settle()
	var panel := _editor._enemy_panel
	_check(not panel.enable_switch.button_pressed and not panel.limit_field.editable and not panel.health_field.editable and panel.place_button.disabled, "无敌人地图默认关闭，数量耐久和放置操作均禁用")
	_check(panel._choices.size() >= 4 and panel._choices[0].disabled and panel._settings_body.modulate.a < 0.5 and not model.is_dirty(), "未启用组合显示灰色空槽，查看不会修改文档")
	panel.enable_switch.button_pressed = true
	await _settle()
	_check(model.get_enemies_enabled() and panel.limit_field.editable and panel.health_field.editable and not panel.place_button.disabled and not panel._choices[1].disabled, "开关立即启用所有敌人设置与组合选择")
	panel.limit_field.text = "2"
	panel.health_field.text = "2.8"
	panel.health_field.text_submitted.emit("2.8")
	await _settle()
	_choose_module(panel, 1, "melee")
	await _settle()
	var config := model.get_enemy_template(_editor.registry)
	_check(config.module_limit == 2 and is_equal_approx(config.module_health, 2.8) and config.module_ids == ["movement", "melee"], "数字输入和药丸选择保存真实双模块模板及2.8耐久")
	panel.limit_field.text = "0"
	panel.limit_field.text_submitted.emit("0")
	_check(panel.limit_field.text == "2" and model.get_enemy_template(_editor.registry) == config, "非法数量恢复有效值而不破坏模板")
	panel.health_field.text = "NaN"
	panel.health_field.text_submitted.emit("NaN")
	_check(panel.health_field.text == "2.8" and model.get_enemy_template(_editor.registry) == config, "非法耐久恢复有效值而不修改文档")
	await _test_numeric_sync()
	await _test_glass_picker()
	panel.place_button.pressed.emit()
	await _settle()
	_check(_editor._canvas.paint_mode == MapEditorCanvas.PaintMode.ENEMY, "左侧加号进入敌人放置工具")
	var point := _editor._canvas.global_position + Vector2(7.5, 5.5) * _editor._canvas.cell_size
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	await _settle()
	_check(not _editor._canvas._enemy_preview.is_empty() and _editor._canvas._enemy_preview_valid and model.document.enemies.is_empty(), "真实鼠标移动只建立合法半透明预览，不提前修改地图")
	_click(point)
	await _settle()
	_check(model.document.enemies.size() == 1 and model.document.enemies[0].modules.size() == 2 and model.document.enemies[0].position == {"x": 7.5, "y": 5.5}, "左键在真实半格位置放置整组敌人")
	_check(model.document.enemies[0].behavior == "auto_chase_attack" and model.document.enemies[0].properties.module_health.values().all(func(value: Variant) -> bool: return is_equal_approx(value, 2.8)), "放置敌人自动绑定追击攻击行为及每模块耐久")
	var saved_enemies := model.document.enemies.duplicate(true)
	panel.enable_switch.button_pressed = false
	await _settle()
	_check(not model.get_enemies_enabled() and model.document.enemies == saved_enemies and _editor._canvas.paint_mode != MapEditorCanvas.PaintMode.ENEMY, "关闭保留位置组合耐久，同时取消尚未提交的放置工具")
	var disabled_world := SimulationWorld.create(model.document, _editor.registry)
	_check(disabled_world.is_ok() and disabled_world.value.machines.size() == 1, "关闭开关的真实世界只生成玩家")
	_editor._undo()
	await _settle()
	_check(model.get_enemies_enabled() and panel.enable_switch.button_pressed and model.document.enemies == saved_enemies, "撤销关闭恢复敌人启用状态且不丢失位置")
	var enabled_world := SimulationWorld.create(model.document, _editor.registry)
	_check(enabled_world.is_ok() and enabled_world.value.machines.size() == 2, "重新启用后真实世界生成原有敌人")
	await _test_layout()
	var before := JSON.stringify(model.document.to_dict(), "", true)
	_editor._play_button.pressed.emit()
	await _settle()
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session != null and _game.session.assembly.modules.is_empty(), "含自定义敌人的地图仍从正式空装配开始测试")
	if _game.session != null:
		_check(_game.session.level.document.enemies == saved_enemies, "试玩快照完整携带自定义敌人")
		_game._dialogue_dialog.hide()
		_game.session.assembly.add_module("movement", Vector2.ZERO)
		_game._confirm_assembly_button.pressed.emit()
		await _settle()
		_check(_game.page == GameShell.Page.PLAY, "确认装配后进入正常编程测试")
		_game._back_button.pressed.emit()
		await _settle()
		_check(_game.page == GameShell.Page.EDITOR and _game._editor == _editor and JSON.stringify(model.document.to_dict(), "", true) == before, "结束试玩返回原文档，敌人、模板和历史不被运行状态覆盖")
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("敌人编辑界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 模块下拉通过真实选项信号更新同一模板，不直接修改文档敌人。
func _choose_module(panel: MapEditorEnemyPanel, slot: int, module_id: String) -> void:
	var choice := panel._choices[slot]
	for index in choice.item_count:
		if choice.get_item_metadata(index) == module_id:
			choice.select(index)
			choice.item_selected.emit(index)
			return
	_check(false, "模块菜单缺少 " + module_id)


## 属性区通过自身滚动查看新分类，英文及最小窗口都不横向越界。
func _test_layout() -> void:
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	for dimensions in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale in ["zh_CN", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			scroll.ensure_control_visible(_editor._enemy_panel.place_button)
			await _settle()
			var bounds := scroll.get_global_rect()
			for control: Control in [_editor._enemy_panel, _editor._enemy_panel.limit_field, _editor._enemy_panel.health_field, _editor._enemy_panel._slots]:
				var rect := control.get_global_rect()
				_check(rect.position.x >= bounds.position.x - 1 and rect.end.x <= bounds.end.x + 1, "敌人表单不横向溢出 " + locale + str(dimensions) + str(control.name))
			_check(bounds.grow(1).encloses(_editor._enemy_panel.place_button.get_global_rect()), "属性滚动后能完整显示放置按钮 " + locale + str(dimensions))
			scroll.ensure_control_visible(_editor._play_button)
			await _settle()
			_check(bounds.grow(1).encloses(_editor._play_button.get_global_rect()), "敌人设置增加内容后仍可滚动访问开始测试 " + locale + str(dimensions))
			if locale == "en":
				var choice := _editor._enemy_panel._choices[0]
				_check(choice.get_item_text(choice.selected) == "Movement Module", "模块药丸实时切换为英文名称")
			# 最右侧空槽紧贴属性栏边缘，真实菜单需要向内钳制并按可用空间上下翻转。
			var edge_choice: EnemyModuleChoice = _editor._enemy_panel._choices.back()
			scroll.ensure_control_visible(edge_choice)
			await _settle()
			edge_choice.show_popup()
			await _settle()
			var picker := _editor._enemy_panel._picker
			_check(picker.is_open(), "边缘药丸可以展开玻璃选择菜单 " + locale + str(dimensions))
			_check(root.get_visible_rect().grow(-1).encloses(picker._panel.get_global_rect()), "玻璃菜单在中英文最小视口内完整可见 " + locale + str(dimensions))
			_check(picker._panel.size.x >= 142 and picker._panel.size.x <= 220 and picker._panel.size.y <= 270, "菜单按语言自适应宽度且不会被原SVG撑大 " + locale + str(dimensions))
			_key(KEY_ESCAPE)
			await _settle()
			_check(not picker.is_open(), "边缘菜单可用Esc关闭 " + locale + str(dimensions))
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game.settings.set_language("zh_CN")
	await _settle()


## 弹窗应用新值时底层输入可能仍有焦点，回填必须阻止旧文本在失焦后覆盖 JSON。
func _test_numeric_sync() -> void:
	var panel := _editor._enemy_panel
	var model := _editor.editor_document
	for item: Array in [[panel.limit_field, "module_limit", 5, "2"], [panel.health_field, "module_health", 7.0, "2.8"]]:
		var field: LineEdit = item[0]
		field.grab_focus()
		_editor._open_metadata()
		await _settle()
		var metadata := model.metadata_dict()
		metadata.properties.editor.enemy_template[item[1]] = item[2]
		_editor._metadata_text.text = JSON.stringify(metadata)
		_editor._apply_metadata()
		await _settle()
		_check(float(field.text) == float(item[2]) and model.get_enemy_template(_editor.registry)[item[1]] == item[2], "聚焦输入正确同步 JSON 新值 " + item[1])
		field.release_focus()
		await _settle()
		_check(model.get_enemy_template(_editor.registry)[item[1]] == item[2], "失焦不会将 JSON 新值回写为旧数值 " + item[1])
		field.grab_focus()
		_editor._undo()
		await _settle()
		_check(field.text == item[3], "聚焦时撤销仍强制回填模板数值 " + item[1])
		field.release_focus()
		_check(float(model.get_enemy_template(_editor.registry)[item[1]]) == float(item[3]), "撤销后失焦不产生反向写回 " + item[1])
	panel.limit_field.text = "4"
	panel.commit_fields()
	_choose_module(panel, 2, "shooting")
	await _settle()
	_choose_module(panel, 3, "radar")
	await _settle()
	_check(panel._choices.size() == 4, "四模块达到数量上限时不生成额外一排空药丸")
	for index in 3:
		_editor._undo()
	await _settle()
	_check(model.get_enemy_template(_editor.registry).module_ids == ["movement", "melee"] and model.get_enemy_template(_editor.registry).module_limit == 2, "组合容量修改可逐步撤销并恢复原配置")


## 菜单通过真实键盘和指针事件验证，关闭流程不能意外绘制背景地图或改写模块。
func _test_glass_picker() -> void:
	var panel := _editor._enemy_panel
	var picker := panel._picker
	var model := _editor.editor_document
	var scroll := _editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(panel.place_button)
	await _settle()
	var plus := panel.place_button
	var plus_style := plus.get_theme_stylebox("normal")
	_check(plus.icon_alignment == HORIZONTAL_ALIGNMENT_CENTER and plus.get_theme_constant("h_separation") == 0 and plus.text.is_empty(), "单图标加号取消文字间距并位于按钮中心")
	_check(is_equal_approx(plus.size.x, plus.size.y) and is_equal_approx(plus_style.get_content_margin(SIDE_LEFT), plus_style.get_content_margin(SIDE_RIGHT)) and is_equal_approx(plus_style.get_content_margin(SIDE_TOP), plus_style.get_content_margin(SIDE_BOTTOM)), "加号圆形按钮宽高与四周内距对称")
	var before := JSON.stringify(model.document.to_dict(), "", true)
	panel._choices[0].show_popup()
	await _settle()
	_check(picker.is_open() and picker._overlay.visible, "药丸展开同一视口中的玻璃菜单")
	if not picker.is_open():
		return
	_check(picker._panel.size.is_equal_approx(Vector2(142, 270)), "六行中文菜单保持紧凑142乘270尺寸")
	_check(root.get_visible_rect().grow(-1).encloses(picker._panel.get_global_rect()), "初始菜单完整位于游戏视口内")
	_check(picker._glass.material is ShaderMaterial and picker._glass.get_global_rect().is_equal_approx(picker._panel.get_global_rect()), "毛玻璃底完整覆盖菜单且文字位于独立清晰控件中")
	_check(picker._items.size() == panel._choices[0].item_count, "菜单同时包含空槽和全部真实模块")
	for item: Button in picker._items:
		_check(item.size.y <= 43 and item.get_theme_font_size("font_size") == 12 and (item.icon == null or (item.expand_icon and item.get_theme_constant("icon_max_width") == 32)), "模块行和SVG图标使用一致的受限显示尺寸 " + item.text)
	var current := panel._choices[0].selected
	_check(root.gui_get_focus_owner() == picker._items[current], "展开后键盘焦点定位当前模块")
	_key(KEY_DOWN)
	await _settle()
	_check(root.gui_get_focus_owner() == picker._items[(current + 1) % picker._items.size()], "真实下方向键只移动菜单焦点")
	_key(KEY_UP)
	await _settle()
	_check(root.gui_get_focus_owner() == picker._items[current], "真实上方向键可回到原模块")
	var target := -1
	for index in panel._choices[0].item_count:
		if panel._choices[0].get_item_metadata(index) == "shooting":
			target = index
	if target >= 0:
		for unused in posmod(target - current, picker._items.size()):
			_key(KEY_DOWN)
			await _settle()
		_key(KEY_ENTER)
		await _settle()
		_check(panel._choices[0].has_focus(), "选择重建药丸后焦点返回同一槽位，可继续使用键盘")
		_check(not picker.is_open() and model.get_enemy_template(_editor.registry).module_ids == ["shooting", "melee"], "真实Enter提交高亮模块并收起菜单")
		_editor._undo()
		await _settle()
		_check(JSON.stringify(model.document.to_dict(), "", true) == before, "菜单选择复用原子模板事务，撤销恢复原组合")
	else:
		_check(false, "真实目录提供射击模块供键盘选择")
		picker.close_menu()
	panel._choices[0].show_popup()
	await _settle()
	_key(KEY_ESCAPE)
	await _settle()
	_check(not picker.is_open() and JSON.stringify(model.document.to_dict(), "", true) == before, "Esc只收起菜单而不修改地图或组合")
	# 使用擦除画笔并在实际地板处点击：首次外点必须关闭菜单，第二次才可擦除。
	_editor._set_paint_mode(MapEditorCanvas.PaintMode.BRUSH)
	var brush_index := _editor._brush.selected
	_editor._brush.select(_editor._brush_ids.find(""))
	panel._choices[0].show_popup()
	await _settle()
	var point := _editor._canvas.global_position + Vector2(4.5, 4.5) * _editor._canvas.cell_size
	_check(not picker._panel.get_global_rect().has_point(point), "外点回归使用玻璃菜单以外的真实地图地板")
	_click(point)
	await _settle()
	_check(not picker.is_open() and model.document.get_tile_id(Vector2i(4, 4)) == "floor" and JSON.stringify(model.document.to_dict(), "", true) == before, "菜单外完整点击被吞掉，不能穿透擦除地图")
	_click(point)
	await _settle()
	_check(model.document.get_tile_id(Vector2i(4, 4)).is_empty(), "关闭后的下一次独立点击仍能正常编辑地图")
	_editor._undo()
	_editor._brush.select(brush_index)
	await _settle()
	_check(JSON.stringify(model.document.to_dict(), "", true) == before, "外点测试可完整撤销且未改敌人配置")
	await _test_picker_lifecycle(scroll, before)


## 分类、页面和开关改变时菜单必须随真实入口消失；旧语言的独立画布层也不能残留。
func _test_picker_lifecycle(scroll: ScrollContainer, before: String) -> void:
	var panel := _editor._enemy_panel
	var picker := panel._picker
	var model := _editor.editor_document
	scroll.ensure_control_visible(panel._choices[0])
	await _settle()
	panel._choices[0].show_popup()
	await _settle()
	_check(picker.is_open(), "关闭开关前确实已展开菜单")
	panel.enable_switch.button_pressed = false
	await _settle()
	_check(not picker.is_open() and not picker._overlay.visible and panel._choices[0].disabled, "关闭敌人即收起玻璃层并禁用药丸")
	panel._choices[0].show_popup()
	await _settle()
	_check(not picker.is_open(), "禁用药丸无法通过show_popup绕过开关")
	_editor._undo()
	await _settle()
	var collapse := _editor.find_child("MapEditorSceneCollapse", true, false) as Button
	panel._choices[0].show_popup()
	await _settle()
	_check(picker.is_open(), "折叠分类前菜单已展开")
	collapse.pressed.emit()
	await _settle()
	_check(not picker.is_open() and not picker._overlay.visible and not panel.is_visible_in_tree(), "收起父分类后独立玻璃层不残留")
	collapse.pressed.emit()
	await _settle()
	scroll.ensure_control_visible(panel._choices[0])
	await _settle()
	panel._choices[0].show_popup()
	await _settle()
	_check(picker.is_open(), "切换语言前菜单已展开")
	_game.settings.set_language("en")
	await _settle()
	_check(not picker.is_open() and not picker._overlay.visible, "切换语言后旧菜单关闭")
	scroll.ensure_control_visible(panel._choices[0])
	await _settle()
	panel._choices[0].show_popup()
	await _settle()
	_check(picker.is_open() and picker._items[panel._choices[0].selected].text == "Movement Module", "重开后菜单使用英文模块名称")
	_editor.hide()
	await _settle()
	_check(not picker.is_open() and not picker._overlay.visible, "编辑器页面隐藏时菜单和玻璃层一起隐藏")
	_editor.show()
	_game.settings.set_language("zh_CN")
	await _settle()
	_check(JSON.stringify(model.document.to_dict(), "", true) == before, "菜单开合、页面折叠和语言切换都不改地图数据")


## 真实按键按下和松开均经场景树分发，验证输入路由而不直接调用菜单选择方法。
func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = pressed
		root.push_input(event, true)


## 通过场景树分发真实左键按下与松开，避免测试绕过地图命中逻辑。
func _click(point: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)


## 等待原生容器、文档信号和翻译重排完成。
func _settle() -> void:
	for index in 4:
		await process_frame


## 统一记录失败并保留后续独立检查。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 测试仅清理本次独占目录，不接触真实玩家配置或地图。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	for file in directory.get_files():
		directory.remove(file)
	DirAccess.remove_absolute(path)
