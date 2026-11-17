class_name EffectChain
extends Node
## Ordered chain of Effect passes. Each pass renders into its own SubViewport
## (ping-pong is unnecessary because every pass has a distinct target, so no
## pass ever samples the texture it writes). An empty chain returns its input
## unchanged and allocates nothing.
##
## Used for layer-local, group and global effects. `scale` < 1 renders passes
## at reduced resolution for effects that tolerate it.

var size := Vector2i(1920, 1080)
var scale := 1.0
var effects: Array[Effect] = []
var _input: Texture2D
var _passes: Array[SubViewport] = []
var _rects: Array[TextureRect] = []


func configure(defs: Array, input: Texture2D, sz: Vector2i) -> Error:
	var parsed: Array[Effect] = []
	for d in defs:
		var e := Effect.from_dict(d)
		if not e.is_valid():
			push_error(e.error)
			return ERR_INVALID_PARAMETER
		parsed.append(e)
	effects = parsed
	size = sz
	_input = input
	_rebuild()
	return OK


func set_input(tex: Texture2D) -> void:
	_input = tex
	if not _rects.is_empty():
		_rects[0].texture = tex


func _rebuild() -> void:
	for p in _passes:
		p.queue_free()
	_passes.clear()
	_rects.clear()
	var prev := _input
	var psize := Vector2i(maxi(1, int(size.x * scale)), maxi(1, int(size.y * scale)))
	for i in effects.size():
		var vp := SubViewport.new()
		vp.name = "pass_%d_%s" % [i, effects[i].type]
		vp.size = psize
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var r := TextureRect.new()
		r.texture = prev
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.size = Vector2(psize)
		r.material = effects[i].material
		vp.add_child(r)
		add_child(vp)
		_passes.append(vp)
		_rects.append(r)
		prev = vp.get_texture()


func get_output() -> Texture2D:
	return _passes[-1].get_texture() if not _passes.is_empty() else _input


func pass_count() -> int:
	return _passes.size()


func update(u: Dictionary) -> void:
	for e in effects:
		e.apply(u)


func to_array() -> Array:
	return effects.map(func(e): return e.to_dict())
