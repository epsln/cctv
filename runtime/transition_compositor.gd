class_name TransitionCompositor
extends SubViewport
## Two composition slots and the transition between them.
##
## Slot A is the active composition; slot B only exists during a transition,
## so steady-state cost is one composition. Progress is derived from clock
## time, never wall time, so transitions replay identically.

signal transition_started(from_id: String, to_id: String, kind: String)
signal transition_finished(comp_id: String)

const SHADER := preload("res://effects/shaders/transition.gdshader")
const KINDS := {"cut": 0, "crossfade": 1, "wipe": 2, "glitch_cut": 3}

var slot_a: Composition
var slot_b: Composition
var kind := "crossfade"
var t_start := 0.0
var duration := 1.0
var progress := 0.0
var _rect: TextureRect
var _mat: ShaderMaterial
var _empty: ImageTexture


func _init() -> void:
	disable_3d = true
	transparent_bg = false
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	_empty = ImageTexture.create_from_image(img)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_rect = TextureRect.new()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.material = _mat
	_rect.texture = _empty
	add_child(_rect)
	set_size_px(Vector2i(1920, 1080))


func set_size_px(sz: Vector2i) -> void:
	size = sz
	_rect.size = Vector2(sz)


## Install a composition immediately (no transition).
func set_active(c: Composition, t: float) -> void:
	if slot_a and slot_a != c:
		slot_a.release()
	if slot_b:
		slot_b.release()
		slot_b = null
	slot_a = c
	_adopt(c)
	c.activate(t)
	_rect.texture = c.get_texture()
	progress = 0.0
	_mat.set_shader_parameter("progress", 0.0)


func is_transitioning() -> bool:
	return slot_b != null


## Begin a transition to c at clock time t0 lasting dur seconds.
func start(c: Composition, k: String, t0: float, dur: float) -> Error:
	if not KINDS.has(k):
		push_error("unknown transition " + k)
		return ERR_INVALID_PARAMETER
	if slot_a == null or k == "cut" and dur <= 0.0:
		set_active(c, t0)
		transition_finished.emit(c.comp_id)
		return OK
	if slot_b:
		_finish()  # complete an in-flight transition before starting another
	slot_b = c
	_adopt(c)
	c.activate(t0)
	kind = k
	t_start = t0
	duration = maxf(dur, 1e-3)
	progress = 0.0
	_mat.set_shader_parameter("kind", KINDS[k])
	_mat.set_shader_parameter("tex_b", c.get_texture())
	transition_started.emit(slot_a.comp_id, c.comp_id, k)
	return OK


func update(t: float, u: Dictionary) -> void:
	for k in u:
		_mat.set_shader_parameter(k, u[k])
	if slot_a:
		slot_a.update(t, u)
	if slot_b:
		slot_b.update(t, u)
		progress = clampf((t - t_start) / duration, 0.0, 1.0)
		_mat.set_shader_parameter("progress", progress)
		if progress >= 1.0:
			_finish()


func _finish() -> void:
	var b := slot_b
	slot_b = null
	if slot_a:
		slot_a.release()
	slot_a = b
	_rect.texture = b.get_texture()
	progress = 0.0
	_mat.set_shader_parameter("progress", 0.0)
	transition_finished.emit(b.comp_id)


func _adopt(c: Composition) -> void:
	if c.get_parent() != self:
		if c.get_parent():
			c.get_parent().remove_child(c)
		add_child(c)


func active_id() -> String:
	return slot_a.comp_id if slot_a else ""


func describe() -> Dictionary:
	return {
		"active": active_id(),
		"incoming": slot_b.comp_id if slot_b else "",
		"kind": kind if slot_b else "",
		"progress": progress,
	}
