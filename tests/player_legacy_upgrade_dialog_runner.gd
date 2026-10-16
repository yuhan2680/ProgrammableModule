extends SceneTree
## 升级询问只验证选择与模态边界，不创建、迁移或删除任何玩家关卡。

const UpgradeDialog = preload("res://scripts/ui/player_legacy_upgrade_dialog.gd")
const EXPECTED_WARNING := "发现%d个位于旧目录的关卡文件，点击下方按钮后可前往“关卡列表”完成迁移。若选择删除，则所有旧目录中的关卡都将被删除，此操作无法撤销。"
const OLD_DIRECTORY := "/Users/Test 玩家/Library/Application Support/Godot/app_userdata/ProgrammableModule/levels"

var _checks := 0
var _failures := 0
var _fixture: Control
var _origin: Button
var _dialog: Control
var _requests: Array[Dictionary] = []
var _choices: Array[Dictionary] = []
var _native_result := OK
var _immediate_choice := -999


## 等场景树准备后构造系统替身，测试不会显示真实原生弹窗。
func _initialize() -> void:
	_run.call_deferred()


## 覆盖原生默认取消、明确选择、过期响应和可交互后备，不参与提醒次数持久化。
func _run() -> void:
	var previous_locale := TranslationServer.get_locale()
	GameI18n.install()
	TranslationServer.set_locale("zh_CN")
	root.size = Vector2i(960, 720)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	_fixture = Control.new()
	_fixture.theme = GameTheme.create_theme()
	root.add_child(_fixture)
	_fixture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_origin = GameTheme.button(_fixture, "原页面入口", func() -> void: pass)
	_origin.position = Vector2(20, 20)
	_origin.size = Vector2(150, 44)
	_dialog = UpgradeDialog.new()
	_dialog.native_dialog_handler = _record_native
	_dialog.migrate_requested.connect(_record_choice.bind("migrate"))
	_dialog.discard_requested.connect(_record_choice.bind("discard"))
	_dialog.canceled.connect(_record_choice.bind("cancel"))
	_fixture.add_child(_dialog)
	await _settle()
	await _test_native_cancel()
	await _test_native_choices()
	await _test_frozen_actions()
	await _test_stale_callbacks()
	await _test_fallback()
	await _test_localization()
	_fixture.queue_free()
	await _settle()
	TranslationServer.set_locale(previous_locale)
	print("旧关卡升级提示界面回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 系统接口记录完整本土化参数，并允许模拟立即回调或不可用错误。
func _record_native(title: String, description: String, buttons: PackedStringArray, callback: Callable) -> int:
	_requests.append({"title": title, "description": description, "buttons": buttons, "callback": callback})
	if _immediate_choice != -999:
		callback.call(_immediate_choice)
	return _native_result


## 记录意图发出时的模态状态，确保外壳可以安全打开迁移页面或进行后续操作。
func _record_choice(action: String) -> void:
	_choices.append({"action": action, "open": _dialog.is_open()})


## 两个平台的关闭和未知索引都不等价于删除，重复打开保持原请求数据。
func _test_native_cancel() -> void:
	_check(UpgradeDialog.WARNING_BODY == EXPECTED_WARNING, "提示采用精简正文且仅包含数量占位符")
	for platform in ["macOS", "Windows"]:
		_dialog.platform_name = platform
		var canceled_indices := [0, -1, 3, 99] if platform == "macOS" else [-1, 2, 99]
		for index in canceled_indices:
			_origin.grab_focus()
			_dialog.open_confirmation(OLD_DIRECTORY, 7)
			var request: Dictionary = _requests.back()
			_check(_dialog.is_open() and _dialog._native_active and not _dialog._fallback.visible, "原生询问不叠加后备窗口：" + platform)
			var expected := PackedStringArray(["忽略", "前往迁移", "删除"]) if platform == "macOS" else PackedStringArray(["前往迁移", "删除"])
			_check(request.title == "旧关卡迁移" and request.buttons == expected, "原生按钮按平台精简且删除不是默认首项：" + platform)
			_check(request.description == EXPECTED_WARNING % 7 and not request.description.contains(OLD_DIRECTORY), "精简说明包含实际数量与删除警告，不展示旧路径：" + platform)
			var request_count := _requests.size()
			_dialog.open_confirmation("/changed", 99)
			_check(_requests.size() == request_count and _dialog._old_directory == OLD_DIRECTORY and _dialog._level_count == 7, "重复请求不会替换正在询问的路径或数量")
			var choice_count := _choices.size()
			request.callback.call(index)
			_check(_choices.size() == choice_count, "原生回调在系统调用栈中不立即执行业务")
			await _settle()
			_check(_choices.size() == choice_count + 1 and _choices.back().action == "cancel" and not _choices.back().open, "系统取消、关闭或未知返回仅产生关闭后的取消意图：" + platform)
			_check(not _dialog.is_open() and _origin.has_focus(), "取消恢复原页面焦点")
			request.callback.call(expected.size() - 1)
			await _settle()
			_check(_choices.size() == choice_count + 1, "取消后的迟到删除回调被忽略：" + platform)


## macOS 和 Windows 的明确迁移、删除索引不同，但一次选择都只发出一次意图。
func _test_native_choices() -> void:
	for platform in ["macOS", "Windows"]:
		_dialog.platform_name = platform
		var pairs := [[1, "migrate"], [2, "discard"]] if platform == "macOS" else [[0, "migrate"], [1, "discard"]]
		for pair in pairs:
			_dialog.open_confirmation(OLD_DIRECTORY, 4)
			var callback: Callable = _requests.back().callback
			var count := _choices.size()
			callback.call(pair[0])
			await _settle()
			_check(_choices.size() == count + 1 and _choices.back().action == pair[1] and not _choices.back().open, "明确原生按钮先关闭再发出对应意图：" + platform + " " + pair[1])
			callback.call(pair[0])
			await _settle()
			_check(_choices.size() == count + 1, "重复系统选择不能再次执行：" + platform + " " + pair[1])
		_immediate_choice = 2 if platform == "macOS" else 1
		var count := _choices.size()
		_dialog.open_confirmation(OLD_DIRECTORY, 1)
		_check(_choices.size() == count and _dialog.is_open(), "原生同步选择同样延后，不能重入调用方：" + platform)
		await _settle()
		_check(_choices.size() == count + 1 and _choices.back().action == "discard", "当前代同步明确删除最终只发出一次：" + platform)
		_immediate_choice = -999


## 系统窗口已显示后平台和语言变化不改变其按钮含义，索引一是关键分歧。
func _test_frozen_actions() -> void:
	for platform in ["macOS", "Windows"]:
		TranslationServer.set_locale("zh_CN")
		_dialog.platform_name = platform
		_dialog.open_confirmation(OLD_DIRECTORY, 3)
		var callback: Callable = _requests.back().callback
		var request_count := _requests.size()
		var choice_count := _choices.size()
		_dialog.platform_name = "Windows" if platform == "macOS" else "macOS"
		TranslationServer.set_locale("en")
		await _settle()
		_check(_requests.size() == request_count, "语言变化不重开正在等待选择的原生窗口：" + platform)
		callback.call(1)
		await _settle()
		var expected := "migrate" if platform == "macOS" else "discard"
		_check(_choices.size() == choice_count + 1 and _choices.back().action == expected, "响应按窗口打开时的按钮映射，平台变化不能误删：" + platform)
	TranslationServer.set_locale("zh_CN")


## 导航关闭、父页面隐藏和新代询问全部使旧系统响应失效。
func _test_stale_callbacks() -> void:
	for platform in ["macOS", "Windows"]:
		_dialog.platform_name = platform
		_dialog.open_confirmation(OLD_DIRECTORY, 2)
		var obsolete: Callable = _requests.back().callback
		var destructive_index := 2 if platform == "macOS" else 1
		_dialog.close_dialog()
		var count := _choices.size()
		_dialog.platform_name = "Windows" if platform == "macOS" else "macOS"
		_dialog.open_confirmation(OLD_DIRECTORY, 3)
		obsolete.call(destructive_index)
		await _settle()
		_check(_choices.size() == count and _dialog.is_open(), "上一代删除回调不能确认另一平台的新一代询问：" + platform)
		var current: Callable = _requests.back().callback
		_fixture.hide()
		current.call(1 if platform == "macOS" else 2)
		await _settle()
		_check(_choices.size() == count and not _dialog.is_open() and not _dialog._native_active, "父页面隐藏作废原生删除响应：" + platform)
		# 外层重新展示之前关闭逻辑节点，避免把已取消的询问恢复为可见。
		_dialog.hide()
		_fixture.show()
		await _settle()


## Windows 后备只保留迁移与删除，macOS 保留忽略；默认回车、Esc 和关闭均不删除。
func _test_fallback() -> void:
	for platform in ["macOS", "Windows"]:
		_dialog.platform_name = platform
		_dialog.use_native_dialog = true
		_native_result = ERR_UNAVAILABLE
		_immediate_choice = 2 if platform == "macOS" else 1
		var destructive_index := _immediate_choice
		_dialog.open_confirmation(OLD_DIRECTORY, 6)
		await _settle()
		_immediate_choice = -999
		_check(_dialog.is_open() and not _dialog._native_active and _dialog._fallback.visible, "原生失败后提供可关闭的后备窗口：" + platform)
		var default_button: Button = _dialog._fallback.get_cancel_button() if platform == "macOS" else _dialog._fallback.get_ok_button()
		_check(_dialog._fallback.gui_get_focus_owner() == default_button, "后备默认焦点不落在删除：" + platform)
		_check(_dialog._fallback.get_cancel_button().visible == (platform == "macOS"), "Windows 后备不显示第三个忽略按钮：" + platform)
		_check(_dialog._fallback.get_ok_button().text == "前往迁移" and _dialog._discard_button.text == "删除" and _dialog._fallback.get_cancel_button().text == "忽略", "后备按钮使用精简文字：" + platform)
		_check(_visible_buttons(_dialog._fallback) == (3 if platform == "macOS" else 2), "后备仅呈现平台要求的按钮数量：" + platform)
		var count := _choices.size()
		_requests.back().callback.call(destructive_index)
		await _settle()
		_check(_choices.size() == count and _dialog.is_open(), "失败调用的同步和迟到删除回调均不能穿透后备窗口：" + platform)
		await _key(KEY_ENTER)
		var default_action := "cancel" if platform == "macOS" else "migrate"
		_check(not _dialog.is_open() and _choices.size() == count + 1 and _choices.back().action == default_action, "后备默认回车仅执行忽略或迁移：" + platform)
		_dialog.use_native_dialog = false
		_dialog.open_confirmation(OLD_DIRECTORY, 2)
		await _settle()
		await _key(KEY_ESCAPE)
		_check(not _dialog.is_open() and _choices.back().action == "cancel", "后备 Esc 只取消：" + platform)
		_dialog.open_confirmation(OLD_DIRECTORY, 2)
		await _settle()
		_dialog._fallback.close_requested.emit()
		await _settle()
		_check(not _dialog.is_open() and _choices.back().action == "cancel", "后备系统关闭按钮只取消：" + platform)
		var pairs := [["cancel", "cancel"], ["migrate", "migrate"], ["discard", "discard"]] if platform == "macOS" else [["migrate", "migrate"], ["discard", "discard"]]
		for pair in pairs:
			_dialog.open_confirmation(OLD_DIRECTORY, 2)
			await _settle()
			var target: Button = _dialog._discard_button if pair[0] == "discard" else _dialog._fallback.get_ok_button() if pair[0] == "migrate" else _dialog._fallback.get_cancel_button()
			count = _choices.size()
			await _click_fallback(target)
			_check(_choices.size() == count + 1 and _choices.back().action == pair[1] and not _dialog.is_open(), "真实后备按钮正确提交选择：" + platform + " " + pair[1])
		_dialog._fallback.custom_action.emit("discard")
		_check(_choices.size() == count + 1, "后备窗口关闭后重复自定义动作无效：" + platform)
		_dialog.open_confirmation(OLD_DIRECTORY, 2)
		await _settle()
		count = _choices.size()
		_dialog._fallback.custom_action.emit("unknown")
		_check(_dialog.is_open() and _choices.size() == count, "未知自定义动作不删除也不确认：" + platform)
		_dialog.close_dialog()
	_native_result = OK


## 五种语言双平台均使用简短正文，旧路径隐藏，翻译变化不能改变当前按钮布局。
func _test_localization() -> void:
	_dialog.use_native_dialog = true
	for platform in ["macOS", "Windows"]:
		_dialog.platform_name = platform
		for locale in ["zh_CN", "zh_TW", "en", "es", "ja"]:
			TranslationServer.set_locale(locale)
			await _settle()
			_dialog.open_confirmation(OLD_DIRECTORY, 12)
			var request: Dictionary = _requests.back()
			_check(request.description == _dialog.tr(EXPECTED_WARNING) % 12 and request.description.contains("12") and not request.description.contains(OLD_DIRECTORY), "翻译仅插入实际数量，不显示旧路径：" + platform + " " + locale)
			var expected := PackedStringArray([_dialog.tr("忽略"), _dialog.tr("前往迁移"), _dialog.tr("删除")]) if platform == "macOS" else PackedStringArray([_dialog.tr("前往迁移"), _dialog.tr("删除")])
			_check(request.buttons == expected, "翻译保持平台的按钮数量与安全顺序：" + platform + " " + locale)
			if locale != "zh_CN":
				_check(_dialog.tr(EXPECTED_WARNING) != EXPECTED_WARNING and not request.description.contains("发现"), "精简正文有本语言翻译而非简体回退：" + platform + " " + locale)
			_dialog.close_dialog()
	_dialog.use_native_dialog = false
	for platform in ["macOS", "Windows"]:
		TranslationServer.set_locale("ja")
		_dialog.platform_name = platform
		_dialog.open_confirmation(OLD_DIRECTORY, 5)
		await _settle()
		_dialog.platform_name = "Windows" if platform == "macOS" else "macOS"
		TranslationServer.set_locale("en")
		await _settle()
		_check(_dialog._fallback.title == _dialog.tr("旧关卡迁移") and _dialog._fallback.dialog_text == _dialog.tr(EXPECTED_WARNING) % 5, "后备窗口实时翻译仍保留同一数量：" + platform)
		_check(_dialog._fallback.get_cancel_button().visible == (platform == "macOS") and _visible_buttons(_dialog._fallback) == (3 if platform == "macOS" else 2), "后备语言刷新遵守打开时的平台按钮布局：" + platform)
		_dialog.close_dialog()


## 统计后备窗口内实际可见按钮，防止隐藏取消按钮后仍出现第三项。
func _visible_buttons(node: Node) -> int:
	var count := 1 if node is Button and node.is_visible_in_tree() else 0
	for child in node.get_children(true):
		count += _visible_buttons(child)
	return count


## 后备窗口是独立视口，按键通过其真实焦点路由传递。
func _key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle()


## 鼠标按下和抬起发送给后备窗口的实际按钮位置，不直接伪造动作信号。
func _click_fallback(button: Button) -> void:
	var position: Vector2 = Vector2(_dialog._fallback.position) + button.get_global_transform_with_canvas() * (button.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.global_position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await _settle()


## 等待模态、延后回调和布局完成后再断言。
func _settle() -> void:
	for unused in 6:
		await process_frame


## 汇总明确场景的断言，并用最终退出码反馈结果。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
