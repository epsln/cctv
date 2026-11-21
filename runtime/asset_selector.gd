class_name AssetSelector
extends RefCounted
## Resolves curated collections to concrete asset IDs with controlled,
## seeded randomness and repetition limits, and logs every resolution.
##
## collections.json:
##   {"version": 1, "collections": {
##     "cctv": {"tags_any": ["cctv"], "types": ["video", "image"]},
##     "bureaucratic_documents": {"tags_any": ["documents"], "exclude_tags": ["redacted"]},
##     "favourites": {"ids": ["cctv/lobby", "tv_news/anchor_03"]}}}
## Rules: "ids" (explicit), "tags_any", "tags_all", "exclude_tags", "types".
## A name that is not defined but is a tag in the library resolves to that tag.
##
## Repetition: the last `repeat_window` picks of each collection are avoided
## while fresh members remain (persistence lowers the window so motifs recur).
## Every select() appends {collection, seed, state, count, ids, assets} to `log`
## so the exact assets (content hashes, analyses) can be recovered for replay.

const RULES := ["ids", "tags_any", "tags_all", "exclude_tags", "types"]
const LOG_SIZE := 1024

var assets: AssetManager
var collections := {}
var collections_version := 0
var repeat_window := 4
var log: Array = []
var errors: PackedStringArray = []
var _recent := {}


func _init(am: AssetManager = null) -> void:
	assets = am


func load_collections(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var d = JSON.parse_string(f.get_as_text())
	if not d is Dictionary or not d.get("collections") is Dictionary:
		return ERR_PARSE_ERROR
	for name in d["collections"]:
		var c: Dictionary = d["collections"][name]
		for k in c:
			if k not in RULES and k != "description":
				errors.append("collection %s: unknown rule '%s'" % [name, k])
				return ERR_INVALID_DATA
		collections[name] = c
	collections_version = int(d.get("version", 1))
	return OK


func has_collection(name: String) -> bool:
	return collections.has(name) or not members(name).is_empty()


## Collection names: defined collections plus library tags.
func names() -> Array:
	var out := collections.keys()
	for id in assets.assets:
		for t in assets.assets[id].get("tags", []):
			if t not in out:
				out.append(t)
	out.sort()
	return out


## Sorted member IDs of a collection (deterministic order for seeded picks).
func members(name: String, constraints := {}) -> Array:
	var rule: Dictionary = collections.get(name, {"tags_any": [name]})
	var out := []
	for id in assets.assets:
		var e: Dictionary = assets.assets[id]
		if _matches(id, e, rule) and _allowed(id, e, constraints):
			out.append(id)
	out.sort()
	return out


static func _matches(id: String, e: Dictionary, r: Dictionary) -> bool:
	var tags: Array = e.get("tags", [])
	if r.has("ids") and id not in r["ids"]:
		return false
	if r.has("types") and e["type"] not in r["types"]:
		return false
	if r.has("tags_any") and not r["tags_any"].any(func(t): return t in tags):
		return false
	if r.has("tags_all") and not r["tags_all"].all(func(t): return t in tags):
		return false
	if r.has("exclude_tags") and r["exclude_tags"].any(func(t): return t in tags):
		return false
	return true


## constraints: {"types": [...], "tags": [...] (all required), "exclude": [ids],
##               "max_videos": n (cap on video picks)}
static func _allowed(id: String, e: Dictionary, c: Dictionary) -> bool:
	if c.has("types") and e["type"] not in c["types"]:
		return false
	if c.has("exclude") and id in c["exclude"]:
		return false
	var tags: Array = e.get("tags", [])
	if c.has("tags") and not c["tags"].all(func(t): return t in tags):
		return false
	return true


## Pick up to `count` distinct assets. Returns fewer when the collection is
## smaller; an empty array (and an error entry) when it is empty.
func select(name: String, count: int, rng: RandomNumberGenerator, constraints := {}) -> Array:
	var entry := {"collection": name, "seed": rng.seed, "state": rng.state, "count": count, "ids": []}
	var pool := members(name, constraints)
	if pool.is_empty():
		errors.append("collection '%s' has no members matching %s" % [name, str(constraints)])
		entry["error"] = "empty"
		_log(entry)
		return []
	var recent: Array = _recent.get(name, [])
	var fresh := pool.filter(func(id): return id not in recent)
	# Recently used members come last, least recent first.
	var stale := recent.filter(func(id): return id in pool)
	var max_videos := int(constraints.get("max_videos", 1 << 30))
	var out := []
	var videos := 0
	while out.size() < count and not (fresh.is_empty() and stale.is_empty()):
		var id: String
		if not fresh.is_empty():
			id = fresh.pop_at(rng.randi_range(0, fresh.size() - 1))
		else:
			id = stale.pop_front()
		if assets.assets[id]["type"] == "video":
			if videos >= max_videos:
				continue
			videos += 1
		out.append(id)
	for id in out:
		recent.erase(id)
		recent.append(id)
	while recent.size() > repeat_window:
		recent.pop_front()
	_recent[name] = recent
	entry["ids"] = out
	entry["assets"] = out.map(func(id): return assets.resolved(id))
	_log(entry)
	return out


func pick_one(name: String, rng: RandomNumberGenerator, constraints := {}) -> String:
	var r := select(name, 1, rng, constraints)
	return r[0] if not r.is_empty() else ""


func reset_history() -> void:
	_recent.clear()


func _log(e: Dictionary) -> void:
	log.append(e)
	if log.size() > LOG_SIZE:
		log.pop_front()
