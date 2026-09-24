class_name AssemblyGlassButton
extends Button
## 装配工具入口使用真实背景采样；标准按钮仍负责焦点、图标及鼠标行为。

var _backdrop: BackBufferCopy
var _glass: ColorRect
var _glass_material: ShaderMaterial


## 在标准按钮之后绘制图标，采样、柔影和圆形玻璃则位于按钮绘制之前。
func _ready() -> void:
	custom_minimum_size = Vector2(40, 40)
	expand_icon = true
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_theme_constant_override("icon_max_width", 20)
	add_theme_constant_override("h_separation", 0)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		add_theme_color_override(state, Color.WHITE)
	add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.34))
	var focus := GameTheme.box(Color.TRANSPARENT, Color("99C7FF"), 20)
	focus.set_content_margin_all(0)
	add_theme_stylebox_override("focus", focus)
	_backdrop = BackBufferCopy.new()
	_backdrop.name = "AssemblyButtonBackdrop"
	_backdrop.show_behind_parent = true
	add_child(_backdrop)
	var shadow := Panel.new()
	shadow.name = "AssemblyButtonShadow"
	shadow.show_behind_parent = true
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 20)
	surface.set_content_margin_all(0)
	surface.shadow_color = Color(0.1, 0.18, 0.29, 0.12)
	surface.shadow_size = 5
	surface.shadow_offset = Vector2(0, 2)
	shadow.add_theme_stylebox_override("panel", surface)
	add_child(shadow)
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_glass = ColorRect.new()
	_glass.name = "AssemblyButtonGlass"
	_glass.show_behind_parent = true
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass_material = ShaderMaterial.new()
	_glass_material.shader = load("res://assets/ui/assembly_glass.gdshader")
	_glass_material.set_shader_parameter("frost", 0.84)
	_glass.material = _glass_material
	add_child(_glass)
	_glass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_sync_surface)
	visibility_changed.connect(_sync_surface)
	mouse_entered.connect(_sync_highlight)
	mouse_exited.connect(_sync_highlight)
	toggled.connect(_on_toggled)
	button_down.connect(_sync_highlight)
	button_up.connect(_sync_highlight)
	_sync_surface()
	_sync_highlight()


## 几何变化只更新圆形遮罩和采样范围，不修改按钮的可点击区域。
func _sync_surface() -> void:
	if _glass_material == null:
		return
	_glass_material.set_shader_parameter("panel_size", size)
	_glass_material.set_shader_parameter("corner_radius", minf(size.x, size.y) * 0.5)
	# 全视口复制避免高分屏及嵌入视口中的局部采样范围偏移，关闭侧栏时也有有效背景。
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if is_visible_in_tree() else BackBufferCopy.COPY_MODE_DISABLED


## 悬停和按下沿用圆形玻璃，只改变轻微的冷色反光。
func _sync_highlight() -> void:
	if _glass_material != null:
		_glass_material.set_shader_parameter("highlighted", 1.0 if is_hovered() or button_pressed else 0.0)


## 切换按钮同步选中反光，参数由标准按钮信号提供。
func _on_toggled(_pressed: bool) -> void:
	_sync_highlight()
