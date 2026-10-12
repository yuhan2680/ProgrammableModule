extends SceneTree
## 两个真实滚动页面的渐隐、导航和生命周期回归；GPU 双色底验证实际透明度。

const BLUE := Color(0.12, 0.32, 0.65)
const GREEN := Color(0.10, 0.65, 0.20)
var _checks := 0
var _failures := 0
var _captures := ""
var _temporary := ""
var _game: GameShell
var _background: ColorRect


## 只有实际显示驱动和显式截图目录才读取像素，headless 仅校验交互布局。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_captures = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 正式外壳使用独占存档，分别滚动选关和编辑器指令集，最后释放合成精度。
func _run() -> void:
	Engine.max_fps = 120
	root.size = Vector2i(1280, 800)
	root.content_scale_size = root.size
	root.gui_embed_subwindows = true
	var original_transparent := root.transparent_bg
	_temporary = "user://tests/scroll_content_fade_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.settings_path = _temporary.path_join("settings.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	_game.system_sound_preview_handler = func() -> void: pass
	root.add_child(_game)
	await _settle()
	for child in _game.get_children():
		if child is ColorRect:
			_background = child
			break
	await _levels()
	await _commands()
	_game.queue_free()
	await _settle()
	_check(root.transparent_bg == original_transparent, "销毁页面后恢复原视口透明状态")
	_remove_tree(_temporary)
	print("滚动内容渐隐回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 向上滚动真实图标，确认标题仍独立、搜索可用、焦点滚入清晰区域。
func _levels() -> void:
	_game._tutorials_expanded = true
	_game._show_level_page()
	await _settle()
	var scroll := _game._body.find_child("LevelScroll", true, false) as ScrollContainer
	var icon := _game._body.find_child("LevelButton_0", true, false) as Button
	var header := _game._level_header
	_check(scroll.get_global_rect().position.y >= header.get_global_rect().end.y, "上方可视区延伸仍避开固定导航")
	var initial_position := icon.global_position
	var initial_limit := scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page
	scroll.scroll_vertical = roundi(icon.global_position.y - scroll.global_position.y + 8)
	await _settle()
	_check(scroll.scroll_vertical > 48 and icon.global_position.y < scroll.global_position.y, "真实关卡图标进入顶部边缘")
	await _capture("levels-top-fade")
	if _gpu_enabled():
		var pair := await _pair()
		_check_ramp(pair, Vector2i(roundi(icon.get_global_rect().get_center().x), ceili(scroll.global_position.y)), 1, "关卡顶部")
	icon.grab_focus()
	await _settle()
	_check(icon.get_global_rect().position.y >= scroll.global_position.y + 48 or scroll.scroll_vertical == 0, "键盘聚焦图标完整滚入可读区域")
	header.set_search_open(true, false)
	header._search_input.text = "不存在的关卡"
	_game._on_level_search_changed(header._search_input.text)
	await _settle()
	_check(scroll.scroll_vertical == 0 and _game._search_empty.visible and header._search_input.has_focus(), "渐隐不影响顶部搜索焦点与空结果")
	header.set_search_open(false, false)
	await _settle()
	_check(icon.global_position.is_equal_approx(initial_position) and is_equal_approx(scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page, initial_limit), "清空搜索恢复首行位置与原滚动范围")
	await _capture("levels-at-start")


## 在管理窗口两端滚动真实指令卡，焦点和开关继续使用原编辑器事务。
func _commands() -> void:
	_game._open_editor()
	await _settle()
	var editor := _game._editor
	var document := editor.editor_document.document.to_dict()
	var menu := editor._command_menu
	var properties_scroll := editor.find_child("MapEditorPropertiesScroll", true, false) as ScrollContainer
	properties_scroll.ensure_control_visible(editor._command_button)
	await _settle()
	menu.show_commands(editor._command_button, editor.registry, editor.editor_document.get_enabled_commands(editor.registry))
	await _settle()
	if menu._tween != null:
		menu._tween.kill()
	menu._panel.scale = Vector2.ONE
	menu._panel.modulate.a = 1.0
	await _settle()
	var scroll := menu._scroll
	var top_card := menu._cards[0]
	scroll.scroll_vertical = roundi(top_card.global_position.y - scroll.global_position.y + 8)
	await _settle()
	_check(menu.header.get_global_rect().end.y < scroll.get_global_rect().position.y, "指令管理标题与滚动正文独立")
	await _capture("commands-top-fade")
	if _gpu_enabled():
		var pair := await _pair(menu)
		_check_ramp(pair, Vector2i(roundi(top_card.get_global_rect().end.x - 110), ceili(scroll.global_position.y)), 1, "指令顶部", 0.75)
	var bottom_card := menu._cards[8]
	scroll.scroll_vertical += roundi(bottom_card.get_global_rect().end.y - scroll.get_global_rect().end.y - 8)
	await _settle()
	await _capture("commands-bottom-fade")
	if _gpu_enabled():
		var pair := await _pair(menu)
		_check_ramp(pair, Vector2i(roundi(bottom_card.get_global_rect().end.x - 110), floori(scroll.get_global_rect().end.y)), -1, "指令底部", 0.75)
	scroll.scroll_vertical = 0
	await _settle()
	menu.select_section("movement")
	await _settle()
	_check(scroll.get_v_scroll_bar().max_value <= scroll.get_v_scroll_bar().page + 1 and menu._command_switches.size() == 2, "短指令分类无需滚动且两条指令完整显示")
	_check(editor.editor_document.document.to_dict() == document, "浏览及滚动指令不改变地图内容")
	menu.close_menu(false)
	_check(not menu.is_open(), "管理窗口照常关闭")


## 正常画面直接来自根视口；验证探针结束后恢复正式颜色与玻璃。
func _capture(filename: String) -> Image:
	if not _gpu_enabled():
		return null
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_captures)
	_check(picture.save_png(_captures.path_join(filename + ".png")) == OK, "保存真实 GPU 画面 " + filename)
	return picture


## 只改变实际父底色，不修改内容、遮罩和滚动位置，反推最终卡片透明度。
func _pair(menu: CommandRestrictionMenu = null) -> Array[Image]:
	var background := _background.color
	var surface: StyleBoxFlat
	var original_surface: StyleBox
	if menu != null:
		original_surface = menu._panel.get_theme_stylebox("panel")
		surface = original_surface.duplicate() as StyleBoxFlat
		menu._panel.add_theme_stylebox_override("panel", surface)
		menu._glass.hide()
	var pair: Array[Image] = []
	for color: Color in [BLUE, GREEN]:
		_background.color = color
		if surface != null:
			surface.bg_color = color
		await _settle()
		await RenderingServer.frame_post_draw
		pair.append(root.get_texture().get_image())
	_background.color = background
	if menu != null:
		menu._panel.add_theme_stylebox_override("panel", original_surface)
		menu._glass.show()
	await _settle()
	return pair


## 从像素差判断连续透明过渡，实色覆盖和突然裁切无法满足这些观察值。
func _check_ramp(pair: Array[Image], edge: Vector2i, direction: int, caption: String, alpha: float = 1.0) -> void:
	var profile: Array[float] = []
	for distance in range(1, 49):
		var point := edge + Vector2i(0, direction * distance)
		var a := pair[0].get_pixelv(point)
		var b := pair[1].get_pixelv(point)
		profile.append(1.0 - Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() / Vector3(BLUE.r - GREEN.r, BLUE.g - GREEN.g, BLUE.b - GREEN.b).length())
	var biggest_jump := 0.0
	var biggest_index := 0
	for index in range(1, profile.size()):
		if absf(profile[index] - profile[index - 1]) > biggest_jump:
			biggest_jump = absf(profile[index] - profile[index - 1])
			biggest_index = index
	_check(profile[0] < 0.04 and absf(profile[23] - alpha * 0.5) < 0.05 and profile[47] > alpha - 0.05, caption + "由透明经过半透明恢复原卡片")
	_check(biggest_jump < 0.06, caption + "连续渐隐无裁切跳变")
	print("GPU %s alpha(1/24/48)=%.3f/%.3f/%.3f 最大阶差 %.4f 位置 %d %.4f -> %.4f" % [caption, profile[0], profile[23], profile[47], biggest_jump, biggest_index, profile[maxi(0, biggest_index - 1)], profile[biggest_index]])


## 让容器布局、滚动和焦点请求依次完成，不使用阻塞等待。
func _settle() -> void:
	for frame in 12:
		await process_frame


## 缺少显示驱动时不读取空白图像。
func _gpu_enabled() -> bool:
	return not _captures.is_empty() and DisplayServer.get_name() != "headless"


## 汇总独立断言，失败时保留日志供复查。
func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


## 删除本轮独占存档，正式玩家文件始终不参与验证。
func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		directory.remove(filename)
	for child in directory.get_directories():
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(path)
