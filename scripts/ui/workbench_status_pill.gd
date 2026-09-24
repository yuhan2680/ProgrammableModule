class_name WorkbenchStatusPill
extends Control
## 世界卡片上的运行状态药丸只显示本土化文本，不改变模拟或程序状态。

const HEIGHT := 32.0
const MAX_WIDTH := 380.0
const COLLAPSED_WIDTH := 24.0
const TOP_OFFSET := -4.0
const RIGHT_INSET := 32.0
const TEXT_INSET := 12.0
const FONT_SIZE := 14
const FINAL_HOLD_SECONDS := 1.0
const TIME_COLOR := "#d82929"
const SURFACE_SHADER := """
shader_type canvas_item;
render_mode unshaded;
// 使用原分辨率背景与紧密的 25 点高斯采样，轻微柔化地图但不降采样。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 panel_size = vec2(380.0, 32.0);
uniform float gradient_strength = 0.0;

// 返回二项式高斯权重，增加采样密度而非扩大模糊半径。
float gaussian_weight(int tap) {
	return abs(tap) == 2 ? 1.0 : (abs(tap) == 1 ? 4.0 : 6.0);
}

// 独立合成玻璃背景，文字仍由原标签绘制。
void fragment() {
	vec2 half_size = max(panel_size, vec2(1.0)) * 0.5;
	vec2 point = (UV - vec2(0.5)) * panel_size;
	float radius = min(16.0, min(half_size.x, half_size.y));
	vec2 corner = abs(point) - half_size + vec2(radius);
	float edge = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - radius;
	float antialias = max(fwidth(edge) * 0.75, 0.001);
	float mask = 1.0 - smoothstep(-antialias, antialias, edge);
	// 采样半径随实际显示比例变化，高分屏只增加像素密度，不扩大模糊范围。
	vec2 logical_pixel = vec2(length(vec2(dFdx(point.x), dFdy(point.x))), length(vec2(dFdx(point.y), dFdy(point.y))));
	vec2 sample_step = SCREEN_PIXEL_SIZE * 0.7 / max(logical_pixel, vec2(0.001));
	vec3 backdrop = vec3(0.0);
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float weight = gaussian_weight(x) * gaussian_weight(y) / 256.0;
			backdrop += texture(screen_texture, SCREEN_UV + vec2(float(x), float(y)) * sample_step).rgb * weight;
		}
	}
	float horizontal = smoothstep(0.0, 1.0, UV.x);
	float frost = mix(0.58, mix(0.63, 0.14, horizontal), gradient_strength);
	vec3 glass = mix(backdrop, vec3(0.87, 0.89, 0.925), frost);
	float top_light = 1.0 - smoothstep(0.0, 1.0, UV.y);
	glass = mix(glass, vec3(1.0), top_light * 0.025);
	float rim = 1.0 - smoothstep(0.0, 0.65, max(-edge, 0.0));
	glass = mix(glass, vec3(1.0), rim * top_light * 0.14);
	float opacity = mix(0.94, mix(0.94, 0.20, horizontal), gradient_strength);
	COLOR = vec4(glass, mask * opacity * COLOR.a);
}
"""

var right_inset := RIGHT_INSET
var status_label: RichTextLabel
var _backdrop: BackBufferCopy
var _surface: ColorRect
var _text_clip: Control
var _surface_material: ShaderMaterial
var _bold_font: FontVariation
var _time_pattern: RegEx
var _text := ""
var _requested_visible := false
var _reveal_progress := 0.0
var _tween: Tween


## 创建原分辨率的局部玻璃表面和独立文字裁切层，保留原有形状与展开过程。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_backdrop = BackBufferCopy.new()
	_backdrop.name = "StatusPillBackdrop"
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	add_child(_backdrop)
	visibility_changed.connect(_sync_backdrop)
	_surface = ColorRect.new()
	_surface.name = "StatusPillSurface"
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SURFACE_SHADER
	_surface_material.shader = shader
	_surface.material = _surface_material
	add_child(_surface)
	_text_clip = Control.new()
	_text_clip.name = "StatusPillTextClip"
	_text_clip.clip_contents = true
	_text_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_text_clip)
	status_label = RichTextLabel.new()
	status_label.name = "StatusPillText"
	status_label.bbcode_enabled = true
	status_label.fit_content = false
	status_label.scroll_active = false
	status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	status_label.mouse_filter = Control.MOUSE_FILTER_PASS
	status_label.selection_enabled = false
	status_label.add_theme_font_override("normal_font", GameTheme.body_font())
	_bold_font = GameTheme.body_font().duplicate() as FontVariation
	_bold_font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 700.0}
	status_label.add_theme_font_override("bold_font", _bold_font)
	status_label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	status_label.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	status_label.add_theme_color_override("default_color", GameTheme.TEXT)
	_text_clip.add_child(status_label)
	_time_pattern = RegEx.new()
	_time_pattern.compile("(?<![0-9.])[0-9]+(?:\\.[0-9]+)?(?=\\s*(?:秒|s\\b))")
	resized.connect(_on_resized)
	var parent := get_parent() as Control
	if parent != null:
		parent.resized.connect(_layout_frame)
	_layout_frame()
	_refresh_text()
	_set_reveal_progress(0.0)
	if _requested_visible:
		_expand()
	else:
		hide()


## 相同运行状态仅刷新文字，终态只安排一次短暂停留，避免逐帧通知重置计时。
func show_status(text: String, visible_now: bool) -> void:
	var was_requested := _requested_visible
	_requested_visible = visible_now
	var normalized := text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", " · ").strip_edges()
	# 终态短停期间保留第一次最终结果，重置后连续传入的初始状态不会覆盖它。
	var preserve_final := not visible_now and not was_requested and is_node_ready() and visible
	if not preserve_final and _text != normalized:
		_text = normalized
		if is_node_ready():
			_refresh_text()
	if not is_node_ready() or was_requested == visible_now:
		return
	if visible_now:
		_expand()
	elif visible:
		_hold_then_retract()


## 页面离开时可立即清理，也允许外部要求跳过停留并直接缓动收回。
func hide_status(immediate: bool = true) -> void:
	_requested_visible = false
	_cancel_tween()
	if not is_node_ready():
		return
	if immediate or not visible:
		_finish_hidden()
	else:
		_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_method(_set_reveal_progress, _reveal_progress, 0.0, 0.26)
		_tween.tween_callback(_finish_hidden)


## 展开、终态停留和收回期间都算可见，完全收起后返回 false。
func is_expanded() -> bool:
	return is_node_ready() and visible


## 快速重启取消旧动画和延迟，继续从当前宽度向左展开。
func _expand() -> void:
	_cancel_tween()
	show()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_reveal_progress, _reveal_progress, 1.0, 0.28)


## 先完成短暂的剩余展开，再显示终态一秒并从左向右收回。
func _hold_then_retract() -> void:
	_cancel_tween()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	if _reveal_progress < 1.0:
		_tween.tween_method(_set_reveal_progress, _reveal_progress, 1.0, 0.12)
	_tween.tween_interval(FINAL_HOLD_SECONDS)
	_tween.tween_method(_set_reveal_progress, 1.0, 0.0, 0.26)
	_tween.tween_callback(_finish_hidden)


## 统一终止动画时间线，其中的停留和关闭回调也随之取消。
func _cancel_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## 完全收起后移出鼠标命中范围，等待下一次真实运行。
func _finish_hidden() -> void:
	_set_reveal_progress(0.0)
	hide()


## 外框与问号垂直居中，右端留出按钮及间距；向左缓动延伸时保留左浓右淡。
func _layout_frame() -> void:
	var parent := get_parent() as Control
	if parent == null:
		return
	var frame_width := minf(MAX_WIDTH, maxf(0.0, parent.size.x - right_inset))
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -frame_width - right_inset
	offset_right = -right_inset
	offset_top = TOP_OFFSET
	offset_bottom = TOP_OFFSET + HEIGHT
	_on_resized()


## 尺寸变化重新计算文字省略和当前动画帧，不重启动画或终态计时。
func _on_resized() -> void:
	if status_label == null:
		return
	_refresh_text()
	_set_reveal_progress(_reveal_progress)


## 只改变裁切宽度和透明度，药丸右边缘与文字字号始终保持固定。
func _set_reveal_progress(progress: float) -> void:
	_reveal_progress = clampf(progress, 0.0, 1.0)
	if _surface == null:
		return
	var width := lerpf(minf(COLLAPSED_WIDTH, size.x), size.x, _reveal_progress)
	_surface.position = Vector2(size.x - width, 0.0)
	_surface.size = Vector2(width, HEIGHT)
	_surface.modulate.a = _reveal_progress
	_surface_material.set_shader_parameter("panel_size", _surface.size)
	# 完整展开后玻璃浓度均匀，临近展开或收回端点时保留原来的左右渐变。
	_surface_material.set_shader_parameter("gradient_strength", 1.0 - smoothstep(0.75, 1.0, _reveal_progress))
	_text_clip.position = Vector2(size.x - width + TEXT_INSET, 0.0)
	_text_clip.size = Vector2(maxf(0.0, width - TEXT_INSET * 2.0), HEIGHT)
	var line_height := GameTheme.body_font().get_height(FONT_SIZE)
	status_label.position = Vector2(width - size.x, maxf(0.0, (HEIGHT - line_height) * 0.5))
	status_label.size = Vector2(maxf(0.0, size.x - TEXT_INSET * 2.0), line_height)
	var text_alpha := clampf((_reveal_progress - 0.35) / 0.65, 0.0, 1.0)
	status_label.modulate.a = text_alpha * text_alpha * (3.0 - 2.0 * text_alpha)
	_sync_backdrop()


## 可见时先复制当前视口，兼容全尺寸重挂载与高分屏缩放；隐藏后停止复制。
func _sync_backdrop() -> void:
	if _backdrop == null or _surface == null:
		return
	# 全视口复制避免 Compatibility 渲染下局部缓冲在变换后留下旧画面；着色器仍只采样药丸附近。
	_backdrop.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT if is_visible_in_tree() and _reveal_progress > 0.0 else BackBufferCopy.COPY_MODE_DISABLED


## 完整原文保存在悬停提示，时间数值加粗标红，其他数字保持普通正文。
func _refresh_text() -> void:
	status_label.tooltip_text = _text
	var display_text := _elided_text(_text, maxf(0.0, size.x - TEXT_INSET * 2.0))
	var formatted := ""
	var previous_end := 0
	for result: RegExMatch in _time_pattern.search_all(display_text):
		formatted += _escape_bbcode(display_text.substr(previous_end, result.get_start() - previous_end))
		formatted += "[b][color=%s]%s[/color][/b]" % [TIME_COLOR, _escape_bbcode(result.get_string())]
		previous_end = result.get_end()
	formatted += _escape_bbcode(display_text.substr(previous_end))
	status_label.text = formatted


## 使用粗体度量作为安全上界，在一行内保留尽量多的字符并追加省略号。
func _elided_text(text: String, available_width: float) -> String:
	if _bold_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x <= available_width:
		return text
	if _bold_font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x > available_width:
		return ""
	var low := 0
	var high := text.length()
	while low < high:
		var middle := (low + high + 1) >> 1
		var candidate := text.left(middle) + "…"
		if _bold_font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x <= available_width:
			low = middle
		else:
			high = middle - 1
	return text.left(low) + "…"


## 用户关卡的方括号作为普通文字显示，避免原文变成富文本标签。
func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
