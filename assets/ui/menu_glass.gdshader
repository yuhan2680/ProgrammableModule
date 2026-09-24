shader_type canvas_item;
render_mode unshaded;

// 只在菜单圆角内采样背后的页面；透明屏障不会将整页变暗。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 panel_size = vec2(220.0, 108.0);
uniform float corner_radius = 18.0;

void fragment() {
	float opacity = COLOR.a;
	vec2 offset = SCREEN_PIXEL_SIZE * 4.5;
	vec3 blurred = texture(screen_texture, SCREEN_UV).rgb * 0.2;
	blurred += texture(screen_texture, SCREEN_UV + vec2(offset.x, 0.0)).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV - vec2(offset.x, 0.0)).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV + vec2(0.0, offset.y)).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV - vec2(0.0, offset.y)).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV + offset).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV - offset).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV + vec2(offset.x, -offset.y)).rgb * 0.1;
	blurred += texture(screen_texture, SCREEN_UV + vec2(-offset.x, offset.y)).rgb * 0.1;
	vec2 local_position = (UV - vec2(0.5)) * panel_size;
	vec2 corner = abs(local_position) - panel_size * 0.5 + vec2(corner_radius);
	float distance_to_edge = length(max(corner, vec2(0.0))) + min(max(corner.x, corner.y), 0.0) - corner_radius;
	float mask = 1.0 - smoothstep(-0.8, 0.0, distance_to_edge);
	COLOR = vec4(mix(blurred, vec3(0.985, 0.99, 1.0), 0.80), mask * opacity);
}
