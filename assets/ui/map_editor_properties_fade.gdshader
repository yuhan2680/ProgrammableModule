shader_type canvas_item;
render_mode unshaded;

// 仅采样合成后的原始像素，不模糊文字、输入框或焦点描边。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform vec2 content_size = vec2(1.0);
uniform vec2 edge_strength = vec2(0.0);
uniform float fade_width = 48.0;
varying vec2 content_position;

// 合成层原点与滚动容器一致，保持渐隐宽度为固定逻辑像素。
void vertex() {
	content_position = VERTEX;
}

// 真正减小正文alpha，让原卡片底色透出；右侧原生滚动条保持自己的透明度。
void fragment() {
	vec4 composed = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (composed.a > 0.0001) {
		composed.rgb /= composed.a;
	}
	float opacity = 1.0;
	if (content_position.x < content_size.x) {
		float width = max(1.0, min(fade_width, content_size.y * 0.25));
		float top = smoothstep(0.0, width, content_position.y);
		float bottom = smoothstep(0.0, width, content_size.y - content_position.y);
		opacity = mix(1.0, top, edge_strength.x) * mix(1.0, bottom, edge_strength.y);
	}
	COLOR *= vec4(composed.rgb, composed.a * opacity);
}
