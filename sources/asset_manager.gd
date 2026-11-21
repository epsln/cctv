class_name AssetManager
extends Node
## Registry of library assets and factory for source instances.
##
## Manifest v1 (hand-written): {"version": 1, "assets": [
##   {"id": "news1", "type": "video", "path": "...ogv"},
##   {"id": "cam", "type": "image", "path": "...png"},
##   {"id": "doc", "type": "pdf_page", "path": "...pdf", "page": 2},
##   {"id": "tick", "type": "text", "text": "...", "style": "ticker"},
##   {"id": "osc", "type": "procedural", "generator": "lissajous", "params": {...}}]}
##
## Manifest v2 (written by `cctv-ingest`, see docs/milestone-3.md) adds
## "schema", "library_version" and per asset "content_hash", "tags", "size",
## "duration", "proxies" [{"height", "path"}], "thumbnail", "analyses"
## {step: version} and "faces" (path to a face-track file loaded on demand
## into source metadata["face_tracks"]). pdf_page assets point at a raster PNG.
##
## shared(id) returns one reference-counted instance per (asset, proxy)
## (shared playhead), freed when the last user release()s it.
## instance(id) creates an independent playhead each call.
## Both accept a target height in output pixels to pick the smallest video
## proxy that covers it (0 = largest).

const TYPES := ["video", "image", "pdf_page", "text", "procedural"]

var assets := {}
var library_version := ""
var manifest_version := 0
var pdf_cache_dir := "user://pdf_cache"
var _shared := {}
var _refs := {}
var _faces_cache := {}
var _counter := 0


func load_manifest(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY or not data.has("assets"):
		return ERR_PARSE_ERROR
	manifest_version = int(data.get("version", 1))
	if manifest_version > 2:
		push_error("unsupported manifest version %d" % manifest_version)
		return ERR_FILE_UNRECOGNIZED
	library_version = str(data.get("library_version", ""))
	var base := path.get_base_dir()
	for a in data["assets"]:
		var entry: Dictionary = a.duplicate(true)
		if not entry.has("id") or entry.get("type") not in TYPES:
			push_error("invalid asset entry %s" % str(a).left(120))
			return ERR_INVALID_DATA
		for k in ["path", "thumbnail", "faces"]:
			if entry.has(k):
				entry[k] = _resolve(base, entry[k])
		for p in entry.get("proxies", []):
			p["path"] = _resolve(base, p["path"])
		register(entry)
	return OK


static func _resolve(base: String, p: String) -> String:
	return base.path_join(p) if p.is_relative_path() else p


func register(entry: Dictionary) -> void:
	assert(entry.has("id") and entry.has("type"))
	if not entry.has("tags"):
		entry["tags"] = []
	assets[entry["id"]] = entry


func ids_of_type(t: String) -> Array:
	return assets.keys().filter(func(k): return assets[k]["type"] == t)


func has_tag(asset_id: String, tag: String) -> bool:
	return tag in assets.get(asset_id, {}).get("tags", [])


## Content identity of an asset for logs/replay: id, content hash and analyses.
func resolved(asset_id: String) -> Dictionary:
	var e: Dictionary = assets.get(asset_id, {})
	return {
		"id": asset_id,
		"content_hash": e.get("content_hash", ""),
		"analyses": e.get("analyses", {}),
	}


## Path of the proxy to decode for an on-screen height (smallest proxy that is
## at least that tall; the largest when none is, or when target_h <= 0).
func proxy_path(asset_id: String, target_h := 0) -> String:
	var e: Dictionary = assets[asset_id]
	var proxies: Array = e.get("proxies", [])
	if proxies.is_empty():
		return e.get("path", "")
	var sorted := proxies.duplicate()
	sorted.sort_custom(func(a, b): return a["height"] < b["height"])
	if target_h > 0:
		for p in sorted:
			if int(p["height"]) >= target_h:
				return p["path"]
	return sorted[-1]["path"]


func shared(asset_id: String, target_h := 0) -> VisualSource:
	if not assets.has(asset_id):
		push_error("unknown asset " + asset_id)
		return null
	var key := "%s@%s" % [asset_id, proxy_path(asset_id, target_h)]
	if not _shared.has(key) or not is_instance_valid(_shared[key]):
		var s := instance(asset_id, target_h)
		if s == null:
			return null
		s.set_meta("shared_key", key)
		_shared[key] = s
		_refs[key] = 0
	_refs[key] += 1
	return _shared[key]


func instance(asset_id: String, target_h := 0) -> VisualSource:
	if not assets.has(asset_id):
		push_error("unknown asset " + asset_id)
		return null
	var e: Dictionary = assets[asset_id]
	var s: VisualSource
	match e["type"]:
		"video":
			s = TheoraVideoSource.new(proxy_path(asset_id, target_h))
		"image":
			s = ImageSource.new(e["path"])
		"pdf_page":
			if str(e["path"]).get_extension().to_lower() == "pdf":
				s = PdfPageSource.new(e["path"], int(e.get("page", 1)), pdf_cache_dir)
			else:
				s = ImageSource.new(e["path"])  # pre-rasterized page (manifest v2)
				s.metadata = {"page": int(e.get("page", 1))}
		"text":
			s = TextSource.new(e.get("text", ""), e.get("style", "caption"))
		"procedural":
			s = ProceduralSource.new(e.get("generator", ""), e.get("params", {}), e.get("size", [960, 540]))
		_:
			push_error("unknown asset type " + str(e["type"]))
			return null
	_counter += 1
	s.asset_id = asset_id
	s.source_id = "%s#%d" % [asset_id, _counter]
	s.name = s.source_id.validate_node_name()
	s.metadata.merge(e.get("metadata", {}))
	if e.has("faces"):
		var tracks := _face_tracks(e["faces"])
		if not tracks.is_empty():
			s.metadata["face_tracks"] = tracks
	add_child(s)
	s.prepare()
	return s


func _face_tracks(path: String) -> Array:
	if not _faces_cache.has(path):
		var tracks := []
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var d = JSON.parse_string(f.get_as_text())
			if d is Dictionary:
				tracks = d.get("tracks", [])
		else:
			push_warning("missing face tracks " + path)
		_faces_cache[path] = tracks
	return _faces_cache[path]


## Release a source obtained from shared() or instance(). Shared sources are
## freed when their last user releases them.
func release(s: VisualSource) -> void:
	if not is_instance_valid(s):
		return
	if s.has_meta("shared_key"):
		var key: String = s.get_meta("shared_key")
		if _shared.get(key) == s:
			_refs[key] -= 1
			if _refs[key] > 0:
				return
			_shared.erase(key)
			_refs.erase(key)
	s.queue_free()


func shared_refcount(s: VisualSource) -> int:
	return _refs.get(s.get_meta("shared_key", ""), 0)


func update(t: float) -> void:
	for c in get_children():
		(c as VisualSource).update(t)


func describe() -> Array:
	return get_children().map(func(c): return c.describe())


## Count live video decoders (budget checks, status).
func active_videos() -> int:
	return get_children().filter(func(c): return c is TheoraVideoSource and not c.is_queued_for_deletion()).size()
