class_name MenuBackgroundPicker
extends PanelContainer
## 开始菜单背景选择：自带、纯色和导入图片共用设置事务，全部背景选项保持同一排横向滚动。

const TILE_SIZE := Vector2(144, 112)
const THUMBNAIL_SIZE := Vector2(128, 80)
const CUSTOM_GAP := 10

var settings: GameSettings
var _buttons: Dictionary = {}
var _previews: Dictionary = {}
var _custom_scroll: ScrollContainer
var _custom_row: HBoxContainer
var _file_dialog: FileDialog
var _delete_popup: PopupMenu
var _status: Label
var _delete_id := ""
var _custom_ids: Array[String] = []
var _keyboard_focus := false


## 先构建固定选项，再根据设置中的用户图库创建缩略图，修改即时同步单选状态。
func _ready() -> void:
	if settings == null:
		return
	_build_ui()
	settings.changed.connect(_sync_controls)
	_sync_controls()


## 页面销毁时取消持久模型订阅，文件窗口和删除菜单随页面一同释放。
func _exit_tree() -> void:
	if settings != null and settings.changed.is_connected(_sync_controls):
		settings.changed.disconnect(_sync_controls)


## 浅灰圆角行与代码颜色保持同一列，内置和用户背景共用同一条横向图库。
func _build_ui() -> void:
	var surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 18)
	surface.content_margin_left = 24
	surface.content_margin_right = 24
	surface.content_margin_top = 16
	surface.content_margin_bottom = 16
	add_theme_stylebox_override("panel", surface)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	add_child(column)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	column.add_child(row)
	var caption := GameTheme.label(row, "开始菜单背景", 17)
	caption.name = "MenuBackgroundLabel"
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_custom_scroll = ScrollContainer.new()
	_custom_scroll.name = "CustomBackgroundScroll"
	# 保持原来三个选项的可视宽度；图片增加只扩展横向内容，不能撑宽页面或换行。
	_custom_scroll.custom_minimum_size.x = TILE_SIZE.x * 3 + CUSTOM_GAP * 2
	_custom_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_custom_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_custom_scroll.follow_focus = true
	row.add_child(_custom_scroll)
	# 横条溢出时常显，不挂接设置页纵向条的闲置淡出脚本。
	_custom_row = HBoxContainer.new()
	_custom_row.name = "CustomBackgroundRow"
	_custom_row.add_theme_constant_override("separation", CUSTOM_GAP)
	_custom_scroll.add_child(_custom_row)
	_add_tile(_custom_row, "default", "默认", MainMenuBackground.SOURCE_TEXTURE)
	_add_tile(_custom_row, "solid", "纯色模式", null)
	_add_tile(_custom_row, "add", "自定义", null, true)
	_status = GameTheme.label(column, "", 13)
	_status.name = "MenuBackgroundStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", GameTheme.ERROR)
	_status.hide()
	_file_dialog = FileDialog.new()
	_file_dialog.name = "BackgroundFileDialog"
	_file_dialog.title = "选择背景图片"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga ; " + tr("图片文件")])
	_file_dialog.file_selected.connect(_import_background)
	add_child(_file_dialog)
	GameTheme.style_guide_dialog(_file_dialog)
	_delete_popup = PopupMenu.new()
	_delete_popup.name = "DeleteBackgroundMenu"
	_delete_popup.add_item("删除", 0)
	_delete_popup.add_theme_font_size_override("font_size", 12)
	_delete_popup.add_theme_constant_override("v_separation", 2)
	_delete_popup.add_theme_constant_override("h_separation", 0)
	_delete_popup.add_theme_constant_override("item_start_padding", 3)
	_delete_popup.add_theme_constant_override("item_end_padding", 3)
	var popup_style := GameTheme.box(Color("FBFCFE"), Color(0, 0, 0, 0.06), 8)
	popup_style.set_content_margin_all(5)
	popup_style.shadow_color = Color(0.1, 0.14, 0.2, 0.12)
	popup_style.shadow_size = 3
	_delete_popup.add_theme_stylebox_override("panel", popup_style)
	var hover_style := GameTheme.box(Color("E4EEFC"), Color.TRANSPARENT, 4)
	hover_style.set_content_margin_all(0)
	_delete_popup.add_theme_stylebox_override("hover", hover_style)
	_delete_popup.add_theme_color_override("font_color", GameTheme.ERROR)
	_delete_popup.id_pressed.connect(_delete_selected_background)
	add_child(_delete_popup)


## 整张缩略图和下方说明构成一个按钮，用户图片名称只截断显示，不参与界面翻译。
func _add_tile(parent: HBoxContainer, key: String, caption: String, texture: Texture2D, add_picture: bool = false, custom: bool = false) -> void:
	var button := Button.new()
	button.name = "Background_" + key
	button.custom_minimum_size = TILE_SIZE
	button.toggle_mode = not add_picture
	button.tooltip_text = caption
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	for state in ["normal", "pressed", "hover_pressed", "hover", "focus"]:
		var fill := Color(1, 1, 1, 0.4) if state == "hover" else Color.TRANSPARENT
		var style := GameTheme.box(fill, Color.TRANSPARENT, 10)
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	if add_picture:
		button.pressed.connect(_open_file_dialog)
	elif custom:
		button.pressed.connect(_choose_background.bind("custom", key))
		button.gui_input.connect(_on_custom_gui_input.bind(key))
	else:
		button.pressed.connect(_choose_background.bind(key))
	parent.add_child(button)
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 6)
	button.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 8
	content.offset_right = -8
	content.offset_top = 5
	var preview := MenuBackgroundPreview.new()
	preview.texture = texture
	preview.add_picture = add_picture
	preview.custom_minimum_size = THUMBNAIL_SIZE
	content.add_child(preview)
	var label := GameTheme.label(content, caption, 12)
	label.name = "BackgroundCaption"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	if custom:
		button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_buttons[key] = button
	_previews[key] = preview


## 点击固定或用户选项只请求模型切换，不重建或修改任何前景菜单。
func _choose_background(mode: String, background_id: String = "") -> void:
	_delete_popup.hide()
	var result := settings.set_menu_background(mode, background_id)
	_show_result(result)
	_sync_controls()


## 原生文件选择器导入后由模型复制进游戏目录，原始图片路径不进入删除流程。
func _open_file_dialog() -> void:
	_delete_popup.hide()
	var available := get_viewport_rect().size
	_file_dialog.popup_centered(Vector2i(minf(720, available.x * 0.8), minf(480, available.y * 0.8)))


## 只在模型确认图片与保存成功后刷新图库并把新选择滚入可视区域。
func _import_background(path: String) -> void:
	var result := settings.import_background(path)
	_show_result(result)
	_sync_controls()
	if result.is_ok():
		_scroll_to_active.call_deferred()


## 图库条目顺序改变才重建缩略图，切换已选背景不会重复解码或模糊全部图片。
func _sync_controls() -> void:
	if settings.last_error.is_empty():
		_status.text = ""
		_status.hide()
	var next_ids: Array[String] = []
	for entry: Dictionary in settings.custom_backgrounds:
		next_ids.append(entry.id)
	if next_ids != _custom_ids:
		_rebuild_custom_tiles(next_ids)
	for key: String in _buttons:
		var selected := settings.menu_background_mode == key if key in ["default", "solid"] else settings.menu_background_mode == "custom" and settings.menu_background_id == key
		var button: Button = _buttons[key]
		button.set_pressed_no_signal(selected)
		var preview: MenuBackgroundPreview = _previews[key]
		preview.set_selected(selected)
	if not _delete_id.is_empty() and settings.menu_background_mode == "custom" and settings.menu_background_id == _delete_id:
		_delete_popup.hide()


## 只重建自定义条目并接在三个固定选项右侧，不改变内置按钮或新开第二排。
func _rebuild_custom_tiles(next_ids: Array[String]) -> void:
	_delete_popup.hide()
	for key: String in _custom_ids:
		var button: Button = _buttons[key]
		_custom_row.remove_child(button)
		button.queue_free()
		_buttons.erase(key)
		_previews.erase(key)
	_custom_ids = next_ids
	for entry: Dictionary in settings.custom_backgrounds:
		var picture := Image.new()
		var texture: Texture2D
		var path := settings.get_background_path(entry.id)
		if not path.is_empty() and picture.load(path) == OK and not picture.is_empty():
			# 图库只保留小尺寸显示纹理，不能让多张高分辨率照片同时占满显存。
			var scale_factor := minf(1.0, 512.0 / maxf(picture.get_width(), picture.get_height()))
			if scale_factor < 1.0:
				picture.resize(maxi(1, roundi(picture.get_width() * scale_factor)), maxi(1, roundi(picture.get_height() * scale_factor)), Image.INTERPOLATE_LANCZOS)
			texture = ImageTexture.create_from_image(picture)
		_add_tile(_custom_row, entry.id, entry.name, texture, false, true)


## 新导入或键盘选择的图片进入可见区域，保留其他时候的水平滚动位置。
func _scroll_to_active() -> void:
	# 新图库先由容器完成两轮最小尺寸与整排宽度排版，再按最终位置滚动。
	await get_tree().process_frame
	await get_tree().process_frame
	if settings.menu_background_mode == "custom" and _buttons.has(settings.menu_background_id):
		_custom_scroll.ensure_control_visible(_buttons[settings.menu_background_id])


## 右键仅唤出未使用自定义图片的删除菜单，不改变当前背景或按钮的选中状态。
func _on_custom_gui_input(event: InputEvent, background_id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var button: Button = _buttons[background_id]
		_show_delete_menu(background_id, button.get_global_transform_with_canvas() * event.position)
		_buttons[background_id].accept_event()


## 删除菜单紧贴右键位置，宽高不超过缩略图一半，正在使用或内置图片没有删除入口。
func _show_delete_menu(background_id: String, pointer_position: Vector2) -> void:
	_delete_popup.hide()
	if background_id not in _custom_ids or settings.menu_background_mode == "custom" and settings.menu_background_id == background_id:
		return
	_delete_id = background_id
	var preview: MenuBackgroundPreview = _previews[background_id]
	# 原生弹层会把阴影加在窗口尺寸外，预先扣除双侧阴影以符合预览半尺寸限制。
	var popup_style := _delete_popup.get_theme_stylebox("panel") as StyleBoxFlat
	var shadow_margin := popup_style.shadow_size * 2.0
	var menu_size := Vector2i(minf(60, preview.size.x * 0.5 - shadow_margin), minf(30, preview.size.y * 0.5 - shadow_margin))
	var bounds := get_viewport_rect()
	var origin := Vector2i(clampf(pointer_position.x, 0, maxf(0, bounds.size.x - menu_size.x)), clampf(pointer_position.y, 0, maxf(0, bounds.size.y - menu_size.y)))
	_delete_popup.size = menu_size
	_delete_popup.popup(Rect2i(origin, menu_size))


## 提交时再次检查使用状态，模型拒绝活动图片删除，成功后才移除缩略图。
func _delete_selected_background(_index: int) -> void:
	_delete_popup.hide()
	if _delete_id.is_empty():
		return
	var result := settings.remove_background(_delete_id)
	_delete_id = ""
	_show_result(result)
	_sync_controls()


## 导入和删除失败就地显示反馈，成功时清除旧错误。
func _show_result(result: DataResult) -> void:
	_status.text = GameI18n.translate_errors(result.errors)
	_status.visible = not result.is_ok()


## 键盘导航保留清晰焦点，鼠标切换仅保留真实单选描边，不残留额外蓝圈。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed or event is InputEventScreenTouch and event.pressed:
		_keyboard_focus = false
	elif event is InputEventKey and event.pressed:
		_keyboard_focus = true
	else:
		return
	for button: Button in _buttons.values():
		button.add_theme_stylebox_override("focus", GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 10) if _keyboard_focus else StyleBoxEmpty.new())


## 语言切换保持图库与选择，更新文件类型过滤说明并让父级重新分配文本宽度。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and is_instance_valid(_file_dialog):
		_file_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga ; " + tr("图片文件")])
		if _status.visible:
			_status.text = GameI18n.translate_errors(settings.last_error.split("\n"))
