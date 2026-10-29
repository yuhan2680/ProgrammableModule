class_name QuitGameDialog
extends Node
## 退出询问只提交明确选择，不写存档也不终止进程；启动页可独立加载此轻量组件。

signal confirmed
signal canceled

var use_native_dialog := true
var native_dialog_handler: Callable
var _fallback: ConfirmationDialog
var _native_active := false
var _request_generation := 0
var _open := false
var _previous_focus: Control


## 后备询问在场景暂停时仍可取消，不依赖完整游戏主题或字体资源。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fallback = ConfirmationDialog.new()
	_fallback.name = "QuitGameFallback"
	_fallback.exclusive = true
	_fallback.dialog_autowrap = true
	_fallback.dialog_hide_on_ok = false
	_fallback.min_size = Vector2i(360, 160)
	_fallback.confirmed.connect(_on_fallback_confirmed)
	_fallback.canceled.connect(close_dialog)
	_fallback.close_requested.connect(close_dialog)
	add_child(_fallback)
	set_process_input(false)


## 原生按钮固定以取消为首项；早期启动可传入轻量词典译文而不注册完整词典。
func open_confirmation(title: String = "", body: String = "", cancel_text: String = "", quit_text: String = "") -> void:
	if _open:
		return
	_open = true
	_request_generation += 1
	_previous_focus = get_viewport().gui_get_focus_owner()
	set_process_input(true)
	_fallback.title = tr("离开游戏") if title.is_empty() else title
	_fallback.dialog_text = tr("确定要退出游戏吗？") if body.is_empty() else body
	_fallback.cancel_button_text = tr("取消") if cancel_text.is_empty() else cancel_text
	_fallback.ok_button_text = tr("退出") if quit_text.is_empty() else quit_text
	_native_active = use_native_dialog and (native_dialog_handler.is_valid() or (OS.get_name() in ["macOS", "Windows"] and DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG)))
	if _native_active:
		var generation := _request_generation
		var callback := _on_native_choice.bind(generation)
		var buttons := PackedStringArray([_fallback.cancel_button_text, _fallback.ok_button_text])
		var result: int = native_dialog_handler.call(_fallback.title, _fallback.dialog_text, buttons, callback) if native_dialog_handler.is_valid() else DisplayServer.dialog_show(_fallback.title, _fallback.dialog_text, buttons, callback)
		if result == OK or generation != _request_generation or not _open:
			return
		# 失败调用即使稍后返回“退出”，也不能替代后备窗口中这一次明确选择。
		_request_generation += 1
		_native_active = false
	_style_embedded_card()
	_fallback.popup_centered()
	_fallback.get_cancel_button().grab_focus.call_deferred()


## 嵌入窗口只由外框绘制整张圆角卡片，正文透明并保留原主题实际生效的留白。
func _style_embedded_card() -> void:
	if not _fallback.is_embedded():
		return
	var original := _fallback.get_theme_stylebox("panel")
	var content := StyleBoxEmpty.new()
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		content.set_content_margin(side, original.get_margin(side))
	_fallback.transparent_bg = true
	_fallback.add_theme_stylebox_override("panel", content)


## 系统同步回调也延后一帧处理，避免仍在原生窗口调用栈内写盘或退出。
func _on_native_choice(index: int, generation: int) -> void:
	_apply_native_choice.call_deferred(index, generation)


## 只有当前请求的退出按钮有效，关闭、取消和非法索引一律取消。
func _apply_native_choice(index: int, generation: int) -> void:
	if not _open or not _native_active or generation != _request_generation:
		return
	_finish(index == 1)


## 原生询问期间不接受后备窗口的残留确认信号。
func _on_fallback_confirmed() -> void:
	if not _native_active:
		_finish(true)


## 先关闭并作废回调，再通知外壳；重复按钮事件最多消费一次退出意图。
func _finish(accepted: bool) -> void:
	if not _open:
		return
	_open = false
	_native_active = false
	_request_generation += 1
	set_process_input(false)
	_fallback.hide()
	if not accepted and is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	if accepted:
		confirmed.emit()
	else:
		canceled.emit()


## 生命周期关闭只取消当前询问，绝不能被解释为用户同意退出。
func close_dialog() -> void:
	_finish(false)


## 对原生与后备窗口提供相同的逻辑模态状态。
func is_open() -> bool:
	return _open


## 原生对话框自己消费键盘，残留事件不得落到底页触发游戏快捷键。
func _input(_event: InputEvent) -> void:
	if _open and _native_active:
		get_viewport().set_input_as_handled()


## 销毁使所有已排队系统回调失效，不在移除过程中发出退出信号。
func _exit_tree() -> void:
	_open = false
	_native_active = false
	_request_generation += 1
