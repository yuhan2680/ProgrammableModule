# JSON 扩展指南

2026-09-11 更新：第二、三关现在已实现限时闸门、可破坏障碍物、近战模块与 `attack(角度)`。旧版文档中“攻击尚未实现”的说明已过期。当前对象字段、边界规则和完整示例见 [闸门与近战设计](GATE_AND_MELEE.md)。

## 内容文件

| 内容 | 内置目录 | 用户目录 |
| --- | --- | --- |
| 模块定义 | `data/modules/` | `user://data/modules/` |
| 地块定义 | `data/tiles/` | `user://data/tiles/` |
| 游戏关卡 | `data/levels/` | `user://levels/` |
| 编辑器样例 | `data/maps/` | 不自动进入选关列表 |

目录扫描直接位于目录内的 JSON；同类重复 ID 会拒绝整次内容重载并保留旧注册表。外部内容需先准备贴图再重载内容。图片路径使用安全的 `res://` 或 `user://`，不能带 `..`、反斜杠等逃逸段，支持 SVG、PNG、JPEG、WebP。导出后的内置贴图同样可读取。

所有 JSON 根对象 `format_version` 仍为 1，标准 UTF-8 JSON，不写注释或尾逗号。ID 使用英文字母、数字、下划线、短横线和点，长度 1..128，`void` 为保留名。数值必须有限，不能使用数字字符串或布尔值。单文件上限 8 MiB，最大嵌套 32 层。未知扩展字段保留，但不会自动执行其玩法。

## 胜利条件

目标仍位于完整地图 `properties.level.goal`，不是单独保存到关卡目录的文件。

| 格式 | 状态 |
| --- | --- |
| `{ "position": {"x": 5.5, "y": 1.5}, "radius": 0.25 }` | 已支持的旧版位置目标 |
| 上一项加 `"type": "reach_position"` | 显式位置目标 |
| `{ "type": "destroy_object", "object_id": "training_obstacle" }` | 摧毁本地图指定的可破坏对象 |
| 省略或 null | 沙盒，无通关目标 |
| `survive_time` 或其它类型 | 尚未实现，明确报错 |

位置目标按机器中心的移动线段判定，半径默认 0.25，范围 `(0,0.25]`，完整目标区域需位于可通行地板。摧毁目标不需要 position/radius，object_id 必须存在且类型为 destructible。每关只有一个目标，不支持条件数组或隐含 AND/OR。

## 模块

模块需要 id、name、size、texture、script_type；description 和 properties 为内容说明与行为参数。size.width/height 范围 `0.001..256`；内置模块为 `0.5 × 0.5`。

| 可信行为 | 属性 | 当前效果 |
| --- | --- | --- |
| `MovementModule` | `move_speed` 有限正数 | 速度相加，单位格/秒 |
| `MeleeModule` | `range` 在 `(0,256]`；`damage` 在 `(0,1e9]` | 每 tick 一次沿角度的近战，可破坏对象 |

修改已有能力的外观或参数可直接增加 JSON 变体。全新能力仍需继承 ModuleBehavior、注册可信行为、扩展解释器和模拟规则。script_type 是注册名称，不是脚本文件地址。旧提案中的 AttackModule 与 cooldown_seconds 不是本版接口。

关卡 `allowed_modules` 写模块内容 ID；可用近战行为解锁 attack，但必须实际安装近战模块才能运行攻击程序。module_limit 为 `1..256`。进入关卡或编辑器试玩仍为空装配；地图出生模板不会自动安装。

实际装配首模块在 `(0,0)`，其它模块按真实尺寸共边，允许分支，角点接触不算。编辑草稿可以暂缺中心或断连，确认必须非空、中心存在、沿边连通、完整出生占地无 void 和障碍。

## 地块与对象

地块字段见 `schemas/tile.schema.json`：id、name、texture、collision、radar_block。每个地块为 1×1 格。collision 控制可通行性；radar_block 当前只保存，尚无雷达系统。未列出的地块与地图外为 void，不要写 tile_id:void。

普通不可破坏障碍地块可直接设置 collision:true。可破坏障碍与定时闸门使用地图 objects，叠加在已有地板上；不能仅给地块 properties 添加 max_health 就期待可破坏。对象可从元数据 JSON 编辑，保存/撤销/测试复用同一文档系统。

复制 `data/levels/level_002.json` 或 `level_003.json` 可获得完整可运行关卡。单独的目标或对象 JSON 片段不能直接作为地图导入。

## 代码入口与验证

- MapValidation / MapObjectDefinition：校验旧字段及已支持对象。
- LevelDefinition：读取目标类型、允许模块与调用集合。
- WorldObject / SimulationWorld：独立耐久、闸门时钟、连续碰撞与统一伤害提交。
- ModuleBehaviorRegistry / MeleeModule：注册和验证攻击能力。
- ProgramParser / ProgramAst / ProgramRunner：显式调用节点、参数、行列和顺序等待。
- GameSession：目标判定、失败/重试；画布只读取状态。
- schemas：同步结构校验，运行时额外验证尺寸相关边界、引用和真实占地。

修改后运行 `tools/test.ps1`；测试必须覆盖拒绝非法输入、未知字段往返、旧位置目标、暂停与重试隔离。坏配置不能覆盖有效地图。

[此前存活时间与完整攻击系统的设计提案](history/JSON_EXTENSION_GUIDE_before_gate_melee.md) 保留作历史参考。存活目标、冷却、敌人 AI、模块受伤等提案尚未实现，不能直接安装其中的示例使用。
