# 关卡、装配与玩家存档

游戏关卡继续使用 `MapCodec` 的地图格式，不另造一种地形格式。内置第一至第十三关位于 `data/levels/level_001.json` 至 `level_013.json`，共 13 关，第十关为“猎人游戏”随机追击，第十二关为“八方来敌”有限循环与分波驻守；地图编辑器的 `data/maps/movement_lab.json` 不进入游戏关卡列表。辅助格式说明见 `schemas/level.schema.json`。

## 关卡规则

`properties.level` 可附加如下规则：

```json
{
  "order": 1,
  "description": "沿道路抵达终点。",
  "module_limit": 1,
  "allowed_modules": ["movement"],
  "goal": {"position": {"x": 5.5, "y": 1.5}, "radius": 0.25},
  "starter_program": "main() {\n    move(0, 4)\n}\n"
}
```

- `module_limit` 为 1..256 的整数；省略时为原出生装配的模块数，至少为 1。
- `allowed_modules` 为 1..256 个不重复的已注册模块 ID；省略时沿用原出生装配出现的模块类型。
- `allow_tick`、`allow_named_calls`、`allow_loops`、`allow_conditionals`、`allow_simultaneous`、`allow_distance`、`allow_functions`、`allow_variables`、`allow_radar` 均为独立可选布尔值，默认 false；依次开放回调、命名调用、循环、条件、并行动作、测距数值表达式、无参函数、常变量声明与赋值和雷达扫描 / 目标属性。字符串或数字会被拒绝；新增函数、变量或雷达权限不会暗中打开其他权限。雷达还要求 allowed_modules 中允许具有 RadarModule 行为的模块，并在运行时实际安装可用部件。见 [函数复用](FUNCTIONS.md) 与 [常量与变量](VARIABLES.md)。
- `max_ticks` 为 0..36000 的整数，默认 0 表示不限时；一个 tick 为 0.1 秒，暂停不推进此计时。
- `order` 为 -1000000..1000000 的整数，默认 0。内置关卡始终排在自定义关卡之前；各目录内部先按 order，再按源文件路径排序。
- `goal` 可省略或为 null，此时 `has_goal` 为 false，地图作为没有通关目标的沙盒。省略 `type` 时按 `reach_position` 处理，需要地图坐标 `position`；`radius` 默认 0.25，范围为大于 0、最多 0.25，终点区域须完整位于可通行地形上。其他目标类型按自身字段校验，无需伪造位置终点。
- `description` 与 `starter_program` 是最多 65536 字符的字符串。未知规则字段随地图原样保留；导入的代码始终由受限玩家语言解析，不执行任意 GDScript。

`LevelDefinition.from_document(document, content, path)` 返回 `DataResult`，成功值为关卡定义及其独立地图快照。所有可选默认值只体现在定义中，不修改原地图文件。

地图编辑器提供 `1..256` 的模块数量上限输入，通过 `MapEditorDocument.set_module_limit(limit)` 显式写入 `properties.level.module_limit`，其修改支持撤销和重做，保存后与其他关卡属性一起往返。修改上限只更新对应字段，保留已有终点、允许模块、初始程序和未知扩展数据；若原 `properties.level` 不是对象则返回错误，不能用空规则覆盖它。`get_module_limit()` 提供当前显示值，省略规则时沿用上述默认数量；编辑器测试使用当前文档中的上限，不要求先写盘。

`LevelCatalog.refresh(content)` 扫描 `res://data/levels/` 与 `user_directory`（默认 `user://levels/`）的顶层 JSON。坏文件与重复关卡 ID 进入 `errors`，同次扫描中其他有效关卡继续保留在 `levels`；返回结果也包含错误，因此 UI 应显示 `catalog.levels` 并单独呈现错误，不能因一个坏文件隐藏整页。自定义 ID 与内置 ID 冲突时不会覆盖内置关卡。

`ensure_import_directory()` 仅创建用户导入目录并返回绝对路径。打开系统文件夹由 UI 负责，模型没有操作系统窗口副作用。放入 JSON 后刷新关卡列表即可发现新增地图；普通地图也必须有合法出生点。

## 装配模型

`AssemblyModel.create(level, content)` 始终建立空装配，`GameSession.create()` 也不会预装模块。玩家每次进入关卡先进入独立组装页，主动放置模块，或点击“载入上次装配”恢复已有布局；确认合法装配后进入编程。

地图 `player_spawn.modules` 继续保留为地图格式与缺省关卡规则来源。正常关卡和编辑器测试都不会由玩家装配构造器隐式复制该模板，不需要为此改动地图 Schema。

`add_module`、`move_module`、`remove_module`、`rename_module` 在候选快照通过验证后才提交，并发出 `changed`；失败保持原装配。`add_module` 的成功值是新增模块索引。同步监听器再次请求添加模块时，也会按已经提交的数量检查容量。

组装 UI 列出全部 `ContentRegistry.modules`，把不在 `allowed_modules` 中的项禁用；达到 `module_limit` 时禁用所有新增入口。类型可见不代表允许安装；模型独立检查解锁条件和容量，不能依赖控件状态保证合法性。

偏移以机器参考点为原点，必须在 -4..4 内，以 0.5 格为步长。数量受关卡限制，类型必须已解锁，模块实际矩形不能重叠。模块名称以英文字母或下划线开头，其余字符仅含英文字母、数字和下划线，最多 128 字符且必须唯一。保留玩家语言的入口、指令、控制流、声明和布尔/空值名称，不能将它们用作模块名称。

装配画布允许首件在图纸内任意落格，并将成功落点记为视觉原点。传入模型与保存数据的首件中心偏移仍为 `(0,0)`，视觉原点不改变关卡出生位置；只有一个模块时不能移离此装配原点。后续新增或移动的模块必须与任意已有模块的实际矩形边缘共边，且共享边长大于零。允许向多个方向形成分支，不限制为单链；角点接触、中心距离接近或留有空隙都不算连接。

| 校验入口 | 要求与用途 |
| --- | --- |
| `validate_editing()` | 检查结构、网格、类型、数量、命名与重叠；允许空装配、缺中心、断连，用于草稿编辑与恢复 |
| `validate()` | 在编辑校验之外，要求至少一个模块、存在中心偏移严格为 `(0,0)` 的模块，且全部模块沿边连通 |
| `build_document()` | 通过最终 `validate()` 后应用到地图副本，再通过 `SimulationWorld.create()` 检查每个模块的实际出生占地 |

删除中心或桥接模块可以产生不完整草稿，玩家仍可保存、手动恢复和继续修复。缺中心、断连或出生占地进入 void 时禁用确认按钮，并在悬停提示中显示原因。运行入口同样必须通过最终校验；试运行和草稿都不会修改关卡原件。

这些中心与连通约束只属于游戏装配层，不改变底层地图格式或 `MachineFactory` 的通用规则。碰撞仍检查各模块实际矩形的并集，不将模块之间的空隙当成实体。内置第一关的上限仍为 1，当前共 10 个教学关卡（第一至第九关和第十一关）。

## 编辑器测试会话

编辑器的「校验」检查地图格式和 `properties.level` 规则；「开始测试」基于当前未保存地图创建 `LevelDefinition` 快照，连同编辑器的 `ContentRegistry` 交给游戏页面。有效出生配置是进入组装的前提，玩家实际模块的完整出生占地则在确认装配时通过 `build_document()` 检查。

每次开始测试都创建空装配，数量和类型受快照的 `module_limit` / `allowed_modules` 约束。确认后进入正常编程界面；同一次会话内可以反复切换组装与编程、停止或重置位置，并保留当前程序与布局。返回地图编辑器会结束本次会话，原文档、路径、未保存标记和撤销/重做历史保持不变；下次开始测试不会恢复上次测试的作品。

此入口不读取或写入下述 `GameDraftStore`，也不记录通关进度。保存草稿与载入上次装配入口隐藏，自动保存和完成事件只影响当前会话；即使编辑地图与正式关卡使用相同 ID，也不会覆盖其 `user://solutions` 文件。测试地图不加入关卡列表，不迁移到 `data/levels`。

## 正常关卡的草稿与进度

`GameDraftStore.new(directory)` 默认使用 `user://solutions/`，可注入独立测试目录。`save_draft(level_id, source, modules)` 保存程序和布局；`load_draft(level_id)` 在没有文件时成功返回 null，有文件时返回含 source、modules 的字典。草稿允许空程序，以及空装配、缺中心或断连的未完成布局；保存成功不代表通过最终运行校验。

进入关卡时只自动恢复源程序，已有装配暂存为可选的恢复数据。点击“载入上次装配”后才把旧布局应用到当前模型，使用 `validate_editing()` 重新检查结构、网格、关卡允许类型、容量、命名和重叠。缺中心和断连属于可修复的编辑状态，不应因最终 `validate()` 失败而丢弃；修复前仍不能确认或运行。未主动采用旧布局之前，当前玩家装配保持为空。

每个关卡 ID 经 SHA-256 映射为固定文件名前缀，因此 ID 中的斜杠等字符不会变成文件系统路径。草稿文件为 `<hash>.draft.json`，通关记录为 `<hash>.progress.json`。`mark_completed(level_id)` 只更新通关记录，保存草稿也不会清除通关状态。`is_completed(level_id)` 只将版本、关卡 ID 和布尔 completed 全部正确的记录视为已完成。

保存先验证，再写同目录临时文件并回读，最后备份旧文件并替换。常规写入或替换失败保留旧存档；恢复失败会保留备份并报告路径。此机制不承诺操作系统断电级事务。

`backup_draft(level_id)` 为恢复流程保留原草稿的完整字节，不要求其 JSON 可解析。没有原文件时成功返回 null；否则写入同目录唯一的 `<hash>.draft.recovery.*.json` 并校验内容，成功返回绝对路径。恢复备份不会随下一次保存被删除。

界面遇到损坏草稿或不兼容装配时会给出提示。仅打开再返回不会覆盖旧文件；玩家修改内容或手动保存时，先创建恢复备份，成功后再保存当前作品。

## 菜单与设置

主菜单提供开始、地图编辑器、设置和离开。地图编辑器只由主菜单进入；开始进入关卡列表，选择关卡后先组装再编程。页面切换由 UI 负责，关卡、装配与模拟模型不持有菜单节点。

`GameSettings.new(path)` 默认使用 `user://settings.json`。`load_settings()` 在缺失文件时采用默认值；`set_volume(value)` 接受 `0..1` 的有限数值，`set_language(value)` 接受 `zh_CN` 或 `en`，`set_tab_completion(value)` 接受布尔值，`set_code_hints(value)` 接受 `none`、`normal` 或 `more`。有效值立即应用并保存；错误通过 `DataResult` 和 `last_error` 提供，界面不能把写盘失败显示为已持久化。

配置使用独立 JSON：`format_version = 1`、`audio.master_volume`、`interface.language`、`interface.tab_completion` 和 `interface.code_hints`。Tab 补全默认 true，代码提示默认 normal（一般）；旧文件缺字段时采用默认值，读取不会主动改写文件。none（无）隐藏提示，normal（一般）在连续失败三次后显示，more（多）立即显示；只有正式教学关卡提供入口。主音量作用于 Master 音频总线，零值静音；语言在简体中文和 English 之间切换。未知字段在保存时保留，方便日后扩展设置；它与玩家作品及关卡完成状态分别存储。


## 第二、三关新增能力

本版已增加 `MeleeModule`、`attack(角度)`、`timed_gate`、`destructible` 与 `goal.type: destroy_object`。旧位置目标和无对象地图保持兼容；详细字段和边界请见 [闸门与近战](GATE_AND_MELEE.md)。

## 函数权限与闪避目标

第十一关“巧能躲避”使用 `allow_functions: true`、`allow_variables: true`、`allow_radar: true` 和下列目标；第十关地图仍跳过，本关直接开放继承的常变量、雷达模块与扫描，不读取第十关通关记录作为前置条件。前九关权限不变。

```json
{
  "order": 11,
  "module_limit": 2,
  "allow_functions": true,
  "allow_variables": true,
  "allow_radar": true,
  "allowed_modules": ["movement", "melee", "shooting", "rangefinder", "radar"],
  "max_ticks": 900,
  "goal": {"type": "dodge_attacks", "enemy_id": "radar_hunter", "attack_count": 5}
}
```

这是 `properties.level` 的字段片段，测距、命名调用等已学权限见正式 `level_011.json`。雷达查询和结果语法见 [玩家雷达](PLAYER_RADAR.md)。`attack_count` 必须是 1..1000 的整数，不接受布尔值、数字字符串或小数。`enemy_id` 必须引用本地图已注册行为为 `radar_lunge` 的敌人。成功的 `LevelDefinition` 保存 `goal_enemy_id` 和 `goal_attack_count`，不会改写原输入数据。

`GameSession` 读取实际敌人攻击状态：目标敌人的有效近战落空才计入闪避，命中任意玩家模块立即失败；达到要求次数时取消循环并只发送一次完成事件。`main()` 正常结束后敌人仍行动，无法靠空程序冻结战斗。停止或重试清除世界计数，源码和装配草稿保持原状；第十一关继续用自身稳定 ID 保存进度，不改动旧关卡记录。敌人 JSON 字段见 [Mod 指南](../MODDING.md)，完整场地规则见 [闪避教学](FUNCTIONS_AND_DODGING.md)。

## 教学提示的连续失败记录

正式教学关卡的 `<hash>.progress.json` 增加可选的 `failure_streak`，为 `0..1000000` 的整数，默认 0。`get_failure_streak(level_id)` 读取旧文件时使用默认值而不改写；`save_failure_streak(level_id, count)` 只更新当前关卡计数，保留完成状态与已有扩展字段。损坏或类型无效的旧记录不得被提示保存覆盖；写盘仍走原有临时文件验证与替换流程。

`GameSession` 对每次实际失败只增加一次计数；成功清零。Shell 进入正式教学关卡时恢复计数，失败时保存，通关记录同时写入零，因此退出重进和重启游戏后仍保持该关累计状态。手动停止或重置位置不增加失败次数，也不清除已有次数；导入关卡及编辑器测试不写提示计数。

代码提示由独立设置 `interface.code_hints` 控制，存档中的失败次数不会覆盖该偏好。提示与相邻 SVG 撤销按钮只操作编辑器最新提示事务，不能丢失后续手工编辑。服务不写存档或原会话，完整契约见 [代码提示](CODE_HINTS.md)。

第十关新增的可信 `random_wander` 行为及配置边界见 [猎人游戏](RADAR_PURSUIT.md)，地图版本仍为 1。未知敌人行为继续保留为元数据，不执行宿主脚本。
