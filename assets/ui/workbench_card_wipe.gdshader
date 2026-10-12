shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float curtain_edge = 0.0;
uniform float fade_width = 88.0;
uniform float minimum_alpha : hint_range(0.0, 1.0) = 0.30;
uniform float fade_strength : hint_range(0.0, 1.0) = 0.0;
varying vec2 group_position;

void vertex() {
	group_position = VERTEX;
}

void fragment() {
	vec4 composed = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (composed.a > 0.0001) {
		composed.rgb /= composed.a;
	}
    // 地图在上层遮盖代码；此层在独立同色底板上渐淡，不透出浅色页面形成亮带。
	float distance_alpha = smoothstep(curtain_edge, curtain_edge + max(fade_width, 1.0), group_position.x);
	float edge_alpha = mix(minimum_alpha, 1.0, distance_alpha);
	float visibility = mix(1.0, edge_alpha, fade_strength);
	COLOR *= vec4(composed.rgb, composed.a * visibility);
}
