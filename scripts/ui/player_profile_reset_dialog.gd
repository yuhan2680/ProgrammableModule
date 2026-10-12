class_name PlayerProfileResetDialog
extends Control
## 玩家档案重置优先询问操作系统；仅明确确认才允许外壳清空数据。

signal confirmed
signal canceled

var use_native_dialog := true
var native_dialog_handler: Callable
var _native_active := false
var _request_generation := 0
var _fallback: ConfirmationDialog
var _previous_focus: Control


## 后备窗口仍使用原生取消与确认语义，默认焦点始终为取消。
func _ready() -> void:
	theme = GameTheme.create_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback = ConfirmationDialog.new()
	_fallback.name = "PlayerProfileResetFallback"
	_fallback.theme = theme
	_fallback.exclusive = true
	_fallback.dialog_autowrap = true
	_fallback.min_size = Vector2i(380, 180)
	_fallback.confirmed.connect(_confirm)
	_fallback.canceled.connect(_cancel)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_fallback.get_ok_button().add_theme_color_override(state, Color("9d1414"))
	add_child(_fallback)
	# 嵌入弹窗仅由 Window 外框绘制整张圆角卡片，透明正文避免标题接缝与底角白板。
	GameTheme.style_guide_dialog(_fallback)
	visibility_changed.connect(_sync_visibility)
	hide()


## 重复点击保持同一次询问，原生接口失败时退回可取消的游戏窗口。
func open_confirmation() -> void:
	if is_open():
		return
	_request_generation += 1
	_previous_focus = get_viewport().gui_get_focus_owner()
	_native_active = use_native_dialog and (native_dialog_handler.is_valid() or (OS.get_name() in ["macOS", "Windows"] and DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG)))
	show()
	if _native_active:
		var generation := _request_generation
		var callback := _on_native_choice.bind(generation)
		# 将取消放在首位，避免系统默认按钮对删除档案采取破坏性选择。
		var buttons := PackedStringArray([tr("取消"), tr("删除玩家档案")])
		var result: int = native_dialog_handler.call(tr("删除玩家档案？"), _description(), buttons, callback) if native_dialog_handler.is_valid() else DisplayServer.dialog_show(tr("删除玩家档案？"), _description(), buttons, callback)
		if result == OK or generation != _request_generation or not is_open():
			return
		_request_generation += 1
		_native_active = false
	_refresh_fallback()
	var available := get_viewport().get_visible_rect().size
	_fallback.popup_centered(Vector2i(minf(480.0, maxf(220.0, available.x - 40.0)), minf(240.0, maxf(140.0, available.y - 40.0))))
	_fallback.get_cancel_button().grab_focus.call_deferred()


## 明确列出重置范围，关卡文件、进度与草稿都不属于本次删除操作。
func _description() -> String:
	return tr("用户名和统计信息将被清空，并生成新的 UID。已保存的关卡不会删除。此操作无法撤销。")


## 回调延后执行，避免在系统模态窗口内部更新档案和页面。
func _on_native_choice(index: int, generation: int) -> void:
	_apply_native_choice.call_deferred(index, generation)


## 仅确认当前一次询问的删除按钮；关闭、取消与迟到回调均不能清空数据。
func _apply_native_choice(index: int, generation: int) -> void:
	if not _native_active or generation != _request_generation or not is_open():
		return
	if index == 1:
		_confirm()
	else:
		_cancel()


## 外壳通过此接口判断确认窗口状态，不依赖后备窗口是否绘制。
func is_open() -> bool:
	return is_visible_in_tree()


## 页面关闭等外部清理只取消当前询问，并使可能晚到的原生响应失效。
func close_dialog() -> void:
	if is_open():
		_cancel()


## 确认只提交删除意图，持久化失败处理仍由拥有档案模型的外壳负责。
func _confirm() -> void:
	if not is_open():
		return
	hide()
	confirmed.emit()


## 取消恢复原页面焦点，绝不发出删除请求。
func _cancel() -> void:
	if not is_open():
		return
	hide()
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	canceled.emit()


## 隐藏页面时关闭后备窗口并作废所有旧响应，系统窗口不由游戏绘制替身。
func _sync_visibility() -> void:
	if not is_instance_valid(_fallback):
		return
	if not is_visible_in_tree():
		_request_generation += 1
		_native_active = false
		_fallback.hide()
	set_process_input(is_visible_in_tree())


## 后备窗口的标题、说明和按钮随界面语言更新，取消依旧是安全默认焦点。
func _refresh_fallback() -> void:
	if not is_instance_valid(_fallback):
		return
	_fallback.title = tr("删除玩家档案？")
	_fallback.dialog_text = _description()
	_fallback.ok_button_text = tr("删除玩家档案")
	_fallback.cancel_button_text = tr("取消")


## 原生询问期间拦截游戏残留输入，Esc 等选择由操作系统处理。
func _input(_event: InputEvent) -> void:
	if is_open() and _native_active:
		get_viewport().set_input_as_handled()


## 语言变化只刷新后备文案，不重开正在显示的系统模态窗口。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_refresh_fallback()
