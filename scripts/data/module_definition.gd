class_name ModuleDefinition
extends RefCounted
## 模块只描述内容；行为由运行时按 behavior 名称创建。

var id: String = ""
var display_name: String = ""
var description: String = ""
var size: Vector2 = Vector2(0.5, 0.5)
var texture: String = ""
var behavior: String = ""
var properties: Dictionary = {}
var raw: Dictionary = {}
