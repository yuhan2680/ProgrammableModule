shader_type canvas_item;
render_mode unshaded;

// CanvasGroup 的合成缓冲包含整张编辑卡片，不需要改写任何文字或子控件的材质。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float card_width = 600.0;
uniform float wipe_progress : hint_range(0.0, 1.0) = 0.0;
uniform float edge_softness : hint_range(0.01, 0.5) = 0.18;
varying vec2 group_position;

// 保存合成组的本地位置，让擦除方向始终沿卡片从左到右且不受窗口缩放影响。
void vertex() {
	group_position = VERTEX;
}

// 先还原 CanvasGroup 的预乘颜色，再施加软边遮罩；反向播放同一参数即可恢复。
void fragment() {
	vec4 composed = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (composed.a > 0.0001) {
		composed.rgb /= composed.a;
	}
	float horizontal = group_position.x / max(card_width, 1.0);
	float frontier = mix(-edge_softness, 1.0 + edge_softness, wipe_progress);
	float visibility = smoothstep(frontier - edge_softness, frontier + edge_softness, horizontal);
	// 端点显式归一，卡片阴影伸出矩形时仍能完全保留或完全消失。
	visibility = wipe_progress <= 0.0 ? 1.0 : (wipe_progress >= 1.0 ? 0.0 : visibility);
	COLOR *= vec4(composed.rgb, composed.a * visibility);
}
