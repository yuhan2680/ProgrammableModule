class_name ResponsivePropertyRow
extends Container
## 属性表单只改变原控件的矩形；宽度不足时按关联分组换行，不重建或移动输入节点。

var group_sizes: Array[int] = []
var equal_width := false
var alignment := BoxContainer.ALIGNMENT_BEGIN
var stacked := false
var _minimum_height := 0.0


## 普通容器继续接收子控件的尺寸通知，鼠标沿原控件链冒泡。
func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 10)


## 横向空间由属性卡决定，正文只能增高，不能用完整翻译文字反向撑宽卡片。
func _get_minimum_size() -> Vector2:
	return Vector2(0, _minimum_height)


## 语言、字号和可用宽度变化都重新度量，不读取或提交任何编辑字段。
func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_layout_fields()
	elif what in [NOTIFICATION_THEME_CHANGED, NOTIFICATION_TRANSLATION_CHANGED, NOTIFICATION_RESIZED]:
		queue_sort()


## 未换行时的自然宽度用于选择多栏目或单栏目，不受上一轮标签换行结果影响。
func preferred_width() -> float:
	var children := _visible_controls()
	var result := 0.0
	var widest := 0.0
	for child in children:
		var width := _preferred_width(child)
		result += width
		widest = maxf(widest, width)
	if equal_width:
		result = widest * children.size()
	return result + maxf(0, children.size() - 1) * get_theme_constant("separation")


## 保持原节点顺序，只排版可见控件，折叠和禁用不改变输入归属。
func _visible_controls() -> Array[Control]:
	var result: Array[Control] = []
	for child in get_children():
		if child is Control and child.visible and not child.is_set_as_top_level():
			result.append(child)
	return result


## 标签到原始字号测量；嵌套的尺寸、工具和输入组保留自身所需空间。
func _preferred_width(control: Control) -> float:
	if control is Label:
		var base := maxi(1, roundi(GameTheme.base_font_size(control, "font_size") * GameTheme.font_scale(control)))
		return maxf(control.custom_minimum_size.x, control.get_theme_font("font").get_string_size(control.atr(control.text), HORIZONTAL_ALIGNMENT_LEFT, -1, base).x)
	if control is ResponsivePropertyRow:
		return control.preferred_width()
	if control is BoxContainer or control is MarginContainer:
		var width := 0.0
		var count := 0
		for child in control.get_children():
			if child is Control and child.visible:
				width = width + _preferred_width(child) if control is HBoxContainer else maxf(width, _preferred_width(child))
				count += 1
		if control is HBoxContainer:
			width += maxi(0, count - 1) * control.get_theme_constant("separation")
		elif control is MarginContainer:
			width += control.get_theme_constant("margin_left") + control.get_theme_constant("margin_right")
		return maxf(width, control.custom_minimum_size.x)
	return control.get_combined_minimum_size().x


## 同一行容纳不下所有栏目时，每个标签与控件组独占一行，纵向间距保持可读。
func _layout_fields() -> void:
	var children := _visible_controls()
	if children.is_empty():
		return
	var gap := float(get_theme_constant("separation"))
	var groups: Array[Array] = []
	var cursor := 0
	for count in group_sizes:
		if cursor >= children.size():
			break
		groups.append(children.slice(cursor, mini(cursor + count, children.size())))
		cursor += count
	if cursor < children.size():
		groups.append(children.slice(cursor))
	stacked = groups.size() > 1 and preferred_width() > size.x + 0.5
	if not stacked:
		groups = [children]
	var y := 0.0
	for group in groups:
		if y > 0:
			y += maxf(10.0, gap)
		y += _layout_group(group, y, gap)
	if not is_equal_approx(y, _minimum_height):
		_minimum_height = y
		update_minimum_size()


## 标签完整换行并适度缩小，配对输入按实际高度居中，不压缩图标或点击区域。
func _layout_group(group: Array, y: float, gap: float) -> float:
	var widths: Array[float] = []
	var label_indices: Array[int] = []
	var total := gap * maxi(0, group.size() - 1)
	for index in group.size():
		var child: Control = group[index]
		var width := _preferred_width(child)
		widths.append(width)
		total += width
		if child is Label and (index == 0 or width > 72.0):
			label_indices.append(index)
	if equal_width and not widths.is_empty():
		var widest: float = widths.max()
		widths.fill(widest)
		total = widest * group.size() + gap * maxi(0, group.size() - 1)
	var spare := size.x - total
	if spare < 0 and not label_indices.is_empty():
		var label_width := 0.0
		for index in label_indices:
			label_width += widths[index]
		var available := maxf(1.0, label_width + spare)
		for index in label_indices:
			widths[index] = maxf(1.0, available * widths[index] / maxf(1.0, label_width))
		spare = 0
	elif spare > 0:
		var expanders: Array[int] = []
		for index in group.size():
			if (group[index] as Control).size_flags_horizontal & Control.SIZE_EXPAND:
				expanders.append(index)
		for index in expanders:
			widths[index] += spare / expanders.size()
		if not expanders.is_empty():
			spare = 0
	# 连固定工具也放不下时按控件纵排；标签仍与这一组相邻，不裁切任何字段。
	var used := gap * maxi(0, group.size() - 1)
	for width in widths:
		used += width
	if used > size.x + 0.5:
		var height := 0.0
		for child: Control in group:
			var width := minf(size.x, _preferred_width(child))
			var extent := _fit_label(child, width) if child is Label else child.get_combined_minimum_size().y
			fit_child_in_rect(child, Rect2(Vector2((size.x - width) * 0.5, y + height), Vector2(width, extent)))
			height += extent + gap
		return maxf(0, height - gap)
	var heights: Array[float] = []
	var height := 0.0
	for index in group.size():
		var child: Control = group[index]
		var extent := _fit_label(child, widths[index]) if child is Label else child.get_combined_minimum_size().y
		heights.append(extent)
		height = maxf(height, extent)
	var x := maxf(0, spare) * (0.5 if alignment == BoxContainer.ALIGNMENT_CENTER else 1.0 if alignment == BoxContainer.ALIGNMENT_END else 0.0)
	for index in group.size():
		var child: Control = group[index]
		fit_child_in_rect(child, Rect2(Vector2(x, y + (height - heights[index]) * 0.5), Vector2(widths[index], heights[index])))
		x += widths[index] + gap
	return height


## 仅显示字号最多收小约百分之十五，原始字号元数据不变，恢复空间后自动还原。
func _fit_label(label: Label, width: float) -> float:
	var baseline := maxi(1, roundi(GameTheme.base_font_size(label, "font_size") * GameTheme.font_scale(label)))
	var font := label.get_theme_font("font")
	var natural := font.get_string_size(label.atr(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1, baseline).x
	var font_size := maxi(1, roundi(baseline * 0.85)) if natural > maxf(1, width) * 2.0 else baseline
	if label.get_theme_font_size("font_size") != font_size:
		label.add_theme_font_size_override("font_size", font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = false
	label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	# 使用 Label 自身的智能换行结果，长词拆分与主题行距才和实际绘制一致。
	label.size.x = maxf(1.0, width)
	return maxf(font.get_height(font_size), label.get_minimum_size().y)
