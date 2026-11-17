shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

uniform float strength = 0.008;
uniform float barrel = 0.15;
uniform float energy_mod = 2.0;

vec2 barrel_uv(vec2 uv, float k) {
	vec2 c = uv - 0.5;
	return 0.5 + c * (1.0 + k * dot(c, c));
}

void fragment() {
	float s = strength * (1.0 + uBassEnergy * energy_mod);
	float b = barrel * (1.0 + uBeatEnvelope * 0.5);
	vec2 dir = normalize(UV - 0.5 + 0.001);
	vec4 g = texture(TEXTURE, barrel_uv(UV, b));
	COLOR = vec4(
		texture(TEXTURE, barrel_uv(UV + dir * s, b)).r,
		g.g,
		texture(TEXTURE, barrel_uv(UV - dir * s, b)).b,
		g.a);
}
