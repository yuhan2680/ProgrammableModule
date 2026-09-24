# 玩家随机函数

第十关“猎人游戏”开放 `random()` 和 `randomInt(a, b)`，第十一关“巧能躲避”和第十二关“八方来敌”继承这两个函数。它们是可选的数值工具，不需要额外模块，也不要求先使用常量或变量。第十关继续通过真实击毁敌人判定通关，不检查玩家是否用了随机函数。

## 用法和取值范围

| 调用 | 返回值 | 参数要求 |
| --- | --- | --- |
| `random()` | 闭区间 `[0,1]` 内的随机数，0 和 1 都可能出现 | 不接受参数 |
| `randomInt(a, b)` | 闭区间 `[a,b]` 内的随机整数，包含两个端点 | 必须恰好传入两个有限整数，且 `a <= b` |

`randomInt` 的两个端点分别限制在有符号 32 位整数范围 `-2147483648..2147483647`。整数值的小数写法（例如 `2.0`）可以作为端点；`2.5`、无限值、非数值、扫描快照、位置向量或 null 都不可以。端点可以是合法数值表达式，但计算结果仍须满足上述范围。程序不会自动取整、裁剪范围或交换颠倒的上下限。两端相等时返回这个整数，例如 `randomInt(4,4)` 的结果始终为 4。

名称区分大小写，正确拼写是 `randomInt`。两个函数都是全局内置表达式，不能加模块名，不接受 `模块名.random()`、`模块名.randomInt(...)` 或给随机函数设置种子的调用。它们返回数字，必须放在合法的表达式位置；不作为独立动作语句使用。

```text
main() {
    shoot(randomInt(0, 359))
    move(randomInt(0, 359), random())
}
```

以上仅展示随机角度和随机距离的语法，不是具体关卡答案。动作还要求关卡开放相应能力，并且实际安装射击或移动模块。随机移动仍使用完整占地与真实路径检测，可能撞墙或进入 void；随机射击不会绕过射程、弹道或冷却规则。

随机表达式也能放入已开放的声明、赋值、比较或其他合法数值参数。开启 `allow_random` 会复用现有数值表达式入口，因而支持括号、一元正负号与有限加减。条件、常变量、用户函数、测距和雷达仍执行各自独立权限检查；不新增乘除法或宿主脚本能力。

## 何时重新取值

每次实际执行一次调用，就重新求取该次结果；两次调用可以恰好取得相同结果。未执行的分支、未调用的函数、静态校验、指令搜索、Tab 补全和语法高亮均不会取样。

```text
constant fixed_angle = randomInt(0, 359)
variable next_angle = fixed_angle

main() {
    shoot(fixed_angle)
    next_angle = randomInt(0, 359)
    shoot(next_angle)
}
```

常量在声明执行时只保存一次结果，不会随着时间变化。变量也只保存最近一次赋值的值，需要再次执行 `next_angle = randomInt(0, 359)` 才会重新抽取。循环体内的局部常量每轮重新执行声明，所以每轮都有一次新的求值机会。上述示例仍受射击冷却影响，不保证每次调用都发射；随机参数会在该动作调用被处理时求值。

随机函数本身不提交模拟动作、不额外推进逻辑 tick，也不会替代 `move` / `shoot` / `attack` 的执行。动作参数求值后固定用于本次动作，不会在移动途中每帧重新选择方向。暂停不推进程序，因此不会消耗随机序列；继续时接着原状态执行。停止或取消后不再取样，重新运行建立新的随机源和绑定。

## 关卡权限与兼容

`properties.level.allow_random` 为可选布尔字段，缺省 `false`。第十至第十二关分别显式写入 `true`；前九关保持关闭。此权限与 `allow_variables`、`allow_radar`、`allow_distance`、`allow_functions` 等彼此独立，不根据关卡编号、存档进度或雷达是否安装推断开放状态。

导入关卡可按相同规则显式设置 `allow_random`；地图编辑器试玩读取当前地图快照中的值。字段使用现有 `format_version: 1`，不迁移地图目录、不改变玩家草稿格式。随机源种子不是关卡随机函数字段，玩家 DSL、正式关卡和草稿不提供种子设置。

Tab 补全和指令集合按真实 `allow_random` 状态显示这两个全局函数，未解锁时不可用。正式运行入口由 `GameSession` 把 `level.allow_random` 传给 Parser，由 Parser 校验玩家源码权限，因此修改 UI 不能解锁语法。Runner 不读取地图权限，直接构造 AST 的工具调用方应先通过正确权限的 Parser；Runner 独立验证 AST 结构、类型与数值范围。`random` 与 `randomInt` 是内置能力名，不可用作常变量或用户函数名。

## 实现边界

Parser 使用显式 `RandomNode(callee, arguments)` 表达两个调用，保持 Lexer、Parser、AST 与 Runner 分层。Parser 校验权限、参数数量、可调用名称和表达式预算；Runner 对公开 AST 再检查结构、调用名称、参数数量及复杂度，并在参数最终求值后验证类型、有限性、整数性、端点顺序与支持范围。错误保留源码行列供代码编辑器定位，不通过 `eval`、反射或执行 GDScript 求值。

每个 `ProgramRunner` 拥有独立的 `RandomNumberGenerator`。`random()` 采用引擎 `randf()` 的闭区间语义；`randomInt` 只在完成整数端点校验后请求包含两端的整数。玩家随机数不会使用或改变敌人 `random_wander` 控制器的随机序列，也不依赖全局随机源、帧率或 UI 刷新次数。

`ProgramRunner.create(program, world, random_seed: Variant = null)` 提供可选的整数测试种子。正常运行省略此值并独立初始化随机源；隔离测试可固定种子比较相同程序的序列，不能把测试种子写入正式关卡、玩家代码或存档。测试还需覆盖闭区间与端点、负值及完整整数范围、非法参数、权限、公开 AST、常变量取样、暂停和重新运行，以及玩家与敌人随机源隔离；不能依赖某次随机样本恰好出现两个端点来证明范围。

常变量语义见 [常量与变量](VARIABLES.md)，第十关场地和敌人规则见 [猎人游戏](RADAR_PURSUIT.md)。

## 引擎依据

闭区间取值与实例随机源采用 [Godot 4.5 RandomNumberGenerator 官方说明](https://docs.godotengine.org/en/4.5/classes/class_randomnumbergenerator.html)：`randf()` 包含 0 与 1，`randi_range()` 返回包含两端的有符号 32 位整数，不同实例可独立播种。项目据此将整数端点限定为有符号 32 位，并额外拒绝反向区间。

实现核对基于 [Godot 4.5-stable RandomPCG 源码](https://github.com/godotengine/godot/blob/4.5-stable/core/math/random_pcg.cpp)：整数范围计算使用较宽的中间值，并专门处理完整 32 位区间，避免包含上限时溢出。浮点生成实现见 [random_pcg.h](https://github.com/godotengine/godot/blob/4.5-stable/core/math/random_pcg.h)。测试使用固定种子保证当前引擎内可复现，不承诺跨引擎版本的底层随机序列保持不变。
