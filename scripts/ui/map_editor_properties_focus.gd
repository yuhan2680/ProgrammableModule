extends Node
## 管理属性空白点击失焦并通知卡片工具，不消费事件或改变键盘导航规则。

signal card_blank_clicked

var _editor: Control
var _card: Control
var _blocked: Callable


## 最后加入编辑器，先观察浮层可能吞掉的点击，再等待原生 GUI 完成命中和菜单关闭。
func configure(editor: Control, card: Control, blocked: Callable) -> void:
	_editor = editor
	_card = card
	_blocked = blocked


## 鼠标按下只安排后续检查，原有绘图、按钮和菜单仍完整接收同一次输入。
func _input(event: InputEvent) -> void:
	if not _editor.is_visible_in_tree() or _blocked.call(false):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# 已命中输入或按钮的点击不安排失焦，避免同帧快速移开鼠标打断刚开始的编辑。
		if not _interactive_hit(event.position):
			_release_blank_focus.call_deferred(event.position)


## 空白处真正释放属性焦点；输入框与按钮仍使用原生焦点转移和已有失焦提交。
func _release_blank_focus(point: Vector2) -> void:
	if not _editor.is_visible_in_tree() or not get_viewport().get_visible_rect().has_point(point) or _blocked.call(true):
		return
	var focused := get_viewport().gui_get_focus_owner()
	if _interactive_hit(point):
		return
	if focused != null and _card.is_ancestor_of(focused):
		focused.release_focus()
	# 开关高亮是工具状态，可能已经没有键盘焦点；地图空白不能误取消连续放置。
	if _card.get_global_rect().has_point(point):
		card_blank_clicked.emit()


## 使用原生 GUI 命中控件的父链，兼容内层数字框、按钮图标及滚动条。
func _interactive_hit(point: Vector2) -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	if is_instance_valid(hovered) and hovered.is_visible_in_tree() and hovered.get_global_rect().has_point(point):
		var target: Node = hovered
		while target != null:
			# SpinBox 的内层输入框、滚动条和按钮图标均沿实际控件父链识别。
			if target is BaseButton or target is LineEdit or target is TextEdit or target is Range:
				return true
			target = target.get_parent()
	return false
