shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

// Temporal feedback. TEXTURE is the current input; history is the PREVIOUS
// output, held in the other ping-pong target (never the target being written).
uniform sampler2D history : filter_linear;
uniform float history_gain = 1.0; // 0 for one frame after reset
uniform float decay = 0.85;
uniform float zoom = 0.995;
uniform float spin = 0.3; // degrees per frame
uniform int mode = 0; // 0 = max (trails), 1 = mix (smear)
uniform float beat_cut = 0.2; // decay reduction on beat

mat2 rot2(float a) {
	float c = cos(a), s = sin(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

void fragment() {
	float ang = radians(spin) * (1.0 + uBassEnergy);
	vec2 fb_uv = 0.5 + rot2(ang) * (UV - 0.5) * zoom;
	vec4 cur = texture(TEXTURE, UV);
	vec4 trail = texture(history, fb_uv) * decay * (1.0 - uBeatEnvelope * beat_cut) * history_gain;
	COLOR = mode == 0 ? max(cur, trail) : mix(cur, trail, clamp(decay * history_gain, 0.0, 1.0));
}
