class_name GameWindowController
extends Node
## 只管理桌面窗口呈现；设置模型保持纯数据，地图与模拟坐标不受物理窗口尺寸影响。

signal availability_changed

const CONTENT_SIZE := Vector2i(1280, 800)
const SCREEN_MARGIN := Vector2i(32, 32)

var settings: GameSettings
var available_resolutions := PackedStringArray()
var _window: Window
var _applied_resolution := ""
var _usable_rect := Rect2i()
var _screen_check_elapsed := 0.0
var _switch_generation := 0
var _windowed_decorations := Vector2i.ZERO


## 在绘制游戏页面前恢复窗口偏好；扩展逻辑画幅，保持等比且不产生宽高比黑边。
func _ready() -> void:
	_window = get_window()
	_window.min_size = Vector2i.ZERO
	_window.content_scale_size = CONTENT_SIZE
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	_window.unresizable = true
	settings.changed.connect(_on_settings_changed)
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
	if _current_usable_rect() != _usable_rect:
		_refresh_screen()
		_on_settings_changed()
		_keep_window_on_screen()


## 无界面回归没有真实屏幕限制；桌面使用窗口当前所在屏幕的可用区域。
func _current_usable_rect() -> Rect2i:
	if DisplayServer.get_name() == "headless":
		return Rect2i(0, 0, 8192, 8192)
	return DisplayServer.screen_get_usable_rect(_window.current_screen)


## 按客户区与系统标题栏的实际占地筛选预设，最大化始终可以选择。
func _refresh_screen() -> void:
	_usable_rect = _current_usable_rect()
	if DisplayServer.get_name() != "headless" and _window.mode == Window.MODE_WINDOWED:
		_windowed_decorations = (_window.get_size_with_decorations() - _window.size).max(Vector2i.ZERO)
	available_resolutions = resolutions_for_area(_usable_rect.size - _windowed_decorations - SCREEN_MARGIN)
	availability_changed.emit()


## 独立计算可容纳的预设，便于验证小屏幕与多显示器边界，不查询系统状态。
static func resolutions_for_area(area: Vector2i) -> PackedStringArray:
	var result := PackedStringArray()
	for value: String in GameSettings.SUPPORTED_WINDOW_RESOLUTIONS:
		if value == "maximized":
			result.append(value)
			continue
		var dimensions := resolution_size(value)
		if dimensions.x <= area.x and dimensions.y <= area.y:
			result.append(value)
	return result


## 稳定设置键转换为客户区尺寸；仅对已验证的预设调用。
static func resolution_size(value: String) -> Vector2i:
	var parts := value.split("x")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO


## 不合当前屏幕的旧偏好仅在内存回退，启动不擅自重写旧配置或损坏文件。
func _on_settings_changed() -> void:
	var requested := settings.window_resolution
	if not available_resolutions.has(requested):
		requested = "maximized" if available_resolutions.size() == 1 else available_resolutions[available_resolutions.size() - 2]
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
