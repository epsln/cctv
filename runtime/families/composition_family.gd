# gdlint: disable=max-public-methods
class_name CompositionFamily
extends RefCounted
## A composition family: a generator of compositions in a recognisable style
## plus beat-driven behaviours, steered by MacroControls.
##
## Lifecycle (driven by FamilyDirector):
##   setup(...)          seed, controls, collection bindings, budget
##   generate()          -> composition spec (deterministic for seed+controls)
##   attach(comp)        the built Composition the family now edits live
##   on_beat(i, t)       beat events (cuts, swaps, spawns) via add/remove_item
##   apply_live(t)       push live axis changes into the running composition
##
## Determinism: all randomness comes from `rng` (seeded); selections go
## through AssetSelector, which logs resolved asset IDs.
## Video budget: never more than `max_videos` video layers at once.

const FAMILIES := {
	"surveillance_wall": "res://runtime/families/surveillance_wall.gd",
	"channel_surfing": "res://runtime/families/channel_surfing.gd",
	"document_storm": "res://runtime/families/document_storm.gd",
}
## Fictional display labels (never derived from detector data).
const FICTION := [
	"SUBJECT %04d",
	"PERSON OF INTEREST",
	"UNIDENTIFIED",
	"MATCH 0.%02d",
	"ID PENDING",
	"FLAGGED",
	"TARGET %02d",
	"NO RECORD",
]

var family_id := ""
var display_name := ""
## slot -> default collection
var slots := {}
var assets: AssetManager
var selector: AssetSelector
var rng := RandomNumberGenerator.new()
var seed := 0
var controls: MacroControls
var params := {}
var collections := {}
var size := Vector2i(1920, 1080)
var max_videos := 4
var comp: Composition
var errors: PackedStringArray = []
var _n := 0


static func create(id: String) -> CompositionFamily:
	if not FAMILIES.has(id):
		return null
	var f: CompositionFamily = load(FAMILIES[id]).new()
	f.family_id = id
	return f


static func ids() -> Array:
	return FAMILIES.keys()


func setup(
	am: AssetManager, sel: AssetSelector, c: MacroControls, s: int, coll := {}, sz := Vector2i(1920, 1080), mv := 4
) -> void:
	assets = am
	selector = sel
	controls = c.copy()
	seed = s
	rng.seed = s
	size = sz
	max_videos = mv
	collections = slots.duplicate()
	for k in coll:
		if slots.has(k):
			collections[k] = coll[k]
		else:
			errors.append("%s has no slot '%s'" % [family_id, k])
	params = resolve(controls)


## Concrete parameters from macro controls. Axes map to disjoint key sets.
func resolve(c: MacroControls) -> Dictionary:
	var out := {}
	for axis in MacroControls.AXES:
		var p := axis_params(axis, c.get_axis(axis), c.character)
		for k in p:
			assert(MacroControls.prefix_of(k) == axis, "%s: key %s outside axis %s" % [family_id, k, axis])
			out[k] = p[k]
	return out


func axis_params(axis: String, v: float, character: String) -> Dictionary:
	if axis == "density":
		return density_params(v)
	return MacroControls.base_params(axis, v, character)


## Override: keys must start with "density.".
func density_params(v: float) -> Dictionary:
	return {"density.layers": 1 + int(round(v * 3))}


## Override: return a composition spec (id is set by the director).
func generate() -> Dictionary:
	return {"layers": []}


func attach(c: Composition) -> void:
	comp = c


## Override for beat behaviours.
func on_beat(_beat: int, _t: float) -> void:
	pass


## Update controls; returns true when the change is structural (needs regenerate).
func set_controls(c: MacroControls) -> bool:
	var structural := c.character != controls.character
	for axis in MacroControls.STRUCTURAL:
		if not is_equal_approx(c.get_axis(axis), controls.get_axis(axis)):
			structural = true
	controls = c.copy()
	params = resolve(controls)
	return structural


## Push live parameters (distortion amount, motion, annotation) into the
## running composition. Persistence/feedback is applied by the director.
func apply_live(_t: float) -> void:
	if comp == null or not is_instance_valid(comp):
		return
	selector.repeat_window = int(params["persistence.repeat_window"])
	var fx := comp.find("fx") as LayerGroup
	if fx:
		var defs: Array = params["distortion.effects"]
		var effs: Array = fx.chain.effects
		# Distortion effects are the tail of the fx chain (families may prepend grading).
		var off := effs.size() - defs.size()
		for i in defs.size():
			if off + i < 0:
				continue
			var e: Effect = effs[off + i]
			if e.type != defs[i]["type"]:
				continue
			for k in defs[i].get("params", {}):
				e.set_param(k, defs[i]["params"][k])
			for b in defs[i].get("bindings", []):
				e.set_binding_amount(b["param"], float(b["amount"]))
		fx.effect_defs = fx.chain.to_array()
	for id in comp.ids():
		var n := comp.find(id)
		if n is Layer and n.has_meta("moves"):
			n.motion = motion_dict(float(n.get_meta("moves")), float(n.motion.get("phase", 0.0)))
			_set_pulse(n)
		elif n is AnnotationLayer and n.has_meta("faces"):
			n.visible = (
				bool(params["annotation.faces"]) and float(n.get_meta("faces")) < float(params["annotation.prob"])
			)


# -- helpers for subclasses ----------------------------------------------------


func next_id(prefix: String) -> String:
	_n += 1
	return "%s%d" % [prefix, _n]


func pick(slot: String, count: int, constraints := {}) -> Array:
	return selector.select(collections.get(slot, slot), count, rng, constraints)


func pick_one(slot: String, constraints := {}) -> String:
	var r := pick(slot, 1, constraints)
	return r[0] if not r.is_empty() else ""


func is_video(asset_id: String) -> bool:
	return assets.assets.get(asset_id, {}).get("type", "") == "video"


func has_faces(asset_id: String) -> bool:
	var e: Dictionary = assets.assets.get(asset_id, {})
	return e.has("faces") or e.get("metadata", {}).has("face_track") or e.get("metadata", {}).has("faces")


## Video layers currently in the composition (budget check).
func video_layers() -> int:
	if comp == null or not is_instance_valid(comp):
		return 0
	var n := 0
	for id in comp.ids():
		var l := comp.find(id)
		if l is Layer and l.source is TheoraVideoSource:
			n += 1
	return n


## Register (once) a generated text asset and return its ID. Generated assets
## are deterministic from the seed, so replay can regenerate them.
func text_asset(text: String, style := "caption") -> String:
	var id := "gen:text:%s:%s" % [style, text.md5_text().left(10)]
	if not assets.assets.has(id):
		assets.register({"id": id, "type": "text", "text": text, "style": style, "tags": ["generated"]})
	return id


## Still frame for a video (thumbnail) as an image asset; "" when unavailable.
func still_of(video_id: String) -> String:
	var e: Dictionary = assets.assets.get(video_id, {})
	if not e.has("thumbnail"):
		return ""
	var id := "gen:still:" + video_id
	if not assets.assets.has(id):
		assets.register({"id": id, "type": "image", "path": e["thumbnail"], "tags": ["generated"]})
	return id


func fiction_label() -> String:
	var f: String = FICTION[rng.randi_range(0, FICTION.size() - 1)]
	if f.contains("%04d"):
		return f % rng.randi_range(1, 9999)
	if f.contains("%02d"):
		return f % rng.randi_range(1, 99)
	return f


## Motion block for a layer; `k` scales it per layer (0..1).
func motion_dict(k := 1.0, phase := 0.0) -> Dictionary:
	return {
		"wobble": float(params["motion.wobble"]) * k,
		"freq": float(params["motion.freq"]) * (0.6 + 0.8 * k),
		"phase": phase,
	}


func _set_pulse(l: Layer) -> void:
	for b in l.bindings:
		if b["prop"] == "scale" and b["signal"] == "uBeatEnvelope":
			b["amount"] = float(params["motion.pulse"])


## A layer dict with motion + beat pulse, tagged so apply_live can retune it.
func moving_layer(id: String, asset_id: String, rect: Array, extra := {}) -> Dictionary:
	var k := rng.randf_range(0.5, 1.0)
	var d := {
		"kind": "layer",
		"id": id,
		"asset": asset_id,
		"rect": rect,
		"motion": motion_dict(k, rng.randf()),
		"bindings": [{"prop": "scale", "signal": "uBeatEnvelope", "amount": float(params["motion.pulse"])}],
		"meta_moves": k,
	}
	d.merge(extra, true)
	return d


## Face annotation for a layer, when its asset has faces. Visibility follows
## the annotation axis live; `roll` decides at which density it appears.
func face_annotation(target_id: String, asset_id: String) -> Dictionary:
	if not has_faces(asset_id):
		return {}
	var style := "box"
	if bool(params["annotation.trails"]):
		style = "trail"
	elif bool(params["annotation.labels"]) and rng.randf() < 0.3:
		style = "inset"
	elif bool(params["annotation.labels"]):
		style = "track"
	return {
		"kind": "annotation",
		"id": target_id + "_faces",
		"target": target_id,
		"style": style,
		"label": fiction_label() if bool(params["annotation.labels"]) else "",
		"min_conf": 0.6,
		"color": [1.0, 0.15, 0.1, 1.0],
		"meta_faces": rng.randf(),
	}


## Wrap items in the distortion group "fx" (one offscreen pass).
func fx_group(children: Array, rect := [0.0, 0.0, 1.0, 1.0]) -> Dictionary:
	return {
		"kind": "group",
		"id": "fx",
		"rect": rect,
		"effects": (params["distortion.effects"] as Array).duplicate(true),
		"children": children,
	}


## Add an item, then apply meta_* hints. Returns OK or the build error.
func add(d: Dictionary, at_index := -1, t := 0.0, parent_id := "") -> Error:
	var hints := _strip_meta(d)
	var err := comp.add_item(d, at_index, t, parent_id)
	if err == OK:
		_apply_meta(hints)
	return err


## Remove meta_* hints from a spec (recursively) and return them by item id.
static func _strip_meta(d: Dictionary, out := {}) -> Dictionary:
	for k in d.keys():
		if str(k).begins_with("meta_"):
			if not out.has(d["id"]):
				out[d["id"]] = {}
			out[d["id"]][str(k).substr(5)] = d[k]
			d.erase(k)
	for c in d.get("children", []):
		_strip_meta(c, out)
	return out


## Prepare a generated spec for Composition.build(): strips hints. Call
## attach_hints() after the composition is built.
func take_hints(spec: Dictionary) -> Dictionary:
	var out := {}
	for item in spec.get("layers", []):
		_strip_meta(item, out)
	return out


func _apply_meta(hints: Dictionary) -> void:
	for id in hints:
		var n := comp.find(id)
		if n == null:
			continue
		for k in hints[id]:
			n.set_meta(k, hints[id][k])
		if n is AnnotationLayer and n.has_meta("faces"):
			n.visible = (
				bool(params["annotation.faces"]) and float(n.get_meta("faces")) < float(params["annotation.prob"])
			)


func attach_hints(hints: Dictionary) -> void:
	_apply_meta(hints)


func describe() -> Dictionary:
	return {
		"family": family_id,
		"seed": seed,
		"controls": controls.to_dict(),
		"collections": collections.duplicate(),
		"videos": video_layers(),
		"max_videos": max_videos,
	}
