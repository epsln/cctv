class_name LayerGroup
extends Control
## Combines child layers under a shared transform, opacity, clip mask and
## effect chain.
##
## {"kind": "group", "id": "panels", "rect": [...], "opacity": 1.0, "clip": true,
##  "effects": [...], "children": [...]}
##
## Children are drawn as ordinary 2D unless the group has effects, in which case
## (and only then) they render into an intermediate SubViewport at the group's
## pixel size, which the effect chain consumes.

var layer_id := ""
var norm_rect := Rect2(0, 0, 1, 1)
var opacity := 1.0
var clip := false
var content: Control
var chain: EffectChain
var effect_defs: Array = []
var _vp: SubViewport
var _px_size := Vector2i.ZERO


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(d: Dictionary) -> Error:
	layer_id = d.get("id", "")
	name = ("group_" + layer_id).validate_node_name()
	var r: Array = d.get("rect", [0, 0, 1, 1])
	norm_rect = Rect2(r[0], r[1], r[2], r[3])
	opacity = float(d.get("opacity", 1.0))
	clip = bool(d.get("clip", false))
	clip_contents = clip
	effect_defs = d.get("effects", [])
	for e in effect_defs:
		if not Effect.from_dict(e).is_valid():
			return ERR_INVALID_PARAMETER
	content = Control.new()
	content.name = "content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chain = EffectChain.new()
	chain.name = "effects"
	add_child(chain)
	if is_offscreen():
		_vp = SubViewport.new()
		_vp.name = "offscreen"
		_vp.transparent_bg = true
		_vp.disable_3d = true
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_vp.add_child(content)
		add_child(_vp)
	else:
		add_child(content)
	return OK


func is_offscreen() -> bool:
	return not effect_defs.is_empty()


func add_item(item: Control) -> void:
	content.add_child(item)


func items() -> Array:
	return content.get_children()


func layout(parent_size: Vector2) -> void:
	position = norm_rect.position * parent_size
	size = norm_rect.size * parent_size
	pivot_offset = size * 0.5
	content.size = size
	var px := Vector2i(size.round()).maxi(1)
	if _vp and px != _px_size:
		_px_size = px
		_vp.size = px
		chain.configure(effect_defs, _vp.get_texture(), px)
	for it in items():
		it.layout(size)


func update(t: float, u: Dictionary) -> void:
	modulate.a = opacity
	for it in items():
		it.update(t, u)
	if _vp:
		chain.update(u)
		queue_redraw()


func _draw() -> void:
	if _vp:
		draw_texture_rect(chain.get_output(), Rect2(Vector2.ZERO, size), false)


func to_dict() -> Dictionary:
	return {
		"kind": "group", "id": layer_id,
		"rect": [norm_rect.position.x, norm_rect.position.y, norm_rect.size.x, norm_rect.size.y],
		"opacity": opacity, "clip": clip, "effects": effect_defs.duplicate(true),
		"children": items().map(func(c): return c.to_dict()),
	}
