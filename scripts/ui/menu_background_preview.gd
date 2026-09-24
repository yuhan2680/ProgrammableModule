class_name MenuBackgroundPreview
extends Control
## 背景缩略图只表现壁纸与前景窗口的关系，不复制真实菜单或持续渲染整页。

const FRAME_INSET := 1.0
const FRAME_RADIUS := 8.0

var texture: Texture2D
var add_picture := false
var _background: MainMenuBackground
var _sketch: MenuSketch


## 背景复用一次性高斯缓存，前景以少量矢量块保持清晰，且不参与按钮命中。
func _ready() -> void:
	custom_minimum_size = Vector2(128, 80)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	if not add_picture and texture != null:
		_background = MainMenuBackground.new()
		_background.blur_sigma = 64.0 * 128.0 / 1280.0
		_background.corner_radius = FRAME_RADIUS
		_background.set_texture(texture)
		_background.set_active(true)
		add_child(_background)
		_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 图像与描边共用内缩和圆角，角外真正透明而非用父背景色遮盖。
		_background.offset_left = FRAME_INSET
		_background.offset_top = FRAME_INSET
		_background.offset_right = -FRAME_INSET
		_background.offset_bottom = -FRAME_INSET
	_sketch = MenuSketch.new()
	_sketch.add_picture = add_picture
	_sketch.solid = texture == null
	_sketch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_sketch)
	_sketch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if add_picture:
		var hint := GameTheme.label(self, "添加图片…", 11)
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.add_theme_color_override("font_color", GameTheme.MUTED)
		hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		hint.offset_top = -26
		hint.offset_bottom = -7


## 单选描边绘制在内容之上，避免影响按钮尺寸或遮盖实际图片。
func set_selected(selected: bool) -> void:
	if is_instance_valid(_sketch):
		_sketch.selected = selected
		_sketch.queue_redraw()


class MenuSketch extends Control:
	## 几何图案保持等比居中，仅表示窗口与背景的层次关系。
	var add_picture := false
	var solid := false
	var selected := false

	## 尺寸改变时重绘简化窗口和外框，不依赖实际主菜单布局或文本。
	func _ready() -> void:
		resized.connect(queue_redraw)

	## 添加项使用照片加号图案，其余项使用清晰的白色窗口与简化按钮。
	func _draw() -> void:
		var frame_rect := Rect2(Vector2.ONE * FRAME_INSET, size - Vector2.ONE * FRAME_INSET * 2.0)
		if solid or add_picture:
			draw_style_box(GameTheme.box(GameTheme.BACKGROUND, Color.TRANSPARENT, FRAME_RADIUS), frame_rect)
		if add_picture:
			var picture := Rect2(Vector2(size.x * 0.5 - 15, 16), Vector2(30, 24))
			draw_style_box(GameTheme.box(Color.TRANSPARENT, Color("A1A8B2"), 3), picture)
			draw_circle(picture.position + Vector2(8, 7), 2.5, Color("A1A8B2"), true, -1, true)
			draw_polyline(PackedVector2Array([picture.position + Vector2(3, 21), picture.position + Vector2(11, 12), picture.position + Vector2(17, 18), picture.position + Vector2(23, 10), picture.position + Vector2(28, 17)]), Color("A1A8B2"), 2, true)
			var plus_center := picture.end + Vector2(-1, -1)
			draw_circle(plus_center, 7, Color("A1A8B2"), true, -1, true)
			draw_line(plus_center - Vector2(3.5, 0), plus_center + Vector2(3.5, 0), Color.WHITE, 1.5, true)
			draw_line(plus_center - Vector2(0, 3.5), plus_center + Vector2(0, 3.5), Color.WHITE, 1.5, true)
		else:
			var window := Rect2(size * Vector2(0.16, 0.2), size * Vector2(0.68, 0.6))
			var paper := GameTheme.box(Color.WHITE, Color(0, 0, 0, 0.035), 4)
			paper.shadow_size = 2
			paper.shadow_offset = Vector2(0, 1)
			paper.shadow_color = Color(0, 0, 0, 0.1)
			draw_style_box(paper, window)
			var art := Rect2(window.position + window.size * Vector2(0.09, 0.16), window.size * Vector2(0.34, 0.68))
			draw_style_box(GameTheme.box(Color("E7F0FD"), Color.TRANSPARENT, 3), art)
			draw_style_box(GameTheme.box(Color("3D9FFF"), Color.TRANSPARENT, 2), Rect2(art.position + art.size * 0.26, art.size * 0.48))
			var button_size := window.size * Vector2(0.4, 0.105)
			var button_start := window.position + window.size * Vector2(0.51, 0.42)
			draw_style_box(GameTheme.box(GameTheme.TEXT, Color.TRANSPARENT, 1), Rect2(window.position + window.size * Vector2(0.52, 0.2), window.size * Vector2(0.25, 0.04)))
			for index in range(3):
				var fill := GameTheme.ACCENT if index == 0 else GameTheme.SURFACE
				draw_style_box(GameTheme.box(fill, Color.TRANSPARENT, 2), Rect2(button_start + Vector2(0, float(index) * window.size.y * 0.15), button_size))
		var frame := GameTheme.box(Color.TRANSPARENT, Color("89BFFF") if selected else Color(0, 0, 0, 0.06), FRAME_RADIUS)
		frame.set_border_width_all(2 if selected else 1)
		draw_style_box(frame, frame_rect)
