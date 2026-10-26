shader_type canvas_item;
render_mode unshaded;

// 只采样原生轨道和卡片；旋钮不读取自身上一帧，不把白色光带当成透明玻璃。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 thumb_size = vec2(27.0, 19.0);
uniform float interaction : hint_range(0.0, 1.0) = 0.0;
uniform float shadow_padding = 7.0;
uniform vec4 clip_bounds = vec4(-100000.0, -100000.0, 100000.0, 100000.0);
uniform vec2 viewport_size = vec2(1280.0, 800.0);
uniform int fade_count = 0;
uniform vec4 fade_bounds[4];
uniform vec4 fade_data[4];

// 胶囊的有符号距离同时驱动抗锯齿轮廓、薄边和接触阴影。
float capsule_distance(vec2 p, vec2 half_size) {
	float radius = half_size.y;
	vec2 q = abs(p) - half_size + vec2(radius);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// 曲面法线把真实背景轻微折射，亮边仅留在边缘；文字与页面无需离屏截图。
void fragment() {
	vec2 p = (UV - vec2(0.5)) * (thumb_size + vec2(shadow_padding * 2.0));
	vec2 half_size = thumb_size * 0.5;
	float distance_to_edge = capsule_distance(p, half_size);
	float aa = max(fwidth(distance_to_edge), 0.2);
	float coverage = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, distance_to_edge);
	float inset = max(-distance_to_edge, 0.0);
	vec2 lens_center = vec2(clamp(p.x, -half_size.x + half_size.y, half_size.x - half_size.y), 0.0);
	vec2 normal = (p - lens_center) / max(half_size.y, 1.0);
	vec2 logical_pixel = vec2(length(vec2(dFdx(p.x), dFdy(p.x))), length(vec2(dFdx(p.y), dFdy(p.y))));
	vec2 pixel_scale = 1.0 / max(logical_pixel, vec2(0.001));
	vec2 refraction = normal * (1.0 + 2.4 * pow(clamp(length(normal), 0.0, 1.0), 3.0)) * SCREEN_PIXEL_SIZE * pixel_scale * interaction;
	vec4 sample_color = textureLod(screen_texture, SCREEN_UV - refraction, 0.0);
	vec3 backdrop = sample_color.rgb / max(sample_color.a, 0.001);
	vec3 glass = mix(backdrop, vec3(0.96, 0.98, 1.0), 0.18);
	float rim = 1.0 - smoothstep(0.2, 1.15, inset);
	float top_light = 1.0 - smoothstep(-0.9, 0.5, normal.y);
	glass = mix(glass, vec3(1.0), rim * (0.28 + top_light * 0.52));
	float lower_edge = rim * smoothstep(0.05, 0.95, normal.y);
	glass *= 1.0 - lower_edge * 0.13;
	vec3 resting = mix(vec3(1.0), vec3(0.81, 0.82, 0.85), rim * 0.65);
	vec3 face = mix(resting, glass, interaction);
	float shadow_distance = capsule_distance(p - vec2(0.0, 1.3), half_size);
	float shadow = (1.0 - smoothstep(-1.0, 4.0, shadow_distance)) * (0.12 + 0.05 * interaction) * (1.0 - coverage);
	float alpha = coverage + shadow;
	vec2 viewport_point = SCREEN_UV * viewport_size;
	float fade = step(clip_bounds.x, viewport_point.x) * step(viewport_point.x, clip_bounds.z);
	fade *= step(clip_bounds.y, viewport_point.y) * step(viewport_point.y, clip_bounds.w);
	for (int i = 0; i < 4; i++) {
		if (i < fade_count && viewport_point.x < fade_bounds[i].z) {
			float top = smoothstep(fade_bounds[i].y, fade_bounds[i].y + max(fade_data[i].x, 0.01), viewport_point.y);
			float bottom = 1.0 - smoothstep(fade_bounds[i].w - max(fade_data[i].y, 0.01), fade_bounds[i].w, viewport_point.y);
			fade *= mix(1.0, top, fade_data[i].z) * mix(1.0, bottom, fade_data[i].w);
		}
	}
	COLOR = vec4((face * coverage + vec3(0.18, 0.22, 0.28) * shadow) / max(alpha, 0.001), alpha * fade * COLOR.a);
}
