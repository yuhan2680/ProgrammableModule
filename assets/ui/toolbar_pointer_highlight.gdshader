shader_type canvas_item;
render_mode unshaded;

uniform vec4 base_color : source_color = vec4(0.0);
uniform vec2 panel_size = vec2(44.0);
// 四角依次为左上、右上、右下、左下，分段内侧保持直边。
uniform vec4 corner_radii = vec4(22.0);
uniform vec2 pointer_position = vec2(-100.0);
uniform float light_radius = 26.0;
uniform float hover_opacity = 0.576;
uniform float press_opacity = 0.34;
uniform float hover_amount = 0.0;
uniform bool pressed = false;

// 仅在对应象限使用实际圆角，完整裁切圆形入口与胶囊端部。
float rounded_distance(vec2 point, vec2 half_size) {
	float radius = point.y < 0.0
		? (point.x < 0.0 ? corner_radii.x : corner_radii.y)
		: (point.x < 0.0 ? corner_radii.w : corner_radii.z);
	radius = min(radius, min(half_size.x, half_size.y));
	vec2 edge = abs(point) - half_size + vec2(radius);
	return length(max(edge, vec2(0.0))) + min(max(edge.x, edge.y), 0.0) - radius;
}

// 悬停为鼠标圆心的柔和径向光，仅按下才整面高亮；不采样或模糊屏幕和图标。
void fragment() {
	vec2 local = UV * panel_size;
	float edge_distance = rounded_distance(local - panel_size * 0.5, panel_size * 0.5);
	float antialias = max(fwidth(edge_distance), 0.001);
	float mask = 1.0 - smoothstep(-antialias, 0.0, edge_distance);
	float distance_ratio = length(local - pointer_position) / max(light_radius, 0.001);
	float falloff = 1.0 - smoothstep(0.0, 1.0, distance_ratio);
	float light = pressed ? press_opacity : hover_opacity * hover_amount * falloff;
	// 预乘合成后还原直通 alpha；独立重载按钮保留原灰底，其余段透出父胶囊。
	float alpha = light + base_color.a * (1.0 - light);
	vec3 rgb = (vec3(light) + base_color.rgb * base_color.a * (1.0 - light)) / max(alpha, 0.0001);
	COLOR = vec4(rgb, alpha * mask * COLOR.a);
}
