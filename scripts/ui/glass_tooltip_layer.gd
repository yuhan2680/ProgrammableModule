class_name GlassTooltipLayer
extends CanvasLayer
## 接管原生悬停提示的绘制与定位；出现时机、翻译、文字布局和关闭仍交给 Godot。

const SHADOW_PADDING := 14.0
const TOOLTIP_SCALE := 0.7
const POINTER_OFFSET := Vector2(10.0, 14.0)
var _popup: PopupPanel
var _source_label: Label
var _source_panel: Panel
var _original_style: StyleBox
var _original_label_modulate := Color.WHITE
var _surface_root: Control
var _glass: ColorRect
var _label: Label
var _pointer_position := Vector2.ZERO


## 在嵌入弹窗之上绘制玻璃，以便模糊采样包含普通页面和其他弹窗的完整背景。
func _ready() -> void:
	layer = 1025
	_pointer_position = get_viewport().get_mouse_position()
	var backdrop := BackBufferCopy.new()
	backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(backdrop)
	_surface_root = Control.new()
	_surface_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_surface_root)
	_glass = ColorRect.new()
	_glass.name = "TooltipGlassSurface"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = load("res://assets/ui/tooltip_glass.gdshader")
	material.set_shader_parameter("shadow_padding", SHADOW_PADDING)
	_glass.material = material
	_surface_root.add_child(_glass)
	_label = Label.new()
	_label.name = "GlassTooltipText"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_surface_root.add_child(_label)
	get_tree().node_added.connect(_on_node_added)
	hide()
	set_process(false)


## 记录视口内的鼠标事件坐标，使拉伸窗口和嵌入预览使用与悬停命中一致的位置。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_pointer_position = event.position


## 只接管本游戏生成的默认文字提示，普通二级菜单及自定义弹窗不受影响。
func _on_node_added(node: Node) -> void:
	if node is PopupPanel and node.theme_type_variation == &"TooltipPanel" and get_parent().is_ancestor_of(node):
		_attach_tooltip.call_deferred(node)


## 保留原生窗口和标签的尺寸，仅隐藏原绘制；独立系统窗口使用浅色主题后备外观。
func _attach_tooltip(popup: PopupPanel) -> void:
	if not is_instance_valid(popup) or popup.is_queued_for_deletion() or not popup.is_visible() or not popup.is_embedded():
		return
	var source_label: Label
	var source_panel: Panel
	for child in popup.get_children(true):
		if child is Label and child.theme_type_variation == &"TooltipLabel":
			source_label = child
		elif child is Panel:
			source_panel = child
	if source_label == null or source_panel == null:
		return
	_release_tooltip()
	_popup = popup
	_source_label = source_label
	_source_panel = source_panel
	_original_style = popup.get_theme_stylebox("panel")
	_original_label_modulate = source_label.self_modulate
	var clear_style := _original_style.duplicate() as StyleBoxFlat
	if clear_style == null:
		_release_tooltip()
		return
	# 保留阴影占位及内容边距，避免更换外观时改变原生提示的位置和大小。
	clear_style.bg_color = Color.TRANSPARENT
	clear_style.border_color = Color.TRANSPARENT
	clear_style.shadow_color = Color.TRANSPARENT
	popup.add_theme_stylebox_override("panel", clear_style)
	source_label.self_modulate.a = 0.0
	_label.add_theme_font_override("font", source_label.get_theme_font("font"))
	_label.add_theme_font_size_override("font_size", source_label.get_theme_font_size("font_size"))
	_label.add_theme_color_override("font_color", GameTheme.TEXT)
	_label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	_label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	_label.autowrap_mode = source_label.autowrap_mode
	_label.horizontal_alignment = source_label.horizontal_alignment
	_label.vertical_alignment = source_label.vertical_alignment
	_label.text_direction = source_label.text_direction
	_label.language = source_label.language
	_sync_tooltip()
	show()
	set_process(true)


## 跟随指针及原生提示的缩放和翻译结果，背景模糊每帧读取当前画面而不冻结游戏。
func _process(_delta: float) -> void:
	if not is_instance_valid(_popup) or _popup.is_queued_for_deletion() or not _popup.is_visible() or not is_instance_valid(_source_label):
		_release_tooltip()
		return
	_sync_tooltip()


## 使用视口的真实屏幕变换，将文字、内距、圆角和阴影一并缩至原来的七成。
func _sync_tooltip() -> void:
	var popup_to_root := get_viewport().get_screen_transform().affine_inverse() * _popup.get_screen_transform()
	# 只缩放原生 hover 提示的绘制；保留原生换行和出现/关闭逻辑，普通二级菜单不变。
	_surface_root.scale = popup_to_root.get_scale() * TOOLTIP_SCALE
	var panel_rect := _source_panel.get_rect()
	_position_near_pointer(panel_rect)
	_glass.position = panel_rect.position - Vector2.ONE * SHADOW_PADDING
	_glass.size = panel_rect.size + Vector2.ONE * SHADOW_PADDING * 2.0
	(_glass.material as ShaderMaterial).set_shader_parameter("panel_size", panel_rect.size)
	_label.position = _source_label.position
	_label.size = _source_label.size
	# atr 尊重原控件的翻译模式，玩家自定义文字不会被额外翻译。
	_label.text = _source_label.atr(_source_label.text)


## 按实际显示尺寸在指针旁避让边界，防止七成卡片沿用原尺寸原点后远离鼠标。
func _position_near_pointer(panel_rect: Rect2) -> void:
	var display_scale := _surface_root.scale.abs()
	var display_size := panel_rect.size * display_scale
	var pointer := _pointer_position
	var bounds := get_viewport().get_visible_rect()
	var padding := Vector2.ONE * SHADOW_PADDING * display_scale
	var minimum := bounds.position + padding
	var maximum := bounds.end - padding - display_size
	var origin := pointer + POINTER_OFFSET
	if origin.x > maximum.x:
		origin.x = pointer.x - POINTER_OFFSET.x - display_size.x
	if origin.y > maximum.y:
		origin.y = pointer.y - POINTER_OFFSET.y - display_size.y
	origin.x = clampf(origin.x, minimum.x, maxf(minimum.x, maximum.x))
	origin.y = clampf(origin.y, minimum.y, maxf(minimum.y, maximum.y))
	_surface_root.position = origin - panel_rect.position * display_scale


## 原生提示结束后立即隐藏整层，并恢复仍存活的原窗口，防止界面留下残影。
func _release_tooltip() -> void:
	hide()
	set_process(false)
	if is_instance_valid(_source_label):
		_source_label.self_modulate = _original_label_modulate
	if is_instance_valid(_popup) and _original_style != null:
		_popup.add_theme_stylebox_override("panel", _original_style)
	_popup = null
	_source_label = null
	_source_panel = null
	_original_style = null


## 游戏页面树销毁时还原借用的绘制状态，信号连接随节点自动释放。
func _exit_tree() -> void:
	_release_tooltip()
