extends Node2D
## 仅观察所属控件的实际变换；不参与 UI 排版，不轮询场景树，也不修改共享字体资源。

var _refresh_pending := false
var _window_draw_refresh: Callable
var _popup_original_font: Font
var _popup_had_override := false
var _popup_font: FontVariation
var _popup_base: FontFile


## 祖先缩放也会传播至这个画布节点，避免只监听 Control 自身矩形而漏掉父卡片缩放。
func _init() -> void:
	set_notify_transform(true)


## 移出后重用同一控件时也重新读取新父级的真实矩阵。
func _enter_tree() -> void:
	var item := get_parent() as CanvasItem
	var viewport := get_viewport()
	if is_instance_valid(item) and viewport.has_meta("ui_font_raster_observer"):
		var reference := viewport.get_meta("ui_font_raster_observer") as WeakRef
		var observer: Node = reference.get_ref() if reference != null else null
		if is_instance_valid(observer):
			# 原生菜单后续布局可能才提交实际比例；绘制之后延迟补齐临时字体，不占用每帧轮询。
			_window_draw_refresh = observer.request_refresh
			item.draw.connect(_window_draw_refresh)
	request_refresh()


## 控件可能被保留后放入别的窗口，解除旧视口的绘制监听以免影响旧弹层。
func _exit_tree() -> void:
	var item := get_parent() as CanvasItem
	if is_instance_valid(item) and _window_draw_refresh.is_valid() and item.draw.is_connected(_window_draw_refresh):
		item.draw.disconnect(_window_draw_refresh)
	_window_draw_refresh = Callable()
	if get_parent() is PopupMenu:
		_release_popup_font(get_parent() as PopupMenu)


## 隐藏时原生采样不会更新；恢复显示必须重新检查，尤其是菜单淡入期间的父级动画。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_VISIBILITY_CHANGED:
		request_refresh()


## 同一帧的位置、布局、可见性及比例变化只安排一次刷新，稳定画面不产生工作。
func request_refresh() -> void:
	if not is_inside_tree() or _refresh_pending:
		return
	_refresh_pending = true
	_refresh.call_deferred()


## 4.7 的采样通知可能先读取旧矩阵；矩阵更新后重设原生采样并在绘制回调外请求重绘。
## 原生接口管理实际采样纹理的引用计数，过时比例会释放，不积累每帧的字体副本。
func _refresh() -> void:
	_refresh_pending = false
	if get_parent() is PopupMenu:
		_refresh_popup_font(get_parent() as PopupMenu)
		return
	var item := get_parent() as CanvasItem
	if not is_instance_valid(item) or not item.is_inside_tree():
		return
	# 同时刷新观察节点自身缓存，否则下次祖先失效传播可能把它视为仍未更新而提前停止。
	get_global_transform()
	if not item.is_visible_in_tree():
		if item.has_meta("ui_font_raster_scale"):
			item.remove_meta("ui_font_raster_scale")
		return
	var factor := item.get_global_transform().get_scale()
	if item.has_meta("ui_font_raster_scale") and factor.is_equal_approx(item.get_meta("ui_font_raster_scale")):
		return
	item.set_meta("ui_font_raster_scale", factor)
	item.call("set_oversampling_with_scale", 1)
	item.call("set_oversampling_with_scale", 2)
	item.queue_redraw()


## 原生弹层的布局会重置视口采样；只为打开的菜单创建相同字体的临时栅格缓存。
## 不改窗口尺寸、视口或共享字体，关闭后恢复原字体并释放该缓存，避免每个隐藏菜单常驻副本。
func _refresh_popup_font(popup: PopupMenu) -> void:
	if not popup.is_inside_tree():
		return
	if not popup.visible:
		_release_popup_font(popup)
		return
	var parent_viewport := popup.get_parent().get_viewport()
	var inherited := 1.0
	if parent_viewport.has_method("get_oversampling"):
		inherited = float(parent_viewport.call("get_oversampling"))
	# 嵌入窗口仅缺少自身比例，保留父视口的 Retina 基准；独立原生窗口已有自身 DPI 采样。
	var desired := inherited * popup.content_scale_factor if popup.is_embedded() else inherited
	if not popup.is_embedded() and popup.has_method("get_oversampling"):
		desired = float(popup.call("get_oversampling"))
	if is_equal_approx(popup.content_scale_factor, 1.0):
		_release_popup_font(popup)
		return
	if _popup_font == null:
		var original := popup.get_theme_font("font")
		if not original is FontVariation or not original.base_font is FontFile:
			return
		_popup_original_font = original
		_popup_had_override = popup.has_theme_font_override("font")
		_popup_base = original.base_font.duplicate() as FontFile
		_popup_font = original.duplicate() as FontVariation
		_popup_font.base_font = _popup_base
		popup.add_theme_font_override("font", _popup_font)
		popup.set_meta("ui_font_raster_popup_font", _popup_font)
	if not is_equal_approx(_popup_base.oversampling, desired):
		_popup_base.oversampling = desired
	popup.set_meta("ui_font_raster_window_factor", desired)


## 还原精确的原字体覆盖状态，原有主题及其它菜单不受临时采样影响。
func _release_popup_font(popup: PopupMenu) -> void:
	if _popup_font == null:
		return
	if _popup_had_override:
		popup.add_theme_font_override("font", _popup_original_font)
	else:
		popup.remove_theme_font_override("font")
	popup.remove_meta("ui_font_raster_popup_font")
	_popup_original_font = null
	_popup_font = null
	_popup_base = null
