class_name ModuleRestrictionPicker
extends EnemyModulePicker
## 复用玻璃模块菜单的裁剪、滚动和键盘导航；每次勾选立即提交，菜单保持打开。

signal restrictions_changed(ids: Array)

const CHECKMARK := preload("res://assets/ui/settings_option_check.svg")
const CHECK_SIZE := 18.0
const CHECK_LEFT := 8.0
const TEXT_LEFT := 34.0

var _ids: Array[String] = []
var _restricted := PackedStringArray()
var _checks: Array[TextureRect] = []


## 模块多选采用中性浅白玻璃与双层边缘，参数只覆盖本菜单实例。
func _ready() -> void:
	super._ready()
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 18)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.10, 0.12, 0.16, 0.18)
	surface.shadow_size = 16
	surface.shadow_offset = Vector2(0, 5)
	_panel.add_theme_stylebox_override("panel", surface)
	var material := _glass.material as ShaderMaterial
	material.set_shader_parameter("corner_radius", 18.0)
	material.set_shader_parameter("frost", 0.90)
	material.set_shader_parameter("neutral_tint", 1.0)
	material.set_shader_parameter("menu_depth", 1.0)


## 菜单只列出当前目录中的模块；全部逐项取消后才是不限制。
func show_modules(anchor: Control, content: ContentRegistry, restricted: PackedStringArray) -> void:
	if is_open():
		close_menu()
		return
	_ids = []
	_checks.clear()
	_restricted = restricted.duplicate()
	var entries: Array[Dictionary] = []
	for module_id: String in content.modules:
		var definition := content.get_module(module_id)
		_ids.append(module_id)
		entries.append({"text": tr(definition.display_name)})
	popup_at(anchor, entries, 0)
	_sync_checks()


## 左侧勾号表示禁止；未勾选保留等宽留白，所有名称从同一列开始。
func _add_item(entry: Dictionary, index: int) -> void:
	super._add_item(entry, index)
	var item := _items[index]
	item.name = "ModuleRestrictionItem%d" % index
	item.icon = null
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := Color.TRANSPARENT
		if state in ["hover", "focus"]:
			fill = Color(0.78, 0.81, 0.86, 0.30)
		elif state in ["pressed", "hover_pressed"]:
			fill = Color(0.72, 0.77, 0.84, 0.38)
		var style := GameTheme.box(fill, Color.TRANSPARENT, 7)
		style.content_margin_left = TEXT_LEFT
		style.content_margin_right = 8
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		item.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		item.add_theme_color_override(state, GameTheme.TEXT)
	var check := TextureRect.new()
	check.name = "ModuleRestrictionCheck%d" % index
	check.texture = CHECKMARK
	check.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	check.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	check.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	check.self_modulate = GameTheme.TEXT
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(check)
	check.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	check.offset_left = CHECK_LEFT
	check.offset_right = CHECK_LEFT + CHECK_SIZE
	check.offset_top = -CHECK_SIZE * 0.5
	check.offset_bottom = CHECK_SIZE * 0.5
	check.visible = _ids[index] in _restricted
	_checks.append(check)


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
	_sync_checks()


## 事务与撤销仅更新受限项的勾号，不把选择状态混入悬停或键盘焦点底色。
func _sync_checks() -> void:
	for index in _checks.size():
		_checks[index].visible = _ids[index] in _restricted


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
