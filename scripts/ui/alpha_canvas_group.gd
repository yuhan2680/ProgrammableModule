class_name AlphaCanvasGroup
extends CanvasGroup
## 为需要透明合成的界面提供完整 alpha 精度，引用计数只作用于所属视口。

const ALPHA_STATE := &"_canvas_group_alpha_state"

var alpha_precision_enabled: bool = true:
	set(value):
		if alpha_precision_enabled == value:
			return
		alpha_precision_enabled = value
		if value:
			_acquire_alpha_precision()
		else:
			_release_alpha_precision()
var _alpha_viewport: Viewport


## 保留原始像素采样，不扩张界面内容；边缘清理余量防止小数布局残影。
func _init() -> void:
	fit_margin = 0.0
	clear_margin = 1.0
	use_mipmaps = false


## 默认开启合成精度；固定装配模式可在入树前关闭以维持原绘制路径。
func _enter_tree() -> void:
	if alpha_precision_enabled:
		_acquire_alpha_precision()


## 移除节点时始终清理自身引用，不影响仍显示的其它合成层。
func _exit_tree() -> void:
	_release_alpha_precision()


## Compatibility 的不透明缓冲只有两位 alpha；临时使用完整 alpha 精度保留圆角抗锯齿。
## 只切换渲染缓冲格式；游戏原有不透明背景继续覆盖窗口，不开启操作系统窗口透明。
func _acquire_alpha_precision() -> void:
	if not is_inside_tree() or is_instance_valid(_alpha_viewport):
		return
	_alpha_viewport = get_viewport()
	var state: Dictionary = _alpha_viewport.get_meta(ALPHA_STATE, {})
	if state.is_empty():
		state = {"users": 0, "original": _alpha_viewport.transparent_bg}
	state["users"] += 1
	_alpha_viewport.set_meta(ALPHA_STATE, state)
	_alpha_viewport.transparent_bg = true


## 最后一个使用者释放时恢复原状态，设置页和装配图共用计数，避免互相提前关闭。
func _release_alpha_precision() -> void:
	if is_instance_valid(_alpha_viewport) and _alpha_viewport.has_meta(ALPHA_STATE):
		var state: Dictionary = _alpha_viewport.get_meta(ALPHA_STATE)
		state["users"] -= 1
		if state["users"] <= 0:
			_alpha_viewport.transparent_bg = state["original"]
			_alpha_viewport.remove_meta(ALPHA_STATE)
		else:
			_alpha_viewport.set_meta(ALPHA_STATE, state)
	_alpha_viewport = null


