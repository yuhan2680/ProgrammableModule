# 第五关：越狱与命名模块

来源：[ProgramLevel.md](https://github.com/yuhan2680/ProgrammableModule/blob/main/ProgramLevel.md) 第五关（2026-09-12 核对）。本关上限三个模块，警卫在左侧两格、警报在右侧两格，先解除警卫，再破坏警报器，向上逃脱。原设计注明同时攻击可能成立，因此保留同 tick 同时清除的有效解法。

## 内容与装配

地图：`data/levels/level_005.json`，出生 `(4.5, 6.5)`，出口 `(4.5, 1.5)`。水平牢房连接上方三格宽出口；三个安全门对象各占一格正方形。推荐中心移动模块 `drive`，左近战 `left` 偏移 `(-0.5, 0)`，右近战 `right` 偏移 `(0.5, 0)`。地图模板不自动安装；玩家首次仍空装配。

参考程序：

```text
main() {
    left.attack(180)
    right.attack(0)
    move(90, 5)
}
```

左右近战各从自己的中心攻击，射程沿用现有 2 格规则。广播攻击仍可作为其他解法；不通过检查固定源码来判胜。第五关保留此前的射击及 tick 能力。

## 命名调用接口

- `ProgramParser.parse(source, allowed_calls, allow_tick = false, allow_named_calls = false)`；旧调用兼容，前四关继续锁定成员语法。
- `ProgramAst.CallNode.receiver`：空字符串表示原广播，非空保存大小写敏感的模块实例名。
- `request_move / request_attack / request_shoot / request_tick_action` 末尾添加 `module_id: String = ""`；名称不存在、不可用或能力错误均返回失败，不回退广播。
- Runner 对 main 与 tick 全树预检；后续非法指令不能让前面的动作部分执行。错误保留行列。
- `drive.move` 只选择速度来源，整机占地、完整移动路径和碰撞规则保持一致。冷却属于实际 ModuleInstance；main、tick、命名和广播共享它。
- 成员语法仅一层 `name.method`；没有动态查找、任意脚本、表达式、条件或新并发块。`.5` / `1.` 的既有数值语法不变。tick 仍只允许短动作 attack/shoot。

## 静态 JSON 与运行状态

关卡新增 `properties.level.allow_named_calls: true` 与：

```json
{"type":"escape_prison","enemy_id":"guard","object_id":"alarm","position":{"x":4.5,"y":1.5},"radius":0.25}
```

- 敌人 `behavior: "alarm_guard"`：注册的静止警卫，不执行地图提供的脚本。
- 对象 `type: "prison_alarm"`，`properties: {"max_health": 1, "guard_id": "guard"}`：可破坏并阻挡移动。关联必须是本地图已注册警卫。
- 对象 `type: "security_gate"`，`properties: {"required_enemy_ids": ["guard"], "required_object_ids": ["alarm"]}`：所有依赖销毁后打开。至少一个依赖，不允许重复、缺失、未知类型或门引用门，避免依赖循环。
- `WorldObject.triggered`、`unlocked` 只在运行副本中变化；源 JSON、保存的地图和装配不变。

沿用格式版本 1；新增可选字段默认不改变旧地图行为。Schema 验证结构，MapValidation 与 LevelDefinition 进一步检查跨引用、目标类型及可行走出口。

## 结算顺序

每 tick 收集移动/近战/射击提案，统一提交位置与全部伤害，再检查本 tick 新毁的警报。若警卫仍存活，立即摧毁全部玩家模块并记录失败；这是本关可信机关规则，不伪造无限射程近战。若警卫同 tick 也死亡，警报不触发。

安全门在该提交阶段解锁，下一次移动使用新状态。GameSession 先检查世界失败，再检查两目标和实际出口路径；不能只拆完目标就获胜。暂停不推进冷却、机关或位置；重试建立新世界，恢复警卫、警报及安全门，保留代码和装配。

## 验证入口

`tools/test.ps1` / `tools/test.py` 加入 `prison_world_runner.gd` 与 `prison_level_runner.gd`；现有语言、编辑器、UI 和前四关回归继续运行。对象 SVG 位于 `assets/objects/prison_alarm.svg`、`security_gate_closed.svg`、`security_gate_open.svg`；缩略图依据实际地图自动生成。
