class_name GameShell
extends Control
## 游戏入口负责页面切换、关卡目录、草稿与系统文件夹交互，不参与世界模拟。

enum Page { MAIN, LEVELS, ASSEMBLY, PLAY, EDITOR, SETTINGS, CODE_COLORS }

# 选关页固定七列；缩小图标并独立保留文字字号，导入项沿用相同卡片尺寸。
const LEVEL_COLUMNS := 7
const LEVEL_CARD_SIZE := 104.0
const LEVEL_THUMBNAIL_SIZE := 88
const LEVEL_COLUMN_MIN_WIDTH := 104.0
const LEVEL_CARD_RADIUS := 34

# 单独运行地图编辑器场景时仍复用相同页面路由，不再维护另一套试玩界面。
@export var start_in_editor: bool = false

# 这些依赖可以在测试中替换，避免测试打开资源管理器或写入玩家的真实草稿。
var user_levels_directory: String = "user://levels"
var drafts_directory: String = "user://solutions"
var settings_path: String = "user://settings.json"
var folder_opener: Callable
# 关于链接由系统打开；测试可注入替身而不启动真实浏览器或邮件程序。
var about_link_opener: Callable
var quit_handler: Callable
# 仅由轻量启动场景注入；直接运行游戏或编辑器场景仍在 _ready 中同步初始化。
var startup_reporter: Callable
var startup_complete := false
var registry := ContentRegistry.new()
var catalog := LevelCatalog.new()
var drafts: GameDraftStore
var session: GameSession
var workbench: GameWorkbench
var settings: GameSettings
var window_controller: GameWindowController
var page: Page = Page.MAIN
var assembly_panel: AssemblyPanel
var settings_panel: SettingsPanel
var code_color_panel: CodeColorPanel

var _level_header: LevelBrowserHeader
var _main_background: MainMenuBackground
var _header: HBoxContainer
var _body: VBoxContainer
var _title: Label
var _subtitle: Label
var _back_button: Button
var _text_back_button: Button
var _header_mark: TextureRect
var _level_navigation: Panel
var _refresh_button: Button
var _help_button: Button
var _save_label: Label
var _catalog_status: Label
# 分类展开只属于当前界面会话，刷新目录和游玩返回时保留，不写入玩家存档。
var _tutorials_expanded: bool = false
var _unfinished_first: bool = false
var _tutorial_entries: Array[Control] = []
var _tutorial_toggle: Button
var _level_entries: Array[Dictionary] = []
var _level_grids: Array[GridContainer] = []
var _search_empty: Label
var _message_dialog: AcceptDialog
var _clear_progress_dialog: ClearProgressDialog
var _about_dialog: AboutGameDialog
var _command_menu: CommandReferenceMenu
var _confirm_assembly_caption: String = "确认装配，开始编程"
var _clear_progress_pending: bool = false
var _pending_clear_level_ids: Array[String] = []
var _clear_user_levels_pending: bool = false
var _pending_clear_user_directory: String = ""
var _pending_clear_drafts_directory: String = ""
var _import_dialog: ConfirmationDialog
var _dialogue_dialog: AcceptDialog
var _dialogue_previous: Button
var _editor_discard_dialog: MapExitDialog
var _editor_exit_save_pending := false
var _save_timer: Timer
var _editor: MapEditor
var _editor_playtest: bool = false
var _dialogue_index: int = 0
var _closing: bool = false
# 回退到初始内容不代表玩家修改了作品。只查看并返回时，必须保留旧草稿原件。
var _draft_needs_recovery: bool = false
var _draft_edited: bool = false
var _recovery_backup_path: String = ""
var _saved_modules: Array = []
var _confirm_assembly_button: Button
var _assembly_status: Label
var _startup_managed := false
var _startup_cancelled := false
var _startup_menu_pending := false
var _startup_menu_revealing := false
var _startup_menu_card: Panel
var _startup_menu_buttons: Array[Button] = []
var _startup_menu_tween: Tween
var _startup_menu_progress := 0.0
var _startup_notice_title := ""
var _startup_notice_body := ""


## 建立游戏入口并加载定义；内置关卡由目录读取，编辑器样例不加入关卡列表。
func _ready() -> void:
	_startup_managed = startup_reporter.is_valid()
	_startup_menu_pending = _startup_managed and not start_in_editor
	get_tree().auto_accept_quit = false
	theme = GameTheme.create_theme()
	if _startup_managed and not await _report_startup_step(1.0 / 6.0):
		return
	var tooltip_layer := GlassTooltipLayer.new()
	tooltip_layer.name = "GlassTooltips"
	add_child(tooltip_layer)
	GameI18n.install()
	settings = GameSettings.new(settings_path)
	var settings_result := settings.load_settings()
	window_controller = GameWindowController.new()
	window_controller.name = "GameWindowController"
	window_controller.settings = settings
	window_controller.availability_changed.connect(_sync_window_resolutions)
	add_child(window_controller)
	drafts = GameDraftStore.new(drafts_directory)
	catalog.user_directory = user_levels_directory
	if _startup_managed and not await _report_startup_step(2.0 / 6.0):
		return
	_build_ui()
	if _startup_managed and not await _report_startup_step(3.0 / 6.0):
		return
	var content := registry.load_directories(
		PackedStringArray(["res://data/modules", "user://data/modules"]),
		PackedStringArray(["res://data/tiles", "user://data/tiles"])
	)
	if _startup_managed and not await _report_startup_step(4.0 / 6.0):
		return
	catalog.refresh(registry)
	if _startup_managed and not await _report_startup_step(5.0 / 6.0):
		return
	if start_in_editor:
		_open_editor()
	else:
		_show_main_page()
	if _startup_managed and not await _report_startup_step(1.0):
		return
	startup_complete = true
	if not content.is_ok():
		_startup_notice_title = "内容加载失败"
		_startup_notice_body = "\n".join(content.errors)
	elif not settings_result.is_ok():
		_startup_notice_title = "设置读取失败"
		_startup_notice_body = "\n".join(settings_result.errors)
	if not _startup_menu_pending:
		_show_startup_notice()


## 只在一个真实初始化阶段结束后报告，并先绘制当前进度再进行下一阶段。
func _report_startup_step(progress: float) -> bool:
	if startup_reporter.is_valid():
		startup_reporter.call(progress)
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw
	if _startup_cancelled:
		# 让初始化协程先返回并释放跨帧局部资源，再由场景树销毁节点。
		queue_free()
		return false
	return is_inside_tree() and not is_queued_for_deletion()


## 启动层被关闭时先取消初始化，让等待中的阶段自行收尾，避免销毁悬挂协程。
func cancel_startup() -> void:
	_startup_cancelled = true
	startup_reporter = Callable()
	if startup_complete:
		if _startup_menu_tween != null and _startup_menu_tween.is_running():
			_startup_menu_tween.kill()
		if not _startup_menu_revealing:
			queue_free()


## 主菜单布局与背景缓存都完成后，启动页才能撤去白色加载遮挡。
func is_startup_presentable() -> bool:
	if not startup_complete or not is_instance_valid(_body) or _body.size.x < 1.0 or _body.size.y < 1.0:
		return false
	if start_in_editor or page != Page.MAIN:
		return true
	if _startup_menu_pending and (not is_instance_valid(_startup_menu_card) or _startup_menu_card.size.x < 1.0 or _startup_menu_card.size.y < 1.0):
		return false
	return is_instance_valid(_main_background) and _main_background.is_render_ready()


## 模糊背景显现后只弹出一次启动卡片；普通返回主菜单不触发此动画。
func reveal_startup_menu() -> void:
	if not _startup_menu_pending or _startup_menu_revealing or not is_instance_valid(_startup_menu_card):
		return
	_startup_menu_revealing = true
	_startup_menu_card.show()
	_apply_startup_menu_transition(0.0)
	_startup_menu_tween = create_tween()
	_startup_menu_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_startup_menu_tween.tween_method(_apply_startup_menu_transition, 0.0, 1.0, 0.28)
	while _startup_menu_tween.is_running():
		await get_tree().process_frame
		if _startup_cancelled:
			queue_free()
			return
	if not is_inside_tree() or not is_instance_valid(_startup_menu_card):
		return
	_apply_startup_menu_transition(1.0)
	_startup_menu_pending = false
	_startup_menu_revealing = false
	_startup_menu_tween = null
	for button in _startup_menu_buttons:
		if is_instance_valid(button):
			button.disabled = false
			button.remove_theme_stylebox_override("disabled")
			button.remove_theme_color_override("font_disabled_color")
			button.focus_mode = Control.FOCUS_ALL
	_startup_menu_buttons.clear()
	_show_startup_notice()


## 每帧按最终卡片尺寸重算中心与位移，窗口缩放时也不留下过期的动画坐标。
func _apply_startup_menu_transition(progress: float) -> void:
	if not is_instance_valid(_startup_menu_card):
		return
	_startup_menu_progress = progress
	var host := _startup_menu_card.get_parent() as Control
	_startup_menu_card.pivot_offset = _startup_menu_card.size * 0.5
	_startup_menu_card.position = (host.size - _startup_menu_card.size) * 0.5 + Vector2(0.0, 12.0 * (1.0 - progress))
	_startup_menu_card.scale = Vector2.ONE * lerpf(0.96, 1.0, progress)
	_startup_menu_card.modulate.a = progress


## 启动期间先保存原有错误反馈，卡片出现后再展示，避免弹窗抢到加载层前方。
func _show_startup_notice() -> void:
	if _startup_notice_title.is_empty():
		return
	_show_message(_startup_notice_title, _startup_notice_body)
	_startup_notice_title = ""
	_startup_notice_body = ""


## 回到窗口时刷新导入目录，切换语言时更新装配原因；关闭前保存当前作品。
func _notification(what: int) -> void:
	if not is_node_ready() or not startup_complete or _startup_menu_pending:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and page == Page.LEVELS:
		_refresh_levels()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and page == Page.ASSEMBLY and _confirm_assembly_button != null:
		_update_preparation()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and page == Page.LEVELS:
		_update_tutorial_section()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _closing or _editor_exit_save_pending or _editor_discard_dialog.visible:
			return
		if _editor != null:
			# 试玩期间编辑器隐藏但仍有未保存地图，关闭窗口也必须经过它的保护。
			if _editor_playtest:
				_return_to_editor()
			_editor._request_action("quit")
		else:
			_leave_game()


## 创建全局页头与页面容器，关卡列表、工作台和旧编辑器共用返回入口。
func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = GameTheme.BACKGROUND
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	_main_background = MainMenuBackground.new()
	_main_background.name = "MainMenuBackground"
	add_child(_main_background)
	_main_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main_background.set_active(false)
	_main_background.set_settings(settings)
	var margin := GameTheme.margin(self, 24)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var layout := VBoxContainer.new()
	margin.add_child(layout)
	_level_header = LevelBrowserHeader.new()
	_level_header.name = "LevelBrowserHeader"
	_level_header.back_requested.connect(_go_back)
	_level_header.refresh_requested.connect(_refresh_levels)
	_level_header.import_requested.connect(_import_levels)
	_level_header.sort_changed.connect(_on_level_sort_changed)
	_level_header.query_changed.connect(_on_level_search_changed)
	layout.add_child(_level_header)
	var header := HBoxContainer.new()
	_header = header
	layout.add_child(header)
	var mark := TextureRect.new()
	_header_mark = mark
	mark.name = "HeaderAppIcon"
	mark.texture = load("res://assets/modules/movement.svg")
	mark.custom_minimum_size = Vector2(42, 42)
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(mark)
	_text_back_button = GameTheme.button(header, "← 开始页面", _go_back)
	_back_button = _text_back_button
	_level_navigation = GameTheme.navigation_pill(header, _go_back, "返回关卡", "Game")
	_level_navigation.hide()
	var headings := VBoxContainer.new()
	headings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 隐藏关卡大标题后，说明文字仍与左右导航按钮垂直居中。
	headings.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_child(headings)
	_title = GameTheme.label(headings, "可编程模块", 28)
	_subtitle = GameTheme.label(headings, "选择关卡，组装机器，编写你的第一段程序。", 14, true)
	_help_button = GameTheme.button(header, "关卡说明", _show_dialogue)
	_refresh_button = GameTheme.button(header, "刷新关卡", _refresh_levels)
	_body = VBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_body)
	_save_label = GameTheme.label(layout, "", 13, true)
	_save_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_message_dialog = AcceptDialog.new()
	add_child(_message_dialog)
	_clear_progress_dialog = ClearProgressDialog.new()
	_clear_progress_dialog.name = "ClearProgressDialog"
	_clear_progress_dialog.confirmed.connect(_confirm_clear_progress)
	_clear_progress_dialog.canceled.connect(_cancel_clear_progress)
	add_child(_clear_progress_dialog)
	_about_dialog = AboutGameDialog.new()
	_about_dialog.name = "AboutGameDialog"
	_about_dialog.link_requested.connect(_open_about_link)
	add_child(_about_dialog)
	_command_menu = CommandReferenceMenu.new()
	_command_menu.name = "CommandReferenceMenu"
	add_child(_command_menu)
	_import_dialog = ConfirmationDialog.new()
	_import_dialog.title = "导入关卡"
	_import_dialog.ok_button_text = "已放入，刷新关卡"
	_import_dialog.cancel_button_text = "取消导入"
	_import_dialog.canceled.connect(_cancel_level_import)
	_import_dialog.close_requested.connect(_cancel_level_import)
	_import_dialog.confirmed.connect(_refresh_levels)
	add_child(_import_dialog)
	_dialogue_dialog = AcceptDialog.new()
	_dialogue_dialog.dialog_hide_on_ok = false
	# 中文长段和无空格的文本也要能折行，不能只依赖按空格分词。
	_dialogue_dialog.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_dialog.confirmed.connect(_next_dialogue)
	add_child(_dialogue_dialog)
	GameTheme.style_guide_dialog(_dialogue_dialog)
	_build_dialogue_navigation()
	_editor_discard_dialog = MapExitDialog.new()
	_editor_discard_dialog.name = "MapExitDialog"
	_editor_discard_dialog.save_requested.connect(_save_editor_and_return)
	_editor_discard_dialog.confirmed.connect(_discard_editor_and_return)
	add_child(_editor_discard_dialog)
	_save_timer = Timer.new()
	_save_timer.wait_time = 0.8
	_save_timer.one_shot = true
	_save_timer.timeout.connect(_save_current_draft)
	add_child(_save_timer)


## 清理旧页面并停止会话，页面切换不能让旧程序继续运行。
func _clear_page(keep_level_header: bool = false) -> void:
	_editor_exit_save_pending = false
	_save_timer.stop()
	if session != null:
		session.stop()
	_editor_playtest = false
	_clear_body(keep_level_header)
	session = null
	_editor = null
	_catalog_status = null
	_import_dialog.hide()
	_dialogue_dialog.hide()
	_message_dialog.hide()
	_editor_discard_dialog.hide()


## 只替换当前游戏组件；试玩期间隐藏的编辑器保留文档、历史和画布状态。
func _clear_body(keep_level_header: bool = false) -> void:
	_main_background.set_active(false)
	# 离开设置即撤销待确认请求，隐藏的弹窗不能在其它页面执行清除。
	_cancel_clear_progress()
	_clear_progress_dialog.close_dialog(false)
	_about_dialog.close_dialog(false)
	_command_menu.close_menu(false)
	if is_instance_valid(workbench) and workbench._actions_menu != null:
		workbench._actions_menu.close_menu(false)
	# 非关卡页面恢复标题；组装与编程入口再隐藏它，避免页面切换遗留可见状态。
	_header.show()
	_title.show()
	_title.add_theme_font_size_override("font_size", 28)
	_subtitle.show()
	_save_label.show()
	_set_level_navigation(false)
	# 目录刷新仅替换列表，不能打断搜索框的动画、输入法组合或光标位置。
	if not keep_level_header:
		_level_header.set_active(false)
	_tutorial_entries.clear()
	_level_entries.clear()
	_level_grids.clear()
	_search_empty = null
	_tutorial_toggle = null
	for child in _body.get_children():
		if _editor_playtest and child == _editor:
			continue
		_body.remove_child(child)
		child.queue_free()
	workbench = null
	assembly_panel = null
	settings_panel = null
	code_color_panel = null
	_confirm_assembly_button = null
	_assembly_status = null


## 关卡与设置页共用药丸导航；提示说明目的地，返回操作仍走原路由。
func _set_level_navigation(enabled: bool, back_tooltip: String = "") -> void:
	_header_mark.visible = not enabled
	_text_back_button.visible = not enabled
	_level_navigation.visible = enabled
	_back_button = _level_navigation.get_node("GameBackButton") if enabled else _text_back_button
	if enabled:
		_back_button.tooltip_text = back_tooltip if not back_tooltip.is_empty() else ("返回地图编辑器" if _editor_playtest else "返回关卡")
		# 与选关页同为外边距 24、药丸宽 88、右侧留白 18，页面切换时不发生位移。
		_header.add_theme_constant_override("separation", 18)
	else:
		_header.remove_theme_constant_override("separation")


## 启动页将小图标与标题并排上移，主要入口与底部系统操作分开布局。
func _show_main_page() -> void:
	_clear_page()
	page = Page.MAIN
	_main_background.set_active(true)
	_header.hide()
	_back_button.hide()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "可编程模块"
	_subtitle.text = "选择关卡，组装机器，编写你的第一段程序。"
	_save_label.text = ""
	_save_label.tooltip_text = ""
	_save_label.hide()
	var host := Control.new()
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(host)
	var panel := Panel.new()
	panel.name = "MainMenuCard"
	var card := GameTheme.card()
	card.set_corner_radius_all(32)
	panel.add_theme_stylebox_override("panel", card)
	host.add_child(panel)
	host.resized.connect(_layout_main_menu.bind(host, panel))
	var brand := HBoxContainer.new()
	brand.name = "MainMenuBrand"
	brand.add_theme_constant_override("separation", 16)
	panel.add_child(brand)
	brand.anchor_left = 0.08
	brand.anchor_right = 0.92
	brand.anchor_top = 0.12
	brand.anchor_bottom = 0.12
	brand.offset_bottom = 104
	var illustration := TextureRect.new()
	illustration.name = "MainMenuIcon"
	illustration.texture = load("res://assets/ui/workshop.svg")
	illustration.custom_minimum_size = Vector2(104, 104)
	illustration.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	illustration.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	brand.add_child(illustration)
	var title := GameTheme.label(brand, "可编程模块", 36)
	title.name = "MainMenuTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var menu := VBoxContainer.new()
	menu.name = "MainMenuActions"
	menu.add_theme_constant_override("separation", 16)
	panel.add_child(menu)
	menu.anchor_left = 0.525
	menu.anchor_right = 0.885
	menu.anchor_top = 0.345
	menu.anchor_bottom = 0.345
	_add_menu_button(menu, "开始游戏", "StartGameButton", _start_game)
	_add_menu_button(menu, "地图编辑器", "MapEditorButton", _open_editor)
	var leave := _add_menu_button(panel, "离开游戏", "LeaveGameButton", _leave_game)
	var preferences := _add_menu_button(panel, "设置", "SettingsButton", _show_settings_page)
	for button in [leave, preferences]:
		button.custom_minimum_size = Vector2(150, 48)
		button.add_theme_font_size_override("font_size", 16)
		button.anchor_top = 1.0
		button.anchor_bottom = 1.0
		button.offset_top = -64
		button.offset_bottom = -16
	leave.offset_left = 16
	leave.offset_right = 166
	preferences.anchor_left = 1.0
	preferences.anchor_right = 1.0
	preferences.offset_left = -166
	preferences.offset_right = -16
	_layout_main_menu(host, panel)
	if _startup_menu_pending:
		_startup_menu_card = panel
		panel.hide()
		_startup_menu_buttons.clear()
		for child in panel.find_children("*", "Button", true, false):
			var button := child as Button
			# 动画期间禁用输入，但保留正常配色，避免主按钮最后一帧才突然变蓝。
			button.add_theme_stylebox_override("disabled", button.get_theme_stylebox("normal"))
			button.add_theme_color_override("font_disabled_color", button.get_theme_color("font_color"))
			button.disabled = true
			button.focus_mode = Control.FOCUS_NONE
			_startup_menu_buttons.append(button)


## 卡片优先采用参考尺寸，在最小窗口中收窄而不把按钮挤出可见区域。
func _layout_main_menu(host: Control, panel: Panel) -> void:
	panel.size = Vector2(minf(1120.0, host.size.x), minf(640.0, host.size.y))
	panel.position = (host.size - panel.size) * 0.5
	if _startup_menu_revealing and panel == _startup_menu_card:
		_apply_startup_menu_transition(_startup_menu_progress)


## 保留入口名称与回调；底角半径 16 加上等距内缩 16，恰好与卡片半径 32 同心。
func _add_menu_button(parent: Node, text: String, node_name: String, action: Callable) -> Button:
	var button := GameTheme.button(parent, text, action)
	button.name = node_name
	button.custom_minimum_size.y = 64
	button.add_theme_font_size_override("font_size", 20)
	if node_name == "StartGameButton":
		GameTheme.primary(button)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.set_corner_radius_all(16)
		button.add_theme_stylebox_override(state, style)
	return button


## 开始游戏时重新读取内容目录，便于玩家在主菜单期间安装新的模块文件。
func _start_game() -> void:
	var content := registry.load_directories(
		PackedStringArray(["res://data/modules", "user://data/modules"]),
		PackedStringArray(["res://data/tiles", "user://data/tiles"])
	)
	catalog.refresh(registry)
	_show_level_page()
	if not content.is_ok():
		_show_message("内容加载失败", "\n".join(content.errors))


## 设置面板立即应用音量与语言；返回按钮始终回到开始页。
func _show_settings_page() -> void:
	_clear_page()
	page = Page.SETTINGS
	_set_level_navigation(true, "返回开始页面")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "设置"
	_title.add_theme_font_size_override("font_size", 22)
	_subtitle.hide()
	_save_label.text = ""
	_save_label.hide()
	settings_panel = SettingsPanel.new()
	settings_panel.settings = settings
	settings_panel.set_available_window_resolutions(window_controller.available_resolutions)
	settings_panel.top_boundary = _level_navigation
	settings_panel.code_colors_requested.connect(_show_code_colors_page)
	settings_panel.about_requested.connect(_show_about_dialog)
	settings_panel.clear_progress_requested.connect(_request_clear_progress)
	settings_panel.clear_user_levels_requested.connect(_request_clear_user_levels)
	settings_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(settings_panel)


## 显示器改变时刷新可选尺寸；其他设置页面不需要读取系统窗口信息。
func _sync_window_resolutions() -> void:
	if is_instance_valid(settings_panel):
		settings_panel.set_available_window_resolutions(window_controller.available_resolutions)


## 关于从设置入口打开并留在当前页面；作者链接只响应用户在弹窗中的操作。
func _show_about_dialog() -> void:
	if page != Page.SETTINGS or settings_panel == null or _clear_progress_dialog.is_open():
		return
	_about_dialog.popup_dialog(settings_panel.find_child("AboutButton", true, false) as Control)


## 仅允许关于页登记的公开地址；失败在原弹窗中反馈，测试不打开真实外部程序。
func _open_about_link(url: String) -> void:
	if page != Page.SETTINGS or not _about_dialog.is_open():
		return
	if url not in [AboutGameDialog.WEBSITE_URL, AboutGameDialog.EMAIL_URL, AboutGameDialog.BILIBILI_URL, AboutGameDialog.YOUTUBE_URL, AboutGameDialog.GITHUB_URL]:
		return
	var result: int = about_link_opener.call(url) if about_link_opener.is_valid() else OS.shell_open(url)
	if result != OK:
		_about_dialog.show_link_error()


## 只从资源目录中的真实关卡定义收集清除范围，用户导入文件不能扩大操作范围。
func _request_clear_progress() -> void:
	if page != Page.SETTINGS or settings_panel == null or _clear_progress_dialog.is_open() or _about_dialog.is_open():
		return
	_cancel_clear_progress()
	for definition in catalog.levels:
		if definition.source_path.begins_with("res://data/levels/") and not definition.id in _pending_clear_level_ids:
			_pending_clear_level_ids.append(definition.id)
	_clear_progress_pending = true
	_clear_progress_dialog.popup_dialog(settings_panel.find_child("ClearProgressButton", true, false) as Control)


## 导入清除使用独立操作类型和目录快照，确认时不能串用另一个弹窗或临时改动的路径。
func _request_clear_user_levels() -> void:
	if page != Page.SETTINGS or settings_panel == null or _clear_progress_dialog.is_open() or _about_dialog.is_open():
		return
	_cancel_clear_progress()
	_clear_progress_pending = true
	_clear_user_levels_pending = true
	_pending_clear_user_directory = catalog.user_directory
	_pending_clear_drafts_directory = drafts.directory
	_clear_progress_dialog.popup_dialog(settings_panel.find_child("ClearUserLevelsButton", true, false) as Control, true)


## 取消只丢弃请求快照，不调用存储层，也不会改变任何通关状态或玩家作品。
func _cancel_clear_progress() -> void:
	_clear_progress_pending = false
	_pending_clear_level_ids.clear()
	_clear_user_levels_pending = false
	_pending_clear_user_directory = ""
	_pending_clear_drafts_directory = ""


## 仅消费一次明确确认；设置页没有运行会话，旧自动保存不会重新写入已清除作品。
func _confirm_clear_progress() -> void:
	if not _clear_progress_pending or page != Page.SETTINGS or settings_panel == null or session != null or _clear_progress_dialog.is_open():
		return
	var level_ids: Array[String] = _pending_clear_level_ids.duplicate()
	var user_levels := _clear_user_levels_pending
	var paths_match := catalog.user_directory == _pending_clear_user_directory and drafts.directory == _pending_clear_drafts_directory
	_cancel_clear_progress()
	var result: DataResult
	if user_levels:
		if paths_match:
			result = catalog.clear_user_levels(drafts)
			# 文件删除失败也可能已有部分完成；重新扫描使列表与真实文件保持一致。
			catalog.refresh(registry)
		else:
			result = DataResult.failure("关卡或草稿目录已变更，请重新打开清除确认。")
		settings_panel.show_user_levels_result(result)
	else:
		result = drafts.clear_level_records(level_ids)
		settings_panel.show_progress_result(result)
	var clear_button := settings_panel.find_child("ClearUserLevelsButton" if user_levels else "ClearProgressButton", true, false) as Button
	if clear_button != null:
		clear_button.grab_focus()
	# 关卡页重新进入时从存储读取完成标记与草稿，排序和筛选沿用现有会话选择。
	if result.is_ok():
		_saved_modules.clear()
		_draft_edited = false
		_draft_needs_recovery = false
		_recovery_backup_path = ""


## 退出按钮与窗口关闭共用保存保护，测试通过替身观察退出请求而不终止测试进程。
func _leave_game() -> void:
	if _closing or not _save_current_draft():
		return
	_closing = true
	if quit_handler.is_valid():
		quit_handler.call()
	else:
		get_tree().quit()


## 根据当前页面选择返回目标；地图未保存确认只在编辑器返回时触发。
func _go_back() -> void:
	if _about_dialog.is_open():
		_about_dialog.close_dialog()
		return
	if _editor_exit_save_pending or _editor_discard_dialog.visible:
		return
	if _editor_playtest:
		_return_to_editor()
	elif page in [Page.ASSEMBLY, Page.PLAY]:
		_back_to_levels()
	elif page == Page.CODE_COLORS:
		_show_settings_page()
	elif page == Page.EDITOR:
		# 返回由外壳统一处理，先提交尚未失焦的字段再判断是否存在未保存修改。
		_editor._canvas.finish_stroke()
		if _editor._time_limit_field.has_focus():
			_editor._commit_time_limit()
		_editor._commit_module_limit()
		_editor._commit_identity()
		if _editor.editor_document.is_dirty():
			_editor._actions_menu.close_menu(false)
			_editor._guide_menu.close_menu(false)
			_editor._enemy_panel._picker.close_menu(false)
			_editor_discard_dialog.open_for_map(_editor.editor_document.document.display_name)
		else:
			_show_main_page()
	else:
		_show_main_page()


## 保存按钮沿用编辑器的校验和文件选择；只有本次写盘成功才返回开始页。
func _save_editor_and_return() -> void:
	if page != Page.EDITOR or not is_instance_valid(_editor) or _editor_exit_save_pending:
		return
	_editor_discard_dialog.hide()
	_editor_exit_save_pending = true
	_editor._save_document(false)


## 不保存是明确的放弃动作，仅在地图编辑页面执行，避免旧弹窗影响其它页面。
func _discard_editor_and_return() -> void:
	if page != Page.EDITOR or _editor_exit_save_pending:
		return
	_show_main_page()


## 失败或取消选择路径会清除退出意图，后续普通保存不能自动离开编辑器。
func _on_editor_save_finished(success: bool) -> void:
	if not _editor_exit_save_pending:
		return
	_editor_exit_save_pending = false
	if success and page == Page.EDITOR and is_instance_valid(_editor) and not _editor.editor_document.is_dirty():
		_show_main_page()


## 刷新只更新列表；坏地图在目录中保留并提供错误，不阻挡其他有效关卡。
func _refresh_levels() -> void:
	if page != Page.LEVELS:
		return
	catalog.refresh(registry)
	_show_level_page()


## 教学和导入关卡分别成组，共用七列网格与纵向滚动；展开不改目录或游戏数据。
func _show_level_page() -> void:
	_clear_page(true)
	page = Page.LEVELS
	_header.hide()
	_level_header.set_active(true)
	_level_header.set_sort_enabled(_unfinished_first)
	_back_button.text = "← 开始页面"
	_back_button.show()
	_help_button.hide()
	_refresh_button.show()
	_title.text = "可编程模块"
	_subtitle.text = "选择关卡，组装机器，编写你的第一段程序。"
	_save_label.hide()
	_save_label.tooltip_text = ""
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 20
	_body.add_child(spacer)
	var scroll := ScrollContainer.new()
	scroll.name = "LevelScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	_body.add_child(scroll)
	var sections := VBoxContainer.new()
	sections.name = "LevelSections"
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_theme_constant_override("separation", 36)
	scroll.add_child(sections)
	_search_empty = GameTheme.label(sections, "没有找到匹配的关卡", 16, true)
	_search_empty.name = "SearchEmptyState"
	_search_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_search_empty.hide()
	var tutorial_section := VBoxContainer.new()
	tutorial_section.name = "TutorialSection"
	tutorial_section.add_theme_constant_override("separation", 16)
	sections.add_child(tutorial_section)
	var tutorial_header := HBoxContainer.new()
	tutorial_section.add_child(tutorial_header)
	var tutorial_title := GameTheme.label(tutorial_header, "教学关卡", 22)
	tutorial_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tutorial_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tutorial_toggle = GameTheme.button(tutorial_header, "", _toggle_tutorials)
	_tutorial_toggle.name = "TutorialToggleButton"
	_tutorial_toggle.flat = true
	_tutorial_toggle.toggle_mode = true
	_tutorial_toggle.add_theme_color_override("font_color", GameTheme.MUTED)
	_tutorial_toggle.add_theme_font_size_override("font_size", 14)
	# 文案包含动态总数，由同一刷新方法处理语言切换，避免翻译格式化后的字符串。
	_tutorial_toggle.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var tutorial_grid := _create_level_grid(tutorial_section, "LevelGrid")
	var imported_section := VBoxContainer.new()
	imported_section.name = "ImportedSection"
	imported_section.add_theme_constant_override("separation", 16)
	sections.add_child(imported_section)
	GameTheme.label(imported_section, "导入关卡", 22)
	var imported_grid := _create_level_grid(imported_section, "ImportedLevelGrid")
	_add_import_card(imported_grid)
	for index in range(catalog.levels.size()):
		var definition: LevelDefinition = catalog.levels[index]
		# 来源路径由目录加载器提供；不能按名称、ID 或排序号猜测是否为教学关卡。
		if definition.source_path.begins_with("res://data/levels/"):
			_tutorial_entries.append(_add_level_card(tutorial_grid, definition, index))
		else:
			_add_level_card(imported_grid, definition, index)
	_apply_level_order()
	_update_tutorial_section()
	_catalog_status = GameTheme.label(_body, "", 14, true)
	_catalog_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not catalog.errors.is_empty():
		_catalog_status.text = tr("%d 项导入问题；其余有效关卡仍可游玩。") % catalog.errors.size()
		GameTheme.button(_body, "查看导入问题", _show_catalog_errors)
	else:
		_catalog_status.hide()


## 两类关卡共用相同列宽和间距，导入一张地图时也与教学第一列对齐。
func _create_level_grid(parent: Node, node_name: String) -> GridContainer:
	var grid := GridContainer.new()
	grid.name = node_name
	grid.columns = LEVEL_COLUMNS
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 24)
	parent.add_child(grid)
	_level_grids.append(grid)
	return grid


## 按可见项补齐首行空列，搜索只剩一关时仍保留与其他分类一致的七列宽度。
func _pad_level_grid(grid: GridContainer) -> void:
	var visible_cards := 0
	for child in grid.get_children():
		if child.has_meta("column_spacer"):
			grid.remove_child(child)
			child.queue_free()
		elif child.visible:
			visible_cards += 1
	for unused in range(maxi(0, LEVEL_COLUMNS - visible_cards)):
		var spacer := Control.new()
		spacer.set_meta("column_spacer", true)
		spacer.custom_minimum_size.x = LEVEL_COLUMN_MIN_WIDTH
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(spacer)


## 展开或收起现有卡片，保留按钮焦点；不重建页面或重新读取玩家草稿。
func _toggle_tutorials() -> void:
	if page != Page.LEVELS or not is_instance_valid(_tutorial_toggle):
		return
	_tutorials_expanded = not _tutorials_expanded
	_update_tutorial_section()


## 搜索按当前显示的本土化名称匹配，临时显示全部命中项，不改玩家的展开偏好。
func _update_tutorial_section() -> void:
	if not is_instance_valid(_tutorial_toggle):
		return
	var query := _level_header.get_query().strip_edges().to_lower()
	var searching := not query.is_empty()
	var matches := 0
	for entry in _level_entries:
		var card: Control = entry.control
		var definition: LevelDefinition = entry.definition
		var tutorial_index := _tutorial_entries.find(card)
		if searching:
			# 与卡片的翻译结果使用同一词典，不把 ID、描述或其他语言别名混入搜索。
			card.visible = tr(definition.display_name).to_lower().contains(query)
		else:
			card.visible = tutorial_index < 0 or _tutorials_expanded or tutorial_index < LEVEL_COLUMNS
		if card.visible:
			matches += 1
	_tutorial_toggle.visible = not searching and _tutorial_entries.size() > LEVEL_COLUMNS
	_tutorial_toggle.set_pressed_no_signal(_tutorials_expanded)
	_tutorial_toggle.text = tr("收起") if _tutorials_expanded else tr("展示更多（%d）") % _tutorial_entries.size()
	_search_empty.visible = searching and matches == 0
	for grid in _level_grids:
		_pad_level_grid(grid)


## 输入变化只筛选已有卡片，保留输入焦点和输入法状态，并把结果滚回首行。
func _on_level_search_changed(_query: String) -> void:
	if page != Page.LEVELS:
		return
	_update_tutorial_section()
	var scroll := _body.find_child("LevelScroll", true, false) as ScrollContainer
	if scroll != null:
		scroll.scroll_vertical = 0


## 未通关优先只改变每个分组的显示顺序；目录、关卡编号和玩家存档保持稳定。
func _apply_level_order() -> void:
	for grid in _level_grids:
		var pending: Array[Control] = []
		var completed: Array[Control] = []
		# _level_entries 保留目录原序，稳定分组即可在关闭排序时精确恢复。
		for entry in _level_entries:
			var card: Control = entry.control
			if card.get_parent() != grid:
				continue
			var definition: LevelDefinition = entry.definition
			if _unfinished_first and drafts.is_completed(definition.id):
				completed.append(card)
			else:
				pending.append(card)
		var ordered: Array[Control] = pending + completed
		var is_tutorial := grid.name == "LevelGrid"
		var offset := 0 if is_tutorial else 1
		for index in range(ordered.size()):
			grid.move_child(ordered[index], index + offset)
		if is_tutorial:
			# 折叠状态展示排序后的前七项，搜索依然可以命中其余教学关卡。
			_tutorial_entries.assign(ordered)


## 菜单开关保留在当前会话，排序后回到列表顶部，不重建搜索框或导入入口。
func _on_level_sort_changed(enabled: bool) -> void:
	if page != Page.LEVELS:
		return
	_unfinished_first = enabled
	_level_header.set_sort_enabled(enabled)
	_apply_level_order()
	_on_level_search_changed(_level_header.get_query())


## 圆角方形卡片呈现关卡入口，完成标记仍从独立草稿存储读取。
func _add_level_card(parent: Node, definition: LevelDefinition, index: int) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = LEVEL_COLUMN_MIN_WIDTH
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(column)
	_level_entries.append({"control": column, "definition": definition})
	var button := GameTheme.button(column, "", _enter_level.bind(definition))
	button.name = "LevelButton_%d" % index
	button.icon = LevelThumbnail.create_texture(definition, registry)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", LEVEL_THUMBNAIL_SIZE)
	button.custom_minimum_size = Vector2.ONE * LEVEL_CARD_SIZE
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_color_override("font_color", GameTheme.ACCENT)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, _level_icon_surface(state))
	var title := GameTheme.label(column, definition.display_name, 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = LEVEL_COLUMN_MIN_WIDTH
	var completed_text := "✓ 已完成" if drafts.is_completed(definition.id) else "移动与近战 · 摧毁障碍" if definition.goal_type == "destroy_object" else "移动模块 · 编程与组装"
	if not drafts.is_completed(definition.id) and definition.goal_type == "destroy_enemy":
		completed_text = "射击模块 · 持续射击"
	if not drafts.is_completed(definition.id) and definition.goal_type == "escape_prison":
		completed_text = "命名模块 · 越狱行动"
	if not drafts.is_completed(definition.id) and definition.allow_loops:
		completed_text = "循环编程 · 十组阶梯"
	if not drafts.is_completed(definition.id) and definition.allow_conditionals:
		completed_text = "条件判断 · 射击与躲避"
	if not drafts.is_completed(definition.id) and definition.allow_simultaneous:
		completed_text = "同时执行 · 左右为“铃”"
	if not drafts.is_completed(definition.id) and definition.allow_distance:
		completed_text = "测距模块 · 蛇形寻路"
	if not drafts.is_completed(definition.id) and definition.allow_radar and definition.goal_type == "destroy_enemy":
		completed_text = "雷达追击 · 制导射击"
	if not drafts.is_completed(definition.id) and definition.allow_functions:
		completed_text = "自定义函数 · 巧能躲避"
	if not drafts.is_completed(definition.id) and definition.goal_type == "destroy_waves":
		completed_text = ("雷达锁定 · 十面埋伏" if definition.id == "level_013" else "for 循环 · 八方警戒")
		if definition.id == "level_014":
			completed_text = "移动扫描 · 隔栏射击"
		if definition.id == "level_015":
			completed_text = "雷达事件 · 自动索敌"
	var caption := GameTheme.label(column, completed_text, 12, true)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 长名称和英文说明只能增加行高，不能撑开列宽产生横向溢出。
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.tooltip_text = tr(definition.display_name) + "\n" + tr(definition.description)
	return column


## 导入只需要加号按钮，具体文件放置说明在点击后出现。
func _add_import_card(parent: Node) -> void:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = LEVEL_COLUMN_MIN_WIDTH
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	parent.add_child(column)
	var button := GameTheme.button(column, "+", _import_levels)
	button.name = "ImportLevelButton"
	button.custom_minimum_size = Vector2.ONE * LEVEL_CARD_SIZE
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 44)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, _level_icon_surface(state))
	var title := GameTheme.label(column, "导入关卡", 14)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var caption := GameTheme.label(column, "添加地图 JSON", 12, true)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 缩略图外圈与图内白底一致，以向下的柔和阴影和悬停层次呈现可点击状态。
func _level_icon_surface(state: String) -> StyleBoxFlat:
	if state == "focus":
		return _level_icon_box(Color.TRANSPARENT, GameTheme.ACCENT)
	var style := _level_icon_box(LevelThumbnail.BACKGROUND)
	var pressed := state in ["pressed", "hover_pressed"]
	var hovered := state == "hover"
	style.shadow_color = Color(0.1, 0.16, 0.28, 0.14 if hovered else 0.07 if pressed else 0.10)
	style.shadow_size = 8 if hovered else 2 if pressed else 6
	style.shadow_offset = Vector2(0, 5 if hovered else 1 if pressed else 4)
	return style


## 七列入口使用更小的方形命中区与更饱满的圆角，固定内边距保证 SVG 清晰留白。
func _level_icon_box(color: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var style := GameTheme.box(color, border, LEVEL_CARD_RADIUS)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


## 创建可写目录，先显示放置说明再打开文件夹；测试可注入无系统副作用的打开函数。
func _import_levels() -> void:
	var prepared := catalog.ensure_import_directory()
	if not prepared.is_ok():
		_show_message("无法打开关卡文件夹", "\n".join(prepared.errors))
		return
	var path: String = prepared.value
	_import_dialog.dialog_text = tr("请把要导入的关卡 .json 文件拖入刚打开的 levels 文件夹。\n\n放入后返回游戏，关卡会自动刷新；也可以点击下方按钮刷新。\n地图引用的新模块或地块需要先安装对应内容。\n\n关卡文件夹：\n") + path
	_import_dialog.popup_centered(Vector2i(760, 330))
	var error: int = folder_opener.call(path) if folder_opener.is_valid() else OS.shell_open(path)
	if error != OK:
		_import_dialog.dialog_text += "\n\n" + tr("未能自动打开文件夹，请按上面的路径手动打开：") + error_string(error)


## 取消仅关闭提示，按钮、Esc 和窗口关闭请求都不触发确认或目录刷新。
func _cancel_level_import() -> void:
	_import_dialog.hide()


## 将目录扫描错误呈现给玩家，包括路径和出错字段以方便修正导入文件。
func _show_catalog_errors() -> void:
	_show_message("关卡导入问题", "\n\n".join(catalog.errors.slice(0, 20)))


## 每次进入关卡先显示空组装台；程序自动恢复，历史装配需由玩家主动选择载入。
func _enter_level(definition: LevelDefinition) -> void:
	_clear_page()
	session = GameSession.create(definition, registry)
	var draft_warning := _load_current_draft()
	session.completed.connect(_on_level_completed)
	if definition.source_path == "res://data/levels/%s.json" % definition.id:
		session.consecutive_failures = drafts.get_failure_streak(definition.id)
		session.attempt_failed.connect(_on_attempt_failed)
	_show_assembly_page()
	# Godot 同一窗口只能拥有一个独占弹窗；恢复提示优先，关卡说明仍可从页头查看。
	if draft_warning.is_empty():
		_show_dialogue()
	else:
		_show_message("草稿提示", draft_warning + "\n\n" + tr("可点击右上角「关于说明」重新查看关卡对话。"))


## 独立组装阶段占满页面，所有模块在左侧，确认合法占地后才能进入编程工作台。
func _show_assembly_page(returning_from_code: bool = false) -> void:
	page = Page.ASSEMBLY
	_header.hide()
	_help_button.hide()
	_refresh_button.hide()
	_save_label.hide()
	assembly_panel = AssemblyPanel.new()
	assembly_panel.preparation_mode = true
	assembly_panel.settings = settings
	assembly_panel.model = session.assembly
	assembly_panel.registry = session.assembly.content
	assembly_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	assembly_panel.draft_changed.connect(_on_preparation_changed)
	_body.add_child(assembly_panel)
	var toolbar := assembly_panel.header
	toolbar.configure(returning_from_code, _editor_playtest)
	toolbar.back_requested.connect(_go_back)
	toolbar.confirm_requested.connect(_confirm_assembly)
	toolbar.save_requested.connect(_save_assembly_draft)
	toolbar.restore_requested.connect(_restore_saved_assembly)
	toolbar.help_requested.connect(_show_dialogue)
	toolbar.commands_requested.connect(_show_command_reference)
	_back_button = toolbar.back_button
	_confirm_assembly_button = toolbar.confirm_button
	_confirm_assembly_caption = "确认装配，返回编程" if returning_from_code else "确认装配，开始编程"
	toolbar.restore_button.disabled = _saved_modules.is_empty()
	_assembly_status = assembly_panel.preparation_status
	_update_preparation()


## 工具栏保存沿用既有草稿与恢复保护，仅把操作反馈放在右侧工作区下方。
func _save_assembly_draft() -> void:
	if page != Page.ASSEMBLY or _editor_playtest:
		return
	if _save_current_draft(true):
		_assembly_status.text = _save_label.text
		_assembly_status.show()


## 指令说明只读当前能力及资料目录，不提交程序或修改已安装模块。
func _show_command_reference() -> void:
	if session == null:
		return
	if page == Page.ASSEMBLY and is_instance_valid(assembly_panel):
		_command_menu.popup_at(assembly_panel.header.book_button, session.level, session.assembly.content)
	elif page == Page.PLAY and is_instance_valid(workbench):
		workbench._guide_menu.close_menu(false)
		workbench._actions_menu.close_menu(false)
		_command_menu.popup_at(workbench.header.book_button, session.level, session.assembly.content, "返回编程")


## 编程页返回时保留同一会话；不能调用进入关卡流程，否则会重置模块并重读旧草稿。
func _return_to_assembly() -> void:
	if page != Page.PLAY or session == null:
		return
	# 模块改变会影响模拟世界，因此运行中或暂停中返回都先取消当前试运行。
	# 源程序与装配属于会话草稿，stop() 和更换页面都不清空它们。
	session.stop()
	_clear_body()
	_show_assembly_page(true)


## 组装事件同时更新确认按钮和自动保存，不让界面自行绕过装配模型的上限。
func _on_preparation_changed() -> void:
	_update_preparation()
	_schedule_save()


## 每次编辑后检查完整装配，缺中心、断连和出生占地无效都即时阻止确认。
func _update_preparation() -> void:
	_show_preparation_result(session.assembly.build_document())


## 禁用按钮仍保留原生悬停提示，状态区同时显示原因，方便键盘操作与修复草稿。
func _show_preparation_result(result: DataResult) -> void:
	_confirm_assembly_button.disabled = not result.is_ok()
	var reason := "" if result.is_ok() else GameI18n.translate_errors(result.errors)
	_confirm_assembly_button.tooltip_text = tr(_confirm_assembly_caption) + ("" if reason.is_empty() else "\n" + reason)
	_assembly_status.text = reason
	# 空状态也占一行，避免首次有效放置后画布因布局重排而跳离鼠标落点。
	_assembly_status.show()


## 恢复是玩家主动操作，复制草稿后仍通过同一装配面板继续检查和调整。
func _restore_saved_assembly() -> void:
	if page != Page.ASSEMBLY or _saved_modules.is_empty():
		return
	session.assembly.modules = _saved_modules.duplicate(true)
	session.assembly.changed.emit()


## 确认只负责校验和切换界面，世界在稍后点击运行时才会真正创建。
func _confirm_assembly() -> void:
	if page != Page.ASSEMBLY:
		return
	var prepared := session.assembly.build_document()
	if not prepared.is_ok():
		# 直接调用确认入口也重新验证，不能仅依赖按钮的禁用状态。
		_show_preparation_result(prepared)
		return
	if not _save_current_draft():
		return
	_clear_body()
	page = Page.PLAY
	_header.hide()
	_help_button.hide()
	_title.hide()
	workbench = GameWorkbench.new()
	workbench.session = session
	workbench.settings = settings
	workbench.registry = session.assembly.content
	workbench.allow_draft_save = not _editor_playtest
	workbench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workbench.draft_changed.connect(_schedule_save)
	workbench.save_requested.connect(_save_current_draft.bind(true))
	workbench.edit_modules_requested.connect(_return_to_assembly)
	workbench.back_requested.connect(_go_back)
	workbench.help_requested.connect(_show_dialogue)
	workbench.commands_requested.connect(_show_command_reference)
	workbench.actions_requested.connect(_command_menu.close_menu.bind(false))
	_body.add_child(workbench)
	_back_button = workbench.header.back_button
	_subtitle.text = session.level.description
	_save_label.text = "试玩结束后可返回地图编辑器继续修改。" if _editor_playtest else "程序与装配会自动保存；运行不会修改关卡地图。"
	_save_label.hide()


## 自动恢复源程序，缓存可继续编辑的历史装配；布局只有玩家主动载入才安装。
func _load_current_draft() -> String:
	_draft_needs_recovery = false
	_draft_edited = false
	_recovery_backup_path = ""
	_saved_modules = []
	var loaded := drafts.load_draft(session.level.id)
	if not loaded.is_ok():
		_draft_needs_recovery = true
		return tr("草稿无法恢复，暂时使用关卡初始程序与空装配。原文件保持不变；编辑或手动保存时会先保留恢复备份。") + "\n" + "\n".join(loaded.errors)
	if loaded.value == null:
		return ""
	var data: Dictionary = loaded.value
	session.source = data.source
	var candidate := AssemblyModel.create(session.level, registry)
	candidate.modules = data.modules.duplicate(true)
	if not candidate.modules.is_empty():
		# 缺中心或断连是可保存的编辑过程；载入后仍由确认入口要求完整装配。
		var valid := candidate.validate_editing()
		if not valid.is_ok():
			_draft_needs_recovery = true
			return tr("草稿中的装配与当前关卡不兼容，请重新组装。原文件保持不变；编辑或手动保存时会先保留恢复备份。") + "\n" + "\n".join(valid.errors)
	_saved_modules = candidate.modules.duplicate(true)
	return ""


## 对连续键入做短暂合并，避免每输入一个字符就反复写文件。
func _schedule_save() -> void:
	if _editor_playtest:
		# 编辑器试玩只存在于当前会话；不按地图 ID 访问正式玩家作品。
		return
	_draft_edited = true
	_save_label.text = "正在编辑，稍后自动保存……"
	_save_timer.start()


## 只有存储成功才反馈已保存；离开页面或退出时调用方据返回值决定是否继续。
func _save_current_draft(force: bool = false) -> bool:
	_save_timer.stop()
	if session == null or _editor_playtest:
		return true
	# 进入关卡时故意显示空装配；尚未编辑就离开时，也不能清空原有的合法历史作品。
	if not _draft_edited and not force:
		return true
	# 返回、退出和计时保存不应将读取失败后的默认内容写回原文件。
	# 手动保存明确提交当前内容，但也要先保留原始字节，便于以后恢复旧作品。
	if _draft_needs_recovery:
		if not _draft_edited and not force:
			return true
		if _recovery_backup_path.is_empty():
			var backup := drafts.backup_draft(session.level.id)
			if not backup.is_ok():
				_save_label.text = "无法备份旧草稿，尚未覆盖原文件。"
				_show_message("无法备份旧草稿", "\n".join(backup.errors))
				return false
			if backup.value != null:
				_recovery_backup_path = backup.value
	var saved := drafts.save_draft(session.level.id, session.source, session.assembly.modules)
	if not saved.is_ok():
		_save_label.text = "草稿保存失败，当前内容仍保留在编辑器中。"
		_show_message("无法保存草稿", "\n".join(saved.errors))
		return false
	_draft_needs_recovery = false
	_draft_edited = false
	_save_label.text = tr("✓ 程序与装配草稿已保存")
	if not _recovery_backup_path.is_empty():
		_save_label.text += tr("；旧草稿备份：") + _recovery_backup_path
	_save_label.tooltip_text = _save_label.text
	# 编程页通常把空间留给卡片；主动保存或产生恢复备份时仍显示实际结果。
	if page == Page.PLAY:
		_save_label.visible = force or not _recovery_backup_path.is_empty()
	return true


## 仅教学关卡保存连续失败次数，导入关卡与编辑器试玩不参与提示记录。
func _on_attempt_failed() -> void:
	if _editor_playtest or session == null or session.level.source_path != "res://data/levels/%s.json" % session.level.id:
		return
	var saved := drafts.save_failure_streak(session.level.id, session.consecutive_failures)
	if not saved.is_ok():
		_save_label.text = tr("提示记录保存失败") + "：" + GameI18n.translate_errors(saved.errors)
		_save_label.show()


## 通关只写独立进度标记，并保留玩家刚刚成功的程序与装配。
func _on_level_completed() -> void:
	if _editor_playtest:
		return
	_save_current_draft(true)
	var marked := drafts.mark_completed(session.level.id)
	if not marked.is_ok():
		_show_message("通关记录保存失败", "你已完成关卡，但进度未能写入磁盘。\n" + "\n".join(marked.errors))


## 返回前保存游戏草稿；地图编辑器的未保存更改则走单独确认流程。
func _back_to_levels() -> void:
	if not _save_current_draft():
		return
	_clear_page()
	catalog.refresh(registry)
	_show_level_page()


## 地图编辑器只负责编辑并发出试玩请求，页面切换和游戏会话由外层承接。
func _open_editor() -> void:
	_clear_page()
	_editor = MapEditor.new()
	_editor.settings = settings
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.back_requested.connect(_go_back)
	_editor.playtest_requested.connect(_start_editor_playtest)
	_editor.save_finished.connect(_on_editor_save_finished)
	_body.add_child(_editor)
	_show_editor_header()


## 新建或恢复编辑器时使用同一页头，恢复不重新加载地图或重建编辑控件。
func _show_editor_header() -> void:
	page = Page.EDITOR
	_header.hide()
	_back_button = _editor._header.back_button
	_save_label.hide()
	_save_label.tooltip_text = ""


## 用当前编辑快照进入与正式关卡相同的空装配流程，内容目录以编辑器为准。
func _start_editor_playtest(definition: LevelDefinition, content: ContentRegistry) -> void:
	if page != Page.EDITOR or _editor == null or _editor_playtest:
		return
	_save_timer.stop()
	_editor_playtest = true
	# 保留整个编辑器节点，让路径、未保存标记、撤销重做和视图位置原样返回。
	_editor.hide()
	_editor.process_mode = Node.PROCESS_MODE_DISABLED
	_saved_modules = []
	_draft_needs_recovery = false
	_draft_edited = false
	_recovery_backup_path = ""
	session = GameSession.create(definition, content)
	# 使用相同完成回调的隔离分支，既显示通关结果又不写正式关卡进度。
	session.completed.connect(_on_level_completed)

	_show_assembly_page()
	_show_dialogue()


## 从组装或编程返回原编辑器，停止试运行并丢弃本次测试会话，地图保持原样。
func _return_to_editor() -> void:
	if not _editor_playtest or _editor == null:
		return
	_save_timer.stop()
	if session != null:
		session.stop()
	_clear_body()
	session = null
	_editor_playtest = false
	_dialogue_dialog.hide()
	_message_dialog.hide()
	_editor.process_mode = Node.PROCESS_MODE_INHERIT
	_editor.show()
	_show_editor_header()


## 保留引擎确认按钮和信号，只将默认居中排布改为左侧上一页、右侧下一页。
func _build_dialogue_navigation() -> void:
	_dialogue_previous = _dialogue_dialog.add_button("上一页", false)
	_dialogue_previous.name = "PreviousGuidePageButton"
	_dialogue_previous.pressed.connect(_previous_dialogue)
	var next := _dialogue_dialog.get_ok_button()
	next.name = "NextGuidePageButton"
	_dialogue_dialog.add_theme_constant_override("buttons_min_width", 112)
	# AcceptDialog 自动插入弹性占位；仅保留两按钮之间的占位，不删除引擎内部节点。
	var row := next.get_parent() as HBoxContainer
	for child: Control in row.get_children():
		if child is Button:
			continue
		# 引擎会在弹窗显示时恢复占位可见性，因此调整伸缩而非隐藏，翻页后也保持两端对齐。
		var between := child.get_index() > _dialogue_previous.get_index() and child.get_index() < next.get_index()
		child.size_flags_horizontal = Control.SIZE_EXPAND_FILL if between else Control.SIZE_SHRINK_BEGIN
	GameTheme.primary(next)


## 进入关卡时从第一页显示引导，玩家也可从页头重新打开查看。
func _show_dialogue() -> void:
	if is_instance_valid(workbench) and workbench._actions_menu != null:
		workbench._actions_menu.close_menu(false)
	if _command_menu != null:
		_command_menu.close_menu(false)
	if session == null:
		return
	_dialogue_index = 0
	_display_dialogue_line()


## 显示当前页及页码；第一页禁用返回，最后一页仍可回看，确认才结束引导。
func _display_dialogue_line() -> void:
	if session == null:
		_dialogue_dialog.hide()
		return
	var lines: Array = session.level.document.dialogue
	if lines.is_empty() or _dialogue_index >= lines.size():
		_dialogue_dialog.hide()
		return
	var line: Dictionary = lines[_dialogue_index]
	_dialogue_dialog.title = "%s · %d / %d" % [tr(str(line.get("speaker", "关卡说明"))), _dialogue_index + 1, lines.size()]
	_dialogue_dialog.dialog_text = str(line.text)
	_dialogue_dialog.ok_button_text = "开始编辑" if _dialogue_index == lines.size() - 1 else "下一页"
	_dialogue_previous.disabled = _dialogue_index == 0
	_dialogue_dialog.popup_centered(Vector2i(650, 240))
	if _dialogue_previous.disabled and _dialogue_previous.has_focus():
		_dialogue_dialog.get_ok_button().grab_focus()


## 回看上一页，不结束引导，也不改动玩家装配或程序。
func _previous_dialogue() -> void:
	if session == null or not _dialogue_dialog.visible or _dialogue_index <= 0:
		return
	_dialogue_index -= 1
	_display_dialogue_line()


## 继续到下一页引导，末页确认后回到原组装或编程页面。
func _next_dialogue() -> void:
	if session == null or not _dialogue_dialog.visible:
		return
	_dialogue_index += 1
	_display_dialogue_line()


## 统一展示文件或内容问题，不让失败只存在于开发者控制台中。
func _show_message(title_text: String, body: String) -> void:
	_message_dialog.title = title_text
	_message_dialog.dialog_text = body
	_message_dialog.popup_centered(Vector2i(720, 310))


## 颜色与显示属于设置子页，沿用返回药丸；只切换页面，不影响玩家作品。
func _show_code_colors_page() -> void:
	_clear_page()
	page = Page.CODE_COLORS
	_set_level_navigation(true, "返回设置")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "设置"
	_title.add_theme_font_size_override("font_size", 22)
	_subtitle.hide()
	_save_label.hide()
	code_color_panel = CodeColorPanel.new()
	code_color_panel.settings = settings
	code_color_panel.top_boundary = _level_navigation
	code_color_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(code_color_panel)
