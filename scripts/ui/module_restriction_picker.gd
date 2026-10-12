class_name ModuleRestrictionPicker
extends EnemyModulePicker
## 复用玻璃模块菜单的裁剪、滚动和键盘导航；每次勾选立即提交，菜单保持打开。

signal restrictions_changed(ids: Array)

var _ids: Array[String] = []
var _restricted := PackedStringArray()
var _locks: Array[ModuleRestrictionLock] = []


## 菜单只列出当前目录中的模块；全部逐项取消后才是不限制。
func show_modules(anchor: Control, content: ContentRegistry, restricted: PackedStringArray) -> void:
	if is_open():
		close_menu()
		return
	_ids = []
	_locks.clear()
	_restricted = restricted.duplicate()
	var entries: Array[Dictionary] = []
	for module_id: String in content.modules:
		var definition := content.get_module(module_id)
		_ids.append(module_id)
		entries.append({"text": tr(definition.display_name), "icon": load(definition.texture) if not definition.texture.is_empty() else null})
	popup_at(anchor, entries, 0)
	_sync_locks()


## 原模块图标保持可见，右侧使用开合动画小锁并给正文预留宽度。
func _add_item(entry: Dictionary, index: int) -> void:
	super._add_item(entry, index)
	var item := _items[index]
	item.name = "ModuleRestrictionItem%d" % index
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := item.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		style.content_margin_right = 28
		item.add_theme_stylebox_override(state, style)
	var lock := ModuleRestrictionLock.new()
	item.add_child(lock)
	lock.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	lock.offset_left = -22
	lock.offset_right = -6
	lock.offset_top = -8
	lock.offset_bottom = 8
	lock.set_locked(_ids[index] in _restricted, false)
	_locks.append(lock)


## 用户可连续勾选或取消多个模块；菜单外点击或 Esc 才收起。
func _activate(index: int) -> void:
	if not is_open() or not _anchor_available() or index < 0 or index >= _ids.size():
		return
	var candidate: Array = Array(_restricted)
	if _ids[index] in candidate:
		candidate.erase(_ids[index])
	else:
		candidate.append(_ids[index])
	# 外层事务成功后调用 sync_selection，失败则保留当前有效选择。
	restrictions_changed.emit(candidate)


## 文档撤销、重做或事务提交后同步复选状态，不关闭菜单也不重建焦点。
func sync_selection(restricted: PackedStringArray) -> void:
	_restricted = restricted.duplicate()
	_sync_locks()


## 受限模块锁上、未受限模块打开；只更新变化的状态，不因其他同步重播动画。
func _sync_locks() -> void:
	for index in _locks.size():
		_locks[index].set_locked(_ids[index] in _restricted)


## 菜单截获输入时先同步入口焦点样式；鼠标收起不残留蓝框，Esc 仍有键盘提示。
func _input(event: InputEvent) -> void:
	if is_instance_valid(_anchor) and _anchor is ModuleRestrictionChoice:
		if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
			_anchor.set_keyboard_focus_visible(false)
		elif event is InputEventKey and event.pressed and is_open():
			_anchor.set_keyboard_focus_visible(true)
	super._input(event)


## 菜单与预览药丸保持等宽并左右对齐，仅视口太窄时按安全边距收缩。
func _update_placement() -> void:
	super._update_placement()
	if not is_open():
		return
	var factor := _overlay.scale.x
	var viewport_width := get_viewport().get_visible_rect().size.x / factor
	var width := minf(_anchor.size.x, maxf(1.0, viewport_width - EDGE_MARGIN * 2.0))
	_panel.size.x = width
	_panel.position.x = clampf(_anchor.get_global_rect().position.x / factor, EDGE_MARGIN, maxf(EDGE_MARGIN, viewport_width - width - EDGE_MARGIN))
	_glass.size = _panel.size
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", _glass.size)
	_scroll.size.x = maxf(1.0, width - PADDING * 2.0)
