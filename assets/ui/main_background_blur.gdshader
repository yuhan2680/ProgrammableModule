shader_type canvas_item;
render_mode unshaded, blend_disabled;

// 两次一维高斯卷积分别沿横向、纵向计算，前景卡片不参与背景采样。
uniform sampler2D input_texture : source_color, filter_linear, repeat_disable;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 input_pixel_size = vec2(0.001);
uniform vec2 logical_size = vec2(1280.0, 800.0);
uniform vec2 blur_axis = vec2(1.0, 0.0);
uniform float blur_sigma = 64.0;
uniform bool cover_only = false;

// 采样覆盖正负三倍标准差，权重归一化；边缘复制像素，避免黑边或透明接缝。
void fragment() {
	if (cover_only) {
		vec2 sample_uv = UV * uv_scale + uv_offset;
		sample_uv = clamp(sample_uv, input_pixel_size * 0.5, vec2(1.0) - input_pixel_size * 0.5);
		COLOR = vec4(texture(input_texture, sample_uv).rgb, 1.0);
	} else {
		vec3 sum = vec3(0.0);
		float total_weight = 0.0;
		vec2 logical_pixel = vec2(1.0) / max(logical_size, vec2(1.0));
		// 采样步距为三个逻辑像素，小于缓存像素宽度，防止稀疏采样产生条纹。
		for (int tap = -64; tap <= 64; tap++) {
			float normalized_distance = float(tap) * (3.0 / 64.0);
			float weight = exp(-0.5 * normalized_distance * normalized_distance);
			vec2 sample_uv = UV + blur_axis * logical_pixel * (normalized_distance * blur_sigma);
			sample_uv = clamp(sample_uv, input_pixel_size * 0.5, vec2(1.0) - input_pixel_size * 0.5);
			sum += texture(input_texture, sample_uv).rgb * weight;
			total_weight += weight;
		}
		COLOR = vec4(sum / total_weight, 1.0);
	}
}
