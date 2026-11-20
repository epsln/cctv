class_name Effect
extends RefCounted
## One shader pass with parameters and musical modulation bindings.
##
## Serialized form:
##   {"type": "chromatic", "params": {"strength": 0.01},
##    "bindings": [{"param": "strength", "signal": "uBassEnergy", "amount": 0.02}]}
## A binding evaluates   param = base + amount * signal   every frame.
## Unknown types/params are rejected (never silently ignored).

const LIBRARY := {
	"chromatic": "res://effects/shaders/chromatic.gdshader",
	"glitch": "res://effects/shaders/glitch.gdshader",
	"kaleidoscope": "res://effects/shaders/kaleidoscope.gdshader",
	"edge_detect": "res://effects/shaders/edge_detect.gdshader",
	"bloom": "res://effects/shaders/bloom.gdshader",
	"color_grade": "res://effects/shaders/color_grade.gdshader",
}
const MUSICAL := [
	"uTime",
	"uBeatPhase",
	"uBeatEnvelope",
	"uBassEnergy",
	"uMidEnergy",
	"uHighEnergy",
	"uOnsetEnvelope",
	"uEnergyTrend",
	"uBeatConfidence",
	"uBarPhase",
]

var type := ""
var params := {}
var bindings: Array = []
var material: ShaderMaterial
var error := ""


static func types() -> Array:
	return LIBRARY.keys()


static func from_dict(d: Dictionary) -> Effect:
	var e := Effect.new()
	e.type = d.get("type", "")
	if not LIBRARY.has(e.type):
		e.error = "unknown effect type '%s'" % e.type
		return e
	e.material = ShaderMaterial.new()
	e.material.shader = load(LIBRARY[e.type])
	var known := e.param_names()
	for k in d.get("params", {}):
		if k not in known:
			e.error = "effect '%s' has no param '%s'" % [e.type, k]
			return e
		e.params[k] = d["params"][k]
		e.material.set_shader_parameter(k, d["params"][k])
	for b in d.get("bindings", []):
		if b.get("param") not in known or b.get("signal") not in MUSICAL:
			e.error = "invalid binding %s" % str(b)
			return e
		e.bindings.append(b.duplicate())
	return e


func is_valid() -> bool:
	return error == ""


func param_names() -> Array:
	var out := []
	for u in material.shader.get_shader_uniform_list():
		if u["name"] not in MUSICAL:
			out.append(u["name"])
	return out


func base_value(p: String) -> Variant:
	if params.has(p):
		return params[p]
	var v: Variant = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), p)
	if v == null:
		# Dummy renderer (headless) does not track defaults: parse the source.
		v = parse_default(material.shader.code, p)
	return v


## Scalar default of `uniform <type> name = <number>;` in shader code, else 0.
static func parse_default(code: String, p: String) -> float:
	var re := RegEx.create_from_string("uniform\\s+\\w+\\s+" + p + "\\b[^=;]*=\\s*([-+0-9.eE]+)")
	var m := re.search(code)
	return float(m.get_string(1)) if m else 0.0


## Push musical uniforms and evaluate bindings. Returns evaluated params.
func apply(u: Dictionary) -> Dictionary:
	var out := {}
	for k in u:
		material.set_shader_parameter(k, u[k])
	for b in bindings:
		var v: float = float(base_value(b["param"])) + float(b["amount"]) * float(u.get(b["signal"], 0.0))
		material.set_shader_parameter(b["param"], v)
		out[b["param"]] = v
	return out


func to_dict() -> Dictionary:
	return {"type": type, "params": params.duplicate(), "bindings": bindings.duplicate(true)}
