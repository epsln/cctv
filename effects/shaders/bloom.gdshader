shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

uniform float threshold = 0.6;
uniform float intensity = 1.5;
uniform int radius = 4;
uniform float energy_mod = 2.0;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 bloom = vec3(0.0);
	float total = 0.0;
	int r = clamp(radius, 1, 8);
	// Sparse 2-texel stride keeps cost bounded at 1080p.
	for (int x = -r; x <= r; x++) {
		for (int y = -r; y <= r; y++) {
			vec3 s = texture(TEXTURE, UV + vec2(float(x), float(y)) * TEXTURE_PIXEL_SIZE * 2.0).rgb;
			float b = max(0.0, luma(s) - threshold);
			bloom += s * b;
			total += b;
		}
	}
	if (total > 0.0) {
		bloom /= total;
	}
	COLOR = vec4(base.rgb + bloom * intensity * (1.0 + uBassEnergy * energy_mod), base.a);
}
