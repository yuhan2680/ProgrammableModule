class_name PlayerAttemptTracker
extends RefCounted
## 按单调墙钟累计装配、编程和运行活动时间，暂停、后台和离开期间不计入。

var _clock: Callable
var _started: bool = false
var _completed: bool = false
var _active: bool = false
var _elapsed: float = 0.0
var _active_since: float = 0.0


## 可注入返回秒数的单调时钟，测试无需真实等待或依赖模拟帧率。
func _init(clock: Callable = Callable()) -> void:
	_clock = clock


## 进入新的正式关卡或重新挑战已完成关卡时重新开始计时。
func begin_level(active: bool = true) -> void:
	_started = true
	_completed = false
	_elapsed = 0.0
	_active = active
	_active_since = _now()


## 调用方合并页面、暂停和前台状态；修改装配或代码仍保持活动。
func set_active(active: bool) -> void:
	if not _started or _completed or active == _active:
		return
	var now := _now()
	if _active:
		_elapsed += maxf(0.0, now - _active_since)
	_active = active
	_active_since = now


## 实时读取累计活动耗时，不改变计时基准，也不会累积暂停期间。
func get_elapsed_seconds() -> float:
	return _elapsed + maxf(0.0, _now() - _active_since) if _active else _elapsed


## 首次成功停止计时，重复通知返回同一值；重试需显式 begin_level。
func complete() -> float:
	if _started and not _completed:
		set_active(false)
		_completed = true
	return _elapsed


## 离开关卡丢弃未完成时段，不把主动离开转成失败或成功记录。
func end_level() -> void:
	_started = false
	_completed = false
	_active = false
	_elapsed = 0.0
	_active_since = 0.0


## 是否已进入关卡，供外壳避免重复开始计时。
func has_started() -> bool:
	return _started


## 已完成时重跑可由外壳开始新的挑战，普通编辑返回则不重置时钟。
func is_completed() -> bool:
	return _completed


## 暴露合并后的活动状态方便无界面回归校验。
func is_active() -> bool:
	return _active


## 默认使用单调时间，注入异常或倒退时钟不会增加负耗时。
func _now() -> float:
	if not _clock.is_valid():
		return float(Time.get_ticks_usec()) / 1000000.0
	var value: Variant = _clock.call()
	return float(value) if DataValidation.is_number(value) else _active_since
