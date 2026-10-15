class_name RestrictedCodeEdit
extends CodeEdit
## 限制粘贴的关卡专用编辑器；原生复制、剪切、输入、撤销与程序主动填入仍保留。

var _editing_requested := true
var _drag_active := false


## 从创建起关闭中键和选区拖动，原生菜单移除粘贴项但保留其他编辑操作。
func _init() -> void:
	middle_mouse_paste_enabled = false
	drag_and_drop_selection_enabled = false
	var menu := get_menu()
	var paste_index := menu.get_item_index(TextEdit.MENU_PASTE)
	if paste_index >= 0:
		menu.remove_item(paste_index)


## 原生快捷键、菜单操作和直接 paste() 都先经过此虚方法，不读取剪贴板或修改选区。
func _paste(_caret_index: int) -> void:
	pass


## 同时拦截 Linux 主选择区及显式调用，避免中键粘贴绕开普通剪贴板入口。
func _paste_primary_clipboard(_caret_index: int) -> void:
	pass


## 工作台请求编辑状态时继续尊重拖拽保护，运行中途切换状态不会在拖拽结束后错误解锁。
func set_editing_enabled(enabled: bool) -> void:
	_editing_requested = enabled
	editable = enabled and not _drag_active


## TextEdit 的拒绝投放回调仍会回退接收字符串，故真实拖拽期间暂时只读以阻止外部代码投放。
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_drag_active = true
		editable = false
	elif what == NOTIFICATION_DRAG_END:
		_drag_active = false
		editable = _editing_requested
