shader_type canvas_item;
render_mode unshaded;

// CanvasGroup 的局部合成缓冲仅包含设置内容；固定零级、最近邻采样保持文字原像素。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float fade_top_y = -1.0;
uniform float fade_width = 1.0;
uniform float viewport_height = 1.0;

// 先按 CanvasGroup 默认方式还原预乘颜色，再仅改变最终 alpha，让原背景真实透出。
void fragment() {
	vec4 composed = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (composed.a > 0.0001) {
		composed.rgb /= composed.a;
	}
	float viewport_y = SCREEN_UV.y * max(viewport_height, 1.0);
	float opacity = smoothstep(fade_top_y, fade_top_y + max(fade_width, 1.0), viewport_y);
	COLOR *= vec4(composed.rgb, composed.a * opacity);
}
