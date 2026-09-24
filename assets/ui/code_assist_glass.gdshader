shader_type canvas_item;
render_mode unshaded;

// 仅给圆形按钮背景做局部模糊；SVG 由父按钮清晰绘制，不参与采样。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 panel_size = vec2(28.0);

void fragment() {
	vec2 point = (UV - vec2(0.5)) * panel_size;
	float radius = min(panel_size.x, panel_size.y) * 0.5;
	float distance_to_edge = length(point) - radius;
	float edge_width = max(fwidth(distance_to_edge), 0.001);
	float mask = 1.0 - smoothstep(-edge_width, 0.0, distance_to_edge);
	vec2 logical_pixel = vec2(length(vec2(dFdx(point.x), dFdy(point.x))), length(vec2(dFdx(point.y), dFdy(point.y))));
	vec2 step_uv = SCREEN_PIXEL_SIZE * 2.0 / max(logical_pixel, vec2(0.001));
	vec3 blurred = vec3(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float weight = float((x == 0 ? 2 : 1) * (y == 0 ? 2 : 1)) / 16.0;
			blurred += texture(screen_texture, SCREEN_UV + vec2(float(x), float(y)) * step_uv).rgb * weight;
		}
	}
	vec3 glass = mix(blurred, vec3(0.188, 0.204, 0.231), 0.64);
	float top_light = 1.0 - smoothstep(-radius, radius, point.y);
	glass += vec3(0.018) * top_light;
	float rim = 1.0 - smoothstep(0.0, 0.8, max(-distance_to_edge, 0.0));
	glass += vec3(0.06) * rim * top_light;
	COLOR = vec4(glass, mask * 0.72 * COLOR.a);
}
