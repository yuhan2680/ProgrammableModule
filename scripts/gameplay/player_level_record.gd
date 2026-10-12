class_name PlayerLevelRecord
extends RefCounted
## 玩家文件列表的只读展示快照；文件操作授权由所属资料库独立保管。

var source_path: String = ""
var display_name: String = ""
var creator: String = ""
# 真实文件创建时间（Unix 秒）；系统或文件系统无法提供时为零，不以修改时间代替。
var created_at: int = 0
var errors: PackedStringArray = PackedStringArray()
var can_rename: bool = false
var can_edit: bool = false
var playable: bool = false
var requires_newer_version: bool = false
var is_corrupt: bool = false
