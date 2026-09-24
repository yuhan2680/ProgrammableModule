class_name EnemyModuleChoice
extends Button
## 药丸保存模块选项；选择菜单由属性面板共享的玻璃层绘制，避免原生弹窗放大 SVG。

signal item_selected(index: int)
signal popup_requested(choice: EnemyModuleChoice)

var _entries: Array[Dictionary] = []
var _selected := -1
var _arrow: TextureRect
var selected: int:
	get:
		return _selected
var item_count: int:
	get:
		return _entries.size()


## 标准按钮保留焦点与键盘激活；箭头单独限制尺寸，不参与文本和图标宽度计算。
func _ready() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		add_theme_color_override(state, Color.WHITE)
	_arrow = TextureRect.new()
	_arrow.texture = get_theme_icon("arrow", "OptionButton")
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_arrow)
	resized.connect(_layout_arrow)
	pressed.connect(show_popup)
	_layout_arrow()


## 不带图标的空槽仍使用同一选择数据，索引与编辑器组合逻辑保持一致。
func add_item(caption: String) -> void:
	add_icon_item(null, caption)


## 保存原始 SVG 引用，药丸和展开菜单各自按显示尺寸绘制，不修改共享资源。
func add_icon_item(texture: Texture2D, caption: String) -> void:
	_entries.append({"text": caption, "icon": texture, "metadata": null})
	if _selected < 0:
		select(0)


## 模块 ID 与本土化名称分离，保存地图继续使用目录中的原始 ID。
func set_item_metadata(index: int, value: Variant) -> void:
	_entries[index].metadata = value


## 为表单提交提供当前项的模块 ID。
func get_item_metadata(index: int) -> Variant:
	return _entries[index].metadata


## 显示文字沿用面板已经翻译的名称。
func get_item_text(index: int) -> String:
	return _entries[index].text


## 仅更新当前显示，真实用户选择由菜单接线另行发出信号。
func select(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	_selected = index
	text = _entries[index].text
	icon = _entries[index].icon


## 给共享菜单一份独立列表，打开和关闭都不会修改地图模板。
func items_snapshot() -> Array[Dictionary]:
	return _entries.duplicate(true)


## 禁用和隐藏的药丸不能经键盘或程序调用打开菜单。
func show_popup() -> void:
	if not disabled and is_visible_in_tree():
		popup_requested.emit(self)


## 箭头在右侧留白内垂直居中，不挤压左侧图标和文字。
func _layout_arrow() -> void:
	if _arrow == null:
		return
	_arrow.size = Vector2(9, 9)
	_arrow.position = Vector2(size.x - 12, (size.y - 9) * 0.5)
