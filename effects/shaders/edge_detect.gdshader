shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

// Laplacian edge detection. Offsets are in texels (the old GLSL version
// offset by whole UV units, which sampled outside the texture).
uniform float gain = 1.0;
uniform float mix_amount = 1.0;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec3 c = 8.0 * texture(TEXTURE, UV).rgb;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			if (x != 0 || y != 0) {
				c -= texture(TEXTURE, UV + vec2(float(x), float(y)) * px).rgb;
			}
		}
	}
	float lo = min(c.r, min(c.g, c.b));
	float hi = max(c.r, max(c.g, c.b));
	vec3 e = vec3(0.5 + gain * (1.0 + uBeatEnvelope) * (abs(lo) > abs(hi) ? lo : hi));
	vec4 base = texture(TEXTURE, UV);
	COLOR = vec4(mix(base.rgb, e, mix_amount), base.a);
}
