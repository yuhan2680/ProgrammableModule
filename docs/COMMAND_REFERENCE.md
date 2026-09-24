# 指令集合资料

装配页和编程页的工具栏都提供「指令集合」书本图标，两处打开同一个资料窗口。窗口从 `res://data/commands/` 读取只读 JSON。每次打开时重新扫描直接 `.json` 文件，因此新增、修改或删除资料文件后，再次打开窗口即可看到更新，不需要修改 UI 中的指令清单。导出时需把 `data/commands/*.json` 包含在非资源文件过滤器内。

**增加 JSON 只会增加说明条目，不会增加或解锁 DSL 执行能力。** 真正的新语法仍需按现有架构更新 Lexer、Parser、AST 和 Runner。资料的 `syntax`、标题及说明都是纯文本，不会被执行或写入玩家程序。

当前资料覆盖 `main()`、`move()`、`attack()`、`shoot()`、`tick()`、具名模块调用、`loop {}`、`if / else` 、具名 `ready()`、`simultaneously {}`、普通/具名 `distance()` 以及 `function 名称() { ... }` 与无参调用、`constant` / `value` 常量、`variable` 变量声明和赋值，以及 `scan()`、`module.scan()`、`target.Angle()`、`target.Position` 与 `target.Distance`。通用具名调用介绍保留在「编程基础」，移动、近战、射击目录另有 `module.move()`、`module.attack()`、`module.shoot()` 的完整说明。模板中的 `angle`、`distance`、`module` 和 `...` 是待替换的说明占位符，不能直接作为可运行代码；资料不提供关卡完整解答。

## 阅读与折叠

指令列表默认折叠，每项只显示紧凑的语法入口。点击入口后，说明向下展开，显示本土化标题与功能介绍；多行语法同时展示完整模板。再次点击同一入口即可收起。各条指令独立展开，可以同时对照阅读多项说明。

目录与搜索结果不显示 `tick()` 条目；`if` 的折叠入口简写为 `if {}`，展开后仍可阅读完整条件语法和功能说明。这些调整只影响资料窗口的显示。

切换目录或修改搜索查询会重建列表，新列表中的指令默认收起。折叠仅改变展示状态：搜索仍匹配隐藏的完整描述、标题、语法及模块名称，找到结果后可点击查看介绍。

未解锁条目使用灰色文字，悬停时才提示「目前尚未解锁」，不常驻显示解锁徽章。它们仍可点击展开和阅读。展开、收起与搜索不会修改玩家程序、装配、关卡权限或存档；原有 `CommandCatalog` 数据接口保持不变。

## 新增资料

每个文件对应一个条目，格式见 `schemas/command.schema.json`：

```json
{
  "format_version": 1,
  "id": "move",
  "order": 20,
  "category": "action",
  "category_title": {"zh_CN": "动作指令", "en": "Actions"},
  "title": {"zh_CN": "移动", "en": "Move"},
  "description": {
    "zh_CN": "让机器人沿指定方向移动一段距离。",
    "en": "Move the robot in a specified direction and distance."
  },
  "syntax": "move(angle, distance)",
  "requirements": {"module_behavior": "MovementModule"}
}
```

- `id` 是稳定且唯一的 ASCII ID；改文案不需要改 ID。
- `order` 为整数，先按它排序，相同值按 `id` 排序。
- `category` 是稳定分类 ID；当前使用 `structure`、`action`、`query`。`structure` 表示语言结构，始终放在「编程基础」。`category_title` 保留分类的中英文名称作为资料元数据。
- `title`、`description`、`category_title` 都是语言字典。当前随游戏提供 `zh_CN` 和 `en`，也允许只有一种语言的扩展资料。
- 本土化依次尝试完整区域键、通用语种、同语种已有区域版本、简体中文、英文，最后使用按键排序的首个已有翻译。语言键的大小写与 `-` / `_` 写法不影响匹配。
- `requirements` 可省略；支持 `allow_tick`、`allow_loops`、`allow_named_calls`、`allow_conditionals`、`allow_simultaneous`、`allow_distance`、`allow_functions`、`allow_variables` 布尔值。为 `true` 时要求对应 `LevelDefinition` 权限开放；`false` 不增加限制。
- 可选的 `module_behavior` 要求该关卡允许的模块中至少有一个在注册表中具有对应行为，例如 `MovementModule`、`MeleeModule`、`ShootingModule`。它按行为判断，兼容具有同一行为的自定义模块 ID。

`is_available()` 只表示关卡允许这种能力，不表示玩家已经安装了所需模块。界面据此设置文字颜色和悬停提示；未解锁资料仍可展开阅读，不修改编译器权限、装配状态、关卡 JSON 或存档。

## 加载接口与错误

`CommandCatalog` 是不依赖场景树的 `RefCounted` 数据对象：

```gdscript
var catalog := CommandCatalog.new()
var result := catalog.load_directory() # 默认 res://data/commands
for entry in catalog.entries:
    var title := CommandCatalog.localized(entry, "title", "zh_CN")
    var description := CommandCatalog.localized(entry, "description", "en")
    var available := CommandCatalog.is_available(entry, level, registry)

var directory := catalog.sections(registry, "zh_CN")
var matches := catalog.search("移动", registry, "zh_CN")
```

可注入安全的 `res://` 或 `user://` 目录用于内容工具与隔离测试。每次加载都会清空旧 `entries` 和 `errors`，逐文件重新校验。文件名排序后，第一个有效的重复 ID 被保留，后续重复项报错；最终可见条目按 `order` / `id` 排列。

## 模块目录与全局搜索

`sections(registry, locale)` 返回独立的 `Array[Dictionary]` 快照，每项包含：

| 字段 | 含义 |
| --- | --- |
| `id` | 基础目录为 `general`；模块目录直接使用真实模块 ID |
| `kind` | `general` 或 `module`，区分合法 ID 恰好也为 `general` 的模块 |
| `title` | 当前语言下的目录名称 |
| `texture` | 模块定义的实际 SVG / 图片路径；基础目录为空字符串 |
| `entries` | 属于此目录的指令字典深拷贝，保留既有 `order` / `id` 顺序 |

基础目录固定在第一项，随后按模块 ID 排列注册表中的**所有已加载模块**，包括本关未解锁的模块及尚无资料的模块。界面选中状态应使用 `kind` 与 `id` 的组合，或目录数组索引。

`category: "structure"` 或没有 `requirements.module_behavior` 的资料归入基础目录。其他资料按 `module_behavior` 分配给全部对应行为的模块；新增同一行为的模块 JSON 后，不必复制说明文件。没有匹配模块的资料也临时放在基础目录，以免隐藏有效说明；可用性仍由 `is_available()` 按真实关卡权限判断。例如 `if / else` 属于基础目录，但仍保留当前语言要求的条件、具名调用和射击能力限制。

模块名称沿用游戏已安装的翻译资源，按传入的 `locale` 读取；未知自定义名称保留作者原文。数据接口不会临时切换全局语言，也不会改写模块定义。模块 SVG 加载及空目录提示属于展示层职责。

`search(query, registry, locale)` 搜索所有目录中的本土化指令标题、**完整说明**、语法模板及目录名称，忽略查询首尾空白和大小写；空查询返回全部条目。它只检索当前界面语种及相同的语言回退，不把其他隐藏语言加入匹配，不使用当前选中目录或指令展开状态作为过滤条件。

搜索结果是指令字典的深拷贝，额外携带 `section_id`、`section_kind`、`section_title`、`section_texture` 以显示模块归属，原始 `catalog.entries` 不增加这些字段。同一行为有多个模块时，同一指令会按实际归属出现在多个模块下；顺序仍是基础目录、模块 ID、目录内的指令 `order` / `id`。搜索模块名称会返回该模块的全部资料。两接口只读取当前已加载快照，不执行 I/O；窗口打开时调用 `load_directory()` 后，即可用它们投影最新资料。

## 有效资料与错误隔离

坏文件不会遮蔽有效资料。`load_directory()` 的 `DataResult.value` 是有效条目的独立快照，`DataResult.errors` 及 `catalog.errors` 收集带文件路径的错误；即使结果含错误，展示层仍可呈现 `catalog.entries`，并提示资料加载问题。输出条目增加只读的 `source_path` 来源字段，不需要写在 JSON 中。

每个文件最多 64 KiB，目录最多加载 512 个有效条目。标题和分类标题每语种最多 256 字符，说明每语种最多 4096 字符，语法模板最多 2048 字符；每个语言字典包含 1～16 个非空文本值。格式错误、未知字段、未知权限键、布尔值冒充整数和超限内容都报告错误。单个文件只允许已知资料字段，不接受脚本注册字段。

独立回归入口为 `tests/command_catalog_runner.gd`。它只读内置资料，并在独占 `user://tests/` 子目录验证新增后重载、删除后清除缓存、重复与坏文件隔离、本土化回退、已实现教学关卡的权限标记、模块目录、具名指令归属、描述及模块名称搜索、返回快照隔离；不改写玩家记录，也不运行资料中的示例文本。

第九关新增测距模块目录，收录普通和具名测距两项查询。`if / else` 的结构资料由 `allow_conditionals` 解锁；`ready()` 与 `distance()` 的具体能力仍在各自资料与运行前检查中验证。数值比较另需 `allow_distance`，不影响前八关。

第十一关通过 `data/commands/120_functions.json` 在「编程基础」收录函数声明与调用。`requirements.allow_functions: true` 使其在前九关保持灰色并提供未解锁悬停提示，在第十一关“巧能躲避”正常显示。常量与变量另由 `130_constants.json`、`140_variables.json` 提供说明，要求独立的 `allow_variables: true`。第十一关显式继承第十关这部分能力，第十关地图仍跳过，前九关常变量条目保持灰色；资料本身不开放权限。玩家雷达已按最新要求在第十一关通过独立 `allow_radar: true` 与允许模块 radar 开放，前九关保持灰色。函数边界见 [函数复用](FUNCTIONS.md)，数值绑定与作用域见 [常量与变量](VARIABLES.md)。

Tab 补全根据同一关卡权限建议声明关键字与当前位置可见的绑定名称，忽略注释、尚未声明的局部名称和已经退出的词法块。资料阅读、灰字词语补全与逐步教学代码提示分别工作；后者按设置等级和跨会话的连续失败次数显示，见 [代码提示](CODE_HINTS.md)。


## 雷达资料

雷达目录从 `data/commands/150_radar_scan.json` 至 `154_radar_distance.json` 读取普通扫描、具名扫描、目标角度、目标位置和目标距离。全部要求 `allow_radar` 与 `RadarModule`；具名扫描另要求 `allow_named_calls`，保存目标后读取属性的介绍另要求 `allow_variables`。第十一关满足这些条件，解锁状态、搜索、灰色提示及 Tab 补全均使用同一关卡权限。

文档中的 `target` 是用户保存扫描结果时采用的示例名称。读取前用 `target != null` 判断；`Angle()` 返回方向角，`Position` 是可读 x/y 的世界坐标向量，`Distance` 是扫描来源中心到目标参考点的直线距离，兼容 `Distance()`。`Null` 是 null 的兼容写法。资料不承诺旧快照自动刷新，完整语义见 [玩家雷达](PLAYER_RADAR.md)。
