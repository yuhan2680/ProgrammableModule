extends SceneTree
## 自定义引导共用真实关卡入口与试玩流程，验证受控 Markdown、翻页和旧教学兼容。

var _checks := 0
var _failures := 0
var _game: GameShell
var _temporary := ""
var _capture_dir := ""
var _opened_urls: Array[String] = []


## 延迟建立场景，避免初始化期间向根节点添加子节点。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 使用独占设置和草稿目录验证两种正文格式，结束时只清理本次测试文件。
func _run() -> void:
	Engine.max_fps = 120
	_temporary = "user://tests/player_guide_runtime_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1000, 740)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.system_sound_preview_handler = func() -> void: pass
	_game.guide_link_opener = _record_link
	root.add_child(_game)
	await _settle()
	await _test_safe_renderer()
	await _test_emphasis_and_urls()
	await _test_runtime_links()
	await _test_custom_pages()
	await _test_builtin_compatibility()
	await _test_playtest_and_empty_pages()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("玩家关卡引导运行时回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 用户标签始终作为文本，标题只有受控字号变化；图片及非 Markdown 标签不能成为资源。
func _test_safe_renderer() -> void:
	var preview := RichTextLabel.new()
	preview.size = Vector2(600, 400)
	preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(preview)
	var source := "# 一级标题 🦈\n## 二级标题\n### 三级标题\n普通 **粗体** 与 `move(0, 1)`\n- 列表\n[url=https://example.com]链接[/url]\n[img]res://missing.png[/img]\n<script>literal</script>\n![image](https://example.com/image.png)\n#没有空格\n#### 未支持层级"
	GuideMarkdown.render(preview, source)
	await _settle()
	var parsed := preview.get_parsed_text()
	_check(not preview.bbcode_enabled and preview.auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "共享渲染器禁用BBCode及用户正文翻译")
	_check(parsed.begins_with("一级标题 🦈\n二级标题\n三级标题\n普通 粗体 与 move(0, 1)\n• 列表"), "标题、粗体、代码与列表按有限语法排版")
	_check(parsed.contains("[url=https://example.com]链接[/url]") and parsed.contains("[img]res://missing.png[/img]"), "BBCode链接与图片标签完整显示为文字")
	_check(parsed.contains("<script>literal</script>") and parsed.contains("![image](https://example.com/image.png)"), "HTML和Markdown图片不会解释或下载")
	_check(parsed.contains("#没有空格") and parsed.contains("#### 未支持层级"), "不符合标题规则的井号原样保留")
	GuideMarkdown.render(preview, "# 同样的文字")
	await _settle()
	var heading_height := preview.get_content_height()
	GuideMarkdown.render(preview, "同样的文字")
	await _settle()
	_check(heading_height > preview.get_content_height(), "一级标题真实使用更大的字体而非只删除井号")
	GuideMarkdown.render(preview, "未闭合 **粗体\n下一行 `代码\n结束")
	_check(preview.get_parsed_text() == "未闭合 **粗体\n下一行 `代码\n结束", "未完成语法保持原文，不吞掉后续内容")
	preview.queue_free()
	await _settle()


## 覆盖嵌套强调、转义、代码和网页地址，不把无效链接或图片转换为可点击目标。
func _test_emphasis_and_urls() -> void:
	var label := RichTextLabel.new()
	label.size = Vector2(600, 400)
	root.add_child(label)
	var cases := {
		"*中文 italic* 与 _English italic_": "中文 italic 与 English italic",
		"***粗斜体*** 与 ___bold italic___": "粗斜体 与 bold italic",
		"**粗体 *内含斜体* 结尾**": "粗体 内含斜体 结尾",
		"*斜体 **内含粗体** 结尾*": "斜体 内含粗体 结尾",
		"**粗体 *共享三星***": "粗体 共享三星",
		"*斜体 **共享三星***": "斜体 共享三星",
		"***粗体** 斜体*": "粗体 斜体",
		"***斜体* 粗体**": "斜体 粗体",
		"_斜体 **混合**_ 与 **粗体 _混合_**": "斜体 混合 与 粗体 混合",
		"`*代码* _name_ [链接](https://example.com)`": "*代码* _name_ [链接](https://example.com)",
		"\\*原文\\* module_name foo_bar_baz": "*原文* module_name foo_bar_baz",
		"未闭合 *正文 和 _正文": "未闭合 *正文 和 _正文",
		"[**网页**](https://example.com/a_(b)?x=1#top)": "网页",
		"**[网页](https://example.com/a**b) 结尾**": "网页 结尾",
		"**[网页](https://example.com/a*b) 结尾**": "网页 结尾",
		"[坏链接](javascript:alert(1))": "[坏链接](javascript:alert(1))",
		"![图片](https://example.com/image.png)": "![图片](https://example.com/image.png)",
		"旧正文🐬": "旧正文🐬",
	}
	for source: String in cases:
		GuideMarkdown.render(label, source)
		_check(label.get_parsed_text() == cases[source], "强调及链接排版保留正文：" + source)
	var italic := label.get_theme_font("italics_font") as FontVariation
	var combined := label.get_theme_font("bold_italics_font") as FontVariation
	_check(italic != null and combined != null and italic.variation_transform != Transform2D.IDENTITY and combined.variation_transform == italic.variation_transform, "斜体由字体轮廓变换生成，粗斜体共用倾角")
	for url: String in ["https://example.com/", "HTTP://example.com:8080/path?a=1&b=2#top", "https://例子.测试/中文", "https://[::1]/", "https://example.com/a_(b)"]:
		_check(GuideMarkdown.is_web_url(url), "完整网页地址可点击：" + url)
	for url: String in ["", "example.com", "//example.com", "javascript:alert(1)", "file:///tmp/a", "res://a", "mailto:a@b", "https://example.com/\nfoo", "https://example.com/ a", "https://user:pass@example.com/", "https://example.com/", "https://example.com/\\a"]:
		_check(not GuideMarkdown.is_web_url(url), "无效或非网页地址不会打开：" + url)
	GuideMarkdown.render(label, "普通 Normal\n*斜体 Italic*\n**粗体 Bold**\n***粗斜体 Bold italic***\n[网页链接](https://example.com/)\n普通 emoji 🐬 👩🏽‍💻")
	await _settle()
	await _capture("guide-markdown-emphasis-links.png")
	label.queue_free()
	await _settle()


## 真实引导点击链接调用注入的系统打开器，显示和关闭均不自动打开网页或修改地图。
func _test_runtime_links() -> void:
	var url := "https://example.com/a_(b)*c**d?x=1#top"
	var source := "**[打开网页](" + url + ") 结尾**\n*斜体说明* 🐬"
	var level := _level("web_guide", [{"text": source, "format": "markdown"}])
	var original := level.document.to_dict()
	_game._enter_level(level)
	await _settle()
	_check(_opened_urls.is_empty(), "展示 Markdown 链接不会自动打开网页")
	var body := _game._dialogue_markdown
	await _click_link(body, url)
	_check(_opened_urls == [url] and _game._dialogue_dialog.visible, "实际点击粗体包裹的链接保留星号、括号及完整目标，且引导窗口保持打开")
	_check(level.document.to_dict() == original and _game._dialogue_dialog.dialog_text == source, "网页跳转不改写地图或 Markdown 源文")
	body.meta_clicked.emit("file:///tmp/rejected")
	_check(_opened_urls.size() == 1, "运行入口再次拒绝非网页元数据")
	_game._dialogue_dialog.hide()
	body.meta_clicked.emit("https://example.com/hidden")
	_check(_opened_urls.size() == 1, "关闭引导后的元数据不打开网页")


## 通过根窗口路由真实嵌入弹窗的输入；GPU 元数据命中读取系统指针，因此同步并恢复其位置。
func _click_link(label: RichTextLabel, url: String) -> void:
	var hovered: Array = []
	var on_hover := func(meta: Variant) -> void: hovered.append(meta)
	label.meta_hover_started.connect(on_hover)
	var native := DisplayServer.get_name() != "headless"
	var saved_mouse := root.get_mouse_position() if native else Vector2.ZERO
	var point := Vector2.ZERO
	for y in range(8, 64, 6):
		for x in range(8, 170, 6):
			# 局部正文先经屏幕变换回根逻辑坐标，再换成根窗口输入像素；不能直接送进嵌入子窗口。
			var logical := root.get_screen_transform().affine_inverse() * (label.get_screen_transform() * Vector2(x, y))
			if native:
				root.warp_mouse(logical)
				await _settle()
			point = root.get_final_transform() * logical
			var motion := InputEventMouseMotion.new()
			motion.position = point
			motion.global_position = motion.position
			Input.parse_input_event(motion)
			Input.flush_buffered_events()
			await process_frame
			if hovered.has(url):
				break
		if hovered.has(url):
			break
	_check(hovered.has(url), "网页文字有真实可点击区域")
	if hovered.has(url):
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = point
			event.global_position = event.position
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = down
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
			Input.parse_input_event(event)
			Input.flush_buffered_events()
			await process_frame
	label.meta_hover_started.disconnect(on_hover)
	if native:
		root.warp_mouse(saved_mouse)
	await _settle()


## 回归不启动宿主浏览器，仅记录已通过系统打开入口的实际目标。
func _record_link(url: String) -> int:
	_opened_urls.append(url)
	return OK


## 正式玩家关卡自动弹出引导，空页不计数，长中文可以滚动且切换语言不翻译用户文字。
func _test_custom_pages() -> void:
	var markdown := "# 可编程模块 🦈\n\n## 小节标题\n" + "玩家原文保持不变，长中文没有空格也能自动换行。🌙\n".repeat(80)
	var pages := [
		{"speaker": "引导", "text": " \n\t", "format": "markdown"},
		{"speaker": "可编程模块", "text": markdown, "format": "markdown"},
		{"speaker": "玩家自写标题", "text": "可编程模块"},
		{"speaker": "引导", "text": "# 最后一页\n结束后自己组装。", "format": "markdown"},
		{"speaker": "引导", "text": "", "format": "markdown"},
	]
	var level := _level("custom_guide", pages)
	if level == null:
		return
	var original := JSON.stringify(level.document.to_dict())
	_game._enter_level(level)
	await _settle()
	var dialog := _game._dialogue_dialog
	var body := _game._dialogue_markdown
	_check(dialog.visible and _game.page == GameShell.Page.ASSEMBLY, "玩家关卡进入空装配时自动显示第一页")
	_check(_game._dialogue_pages.size() == 4 and dialog.title == "可编程模块 · 1 / 4", "非空用户页后追加系统页，页码包含系统页且自写标题保持原文")
	_check(not dialog.get_label().visible and body.visible and body.scroll_active and not body.fit_content, "Markdown采用独立滚动正文，旧Label隐藏")
	_check(dialog.dialog_text == markdown and dialog.get_label().text == markdown, "原生兼容接口仍保留完整原文")
	_check(dialog.size.x <= root.get_visible_rect().size.x - 24 and dialog.size.y <= root.get_visible_rect().size.y - 48, "长文不会将弹窗撑出最小窗口：" + str(dialog.size))
	_check(body.get_content_height() > body.size.y and body.size.x <= dialog.size.x, "长中文真正产生可滚动内容并保持有限宽度")
	_check(_game._dialogue_previous.disabled, "第一页上一页禁用")
	await _capture("player-guide-markdown.png")
	body.scroll_to_line(20)
	await _settle()
	var before_scroll := body.get_v_scroll_bar().value
	for locale in ["en", "zh_HK", "zh_CN"]:
		_game.settings.set_language(locale)
		await _settle()
		_check(body.get_parsed_text().begins_with("可编程模块 🦈") and dialog.title == "可编程模块 · 1 / 4", "切换语言不翻译用户标题与正文：" + locale)
		_check(is_equal_approx(body.get_v_scroll_bar().value, before_scroll), "切换语言不重建正文或重置滚动：" + locale + str([before_scroll, body.get_v_scroll_bar().value]))
	dialog.confirmed.emit()
	await _settle()
	_check(_game._dialogue_index == 1 and dialog.get_label().visible and not body.visible, "第二页旧纯文格式正确切换显示控件")
	_check(dialog.get_label().text == "可编程模块" and dialog.get_label().auto_translate_mode == Node.AUTO_TRANSLATE_MODE_DISABLED, "玩家纯文也不会被碰巧同名的词典替换")
	_game._dialogue_previous.pressed.emit()
	await _settle()
	_check(_game._dialogue_index == 0 and body.visible and is_zero_approx(body.get_v_scroll_bar().value), "回到上一页从顶部显示")
	dialog.confirmed.emit()
	dialog.confirmed.emit()
	await _settle()
	_check(dialog.title == "引导 · 3 / 4" and dialog.ok_button_text == "下一页", "最后一张用户页之后仍有系统程序说明")
	for locale: String in ["en", "zh_HK", "zh_CN"]:
		_game.settings.set_language(locale)
		await _settle()
		var heading := "Guide" if locale == "en" else "引導" if locale == "zh_HK" else "引导"
		_check(dialog.title == heading + " · 3 / 4" and body.get_parsed_text().begins_with("最后一页"), "固定引导页头翻译而用户正文不变：" + locale)
	dialog.confirmed.emit()
	await _settle()
	_check(dialog.visible and _game._dialogue_index == 3 and dialog.ok_button_text == "开始编辑", "系统程序说明是最后一页，确认才结束引导")
	_check(dialog.get_label().text == WorkbenchProgramGuide.entry_text(level) and dialog.get_label().auto_translate_mode == Node.AUTO_TRANSLATE_MODE_INHERIT, "玩家关卡系统说明独立参与翻译")
	for locale: String in ["en", "zh_HK", "zh_CN"]:
		_game.settings.set_language(locale)
		await _settle()
		_check(_game.tr(dialog.get_label().text) == str(TranslationServer.translate(WorkbenchProgramGuide.entry_text(level))), "系统末页随语言变化使用现有完整译文：" + locale)
		if locale != "zh_CN":
			_check(_game.tr(dialog.get_label().text) != dialog.get_label().text, "系统末页确实具备目标语言译文：" + locale)
	dialog.confirmed.emit()
	_check(not dialog.visible and _game.page == GameShell.Page.ASSEMBLY and _game.session.assembly.modules.is_empty(), "完成引导只关闭弹窗，仍须玩家自己组装")
	_game.assembly_panel.header.help_requested.emit()
	await _settle()
	_check(dialog.visible and _game._dialogue_index == 0 and dialog.title.ends_with("1 / 4"), "页头帮助可从第一张有效引导重新打开")
	_check(JSON.stringify(level.document.to_dict()) == original and level.document.dialogue.size() == 5, "过滤空页和翻页均不改写地图数据")
	dialog.hide()


## 内置教学继续走原Label与翻译词典，不能被自定义Markdown模式改变导航和原文接口。
func _test_builtin_compatibility() -> void:
	_game.settings.set_language("en")
	var level: LevelDefinition = _game.catalog.levels[0]
	_game._enter_level(level)
	await _settle()
	var dialog := _game._dialogue_dialog
	_check(dialog.visible and dialog.get_label().visible and not _game._dialogue_markdown.visible, "回到教学关卡恢复旧纯文正文")
	_check(dialog.dialog_text == level.document.dialogue[0].text and dialog.get_label().auto_translate_mode == Node.AUTO_TRANSLATE_MODE_INHERIT, "教学仍保留原始字符串并由原生Label参与翻译")
	_check(_game.tr(dialog.get_label().text) != dialog.get_label().text, "教学正文继续取得英文译文")
	for index in range(level.document.dialogue.size()):
		_check(dialog.visible and dialog.dialog_text == level.document.dialogue[index].text, "旧教学翻页保持原JSON顺序")
		dialog.confirmed.emit()
	_check(dialog.visible and dialog.dialog_text == WorkbenchProgramGuide.entry_text(level), "旧教学原页之后追加系统程序说明")
	dialog.confirmed.emit()
	_check(not dialog.visible, "教学与系统末页读完后正常结束")
	_game.settings.set_language("zh_CN")


## 未保存试玩复用引导；全空用户页仍显示系统程序说明，原始地图与历史保持不变。
func _test_playtest_and_empty_pages() -> void:
	_game._open_editor()
	await _settle()
	var editor := _game._editor
	var before := JSON.stringify(editor.editor_document.document.to_dict())
	var level := _level("preview_guide", [{"speaker": "引导", "text": "# 未保存试玩 🦈\n检查自己的关卡。", "format": "markdown"}])
	_game._start_editor_playtest(level, _game.registry)
	await _settle()
	_check(_game._editor_playtest and _game._dialogue_dialog.visible and _game._dialogue_markdown.get_parsed_text().begins_with("未保存试玩 🦈"), "编辑器试玩入口自动显示当前快照引导")
	_game._dialogue_dialog.confirmed.emit()
	_game._show_dialogue()
	_check(_game._dialogue_dialog.visible, "试玩也可重复打开当前引导")
	_game._return_to_editor()
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and not _game._dialogue_dialog.visible and JSON.stringify(editor.editor_document.document.to_dict()) == before, "回到编辑器完整保留原地图与未保存状态")
	var blank := _level("blank_guide", [{"speaker": "引导", "text": " \n", "format": "markdown"}])
	_game._enter_level(blank)
	await _settle()
	_check(_game._dialogue_dialog.visible and _game._dialogue_pages.size() == 1 and blank.document.dialogue.size() == 1, "全空用户页仅显示系统程序说明，底层原始dialogue保留")
	_check(_game._dialogue_dialog.dialog_text == WorkbenchProgramGuide.entry_text(blank), "无用户引导的地图也有对应程序说明")


## 复用真实有效地图结构构建独立玩家关卡，不能绕过地图与关卡校验。
func _level(identity: String, pages: Array) -> LevelDefinition:
	var document := _game.catalog.levels[0].document.duplicate_document()
	document.id = identity
	document.dialogue = pages.duplicate(true)
	var result := LevelDefinition.from_document(document, _game.registry, _temporary.path_join("levels/" + identity + ".json"))
	_check(result.is_ok(), "自定义引导通过正式地图与关卡校验")
	return result.value if result.is_ok() else null


## 仅在真实渲染器和显式绝对输出目录下保存截图，方便审查自定义引导的实际排版。
func _capture(filename: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	_check(_capture_dir.is_absolute_path(), "截图目录使用绝对路径")
	if not _capture_dir.is_absolute_path():
		return
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(filename)) == OK, "保存自定义引导的真实截图")


## 给容器尺寸和原生弹窗布局足够帧数协商。
func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


## 统计断言并让失败通过退出码传播给统一测试脚本。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 递归清理仅限本轮独占目录，不访问真实玩家关卡或设置。
func _cleanup(path: String) -> void:
	if not path.begins_with(_temporary + "/") and path != _temporary:
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for child in directory.get_directories():
		_cleanup(path.path_join(child))
	DirAccess.remove_absolute(path)
