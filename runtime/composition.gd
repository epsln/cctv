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
var _shared_sources: Array[VisualSource] = []
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
		var node := _build_item(item, float(sz.y))
		if node:
			root.add_child(node)
	_resolve_targets(root)
	if not errors.is_empty():
		for e in errors:
			push_error("composition %s: %s" % [comp_id, e])
		return ERR_INVALID_DATA
	relayout()
	return OK


## parent_h: on-screen height of the parent container in output pixels, used to
## choose the video proxy resolution.
func _build_item(d: Dictionary, parent_h: float) -> Control:
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
			var target_h := ceili(parent_h * _rect_h(d) * float(d.get("scale", 1.0)))
			if mode == "independent":
				src = assets.instance(d["asset"], target_h)
				_owned_sources.append(src)
				_source_offsets[src] = float(d.get("start", 0.0))
			elif mode == "shared":
				src = assets.shared(d["asset"], target_h)
				_shared_sources.append(src)
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
				var n := _build_item(c, parent_h * _rect_h(d))
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


static func _rect_h(d: Dictionary) -> float:
	var r: Array = d.get("rect", [0, 0, 1, 1])
	return float(r[3])


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
	for s in _owned_sources + _shared_sources:
		if is_instance_valid(s):
			assets.release(s)
	_owned_sources.clear()
	_shared_sources.clear()
	queue_free()


## Add an item to a built composition (live editing by composition families),
## at top level or inside group `parent_id`. Transactional: on error nothing
## is added. at_index < 0 appends. Independent sources start at clock time t.
func add_item(d: Dictionary, at_index := -1, t := 0.0, parent_id := "") -> Error:
	errors = []
	var container: Control = root
	var parent_h := float(size.y)
	if parent_id != "":
		var g = _index.get(parent_id)
		if not g is LayerGroup:
			errors.append("add_item: '%s' is not a group" % parent_id)
			push_error("composition %s: %s" % [comp_id, errors[0]])
			return ERR_INVALID_PARAMETER
		container = g.content
		parent_h *= g.norm_rect.size.y
	var owned_before := _owned_sources.size()
	var node := _build_item(d, parent_h)
	if node:
		_resolve_targets_of(node)
	if not errors.is_empty():
		for e in errors:
			push_error("composition %s: %s" % [comp_id, e])
		if node:
			_unindex(node)
			_release_sources_of(node)
			node.free()
		return ERR_INVALID_DATA
	container.add_child(node)
	if at_index >= 0:
		container.move_child(node, mini(at_index, container.get_child_count() - 1))
	node.layout(container.size)
	for i in range(owned_before, _owned_sources.size()):
		var s := _owned_sources[i]
		s.start_time = t - _source_offsets.get(s, 0.0)
	return OK


## Remove an item (and annotations targeting it), releasing its sources.
func remove_item(id: String) -> Error:
	var node: Control = _index.get(id)
	if node == null:
		return ERR_DOES_NOT_EXIST
	for k in _index.keys():
		var c = _index.get(k)
		if c is AnnotationLayer and c.target and (c.target == node or node.is_ancestor_of(c.target)):
			_unindex(c)
			c.get_parent().remove_child(c)
			c.queue_free()
	_unindex(node)
	_release_sources_of(node)
	node.get_parent().remove_child(node)
	node.queue_free()
	return OK


## Index of an item within its container (for in-place replacement).
func index_of(id: String) -> int:
	var node: Control = _index.get(id)
	return node.get_index() if node else -1


func top_level_ids() -> Array:
	return root.get_children().map(func(c): return _id_of(c))


static func _id_of(n: Node) -> String:
	return str(n.get("layer_id")) if "layer_id" in n else ""


func _unindex(n: Node) -> void:
	_index.erase(_id_of(n))
	if n is LayerGroup:
		for c in n.content.get_children():
			_unindex(c)


func _release_sources_of(n: Node) -> void:
	if n is Layer and n.source:
		var s: VisualSource = n.source
		_owned_sources.erase(s)
		_shared_sources.erase(s)
		_source_offsets.erase(s)
		assets.release(s)
	elif n is LayerGroup:
		for c in n.content.get_children():
			_release_sources_of(c)


func _resolve_targets_of(n: Node) -> void:
	if n is AnnotationLayer and n.target_id != "":
		var t = _index.get(n.target_id)
		if t is Layer:
			n.target = t
		else:
			errors.append("annotation %s: target '%s' is not a layer" % [n.layer_id, n.target_id])
	elif n is LayerGroup:
		_resolve_targets(n.content)


func to_dict() -> Dictionary:
	return {
		"id": comp_id,
		"background": [background.r, background.g, background.b, background.a],
		"layers": root.get_children().map(func(c): return c.to_dict()),
	}
