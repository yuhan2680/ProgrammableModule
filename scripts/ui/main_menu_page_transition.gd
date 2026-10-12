class_name MainMenuPageTransition
extends CanvasLayer
## 主菜单入口的临时呈现层：白卡扩展、原生菜单内容淡出，再揭开已排好版的目标页。

var expansion_progress := 0.0
var _source_card: Panel
var _overlay: Control
var _surface: Panel
var _content: Control
var _surface_style: StyleBoxFlat
var _source_style: StyleBoxFlat


## 浮层覆盖提示与普通页面，动画中的鼠标不能穿透到旧菜单或新页面。
func _ready() -> void:
	layer = 1026
	_overlay = Control.new()
	_overlay.name = "MenuTransitionOverlay"
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.resized.connect(_layout_transition)
	_surface = Panel.new()
	_surface.name = "ExpandingMenuSurface"
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_surface)
	_content = Control.new()
	_content.name = "FadingMenuContent"
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_content)
	set_process(false)


## 保留同一批文字和按钮的原始尺寸，仅把白卡表面与内容的动画分开。
func begin(card: Panel) -> void:
	_source_card = card
	# 跨 CanvasLayer 时显式沿用原主题，不能回退到引擎字体而改变字形与行高。
	var theme_owner := card.get_parent_control()
	while theme_owner != null and theme_owner.theme == null:
		theme_owner = theme_owner.get_parent_control()
	if theme_owner != null:
		_overlay.theme = theme_owner.theme
	_source_style = card.get_theme_stylebox("panel") as StyleBoxFlat
	_surface_style = _source_style.duplicate() as StyleBoxFlat
	_surface.add_theme_stylebox_override("panel", _surface_style)
	_layout_transition()
	for child in card.get_children():
		child.reparent(_content, false)
	card.hide()
	set_process(true)


## 以进度重算矩形而不放大文字纹理；内容在卡片铺满前已完全淡出。
func set_expansion_progress(progress: float) -> void:
	expansion_progress = clampf(progress, 0.0, 1.0)
	_content.modulate.a = 1.0 - smoothstep(0.0, 0.72, expansion_progress)
	_layout_transition()


## 扩展阶段随原卡片布局与实际视口变化更新，Windows 大窗口与中途缩窗共用坐标。
func _process(_delta: float) -> void:
	_layout_transition()


## 浮层最后加入场景树，优先吞掉按键与点击，防止目的页的输入脚本在揭开期间抢先响应。
func _input(_event: InputEvent) -> void:
	if is_instance_valid(_overlay) and _overlay.visible:
		get_viewport().set_input_as_handled()


## 白卡从原来的屏幕矩形扩展到整个客户区，圆角与阴影在边界处平滑收尽。
func _layout_transition() -> void:
	if _surface_style == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if not is_instance_valid(_source_card):
		_surface.position = Vector2.ZERO
		_surface.size = viewport_size
		return
	var bounds := _source_card.get_global_rect()
	var factor := _source_card.get_global_transform().get_scale().x
	_surface.position = bounds.position.lerp(Vector2.ZERO, expansion_progress)
	_surface.size = bounds.size.lerp(viewport_size, expansion_progress)
	_surface_style.set_corner_radius_all(roundi(_source_style.corner_radius_top_left * factor * (1.0 - expansion_progress)))
	_surface_style.shadow_size = roundi(_source_style.shadow_size * factor * (1.0 - expansion_progress))
	_surface_style.shadow_offset = _source_style.shadow_offset * factor * (1.0 - expansion_progress)
	_content.position = bounds.position
	_content.size = _source_card.size
	_content.scale = Vector2.ONE * factor


## 页面构建前断开原卡片引用，满屏白色遮挡一直保留到新页面完成原生布局。
func prepare_reveal() -> void:
	set_expansion_progress(1.0)
	_content.hide()
	_source_card = null
	set_process(false)


## 仅降低遮挡层透明度，让目标页面的文字、图标及背景一起从白色中显现。
func set_reveal_progress(progress: float) -> void:
	_overlay.modulate.a = 1.0 - clampf(progress, 0.0, 1.0)


## 同步导航中断时归还旧菜单控件，恢复可见性，防止迟到的动画留下透明页面。
func cancel() -> void:
	set_process(false)
	_overlay.hide()
	if is_instance_valid(_source_card):
		for child in _content.get_children():
			child.reparent(_source_card, false)
		_source_card.show()
	_source_card = null
