class_name ProgramBindingScope
extends RefCounted
## 词法作用域只保存经验证的有限数字、雷达快照、坐标或无目标值，父级为封闭的词法环境，不持有执行器或世界。

var parent: ProgramBindingScope
var bindings: Dictionary = {}


## 创建独立子作用域，每次函数调用或循环迭代都会重新建立局部存储。
static func create(outer: ProgramBindingScope = null) -> ProgramBindingScope:
	var scope := ProgramBindingScope.new()
	scope.parent = outer
	return scope


## 从最近的作用域寻找名称；返回绑定单元，使赋值能更新外层而不是复制数值。
func resolve(name: String) -> Dictionary:
	var scope: ProgramBindingScope = self
	while scope != null:
		if scope.bindings.has(name):
			return scope.bindings[name]
		scope = scope.parent
	return {}


## 声明只写入当前层；语义校验负责提前拒绝同层重名和无效值；快照复制防止绑定之间相互修改。
func define(name: String, value: Variant, mutable: bool) -> void:
	bindings[name] = {"value": value.duplicate(true) if value is Dictionary else value, "mutable": mutable}
