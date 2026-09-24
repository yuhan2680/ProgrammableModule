extends CanvasLayer
## 轻量启动入口不引用游戏类，先绘制进度条，再异步载入完整游戏及字体。

signal progress_changed(value: float)
signal phase_changed(phase: String)
signal completed(game: Node)
signal failed(message: String)

const GAME_SCENE := "res://scenes/game.tscn"
# 启动失败时仍需香港繁体提示；静态小词典不引入完整游戏依赖。
const HONG_KONG_ERRORS := {
	"找不到启动资源。": "找不到啟動資源。",
	"无法读取启动资源。": "無法讀取啟動資源。",
	"启动资源加载失败。": "啟動資源載入失敗。",
	"启动场景格式不正确。": "啟動場景格式不正確。",
	"启动场景缺少必要的界面。": "啟動場景缺少必要的介面。",
	"重试": "重試",
}
const WARM_RESOURCES := [
	"res://assets/fonts/NotoSansSC.ttf",
	"res://assets/fonts/JetBrainsMono.ttf",
	"res://assets/ui/workshop.svg",
]

# 这些路径供独立启动回归替换，不读取或写入正式玩家测试数据。
var scene_path := GAME_SCENE
var settings_path := "user://settings.json"
var user_levels_directory := "user://levels"
var drafts_directory := "user://solutions"
var progress := 0.0
var phase := "waiting"
var _screen: Control
var _bar: ProgressBar
var _error_box: VBoxContainer
var _message: Label
var _paths: Array[String] = []
var _loaded: Dictionary = {}
# 每个成功提交的请求必须领取一次结果，包括失败结果；重试不能叠加同一路径的加载令牌。
var _pending: Array[String] = []
var _game: Node
var _transition: Tween


## 创建无需字体、图片或游戏主题的白底细进度条，先给首帧一次呈现机会。
func _ready() -> void:
	layer = 100
	get_window().unresizable = true
	_screen = Control.new()
	_screen.name = "StartupSurface"
	add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	var white := ColorRect.new()
	white.color = Color.WHITE
	white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen.add_child(white)
	white.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bar = ProgressBar.new()
	_bar.name = "StartupProgress"
	_bar.show_percentage = false
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for entry in [["background", Color("DDDDDD")], ["fill", Color("111111")]]:
		var style := StyleBoxFlat.new()
		style.bg_color = entry[1]
		style.set_corner_radius_all(2)
		_bar.add_theme_stylebox_override(entry[0], style)
	_screen.add_child(_bar)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_bar.offset_left = -120
	_bar.offset_right = 120
	_bar.offset_top = -2
	_bar.offset_bottom = 2
	set_process(false)
	_begin.call_deferred()


## 引擎开始绘图后才发起资源请求，确保加载期间有真实可见的反馈。
func _begin() -> void:
	await _draw_frame()
	_set_phase("resources")
	_paths.assign(WARM_RESOURCES)
	if not _paths.has(scene_path):
		_paths.append(scene_path)
	for path in _paths:
		if not ResourceLoader.exists(path):
			_fail("找不到启动资源。", "A startup resource could not be found.")
			return
	for path in _paths:
		var error := ResourceLoader.load_threaded_request(path)
		if error != OK:
			_fail("无法读取启动资源。", "A startup resource could not be loaded.")
			return
		_pending.append(path)
	set_process(true)


## 按资源加载器实际进度与初始化状态前进，不以计时器伪造加载百分比。
func _process(_delta: float) -> void:
	if phase == "resources":
		var total := 0.0
		for path in _paths:
			if _loaded.has(path):
				total += 1.0
				continue
			var amount: Array = []
			var status := ResourceLoader.load_threaded_get_status(path, amount)
			if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				if status == ResourceLoader.THREAD_LOAD_FAILED:
					_claim_request(path)
				else:
					_pending.erase(path)
				_fail("启动资源加载失败。", "Loading a startup resource failed.")
				return
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				# 仅在完成后获取资源，避免 get 在主线程上阻塞进度条绘制。
				_loaded[path] = _claim_request(path)
				total += 1.0
			elif not amount.is_empty():
				total += float(amount[0])
		_set_progress(0.7 * total / float(_paths.size()))
		if _loaded.size() == _paths.size():
			_start_game.call_deferred()
			set_process(false)
	elif phase == "initializing" and is_instance_valid(_game) and _game.get("startup_complete"):
		_set_phase("rendering")
	elif phase == "rendering" and _game.call("is_startup_presentable"):
		set_process(false)
		_reveal.call_deferred()


## 在主线程建立节点；完整游戏以可让出帧的初始化里程碑反馈剩余工作。
func _start_game() -> void:
	var packed: Resource = _loaded.get(scene_path)
	if not packed is PackedScene:
		_fail("启动场景格式不正确。", "The startup scene has an invalid format.")
		return
	_game = packed.instantiate()
	if not _game.has_method("is_startup_presentable") or not _game.has_method("reveal_startup_menu"):
		_game.free()
		_game = null
		_fail("启动场景缺少必要的界面。", "The startup scene is missing its interface.")
		return
	_game.set("settings_path", settings_path)
	_game.set("user_levels_directory", user_levels_directory)
	_game.set("drafts_directory", drafts_directory)
	_game.set("startup_reporter", _on_game_progress)
	_set_phase("initializing")
	get_tree().root.add_child(_game)
	set_process(true)


## 资源占前七成，主题、设置、目录与菜单等真实初始化里程碑占后续部分。
func _on_game_progress(value: float) -> void:
	_set_progress(0.7 + clampf(value, 0.0, 1.0) * 0.25)


## 背景已经绘制后才到满格，先显露模糊背景，再弹出菜单窗口。
func _reveal() -> void:
	_set_progress(1.0)
	await _draw_frame()
	_set_phase("background")
	_transition = create_tween()
	_transition.tween_property(_screen, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_SINE)
	await _transition.finished
	_set_phase("menu")
	await _game.call("reveal_startup_menu")
	# 游戏脱离启动层独立存在；启动控制器和资源缓存随后释放。
	var game := _game
	_game = null
	get_tree().current_scene = game
	_set_phase("complete")
	completed.emit(game)
	queue_free()


## 等待一次实际绘制；无图形的自动回归以逻辑帧推进，不能无限等待 GPU。
func _draw_frame() -> void:
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw


## 进度始终单调且限制在合法区间；重试会显式建立新的进度周期。
func _set_progress(value: float) -> void:
	progress = maxf(progress, clampf(value, 0.0, 1.0))
	_bar.value = progress
	progress_changed.emit(progress)


## 状态信号使冷启动验证能观察真实阶段，无需通过等待固定秒数猜测完成。
func _set_phase(value: String) -> void:
	phase = value
	phase_changed.emit(phase)


## 失败保留简洁可重试反馈，避免白屏、假满格或隐藏加载错误。
func _fail(chinese: String, english: String) -> void:
	set_process(false)
	_set_phase("failed")
	if _error_box == null:
		_error_box = VBoxContainer.new()
		_error_box.name = "StartupError"
		_screen.add_child(_error_box)
		_error_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		_error_box.offset_left = -210
		_error_box.offset_right = 210
		_error_box.offset_top = 24
		var font := SystemFont.new()
		font.font_names = PackedStringArray(["PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "Arial"])
		_error_box.add_theme_font_override("font", font)
		_message = Label.new()
		_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_message.add_theme_color_override("font_color", Color("333333"))
		_error_box.add_child(_message)
		var retry := Button.new()
		retry.name = "StartupRetry"
		retry.text = _localized("重试", "Retry")
		retry.pressed.connect(_retry)
		_error_box.add_child(retry)
	_message.text = _localized(chinese, english)
	_error_box.show()
	failed.emit(_message.text)


## 资源故障允许再次请求；已完成缓存继续由 Godot 复用，不重复进入游戏。
func _retry() -> void:
	if phase != "failed":
		return
	_error_box.hide()
	_set_phase("waiting")
	# 其他请求可能仍在进行；逐帧领取完成结果后再重试，避免 get 阻塞或复用失败令牌。
	await _drain_pending_requests()
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_loaded.clear()
	progress = 0.0
	_bar.value = 0.0
	_begin()


## 已完成或失败的请求都必须领取一次，使资源加载器释放当前请求令牌。
func _claim_request(path: String) -> Resource:
	var resource := ResourceLoader.load_threaded_get(path)
	_pending.erase(path)
	return resource


## 重试前等待本轮剩余请求结束；只读取终态结果，等待期间持续让出界面帧。
func _drain_pending_requests() -> void:
	while not _pending.is_empty():
		for path in _pending.duplicate():
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_LOADED or status == ResourceLoader.THREAD_LOAD_FAILED:
				_claim_request(path)
			elif status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				_pending.erase(path)
		if not _pending.is_empty():
			await get_tree().process_frame
			if not is_inside_tree() or is_queued_for_deletion():
				return


## 早期失败不能为一句错误信息预载整个翻译与字体系统，直接按当前语言反馈。
func _localized(chinese: String, english: String) -> String:
	var locale := _failure_locale()
	if locale in ["zh_HK", "zh_Hant_HK"]:
		return HONG_KONG_ERRORS.get(chinese, chinese)
	return chinese if locale.begins_with("zh") else english


## 仅故障提示读取有限的语言偏好，不为启动错误同步载入游戏或改写损坏配置。
func _failure_locale() -> String:
	if FileAccess.file_exists(settings_path):
		var file := FileAccess.open(settings_path, FileAccess.READ)
		if file != null:
			if file.get_length() <= 65536:
				var parser := JSON.new()
				if parser.parse(file.get_as_text()) == OK and parser.data is Dictionary:
					var config: Dictionary = parser.data
					if config.get("format_version") == 1 and config.get("interface") is Dictionary:
						var locale: Variant = config["interface"].get("language")
						if locale is String and locale in ["zh_CN", "en", "zh_HK"]:
							file.close()
							return locale
			file.close()
	return TranslationServer.get_locale()


## 启动覆盖层消失前屏蔽菜单输入，不能在隐藏窗口上触发点击或键盘操作。
func _input(_event: InputEvent) -> void:
	if phase != "failed":
		get_viewport().set_input_as_handled()


## 游戏会关闭自动退出；启动尚未完成时仍允许用户关闭窗口。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_inside_tree():
		get_tree().quit()


## 中途关闭或测试移除启动页时释放尚未交接的游戏，避免残留第二个菜单。
func _exit_tree() -> void:
	if _transition != null and _transition.is_running():
		_transition.kill()
	if is_instance_valid(_game):
		if _game.has_method("cancel_startup"):
			_game.call("cancel_startup")
		else:
			_game.queue_free()
