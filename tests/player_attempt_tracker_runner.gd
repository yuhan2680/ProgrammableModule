extends SceneTree
## 单调墙钟回归不用真实等待，覆盖编辑、暂停、后台、失败后修改与成功重试。

var _time: float = 0.0
var _checks: int = 0
var _failures: int = 0


## 无场景模型可以直接运行，专用时钟让每个统计时段可精确复核。
func _initialize() -> void:
	var tracker := PlayerAttemptTracker.new(_clock)
	_check(not tracker.has_started() and not tracker.is_active() and tracker.get_elapsed_seconds() == 0.0, "未进入关卡时不计时")
	tracker.set_active(true)
	_time = 100.0
	_check(not tracker.is_active() and tracker.get_elapsed_seconds() == 0.0, "设置活动状态不能绕过开始关卡")
	tracker.begin_level()
	_time = 140.0
	_check(tracker.has_started() and tracker.is_active() and tracker.get_elapsed_seconds() == 40.0, "装配和代码编辑累计真实墙钟时间")
	tracker.set_active(true)
	_time = 150.0
	_check(tracker.get_elapsed_seconds() == 50.0, "重复活动同步不重置已开始的装配时段")
	tracker.set_active(false)
	_time = 1000.0
	_check(tracker.get_elapsed_seconds() == 50.0, "暂停、失焦和后台期间全部排除")
	tracker.set_active(false)
	_time = 1050.0
	_check(tracker.get_elapsed_seconds() == 50.0, "重复暂停通知不计入非活动时间")
	tracker.set_active(true)
	_time = 1060.0
	_check(tracker.get_elapsed_seconds() == 60.0, "恢复前台继续原关卡累计时间")
	# 失败后仍在关卡内修改代码和装配，因此不调用结束或重新开始。
	_time = 1100.0
	_check(tracker.get_elapsed_seconds() == 100.0, "真实失败后的修改与重组时间仍计入本次通关")
	_check(tracker.complete() == 100.0 and tracker.is_completed() and not tracker.is_active(), "成功停止计时并保留完整活动耗时")
	_time = 5000.0
	tracker.set_active(true)
	_check(tracker.complete() == 100.0 and tracker.get_elapsed_seconds() == 100.0 and not tracker.is_active(), "成功后的界面停留和重复成功通知不增加耗时")
	tracker.begin_level()
	_time = 5030.0
	_check(not tracker.is_completed() and tracker.get_elapsed_seconds() == 30.0, "重试已通关关卡以新的活动时段开始")
	tracker.end_level()
	_time = 9000.0
	_check(not tracker.has_started() and not tracker.is_completed() and tracker.get_elapsed_seconds() == 0.0, "离开关卡清除未完成时段")
	tracker.begin_level(false)
	_time = 9500.0
	_check(tracker.has_started() and not tracker.is_active() and tracker.get_elapsed_seconds() == 0.0, "后台进入关卡不会提前计入等待时间")
	tracker.set_active(true)
	_time = 9512.5
	_check(tracker.complete() == 12.5, "恢复前台后允许精确小数秒耗时")
	tracker.end_level()
	_check(tracker.complete() == 0.0 and not tracker.is_completed(), "无关卡完成通知不会伪造成功状态")
	tracker.begin_level()
	_time = 9000.0
	_check(tracker.get_elapsed_seconds() == 0.0, "注入时钟倒退不产生负耗时")
	tracker.set_active(false)
	_check(tracker.get_elapsed_seconds() == 0.0, "倒退时结束活动不保存负数")
	var runtime := PlayerAttemptTracker.new()
	runtime.begin_level()
	_check(runtime.get_elapsed_seconds() >= 0.0 and is_finite(runtime.complete()), "默认系统单调时钟提供有限秒数")
	print("玩家耗时回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 返回可控秒数，不依赖游戏模拟速度或帧间隔。
func _clock() -> float:
	return _time


## 汇总全部失败，确保后续暂停和重试边界仍能继续验证。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
