class_name PlayerProfilePanel
extends Control
## 玩家资料只绑定独立档案模型；关卡、模拟与删除确认由游戏外壳负责。

signal reset_requested

const TOP_FADE_WIDTH := SettingsContentFade.TOP_FADE_WIDTH
const CONTENT_TOP_GAP := SettingsContentFade.CONTENT_TOP_GAP
const DELETE_COLOR := Color("9d1414")

var profile: PlayerProfileStore
var card_boundary: Control
var top_boundary: Control
var navigation_title: Label

var _card: Control
var _content_fade: SettingsContentFade
var _column: VBoxContainer
var _scroll: ScrollContainer
var _scroll_content: MarginContainer
var _username_field: LineEdit
var _uid_field: LineEdit
var _uid_menu: PlayerUidContextMenu
var _hint_value: Label
var _play_time_value: Label
var _mystery_value: Label
var _mystery_row: Control
var _mystery_divider: Control
var _rate_value: Label
var _fastest_value: Label
var _longest_value: Label
var _delete_button: Button
var _status: Label
var _last_result: DataResult
var _syncing := false
var _committing := false
var _username_dirty := false
var _keyboard_focus := false


## 外层在挂入场景前注入模型，独立面板不访问正式玩家文件。
func _ready() -> void:
	if profile == null:
		GameTheme.label(self, "玩家档案模型未注入。")
		return
	_build_ui()
	set_notify_transform(true)
	profile.changed.connect(_sync_controls)
	get_viewport().gui_focus_changed.connect(_on_content_focus_changed)
	_sync_controls()


## 正文沿用设置页八成比例与上下透明渐隐，不重复绘制外层白色卡片。
func _build_ui() -> void:
	_content_fade = SettingsContentFade.new()
	_content_fade.name = "PlayerProfileContentFade"
	add_child(_content_fade)
	_card = Control.new()
	_card.name = "PlayerProfileCard"
	_card.theme = SettingsContentFade.inherited_theme(self)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_fade.add_child(_card)
	_scroll = ScrollContainer.new()
	_scroll.name = "PlayerProfileScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	_scroll.scale = Vector2.ONE * SettingsContentFade.CONTENT_SCALE
	_card.add_child(_scroll)
	SettingsContentFade.style_scrollbar(_scroll.get_v_scroll_bar())
	SettingsScrollFade.attach(_scroll)
	_scroll_content = MarginContainer.new()
	_scroll_content.name = "PlayerProfileScrollbarGutter"
	_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_content.add_theme_constant_override("margin_right", 24)
	_scroll.add_child(_scroll_content)
	_column = VBoxContainer.new()
	_column.name = "PlayerProfileColumn"
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override("separation", 12)
	_scroll_content.add_child(_column)
	var identity := _make_group("PlayerIdentityGroup")
	var name_row := _make_row(identity, "PlayerUsernameRow", "用户名")
	_username_field = _make_field(name_row, "PlayerUsername", true)
	_username_field.caret_blink = true
	_username_field.caret_blink_interval = 0.5
	_username_field.tooltip_text = "用户名最多 11 个字符，不支持 emoji 或控制字符；留空时使用 Player。"
	_username_field.text_changed.connect(_on_username_changed)
	_username_field.text_submitted.connect(_on_username_submitted)
	_username_field.focus_exited.connect(commit_username)
	_add_divider(identity)
	var uid_row := _make_row(identity, "PlayerUidRow", "UID")
	_uid_field = _make_field(uid_row, "PlayerUID", false)
	_uid_field.tooltip_text = "UID 由游戏自动生成，修改用户名不会改变。"
	_uid_field.context_menu_enabled = false
	_uid_field.gui_input.connect(_on_uid_input)
	_uid_menu = PlayerUidContextMenu.new()
	_uid_menu.copy_requested.connect(_copy_uid)
	add_child(_uid_menu)
	_add_section_gap()
	var statistics_title := GameTheme.label(_column, "统计信息", 16)
	statistics_title.name = "PlayerStatisticsTitle"
	var statistics := _make_group("PlayerStatisticsGroup")
	_hint_value = _make_value(_make_row(statistics, "PlayerHintsRow", "累积使用“代码提示”的次数"), "PlayerCodeHintUses")
	_add_divider(statistics)
	_play_time_value = _make_value(_make_row(statistics, "PlayerPlayTimeRow", "累积游戏时间"), "PlayerPlayTime")
	_add_divider(statistics)
	_rate_value = _make_value(_make_row(statistics, "PlayerPassRateRow", "平均关卡通过率"), "PlayerPassRate")
	_rate_value.tooltip_text = "通过率＝首次通关权重总和 ÷（首次通关数＋首通前失败次数）。首通前最高提示档与敌人数量权重相乘；通关后重玩、手动停止及编辑器测试不计入。"
	_add_divider(statistics)
	_fastest_value = _make_value(_make_row(statistics, "PlayerFastestRow", "最小关卡耗时时间"), "PlayerFastestTime")
	_add_divider(statistics)
	_longest_value = _make_value(_make_row(statistics, "PlayerLongestRow", "最长关卡耗时时间"), "PlayerLongestTime")
	for value in [_fastest_value, _longest_value]:
		value.tooltip_text = "从进入装配到成功通关累计耗时，修改装配和代码继续计时；暂停、后台与退出关卡不计时。"
	_mystery_divider = _add_divider(statistics)
	_mystery_divider.name = "PlayerMysteryDivider"
	var mystery_row := _make_row(statistics, "PlayerMysteryRow", "？？？")
	_mystery_row = mystery_row.get_parent() as Control
	# 保留未知栏目名称，不通过本土化或悬浮提示提前揭示彩蛋内容。
	(mystery_row.get_child(0) as Label).auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_mystery_value = _make_value(mystery_row, "PlayerMysteryBest")
	_delete_button = GameTheme.button(_column, "删除玩家档案", _request_reset)
	_delete_button.name = "DeletePlayerProfileButton"
	_delete_button.custom_minimum_size.y = 52
	_delete_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	GameTheme.font_size(_delete_button, "font_size", 16)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_delete_button.add_theme_color_override(state, DELETE_COLOR)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		var fill := GameTheme.SETTINGS_GROUP_BACKGROUND
		if state == "hover":
			fill = Color("dce0e6")
		elif state in ["pressed", "hover_pressed"]:
			fill = Color("d3d8e0")
		_delete_button.add_theme_stylebox_override(state, GameTheme.box(fill, Color.TRANSPARENT, 14))
	_delete_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_status = GameTheme.label(_column, "", 14)
	_status.name = "PlayerProfileStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", GameTheme.ERROR)
	_status.hide()
	resized.connect(_layout_card)
	_layout_card.call_deferred()


## 每组只由唯一圆角面板绘制灰底，分隔处不叠加独立卡片。
func _make_group(node_name: String) -> VBoxContainer:
	var group := PanelContainer.new()
	group.name = node_name
	var surface := GameTheme.box(GameTheme.SETTINGS_GROUP_BACKGROUND, Color.TRANSPARENT, 14)
	surface.set_content_margin_all(0)
	group.add_theme_stylebox_override("panel", surface)
	_column.add_child(group)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	group.add_child(rows)
	return rows


## 左侧说明可换行，右侧值保持贴齐灰卡右缘，长英文不会挤出窗口。
func _make_row(parent: Node, node_name: String, caption: String) -> HBoxContainer:
	var margin := MarginContainer.new()
	margin.name = node_name
	margin.custom_minimum_size.y = 64
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	parent.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)
	var label := GameTheme.label(row, caption, 16)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


## 原生单行输入提供闪烁光标、剪贴板与水平滚动，右对齐不会随编辑状态改变。
func _make_field(parent: Node, node_name: String, editable: bool) -> LineEdit:
	var field := LineEdit.new()
	field.name = node_name
	field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	field.editable = editable
	field.selecting_enabled = true
	field.custom_minimum_size = Vector2(180, 36)
	field.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.size_flags_stretch_ratio = 1.5
	GameTheme.font_size(field, "font_size", 16)
	for state in ["normal", "read_only"]:
		var surface := GameTheme.box(Color.TRANSPARENT, Color.TRANSPARENT, 8)
		surface.set_content_margin_all(2)
		field.add_theme_stylebox_override(state, surface)
	field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	parent.add_child(field)
	return field


## 只读 UID 以单项玻璃菜单替代系统编辑菜单，鼠标与键盘都可打开。
func _on_uid_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_uid_field.accept_event()
		_uid_menu.popup_at(_uid_field, _uid_field.get_global_transform() * event.position)
	elif event is InputEventKey and event.pressed and (event.keycode == KEY_MENU or (event.keycode == KEY_F10 and event.shift_pressed)):
		_uid_field.accept_event()
		_uid_menu.popup_at(_uid_field, _uid_field.get_global_rect().end)


## 菜单始终复制当前完整 UID，不依赖只读输入框中的局部选区。
func _copy_uid() -> void:
	if profile != null:
		DisplayServer.clipboard_set(profile.get_uid())


## 统计值不受翻译器重写，数字与时间直接来自当前档案快照。
func _make_value(parent: Node, node_name: String) -> Label:
	var value := GameTheme.label(parent, "—", 16)
	value.name = node_name
	value.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.custom_minimum_size.x = 100
	return value


## 分隔线与组左右留白相同，整个灰卡保持连续圆角。
func _add_divider(parent: Node) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	parent.add_child(margin)
	var line := ColorRect.new()
	line.color = Color("D0D5DD")
	line.custom_minimum_size.y = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(line)
	return margin


## 资料与统计之间保留明显分组间隔，溢出仍由原生纵向滚动管理。
func _add_section_gap() -> void:
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(gap)


## 键入与粘贴都经过模型同一字符规则，不允许 emoji 或私用字符进入草稿。
func _on_username_changed(text: String) -> void:
	if _syncing:
		return
	var clean := PlayerProfileStore.sanitize_username(text)
	if clean != text:
		var old_caret := _username_field.caret_column
		var clean_prefix := PlayerProfileStore.sanitize_username(text.left(old_caret))
		_syncing = true
		_username_field.text = clean
		_username_field.caret_column = clean_prefix.length()
		_syncing = false
	_username_dirty = true


## 回车提交当前名字，仍由同一函数处理失焦与页面返回。
func _on_username_submitted(_text: String) -> void:
	commit_username()


## 名字仅在提交时写盘，失败保留输入与错误，成功回填默认 Player 或已保存值。
func commit_username() -> bool:
	if not is_instance_valid(_username_field) or profile == null or _committing:
		return true
	if not _username_dirty:
		return true
	_committing = true
	var result := profile.set_username(_username_field.text)
	_committing = false
	_last_result = result
	if result.is_ok():
		_username_dirty = false
		_syncing = true
		_username_field.text = profile.get_username()
		_syncing = false
	_sync_controls()
	return result.is_ok()


## 删除按钮只发出意图，不在面板内部直接清空档案或关卡。
func _request_reset() -> void:
	# 删除后名字也会清空，受损档案导致名字写入失败时仍允许用户主动重置。
	commit_username()
	reset_requested.emit()


## 外壳提供载入、重置或写盘结果，失败原因留在页内并能跟随语言切换。
func show_result(result: DataResult) -> void:
	_last_result = result
	if result.is_ok():
		_username_dirty = false
	_sync_controls()


## 档案更新不覆盖正在键入的名字，UID 与统计始终刷新到最新持久值。
func _sync_controls() -> void:
	if not is_instance_valid(_username_field):
		return
	_syncing = true
	if not _username_dirty or _committing:
		_username_field.text = profile.get_username()
	_uid_field.text = profile.get_uid()
	var stats := profile.get_statistics()
	_hint_value.text = str(stats.get("code_hint_uses", 0))
	_play_time_value.text = tr("%s小时") % ("%.1f" % (float(stats.get("play_seconds", 0.0)) / 3600.0))
	_mystery_value.text = str(stats.get("shark_best_score", 0))
	# 发现状态属于本机档案，首次更新和页面重建均同步隐藏行及其前分隔线。
	_mystery_row.visible = bool(stats.get("shark_discovered", false))
	_mystery_divider.visible = _mystery_row.visible
	var successes := int(stats.get("successes", 0))
	var rate := profile.get_weighted_pass_rate()
	_rate_value.text = (("%.1f" % (rate * 100.0)).trim_suffix(".0") + "%") if rate >= 0.0 else "—"
	_fastest_value.text = _format_duration(float(stats.get("fastest_seconds", -1.0))) if successes > 0 else "—"
	_longest_value.text = _format_duration(float(stats.get("longest_seconds", -1.0))) if successes > 0 else "—"
	_status.visible = _last_result != null and not _last_result.is_ok()
	_status.text = GameI18n.translate_errors(_last_result.errors) if _status.visible else ""
	_syncing = false
	_layout_card.call_deferred()


## 耗时按真实秒数显示，尚无成功记录使用横线，不伪造零秒通关。
func _format_duration(seconds: float) -> String:
	if seconds < 0.0:
		return "—"
	var whole := maxi(0, ceili(seconds))
	if whole < 60:
		return tr("%d秒") % whole
	if whole < 3600:
		return tr("%d分%d秒") % [whole / 60, whole % 60]
	return tr("%d小时%d分%d秒") % [whole / 3600, (whole % 3600) / 60, whole % 60]


## 页面边界来自外层白卡，正文与现有设置页保持同样的居中列和滚动淡出。
func _layout_card() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_card) or size.x <= 0 or size.y <= 0:
		return
	var inside_card := is_instance_valid(card_boundary)
	if inside_card:
		var bounds := get_global_transform().affine_inverse() * card_boundary.get_global_rect()
		_card.position = bounds.position
		_card.size = bounds.size
	else:
		var top_y := top_boundary.get_global_rect().end.y if is_instance_valid(top_boundary) else global_position.y
		var offset_y := minf(0.0, top_y - global_position.y)
		_card.position = Vector2(0, offset_y)
		_card.size = Vector2(size.x, maxf(0.0, size.y - offset_y))
	var content_scale := SettingsContentFade.CONTENT_SCALE
	var top_padding := SettingsContentFade.CARD_CONTENT_TOP_PADDING if inside_card else int(TOP_FADE_WIDTH) + CONTENT_TOP_GAP
	_scroll_content.add_theme_constant_override("margin_top", ceili(top_padding / content_scale))
	_scroll_content.add_theme_constant_override("margin_bottom", ceili((TOP_FADE_WIDTH + CONTENT_TOP_GAP) / content_scale))
	var scroll_rect := SettingsContentFade.content_rect(_card, 620.0, _column.get_combined_minimum_size().x, navigation_title)
	_scroll.position = scroll_rect.position
	_scroll.size = Vector2(scroll_rect.size.x, maxf(0.0, scroll_rect.size.y - (0 if inside_card else CONTENT_TOP_GAP))) / content_scale
	var visible_rect := _scroll.get_global_rect()
	_content_fade.set_fade(visible_rect.position.y, TOP_FADE_WIDTH * absf(get_global_transform().get_scale().y), get_viewport().get_visible_rect().size.y, visible_rect.end.y)


## 原生跟随焦点完成后避开导航与渐隐带，键盘编辑时完整显示正在操作的控件。
func _on_content_focus_changed(control: Control) -> void:
	if _keyboard_focus and is_instance_valid(control) and _column.is_ancestor_of(control):
		_reveal_focused_control.call_deferred(control)


## 只为当前页面真实焦点滚动，不改变弹窗焦点或无关页面的视点。
func _reveal_focused_control(control: Control) -> void:
	if not _keyboard_focus or not is_instance_valid(control) or not control.has_focus() or not is_visible_in_tree():
		return
	var visible_rect := _scroll.get_global_rect()
	var top_inset := SettingsContentFade.CARD_FOCUS_TOP_INSET if is_instance_valid(card_boundary) else TOP_FADE_WIDTH + 8
	var layout_scale := absf(get_global_transform().get_scale().y)
	var top := visible_rect.position.y + top_inset * layout_scale
	var bottom := visible_rect.end.y - (TOP_FADE_WIDTH + 8) * layout_scale
	var focused_rect := control.get_global_rect()
	var scroll_scale := absf(_scroll.get_global_transform().get_scale().y)
	if focused_rect.position.y < top:
		_scroll.scroll_vertical -= ceili((top - focused_rect.position.y) / scroll_scale)
	elif focused_rect.end.y > bottom:
		_scroll.scroll_vertical += ceili((focused_rect.end.y - bottom) / scroll_scale)


## 空白处点击真正释放输入焦点；删除按钮的蓝边仅在键盘导航时出现。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_delete_button):
		return
	if event is InputEventMouseButton and event.pressed:
		_keyboard_focus = false
		var focused := get_viewport().gui_get_focus_owner()
		if is_instance_valid(focused) and _column.is_ancestor_of(focused):
			if not focused.get_global_rect().has_point(event.position):
				focused.release_focus()
	elif event is InputEventKey and event.pressed:
		_keyboard_focus = true
	else:
		return
	_delete_button.add_theme_stylebox_override("focus", GameTheme.box(Color.TRANSPARENT, Color("A7CDFF"), 14) if _keyboard_focus else StyleBoxEmpty.new())


## 动态语言与画布缩放只更新显示，玩家姓名不会被自动翻译。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_node_ready() and _scroll != null:
		_layout_card.call_deferred()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready() and _status != null:
		_sync_controls()
