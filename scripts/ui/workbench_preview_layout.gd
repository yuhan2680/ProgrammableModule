class_name WorkbenchPreviewLayout
extends Control
## 地图像窗帘一样覆盖原宽度代码卡片，交界附近仅作局部柔和渐淡。

signal transition_started(expanding: bool)
signal transition_finished(expanded: bool)

const RESIZE_SECONDS := 0.40
const HANDLE_WIDTH := 12.0
const CODE_WIDTH_RATIO := 0.38
const MINIMUM_CODE_WIDTH := 430.0
const MINIMUM_CARD_GAP := 16.0
const FADE_WIDTH := 88.0
const MINIMUM_ALPHA := 0.30
const ENDPOINT_EPSILON := 0.001
const WIPE_SHADER := preload("res://assets/ui/workbench_card_wipe.gdshader")

var split: HSplitContainer
var expanded := false
var transitioning := false
var _world: Control
var _edit: Control
var _overlay: Control
var _edge_handle: Control
var _edit_backplate: Panel
var _edit_group: CanvasGroup
var _wipe_material: ShaderMaterial
var _world_slot: Control
var _edit_slot: Control
var _manual_layout := false
var _expand_progress := 0.0
var _dragging := false
var _drag_start_progress := 0.0
var _drag_grab_offset := 0.0
var _layout_queued := false
var _saved_split_modulate := Color.WHITE
var _saved_edit_theme: Theme
var _tween: Tween


## 静态分栏只负责基准排版，独立边缘拖柄控制覆盖范围而不压缩代码卡片。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	split = HSplitContainer.new()
	split.name = "WorkbenchSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 40
	split.dragging_enabled = false
	split.dragger_visibility = SplitContainer.DRAGGER_HIDDEN
	add_child(split)
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.minimum_size_changed.connect(update_minimum_size)
	_overlay = Control.new()
	_overlay.name = "PreviewCardLayer"
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.mouse_force_pass_scroll_events = false
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 渐淡层下面保留原卡片底色，避免深色背景透出浅色页面而形成发光条。
	_edit_backplate = Panel.new()
	_edit_backplate.name = "CurtainEditBackground"
	_edit_backplate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_edit_backplate)
	_edit_group = CanvasGroup.new()
	_edit_group.name = "CurtainEditCard"
	_edit_group.fit_margin = 12.0
	_edit_group.clear_margin = 12.0
	_edit_group.use_mipmaps = false
	_wipe_material = ShaderMaterial.new()
	_wipe_material.shader = WIPE_SHADER
	_wipe_material.set_shader_parameter("minimum_alpha", MINIMUM_ALPHA)
	_wipe_material.set_shader_parameter("fade_width", FADE_WIDTH)
	_edit_group.material = _wipe_material
	_overlay.add_child(_edit_group)
	_overlay.hide()
	_edge_handle = Control.new()
	_edge_handle.name = "WorldCurtainHandle"
	_edge_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_edge_handle.mouse_force_pass_scroll_events = false
	_edge_handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_edge_handle.gui_input.connect(_on_edge_input)
	add_child(_edge_handle)
	resized.connect(_on_layout_resized)
	update_minimum_size()


## 记录原卡片与画布，覆盖层始终复用这些实例及其撤销、选区和运行状态。
func configure(world: Control, edit: Control) -> void:
	_world = world
	_edit = edit
	_world.mouse_filter = Control.MOUSE_FILTER_STOP
	_world.mouse_force_pass_scroll_events = false
	_world.minimum_size_changed.connect(_refresh_slot_minimums)
	_edit.minimum_size_changed.connect(_refresh_slot_minimums)
	_edit.theme_changed.connect(_queue_manual_layout)
	_world.resized.connect(_queue_manual_layout)
	_sync_baseline_layout()
	_queue_manual_layout()
	update_minimum_size()


## 预览期间代码仍有原始尺寸，但不能反过来撑开覆盖地图所在工作区。
func _get_minimum_size() -> Vector2:
	if split == null:
		return Vector2.ZERO
	var minimum := split.get_combined_minimum_size()
	if _world != null and _edit != null:
		minimum.x = _world.get_combined_minimum_size().x if _manual_layout else _world.get_combined_minimum_size().x + maxf(MINIMUM_CODE_WIDTH, _edit.get_combined_minimum_size().x) + MINIMUM_CARD_GAP
	return minimum


## 保留原全屏按钮；部分展开时继续展开，完全展开时才收回基准位置。
func toggle_preview() -> void:
	if transitioning or _world == null or _edit == null or not _world.visible:
		return
	transitioning = true
	var expanding := not expanded
	transition_started.emit(expanding)
	_begin_manual_layout()
	_show_edit_card()
	_tween = create_tween()
	var target := 1.0 if expanding else 0.0
	_tween.tween_method(_set_expand_progress, _expand_progress, target, RESIZE_SECONDS).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(_finish_transition)


## 地图适配与上层按钮共享同一个连续展开比例，拖动不修改模拟时钟。
func get_expand_progress() -> float:
	return _expand_progress


## 上层输入屏障先转交拖动事件，保证鼠标离开拖柄后仍能完成或取消操作。
func handle_drag_input(event: InputEvent) -> bool:
	if not _dragging:
		return false
	if event is InputEventMouseMotion:
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var normal_right := _world_slot.position.x + _world_slot.size.x
		var distance := size.x - normal_right
		_set_expand_progress((point.x - _drag_grab_offset - normal_right) / maxf(distance, 1.0))
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_finish_transition()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_cancel_drag()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_drag()
	return event is InputEventMouse or event is InputEventKey


## 暴露拖动状态以便上层区分持续手势与按钮补间。
func is_dragging() -> bool:
	return _dragging


## 部分覆盖也有覆盖层，但未覆盖的代码仍可在拖动结束后正常编辑。
func is_covering_code() -> bool:
	return _expand_progress > ENDPOINT_EPSILON


## 失焦、应用暂停和页面隐藏取消手势，避免遗失鼠标释放后留下输入锁。
func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		_cancel_drag()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_drag()


## 离场销毁时停止绑定页面的补间，不把过期结束通知发送给下一页。
func _exit_tree() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_dragging = false
	transitioning = false


## 从真实地图右边缘开始手势，保存抓取偏移以避免按下瞬间跳动。
func _on_edge_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	if transitioning or _world == null or not _world.is_visible_in_tree():
		return
	var global_point: Vector2 = _edge_handle.get_global_transform_with_canvas() * event.position
	var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * global_point
	_drag_start_progress = _expand_progress
	_drag_grab_offset = point.x - _world_rect().end.x
	_dragging = true
	transitioning = true
	transition_started.emit(not expanded)
	_begin_manual_layout()
	_show_edit_card()
	_edge_handle.accept_event()


## 取消只还原本次手势的起始覆盖范围，不撤销用户之前已经确认的部分展开。
func _cancel_drag() -> void:
	if not _dragging:
		return
	_set_expand_progress(_drag_start_progress)
	_finish_transition()


## 窗口改变时终止旧坐标手势；稳定覆盖和按钮补间继续按新工作区尺寸排版。
func _on_layout_resized() -> void:
	_cancel_drag()
	_sync_baseline_layout()
	_queue_manual_layout()


## 代码以较窄比例右对齐，地图默认填满其余宽度；两张卡片之间保留固定间距。
func _sync_baseline_layout() -> void:
	if split == null or _world == null or _edit == null or size.x <= 0.0:
		return
	var world_minimum := _world.get_combined_minimum_size().x
	var code_minimum := maxf(MINIMUM_CODE_WIDTH, _edit.get_combined_minimum_size().x)
	var code_width := maxf(code_minimum, roundf(size.x * CODE_WIDTH_RATIO))
	var world_width := maxf(world_minimum, size.x - code_width - MINIMUM_CARD_GAP)
	var gap := int(MINIMUM_CARD_GAP)
	if split.get_theme_constant("separation") != gap:
		split.add_theme_constant_override("separation", gap)
	# 原生分栏的偏移相对于扣除间距后的中点；它只分配静态基准，不响应鼠标拖动。
	var offset := int(roundf(world_width - (size.x - gap) * 0.5))
	if split.split_offset != offset:
		split.split_offset = offset


## 透明占位保留正常代码宽度；真实地图在合成代码层后绘制，从而真正遮住其输入和内容。
func _begin_manual_layout() -> void:
	if _manual_layout:
		return
	var world_rect := _world.get_rect()
	var edit_rect := _edit.get_rect()
	var normal_offset := split.split_offset
	_world_slot = _make_slot(_world, "WorldNormalSlot")
	_edit_slot = _make_slot(_edit, "EditNormalSlot")
	_saved_split_modulate = split.modulate
	split.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_world.reparent(_overlay, false)
	_pin_edit_theme()
	_edit.reparent(_edit_group, false)
	split.add_child(_world_slot)
	split.add_child(_edit_slot)
	# 移除最后一个分栏会重置偏移；占位重新加入后还原基准，而非让代码跟随地图缩窄。
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
	_show_edit_card()
	update_minimum_size()


## CanvasGroup 会截断 Control 主题继承，临时绑定同一资源保持代码字体与配色不变。
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


## 占位只复制排版约束，所有用户内容继续保留在原有控件中。
func _make_slot(card: Control, slot_name: String) -> Control:
	var slot := Control.new()
	slot.name = slot_name
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.custom_minimum_size = card.get_combined_minimum_size()
	slot.size_flags_horizontal = card.size_flags_horizontal
	slot.size_flags_vertical = card.size_flags_vertical
	slot.size_flags_stretch_ratio = card.size_flags_stretch_ratio
	return slot


## 文案或主题更新最小尺寸时，让基准占位保持与正常分栏相同约束。
func _refresh_slot_minimums() -> void:
	if _manual_layout:
		_world_slot.custom_minimum_size = _world.get_combined_minimum_size()
		_edit_slot.custom_minimum_size = _edit.get_combined_minimum_size()
	update_minimum_size()
	_sync_baseline_layout()
	_queue_manual_layout()


## 等容器完成同帧排版后统一同步，避免尺寸信号递归和窗口变化时混用坐标。
func _queue_manual_layout() -> void:
	if _layout_queued or not is_inside_tree():
		return
	_layout_queued = true
	_layout_manual_cards.call_deferred()


## 地图覆盖代码基准矩形，内容在同色底板上渐淡；未触及代码时不提前绘制淡化带。
func _layout_manual_cards() -> void:
	_layout_queued = false
	if _manual_layout:
		_world.position = _world_slot.position.lerp(Vector2.ZERO, _expand_progress)
		_world.size = _world_slot.size.lerp(size, _expand_progress)
		_edit_group.position = _edit_slot.position
		_edit.position = Vector2.ZERO
		_edit.size = _edit_slot.size
		_edit_backplate.position = _edit_slot.position
		_edit_backplate.size = _edit_slot.size
		var background := _edit.get_theme_stylebox("panel")
		if _edit_backplate.get_theme_stylebox("panel") != background:
			_edit_backplate.add_theme_stylebox_override("panel", background)
		var curtain_edge := _world.position.x + _world.size.x - _edit_group.position.x
		_wipe_material.set_shader_parameter("curtain_edge", curtain_edge)
		_wipe_material.set_shader_parameter("fade_strength", smoothstep(0.0, HANDLE_WIDTH, curtain_edge))
	_layout_handle()


## 将地图实际坐标转换回布局局部坐标，兼容原生分栏和覆盖层两种父级。
func _world_rect() -> Rect2:
	return (get_global_transform().affine_inverse() * _world.get_global_transform()) * Rect2(Vector2.ZERO, _world.size)


## 拖柄始终跟随地图右边缘，全幅时仍留在视口内以便直接向左拖回。
func _layout_handle() -> void:
	if _world == null or _edge_handle == null:
		return
	var world_rect := _world_rect()
	_edge_handle.visible = _world.is_visible_in_tree()
	_edge_handle.position = Vector2(clampf(world_rect.end.x - HANDLE_WIDTH * 0.5, 0.0, maxf(size.x - HANDLE_WIDTH, 0.0)), world_rect.position.y)
	_edge_handle.size = Vector2(HANDLE_WIDTH, world_rect.size.y)


## 连续进度只驱动界面矩形和渐淡着色器，不改变编辑器宽度或游戏数据。
func _set_expand_progress(value: float) -> void:
	_expand_progress = clampf(value, 0.0, 1.0)
	_layout_manual_cards()


## 展开与收回过程中代码一直存在；仅地图实际遮满后退出不可见控件的命中范围。
func _show_edit_card() -> void:
	_edit.show()
	_edit_group.show()
	_layout_manual_cards()


## 稳定部分展开可继续编辑；两端分别恢复原分栏或隐藏已被完全覆盖的代码卡片。
func _finish_transition() -> void:
	_dragging = false
	expanded = _expand_progress >= 1.0 - ENDPOINT_EPSILON
	if _expand_progress <= ENDPOINT_EPSILON:
		_set_expand_progress(0.0)
		_restore_split_layout()
	elif expanded:
		_set_expand_progress(1.0)
		_edit.hide()
		_edit_group.hide()
	transitioning = false
	_tween = null
	transition_finished.emit(expanded)


## 原节点交回静态分栏并恢复主题，不重新创建编辑器或恢复旧的挤压式分隔条。
func _restore_split_layout() -> void:
	if not _manual_layout:
		return
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
	_edit.theme = _saved_edit_theme
	split.split_offset = normal_offset
	_world.position = world_rect.position
	_world.size = world_rect.size
	_edit.position = edit_rect.position
	_edit.size = edit_rect.size
	split.modulate = _saved_split_modulate
	_overlay.hide()
	split.queue_sort()
	_layout_handle()
	update_minimum_size()
