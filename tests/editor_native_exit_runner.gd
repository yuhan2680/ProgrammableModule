extends "res://tests/editor_exit_dialog_runner.gd"
## 原生窗口边界用可控系统替身验证，地图保存仍使用真实编辑器与隔离文件。

var _native_requests: Array[Dictionary] = []
var _native_result := OK
var _immediate_choice := -999
var _quit_count := 0


## 创建正常外壳，只替换需要人点击的操作系统窗口，不依赖真实玩家存档。
func _run() -> void:
	_temporary = "user://tests/editor_native_exit_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	_game = load("res://scenes/map_editor.tscn").instantiate()
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.drafts_directory = _temporary.path_join("drafts")
	_game.settings_path = _temporary.path_join("settings.json")
	_game.quit_handler = _record_quit
	root.add_child(_game)
	await _settle()
	_game._editor_discard_dialog.native_dialog_handler = _record_native
	await _test_native_question()
	await _test_native_results()
	await _test_native_fallback()
	await _test_native_window_close()
	_game.queue_free()
	await _settle()
	_cleanup(_temporary)
	print("EDITOR_NATIVE_EXIT_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 系统只接收已本土化文本与回调；同步返回也必须延后执行保存与页面跳转。
func _record_native(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_native_requests.append({"title": title, "description": description, "buttons": buttons, "callback": callback})
	if _immediate_choice != -999:
		callback.call(_immediate_choice)
	return _native_result


## 记录真实外壳的退出意图，回归不得退出自己的引擎进程。
func _record_quit() -> void:
	_quit_count += 1


## 回复最近一次系统询问并等待生产回调经过延迟分派。
func _reply(choice: int) -> void:
	_native_requests[-1].callback.call(choice)
	await _settle()


## 三种语言与原始地图名传入系统，编辑器输入被拦截且重复返回不会再开弹窗。
func _test_native_question() -> void:
	for locale in ["zh_CN", "zh_HK", "en"]:
		await _fixture()
		_game.settings.set_language(locale)
		await _settle()
		var model := _editor.editor_document
		_editor._name_field.grab_focus()
		_editor._name_field.text = "Map原始名称_测试"
		_game._go_back()
		var dialog := _game._editor_discard_dialog
		var request: Dictionary = _native_requests[-1]
		_check(dialog.visible and dialog._native_active and not dialog._layer.visible, "原生询问期间保留逻辑模态但不绘制游戏玻璃弹窗 " + locale)
		_check(request.description.contains("Map原始名称_测试") and request.description.contains("\n") and model.document.display_name == "Map原始名称_测试", "原生询问采用待提交名称并分行说明丢失更改 " + locale)
		_check(request.buttons == PackedStringArray([dialog.tr("保存"), dialog.tr("不保存"), dialog.tr("取消")]) and request.title == dialog.tr("保存地图更改？"), "系统按钮及标题按游戏语言翻译 " + locale)
		var before := _signature(model)
		var history := model._undo_stack.size()
		var count := _native_requests.size()
		_game._go_back()
		_click(_cell_point(Vector2i.ZERO), MOUSE_BUTTON_RIGHT)
		_key(KEY_Z, true)
		_key(KEY_ENTER)
		await _settle()
		_check(_native_requests.size() == count and dialog.visible and _signature(model) == before and model._undo_stack.size() == history, "原生期间重复返回及游戏输入不修改地图或误选按钮 " + locale)
		await _reply(2)
		_check(not dialog.visible and not dialog._native_active and _game.page == GameShell.Page.EDITOR and _signature(model) == before and model.is_dirty(), "系统取消保留编辑器与全部修改 " + locale)
	_game.settings.set_language("zh_CN")


## 保存成功、放弃、关闭及迟到回调沿用同一文档保护，不凭选择按钮就认为已写盘。
func _test_native_results() -> void:
	await _fixture(_temporary.path_join("native_existing.json"))
	var model := _editor.editor_document
	var before := _signature(model)
	var history := model._undo_stack.size()
	_game._go_back()
	var obsolete: Callable = _native_requests[-1].callback
	await _reply(-1)
	_check(_game.page == GameShell.Page.EDITOR and model.is_dirty() and _signature(model) == before and model._undo_stack.size() == history, "未知或关闭系统窗口的结果视为取消")
	_game._go_back()
	obsolete.call(1)
	await _settle()
	_check(_game._editor_discard_dialog.visible and _game.page == GameShell.Page.EDITOR, "上一次询问的迟到放弃回调不能影响新询问")
	await _reply(0)
	_check(_game.page == GameShell.Page.MAIN and not model.is_dirty() and FileAccess.file_exists(model.path), "原生保存分支经过真实托管写盘后才返回")
	var saved := MapCodec.load_file(model.path, _game.registry, false)
	_check(saved.is_ok() and JSON.parse_string(JSON.stringify(saved.value.to_dict(), "", true)) == JSON.parse_string(before), "原生保存包含当前全部地图内容")
	await _fixture(_temporary.path_join("native_discard.json"))
	model = _editor.editor_document
	var baseline := FileAccess.get_file_as_string(model.path)
	_game._go_back()
	await _reply(1)
	_check(_game.page == GameShell.Page.MAIN and FileAccess.get_file_as_string(_temporary.path_join("native_discard.json")) == baseline, "原生不保存分支不覆盖外部原件")
	await _fixture()
	model = _editor.editor_document
	before = _signature(model)
	history = model._undo_stack.size()
	var blocked := _temporary.path_join("native_blocked")
	var file := FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("retain")
	file.close()
	_editor.player_levels_directory = blocked.path_join("levels")
	_game._go_back()
	await _reply(0)
	_check(_game.page == GameShell.Page.EDITOR and not _game._editor_exit_save_pending and _editor._message_dialog.visible and model.is_dirty(), "原生保存失败保留编辑器并清除退出请求")
	_check(_signature(model) == before and model._undo_stack.size() == history and model.path.is_empty() and FileAccess.get_file_as_string(blocked) == "retain", "原生保存失败不改文档、历史、路径或旧文件")
	_editor._message_dialog.hide()
	_editor.player_levels_directory = _game.user_levels_directory
	_editor._save_document(false)
	await _settle()
	_check(_game.page == GameShell.Page.EDITOR and not model.is_dirty(), "失败后普通保存不意外退出")


## 系统接口失败回退到既有保护，失败调用的晚回调不能绕过后备确认。
func _test_native_fallback() -> void:
	await _fixture()
	_native_result = ERR_UNAVAILABLE
	_game._go_back()
	await _settle()
	var dialog := _game._editor_discard_dialog
	_check(dialog.visible and not dialog._native_active and dialog._layer.visible and dialog.get_cancel_button().has_focus(), "原生接口失败自动使用安全的玻璃后备窗口")
	_native_requests[-1].callback.call(1)
	await _settle()
	_check(dialog.visible and _game.page == GameShell.Page.EDITOR, "系统调用失败后的迟到回调不能放弃草稿")
	_click(dialog._cancel_button.get_global_rect().get_center())
	await _settle()
	_native_result = OK
	_immediate_choice = 2
	_game._go_back()
	_check(dialog.visible and _game.page == GameShell.Page.EDITOR, "系统同步回调不会在原生调用栈中跳转页面")
	await _settle()
	_check(not dialog.visible and _game.page == GameShell.Page.EDITOR, "系统同步取消回调延后正常执行")
	_immediate_choice = -999


## 关闭游戏也走三选项保护；取消和失败清除关闭意图，成功保存后才请求进程退出。
func _test_native_window_close() -> void:
	await _fixture()
	var model := _editor.editor_document
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_game._editor_discard_dialog._native_active and _game._editor_exit_quit_requested and not _editor._dirty_dialog.visible, "关闭窗口采用同一个原生保存询问")
	await _reply(2)
	_check(_quit_count == 0 and not _game._editor_exit_quit_requested and _game.page == GameShell.Page.EDITOR and model.is_dirty(), "取消关闭游戏保留草稿并撤销关闭意图")
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _reply(0)
	_check(_quit_count == 1 and not model.is_dirty() and FileAccess.file_exists(model.path), "关闭游戏选择保存必须写盘成功才发出退出")
	_game._closing = false
	await _fixture()
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _reply(1)
	_check(_quit_count == 2 and _editor.editor_document.path.is_empty() and _editor.editor_document.is_dirty(), "关闭游戏选择不保存直接退出且不写草稿")
	_game._closing = false
	await _fixture()
	model = _editor.editor_document
	var blocked := _temporary.path_join("close_blocked")
	var file := FileAccess.open(blocked, FileAccess.WRITE)
	file.store_string("retain")
	file.close()
	_editor.player_levels_directory = blocked.path_join("levels")
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	await _reply(0)
	_check(_quit_count == 2 and not _game._editor_exit_quit_requested and not _game._closing and model.is_dirty(), "关闭窗口时保存失败不能退出且清除关闭意图")
	_editor._message_dialog.hide()
	_editor.player_levels_directory = _game.user_levels_directory
	_editor._save_document(false)
	await _settle()
	_check(_quit_count == 2 and _game.page == GameShell.Page.EDITOR and not model.is_dirty(), "关闭保存失败后的普通保存成功仍保留编辑页面")
	var count := _native_requests.size()
	_game._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check(_quit_count == 3 and _native_requests.size() == count, "已保存干净地图关闭无需再次询问")
	_game._closing = false
