class_name SharkCaveGame
extends Control
## 独立彩蛋界面：低分辨率洞穴仅负责呈现，模拟状态全部交给 SharkCaveRun。

signal exit_requested
signal run_finished(score: int)

enum Screen { INTRO, PLAYING, PAUSED, GAME_OVER }

const INK := Color("101d33")
const TEXT := Color("eef8f4")
const MUTED := Color("9dbbc8")
const MINT := Color("91dfc5")
const ACTION_DIAMETER := 56.0
const INTRO_DURATION := 4.0
const DEPARTURE_DURATION := 1.15
const FAILURE_BLUR_DURATION := 0.65

var run := SharkCaveRun.new()
var screen_state := Screen.INTRO
var best_score := 0
var _up_pressed := false
var _down_pressed := false
var _world: SubViewport
var _world_image: TextureRect
var _failure_blur_bounds: Control
var _failure_blur: MainMenuBackground
var _canvas: SharkCaveCanvas
var _hud: Control
var _score: Label
var _result: Label
var _run_actions: VBoxContainer
var _action_title: Label
var _run_buttons: HBoxContainer
var _exit_run: Button
var _veil: ColorRect
var _resume: Button
var _retry: Button
var _clock := 0.0
var _intro_elapsed := 0.0
var _intro_focus_paused := false
var _layout_pending := false
var _death_elapsed := 0.0
var _blur_elapsed := 0.0
var _departure_frame_presented := false
var _death_blur_started := false


## 创建独立视口，直接播放海底游入洞穴的开场，交接前不推进模拟或计分。
func _ready() -> void:
	name = "SharkCaveGame"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = GameTheme.create_theme()
	_build_world()
	_build_hud()
	_build_panels()
	resized.connect(_queue_layout)
	visibility_changed.connect(_on_visibility_changed)
	begin_intro()
	_layout()


## 等比放大像素画布，外围沿用洞壁深蓝色，宽屏与小窗口均无黑色边带。
func _build_world() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "SharkBackdrop"
	backdrop.color = INK
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world = SubViewport.new()
	_world.name = "SharkWorldViewport"
	_world.size = Vector2i(640, 360)
	_world.disable_3d = true
	_world.handle_input_locally = false
	_world.gui_disable_input = true
	_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_world)
	_canvas = SharkCaveCanvas.new()
	_canvas.run = run
	_world.add_child(_canvas)
	_world_image = TextureRect.new()
	_world_image.name = "SharkWorldImage"
	_world_image.texture = _world.get_texture()
	_world_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_world_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_world_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_world_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world_image)
	_world_image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 独立缓存只取像素世界纹理；分数、失败原因和按钮位于此层之后，始终清晰。
	_failure_blur_bounds = Control.new()
	_failure_blur_bounds.name = "SharkFailureBlurBounds"
	_failure_blur_bounds.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_failure_blur_bounds)
	_failure_blur = MainMenuBackground.new()
	_failure_blur.name = "SharkFailureBlur"
	_failure_blur_bounds.add_child(_failure_blur)
	_failure_blur.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_failure_blur.set_texture(_world.get_texture())
	_failure_blur.modulate.a = 0.0
	_veil = ColorRect.new()
	_veil.name = "SharkPauseVeil"
	_veil.color = Color(0.025, 0.065, 0.12, 0.20)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_veil)
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## HUD 只保留左上角当前得分，最高纪录移到中央成绩区，暂停统一使用 Esc。
func _build_hud() -> void:
	_hud = Control.new()
	_hud.name = "SharkHUD"
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var score_box := VBoxContainer.new()
	score_box.position = Vector2(32, 24)
	score_box.size = Vector2(180, 76)
	score_box.add_theme_constant_override("separation", 0)
	_hud.add_child(score_box)
	_make_label(score_box, "SharkScoreHeading", "得分", 13, MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	_score = _make_label(score_box, "SharkScore", "00000", 32, TEXT, HORIZONTAL_ALIGNMENT_LEFT)
	_score.add_theme_font_override("font", GameTheme.code_font())



## 暂停和失败直接在场景中央显示圆形操作；开场不再创建需要点击的菜单。
func _build_panels() -> void:
	_run_actions = VBoxContainer.new()
	_run_actions.name = "SharkRunActions"
	_run_actions.size.x = 360
	_run_actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_run_actions.add_theme_constant_override("separation", 14)
	_run_actions.minimum_size_changed.connect(_queue_layout)
	add_child(_run_actions)
	_action_title = _make_label(_run_actions, "SharkRunStatus", "已暂停", 28)
	_result = _make_label(_run_actions, "SharkGameOverScore", "", 14, MINT)
	_run_buttons = HBoxContainer.new()
	_run_buttons.name = "SharkRunButtons"
	_run_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_run_buttons.add_theme_constant_override("separation", 16)
	_run_actions.add_child(_run_buttons)
	_exit_run = _make_run_button("SharkExitRunButton", "退出", "res://assets/minigame/action_exit.svg", _exit_game)
	_resume = _make_run_button("SharkResumeButton", "开始", "res://assets/minigame/action_start.svg", _resume_run)
	_retry = _make_run_button("SharkRetryButton", "重新开始", "res://assets/minigame/action_restart.svg", start_run)


## 圆形操作仅显示居中 SVG；名称由已有毛玻璃悬停提示呈现，保留键盘焦点与禁用语义。
func _make_run_button(node_name: String, caption: String, icon_path: String, callback: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.tooltip_text = caption
	button.icon = load(icon_path)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.add_theme_constant_override("icon_max_width", 24)
	button.add_theme_constant_override("h_separation", 0)
	button.custom_minimum_size = Vector2.ONE * ACTION_DIAMETER
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.pressed.connect(callback)
	_run_buttons.add_child(button)
	_set_run_primary(button, false)
	return button


## 正常、悬停、按下和焦点均保持同心正圆；白色源图按状态着色，蓝色主操作仍清晰。
func _set_run_primary(button: Button, primary: bool) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var fill := GameTheme.ACCENT if primary else GameTheme.SURFACE
		if state in ["hover", "hover_pressed"]:
			fill = Color("1686FF") if primary else Color("E4EEFC")
		elif state == "pressed":
			fill = Color("0065D4") if primary else Color("D8E3F1")
		elif state == "disabled":
			fill = Color("E7ECF3")
		var border := Color("A7CDFF") if state == "focus" else Color.TRANSPARENT
		var style := GameTheme.box(Color.TRANSPARENT if state == "focus" else fill, border, int(ACTION_DIAMETER * 0.5))
		style.set_content_margin_all(0)
		button.add_theme_stylebox_override(state, style)
	for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(color_name, Color.WHITE if primary else GameTheme.TEXT)
	button.add_theme_color_override("icon_disabled_color", Color("9AA5B5"))


## 文本默认允许本地化；自动换行确保中英标题和说明都不会超出面板。
func _make_label(parent: Node, node_name: String, value: String, font_size: int, color: Color = TEXT, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


## 合并容器与文本触发的最小尺寸变化，待换行测量完成后再统一调整高度。
func _queue_layout() -> void:
	if _layout_pending or not is_inside_tree():
		return
	_layout_pending = true
	_layout.call_deferred()


## 操作组始终居中，模糊层严格贴合等比像素世界的显示范围。
func _layout() -> void:
	_layout_pending = false
	if not is_instance_valid(_run_actions):
		return
	_run_actions.size = Vector2(minf(360, size.x - 48), _run_actions.get_combined_minimum_size().y)
	_run_actions.position = ((size - _run_actions.size) * 0.5).round()
	var world_scale := minf(size.x / SharkCaveRun.WORLD_SIZE.x, size.y / SharkCaveRun.WORLD_SIZE.y)
	_failure_blur_bounds.size = SharkCaveRun.WORLD_SIZE * world_scale
	_failure_blur_bounds.position = (size - _failure_blur_bounds.size) * 0.5


## 重试直接从安全洞穴开始新局；独立种子只供回归，不重复首次入场动画。
func start_run(seed_value: int = -1) -> void:
	# 暂停后主动重开也保留已取得的新高，避免清空当前分数后遗漏纪录。
	best_score = maxi(best_score, run.score)
	_reset_intro()
	_clear_input()
	_reset_failure_transition()
	run.start(seed_value)
	screen_state = Screen.PLAYING
	_clock = 0.0
	_sync_state()
	get_viewport().gui_release_focus()


## 准备真实随机世界但冻结模拟，四秒入场只改变画布坐标，不消耗分数或随机序列。
func begin_intro(seed_value: int = -1) -> void:
	_clear_input()
	_reset_failure_transition()
	_reset_intro()
	run.start(seed_value)
	run.pause()
	screen_state = Screen.INTRO
	_clock = 0.0
	_canvas.intro_active = true
	_canvas.menu_mode = false
	_sync_state()
	get_viewport().gui_release_focus()


## 开场仅在窗口有焦点时推进；终点与模型原点完全一致，再开启玩家控制。
func _advance_intro(delta: float) -> void:
	if _intro_focus_paused:
		return
	_intro_elapsed = minf(_intro_elapsed + maxf(delta, 0.0), INTRO_DURATION)
	_clock = _intro_elapsed
	_canvas.intro_time = _intro_elapsed
	_canvas.intro_progress = _intro_elapsed / INTRO_DURATION
	if _intro_elapsed >= INTRO_DURATION:
		_clear_input()
		_canvas.intro_active = false
		run.resume()
		screen_state = Screen.PLAYING
		_sync_state()
		get_viewport().gui_release_focus()


## 清除入场表现与焦点挂起状态，重试和退出不能遗留半程洞口或失效输入。
func _reset_intro() -> void:
	_intro_elapsed = 0.0
	_intro_focus_paused = false
	if is_instance_valid(_canvas):
		_canvas.intro_active = false
		_canvas.intro_progress = 0.0
		_canvas.intro_time = 0.0


## 外壳从玩家档案提供最高分；界面接收展示值，不直接读写存档。
func set_best_score(value: int) -> void:
	best_score = maxi(0, value)
	_update_scores()


## 开场推进装饰时钟，游玩才推进模型；暂停与失败均保持已冻结的世界快照。
func _process(delta: float) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_canvas):
		return
	if screen_state == Screen.PLAYING:
		var axis := float(int(_down_pressed) - int(_up_pressed))
		run.advance(delta, axis)
		_clock += delta
		if run.state == SharkCaveRun.State.OVER:
			_finish_run()
		_update_scores()
	elif screen_state == Screen.INTRO:
		_advance_intro(delta)
	elif screen_state == Screen.GAME_OVER:
		_advance_failure_transition(delta)
	_canvas.decorative_time = _clock
	_canvas.queue_redraw()


## 失败只推进离场表现：真实洞壁、章鱼、分数和输入保持终局快照，鱼先游出再淡入高斯背景。
func _advance_failure_transition(delta: float) -> void:
	_death_elapsed += maxf(delta, 0.0)
	_canvas.departure_progress = clampf(_death_elapsed / DEPARTURE_DURATION, 0.0, 1.0)
	_canvas.departure_time = minf(_death_elapsed, DEPARTURE_DURATION)
	if _canvas.departure_progress < 1.0:
		return
	# 先呈现一帧没有鲨鱼的世界，再启动离屏采样，避免模糊缓存留下鲨鱼残影。
	if not _departure_frame_presented:
		_departure_frame_presented = true
		return
	if not _death_blur_started:
		_death_blur_started = true
		_failure_blur.set_active(true)
	if _failure_blur.is_render_ready():
		_blur_elapsed = minf(_blur_elapsed + maxf(delta, 0.0), FAILURE_BLUR_DURATION)
		_failure_blur.modulate.a = smoothstep(0.0, FAILURE_BLUR_DURATION, _blur_elapsed)


## 重试、开场和退出均清理未完成的视觉过渡，防止上一局的鲨鱼位置或模糊缓存污染新局。
func _reset_failure_transition() -> void:
	_death_elapsed = 0.0
	_blur_elapsed = 0.0
	_departure_frame_presented = false
	_death_blur_started = false
	if is_instance_valid(_canvas):
		_canvas.departure_active = false
		_canvas.departure_progress = 0.0
		_canvas.departure_time = 0.0
	if is_instance_valid(_failure_blur):
		_failure_blur.set_active(false)
		_failure_blur.modulate.a = 0.0
		# ViewportTexture 本身不换资源，需显式使静态背景缓存失效，下一局才会重新采样。
		_failure_blur.set_texture(null)
		_failure_blur.set_texture(_world.get_texture())


## 上下输入维护完整按下与释放状态；Esc 切换游玩与暂停，撞壁后保持操作栏等待明确选择。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey:
		return
	var key := event as InputEventKey
	var code := key.physical_keycode if key.physical_keycode != 0 else key.keycode
	if code == KEY_ESCAPE and key.pressed and not key.echo:
		# 退出信号可以立即移除此节点，必须在回调之前消费事件，不能再查询退树后的视口。
		get_viewport().set_input_as_handled()
		match screen_state:
			Screen.PLAYING:
				_pause_run()
			Screen.PAUSED:
				_resume_run()
			Screen.GAME_OVER:
				pass
			Screen.INTRO:
				_exit_game()
		return
	if screen_state != Screen.PLAYING:
		return
	# 开场期间按住的键不能在交接后靠系统重复事件悄悄生效，需要重新按下。
	if key.pressed and key.echo:
		return
	if code == KEY_UP:
		_up_pressed = key.pressed
	elif code == KEY_DOWN:
		_down_pressed = key.pressed
	else:
		return
	get_viewport().set_input_as_handled()


## 失焦时开场冻结、游玩暂停；开场恢复焦点后续播，正式游玩仍需主动继续。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_intro_focus_paused = false
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_clear_input()
		if screen_state == Screen.INTRO:
			_intro_focus_paused = true
		elif screen_state == Screen.PLAYING:
			_pause_run()


## 隐藏页面停止输入与像素视口更新，并冻结未结束的运行。
func _on_visibility_changed() -> void:
	var active := is_visible_in_tree()
	set_process(active)
	set_process_input(active)
	if is_instance_valid(_world):
		_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if is_instance_valid(_failure_blur):
		_failure_blur.set_active(active and _death_blur_started)
	if not active:
		_clear_input()
		if screen_state == Screen.PLAYING:
			_pause_run()


## 暂停不修改分数或洞穴随机状态，继续时从同一位置恢复。
func _pause_run() -> void:
	if screen_state != Screen.PLAYING:
		return
	_clear_input()
	run.pause()
	screen_state = Screen.PAUSED
	_sync_state()
	if _resume.is_visible_in_tree():
		_resume.grab_focus()


## 继续前再次清空输入，确保切换窗口期间释放的按键不会继续推动鲨鱼。
func _resume_run() -> void:
	if screen_state != Screen.PAUSED:
		return
	_clear_input()
	run.resume()
	screen_state = Screen.PLAYING
	_sync_state()
	get_viewport().gui_release_focus()


## 一次碰撞只结算一次，外壳接收分数后保存玩家的最高纪录。
func _finish_run() -> void:
	_clear_input()
	_reset_failure_transition()
	screen_state = Screen.GAME_OVER
	_canvas.departure_active = true
	best_score = maxi(best_score, run.score)
	_sync_state()
	_retry.grab_focus()
	run_finished.emit(run.score)


## 退出请求由外壳恢复设置页面；本视图先停止操作，避免信号处理期间继续推进。
func _exit_game() -> void:
	_reset_intro()
	_clear_input()
	_reset_failure_transition()
	run.pause()
	set_process(false)
	set_process_input(false)
	exit_requested.emit()


## 按当前状态更新面板和 HUD，只允许一个操作层接收输入。
func _sync_state() -> void:
	if not is_instance_valid(_run_actions):
		return
	_run_actions.visible = screen_state == Screen.PAUSED or screen_state == Screen.GAME_OVER
	var failure_text := "墨汁遮挡了视线" if run.fail_reason == "ink" else "碰到洞壁了"
	if run.fail_reason == "tuna":
		failure_text = "撞到逆行金枪鱼了"
	_action_title.text = tr(failure_text) if screen_state == Screen.GAME_OVER else tr("已暂停")
	_resume.disabled = screen_state != Screen.PAUSED
	_set_run_primary(_resume, screen_state == Screen.PAUSED)
	_set_run_primary(_retry, screen_state == Screen.GAME_OVER)
	_hud.visible = screen_state != Screen.INTRO
	_veil.visible = screen_state == Screen.PAUSED or screen_state == Screen.GAME_OVER
	_canvas.menu_mode = false
	_update_scores()
	_queue_layout()
	_canvas.queue_redraw()


## 动态分数先翻译模板后格式化，数字不会进入翻译字典或主游戏统计。
func _update_scores() -> void:
	if not is_instance_valid(_score):
		return
	_score.text = "%05d" % run.score
	_result.text = (tr("本次得分：%d") % run.score) + "\n" + (tr("最高纪录得分：%d") % best_score)


## 释放输入是页面切换、失焦和暂停的共用清理，避免上下键残留。
func _clear_input() -> void:
	_up_pressed = false
	_down_pressed = false
