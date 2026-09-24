class_name MainMenuBackground
extends Control
## 开始页的静态图片背景：保持原图，等比铺满，再缓存两次高斯卷积的结果。

const SOURCE_TEXTURE: Texture2D = preload("res://assets/backgrounds/main_menu.png")
const BLUR_SHADER: Shader = preload("res://assets/ui/main_background_blur.gdshader")
const ROUNDED_SHADER: Shader = preload("res://assets/ui/rounded_background.gdshader")
const BLUR_SIGMA := 64.0
const DOWNSAMPLE := 4.0

var blur_sigma := BLUR_SIGMA
var corner_radius := 0.0
var _rounded_material: ShaderMaterial
var _source_texture: Texture2D = SOURCE_TEXTURE
var _settings: GameSettings
var _selected_path := "res://assets/backgrounds/main_menu.png"
var _source: SubViewport
var _horizontal: SubViewport
var _vertical: SubViewport
var _source_surface: ColorRect
var _horizontal_surface: ColorRect
var _vertical_surface: ColorRect
var _source_material: ShaderMaterial
var _horizontal_material: ShaderMaterial
var _vertical_material: ShaderMaterial
var _display: TextureRect
var _active := false
var _dirty := true
var _render_phase := 0
var _cached_size := Vector2.ZERO


## 构建独立离屏通道；尚未进入开始页时不渲染，也不接收鼠标或键盘输入。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_process(false)
	clip_contents = true
	_source = _make_viewport("CoverSource")
	_horizontal = _make_viewport("HorizontalBlur")
	_vertical = _make_viewport("VerticalBlur")
	_source_material = _make_material(_source_texture, Vector2.ZERO)
	_source_material.set_shader_parameter("cover_only", true)
	_horizontal_material = _make_material(_source.get_texture(), Vector2.RIGHT)
	_vertical_material = _make_material(_horizontal.get_texture(), Vector2.DOWN)
	_source_surface = _make_surface(_source, _source_material)
	_horizontal_surface = _make_surface(_horizontal, _horizontal_material)
	_vertical_surface = _make_surface(_vertical, _vertical_material)
	_display = TextureRect.new()
	_display.name = "BlurredBackground"
	_display.texture = _vertical.get_texture()
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if corner_radius > 0.0:
		_rounded_material = ShaderMaterial.new()
		_rounded_material.shader = ROUNDED_SHADER
		_rounded_material.set_shader_parameter("corner_radius", corner_radius)
		_rounded_material.set_shader_parameter("rect_size", size)
		_display.material = _rounded_material
	_display.hide()
	add_child(_display)
	_display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_on_resized)
	visible = _active and _source_texture != null
	if visible:
		_request_render()


## 共用设置的变化只影响背景，不重建前景菜单或重新加载其他页面。
func set_settings(model: GameSettings) -> void:
	if _settings != null and _settings.changed.is_connected(_apply_background_preference):
		_settings.changed.disconnect(_apply_background_preference)
	_settings = model
	if _settings != null:
		_settings.changed.connect(_apply_background_preference)
		_apply_background_preference()


## 自带背景复用导入纹理，自定义背景从游戏管理目录读取；丢失图片回退自带背景。
func _apply_background_preference() -> void:
	var path := _settings.get_menu_background_path()
	if path == _selected_path:
		return
	_selected_path = path
	if path.is_empty():
		set_texture(null)
	elif path == "res://assets/backgrounds/main_menu.png":
		set_texture(SOURCE_TEXTURE)
	else:
		var picture := Image.new()
		if picture.load(path) == OK and not picture.is_empty():
			set_texture(ImageTexture.create_from_image(picture))
		else:
			set_texture(SOURCE_TEXTURE)


## 更换背景时丢弃旧模糊缓存；空纹理显示底层原有纯色背景。
func set_texture(texture: Texture2D) -> void:
	if texture == _source_texture:
		return
	_source_texture = texture
	_dirty = true
	visible = _active and texture != null
	if not is_node_ready():
		return
	_stop_rendering()
	_display.hide()
	_source_material.set_shader_parameter("input_texture", texture)
	if visible:
		_request_render()


## 页面切换只改变背景可见性；离开开始页立即停掉未完成的离屏渲染。
func set_active(active: bool) -> void:
	_active = active
	visible = active and _source_texture != null
	if not is_node_ready():
		return
	if not visible:
		_stop_rendering()
		return
	if _dirty or not size.is_equal_approx(_cached_size):
		_request_render()


## 纯色不需要缓存；真实窗口必须等待三次渲染完成，无绘图的测试环境可直接就绪。
func is_render_ready() -> bool:
	if DisplayServer.get_name() == "headless" or _source_texture == null:
		return true
	return is_node_ready() and _active and not _dirty and _render_phase == 0 and is_instance_valid(_display) and _display.visible and size.is_equal_approx(_cached_size)


## 离开场景树前取消绘制回调，防止窗口关闭时访问已释放的离屏节点。
func _exit_tree() -> void:
	_stop_rendering()
	if _settings != null and _settings.changed.is_connected(_apply_background_preference):
		_settings.changed.disconnect(_apply_background_preference)


## 创建四分之一尺寸的缓存视口，禁用三维及持续刷新以减少静态背景开销。
func _make_viewport(node_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = node_name
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	add_child(viewport)
	return viewport


## 原图先等比缩成缓存，再进行密集高斯采样，避免直接稀疏读取大图产生条纹。
func _make_material(texture: Texture2D, axis: Vector2) -> ShaderMaterial:
	var blur_material := ShaderMaterial.new()
	blur_material.shader = BLUR_SHADER
	blur_material.set_shader_parameter("input_texture", texture)
	blur_material.set_shader_parameter("blur_axis", axis)
	blur_material.set_shader_parameter("blur_sigma", blur_sigma)
	return blur_material


## 离屏矩形覆盖其缓存视口，完全忽略输入，避免影响中央菜单的交互。
func _make_surface(viewport: SubViewport, blur_material: ShaderMaterial) -> ColorRect:
	var surface := ColorRect.new()
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.material = blur_material
	viewport.add_child(surface)
	return surface


## 窗口尺寸变化使缓存失效；隐藏期间只记录，回到开始页才重新计算。
func _on_resized() -> void:
	if _rounded_material != null:
		_rounded_material.set_shader_parameter("rect_size", size)
	_dirty = true
	if _active and _source_texture != null and is_node_ready():
		_request_render()


## 按逻辑像素计算居中裁剪和模糊强度；缩小缓存分辨率不会改变模糊半径。
func _request_render() -> void:
	if _source_texture == null or size.x < 1.0 or size.y < 1.0:
		return
	_cached_size = size
	_dirty = true
	var render_size := Vector2i(maxi(1, ceili(size.x / DOWNSAMPLE)), maxi(1, ceili(size.y / DOWNSAMPLE)))
	# 改变缓存尺寸会清空旧纹理，缓存和两次卷积完成前显示底层浅灰，避免黑帧。
	if _vertical.size != render_size:
		_display.hide()
	_source.size = render_size
	_horizontal.size = render_size
	_vertical.size = render_size
	_source_surface.size = Vector2(render_size)
	_horizontal_surface.size = Vector2(render_size)
	_vertical_surface.size = Vector2(render_size)
	var source_size := _source_texture.get_size()
	var cover_scale := maxf(size.x / source_size.x, size.y / source_size.y)
	var visible_uv := size / (source_size * cover_scale)
	_source_material.set_shader_parameter("uv_scale", visible_uv)
	_source_material.set_shader_parameter("uv_offset", (Vector2.ONE - visible_uv) * 0.5)
	_source_material.set_shader_parameter("input_pixel_size", Vector2.ONE / source_size)
	_horizontal_material.set_shader_parameter("input_pixel_size", Vector2.ONE / Vector2(render_size))
	_vertical_material.set_shader_parameter("input_pixel_size", Vector2.ONE / Vector2(render_size))
	_horizontal_material.set_shader_parameter("logical_size", size)
	_vertical_material.set_shader_parameter("logical_size", size)
	_vertical.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_horizontal.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_source.render_target_update_mode = SubViewport.UPDATE_ONCE
	_render_phase = 1
	if not RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)


## 每个通道仅渲染一帧；纵向卷积完成后才显示结果，避免原图或半成品闪现。
func _on_frame_post_draw() -> void:
	if not _active:
		_stop_rendering()
		return
	if _render_phase == 1:
		_source.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_horizontal.render_target_update_mode = SubViewport.UPDATE_ONCE
		_render_phase = 2
	elif _render_phase == 2:
		_horizontal.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_vertical.render_target_update_mode = SubViewport.UPDATE_ONCE
		_render_phase = 3
	elif _render_phase == 3:
		_display.show()
		_dirty = false
		_stop_rendering()


## 清理一次性刷新；缓存纹理仍保留，可供同尺寸返回开始页时直接复用。
func _stop_rendering() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	if is_instance_valid(_source):
		_source.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_horizontal):
		_horizontal.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_vertical):
		_vertical.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_render_phase = 0
