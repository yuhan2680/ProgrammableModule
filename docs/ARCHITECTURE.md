> 2026-09-22 启动流程：正式入口为 `scenes/startup.tscn`。轻量 `startup_loader.gd` 不预载游戏类，先呈现白底细进度条，再用 ResourceLoader 后台加载游戏场景和字体；资源完成后才获取并在主线程实例化。GameShell 仅在收到启动回调时分帧初始化，直接运行 `game.tscn` 与编辑器场景保留同步行为。进度依照加载器和六个初始化阶段推进，主菜单布局与背景缓存就绪才满格；先显露背景，再弹出卡片。失败保留重试入口，中途关闭清理未交接场景，启动完成移除覆盖层。

> 2026-09-19 第十五关“自动索敌”：独立 `allow_radar_events` 开放顶层固定绑定 `radar.onDetected { EnemyPosition -> target }`。Runner 在首次动作前及每个逻辑 tick 开始时刷新全局目标快照，无目标写入 null；不增加任意回调执行。三模块、四格主路与十波战斗沿用第十四关结构，敌方每模块耐久 2.8，详见 [雷达事件](RADAR_EVENTS.md)。

> 2026-09-18 第十四关：按用户确认使用三个模块。四格主通道与左右各五条细支道构成鱼骨地图；栅栏阻挡机器、放行攻击，十波每个敌方模块耐久 2.7。新增可选 `attack_block` 和 `activation_region` 保持旧默认值，详见 [通道清剿](CORRIDOR_SWEEP.md)。

> 2026-09-17 第十三关“十面埋伏”：最多两个模块，推荐中心雷达加右侧射击，10 波敌人从连续随机角度依次接近；每个敌方移动/近战模块耐久 2.0，整机被毁后约 3 秒淡出。继承此前解锁，保持真实碰撞与雷达语义，详见 [十面埋伏](AMBUSH.md)。

> 2026-09-17 第十二关：“八方来敌”使用最多两个模块防守八个方向的顺序来敌。独立 `allow_for` 开放包含两端、可指定步长的有限循环；`if` 支持省略 `else`。`EnemyWaveController` 只在固定 tick 激活当前波，未来波次不参与查询或伤害；`destroy_waves` 必须清空全部波次才成功。第十二关继承此前工具权限，旧十一关仍不开放 `for`。规则与验证见 [八方来敌](EIGHT_DIRECTIONS.md)。

> 2026-09-17 玩家随机函数：第十、十一关显式开放独立 `allow_random` 权限，默认关闭且不依赖模块。`random()` 返回 `[0,1]` 数值，`randomInt(a,b)` 返回两端包含的整数；每个 Runner 独立采样，预检和 UI 不采样，暂停冻结、重试重新初始化。随机函数只是可选工具，不成为通关条件。详见 [随机函数](RANDOM_FUNCTIONS.md)。

> 2026-09-15 代码配色：设置新增「颜色与显示」子页，`GameSettings.code_color_mode` 保存 light/dark，默认 light。`GameTheme.style_code()` 统一预览和真实代码区样式，dark 使用 `#121314`；只修改控件本地主题并保留编辑与运行状态。两级设置页通过 `SettingsScrollFade` 仅改变原生滚动条透明度，保留右侧 24 像素间距和原布局。见 [代码区颜色与显示](CODE_COLORS.md)。

> 2026-09-16 第十关更新：第一至第十一关共 11 关。“猎人游戏”是三模块综合复习，允许雷达、移动、射击和可选常变量；120 秒内追击并击毁 18 点耐久的随机游走敌人。random_wander 使用独立随机源与真实移动，不改全局模块属性。第十一关保留“巧能躲避”和既有全部权限，前九关不变。见 [猎人游戏](RADAR_PURSUIT.md)、[常量与变量](VARIABLES.md) 与 [玩家雷达](PLAYER_RADAR.md)。

> 2026-09-14 第九关更新：“蜿蜒穿行”新增独立测距模块与 `distance(角度)`，从部件中心只读测量首个阻挡表面。`allow_distance` 单独解锁有限数值加减及比较，变量仍未开放。旧关卡权限不变；见 [测距与蛇形隧道](RANGEFINDING.md)。下方早期“只支持字面量/ready 条件”的描述为当时版本范围。

> 2026-09-14 第八关更新：新增显式 `simultaneously {}` 与双联动警报，同一逻辑帧启动独立动作并等待全部完成。报警判断在统一伤害提交后进行，移动禁令读取 tick 开始时的警报状态。兼容边界见 [同步越狱与并行动作](SIMULTANEOUS_AND_ALARMS.md)；下方早期“并行未实现”的描述为历史记录。

> 2026-09-12 第七关更新：新增具名射击 ready()、if / else 和持续推进攻击行为，语法、格式及兼容边界见 [条件判断与追击](CONDITIONALS_AND_PURSUIT.md)。下方早期“条件未实现”的描述为历史记录。

> 2026-09-12 第六关更新：当前已加入显式无限 loop {} 与十组阶梯；旧阶段“循环未实现”的记录由 [循环与阶梯](LOOPS_AND_STAIRCASE.md) 取代。

> 2026-09-12 更新：第五关新增命名模块调用、警报守卫、安全门与复合越狱目标。当前范围见 [越狱与命名调用](PRISON_AND_NAMED_CALLS.md)；下方旧阶段中的“未实现命名调用 / 前四关”属于历史记录。

> 2026-09-11 更新：用户要求按 ProgramLevel.md 制作第四关，本轮新增射击、敌方模块耐久及逐关解锁的 tick()。以下旧阶段记录中“尚无敌人 / 不使用 tick / 前三关”的范围由文末更新及 [射击与敌人设计](SHOOTING_AND_ENEMIES.md) 取代；原有三关、装配与存档约定继续有效。

# 底层架构与开发约定

截至 2026-09-19，工程包含第一至第十五关共 15 个教学关卡。数据、固定 tick 模拟、地图编辑器和游戏会话继续分层；每次进入关卡先从空装配开始，确认后进入编程。当前支持移动、近战、射击、测距、玩家雷达、已注册敌人行为，以及逐关开放的条件、循环、并行动作、无参函数、常变量和随机函数。第十一关直接开放继承的常变量和玩家雷达扫描，第十关已补齐随机追猎复习；敌方雷达用于固定突袭，玩家扫描只读当前世界并返回独立目标快照。

## 分层与职责

| 层 | 主要文件 | 职责 |
| --- | --- | --- |
| 内容 | `scripts/data/content_registry.gd` | 扫描 JSON，建立模块与地块定义，检查资源与引用 |
| 地图 | `scripts/data/map_document.gd`、`map_codec.gd`、`map_validation.gd` | 稀疏地图、未知字段保留、格式校验与文件存储 |
| 模块 | `scripts/modules/` | 模块定义的行为实例、能力计算与可信行为注册 |
| 模拟 | `scripts/simulation/` | 机器装配、命令生命周期、10 Hz tick、地形碰撞与战斗；`RadarLungeController` 只通过普通世界动作控制锁定突袭 |
| 编辑 | `scripts/editor/map_editor_document.gd` | 独立于界面的编辑事务、保存点和撤销重做 |
| 关卡与装配 | `scripts/gameplay/level_definition.gd`、`level_catalog.gd`、`assembly_model.gd` | 关卡规则、内置与导入列表、装配编辑校验及最终中心/连通校验 |
| 语言 | `scripts/language/` | 词法分析、语法分析、AST 与执行器；`ProgramFunctionValidation` 验证函数调用，`ProgramVariableValidation` 验证绑定与词法作用域 |
| 游戏会话 | `scripts/game/game_session.gd` | 组合程序、装配与世界，管理运行、暂停、失败和通关 |
| 玩家草稿 | `scripts/gameplay/game_draft_store.gd` | 按关卡保存程序、装配和完成记录 |
| 设置与翻译 | `scripts/gameplay/game_settings.gd`、`scripts/ui/game_i18n.gd`、`settings_panel.gd` | 音量、语言、Tab 补全、代码提示等级与界面翻译 |
| 代码提示 | `scripts/gameplay/code_hint_service.gd`、`data/hints/` | 教学来源与装配核对、独立模拟验证、返回一条源码修改；不改玩家会话或存档 |
| 展示 | 游戏 UI、`scripts/editor/` 中的画布与控制器、`scenes/` | 主菜单、关卡四列网格、独立组装页、程序面板、绘图和时间驱动 |
| 回归 | `tests/headless_runner.gd`、`tests/gameplay_runner.gd` 及语言、场景测试 | 分层验证数据、语言、编辑器和玩家流程 |

内容、地图、模块、模拟与编辑文档均使用 `RefCounted` 数据对象。它们不持有 UI 节点、不读取键盘、不依赖画布像素或物理帧。其他程序员可以更换界面而保留相同数据与模拟接口。

`GameSession` 同样不读取文件，也不会自动记录真实进度。界面负责把草稿注入会话、在需要时调用 `GameDraftStore`，因此无界面测试能够运行整个第一关而不修改玩家存档。

## 地图与单位

- 一格地板是 `1 × 1` 世界单位，地图尺寸为 `1..256` 的整数格数。
- 坐标原点在左上，X 向右、Y 向下。`move` 使用玩家设计角度：`0°` 向右、`90°` 向上、`180°` 向左、`270°` 向下。
- `MapDocument.cells` 只存明确放置的地块，键为 `Vector2i`，值为地块 ID。不存在的格子与地图边界外始终是 `void`。
- `void` 不注册为地块、不写入 JSON；擦除格子等同于删除该位置的记录。
- 默认移动模块占地 `0.5 × 0.5`。机器位置是装配参考点；模块 `offset` 表示相对参考点的中心偏移。
- 机器没有额外的 Core 实体。碰撞按各个可用模块的矩形分别计算，模块之间的空隙不会被填充为整机碰撞体。
- 模块可以相邻排列，不能在同一机器内占地重叠。多个移动模块的“叠加”指移动能力相加。

玩家装配的中心与连通要求由 `AssemblyModel` 管理，不下沉到地图格式、`MachineFactory` 或通用碰撞代码。底层机器继续按各模块的实际矩形校验；连通规则不改变碰撞形状。编辑器测试使用玩家在组装页确认的布局，出生模板不作为预装机器。

定义中的 `collision: true`、未知地块、无地块和越界都视为不可通行。通行判定不硬编码 `floor` ID，因此新增可行走地块只需内容定义。

## 数据边界

`DataResult` 统一携带 `value` 与 `errors`。使用结果前必须调用 `is_ok()`，失败内容可直接供 UI 展示。公开输入边界先检查真实类型再转换，避免 GDScript 把布尔值悄悄转为数值。

`ContentRegistry.load_directories()` 以稳定顺序加载指定目录。一次加载中任何定义失败，旧注册表保持完整；相同 ID 不会被后加载的文件静默覆盖。

`MapCodec` 提供四个主要操作：

```gdscript
MapCodec.load_file(path, content, require_spawn)
MapCodec.from_dict(data, content, require_spawn)
MapCodec.validate(document, content, require_spawn)
MapCodec.save_file(document, path, content, require_spawn)
```

`require_spawn = false` 允许编辑器保存尚未设置出生点的草稿。`true` 检查完整运行地图格式，但模块是否真正落在可通行地形上由 `SimulationWorld.create()` 的装配检查负责。不要把“可以保存”当作“可以运行”。

写盘前先校验完整文档，再写同目录临时文件并回读检查，最后备份旧文件并替换；常规替换失败会恢复旧文件。返回失败时界面保留未保存标记。该机制避免普通写盘或验证失败覆盖有效地图，不承诺操作系统断电级事务。

地图顶层未知字段进入 `extra`；地块条目的未知字段进入 `cell_extras`。`properties`、敌人、物品、对话、出生配置中的扩展数据也会保留。删除地块会删除该地块元数据。敌人与未知类型物品只作校验与存储；`timed_gate` 和 `destructible` 对象通过可信类型参与模拟；游戏入口会逐句显示地图对话，但尚未实现运行中的条件触发对话。

修改格式时必须考虑 `format_version`。遇到未知版本应明确报错；日后需要迁移时，应先转换到当前标准字典，再交给统一校验与构造。

## 模拟与命令

```gdscript
# 用途：展示上层如何通过公开接口建立世界并提交移动。
func start_example(document: MapDocument, content: ContentRegistry) -> DataResult:
	var created := SimulationWorld.create(document, content)
	if not created.is_ok():
		return created
	var world: SimulationWorld = created.value
	return world.request_move(world.player.id, 90.0, 2.0)
```

`create()` 深拷贝地图，试玩位置与编辑草稿互不回写。当前从 `player_spawn` 实例化玩家；未来系统可以通过 `MachineFactory` 和 `add_machine()` 添加其他机器，所有机器使用相同地形规则。

调用 `request_move(machine_id, angle, distance)` 只入队，不立即移动。一个机器同时只有一个排队或执行中的动作，移动和攻击互斥；忙碌时返回错误。距离必须是有限非负数，零距离合法，角度会归一化到一周。

`world.step()` 固定推进 `0.1` 秒：

1. 使用当前状态计算所有机器本 tick 的位移提案。
2. 统一提交位置和命令状态。
3. 清理已结束命令，发送命令结束信号与 `tick_completed`。

移动速度是所有可用移动模块贡献之和。最后一步按剩余距离截断；运动没有惯性或机器旋转。地形碰撞通过 swept AABB 求整个运动路径的首次接触点，高速运动不能跳过空洞，对角运动不能切入 void 角。贴边接触允许。

`MovementCommand` 有 `QUEUED`、`RUNNING`、`COMPLETED`、`BLOCKED`、`CANCELLED`、`REJECTED` 状态，并保留实际路程与说明文字。当前入队前的拒绝通过 `DataResult` 返回；`REJECTED` 保留给后续统一命令系统。订阅 `command.finished` 或 `world.command_finished` 可以等待终态。结束回调中新入队的动作要到下一 tick 才会执行。

`stop()` 取消所有未结束动作并发送结束信号；它保留机器当前位置，并允许之后提交新指令。调用者负责停止自己的时间累加器，或创建新的试玩世界。

这里的计算与提交分离为今后的同 tick 攻击结算保留了接入点，尚未包含伤害汇总、效果队列或完整并发调度器。

## UI 接入

启动先显示主菜单，包含开始、地图编辑器、设置和离开。游戏页面流程为主菜单 → 七列纵向滚动关卡列表 → 独立组装页 → 编程页。地图编辑器只从主菜单进入，不再作为关卡列表或工作台的入口。

`MainMenuBackground` 只在主菜单显示项目内的 `assets/backgrounds/main_menu.png`，原图等比居中铺满，使用横向、纵向两次高斯卷积实现约 64 逻辑像素的模糊。四分之一尺寸的离屏视口缓存结果，仅首次显示或窗口尺寸变化时重新渲染；中央菜单卡片保持独立且清晰，其他页面继续使用浅色背景。通过 `set_settings()` 订阅共享背景偏好，纯色模式关闭纹理层，图片切换使缓存失效；用户图片来自独立管理目录，丢失时回退内置资源。

数据流由 `LevelCatalog → LevelDefinition → AssemblyModel + 程序源文本 → GameSession` 组织。关卡选择页从目录取得卡片数据；末尾的“+”引导用户把地图 JSON 放入 `user://levels`，随后刷新列表。`LevelCatalog.ensure_import_directory()` 只创建并返回目录，打开系统文件夹是 UI 职责。

内置关卡来自 `res://data/levels`，当前包含第一至第十五关，共 15 关；排序使用真实 `order`，第十关使用真实复习地图。自定义关卡来自 `user://levels`。单个损坏文件或重复 ID 会加入 `catalog.errors`，但有效关卡仍保留在 `catalog.levels`；界面不能因 `refresh()` 的结果含错误就隐藏全部关卡。内置项保持优先，分别按 `order` 与源路径稳定排序。

`AssemblyModel.create()` 始终建立空模块清单，`GameSession.create()` 继承这一语义。地图 `player_spawn.modules` 仍保留为底层格式和缺省关卡规则的来源；正常关卡与编辑器测试都不会自动复制它。正常关卡上次草稿中的源程序可以自动恢复，装配只能在玩家点击“载入上次装配”后显式恢复，并通过 `validate_editing()` 检查当前关卡的编辑约束。缺中心或断连的草稿仍可恢复修复，不能因此被当成损坏数据丢弃。

组装页左侧加号展开玻璃目录，列出 `ContentRegistry.modules` 中的全部模块；不在本关 `allowed_modules` 中的项禁用，数量达到 `module_limit` 后禁用新增。已有模块仍可按装配规则修改。界面禁用只是即时反馈，模型始终再次校验，避免程序调用或同步信号回调绕过规则。

`AssemblyModuleDrawer` 用独立玻璃画布层覆盖图纸，以加号圆钮为固定左上角向右下展开，不改变底层布局；面板保持可用高度，简介开关只影响标签可见性，外侧关闭点击与释放配对吞掉。`AssemblyPanel` 接受 Shell / Workbench 注入的共享 `GameSettings`，订阅偏好变化并仅更新 `AssemblyCanvas.free_zoom_enabled` 与操作提示，退出时断开订阅。默认关闭时固定显示完整横向 SVG 纸张与白框，忽略滚轮和右键查看、不使用柔边；开启时统一以视点和等比缩放转换纸张、模块、命中及拖动坐标，滚轮与右键仅操作视图。关闭开关会结束查看手势并把纸张围绕当前装配原点完整呈现，模块编辑仍提交给模型，视图切换不写草稿。图纸接近视口裁切边缘时，将纸张、中心十字、模块、选中框和拖动预览放入内部 AlphaCanvasGroup 合成，再以本地坐标统一缩减 alpha，避免各绘图层分别淡出后在重叠处叠浓。顶部采用与设置页相同的 48 像素 smoothstep，上角以乘积保持纵向曲线连续；左右、底部保留原有 64 像素连续透明度曲线。过渡宽度不随缩放变化，无模糊或白色覆盖；正常完整显示保留 SVG 白框和蓝边，遮罩不改变命中区域。固定模式仍直接绘制，不启用合成层。Del/Backspace 删除仅由画布焦点接收；页签隐藏或退出会取消拖动、恢复光标并关闭侧栏。装配规则指引单独启用 `WorkbenchGuideMenu.expand_from_top_right`，从问号原位置向左下展开，展开时隐藏原圆底，收回后恢复；其他页面指引继续使用默认下拉样式。

`AssemblyModel` 通过候选快照校验再提交修改。`add_module()`、`move_module()`、`remove_module()`、`rename_module()` 成功时发出 `changed`，失败时保留原布局。装配采用 `0.5` 格网格，中心偏移限制在 `-4..4`；模块名使用 DSL 可识别的英文字母、数字和下划线，不能以数字开头，也不能使用语言保留词。关卡的 `module_limit`、`allowed_modules`、模块重叠与重复名称都由模型检查。

空装配首件可在图纸内任意半格落点放置。`AssemblyCanvas` 将该次请求转换为逻辑 `(0,0)`，仅在同步放置成功后提交视觉原点；失败保留原视图。后续模块、命中及拖动统一相对该原点换算，缩放与平移继续独立作用于视图；自由缩放模式下，原点靠近原纸边时扩展 SVG 网格纸面，以容纳完整装配范围。固定模式保持纸面尺寸和首次点击格点不动，只接受可见纸内的放置；重新居中视图或关闭自由查看时按当前原点恢复完整纸面。删除全部模块后下次成功放置可重新选点；视觉原点不写入装配草稿或关卡出生位置。模型首件中心偏移仍严格为 `(0,0)`，单模块不能移离此装配原点。后续新增或移动的目标矩形必须与任意已有模块共用一段正长度的边；允许分支，角点和间隙不算连接。连接关系依据模块实际尺寸计算，不以中心距离或网格邻接替代。

编辑和运行使用不同校验入口：`validate_editing()` 只检查结构、网格、类型、数量、命名与重叠，允许空装配、缺中心和断连。删除中心或桥接模块后可保留并保存草稿。`validate()` 在编辑校验之外要求非空、中心模块及整体沿边连通；`build_document()` 再把布局应用到地图副本，通过 `SimulationWorld.create()` 校验实际出生占地。确认按钮使用最终构造结果决定是否可用，并在悬停提示中展示失败原因；运行入口也必须调用最终校验，不能把编辑校验当作通行证。

编程页的“编辑模块”按钮通过 `GameWorkbench.edit_modules_requested` 请求 `GameShell._return_to_assembly()`。此路径同步最新源文本、停止试运行，并复用当前 `GameSession` 和装配模型返回组装；不会调用 `_enter_level()`、清空模块或从磁盘重新载入旧作品。确认装配后仍回到同一会话的编程页，语法错误不会阻止返回组装。

`GameSession.run()` 使用当前程序和装配建立全新世界及解释器。`step()` 推进一步逻辑 tick；`pause()` / `resume()` 保留当前执行状态；`stop()` / `reset()` 返回编辑流程并取消执行。重置保留玩家程序和装配。`changed` 用于刷新状态，`completed` 通知上层完成结果；只有正常关卡入口据此持久化通关记录，编辑器测试不落盘。

`reset_code()` 是独立的显式操作：取消旧解释器、清空世界与错误行、将 source 恢复为当前 LevelDefinition.starter_program，保留装配。工作台用一次原生 CodeEdit 复合编辑同步文本，支持一次撤销恢复玩家原稿，再通过既有 draft_changed 通知保存；仍由 Shell 隔离编辑器试玩和正式存档。它不调用完成事件，不更改地图定义或其他关卡。

有终点的关卡在机器参考点到达或经过终点半径范围时成功，程序结束但未抵达终点则失败。移动受到 void 阻挡会传播为程序失败。没有 `properties.level.goal` 的导入地图作为沙盒使用，程序正常结束时不要求终点。终点检测只读世界位置，不改变底层移动或地形规则。

`GameDraftStore` 默认写入 `user://solutions`。草稿与通关记录分开保存，以关卡 ID 的 SHA-256 构造文件名；关卡 ID 不作为路径拼接。保存程序不会清除已有完成状态。可通过 `directory` 注入独占测试目录，缺失草稿返回成功且 `value = null`。

设置页的「清除预设进度」由 `ClearProgressDialog` 负责确认外观与输入，`GameShell` 收集来源位于 `res://data/levels/` 的内置关卡 ID，只有弹窗明确确认才调用 `GameDraftStore.clear_level_records()`。存储接口按 ID 定位对应通关记录、代码/装配草稿及已知恢复副本；清除前校验完整候选集，先暂存、失败时回滚，不递归删除整个 solutions 目录。导入关卡、设置及关卡地图不属于此操作范围。

「清除用户关卡」复用确认组件但切换独立正文；Shell 保存操作类型与目录快照，确认时调用 `LevelCatalog.clear_user_levels(drafts)`，完成后重新扫描目录。目录只接受正式 `user://levels` 或隔离测试位置，逐段拒绝符号链接；枚举直接 JSON（包含坏文件和重复 ID），非 JSON 和子目录保留。关联记录仅按文件合法顶层 ID 或本会话同路径已加载定义识别，并独立读取全部内置 ID 加以排除。内置保护范围不能确定时终止操作。

用户地图整体暂存后才清关联记录；暂存或记录失败时恢复地图，最终删除失败时恢复尚未删除的地图并报告部分完成情况，不误报成功。所有取消与页面切换撤销待处理请求，确认仅消费一次；设置面板只显示结果，不直接接触文件。测试使用独占目录并覆盖取消、范围隔离、符号链接和磁盘失败恢复。

`GameShell` 在草稿损坏或装配不兼容时回退到初始内容，同时记录恢复状态。未编辑直接返回不会写回默认内容；首次编辑或手动保存前，先通过 `backup_draft()` 逐字节保留旧文件。备份失败则停止保存，成功路径显示在保存状态提示中。该备份与普通写盘事务中的临时备份不同，会持续保留供恢复使用。

`GameSettings` 默认读写 `user://settings.json`，可注入独立测试路径。`set_volume()` 接受线性 `0..1` 数值，应用到 Master 总线，零值单独静音；`set_language()` 接受 `zh_CN` 或 `en`，通过翻译服务即时更新语言。`set_tab_completion()` 和 `set_assembly_free_zoom()` 接受布尔值，后者独立保存到 `interface.assembly_free_zoom`，缺省为 false；`set_code_hints()` 接受 `none`、`normal` 或 `more`。这些入口立即应用有效值并尝试保存，使用 `DataResult` 和 `last_error` 报告写盘失败。缺失配置使用默认设置，旧文件缺少新字段时 Tab 补全默认开启、装配图自由缩放默认关闭、代码提示默认一般；损坏配置不会部分载入字段。

`GameSettings.window_resolution` 以 `interface.window_resolution` 保存稳定字符串：六档16:10窗口尺寸及 `maximized`，默认 `1280x800`。旧配置缺省兼容，非法值参与整体原子校验，未知字段保留。`GameWindowController` 是 Shell 的 UI 子节点，负责恢复物理窗口、禁止边缘自由缩放、切换最大化、筛选当前屏幕可用项，并向设置面板注入可用列表；数据与模拟层不依赖系统窗口。项目和运行时均采用 1280×800 基准的 canvas_items / expand：保持等比缩放，将多余空间纳入逻辑视口，避免黑边。macOS 必须先临时解锁再提交最大化，随后恢复锁定；递增代数防止旧回调覆盖快速改选。控制器缓存已应用值，音量、语言等变化不重新居中或恢复最小化窗口。正常窗口装饰尺寸独立缓存；显示器变化时更新选项并修正越界位置。不合新屏幕的尺寸仅在内存回退，启动不自动重写旧配置；下一次用户保存偏好时写入有效选择。

`GameI18n` 使用中文源串作为稳定翻译键，注册简体中文与英文资源；`SettingsPanel` 只绑定注入的设置模型。静态控件通过 Godot 翻译通知更新，带数值的动态文本在通知时重新格式化。自定义关卡的文本保留作者原文，程序源代码不因切换界面语言而改写。

原生 TextEdit / CodeEdit 文本菜单使用英文源串，`NATIVE_MENU_CHINESE` 为这些项及书写方向、控制字符子菜单提供简体中文映射。程序编辑区继续禁用自动翻译；工作台仅通过 `localize_text_edit_menu()` 为内部 PopupMenu 显式启用翻译，使其不继承编辑区的禁用设置。菜单仍由 Godot 构造、重建并处理命令、快捷键和只读状态，不维护第二套菜单行为。

## 地图编辑器与测试接入

`MapEditorHeader` 只发出操作信号，左侧复用 `GameTheme.navigation_pill()`，外层 24 像素边距与其他页头一致。`MapEditorActionsMenu` 在独立画布层展示三项玻璃下拉菜单，关闭时处理 Esc、焦点与外部点击。文档保存、校验、元数据编辑、撤销重做仍接回 `MapEditor` 原入口；路径按钮及 Ctrl/Cmd+O 调用同一未保存检查。编辑器隐藏时主动关闭菜单，防止其画布层进入试玩页面。

编辑器返回开始页时，`MapExitDialog` 用同视口背景采样呈现一体圆角毛玻璃确认卡片，SVG 警告图标与正文独立清晰绘制。卡片及内部图标、文字、间距按原布局的 70% 整体呈现，普通名称下约 266×286 像素；保留默认取消焦点，蓝色焦点提示仅在 Tab／方向键导航时显示，鼠标操作后隐藏。正文使用刚提交的地图名称，长名称自动换行，极长内容在正文内滚动；地图名称本身不参与翻译。「保存 / 不保存 / 取消」纵向排列，Esc 等同取消，外部点击和背景快捷键不能穿透。`GameShell` 只在本次退出保存请求收到 `MapEditor.save_finished(true)` 且文档已保存时返回开始页；首次保存沿用系统文件选择。写盘失败或取消文件选择清除退出意图并保留编辑器，之后普通保存不会意外退出。「不保存」明确放弃当前编辑并返回，「取消」保留文档与历史。新建、打开地图和操作系统关闭窗口仍沿用各自原有未保存保护。

`MapEditorViewport` 保存独立的显示比例和地图坐标观察中心，裁剪并定位原 `MapCanvas`；点击换算仍以画布实际 `cell_size` 为准。初次打开和地图尺寸变化时居中适配，普通内容变化保留视点；缩放或滚动前结束当前笔画，不写地图或历史。指引复用 `WorkbenchGuideMenu`，原状态标签保留为其子项，地图页脚不再占据画幅。

`MapCanvas` 在显式地块之前绘制浅蓝灰石纹底面，运行地图和编辑器共用此路径。`assets/tiles/void_stone.png` 仅是显示资源，不注册为地块；缺失地块仍为不可通行的 void。四顶点纹理面以地图坐标连续映射，每 8 格镜像重复，独立 CanvasTexture 启用 mipmap 滤波；资源导入生成 mipmap。重绘纹理的均色校正与 45% 混合保留原 `GameTheme.VOID` 色调，显式地块的不透明底色遮住纹理，网格、实体、输入及碰撞继续使用原实现。

原生 `floor.svg` 地板在圆角描边内叠加按用户参考图重绘的 `assets/tiles/floor_scratched.png`，渲染时提亮并以 24% 混合，降低通行路面划痕对比度。两套重绘纹理均为 1254 × 1254，沿地图坐标每 8 格镜像重复，每格约 157 个纹理像素，覆盖编辑器最高 4 倍缩放下的 128 逻辑像素格子；缩小时仍使用 mipmap。地板 SVG 从矢量源以 4 倍分辨率绘制并缓存，导入资源也设为相同倍率，避免圆角边框放大后发软。圆角描边以 75% 不透明度绘制，格缝底色相对亮底的色差也降至原来的约 75%，使通行格子的边界更柔和。匹配原生纹理路径只用于选择画法，不改变地块通行判定，也不覆盖其他自定义图片。圆角内侧几何复用原 SVG 尺寸，绘制结束恢复变换，后续网格、物件和机器继续按原坐标显示。

`MapEditorCanvas` 继承通用 `MapCanvas`，在编辑器中增加框选捕获、点位工具和敌人放置预览；运行中的地图仍使用原画布。松开时只发出一次 `rectangle_requested`，由 `MapEditorDocument.paint_rectangle()` 裁剪边界、批量修改地块并提交一个撤销事务。预览不修改文档；缩放、滚动、切换工具、失焦或 Esc 取消预览。起点和终点使用独立的 `POINT` 单击模式，与画笔和框选互斥；按住移动不重复放置，右键或 Esc 返回之前的地形工具。绿色终点标记只读取现有 `properties.level.goal`。

`MapEditorEnemyPanel` 管理敌人开关、数量与耐久输入及模块组合，配置通过 `MapEditorDocument` 的事务接口提交。`properties.level.enemies_enabled` 显式关闭时保留文档敌人，但 `SimulationWorld` 不生成其实例；旧地图缺省启用原有敌人。`properties.editor.enemy_template` 保存 `{module_limit, module_health, module_ids}`，分别接受 1..256 的整数、0.01..1000000 的有限数字及数量不超过上限的非空已注册模块列表。表单、地图校验和放置入口共享验证，模板更新不修改已放置敌人的独立快照。 模块药丸使用 `EnemyModuleChoice` 保存原始 ID 与本土化名称，共享 `EnemyModulePicker` 的同视口玻璃菜单；中文六项菜单为 142×270，SVG 图标统一为 32 像素，英文按文字需要适当扩宽。玻璃先复制背后画面再采样，菜单内文字和图标不参与模糊。菜单支持键盘选择、视口边界定位和内部滚动；外部关闭点击按下与抬起均吞掉，禁用、隐藏、折叠或切换语言时关闭，不改变地图模板。

`MapEditorEnemyTemplate` 是预览与提交共用的纯数据构造器，按所选顺序和真实宽度将模块横向共边排列，首件偏移为零；`build_entry()` 生成标准敌人条目和逐模块耐久覆盖，`validate_placement()` 检查半格落点及所有真实模块矩形的地形、边界与实体重叠。组合加号选择 `ENEMY` 模式，画布以半透明 SVG 显示合法或红色非法预览，左键按下只发出一次位置请求，由 `place_enemy()` 校验并一次性记录撤销。右键或 Esc 返回地形工具；视图变化、隐藏及失焦只清理预览。`MapCanvas` 继续从文档读取已放置敌人，不在编辑器中推进战斗。

新敌人引用已注册行为 `auto_chase_attack`。`SimulationWorld` 创建 `EditorEnemyController`，在统一固定 tick 中依据实际存活模块提交普通移动、近战和射击动作，继续使用现有碰撞、射程、冷却及损伤规则。模块损坏只使对应能力失效；敌人 JSON 不包含可执行程序，也不能赋予未安装的模块能力。开关、模板及放置均随地图保存并支持撤销重做，未知扩展字段继续保留。

场景尺寸表单仅接受 `1..64` 整数，键入/粘贴和应用入口分别校验；输入时只更新控件，点击应用才修改文档。旧地图格式的 `1..256` 上限保持兼容，加载超过 64 的旧尺寸不自动裁剪。

终点为可选项。`place_goal()` 通过编辑事务写入现有的 `reach_position` 目标；重新定位现有逃脱终点时保留目标类型、条件、半径及扩展字段。`clear_goal()` 只移除坐标目标，不删除战斗目标。没有目标也能保存、校验及测试；旧自由模式在程序正常结束时回到编辑状态，新限时模式继续倒计时至完成目标或超时。

分类折叠只设置内容容器的 `visible`，不重建控件或修改地图；默认展开，同一编辑器实例在试玩往返中保留状态。「场景编辑」折叠宽高、画笔样式及绘制项目；「场景玩法与行为控制」折叠起终点、重置按钮、限时及并排的玩家模块数量和耐久上限。起终点和限时标签共用字体、字号与字重。

秒表输入使用 `LineEdit`，没有调节箭头。编辑器默认显示 60 秒，接受 `(0,3600]` 秒、最多一位小数；空白不能提交，键入/粘贴和模型入口都验证。`MapEditorDocument.set_time_limit_seconds()` 将秒数转换为既有 `max_ticks`（10 Hz），并写入显式 `completion_mode: "reach_or_clear"`，一次修改对应一个撤销事务。相同值重复提交不修改 JSON 数值类型或 dirty 状态。新地图直接保存 600 tick 的默认值；旧无时限地图在编辑器中显示 60 秒，保存时写入正时限；校验/测试仅在独立快照中补上有效时限，不因默认值改变原地图或历史。直接游玩旧地图的缺省规则保持兼容。

`LevelDefinition.completion_mode` 缺省 `goal`，保留全部现有教学规则。显式 `reach_or_clear` 要求正限时，GameSession 以真实运动路径到达坐标目标，或已注册的全部敌人整机被毁为胜利；两个条件取或，零敌人不能触发清场胜利，待生波次仍计入未清除敌人。世界失败优先，截止 tick 的成功优先于超时。该模式下主程序提前完成仍以同一 `world.step()` 推进战斗、弹丸和计时，不能冻结倒计时；暂停和重置复用原会话。UI 药丸只读取剩余 tick 和剩余敌人数，不维护独立计时器。旧地图仍允许 `max_ticks: 0`，但不能与新的限时模式组合。

`properties.level.player_max_health` 是可选的玩家每模块耐久覆盖，接受大于0且不超过1000000000的有限数字。`MapValidation` 在无出生点草稿阶段也验证它；`LevelDefinition` 使用内部0表示未覆盖。`SimulationWorld.create()` 在创建真实玩家装配后设置各玩家实例的 `health/max_health`，不会修改敌人或共享模块定义；重试创建新世界恢复该值。未设置的旧地图继承原模块定义，编辑表单仅默认显示1，不因打开地图自动添加覆盖。`MapEditorDocument` 的 getter/setter 提供事务保存及整数/浮点等值无操作，表单在回车、失焦、保存或试玩时提交有效值。

地图编辑器继续使用独立的 `MapEditorDocument`：

- `replace_document()` 建立载入状态及保存点。
- `begin_action()` / `end_action()` 把一次笔划合并为一次撤销操作，事务允许嵌套。
- `paint()`、`resize()`、`place_spawn()`、`clear_spawn()`、`place_goal()`、`clear_goal()`、`set_identity()` 修改对应内容。
- `get_module_limit()` 读取有效上限，未显式配置时按出生模板数量回退，至少为 1。`set_module_limit(limit)` 返回 `DataResult`，只接受 `1..256` 整数，并作为编辑事务写入 `properties.level.module_limit`；保留其他关卡属性并参与撤销、重做及保存点判断。
- `set_enemies_enabled()`、`set_enemy_template()` 和 `place_enemy()` 分别保存敌人运行开关、未来放置模板及完整敌人快照；无效输入或落点返回 `DataResult` 失败，不修改文档和历史。
- `metadata_dict()` 提供扩展元数据副本；调用方验证后通过 `apply_metadata()` 应用。
- `changed` 用于重绘和更新状态；`undo()` / `redo()` 恢复文档快照。
- 文件成功写入后才调用 `mark_saved()`；`is_dirty()` 通过内容签名判断，撤销回保存点会恢复未修改状态。

缩小地图会裁剪越界地块，并清除中心点已越界的出生点与坐标终点，裁剪仍为同一个撤销事务。「校验」与「开始测试」检查地图及 `LevelDefinition`，包括出生配置格式、规则引用和终点区域；实际玩家模块的中心、连通和完整出生占地留到确认装配时，由 `AssemblyModel.build_document()` 检查。出生模板的地形占地不能代替尚未完成的玩家装配检查。

`MapEditor.playtest_requested(definition: LevelDefinition, content: ContentRegistry)` 发出由当前文档创建的关卡快照与编辑器注册表。地图可以尚未保存，不经过 `LevelCatalog` 或文件重载；数量上限、允许模块与其他关卡规则取当前快照。编辑器不持有试玩世界，不直接执行 `move`，也不累计模拟时间。

`GameShell` 保留原编辑器实例并切换到新测试会话的空装配页，确认后复用 `GameWorkbench` 的程序编辑和运行界面。组装与编程之间切换、停止或重置位置都沿用本次会话。返回地图编辑器时结束会话并恢复原节点，因此同一个文档、路径、未保存标记和撤销/重做历史完整保留；再次开始测试会建立新会话。

测试会话不载入或保存 `GameDraftStore`，隐藏“保存草稿”和“载入上次装配”，自动保存与通关回调也不能写盘。Shell 为工作台设置 `allow_draft_save = false` 隐藏保存入口，并在存储回调中独立检查测试状态，不能只依赖按钮隐藏。程序、装配与完成状态仅存在于本次测试内，地图 ID 与正式关卡相同时仍不影响真实草稿或完成记录。正常关卡入口的存储流程保持不变。

独立场景 `scenes/map_editor.tscn` 以 `GameShell` 为入口并设置 `start_in_editor = true`。Shell 直接构造 `MapEditor`，不通过再次实例化该场景创建编辑器，避免递归包装。主菜单与独立场景共用相同的测试流程。

内置关卡为 `data/levels/level_001.json` 至 `level_003.json`；`data/maps/movement_lab.json` 保持编辑器样例用途。本轮不迁移或合并地图与关卡目录。

画布应只负责显示与坐标换算；玩法必须调用模拟层。真正开始执行后，由 `GameWorkbench` 累计真实时间，每累积 `SimulationWorld.TICK_DURATION` 调用一次 `GameSession.step()`。表现动画可以独立插值，不改变逻辑位置。

## 当前语言与扩展边界

当前实现专用语言子集，没有使用 `eval`，不执行用户 GDScript。词法分析、语法分析、AST 与执行器位于 `scripts/language/`，解释器通过世界公开命令接口执行移动，不持有 UI 节点。

```text
main() {
    // 每条指令单独一行，按顺序等待移动完成。
    move(0, 4)
    move(90, 2)
}
```

源程序需要唯一 `main()` 入口。当前支持 `move(角度, 距离)`、第三关解锁的 `attack(角度)`、正负整数或小数、空行、`//` 注释及 Windows 换行。数字可以写 `.5` 或 `1.`，参数括号内可以换行；相邻调用之间必须换行，不接受分号。语法或运行错误保留行号，供程序编辑面板定位。源程序最多 `64 KiB`、`4096` 个 token、`512` 条调用，以有限输入上限控制编译工作量。

顺序执行器等待当前动作结束后才提交下一条；阻挡立即失败，取消后不再执行剩余语句。再次运行从新的世界与执行器开始。装配可以命名模块，但当前语言尚未提供 `drive.move()` 这种命名模块调用。

变量、表达式、条件、自定义函数、`loop {}`、`simultaneously {}`、事件与战斗能力仍待后续实现。新增功能应扩展明确的 AST 节点和调度语义，不能把并发块伪装成普通函数调用。完整设计约束见 `docs/DESIGN_CONSTRAINTS.md`，内容扩展见仓库根目录 `MODDING.md`。

## 验证

优先运行 `tools/test.ps1`；包装脚本会把 Godot 的脚本异常和编译失败也视为失败，并包含编辑器场景集成检查。引擎已在 PATH 中时使用：

```powershell
.\tools\test.ps1 -GodotPath godot
```

也可以将 `-GodotPath` 替换为本机 Godot 可执行文件的完整路径。底层入口是：

```powershell
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/headless_runner.gd
```

首次导入用于生成全局脚本类与资源缓存。直接调用引擎时，除检查退出码与回归汇总，还必须确认日志中没有一般引擎 `ERROR`、`SCRIPT ERROR` 或解析失败；GDScript 异常可能中断单个用例而不令引擎自动返回失败。

测试覆盖合法与非法 JSON、资源与 ID 校验、保存失败保护、未知数据往返、编辑撤销重做、编辑后再载入、固定 tick、速度叠加、准确距离、命令取消，以及完整占地、地图边界、高速空洞和对角碰撞。临时文件只写入本次独占的 `user://tests/programmable_module_*` 目录，并在正常结束后清理。

游戏层另有 `tests/gameplay_runner.gd`，使用独占的 `user://tests/gameplay_*` 目录，覆盖首关完整路线、关卡导入隔离、装配约束、草稿往返与通关状态，以及程序会话的成功、失败、暂停和重置。实际验证日期和结果记录在 `docs/VALIDATION.md`。

## 2026-09-11：显示层更新

GameTheme 集中维护字体、圆角、颜色和交互状态；GameShell、GameWorkbench、AssemblyPanel、SettingsPanel 与 MapEditor 的界面复用既有回调。MapCanvas / AssemblyCanvas / PlayfieldCanvas 仅更改绘制。数据、模块行为、模拟、语言、装配模型、游戏会话、草稿和设置模型保持原文件内容。关卡仅增加和修改现有格式的 JSON，未扩展 Schema。


## 闸门与近战扩展

- `MapObjectDefinition` 验证已实现的对象类型，`WorldObject` 保存每次运行的独立耐久；未知扩展不执行。
- `SimulationCommand` 提供统一状态与完成信号。`MovementCommand` 保留旧接口，`AttackCommand` 增加命中数量。
- `SimulationWorld` 使用独占的机器动作通道；tick 开始按当前时间判定闸门、计算所有移动/攻击提案，之后统一提交位置/伤害，最后通知。回调提交的新动作只在下一 tick 执行。
- `MeleeModule` 通过基类能力接口提供射程和伤害，JSON 不加载任意脚本。`ProgramParser` 仍创建显式 CallNode，`ProgramRunner` 顺序等待命令终态。
- `LevelDefinition.goal_type` 区分 `reach_position` 和 `destroy_object`，禁止只凭 `has_goal` 推断存在终点坐标。旧省略 type 的目标按 reach_position 读取。
- UI 只投影闸门剩余 tick、对象耐久和攻击轨迹。所有编辑器测试仍走正式组装与会话，不增加独立执行器。

详细约定见 [GATE_AND_MELEE.md](GATE_AND_MELEE.md)。

## 第四关扩展

当前内置四关。`LevelDefinition` 新增 `allow_tick`（默认 false）、`max_ticks`（默认 0，不限时）和 `destroy_enemy` 目标；射击调用按允许的模块行为解锁。第四关上限 1、敌人初始位于右侧 6 格，向左移动 4.5 格后近战攻击。

`GameSession` 在战斗主程序结束后继续推进世界；玩家死亡优先于同 tick 敌人全毁的胜利，超时失败，暂停/重试语义不变。`MapCanvas` 只显示敌方模块耐久和子弹；`LevelThumbnail` 从地图敌人数据生成选关 SVG。

语法、敌人 JSON、伤害与冷却细节见 [SHOOTING_AND_ENEMIES.md](SHOOTING_AND_ENEMIES.md)。


## 第五关扩展

`allow_named_calls` 默认 false；第五关显式开启。Lexer 保留小数词法，Parser 使用显式 `CallNode.receiver`，Runner 在提交任何动作前检查所有实例名与能力。世界接口可选 `module_id`，空值保持广播，非空精确筛选能力来源；命名不改变真实模块占地或各实例冷却。

`alarm_guard` 等待警报，`prison_alarm` 在同 tick 全部伤害提交后检查绑定警卫；警卫仍活则立即处决全部玩家模块。`security_gate` 仅在引用的全部已注册敌人和可破坏对象被清除后解锁。`escape_prison` 还要求玩家沿实际路径到达出口；失败先于胜利。

UI 从世界读取 `triggered` / `unlocked` 状态，SVG 和地图缩略图只呈现，不自行控制规则。新增字段兼容 `format_version: 1`；坏引用拒绝，未知扩展仍保留。前四关 JSON、草稿数据及编辑器测试隔离约定不变。


## 第六关扩展

`properties.level.allow_loops` 可选且默认 false，第六关显式开启，前五关 JSON 保持不变。Parser 使用显式 LoopNode，Runner 使用有界执行帧维护 main 的循环位置，不展开源码、不按关卡编号硬编码十次。每个 step 仍只推进至多一个模拟 tick；循环边界本身不消耗世界时间。

循环仅能出现在 main 中，tick 回调仍为有限的 attack/shoot 短动作。整树预检、层级/节点数量限制和空块拒绝避免语法树或结构遍历卡死；零距离移动也保持每次一个 tick。到达目标后由 GameSession 取消解释器，暂停/重试和草稿隔离约定延续。

33×23 阶梯地图采用现有 floor SVG、位置目标与一模块装配，不增加新的模拟对象类型。观察区允许缩小至每格8像素以完整显示本关；小网格的机器人圆环只属于显示，不改变真实占地。详见 [循环与阶梯](LOOPS_AND_STAIRCASE.md)。


## 2026-09-14：行内 Tab 补全

`ProgramCompletion` 只根据光标前的 DSL 词法上下文、`LevelDefinition` 解锁标志与 `AssemblyModel` 实例能力产生标识符后缀，不参与解析执行或修改关卡权限。`ProgramInlineCompletion` 在现有 `CodeEdit` 内使用同一字体与光标基线绘制浅灰建议，只有普通 Tab 接受时通过一次原生编辑操作写入。没有候选时保留缩进；选区、多光标、IME、只读、失焦与不可见光标不接受建议。工作台通过 Shell 注入 `GameSettings`，偏好保存在 `interface.tab_completion`；旧格式缺字段默认开启，仍保持格式版本 1 和未知配置字段。

## 第十一关的分层接入

`LevelDefinition` 提供默认 false、相互独立的 `allow_functions`、`allow_variables` 与 `allow_radar`，以及 `dodge_attacks` 目标的 `goal_attack_count`。第十一关同时显式开启三个权限，并将 radar 加入允许模块；常变量与玩家雷达直接可用，第十关也以相同独立权限开放玩家扫描和可选常变量。Parser、显式 AST 与 Runner 共同维护用户函数调用；有限深度的执行帧等待真实动作完成后返回，不展开源码，也不把函数变成宿主脚本。具体限制见 [函数复用](FUNCTIONS.md)。

`RadarModule` 只提供真实部件能力；`SimulationWorld.radar_detects_player()` 按部件范围与地块 `radar_block` 查询。`RadarLungeController` 在一次扫描后固定目标位置，经普通移动命令抵达准备点和攻击点，再提交普通近战命令；每轮实际攻击提交后才更新尝试与闪避次数。`get_enemy_attack_status()` 返回状态副本，`GameSession` 判断失败和五次闪避完成，UI 只读取同一状态显示药丸和指引。敌人能力失效、动作取消或移动受阻不能凭空得分。见 [闪避教学](FUNCTIONS_AND_DODGING.md)。

## 常变量与逐步提示的职责

常变量由显式声明、赋值及名称表达式 AST 表示。`ProgramVariableValidation` 检查全局和局部词法作用域；Runner 按源码顺序初始化全局绑定，main 与各次函数调用使用独立局部，if / loop 子块独立遮蔽。tick / simultaneously 只读已有绑定，不声明或赋值。变量、函数、条件、测距、雷达和随机函数权限由 Parser 分别校验；绑定可保存有限数字、扫描快照、世界位置向量或 null，动作参数与加减仍要求有限数字，详见 [常量与变量](VARIABLES.md)。`ProgramCompletion` 复用词法及权限，只有当前位置可见的绑定才成为候选；高亮与指令 JSON 不会改写源码或提高权限。

设置将代码提示档位独立保存到 `interface.code_hints`：无 / 一般 / 多对应 none / normal / more，默认一般。工作台只给正式教学关卡显示入口，一般要求该关连续失败三次，多立即显示，无隐藏。`GameSession` 每次真实失败只计一次并发出 `attempt_failed`，成功清零；停止和重置不计失败。`GameShell` 在进入教学关卡时恢复计数，并通过 `GameDraftStore` 把它保存在该关 progress 的 `failure_streak` 中，因此跨会话和重启继续有效。

`CodeHintService` 先核对教学来源与地图快照，再在独立会话验证实际装配和参考方案，只返回一次修改。工作台将提示写成单次 CodeEdit 撤销事务并记录版本；相邻 SVG 撤销按钮仅在最新提示仍处于历史顶部时可用，不跨过手工编辑、不覆盖旧快照。提示验证不变更原会话或失败计数，导入关卡和编辑器测试没有入口。见 [代码提示](CODE_HINTS.md)。


## 玩家雷达查询

`SimulationWorld.validate_radar_source()` 按实际模块名称与能力做只读预检，`query_scan()` 使用该雷达的世界中心，读取最近可见敌机的参考点；同距离按机器 ID 选择，返回独立 `{enemy_id, position, angle, distance}` 字典或 null。扫描范围取 `RadarModule` 配置，玩家扫描与敌方 `radar_detects_player()` 共用 `radar_block` 线段遮挡，不改动敌人锁定、冷却或任何动作。世界不向语言公开机器实例。

Parser 通过 `ScanNode`、`NullNode` 和 `TargetMemberNode` 表示扫描、空目标与固定只读属性；Runner 验证快照字段和有限值，再读取 `Angle()`、`Position`、`Distance` 与坐标 x/y。属性不经宿主反射或任意方法调用，旧快照不自动追踪世界。变量作用域存储快照副本；数值动作、算术和排序比较继续严格校验类型。详情与测试入口见 [玩家雷达](PLAYER_RADAR.md)。

## 玩家随机表达式

`LevelDefinition.allow_random` 从 `properties.level` 读取，缺省 false，第十、十一关分别显式开启；它不依赖关卡序号推断、已通关记录或实际装配。`GameSession` 把当前关卡的 `allow_random` 传给 Parser，由 Parser 校验玩家源码的解锁权限；Runner 与现有内置表达式保持一致，不读取关卡权限，而是验证传入 AST 的结构、名称、类型和数值范围。直接构造 AST 的工具调用方须自行保证使用正确的关卡权限解析源码。随机调用保留为显式表达式节点，静态检查、变量名称校验、补全和指令集合只读取语法与权限，不能通过试求值消耗随机数。

每个 `ProgramRunner` 持有私有 `RandomNumberGenerator`，实际执行表达式时才取值。`random()` 使用 `randf()` 的 `[0,1]` 语义；`randomInt(a,b)` 先计算并校验两个有限整数端点，再取包含两端的随机整数。它们只返回数字、不产生模拟命令、不单独推进 tick；动作仍在完整参数求值后交给同一个世界接口。随机源与敌人控制器、Godot 全局随机状态和 UI 隔离；暂停不执行求值，取消后不继续采样，重新运行创建新的 Runner。测试可向 Runner 注入种子，但 DSL、正式关卡 JSON 和玩家存档不暴露此种子。

常量只在声明执行时保存一次采样结果，变量重新赋值可以再次取样；未进入的分支和未调用的函数不采样。开启 `allow_random` 后复用现有数值表达式入口，因此括号、一元正负号与有限加减也可用；条件、绑定、测距、雷达和用户函数仍需各自权限。循环、回调和并行组保持原有结构限制，表达式节点计入原有复杂度预算。范围错误返回带行列的语言错误；没有宿主反射或任意方法调用。详细用法和数值边界见 [随机函数](RANDOM_FUNCTIONS.md)。


## 第十五关的雷达事件

`LevelDefinition.allow_radar_events` 默认 false；第十五关显式开启，前十四关保持关闭。`GameSession` 将它作为 Parser 的独立权限传入，Parser 同时要求 `allow_radar`、`allow_variables` 与 `allow_named_calls`。Lexer 使用连续箭头 `->`，AST 使用 `RadarEventNode` 并保存在 `ProgramNode.radar_events`；事件体只保存真实来源名称和一个此前已声明的全局可变绑定，不含任意语句或用户回调。

启动时先验证全部事件来源与绑定，再按源码顺序初始化全局值，首次刷新后派发 main。每次 `step()` 在 main / tick 读取变量之前调用现有只读 `query_scan()`，即使 main 正在等待移动也更新目标；这一刷新不推进世界、不改变动作和冷却。世界仍每次至多推进一个 0.1 秒 tick。无目标写入 null，来源损毁或失效返回可定位错误；直接写入全局作用域，不受同名局部遮蔽。暂停不刷新，取消后停止，重试创建新世界与绑定。main 已结束时，事件仍随运行中的会话继续更新。

`ProgramCompletion` 仅在合法顶层建议真实雷达名称和 `onDetected`，事件内只建议固定载荷及此前声明的全局 variable；事件目标参与既有快照成员推断。`CommandCatalog` 读取双语事件 JSON，菜单目录与搜索对旧关隐藏该条目；`GameTheme` 为预览与工作台共用深浅高亮。以上辅助均不执行扫描或写入世界，完整边界见 [雷达事件](RADAR_EVENTS.md)。


## 2026-09-22：显示语言地区名称与香港繁体

语言选择器按固定顺序显示「简体中文」「繁體中文」「English」，选项使用各语言自名并禁用自动翻译。设置继续以 `zh_CN`、`en`、`zh_HK` 保存，旧英文代码 `en` 保持兼容，不因地区显示名称迁移配置；切换立即生效，重启恢复。

`GameI18nHK` 保存香港繁体静态词典；`GameI18n.install()` 独立注册简体恒等映射、英语和香港繁体三份 `Translation`。内置指令 JSON 的显示标题、分类和说明增加 `zh_HK`，语法示例与内容 ID 不变。格式化错误缓存源模板，每次按当前语言取得译文，再原样回填玩家标识符；不会转换玩家代码、自定义名称或地图 JSON。早期启动故障使用独立小词典和有限配置读取，避免为提示同步载入完整游戏。


## 2026-09-22：两级设置开放布局与统一背景图库

`SettingsPanel` 与 `CodeColorPanel` 的外层布局使用不绘制背景的 Control，原生 ScrollContainer 和设置分组直接显示在页面底色上。`GameShell` 传入导航药丸作为上边界；`SettingsContentFade` 用 CanvasGroup 合成原有控件，通过 shader 只缩减 alpha，在药丸底边下方 48 像素内渐隐，不模糊文字或叠加白色。弹窗与导航不在合成层内；键盘焦点额外避开渐隐带，鼠标按下时不触发布局滚动。

CanvasGroup 隔开了 Control 的主题继承，因此显式沿父级取得原 Theme，避免字体与圆角回退。Godot 4.5.1 OpenGL Compatibility 的不透明视口采用低 alpha 精度缓冲；共享基类 `AlphaCanvasGroup` 按所属视口引用计数临时启用 `transparent_bg`，使用完整 alpha 精度防止圆角产生暗点；设置页和自由装配共用计数，固定装配模式释放自身请求。页面全屏背景仍完整绘制，不开启操作系统透明窗口；最后一个渐隐层离开后恢复视口原状态。

`MenuBackgroundPicker` 只维护一条 HBox：默认、纯色、自定义添加入口、随后全部用户图片。原生水平 ScrollContainer 的可视宽度保持三个按钮的宽度，溢出即常显横条，原有内置项也一起滚动；导入新图后滚入可见区。重建图库只替换用户项，保留三个固定按钮；没有第二行图库和另行均分四列的尺寸逻辑。模型持久化、模糊预览与删除保护沿用既有接口。


## 2026-09-23：关于游戏与作者链接

`SettingsPanel` 在「更多」分组首行提供 AboutButton，通过 `about_requested` 通知外壳；不访问网络或变更设置。`AboutGameDialog` 使用独立 CanvasLayer 和既有 `menu_glass.gdshader`，不参与设置内容的顶部渐隐。384×608 的竖向卡片使用自动布局，正文可滚动、关闭按钮常驻；支持三语言、窗口缩放、键盘循环焦点、Esc 和点击外部关闭，关闭后恢复原入口焦点。默认或鼠标操作不绘制焦点边框，键盘导航时恢复描边。

联系方式为用户提供的固定公开地址：小涵Naiwenel 的 `https://naiwenel.com/`；YWMKerman 的 Bilibili `https://space.bilibili.com/443343766`、YouTube `https://www.youtube.com/@YWMKerman`、GitHub `https://github.com/YWMKerman`、邮箱 `mailto:YWMKerman@gmail.com`。作者、年份、平台名和地址不参与翻译，界面源串进入三语言词典。

LinkButton 只发 `link_requested`，GameShell 在设置页且弹窗打开时校验地址属于上述固定集合，再调用 `OS.shell_open`；不会在进入关于页时自动打开链接。测试注入 `about_link_opener` 记录地址和模拟失败，不打开真实浏览器或邮件程序。系统打开失败时原弹窗内显示可翻译的提示，切换页面自动关闭关于弹窗，不能与清除数据确认叠开。
