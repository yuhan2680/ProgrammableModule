class_name GameShell
extends Control
## 游戏入口负责页面切换、关卡目录、草稿与系统文件夹交互，不参与世界模拟。

enum Page { MAIN, LEVELS, ASSEMBLY, PLAY, EDITOR, SETTINGS, CODE_COLORS, PLAYER_LEVEL_LIST, PLAYER_PROFILE }

# 选关页固定七列；缩小图标并独立保留文字字号，导入项沿用相同卡片尺寸。
const LEVEL_COLUMNS := 7
const LEVEL_CARD_SIZE := 104.0
const LEVEL_THUMBNAIL_SIZE := 88
const LEVEL_COLUMN_MIN_WIDTH := 104.0
const LEVEL_CARD_RADIUS := 34
const LEVEL_SCROLLBAR_WIDTH := 12
const MAIN_MENU_CARD_SIZE := Vector2(1120, 640)
const ACTIVITY_SAVE_INTERVAL := 30.0

# 单独运行地图编辑器场景时仍复用相同页面路由，不再维护另一套试玩界面。
@export var start_in_editor: bool = false

# 这些依赖可以在测试中替换，避免测试打开资源管理器或写入玩家的真实草稿。
var user_levels_directory: String = ""
var player_save_location: PlayerSaveLocation
var player_saves_source := "user://levels"
var player_saves_journal := "user://player_saves_migration.json"
var legacy_upgrade: PlayerLegacyUpgrade
var legacy_upgrade_native_dialog_handler: Callable
var drafts_directory: String = "user://solutions"
var runtime_storage_migration: PlayerRuntimeMigration
var settings_path: String = "user://settings.json"
var profile_path: String = ""
# 档案与计时边界可独立注入，回归不读取真实玩家信息或等待实际时间。
var profile_clock: Callable
var profile_native_dialog_handler: Callable
# 清除进度询问可独立注入，测试不会唤起真实系统弹窗。
var clear_progress_native_dialog_handler: Callable
var folder_opener: Callable
# 关于链接由系统打开；测试可注入替身而不启动真实浏览器或邮件程序。
var about_link_opener: Callable
var guide_link_opener: Callable
# 自动化界面验证可替换试听入口，不调用系统程序或播放真实声音。
var system_sound_preview_handler: Callable
var quit_handler: Callable
# 仅由轻量启动场景注入；直接运行游戏或编辑器场景仍在 _ready 中同步初始化。
var startup_reporter: Callable
var startup_complete := false
var registry := ContentRegistry.new()
var catalog := LevelCatalog.new()
var player_level_library := PlayerLevelLibrary.new()
var drafts: GameDraftStore
var session: GameSession
var workbench: GameWorkbench
var settings: GameSettings
var profile: PlayerProfileStore
var _profile_tracker: PlayerAttemptTracker
var _profile_hint_mode := "none"
var _activity_tracker: PlayerActivityTracker
var _activity_save_elapsed := 0.0
var _application_active := true
var _application_suspended := false
var _profile_reset_pending := false
var _profile_reset_uid := ""
var _profile_reset_dialog: PlayerProfileResetDialog
var window_controller: GameWindowController
var page: Page = Page.MAIN:
	set(value):
		if page == value:
			return
		page = value
		_sync_activity_timer()
var assembly_panel: AssemblyPanel
var settings_panel: SettingsPanel
var code_color_panel: CodeColorPanel
var player_level_list_panel: PlayerLevelListPanel
var player_profile_panel: PlayerProfilePanel
var shark_game: SharkCaveGame

var _shark_layer: CanvasLayer
var _shark_best_score := 0
var _shark_discovered := false
var _shark_settings_scroll := 0
var _shark_entry_generation := 0
var _shark_entry_pending := false
var _shark_entry_tween: Tween

var _level_header: LevelBrowserHeader
var _player_level_context_menu: PlayerLevelContextMenu
var _main_background: MainMenuBackground
var _page_margin: MarginContainer
var _page_host: Control
var _page_layout: VBoxContainer
var _menu_host: Control
var _menu_card: Panel
var _menu_transition: Tween
var _menu_transitioning := false
var _menu_transition_generation := 0
var _menu_page_transition: MainMenuPageTransition
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
# 分类展开只属于当前界面会话，刷新目录和游玩返回时保留，不写入玩家存档。
var _tutorials_expanded: bool = false
var _players_expanded: bool = false
var _unfinished_first: bool = false
var _tutorial_entries: Array[Control] = []
var _tutorial_toggle: Button
var _player_entries: Array[Control] = []
var _player_toggle: Button
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
var _pending_clear_drafts_directory: String = ""
var _pending_clear_progress_directory: String = ""
var _import_dialog: FileDialog
var _level_import_pending := false
var _rename_input: LineEdit
var _rename_title: Label
var _rename_card_button: Button
var _rename_target: LevelDefinition
var _dialogue_dialog: AcceptDialog
var _dialogue_previous: Button
var _dialogue_markdown: RichTextLabel
var _dialogue_pages: Array = []
var _dialogue_system_index := -1
var _program_editor_view: Dictionary = {}
var _editor_discard_dialog: MapExitDialog
var _editor_exit_save_pending := false
var _editor_exit_quit_requested := false
var _editor_returns_to_player_list := false
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
var _legacy_upgrade_state: Dictionary = {}
var _legacy_upgrade_errors := PackedStringArray()
var _legacy_upgrade_dialog: PlayerLegacyUpgradeDialog
var _player_storage_ready := false
var _uses_external_runtime_storage := false
var _runtime_storage_ready := false
var _runtime_storage_errors := PackedStringArray()
var _player_storage_errors := PackedStringArray()
var _player_storage_continuation: Callable
var _player_storage_dialog: FileDialog
var _player_storage_problem: ConfirmationDialog
var _player_storage_selecting := false
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
	# 正式入口共享 saves 的平台根；显式依赖注入继续使用原有隔离目录。
	_uses_external_runtime_storage = runtime_storage_migration != null or (settings_path == "user://settings.json" and drafts_directory == "user://solutions" and profile_path.is_empty() and user_levels_directory.is_empty())
	if not user_levels_directory.is_empty():
		_player_storage_ready = true
	elif player_save_location == null and settings_path != "user://settings.json":
		user_levels_directory = settings_path.get_base_dir().path_join("levels")
		_player_storage_ready = true
	else:
		_prepare_player_storage()
	var profile_result: DataResult
	if _uses_external_runtime_storage:
		# 迁移或授权失败时占位模型不可写，绝不生成新的 UID 覆盖待恢复档案。
		profile = PlayerProfileStore.new("")
		drafts = GameDraftStore.new("")
		profile_result = _prepare_runtime_storage()
	else:
		var storage_path := profile_path
		if storage_path.is_empty():
			storage_path = "user://player_profile.json" if settings_path == "user://settings.json" else settings_path.get_basename() + ".player_profile.json"
		profile = PlayerProfileStore.new(storage_path)
		profile_result = profile.load_profile()
		drafts = GameDraftStore.new(drafts_directory)
		_runtime_storage_ready = true
	settings.changed.connect(_remember_profile_hint_mode)
	_profile_tracker = PlayerAttemptTracker.new(profile_clock)
	_activity_tracker = PlayerActivityTracker.new(profile_clock)
	_shark_best_score = int(profile.get_statistics().shark_best_score)
	_shark_discovered = bool(profile.get_statistics().get("shark_discovered", _shark_best_score > 0))
	window_controller = GameWindowController.new()
	window_controller.name = "GameWindowController"
	window_controller.settings = settings
	window_controller.availability_changed.connect(_sync_window_resolutions)
	add_child(window_controller)
	catalog.user_directory = user_levels_directory if _player_storage_ready else ""
	_prepare_legacy_upgrade()
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
	if start_in_editor and _player_storage_ready:
		_open_editor()
	else:
		_show_main_page()
	if _startup_managed and not await _report_startup_step(1.0):
		return
	startup_complete = true
	_sync_activity_timer()
	if not content.is_ok():
		_startup_notice_title = "内容加载失败"
		_startup_notice_body = "\n".join(content.errors)
	elif not settings_result.is_ok():
		_startup_notice_title = "设置读取失败"
		_startup_notice_body = "\n".join(settings_result.errors)
	elif not profile_result.is_ok() and not _uses_external_runtime_storage:
		_startup_notice_title = "玩家档案读取失败"
		_startup_notice_body = "\n".join(profile_result.errors)
	if not _startup_menu_pending:
		_show_startup_notice()


## 正式入口只准备可见保存目录，不自动搬动旧地图，也不回退到隐藏目录写入。
func _prepare_player_storage() -> void:
	_player_storage_ready = false
	if player_save_location == null:
		player_save_location = PlayerSaveLocation.new()
	var resolved := player_save_location.resolve()
	_player_storage_errors = resolved.errors.duplicate()
	if not resolved.is_ok():
		return
	user_levels_directory = str(resolved.value)
	var prepared := PlayerLevelPaths.open_directory(user_levels_directory, true, true)
	_player_storage_errors = prepared.errors.duplicate()
	_player_storage_ready = prepared.is_ok()


## 缓存和进度先迁移后载入；失败保留原件和不可写状态，重试不会重复导入旧数据。
func _prepare_runtime_storage() -> DataResult:
	if not _uses_external_runtime_storage or _runtime_storage_ready:
		return DataResult.success()
	if not _player_storage_ready:
		_runtime_storage_errors = _player_storage_errors.duplicate()
		return DataResult.failure("\n".join(_runtime_storage_errors))
	var paths := PlayerRuntimePaths.configure_from_saves(user_levels_directory, runtime_storage_migration != null)
	if not paths.is_ok():
		_runtime_storage_errors = paths.errors.duplicate()
		return paths
	var cache_path: String = paths.value.cache_directory
	var progress_path: String = paths.value.progress_directory
	if runtime_storage_migration == null:
		runtime_storage_migration = PlayerRuntimeMigration.new(cache_path, progress_path)
	elif runtime_storage_migration.cache_directory != cache_path or runtime_storage_migration.progress_directory != progress_path:
		_runtime_storage_errors = PackedStringArray(["运行数据保存位置已改变，请恢复原目录后重试。"])
		return DataResult.failure("\n".join(_runtime_storage_errors))
	var migrated := runtime_storage_migration.migrate()
	if not migrated.is_ok():
		_runtime_storage_errors = migrated.errors.duplicate()
		return migrated
	var loaded_profile := PlayerProfileStore.new(paths.value.profile_path)
	var loaded := loaded_profile.load_profile()
	if not loaded.is_ok():
		_runtime_storage_errors = loaded.errors.duplicate()
		return loaded
	profile = loaded_profile
	drafts = GameDraftStore.new(cache_path, progress_path)
	_runtime_storage_errors.clear()
	_runtime_storage_ready = true
	_shark_best_score = int(profile.get_statistics().shark_best_score)
	_shark_discovered = bool(profile.get_statistics().get("shark_discovered", _shark_best_score > 0))
	return DataResult.success()


## 正式游玩和统计修改必须等待保存目录可用；菜单与设置仍可浏览并从原入口重试。
func _ensure_runtime_storage(continuation: Callable) -> bool:
	if _runtime_storage_ready:
		return true
	_player_storage_continuation = continuation
	_request_player_storage()
	return false


## 保存相关入口可重试失败的授权或迁移，菜单始终可以继续浏览。
func _ensure_player_storage(continuation: Callable) -> bool:
	if _player_storage_ready:
		return true
	_player_storage_continuation = continuation
	_request_player_storage()
	return false


## macOS 沙盒首次使用原生选择器授予文稿目录访问；恢复失败时沿用相同重试入口。
func _request_player_storage() -> void:
	if _closing or _player_storage_selecting or (is_instance_valid(_player_storage_problem) and _player_storage_problem.visible):
		return
	if player_save_location != null and player_save_location.needs_authorization:
		if not is_instance_valid(_player_storage_dialog):
			_player_storage_dialog = FileDialog.new()
			_player_storage_dialog.name = "PlayerSaveFolderDialog"
			_player_storage_dialog.access = FileDialog.ACCESS_FILESYSTEM
			_player_storage_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			_player_storage_dialog.use_native_dialog = true
			_player_storage_dialog.title = "请选择文稿（Documents）文件夹以保存玩家关卡"
			_player_storage_dialog.dir_selected.connect(_select_player_save_folder)
			_player_storage_dialog.canceled.connect(_cancel_player_save_folder)
			add_child(_player_storage_dialog)
		_player_storage_selecting = true
		_player_storage_dialog.popup_centered(Vector2i(900, 600))
	else:
		_show_player_storage_problem()


## 系统选择成功后持久化位置，再继续原来的保存或单条迁移入口。
func _select_player_save_folder(directory: String) -> void:
	_player_storage_selecting = false
	if _closing:
		return
	# 原授权记录丢失时也不能把仍绑定旧目录的迁移进度提交到另一个保存位置。
	var target := directory.trim_suffix("/").path_join(PlayerLevelPaths.SAVE_SUFFIX)
	var compatible := PlayerLevelMigration.new().check_target(player_saves_source, target, player_saves_journal)
	if not compatible.is_ok():
		_player_storage_errors = compatible.errors.duplicate()
		player_save_location.needs_authorization = true
		_show_player_storage_problem()
		return
	var selected := player_save_location.accept_directory(directory)
	if not selected.is_ok():
		_player_storage_errors = selected.errors.duplicate()
		_show_player_storage_problem()
		return
	_retry_player_storage()


## 取消授权明确保留所有原文件；下一次进入地图编辑或导入时仍可以重新选择。
func _cancel_player_save_folder() -> void:
	_player_storage_selecting = false
	_player_storage_continuation = Callable()
	_show_message("玩家关卡保存位置", tr("尚未授权保存目录。再次打开地图编辑器、导入关卡或玩家关卡列表时可以重试。"))


## 读取或写入错误显示具体原因与重试按钮，不能假装已完成迁移或清空玩家地图。
func _show_player_storage_problem() -> void:
	if not is_instance_valid(_player_storage_problem):
		_player_storage_problem = ConfirmationDialog.new()
		_player_storage_problem.name = "PlayerSaveFolderProblem"
		_player_storage_problem.title = "无法使用玩家关卡保存目录"
		_player_storage_problem.ok_button_text = "重试"
		_player_storage_problem.cancel_button_text = "暂不处理"
		_player_storage_problem.confirmed.connect(_retry_player_storage)
		_player_storage_problem.canceled.connect(func() -> void: _player_storage_continuation = Callable())
		add_child(_player_storage_problem)
	_player_storage_problem.title = "无法使用游戏保存目录" if _uses_external_runtime_storage else "无法使用玩家关卡保存目录"
	var errors := _runtime_storage_errors if _player_storage_ready and not _runtime_storage_ready else _player_storage_errors
	_player_storage_problem.dialog_text = user_levels_directory + "\n" + GameI18n.translate_errors(errors)
	_player_storage_problem.popup_centered(Vector2i(720, 310))


## 重试成功后重新扫描同一正式路径；失败则保留原入口，等待玩家修复权限。
func _retry_player_storage() -> void:
	if is_instance_valid(_player_storage_problem):
		_player_storage_problem.hide()
	_prepare_player_storage()
	if not _player_storage_ready:
		_request_player_storage()
		return
	var runtime_result := _prepare_runtime_storage()
	if not runtime_result.is_ok():
		_request_player_storage()
		return
	catalog.user_directory = user_levels_directory
	if legacy_upgrade != null:
		legacy_upgrade.target_directory = user_levels_directory
	catalog.refresh(registry)
	var continuation := _player_storage_continuation
	_player_storage_continuation = Callable()
	if continuation.is_valid():
		continuation.call()
	elif page == Page.LEVELS:
		_refresh_levels()


## 升级状态与玩家档案分开；空旧目录静默停用，已有作品只登记一次原生提醒。
func _prepare_legacy_upgrade() -> void:
	if legacy_upgrade == null and (player_save_location == null or user_levels_directory == player_saves_source):
		return
	if legacy_upgrade == null:
		legacy_upgrade = PlayerLegacyUpgrade.new()
		if settings_path != "user://settings.json":
			legacy_upgrade.state_directory = settings_path.get_base_dir().path_join("player_saves_upgrade")
	legacy_upgrade.source_directory = player_saves_source
	legacy_upgrade.target_directory = user_levels_directory
	legacy_upgrade.journal_path = player_saves_journal
	var inspected := legacy_upgrade.inspect()
	_legacy_upgrade_errors = inspected.errors.duplicate()
	if inspected.is_ok():
		_legacy_upgrade_state = inspected.value


## 只在首次发现旧作品时询问，默认关闭保留原件，不能把未回应当作删除授权。
func _show_legacy_upgrade_notice() -> bool:
	if legacy_upgrade == null:
		return false
	if not _legacy_upgrade_errors.is_empty():
		_show_message("旧关卡迁移", GameI18n.translate_errors(_legacy_upgrade_errors))
		return true
	if not _legacy_upgrade_state.get("needs_notice", false):
		return false
	var marked := legacy_upgrade.mark_prompted()
	if not marked.is_ok():
		_show_message("旧关卡迁移", GameI18n.translate_errors(marked.errors))
		return true
	_legacy_upgrade_state["needs_notice"] = false
	if not is_instance_valid(_legacy_upgrade_dialog):
		_legacy_upgrade_dialog = PlayerLegacyUpgradeDialog.new()
		_legacy_upgrade_dialog.native_dialog_handler = legacy_upgrade_native_dialog_handler
		_legacy_upgrade_dialog.migrate_requested.connect(_show_player_level_list_page)
		_legacy_upgrade_dialog.discard_requested.connect(_discard_legacy_levels)
		add_child(_legacy_upgrade_dialog)
	_legacy_upgrade_dialog.open_confirmation(ProjectSettings.globalize_path(player_saves_source), int(_legacy_upgrade_state.get("pending_count", 0)))
	return true


## 只有原生询问中明确的放弃按钮进入此处，删除限定在本次旧关卡目录快照。
func _discard_legacy_levels() -> void:
	if _closing or legacy_upgrade == null:
		return
	var discarded := legacy_upgrade.discard()
	if not discarded.is_ok():
		_show_message("无法清理旧关卡目录", GameI18n.translate_errors(discarded.errors))
		return
	_legacy_upgrade_state = {"needs_notice": false, "retired": true, "pending_count": 0}
	if page == Page.PLAYER_LEVEL_LIST:
		_refresh_player_level_list()


## 旧条目先核对列表快照，授权后只迁移这一文件；全部完成才清理旧副本并永久停用旧目录。
func _migrate_player_entry(entry: PlayerLevelRecord) -> void:
	if page != Page.PLAYER_LEVEL_LIST or entry == null or not entry.needs_migration or legacy_upgrade == null or _legacy_upgrade_state.get("retired", false):
		return
	if not _ensure_player_storage(_migrate_player_entry.bind(entry)):
		return
	var source := player_level_library.get_legacy_migration_source(entry)
	if not source.is_ok():
		_show_message("无法迁移旧关卡", GameI18n.translate_errors(source.errors))
		return
	var migrated := PlayerLevelMigration.new().migrate_file(player_saves_source, user_levels_directory, player_saves_journal, source.value.filename, source.value.fingerprint)
	if not migrated.is_ok():
		_show_message("无法迁移旧关卡", GameI18n.translate_errors(migrated.errors))
		return
	legacy_upgrade.target_directory = user_levels_directory
	var retired := legacy_upgrade.retire_if_migrated()
	if retired.is_ok() and retired.value:
		_legacy_upgrade_state = {"needs_notice": false, "retired": true, "pending_count": 0}
	catalog.user_directory = user_levels_directory
	catalog.refresh(registry)
	_refresh_player_level_list()
	if not retired.is_ok():
		_show_message("无法清理旧关卡目录", GameI18n.translate_errors(retired.errors))


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
	var layout_scale := float(_startup_menu_card.get_meta("ui_menu_layout_scale", 1.0))
	_startup_menu_card.position = (host.size - _startup_menu_card.size) * 0.5 + Vector2(0.0, 12.0 * layout_scale * (1.0 - progress))
	_startup_menu_card.scale = Vector2.ONE * layout_scale * lerpf(0.96, 1.0, progress)
	_startup_menu_card.modulate.a = progress


## 启动期间先保存原有错误反馈，卡片出现后再展示，避免弹窗抢到加载层前方。
func _show_startup_notice() -> void:
	if _startup_notice_title.is_empty():
		if _show_legacy_upgrade_notice():
			return
		if not _player_storage_ready or not _runtime_storage_ready:
			_request_player_storage()
		return
	_show_message(_startup_notice_title, _startup_notice_body)
	_startup_notice_title = ""
	_startup_notice_body = ""


## 回到窗口时刷新导入目录，切换语言时更新装配原因；关闭前保存当前作品。
func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_application_active = what == NOTIFICATION_APPLICATION_FOCUS_IN
		_sync_profile_timer()
		_sync_activity_timer()
	elif what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_RESUMED]:
		_application_suspended = what == NOTIFICATION_APPLICATION_PAUSED
		_sync_profile_timer()
		_sync_activity_timer()
	if not is_node_ready() or not startup_complete or _startup_menu_pending:
		return
	if what == NOTIFICATION_TRANSLATION_CHANGED and _dialogue_dialog.visible and not _dialogue_pages.is_empty():
		_update_dialogue_title()
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and page == Page.PLAYER_LEVEL_LIST and is_instance_valid(player_level_list_panel) and not player_level_list_panel.is_editing() and not player_level_list_panel.is_context_menu_open() and not _message_dialog.visible:
		_refresh_player_level_list()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and page == Page.LEVELS and not _level_import_pending and _rename_target == null and not _message_dialog.visible:
		_refresh_levels()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and page == Page.ASSEMBLY and _confirm_assembly_button != null:
		_update_preparation()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and page == Page.LEVELS:
		_player_level_context_menu.close_menu(false)
		_update_player_level_captions()
		_update_tutorial_section()
		if is_instance_valid(_rename_input):
			_on_player_level_name_changed(_rename_input.text)
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _closing or _editor_exit_save_pending or _editor_discard_dialog.visible:
			return
		if _editor != null:
			# 试玩期间编辑器隐藏但仍有未保存地图，关闭窗口也必须经过它的保护。
			if _editor_playtest:
				_return_to_editor()
			_request_editor_exit(true)
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
	_page_margin = margin
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 独立宿主保留逻辑排版，选关与编辑器按实际客户区统一显示图标、文字和地图。
	_page_host = Control.new()
	_page_host.name = "PageLayoutHost"
	_page_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_page_host)
	var layout := VBoxContainer.new()
	_page_layout = layout
	_page_host.add_child(layout)
	_page_host.resized.connect(_layout_page_content)
	_layout_page_content()
	_level_header = LevelBrowserHeader.new()
	_level_header.name = "LevelBrowserHeader"
	_level_header.back_requested.connect(_go_back)
	_level_header.refresh_requested.connect(_refresh_levels)
	_level_header.import_requested.connect(_import_levels)
	_level_header.sort_changed.connect(_on_level_sort_changed)
	_level_header.query_changed.connect(_on_level_search_changed)
	layout.add_child(_level_header)
	_player_level_context_menu = PlayerLevelContextMenu.new()
	_player_level_context_menu.name = "PlayerLevelContextMenu"
	_player_level_context_menu.delete_requested.connect(_delete_player_level)
	_player_level_context_menu.open_folder_requested.connect(_open_player_level_folder)
	_player_level_context_menu.rename_requested.connect(_rename_player_level)
	add_child(_player_level_context_menu)
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
	_clear_progress_dialog.native_dialog_handler = clear_progress_native_dialog_handler
	_clear_progress_dialog.confirmed.connect(_confirm_clear_progress)
	_clear_progress_dialog.canceled.connect(_cancel_clear_progress)
	add_child(_clear_progress_dialog)
	_about_dialog = AboutGameDialog.new()
	_about_dialog.name = "AboutGameDialog"
	_about_dialog.link_requested.connect(_open_about_link)
	_about_dialog.easter_egg_requested.connect(_open_shark_game)
	_about_dialog.easter_expansion_finished.connect(_reveal_shark_game)
	_about_dialog.easter_expansion_canceled.connect(_cancel_shark_entry)
	add_child(_about_dialog)
	_command_menu = CommandReferenceMenu.new()
	_command_menu.name = "CommandReferenceMenu"
	add_child(_command_menu)
	_import_dialog = FileDialog.new()
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.title = "导入关卡"
	_import_dialog.use_native_dialog = true
	_import_dialog.filters = PackedStringArray(["*.json ; JSON ; application/json"])
	_import_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	_import_dialog.file_selected.connect(_on_level_file_selected)
	_import_dialog.canceled.connect(_cancel_level_import)
	_import_dialog.close_requested.connect(_cancel_level_import)
	add_child(_import_dialog)
	GameTheme.style_guide_dialog(_import_dialog)
	_dialogue_dialog = AcceptDialog.new()
	_dialogue_dialog.dialog_hide_on_ok = false
	# 中文长段和无空格的文本也要能折行，不能只依赖按空格分词。
	_dialogue_dialog.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_dialog.confirmed.connect(_next_dialogue)
	add_child(_dialogue_dialog)
	GameTheme.style_guide_dialog(_dialogue_dialog)
	_build_dialogue_navigation()
	_build_markdown_dialogue()
	_editor_discard_dialog = MapExitDialog.new()
	_editor_discard_dialog.name = "MapExitDialog"
	_editor_discard_dialog.save_requested.connect(_save_editor_and_return)
	_editor_discard_dialog.confirmed.connect(_discard_editor_and_return)
	_editor_discard_dialog.canceled.connect(_cancel_editor_exit)
	add_child(_editor_discard_dialog)
	_save_timer = Timer.new()
	_save_timer.wait_time = 0.8
	_save_timer.one_shot = true
	_save_timer.timeout.connect(_save_current_draft)
	add_child(_save_timer)


## 清理旧页面并停止会话，页面切换不能让旧程序继续运行。
func _clear_page(keep_level_header: bool = false, keep_menu_card: bool = false) -> void:
	if _profile_tracker != null:
		_profile_tracker.end_level()
	_editor_exit_save_pending = false
	_editor_exit_quit_requested = false
	_save_timer.stop()
	if session != null:
		session.stop()
	_editor_playtest = false
	_clear_body(keep_level_header, keep_menu_card)
	session = null
	_program_editor_view.clear()
	_editor = null
	_cancel_level_import()
	_dialogue_dialog.hide()
	_message_dialog.hide()
	_editor_discard_dialog.hide()


## 只替换当前游戏组件；试玩期间隐藏的编辑器保留文档、历史和画布状态。
func _clear_body(keep_level_header: bool = false, keep_menu_card: bool = false) -> void:
	_cancel_menu_transition()
	_set_page_layout_scale(1.0)
	_restore_page_header()
	_cancel_player_level_rename()
	_player_level_context_menu.close_menu(false)
	_dispose_shark_game()
	_body.show()
	if not keep_menu_card:
		_main_background.set_active(false)
	# 离开设置即撤销待确认请求，隐藏的弹窗不能在其它页面执行清除。
	_cancel_clear_progress()
	_cancel_profile_reset()
	_clear_progress_dialog.close_dialog(false)
	_about_dialog.close_dialog(false)
	_command_menu.close_menu(false)
	if is_instance_valid(workbench) and workbench._actions_menu != null:
		workbench._actions_menu.close_menu(false)
	# 非关卡页面恢复标题；组装与编程入口再隐藏它，避免页面切换遗留可见状态。
	_header.show()
	_title.show()
	GameTheme.font_size(_title, "font_size", 28)
	_subtitle.show()
	_save_label.show()
	_set_level_navigation(false)
	# 目录刷新仅替换列表，不能打断搜索框的动画、输入法组合或光标位置。
	if not keep_level_header:
		_level_header.set_active(false)
	_tutorial_entries.clear()
	_player_entries.clear()
	_level_entries.clear()
	_level_grids.clear()
	_search_empty = null
	_tutorial_toggle = null
	_player_toggle = null
	if is_instance_valid(_menu_card):
		for child in _menu_card.get_children():
			_menu_card.remove_child(child)
			child.queue_free()
	for child in _body.get_children():
		if keep_menu_card and child == _menu_host:
			continue
		if _editor_playtest and child == _editor:
			continue
		_body.remove_child(child)
		child.queue_free()
	if not keep_menu_card:
		_menu_host = null
		_menu_card = null
	workbench = null
	assembly_panel = null
	settings_panel = null
	code_color_panel = null
	player_level_list_panel = null
	player_profile_panel = null
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
	_clear_page(false, true)
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
	_ensure_menu_card()
	var host := _menu_host
	var panel := _menu_card
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
	_add_menu_button(menu, "开始游戏", "StartGameButton", _open_page_from_main.bind(Page.LEVELS))
	_add_menu_button(menu, "地图编辑器", "MapEditorButton", _open_page_from_main.bind(Page.EDITOR))
	var leave := _add_menu_button(panel, "离开游戏", "LeaveGameButton", _leave_game)
	var preferences := _add_menu_button(panel, "设置", "SettingsButton", _open_settings_from_main)
	for button in [leave, preferences]:
		button.custom_minimum_size = Vector2(150, 48)
		GameTheme.font_size(button, "font_size", 16)
		button.anchor_top = 1.0
		button.anchor_bottom = 1.0
		button.offset_top = -64
		button.offset_bottom = -16
		button.minimum_size_changed.connect(_layout_main_menu.bind(host, panel))
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


## 主菜单与两级设置共享同一张白卡和布局，不因替换正文而重建背景或卡片。
func _ensure_menu_card() -> void:
	if is_instance_valid(_menu_card):
		return
	_menu_host = Control.new()
	_menu_host.name = "MainMenuHost"
	_menu_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_menu_host)
	_menu_card = Panel.new()
	_menu_card.name = "MainMenuCard"
	var surface := GameTheme.card()
	surface.set_corner_radius_all(32)
	_menu_card.add_theme_stylebox_override("panel", surface)
	_menu_host.add_child(_menu_card)
	_menu_host.resized.connect(_layout_main_menu.bind(_menu_host, _menu_card))
	_layout_main_menu(_menu_host, _menu_card)


## 设置导航固定于白卡左上方，置于正文合成层之外，避免随滚动淡出。
func _attach_settings_header() -> void:
	_header.reparent(_menu_card, false)
	_header.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_header.offset_left = 24
	_header.offset_right = -24
	_header.offset_top = 24
	_header.offset_bottom = 68
	_header.show()


## 返回其他页面前把公共导航归还原布局，不能随设置正文释放或遗留透明度。
func _restore_page_header() -> void:
	if is_instance_valid(_header) and _header.get_parent() != _page_layout:
		_header.reparent(_page_layout, false)
		_header.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_page_layout.move_child(_header, 1)
	if is_instance_valid(_header):
		_header.modulate = Color.WHITE


## 两个主要入口先扩展白卡；内部同步导航仍沿用原有路由，不影响独立编辑器与试玩。
func _open_page_from_main(destination: Page) -> void:
	if page != Page.MAIN or _menu_transitioning or _startup_menu_pending or _closing or not is_instance_valid(_menu_card):
		return
	if destination not in [Page.LEVELS, Page.EDITOR]:
		return
	_menu_transitioning = true
	_menu_transition_generation += 1
	var generation := _menu_transition_generation
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	_menu_page_transition = MainMenuPageTransition.new()
	_menu_page_transition.name = "MainMenuPageTransition"
	add_child(_menu_page_transition)
	_menu_page_transition.begin(_menu_card)
	_menu_transition = create_tween()
	_menu_transition.tween_method(_menu_page_transition.set_expansion_progress, 0.0, 1.0, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_menu_transition.finished.connect(_finish_menu_expansion.bind(destination, generation), CONNECT_ONE_SHOT)


## 白卡铺满后才构建目的页；原路由的清理不能释放正在保护画面的临时白色层。
func _finish_menu_expansion(destination: Page, generation: int) -> void:
	if generation != _menu_transition_generation or page != Page.MAIN or not is_instance_valid(_menu_page_transition):
		return
	var presentation := _menu_page_transition
	presentation.prepare_reveal()
	_menu_page_transition = null
	_menu_transition = null
	if destination == Page.LEVELS:
		_start_game()
	else:
		_open_editor()
	_menu_page_transition = presentation
	_menu_transitioning = true
	_reveal_expanded_page(_menu_transition_generation)


## 等容器的延后排版完成再淡入，避免新页面首帧闪烁或在 Windows 高分辨率下跳位。
func _reveal_expanded_page(generation: int) -> void:
	for frame in 2:
		await get_tree().process_frame
		if generation != _menu_transition_generation or not is_instance_valid(_menu_page_transition):
			return
	_menu_transition = create_tween()
	_menu_transition.tween_method(_menu_page_transition.set_reveal_progress, 0.0, 1.0, 0.24).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_menu_transition.finished.connect(_finish_page_reveal.bind(generation), CONNECT_ONE_SHOT)


## 新页面完全显现后释放临时层并恢复交互；旧回调不能影响已经切换的页面。
func _finish_page_reveal(generation: int) -> void:
	if generation != _menu_transition_generation:
		return
	if is_instance_valid(_menu_page_transition):
		_menu_page_transition.cancel()
		_menu_page_transition.queue_free()
	_menu_page_transition = null
	_menu_transition = null
	_menu_transitioning = false


## 鼠标或键盘激活设置入口时先淡出菜单内容，白卡与背景始终保持原位和不透明。
func _open_settings_from_main() -> void:
	if page != Page.MAIN or _menu_transitioning or not is_instance_valid(_menu_card):
		return
	_menu_transitioning = true
	_menu_transition_generation += 1
	var generation := _menu_transition_generation
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()
	_menu_transition = create_tween().set_parallel(true)
	for child in _menu_card.get_children():
		if child is Control:
			_menu_transition.tween_property(child, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_menu_transition.finished.connect(_finish_menu_fade_out.bind(generation), CONNECT_ONE_SHOT)


## 旧内容完全消失后构建设置；新控件和导航共同淡入，不让透明控件提前接收操作。
func _finish_menu_fade_out(generation: int) -> void:
	if generation != _menu_transition_generation or page != Page.MAIN:
		return
	_menu_transition = null
	_show_settings_page()
	_menu_transitioning = true
	generation = _menu_transition_generation
	_menu_transition = create_tween().set_parallel(true)
	for child in _menu_card.get_children():
		if child is Control:
			child.modulate.a = 0.0
			_menu_transition.tween_property(child, "modulate:a", 1.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_menu_transition.finished.connect(_finish_menu_fade_in.bind(generation), CONNECT_ONE_SHOT)


## 动画结束后恢复原生控件输入；过期动画回调不能解锁或修改后来打开的页面。
func _finish_menu_fade_in(generation: int) -> void:
	if generation == _menu_transition_generation:
		_menu_transitioning = false
		_menu_transition = null


## 任何同步页面切换都取消旧动画，使快速返回、重载或退出没有迟到的设置回调。
func _cancel_menu_transition() -> void:
	_menu_transition_generation += 1
	_menu_transitioning = false
	if _menu_transition != null and _menu_transition.is_valid():
		_menu_transition.kill()
	_menu_transition = null
	if is_instance_valid(_menu_page_transition):
		_menu_page_transition.cancel()
		_menu_page_transition.queue_free()
	_menu_page_transition = null


## Windows 高分辨率等比呈现整张菜单与设置白卡；手动百分比仍只调整字号，小窗口沿用原布局。
func _layout_main_menu(host: Control, panel: Panel) -> void:
	var factor := 1.0
	if is_instance_valid(window_controller) and window_controller.platform_name == "Windows":
		var area := get_viewport_rect().size
		factor = maxf(1.0, minf(area.x / GameWindowController.CONTENT_SIZE.x, area.y / GameWindowController.CONTENT_SIZE.y))
	panel.set_meta("ui_menu_layout_scale", factor)
	panel.size = MAIN_MENU_CARD_SIZE.min(host.size / factor)
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2.ONE * factor
	panel.position = (host.size - panel.size) * 0.5
	# 大字号可能提高按钮最小尺寸，重新保留边角内缩，不能让底部按钮越过白卡边界。
	for name: String in ["LeaveGameButton", "SettingsButton"]:
		var button := panel.get_node_or_null(name) as Button
		if button == null:
			continue
		var extent := button.get_combined_minimum_size().max(Vector2(150, 48))
		button.offset_top = -16 - extent.y
		button.offset_bottom = -16
		button.offset_left = 16 if name == "LeaveGameButton" else -16 - extent.x
		button.offset_right = 16 + extent.x if name == "LeaveGameButton" else -16
	if _startup_menu_revealing and panel == _startup_menu_card:
		_apply_startup_menu_transition(_startup_menu_progress)


## 保留入口名称与回调；底角半径 16 加上等距内缩 16，恰好与卡片半径 32 同心。
func _add_menu_button(parent: Node, text: String, node_name: String, action: Callable) -> Button:
	var button := GameTheme.button(parent, text, action)
	button.name = node_name
	button.custom_minimum_size.y = 64
	GameTheme.font_size(button, "font_size", 20)
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
	_clear_page(false, true)
	page = Page.SETTINGS
	_ensure_menu_card()
	_main_background.set_active(true)
	_set_level_navigation(true, "返回开始页面")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "设置"
	GameTheme.font_size(_title, "font_size", 22)
	_subtitle.hide()
	_save_label.text = ""
	_save_label.hide()
	settings_panel = SettingsPanel.new()
	settings_panel.settings = settings
	settings_panel.set_available_window_resolutions(window_controller.available_resolutions)
	settings_panel.set_available_ui_scales(window_controller.available_ui_scales, window_controller.effective_ui_scale)
	settings_panel.card_boundary = _menu_card
	settings_panel.navigation_title = _title
	settings_panel.code_colors_requested.connect(_show_code_colors_page)
	settings_panel.about_requested.connect(_show_about_dialog)
	settings_panel.player_levels_requested.connect(_show_player_level_list_page)
	settings_panel.player_profile_requested.connect(_show_player_profile_page)
	settings_panel.clear_progress_requested.connect(_request_clear_progress)
	settings_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_card.add_child(settings_panel)
	settings_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_attach_settings_header()
	var preview := SystemSoundPreview.new()
	preview.name = "SystemSoundPreview"
	preview.settings = settings
	settings_panel.add_child(preview)
	preview.preview_status_changed.connect(settings_panel.set_system_sound_preview_status)
	settings_panel.system_sound_preview_requested.connect(system_sound_preview_handler if system_sound_preview_handler.is_valid() else preview.request_preview)
	settings_panel.system_sound_preview_cancel_requested.connect(preview.cancel_preview)


## 显示器改变时刷新可选尺寸；其他设置页面不需要读取系统窗口信息。
func _sync_window_resolutions() -> void:
	_layout_page_content()
	if is_instance_valid(_menu_host) and is_instance_valid(_menu_card):
		_layout_main_menu(_menu_host, _menu_card)
	if is_instance_valid(settings_panel):
		settings_panel.set_available_window_resolutions(window_controller.available_resolutions)
		settings_panel.set_available_ui_scales(window_controller.available_ui_scales, window_controller.effective_ui_scale)


## 关于从设置入口打开并留在当前页面；作者链接只响应用户在弹窗中的操作。
func _show_about_dialog() -> void:
	if page != Page.SETTINGS or settings_panel == null or shark_game != null or _shark_entry_pending or _clear_progress_dialog.is_open():
		return
	_about_dialog.popup_dialog(settings_panel.find_child("AboutButton", true, false) as Control)


## 连击只开始版权卡扩展；保留底页直到海洋完整显现，避免瞬间切换和重复创建。
func _open_shark_game() -> void:
	if page != Page.SETTINGS or not is_instance_valid(settings_panel) or not _about_dialog.is_open() or shark_game != null or _shark_entry_pending:
		return
	if not _runtime_storage_ready:
		_about_dialog.close_dialog()
		_ensure_runtime_storage(_show_about_dialog)
		return
	_shark_settings_scroll = settings_panel._scroll.scroll_vertical
	_shark_entry_generation += 1
	_shark_entry_pending = true
	if not _about_dialog.begin_easter_expansion():
		_shark_entry_pending = false


## 版权卡覆盖视口后才构造彩蛋；淡入期间冻结INTRO计时，先呈现完整海洋再开始入场。
func _reveal_shark_game() -> void:
	if not _shark_entry_pending or page != Page.SETTINGS or not is_instance_valid(settings_panel) or not _about_dialog.is_open() or not _about_dialog.is_easter_expanding() or shark_game != null:
		return
	var generation := _shark_entry_generation
	_shark_layer = CanvasLayer.new()
	_shark_layer.name = "SharkCaveLayer"
	_shark_layer.layer = 150
	add_child(_shark_layer)
	shark_game = SharkCaveGame.new()
	shark_game.name = "SharkCaveGame"
	shark_game.process_mode = Node.PROCESS_MODE_DISABLED
	shark_game.modulate.a = 0.0
	shark_game.exit_requested.connect(_close_shark_game)
	shark_game.run_finished.connect(_on_shark_run_finished)
	_shark_layer.add_child(shark_game)
	shark_game.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shark_game.set_best_score(_shark_best_score)
	_shark_entry_tween = create_tween()
	_shark_entry_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_shark_entry_tween.tween_property(shark_game, "modulate:a", 1.0, 0.55)
	_shark_entry_tween.tween_callback(_finish_shark_entry.bind(generation))


## 仅当前轮淡入结束可交出控制；清理版权卡后才隐藏设置，避免锚点可见性中断过渡。
func _finish_shark_entry(generation: int) -> void:
	if generation != _shark_entry_generation or not _shark_entry_pending or page != Page.SETTINGS or not is_instance_valid(shark_game) or not _about_dialog.is_open():
		return
	_shark_entry_pending = false
	_shark_entry_tween = null
	_about_dialog.cancel_easter_expansion(false)
	_about_dialog.close_dialog(false)
	_header.hide()
	_body.hide()
	shark_game.modulate.a = 1.0
	shark_game.process_mode = Node.PROCESS_MODE_INHERIT
	_shark_discovered = true
	_persist_shark_statistics()
	_sync_activity_timer()


## Esc、失焦或版权卡关闭会取消入口并释放半成品，旧动画回调不能再次启动。
func _cancel_shark_entry() -> void:
	if not _shark_entry_pending:
		return
	_dispose_shark_game()
	if page == Page.SETTINGS and is_instance_valid(settings_panel):
		_header.show()
		_body.show()
		settings_panel._scroll.scroll_vertical = _shark_settings_scroll


## 新纪录写入玩家档案；独立于教学进度和装配草稿，统计页仅以问号展示。
func _on_shark_run_finished(score_value: int) -> void:
	_shark_best_score = maxi(_shark_best_score, score_value)
	_persist_shark_statistics()
	if is_instance_valid(shark_game):
		shark_game.set_best_score(_shark_best_score)


## 主动退出恢复关于窗口；先恢复布局再恢复滚动，防止隐藏容器重排改变阅读位置。
func _close_shark_game() -> void:
	_dispose_shark_game()
	if page != Page.SETTINGS or not is_instance_valid(settings_panel):
		return
	_header.show()
	_body.show()
	_restore_shark_settings.call_deferred(_shark_entry_generation)


## 下一帧复用原入口打开关于，玩家可继续查看作者信息或正常返回设置。
func _restore_shark_settings(generation: int) -> void:
	if generation != _shark_entry_generation or page != Page.SETTINGS or not is_instance_valid(settings_panel) or shark_game != null or _shark_entry_pending:
		return
	settings_panel._scroll.scroll_vertical = _shark_settings_scroll
	_show_about_dialog()


## 外部导航与正常退出共用释放路径，立即停止输入和模拟，避免队列释放前重复响应。
func _dispose_shark_game() -> void:
	_persist_shark_statistics()
	if is_instance_valid(shark_game):
		shark_game.hide()
	_sync_activity_timer()
	_shark_entry_generation += 1
	_shark_entry_pending = false
	if _shark_entry_tween != null and _shark_entry_tween.is_valid():
		_shark_entry_tween.kill()
	_shark_entry_tween = null
	if is_instance_valid(_about_dialog):
		_about_dialog.cancel_easter_expansion(false)
	if is_instance_valid(_shark_layer):
		_shark_layer.process_mode = Node.PROCESS_MODE_DISABLED
		if is_instance_valid(shark_game):
			shark_game.hide()
		remove_child(_shark_layer)
		_shark_layer.queue_free()
	_shark_layer = null
	shark_game = null


## 仅允许关于页登记的公开地址；失败在原弹窗中反馈，测试不打开真实外部程序。
func _open_about_link(url: String) -> void:
	if page != Page.SETTINGS or not _about_dialog.is_open() or _shark_entry_pending:
		return
	if url not in [AboutGameDialog.WEBSITE_URL, AboutGameDialog.EMAIL_URL, AboutGameDialog.BILIBILI_URL, AboutGameDialog.YOUTUBE_URL, AboutGameDialog.GITHUB_URL]:
		return
	var result: int = about_link_opener.call(url) if about_link_opener.is_valid() else OS.shell_open(url)
	if result != OK:
		_about_dialog.show_link_error()


## 只从资源目录中的真实关卡定义收集清除范围，用户导入文件不能扩大操作范围。
func _request_clear_progress() -> void:
	if _closing or page != Page.SETTINGS or settings_panel == null or _clear_progress_dialog.is_open() or _about_dialog.is_open():
		return
	if not _ensure_runtime_storage(_request_clear_progress):
		return
	_cancel_clear_progress()
	for definition in catalog.levels:
		if definition.source_path.begins_with("res://data/levels/") and not definition.id in _pending_clear_level_ids:
			_pending_clear_level_ids.append(definition.id)
	_pending_clear_drafts_directory = drafts.directory
	_pending_clear_progress_directory = drafts.progress_directory
	_clear_progress_pending = true
	_clear_progress_dialog.popup_dialog(settings_panel.find_child("ClearProgressButton", true, false) as Control)


## 取消只丢弃请求快照，不调用存储层，也不会改变任何通关状态或玩家作品。
func _cancel_clear_progress() -> void:
	_clear_progress_pending = false
	_pending_clear_level_ids.clear()
	_pending_clear_drafts_directory = ""
	_pending_clear_progress_directory = ""
	if is_instance_valid(_clear_progress_dialog):
		_clear_progress_dialog.close_dialog(false)


## 仅消费一次明确确认；设置页没有运行会话，旧自动保存不会重新写入已清除作品。
func _confirm_clear_progress() -> void:
	if _closing or not _clear_progress_pending or page != Page.SETTINGS or settings_panel == null or session != null or _clear_progress_dialog.is_open():
		return
	var level_ids: Array[String] = _pending_clear_level_ids.duplicate()
	var paths_match := drafts.directory == _pending_clear_drafts_directory and drafts.progress_directory == _pending_clear_progress_directory
	_cancel_clear_progress()
	var result := drafts.clear_level_records(level_ids) if paths_match else DataResult.failure("关卡或草稿目录已变更，请重新打开清除确认。")
	settings_panel.show_progress_result(result)
	var clear_button := settings_panel.find_child("ClearProgressButton", true, false) as Button
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
	if page == Page.PLAYER_PROFILE and is_instance_valid(player_profile_panel) and not player_profile_panel.commit_username():
		return
	if _profile_tracker != null:
		_profile_tracker.end_level()
	_closing = true
	_sync_activity_timer()
	_flush_activity_statistics()
	_cancel_clear_progress()
	_cancel_profile_reset()
	_cancel_menu_transition()
	if quit_handler.is_valid():
		quit_handler.call()
	else:
		get_tree().quit()


## 根据当前页面选择返回目标；地图未保存确认只在编辑器返回时触发。
func _go_back() -> void:
	if _menu_transitioning:
		return
	if is_instance_valid(shark_game):
		_close_shark_game()
		return
	if _about_dialog.is_open():
		_about_dialog.close_dialog()
		return
	if is_instance_valid(player_profile_panel) and player_profile_panel.is_statistics_about_open():
		player_profile_panel.close_statistics_about()
		return
	if _editor_exit_save_pending or _editor_discard_dialog.visible:
		return
	if _clear_progress_dialog.is_open() or (is_instance_valid(_profile_reset_dialog) and _profile_reset_dialog.is_open()):
		return
	if page == Page.PLAYER_PROFILE and is_instance_valid(player_profile_panel) and not player_profile_panel.commit_username():
		return
	if _editor_playtest:
		_return_to_editor()
	elif page in [Page.ASSEMBLY, Page.PLAY]:
		_back_to_levels()
	elif page in [Page.CODE_COLORS, Page.PLAYER_LEVEL_LIST, Page.PLAYER_PROFILE]:
		_show_settings_page()
	elif page == Page.EDITOR:
		_request_editor_exit(false)
	else:
		_show_main_page()


## 返回开始页和关闭窗口共用保存询问，先提交尚未失焦的编辑再判断dirty。
func _request_editor_exit(quit_game: bool) -> void:
	if page != Page.EDITOR or not is_instance_valid(_editor) or _closing or _editor_exit_save_pending or _editor_discard_dialog.visible:
		return
	_editor._commit_gate_timer()
	if not _editor._level_guide_editor.close_dialog():
		return
	_editor._canvas.finish_stroke()
	if _editor._time_limit_field.has_focus():
		_editor._commit_time_limit()
	_editor._commit_module_limit()
	if _editor._message_dialog.visible:
		return
	if not _editor._commit_identity():
		return
	_editor_exit_quit_requested = quit_game
	if _editor.editor_document.is_dirty():
		_editor._actions_menu.close_menu(false)
		_editor._guide_menu.close_menu(false)
		_editor._enemy_panel._picker.close_menu(false)
		_editor._restriction_picker.close_menu(false)
		_editor._command_menu.close_menu(false)
		_editor_discard_dialog.open_for_map(_editor.editor_document.document.display_name)
	else:
		_complete_editor_exit()


## 取消只清除本次退出目标，保留地图、路径和历史。
func _cancel_editor_exit() -> void:
	_editor_exit_quit_requested = false


## 用户确认放弃或写盘成功后，执行原先请求的返回或退出目标。
func _complete_editor_exit() -> void:
	var quit_game := _editor_exit_quit_requested
	_editor_exit_quit_requested = false
	if quit_game:
		_leave_game()
	else:
		_return_from_map_editor()


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
	_complete_editor_exit()


## 失败或取消选择路径会清除退出意图，后续普通保存不能自动离开编辑器。
func _on_editor_save_finished(success: bool) -> void:
	if success:
		catalog.refresh(registry)
	if not _editor_exit_save_pending:
		return
	_editor_exit_save_pending = false
	if success and page == Page.EDITOR and is_instance_valid(_editor) and not _editor.editor_document.is_dirty():
		_complete_editor_exit()
	else:
		_editor_exit_quit_requested = false


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
	_layout_page_content()
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
	# 滚动条使用页面既有的右侧留白，不因展示更多而挤压七列卡片。
	var scroll_margin := MarginContainer.new()
	scroll_margin.name = "LevelScrollMargin"
	scroll_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_right", -LEVEL_SCROLLBAR_WIDTH)
	_body.add_child(scroll_margin)
	var scroll := ScrollContainer.new()
	scroll.name = "LevelScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	scroll.follow_focus = true
	_style_level_scrollbar(scroll.get_v_scroll_bar())
	var content_fade := ScrollContentFade.new()
	content_fade.name = "LevelContentFade"
	content_fade.top_extension = spacer.custom_minimum_size.y
	content_fade.fade_bottom_enabled = false
	content_fade.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_margin.add_child(content_fade)
	var sections := VBoxContainer.new()
	sections.name = "LevelSections"
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sections.add_theme_constant_override("separation", 36)
	scroll.add_child(sections)
	content_fade.set_scroll(scroll)
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
	GameTheme.font_size(_tutorial_toggle, "font_size", 14)
	# 文案包含动态总数，由同一刷新方法处理语言切换，避免翻译格式化后的字符串。
	_tutorial_toggle.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var tutorial_grid := _create_level_grid(tutorial_section, "LevelGrid")
	var imported_section := VBoxContainer.new()
	imported_section.name = "ImportedSection"
	imported_section.add_theme_constant_override("separation", 16)
	sections.add_child(imported_section)
	var player_header := HBoxContainer.new()
	imported_section.add_child(player_header)
	var player_title := GameTheme.label(player_header, "玩家关卡", 22)
	player_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_player_toggle = GameTheme.button(player_header, "", _toggle_players)
	_player_toggle.name = "PlayerToggleButton"
	_player_toggle.flat = true
	_player_toggle.toggle_mode = true
	_player_toggle.add_theme_color_override("font_color", GameTheme.MUTED)
	GameTheme.font_size(_player_toggle, "font_size", 14)
	_player_toggle.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var imported_grid := _create_level_grid(imported_section, "ImportedLevelGrid")
	_add_import_card(imported_grid)
	for index in range(catalog.levels.size()):
		var definition: LevelDefinition = catalog.levels[index]
		# 来源路径由目录加载器提供；不能按名称、ID 或排序号猜测是否为教学关卡。
		if definition.source_path.begins_with("res://data/levels/"):
			_tutorial_entries.append(_add_level_card(tutorial_grid, definition, index))
		else:
			_player_entries.append(_add_level_card(imported_grid, definition, index))
	_apply_level_order()
	_update_tutorial_section()
	_layout_page_content.call_deferred()


## Windows 选关和地图编辑器复用白卡的客户区比例；手动百分比仍只改变真实字号。
func _layout_page_content() -> void:
	if not is_instance_valid(_page_host) or not is_instance_valid(_page_layout):
		return
	var factor := 1.0
	if page in [Page.LEVELS, Page.EDITOR] and is_instance_valid(window_controller) and window_controller.platform_name == "Windows":
		var area := get_viewport_rect().size
		factor = maxf(1.0, minf(area.x / GameWindowController.CONTENT_SIZE.x, area.y / GameWindowController.CONTENT_SIZE.y))
	_set_page_layout_scale(factor)


## 外边距与控件共同扩大，编辑坐标保持逻辑单位；独立浮层同步比例，切换页面时恢复。
func _set_page_layout_scale(factor: float) -> void:
	if not is_instance_valid(_page_host) or not is_instance_valid(_page_layout):
		return
	var inset := roundi(24.0 * factor)
	for edge: String in ["left", "top", "right", "bottom"]:
		_page_margin.add_theme_constant_override("margin_" + edge, inset)
	_page_layout.position = Vector2.ZERO
	_page_layout.pivot_offset = Vector2.ZERO
	_page_layout.size = _page_host.size / factor
	_page_layout.scale = Vector2.ONE * factor
	if is_instance_valid(_level_header):
		_level_header.set_presentation_scale(factor)
	if is_instance_valid(_editor):
		_editor.set_presentation_scale(factor)
	if is_instance_valid(_editor_discard_dialog):
		_editor_discard_dialog.set_presentation_scale(factor)


## 选关滚动条保留固定宽度与原生操作，透明轨道及浅色滑块降低视觉干扰。
func _style_level_scrollbar(bar: VScrollBar) -> void:
	for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxFlat.new()
		var opacity := 0.0 if state.begins_with("scroll") else 0.26
		if state == "grabber_highlight":
			opacity = 0.36
		elif state == "grabber_pressed":
			opacity = 0.46
		style.bg_color = Color(0.50, 0.57, 0.66, opacity)
		style.set_corner_radius_all(6)
		style.set_content_margin_all(LEVEL_SCROLLBAR_WIDTH * 0.5)
		bar.add_theme_stylebox_override(state, style)


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


## 玩家关卡单独展开；导入卡片占一列，折叠时只保留完整首行。
func _toggle_players() -> void:
	if page != Page.LEVELS or not is_instance_valid(_player_toggle):
		return
	_player_level_context_menu.close_menu(false)
	_cancel_player_level_rename()
	_players_expanded = not _players_expanded
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
			card.visible = _level_display_name(definition).to_lower().contains(query)
		else:
			if tutorial_index >= 0:
				card.visible = _tutorials_expanded or tutorial_index < LEVEL_COLUMNS
			else:
				card.visible = _players_expanded or _player_entries.find(card) < LEVEL_COLUMNS - 1
		if card.visible:
			matches += 1
	_tutorial_toggle.visible = not searching and _tutorial_entries.size() > LEVEL_COLUMNS
	_tutorial_toggle.set_pressed_no_signal(_tutorials_expanded)
	_tutorial_toggle.text = tr("收起") if _tutorials_expanded else tr("展示更多（%d）") % _tutorial_entries.size()
	_player_toggle.visible = not searching and _player_entries.size() > LEVEL_COLUMNS - 1
	_player_toggle.set_pressed_no_signal(_players_expanded)
	_player_toggle.text = tr("收起") if _players_expanded else tr("展示更多（%d）") % _player_entries.size()
	_search_empty.visible = searching and matches == 0
	for grid in _level_grids:
		_pad_level_grid(grid)


## 输入变化只筛选已有卡片，保留输入焦点和输入法状态，并把结果滚回首行。
func _on_level_search_changed(_query: String) -> void:
	if page != Page.LEVELS:
		return
	_player_level_context_menu.close_menu(false)
	_cancel_player_level_rename()
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
		else:
			_player_entries.assign(ordered)


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
	var is_player := not definition.source_path.begins_with("res://data/levels/")
	var title := GameTheme.label(column, definition.display_name, 14)
	title.name = "LevelCardTitle"
	if is_player:
		title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		column.mouse_filter = Control.MOUSE_FILTER_PASS
		title.mouse_filter = Control.MOUSE_FILTER_PASS
		column.gui_input.connect(_on_player_level_input.bind(definition, column, button))
		button.gui_input.connect(_on_player_level_input.bind(definition, button, button))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = LEVEL_COLUMN_MIN_WIDTH
	if is_player:
		title.max_lines_visible = 2
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.tooltip_text = definition.display_name
		title.resized.connect(_fit_player_level_title.bind(title))
		_fit_player_level_title.call_deferred(title)
	# 教学卡片只在实际通关后显示完成标记；玩家卡片继续保留署名和独立完成状态。
	var is_completed := drafts.is_completed(definition.id)
	var caption := GameTheme.label(column, "✓ 已完成" if is_completed else "", 12, true)
	caption.name = "LevelCardCaption"
	caption.visible = is_player or is_completed
	if is_player:
		caption.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		# 署名需要接收悬停以显示完整文本；右键继续冒泡给卡片处理。
		caption.mouse_filter = Control.MOUSE_FILTER_PASS
		caption.text = _player_level_caption(definition)
		caption.tooltip_text = caption.text
		caption.max_lines_visible = 2
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if is_completed:
			var completed := GameTheme.label(column, "✓ 已完成", 12, true)
			completed.name = "PlayerLevelCompleted"
			completed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 长署名和本土化完成标记只能增加行高，不能撑开列宽产生横向溢出。
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.tooltip_text = _level_display_name(definition) + "\n" + (definition.description if is_player else tr(definition.description))
	return column


## 长玩家名称优先按列宽缩字，最小保持可读字号；两行仍不足时由标签省略且悬停可看原文。
func _fit_player_level_title(title: Label) -> void:
	if not is_instance_valid(title) or title.is_queued_for_deletion() or title.size.x <= 0:
		return
	var base_size := 14
	var factor := GameTheme.font_scale(title)
	var text_width := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(base_size * factor)).x
	var fitted_size := base_size
	if text_width > title.size.x:
		fitted_size = clampi(floori(base_size * title.size.x / text_width), 10, base_size)
	if GameTheme.base_font_size(title, "font_size") != fitted_size:
		GameTheme.font_size(title, "font_size", fitted_size)


## 只有内置教学名进入翻译词典，玩家自定义名称必须逐字显示并使用同样内容搜索。
func _level_display_name(definition: LevelDefinition) -> String:
	return tr(definition.display_name) if definition.source_path.begins_with("res://data/levels/") else definition.display_name


## 分类文案参与本土化，玩家填写的署名作为格式参数原样保留。
func _player_level_caption(definition: LevelDefinition) -> String:
	return tr("玩家关卡") if definition.creator.is_empty() else tr("玩家关卡，by %s") % definition.creator


## 翻译通知只重算动态署名，保留列表、滚动位置以及原始名称。
func _update_player_level_captions() -> void:
	if page != Page.LEVELS:
		return
	for entry in _level_entries:
		var definition: LevelDefinition = entry.definition
		if definition.source_path.begins_with("res://data/levels/"):
			continue
		var caption := (entry.control as Control).get_node("LevelCardCaption") as Label
		caption.text = _player_level_caption(definition)
		caption.tooltip_text = caption.text


## 玩家卡片的图标、标题和说明接收右键；目录拒绝删除的来源不显示入口。
func _on_player_level_input(event: InputEvent, definition: LevelDefinition, source: Control, anchor: Control) -> void:
	if page != Page.LEVELS or not event is InputEventMouseButton:
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_RIGHT or not mouse.pressed:
		return
	source.accept_event()
	_cancel_player_level_rename()
	if not catalog.can_delete_user_level(definition):
		return
	_level_header._actions_menu.close_menu(false)
	_player_level_context_menu.popup_at(anchor, source.get_global_transform_with_canvas() * mouse.position, definition)


## 删除仅作用于菜单选中的当前目录对象，成功后原搜索、排序和滚动仍保留。
func _delete_player_level(definition: LevelDefinition) -> void:
	if page != Page.LEVELS or not catalog.levels.has(definition):
		return
	var result := catalog.delete_user_level(definition)
	if not result.is_ok():
		_show_message("无法删除关卡", GameI18n.translate_errors(result.errors))
		return
	var old_scroll := _body.find_child("LevelScroll", true, false) as ScrollContainer
	var scroll_value := old_scroll.scroll_vertical if old_scroll != null else 0
	_refresh_levels()
	var new_scroll := _body.find_child("LevelScroll", true, false) as ScrollContainer
	if new_scroll != null:
		new_scroll.set_deferred("scroll_vertical", scroll_value)


## 导入卡片和页头菜单共用系统文件选择入口。
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
	GameTheme.font_size(button, "font_size", 44)
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


## 直接用系统选择器从下载目录选取 JSON；取消不会创建目录或修改关卡。
func _import_levels() -> void:
	if page != Page.LEVELS or _level_import_pending:
		return
	if not _ensure_player_storage(_import_levels):
		return
	_import_dialog.current_file = ""
	var downloads := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if downloads.is_empty():
		downloads = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_import_dialog.current_dir = downloads
	_level_import_pending = true
	_import_dialog.popup_centered(Vector2i(900, 600))


## 验证所选文件后生成独立托管副本，再刷新关卡；不覆盖下载原件或已有地图。
func _on_level_file_selected(path: String) -> void:
	if page != Page.LEVELS or not _level_import_pending:
		return
	_cancel_level_import()
	var store := PlayerLevelStore.new()
	store.directory = user_levels_directory
	var imported := store.import_file(path, registry)
	if not imported.is_ok():
		_show_message("无法导入关卡", GameI18n.translate_errors(imported.errors))
		return
	_refresh_levels()


## 取消或换页使本次选择失效，原生窗口返回焦点不能触发旧提示或额外刷新。
func _cancel_level_import() -> void:
	_level_import_pending = false
	_import_dialog.hide()


## 只为当前目录拥有的玩家关卡打开真实托管文件夹，不打开下载原件或教学资源。
func _open_player_level_folder(definition: LevelDefinition) -> void:
	if page != Page.LEVELS:
		return
	var result := catalog.get_user_level_directory(definition)
	if not result.is_ok():
		_show_message("无法打开关卡文件夹", GameI18n.translate_errors(result.errors))
		return
	var path: String = result.value
	var error: int = folder_opener.call(path) if folder_opener.is_valid() else OS.shell_open(path)
	if error != OK:
		_show_message("无法打开关卡文件夹", tr("无法打开文件夹：%s（%s）。") % [path, error_string(error)])


## 在当前卡片的标题上覆盖等宽输入框，标签仍保留原占位，长名称不会撑开七列网格。
func _rename_player_level(definition: LevelDefinition) -> void:
	if page != Page.LEVELS or not catalog.can_delete_user_level(definition):
		return
	_cancel_player_level_rename()
	for entry in _level_entries:
		if entry.definition != definition or not entry.control.is_visible_in_tree():
			continue
		_rename_title = entry.control.get_node("LevelCardTitle") as Label
		_rename_card_button = entry.control.get_child(0) as Button
		break
	if _rename_title == null:
		return
	_rename_target = definition
	_rename_input = LineEdit.new()
	_rename_input.name = "PlayerLevelNameInput"
	_rename_input.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_rename_input.text = definition.display_name
	_rename_input.caret_blink = true
	_rename_input.keep_editing_on_text_submit = true
	_rename_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rename_input.expand_to_text_length = false
	GameTheme.font_size(_rename_input, "font_size", GameTheme.base_font_size(_rename_title, "font_size"))
	_rename_input.text_changed.connect(_on_player_level_name_changed.bind(_rename_input))
	_rename_input.text_submitted.connect(_on_player_level_name_submitted.bind(_rename_input))
	_rename_input.focus_exited.connect(_on_player_level_name_focus_exited.bind(_rename_input))
	# 透明合成组分隔原生焦点遍历；Tab 与 Shift+Tab 明确返回同一卡片，继续沿用失焦取消。
	_rename_title.add_child(_rename_input)
	_rename_input.focus_next = _rename_input.get_path_to(_rename_card_button)
	_rename_input.focus_previous = _rename_input.get_path_to(_rename_card_button)
	_on_player_level_name_changed(_rename_input.text)
	_rename_input.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rename_input.anchor_top = 0.5
	_rename_input.anchor_bottom = 0.5
	_rename_input.offset_left = -4
	_rename_input.offset_right = 4
	# 原生输入框仍有字体/主题最小高度，按实际高度居中，避免强设 28 后被向下撑开。
	var input_height := maxf(28.0, _rename_input.get_combined_minimum_size().y)
	_rename_input.offset_top = -input_height * 0.5
	_rename_input.offset_bottom = input_height * 0.5
	# self_modulate 只隐藏旧标题字形，不会让子输入框透明，也不改变卡片高度。
	_rename_title.self_modulate.a = 0
	_rename_input.grab_focus()
	_rename_input.select_all()
	var scroll := _body.find_child("LevelScroll", true, false) as ScrollContainer
	if scroll != null:
		scroll.ensure_control_visible(_rename_input)


## 编辑时 Esc 恢复原名，点击输入框之外也仅取消；输入法候选与原生文本菜单优先处理。
func _input(event: InputEvent) -> void:
	if _menu_transitioning:
		get_viewport().set_input_as_handled()
		return
	if _rename_target == null or not is_instance_valid(_rename_input) or _rename_input.get_menu().visible:
		return
	if event.is_action_pressed("ui_cancel"):
		if _rename_input.has_ime_text():
			return
		get_viewport().set_input_as_handled()
		var button := _rename_card_button
		_cancel_player_level_rename()
		if is_instance_valid(button) and button.is_visible_in_tree():
			button.grab_focus()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _rename_input.get_global_rect().has_point(event.position):
			_cancel_player_level_rename()


## 与落盘接口使用同一校验；非法字符保留在输入框供修正，但不允许悄悄过滤后提交。
func _on_player_level_name_changed(value: String, edit: LineEdit = null) -> void:
	if not is_instance_valid(_rename_input) or (edit != null and edit != _rename_input):
		return
	var checked := LevelCatalog.validate_player_level_name(value)
	_set_player_level_name_error("" if checked.is_ok() else GameI18n.translate_errors(checked.errors))


## 正常重命名只显示文字选区和光标；仅非法输入用红边和悬停文字反馈错误。
func _set_player_level_name_error(message: String) -> void:
	if not is_instance_valid(_rename_input):
		return
	var border := Color.TRANSPARENT if message.is_empty() else GameTheme.ERROR
	var background := Color.TRANSPARENT if message.is_empty() else Color("F5F9FF")
	var normal := GameTheme.box(background, border, 5)
	normal.content_margin_left = 6
	normal.content_margin_right = 6
	normal.content_margin_top = 3
	normal.content_margin_bottom = 3
	_rename_input.add_theme_stylebox_override("normal", normal)
	var focused := normal.duplicate() as StyleBoxFlat
	focused.bg_color = Color.TRANSPARENT
	_rename_input.add_theme_stylebox_override("focus", focused)
	_rename_input.tooltip_text = tr("Enter 确认，Esc 取消") if message.is_empty() else message


## 原生 LineEdit 在输入法确认后才发出提交事件，不把候选词的回车当作关卡保存。
func _on_player_level_name_submitted(_value: String, edit: LineEdit) -> void:
	if edit == _rename_input:
		_confirm_rename_player_level()


## 焦点转移延后到当前 GUI 事件完成；文本右键菜单不算放弃编辑，旧控件回调不能取消新编辑。
func _on_player_level_name_focus_exited(edit: LineEdit) -> void:
	_cancel_unfocused_player_level_rename.call_deferred(edit)


## 点击其他控件或键盘 Tab 离开时丢弃未确认文本，不隐式写盘。
func _cancel_unfocused_player_level_rename(edit: LineEdit) -> void:
	if is_instance_valid(edit) and edit == _rename_input and not edit.has_focus() and not edit.get_menu().visible:
		_cancel_player_level_rename()


## 仅回车确认才写入；原子保存成功后刷新同一关卡，失败保留输入供玩家修正或取消。
func _confirm_rename_player_level() -> void:
	if page != Page.LEVELS or _rename_target == null or not is_instance_valid(_rename_input):
		return
	var checked := LevelCatalog.validate_player_level_name(_rename_input.text)
	if not checked.is_ok():
		_set_player_level_name_error(GameI18n.translate_errors(checked.errors))
		return
	var result := catalog.rename_user_level(_rename_target, _rename_input.text, registry)
	if not result.is_ok():
		_set_player_level_name_error(GameI18n.translate_errors(result.errors))
		return
	var scroll := _body.find_child("LevelScroll", true, false) as ScrollContainer
	var scroll_value := scroll.scroll_vertical if scroll != null else 0
	_cancel_player_level_rename()
	_refresh_levels()
	scroll = _body.find_child("LevelScroll", true, false) as ScrollContainer
	if scroll != null:
		scroll.set_deferred("scroll_vertical", scroll_value)


## 取消只恢复标题显示并销毁临时输入框；先清空引用，防止隐藏或释放触发的失焦回调重入。
func _cancel_player_level_rename() -> void:
	_rename_target = null
	var edit := _rename_input
	_rename_input = null
	if is_instance_valid(_rename_title):
		_rename_title.self_modulate.a = 1
	_rename_title = null
	_rename_card_button = null
	if is_instance_valid(edit):
		edit.hide()
		edit.queue_free()


## 每次进入关卡先显示空组装台；程序自动恢复，历史装配需由玩家主动选择载入。
func _enter_level(definition: LevelDefinition) -> void:
	if not _ensure_runtime_storage(_enter_level.bind(definition)):
		return
	_clear_page()
	session = GameSession.create(definition, registry)
	var draft_warning := _load_current_draft()
	session.completed.connect(_on_level_completed)
	# 所有正式入口共用统计，不按教学目录限定未来的正式关卡或玩家关卡。
	session.attempt_failed.connect(_on_profile_attempt_failed)
	session.attempt_started.connect(_on_profile_attempt_started)
	session.changed.connect(_sync_profile_timer)
	_profile_tracker.begin_level(_application_active and not _application_suspended)
	_profile_hint_mode = "none"
	_remember_profile_hint_mode()
	if definition.can_use_code_hints():
		session.consecutive_failures = drafts.get_failure_streak(_hint_progress_key())
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
	# 编辑器试玩保留隐藏编辑页而不清空正文，必须在同一宿主取消编辑器专用比例。
	_layout_page_content()
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
	# text_changed 可以延后到下一帧；离开前读取真实编辑器，不能用尚未同步的旧源码重建。
	_capture_program_editor_view()
	# 模块改变会影响模拟世界，运行中或暂停中都沿用 stop()，不产生新的失败统计。
	session.stop()
	_clear_body()
	_show_assembly_page(true)


## 同一会话内保存源码、缩放与主光标视点；这些展示状态不写入关卡或装配数据。
func _capture_program_editor_view() -> void:
	if not is_instance_valid(workbench) or not is_instance_valid(workbench._code):
		return
	var code := workbench._code
	if session.source != code.text:
		session.source = code.text
		_schedule_save()
	_program_editor_view = {
		"zoom": workbench.code_zoom_percent,
		"line": code.get_caret_line(), "column": code.get_caret_column(),
		"scroll_vertical": code.scroll_vertical, "scroll_horizontal": code.scroll_horizontal,
		"selection": code.has_selection(),
	}
	if code.has_selection():
		_program_editor_view["selection_from"] = Vector2i(code.get_selection_from_line(), code.get_selection_from_column())
		_program_editor_view["selection_to"] = Vector2i(code.get_selection_to_line(), code.get_selection_to_column())


## 新编辑器完成排版后恢复视点，过期回调不得抢占新页面或新会话的光标。
func _restore_program_editor_view(expected: GameWorkbench) -> void:
	if _program_editor_view.is_empty():
		return
	var view := _program_editor_view.duplicate(true)
	await get_tree().process_frame
	await get_tree().process_frame
	if page != Page.PLAY or not is_instance_valid(expected) or workbench != expected:
		return
	var code := expected._code
	code.set_caret_line(int(view.line))
	code.set_caret_column(int(view.column))
	if bool(view.selection):
		var start: Vector2i = view.selection_from
		var end: Vector2i = view.selection_to
		code.select(start.x, start.y, end.x, end.y)
	code.scroll_vertical = float(view.scroll_vertical)
	code.scroll_horizontal = int(view.scroll_horizontal)


## 组装事件同时更新确认按钮和自动保存，不让界面自行绕过装配模型的上限。
func _on_preparation_changed() -> void:
	_update_preparation()
	_schedule_save()


## 每次编辑后检查完整装配，缺中心、断连和出生占地无效都即时阻止确认。
func _update_preparation() -> void:
	_show_preparation_result(session.assembly.build_document())


## 禁用按钮仍保留原生悬停提示，状态区同时显示原因，方便键盘操作与修复草稿。
func _show_preparation_result(result: DataResult) -> void:
	var reason := "" if result.is_ok() else GameI18n.translate_errors(result.errors)
	var tooltip := tr(_confirm_assembly_caption) + ("" if reason.is_empty() else "\n" + reason)
	assembly_panel.header.set_confirmation_state(result.is_ok(), tooltip)
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
	workbench.code_zoom_percent = int(_program_editor_view.get("zoom", 100))
	workbench.settings = settings
	workbench.registry = session.assembly.content
	workbench.allow_draft_save = not _editor_playtest
	workbench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workbench.draft_changed.connect(_schedule_save)
	workbench.save_requested.connect(_save_current_draft.bind(true))
	workbench.edit_modules_requested.connect(_return_to_assembly)
	workbench.back_requested.connect(_return_to_assembly)
	workbench.help_requested.connect(_show_dialogue)
	workbench.commands_requested.connect(_show_command_reference)
	workbench.actions_requested.connect(_command_menu.close_menu.bind(false))
	workbench.code_hint_used.connect(_on_profile_code_hint_used)
	_body.add_child(workbench)
	_restore_program_editor_view.call_deferred(workbench)
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


## 教学沿用旧进度键，玩家与其他来源的提示门槛独立保存，避免同名地图互相污染。
func _hint_progress_key() -> String:
	if session == null:
		return ""
	if session.level.source_path == "res://data/levels/%s.json" % session.level.id:
		return session.level.id
	return "hints:" + _profile_level_key()


## 正式教学与允许提示的玩家关卡保存连续失败次数，编辑器试玩始终隔离。
func _on_attempt_failed() -> void:
	if _editor_playtest or session == null or not session.level.can_use_code_hints():
		return
	var saved := drafts.save_failure_streak(_hint_progress_key(), session.consecutive_failures)
	if not saved.is_ok():
		_save_label.text = tr("提示记录保存失败") + "：" + GameI18n.translate_errors(saved.errors)
		_save_label.show()


## 通关后的重新运行属于新挑战；失败重试继续累计原来的装配与编辑时间。
func _on_profile_attempt_started() -> void:
	if _editor_playtest or session == null or _profile_tracker == null:
		return
	if _profile_tracker.is_completed():
		_profile_tracker.begin_level(_application_active and not _application_suspended)
	# run 的状态锁已排除暂停/运行；这里仍可能看到上次 SUCCEEDED，不能因此漏计同步编译时间。
	_profile_tracker.set_active(_application_active and not _application_suspended and page in [Page.ASSEMBLY, Page.PLAY])


## 前台页面累计时间独立于通关耗时，暂停、编辑器和选关也属于前台使用。
func _process(delta: float) -> void:
	_sync_activity_timer()
	if _activity_tracker == null or _closing:
		return
	_activity_save_elapsed += delta
	if _activity_save_elapsed >= ACTIVITY_SAVE_INTERVAL:
		_activity_save_elapsed = 0.0
		_flush_activity_statistics()


## 所有设置子页和主菜单排除；彩蛋完成淡入后覆盖设置页，按实际前台内容计时。
func _sync_activity_timer() -> void:
	if _activity_tracker == null:
		return
	var was_active := _activity_tracker.is_active()
	var content_active := page not in [Page.MAIN, Page.SETTINGS, Page.CODE_COLORS, Page.PLAYER_LEVEL_LIST, Page.PLAYER_PROFILE]
	if is_instance_valid(shark_game) and shark_game.is_visible_in_tree() and not _shark_entry_pending:
		content_active = true
	var active := _runtime_storage_ready and startup_complete and not _closing and _application_active and not _application_suspended and not _is_activity_window_minimized() and content_active
	_activity_tracker.set_active(active)
	if was_active and not active:
		_activity_save_elapsed = 0.0
		_flush_activity_statistics()


## 独立查询最小化状态，未收到失焦通知的窗口仍停止计时，测试可覆盖系统边界。
func _is_activity_window_minimized() -> bool:
	return is_inside_tree() and get_window().mode == Window.MODE_MINIMIZED


## 定期、离开前台和退出时保存；写盘失败保留待存秒数，下一次边界或周期重试。
func _flush_activity_statistics() -> void:
	if not _runtime_storage_ready or profile == null or _activity_tracker == null:
		return
	var seconds := _activity_tracker.get_pending_seconds()
	if seconds > 0.0:
		var result := profile.record_play_time(seconds)
		if result.is_ok():
			_activity_tracker.acknowledge(seconds)
		else:
			_show_profile_save_error(result)
	_persist_shark_statistics()


## 首次进入与最高分一起保存；主动退出也保留新高，写盘失败由后续周期重试。
func _persist_shark_statistics() -> void:
	if not _runtime_storage_ready or profile == null:
		return
	if is_instance_valid(shark_game):
		_shark_best_score = maxi(_shark_best_score, shark_game.best_score)
		if shark_game.run != null:
			_shark_best_score = maxi(_shark_best_score, shark_game.run.score)
	if _shark_discovered and not bool(profile.get_statistics().get("shark_discovered", false)):
		_show_profile_save_error(profile.record_shark_discovery())
	if _shark_best_score > int(profile.get_statistics().shark_best_score):
		_show_profile_save_error(profile.record_shark_score(_shark_best_score))


## 单调墙钟只统计正式关卡的前台操作；失败后的修复仍继续，暂停和成功后停止。
func _sync_profile_timer() -> void:
	if _profile_tracker == null or not _profile_tracker.has_started() or session == null or _editor_playtest:
		return
	if _profile_tracker.is_completed() and session.state != GameSession.State.SUCCEEDED:
		_profile_tracker.begin_level(_application_active and not _application_suspended)
	var active := _application_active and not _application_suspended and page in [Page.ASSEMBLY, Page.PLAY] and session.state not in [GameSession.State.PAUSED, GameSession.State.SUCCEEDED]
	_profile_tracker.set_active(active)


## 来源域与地图 ID 共同标记首通；玩家移动文件不改变身份，也不会与同名教学关卡冲突。
func _profile_level_key() -> String:
	if session == null:
		return ""
	var source := session.level.source_path
	var domain := "tutorial" if source.begins_with("res://data/levels/") else "official" if source.begins_with("res://") else "player"
	return domain + ":" + session.level.id


## 只统计本关允许使用的帮助档，且会话内保留最高档，避免切低设置或写盘失败丢失记录。
func _profile_current_hint_mode() -> String:
	if session == null or not session.level.can_use_code_hints():
		return _profile_hint_mode
	var modes := ["none", "normal", "more"]
	if settings != null and modes.find(settings.code_hints) > modes.find(_profile_hint_mode):
		_profile_hint_mode = settings.code_hints
	return _profile_hint_mode


## 进入正式关卡及设置变化时保存帮助上限；模型合并既有档位，未变化时不会重复写盘。
func _remember_profile_hint_mode() -> void:
	if _editor_playtest or session == null or profile == null:
		return
	_show_profile_save_error(profile.record_level_hint_mode(_profile_level_key(), _profile_current_hint_mode()))


## 会话已保证失败信号只发一次；预览校验、主动停止与编辑器试玩不进入统计。
func _on_profile_attempt_failed() -> void:
	if not _editor_playtest and session != null and profile != null:
		_show_profile_save_error(profile.record_failure(_profile_level_key(), _profile_current_hint_mode()))


## 只有真正插入提示代码才累计一次；无提示、被取消及撤销提示均不补记。
func _on_profile_code_hint_used() -> void:
	if not _editor_playtest and session != null and profile != null:
		_show_profile_save_error(profile.record_hint_use())


## 统计写盘问题以现有状态区反馈，不能打断模拟或伪造失败/通关结果。
func _show_profile_save_error(result: DataResult) -> void:
	if result.is_ok():
		return
	if is_instance_valid(_save_label):
		_save_label.text = tr("玩家统计保存失败") + "：" + GameI18n.translate_errors(result.errors)
		_save_label.show()


## 外壳释放也停止墙钟，不将离开游戏后的等待计入下一次挑战。
func _exit_tree() -> void:
	_closing = true
	_sync_activity_timer()
	_flush_activity_statistics()
	if _profile_tracker != null:
		_profile_tracker.end_level()


## 通关只写独立进度标记，并保留玩家刚刚成功的程序与装配。
func _on_level_completed() -> void:
	if _editor_playtest:
		return
	var statistics_result: DataResult
	if _profile_tracker != null and not _profile_tracker.is_completed():
		statistics_result = profile.record_completion(_profile_tracker.complete(), _profile_level_key(), _profile_current_hint_mode(), session.total_enemy_count())
	_save_current_draft(true)
	var marked := drafts.mark_completed(session.level.id)
	if not marked.is_ok():
		_show_message("通关记录保存失败", "你已完成关卡，但进度未能写入磁盘。\n" + "\n".join(marked.errors))
	if session.level.can_use_code_hints() and _hint_progress_key() != session.level.id:
		var hint_saved := drafts.save_failure_streak(_hint_progress_key(), 0)
		if not hint_saved.is_ok():
			_save_label.text = tr("提示记录保存失败") + "：" + GameI18n.translate_errors(hint_saved.errors)
			_save_label.show()
	if statistics_result != null:
		_show_profile_save_error(statistics_result)


## 返回前保存游戏草稿；地图编辑器的未保存更改则走单独确认流程。
func _back_to_levels() -> void:
	if not _save_current_draft():
		return
	_clear_page()
	catalog.refresh(registry)
	_show_level_page()


## 地图编辑器只负责编辑并发出试玩请求，页面切换和游戏会话由外层承接。
func _open_editor(initial_path: String = "", return_to_player_list: bool = false) -> void:
	if not _ensure_player_storage(_open_editor.bind(initial_path, return_to_player_list)):
		return
	_clear_page()
	_editor_returns_to_player_list = return_to_player_list
	_editor = MapEditor.new()
	_editor.initial_map_path = initial_path
	_editor.settings = settings
	_editor.default_creator = profile.get_username()
	_editor.player_levels_directory = catalog.user_directory
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.back_requested.connect(_go_back)
	_editor.playtest_requested.connect(_start_editor_playtest)
	_editor.save_finished.connect(_on_editor_save_finished)
	_body.add_child(_editor)
	_editor._level_guide_editor.link_opener = guide_link_opener
	if not initial_path.is_empty() and not _editor.initial_map_opened:
		var errors := _editor.initial_map_error.duplicate()
		_return_from_map_editor()
		_show_message("无法打开关卡", GameI18n.translate_errors(errors))
		return
	_show_editor_header()


## 新建或恢复编辑器时使用同一页头，恢复不重新加载地图或重建编辑控件。
func _show_editor_header() -> void:
	page = Page.EDITOR
	_header.hide()
	_back_button = _editor._header.back_button
	_save_label.hide()
	_save_label.tooltip_text = ""
	_layout_page_content()


## 用当前编辑快照进入与正式关卡相同的空装配流程，内容目录以编辑器为准。
func _start_editor_playtest(definition: LevelDefinition, content: ContentRegistry) -> void:
	if page != Page.EDITOR or _editor == null or _editor_playtest:
		return
	_save_timer.stop()
	_editor_playtest = true
	_program_editor_view.clear()
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
	_program_editor_view.clear()
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


## 自定义 Markdown 正文独立滚动，继续复用原生弹窗、翻页按钮和关闭行为。
func _build_markdown_dialogue() -> void:
	_dialogue_markdown = RichTextLabel.new()
	_dialogue_markdown.name = "PlayerGuideMarkdown"
	_dialogue_markdown.bbcode_enabled = false
	_dialogue_markdown.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_dialogue_markdown.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_markdown.fit_content = false
	_dialogue_markdown.scroll_active = true
	_dialogue_markdown.selection_enabled = true
	_dialogue_markdown.meta_clicked.connect(_open_player_guide_link)
	_dialogue_markdown.custom_minimum_size = Vector2(0, 220)
	_dialogue_markdown.hide()
	_dialogue_dialog.add_child(_dialogue_markdown)
	get_viewport().size_changed.connect(_resize_markdown_dialogue)


## 只有可见玩家引导中明确点击的 HTTP/HTTPS 链接才交给系统默认浏览器。
func _open_player_guide_link(meta: Variant) -> void:
	if not _dialogue_dialog.visible or not _dialogue_markdown.visible or not meta is String or not GuideMarkdown.is_web_url(meta):
		return
	var result: int = guide_link_opener.call(meta) if guide_link_opener.is_valid() else OS.shell_open(meta)
	if result != OK:
		_show_message("无法打开网页链接。", "无法打开网页链接。")


## 自定义长文只改变滚动区域大小，不把完整内容高度加入弹窗最小尺寸。
func _resize_markdown_dialogue() -> void:
	if not _dialogue_dialog.visible or not _dialogue_markdown.visible:
		return
	var available := get_viewport().get_visible_rect().size - Vector2(48, 96)
	_dialogue_dialog.popup_centered(Vector2i(Vector2(720, 440).min(available.max(Vector2(280, 280)))))


## 内置教学仍使用词典，玩家自己的说话人和正文始终保持地图原文。
func _dialogue_is_builtin() -> bool:
	return session != null and not _editor_playtest and session.level.source_path.begins_with("res://data/levels/")


## 仅重新格式化标题中的页面计数与内置说话人，语言切换不重置正文滚动。
func _update_dialogue_title() -> void:
	if session == null or _dialogue_index < 0 or _dialogue_index >= _dialogue_pages.size():
		return
	var line: Dictionary = _dialogue_pages[_dialogue_index]
	var speaker := str(line.get("speaker", "关卡说明"))
	if _dialogue_is_builtin() or _dialogue_index == _dialogue_system_index or not line.has("speaker") or (line.get("format") == "markdown" and speaker == "引导"):
		# 编辑器生成的固定页头随语言切换；自写说话人仍保持原文。
		speaker = tr(speaker)
	_dialogue_dialog.title = "%s · %d / %d" % [speaker, _dialogue_index + 1, _dialogue_pages.size()]


## 进入关卡时从第一页显示引导，玩家也可从页头重新打开查看。
func _show_dialogue() -> void:
	if is_instance_valid(workbench) and workbench._actions_menu != null:
		workbench._actions_menu.close_menu(false)
	if _command_menu != null:
		_command_menu.close_menu(false)
	if session == null:
		return
	_dialogue_pages.clear()
	_dialogue_system_index = -1
	# 空白页只在展示快照中跳过，兼容旧 JSON 并完整保留地图与编辑器中的原始数据。
	for line: Dictionary in session.level.document.dialogue:
		if not str(line.text).strip_edges().is_empty():
			_dialogue_pages.append(line.duplicate(true))
	# 程序说明来自运行权限，仅追加到展示快照，不能改写玩家地图的引导正文。
	_dialogue_system_index = _dialogue_pages.size()
	_dialogue_pages.append(WorkbenchProgramGuide.page(session.level))
	_dialogue_index = 0
	_display_dialogue_line()


## 显示当前页及页码；第一页禁用返回，最后一页仍可回看，确认才结束引导。
func _display_dialogue_line() -> void:
	if session == null:
		_dialogue_dialog.hide()
		return
	if _dialogue_pages.is_empty() or _dialogue_index >= _dialogue_pages.size():
		_dialogue_dialog.hide()
		return
	var line: Dictionary = _dialogue_pages[_dialogue_index]
	_update_dialogue_title()
	var markdown := str(line.get("format", "")) == "markdown"
	var plain := _dialogue_dialog.get_label()
	plain.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_INHERIT if _dialogue_is_builtin() or _dialogue_index == _dialogue_system_index else Node.AUTO_TRANSLATE_MODE_DISABLED
	# 保留原始 dialog_text 与 Label.text，旧教学测试和需要读取原文的工具不必改用排版后的文字。
	_dialogue_dialog.dialog_text = str(line.text)
	# AcceptDialog 即使隐藏内部Label也会参考其最小尺寸，限制隐藏副本行数避免长文撑高窗口。
	plain.max_lines_visible = 1 if markdown else -1
	plain.clip_text = markdown
	plain.visible = not markdown
	_dialogue_markdown.visible = markdown
	if markdown:
		GuideMarkdown.render(_dialogue_markdown, str(line.text))
		_dialogue_markdown.scroll_to_line(0)
	_dialogue_dialog.ok_button_text = "开始编辑" if _dialogue_index == _dialogue_pages.size() - 1 else "下一页"
	_dialogue_previous.disabled = _dialogue_index == 0
	if markdown:
		var available := get_viewport().get_visible_rect().size - Vector2(48, 96)
		_dialogue_dialog.popup_centered(Vector2i(Vector2(720, 440).min(available.max(Vector2(280, 280)))))
	else:
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
	# 通用弹窗独立于共享白卡，仅在设置页面继承其视觉比例，离开设置后恢复基准。
	var factor := 1.0
	if page in [Page.SETTINGS, Page.CODE_COLORS, Page.PLAYER_LEVEL_LIST, Page.PLAYER_PROFILE] and is_instance_valid(_menu_card):
		factor = float(_menu_card.get_meta("ui_menu_layout_scale", 1.0))
	_message_dialog.content_scale_factor = factor
	var available := (get_viewport_rect().size - Vector2(32, 32) * factor).max(Vector2.ONE)
	_message_dialog.popup_centered(Vector2i((Vector2(720, 310) * factor).min(available)))


## 颜色与显示属于设置子页，沿用返回药丸；只切换页面，不影响玩家作品。
func _show_code_colors_page() -> void:
	_clear_page(false, true)
	page = Page.CODE_COLORS
	_ensure_menu_card()
	_main_background.set_active(true)
	_set_level_navigation(true, "返回设置")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "设置"
	GameTheme.font_size(_title, "font_size", 22)
	_subtitle.hide()
	_save_label.hide()
	code_color_panel = CodeColorPanel.new()
	code_color_panel.settings = settings
	code_color_panel.card_boundary = _menu_card
	code_color_panel.navigation_title = _title
	code_color_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_card.add_child(code_color_panel)
	code_color_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_attach_settings_header()


## 玩家档案作为设置子页共用白卡、渐隐和导航，数据只读注入的独立模型。
func _show_player_profile_page() -> void:
	if not _ensure_runtime_storage(_show_player_profile_page):
		return
	_clear_page(false, true)
	# 每次进入按当前版本实际可用目录计算教学进度，新增关卡不需要迁移玩家档案。
	catalog.refresh(registry)
	page = Page.PLAYER_PROFILE
	_ensure_menu_card()
	_main_background.set_active(true)
	_set_level_navigation(true, "返回设置")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "玩家与统计信息"
	GameTheme.font_size(_title, "font_size", 22)
	_subtitle.hide()
	_save_label.hide()
	player_profile_panel = PlayerProfilePanel.new()
	player_profile_panel.name = "PlayerProfilePanel"
	player_profile_panel.profile = profile
	player_profile_panel.catalog = catalog
	player_profile_panel.drafts = drafts
	player_profile_panel.card_boundary = _menu_card
	player_profile_panel.navigation_title = _title
	player_profile_panel.reset_requested.connect(_request_profile_reset)
	_menu_card.add_child(player_profile_panel)
	player_profile_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_attach_settings_header()
	if not profile.last_error.is_empty():
		player_profile_panel.show_result(DataResult.failure(profile.last_error))


## 删除意图先记录当前档案身份，系统确认之前不修改用户名、UID 或任何文件。
func _request_profile_reset() -> void:
	if page != Page.PLAYER_PROFILE or not is_instance_valid(player_profile_panel) or _profile_reset_pending:
		return
	if not is_instance_valid(_profile_reset_dialog):
		_profile_reset_dialog = PlayerProfileResetDialog.new()
		_profile_reset_dialog.name = "PlayerProfileResetDialog"
		_profile_reset_dialog.native_dialog_handler = profile_native_dialog_handler
		_profile_reset_dialog.confirmed.connect(_confirm_profile_reset)
		_profile_reset_dialog.canceled.connect(_cancel_profile_reset)
		add_child(_profile_reset_dialog)
	_profile_reset_uid = profile.get_uid()
	_profile_reset_pending = true
	_profile_reset_dialog.open_confirmation()


## 取消或切换页面使待处理请求失效，迟到的系统回调不能清除新页面的档案。
func _cancel_profile_reset() -> void:
	_profile_reset_pending = false
	_profile_reset_uid = ""
	if is_instance_valid(_profile_reset_dialog):
		_profile_reset_dialog.close_dialog()


## 只消费一次当前身份的明确确认；原子替换后重新显示默认名字和新 UID。
func _confirm_profile_reset() -> void:
	if _closing or not _profile_reset_pending or page != Page.PLAYER_PROFILE or not is_instance_valid(player_profile_panel):
		return
	var expected_uid := _profile_reset_uid
	_cancel_profile_reset()
	if profile.get_uid() != expected_uid:
		player_profile_panel.show_result(DataResult.failure("玩家档案已变更，请重新打开删除确认。"))
		return
	var result := profile.reset_profile()
	if result.is_ok():
		_shark_best_score = 0
		_shark_discovered = false
		_activity_save_elapsed = 0.0
		if _activity_tracker != null:
			_activity_tracker.reset()
	player_profile_panel.show_result(result)


## 设置中的玩家文件管理页保留坏地图，使用独立列表诊断而不影响开始游戏的有效关卡。
func _show_player_level_list_page() -> void:
	_clear_page(false, true)
	page = Page.PLAYER_LEVEL_LIST
	_ensure_menu_card()
	_main_background.set_active(true)
	_set_level_navigation(true, "返回设置")
	_back_button.show()
	_help_button.hide()
	_refresh_button.hide()
	_title.text = "设置"
	GameTheme.font_size(_title, "font_size", 22)
	_subtitle.hide()
	_save_label.hide()
	player_level_list_panel = PlayerLevelListPanel.new()
	player_level_list_panel.name = "PlayerLevelListPanel"
	player_level_list_panel.card_boundary = _menu_card
	player_level_list_panel.navigation_title = _title
	player_level_list_panel.rename_requested.connect(_rename_player_entry)
	player_level_list_panel.delete_requested.connect(_delete_player_entry)
	player_level_list_panel.edit_requested.connect(_open_editor_from_player_entry)
	player_level_list_panel.open_folder_requested.connect(_open_player_entry_folder)
	player_level_list_panel.migration_requested.connect(_migrate_player_entry)
	_menu_card.add_child(player_level_list_panel)
	player_level_list_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_attach_settings_header()
	_refresh_player_level_list()


## 刷新文件快照并更新同一列表，让搜索和滚动由面板保留，旧菜单记录不再有修改权限。
func _refresh_player_level_list() -> void:
	if page != Page.PLAYER_LEVEL_LIST or not is_instance_valid(player_level_list_panel):
		return
	player_level_library.user_directory = catalog.user_directory
	player_level_library.legacy_directory = player_saves_source if legacy_upgrade != null and not _legacy_upgrade_state.get("retired", false) else ""
	player_level_library.migration_journal = player_saves_journal
	var result := player_level_library.refresh(registry)
	player_level_list_panel.set_entries(player_level_library.entries)
	if not result.is_ok():
		_show_message("无法读取玩家关卡列表", GameI18n.translate_errors(result.errors))


## 列表重命名仍只修改地图显示名；失败保留原位输入，不因错误跳出设置页。
func _rename_player_entry(entry: PlayerLevelRecord, new_name: String) -> void:
	if page != Page.PLAYER_LEVEL_LIST or not is_instance_valid(player_level_list_panel):
		return
	var result := player_level_library.rename_entry(entry, new_name, registry)
	if not result.is_ok():
		player_level_list_panel.show_entry_error(entry, result.errors)
		return
	catalog.refresh(registry)
	_refresh_player_level_list()


## 删除当前列表快照中的单个文件，损坏地图也可移除，但不触碰源导出文件或玩家记录。
func _delete_player_entry(entry: PlayerLevelRecord) -> void:
	if page != Page.PLAYER_LEVEL_LIST or not is_instance_valid(player_level_list_panel):
		return
	var result := player_level_library.delete_entry(entry)
	if not result.is_ok():
		player_level_list_panel.show_entry_error(entry, result.errors)
		return
	catalog.refresh(registry)
	_refresh_player_level_list()


## 文件管理器只打开已经重新确认归属的玩家目录，换页后的旧请求无效。
func _open_player_entry_folder(entry: PlayerLevelRecord) -> void:
	if page != Page.PLAYER_LEVEL_LIST or not is_instance_valid(player_level_list_panel):
		return
	var result := player_level_library.get_entry_directory(entry)
	if not result.is_ok():
		player_level_list_panel.show_entry_error(entry, result.errors)
		return
	var error: int = folder_opener.call(result.value) if folder_opener.is_valid() else OS.shell_open(result.value)
	if error != OK:
		player_level_list_panel.show_entry_error(entry, PackedStringArray([tr("无法打开文件夹：%s（%s）。") % [result.value, error_string(error)]]))


## 编辑前重新核对同一磁盘快照，编辑器以该托管路径打开并在返回时恢复玩家列表。
func _open_editor_from_player_entry(entry: PlayerLevelRecord) -> void:
	if page != Page.PLAYER_LEVEL_LIST or not is_instance_valid(player_level_list_panel):
		return
	var result := player_level_library.get_entry_edit_path(entry)
	if not result.is_ok():
		player_level_list_panel.show_entry_error(entry, result.errors)
		return
	_open_editor(result.value, true)


## 玩家列表打开的编辑任务沿原入口返回，主菜单和独立编辑器仍返回开始页。
func _return_from_map_editor() -> void:
	var return_to_list := _editor_returns_to_player_list
	_editor_returns_to_player_list = false
	if return_to_list:
		_show_player_level_list_page()
	else:
		_show_main_page()
