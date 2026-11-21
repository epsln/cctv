extends CompositionFamily
## Document storm: pages pile up over a dimmed feed; redactions, highlights
## and stamps appear on them; old pages are cleared as new ones arrive.
##
## density     maximum pages on screen and their size
## text_rate   page/stamp spawn probability per beat
## cutting     beats between background feed changes
## motion      drift and rotation range of pages
## annotation  redaction/highlight probability per page
## persistence feedback trails (director) and page re-appearance (motif)

const DOC_TYPES := ["pdf_page", "image"]
const STAMPS := ["CONFIDENTIAL", "REDACTED", "CLASSIFIED", "VOID", "COPY", "RESTRICTED"]

var _pages: Array = []  # [{"ids": [...], "asset"}], oldest first
var _bg := {}


func _init() -> void:
	display_name = "Document storm"
	slots = {
		"documents": "bureaucratic_documents",
		"redacted": "redacted_pages",
		"background": "cctv",
		"text": "captions",
	}


func density_params(v: float) -> Dictionary:
	return {
		"density.max_pages": 2 + int(round(v * 12.0)),
		"density.page_size": lerpf(0.3, 0.15, v),
		"density.background": lerpf(0.35, 0.7, v),
	}


func generate() -> Dictionary:
	_pages = []
	_bg = {}
	var children := []
	var bg := pick_one("background", {"max_videos": 1})
	if bg != "":
		var d := {
			"kind": "layer",
			"id": next_id("bg"),
			"asset": bg,
			"rect": [0, 0, 1, 1],
			"opacity": float(params["density.background"]),
		}
		children.append(d)
		_bg = {"id": d["id"], "asset": bg}
	var start := maxi(1, int(params["density.max_pages"]) / 2)
	for k in start:
		children.append_array(_page_items())
	return {
		"background": [0.02, 0.02, 0.02, 1],
		"layers": [fx_group(children)],
	}


func _page_items() -> Array:
	var slot := "redacted" if rng.randf() < 0.3 else "documents"
	var recent: Array = _pages.map(func(p): return p["asset"])
	var id := ""
	if rng.randf() < float(params["persistence.recur"]) and not recent.is_empty():
		id = recent[rng.randi_range(0, recent.size() - 1)]  # motif: a page returns
	else:
		id = pick_one(slot, {"types": DOC_TYPES, "exclude": recent})
		if id == "":
			id = pick_one("documents" if slot == "redacted" else "redacted", {"types": DOC_TYPES})
	if id == "":
		return []
	var e: Dictionary = assets.assets[id]
	var sz: Array = e.get("size", [1240, 1754])
	var w := float(params["density.page_size"]) * rng.randf_range(0.8, 1.2)
	var h := w * float(size.x) / float(size.y) * float(sz[1]) / maxf(float(sz[0]), 1.0)
	var rot := float(params["motion.rotation"])
	var rect := [rng.randf_range(-0.05, 1.0 - w * 0.8), rng.randf_range(-0.1, 1.0 - h * 0.6), w, h]
	var lid := next_id("page")
	var page := moving_layer(lid, id, rect, {"rotation": rng.randf_range(-rot, rot) + rng.randf_range(-3.0, 3.0)})
	var items := [page]
	var ids := [lid]
	var red := float(params["annotation.redact"])
	if rng.randf() < red:
		var boxes := []
		for k in rng.randi_range(1, 4):
			boxes.append([rng.randf_range(0.08, 0.2), rng.randf_range(0.15, 0.85), rng.randf_range(0.3, 0.75), 0.025])
		var style := "redact" if rng.randf() < 0.7 else "highlight"
		var aid := lid + "_marks"
		items.append(
			{"kind": "annotation", "id": aid, "target": lid, "style": style, "color": [1, 0.9, 0, 1], "boxes": boxes}
		)
	if rng.randf() < float(params["text_rate.prob"]) * 0.5:
		var sid := next_id("stamp")
		var sw := w * 0.8
		var sh := sw * float(size.x) / float(size.y) * 130.0 / 900.0
		(
			items
			. append(
				{
					"kind": "layer",
					"id": sid,
					"asset": text_asset(STAMPS[rng.randi_range(0, STAMPS.size() - 1)], "stamp"),
					"rect": [rect[0] + (w - sw) * 0.5, rect[1] + h * 0.3, sw, sh],
					"rotation": rng.randf_range(-25.0, 25.0),
					"opacity": 0.85,
				}
			)
		)
		ids.append(sid)
	_pages.append({"ids": ids, "asset": id})
	return items


func on_beat(beat: int, t: float) -> void:
	if comp == null or not is_instance_valid(comp):
		return
	if rng.randf() < float(params["text_rate.prob"]):
		_spawn(t)
	var every := int(params["cutting.beats"])
	if every > 0 and beat % every == 0 and beat > 0 and not _bg.is_empty():
		_swap_background(t)


func _spawn(t: float) -> void:
	var items := _page_items()
	for d in items:
		add(d, -1, t, "fx")
	while _pages.size() > int(params["density.max_pages"]):
		var p: Dictionary = _pages.pop_front()
		for id in p["ids"]:
			comp.remove_item(id)


func _swap_background(t: float) -> void:
	var id := pick_one("background", {"exclude": [_bg["asset"]], "max_videos": 1})
	if id == "":
		return
	comp.remove_item(_bg["id"])
	var d := {
		"kind": "layer",
		"id": next_id("bg"),
		"asset": id,
		"rect": [0, 0, 1, 1],
		"opacity": float(params["density.background"]),
	}
	if add(d, 0, t, "fx") == OK:
		_bg = {"id": d["id"], "asset": id}
