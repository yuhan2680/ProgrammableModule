extends CanvasLayer
## 原生选择器继续处理鼠标、键盘和滚动；在弹出前捕获真实页面，玻璃与原生前景独立合成。

const SHADOW_PADDING := 14.0
const GLASS_SHADER := preload("res://assets/ui/settings_option_glass.gdshader")
const SCROLLBAR_HELPER := preload("res://scripts/ui/settings_option_scrollbar.gd")
const SCROLLBAR_RIGHT_MARGIN := 8.0

var option: OptionButton
var _popup: PopupMenu
var _glass: ColorRect
var _native_content: TextureRect
var _backdrop: ImageTexture
var _pending_backdrop: Image
var _original_style: StyleBox
var _original_transparent := false
var _original_window_transparent := false
var _last_bounds := Rect2()


## 原生前景和玻璃在嵌入窗口之上合成，避免弹窗屏幕采样与透明缓冲的兼容性黑底。
func _ready() -> void:
	layer = 1025
	_glass = ColorRect.new()
	_glass.name = "SettingsOptionGlassSurface"
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glass_material := ShaderMaterial.new()
	glass_material.shader = GLASS_SHADER
	glass_material.set_shader_parameter("frost_amount", 0.72)
	_glass.material = glass_material
	add_child(_glass)
	# 以窗口实际输出像素显示原生前景，不修改字号或放大一张低分辨率文字图。
	# 嵌入窗口自身的透明合成在部分 Compatibility 尺寸下会残留黑底，主画布统一合成可避免此问题。
	_native_content = TextureRect.new()
	_native_content.name = "SettingsOptionNativeContent"
	_native_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_native_content.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_native_content.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_native_content)
	hide()
	set_process(false)
	if not is_instance_valid(option):
		return
	_popup = option.get_popup()
	_original_style = _popup.get_theme_stylebox("panel")
	_original_transparent = _popup.transparent_bg
	_original_window_transparent = _popup.transparent
	_prepare_popup()
	_popup.about_to_popup.connect(_capture_background)
	_popup.about_to_popup.connect(_prepare_popup)
	_popup.about_to_popup.connect(_show_surface.call_deferred)
	_popup.popup_hide.connect(_hide_surface)
	get_viewport().size_changed.connect(_on_viewport_resized)


## 读取尚未显示菜单的真实页面；菜单期间背景不能交互，捕获一次避免自身文字反馈和窗口采样串台。
func _capture_background() -> void:
	if not is_instance_valid(_popup) or not _popup.is_embedded() or DisplayServer.get_name() == "headless":
		return
	var source := get_viewport().get_texture().get_image()
	if source == null or source.is_empty():
		return
	_pending_backdrop = source


## 只接管嵌入菜单的背景；系统独立窗口保留原生不透明后备外观。
func _prepare_popup() -> void:
	if not is_instance_valid(_popup):
		return
	if not _popup.is_embedded():
		_restore_popup()
		return
	var surface := _original_style.duplicate() as StyleBoxFlat
	if surface == null:
		return
	surface.bg_color = Color.TRANSPARENT
	surface.border_color = Color.TRANSPARENT
	surface.shadow_color = Color.TRANSPARENT
	# 外部玻璃已经绘制阴影，原生透明阴影不能继续占据弹层内部的滚动条留白。
	surface.shadow_size = 0
	surface.shadow_offset = Vector2.ZERO
	# 让原生容器本身延伸到右侧；不能只挪动画出来的滑块而留下旧命中位置。
	surface.content_margin_right = minf(surface.get_margin(SIDE_RIGHT), SCROLLBAR_RIGHT_MARGIN)
	_popup.add_theme_stylebox_override("panel", surface)
	_popup.transparent_bg = true
	_popup.transparent = true
	_style_scrollbars(_popup)


## 延迟到原生位置计算完成再显示玻璃，透明目标须在菜单打开前准备而非首帧之后。
func _show_surface() -> void:
	if not is_instance_valid(_popup) or not _popup.visible or not is_instance_valid(option) or not option.is_visible_in_tree() or not _popup.is_embedded():
		return
	_last_bounds = Rect2()
	_native_content.texture = _popup.get_texture()
	_update_surface()
	show()
	set_process(true)


## 调整实际原生滚动条的绘制与几何，活动淡出继续使用统一的原生数值监听。
func _style_scrollbars(node: Node) -> void:
	if node is ScrollContainer and not node.has_node("SettingsOptionScrollbar"):
		var helper := SCROLLBAR_HELPER.new()
		helper.name = "SettingsOptionScrollbar"
		helper.popup = _popup
		helper.scroll = node
		node.add_child(helper)
	if node is VScrollBar:
		for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
			var style := StyleBoxFlat.new()
			var opacity := 0.0 if state.begins_with("scroll") else 0.20
			if state == "grabber_highlight":
				opacity = 0.28
			elif state == "grabber_pressed":
				opacity = 0.36
			style.bg_color = Color(0.50, 0.57, 0.66, opacity)
			style.set_corner_radius_all(4)
			style.set_content_margin_all(4.0)
			node.add_theme_stylebox_override(state, style)
	for child in node.get_children(true):
		_style_scrollbars(child)


## 原生菜单的位置、大小或白卡缩放变化时，玻璃继续跟随同一真实矩形。
func _process(_delta: float) -> void:
	if not is_instance_valid(_popup) or not _popup.visible or not is_instance_valid(option) or not option.is_visible_in_tree():
		if is_instance_valid(_popup) and _popup.visible and (not is_instance_valid(option) or not option.is_visible_in_tree()):
			_popup.hide()
		_hide_surface()
		return
	_update_surface()


## 将原生窗口客户区换算到主视口，阴影和圆角也使用实际显示像素。
func _update_surface() -> void:
	var popup_to_root := get_viewport().get_screen_transform().affine_inverse() * _popup.get_screen_transform()
	var bounds := popup_to_root * _popup.get_visible_rect()
	if bounds.is_equal_approx(_last_bounds):
		return
	_last_bounds = bounds
	var layout_scale := popup_to_root.get_scale().abs().x
	var padding := SHADOW_PADDING * layout_scale
	_glass.position = bounds.position - Vector2.ONE * padding
	_glass.size = bounds.size + Vector2.ONE * padding * 2.0
	_native_content.position = bounds.position
	_native_content.size = bounds.size
	var glass_material := _glass.material as ShaderMaterial
	glass_material.set_shader_parameter("panel_size", bounds.size)
	glass_material.set_shader_parameter("corner_radius", 23.0 * layout_scale)
	glass_material.set_shader_parameter("shadow_padding", padding)
	glass_material.set_shader_parameter("blur_step", 3.2 * layout_scale)
	_crop_backdrop(Rect2(_glass.position, _glass.size))


## 弹层位置确定后只保留菜单及阴影的背景区域，4K 画面不常驻整屏副本。
func _crop_backdrop(bounds: Rect2) -> void:
	if _pending_backdrop == null:
		return
	var source_size := Vector2(_pending_backdrop.get_size())
	var image_scale := source_size / get_viewport().get_visible_rect().size
	var source_bounds := Rect2i(Vector2i((bounds.position * image_scale).floor()), Vector2i((bounds.size * image_scale).ceil()) + Vector2i.ONE)
	source_bounds = source_bounds.intersection(Rect2i(Vector2i.ZERO, _pending_backdrop.get_size()))
	if source_bounds.size.x <= 0 or source_bounds.size.y <= 0:
		_pending_backdrop = null
		return
	_backdrop = ImageTexture.create_from_image(_pending_backdrop.get_region(source_bounds))
	_pending_backdrop = null
	var glass_material := _glass.material as ShaderMaterial
	glass_material.set_shader_parameter("backdrop_texture", _backdrop)
	glass_material.set_shader_parameter("backdrop_origin", Vector2(source_bounds.position) / source_size)
	glass_material.set_shader_parameter("backdrop_extent", Vector2(source_bounds.size) / source_size)


## 系统改变窗口尺寸时关闭已有菜单，避免沿旧背景副本显示偏移的玻璃。
func _on_viewport_resized() -> void:
	if is_instance_valid(_popup) and _popup.visible:
		_popup.hide()


## 关闭菜单立即移除玻璃，不残留遮罩，也不接管焦点恢复与点击关闭行为。
func _hide_surface() -> void:
	hide()
	set_process(false)
	_backdrop = null
	_pending_backdrop = null
	if is_instance_valid(_glass):
		(_glass.material as ShaderMaterial).set_shader_parameter("backdrop_texture", null)
	if is_instance_valid(_native_content):
		_native_content.texture = null


## 独立原生窗口和页面销毁恢复原外观；隐藏时保留透明目标避免下次打开复用不透明缓冲。
func _restore_popup() -> void:
	if is_instance_valid(_popup) and _original_style != null:
		_popup.add_theme_stylebox_override("panel", _original_style)
		_popup.transparent_bg = _original_transparent
		_popup.transparent = _original_window_transparent


## 页面销毁时恢复借用的原生外观，迟到的打开回调不会重新生成浮层。
func _exit_tree() -> void:
	_hide_surface()
	_restore_popup()
