class_name SettingsContentFade
extends AlphaCanvasGroup
## 只合成设置页内容子树；页头和弹出窗口由外层保留在本组之外。

const TOP_FADE_WIDTH := 48.0
const CONTENT_TOP_GAP := 12
const CARD_CONTENT_TOP_PADDING := 92
const CARD_FOCUS_TOP_INSET := 80.0
const CONTENT_SCALE := 0.8
const SCROLLBAR_GUTTER := 24.0
const FADE_SHADER := preload("res://assets/ui/settings_content_fade.gdshader")

var _fade_material := ShaderMaterial.new()
var _fade_parameters := Vector4(-1.0, 1.0, 1.0, -1.0)


## 在加入场景树前准备材质，调用者可以先设定淡出范围再挂入真实设置控件。
func _init() -> void:
	_fade_material.shader = FADE_SHADER
	material = _fade_material


## 上下边界均用视口逻辑坐标；负的底边保留旧单向入口，双向渐隐只削减内容透明度。
func set_fade(top_y: float, width: float, viewport_height: float, bottom_y: float = -1.0) -> void:
	var parameters := Vector4(top_y, maxf(width, 1.0), maxf(viewport_height, 1.0), bottom_y)
	if parameters == _fade_parameters:
		return
	_fade_parameters = parameters
	# 仅在布局边界改变时更新；滚动直接移动原控件，无需逐帧同步或复制界面。
	_fade_material.set_shader_parameter("fade_top_y", parameters.x)
	_fade_material.set_shader_parameter("fade_width", parameters.y)
	_fade_material.set_shader_parameter("viewport_height", parameters.z)
	_fade_material.set_shader_parameter("fade_bottom_y", parameters.w)


## 正文保持原逻辑宽度并统一缩到八成，只有水平冲突时才避让固定导航的实际文字。
static func content_rect(surface: Control, preferred_width: float, minimum_width: float, navigation_title: Label = null) -> Rect2:
	var width := minf(preferred_width, maxf(0.0, (surface.size.x - 64.0) / CONTENT_SCALE - SCROLLBAR_GUTTER))
	width = maxf(width, minimum_width)
	var left := (surface.size.x - width * CONTENT_SCALE) * 0.5
	if is_instance_valid(navigation_title) and navigation_title.is_visible_in_tree():
		# 标题的布局框会占满整行，只用真实本土化文字宽度计算导航占位。
		var title_width := navigation_title.get_combined_minimum_size().x
		var title_right := navigation_title.get_global_transform() * Vector2(title_width, 0.0)
		var safe_left := (surface.get_global_transform().affine_inverse() * title_right).x + 16.0
		if left < safe_left:
			left = safe_left
			var available := (surface.size.x - left - 32.0) / CONTENT_SCALE - SCROLLBAR_GUTTER
			width = maxf(minimum_width, minf(width, available))
			# 极小独立面板仍优先保留控件最小宽度，不能被原生布局悄悄撑出右边界。
			left = minf(left, maxf(0.0, surface.size.x - (width + SCROLLBAR_GUTTER) * CONTENT_SCALE - 32.0))
	return Rect2(Vector2(left, 0.0), Vector2((width + SCROLLBAR_GUTTER) * CONTENT_SCALE, surface.size.y))


## 仅设置页纵条采用透明轨道和低对比蓝灰滑块，闲置隐藏仍由原控制器处理。
static func style_scrollbar(bar: VScrollBar) -> void:
	for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxFlat.new()
		var opacity := 0.0 if state.begins_with("scroll") else 0.18
		if state == "grabber_highlight":
			opacity = 0.26
		elif state == "grabber_pressed":
			opacity = 0.34
		style.bg_color = Color(0.50, 0.57, 0.66, opacity)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(4.0)
		bar.add_theme_stylebox_override(state, style)


## CanvasGroup 会截断 Control 的主题继承，显式沿原面板祖先取得相同主题。
static func inherited_theme(source: Control) -> Theme:
	var ancestor: Node = source
	while ancestor != null:
		if ancestor is Control or ancestor is Window:
			var inherited: Theme = ancestor.get("theme") as Theme
			if inherited != null:
				return inherited
		ancestor = ancestor.get_parent()
	return GameTheme.create_theme()
