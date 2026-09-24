shader_type canvas_item;
render_mode unshaded;

uniform vec2 rect_size = vec2(128.0, 80.0);
uniform float corner_radius = 8.0;

// 在最终显示尺寸计算圆角透明度，避免缩小的模糊缓存把边缘放大成锯齿。
void fragment() {
	vec2 half_size = rect_size * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 corner = abs(UV * rect_size - half_size) - (half_size - vec2(radius));
	float distance_to_edge = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - radius;
	float antialias = max(fwidth(distance_to_edge) * 0.5, 0.001);
	COLOR.a *= 1.0 - smoothstep(-antialias, antialias, distance_to_edge);
}
