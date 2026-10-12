shader_type canvas_item;
render_mode unshaded;

// 打开前捕获完整页面；原生前景另以实际像素绘制，圆角外还原同一页面。
uniform sampler2D backdrop_texture : repeat_disable, filter_linear;
uniform vec2 backdrop_origin = vec2(0.0);
uniform vec2 backdrop_extent = vec2(1.0);
uniform vec2 panel_size = vec2(220.0, 44.0);
uniform float corner_radius = 18.0;
uniform float shadow_padding = 14.0;
uniform float blur_step : hint_range(0.5, 6.0, 0.1) = 3.2;
uniform float frost_amount : hint_range(0.0, 1.0, 0.01) = 0.68;

float rounded_distance(vec2 point, vec2 half_size, float radius) {
	vec2 corner = abs(point) - half_size + vec2(radius);
	return length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - radius;
}

float gaussian_weight(int tap) {
	if (abs(tap) == 2) {
		return 1.0;
	}
	if (abs(tap) == 1) {
		return 4.0;
	}
	return 6.0;
}

void fragment() {
	float opacity = COLOR.a;
	vec2 safe_size = max(panel_size, vec2(1.0));
	vec2 padded_size = safe_size + vec2(shadow_padding * 2.0);
	vec2 point = (UV - vec2(0.5)) * padded_size;
	float radius = min(corner_radius, min(safe_size.x, safe_size.y) * 0.5);
	float edge_distance = rounded_distance(point, safe_size * 0.5, radius);
	float antialias = max(fwidth(edge_distance) * 0.75, 0.001);
	float card_mask = 1.0 - smoothstep(-antialias, antialias, edge_distance);

	// 按界面像素计算采样步长，高分辨率屏幕与窗口缩放后仍保持相同的柔化程度。
	vec2 local_pixel_size = vec2(
		length(vec2(dFdx(point.x), dFdy(point.x))),
		length(vec2(dFdx(point.y), dFdy(point.y)))
	);
	vec2 sample_step = SCREEN_PIXEL_SIZE * blur_step / max(local_pixel_size, vec2(0.001));
	vec3 blurred = vec3(0.0);
	// 5 × 5 二项式高斯核，不依赖 mipmap，兼容桌面与网页的 Compatibility 渲染器。
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float weight = gaussian_weight(x) * gaussian_weight(y) / 256.0;
			vec2 source_uv = (SCREEN_UV + vec2(float(x), float(y)) * sample_step - backdrop_origin) / backdrop_extent;
			blurred += texture(backdrop_texture, source_uv).rgb * weight;
		}
	}

	float top_light = 1.0 - smoothstep(0.0, safe_size.y * 0.85, point.y + safe_size.y * 0.5);
	vec3 glass = mix(blurred, vec3(0.985, 0.990, 1.0), frost_amount);
	glass = mix(glass, vec3(1.0), top_light * 0.055);
	float luminous_edge = 1.0 - smoothstep(0.0, 1.25, max(-edge_distance, 0.0));
	glass = mix(glass, vec3(1.0), luminous_edge * (0.36 + top_light * 0.35));

	// 阴影只出现在卡片轮廓以外，不叠加深色描边，也不压暗玻璃内部。
	float shadow_distance = max(rounded_distance(point - vec2(0.0, 3.0), safe_size * 0.5, radius), 0.0);
	float shadow_alpha = 0.10 * exp(-0.5 * pow(shadow_distance / 4.2, 2.0));
	shadow_alpha *= 1.0 - card_mask;
	// 还原透明圆角外的页面，避免部分桌面嵌入窗口合成器在透明客户区留下黑底。
	vec3 backdrop = texture(backdrop_texture, (SCREEN_UV - backdrop_origin) / backdrop_extent).rgb;
	vec3 composed = mix(backdrop, glass, card_mask);
	composed = mix(composed, vec3(0.16, 0.21, 0.30), shadow_alpha);
	// 只在原生窗口矩形内恢复背景，矩形外阴影继续透明叠加，不覆盖当前按钮的焦点颜色。
	float window_mask = step(abs(point.x), safe_size.x * 0.5) * step(abs(point.y), safe_size.y * 0.5);
	float alpha = max(window_mask, card_mask + shadow_alpha);
	composed = mix(vec3(0.16, 0.21, 0.30), composed, max(window_mask, card_mask));
	COLOR = vec4(composed, alpha * opacity);
}
