extends SceneTree
## 真实设置音量控件回归：输入、持久化和玻璃过渡共用正式页面，截图仅来自 GPU 视口。

var _checks := 0
var _failures := 0
var _temporary := ""
var _capture_directory := ""
var _game: GameShell
var _finished := false
var _original_locale := ""
var _original_volume := 0.0
var _original_mute := false
var _original_transparent := false


## 可选输出实际渲染画面；不在无显示驱动下生成替代截图。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_capture_directory = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 独占用户目录运行正式页面，并在结束时恢复全局语言、总线和视口状态。
func _run() -> void:
	_temporary = "user://tests/settings_audio_glass_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	_original_transparent = root.transparent_bg
	root.gui_embed_subwindows = true
	create_timer(75.0).timeout.connect(_timeout)
	_game = load("res://scenes/game.tscn").instantiate() as GameShell
	_game.system_sound_preview_handler = func() -> void: pass
	_game.settings_path = _temporary.path_join("settings.json")
	_game.profile_path = _temporary.path_join("profile.json")
	_game.drafts_directory = _temporary.path_join("solutions")
	_game.user_levels_directory = _temporary.path_join("levels")
	root.add_child(_game)
	await _settle()
	var button := _game.find_child("SettingsButton", true, false) as Control
	await _click(button.get_global_rect().get_center())
	await create_timer(0.55).timeout
	if not _check(_game.page == GameShell.Page.SETTINGS and _game.settings_panel != null, "实际菜单输入进入设置页面"):
		await _finish()
		return
	_game.settings.set_volume(0.42)
	_game.settings.set_system_sound_volume(0.64)
	await _settle()
	_check_speakers()
	for prefix: String in ["Volume", "SystemSound"]:
		var slider := _game.settings_panel.find_child(prefix + "Slider", true, false) as HSlider
		if not _check(slider != null and slider.has_method("get_thumb_rect"), "音量保留原生 HSlider 并提供实际旋钮几何 " + prefix):
			continue
		await _check_pointer(slider, prefix)
		await _check_elastic_drag(slider, prefix)
		await _check_keyboard_and_wheel(slider, prefix)
		await _check_cancellation(slider, prefix)
	_check_persistence("基准布局")
	await _check_overlay_scroll()
	await _check_scaled_layouts()
	await _finish()


## 高清资源与逻辑占位分开验证，避免直接放大图标后破坏两行布局。
func _check_speakers() -> void:
	for controls: HBoxContainer in [_game.settings_panel._audio_controls, _game.settings_panel._system_sound_controls]:
		var count := 0
		for child: Node in controls.get_children():
			if not child is TextureRect:
				continue
			count += 1
			var icon := child as TextureRect
			var pixels := icon.texture.get_image()
			_check(icon.texture.get_size() == Vector2(96, 96) and pixels.has_mipmaps(), "扬声器使用 96 像素 SVG 栅格和 mipmap " + controls.name)
			_check(icon.custom_minimum_size == Vector2(22, 22) and icon.mouse_filter == Control.MOUSE_FILTER_IGNORE, "高清扬声器保持 22 像素占位且不拦截滑条输入 " + controls.name)
		_check(count == 2, "每行均使用低/高音量两个清晰图标 " + controls.name)


## 悬停不激活玻璃，按住和跨轨道拖动才过渡；松开仍沿用同一原生范围和信号。
func _check_pointer(slider: HSlider, prefix: String) -> void:
	await _reveal(slider)
	var original := slider.value
	var sibling := _other_slider(slider)
	var other_value := sibling.value
	_check(_amount(slider) < 0.01, "打开和外部同步不产生玻璃状态 " + prefix)
	var initial_thumb := _thumb(slider)
	_check(_valid_thumb(slider, initial_thumb), "初始旋钮在原生滑条范围内且垂直居中 " + prefix)
	var center := slider.get_global_transform_with_canvas() * initial_thumb.get_center()
	_motion(center)
	await create_timer(0.30).timeout
	_check(_amount(slider) < 0.01 and is_equal_approx(slider.value, original), "单纯悬停不改变音量或玻璃状态 " + prefix)
	var idle := await _capture(prefix + "_idle")
	_mouse_button(center, MOUSE_BUTTON_LEFT, true)
	await create_timer(0.25).timeout
	_check(_amount(slider) > 0.70, "按住原生旋钮呈现交互玻璃 " + prefix)
	_check(is_equal_approx(slider.value, original), "按住同一旋钮不跳变音量 " + prefix)
	var held_thumb := _thumb(slider)
	_check(held_thumb.size.x / initial_thumb.size.x > held_thumb.size.y / initial_thumb.size.y + 0.15, "按住横向拉长明显多于纵向，避免等比放大 " + prefix)
	_check(held_thumb.get_center().distance_to(initial_thumb.get_center()) < 0.1, "按住拉伸锚定同一原生中心 " + prefix)
	var active := await _capture(prefix + "_pressed")
	if idle != null and active != null:
		_check_changed_pixels(slider, idle, active, prefix)
	var target := slider.get_global_transform_with_canvas() * Vector2(slider.size.x * 0.73, slider.size.y * 0.5)
	_motion(target, target - center, MOUSE_BUTTON_MASK_LEFT)
	await create_timer(0.10).timeout
	_check(slider.value > slider.max_value * 0.6 and slider.value < slider.max_value * 0.9 and not is_equal_approx(slider.value, original), "真实拖动修改原生范围值 " + prefix)
	_check(is_equal_approx(slider.value / slider.max_value, _stored_volume(slider)), "拖动音量即时同步正式设置模型 " + prefix)
	_check(is_equal_approx(sibling.value, other_value) and _amount(sibling) < 0.01, "另一个音量及玻璃状态独立 " + prefix)
	_check(_thumb(slider).get_center().x > initial_thumb.get_center().x, "视觉旋钮随真实音量向右移动 " + prefix)
	_check(_valid_thumb(slider, _thumb(slider)), "交互旋钮留在原生滑条边界内 " + prefix)
	await _capture(prefix + "_dragged")
	_mouse_button(target, MOUSE_BUTTON_LEFT, false)
	await process_frame
	_check(_amount(slider) > 0.05, "松开后保留短暂平滑退场而不是骤然切换 " + prefix)
	await create_timer(0.65).timeout
	_check(_amount(slider) < 0.01 and _thumb(slider).size.is_equal_approx(initial_thumb.size), "松开后恢复白色静止旋钮及原有尺寸 " + prefix)
	_check_persistence(prefix + " 拖动")
	# 两端直接点轨道仍使用原生精确端值，验证自绘不会缩短操作范围。
	for fraction: float in [0.0, 1.0]:
		var edge := slider.get_global_transform_with_canvas() * Vector2(1.0 + (slider.size.x - 2.0) * fraction, slider.size.y * 0.5)
		await _click(edge)
		_check(is_equal_approx(slider.value, lerpf(slider.min_value, slider.max_value, fraction)), "点击轨道端点可达精确最小或最大音量 " + prefix + " " + str(fraction))
		_check(_valid_thumb(slider, _thumb(slider)), "端点旋钮保持完整可见 " + prefix + " " + str(fraction))
	_game.settings.set_volume(0.42) if prefix == "Volume" else _game.settings.set_system_sound_volume(0.64)
	await create_timer(0.65).timeout


## 连续实际指针运动产生额外拉伸，停止移动保持按住，释放回到原始尺寸。
func _check_elastic_drag(slider: HSlider, prefix: String) -> void:
	await _reveal(slider)
	var resting_size := _thumb(slider).size
	var point := slider.get_global_transform_with_canvas() * _thumb(slider).get_center()
	_mouse_button(point, MOUSE_BUTTON_LEFT, true)
	await create_timer(0.32).timeout
	var held_size := _thumb(slider).size
	var peak_width := held_size.x
	for index in 9:
		var next := slider.get_global_transform_with_canvas() * Vector2(slider.size.x * (0.25 + 0.055 * index), slider.size.y * 0.5)
		_motion(next, next - point, MOUSE_BUTTON_MASK_LEFT)
		point = next
		await create_timer(0.025).timeout
		peak_width = maxf(peak_width, _thumb(slider).size.x)
		_check(_valid_thumb(slider, _thumb(slider)), "连续拖动拉伸不覆盖音量图标 " + prefix + " " + str(index))
	_check(peak_width > held_size.x + 0.8, "持续拖动在按住轮廓之外产生速度拉伸 " + prefix)
	await _capture(prefix + "_elastic_motion")
	await create_timer(0.60).timeout
	_check(_thumb(slider).size.distance_to(held_size) < 0.15 and _amount(slider) > 0.99, "停止移动时弹性回到按住轮廓并保持玻璃 " + prefix)
	_mouse_button(point, MOUSE_BUTTON_LEFT, false)
	await create_timer(0.65).timeout
	_check(_thumb(slider).size.is_equal_approx(resting_size), "拖动结束轮廓准确恢复而非累积变形 " + prefix)


## 键盘与滚轮不依赖鼠标拖动标志，短暂反馈后自动恢复且保存各自偏好。
func _check_keyboard_and_wheel(slider: HSlider, prefix: String) -> void:
	await _reveal(slider)
	slider.grab_focus()
	var before := slider.value
	_key(KEY_RIGHT)
	await create_timer(0.10).timeout
	_check(slider.value > before and _amount(slider) > 0.1, "原生方向键调节并给出玻璃反馈 " + prefix)
	await create_timer(0.70).timeout
	_check(_amount(slider) < 0.01, "键盘停止后玻璃反馈自动消退 " + prefix)
	before = slider.value
	await _click(slider.get_global_rect().get_center(), MOUSE_BUTTON_WHEEL_UP)
	await create_timer(0.10).timeout
	_check(slider.value > before and _amount(slider) > 0.1, "原生滚轮调节并给出玻璃反馈 " + prefix)
	await create_timer(0.70).timeout
	_check(_amount(slider) < 0.01, "滚轮停止后玻璃反馈自动消退 " + prefix)
	_check_persistence(prefix + " 键盘与滚轮")


## 隐藏、失焦和不可编辑都不能留下玻璃拖动态；恢复显示不重放旧交互。
func _check_cancellation(slider: HSlider, prefix: String) -> void:
	await _reveal(slider)
	var center := slider.get_global_transform_with_canvas() * _thumb(slider).get_center()
	_mouse_button(center, MOUSE_BUTTON_LEFT, true)
	await create_timer(0.20).timeout
	_game.settings_panel.hide()
	_check(_amount(slider) < 0.01, "隐藏页面立即清除交互玻璃 " + prefix)
	_mouse_button(center, MOUSE_BUTTON_LEFT, false)
	_game.settings_panel.show()
	await create_timer(0.30).timeout
	_check(_amount(slider) < 0.01, "重新显示页面不恢复过期拖动 " + prefix)
	slider.grab_focus()
	_key(KEY_LEFT)
	await create_timer(0.08).timeout
	slider.release_focus()
	await process_frame
	_check(_amount(slider) < 0.01, "键盘焦点离开立即清除旧交互 " + prefix)
	slider.editable = false
	var before := slider.value
	await _click(slider.get_global_rect().get_center())
	await create_timer(0.20).timeout
	_check(is_equal_approx(slider.value, before) and _amount(slider) < 0.01, "不可编辑滑条拒绝改值和玻璃交互 " + prefix)
	slider.editable = true
	await _settle()


## 按住状态随真实滚动移动到双端边缘；额外留白仅让首行也能到达下边缘。
func _check_overlay_scroll() -> void:
	var panel := _game.settings_panel
	var slider := panel._volume_slider
	var scroll := panel._scroll
	var gutter := panel._scroll_content
	var overlay := panel.get_node("AudioGlassOverlay") as Control
	var layer := overlay.get_node("VolumeSliderGlassLayer") as Control
	var surface := layer.get_node("LiquidGlassThumb") as Control
	var original_top := gutter.get_theme_constant("margin_top")
	var original_scroll := scroll.scroll_vertical
	gutter.add_theme_constant_override("margin_top", original_top + roundi(scroll.size.y))
	await _settle()
	await _reveal(slider)
	var press_point := slider.get_global_transform_with_canvas() * _thumb(slider).get_center()
	_mouse_button(press_point, MOUSE_BUTTON_LEFT, true)
	await create_timer(0.23).timeout
	var held_value := slider.value
	for edge: String in ["top", "bottom"]:
		var strengths: Dictionary = {}
		var boundary := scroll.get_global_rect().position.y if edge == "top" else scroll.get_global_rect().end.y
		for distance: float in [80.0, 12.0, -30.0]:
			var wanted_y := boundary + distance if edge == "top" else boundary - distance
			var actual_center := slider.get_global_transform_with_canvas() * _thumb(slider).get_center()
			var scale_y := scroll.get_global_transform_with_canvas().get_scale().y
			scroll.scroll_vertical += roundi((actual_center.y - wanted_y) / scale_y)
			await _settle()
			actual_center = slider.get_global_transform_with_canvas() * _thumb(slider).get_center()
			var context := edge + " " + str(distance)
			_check(absf(actual_center.y - wanted_y) <= 1.0, "真实滚动将按住旋钮移动到预期边缘位置 " + context)
			_check(surface.get_global_rect().get_center().distance_to(actual_center) <= 1.0 and layer.get_global_transform_with_canvas().get_scale().is_equal_approx(slider.get_global_transform_with_canvas().get_scale()), "外部玻璃与原生旋钮的中心及缩放同步 " + context)
			_check(_amount(slider) > 0.99 and is_equal_approx(slider.value, held_value), "滚动过程中保持按住状态且不更改音量 " + context)
			if not _capture_directory.is_empty() and DisplayServer.get_name() != "headless":
				var with_glass := await _capture("scroll_" + edge + "_" + str(int(distance)) + "_glass")
				overlay.hide()
				var without_glass := await _capture("scroll_" + edge + "_" + str(int(distance)) + "_background")
				overlay.show()
				strengths[distance] = _glass_pixel_contribution(surface, with_glass, without_glass)
				_check(_outside_glass_contribution(surface, scroll, with_glass, without_glass) < 0.006, "GPU 玻璃在真实滚动范围外没有残留像素 " + context)
		if not strengths.is_empty():
			var clear := float(strengths[80.0])
			var fading := float(strengths[12.0])
			var outside := float(strengths[-30.0])
			_check(clear > 0.008 and fading > clear * 0.05 and fading < clear * 0.90 and outside < 0.006, "GPU 双端渐隐保留中间透明层次，越界贡献为零 " + edge)
			print("玻璃滚动像素 %s：清晰 %.5f，渐隐 %.5f，界外 %.5f。" % [edge, clear, fading, outside])
	_mouse_button(press_point, MOUSE_BUTTON_LEFT, false)
	gutter.add_theme_constant_override("margin_top", original_top)
	scroll.scroll_vertical = original_scroll
	await create_timer(0.65).timeout
	await _settle()
	_check(_amount(slider) < 0.01, "跨边缘滚动后的释放仍恢复空闲旋钮")


## 比较有无纯装饰 overlay 的同一画面，量化玻璃真实合成贡献而非 Shader 内部参数。
func _glass_pixel_contribution(surface: Control, active: Image, background: Image) -> float:
	var rectangle := root.get_final_transform() * surface.get_global_rect()
	var pixels := Rect2i(rectangle).intersection(Rect2i(Vector2i.ZERO, active.get_size()))
	var total := 0.0
	for y in range(pixels.position.y, pixels.end.y):
		for x in range(pixels.position.x, pixels.end.x):
			var a := active.get_pixel(x, y)
			var b := background.get_pixel(x, y)
			total += Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
	return total / maxf(pixels.get_area(), 1.0)


## 越界部分逐像素比较，不让浮层正确移动但忘记裁剪也通过回归。
func _outside_glass_contribution(surface: Control, scroll: ScrollContainer, active: Image, background: Image) -> float:
	var rectangle := root.get_final_transform() * surface.get_global_rect()
	var pixels := Rect2i(rectangle).intersection(Rect2i(Vector2i.ZERO, active.get_size()))
	var clipping := root.get_final_transform() * scroll.get_global_rect()
	var maximum := 0.0
	for y in range(pixels.position.y, pixels.end.y):
		for x in range(pixels.position.x, pixels.end.x):
			if clipping.has_point(Vector2(x + 0.5, y + 0.5)):
				continue
			var a := active.get_pixel(x, y)
			var b := background.get_pixel(x, y)
			maximum = maxf(maximum, Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length())
	return maximum


## 用生产窗口策略注入 Windows 屏幕画像；真实 GPU 只选宿主可容纳的尺寸。
func _check_scaled_layouts() -> void:
	_game.window_controller.platform_name = "Windows"
	_game.window_controller.screen_size_provider = func() -> Vector2i: return Vector2i(3840, 2160)
	_game.window_controller._refresh_screen()
	_game.window_controller._on_settings_changed()
	for size_name: String in ["1280x800", "3840x2160"]:
		if DisplayServer.get_name() != "headless" and not _game.window_controller.available_resolutions.has(size_name):
			print("SKIP 音量玻璃 GPU 尺寸 " + size_name + "：宿主可用客户区不足；headless 保留几何覆盖。")
			continue
		_game.settings.set_window_resolution(size_name)
		_game.settings.set_ui_scale(200)
		_game.settings.set_language("ja")
		await _settle(14)
		var panel := _game.settings_panel
		for slider: HSlider in [panel._volume_slider, panel._system_sound_slider]:
			await _reveal(slider)
			_check(_valid_thumb(slider, _thumb(slider)), "大字号与高分辨率的旋钮仍完整且居中 " + size_name + " " + slider.name)
			_check(root.get_visible_rect().grow(1).encloses(slider.get_global_rect()), "高分辨率音量滑条可滚动到完整可见 " + size_name + " " + slider.name)
			var point := slider.get_global_transform_with_canvas() * Vector2(slider.size.x * 0.38, slider.size.y * 0.5)
			_mouse_button(point, MOUSE_BUTTON_LEFT, true)
			await create_timer(0.22).timeout
			_check(slider.value > slider.max_value * 0.25 and slider.value < slider.max_value * 0.50 and _amount(slider) > 0.7, "放大父容器后真实指针命中与玻璃同步 " + size_name + " " + slider.name)
			await _capture(size_name + "_200_" + slider.name)
			_mouse_button(point, MOUSE_BUTTON_LEFT, false)
			await create_timer(0.65).timeout
			_check(_amount(slider) < 0.01, "高分辨率释放后状态无泄漏 " + size_name + " " + slider.name)
		_check(absf(panel._volume_slider.global_position.x - panel._system_sound_slider.global_position.x) < 1.0 and absf(panel._volume_slider.size.x - panel._system_sound_slider.size.x) < 1.0, "两种音量在日语大字号下仍对齐 " + size_name)
	_check_persistence("高分辨率")


## 每次重新从磁盘载入设置，而不是只验证控件与内存同步。
func _check_persistence(context: String) -> void:
	var restored := GameSettings.new(_game.settings_path)
	_check(restored.load_settings().is_ok() and is_equal_approx(restored.volume, _game.settings.volume) and is_equal_approx(restored.system_sound_volume, _game.settings.system_sound_volume), "两项音量独立持久化 " + context)


## 将当前滑条滚入正文内部清晰区域；不改变布局或替换正式控件。
func _reveal(slider: HSlider) -> void:
	var scroll := _game.settings_panel._scroll
	var desired := scroll.global_position.y + scroll.get_global_rect().size.y * 0.48
	var scale_y := scroll.get_global_transform_with_canvas().get_scale().y
	scroll.scroll_vertical += roundi((slider.get_global_rect().get_center().y - desired) / scale_y)
	await _settle()


## 只读取公开的视觉比例，不依赖实现内部 Tween 或 Shader 参数命名。
func _amount(slider: HSlider) -> float:
	return float(slider.get("interaction_amount"))


## 自绘旋钮几何使用控件本地坐标，缩放与鼠标投影统一由 Godot 变换处理。
func _thumb(slider: HSlider) -> Rect2:
	return slider.call("get_thumb_rect") as Rect2


## 拉伸可越过原生轨道，但必须保留行内留白且不能覆盖左右音量图标。
func _valid_thumb(slider: HSlider, thumb: Rect2) -> bool:
	if not thumb.has_area() or absf(thumb.get_center().y - slider.size.y * 0.5) >= 1.0:
		return false
	var bounds := slider.get_global_transform_with_canvas() * thumb
	var row := slider.get_parent() as Control
	if not row.get_global_rect().grow(1.0).encloses(bounds):
		return false
	for child: Node in row.get_children():
		if child is TextureRect and bounds.intersects(child.get_global_rect()):
			return false
	return true


## 按名称读取对应模型，防止两种音量被错误绑定到同一字段。
func _stored_volume(slider: HSlider) -> float:
	return _game.settings.volume if slider.name == "VolumeSlider" else _game.settings.system_sound_volume


## 返回另一行控件供独立性断言，仍保留 HSlider 原生接口。
func _other_slider(slider: HSlider) -> HSlider:
	return _game.settings_panel._system_sound_slider if slider.name == "VolumeSlider" else _game.settings_panel._volume_slider


## GPU 只比较同值按下前后的真实旋钮区域，排除空白截图和仅改变内部状态的伪实现。
func _check_changed_pixels(slider: HSlider, idle: Image, active: Image, context: String) -> void:
	var logical := slider.get_global_transform_with_canvas() * _thumb(slider)
	var physical := root.get_final_transform() * logical
	var bounds := Rect2i(physical.grow(2.0)).intersection(Rect2i(Vector2i.ZERO, active.get_size()))
	var changed := 0
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var a := idle.get_pixel(x, y)
			var b := active.get_pixel(x, y)
			if Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() > 0.035:
				changed += 1
	_check(changed > bounds.get_area() * 0.08, "GPU 按住状态实际改变旋钮像素 " + context + " changed=" + str(changed))


## 根视口分发原生鼠标运动，保证装饰层不能吞掉拖动命中。
func _motion(point: Vector2, relative: Vector2 = Vector2.ZERO, mask: MouseButtonMask = 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = mask
	root.push_input(event, true)


## 原生按键与释放分开，便于观察拖动中真实的视觉状态。
func _mouse_button(point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	root.push_input(event, true)


## 常规点击经完整运动、按下、释放序列进入原生控件。
func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	_motion(point)
	_mouse_button(point, button, true)
	_mouse_button(point, button, false)
	await _settle()


## 键盘事件从根视口进入当前焦点，不直接调用生产回调。
func _key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		root.push_input(event, true)


## 容器布局等待按帧进行，交互动画另用明确的墙钟等待。
func _settle(frames: int = 6) -> void:
	for frame in frames:
		await process_frame


## 截图必须等待真实绘制完成，输出到调用者明确指定的目录。
func _capture(filename: String) -> Image:
	if _capture_directory.is_empty() or DisplayServer.get_name() == "headless":
		return null
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_directory)
	_check(image.save_png(_capture_directory.path_join(filename + ".png")) == OK, "保存 GPU 画面 " + filename)
	return image


## 单条失败不截断其他输入路径，便于一次定位相互独立的回归。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition


## 异常等待也按失败退出，防止无头渲染无限挂起。
func _timeout() -> void:
	if not _finished:
		_check(false, "音量玻璃回归超时")
		await _finish()


## 清理仅覆盖本轮独占测试目录，不接触平台可见玩家目录。
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_game):
		_game.queue_free()
		await _settle()
	_check(root.transparent_bg == _original_transparent, "退出设置恢复原视口透明状态")
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), _original_volume)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), _original_mute)
	TranslationServer.set_locale(_original_locale)
	_remove_tree(_temporary)
	print("音量玻璃回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 递归清理调用者已创建的测试树，不扩大到用户目录其他内容。
func _remove_tree(path: String) -> void:
	for filename: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory: String in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)
