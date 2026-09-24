class_name SimultaneousCommand
extends SimulationCommand
## 一个并行块拥有多个独立子动作，全部完成后才释放 main 通道；不自行推进世界时钟。

var children: Array[SimulationCommand] = []
var started_tick: int = -1
