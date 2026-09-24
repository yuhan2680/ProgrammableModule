class_name MovementCommand
extends SimulationCommand
## 可观察的长移动动作；继承原有 State 和 finished 接口，旧调用保持兼容。

var angle_degrees: float = 0.0
var distance: float = 0.0
var direction: Vector2 = Vector2.RIGHT
var traveled_distance: float = 0.0
