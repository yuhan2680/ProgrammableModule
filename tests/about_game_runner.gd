extends SceneTree
## 关于窗口的真实输入回归；系统打开器始终注入无副作用替身，文件仅写入独占测试目录。

const LINKS := [
	{"node": "AboutWebsiteLink", "text": "https://naiwenel.com/", "url": "https://naiwenel.com/"},
	{"node": "AboutBilibiliLink", "text": "Bilibili", "url": "https://space.bilibili.com/443343766"},
	{"node": "AboutYoutubeLink", "text": "YouTube", "url": "https://www.youtube.com/@YWMKerman"},
	{"node": "AboutGithubLink", "text": "GitHub", "url": "https://github.com/YWMKerman"},
	{"node": "AboutEmailLink", "text": "YWMKerman@gmail.com", "url": "mailto:YWMKerman@gmail.com"},
]
const TITLES := {"zh_CN": "可编程模块", "zh_HK": "可編程模組", "en": "Programmable Modules"}
const ENTRIES := {"zh_CN": "关于", "zh_HK": "關於", "en": "About"}
const AUTHORS := "小涵Naiwenel · YWMKerman"

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _opened_urls: Array[String] = []
var _opener_result: int = OK


## 仅明确指定截图目录时输出真实 GPU 画面，普通回归保持无交互运行。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 独占设置和存档路径，在两种窗口尺寸运行全部语言，结束后还原进程全局状态。
func _run() -> void:
	_temporary = "user://tests/about_game_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var original_volume := AudioServer.get_bus_volume_db(master)
	var original_mute := AudioServer.is_bus_mute(master)
	var original_transparent := root.transparent_bg
	root.gui_embed_subwindows = true
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.about_link_opener = _record_link
	root.add_child(_game)
	await _settle()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1000, 740)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "en"]:
			_game.settings.set_language(locale)
			_game._show_main_page()
			await _settle()
			await _click(_game.find_child("SettingsButton", true, false) as Control)
			await _check_about("%dx%d_%s" % [dimensions.x, dimensions.y, locale], locale)
	_game.queue_free()
	await _settle()
	_check(root.transparent_bg == original_transparent, "销毁设置与关于窗口恢复原视口透明状态")
	AudioServer.set_bus_volume_db(master, original_volume)
	AudioServer.set_bus_mute(master, original_mute)
	TranslationServer.set_locale(original_locale)
	_remove_tree(_temporary)
	print("关于游戏回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 一次打开覆盖固定内容、可达链接和失败反馈，再验证关闭方式及切页清理。
func _check_about(context: String, locale: String) -> void:
	if not _check(_game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "真实设置入口可达 " + context):
		return
	var panel := _game.settings_panel
	var entry := panel.find_child("AboutButton", true, false) as Button
	var language := panel.find_child("LanguageRow", true, false) as Control
	var more := panel.find_child("MoreSettingsGroup", true, false)
	if not _check(entry != null and language != null and more != null, "关于入口与更多分组存在 " + context):
		return
	_check(more.is_ancestor_of(entry) and entry.get_parent() == language.get_parent() and entry.get_index() == 0, "关于游戏是更多分组第一行 " + context)
	_check(entry.get_global_rect().end.y <= language.global_position.y and entry.atr(entry.text) == ENTRIES[locale], "关于入口位于语言行上方并正确翻译 " + context)
	_check(absf(entry.global_position.x - language.global_position.x) < 1.0 and absf(entry.size.x - language.size.x) < 1.0, "关于入口沿用更多分组左右边界 " + context)
	await _scroll_to(panel._scroll, entry, 56.0, context)
	var saved_settings := FileAccess.get_file_as_bytes(_game.settings_path)
	var initial_calls := _opened_urls.size()
	_game._open_about_link(LINKS[0].url)
	_check(_opened_urls.size() == initial_calls, "关于未打开时忽略外链请求 " + context)
	await _open_entry(entry)
	var dialog := _game._about_dialog
	if not _check(dialog != null and dialog.is_open(), "真实点击关于入口打开窗口 " + context):
		return
	_check(_opened_urls.size() == initial_calls, "打开窗口不触发任何系统外链 " + context)
	_check(dialog is CanvasLayer and not panel.is_ancestor_of(dialog), "关于窗口独立画布不继承设置渐隐 " + context)
	var card := dialog.find_child("AboutGamePanel", true, false) as Control
	var scroll := dialog.find_child("AboutGameScroll", true, false) as ScrollContainer
	var close := dialog.find_child("AboutCloseButton", true, false) as Button
	var error := dialog.find_child("AboutGameLinkError", true, false) as Label
	if not _check(card != null and scroll != null and close != null and error != null, "正文、滚动、关闭和错误节点齐全 " + context):
		dialog.close_dialog()
		return
	_check(root.get_visible_rect().grow(1).encloses(card.get_global_rect()) and card.size.y > card.size.x, "竖向关于卡片完整位于窗口内 " + context)
	_check(card.get_global_rect().grow(1).encloses(scroll.get_global_rect()) and card.get_global_rect().grow(1).encloses(close.get_global_rect()), "正文滚动与关闭按钮位于卡片内 " + context)
	_check(scroll.get_global_rect().end.y <= close.global_position.y and close.has_focus(), "关闭按钮常驻正文下方并获得默认焦点 " + context)
	_check(not error.is_visible_in_tree(), "打开时无残留外链错误 " + context)
	_check_content(dialog, locale, context)
	await _capture(context + "_about")
	await _check_focus(dialog, scroll, close, context)
	for spec: Dictionary in LINKS:
		var link := dialog.find_child(spec.node, true, false) as LinkButton
		if not _check(link != null, "真实链接控件存在 " + str(spec.node) + " " + context):
			continue
		_check(link.text == spec.text and link.atr(link.text) == spec.text and link.tooltip_text == spec.url and link.uri.is_empty(), "链接原文及地址固定且系统调用只经外壳 " + str(spec.node) + " " + context)
		await _scroll_to(scroll, link, 0.0, context)
		var before := _opened_urls.size()
		await _click(link)
		_check(_opened_urls.size() == before + 1 and _opened_urls[-1] == spec.url, "一次真实点击只打开对应地址 " + str(spec.node) + " " + context)
		_check(dialog.is_open() and _game.page == GameShell.Page.SETTINGS, "外链点击保留关于及设置页 " + context)
	var valid_calls := _opened_urls.size()
	for invalid: String in ["https://naiwenel.com.evil/", "https://github.com/YWMKerman/other", "mailto:someone@example.com", "javascript:alert(1)"]:
		_game._open_about_link(invalid)
	_check(_opened_urls.size() == valid_calls, "相似域名、任意路径和非白名单协议不交给系统 " + context)
	var settings_scroll := panel._scroll.scroll_vertical
	await _click(_game._back_button, MOUSE_BUTTON_WHEEL_DOWN)
	_check(dialog.is_open() and panel._scroll.scroll_vertical == settings_scroll, "关于外侧滚轮不能滚动底层设置页 " + context)
	_opener_result = ERR_CANT_OPEN
	var email := dialog.find_child("AboutEmailLink", true, false) as Control
	await _scroll_to(scroll, email, 0.0, context)
	await _click(email)
	_check(_opened_urls.size() == valid_calls + 1 and _opened_urls[-1] == LINKS[-1].url, "失败测试仍只尝试一次精确邮箱地址 " + context)
	_check(dialog.is_open() and error.is_visible_in_tree() and not _game._message_dialog.visible, "系统打开失败在关于窗口内反馈 " + context)
	_check(error.atr(error.text) == _game.tr("打开链接失败，请稍后重试。") and (locale == "zh_CN" or error.atr(error.text) != error.text), "外链失败反馈按当前语言显示 " + context)
	_check(scroll.get_global_rect().grow(1).encloses(error.get_global_rect()) and card.get_global_rect().grow(1).encloses(close.get_global_rect()), "错误就地可见且不挤走关闭按钮 " + context)
	await _capture(context + "_about_error")
	_opener_result = OK
	await _click(close)
	_check(not dialog.is_open() and entry.has_focus(), "真实关闭按钮恢复关于入口焦点 " + context)
	var after_links := _opened_urls.size()
	await _key(KEY_ENTER)
	await _animate()
	_check(dialog.is_open() and close.has_focus() and not error.is_visible_in_tree(), "入口回车重新打开并清空失败反馈 " + context)
	await _key(KEY_ESCAPE)
	_check(not dialog.is_open() and entry.has_focus() and _game.page == GameShell.Page.SETTINGS, "Esc只关闭关于并恢复入口焦点 " + context)
	await _open_entry(entry)
	await _click(_game._back_button)
	_check(not dialog.is_open() and entry.has_focus() and _game.page == GameShell.Page.SETTINGS, "外部点击完整吞掉按下和抬起，不穿透返回药丸 " + context)
	_check(FileAccess.get_file_as_bytes(_game.settings_path) == saved_settings, "查看、链接和关闭均不改写玩家设置 " + context)
	await _key(KEY_ENTER)
	await _animate()
	_game._show_code_colors_page()
	await _settle()
	_check(_game.page == GameShell.Page.CODE_COLORS and not dialog.is_open() and not card.is_visible_in_tree(), "切换子页同步关闭关于窗口 " + context)
	_game._open_about_link(LINKS[0].url)
	_check(_opened_urls.size() == after_links, "键盘打开、关闭和离开设置不会触发外链 " + context)
	_game._show_main_page()
	await _settle()


## 身份和年份保持原文，界面标题跟随语言，网站及社交链接归属正确作者。
func _check_content(dialog: Node, locale: String, context: String) -> void:
	var title := dialog.find_child("AboutGameTitle", true, false) as Label
	var authors := dialog.find_child("AboutGameAuthors", true, false) as Label
	var years := dialog.find_child("AboutGameYears", true, false) as Label
	var author_heading := dialog.find_child("AboutGameAuthorsHeading", true, false) as Label
	var contact := dialog.find_child("AboutGameContactHeading", true, false) as Label
	var website_author := dialog.find_child("AboutGameWebsiteAuthor", true, false) as Label
	var social_author := dialog.find_child("AboutGameSocialAuthor", true, false) as Label
	_check(title != null and title.atr(title.text) == TITLES[locale], "游戏标题正确翻译 " + context)
	_check(authors != null and authors.text == AUTHORS and authors.atr(authors.text) == AUTHORS, "作者身份保持完整原文 " + context)
	_check(years != null and years.text == "2026–2027" and years.atr(years.text) == "2026–2027", "年份固定显示2026–2027 " + context)
	_check(author_heading != null and contact != null and author_heading.atr(author_heading.text) == _game.tr("作者") and contact.atr(contact.text) == _game.tr("联系我们"), "作者及联系标题使用当前语言 " + context)
	if locale != "zh_CN" and contact != null:
		_check(contact.atr(contact.text) != contact.text, "联系标题提供独立繁体和英文译文 " + context)
	var website := dialog.find_child("AboutWebsiteLink", true, false)
	_check(website_author != null and website_author.text == "小涵Naiwenel" and website_author.atr(website_author.text) == website_author.text and website != null and website.get_parent() == website_author.get_parent(), "个人网站明确属于小涵Naiwenel " + context)
	_check(social_author != null and social_author.text == "YWMKerman" and social_author.atr(social_author.text) == social_author.text, "社交资料明确属于YWMKerman " + context)
	if social_author != null:
		for link_name: String in ["AboutBilibiliLink", "AboutYoutubeLink", "AboutGithubLink"]:
			var link := dialog.find_child(link_name, true, false)
			_check(link != null and social_author.get_parent().is_ancestor_of(link), "社交链接归于同一作者 " + link_name + " " + context)


## Tab必须遍历全部六项并闭环，反向Tab和回车同样通过视口真实输入。
func _check_focus(dialog: Node, scroll: ScrollContainer, close: Control, context: String) -> void:
	var before := _opened_urls.size()
	var visited: Dictionary = {}
	for step in 6:
		await _key(KEY_TAB)
		var focused := root.gui_get_focus_owner()
		_check(focused != null and dialog.is_ancestor_of(focused), "Tab焦点不能进入背后设置页 " + context)
		if focused != null:
			visited[focused.name] = true
			if focused != close:
				_check(scroll.get_global_rect().grow(1).encloses(focused.get_global_rect()), "键盘目标自动滚入完整可见区域 " + context)
	_check(visited.size() == 6 and close.has_focus(), "Tab遍历五个链接与关闭后回到关闭 " + context)
	await _key(KEY_TAB, true)
	_check(root.gui_get_focus_owner() == dialog.find_child("AboutEmailLink", true, false), "Shift+Tab在窗口内反向导航 " + context)
	await _key(KEY_TAB)
	await _key(KEY_TAB)
	_check(root.gui_get_focus_owner() == dialog.find_child("AboutWebsiteLink", true, false), "正向Tab定位第一个链接 " + context)
	_check(_opened_urls.size() == before, "仅浏览焦点不会打开地址 " + context)
	await _key(KEY_ENTER)
	_check(_opened_urls.size() == before + 1 and _opened_urls[-1] == LINKS[0].url, "真实回车只激活聚焦网站 " + context)


## 真实滚轮将目标移入有效命中区，设置顶部渐隐区域不视为完整可见内容。
func _scroll_to(scroll: ScrollContainer, target: Control, top_inset: float, context: String) -> void:
	if not _check(target != null, "滚动目标存在 " + context):
		return
	for attempt in 40:
		var area := scroll.get_global_rect()
		area.position.y += top_inset
		area.size.y -= top_inset
		if area.grow(1).encloses(target.get_global_rect()):
			return
		var previous := scroll.scroll_vertical
		var direction := MOUSE_BUTTON_WHEEL_DOWN if target.get_global_rect().end.y > area.end.y else MOUSE_BUTTON_WHEEL_UP
		await _click(scroll, direction, Vector2(0.02, 0.5))
		if previous == scroll.scroll_vertical:
			break
	_check(scroll.get_global_rect().grow(1).encloses(target.get_global_rect()), "真实滚轮到达目标 " + target.name + " " + context)


## 实际坐标打开入口，等待动画完成后再检查最终卡片和透明度。
func _open_entry(entry: Control) -> void:
	await _click(entry)
	await _animate()


## 替身仅记录参数并返回可控制错误码，绝不调用浏览器或邮件客户端。
func _record_link(url: String) -> int:
	_opened_urls.append(url)
	return _opener_result


## 鼠标经根视口实际命中和原生处理，不直接发射产品按钮信号。
func _click(control: Control, button: MouseButton = MOUSE_BUTTON_LEFT, fraction: Vector2 = Vector2(0.5, 0.5)) -> void:
	if not _check(control != null, "待点击控件存在"):
		return
	var point := control.global_position + control.size * fraction
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()


## Tab修饰键、回车与Esc均发送完整按下和抬起，验证真实输入生命周期。
func _key(keycode: Key, shift: bool = false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.shift_pressed = shift
		event.pressed = pressed
		root.push_input(event, true)
	await _settle()


## 等容器和焦点的延迟布局完成，不用硬编码坐标替代实际布局。
func _settle() -> void:
	for frame in 4:
		await process_frame


## 打开动画持续不足两百毫秒，等待稳定画面再读取几何或截图。
func _animate() -> void:
	await create_timer(0.20).timeout
	await _settle()


## 截图严格读取真实GPU视口，headless运行不创建模拟图片。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(image.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存GPU截图 " + filename)


## 汇总所有语言与分辨率失败，最后以退出码报告回归结果。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 清理范围仅限本轮新建的独占测试目录。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
