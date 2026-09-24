class_name SettingsContentFade
extends AlphaCanvasGroup
## 只合成设置页内容子树；页头和弹出窗口由外层保留在本组之外。

const TOP_FADE_WIDTH := 48.0
const CONTENT_TOP_GAP := 12
const FADE_SHADER := preload("res://assets/ui/settings_content_fade.gdshader")

var _fade_material := ShaderMaterial.new()
var _fade_parameters := Vector3(-1.0, 1.0, 1.0)


## 在加入场景树前准备材质，调用者可以先设定淡出范围再挂入真实设置控件。
func _init() -> void:
	_fade_material.shader = FADE_SHADER
	material = _fade_material


## 参数均为所属视口的逻辑坐标；顶线及其上方全透明，向下经过 width 后完全保留。
func set_fade(top_y: float, width: float, viewport_height: float) -> void:
	var parameters := Vector3(top_y, maxf(width, 1.0), maxf(viewport_height, 1.0))
	if parameters == _fade_parameters:
		return
	_fade_parameters = parameters
	# 仅在布局边界改变时更新；滚动直接移动原控件，无需逐帧同步或复制界面。
	_fade_material.set_shader_parameter("fade_top_y", parameters.x)
	_fade_material.set_shader_parameter("fade_width", parameters.y)
	_fade_material.set_shader_parameter("viewport_height", parameters.z)


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
