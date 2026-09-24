shader_type canvas_item;
render_mode unshaded;

// 读取仅含图纸和模块的合成结果；最近邻零级采样不模糊原像素。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform vec2 viewport_size = vec2(1.0);
uniform vec4 edge_strength = vec4(0.0);
uniform float fade_width = 64.0;
uniform float top_fade_width = 48.0;
varying vec2 canvas_position;

// 合成组与画布共用局部原点，柔边宽度保持逻辑像素，不随图纸缩放而拉伸。
void vertex() {
	canvas_position = VERTEX;
}

// 过渡段在两端保持连续的斜率与曲率，网格不会出现从渐变突然切回实色的边线。
vec4 transition_cap(vec4 t) {
	return t * t * t * (6.0 + t * (-8.0 + 3.0 * t));
}

// 透明端轻柔起步，靠近实色的一半宽度慢慢收尾，消除内边界的亮带感。
vec4 opacity_ramp(vec4 distance_to_edge, float width) {
	vec4 t = clamp(distance_to_edge / width, vec4(0.0), vec4(1.0));
	vec4 start = 0.1 * transition_cap(clamp(t / 0.1, vec4(0.0), vec4(1.0)));
	vec4 finish = 1.0 - 0.5 * transition_cap(clamp((1.0 - t) / 0.5, vec4(0.0), vec4(1.0)));
	vec4 ramp = mix(t, start, lessThan(t, vec4(0.1)));
	return mix(ramp, finish, greaterThan(t, vec4(0.5)));
}

// 左右与底边沿用连续合并，保留下方两角的既有过渡。
float combine_opacity(float horizontal, float vertical) {
	float product = horizontal * vertical;
	if (product <= 0.0) {
		return 0.0;
	}
	vec2 loss = vec2((1.0 - horizontal) * vertical, (1.0 - vertical) * horizontal);
	return product / (product + length(loss));
}

// 整图合成后只减一次 alpha，重叠的纸张、模块与选框不会在渐隐带重新叠浓。
void fragment() {
	vec4 composed = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (composed.a > 0.0001) {
		composed.rgb /= composed.a;
	}
	float width = max(1.0, min(fade_width, min(viewport_size.x, viewport_size.y) * 0.25));
	vec4 distance_to_edge = vec4(canvas_position, viewport_size - canvas_position);
	vec4 ramp = opacity_ramp(distance_to_edge, width);
	// 顶部与设置页使用相同的 48 像素 smoothstep；乘积保留顶角处同样的纵向曲线。
	ramp.y = smoothstep(0.0, max(top_fade_width, 1.0), canvas_position.y);
	vec4 fade = mix(vec4(1.0), ramp, edge_strength);
	float opacity = fade.y * combine_opacity(fade.x * fade.z, fade.w);
	COLOR *= vec4(composed.rgb, composed.a * opacity);
}
