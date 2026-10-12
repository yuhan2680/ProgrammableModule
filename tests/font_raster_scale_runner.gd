extends SceneTree
## 验证真实字号、父级变换、合成层与原生弹层的字形缓存；GPU 证据不以属性值冒充清晰渲染。

var _checks := 0
var _failures := 0
var _captures := ""
var _scope: Control
var _viewport: SubViewport
var _card: Control
var _body: Control
var _scale: GameFontScale
var _labels: Array[Label] = []
var _baseline: Label
var _layer_label: Label
var _popup: PopupMenu


## 只保存用户指定的截图，不创建游戏设置、地图或通关记录。
func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			_captures = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()


## 各比例顺序作用于同一父卡片，特意不修改子标签的 scale，覆盖原生变换旧缓存问题。
func _run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 800)
	root.gui_embed_subwindows = true
	_build_fixture()
	await _settle()
	_check_source_fonts()
	for percentage in [110, 125]:
		_scale.set_percentage(percentage)
		_check(_labels[0].get_theme_font_size("font_size") == roundi(20 * percentage / 100.0), "百分比立即改变真实字号 " + str(percentage))
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_pre_draw
			await RenderingServer.frame_post_draw
			_check_font_cache(_card.scale.x * 0.8, roundi(20 * percentage / 100.0), "改档后首帧 " + str(percentage))
		for factor in [1.35, 1.8, 2.7]:
			_card.scale = Vector2.ONE * factor
			_layer_label.get_parent().scale = Vector2.ONE * factor
			_baseline.scale = Vector2.ONE * factor * 0.8
			_baseline.add_theme_font_size_override("font_size", roundi(20 * percentage / 100.0))
			await _settle()
			var context := "%.2f %d%%" % [factor, percentage]
			_check_geometry(factor, percentage, context)
			if DisplayServer.get_name() != "headless":
				await _check_glyph_raster(factor, percentage, context)
	await _check_registration()
	await _check_reuse()
	await _check_hidden_reveal()
	await _check_popup_font_raster()
	_scope.queue_free()
	_viewport.queue_free()
	await _settle()
	print("FONT_RASTER_SCALE_TESTS %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 左列沿用实际主题路径，右列显示未启用变换采样的原位图作为视觉参照。
func _build_fixture() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1600, 940)
	_viewport.gui_embed_subwindows = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var background := ColorRect.new()
	background.color = Color.WHITE
	background.size = Vector2(_viewport.size)
	_viewport.add_child(background)
	_scope = Control.new()
	_scope.theme = GameTheme.create_theme()
	_viewport.add_child(_scope)
	_card = Control.new()
	_card.position = Vector2(24, 90)
	_scope.add_child(_card)
	var group := AlphaCanvasGroup.new()
	_card.add_child(group)
	_body = Control.new()
	_body.scale = Vector2.ONE * 0.8
	# 与真实 SettingsPanel 一样在 CanvasGroup 后显式恢复主题，避免默认白字隐藏字体证据。
	_body.theme = _scope.theme
	group.add_child(_body)
	for index in 4:
		var label := GameTheme.label(_body, ["缩放与布局 125%", "Settings Window 125%", "main() 移动模块", "缺少必要的终点"][index], 20)
		label.position = Vector2(0, index * 65)
		if index == 2:
			label.add_theme_font_override("font", GameTheme.code_font())
		_labels.append(label)
	var layer := CanvasLayer.new()
	_scope.add_child(layer)
	var host := Control.new()
	host.position = Vector2(24, 705)
	layer.add_child(host)
	_layer_label = Label.new()
	_layer_label.text = "独立弹层 Settings"
	_layer_label.theme = _scope.theme
	host.add_child(_layer_label)
	_popup = PopupMenu.new()
	_popup.theme = _scope.theme
	_popup.add_item("1920 × 1080")
	_popup.add_item("2560 × 1440")
	_scope.add_child(_popup)
	_scale = GameFontScale.new()
	_scale.scope = _scope
	_scope.add_child(_scale)
	_baseline = Label.new()
	_baseline.text = "缩放与布局 125%"
	_baseline.position = Vector2(810, 90)
	_baseline.add_theme_font_override("font", GameTheme.body_font())
	_baseline.add_theme_color_override("font_color", GameTheme.TEXT)
	_viewport.add_child(_baseline)
	for column in 2:
		var heading := Label.new()
		heading.text = "按目标像素重新栅格化" if column == 0 else "参照：放大原字号位图"
		heading.position = Vector2(24 + column * 786, 20)
		heading.add_theme_font_override("font", GameTheme.body_font())
		heading.add_theme_font_size_override("font_size", 24)
		heading.add_theme_color_override("font_color", GameTheme.TEXT)
		_viewport.add_child(heading)


## 继续采用原字体的灰阶抗锯齿和 hinting；不强开存在中文重叠轮廓问题的 MSDF，也不固定超采样倍数。
func _check_source_fonts() -> void:
	for path in ["res://assets/fonts/NotoSansSC.ttf", "res://assets/fonts/JetBrainsMono.ttf"]:
		var font := load(path) as FontFile
		_check(not font.multichannel_signed_distance_field and is_zero_approx(font.oversampling), "字体保持原生动态缓存策略 " + path)
	_check(GameTheme.body_font().has_char("缩".unicode_at(0)) and GameTheme.body_font().has_char("S".unicode_at(0)), "中文与英语仍来自随项目打包的字体")
	_check(GameTheme.code_font().fallbacks[0] == GameTheme.body_font(), "等宽代码字体仍共享中文回退")


## 字体百分比不修改控件变换或字形度量，设置八成缩放与父卡片比例只由实际变换计算一次。
func _check_geometry(factor: float, percentage: int, context: String) -> void:
	for label in _labels:
		_check(label.scale == Vector2.ONE and label.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor * 0.8), "子标签保留一倍变换，继承 CanvasGroup 与八成正文 " + context)
		_check(label.get_theme_font_size("font_size") == roundi(20 * percentage / 100.0), "中文、英语与代码字号只乘手动百分比 " + context)
		if label.has_method("get_oversampling_with_scale"):
			_check(int(label.call("get_oversampling_with_scale")) == 2, "原生变换采样已启用 " + context)
	_check(_layer_label.get_global_transform().get_scale().is_equal_approx(Vector2.ONE * factor), "CanvasLayer 不重复继承卡片变换 " + context)
	if _layer_label.has_meta("ui_font_raster_scale"):
		_check((_layer_label.get_meta("ui_font_raster_scale") as Vector2).is_equal_approx(Vector2.ONE * factor), "独立弹层取得当前全局比例 " + context)


## 读取实际生成的字体像素缓存，并保存未重采样的 GPU 图像；能区别仅设置属性但仍使用旧纹理的情况。
func _check_glyph_raster(factor: float, percentage: int, context: String) -> void:
	await RenderingServer.frame_post_draw
	_check_font_cache(factor * 0.8, roundi(20 * percentage / 100.0), context)
	var image := _viewport.get_texture().get_image()
	_check(image != null and image.get_size() == _viewport.size, "GPU 输出保留原生像素尺寸 " + context)
	if image != null:
		for label in _labels:
			var area := Rect2i(Vector2i(label.get_global_position()), Vector2i(ceili(310 * factor * 0.8), ceili(40 * factor * 0.8)))
			_check(_has_visible_ink(image, area), "合成层内中文、英语与等宽字形实际可见 " + context + " " + label.text)
	if image != null and factor >= 1.8 and _labels[0].has_method("get_oversampling_with_scale"):
		var difference := _glyph_pixel_difference(image, _labels[0].get_global_position(), _baseline.position, Vector2i(ceili(240 * factor * 0.8), ceili(40 * factor * 0.8)))
		_check(difference > 0.01, "重新栅格化后的字形与旧位图放大具有实际像素差异 " + context)
	if image != null and not _captures.is_empty():
		DirAccess.make_dir_recursive_absolute(_captures)
		var path := _captures.path_join("font_raster_%.2f_%d.png" % [factor, percentage])
		_check(image.save_png(path) == OK, "保存 GPU 字体证据 " + context)


## 比较实际目标采样和生成纹理；旧版本缺少缓存详情 API 时仍执行排版与可见性检查。
func _check_font_cache(expected: float, font_size: int, context: String) -> void:
	var text_server := TextServerManager.get_primary_interface()
	if not _labels[0].has_method("get_oversampling_with_scale") or not text_server.has_method("font_get_size_cache_info"):
		return
	for font in [GameTheme.body_font(), GameTheme.code_font()]:
		var information: Array = text_server.call("font_get_size_cache_info", font.get_rids()[0])
		var matched := false
		for entry: Dictionary in information:
			var oversampling := float(entry.get("viewport_oversampling", 1.0))
			var target_size := font_size * oversampling
			if absf(oversampling - expected) <= 1.0 / 64.0 and absi((entry.get("size_px") as Vector2i).x - int(target_size)) <= 1 and int(entry.get("glyphs", 0)) > 0 and int(entry.get("textures", 0)) > 0:
				matched = true
		_check(matched, "GPU 按目标比例实际生成中文/等宽字体字形纹理 " + context)


## 只比较字体所在区域，忽略整张背景；保留原像素，不人工锐化或放大截图。
func _glyph_pixel_difference(image: Image, first: Vector2, second: Vector2, area: Vector2i) -> float:
	var total := 0.0
	var count := 0
	for y in area.y:
		for x in area.x:
			var a := Vector2i(first) + Vector2i(x, y)
			var b := Vector2i(second) + Vector2i(x, y)
			if not Rect2i(Vector2i.ZERO, image.get_size()).has_point(a) or not Rect2i(Vector2i.ZERO, image.get_size()).has_point(b):
				continue
			total += absf(image.get_pixelv(a).r - image.get_pixelv(b).r)
			count += 1
	return total / maxi(1, count)


## 白底区域必须包含实际文字笔画，不能把透明或白字空图当成字体渲染成功。
func _has_visible_ink(image: Image, area: Rect2i) -> bool:
	var pixels := 0
	var bounds := area.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			if image.get_pixel(x, y).r < 0.5:
				pixels += 1
				if pixels > 80:
					return true
	return false


## 原生 PopupMenu 的内部控件与无显式字号的独立 CanvasLayer 文本也必须登记。
func _check_registration() -> void:
	if not _layer_label.has_method("get_oversampling_with_scale"):
		print("SKIP 此引擎没有 4.7 原生变换超采样接口，仍可载入旧版本。")
		return
	_check(int(_layer_label.call("get_oversampling_with_scale")) == 2, "无显式字号的独立弹层也启用采样")
	var descendants := _descendants(_popup)
	var internal_count := 0
	for node in descendants:
		if node is Control:
			internal_count += 1
			_check(int(node.call("get_oversampling_with_scale")) == 2, "原生菜单内部控件独立启用采样 " + node.get_class())
	_check(internal_count > 0, "测试覆盖实际原生菜单内部控件")


## 多次字体刷新不会叠加观察节点，移出后重新加入也不产生重复订阅或保持旧比例。
func _check_reuse() -> void:
	var label := _labels[0]
	if not label.has_method("get_oversampling_with_scale"):
		return
	var before := label.get_children(true).size()
	for iteration in 40:
		GameTheme.font_size(label, "font_size", 20)
	_check(label.get_children(true).size() == before, "反复变更真实字号只保留一个变换观察节点")
	_body.remove_child(label)
	_card.scale = Vector2.ONE * 1.35
	_body.add_child(label)
	await _settle()
	_check((label.get_meta("ui_font_raster_scale") as Vector2).is_equal_approx(Vector2.ONE * 1.35 * 0.8), "同一标签重新进入时刷新实际比例")
	_check(label.get_children(true).size() == before, "节点保留及重用不会累积观察节点")
	_check(label.get_theme_font_size("font_size") == 25, "重用仍保留当前 125% 真实字号")


## 淡入前隐藏期间的祖先缩放不能缓存为已完成；显示后必须按最终比例重新绘制。
func _check_hidden_reveal() -> void:
	if not _labels[0].has_method("get_oversampling_with_scale"):
		return
	_card.hide()
	_card.scale = Vector2.ONE * 1.8
	await _settle()
	_check(not _labels[0].has_meta("ui_font_raster_scale"), "隐藏时不把尚未生效的字体采样标成已完成")
	_card.scale = Vector2.ONE * 2.7
	_card.show()
	await _settle()
	_check((_labels[0].get_meta("ui_font_raster_scale") as Vector2).is_equal_approx(Vector2.ONE * 2.7 * 0.8), "隐藏再显示后采用最终父级比例")
	if DisplayServer.get_name() != "headless":
		await _check_glyph_raster(2.7, 125, "隐藏再显示")


## 使用真实 OptionButton 打开原生菜单，验证其独立视口不会继续放大旧字号的字形。
func _check_popup_font_raster() -> void:
	var option := OptionButton.new()
	option.position = Vector2(900, 400)
	option.add_item("1920 × 1080 中文")
	option.add_item("2560 × 1440")
	_scope.add_child(option)
	var popup := option.get_popup()
	popup.theme = _scope.theme
	GameTheme.font_size(popup, "font_size", 37)
	await _settle()
	var original := popup.get_theme_font("font")
	for factor in [1.08, 1.44, 2.16]:
		var had_override := popup.has_theme_font_override("font")
		var retired: WeakRef
		option.scale = Vector2.ONE * factor
		# 新测试窗口刚取得系统焦点时，原生菜单可能自动关闭；重新打开覆盖实际保持显示的菜单。
		for attempt in 3:
			option.show_popup()
			await _settle()
			if popup.visible:
				break
		_check(popup.visible, "原生菜单保持显示 " + str(factor))
		if popup.visible:
			var font := popup.get_theme_font("font") as FontVariation
			retired = weakref(font)
			_check(font != original and popup.has_meta("ui_font_raster_popup_font"), "打开菜单独占临时字体缓存 " + str(factor))
			_check(is_equal_approx((font.base_font as FontFile).oversampling, factor), "菜单字形按真实窗口比例采样 " + str(factor))
			_check(is_zero_approx((GameTheme.body_font() as FontVariation).base_font.oversampling), "共享正文字体保持自动采样 " + str(factor))
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				var server := TextServerManager.get_primary_interface()
				if server.has_method("font_get_size_cache_info"):
					var information: Array = server.call("font_get_size_cache_info", font.get_rids()[0])
					var matched := false
					for entry: Dictionary in information:
						if absi((entry.get("size_px") as Vector2i).x - int(popup.get_theme_font_size("font_size") * factor)) <= 1 and int(entry.get("glyphs", 0)) > 0 and int(entry.get("textures", 0)) > 0:
							matched = true
					_check(matched, "原生菜单实际生成目标像素字号的字形纹理 " + str(factor))
			font = null
		popup.hide()
		await _settle()
		_check(popup.get_theme_font("font") == original and popup.has_theme_font_override("font") == had_override, "关闭菜单恢复原主题覆盖状态 " + str(factor))
		_check(not popup.has_meta("ui_font_raster_popup_font"), "关闭菜单释放临时字体缓存 " + str(factor))
		if retired != null:
			_check(retired.get_ref() == null, "关闭后临时 FontVariation 实际销毁 " + str(factor))
		# 下一次打开覆盖具有显式字体覆盖的原生菜单，不能只验证继承主题的路径。
		popup.add_theme_font_override("font", original)
	if _viewport.has_method("set_oversampling_override"):
		_viewport.call("set_oversampling_override", 2.0)
		option.scale = Vector2.ONE * 1.44
		for attempt in 3:
			option.show_popup()
			await _settle()
			if popup.visible:
				break
		_check(popup.visible, "父视口两倍字体采样下原生菜单保持显示")
		if popup.visible:
			var font := popup.get_theme_font("font") as FontVariation
			_check(is_equal_approx((font.base_font as FontFile).oversampling, 2.88), "菜单采样保留父视口 Retina 基准")
		popup.hide()
		await _settle()
		_check(popup.get_theme_font("font") == original, "Retina 菜单关闭后恢复原字体")
		_viewport.call("set_oversampling_override", 0.0)
	option.queue_free()
	await _settle()


## 包含原生内部节点，避免只检查公开子节点而漏掉 Window 之后的继承断点。
func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in node.get_children(true):
		result.append(child)
		result.append_array(_descendants(child))
	return result


## 两次真实绘制足以更新旧变换缓存，再留出容器及原生字体刷新时间。
func _settle() -> void:
	for frame in 6:
		await process_frame


## 输出明确失败，不让截图保存成功掩盖字形缓存或布局错误。
func _check(condition: bool, caption: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(caption)
