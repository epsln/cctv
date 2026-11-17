shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

uniform float segments = 6.0;
uniform float rotation = 0.2;

void fragment() {
	vec2 uv = UV - 0.5;
	float r = length(uv);
	float a = atan(uv.y, uv.x);
	float seg = PI / max(segments, 1.0);
	a = mod(a + uTime * rotation * (1.0 + uBassEnergy), 2.0 * seg);
	if (a > seg) {
		a = 2.0 * seg - a;
	}
	COLOR = texture(TEXTURE, clamp(vec2(r * cos(a), r * sin(a)) + 0.5, 0.0, 1.0));
}
