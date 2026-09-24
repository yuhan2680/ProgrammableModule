class_name SimulationCommand
extends RefCounted
## 所有顺序动作共用的生命周期；具体动作仍有独立句柄与参数。

signal finished(command: SimulationCommand)
enum State { QUEUED, RUNNING, COMPLETED, BLOCKED, CANCELLED, REJECTED }
var machine_id: String = ""
# 空字符串沿用全机广播；非空只授权指定的装配实例，失效时不得替换为其他模块。
var module_id: String = ""
var state: State = State.QUEUED
var message: String = ""


## 判断动作是否结束，支持轮询和信号两种接入方式。
func is_finished() -> bool:
	return state in [State.COMPLETED, State.BLOCKED, State.CANCELLED, State.REJECTED]


## 只记录终态；世界统一提交后才发信号，避免订阅者看到半个 tick。
func set_terminal(new_state: State, reason: String) -> void:
	state = new_state
	message = reason
