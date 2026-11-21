shader_type canvas_item;
// Procedural generator: Lissajous / phase-scope figure. First of the
// mathematical visualisation generators (ProceduralSource).
#include "res://effects/shaders/musical.gdshaderinc"

uniform float freq_a = 3.0;
uniform float freq_b = 2.0;
uniform float phase_speed = 0.25;
uniform float thickness = 0.004;
uniform vec4 line_color : source_color = vec4(0.6, 1.0, 0.6, 1.0);
uniform float grid = 0.15;
uniform float aspect = 1.7778;

const int N = 96;

float seg(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

void fragment() {
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0) * 2.2;
	float ph = uTime * phase_speed + uBeatEnvelope * 0.15;
	float amp = 0.85 + 0.15 * uBassEnergy;
	float d = 1e3;
	vec2 prev = amp * vec2(sin(ph), sin(0.0));
	for (int i = 1; i <= N; i++) {
		float s = 6.2831853 * float(i) / float(N);
		vec2 q = amp * vec2(sin(freq_a * s + ph), sin(freq_b * s));
		d = min(d, seg(p, prev, q));
		prev = q;
	}
	float w = thickness * 2.2 * (1.0 + 2.0 * uOnsetEnvelope);
	float line = smoothstep(w, w * 0.3, d);
	float glow = exp(-d * 30.0) * 0.35;
	vec2 g = abs(fract(p * 4.0) - 0.5);
	float gl = grid * smoothstep(0.49, 0.5, max(g.x, g.y));
	vec3 c = line_color.rgb * (line + glow) + vec3(gl * 0.5);
	COLOR = vec4(c, 1.0);
}
