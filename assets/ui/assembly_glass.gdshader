shader_type canvas_item;
render_mode unshaded;

// 装配侧栏独立采样背后的蓝图，不修改其他菜单的玻璃颜色。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 panel_size = vec2(296.0, 320.0);
uniform float corner_radius = 22.0;
uniform float frost = 0.84;
uniform float highlighted = 0.0;

// 紧密高斯采样保持高分屏下的细节，边缘另外叠加轻薄亮边。
float gaussian_weight(int tap) {
	return abs(tap) == 2 ? 1.0 : (abs(tap) == 1 ? 4.0 : 6.0);
}

// 背景与图标分层绘制，动画只改变透明度而不缩放文字。
void fragment() {
	vec2 half_size = max(panel_size, vec2(1.0)) * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 local_point = (UV - vec2(0.5)) * panel_size;
	vec2 corner = abs(local_point) - half_size + vec2(radius);
	float edge = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - radius;
	float antialias = max(fwidth(edge) * 0.7, 0.001);
	float mask = 1.0 - smoothstep(-antialias, antialias, edge);
	vec2 logical_pixel = vec2(length(vec2(dFdx(local_point.x), dFdy(local_point.x))), length(vec2(dFdx(local_point.y), dFdy(local_point.y))));
	vec2 step_size = SCREEN_PIXEL_SIZE * 1.3 / max(logical_pixel, vec2(0.001));
	vec3 backdrop = vec3(0.0);
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float weight = gaussian_weight(x) * gaussian_weight(y) / 256.0;
			backdrop += texture(screen_texture, SCREEN_UV + vec2(float(x), float(y)) * step_size).rgb * weight;
		}
	}
	float top_light = 1.0 - smoothstep(0.0, 1.0, UV.y);
	vec3 tint = mix(vec3(0.975, 0.988, 1.0), vec3(0.79, 0.89, 1.0), highlighted * 0.25);
	vec3 glass = mix(backdrop, tint, clamp(frost + top_light * 0.035, 0.0, 1.0));
	float rim = 1.0 - smoothstep(0.0, 0.9, max(-edge, 0.0));
	glass = mix(glass, vec3(1.0), rim * (0.18 + top_light * 0.24));
	COLOR = vec4(glass, mask * 0.99 * COLOR.a);
}
