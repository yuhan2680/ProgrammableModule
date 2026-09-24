# 第四关：远程打击

本轮按用户提供的 `ProgramLevel.md` 第四关扩展现有分层实现。原先“不使用 tick / 暂无敌人”的阶段约定由本轮需求取代，前三关的地图、装配限制、通关方式和存档 ID 保持不变。

## 关卡与教学

- `data/levels/level_004.json`，显示名称“第四关 · 远程打击”，模块上限 1。
- 玩家参考点 `(1.5, 2.5)`；敌人 `guard` 参考点 `(7.5, 2.5)`，初始水平距离 6 格。
- 敌人移动模块偏移 `(-0.5, 0)`、近战模块偏移 `(0, 0)`，两模块各占 `0.5 × 0.5` 格、默认耐久 1。前面的移动模块会先受到水平攻击。
- 敌人向左移动 4.5 格，完成后向左近战。移动模块先被摧毁时，取消剩余移动，残存近战模块仍可按原射程攻击；不瞬移、不扩大射程。
- 目标为玩家存活并击毁敌人的全部模块。只损坏移动能力不会通关。同 tick 双方全毁时玩家死亡优先，判定失败。
- 本关允许玩家比较移动、近战与射击模块。推荐中心放射击模块，在 `tick()` 中持续 `shoot(0)`；每次进入仍从空装配开始。
- 为避免近战打掉移动模块后永久僵持，本关设置 `max_ticks: 150`（15 秒），教程及场地状态均明确显示。超时可保留代码与装配重试。

```text
main() {
}

tick() {
    shoot(0)
}
```

## 有限语言扩展

`ProgramParser.parse(source, allowed_calls, allow_tick=false)` 保留旧调用方式。`ProgramAst.ProgramNode` 包含必需的唯一 `main` 及可选的唯一 `tick` 函数节点。`shoot(角度)` 仍是显式 CallNode。射击按 `allowed_modules` 中是否存在 `ShootingModule` 行为解锁；`allow_tick` 是独立的布尔开关，默认关闭。

`main` 按顺序等待 `move` / `attack` / `shoot` 命令。`tick` 本阶段仅接受 `shoot` / `attack` 短动作，每个逻辑 tick 执行一次，不能放等待型 `move`、循环、递归或任意脚本。主程序与回调共享 512 条调用的编译上限，原有源文本与 token 上限不变。

每次 `ProgramRunner.step()` 先收集主程序及回调输入，之后只推进一次世界。相同机器、相同武器类别的多次回调取第一次方向；主程序和回调共享模块冷却，不能靠重复调用增加射速。回调可与主程序的移动在同一个逻辑 tick 生效，不引入通用 `simultaneously` 或多线程。

主程序只射一次时，执行器等待该玩家已有子弹飞行结束。战斗会话即使在 `main` 完成后也继续推动敌人；空 `main` 不能冻结敌人。有 `tick` 时执行器持续运行，直到失败、胜利、停止或该关设置的时限。暂停冻结所有模拟；重新运行创建独立世界，清空旧子弹并重置耐久及冷却。

## 射击与统一结算

`data/modules/shooting.json` 的 `ShootingModule` 是可信行为，SVG 贴图位于 `assets/modules/shooting.svg`。可调属性为：

| 属性 | 含义 |
| --- | --- |
| `projectile_speed` | 子弹初速，格/秒 |
| `deceleration` | 正的减速度，格/秒² |
| `damage_per_speed` | 命中速度对应的伤害系数 |
| `cooldown_ticks` | 模块射击冷却，按模拟 tick 计时 |
| `max_health` | 模块耐久上限，可选，默认 1 |

初速 8、减速度 4、伤害系数 0.2、冷却 10 tick（1 秒）。理论无障碍射程为 `v² / (2a) = 8` 格。伤害为命中瞬间速度乘以系数，距离越远通常伤害越低；单发只命中第一个实体，不穿透后方模块。子弹从实际模块中心出发，自己的模块不遮挡自己的子弹。

`SimulationWorld.request_shoot(machine_id, angle)` 返回单 tick 的 `ShootCommand`。冷却中请求仍成功完成但 `shot_count` 为 0。`request_tick_action(machine_id, callee, angle)` 是有限回调输入队列；`has_pending_projectiles(machine_id)` 供执行器判断是否仍有子弹在飞行。

世界先收集所有移动、近战、射击与弹道命中提案，再统一提交模块和对象的伤害。被同 tick 攻击摧毁的模块仍能发出本 tick 已计算的攻击，避免按遍历顺序决定先手。近战的每个来源模块只命中射线上的一个最近对象或模块；原第三关的 2 格近战射程与伤害保持不变。

弹道使用连续扫掠，命中速度依据匀减速公式计算。地形、void、边界、关闭闸门与障碍物会遮挡；移动模块的命中需要相对运动计算，不能只检查子弹落点。速度降到零后移除弹丸。

`ModuleInstance` 保存 `health`、`max_health`、`available`、`next_shoot_tick` 与 `next_attack_tick`。耐久归零同时移除该模块的能力与实体占地，没有新增 Core。`MachineInstance.is_destroyed()` 表示已没有可用模块。

## 地图 JSON 与向后兼容

格式仍为版本 1；缺省没有敌人行为、没有 tick、没有时限，旧地图行为保持不变。只执行白名单 `approach_attack`，未知敌人行为仍保留为扩展数据，不从 JSON 加载代码。地图保存继续保留未知字段。

```json
{
  "id": "guard",
  "position": {"x": 7.5, "y": 2.5},
  "modules": [
    {"id": "guard_drive", "module_id": "movement", "offset": {"x": -0.5, "y": 0}},
    {"id": "guard_blade", "module_id": "melee", "offset": {"x": 0, "y": 0}}
  ],
  "behavior": "approach_attack",
  "properties": {"move_angle": 180, "move_distance": 4.5, "attack_angle": 180}
}
```

上述对象置于地图 `enemies` 数组。`properties.level` 的新增规则为：

```json
{
  "allow_tick": true,
  "max_ticks": 150,
  "goal": {"type": "destroy_enemy", "enemy_id": "guard"}
}
```

`allow_tick` 必须为布尔值；`max_ticks` 为 0..36000 的整数，0 表示不限时；目标必须引用当前地图内具有已注册行为的敌人。运行前仍由通用装配与地形接口检查实际出生占地。编辑器通过现有元数据 JSON 编辑敌人、保存并使用未保存快照测试，不建立第二套战斗实现。

## 显示与验证

选关 SVG 自动包含敌方双模块标记。正式场地和编辑预览显示真实敌人布局，运行时显示各模块耐久、残骸、子弹、射击冷却及练习剩余时间。显示层只读取数据，计时及命中均属于模拟层。

`tools/test.ps1` / `tools/test.py` 保留原有全部测试，并在 campaign_runner 中扩展战斗用例，新增弹道与第四关端到端回归，覆盖正确与错误程序、逐关解锁、冷却、移动敌人、暂停重试、编辑器未保存快照、原关卡与存档隔离以及中英窄窗口布局。具体运行结果以本轮验证记录为准。
