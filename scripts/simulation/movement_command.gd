class_name MovementCommand
extends SimulationCommand
## 可观察的长移动动作；继承原有 State 和 finished 接口，旧调用保持兼容。

var angle_degrees: float = 0.0
var distance: float = 0.0
var direction: Vector2 = Vector2.RIGHT
var traveled_distance: float = 0.0
## 从动作起点和累计标量行程重建位置，避免逐帧 Vector2 加法导致贴墙路径漂移。
var start_position: Vector2 = Vector2.ZERO
