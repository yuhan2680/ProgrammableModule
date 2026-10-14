extends "res://tests/windows_menu_card_runner.gd"
## 原生选择菜单的透明合成、超长滚动和真实键盘回归；GPU 另外验证确实模糊了背景纹理。

var _blur_checked := false


## 单独提供测试套件标记，清理隔离目录与恢复音频语言仍沿用父回归的收尾。
func _finish() -> void:
	if not _finished:
		print("SETTINGS_OPTION_GLASS_TESTS: %d checks, %d failures" % [_checks, _failures])
	super._finish()


## 通过正式设置面板覆盖常见宽屏和两个非整数手动字号，数据始终写入独占测试目录。
func _run() -> void:
	_temporary = "user://tests/settings_option_glass_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_original_locale = TranslationServer.get_locale()
	var master := AudioServer.get_bus_index("Master")
	_original_volume = AudioServer.get_bus_volume_db(master)
	_original_mute = AudioServer.is_bus_mute(master)
	root.gui_embed_subwindows = true
	create_timer(90.0).timeout.connect(_timeout)
	await _create_game()
	_set_platform("Windows")
	await _settle(12)
	await _open_settings()
	if "--language-only" in OS.get_cmdline_user_args():
		_game.settings.set_window_resolution("1024x640")
		_game.settings.set_ui_scale(200)
		await _settle(12)
		await _check_option("LanguageOption", "1024x640_200")
		await _check_constrained_language()
		await _capture_spanish_settings()
		await _dispose_game()
		_finish()
		return
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]:
		if not _native_size_available(dimensions):
			continue
		_game.settings.set_window_resolution("%dx%d" % [dimensions.x, dimensions.y])
		for percentage: int in [110, 125]:
			_game.settings.set_ui_scale(percentage)
			await _settle(18)
			await _check_option("WindowResolutionOption", "%dx%d_%d" % [dimensions.x, dimensions.y, percentage])
			await _check_option("UiScaleOption", "%dx%d_%d" % [dimensions.x, dimensions.y, percentage])
			await _check_option("LanguageOption", "%dx%d_%d" % [dimensions.x, dimensions.y, percentage])
	_game.settings.set_window_resolution("1024x640")
	_game.settings.set_ui_scale(200)
	await _settle(18)
	await _check_option("WindowResolutionOption", "1024x640_200_scroll")
	await _check_option("LanguageOption", "1024x640_200")
	await _check_constrained_language()
	await _check_hide_and_selection()
	await _dispose_game()
	_finish()


## 真实空格打开菜单，方向键及 Esc 沿用 Godot 路由，不通过内部方法假造选择。
func _check_option(node_name: String, context: String) -> void:
	var option := _game.settings_panel.find_child(node_name, true, false) as OptionButton
	var popup := option.get_popup()
	var original_font_size := popup.get_theme_font_size("font_size")
	# 紧凑菜单可容纳更多选项；溢出夹具主动放大字号，不依赖某个主题留白恰好产生滚动。
	if context.ends_with("_scroll"):
		popup.add_theme_font_size_override("font_size", maxi(original_font_size, 48))
	var source_scroll: ScrollContainer = _game.settings_panel.get("_scroll")
	source_scroll.ensure_control_visible(option)
	await _settle(8)
	option.grab_focus()
	await _key(root, KEY_SPACE)
	await _settle(12)
	var glass: CanvasLayer = _game.settings_panel.get_node(node_name + "Glass")
	if not _check(popup.visible and glass.visible, "原生菜单和玻璃同时出现 " + node_name + " " + context):
		return
	var source_style := popup.get_theme_stylebox("panel") as StyleBoxFlat
	_check(popup.is_embedded() and popup.transparent_bg and source_style != null and source_style.bg_color.a == 0.0, "原生窗口只绘制文字和交互，不遮挡主视口玻璃 " + context)
	_check(glass.layer == 1025 and (glass.get("_native_content") as TextureRect).texture == popup.get_texture(), "玻璃在打开前捕获完整页面，再以原生输出像素绘制前景 " + context)
	var popup_to_root := root.get_screen_transform().affine_inverse() * popup.get_screen_transform()
	var source_bounds := popup_to_root * popup.get_visible_rect()
	_check(root.get_visible_rect().grow(1).encloses(source_bounds), "菜单客户区在实际视口边界内且可滚动 " + context)
	var surface := glass.get("_glass") as ColorRect
	var material := surface.material as ShaderMaterial
	_check((material.get_shader_parameter("panel_size") as Vector2).is_equal_approx(source_bounds.size), "玻璃使用原生弹层的真实客户区尺寸 " + context)
	_check(surface.mouse_filter == Control.MOUSE_FILTER_IGNORE and surface.focus_mode == Control.FOCUS_NONE, "玻璃不拦截鼠标和键盘焦点 " + context)
	var bar := _find_vscroll(popup)
	_check(bar != null, "原生弹层保留纵向滚动控件 " + context)
	if bar != null:
		var track := bar.get_theme_stylebox("scroll") as StyleBoxFlat
		var thumb := bar.get_theme_stylebox("grabber") as StyleBoxFlat
		_check(track != null and thumb != null and track.bg_color.a == 0.0 and thumb.bg_color.a <= 0.201, "下滑条使用透明轨道和低对比滑块 " + context)
		if node_name == "LanguageOption":
			_check(not bar.visible, "自然高度四语言菜单没有舍入产生的虚假滚动条 " + context + " overflow=" + str(bar.max_value - bar.page))
		if context.ends_with("_scroll"):
			_check(bar.visible and bar.max_value > bar.page, "小窗口大字号真实产生可操作下滑条 " + context)
			for step in popup.item_count:
				if popup.get_focused_item() == popup.item_count - 1:
					break
				await _key(root, KEY_DOWN)
			_check(popup.get_focused_item() == popup.item_count - 1 and bar.value > 0.0, "方向键聚焦末项并推动原生滚动条 " + context)
			var bottom_scroll := bar.value
			for step in popup.item_count:
				if popup.get_focused_item() == 0:
					break
				await _key(root, KEY_UP)
			_check(popup.get_focused_item() == 0 and bar.value < bottom_scroll and bar.value < bar.page * 0.1, "方向键返回首项并滚回菜单顶部 " + context)
	print("设置玻璃菜单诊断：%s，选项比例 %s，弹窗大小 %s，客户区 %s，屏幕变换 %s，玻璃 %s。" % [context, option.get_global_transform().get_scale(), popup.size, popup.get_visible_rect(), popup.get_screen_transform(), source_bounds])
	await _capture("resolution_glass_" + context + "_" + node_name)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var screenshot := root.get_texture().get_image()
		var image_scale := Vector2(screenshot.get_size()) / root.get_visible_rect().size
		var sample := source_bounds.get_center()
		sample.x = source_bounds.position.x + 8.0 * popup_to_root.get_scale().abs().x
		var pixel := screenshot.get_pixelv(Vector2i(sample * image_scale))
		var source_image := popup.get_texture().get_image()
		print("菜单 GPU 透明诊断：%s transparent=%s bg=%s raw=%s composed=%s texture=%s" % [context, popup.transparent, popup.transparent_bg, source_image.get_pixel(8, source_image.get_height() / 2), pixel, source_image.get_size()])
		_check(pixel.r > 0.60 and pixel.g > 0.60 and pixel.b > 0.60, "每次重新打开都保留亮色玻璃，不出现黑色不透明底板 " + context + " " + str(pixel))
		var backdrop: ImageTexture = glass.get("_backdrop")
		_check(backdrop != null and backdrop.get_width() < screenshot.get_width() and backdrop.get_height() <= screenshot.get_height() and glass.get("_pending_backdrop") == null, "只保留菜单区域的裁剪背景，不常驻整屏副本 " + context)
		for corner: Vector2 in [source_bounds.position + Vector2.ONE * 2.0, source_bounds.end - Vector2.ONE * 2.0]:
			var corner_pixel := screenshot.get_pixelv(Vector2i(corner * image_scale))
			var background_position := Vector2i((corner / root.get_visible_rect().size - (material.get_shader_parameter("backdrop_origin") as Vector2)) / (material.get_shader_parameter("backdrop_extent") as Vector2) * Vector2(backdrop.get_size()))
			var background_pixel := backdrop.get_image().get_pixelv(background_position.clamp(Vector2i.ZERO, Vector2i(backdrop.get_size()) - Vector2i.ONE))
			_check(Vector3(corner_pixel.r - background_pixel.r, corner_pixel.g - background_pixel.g, corner_pixel.b - background_pixel.b).length() < 0.15, "圆角外恢复真实背景，没有黑色直角 " + context)
	if not _blur_checked and DisplayServer.get_name() != "headless":
		await _check_real_blur(popup, glass, source_bounds)
		_blur_checked = true
	var original := option.selected
	await _key(root, KEY_DOWN)
	var focused := popup.get_focused_item()
	_check(focused >= 0 and not popup.is_item_disabled(focused), "方向键保留原生禁用项跳过规则 " + context)
	await _key(root, KEY_ESCAPE)
	await _settle(8)
	_check(not popup.visible and not glass.visible and option.selected == original, "Esc 同时关闭原生弹层和玻璃且不改保存选择 " + context)
	_check(glass.get("_backdrop") == null and glass.get("_pending_backdrop") == null and (glass.get("_native_content") as TextureRect).texture == null, "关闭后释放背景捕获和前景引用 " + context)
	if context.ends_with("_scroll"):
		popup.add_theme_font_size_override("font_size", original_font_size)


## 人为限制真实四语言菜单高度，验证原生滚动条的最终位置、活动显示和静止隐藏。
func _check_constrained_language() -> void:
	var option := _game.settings_panel.find_child("LanguageOption", true, false) as OptionButton
	var source_scroll: ScrollContainer = _game.settings_panel.get("_scroll")
	source_scroll.ensure_control_visible(option)
	await _settle(8)
	option.grab_focus()
	await _key(root, KEY_SPACE)
	var popup := option.get_popup()
	# 原生 PopupMenu 的最小高度由可用父视口裁剪；大字夹具让四项真实超过可用高度。
	var original_font := popup.get_theme_font_size("font_size")
	popup.add_theme_font_size_override("font_size", 160)
	popup.reset_size()
	await _settle(12)
	_game.settings_panel._fit_language_popup()
	await _settle(6)
	var bar := _find_vscroll(popup)
	var scroll := bar.get_parent() as ScrollContainer
	_check(bar.visible and bar.max_value > bar.page, "受限高度语言菜单保留全部四项与真实溢出")
	_check(popup.item_count == 4 and popup.get_item_text(2) == "Español", "受限高度菜单不移除语言选项")
	var native_right := float(popup.size.x) / popup.content_scale_factor
	print("受限菜单诊断：popup=%s visible=%s content=%s scale=%s scroll=%s bar=%s actualright=%s" % [popup.size, popup.get_visible_rect(), popup.get_contents_minimum_size(), popup.content_scale_factor, scroll.get_global_rect(), bar.get_global_rect(), native_right - bar.get_global_rect().end.x])
	_check(absf(native_right - bar.get_global_rect().end.x - 8.0) < 1.1, "受限语言菜单实际条右边缘留白为 8 像素")
	_check(absf(bar.position.y - 6.0) < 0.1 and absf(bar.size.y - scroll.size.y + 12.0) < 0.1, "受限语言菜单的原生条两端缩短且未挤压内容页数")
	for step in popup.item_count:
		if popup.get_focused_item() == popup.item_count - 1:
			break
		await _key(root, KEY_DOWN)
	_check(bar.value > 0.0 and bar.modulate.a > 0.99, "语言菜单键盘滚动显示原生条")
	await _capture("language_glass_constrained_active")
	await create_timer(1.1).timeout
	_check(is_zero_approx(bar.modulate.a), "语言菜单停止滚动后隐藏原生条")
	await _capture("language_glass_constrained_idle")
	await _key(root, KEY_ESCAPE)
	_check(not popup.visible, "受限语言菜单可用 Esc 关闭")
	popup.add_theme_font_size_override("font_size", original_font)


## 可选证据覆盖西语实际设置的两个常用画幅，截图始终来自真实 GPU。
func _capture_spanish_settings() -> void:
	_game.settings.set_language("es")
	_game.settings.set_ui_scale(100)
	_game.settings.set_window_resolution("1280x800")
	await _settle(15)
	var scroll: ScrollContainer = _game.settings_panel.get("_scroll")
	scroll.scroll_vertical = 0
	await _settle(8)
	await _capture("settings_spanish_1280x800_top")
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	await _settle(8)
	await _capture("settings_spanish_1280x800_bottom")
	root.size = Vector2i(1000, 740)
	await _settle(15)
	scroll.scroll_vertical = 0
	await _settle(8)
	await _capture("settings_spanish_1000x740_top")
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	await _settle(8)
	await _capture("settings_spanish_1000x740_bottom")


## 面板隐藏不会留下透明原生窗口；重新打开再回车选择仍只提交一次正常偏好。
func _check_hide_and_selection() -> void:
	var panel := _game.settings_panel
	var option := panel.find_child("UiScaleOption", true, false) as OptionButton
	var popup := option.get_popup()
	var glass: CanvasLayer = panel.get_node("UiScaleOptionGlass")
	option.grab_focus()
	await _key(root, KEY_SPACE)
	await _settle(8)
	_check(popup.visible and glass.visible, "隐藏面板前原生菜单与玻璃均已打开")
	panel.hide()
	await _settle(8)
	_check(not popup.visible and not glass.visible and glass.get("_backdrop") == null, "隐藏设置面板关闭原生窗口并释放玻璃捕获")
	panel.show()
	await _settle(8)
	option.grab_focus()
	await _key(root, KEY_SPACE)
	await _settle(8)
	await _key(root, KEY_UP)
	var index := popup.get_focused_item()
	var selected := popup.get_item_id(index)
	await _key(root, KEY_ENTER)
	await _settle(12)
	_check(_game.settings.ui_scale == selected and not popup.visible and not glass.visible, "原生回车提交被聚焦的百分比并同步关闭玻璃")
	var stored := GameSettings.new(_game.settings_path)
	_check(stored.load_settings().is_ok() and stored.ui_scale == selected, "原生百分比选择正常写入隔离设置文件")


## 内部滚动条只用于观察样式，不替代原生滚动或尺寸计算。
func _find_vscroll(node: Node) -> VScrollBar:
	if node is VScrollBar:
		return node
	for child in node.get_children(true):
		var result := _find_vscroll(child)
		if result != null:
			return result
	return null


## 彩色高频纹理置于玻璃之前，像素方差降低证明实时模糊，单纯半透明填充无法通过。
func _check_real_blur(popup: PopupMenu, glass: CanvasLayer, bounds: Rect2) -> void:
	var fixture_layer := CanvasLayer.new()
	fixture_layer.layer = 1022
	root.add_child(fixture_layer)
	var fixture := ColorRect.new()
	fixture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fixture.size = root.get_visible_rect().size
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; render_mode unshaded; void fragment() { float stripe = step(0.5, fract(FRAGCOORD.y / 4.0)); COLOR = vec4(stripe, 0.0, 1.0 - stripe, 1.0); }"
	var fixture_material := ShaderMaterial.new()
	fixture_material.shader = shader
	fixture.material = fixture_material
	fixture_layer.add_child(fixture)
	# 先关闭并绘制纯背景，再用真实键盘重新打开，让生产捕获取得测试纹理。
	popup.hide()
	await _settle(8)
	(popup.get_parent() as OptionButton).grab_focus()
	await _key(root, KEY_SPACE)
	await _settle(8)
	await RenderingServer.frame_post_draw
	var blurred := root.get_texture().get_image()
	glass.hide()
	await _settle(4)
	await RenderingServer.frame_post_draw
	var direct := root.get_texture().get_image()
	glass.show()
	var image_scale := Vector2(blurred.get_size()) / root.get_visible_rect().size
	var popup_scale := (root.get_screen_transform().affine_inverse() * popup.get_screen_transform()).get_scale().abs().x
	var x := roundi((bounds.position.x + 8.0 * popup_scale) * image_scale.x)
	var start := roundi((bounds.get_center().y - 32.0 * popup_scale) * image_scale.y)
	var end := roundi((bounds.get_center().y + 32.0 * popup_scale) * image_scale.y)
	var blurred_min := 1.0
	var blurred_max := 0.0
	var direct_min := 1.0
	var direct_max := 0.0
	var green := 0.0
	for y in range(start, end):
		var softened := blurred.get_pixel(x, y)
		var raw := direct.get_pixel(x, y)
		blurred_min = minf(blurred_min, softened.r)
		blurred_max = maxf(blurred_max, softened.r)
		direct_min = minf(direct_min, raw.r)
		direct_max = maxf(direct_max, raw.r)
		green += softened.g
	var contrast := blurred_max - blurred_min
	var raw_contrast := direct_max - direct_min
	var mean_green := green / maxf(1.0, end - start)
	print("设置菜单真实模糊像素：原对比 %.3f，模糊后 %.3f，绿色均值 %.3f。" % [raw_contrast, contrast, mean_green])
	_check(raw_contrast > 0.5 and contrast < raw_contrast * 0.16 and mean_green > 0.60 and mean_green < 0.85, "实际 GPU 毛玻璃模糊实际页面背景而非不透明白底或仅降低 alpha，原对比 %.3f，模糊后 %.3f，绿色均值 %.3f" % [raw_contrast, contrast, mean_green])
	fixture_layer.queue_free()
	await _settle(6)
