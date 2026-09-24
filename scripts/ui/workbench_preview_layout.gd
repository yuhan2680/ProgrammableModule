class_name WorkbenchPreviewLayout
extends Control
## 保留同一卡片和原生分栏，按先擦除编辑区、再展开地图的顺序切换预览。

signal transition_started(expanding: bool)
signal transition_finished(expanded: bool)

const WIPE_SECONDS := 0.25
const RESIZE_SECONDS := 0.40
const WIPE_SHADER := preload("res://assets/ui/workbench_card_wipe.gdshader")

var split: HSplitContainer
var expanded := false
var transitioning := false
var _world: Control
var _edit: Control
var _overlay: Control
var _edit_group: CanvasGroup
var _wipe_material: ShaderMaterial
var _world_slot: Control
var _edit_slot: Control
var _manual_layout := false
var _expand_progress := 0.0
var _wipe_progress := 0.0
var _saved_split_modulate := Color.WHITE
var _saved_dragger_visibility := SplitContainer.DRAGGER_VISIBLE
var _saved_edit_theme: Theme
var _tween: Tween


## 创建正常分栏与仅在过渡时接管卡片的展示层，页头留在组件外。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	split = HSplitContainer.new()
	split.name = "WorkbenchSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 40
	add_child(split)
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.minimum_size_changed.connect(update_minimum_size)
	_overlay = Control.new()
	_overlay.name = "PreviewCardLayer"
	# 接住卡片间隙的输入，透明原生分栏在预览期间不能继续被拖动。
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edit_group = CanvasGroup.new()
	_edit_group.name = "WholeEditCardWipe"
	_edit_group.fit_margin = 12.0
	_edit_group.clear_margin = 12.0
	_edit_group.use_mipmaps = false
	_wipe_material = ShaderMaterial.new()
	_wipe_material.shader = WIPE_SHADER
	_edit_group.material = _wipe_material
	_overlay.add_child(_edit_group)
	_overlay.hide()
	resized.connect(_queue_manual_layout)
	update_minimum_size()


## 记录已经由调用者构建的真实卡片，不复制内容、代码编辑器或地图画布。
func configure(world: Control, edit: Control) -> void:
	_world = world
	_edit = edit
	_world.minimum_size_changed.connect(_refresh_slot_minimums)
	_edit.minimum_size_changed.connect(_refresh_slot_minimums)
	update_minimum_size()


## 正常布局延续原生最小尺寸；预览只为地图保留宽度，编辑区不再撑开工作区。
func _get_minimum_size() -> Vector2:
	if split == null:
		return Vector2.ZERO
	var minimum := split.get_combined_minimum_size()
	if _manual_layout and _world != null:
		minimum.x = _world.get_combined_minimum_size().x
	return minimum


## 稳定状态才接受切换，顺序动画只驱动显示参数，不接触会话或模拟时间。
func toggle_preview() -> void:
	if transitioning or _world == null or _edit == null:
		return
	if not expanded and not _world.visible:
		return
	transitioning = true
	var expanding := not expanded
	transition_started.emit(expanding)
	_tween = create_tween()
	if expanding:
		_begin_manual_layout()
		_tween.tween_method(_set_wipe_progress, 0.0, 1.0, WIPE_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_callback(_hide_edit_card)
		_tween.tween_method(_set_expand_progress, 0.0, 1.0, RESIZE_SECONDS).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	else:
		_tween.tween_method(_set_expand_progress, 1.0, 0.0, RESIZE_SECONDS).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_callback(_show_edit_card)
		_tween.tween_method(_set_wipe_progress, 1.0, 0.0, WIPE_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(_finish_transition.bind(expanding))


## 向地图适配逻辑提供当前展开比例，渐变期间也能按同一进度调整观察尺度。
func get_expand_progress() -> float:
	return _expand_progress


## 退出时取消尚未结束的回调，避免销毁页面后继续调整卡片。
func _exit_tree() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## 原生分栏继续用透明占位控件计算缩回位置，窗口改变后仍与真实分栏完全一致。
func _begin_manual_layout() -> void:
	var world_rect := _world.get_rect()
	var edit_rect := _edit.get_rect()
	var normal_offset := split.split_offset
	_world_slot = _make_slot(_world, "WorldNormalSlot")
	_edit_slot = _make_slot(_edit, "EditNormalSlot")
	_saved_split_modulate = split.modulate
	_saved_dragger_visibility = split.dragger_visibility
	# 不隐藏分栏，确保原生容器在预览和窗口缩放期间仍正常计算占位矩形。
	split.modulate = Color(1.0, 1.0, 1.0, 0.0)
	split.dragger_visibility = SplitContainer.DRAGGER_HIDDEN
	_world.reparent(_overlay, false)
	_pin_edit_theme()
	_edit.reparent(_edit_group, false)
	split.add_child(_world_slot)
	split.add_child(_edit_slot)
	# 新版 Godot 会在移除最后一个分栏时清理偏移，换占位后显式还原用户拖动的位置。
	split.split_offset = normal_offset
	_world_slot.position = world_rect.position
	_world_slot.size = world_rect.size
	_edit_slot.position = edit_rect.position
	_edit_slot.size = edit_rect.size
	_world.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_edit.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_world_slot.resized.connect(_queue_manual_layout)
	_edit_slot.resized.connect(_queue_manual_layout)
	_manual_layout = true
	_overlay.show()
	_edit_group.show()
	_set_wipe_progress(0.0)
	_set_expand_progress(0.0)
	update_minimum_size()


## CanvasGroup 不是 Control，会截断主题继承；临时绑定同一主题资源以保留字体和控件外观。
func _pin_edit_theme() -> void:
	_saved_edit_theme = _edit.theme
	if _saved_edit_theme != null:
		return
	var ancestor := _edit.get_parent()
	while ancestor != null:
		if ancestor is Control or ancestor is Window:
			var inherited_theme := ancestor.get("theme") as Theme
			if inherited_theme != null:
				_edit.theme = inherited_theme
				return
		ancestor = ancestor.get_parent()


## 占位只记录布局约束，原卡片的控件、选择、滚动与撤销记录仍保留在原实例中。
func _make_slot(card: Control, slot_name: String) -> Control:
	var slot := Control.new()
	slot.name = slot_name
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.custom_minimum_size = card.get_combined_minimum_size()
	slot.size_flags_horizontal = card.size_flags_horizontal
	slot.size_flags_vertical = card.size_flags_vertical
	slot.size_flags_stretch_ratio = card.size_flags_stretch_ratio
	return slot


## 动态文案或状态改变最小尺寸时，同步透明占位的约束以保持返回布局一致。
func _refresh_slot_minimums() -> void:
	if _manual_layout:
		_world_slot.custom_minimum_size = _world.get_combined_minimum_size()
		_edit_slot.custom_minimum_size = _edit.get_combined_minimum_size()
	update_minimum_size()


## 容器先完成同帧重新排版，再读占位尺寸，避免窗口缩放时混用前后两帧矩形。
func _queue_manual_layout() -> void:
	if _manual_layout:
		_layout_manual_cards.call_deferred()


## 地图右边缘向工作区右侧插值，编辑卡片保持原宽度，文字和控件不被压扁。
func _layout_manual_cards() -> void:
	if not _manual_layout:
		return
	_world.position = _world_slot.position.lerp(Vector2.ZERO, _expand_progress)
	_world.size = _world_slot.size.lerp(size, _expand_progress)
	_edit_group.position = _edit_slot.position
	_edit.position = Vector2.ZERO
	_edit.size = _edit_slot.size
	_wipe_material.set_shader_parameter("card_width", maxf(_edit.size.x, 1.0))


## 一次修改整体合成遮罩，使背景、文字、行号及选中区域按相同方向一起淡去。
func _set_wipe_progress(value: float) -> void:
	_wipe_progress = clampf(value, 0.0, 1.0)
	_wipe_material.set_shader_parameter("wipe_progress", _wipe_progress)


## 尺寸插值独立于擦除阶段，地图适配只需读取同一个连续比例。
func _set_expand_progress(value: float) -> void:
	_expand_progress = clampf(value, 0.0, 1.0)
	_layout_manual_cards()


## 完全擦除后隐藏真实编辑卡片，让不可见控件退出鼠标和键盘命中范围。
func _hide_edit_card() -> void:
	_edit.hide()
	_edit_group.hide()


## 缩回原宽度后才恢复编辑卡片绘制，初始遮罩保持完全透明。
func _show_edit_card() -> void:
	_edit.show()
	_edit_group.show()
	_layout_manual_cards()


## 稳定落点后恢复原生布局或保留全幅地图，最后通知调用者更新输入和图标。
func _finish_transition(expanding: bool) -> void:
	if not expanding:
		_restore_split_layout()
	expanded = expanding
	transitioning = false
	_tween = null
	transition_finished.emit(expanded)


## 将同一卡片交回原生分栏；保留分栏偏移和拖动行为，不重新创建任何编辑内容。
func _restore_split_layout() -> void:
	var world_rect := _world_slot.get_rect()
	var edit_rect := _edit_slot.get_rect()
	var normal_offset := split.split_offset
	_manual_layout = false
	_world_slot.free()
	_edit_slot.free()
	_world_slot = null
	_edit_slot = null
	_world.reparent(split, false)
	_edit.reparent(split, false)
	# 回到原生 Control 层级后恢复原属性，继续按正常主题继承响应后续变化。
	_edit.theme = _saved_edit_theme
	split.split_offset = normal_offset
	_world.position = world_rect.position
	_world.size = world_rect.size
	_edit.position = edit_rect.position
	_edit.size = edit_rect.size
	split.modulate = _saved_split_modulate
	split.dragger_visibility = _saved_dragger_visibility
	_overlay.hide()
	split.queue_sort()
	update_minimum_size()
