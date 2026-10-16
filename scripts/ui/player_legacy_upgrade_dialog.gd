class_name PlayerLegacyUpgradeDialog
extends Control
## 旧目录升级询问只提交玩家选择；显示次数、迁移及删除文件均由外壳和模型负责。

signal migrate_requested
signal discard_requested
signal canceled

const WARNING_BODY := "发现 %d 个旧关卡。请前往玩家关卡列表，逐个迁移到新的保存目录。选择‘放弃并删除’将永久删除旧目录中的关卡，此操作无法撤销。此提醒只显示一次。\n旧目录：%s"

var use_native_dialog := true
var native_dialog_handler: Callable
var _native_active := false
var _request_generation := 0
var _fallback: ConfirmationDialog
var _discard_button: Button
var _previous_focus: Control
var _old_directory := ""
var _level_count := 0


## 后备窗口保留取消语义，破坏性选择使用独立自定义按钮而不充当默认确认。
func _ready() -> void:
	theme = GameTheme.create_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback = ConfirmationDialog.new()
	_fallback.name = "PlayerLegacyUpgradeFallback"
	_fallback.theme = theme
	_fallback.exclusive = true
	_fallback.dialog_autowrap = true
	_fallback.min_size = Vector2i(380, 220)
	_fallback.confirmed.connect(_on_fallback_confirmed)
	_fallback.canceled.connect(_cancel)
	_fallback.close_requested.connect(_cancel)
	_fallback.custom_action.connect(_on_custom_action)
	_discard_button = _fallback.add_button("放弃并删除", false, "discard")
	_discard_button.name = "DiscardLegacyLevelsButton"
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_discard_button.add_theme_color_override(state, Color("9d1414"))
	add_child(_fallback)
	GameTheme.style_guide_dialog(_fallback)
	visibility_changed.connect(_sync_visibility)
	hide()


## 系统默认首项为暂不处理，重复请求不会替换正在确认的路径或数量。
func open_confirmation(oldpath: String, count: int) -> void:
	if is_open():
		return
	_request_generation += 1
	_old_directory = oldpath
	_level_count = maxi(count, 0)
	_previous_focus = get_viewport().gui_get_focus_owner()
	_native_active = use_native_dialog and (native_dialog_handler.is_valid() or (OS.get_name() in ["macOS", "Windows"] and DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG)))
	show()
	if _native_active:
		var generation := _request_generation
		var callback := _on_native_choice.bind(generation)
		var buttons := PackedStringArray([tr("暂不处理"), tr("前往迁移"), tr("放弃并删除")])
		var result: int = native_dialog_handler.call(tr("旧关卡迁移"), _description(), buttons, callback) if native_dialog_handler.is_valid() else DisplayServer.dialog_show(tr("旧关卡迁移"), _description(), buttons, callback)
		if result == OK or generation != _request_generation or not is_open():
			return
		# 原生失败之后的回调不能穿透后备窗口，必须让玩家重新明确选择。
		_request_generation += 1
		_native_active = false
	_refresh_fallback()
	var available := get_viewport().get_visible_rect().size
	_fallback.popup_centered(Vector2i(minf(540.0, maxf(380.0, available.x - 40.0)), minf(320.0, maxf(220.0, available.y - 60.0))))
	_fallback.get_cancel_button().grab_focus.call_deferred()


## 路径作为原始数据插入译文，不翻译用户文件夹名。
func _description() -> String:
	return tr(WARNING_BODY) % [_level_count, _old_directory]


## 系统回调只排队，避免仍处于原生模态调用栈时迁移页面或删除文件。
func _on_native_choice(index: int, generation: int) -> void:
	_apply_native_choice.call_deferred(index, generation)


## 仅第三个明确按钮产生删除意图，系统关闭、取消及未知索引全部视为暂不处理。
func _apply_native_choice(index: int, generation: int) -> void:
	if not _native_active or generation != _request_generation or not is_open():
		return
	match index:
		1: _finish_choice("migrate")
		2: _finish_choice("discard")
		_: _cancel()


## 后备普通确认只导航迁移，绝不能借用默认确认触发删除。
func _on_fallback_confirmed() -> void:
	if not _native_active:
		_finish_choice("migrate")


## 后备删除只能来自独立自定义动作，未知动作不关闭窗口或发出请求。
func _on_custom_action(action: String) -> void:
	if not _native_active and action == "discard":
		_finish_choice("discard")


## 选择先关闭询问并作废旧回调，再把无副作用的操作意图交给外壳。
func _finish_choice(action: String) -> void:
	if not is_open():
		return
	hide()
	if action == "migrate":
		migrate_requested.emit()
	elif action == "discard":
		discard_requested.emit()


## 取消恢复原入口焦点，不负责记录提醒次数，也不触碰任何关卡文件。
func _cancel() -> void:
	if not is_open():
		return
	hide()
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	canceled.emit()


## 外壳通过逻辑可见性判断原生与后备两种模态是否正在占用交互。
func is_open() -> bool:
	return is_visible_in_tree()


## 导航或退出使本次请求失效，旧原生回调不能作用于之后的新询问。
func close_dialog() -> void:
	if is_open():
		_cancel()


## 页面隐藏同步收起后备窗口并作废请求代数，取消不依赖系统一定返回回调。
func _sync_visibility() -> void:
	if not is_instance_valid(_fallback):
		return
	if not is_visible_in_tree():
		_request_generation += 1
		_native_active = false
		_fallback.hide()
	set_process_input(is_visible_in_tree())


## 后备标题正文及按钮跟随当前语言，正在显示的原生询问不被重新打开。
func _refresh_fallback() -> void:
	if not is_instance_valid(_fallback):
		return
	_fallback.title = tr("旧关卡迁移")
	_fallback.dialog_text = _description()
	_fallback.ok_button_text = tr("前往迁移")
	_fallback.cancel_button_text = tr("暂不处理")
	_discard_button.text = tr("放弃并删除")


## 原生模态期间吞掉残留游戏输入，实际按钮和系统关闭事件由操作系统处理。
func _input(_event: InputEvent) -> void:
	if is_open() and _native_active:
		get_viewport().set_input_as_handled()


## 翻译变化只更新后备文案，保持同一请求代数与目标目录。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_refresh_fallback()
