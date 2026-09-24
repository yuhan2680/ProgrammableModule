class_name ProjectileCollision
extends RefCounted
## 匀减速弹丸与匀速移动模块的连续碰撞，不把随时间非线性变化的位移当作线性时间。
## 每轴只求与两条矩形边界的二次方程根，总共至多十个候选时刻，与速度无关。

const ROOT_EPSILON: float = 0.0000000001
const COEFFICIENT_EPSILON: float = 0.000000000001


## 返回 [0,time_limit] 内首次接触时间；无交点或无效输入返回 INF，不修改双方状态。
static func hit_time(projectile: ProjectileInstance, rect: Rect2, velocity: Vector2, time_limit: float) -> float:
	if projectile == null or not _finite_vector(projectile.position) or not _finite_vector(projectile.direction):
		return INF
	if not _finite_vector(rect.position) or not _finite_vector(rect.size) or not _finite_vector(velocity):
		return INF
	if rect.size.x <= 0.0 or rect.size.y <= 0.0 or not is_finite(time_limit) or time_limit < 0.0:
		return INF
	if not is_finite(projectile.speed) or not is_finite(projectile.deceleration) or projectile.speed < 0.0 or projectile.deceleration < 0.0:
		return INF
	# 弹丸减速到零就消失，不允许公式延伸到倒退运动的时间段。
	var duration := time_limit
	if projectile.deceleration > 0.0:
		duration = minf(duration, projectile.speed / projectile.deceleration)
	# 归一化到 u∈[0,1]，避免极短 tick 把求根阈值放大；系数始终使用标量 double。
	var x := _axis_coefficients(projectile, rect.position.x, velocity.x, duration, true)
	var y := _axis_coefficients(projectile, rect.position.y, velocity.y, duration, false)
	if x.is_empty() or y.is_empty():
		return INF
	var candidates: Array[float] = [0.0, 1.0]
	_append_roots(x[0], x[1], x[2], candidates)
	_append_roots(x[0], x[1], x[2] - rect.size.x, candidates)
	_append_roots(y[0], y[1], y[2], candidates)
	_append_roots(y[0], y[1], y[2] - rect.size.y, candidates)
	candidates.sort()
	for index: int in range(candidates.size()):
		var at := candidates[index]
		if _inside(at, x, y, rect.size):
			return at * duration
		# 两根之间各轴是否在矩形内不会改变；检查中点可稳健处理根的舍入误差。
		# 若中点在内，则数学上的左端点就是首次接触，而不是中点才发生碰撞。
		if index + 1 < candidates.size():
			var next := candidates[index + 1]
			if next - at > ROOT_EPSILON and _inside((at + next) * 0.5, x, y, rect.size):
				return at * duration
	return INF


## 构造相对坐标 q(u)=a·u²+b·u+c；目标位移只减去匀速项，不改变弹丸减速项。
static func _axis_coefficients(projectile: ProjectileInstance, minimum: float, velocity: float, duration: float, is_x: bool) -> Array[float]:
	var direction := float(projectile.direction.x if is_x else projectile.direction.y)
	var position := float(projectile.position.x if is_x else projectile.position.y)
	var a := -0.5 * projectile.deceleration * direction * duration * duration
	var b := (projectile.speed * direction - velocity) * duration
	var c := position - minimum
	if not is_finite(a) or not is_finite(b) or not is_finite(c):
		return []
	return [a, b, c]


## 求有限区间内的实根；缩放系数并使用稳定求根形式，避免大数平方溢出及相减抵消。
static func _append_roots(a: float, b: float, c: float, candidates: Array[float]) -> void:
	var scale := maxf(absf(a), maxf(absf(b), absf(c)))
	if scale == 0.0:
		return
	a /= scale
	b /= scale
	c /= scale
	if absf(a) <= COEFFICIENT_EPSILON:
		if absf(b) > COEFFICIENT_EPSILON:
			_append_candidate(-c / b, candidates)
		return
	var discriminant := b * b - 4.0 * a * c
	var tolerance := COEFFICIENT_EPSILON * maxf(b * b + absf(4.0 * a * c), 0.000000000000000000000000000001)
	if discriminant < -tolerance:
		return
	var root := sqrt(maxf(0.0, discriminant))
	var q := -0.5 * (b + root if b >= 0.0 else b - root)
	if q == 0.0:
		_append_candidate(-b / (2.0 * a), candidates)
	else:
		_append_candidate(q / a, candidates)
		_append_candidate(c / q, candidates)


## 仅保留本 tick 的候选根，边界附近的浮点尾数截回闭区间。
static func _append_candidate(value: float, candidates: Array[float]) -> void:
	if is_finite(value) and value >= -ROOT_EPSILON and value <= 1.0 + ROOT_EPSILON:
		candidates.append(clampf(value, 0.0, 1.0))


## 同时检查两个闭区间，正好擦到角或边也算接触；容差只用于浮点舍入。
static func _inside(at: float, x: Array[float], y: Array[float], size: Vector2) -> bool:
	return _inside_axis(at, x, size.x) and _inside_axis(at, y, size.y)


## 用 Horner 形式计算单轴位置，减少临界根处的舍入误差。
static func _inside_axis(at: float, coefficients: Array[float], extent: float) -> bool:
	var value := (coefficients[0] * at + coefficients[1]) * at + coefficients[2]
	var magnitude := maxf(1.0, maxf(extent, maxf(absf(coefficients[0]), maxf(absf(coefficients[1]), absf(coefficients[2])))))
	var epsilon := COEFFICIENT_EPSILON * magnitude
	return value >= -epsilon and value <= extent + epsilon


## Vector2 也可能由外部可信代码错误构造为 NaN/INF；公开边界拒绝非有限输入。
static func _finite_vector(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
