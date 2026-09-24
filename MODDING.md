# 内容扩展说明

本阶段使用 JSON 定义模块和地块，地图引用稳定内容 ID。修改速度、尺寸或贴图等现有行为的变体不需要改模拟代码；增加攻击等全新行为需要程序员实现并注册受信任代码。

`schemas/module.schema.json`、`schemas/tile.schema.json`、`schemas/map.schema.json` 与 `schemas/level.schema.json` 提供 JSON Schema，可配置到代码编辑器中获得字段提示和结构检查。尺寸相关边界、重复坐标与 ID、实际内容引用、图片可解码性和完整模块占地仍由游戏代码校验。

## 目录与载入

默认模块来自 `data/modules/*.json`，默认地块来自 `data/tiles/*.json`，贴图放在 `assets/`。编辑器同时扫描 `user://data/modules` 与 `user://data/tiles`；放入外部定义后点击“重载内容”即可更新内容列表与贴图。扫描只读取指定目录的直接 JSON 文件，不递归读取子目录。

`res://` 对应工程资源，`user://` 对应 Godot 用户数据目录。内容加载器也支持传入多个目录，因此其他入口可以指定额外内容包位置：

```gdscript
# 用途：从内置内容和一个指定的外部内容包建立统一注册表。
func load_content_pack() -> DataResult:
	var registry := ContentRegistry.new()
	return registry.load_directories(
		PackedStringArray(["res://data/modules", "user://mods/example/modules"]),
		PackedStringArray(["res://data/tiles", "user://mods/example/tiles"])
	)
```

缺失的可选 `user://` 内容目录作为空目录处理。不同内容包必须使用不同 ID，同类重复 ID 会使整个载入失败，不能依赖文件顺序覆盖已有内容。

## 新增移动模块变体

例如创建 `data/modules/fast_movement.json`：

```json
{
  "format_version": 1,
  "id": "example.fast_movement",
  "name": "快速移动模块",
  "description": "提供每秒两单位的移动速度。",
  "size": {"width": 0.5, "height": 0.5},
  "texture": "res://assets/modules/movement.svg",
  "script_type": "MovementModule",
  "properties": {"move_speed": 2.0}
}
```

| 字段 | 含义 |
| --- | --- |
| `format_version` | 当前只接受 `1` |
| `id` | 稳定引用 ID；支持英文字母、数字、`_`、`-`、`.`，最长 128 字符 |
| `name` | 界面显示名，可以使用中文 |
| `description` | 可选说明 |
| `size.width` / `size.height` | 模块占地宽高，使用地图单位，范围 `0.001..256` |
| `texture` | 有效的 `res://` 或 `user://` 图片路径 |
| `script_type` | 程序已注册的行为名称，本阶段为 `MovementModule` |
| `properties.move_speed` | 每秒世界单位，必须是有限正数 |

保留名称 `void` 不能作为内容 ID。数值字段不能写 `true`、`false` 或数字字符串。资源路径使用 `/`，不能包含 `..`。支持 PNG、JPG/JPEG、WebP 和 SVG，文件需要存在且可解码；可以复用已有贴图，也可以添加新图片并更新 `texture`。

要在游戏或地图编辑器测试中使用变体，让 `properties.level.allowed_modules` 包含 `example.fast_movement`，再在组装页主动安装。两个入口每次都从空装配开始，出生模板不会自动预装到玩家机器；省略允许列表时才从出生模板推导可用类型。下面的出生模板展示双模块的数据结构，`id` 是机器内的模块实例名，`module_id` 才是内容定义名：

```json
{
  "position": {"x": 1.5, "y": 1.5},
  "modules": [
    {"id": "left_drive", "module_id": "movement", "offset": {"x": 0, "y": 0}},
    {"id": "right_drive", "module_id": "example.fast_movement", "offset": {"x": 0.5, "y": 0}}
  ]
}
```

这两个 `0.5 × 0.5` 模块有一段正长度的共边，合计速度为每秒 `3` 单位。模块中心偏移以世界单位计算；模块不能占地重叠，完整占地都必须得到可通行地块支撑。游戏图形装配采用 `0.5` 格步长和 `-4..4` 偏移范围，并受关卡数量及允许类型限制。要在游戏中安装这个组合，自定义关卡的模块上限至少为 2；内置第一关仍只允许 1 个移动模块。

游戏装配的第一个模块必须放在 `(0,0)`，只有一个模块时不能移离中心。后续新增或移动的模块必须与任意已有模块的实际矩形共享正长度的边；允许分支，角点和空隙不算连接。自定义尺寸也按真实矩形判断，因此网格中心相邻不一定意味着模块共边。

删除中心或桥接模块后，可以保存并手动恢复缺中心或断连的草稿继续修复。`validate_editing()` 只检查编辑所需的结构、网格、类型、数量、命名与重叠；最终 `validate()` 还要求中心模块和整体沿边连通，`build_document()` 再检查出生占地。缺中心、断连或落入 void 时不能确认运行，按钮悬停会显示原因。

中心与连通要求属于游戏装配层，不改变地图 JSON 或 `MachineFactory` 的通用约束，也不要求为地图编辑器模板新增字段。底层碰撞仍使用实际模块矩形的并集，不填充空隙。

## 新增地块变体

创建 `data/tiles/blue_floor.json`，并指定自己的贴图或复用默认贴图：

```json
{
  "format_version": 1,
  "id": "example.blue_floor",
  "name": "蓝色地板",
  "texture": "res://assets/tiles/floor.svg",
  "collision": false,
  "radar_block": false,
  "properties": {}
}
```

`collision: false` 允许机器通行，`true` 会阻挡。`radar_block: true` 会遮挡第十一关敌方雷达的目标检测；它与地形通行的 `collision` 含义独立。玩家 `scan()` 仍未开放。增加如 `properties.friction` 的字段只会保存数据；现有移动行为不会自动采用未实现的属性。

## 地图 JSON

最小可运行地图示例，只有一条长度为五格的地板路径，其余区域全为 void：

```json
{
  "format_version": 1,
  "id": "example.straight_path",
  "name": "直线路径",
  "width": 5,
  "height": 3,
  "tiles": [
    {"x": 0, "y": 1, "tile_id": "floor"},
    {"x": 1, "y": 1, "tile_id": "floor"},
    {"x": 2, "y": 1, "tile_id": "floor"},
    {"x": 3, "y": 1, "tile_id": "floor"},
    {"x": 4, "y": 1, "tile_id": "floor"}
  ],
  "player_spawn": {
    "position": {"x": 0.5, "y": 1.5},
    "modules": [
      {"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}
    ]
  },
  "enemies": [],
  "objects": [],
  "dialogue": [],
  "properties": {}
}
```

地块坐标必须是图内整数，不允许重复坐标。尺寸范围为 `1..256`；单个 JSON 文件不超过 `8 MiB`。不要写 `{"tile_id":"void"}`，直接省略对应格子。

机器世界坐标可以带小数。`position: {"x":0.5,"y":1.5}` 位于格子 `(0,1)` 中心。安装中心移动模块后，`move(0, 4)` 会把机器送到 `(4.5,1.5)`。在地图编辑器点击「开始测试」，先从空装配放置模块并确认，再在程序面板编写下方的语言子集；编辑器不再提供单次移动表单。程序员仍可用 `SimulationWorld.request_move()` 编写底层模拟测试。

编辑草稿可以使用 `"player_spawn": null`，开始测试前必须放置合法出生点并通过地图与关卡定义校验。出生模板不会被直接运行；玩家实际装配的中心、连通与完整出生占地在确认装配时检查。`enemies` 与 `objects` 的记录需要图内 `position`，可选 `id` 在两类实体之间也不能重复；可选 `modules` 使用与出生点相同的清单格式。`dialogue` 条目需要字符串 `text`，可选 `speaker`。只有明确注册的敌人行为与对象类型会参与模拟，其他记录继续保留为数据；地图对话会在游戏界面显示。

自定义地图属性可以放进 `properties`。未知顶层字段和现有记录内的扩展字段会在加载与保存时保留，适合未来增加目标、触发器等配置。它们必须是有限数字、字符串、布尔值、数组、对象或 `null`，且嵌套不超过 32 层。

## 导入游戏关卡

游戏关卡列表分为「教学关卡」与「导入关卡」，共用七列纵向滚动。教学来自内置目录，包含第一至第九关及第十一关共 10 关，默认显示前七项，右侧按钮显示教学总数并展开或收起。用户关卡按来源进入导入分类，其“+”入口固定在该分类第一格。点击“+”进入导入流程，把地图 JSON 放入 `user://levels`，再刷新列表。目录只扫描直接 JSON 文件。坏文件会显示诊断，其余有效关卡仍可选择；重复 ID 不能覆盖内置关卡。

没有 `properties.level` 的普通编辑地图可以作为沙盒导入：沿用出生装配的模块类型与数量，没有终点要求。导入游戏的地图需要有效出生点；无出生点草稿仍应在地图编辑器中继续制作。

要让上面的五格直线路径成为有通关条件的关卡，把地图的 `properties` 改为：

```json
{
  "level": {
    "module_limit": 1,
    "allowed_modules": ["movement"],
    "goal": {"position": {"x": 4.5, "y": 1.5}, "radius": 0.2},
    "starter_program": "main() {\n    // 在这里编写移动指令。\n}\n",
    "description": "沿地板移动到右侧终点。",
    "order": 10
  }
}
```

`module_limit` 为 `1..256`，可在地图编辑器的模块数量上限输入中设置，支持撤销、重做和保存；其他关卡属性继续通过元数据 JSON 编辑。`allowed_modules` 必须是无重复的已注册模块 ID 列表。终点半径范围为 `0 < radius <= 0.25`，其包围矩形必须落在可通行地块上。机器参考点到达或经过终点范围即成功，程序结束却未抵达终点则失败。省略 `goal` 或设为 `null` 会启用沙盒，不作终点要求。

`order` 控制同一来源目录内的排列顺序，内置关卡保持在导入关卡之前。`starter_program` 是玩家首次进入时的模板，不要求包含答案；玩家修改后的程序与装配另存于 `user://solutions`，不会写回关卡 JSON。

地图编辑器的「开始测试」直接使用当前未保存地图快照和已加载的内容注册表，不必先保存或导入关卡目录。当前模块上限、允许列表和初始程序立即用于新测试会话。组装与编程之间切换、停止和重置会保留本次程序与装配；返回地图编辑器即结束测试，保留原地图文档、路径、未保存标记和撤销/重做历史，下次重新从空装配开始。

编辑器测试不读取或覆盖 `user://solutions` 的草稿和通关记录，界面不提供保存草稿或载入上次装配。正式关卡仍按上面的存档规则运行；本轮没有合并 `data/maps` 与 `data/levels`，内置包含第一至第九关及第十一关，共 10 关，第十关暂时跳过。

## 玩家程序子集

当前程序使用单一 `main()` 入口和逐行顺序执行的移动指令：

```text
main() {
    // 角度 0 向右，90 向上；移动结束后才执行下一条。
    move(0, 4)
}
```

参数支持正负整数或小数，距离必须非负。支持空行、`//` 注释和 Windows 换行；每条调用之间必须换行，不使用分号。界面会显示解析或执行错误所在行。阻挡会终止当前程序，修改后重新运行会从原始出生位置开始。

当前按关卡开放 move/attack/shoot、tick 回调、命名调用和 main 内的 `loop {}`。在 `properties.level` 设置 `allow_named_calls: true` 或 `allow_loops: true` 可分别解锁后两者；缺省关闭。循环不会自动计数，到达关卡目标时由会话停止，tick 内不能循环。语法与限制见 [循环与阶梯](docs/LOOPS_AND_STAIRCASE.md)。第七关可用 `allow_conditionals: true` 开放 `if (gun.ready()) { ... } else { ... }`，并同时开启具名调用与射击。第七关只支持具名射击冷却条件；第八关开放 simultaneously，第九关开放测距数值表达式，第十一关通过 `allow_functions: true` 开放无参用户函数；常量和变量仍未开放；不要把模块 ID 写成任意脚本路径。

## 新增行为代码

JSON 的 `script_type` 是注册名称，不是脚本路径。运行时不从 Mod JSON 执行任意 GDScript，也不会自动把新字段变成玩法。

程序员添加全新行为的步骤：

1. 在 `scripts/modules/` 添加继承 `ModuleBehavior` 的脚本，为每个函数写中文说明。
2. 覆盖 `validate_definition()` 检查该行为的专用属性，并实现对应能力方法。
3. 通过 `ModuleBehaviorRegistry.register_behavior()` 注册唯一名称；内置行为通常加入 `create_default()`。
4. 为新的能力增加命令与模拟结算逻辑，保持计算提案和统一提交分离。近战已通过独立攻击能力接口实现；冷却、雷达等新系统仍需代码，不能仅靠移动接口完成。
5. 创建引用新名称的 JSON，补充行为测试，并扩展语言的 AST、执行器和关卡能力限制以暴露新的调用。

内容层允许合法的未注册行为名称被编辑和保存；实际装配时会明确报错，避免悄悄变成空行为。新增纯移动变体继续使用现有 `MovementModule` 即可。

开发结构与测试运行方法见 `docs/ARCHITECTURE.md`。

关卡、装配和存档的字段与 API 详解见 `docs/GAMEPLAY_DATA.md`。


## 第二、三关新增能力

本版已增加 `MeleeModule`、`attack(角度)`、`timed_gate`、`destructible` 与 `goal.type: destroy_object`。旧位置目标和无对象地图保持兼容；详细字段和边界请见 [闸门与近战](docs/GATE_AND_MELEE.md)。


## 第七关条件与追击敌人

`properties.level.allow_conditionals` 为可选布尔值，缺省 false，不改变旧关卡。条件只查询装配中真实射击模块的 `ready()`；两个非空分支均在运行前校验。`main` 中可以配合 loop，`tick` 中分支仍只能包含有限短动作，不能移动或循环。

新的注册行为 `advance_attack` 每个 tick 向 `properties.move_angle` 持续推进，并同时向 `properties.attack_angle` 近战；这两个字段必须是有限数字，不需要 `move_distance`。碰墙或失去驱动不会停止其可用近战模块。可选 `properties.module_health` 是实例名称到耐久的字典，例如 `{"blade": 10}`，只允许当前敌人装配中的实例 ID，耐久为0.01..1000000。只覆盖该敌人的运行实例，不改变全局模块定义或玩家耐久；旧 `approach_attack` 与 `alarm_guard` 保持原规则。

关卡仍使用版本1地图格式，Schema 位于 `schemas/map.schema.json` 与 `schemas/level.schema.json`。未知扩展字段仍保留；敌人行为只允许已注册代码，JSON 不能执行脚本。完整示例和执行边界见 [条件判断与追击](docs/CONDITIONALS_AND_PURSUIT.md)。


## 第八关：双联动警报与同步动作

地图格式版本继续为 1。新对象 `paired_alarm` 使用 `properties.max_health` 和 `properties.partner_id`；关联必须双向、指向另一真实同类对象且不能自指。安全门的 `required_object_ids` 可以引用这些警报器。警报仍工作时，玩家发生实际位移会触发；其中一个被毁而另一个存活也会触发。同一个 tick 的全部伤害统一结算，所以同帧解除两个目标不会误报警。

`properties.level.allow_simultaneous` 是默认 false 的独立布尔解锁项。开启后，main 内可以使用 `simultaneously { ... }`，块内至少两条直接 move/attack/shoot 调用，具名调用仍要求对应权限。一个组最多一次整机移动，模块资源不能重叠，广播调用也遵循此限制。所有动作一次提交、同帧启动，全部完成后执行后续代码。详见 [同步越狱与并行动作](docs/SIMULTANEOUS_AND_ALARMS.md)。

新目标 `escape_alarms` 包含 `alarm_ids`（恰好一对关联警报 ID）、`position` 与 `radius`（大于 0 且不超过 0.25）。玩家必须安全解除这对警报并真正抵达出口；仅解除警报不能通关。第八关的 JSON 展示了完整可用格式。指令合集通过 `data/commands/100_simultaneously.json` 和 `allow_simultaneous` requirement 自动呈现对应解锁状态。

## 第九关：测距与数值查询

内置模块 `rangefinder` 使用已注册的 `RangefinderModule`，尺寸为半格；定义不要求额外能力参数。`properties.level.allow_distance` 是默认 false 的布尔值，在允许模块中加入该部件并显式开启权限后才能使用 `distance(角度)`。具名查询还需 `allow_named_calls`，数值比较还需 `allow_conditionals`。裸测距必须只有一个可用测距实例，多个实例要用名称选择。

测距从模块中心计算到首个当前阻挡表面，可用在动作参数、有限加减表达式或 `< <= > >= == !=` 比较中。只读查询不消耗 tick，也不保证装配的完整占地可通过；不要把查询单独写成动作。变量、赋值和逻辑组合不属于本关语言范围。指令资料 JSON 可用 `allow_distance` requirement，测距目录按真实 `RangefinderModule` 行为自动归类。详见 [测距实现](docs/RANGEFINDING.md) 和 [教学关卡](docs/RANGEFINDING_TUTORIAL.md)。

## 第十一关：函数与雷达突袭

自定义无参函数由 `properties.level.allow_functions` 独立解锁，必须是布尔值，省略即锁定。使用 `function 名称() { ... }` 顶层声明，再以 `名称()` 调用；函数体内的测距、条件、循环和并行动作仍各自要求原权限。函数参数、返回值、递归、空函数、常量和变量不在当前范围。完整语言边界见 [函数复用](docs/FUNCTIONS.md)。指令资料可用 `requirements.allow_functions` 跟随关卡锁定状态。

敌人行为 `radar_lunge` 需要真实的移动、近战与雷达模块，可参考 `data/levels/level_011.json`。在敌人的 `properties` 中配置：

| 字段 | 类型与约束 |
| --- | --- |
| `attack_module_id` | 自身已有近战模块的实例 ID，行为必须是 `MeleeModule` |
| `radar_module_id` | 自身已有雷达模块的实例 ID，行为必须是 `RadarModule`，不能与攻击实例相同 |
| `attack_angle` | 有限数字，采用与 move 相同的绝对角度 |
| `stand_off` | 0.5..32 的有限数字，攻击模块中心距离锁定位置的停步距离 |
| `approach_distance` | 0.5..32 的有限数字，从准备位置接近到攻击位置的路程 |
| `recovery_ticks` | 1..600 的整数，每次出手后的恢复时间 |

`RadarModule` 内容定义必须提供 `properties.radar_range`，为大于 0、最多 512 的有限数字。扫描来自存活雷达的真实中心，并读取地块 `radar_block`；失效雷达不能继续锁定。当前只提供敌人行为所需的检测，玩家 `scan()` 不会因注册了雷达部件而自动可用。

关卡目标 `{"type":"dodge_attacks","enemy_id":"radar_hunter","attack_count":5}` 必须引用实际 `radar_lunge` 敌人，次数为 1..1000 的整数。计数依赖有效攻击落空，取消动作、失效模块或摧毁敌人不算闪避；该敌人任一次近战命中玩家部件都会立即失败。场地、实际节奏和参考解法见 [巧能躲避](docs/FUNCTIONS_AND_DODGING.md)。所有新字段继续兼容 `format_version: 1`，不替换旧关卡数据或玩家草稿。
