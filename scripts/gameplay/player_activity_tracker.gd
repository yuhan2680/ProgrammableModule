class_name PlayerActivityTracker
extends RefCounted
## 累计前台页面的活动墙钟，待写入秒数只在存储成功后扣除。

var _clock: Callable
var _active := false
var _pending_seconds := 0.0
var _active_since := 0.0
var _last_now := 0.0


## 时钟返回单调秒数；测试可注入时钟而不等待真实时间。
func _init(clock: Callable = Callable()) -> void:
	_clock = clock
	_active_since = _now()


## 页面或前台状态改变时结算旧区间，后台等待不会混入下次活动。
func set_active(active: bool) -> void:
	if active == _active:
		return
	_settle()
	_active = active


## 查询尚未成功保存的秒数，不修改已保存计时边界。
func get_pending_seconds() -> float:
	return _pending_seconds + (_now() - _active_since if _active else 0.0)


## 仅扣除已经持久化的快照，保留写盘期间新增时间及失败重试所需数据。
func acknowledge(seconds: float) -> void:
	if not is_finite(seconds) or seconds < 0.0:
		return
	_settle()
	_pending_seconds = maxf(0.0, _pending_seconds - seconds)


## 新档案从当前时刻开始，旧身份的待存时段不能再次写入。
func reset() -> void:
	_pending_seconds = 0.0
	_active_since = _now()


## 暴露合并后的活动状态，供页面生命周期和隔离回归使用。
func is_active() -> bool:
	return _active


## 将当前活动区间移入待保存值，更新时间基准但不改变活动开关。
func _settle() -> void:
	var now := _now()
	if _active:
		_pending_seconds += now - _active_since
	_active_since = now


## 异常及倒退时钟保持上次有效值，避免负数或重复累计同一时间区间。
func _now() -> float:
	var value: Variant = _clock.call() if _clock.is_valid() else float(Time.get_ticks_usec()) / 1000000.0
	if DataValidation.is_number(value):
		_last_now = maxf(_last_now, float(value))
	return _last_now
