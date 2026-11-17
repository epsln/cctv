shader_type canvas_item;
#include "res://effects/shaders/musical.gdshaderinc"

// Colour treatment: saturation, contrast, tint, exposure pulse.
uniform float saturation = 1.0;
uniform float contrast = 1.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float exposure_pulse = 0.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float l = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
	vec3 rgb = mix(vec3(l), c.rgb, saturation);
	rgb = (rgb - 0.5) * contrast + 0.5;
	rgb *= tint.rgb * (1.0 + exposure_pulse * uBeatEnvelope);
	COLOR = vec4(clamp(rgb, 0.0, 1.0), c.a);
}
