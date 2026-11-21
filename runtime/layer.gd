class_name Layer
extends Control
## A source drawn into a normalized rect of its parent, with crop, opacity,
## blend mode, a local effect chain and musical modulation bindings.
##
## Serialized form (all coordinates normalized to the parent container):
##   {"kind": "layer", "id": "news", "asset": "news1", "instance": "shared",
##    "start": 0.0, "rect": [x, y, w, h], "rotation": 0.0, "crop": [u, v, w, h],
##    "opacity": 1.0, "blend": "mix", "effects": [...],
##    "bindings": [{"prop": "opacity", "signal": "uBeatEnvelope", "amount": -0.3}],
##    "motion": {"wobble": 0.02, "freq": 0.1, "phase": 0.0}}
## Bindable props: opacity, rotation (deg), scale, x, y (offsets, normalized).
## motion: slow elliptical drift of amplitude `wobble` (normalized) at `freq` Hz.

const BLENDS := {
	"mix": CanvasItemMaterial.BLEND_MODE_MIX,
	"add": CanvasItemMaterial.BLEND_MODE_ADD,
	"sub": CanvasItemMaterial.BLEND_MODE_SUB,
	"mul": CanvasItemMaterial.BLEND_MODE_MUL,
}
const BINDABLE := ["opacity", "rotation", "scale", "x", "y"]

var layer_id := ""
var source: VisualSource
var owns_source := false
var instance_mode := "shared"
var norm_rect := Rect2(0, 0, 1, 1)
var crop := Rect2(0, 0, 1, 1)
var opacity := 1.0
var blend := "mix"
var rotation_deg := 0.0
var scale_factor := 1.0
var bindings: Array = []
var motion := {}
var chain: EffectChain
var error := ""
var _parent_size := Vector2.ONE


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	chain = EffectChain.new()
	chain.name = "effects"
	add_child(chain)


func configure(d: Dictionary, src: VisualSource) -> Error:
	layer_id = d.get("id", "")
	name = ("layer_" + layer_id).validate_node_name()
	source = src
	var r: Array = d.get("rect", [0, 0, 1, 1])
	norm_rect = Rect2(r[0], r[1], r[2], r[3])
	var c: Array = d.get("crop", [0, 0, 1, 1])
	crop = Rect2(c[0], c[1], c[2], c[3])
	opacity = float(d.get("opacity", 1.0))
	rotation_deg = float(d.get("rotation", 0.0))
	scale_factor = float(d.get("scale", 1.0))
	blend = d.get("blend", "mix")
	if not BLENDS.has(blend):
		error = "layer %s: unknown blend '%s'" % [layer_id, blend]
		return ERR_INVALID_PARAMETER
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = BLENDS[blend]
	material = mat
	motion = d.get("motion", {}).duplicate()
	for k in motion:
		if k not in ["wobble", "freq", "phase"]:
			error = "layer %s: unknown motion key '%s'" % [layer_id, k]
			return ERR_INVALID_PARAMETER
	for b in d.get("bindings", []):
		if b.get("prop") not in BINDABLE or b.get("signal") not in Effect.MUSICAL:
			error = "layer %s: invalid binding %s" % [layer_id, str(b)]
			return ERR_INVALID_PARAMETER
		bindings.append(b.duplicate())
	var tex := source.get_texture() if source else null
	var src_size := source.get_size() if source else Vector2i(16, 16)
	if chain.configure(d.get("effects", []), tex, src_size.maxi(1)) != OK:
		error = "layer %s: invalid effect chain" % layer_id
		return ERR_INVALID_PARAMETER
	return OK


## Lay out in parent coordinates.
func layout(parent_size: Vector2) -> void:
	_parent_size = parent_size
	position = norm_rect.position * parent_size
	size = norm_rect.size * parent_size
	pivot_offset = size * 0.5


func update(t: float, u: Dictionary) -> void:
	var op := opacity
	var rot := rotation_deg
	var sc := scale_factor
	var off := Vector2.ZERO
	if not motion.is_empty():
		var a := TAU * (float(motion.get("freq", 0.1)) * t + float(motion.get("phase", 0.0)))
		off = float(motion.get("wobble", 0.0)) * Vector2(sin(a), cos(a * 0.7))
	for b in bindings:
		var v := float(b["amount"]) * float(u.get(b["signal"], 0.0))
		match b["prop"]:
			"opacity":
				op += v
			"rotation":
				rot += v
			"scale":
				sc += v
			"x":
				off.x += v
			"y":
				off.y += v
	modulate.a = clampf(op, 0.0, 1.0)
	rotation_degrees = rot
	scale = Vector2(sc, sc)
	position = (norm_rect.position + off) * _parent_size
	if source:
		source.update(t)
		if source.has_method("set_uniforms"):
			source.set_uniforms(u)
		var tex := source.get_texture()
		if tex and chain.pass_count() > 0 and chain._input != tex:
			# Late-prepared source (e.g. async PDF page): rebuild at real size.
			chain.size = source.get_size().maxi(1)
			chain._input = tex
			chain._rebuild()
	chain.update(u)
	queue_redraw()


func output_texture() -> Texture2D:
	return chain.get_output() if chain.pass_count() > 0 else (source.get_texture() if source else null)


func _draw() -> void:
	var tex := output_texture()
	if tex == null:
		return
	var ts := tex.get_size()
	var region := Rect2(crop.position * ts, crop.size * ts)
	draw_texture_rect_region(tex, Rect2(Vector2.ZERO, size), region)


func to_dict() -> Dictionary:
	return {
		"kind": "layer",
		"id": layer_id,
		"asset": source.asset_id if source else "",
		"instance": instance_mode,
		"start": source.start_time if source else 0.0,
		"rect": [norm_rect.position.x, norm_rect.position.y, norm_rect.size.x, norm_rect.size.y],
		"rotation": rotation_deg,
		"scale": scale_factor,
		"crop": [crop.position.x, crop.position.y, crop.size.x, crop.size.y],
		"opacity": opacity,
		"blend": blend,
		"effects": chain.to_array(),
		"bindings": bindings.duplicate(true),
		"motion": motion.duplicate(),
	}
