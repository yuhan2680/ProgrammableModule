extends SceneTree
## 系统提示音回归只统计面板信号并检查总线参数，不连接原生服务或发出真实声音。

var _checks := 0
var _failures := 0
var _test_root: String
var _preview_count := 0
var _cancel_count := 0


## 等待根视口初始化后运行隔离配置及真实控件回归。
func _initialize() -> void:
	_run.call_deferred()


## 保存全局音频与语言状态，所有文件都位于本次进程的独占目录。
func _run() -> void:
	Engine.max_fps = 120
	_test_root = "user://tests/system_sound_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var locale := TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	var master_db := AudioServer.get_bus_volume_db(master)
	var master_mute := AudioServer.is_bus_mute(master)
	var existing_bus := AudioServer.get_bus_index(GameSettings.SYSTEM_SOUND_BUS)
	var previous_db := AudioServer.get_bus_volume_db(existing_bus) if existing_bus >= 0 else 0.0
	var previous_mute := AudioServer.is_bus_mute(existing_bus) if existing_bus >= 0 else false
	var previous_send := AudioServer.get_bus_send(existing_bus) if existing_bus >= 0 else StringName("Master")
	_test_model()
	await _test_panel()
	var system_bus := AudioServer.get_bus_index(GameSettings.SYSTEM_SOUND_BUS)
	if existing_bus < 0:
		AudioServer.remove_bus(system_bus)
	else:
		AudioServer.set_bus_volume_db(system_bus, previous_db)
		AudioServer.set_bus_mute(system_bus, previous_mute)
		AudioServer.set_bus_send(system_bus, previous_send)
	AudioServer.set_bus_volume_db(master, master_db)
	AudioServer.set_bus_mute(master, master_mute)
	TranslationServer.set_locale(locale)
	_remove_tree(_test_root)
	print("系统提示音回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 验证旧配置兼容、原子拒绝非法值、两级音量与写盘失败，不接触玩家配置。
func _test_model() -> void:
	var path := _test_root.path_join("settings.json")
	var settings := GameSettings.new(path)
	_check(settings.load_settings().is_ok() and settings.system_sound_volume == 1.0 and not FileAccess.file_exists(path), "缺失配置默认提示音1且读取不写盘")
	var legacy := {"format_version": 1, "audio": {"master_volume": 0.4, "device": "retain"}, "interface": {"language": "en", "future_ui": 17}, "future": [1, 2]}
	_write_text(path, JSON.stringify(legacy))
	var legacy_bytes := FileAccess.get_file_as_bytes(path)
	var legacy_loaded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(settings.load_settings().is_ok() and settings.system_sound_volume == 1.0 and settings.volume == 0.4, "旧配置缺提示音字段只补内存默认值")
	_check(FileAccess.get_file_as_bytes(path) == legacy_bytes, "载入旧配置保持原始字节")
	var bus_count := AudioServer.bus_count
	_check(settings.set_system_sound_volume(0.25).is_ok(), "系统提示音支持独立保存")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(saved.audio.system_sound_volume == 0.25 and saved.audio.master_volume == 0.4 and saved.audio.device == "retain" and saved.interface.future_ui == 17 and saved.future == legacy_loaded.future, "保存提示音保留主音量及所有层级扩展字段")
	var reloaded := GameSettings.new(path)
	_check(reloaded.load_settings().is_ok() and reloaded.system_sound_volume == 0.25, "重建设置模型恢复系统提示音音量")
	var bus := AudioServer.get_bus_index(GameSettings.SYSTEM_SOUND_BUS)
	var master := AudioServer.get_bus_index("Master")
	_check(AudioServer.bus_count == bus_count and AudioServer.get_bus_send(bus) == StringName("Master"), "重复应用不新增同名总线且提示音只送到Master")
	var effective := db_to_linear(AudioServer.get_bus_volume_db(bus) + AudioServer.get_bus_volume_db(master))
	_check(is_equal_approx(effective, 0.1), "主音量0.4与提示音0.25的有效增益为0.1")
	var before := FileAccess.get_file_as_bytes(path)
	var rejected := true
	for value in [true, "0.5", INF, NAN, -0.01, 1.01, null, [], {}]:
		rejected = not settings.set_system_sound_volume(value).is_ok() and settings.system_sound_volume == 0.25 and rejected
	_check(rejected and FileAccess.get_file_as_bytes(path) == before, "非法类型和非有限或越界值均不改内存与有效文件")
	_check(settings.set_system_sound_volume(0).is_ok() and AudioServer.is_bus_mute(bus) and is_finite(AudioServer.get_bus_volume_db(bus)) and not AudioServer.is_bus_mute(master), "提示音零值独立静音且总线分贝有限")
	_check(settings.set_system_sound_volume(1).is_ok() and not AudioServer.is_bus_mute(bus), "提示音恢复1会解除独立静音")
	settings.set_volume(0)
	_check(AudioServer.is_bus_mute(master) and not AudioServer.is_bus_mute(bus), "主音量零值通过父总线使提示音静音")
	legacy.audio.system_sound_volume = "invalid"
	var broken := JSON.stringify(legacy)
	_write_text(path, broken)
	_check(not settings.load_settings().is_ok() and settings.volume == 1.0 and settings.system_sound_volume == 1.0 and settings.language == "zh_CN" and FileAccess.get_file_as_string(path) == broken, "无效提示音字段整份回退默认且损坏原件保留")
	var blocked := _test_root.path_join("blocked")
	_write_text(blocked, "retain")
	var unsaved := GameSettings.new(blocked.path_join("settings.json"))
	_check(not unsaved.set_system_sound_volume(0.3).is_ok() and unsaved.system_sound_volume == 0.3 and not unsaved.last_error.is_empty() and is_equal_approx(db_to_linear(AudioServer.get_bus_volume_db(bus)), 0.3) and FileAccess.get_file_as_string(blocked) == "retain", "保存失败仍即时应用音量并保留可见错误和阻挡文件")


## 真实键盘、滚轮和拖动仅产生防抖后的试听请求，同时检查三语言布局及取消路径。
func _test_panel() -> void:
	var settings := GameSettings.new(_test_root.path_join("panel.json"))
	settings.load_settings()
	settings.set_system_sound_volume(0.5)
	var panel := SettingsPanel.new()
	panel.settings = settings
	panel.size = Vector2(1024, 640)
	panel.system_sound_preview_requested.connect(_on_preview)
	panel.system_sound_preview_cancel_requested.connect(_on_cancel)
	root.add_child(panel)
	await create_timer(0.32).timeout
	var master := panel.find_child("VolumeSlider", true, false) as HSlider
	var slider := panel.find_child("SystemSoundSlider", true, false) as HSlider
	_check(master != null and slider != null and _preview_count == 0, "打开面板不自动试听且保留两个原生滑条")
	if master == null or slider == null:
		panel.queue_free()
		await process_frame
		return
	settings.set_system_sound_volume(0.6)
	await create_timer(0.3).timeout
	_check(slider.value == 60 and _preview_count == 0, "外部设置同步滑条不会试听")
	await _test_locales(panel, settings, master, slider)
	slider.grab_focus()
	for unused in 3:
		_key(KEY_RIGHT)
		await process_frame
	await create_timer(0.12).timeout
	_check(_preview_count == 0 and settings.system_sound_volume > 0.6, "连续键盘改值在250毫秒内不抢先试听")
	await create_timer(0.2).timeout
	_check(_preview_count == 1, "键盘停止改值后只试听一次")
	var before := _preview_count
	var cancellations := _cancel_count
	var old_value := slider.value
	for unused in 3:
		_mouse_button(slider.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_UP, true)
		_mouse_button(slider.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_UP, false)
		await process_frame
	_check(_cancel_count > cancellations and _preview_count == before, "重新滚轮改值立即取消旧试听而非等待新防抖结束")
	await create_timer(0.32).timeout
	_check(slider.value != old_value and _preview_count == before + 1, "真实滚轮连续改值合并为一次试听")
	before = _preview_count
	var rect := slider.get_global_rect()
	var start := Vector2(rect.position.x + rect.size.x * 0.2, rect.get_center().y)
	var finish := Vector2(rect.position.x + rect.size.x * 0.7, rect.get_center().y)
	_mouse_button(start, MOUSE_BUTTON_LEFT, true)
	var motion := InputEventMouseMotion.new()
	motion.position = finish
	motion.global_position = finish
	motion.relative = finish - start
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	await create_timer(0.32).timeout
	_check(_preview_count == before, "真实拖动停留超过250毫秒也不在按住时试听")
	_mouse_button(finish, MOUSE_BUTTON_LEFT, false)
	await process_frame
	_check(_preview_count == before + 1, "真实拖动松开后立即试听一次")
	await create_timer(0.3).timeout
	_check(_preview_count == before + 1, "拖动结束没有残留定时器重复试听")
	before = _preview_count
	master.grab_focus()
	_key(KEY_LEFT)
	await create_timer(0.32).timeout
	_check(_preview_count == before + 1, "主音量也提供一次合成音量试听")
	before = _preview_count
	settings.set_volume(0)
	slider.grab_focus()
	_key(KEY_LEFT)
	await create_timer(0.3).timeout
	_check(_preview_count == before, "主音量静音时改提示音不请求播放")
	settings.set_volume(0.8)
	settings.set_system_sound_volume(0)
	master.grab_focus()
	_key(KEY_LEFT)
	await create_timer(0.3).timeout
	_check(_preview_count == before, "提示音静音时改主音量不请求播放")
	settings.set_system_sound_volume(0.5)
	slider.grab_focus()
	_key(KEY_LEFT)
	panel.hide()
	panel.show()
	await create_timer(0.32).timeout
	_check(_preview_count == before and _cancel_count > 0, "隐藏再显示取消待播请求且不会补播")
	slider.grab_focus()
	_key(KEY_LEFT)
	panel.queue_free()
	await create_timer(0.32).timeout
	_check(_preview_count == before, "退出面板取消尚未到期的试听")


## 三种语言使用相同音频行，状态翻译与设置保存错误相互独立且文字不越界。
func _test_locales(panel: SettingsPanel, settings: GameSettings, master: HSlider, slider: HSlider) -> void:
	var row := panel.find_child("SystemSoundRow", true, false) as Control
	var master_row := panel.find_child("VolumeRow", true, false) as Control
	var label := panel.find_child("SystemSoundLabel", true, false) as Label
	var master_label := panel.find_child("VolumeLabel", true, false) as Label
	var preview_status := panel.find_child("SystemSoundPreviewStatus", true, false) as Label
	var status := panel.find_child("SettingsStatus", true, false) as Label
	var captions := {"zh_CN": ["主音量", "系统提示音", "当前系统未设置提示音。"], "zh_HK": ["主音量", "系統提示音", "目前系統未設定提示音。"], "en": ["Master Volume", "System Sounds", "No system sound is configured."]}
	panel.set_system_sound_preview_status("当前系统未设置提示音。")
	for locale: String in ["zh_CN", "zh_HK", "en"]:
		settings.set_language(locale)
		for unused in 3:
			await process_frame
		_check(master_label.atr(master_label.text) == captions[locale][0] and label.atr(label.text) == captions[locale][1] and preview_status.text == captions[locale][2], "音频标签和独立状态支持语言：" + locale)
		_check(row.get_global_rect().encloses(label.get_global_rect()) and row.get_global_rect().encloses(slider.get_global_rect()) and label.get_global_rect().end.x < slider.global_position.x and is_equal_approx(slider.global_position.x, master.global_position.x) and is_equal_approx(slider.size.x, master.size.x) and master_row.get_global_rect().end.y < row.global_position.y, "两行滑条对齐且标签无重叠裁切：" + locale)
	settings.last_error = "设置保存失败"
	panel._sync_controls()
	_check(status.visible and status.text.contains("Settings Could Not Be Saved") and preview_status.visible, "系统试听状态不覆盖保存失败反馈")
	settings.last_error = ""
	panel.set_system_sound_preview_status("")
	panel._sync_controls()
	_check(not preview_status.visible and _preview_count == 0, "清空试听状态收起行且语言切换不试听")
	var display_title := panel.find_child("CompletionSectionTitle", true, false) as Control
	for unused in 3:
		await process_frame
	var title_y := display_title.global_position.y
	panel.set_system_sound_preview_status("正在读取系统提示音…")
	for unused in 3:
		await process_frame
	_check(not preview_status.visible and display_title.global_position.y == title_y, "短暂读取状态不使下方设置跳动")
	panel.set_system_sound_preview_status("")


## 用真实按键按下与释放驱动当前焦点滑条，保留原生输入路径。
func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)


## 鼠标坐标已处于视口逻辑空间，避免重复套用窗口伸缩变换。
func _mouse_button(position: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = pressed
	root.push_input(event, true)


## 只统计请求，不创建或调用任何系统声音服务。
func _on_preview() -> void:
	_preview_count += 1


## 统计取消通知以证明隐藏和新手势能撤销外层服务工作。
func _on_cancel() -> void:
	_cancel_count += 1


## 报告断言同时继续其余路径，使失败输出包含本次完整检查范围。
func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)


## 测试文件仅写入独占目录；需要时递归创建父目录。
func _write_text(path: String, source: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(source)
	file.close()


## 回归结束只递归清理本次独占测试目录。
func _remove_tree(path: String) -> void:
	for file: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for directory: String in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)
