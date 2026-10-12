extends SceneTree
## 清除预设进度的原生询问使用系统替身，实际删除仅作用于独占测试存档。

var _checks := 0
var _failures := 0
var _temporary := ""
var _game: GameShell
var _callbacks: Array[Callable] = []
var _requests: Array[Dictionary] = []
var _native_result := OK
var _quit_count := 0
var _builtin_id := ""


## 延后到场景树可添加节点时开始，避免初始化期间访问真实玩家资料。
func _initialize() -> void:
	_run.call_deferred()


## 实际外壳覆盖取消、默认确认、失效响应、原生失败后备以及清除范围不变。
func _run() -> void:
	_temporary = "user://tests/clear_progress_native_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	_game = GameShell.new()
	_game.settings_path = _temporary.path_join("settings.json")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.clear_progress_native_dialog_handler = _show_native
	_game.quit_handler = _record_quit
	root.add_child(_game)
	await _settle()
	_builtin_id = _game.catalog.levels[0].id
	_write_builtin()
	_check(_game.drafts.save_draft("player_fixture", "main() {}", []).is_ok(), "创建玩家关卡代码夹具")
	var user_draft := _game.drafts._path("player_fixture", "draft")
	var user_before := FileAccess.get_file_as_bytes(user_draft)
	var profile_before := FileAccess.get_file_as_bytes(_game.profile.storage_path)
	_game._show_settings_page()
	await _settle()
	_check(_game.settings_panel.find_child("ClearUserLevelsButton", true, false) == null, "设置移除批量清除用户关卡按钮")
	_check(not _game.has_method("_request_clear_user_levels"), "外壳不再暴露批量清除用户关卡路由")
	var dialog := _game._clear_progress_dialog
	for choice in [0, -1, 3]:
		_game._request_clear_progress()
		_check(dialog.is_open() and dialog._native_active and not dialog._overlay.visible, "优先显示原生询问且不叠加后备卡片")
		var request: Dictionary = _requests.back()
		_check(request.buttons.size() == 2 and request.buttons[0] == _game.tr("取消") and request.buttons[1] == _game.tr("清除"), "原生默认首项为取消，仅第二项表示清除")
		_check(request.title == _game.tr("清除预设进度") and request.description == _game.tr(ClearProgressDialog.WARNING_BODY), "原生询问沿用完整清除范围说明")
		var count := _callbacks.size()
		_game._request_clear_progress()
		_game._go_back()
		_check(_callbacks.size() == count and _game.page == GameShell.Page.SETTINGS, "原生询问期间重复点击和返回不发起新操作")
		_callbacks.back().call(choice)
		await _settle()
		_check(not dialog.is_open() and not _game._clear_progress_pending and _game.drafts.is_completed(_builtin_id), "取消、系统关闭及未知响应都保留进度")
		_callbacks.back().call(1)
		await _settle()
		_check(_game.drafts.is_completed(_builtin_id), "取消后迟到确认无法重放")
	_game._request_clear_progress()
	var old_callback: Callable = _callbacks.back()
	_game._show_main_page()
	old_callback.call(1)
	await _settle()
	_check(_game.drafts.is_completed(_builtin_id) and not dialog.is_open(), "强制导航后旧系统响应不能清除")
	_game._show_settings_page()
	await _settle()
	_game._request_clear_progress()
	old_callback.call(1)
	await _settle()
	_check(dialog.is_open() and _game.drafts.is_completed(_builtin_id), "上一代响应不能确认新一代询问")
	_callbacks.back().call(1)
	await _settle()
	_check(not _game.drafts.is_completed(_builtin_id) and _game.drafts.load_draft(_builtin_id).value == null, "当前原生明确确认清除预设通关与代码装配记录")
	_check(FileAccess.get_file_as_bytes(user_draft) == user_before and FileAccess.get_file_as_bytes(_game.profile.storage_path) == profile_before, "预设清除不改变玩家关卡草稿或玩家档案")
	_write_builtin()
	_callbacks.back().call(1)
	await _settle()
	_check(_game.drafts.is_completed(_builtin_id), "重复系统确认不能清除后来产生的新记录")
	_game._request_clear_progress()
	var original_directory := _game.drafts.directory
	_game.drafts.directory = _temporary.path_join("changed_solutions")
	_callbacks.back().call(1)
	await _settle()
	_game.drafts.directory = original_directory
	_check(_game.drafts.is_completed(_builtin_id) and _game.settings_panel._status.visible, "询问期间目录变化拒绝删除并显示错误")
	_native_result = ERR_UNAVAILABLE
	_game._request_clear_progress()
	await _settle()
	_check(dialog.is_open() and not dialog._native_active and dialog._overlay.visible and dialog._cancel.has_focus(), "原生失败回退单层圆角卡片并聚焦取消")
	_callbacks.back().call(1)
	await _settle()
	_check(dialog.is_open() and _game.drafts.is_completed(_builtin_id), "原生失败后的迟到确认不能穿透后备询问")
	dialog._cancel_requested()
	await _settle()
	_check(not dialog.is_open() and _game.drafts.is_completed(_builtin_id), "后备取消同样保留记录")
	_native_result = OK
	_game._request_clear_progress()
	_game._leave_game()
	_callbacks.back().call(1)
	await _settle()
	_check(_quit_count == 1 and not dialog.is_open() and _game.drafts.is_completed(_builtin_id), "退出游戏撤销询问，迟到响应不改变档案")
	_game.queue_free()
	await _settle()
	_remove_directory(_temporary)
	print("预设进度原生确认回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 仅记录系统询问参数和回调，返回可控结果而不打开真实桌面弹窗。
func _show_native(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_requests.append({"title": title, "description": description, "buttons": buttons})
	_callbacks.append(callback)
	return _native_result


## 每轮确认前写入一份真实预设记录，验证不是只检查内部状态标志。
func _write_builtin() -> void:
	_check(_game.drafts.save_draft(_builtin_id, "main() {}", []).is_ok() and _game.drafts.mark_completed(_builtin_id).is_ok(), "创建预设关卡代码与完成夹具")


## 退出替身只累加次数，保证生命周期回归不关闭测试宿主。
func _record_quit() -> void:
	_quit_count += 1


## 等待布局、信号及延后原生选择完成，避免测试与事件队列竞争。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 统一报告断言，不在首个失败处中断后续安全边界覆盖。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL " + message)


## 仅递归清理本次生成的测试目录，不接受真实用户位置。
func _remove_directory(path: String) -> void:
	if not path.begins_with("user://tests/clear_progress_native_"):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file in directory.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for folder in directory.get_directories():
		_remove_directory(path.path_join(folder))
	DirAccess.remove_absolute(path)
