class_name ScrollContentFade
extends Control
## 滚动内容统一透明渐隐；导航与背景独立绘制，原生滚动条保持自身透明度。

const FADE_WIDTH := 48.0
const FOCUS_GAP := 8.0
const FADE_SHADER := preload("res://assets/ui/map_editor_properties_fade.gdshader")

var top_extension := 0.0
var fade_bottom_enabled := true

var _scroll: ScrollContainer
var _group := AlphaCanvasGroup.new()
var _fade_material := ShaderMaterial.new()


## 保留容器最小宽度和鼠标冒泡，合成层只负责显示，不接管滚动与表单输入。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_group.name = "ScrollDrawingGroup"
	_fade_material.shader = FADE_SHADER
	_fade_material.set_shader_parameter("fade_width", FADE_WIDTH)
	_group.material = _fade_material
	add_child(_group)
	resized.connect(_layout_scroll)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)


## 原滚动容器保持同一实例与主题；尺寸显式跟随白卡原内容区域。
func set_scroll(scroll: ScrollContainer) -> void:
	_scroll = scroll
	_scroll.theme = SettingsContentFade.inherited_theme(self)
	if top_extension > 0.0:
		# 向标题下方延伸裁切区域，同时等量补回内容留白，首行与滚动范围均不位移。
		var padding := MarginContainer.new()
		padding.name = "ScrollTopPadding"
		padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		padding.add_theme_constant_override("margin_top", roundi(top_extension))
		for child in _scroll.get_children():
			if child is Control and child != _scroll.get_v_scroll_bar() and child != _scroll.get_h_scroll_bar():
				_scroll.remove_child(child)
				padding.add_child(child)
		_scroll.add_child(padding)
	_group.add_child(_scroll)
	_scroll.minimum_size_changed.connect(_on_minimum_size_changed)
	_scroll.resized.connect(_sync_fade)
	_scroll.sort_children.connect(_sync_fade.call_deferred)
	_scroll.get_v_scroll_bar().changed.connect(_sync_fade)
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)
	_layout_scroll()
	update_minimum_size()


## 将原滚动容器的最小尺寸传给外层PanelContainer，避免新增合成层撑大或压窄侧栏。
func _get_minimum_size() -> Vector2:
	if not is_instance_valid(_scroll):
		return Vector2.ZERO
	var minimum := _scroll.get_combined_minimum_size()
	return Vector2(minimum.x, maxf(0.0, minimum.y - top_extension))


## 动态折叠、翻译及新增表单仍通过原容器重新计算最小宽度。
func _on_minimum_size_changed() -> void:
	update_minimum_size()
	_sync_fade.call_deferred()


## 仅扩展标题下方可用的留白；渐隐坐标与滚动裁切矩形仍共用一个原点。
func _layout_scroll() -> void:
	if not is_instance_valid(_scroll):
		return
	_group.position = Vector2(0, -top_extension)
	_scroll.position = Vector2.ZERO
	_scroll.size = size + Vector2(0, top_extension)
	_sync_fade()


## 只更新渐隐参数，不修改滚动数值或地图编辑事务。
func _on_scroll_changed(_value: float) -> void:
	_sync_fade()


## 仅剩余内容存在的边缘渐隐，到顶或到底时平滑恢复完整正文；滚动条不套边缘透明度。
func _sync_fade() -> void:
	if not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	var remaining := maxf(0.0, bar.max_value - bar.page - bar.value)
	var content_right := bar.position.x if bar.visible else _scroll.size.x
	_fade_material.set_shader_parameter("content_size", Vector2(content_right, _scroll.size.y))
	_fade_material.set_shader_parameter("edge_strength", Vector2(
		smoothstep(0.0, FADE_WIDTH, bar.value),
		smoothstep(0.0, FADE_WIDTH, remaining) if fade_bottom_enabled else 0.0
	))


## 键盘或程序定位焦点时避开淡隐带，鼠标操作保持点击位置不突然滚动。
func _on_focus_changed(control: Control) -> void:
	if not is_instance_valid(_scroll) or not is_instance_valid(control) or not _scroll.is_ancestor_of(control):
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	_ensure_focus_readable.call_deferred(control)


## 原生follow_focus完成后补足上下渐隐余量；尽头由滚动条夹紧，届时对应遮罩关闭。
func _ensure_focus_readable(control: Control) -> void:
	if not is_instance_valid(control) or not control.is_visible_in_tree() or not _scroll.is_ancestor_of(control):
		return
	var bar := _scroll.get_v_scroll_bar()
	var remaining := maxf(0.0, bar.max_value - bar.page - bar.value)
	var factor := absf(_scroll.get_global_transform().get_scale().y)
	var visible_rect := _scroll.get_global_rect()
	var top := visible_rect.position.y + ((FADE_WIDTH + FOCUS_GAP) * factor if bar.value > 0.0 else 0.0)
	var bottom := visible_rect.end.y - ((FADE_WIDTH + FOCUS_GAP) * factor if fade_bottom_enabled and remaining > 0.0 else 0.0)
	var focused_rect := control.get_global_rect()
	if focused_rect.position.y < top:
		_scroll.scroll_vertical += floori((focused_rect.position.y - top) / factor)
	elif focused_rect.end.y > bottom:
		_scroll.scroll_vertical += ceili((focused_rect.end.y - bottom) / factor)
