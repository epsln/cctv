shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

uniform float amount = 0.05;
uniform float speed = 4.0;
uniform float seed = 0.0;

float rand(float x) { return fract(sin(x * 127.1 + seed) * 43758.5453); }

void fragment() {
	float t = floor(uTime * speed) / speed;
	float amt = amount * (1.0 + uOnsetEnvelope * 3.0);
	float band = floor(UV.y * 20.0 + t * 7.0);
	float jitter = (rand(band + t) * 2.0 - 1.0) * amt;
	float line = rand(floor(uTime * 13.0)) * 0.95;
	jitter += step(abs(UV.y - line), 0.01) * (rand(t) * 2.0 - 1.0) * amt * 5.0;
	vec2 uv_g = UV + vec2(jitter, 0.0);
	vec2 uv_r = uv_g + vec2(amt * rand(t + 0.3) * 0.5, 0.0);
	vec2 uv_b = uv_g - vec2(amt * rand(t + 0.7) * 0.5, 0.0);
	float scan = sin(UV.y / TEXTURE_PIXEL_SIZE.y * 1.5) * 0.03 * uBassEnergy * min(amount * 20.0, 1.0);
	vec4 g = texture(TEXTURE, clamp(uv_g, 0.0, 1.0));
	COLOR = vec4(
		texture(TEXTURE, clamp(uv_r, 0.0, 1.0)).r + scan,
		g.g,
		texture(TEXTURE, clamp(uv_b, 0.0, 1.0)).b - scan,
		g.a);
}
