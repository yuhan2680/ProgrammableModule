extends SceneTree
## 用正式第十一关、玩家雷达与函数/变量程序验证真实五次闪避，不改变关卡目标。

const SOLUTION := "constant limit = 2.5\nmain() {\n    loop {\n        dodge()\n    }\n}\n\nfunction dodge() {\n    variable target = eyes.scan()\n    if (target != null) {\n        if (target.Distance < limit) {\n            if (target.Angle() < 10) {\n                move(90, 1)\n            } else {\n                if (target.Angle() > 350) {\n                    move(90, 1)\n                } else {\n                    move(0, 0)\n                }\n            }\n        } else {\n            move(0, 0)\n        }\n    } else {\n        move(0, 0)\n    }\n}\n"
var _checks := 0
var _failures := 0


## 延后加载全局类，在内存会话中检查关卡解锁与真实通关过程。
func _initialize() -> void:
	_run.call_deferred()


## 对照旧关卡权限、两种雷达装配和暂停/重试行为，保证设施可用而非仅显示解锁。
func _run() -> void:
	var content := ContentRegistry.new()
	_check(content.load_directories().is_ok(), "正式模块可加载")
	var path := "res://data/levels/level_011.json"
	var map := MapCodec.load_file(path, content, true)
	if not _check(map.is_ok(), "第十一关地图可加载"):
		_finish()
		return
	var level: LevelDefinition = LevelDefinition.from_document(map.value, content, path).value
	_check(level.allow_radar and level.allow_variables and level.allow_functions, "第十一关完整开放雷达及此前常变量和函数")
	_check("radar" in level.allowed_modules and level.module_limit == 2, "允许安装玩家雷达，原两模块限制保持不变")
	_check(FileAccess.file_exists("res://data/levels/level_010.json"), "第十关地图已补齐，十一关保留既有权限")
	for number in range(1, 10):
		var previous := MapCodec.load_file("res://data/levels/level_%03d.json" % number, content, true)
		var defined: LevelDefinition = LevelDefinition.from_document(previous.value, content).value
		_check(not defined.allow_radar and not "radar" in defined.allowed_modules, "前九关保持自己的雷达解锁范围")
	for position: Vector2 in [Vector2(0.5, 0), Vector2.ZERO]:
		var session := GameSession.create(level, content)
		if position == Vector2.ZERO:
			_check(session.assembly.add_module("movement", position, "drive").is_ok(), "另一装配以移动模块居中")
			_check(session.assembly.add_module("radar", Vector2(0.5, 0), "eyes").is_ok(), "雷达放于移动模块右侧")
		else:
			_check(session.assembly.add_module("radar", Vector2.ZERO, "eyes").is_ok(), "雷达可作为首个中心模块")
			_check(session.assembly.add_module("movement", position, "drive").is_ok(), "雷达与移动模块共边合法装配")
		session.source = SOLUTION
		var result := session.run()
		if not _check(result.is_ok(), "真实扫描程序通过会话编译：" + "\n".join(result.errors)):
			continue
		session.step()
		session.pause()
		var tick := session.world.tick_index
		var state_before := session.world.query_scan("player", "eyes")
		session.step()
		_check(session.world.tick_index == tick and session.world.query_scan("player", "eyes").value == state_before.value, "暂停不推进敌人和扫描结果")
		session.resume()
		for unused in 900:
			if session.state != GameSession.State.RUNNING:
				break
			session.step()
		_check(session.state == GameSession.State.SUCCEEDED, "玩家雷达/变量/函数解法真实躲过五次攻击：" + session.message)
		_check(int(session.world.get_enemy_attack_status("radar_hunter").get("dodged", 0)) == 5, "通关来自真实闪避计数而非跳过攻击")
		session.reset()
		_check(session.run().is_ok(), "重试可重新创建雷达世界和变量")
		_check(session.world.query_scan("player", "eyes").is_ok(), "重试扫描仍可使用")
		session.stop()
	_finish()


## 记录每个回归条件，保留失败的实际会话反馈。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 提供统一完成标记，外部测试入口拒绝脚本错误与失败退出。
func _finish() -> void:
	print("玩家雷达教学回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
