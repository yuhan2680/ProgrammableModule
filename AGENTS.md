# 项目开发约定

- 修改前阅读 README.md、docs/DESIGN_CONSTRAINTS.md 和 docs/ARCHITECTURE.md。
- 保持 Godot 4.5+、GDScript，以及不依赖场景树的底层数据和模拟接口。
- 模块、地块、地图使用 JSON，静态定义与运行时状态分离。JSON 只引用已注册行为，不执行任意脚本。
- 所有函数附中文用途注释；复杂逻辑解释原因与约束。避免万能管理器和不必要抽象。
- 未指定地块和地图外始终为 void，任何机器都不能通过；检查实际模块占地和完整运动路径。
- 当前包含游戏本体、第一至第十五关（共 15 关）、移动/近战/射击/测距/雷达模块、地板、限时闸门和可破坏对象、敌方模块耐久与接近后攻击行为、图形装配、main/move/attack/shoot 及逐关解锁 tick()、模块名调用及 main() 内无限 loop {} 的语言子集与地图编辑器。第五关支持警卫、警报器和条件解锁安全门；规则见 docs/PRISON_AND_NAMED_CALLS.md。第六关为十组右3上2阶梯，循环规则见 docs/LOOPS_AND_STAIRCASE.md。第七关加入 if / else、具名 ready() 与持续推进攻击，规则见 docs/CONDITIONALS_AND_PURSUIT.md；初始程序不预填条件、动作或答案提示。第八关加入显式 simultaneously {}、原子并行动作组和双联动警报，规则见 docs/SIMULTANEOUS_AND_ALARMS.md；旧关卡默认不开放新语法。第九关“蜿蜒穿行”加入测距模块、distance 查询及独立 allow_distance 解锁的有限数值加减和比较；变量仍未开放，规则见 docs/RANGEFINDING.md。第十一关“巧能躲避”通过独立 allow_functions 开放无参函数，敌方雷达锁定后进行真实接近与近战，目标 dodge_attacks 要求躲过 5 次实际攻击；任一玩家模块被该敌人命中立即失败。函数边界见 docs/FUNCTIONS.md，场地与目标见 docs/FUNCTIONS_AND_DODGING.md；第十一关另以 allow_variables: true 继承第十关的 constant/value 常量、variable 变量与赋值，前九关仍关闭，见 docs/VARIABLES.md。按用户最新要求，第十一关另以 allow_radar: true 和 allowed_modules 中的 radar 开放玩家雷达、scan() / 模块名.scan()，以及目标 Angle()、Position.x/y、Distance（兼容 Distance()）；目标快照可存入常变量，无目标用 null/Null 判断，见 docs/PLAYER_RADAR.md。第十关“猎人游戏”已补齐：最多三个模块，允许雷达、移动和射击；随机游走敌人 18 点耐久，120 秒内击毁，常变量可选而非目标门槛。固定可信行为 random_wander 仅提交真实移动，每次重试独立随机；测试种子不得写入正式地图，见 docs/RADAR_PURSUIT.md。只在用户要求的范围内增加关卡和能力。
- 开始页面提供开始游戏、地图编辑器、设置、离开游戏；地图编辑器入口不放在关卡页。每次进入关卡先空装配，玩家确认后才能进入编程；历史装配仅由玩家主动载入。
- 地图编辑器的「开始测试」复用空装配→确认→编程流程；移除直接执行 `move` 的编辑器表单，不增加独立模拟驱动。`MapEditor.playtest_requested` 只传递关卡快照和编辑器注册表，由 `GameShell`、`GameWorkbench`、`GameSession` 处理页面和执行。独立编辑器场景也使用 `GameShell(start_in_editor=true)`，Shell 直接构造 `MapEditor`。
- 测试使用当前未保存地图快照；返回时保留同一编辑器文档、路径、dirty 状态和撤销/重做历史。本次测试内保留程序与装配，返回编辑器结束会话，下次重新空装配；不得读写同 ID 的正式 solutions 或通关记录，隐藏保存草稿和载入上次装配入口。
- 编辑器模块数量上限 `1..256` 写入 `properties.level.module_limit`，走编辑事务并保留其他属性，支持保存与撤销重做。编辑器校验只检查地图和关卡定义，真实装配占地延后到玩家确认装配；不能用出生模板提前替代实际装配。
- `data/maps` 与 `data/levels` 保持现有职责；目录合并或迁移需要用户明确授权，不因讨论方案自动执行。
- 组装目录显示所有已加载模块，地图允许列表和数量上限控制可用性；满上限仍可按装配规则移动、命名或移除已有模块。第一关上限保持 1。
- 空装配首件可在图纸内任意半格落点放置，成功落点成为仅画布持有的视觉原点；模型首件中心偏移仍严格为 `(0,0)`，单模块不能移离该原点。删空后可重新定位，视觉原点不影响存档相对偏移或关卡出生位置。后续新增或移动必须与任意已有模块实际矩形共用正长度的边，允许分支，角点和空隙不算连接。
- `validate_editing()` 仅检查结构、网格、类型、数量、命名与重叠，允许空装配、缺中心或断连，删除中心或桥接模块后的草稿可保存并手动恢复修复。最终 `validate()` 要求非空、中心模块及整体沿边连通，`build_document()` 再检查出生占地；确认禁用时用悬停提示解释原因，运行入口不得绕过最终校验。
- 中心和连通规则只属于游戏装配层，不添加到通用地图格式或 `MachineFactory`；碰撞仍取真实模块矩形的并集，不填充空隙，不增加 Core 实体。
- 设置使用独立 JSON 持久化主音量、简体中文 / 繁體中文 / English 三种显示语言、默认开启的 Tab 补全、默认关闭的装配图自由缩放（`interface.assembly_free_zoom`），以及代码提示 none/normal/more（无/一般/多，默认一般）。代码提示仅正式教学开放：一般在按关持久的连续失败达到三次后显示，多立即显示，无关闭；成功清零，手动停止/重置不计失败。相邻 SVG 撤销按钮只撤最新提示，不能覆盖后续手工编辑。语义与存储边界见 docs/CODE_HINTS.md。UI 文案通过翻译词典处理，玩家代码、名称和地图 JSON 不应被自动翻译。
- 代码区配色独立保存为 `interface.code_color_mode`（light 默认 / dark），设置的「颜色与显示」子页使用真实只读 CodeEdit 预览。深色背景固定 `#121314`，仅代码区改变；换色保留文本、撤销记录、光标、选区、滚动及运行状态。规则见 docs/CODE_COLORS.md。
- 玩家随机函数由独立 `properties.level.allow_random` 解锁，默认 false；第十至第十五关显式开启，前九关保持关闭，不要求模块或常变量。`random()` 返回闭区间 `[0,1]` 数值，`randomInt(a,b)` 返回闭区间整数，要求有限整数端点且下限不大于上限。GameSession 将权限传入 Parser；Runner 负责 AST 结构、类型及范围校验，不读取关卡权限。`allow_random` 复用有限数值表达式入口并支持括号、一元正负号和加减，其他能力仍分别解锁。每个 Runner 持有独立随机源，仅实际求值采样；不得在预检、补全或 UI 中采样，不得与敌人或全局随机源共享。暂停不采样，重试重新初始化；可复现种子仅限测试注入，不加入 DSL 或关卡随机函数配置。完整边界见 docs/RANDOM_FUNCTIONS.md。
- 第十二关“八方来敌”最多两个模块，继承已解锁五种模块；推荐测距加射击、中心驻守。`allow_for` 默认 false，本关显式开启有限 `for (angle in 0..315 step 45)`；`if` 可省略 `else`。`wave_approach_attack` 为已注册可信行为，一次仅激活一台敌人，真实整机被毁后按逻辑 tick 延迟激活下一波；待生敌人不能出现在机器、雷达、测距或弹丸目标中。`destroy_waves` 必须计算尚未出场的波次。不得扩大通用模块或碰撞范围代替八方向命中几何，详见 docs/EIGHT_DIRECTIONS.md。
- 新增语法继续分离 Lexer、Parser、显式 AST 和执行器；运行失败应保留程序与装配，并返回可定位到行列的错误。
- 不擅自恢复 Core、能源、维修系统；不擅自更改 DSL、雷达或抓取设计。
- 更改地图格式需处理版本兼容、保留扩展字段；失败不能覆盖有效地图。
- 修改核心数据、运动或编辑逻辑后运行 tools/test.ps1，同时检查脚本错误。按修改范围补充有意义的回归。
- 用户后续明确提出的新要求优先于以上约定。

- 第十三关“十面埋伏”使用十波随机径向来敌、两个玩家模块及敌方每模块 2.0 耐久。`wave_approach_attack` 可选 `random_spawn` 在独立世界中采样并校验实际占地，不改地图文档、雷达查询或共享模块。`wreck_fade_seconds: 3.0` 仅控制整机残骸的显示，暂停冻结、终局继续淡出、换世界清空。见 docs/AMBUSH.md。

- 第十四关按最新原始 ProgramLevel.md 与用户确认使用三模块、鱼骨式主通道、十波及敌方每模块 2.7 耐久。新增地块 attack_block 缺省继承 collision；铁栅栏阻机器但放行攻击和雷达。可选 activation_region 由同一波次控制器检查实际玩家位置，旧关卡无字段保持原语义；第十四关不开放雷达事件。见 docs/CORRIDOR_SWEEP.md。

- 第十五关“自动索敌”按用户明确确认使用三个模块（原始 ProgramLevel 写两个），沿用第十四关四格主路、栅栏和十波，敌方每模块 2.8 耐久、整机残骸约三秒淡出、限时 240 秒。保持空装配、确认流程与空 `main()`。独立 `allow_radar_events` 默认 false，前十四关关闭；另需 `allow_radar`、`allow_variables`、`allow_named_calls` 和真实可用雷达。只接受顶层 `radar.onDetected { EnemyPosition -> target }`，target 必须是此前声明的全局 variable，不能是常量、局部或后置名称；事件不是任意回调代码块。首次动作前及每个逻辑 tick 开始时刷新 scan 同型快照，无目标写入 null，直接写全局且不受同名局部遮蔽；暂停不刷新、停止后取消、重试重建。补全只填合法标识符后缀，前十四关目录与搜索隐藏事件资料。见 docs/RADAR_EVENTS.md。

- 开始菜单背景可在「颜色与显示」中选择默认内置图、原有纯色或自定义图，图片统一应用约 64 逻辑像素高斯模糊。`interface.menu_background_mode` / `menu_background_id` / `custom_backgrounds` 独立持久化，旧配置缺省 default。自定义图保存为设置目录下的托管 PNG 副本，删除只允许未使用项且不能删除用户原图；背景保存失败回滚，不影响其他偏好。默认、纯色、自定义入口和全部用户图片保持同一排，新增图片只往右追加；整排溢出时横向原生滚动条常显，不套用纵向条自动淡出。详见 docs/CODE_COLORS.md。

- 设置主页面与「颜色与显示」子页不绘制外层白色卡片；原生设置分组直接显示在浅色背景上。内容靠近导航药丸底边时使用统一透明度遮罩渐隐，不叠加白色或模糊。导航和弹窗不参与遮罩，键盘焦点须滚入完全可见区域。
