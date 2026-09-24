# 常量与变量

第十关“猎人游戏”开放可选的 `value` / `constant` 常量与 `variable` 变量，第十一关继续继承这些能力。第十关只根据真实击毁目标判定通关，不检查是否使用绑定。`allow_variables` 是独立权限，旧关卡默认关闭；函数、条件、测距、雷达、并行和随机函数等权限仍分别检查。按用户最新要求，第十一关同时开放玩家雷达，常变量也可保存扫描快照、世界位置向量或无目标值 null。

```text
constant warning = 2.5
variable observed = 0

main() {
    loop {
        observed = sensor.distance(0)
        if (observed < warning) {
            dodge()
        } else {
            move(0, 0.1)
        }
    }
}

function dodge() {
    constant sideways = 1
    move(90, sideways)
    move(270, sideways)
}
```

上述示例中的 `sensor` 是已安装的测距模块名称，关卡还需开放对应能力。它只展示语言用法，不是具体关卡答案。

## 声明与表达式

- `constant name = 表达式` 声明常量，只在声明执行时取值一次，不允许重新赋值。旧版文档的 `value` 是同义兼容写法；新的教程使用 `constant`。
- `variable name = 表达式` 声明变量，`name = 表达式` 修改已有变量。
- 数值表达式接受有限数字、已声明的数值名称、已解锁的 `distance(角度)` 或 `模块名.distance(角度)`、雷达目标的数值属性、已解锁的 `random()` / `randomInt(a,b)`、括号以及一元正负号、加减法。数值名称可用于动作参数、测距角度与已解锁的数值比较。
- 开放 `allow_radar` 后，还能保存 `scan()` 返回的目标快照、`target.Position` 世界位置向量及 `null`（兼容 `Null`）。快照和坐标只有固定只读属性，不支持修改 `target.Distance` 或 `position.x`；需要新目标状态时重新执行扫描。
- 不支持字符串、布尔变量、乘除法、复合赋值、函数返回值或宿主脚本求值。赋值是语句，不能嵌入条件或动作参数。`=` 与比较运算符 `==` 不同。
- 每行一条语句，不使用分号；`=` 后、运算符后或括号内可以换行。

名称区分大小写，采用最长 128 字符的英文标识符规则，允许下划线与非首位数字，不能覆盖保留字、已有语言能力或任意用户函数名。模块实例名属于独立空间，仍通过 `模块名.动作(...)` 访问。

常量记录声明时的值，不会自动追踪世界变化；雷达快照与位置向量也同样如此。例如 `constant gap = distance(0)` 保留当时距离；若需要持续测量，使用变量并在每次需要时重新赋值。负的普通变量值合法；将负值传入移动距离时仍会报错。任何计算得到非有限数值都会立即失败。扫描快照、坐标或 null 不能隐式转换成动作参数、加减操作数或排序比较值；先读取 Angle()、Distance 或 Position.x/y 得到数值。目标仅支持与 null 的 == / != 存在判断，读取空目标属性会给出行列错误。

## 保存随机数

第十、十一关同时开启独立的 `allow_random`。`random()` 返回 `[0,1]` 内的数值，`randomInt(a,b)` 返回包含两端的整数；它们不依赖常变量权限，也可直接作为已开放动作的参数；开启随机能力同时复用现有括号、一元正负号和有限加减表达式入口。声明和赋值只存储实际求值的结果，不存储一个自动刷新的随机表达式：

```text
constant chosen_angle = randomInt(0, 359)
variable next_angle = chosen_angle

main() {
    shoot(chosen_angle)
    next_angle = randomInt(0, 359)
    shoot(next_angle)
}
```

此例只展示取样和保存数值；仍需关卡允许射击、实际安装射击模块，且不会跳过射击冷却。常量在这次运行中保留首次抽取的角度；每次执行变量赋值才会抽取新值。重新运行会重新初始化绑定与随机源。循环内的局部常量每轮重新执行声明，所以每轮都可得到新值。完整参数范围与错误规则见 [随机函数](RANDOM_FUNCTIONS.md)。

## 作用域与执行顺序

顶层只接受常变量声明、`main()`、可选 `tick()` 和用户函数声明，不接受顶层赋值或动作。所有顶层声明在 `main()` 与 `tick()` 执行前按各声明的源码先后顺序初始化，初始化表达式只能引用之前的顶层声明。所有函数体可以读取完整的全局名称表，因此函数可以引用在函数声明之后书写的全局变量。

`main()` 与每次用户函数调用都创建独立局部作用域，其共同父级为全局作用域。函数不会读取调用者的局部变量。`if` 的两个分支拥有不同子作用域；`loop` 每一轮都创建新的局部作用域。声明执行后才在本层可见，同层重复声明会报错；内层可以遮蔽外层名称，初始化表达式先读取外层，再建立新的内层绑定。赋值修改最近的可见变量，并继续执行外层常量写保护。

```text
constant step = 0.1

main() {
    variable step = step + 0.1
    move(0, step)
    repeat_step()
}

function repeat_step() {
    move(0, step)
}
```

此例 `main()` 移动 0.2 格，函数读取全局常量，移动 0.1 格。每次重新运行都重新初始化全部绑定。

`tick()` 与 `simultaneously` 可以读取可见绑定及其合法只读属性，但不能声明或修改变量。`tick()` 只能读取全局绑定，不能读取 `main()` 局部变量；并行组在提交前从同一作用域读取全部参数，然后按原有规则原子提交。它们仍禁止用户函数调用，保持有限回调与直接并行动作的约束。

## 实现与边界

`ProgramParser.parse()` 的尾部权限参数依次为 `allow_functions`、`allow_variables`、`allow_radar`、`allow_random`，均默认 false。`ProgramLexer.Kind.ASSIGN` 表示单等号；AST 使用 `NameNode`、`DeclarationNode`、`AssignmentNode`，顶层声明保存在 `ProgramNode.globals`。`ProgramVariableValidation.is_binding_name()` 为编辑器提供一致的名称规则。静态名称检查在 Parser 与 Runner 入口共享，对未执行分支、未调用函数和公开 AST 都生效。

`ProgramBindingScope` 保存经校验的有限数值、目标快照、坐标或 null 及其可变性；字典快照按值复制，Runner 的执行帧持有词法作用域，声明与赋值不推进世界时间。连续寻找下一真实动作最多执行 4096 个纯计算或控制步骤，超过预算会带行列报错，因此 `loop { count = count + 1 }` 不会卡死。有限纯计算程序可直接完成，不额外消耗空白逻辑 tick。原来的源码、语句、表达式、控制深度与函数调用深度预算继续适用。

暂停由调用方停止推进 Runner 实现，不重新执行已经提交的声明与赋值；取消会终止后续初始化、计算和动作。重试创建新的 Runner 与世界，因此不会继承上一次运行的变量值。全部实现使用显式 AST、有限数值运算及固定快照属性读取，不调用 `eval`，不生成或执行 GDScript。雷达值语法和空目标判断见 [玩家雷达](PLAYER_RADAR.md)。

`tests/variables_language_runner.gd` 使用真实内容与独立内存世界验证权限、名称顺序、常量写保护、函数隔离、循环局部、动态测距、并行及回调读值、溢出、计算预算、取消与重新运行，以及公开 AST 防御；不读写玩家存档。
