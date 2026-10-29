extends Button
## 固定圆形蓝色操作按钮：曲面亮边与按下回弹只改变视觉，不移动命中区域。

# 源 XML 随脚本进入导出包，避免运行时读取已被纹理导入器替换的 SVG 文件。
const ICON_SVG := {
	"res://assets/ui/settings_option_check.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 18 18\"><path d=\"m3.2 9 3.7 4.1 7.9-9\" fill=\"none\" stroke=\"#ffffff\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>\n",
	"res://assets/ui/editor_test_arrow.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\" viewBox=\"0 0 48 48\"><path d=\"M7 24h31M27 13l12 11-12 11\" fill=\"none\" stroke=\"#fff\" stroke-width=\"3.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>\n",
}

var _surface: ColorRect
var _material: ShaderMaterial
var _motion: Tween
var _pressure := 0.0
var _icon_source_path := ""
var _icon_raster_scale := 0
var _icon_raster: Texture2D
var _icon_refresh_pending := false


## 无文字按钮通过本地化工具提示说明用途，白色 SVG 保持高分屏清晰。
func _init() -> void:
	set_notify_transform(true)
	custom_minimum_size = Vector2(32, 32)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	expand_icon = true
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_theme_constant_override("icon_max_width", 18)
	add_theme_constant_override("h_separation", 0)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		add_theme_color_override("icon_" + state + "_color", Color.WHITE)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## 将带厚度的蓝色玻璃画在图标下方，局部高光与正文的滚动裁剪自然一致。
func _ready() -> void:
	_surface = ColorRect.new()
	_surface.name = "BlueConfirmationGlass"
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.show_behind_parent = true
	_material = ShaderMaterial.new()
	_material.shader = load("res://assets/ui/editor_confirm_glass.gdshader")
	_surface.material = _material
	add_child(_surface)
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_sync_surface)
	mouse_entered.connect(_sync_surface)
	mouse_exited.connect(_sync_surface)
	button_down.connect(_animate_pressure.bind(1.0))
	button_up.connect(_animate_pressure.bind(0.0))
	focus_entered.connect(_sync_surface)
	focus_exited.connect(_sync_surface)
	visibility_changed.connect(_release_hidden)
	draw.connect(_request_icon_refresh)
	get_viewport().size_changed.connect(_request_icon_refresh)
	_sync_surface()
	_request_icon_refresh()


## 按下时微收缩、松开时柔和回弹，不让容器反复重新排版。
func _animate_pressure(target: float) -> void:
	if _motion != null and _motion.is_valid():
		_motion.kill()
	_motion = create_tween()
	_motion.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_motion.tween_method(_set_pressure, _pressure, target, 0.12 if target > 0.0 else 0.23)


## 动画参数只传给局部材质，图标与按钮位置始终稳定。
func _set_pressure(value: float) -> void:
	_pressure = value
	_sync_surface()


## 收起页面时清理按下效果，返回编辑器不会残留半按状态。
func _release_hidden() -> void:
	if not is_visible_in_tree():
		if _motion != null and _motion.is_valid():
			_motion.kill()
		_set_pressure(0.0)
	else:
		_request_icon_refresh()


## 控件大小和交互状态决定玻璃边缘与泛光，不创建额外焦点蓝框。
func _sync_surface() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("panel_size", size)
	_material.set_shader_parameter("pressure", _pressure)
	_material.set_shader_parameter("highlight", 1.0 if is_hovered() or has_focus() else 0.0)
	_material.set_shader_parameter("disabled", 1.0 if disabled else 0.0)


## 祖先页面缩放也触发采样更新；只改变图标纹理，不影响玻璃或控件布局。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready():
		_request_icon_refresh()


## 一帧中的变换、窗口尺寸和重绘只合并一次检查，不建立持续轮询或重复栅格化。
func _request_icon_refresh() -> void:
	if not is_inside_tree() or _icon_refresh_pending:
		return
	_icon_refresh_pending = true
	_refresh_icon_raster.call_deferred()


## 原始路径和实际屏幕倍率共同决定采样；保留逻辑十八像素、圆形命中区及未知外部图标。
func _refresh_icon_raster() -> void:
	_icon_refresh_pending = false
	if not is_inside_tree() or not is_visible_in_tree() or icon == null:
		return
	var source_path := _icon_source_path if icon == _icon_raster else icon.resource_path
	if not ICON_SVG.has(source_path):
		return
	var screen_scale := get_screen_transform().get_scale()
	var factor := maxf(absf(screen_scale.x), absf(screen_scale.y))
	# 至少四倍源图涵盖 Retina；额外采样保留分数比例的平滑边缘，上限避免极端缩放分配大图。
	var raster_scale := clampi(ceili(maxf(4.0, factor * 2.0)), 4, 16)
	if icon == _icon_raster and source_path == _icon_source_path and raster_scale == _icon_raster_scale:
		return
	var image := Image.new()
	if image.load_svg_from_string(ICON_SVG[source_path], float(raster_scale)) != OK:
		return
	image.generate_mipmaps()
	_icon_source_path = source_path
	_icon_raster_scale = raster_scale
	_icon_raster = ImageTexture.create_from_image(image)
	icon = _icon_raster
