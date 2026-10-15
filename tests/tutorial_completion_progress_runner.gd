extends "res://tests/window_resolution_ui_runner.gd"
## 教学完成度读取当前目录与独立通关标记，真实页面和存档均使用测试专属目录。

class MemoryDraftStore extends GameDraftStore:
	## 大目录的四舍五入边界仅替换只读查询，避免生成数千个测试文件。
	func is_completed(level_id: String) -> bool:
		return level_id != "last_pending"

var _original_levels: Array[LevelDefinition] = []


## 真实设置入口、升级目录、错误存档和首次完整通关共同验证动态百分比与样式。
func _run() -> void:
	_temporary = "user://tests/tutorial_progress_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_game.settings.set_window_resolution("1280x800")
	_game.settings.set_ui_scale(100)
	_game.settings.set_language("zh_CN")
	await _settle(12)
	if not await _open_settings():
		await _dispose_game()
		_finish()
		return
	var entry := _game.settings_panel.find_child("PlayerProfileButton", true, false) as Button
	await _click(entry)
	await _settle(12)
	if not _check(_game.page == GameShell.Page.PLAYER_PROFILE, "真实设置入口打开玩家资料"):
		await _dispose_game()
		_finish()
		return
	_original_levels = _game.catalog.levels.duplicate()
	_check(not _original_levels.is_empty(), "当前版本加载真实教学目录")
	_check(_game.player_profile_panel.catalog == _game.catalog and _game.player_profile_panel.drafts == _game.drafts, "面板使用外壳同一目录与通关存储")
	_check_row_order()
	_expect("0%", false, "没有已通关的教学记录")
	await _capture("tutorial_progress_0_zh_CN")
	await _check_catalog_changes()
	await _check_invalid_progress()
	await _check_language_and_reload()
	await _check_playtest_isolation()
	await _check_empty_and_rounding()
	await _dispose_game()
	_finish()


## 四类玩家持久文件全部注入独占目录，不读取或覆盖现有玩家档案。
func _create_game() -> void:
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("profile.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle(12)


## 完成度应当是统计首项，右侧值沿用普通统计字号和对齐方式。
func _check_row_order() -> void:
	var panel := _game.player_profile_panel
	var row := panel.find_child("PlayerTutorialProgressRow", true, false) as MarginContainer
	var hints := panel.find_child("PlayerHintsRow", true, false) as MarginContainer
	_check(row != null and hints != null and row.get_index() == 0 and hints.get_index() == row.get_index() + 2, "教学完成进度位于提示次数之前且只隔一条分隔线")
	_check(panel._tutorial_progress_value.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT and panel._tutorial_progress_value.get_theme_font_size("font_size") == panel._hint_value.get_theme_font_size("font_size"), "完成度保持右对齐并沿用统计字号")


## 当前全部完成、添加新关及移除旧关时重新计算，玩家与过期记录不会增加进度。
func _check_catalog_changes() -> void:
	var ids := _tutorial_ids()
	for level_id in ids:
		_check(_game.drafts.mark_completed(level_id).is_ok(), "保存真实教学通关标记 " + level_id)
	_game.player_profile_panel.refresh_tutorial_progress()
	await _settle()
	_expect("100%", true, "当前目录全部通关")
	await _capture("tutorial_progress_100_zh_CN")
	var profile_bytes := FileAccess.get_file_as_bytes(_game.profile_path)
	var next := _level("next_version_tutorial", "res://data/levels/next_version_tutorial.json")
	_game.catalog.levels.append(next)
	_game.player_profile_panel.refresh_tutorial_progress()
	await _settle()
	_expect(_percentage(ids.size(), ids.size() + 1), false, "新版加入未通关教学后自动降低百分比并恢复普通字色字重")
	await _capture("tutorial_progress_new_level_zh_CN")
	var player := _level("map_0255413726", _temporary.path_join("levels/player.json"))
	_game.catalog.levels.append(player)
	_check(_game.drafts.mark_completed(player.id).is_ok() and _game.drafts.mark_completed("removed_tutorial").is_ok(), "准备玩家地图和已下架教学的通关记录")
	_game.catalog.levels.append(_original_levels[0])
	_game.catalog.levels.append(null)
	_game.player_profile_panel.refresh_tutorial_progress()
	_expect(_percentage(ids.size(), ids.size() + 1), false, "重复 ID、空项、玩家关卡及过期通关记录不影响当前教学比例")
	_check(FileAccess.get_file_as_bytes(_game.profile_path) == profile_bytes, "目录刷新不向玩家档案写入缓存百分比或总关卡数")
	_game.catalog.levels.erase(next)
	_game.player_profile_panel.refresh_tutorial_progress()
	_expect("100%", true, "撤下尚未完成的教学后按仍在目录的关卡恢复完整进度")
	_game.catalog.levels.assign(_original_levels)


## 缺失、格式错误和内容不匹配的通关记录都不能使界面误判已完成，读取不得改写原件。
func _check_invalid_progress() -> void:
	var first := _original_levels[0].id
	var path := _game.drafts._path(first, "progress")
	_check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK, "移除独占目录中的一个教学标记")
	_game.player_profile_panel.refresh_tutorial_progress()
	_expect(_percentage(_tutorial_ids().size() - 1, _tutorial_ids().size()), false, "缺失标记未完成")
	for contents: String in ["{broken-json", JSON.stringify({"format_version": 1, "level_id": first, "completed": "true"}), JSON.stringify({"format_version": 1, "level_id": "wrong_id", "completed": true}), JSON.stringify({"format_version": 9, "level_id": first, "completed": true})]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(contents)
		file.close()
		_game.player_profile_panel.refresh_tutorial_progress()
		_expect(_percentage(_tutorial_ids().size() - 1, _tutorial_ids().size()), false, "无效通关文件不计入")
		_check(FileAccess.get_file_as_string(path) == contents, "统计只读查询保留无效文件原始内容")
	_check(_game.drafts.mark_completed(first).is_ok(), "恢复有效教学记录")
	_game.player_profile_panel.refresh_tutorial_progress()
	_expect("100%", true, "有效记录恢复完整进度")


## 重新进入与更换语言沿用磁盘事实，统计刷新不会覆盖正在编辑的用户名。
func _check_language_and_reload() -> void:
	var panel := _game.player_profile_panel
	panel._username_field.text = "Typing"
	panel._username_field.text_changed.emit("Typing")
	panel.refresh_tutorial_progress()
	_check(panel._username_field.text == "Typing" and _game.profile.get_username() == "Player", "完成度刷新不覆盖尚未提交的用户名")
	panel.commit_username()
	_game.catalog.levels.clear()
	_game._show_player_profile_page()
	await _settle(12)
	_expect("100%", true, "重新进入会重新加载当前版本目录而非沿用失效目录缓存")
	_check(_game.catalog.levels.size() == _original_levels.size(), "重新进入重建实际可用关卡集合")
	for locale: String in ["zh_CN", "zh_HK", "es", "en"]:
		_game.settings.set_language(locale)
		await _settle(12)
		var row := _game.player_profile_panel.find_child("PlayerTutorialProgressRow", true, false) as MarginContainer
		var caption := (row.get_child(0) as HBoxContainer).get_child(0) as Label
		var translated := caption.tr(caption.text)
		_check(not translated.is_empty() and (locale == "zh_CN" or translated != "教学关卡完成进度"), "新增统计标题有当前语言翻译 " + locale)
		_expect("100%", true, "切换语言保持完成状态 " + locale)
		if locale == "zh_HK":
			await _capture("tutorial_progress_100_zh_HK")
	_game.settings.set_language("zh_CN")
	await _settle()


## 编辑器试玩沿用完成信号的隔离分支，即便 ID 与正式教学一致也不能写入教学进度。
func _check_playtest_isolation() -> void:
	var ids := _tutorial_ids()
	_check(_game.drafts.clear_level_records(ids).is_ok(), "只清除独占目录中本轮教学记录")
	_game._open_editor()
	await _settle(12)
	_game._start_editor_playtest(_original_levels[0], _game.registry)
	await _settle(8)
	_check(_game._editor_playtest and _game.session != null, "编辑器测试使用正常临时组装会话")
	_game._dialogue_dialog.hide()
	_game.session.completed.emit()
	_check(not _game.drafts.is_completed(_original_levels[0].id), "试玩完成信号不写同 ID 正式教学进度")
	_game._return_to_editor()
	_game._show_player_profile_page()
	await _settle(12)
	_expect("0%", false, "试玩返回后教学完成度仍然为零")


## 空目录、缺失依赖与临近百分之百的大目录不会显示伪完成或残留红色粗体。
func _check_empty_and_rounding() -> void:
	var panel := _game.player_profile_panel
	_game.catalog.levels.clear()
	panel.refresh_tutorial_progress()
	_expect("0%", false, "空教学目录显示零进度")
	panel.catalog = null
	panel.refresh_tutorial_progress()
	_expect("—", false, "未注入目录不猜测完成度")
	panel.catalog = _game.catalog
	panel.drafts = null
	panel.refresh_tutorial_progress()
	_expect("—", false, "未注入通关存储不猜测完成度")
	panel.drafts = MemoryDraftStore.new()
	for index in range(2000):
		_game.catalog.levels.append(_level("large_%d" % index, "res://data/levels/large_%d.json" % index))
	_game.catalog.levels.append(_level("last_pending", "res://data/levels/last_pending.json"))
	panel.refresh_tutorial_progress()
	_expect("99.9%", false, "大量教学尚有一关未完成也不能四舍五入显示完整进度")
	panel.drafts = _game.drafts
	_game.catalog.levels.assign(_original_levels)


## 合成未来版本目录项仅在内存存在，不写入资源目录或真实教学文件。
func _level(level_id: String, path: String) -> LevelDefinition:
	var definition := LevelDefinition.new()
	definition.id = level_id
	definition.source_path = path
	return definition


## 测试期望根据实际加载教学计算，增加正式关卡后无需把总数硬编码到回归中。
func _tutorial_ids() -> Array[String]:
	var ids: Array[String] = []
	for definition in _original_levels:
		if definition.source_path.begins_with("res://data/levels/") and not ids.has(definition.id):
			ids.append(definition.id)
	return ids


## 格式断言兼顾完整整数与一位小数，测试数据不受其他统计权重影响。
func _percentage(completed: int, total: int) -> String:
	return ("%.1f" % (100.0 * completed / total)).trim_suffix(".0") + "%"


## 同时检查文本、字体轴和颜色，尤其验证从完成状态下降后移除旧粗体覆盖。
func _expect(text: String, complete: bool, context: String) -> void:
	var value := _game.player_profile_panel._tutorial_progress_value
	_check(value.text == text, "%s：显示 %s，实际 %s" % [context, text, value.text])
	_check(value.get_theme_color("font_color") == (Color("ff2020") if complete else GameTheme.TEXT), context + " 字色准确")
	_check(value.has_theme_font_override("font") == complete, context + " 只在完整通关时覆盖粗体")
	if complete:
		var font := value.get_theme_font("font") as FontVariation
		var axis := TextServerManager.get_primary_interface().name_to_tag("wght")
		_check(font != null and is_equal_approx(float(font.variation_opentype.get(axis, 0.0)), 700.0), context + " 使用真实 700 字重而非放大字号")


## 恢复进程设置并删除独占测试目录，给出可供命令行核对的结束标记。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	TranslationServer.set_locale(_original_locale)
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, _original_volume)
	AudioServer.set_bus_mute(master, _original_mute)
	_remove_tree(_temporary)
	print("TUTORIAL_COMPLETION_PROGRESS_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
