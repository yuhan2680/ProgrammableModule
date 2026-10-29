shader_type canvas_item;
render_mode unshaded;

// 饱和蓝色玻璃的曲面、薄亮边与接触阴影均为解析曲线，高分屏不依赖位图。
uniform vec2 panel_size = vec2(32.0);
uniform float pressure = 0.0;
uniform float highlight = 0.0;
uniform float disabled = 0.0;

void fragment() {
	float radius = min(panel_size.x, panel_size.y) * 0.5 - 1.0 - pressure * 0.7;
	vec2 p = (UV - vec2(0.5)) * panel_size;
	float edge = length(p) - radius;
	float aa = max(fwidth(edge), 0.3);
	float coverage = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, edge);
	float inset = max(-edge, 0.0);
	float rim = 1.0 - smoothstep(0.2, 1.1, inset);
	float top_light = 1.0 - smoothstep(-0.9, 0.7, p.y / max(radius, 1.0));
	vec3 blue = mix(vec3(0.0, 0.43, 0.96), vec3(0.0, 0.60, 1.0), top_light * 0.7);
	blue *= 1.0 - pressure * 0.12;
	float sheen = exp(-dot((UV - vec2(0.35, 0.18)) * vec2(2.1, 3.0), (UV - vec2(0.35, 0.18)) * vec2(2.1, 3.0)) * 4.0);
	blue = mix(blue, vec3(1.0), sheen * (0.05 + highlight * 0.12));
	blue = mix(blue, vec3(1.0), rim * (0.28 + top_light * 0.34));
	blue = mix(blue, vec3(0.70, 0.78, 0.87), disabled * 0.75);
	float shadow_edge = length(p - vec2(0.0, 0.8)) - radius;
	float shadow = (1.0 - smoothstep(-1.0, 1.5, shadow_edge)) * (1.0 - coverage) * 0.15;
	float alpha = coverage + shadow;
	COLOR = vec4((blue * coverage + vec3(0.10, 0.24, 0.42) * shadow) / max(alpha, 0.001), alpha * COLOR.a);
}
