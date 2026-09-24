class_name AttackCommand
extends SimulationCommand
## 一次全机近战命令；多个可用近战模块同 tick 各自沿指定方向攻击。

var direction: Vector2 = Vector2.RIGHT
var hit_count: int = 0
