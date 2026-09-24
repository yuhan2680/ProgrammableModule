extends SceneTree
## 独立验证真实匀减速时间方程与移动矩形碰撞，包括原线性近似会误判的擦边轨迹。

var _checks: int = 0
var _failures: int = 0


## 在引擎初始化完成后运行纯数学回归，不写存档或依赖界面。
func _initialize() -> void:
	_run.call_deferred()


## 执行解析解、边界、对称性和输入防御案例，统一返回退出码。
func _run() -> void:
	_test_exact_motion()
	_test_boundaries()
	_test_invalid_inputs()
	print("弹道碰撞回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 使用可手算的二次方程根验证静态、追近、远离和垂直擦边，避免只镜像实现。
func _test_exact_motion() -> void:
	var bullet := _bullet(Vector2(1.5, 1.5), Vector2.RIGHT, 8.0, 8.0)
	var target := Rect2(2.0, 1.25, 0.5, 0.5)
	_close(ProjectileCollision.hit_time(bullet, target, Vector2.ZERO, 0.1), (8.0 - sqrt(56.0)) / 8.0, "静止目标命中时间使用真实减速方程")
	_close(ProjectileCollision.hit_time(bullet, target, Vector2.LEFT, 0.1), (9.0 - sqrt(73.0)) / 8.0, "迎面移动目标使用相对速度及弹丸减速")
	_close(ProjectileCollision.hit_time(bullet, target, Vector2.RIGHT, 0.1), (7.0 - sqrt(41.0)) / 8.0, "远离目标的命中时间不会沿用静态或平均速度")
	var miss := Rect2(1.385, 1.55, 0.5, 0.5)
	_check(is_inf(ProjectileCollision.hit_time(bullet, miss, Vector2.UP, 0.1)), "弹丸先越过右边缘、目标后进入弹道时保持未命中，修复线性近似假命中")
	var crossing := Rect2(1.4, 1.55, 0.5, 0.5)
	_close(ProjectileCollision.hit_time(bullet, crossing, Vector2.UP, 0.1), 0.05, "垂直移动目标进入弹道的实际时刻被准确命中")
	var tangent := Rect2(1.515625, 1.25, 0.5, 0.5)
	_close(ProjectileCollision.hit_time(bullet, tangent, Vector2(7.5, 0.0), 0.1), 0.0625, "相对抛物线仅在单个时刻擦到边缘也能检测")
	tangent.position.x += 0.001
	_check(is_inf(ProjectileCollision.hit_time(bullet, tangent, Vector2(7.5, 0.0), 0.1)), "近切线但尚有间隙时不产生虚假命中")
	var fast := _bullet(Vector2(1.5, 1.5), Vector2.RIGHT, 256.0, 256.0)
	var fast_time := ProjectileCollision.hit_time(fast, Rect2(10.0, 1.25, 0.5, 0.5), Vector2.ZERO, 0.1)
	_close(fast_time, 17.0 / (256.0 + sqrt(65536.0 - 4352.0)), "高速弹丸跨越多个格子也不会穿过半格目标")
	var diagonal := _bullet(Vector2(1.5, 1.5), Vector2(1, 1).normalized(), 8.0, 8.0)
	var diagonal_time := ProjectileCollision.hit_time(diagonal, Rect2(2, 2, 0.5, 0.5), Vector2.ZERO, 0.1)
	_close(diagonal_time, (8.0 - sqrt(64.0 - 16.0 * (0.5 / diagonal.direction.x))) / 8.0, "对角弹道同时接触矩形角点")
	var mirrored := _bullet(Vector2(-1.5, -1.5), Vector2.LEFT, 8.0, 8.0)
	var mirrored_rect := Rect2(-2.5, -1.75, 0.5, 0.5)
	_close(ProjectileCollision.hit_time(mirrored, mirrored_rect, Vector2.RIGHT, 0.1), (9.0 - sqrt(73.0)) / 8.0, "坐标和方向翻转不改变碰撞时间")


## 覆盖零轴、初始重叠、零时长、停止时刻与退化为匀速的一次方程。
func _test_boundaries() -> void:
	var bullet := _bullet(Vector2(2, 2), Vector2.RIGHT, 8.0, 8.0)
	_close(ProjectileCollision.hit_time(bullet, Rect2(1.75, 1.75, 0.5, 0.5), Vector2.ZERO, 0.1), 0.0, "弹丸初始位于目标内部立即接触")
	_close(ProjectileCollision.hit_time(bullet, Rect2(2, 1.75, 0.5, 0.5), Vector2.ZERO, 0.0), 0.0, "零时长仍检测初始边界接触")
	_check(is_inf(ProjectileCollision.hit_time(bullet, Rect2(3, 1.75, 0.5, 0.5), Vector2.ZERO, 0.0)), "零时长不凭空前进到未接触目标")
	_check(is_inf(ProjectileCollision.hit_time(bullet, Rect2(2.2, 2.5, 0.5, 0.5), Vector2.ZERO, 0.1)), "水平弹道的零垂直速度不会命中异行矩形")
	var constant := _bullet(Vector2(2, 2), Vector2.RIGHT, 8.0, 0.0)
	_close(ProjectileCollision.hit_time(constant, Rect2(2.5, 1.75, 0.5, 0.5), Vector2.ZERO, 0.1), 0.0625, "零减速度退化为正确的匀速碰撞")
	var resting := _bullet(Vector2(2, 2), Vector2.RIGHT, 0.0, 0.0)
	_close(ProjectileCollision.hit_time(resting, Rect2(1, 1.75, 0.5, 0.5), Vector2(10, 0), 0.1), 0.05, "弹丸静止时仍能处理运动目标跨过它")
	var stopping := _bullet(Vector2(2, 2), Vector2.RIGHT, 1.0, 10.0)
	_check(is_inf(ProjectileCollision.hit_time(stopping, Rect2(2.1, 1.75, 0.5, 0.5), Vector2.ZERO, 1.0)), "到达最大射程后不延伸到倒退运动")
	_check(is_inf(ProjectileCollision.hit_time(stopping, Rect2(1.0, 1.75, 0.5, 0.5), Vector2.ZERO, 1.0)), "长时长不会误判减速公式倒退后击中背后目标")
	_close(ProjectileCollision.hit_time(constant, Rect2(3, 1.75, 0.5, 0.5), Vector2(-2, 0), 0.1), 0.1, "恰好在 tick 结束时接触目标仍算命中")
	var translated := _bullet(Vector2(202, 202), Vector2.RIGHT, 8.0, 0.0)
	_close(ProjectileCollision.hit_time(translated, Rect2(202.5, 201.75, 0.5, 0.5), Vector2.ZERO, 0.1), 0.0625, "相同场景平移至地图远端仍得到一致时间")


## 非有限公开输入统一返回无交点，避免数学异常污染世界或阻塞模拟。
func _test_invalid_inputs() -> void:
	var bullet := _bullet(Vector2(2, 2), Vector2.RIGHT, 8.0, 8.0)
	var rect := Rect2(2.5, 1.75, 0.5, 0.5)
	_check(is_inf(ProjectileCollision.hit_time(null, rect, Vector2.ZERO, 0.1)), "空弹丸被拒绝")
	for limit: float in [-0.1, INF, NAN]:
		_check(is_inf(ProjectileCollision.hit_time(bullet, rect, Vector2.ZERO, limit)), "无效时间上限被拒绝")
	_check(is_inf(ProjectileCollision.hit_time(bullet, Rect2(2.5, 1.75, 0, 0.5), Vector2.ZERO, 0.1)), "零面积目标被拒绝")
	_check(is_inf(ProjectileCollision.hit_time(bullet, rect, Vector2(INF, 0), 0.1)), "非有限目标速度被拒绝")
	bullet.speed = INF
	_check(is_inf(ProjectileCollision.hit_time(bullet, rect, Vector2.ZERO, 0.1)), "非有限弹速被拒绝")
	bullet.speed = 8.0
	bullet.deceleration = -1.0
	_check(is_inf(ProjectileCollision.hit_time(bullet, rect, Vector2.ZERO, 0.1)), "负减速度被拒绝")
	bullet.deceleration = 8.0
	bullet.position = Vector2(NAN, 2)
	_check(is_inf(ProjectileCollision.hit_time(bullet, rect, Vector2.ZERO, 0.1)), "非有限弹丸位置被拒绝")


## 建立只含物理字段的弹丸夹具，不依赖模块内容、敌人 AI 或渲染。
func _bullet(position: Vector2, direction: Vector2, speed: float, deceleration: float) -> ProjectileInstance:
	var projectile := ProjectileInstance.new()
	projectile.position = position
	projectile.direction = direction
	projectile.speed = speed
	projectile.deceleration = deceleration
	return projectile


## 比较可解析的命中时间，容差覆盖 Vector2 使用单精度存储引入的坐标舍入。
func _close(actual: float, expected: float, reason: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) < 0.000001, reason + "，实际=%s，预期=%s" % [actual, expected])


## 累计所有断言失败以便外部测试包装器识别。
func _check(condition: bool, reason: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(reason)
