extends SceneTree
## 统计说明与首次运行日期的真实界面回归，档案与设置仅写入本轮独占目录。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _fixture: Control
var _profile: PlayerProfileStore
var _panel: PlayerProfilePanel
var _font_scale: GameFontScale
var _reset_count := 0
var _background_count := 0


## 明确指定截图目录后才保存 GPU 视口，普通自动验证不生成模拟画面。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 独立模型覆盖日期与模态，最后使用真实外壳检查返回路由和生命周期。
func _run() -> void:
	_temporary = "user://tests/statistics_about_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var original_locale := TranslationServer.get_locale()
	var original_transparent := root.transparent_bg
	GameI18n.install()
	TranslationServer.set_locale("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_profile = PlayerProfileStore.new(_temporary.path_join("profile.json"))
	_check(_profile.load_profile().is_ok(), "独立档案加载成功")
	_fixture = Control.new()
	_fixture.theme = GameTheme.create_theme()
	root.add_child(_fixture)
	_fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color.WHITE
	_fixture.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var behind := GameTheme.button(_fixture, "背景操作", func() -> void: _background_count += 1)
	behind.position = Vector2(16, 16)
	behind.size = Vector2(100, 40)
	_font_scale = GameFontScale.new()
	_font_scale.scope = _fixture
	_fixture.add_child(_font_scale)
	_panel = PlayerProfilePanel.new()
	_panel.profile = _profile
	_panel.reset_requested.connect(func() -> void: _reset_count += 1)
	_fixture.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font_scale.layout_check = _panel._layout_card
	await _settle()
	await _test_rows()
	await _test_modal_input(behind)
	await _test_layouts()
	await _test_overflow_fade()
	_fixture.queue_free()
	await _settle()
	await _test_shell_navigation()
	root.transparent_bg = original_transparent
	TranslationServer.set_locale(original_locale)
	_remove_tree(_temporary)
	print("STATISTICS_ABOUT_UI_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 日期来自只读模型接口，刷新、翻译和隐藏彩蛋都不改变行顺序或历史日期。
func _test_rows() -> void:
	var longest := _panel.find_child("PlayerLongestRow", true, false)
	var first := _panel.find_child("PlayerFirstRunRow", true, false)
	var mystery := _panel.find_child("PlayerMysteryRow", true, false)
	_check(first != null and longest != null and mystery != null, "日期行和相邻统计行存在")
	if first != null and longest != null and mystery != null:
		_check(first.get_index() == longest.get_index() + 2 and mystery.get_index() == first.get_index() + 2, "日期紧跟最长耗时、位于隐藏彩蛋之前")
	var date := _profile.get_first_run_date()
	_check(not date.is_empty() and _panel._first_run_value.text == date and not _panel._mystery_row.visible, "新档案日期可见，未触发彩蛋继续隐藏")
	_profile.record_hint_use()
	await _settle()
	_check(_panel._first_run_value.text == date, "统计变化刷新不会覆盖首次运行日期")
	var button := _panel._statistics_help_button
	_check(button.get_parent().get_index() == _panel._delete_button.get_index() + 1, "问号入口位于删除档案按钮下方")
	_check(button.size.is_equal_approx(Vector2(32, 32)) and button.icon != null and button.get_theme_stylebox("focus") is StyleBoxEmpty, "问号使用固定圆形图标且无蓝色焦点框")
	_check(absf(button.get_global_rect().end.x - _panel._delete_button.get_global_rect().end.x) < 1.0, "问号入口与删除按钮右边界对齐")
	_panel._scroll.scroll_vertical = 100000
	await _settle()
	await _capture("statistics_profile_zh_CN")


## 真实鼠标、键盘和滚轮只作用于模态；关闭恢复入口，遮罩不可穿透。
func _test_modal_input(background_button: Button) -> void:
	await _show_help()
	var dialog := _panel._statistics_about_dialog
	_check(dialog is CanvasLayer and dialog.get_parent() == _panel and not _panel._content_fade.is_ancestor_of(dialog), "说明独立画布避开设置正文渐隐遮罩")
	_check(_panel.is_statistics_about_open() and dialog._close.has_focus(), "真实点击问号打开说明并聚焦关闭按钮")
	_check(dialog._title.text == "关于统计" and dialog._body.text == StatisticsAboutDialog.DESCRIPTION and dialog._close.text == "关闭", "中文标题、完整正文和关闭按钮精确匹配")
	var surface := dialog._panel.get_theme_stylebox("panel") as StyleBoxFlat
	_check(surface.bg_color == Color.WHITE and surface.corner_radius_top_left == 24 and surface.corner_radius_bottom_right == 24 and dialog._dimmer.color.a > 0.0 and dialog._dimmer.color.a < 1.0, "单一白色圆角卡片配灰色半透明遮罩")
	_check(dialog._close.get_theme_stylebox("focus") is StyleBoxEmpty, "默认关闭焦点不会显示蓝框")
	_check(dialog._body.get_theme_font_size("font_size") == 11 and dialog._body.get_theme_constant("line_spacing") == 4 and dialog._title.get_theme_font_size("font_size") == 22 and dialog._close.get_theme_font_size("font_size") == 16, "正文缩小至原字号约六成，标题与关闭按钮字号保持不变")
	var initial_bytes := FileAccess.get_file_as_bytes(_temporary.path_join("profile.json"))
	_click(background_button.get_global_rect().get_center())
	_click(_panel._delete_button.get_global_rect().get_center())
	await _settle()
	_check(dialog.is_open() and _background_count == 0 and _reset_count == 0, "遮罩阻止背景操作与删除按钮，点击卡片外不关闭")
	var previous_scroll := _panel._scroll.scroll_vertical
	_mouse(Vector2(24, 24), MOUSE_BUTTON_WHEEL_DOWN)
	_key(KEY_TAB)
	_key(KEY_A, "x".unicode_at(0))
	await _settle()
	_check(dialog._close.has_focus() and previous_scroll == _panel._scroll.scroll_vertical, "Tab 焦点不逃出模态，背景滚动和输入被拦截")
	_check(FileAccess.get_file_as_bytes(_temporary.path_join("profile.json")) == initial_bytes, "查看统计说明不修改玩家档案")
	_key(KEY_ESCAPE)
	await _settle()
	_check(not dialog.is_open() and _panel._statistics_help_button.has_focus(), "Esc 收起说明并恢复问号焦点")
	await _show_help()
	_click(dialog._close.get_global_rect().get_center())
	await _settle()
	_check(not dialog.is_open(), "真实鼠标点击右下关闭按钮收起说明")
	await _show_help()
	_key(KEY_ENTER)
	await _settle()
	_check(not dialog.is_open(), "回车激活唯一的关闭动作")
	await _show_help()
	_panel.hide()
	await _settle()
	_check(not dialog.is_open() and not dialog._overlay.visible, "统计页面隐藏同步清理 CanvasLayer 浮层")
	_panel.show()
	await _settle()


## 四种语言和字号比例在大小视口中保持卡片居中、关闭可达、长正文可滚动。
func _test_layouts() -> void:
	var date := _profile.get_first_run_date()
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(960, 640)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for locale: String in ["zh_CN", "zh_HK", "es", "en"]:
			TranslationServer.set_locale(locale)
			for percentage: int in [100, 150, 200]:
				_font_scale.set_percentage(percentage)
				await _settle()
				await _show_help()
				var context := "%dx%d_%s_%d" % [dimensions.x, dimensions.y, locale, percentage]
				var dialog := _panel._statistics_about_dialog
				_check_geometry(dialog, context)
				_check(dialog._panel.size.is_equal_approx(Vector2(384, 384)), "语言与字号不撑长固定方形弹窗 " + context)
				_check(dialog._body.get_theme_font_size("font_size") == roundi(11.0 * percentage / 100.0), "缩小正文继续沿用字体缩放 " + context)
				_check(_panel._first_run_value.text == date and _panel._statistics_help_button.size.is_equal_approx(Vector2(32, 32)), "日期稳定且放大文字不拉长圆形入口 " + context)
				_check(dialog._title.atr(dialog._title.text) == dialog.tr("关于统计") and dialog._body.atr(dialog._body.text) == dialog.tr(StatisticsAboutDialog.DESCRIPTION), "标题和正文使用当前语言 " + context)
				if locale != "zh_CN":
					_check(dialog.tr(StatisticsAboutDialog.DESCRIPTION) != StatisticsAboutDialog.DESCRIPTION, "非简体语言提供完整说明翻译 " + context)
				var bar := dialog._scroll.get_v_scroll_bar()
				var overflow := bar.max_value > bar.page + 0.5
				var strength := _fade_strength(dialog)
				_check(is_zero_approx(strength.x) and (strength.y > 0.0 if overflow else is_zero_approx(strength.y)), "首屏只在真实下方溢出时渐隐，没有溢出时完整显示 " + context)
				if dimensions.x == 960 and percentage == 200 and overflow:
					var before := dialog._scroll.scroll_vertical
					_key(KEY_PAGEDOWN)
					await _settle()
					_check(dialog._scroll.scroll_vertical > before, "实际溢出的小屏大字正文可滚动 " + context)
					await _capture("statistics_about_" + context)
				elif dimensions.x == 1280 and percentage == 100:
					await _capture("statistics_about_" + context)
				_panel.close_statistics_about(false)
	# 外层白卡展示缩放单独覆盖，不继承正文八成缩放。
	TranslationServer.set_locale("zh_CN")
	_font_scale.set_percentage(100)
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_fixture.set_meta("ui_menu_layout_scale", 1.5)
	await _settle()
	await _show_help()
	_check_geometry(_panel._statistics_about_dialog, "outer_scale_150")
	_check(_panel._statistics_about_dialog._panel.scale.is_equal_approx(Vector2(1.5, 1.5)), "说明继承外层呈现比例而不是统计正文的八成缩放")
	_panel.close_statistics_about(false)
	_fixture.remove_meta("ui_menu_layout_scale")


## 使用真实长翻译和大字号验证顶中底渐隐，文字与滚动条仍由原生容器驱动。
func _test_overflow_fade() -> void:
	root.size = Vector2i(960, 640)
	root.content_scale_size = root.size
	_font_scale.set_percentage(200)
	TranslationServer.set_locale("en")
	await _settle()
	await _show_help()
	var dialog := _panel._statistics_about_dialog
	var close_rect := dialog._close.get_global_rect()
	var card_rect := dialog._panel.get_global_rect()
	var bar := dialog._scroll.get_v_scroll_bar()
	var limit := maxf(0.0, bar.max_value - bar.page)
	_check(limit > ScrollContentFade.FADE_WIDTH * 2.0, "实际英文正文在固定方卡与 200% 字号下产生足够滚动范围")
	_check(dialog._content_fade.is_ancestor_of(dialog._scroll) and not dialog._content_fade.is_ancestor_of(dialog._title) and not dialog._content_fade.is_ancestor_of(dialog._close), "只有正文进入透明合成组，标题与关闭按钮保持清晰")
	_check(is_zero_approx(_fade_strength(dialog).x) and _fade_strength(dialog).y > 0.0, "到达顶部时首行不渐隐，下边缘提示剩余正文")
	await _capture("statistics_fade_en_200_top")
	_mouse(dialog._scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
	await _settle()
	_check(dialog._scroll.scroll_vertical > 0 and dialog._scroll.scroll_vertical < limit, "真实滚轮在渐隐正文内滚动且不会穿透背景")
	dialog._scroll.scroll_vertical = roundi(limit * 0.5)
	await _settle()
	var middle := _fade_strength(dialog)
	_check(middle.x > 0.0 and middle.y > 0.0, "正文中段同时在上下边缘透明渐隐")
	_check(close_rect.is_equal_approx(dialog._close.get_global_rect()) and card_rect.is_equal_approx(dialog._panel.get_global_rect()), "滚动正文不移动白卡或关闭按钮")
	await _capture("statistics_fade_en_200_middle")
	for _attempt in range(60):
		if dialog._scroll.scroll_vertical >= limit - 1.0:
			break
		_mouse(dialog._scroll.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_DOWN)
		await _settle()
	_check(dialog._scroll.scroll_vertical >= limit - 1.0 and _fade_strength(dialog).x > 0.0 and is_zero_approx(_fade_strength(dialog).y), "真实滚轮到底后恢复末行清晰，只保留上边缘渐隐")
	await _capture("statistics_fade_en_200_bottom")
	# 打开的窗口内直接切换语言，卡片和关闭锚点不跟随翻译文字长度变化。
	for locale: String in ["es", "zh_HK", "zh_CN", "en"]:
		TranslationServer.set_locale(locale)
		await _settle()
		_check_geometry(dialog, "live_translation_" + locale)
		_check(card_rect.is_equal_approx(dialog._panel.get_global_rect()) and close_rect.end.is_equal_approx(dialog._close.get_global_rect().end), "弹窗内切换语言保持外形与关闭按钮右下锚点 " + locale)
		dialog._scroll.scroll_vertical = 0
		await _settle()
		var remaining := bar.max_value - bar.page
		_check(is_zero_approx(_fade_strength(dialog).x) and (_fade_strength(dialog).y > 0.0 if remaining > 0.5 else is_zero_approx(_fade_strength(dialog).y)), "翻译重新排版后渐隐范围按实际内容更新 " + locale)
		if locale == "es":
			await _capture("statistics_fade_es_200_top")
	_font_scale.set_percentage(100)
	TranslationServer.set_locale("zh_CN")
	await _settle()
	_check(card_rect.is_equal_approx(dialog._panel.get_global_rect()) and bar.max_value <= bar.page + 0.5 and _fade_strength(dialog).is_zero_approx(), "缩回正常字号后正文无溢出，自动取消上下渐隐")
	_click(dialog._close.get_global_rect().get_center())
	await _settle()
	_check(not dialog.is_open(), "发生滚动与翻译后关闭按钮仍可真实点击")
	root.size = Vector2i(800, 600)
	root.content_scale_size = root.size
	_fixture.set_meta("ui_menu_layout_scale", 1.5)
	_font_scale.set_percentage(200)
	TranslationServer.set_locale("es")
	await _settle()
	await _show_help()
	_check_geometry(dialog, "800x600_es_font200_outer150")
	_check(dialog._panel.size.y < 384.0 and dialog._scroll.size.y > 0.0, "小屏叠加外层比例时限制卡片高度，并为正文保留滚动区域")
	await _capture("statistics_fade_800x600_es_200_outer150")
	_click(dialog._close.get_global_rect().get_center())
	await _settle()
	_check(not dialog.is_open(), "小屏叠加字体与外层比例后关闭仍可点击")
	_fixture.remove_meta("ui_menu_layout_scale")
	_font_scale.set_percentage(100)
	TranslationServer.set_locale("zh_CN")
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	await _settle()


## 读取实际合成材质参数，避免仅按滚动位置推测是否存在透明渐隐。
func _fade_strength(dialog: StatisticsAboutDialog) -> Vector2:
	return dialog._content_fade._fade_material.get_shader_parameter("edge_strength") as Vector2


## 验证实际绘制范围而非仅局部尺寸，避免缩放后的按钮、留白或标题越过卡片。
func _check_geometry(dialog: StatisticsAboutDialog, context: String) -> void:
	var card := dialog._panel.get_global_rect()
	var screen := root.get_visible_rect()
	_check(dialog.is_open() and screen.grow(1).encloses(card) and card.get_center().distance_to(screen.get_center()) <= 1.0, "模态白卡居中且完整位于视口 " + context)
	_check(card.grow(1).encloses(dialog._title.get_global_rect()) and card.grow(1).encloses(dialog._scroll.get_global_rect()) and card.grow(1).encloses(dialog._close.get_global_rect()), "标题、正文和关闭按钮都位于卡片内 " + context)
	_check(dialog._footer_gap.get_global_rect().end.y <= dialog._close.global_position.y and dialog._close.get_global_rect().end.x <= card.end.x and dialog.find_child("StatisticsAboutSeparator", true, false) == null, "正文与关闭栏只保留透明留白，关闭按钮仍靠右 " + context)
	_check(dialog._body.size.x <= dialog._scroll.size.x + 1.0 and dialog._scroll.get_h_scroll_bar().visible == false, "长文换行并仅使用纵向滚动 " + context)


## 完整外壳必须先关闭模态再处理页面返回，直接切页或销毁不能留下遮罩。
func _test_shell_navigation() -> void:
	var game := load("res://scenes/game.tscn").instantiate() as GameShell
	game.settings_path = _temporary.path_join("shell_settings.json")
	game.profile_path = _temporary.path_join("shell_profile.json")
	game.drafts_directory = _temporary.path_join("solutions")
	game.user_levels_directory = _temporary.path_join("levels")
	root.add_child(game)
	await _settle()
	game._show_player_profile_page()
	await _settle()
	var panel := game.player_profile_panel
	panel._scroll.scroll_vertical = 100000
	await _settle()
	await _capture("statistics_shell_profile_zh_CN")
	_click(panel._statistics_help_button.get_global_rect().get_center())
	await _settle()
	_check(panel.is_statistics_about_open(), "真实外壳中的问号打开统计说明")
	await _capture("statistics_shell_about_zh_CN")
	game._go_back()
	await _settle()
	_check(game.page == GameShell.Page.PLAYER_PROFILE and not panel.is_statistics_about_open(), "外壳返回先收起说明，继续停留统计页")
	panel._open_statistics_about()
	await _settle()
	var old_dialog: WeakRef = weakref(panel._statistics_about_dialog)
	game._show_settings_page()
	await _settle()
	_check(old_dialog.get_ref() == null and game.page == GameShell.Page.SETTINGS, "切页释放说明与遮罩，不保留孤立画布")
	game._show_player_profile_page()
	await _settle()
	panel = game.player_profile_panel
	panel._open_statistics_about()
	await _settle()
	old_dialog = weakref(panel._statistics_about_dialog)
	game.queue_free()
	await _settle()
	_check(old_dialog.get_ref() == null, "游戏场景销毁释放仍打开的统计说明")


## 将底部问号移入可点区域后发送真实鼠标事件，不用直接信号代替入口验证。
func _show_help() -> void:
	_panel._scroll.scroll_vertical = 100000
	await _settle()
	_click(_panel._statistics_help_button.get_global_rect().get_center())
	await _settle()


## 向真实视口推送完整的按下与松开，保留原生 GUI 命中规则。
func _click(point: Vector2) -> void:
	_mouse(point, MOUSE_BUTTON_LEFT)


## 滚轮与点击共用事件入口，检查遮罩对鼠标输入的实际阻挡。
func _mouse(point: Vector2, button: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)


## 默认 UI 动作来自真实按键映射，不直接调用关闭回调。
func _key(code: Key, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.unicode = unicode
		event.pressed = pressed
		root.push_input(event, true)


## 等待容器重排、字体刷新和 deferred 信号完成。
func _settle() -> void:
	for _frame in range(6):
		await process_frame


## 截图仅取真实 GPU 视口，并记录保存失败。
func _capture(filename: String) -> void:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(root.get_texture().get_image().save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存截图 " + filename)


## 汇总所有独立断言，失败时保留清晰的场景标签。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("STATISTICS_ABOUT_UI_TEST: " + message)
	return condition


## 清理仅限本次创建的隔离目录，不碰正式玩家文件。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	for child in directory.get_files():
		directory.remove(child)
	DirAccess.remove_absolute(path)
