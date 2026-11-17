shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

// TEXTURE = outgoing composition (slot A), tex_b = incoming (slot B).
uniform sampler2D tex_b : filter_linear;
uniform float progress = 0.0;
uniform int kind = 0; // 0 cut, 1 crossfade, 2 wipe, 3 glitch_cut
uniform vec2 wipe_dir = vec2(1.0, 0.0);
uniform float softness = 0.05;

float rand(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec4 a = texture(TEXTURE, UV);
	vec4 b = texture(tex_b, UV);
	float p = clamp(progress, 0.0, 1.0);
	float w = 0.0;
	if (kind == 0) {
		w = step(0.5, p);
	} else if (kind == 1) {
		w = p;
	} else if (kind == 2) {
		vec2 d = normalize(wipe_dir);
		// project UV onto direction, normalised to 0..1 across the frame
		float x = dot(UV - 0.5, d) / (abs(d.x) * 0.5 + abs(d.y) * 0.5) * 0.5 + 0.5;
		w = 1.0 - smoothstep(p * (1.0 + softness) - softness, p * (1.0 + softness), x);
	} else {
		// glitch cut: horizontal bands switch at random thresholds
		float band = floor(UV.y * 24.0);
		float r = rand(vec2(band, floor(p * 8.0)));
		w = step(r, p * 1.15 - 0.05);
		vec2 off = vec2((rand(vec2(band, uTime)) - 0.5) * 0.08 * (1.0 - abs(2.0 * p - 1.0)), 0.0);
		a = texture(TEXTURE, UV + off);
		b = texture(tex_b, UV - off);
	}
	COLOR = mix(a, b, w);
}
