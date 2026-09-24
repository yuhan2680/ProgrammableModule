# 第十五关：自动索敌与雷达事件

依据 2026-09-19 直接读取的最新 ProgramLevel.md，第十五关用雷达探测事件代替反复手动扫描，目标仍为摧毁通道内全部敌人。原文写两个模块，**本次按用户明确确认采用三个模块**。显示名称为“第十五关 · 自动索敌”。

## 关卡与装配

`level_015`、order 15，18×35 地图、最多三个模块、240 秒，目标为 `destroy_waves`。沿用[第十四关](CORRIDOR_SWEEP.md)的四格宽纵向主通道、左右各五条支道和铁栅栏。栅栏阻挡机器，放行雷达、弹丸与近战；实墙继续遮挡，运动和伤害都读取真实格子与模块几何。

十波依次激活，前波整机被毁且玩家到达下一组触发区域后才出现下一波。未来敌人不参与扫描或伤害；每个敌方移动/近战模块各有 **2.8 耐久**，必须击毁全部部件才清波。整机残骸约三秒淡出，暂停冻结，重试清空。

正常入口仍为空装配，初始程序为无动作的 `main()`。建议中心雷达命名为 `radar`，右侧 `(0.5,0)` 射击命名为 `gun`，左侧 `(-0.5,0)` 移动命名为 `drive`；必须由玩家实际安装并确认。雷达与枪口位置不同，其他布局需要按实际几何调整瞄准。

## 固定事件绑定

```text
variable target = null
radar.onDetected { EnemyPosition -> target }

main() {
    loop {
        if (target != null) {
            gun.shoot(target.Angle())
        } else {
            drive.move(90, 0.1)
        }
    }
}
```

这是参考程序，初始代码不预填。事件负责更新目标，main 在有目标时持续射击，无目标时短步向上移动；两个分支都用真实动作推进时间，不需要扫描循环。

- `radar` 必须是实际可用雷达的实例名；没有裸 `onDetected` 或自动选择来源。
- 全局 `variable target` 必须先于事件声明。箭头后不能绑定常量、局部变量、未声明名称或后置声明。
- `EnemyPosition` 是区分大小写的固定载荷名，载荷与 `scan()` 返回的目标快照同型，并非单独坐标向量。
- 事件只能注册在顶层，不接受 `onDetected()`，不能放入 main、tick、函数或控制块。花括号内只有一个 `EnemyPosition -> target` 绑定，不执行动作、条件、赋值或任意回调代码。
- 每个雷达只能注册一次，同一全局变量不能由多个雷达事件写入。不同雷达可以分别绑定不同的全局变量。

## 快照与固定 tick

全局初始化完成后、main 首次动作前刷新一次；每个后续逻辑 tick 开始时，在 main / tick 读取变量之前更新。main 等待移动完成期间仍会更新，main 结束后只要会话仍运行，事件继续生效。刷新本身不消耗额外 tick，不提交动作或改变冷却，世界仍按 0.1 秒固定步长推进。

每次更新都使用该雷达的最新 `query_scan()` 结果：最近可见敌人的独立目标快照，或没有可见目标时的 `null`。范围、遮挡、等距目标顺序及雷达来源中心沿用[玩家雷达](PLAYER_RADAR.md)。敌人死亡、离开范围或被遮挡后，下一次刷新会清除旧目标。损毁或停用雷达是带行列的能力错误，不能冒充无目标。

先判断 `target != null`，再读取 `target.Angle()`、`target.Position`、`target.Position.x/y` 或 `target.Distance`；保留既有 `Distance()` 和 `Null` 兼容写法。事件更新的是全局绑定，复制到其他常变量的旧快照不会跟随刷新。同名局部变量只影响该作用域的普通读写，不改变事件写入的全局目标。暂停不刷新，停止后取消更新，重试重新初始化全局值、事件和世界。

## 权限与实现

`properties.level.allow_radar_events` 是默认 false 的独立布尔权限，第十五关显式开启，前十四关关闭；同时要求 `allow_radar`、`allow_variables`、`allow_named_calls` 以及真实雷达能力。导入地图也按自己的显式权限检查，不能由地图 ID 或通关记录推测。

Lexer 将连续 `->` 识别为箭头；Parser 构造 `RadarEventNode` 并写入 `ProgramNode.radar_events`。共享名称与结构校验检查声明顺序、可变性和重复绑定，Runner 在启动前验证真实雷达，运行时只调用现有只读扫描并写入全局作用域。公开 AST 同样接受结构、来源、绑定和复杂度检查，不生成宿主代码或调用任意方法。

Tab 补全只补标识符后缀：顶层真实雷达名称与 `onDetected`，事件内固定 `EnemyPosition`，箭头后此前声明的全局 variable。常量和局部不会成为事件目标候选，快照成员提示继续遵守局部遮蔽。中英文指令资料位于 `data/commands/155_radar_event.json`，旧关目录和搜索隐藏该条目；`GameTheme` 为深浅模式与设置预览提供一致高亮。补全、高亮与阅读资料不会执行扫描。

## 回归入口

- `tests/radar_event_parser_runner.gd`：权限、固定语法、声明顺序、目标作用域、重复绑定和非法结构。
- `tests/radar_event_runtime_runner.gd`：实际雷达、最新快照、空目标、全局写入、等待动作、暂停停止和公开 AST 防御。
- `tests/radar_event_editor_runner.gd`：前十四关隔离、实际实例候选、全局变量候选、成员推断、双语资料及深浅高亮。
- `tests/radar_event_level_runner.gd`：正式第十五关数据、真实三模块战斗、十波目标、暂停重试和旧关兼容。

统一验证使用 `tools/test.ps1` 或 `tools/test.py`；实际执行结果由 [验证记录](VALIDATION.md) 汇总。
