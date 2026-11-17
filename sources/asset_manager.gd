class_name AssetManager
extends Node
## Registry of library assets and factory for source instances.
##
## Manifest format (JSON): {"version": 1, "assets": [
##   {"id": "news1", "type": "video", "path": "...ogv"},
##   {"id": "cam", "type": "image", "path": "...png"},
##   {"id": "doc", "type": "pdf_page", "path": "...pdf", "page": 2},
##   {"id": "tick", "type": "text", "text": "...", "style": "ticker"}]}
##
## shared(id) returns one instance per asset (shared playhead);
## instance(id) creates an independent playhead each call.

var assets := {}
var pdf_cache_dir := "user://pdf_cache"
var _shared := {}
var _counter := 0


func load_manifest(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY or not data.has("assets"):
		return ERR_PARSE_ERROR
	var base := path.get_base_dir()
	for a in data["assets"]:
		var entry: Dictionary = a.duplicate()
		if entry.has("path") and entry["path"].is_relative_path():
			entry["path"] = base.path_join(entry["path"])
		register(entry)
	return OK


func register(entry: Dictionary) -> void:
	assert(entry.has("id") and entry.has("type"))
	assets[entry["id"]] = entry


func ids_of_type(t: String) -> Array:
	return assets.keys().filter(func(k): return assets[k]["type"] == t)


func shared(asset_id: String) -> VisualSource:
	if not _shared.has(asset_id) or not is_instance_valid(_shared[asset_id]):
		_shared[asset_id] = instance(asset_id)
	return _shared[asset_id]


func instance(asset_id: String) -> VisualSource:
	if not assets.has(asset_id):
		push_error("unknown asset " + asset_id)
		return null
	var e: Dictionary = assets[asset_id]
	var s: VisualSource
	match e["type"]:
		"video":
			s = TheoraVideoSource.new(e["path"])
		"image":
			s = ImageSource.new(e["path"])
		"pdf_page":
			s = PdfPageSource.new(e["path"], int(e.get("page", 1)), pdf_cache_dir)
		"text":
			s = TextSource.new(e.get("text", ""), e.get("style", "caption"))
		_:
			push_error("unknown asset type " + str(e["type"]))
			return null
	_counter += 1
	s.asset_id = asset_id
	s.source_id = "%s#%d" % [asset_id, _counter]
	s.name = s.source_id.validate_node_name()
	s.metadata.merge(e.get("metadata", {}))
	add_child(s)
	s.prepare()
	return s


func release(s: VisualSource) -> void:
	if _shared.get(s.asset_id) == s:
		_shared.erase(s.asset_id)
	s.queue_free()


func update(t: float) -> void:
	for c in get_children():
		(c as VisualSource).update(t)


func describe() -> Array:
	return get_children().map(func(c): return c.describe())
