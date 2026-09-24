class_name TileDefinition
extends RefCounted
## 地块语义来自定义文件，不由贴图或渲染节点决定。

var id: String = ""
var display_name: String = ""
var texture: String = ""
var collision: bool = false
var radar_block: bool = false
# 未显式设置时随 collision 变化，兼容以代码构造地块的旧调用方。
var _attack_block_override: Variant = null
var attack_block: bool:
	get:
		return collision if _attack_block_override == null else bool(_attack_block_override)
	set(value):
		_attack_block_override = value
var properties: Dictionary = {}
var raw: Dictionary = {}
