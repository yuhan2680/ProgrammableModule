extends SceneTree
## 内嵌指引回归覆盖格式工具、真实分页输入、事务提交、保存试玩往返与三语窄屏布局。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""
var _capture_dir := ""


## 等待节点可加入场景树，仅在明确提供路径时保存 GPU 截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 用独占玩家目录启动真实编辑器，保留机器原语言并清理全部测试地图。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/map_guide_editor_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var locale := TranslationServer.get_locale()
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	_game.settings.set_language("zh_CN")
	var editor := _game._editor
	editor._load_document(MapEditor.DEFAULT_MAP_PATH) # 此回归需要有出生点的既有地图夹具。
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.id = "guide_ui_fixture"
	document.dialogue = []
	model.replace_document(document)
	await _test_page_switch_glass(editor)
	var guide := editor._level_guide_editor
	await _click(editor._level_guide_button)
	_check(guide.is_open() and guide._title.text == "指引 1/1" and guide._next.disabled and guide._previous.disabled, "空地图通过指引页签显示单个占位页，禁止无限添加空页")
	_check(not model.is_dirty() and not model.can_undo(), "打开空引导不改地图和历史")
	await _key(KEY_ESCAPE)
	_check(not guide.is_open() and model.document.dialogue.is_empty() and not model.is_dirty(), "Esc关闭空占位不会落盘或变脏")
	await _click(editor._level_guide_button)
	_input_text(guide, "# 第一页\n欢迎 **Muna**，请向终点移动。")
	_check(guide._title.text == "指引 1/1" and not guide._next.disabled and model.document.dialogue.is_empty(), "输入第一页即时更新状态，仍保留为本地草稿")
	await _click(guide._next)
	_check(guide._title.text == "指引 2/2" and guide._next.disabled, "新草稿有准确页码且不允许连续新增空页")
	await _click(guide._previous)
	_check(guide._pages.size() == 1 and guide._text.text.begins_with("# 第一页"), "返回上一页删除空草稿而不丢正文")
	await _click(guide._next)
	_input_text(guide, "## 第二页\n- 装配移动模块\n- 点击 `开始`")
	await _click(guide._next)
	_input_text(guide, "### 第三页\n完成后返回编辑器。")
	_check(guide._title.text == "指引 3/3", "三张有正文的页数即时成为3/3")
	await _click(guide._previous)
	await _click(guide._previous)
	_check(guide._title.text == "指引 1/3", "返回首张显示1/3，不累计翻页次数")
	await _click(guide._preview_button)
	_check(guide._preview.visible and not guide._text.visible and guide._preview.get_parsed_text().contains("第一页") and not guide._preview.get_parsed_text().contains("# "), "预览渲染标题与正文，并保留编辑源文")
	await _capture("map-guide-preview.png")
	await _click(guide._preview_button)
	_check(model.path.is_empty() and not editor._file_dialog.visible and not model.can_undo(), "翻页与预览仍仅操作本地草稿")
	await _show_edit_tab(editor)
	_check(not guide.is_open() and model.document.dialogue.size() == 3 and model._undo_stack.size() == 1, "切回编辑页签一次提交三页，仅新增一个撤销事务")
	_check(model.document.dialogue[0].format == "markdown" and model.document.dialogue[0].speaker == "引导", "新引导正文与Markdown标记写入现有dialogue字段")
	var accepted := model.document.dialogue.duplicate(true)
	model.undo()
	_check(model.document.dialogue.is_empty() and not model.is_dirty(), "一次撤销回到原地图保存点")
	model.redo()
	_check(model.document.dialogue == accepted, "一次重做完整恢复所有引导页")
	await _test_format_toolbar(editor)
	await _test_portable_input(editor)
	await _test_preview_links(editor)
	await _test_legacy_and_empty(editor)
	await _test_layout(editor)
	await _test_save_and_play(editor)
	await _test_canceled_document_actions(editor)
	_game.queue_free()
	await _settle()
	TranslationServer.set_locale(locale)
	_cleanup(_temporary)
	print("关卡引导编辑界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 按住真实页签后比较最终渲染区域，父级位移和缩放不能让玻璃采到屏幕左上角的旧位置。
func _test_page_switch_glass(editor: MapEditor) -> void:
	var tabs := editor._property_pages
	var original_position := tabs.position
	var original_scale := tabs.scale
	var original_viewport_scale := root.content_scale_factor
	await _hold_switch_button(tabs.guide_button, true)
	_check_switch_sampling(tabs, "按住指引页签")
	var initial_bounds := root.get_final_transform() * tabs._glass.get_global_rect()
	tabs.position += Vector2(-73, 17)
	tabs.scale = original_scale * 0.85
	await _settle()
	var moved_bounds := root.get_final_transform() * tabs._glass.get_global_rect()
	_check(moved_bounds.position.distance_to(initial_bounds.position) > 20.0 and moved_bounds.size.x < initial_bounds.size.x * 0.95, "按住期间玻璃确实移动并缩放，覆盖非默认页面变换")
	_check_switch_sampling(tabs, "按住期间移动及缩放")
	root.content_scale_factor = original_viewport_scale * 1.25
	await _settle()
	_check(not root.get_final_transform().get_scale().is_equal_approx(Vector2.ONE), "取样回归包含真实视口像素比例而非仅逻辑坐标")
	_check_switch_sampling(tabs, "按住期间视口比例变化")
	await _hold_switch_button(tabs.guide_button, false)
	var deadline := Time.get_ticks_msec() + 1500
	while tabs.is_processing() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not tabs._pointer_held and not tabs._glass.visible and tabs._backdrop.copy_mode == BackBufferCopy.COPY_MODE_DISABLED and not tabs.is_processing(), "松开页签并完成回弹后停止玻璃复制与逐帧处理")
	root.content_scale_factor = original_viewport_scale
	tabs.scale = original_scale
	await _settle()
	tabs.position = original_position
	await _hold_switch_button(tabs.edit_button, true)
	_check_switch_sampling(tabs, "再次按住编辑页签")
	tabs.hide()
	await _settle()
	_check(not tabs._pointer_held and not tabs._glass.visible and tabs._backdrop.copy_mode == BackBufferCopy.COPY_MODE_DISABLED and not tabs.is_processing(), "按住时隐藏页签立即清理手势及屏幕复制")
	await _hold_switch_button(tabs.edit_button, false)
	tabs.show()
	await _settle()
	_check(tabs.get_page() == 0 and not editor._level_guide_editor.is_open() and not tabs._glass.visible, "重新显示页签保留已选编辑页且不会复活按住玻璃")


## 直接使用最终玻璃控件的目标像素边界，不重算组件内部的滑块形状、留白或复制公式。
func _check_switch_sampling(tabs: EditorPageSwitch, context: String) -> void:
	var rendered_bounds := root.get_final_transform() * tabs._glass.get_global_rect()
	_check(tabs._pointer_held and tabs._glass.is_visible_in_tree() and tabs._backdrop.copy_mode == BackBufferCopy.COPY_MODE_RECT, "真实按住启用可见玻璃及局部取样：" + context)
	_check(rendered_bounds.has_area() and tabs._backdrop.rect.grow(0.5).encloses(rendered_bounds), "复制范围覆盖实际玻璃像素区域：" + context + " copy=" + str(tabs._backdrop.rect) + " rendered=" + str(rendered_bounds))


## 分开发送原生按下和释放，让交互材质在检查时持续处于按住状态。
func _hold_switch_button(button: Button, pressed: bool) -> void:
	var point := root.get_final_transform() * button.get_global_rect().get_center()
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	Input.parse_input_event(event)
	await _settle()


## 原生文本选择经真实格式按钮生成可持久化源文，单次撤销恢复且预览不泄漏格式标记。
func _test_format_toolbar(editor: MapEditor) -> void:
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.dialogue = []
	model.replace_document(document)
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	var marks := {"bold": "**", "italic": "*", "underline": "++", "strike": "~~"}
	for key: String in marks:
		_input_text(guide, "Alpha")
		guide._text.select_all()
		await _click(guide._format_buttons[key])
		_check(guide._text.text == str(marks[key]) + "Alpha" + str(marks[key]) and guide._text.has_focus(), "格式按钮修改真实选中文本并返回输入焦点：" + key + " actual=" + guide._text.text)
		await _click(guide._preview_button)
		_check(guide._preview.get_parsed_text() == "Alpha", "预览正确消费格式标记而保留正文：" + key + " actual=" + guide._preview.get_parsed_text())
		await _click(guide._preview_button)
		guide._text.undo()
		await _settle()
		_check(guide._text.text == "Alpha", "一次原生文本撤销恢复格式前正文：" + key)
	var lists := {"bullet": "- Alpha\n- Beta", "numbered": "1. Alpha\n2. Beta", "task": "- [ ] Alpha\n- [ ] Beta"}
	for key: String in lists:
		_input_text(guide, "Alpha\nBeta")
		guide._text.select_all()
		await _click(guide._format_buttons[key])
		_check(guide._text.text == lists[key], "列表工具处理所选全部行并保存明确标记：" + key + " actual=" + guide._text.text.replace("\n", "\\n"))
		guide._text.undo()
		await _settle()
		_check(guide._text.text == "Alpha\nBeta", "列表操作作为一个文本事务撤销：" + key)
	_check(model.document.dialogue.is_empty() and not model.can_undo(), "格式编辑仍只修改指引草稿，不拆成地图历史")
	await _show_edit_tab(editor)
	_check(model.document.dialogue.size() == 1 and model._undo_stack.size() == 1, "格式工具编辑结束后由切页统一提交一次地图事务")


## 混合输入在原生文本历史中清除三段私用区，emoji及连接序列保留，非法输入不能重做复活。
func _test_portable_input(editor: MapEditor) -> void:
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.dialogue = [{"speaker": "旧作者", "text": "前😀👩‍💻后", "future": {"keep": true}}]
	model.replace_document(document)
	var baseline := JSON.stringify(document.to_dict())
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	var edit := guide._text
	edit.set_caret_column(1)
	edit.begin_complex_operation()
	edit.insert_text_at_caret("!")
	edit.end_complex_operation()
	await _settle()
	var earlier := "前!😀👩‍💻后"
	var private_text := "" + String.chr(0xE000) + String.chr(0xF0000) + String.chr(0x100000) + String.chr(0x10FFFD)
	var kept := "🌊👨‍👩‍👧‍👦\n中😀"
	await _paste_guide_text(guide, private_text + kept + private_text)
	var expected := "前!" + kept + "😀👩‍💻后"
	_check(edit.text == expected, "混合粘贴过滤 BMP 与补充平面私用字符，普通 emoji 和 ZWJ 家庭序列完整保留")
	_check(edit.get_caret_line() == 1 and edit.get_caret_column() == "中😀".length(), "过滤后光标留在粘贴末尾，按剩余 Unicode 字符计算位置")
	edit.undo()
	await _settle()
	_check(edit.text == earlier, "文本原生一次撤销只撤销粘贴，保留此前合法编辑")
	edit.undo()
	await _settle()
	_check(edit.text == "前😀👩‍💻后", "过滤没有清空此前历史，继续撤销可恢复原文")
	edit.redo()
	await _settle()
	_check(edit.text == earlier, "原生重做先恢复此前合法编辑")
	edit.redo()
	await _settle()
	_check(edit.text == expected and edit.text.find("") == -1, "文本原生重做只恢复过滤后的输入，不复活私用区字符")
	edit.undo()
	await _settle()
	edit.undo()
	await _settle()
	await _key(KEY_ESCAPE)
	_check(JSON.stringify(model.document.to_dict()) == baseline and not model.is_dirty() and not model.can_undo(), "过滤后的输入撤销回原文再关闭，不改变旧字段或产生文档事务")
	await _click(editor._level_guide_button)
	edit.set_caret_column(1)
	var before_caret := Vector2i(edit.get_caret_line(), edit.get_caret_column())
	await _paste_guide_text(guide, private_text)
	_check(edit.text == "前😀👩‍💻后" and Vector2i(edit.get_caret_line(), edit.get_caret_column()) == before_caret, "仅非法粘贴保持原文和光标")
	if edit.has_redo():
		edit.redo()
		await _settle()
	_check(edit.text == "前😀👩‍💻后", "仅非法粘贴的重做也不能插回被过滤字符")
	for code: int in [0xF8FF, 0xE000, 0xF0000, 0x100000]:
		await _unicode_key(code)
	_check(edit.text == "前😀👩‍💻后" and Vector2i(edit.get_caret_line(), edit.get_caret_column()) == before_caret, "原生 Unicode 键盘事件在文本接收前挡住各段私用区输入")
	await _key(KEY_ESCAPE)
	_check(JSON.stringify(model.document.to_dict()) == baseline and not model.is_dirty() and not model.can_undo(), "仅非法粘贴和键入关闭后不制造地图修改或撤销记录")
	for format: String in ["plain", "markdown"]:
		document = model.document.duplicate_document()
		document.dialogue = [{"speaker": "旧作者", "text": "旧原文😀" + String.chr(0xF0000), "format": format, "future": {"keep": [1, 2]}}]
		model.replace_document(document)
		baseline = JSON.stringify(document.to_dict())
		await _click(editor._level_guide_button)
		var source := guide._text.text
		await _click(guide._preview_button)
		_check(guide._preview.get_parsed_text() == "旧原文😀", "旧私用字形在预览隐藏而普通 emoji 保留：" + format)
		await _click(guide._preview_button)
		_check(guide._text.text == source, "旧页编辑与预览往返保留全部原始正文：" + format)
		await _key(KEY_ESCAPE)
		_check(JSON.stringify(model.document.to_dict()) == baseline and not model.is_dirty() and not model.can_undo(), "旧 PUA 原文仅打开切换关闭不隐式清洗源文：" + format)


## 剪贴板支持的真实窗口使用原生粘贴快捷键，无窗口回归仍走 TextEdit 插入与 text_changed 路径。
func _paste_guide_text(guide: MapGuideEditor, value: String) -> void:
	guide._text.grab_focus()
	if DisplayServer.get_name() == "headless":
		guide._text.insert_text_at_caret(value)
		await _settle()
		return
	var original := DisplayServer.clipboard_get()
	DisplayServer.clipboard_set(value)
	await _key(KEY_V, OS.get_name() != "macOS", OS.get_name() == "macOS")
	DisplayServer.clipboard_set(original)


## 直接送入真实窗口的 Unicode 字符事件，补充平面仍使用完整码点而非代理对。
func _unicode_key(code: int) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.unicode = code
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame
	await _settle()


## 实际点击 RichTextLabel 的两条网页链接，只调用注入的打开器并始终保留编辑草稿。
func _test_preview_links(editor: MapEditor) -> void:
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.dialogue = []
	model.replace_document(document)
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	var opened: Array[String] = []
	guide.link_opener = func(url: String) -> int:
		opened.append(url)
		return OK
	var urls: Array[String] = ["http://example.com/guide?q=1", "https://example.com/guide?q=2#part"]
	var source := "[HTTP](%s)\n[HTTPS](%s)\n*斜体说明*" % urls
	_input_text(guide, source)
	await _click(guide._preview_button)
	_check(guide._preview.get_parsed_text() == "HTTP\nHTTPS\n斜体说明", "预览显示链接标签与斜体正文，Markdown 标记不泄漏为普通文字")
	var label := guide._preview
	var font := label.get_theme_font("normal_font")
	var font_size := label.get_theme_font_size("normal_font_size")
	var style := label.get_theme_stylebox("normal")
	for index in urls.size():
		var caption := "HTTP" if index == 0 else "HTTPS"
		var local := Vector2(style.get_margin(SIDE_LEFT) + font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 0.5, style.get_margin(SIDE_TOP) + label.get_line_offset(index) + font.get_height(font_size) * 0.5)
		await _click_at(label.get_global_transform() * local)
		_check(opened.size() == index + 1 and opened[index] == urls[index], "真实鼠标点击网页标签调用注入打开器一次：" + urls[index])
	_check(guide.is_open() and guide._previewing and not guide._error.visible and model.document.dialogue.is_empty() and not model.can_undo(), "点击网页后内嵌页保持预览，草稿与文档提交边界不变")
	await _click(guide._preview_button)
	_check(guide._text.text == source, "点击链接再返回编辑保留完整 Markdown 源文")
	await _key(KEY_ESCAPE)
	_check(model.document.dialogue.size() == 1 and model.document.dialogue[0].text == source and model._undo_stack.size() == 1, "含链接的草稿关闭后仍只提交一次引导事务")
	guide.link_opener = Callable()


## 旧页面未编辑不自动转格式，清空正文关闭才移除该页，扩展字段完整保留。
func _test_legacy_and_empty(editor: MapEditor) -> void:
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.dialogue = [{"speaker": "旧作者", "text": "# 旧标题\n**原文**", "future": {"keep": [1, 2]}}, {"text": "第二页"}]
	model.replace_document(document)
	var baseline := JSON.stringify(document.to_dict())
	await _click(editor._level_guide_button)
	var old_guide := editor._level_guide_editor
	await _click(old_guide._preview_button)
	_check(old_guide._preview.get_parsed_text() == "# 旧标题\n**原文**", "旧纯文本页预览保留Markdown标记，与正式展示一致")
	await _click(old_guide._preview_button)
	_input_text(old_guide, "# 改后正文")
	old_guide._text.undo()
	await _settle()
	_check(old_guide._text.text == "# 旧标题\n**原文**", "文本自身撤销回原正文")
	await _key(KEY_ESCAPE)
	_check(JSON.stringify(model.document.to_dict()) == baseline and not model.can_undo(), "正文撤销还原后保留原speaker和旧格式，不生成伪修改")
	await _click(editor._level_guide_button)
	await _click(editor._level_guide_editor._next)
	await _click(editor._level_guide_editor._previous)
	await _key(KEY_ESCAPE)
	_check(JSON.stringify(model.document.to_dict()) == baseline and not model.can_undo(), "旧地图打开、浏览和关闭不隐式转换格式或历史")
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	_input_text(guide, "# 新标题\n可编程模块 原文")
	await _click(guide._next)
	_input_text(guide, "  \n  ")
	await _key(KEY_ESCAPE)
	_check(model.document.dialogue.size() == 1 and model.document.dialogue[0].future == {"keep": [1, 2]} and model.document.dialogue[0].format == "markdown", "清空页不保存，修改非空页保留未知扩展字段")
	await _click(editor._level_guide_button)
	_input_text(guide, "# 切页提交\n正文依然保存")
	var cells_before := model.document.cells.duplicate(true)
	var saved_before := model.document.dialogue.duplicate(true)
	await _click(editor._zoom_in_button)
	_check(guide.is_open() and model.document.dialogue == saved_before and model.document.cells == cells_before, "指引不占用模态浮层，使用地图工具不会关闭或提交草稿")
	await _show_edit_tab(editor)
	_check(not guide.is_open() and model.document.dialogue[0].text.begins_with("# 切页提交") and model.document.cells == cells_before, "切回编辑页签提交草稿而不修改地图格子")


## 窄屏三语下指引位于属性卡片内，编辑/指引页签与正文导航保留独立点击区域。
func _test_layout(editor: MapEditor) -> void:
	for dimensions in [Vector2i(1000, 740), Vector2i(1280, 800)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			await _settle()
			var edit_tab := editor.find_child("MapEditorEditTab", true, false) as Button
			var guide_tab := editor.find_child("MapEditorGuideTab", true, false) as Button
			var card := editor._properties_card.get_global_rect()
			_check(edit_tab != null and guide_tab == editor._level_guide_button and card.encloses(edit_tab.get_global_rect()) and card.encloses(guide_tab.get_global_rect()) and not edit_tab.get_global_rect().intersects(guide_tab.get_global_rect()), "编辑和指引页签在卡片内独立且不溢出：" + locale + str(dimensions))
			await _click(editor._level_guide_button)
			var guide := editor._level_guide_editor
			_check(root.get_visible_rect().grow(1).encloses(card) and card.grow(1).encloses(guide.get_global_rect()) and guide.get_global_rect().grow(1).encloses(guide._text.get_global_rect()) and not editor._creator_field.is_visible_in_tree(), "指引正文内嵌卡片并替换编辑表单：" + locale + str(dimensions))
			_check(guide._text.text == "# 切页提交\n正文依然保存" and guide._text.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "切换界面语言不翻译用户正文：" + locale)
			for control: Control in [guide._toolbar, guide._previous, guide._next, guide._preview_button, guide._title]:
				_check(card.grow(1).encloses(control.get_global_rect()) and not guide._text.get_global_rect().intersects(control.get_global_rect()), "工具栏和分页不遮挡正文或越出卡片：" + locale + " " + str(control.name))
			_check_toolbar_centered(guide, locale + str(dimensions))
			await _show_edit_tab(editor)
			_check(editor._creator_field.is_visible_in_tree() and not guide.is_visible_in_tree(), "切回编辑后表单恢复，指引正文不残留：" + locale)
	_game.settings.set_language("zh_CN")
	await _settle()
	await _click(editor._level_guide_button)
	await _capture("map-guide-editor.png")
	await _show_edit_tab(editor)


## 按控件最终矩形合并同一工具行，检查每一行实际居中而非只检查容器配置。
func _check_toolbar_centered(guide: MapGuideEditor, context: String) -> void:
	var rows: Array[Rect2] = []
	for child in guide._toolbar.get_children():
		if not child is Control or not child.is_visible_in_tree():
			continue
		var bounds: Rect2 = child.get_rect()
		var row_index := -1
		for index in rows.size():
			if bounds.position.y < rows[index].end.y - 0.1 and bounds.end.y > rows[index].position.y + 0.1:
				row_index = index
				break
		if row_index < 0:
			rows.append(bounds)
		else:
			rows[row_index] = rows[row_index].merge(bounds)
	_check(not rows.is_empty(), "工具栏包含真实可见控件行：" + context)
	for index in rows.size():
		_check(absf(rows[index].get_center().x - guide._toolbar.size.x * 0.5) <= 1.1, "工具栏各行内容沿卡片中线居中：" + context + " row=" + str(index + 1))


## 保存、另存为、重新打开和未保存试玩使用同一引导数据，不读写正式游玩记录。
func _test_save_and_play(editor: MapEditor) -> void:
	var model := editor.editor_document
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	var saved_source := "# 当前页直接保存\n++下划线++ 和 ~~删除线~~"
	_input_text(guide, saved_source)
	guide._text.select(1, 2, 1, 5)
	var selected_text := guide._text.get_selected_text()
	var before_save_undo := model._undo_stack.size()
	await _key(KEY_S, true)
	var managed_path := model.path
	var loaded := MapCodec.load_file(managed_path, editor.registry, false)
	_check(loaded.is_ok() and loaded.value.dialogue == JSON.parse_string(JSON.stringify(model.document.dialogue)) and loaded.value.dialogue[0].text == saved_source and not model.is_dirty(), "指引中保存快捷键先提交当前草稿再写入隔离地图")
	_check(guide.is_open() and guide._text.text == saved_source and guide._text.has_focus() and guide._text.get_selected_text() == selected_text and model._undo_stack.size() == before_save_undo + 1, "保存保留当前指引页、输入焦点及选区，只新增一个地图事务")
	await _click(guide._preview_button)
	await _click(editor._header.save_button)
	_check(guide.is_open() and guide._previewing and model._undo_stack.size() == before_save_undo + 1, "预览中再次保存不重复提交且不跳出当前预览")
	await _show_edit_tab(editor)
	_check(model._undo_stack.size() == before_save_undo + 1, "保存后切回编辑不重复提交已经保存的草稿")
	editor._file_dialog.use_native_dialog = false
	editor._save_document(true)
	var export_path := _temporary.path_join("exports/guide.json")
	editor._file_dialog.file_selected.emit(export_path)
	editor._file_dialog.hide()
	loaded = MapCodec.load_file(export_path, editor.registry, false)
	_check(loaded.is_ok() and loaded.value.dialogue == JSON.parse_string(JSON.stringify(model.document.dialogue)), "另存为导出保留相同引导")
	editor._new_document()
	_check(model.get_guide_pages().is_empty(), "新建地图不会继承上一地图的引导")
	editor._load_document(export_path)
	await _click(editor._level_guide_button)
	_input_text(guide, "# 未保存试玩\n## 小标题\n### 小节\n玩家正文")
	var undo_count := model._undo_stack.size()
	var path := model.path
	await _click(editor._play_button)
	_check(_game.page == GameShell.Page.ASSEMBLY and _game.session.level.document.dialogue[0].text.begins_with("# 未保存试玩"), "试玩使用当前未保存引导快照进入空装配")
	_check(not guide.is_visible_in_tree() and model._undo_stack.size() == undo_count + 1, "试玩隐藏编辑卡片并且只提交一次当前引导草稿")
	var before := JSON.stringify(model.document.to_dict())
	_game._dialogue_dialog.hide()
	_game._return_to_editor()
	await _settle()
	_check(_game._editor == editor and JSON.stringify(model.document.to_dict()) == before and model.path == path and model._undo_stack.size() == undo_count + 1 and model.is_dirty(), "试玩返回保留同一文档、引导、路径和撤销历史")
	_check(guide.is_open() and guide.is_visible_in_tree() and guide._text.text.begins_with("# 未保存试玩"), "试玩返回保留作者所在的指引页与当前正文")
	await _show_edit_tab(editor)
	_check(model._undo_stack.size() == undo_count + 1, "试玩返回后切页不重复提交已接受的草稿")


## 新建和打开的取消路径保留当前指引页、预览与已提交草稿，不把询问当作离开编辑器。
func _test_canceled_document_actions(editor: MapEditor) -> void:
	var model := editor.editor_document
	var document := model.document.duplicate_document()
	document.dialogue = [{"speaker": "引导", "text": "# 第一页", "format": "markdown"}, {"speaker": "引导", "text": "# 第二页", "format": "markdown"}]
	model.replace_document(document)
	await _click(editor._level_guide_button)
	var guide := editor._level_guide_editor
	await _click(guide._next)
	var source := "# 保留第二页\n取消操作后仍可继续编辑。"
	_input_text(guide, source)
	await _click(guide._preview_button)
	await _click(editor._header.new_button)
	_check(editor._dirty_dialog.visible and guide.is_open() and guide._previewing and guide._page_index == 1 and model.document.dialogue[1].text == source and model._undo_stack.size() == 1, "新建先提交当前草稿并询问，保留指引第二页预览")
	var snapshot := model.document.to_dict()
	editor._dirty_dialog.get_cancel_button().pressed.emit()
	editor._dirty_dialog.hide()
	await _settle()
	_check(guide.is_visible_in_tree() and guide.is_open() and guide._previewing and guide._page_index == 1 and guide._text.text == source and model.document.to_dict() == snapshot and model._undo_stack.size() == 1, "取消新建保持当前指引、预览、正文与历史")
	await _click(editor._header.more_button)
	await _click(editor._actions_menu.find_child("MapEditorOpenMenuItem", true, false) as Button)
	_check(editor._dirty_dialog.visible and not editor._file_dialog.visible, "未保存时打开地图先走保护询问")
	editor._dirty_dialog.get_cancel_button().pressed.emit()
	editor._dirty_dialog.hide()
	await _settle()
	_check(guide.is_open() and guide._previewing and guide._page_index == 1 and guide._text.text == source and model.document.to_dict() == snapshot and model._undo_stack.size() == 1, "取消打开地图询问不会收起或清空指引草稿")
	await _click(editor._header.save_button)
	var saved_path := model.path
	var saved_bytes := FileAccess.get_file_as_bytes(saved_path)
	editor._file_dialog.use_native_dialog = false
	await _click(editor._header.more_button)
	await _click(editor._actions_menu.find_child("MapEditorOpenMenuItem", true, false) as Button)
	_check(editor._file_dialog.visible and not editor._dirty_dialog.visible and guide.is_open(), "保存后打开文件选择器仍保留原指引页")
	editor._file_dialog.canceled.emit()
	editor._file_dialog.hide()
	await _settle()
	_check(guide.is_visible_in_tree() and guide._previewing and guide._page_index == 1 and guide._text.text == source and not model.is_dirty() and FileAccess.get_file_as_bytes(saved_path) == saved_bytes, "取消文件选择保留第二页预览与已经保存的地图文件")
	_check(not editor._load_document(_temporary.path_join("missing-guide-map.json"), false) and guide.is_open() and guide._text.text == source, "打开失败保留当前指引页与正文")
	_check(editor._load_document(saved_path) and not guide.is_open() and not guide.is_visible_in_tree(), "成功打开地图才离开旧指引并恢复编辑页")


## 通过真实页签命中离开指引，提交边界不依赖已经移除的浮窗关闭按钮。
func _show_edit_tab(editor: MapEditor) -> void:
	await _click(editor.find_child("MapEditorEditTab", true, false) as Button)


## 以原生TextEdit输入接口更新当前页面，保持真实text_changed信号路径。
func _input_text(guide: MapGuideEditor, text: String) -> void:
	guide._text.grab_focus()
	guide._text.select_all()
	guide._text.insert_text_at_caret(text)
	guide._text.text_changed.emit()


## 所有按钮都经完整鼠标按下和抬起，避免直接信号掩盖浮层拦截错误。
func _click(button: Button) -> void:
	_check(button.is_visible_in_tree() and not button.disabled, "测试按钮可操作：" + str(button.name))
	await _click_at(button.get_global_rect().get_center())


## 更新真实指针后发送配对点击，确保全局鼠标状态与实际交互一致。
func _click_at(position: Vector2) -> void:
	# 原生输入接收窗口像素，按钮矩形是逻辑坐标；缩放窗口时先转换，避免误点旁边的控件。
	position = root.get_final_transform() * position
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	Input.parse_input_event(motion)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame
	await _settle()


## 快捷键经过真实输入分发，文本编辑与外层保存沿各自的正常处理链执行。
func _key(code: Key, control: bool = false, meta: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.ctrl_pressed = control
		event.meta_pressed = meta
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame
	await _settle()


## 截图只能来自GPU真实渲染，headless运行跳过可选展示文件。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename)) == OK, "保存真实引导界面截图")


## 等待布局和延迟信号处理完成。
func _settle() -> void:
	await process_frame
	await process_frame


## 将断言失败输出到日志并反映在退出码。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 仅清理当前测试创建的独占目录。
func _cleanup(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
