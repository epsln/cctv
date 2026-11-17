class_name Composition
extends SubViewport
## An offscreen composition: an ordered tree of layers, groups and annotations
## rendered into its own texture so it can be transitioned and post-processed.
##
## {"id": "grid", "background": [0, 0, 0, 1], "layers": [<layer|group|annotation>...]}
##
## build() validates everything and returns an error without partial effects on
## any other composition, so callers can prepare a composition and only swap
## it in when it is valid (transactional preparation).

var comp_id := ""
var background := Color.BLACK
var root: Control
var errors: PackedStringArray = []
var assets: AssetManager
var _bg: ColorRect
var _index := {}
var _owned_sources: Array[VisualSource] = []
var _source_offsets := {}


func _init() -> void:
	transparent_bg = false
	disable_3d = true
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	size = Vector2i(1920, 1080)


func build(d: Dictionary, am: AssetManager, sz := Vector2i(1920, 1080)) -> Error:
	assets = am
	size = sz
	comp_id = d.get("id", "")
	name = ("comp_" + comp_id).validate_node_name()
	var bg: Array = d.get("background", [0, 0, 0, 1])
	background = Color(bg[0], bg[1], bg[2], bg[3] if bg.size() > 3 else 1.0)
	_bg = ColorRect.new()
	_bg.color = background
	_bg.size = Vector2(sz)
	add_child(_bg)
	root = Control.new()
	root.name = "root"
	root.size = Vector2(sz)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	for item in d.get("layers", []):
		var node := _build_item(item)
		if node:
			root.add_child(node)
	_resolve_targets(root)
	if not errors.is_empty():
		for e in errors:
			push_error("composition %s: %s" % [comp_id, e])
		return ERR_INVALID_DATA
	relayout()
	return OK


func _build_item(d: Dictionary) -> Control:
	var id: String = d.get("id", "")
	if id == "" or _index.has(id):
		errors.append("missing or duplicate id '%s'" % id)
		return null
	var kind: String = d.get("kind", "layer")
	match kind:
		"layer":
			var src: VisualSource
			var mode: String = d.get("instance", "shared")
			if not assets.assets.has(d.get("asset", "")):
				errors.append("layer %s: unknown asset '%s'" % [id, d.get("asset", "")])
				return null
			if mode == "independent":
				src = assets.instance(d["asset"])
				_owned_sources.append(src)
				_source_offsets[src] = float(d.get("start", 0.0))
			elif mode == "shared":
				src = assets.shared(d["asset"])
			else:
				errors.append("layer %s: unknown instance mode '%s'" % [id, mode])
				return null
			var l := Layer.new()
			l.instance_mode = mode
			l.owns_source = mode == "independent"
			if l.configure(d, src) != OK:
				errors.append(l.error)
				l.free()
				return null
			_index[id] = l
			return l
		"group":
			var g := LayerGroup.new()
			if g.configure(d) != OK:
				errors.append("group %s: invalid effects" % id)
				g.free()
				return null
			_index[id] = g
			for c in d.get("children", []):
				var n := _build_item(c)
				if n:
					g.add_item(n)
			return g
		"annotation":
			var a := AnnotationLayer.new()
			if a.configure(d) != OK:
				errors.append(a.error)
				a.free()
				return null
			_index[id] = a
			return a
	errors.append("item %s: unknown kind '%s'" % [id, kind])
	return null


func _resolve_targets(node: Node) -> void:
	for c in node.get_children():
		if c is AnnotationLayer and c.target_id != "":
			var t = _index.get(c.target_id)
			if t is Layer:
				c.target = t
			else:
				errors.append("annotation %s: target '%s' is not a layer" % [c.layer_id, c.target_id])
		elif c is LayerGroup:
			_resolve_targets(c.content)


func relayout() -> void:
	_bg.size = Vector2(size)
	root.size = Vector2(size)
	for it in root.get_children():
		it.layout(Vector2(size))


## Called when the composition becomes active; aligns independent playheads.
func activate(t: float) -> void:
	for s in _owned_sources:
		s.start_time = t - _source_offsets.get(s, 0.0)


func update(t: float, u: Dictionary) -> void:
	for it in root.get_children():
		it.update(t, u)


func find(id: String) -> Control:
	return _index.get(id)


func ids() -> Array:
	return _index.keys()


func release() -> void:
	for s in _owned_sources:
		if is_instance_valid(s):
			assets.release(s)
	_owned_sources.clear()
	queue_free()


func to_dict() -> Dictionary:
	return {
		"id": comp_id,
		"background": [background.r, background.g, background.b, background.a],
		"layers": root.get_children().map(func(c): return c.to_dict()),
	}
