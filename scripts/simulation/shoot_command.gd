class_name ShootCommand
extends SimulationCommand
## 射击指令只占一个 tick，飞行中的弹丸由世界独立继续模拟。

var direction: Vector2 = Vector2.RIGHT
var shot_count: int = 0
