class_name GameWindowController
extends Node
## 只管理桌面窗口呈现；设置模型保持纯数据，地图与模拟坐标不受物理窗口尺寸影响。

signal availability_changed

const CONTENT_SIZE := Vector2i(1280, 800)
const SCREEN_MARGIN := Vector2i(32, 32)
const MIN_WINDOWS_LAYOUT := Vector2i(1000, 560)

var settings: GameSettings
var available_resolutions := PackedStringArray()
var available_ui_scales := PackedInt32Array()
var effective_ui_scale := 100
# 测试可注入平台和只读屏幕尺寸；正式运行始终取当前窗口所在的系统显示器。
var platform_name: String = OS.get_name()
var screen_size_provider: Callable
var _font_scale: GameFontScale
var _window: Window
var _applied_resolution := ""
var _usable_rect := Rect2i()
var _screen_check_elapsed := 0.0
var _switch_generation := 0
var _windowed_decorations := Vector2i.ZERO
var _screen_size := Vector2i.ZERO
var _last_scale_preference := -1


## 在绘制游戏页面前恢复窗口偏好；扩展逻辑画幅，保持等比且不产生宽高比黑边。
func _ready() -> void:
	_window = get_window()
	_window.min_size = Vector2i.ZERO
	_window.content_scale_size = CONTENT_SIZE
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	_window.unresizable = true
	settings.changed.connect(_on_settings_changed)
	_font_scale = GameFontScale.new()
	_font_scale.scope = get_parent()
	_font_scale.layout_check = _ensure_text_layout_fits
	add_child(_font_scale)
	_refresh_screen()
	_on_settings_changed()


## 页面宿主释放时断开共享设置引用，避免后续设置变化操作已销毁的窗口控制器。
func _exit_tree() -> void:
	if settings != null and settings.changed.is_connected(_on_settings_changed):
		settings.changed.disconnect(_on_settings_changed)


## 低频检查屏幕移动、分辨率或任务栏变化；不因每帧或音量变化重置窗口位置。
func _process(delta: float) -> void:
	_screen_check_elapsed += delta
	if _screen_check_elapsed < 0.5:
		return
	_screen_check_elapsed = 0.0
	if _current_usable_rect() != _usable_rect or _current_screen_size() != _screen_size:
		_refresh_screen()
		_on_settings_changed()
		_keep_window_on_screen()


## 无界面回归没有真实屏幕限制；桌面使用窗口当前所在屏幕的可用区域。
func _current_usable_rect() -> Rect2i:
	if DisplayServer.get_name() == "headless":
		return Rect2i(0, 0, 8192, 8192)
	return DisplayServer.screen_get_usable_rect(_window.current_screen)


## 4K 能力取整块屏幕的像素尺寸，任务栏与窗口客户区不能误把 UHD 判断成普通显示器。
func _current_screen_size() -> Vector2i:
	if screen_size_provider.is_valid():
		return screen_size_provider.call()
	if DisplayServer.get_name() == "headless":
		return Vector2i(8192, 8192)
	return DisplayServer.screen_get_size(_window.current_screen)


## 只有 Windows 开放手动缩放，横竖屏 UHD 及更大尺寸额外提供 150% 和 200%。
static func ui_scales_for_screen(platform: String, dimensions: Vector2i) -> PackedInt32Array:
	if platform != "Windows":
		return PackedInt32Array()
	var result := PackedInt32Array([100, 110, 125])
	if maxi(dimensions.x, dimensions.y) >= 3840 and mini(dimensions.x, dimensions.y) >= 2160:
		result.append_array(PackedInt32Array([150, 200]))
	return result


## 按客户区与系统标题栏的实际占地筛选预设，最大化始终可以选择。
func _refresh_screen() -> void:
	_usable_rect = _current_usable_rect()
	_screen_size = _current_screen_size()
	available_ui_scales = ui_scales_for_screen(platform_name, _screen_size)
	effective_ui_scale = settings.ui_scale if available_ui_scales.has(settings.ui_scale) else 100
	_last_scale_preference = settings.ui_scale
	if DisplayServer.get_name() != "headless" and _window.mode == Window.MODE_WINDOWED:
		_windowed_decorations = (_window.get_size_with_decorations() - _window.size).max(Vector2i.ZERO)
	var minimum := MIN_WINDOWS_LAYOUT if platform_name == "Windows" else Vector2i.ZERO
	available_resolutions = resolutions_for_area(_usable_rect.size - _windowed_decorations - SCREEN_MARGIN, minimum)
	availability_changed.emit()


## 独立计算可容纳的预设，便于验证小屏幕与多显示器边界，不查询系统状态。
static func resolutions_for_area(area: Vector2i, minimum: Vector2i = Vector2i.ZERO) -> PackedStringArray:
	var result := PackedStringArray()
	for value: String in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS:
		if value == "maximized":
			result.append(value)
			continue
		var dimensions := resolution_size(value)
		if dimensions.x <= area.x and dimensions.y <= area.y and dimensions.x >= minimum.x and dimensions.y >= minimum.y:
			result.append(value)
	return result


## 稳定设置键转换为客户区尺寸；仅对已验证的预设调用。
static func resolution_size(value: String) -> Vector2i:
	var parts := value.split("x")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO


## 不合当前屏幕的旧偏好仅在内存回退，启动不擅自重写旧配置或损坏文件。
func _on_settings_changed() -> void:
	if settings.ui_scale != _last_scale_preference:
		_refresh_screen()
	_apply_ui_scale()
	var requested := settings.window_resolution
	if not available_resolutions.has(requested):
		var target := resolution_size(requested).max(_window.min_size)
		var fallback := "maximized" if available_resolutions.size() == 1 else available_resolutions[available_resolutions.size() - 2]
		# 不足基本布局的小窗口增长到最近可用尺寸；屏幕变小仍沿用最大可用回退。
		if platform_name == "Windows" and resolution_size(requested) != Vector2i.ZERO and (resolution_size(requested).x < _window.min_size.x or resolution_size(requested).y < _window.min_size.y):
			for candidate: String in available_resolutions:
				var dimensions := resolution_size(candidate)
				if dimensions.x >= target.x and dimensions.y >= target.y:
					fallback = candidate
					break
		requested = fallback
		settings.window_resolution = requested
		settings.changed.emit()
	if requested == _applied_resolution:
		return
	_applied_resolution = requested
	_switch_generation += 1
	if requested == "maximized":
		# macOS 拒绝直接最大化不可缩放窗口；只在提交系统模式切换时临时解除限制。
		_window.unresizable = false
		_window.mode = Window.MODE_MAXIMIZED
		_lock_after_maximize.call_deferred(_switch_generation)
	else:
		_window.mode = Window.MODE_WINDOWED
		_window.unresizable = true
		_window.size = resolution_size(requested)
		_window.position = _usable_rect.position + (_usable_rect.size - _window.size) / 2
		_keep_window_on_screen()


## Windows 只放大字号，画布与图标保持像素大小；其他平台继续原画幅策略且字号保持一倍。
func _apply_ui_scale() -> void:
	var windows := platform_name == "Windows"
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED if windows else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_window.content_scale_factor = 1.0
	_window.min_size = MIN_WINDOWS_LAYOUT if windows else Vector2i.ZERO
	_font_scale.set_percentage(effective_ui_scale if windows else 100)


## 等待文字的原生最小尺寸更新，只在正文布局确实溢出时增加窗口；滚动内容不迫使窗口长高。
func _ensure_text_layout_fits() -> void:
	if platform_name != "Windows" or effective_ui_scale <= 100 or settings.window_resolution == "maximized":
		return
	# 无显示驱动的 mode 不对应真实桌面状态；正常桌面不在最小化窗口上改变边界。
	if DisplayServer.get_name() != "headless" and _window.mode != Window.MODE_WINDOWED:
		return
	var required := MIN_WINDOWS_LAYOUT
	for child in get_parent().get_children():
		if child is Container and child.is_visible_in_tree():
			required = required.max(Vector2i(child.get_combined_minimum_size().ceil()))
	if required.x <= _window.size.x and required.y <= _window.size.y:
		return
	var capacity := _usable_rect.size - _windowed_decorations - SCREEN_MARGIN
	var target := _window.size.max(required)
	# 仅在当前窗口不够时找最近可容纳预设；超过显示器时交给最大化和原有滚动布局。
	var fallback := "maximized"
	for candidate in resolutions_for_area(capacity, target):
		fallback = candidate
		break
	if fallback != settings.window_resolution:
		settings.window_resolution = fallback
		settings.changed.emit()


## 屏幕缩小或拔除后只修正越界位置；有效位置不因任务栏变化而重新居中。
func _keep_window_on_screen() -> void:
	if _window.mode != Window.MODE_WINDOWED or DisplayServer.get_name() == "headless":
		return
	var decorated_position := _window.get_position_with_decorations()
	var extent := _window.get_size_with_decorations()
	var maximum := (_usable_rect.end - extent).max(_usable_rect.position)
	var clamped := decorated_position.clamp(_usable_rect.position, maximum)
	_window.position += clamped - decorated_position


## 模式切换提交后恢复拖动限制；快速改选时旧回调不得干扰新的窗口尺寸。
func _lock_after_maximize(generation: int) -> void:
	if generation == _switch_generation:
		_window.unresizable = true
