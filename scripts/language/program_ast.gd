class_name ProgramAst
extends RefCounted
## 有限语言子集的显式语法树。结构保留程序、函数、代码块、调用与字面量层级，
## 之后扩展语法时可新增节点与解释规则，而不必让运行器重新分析源字符串。


class AstNode extends RefCounted:
	## 所有节点都记录从 1 开始的位置，错误提示和源码高亮共用这一约定。
	var line: int = 1
	var column: int = 1


class ExpressionNode extends AstNode:
	## 只读表达式独立于动作语句，读取数值、雷达或坐标时不提交命令。
	pass


class NumberNode extends ExpressionNode:
	## 同时保留数值和原文字面量，后续诊断或代码工具无需反向格式化数字。
	var value: float = 0.0
	var literal: String = ""


class NameNode extends ExpressionNode:
	## 绑定名称按词法作用域解析，可保存数值、雷达快照或坐标，不执行动态函数。
	var name: String = ""


class NullNode extends ExpressionNode:
	## 雷达无目标值使用显式节点，不能与缺失的 AST 表达式混淆。
	pass


class ScanNode extends ExpressionNode:
	## 空接收名选择唯一雷达；查询返回目标快照，不持有世界实体引用。
	var receiver: String = ""


class RandomNode extends ExpressionNode:
	## 内置随机数只在实际求值时消耗当前运行器的随机序列；不是模块动作。
	var callee: String = ""
	var arguments: Array[ExpressionNode] = []


class TargetMemberNode extends ExpressionNode:
	## 固定白名单读取雷达快照或二维坐标，不调用任意对象成员。
	var target: ExpressionNode
	var member: String = ""


class DistanceNode extends ExpressionNode:
	## 空接收名选择唯一可用测距模块；角度也可以是有限数值表达式。
	var receiver: String = ""
	var angle: ExpressionNode


class BinaryNode extends ExpressionNode:
	## 有限加减运算不执行动作或任意函数，名称读取由独立节点处理。
	var operator: String = ""
	var left: ExpressionNode
	var right: ExpressionNode


class StatementNode extends AstNode:
	## 语句有独立类型，运行器不能把普通数值节点当作指令执行。
	pass


class DeclarationNode extends StatementNode:
	## constant/value 不可重新赋值，variable 保存本次运行中的有限值或目标快照。
	var name: String = ""
	var mutable: bool = false
	var initializer: ExpressionNode


class AssignmentNode extends StatementNode:
	## 赋值只更新最近的已声明可变绑定，不创建隐式全局变量。
	var name: String = ""
	var expression: ExpressionNode


class CallNode extends StatementNode:
	## 参数保留显式表达式，字面量仍使用 NumberNode 及其 value。
	var callee: String = ""
	## 空字符串沿用全体同类模块调用；非空值精确引用装配实例名，不做广播回退。
	var receiver: String = ""
	var arguments: Array[ExpressionNode] = []


class UserCallNode extends StatementNode:
	## 无参数用户函数调用与模块动作独立建模，运行时进入已验证的函数体。
	var callee: String = ""


class BlockNode extends AstNode:
	## 调用、循环与分支保持显式节点；tick 的有限结构由解析与预检双重检查。
	var statements: Array[StatementNode] = []


class LoopNode extends StatementNode:
	## 无限重复完整代码块；次数不预展开，也不以伪函数调用代表循环结构。
	var body: BlockNode


class ForNode extends StatementNode:
	## 有限数值循环保留区间表达式；进入时只求值一次，每轮建立只读迭代变量。
	var iterator: String = ""
	var start: ExpressionNode
	var end: ExpressionNode
	var step: ExpressionNode
	var body: BlockNode


class SimultaneousNode extends StatementNode:
	## 同一逻辑 tick 原子提交有限动作，等待全部结束；不等同于顺序块或任意函数。
	var body: BlockNode


class ConditionNode extends AstNode:
	## 条件与动作分开，避免把有副作用的 shoot 调用误当作布尔表达式。
	pass


class ReadyNode extends ConditionNode:
	## 精确查询命名射击模块在下个逻辑 tick 的冷却状态，不广播、不推进世界。
	var receiver: String = ""


class ComparisonNode extends ConditionNode:
	## 比较只读数字或用 null 判断雷达目标是否存在；不允许动作调用充当条件。
	var operator: String = ""
	var left: ExpressionNode
	var right: ExpressionNode


class IfNode extends StatementNode:
	## 条件仅在进入时读取；省略 else 用空分支表示，连续无动作执行仍受预算限制。
	var condition: ConditionNode
	var then_body: BlockNode
	var else_body: BlockNode


class FunctionNode extends AstNode:
	## main / tick 入口与显式 function 声明共用无参数代码块结构。
	var name: String = ""
	var body: BlockNode


class RadarEventNode extends AstNode:
	## 顶层雷达事件只把新目标快照写入已声明的全局变量，不携带任意回调语句。
	var receiver: String = ""
	var binding_name: String = ""


class ProgramNode extends AstNode:
	## 入口在编译时已确定，运行器不会搜索源码或猜测起始语句。
	var main: FunctionNode
	## tick 为可选的每逻辑帧回调，与 main 分离，绝不伪装成顺序调用。
	var tick: FunctionNode

	## 用户函数按声明顺序保留，调用解析通过函数名索引支持前向引用。
	var functions: Array[FunctionNode] = []

	## 全局初始化按源码声明顺序执行，在 main/tick 开始前全部完成。
	var globals: Array[DeclarationNode] = []

	## 事件按源码顺序注册；固定具名雷达与全局可变绑定均在执行前验证。
	var radar_events: Array[RadarEventNode] = []
