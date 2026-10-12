class_name GameFontScale
extends Node
## 仅缩放当前游戏子树的文字，保留每项原字号；新页面、原生弹层与动态文字沿用同一比例。

var scope: Node
var layout_check: Callable
var _percentage := 100
var _nodes: Dictionary = {}
var _pending_layout := false


## 在新控件 ready 前注入比例，随后补齐继承主题的字号，避免首次打开页面使用旧档位。
func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_register_tree(scope)


## 只断开本控制器的场景树监听，不留下全局字体状态影响下一局或独立面板。
func _exit_tree() -> void:
	get_tree().node_added.disconnect(_on_node_added)
	get_tree().node_removed.disconnect(_on_node_removed)


## 档位改变时按原值重算现存字号，返回 100% 后恢复原大小，反复切换不会累积放大。
func set_percentage(value: int) -> void:
	if value == _percentage:
		return
	_percentage = value
	for reference: WeakRef in _nodes.values():
		var node: Node = reference.get_ref()
		if is_instance_valid(node):
			_apply(node)
	_queue_layout_check()


## 初始现存控件也必须登记；内部子节点包含 SpinBox 输入框和原生菜单行。
func _register_tree(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children(true):
		_register_tree(child)


## 只登记属于本游戏的控件和弹层，弱引用不会阻止页面正常销毁。
func _on_node_added(node: Node) -> void:
	if not is_instance_valid(scope) or not (node == scope or scope.is_ancestor_of(node)) or not (node is Control or node is Window):
		return
	_nodes[node.get_instance_id()] = weakref(node)
	# 原生菜单内部及独立 CanvasLayer 会中断父级属性继承，所有控件均独立启用清晰字形采样。
	GameTheme.enable_font_raster_scale(node)
	node.set_meta("ui_font_scale_percent", _percentage)
	if node is LineEdit and node.get_parent() is SpinBox:
		_disconnect_spin_callbacks(node)
		var callback := _on_spin_text_changed.bind(weakref(node))
		var spin := node.get_parent() as SpinBox
		node.set_meta("ui_font_spin_callback", callback)
		node.set_meta("ui_font_spin_owner", weakref(spin))
		node.text_changed.connect(callback)
		spin.value_changed.connect(callback)
	_apply_deferred.call_deferred(weakref(node))


## 页面移除后清除登记，长时间切换设置、装配和编程不会累积旧控件引用。
func _on_node_removed(node: Node) -> void:
	if not _nodes.has(node.get_instance_id()):
		return
	if node is LineEdit:
		_disconnect_spin_callbacks(node)
	_nodes.erase(node.get_instance_id())


## 保留中的面板可能再次加入场景树；同时解绑输入及数值监听，避免重复订阅或保留旧控制器。
func _disconnect_spin_callbacks(edit: LineEdit) -> void:
	if not edit.has_meta("ui_font_spin_callback"):
		return
	var callback: Callable = edit.get_meta("ui_font_spin_callback")
	if edit.text_changed.is_connected(callback):
		edit.text_changed.disconnect(callback)
	var reference := edit.get_meta("ui_font_spin_owner", null) as WeakRef
	var spin := reference.get_ref() as SpinBox if reference != null else null
	if is_instance_valid(spin) and spin.value_changed.is_connected(callback):
		spin.value_changed.disconnect(callback)
	edit.remove_meta("ui_font_spin_callback")
	edit.remove_meta("ui_font_spin_owner")


## 原生内部控件及主题在 ready 后才完整，延迟补齐不修改控件的输入焦点或文本。
func _apply_deferred(reference: WeakRef) -> void:
	var node: Node = reference.get_ref()
	if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion():
		_apply(node)
		_queue_layout_check()


## 继承主题和显式字号统一从记录的原值计算；只改 font_sizes，不改样式和图标。
func _apply(node: Node) -> void:
	node.set_meta("ui_font_scale_percent", _percentage)
	var keys := PackedStringArray()
	var kind := node.get_class()
	while not kind.is_empty():
		for key in ThemeDB.get_default_theme().get_font_size_list(kind):
			if not keys.has(key):
				keys.append(key)
		kind = ClassDB.get_parent_class(kind)
	for meta in node.get_meta_list():
		var name := String(meta)
		if name.begins_with("ui_font_base_") and not keys.has(name.trim_prefix("ui_font_base_")):
			keys.append(name.trim_prefix("ui_font_base_"))
	for key: String in keys:
		GameTheme.font_size(node, key, GameTheme.base_font_size(node, key))
	_fit_spin_text(node)
	if node.has_meta("ui_scaled_markdown_source") and not is_equal_approx(float(node.get_meta("ui_scaled_markdown_factor", 1.0)), _percentage / 100.0):
		GuideMarkdown.render(node as RichTextLabel, node.get_meta("ui_scaled_markdown_source"))


## 数值输入默认不随文本撑宽；大字号确实放不下当前数值时才增加输入框边界。
func _fit_spin_text(node: Node) -> void:
	if not node is LineEdit or not node.get_parent() is SpinBox:
		return
	var edit := node as LineEdit
	var spin := edit.get_parent() as SpinBox
	var original := float(spin.get_meta("ui_font_spin_base_width", spin.custom_minimum_size.x))
	spin.set_meta("ui_font_spin_base_width", original)
	var width := original
	if _percentage > 100:
		var text_width: float = edit.get_theme_font("font").get_string_size(edit.text, HORIZONTAL_ALIGNMENT_LEFT, -1, edit.get_theme_font_size("font_size")).x
		var arrow_width := 16.0
		for key in ["updown", "up", "down"]:
			if spin.has_theme_icon(key):
				arrow_width = maxf(arrow_width, spin.get_theme_icon(key).get_width())
		width = maxf(original, text_width + edit.get_theme_stylebox("normal").get_minimum_size().x + arrow_width + 8)
	spin.custom_minimum_size.x = ceilf(width)


## 输入、箭头及模块切换都可能产生更宽的负数；等待 SpinBox 更新显示文字后再适配数值框。
func _on_spin_text_changed(_value: Variant, reference: WeakRef) -> void:
	_apply_deferred.call_deferred(reference)


## 等两轮原生容器布局后检查是否需要空间，避免字号刚变时用过期尺寸扩大窗口。
func _queue_layout_check() -> void:
	if _pending_layout:
		return
	_pending_layout = true
	_check_layout.call_deferred()


## 合并同一批节点和字号变化的检查，滚动长度不算窗口必须扩大的最小高度。
func _check_layout() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_pending_layout = false
	if is_inside_tree() and layout_check.is_valid():
		layout_check.call()
