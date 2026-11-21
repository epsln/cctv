class_name ProceduralSource
extends VisualSource
## A generated visual: a canvas shader rendered into its own SubViewport.
## Generators are the hook for mathematical visualisations; each is a shader
## with bounded numeric params plus the shared musical uniforms.
##
## Asset: {"id": "osc", "type": "procedural", "generator": "lissajous",
##         "params": {"freq_a": 3.0}, "size": [960, 540]}
## Unknown generators or params are rejected (source FAILED).

const GENERATORS := {
	"lissajous": "res://effects/shaders/gen_lissajous.gdshader",
}

var generator := ""
var params := {}
var px_size := Vector2i(960, 540)
var _vp: SubViewport
var _rect: ColorRect
var _mat: ShaderMaterial


func _init(gen := "", p := {}, sz: Variant = [960, 540]) -> void:
	generator = gen
	params = p.duplicate()
	px_size = Vector2i(int(sz[0]), int(sz[1]))


func prepare() -> void:
	if not GENERATORS.has(generator):
		_set_state(State.FAILED, "unknown generator '%s'" % generator)
		return
	_mat = ShaderMaterial.new()
	_mat.shader = load(GENERATORS[generator])
	var known := []
	for u in _mat.shader.get_shader_uniform_list():
		known.append(u["name"])
	for k in params:
		if k not in known or k in Effect.MUSICAL:
			_set_state(State.FAILED, "generator %s has no param '%s'" % [generator, k])
			return
		_mat.set_shader_parameter(k, params[k])
	if "aspect" in known and not params.has("aspect"):
		_mat.set_shader_parameter("aspect", float(px_size.x) / float(px_size.y))
	_vp = SubViewport.new()
	_vp.size = px_size
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_rect = ColorRect.new()
	_rect.size = Vector2(px_size)
	_rect.material = _mat
	_vp.add_child(_rect)
	add_child(_vp)
	_set_state(State.READY)


func set_param(k: String, v: Variant) -> void:
	params[k] = v
	if _mat:
		_mat.set_shader_parameter(k, v)


## Musical uniforms (called by Layer every frame).
func set_uniforms(u: Dictionary) -> void:
	if _mat:
		for k in u:
			if k != "uTime":  # generator time is the source's own playhead
				_mat.set_shader_parameter(k, u[k])


func update(t: float) -> void:
	if _mat:
		_mat.set_shader_parameter("uTime", t - start_time)


func get_playhead() -> float:
	return 0.0


func get_texture() -> Texture2D:
	return _vp.get_texture() if _vp else null


func get_size() -> Vector2i:
	return px_size


func get_class_name() -> String:
	return "ProceduralSource"
