class_name FeedbackPass
extends Node
## Ping-pong temporal feedback.
##
## Two render targets alternate roles every frame: the target being written
## samples the *other* target as history, so no texture is ever read while it
## is written. Only the write target is rendered each frame (UPDATE_ONCE).
## reset() discards history (wired to MusicalClock.seeked) so seek/replay
## starts from a defined state.

const SHADER := preload("res://effects/shaders/feedback.gdshader")

var enabled := true
var params := {"decay": 0.85, "zoom": 0.995, "spin": 0.3, "mode": 0, "beat_cut": 0.2}
var frames_rendered := 0
var resets := 0

var _vps: Array[SubViewport] = []
var _rects: Array[TextureRect] = []
var _mats: Array[ShaderMaterial] = []
var _write := 0
var _input: Texture2D
var _clear_pending := true


func setup(input: Texture2D, sz: Vector2i) -> void:
	_input = input
	for v in _vps:
		v.queue_free()
	_vps.clear()
	_rects.clear()
	_mats.clear()
	for i in 2:
		var vp := SubViewport.new()
		vp.name = "feedback_%d" % i
		vp.size = sz
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var m := ShaderMaterial.new()
		m.shader = SHADER
		var r := TextureRect.new()
		r.texture = input
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.size = Vector2(sz)
		r.material = m
		vp.add_child(r)
		add_child(vp)
		_vps.append(vp)
		_rects.append(r)
		_mats.append(m)
	for i in 2:
		_mats[i].set_shader_parameter("history", _vps[1 - i].get_texture())
	_clear_pending = true


func set_input(tex: Texture2D) -> void:
	_input = tex
	for r in _rects:
		r.texture = tex


func set_params(p: Dictionary) -> void:
	for k in p:
		if not params.has(k):
			push_error("feedback has no param " + k)
			continue
		params[k] = p[k]


func bind_clock(clock: MusicalClock) -> void:
	clock.seeked.connect(func(_t): reset())


func reset() -> void:
	_clear_pending = true
	resets += 1


func write_index() -> int:
	return _write


## Call once per frame before rendering.
func update(u: Dictionary) -> void:
	if not enabled or _vps.is_empty():
		return
	_write = 1 - _write
	var m := _mats[_write]
	for k in u:
		m.set_shader_parameter(k, u[k])
	for k in params:
		m.set_shader_parameter(k, params[k])
	m.set_shader_parameter("history_gain", 0.0 if _clear_pending else 1.0)
	_clear_pending = false
	_vps[_write].render_target_update_mode = SubViewport.UPDATE_ONCE
	frames_rendered += 1


func get_output() -> Texture2D:
	if not enabled or _vps.is_empty():
		return _input
	return _vps[_write].get_texture()
