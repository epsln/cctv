extends CompositionFamily
## Channel surfing: one full-frame channel that cuts on the beat, picture-in-
## picture inserts, a lower third and a ticker.
##
## density   number of PiP inserts (0-2), lower third, ticker
## cutting   beats between channel changes; share of inserts swapped per cut
## motion    drift/pulse of inserts
## text_rate headline changes per beat
## The next channel is pre-loaded (invisible) one beat before each cut so the
## cut itself does not stall on opening a decoder. Shared playheads follow the
## clock, so returning to a channel finds it "where it is now".

const PIP_RECTS := [[0.66, 0.06, 0.3, 0.3], [0.04, 0.06, 0.24, 0.24]]

var _main := {}  # {"id", "asset"}
var _next := {}
var _pips: Array = []  # [{"id", "asset", "slot"}]


func _init() -> void:
	display_name = "Channel surfing"
	slots = {"channels": "tv_news", "inserts": "advertising", "text": "tickers", "headlines": "captions"}


func density_params(v: float) -> Dictionary:
	return {
		"density.pips": clampi(int(round(v * 2.0)), 0, 2),
		"density.lower_third": v > 0.25,
		"density.ticker": v > 0.5,
	}


func generate() -> Dictionary:
	_main = {}
	_next = {}
	_pips = []
	var main_id := pick_one("channels", {"max_videos": max_videos})
	if main_id == "":
		errors.append("channel_surfing: no channels")
		return {"layers": []}
	var children := [_main_layer(main_id, 1.0)]
	_main = {"id": children[0]["id"], "asset": main_id}
	# Budget: main + pre-loaded next channel + PiPs <= max_videos.
	var npip := mini(int(params["density.pips"]), maxi(max_videos - 2, 0))
	for k in npip:
		var p := _pip_layer(k)
		if not p.is_empty():
			children.append(p)
	var ann := face_annotation(_main["id"], main_id)
	if not ann.is_empty():
		children.append(ann)
	var layers: Array = [fx_group(children)]
	if bool(params["density.lower_third"]):
		(
			layers
			. append(
				{
					"kind": "layer",
					"id": "lower_third",
					"asset": _headline(),
					"rect": [0.05, 0.76, 0.6, 0.06],
					"meta_headline": true,
				}
			)
		)
	if bool(params["density.ticker"]):
		var tk := pick_one("text", {"types": ["text"]})
		if tk == "":
			tk = text_asset("BREAKING  //  " + fiction_label() + "  //  SIGNAL LOST", "ticker")
		layers.append({"kind": "layer", "id": "ticker", "asset": tk, "rect": [0.0, 0.92, 1.0, 0.06]})
	return {"background": [0, 0, 0, 1], "layers": layers}


func _main_layer(asset_id: String, opacity: float) -> Dictionary:
	return {"kind": "layer", "id": next_id("ch"), "asset": asset_id, "rect": [0, 0, 1, 1], "opacity": opacity}


func _pip_layer(k: int) -> Dictionary:
	var exclude := [_main.get("asset", "")] + _pips.map(func(p): return p["asset"])
	var budget := max_videos - 2 - _pips.size()
	var id := pick_one("inserts", {"exclude": exclude, "max_videos": maxi(budget, 0)})
	if id == "" or (is_video(id) and budget <= 0):
		return {}
	var lid := next_id("pip")
	_pips.append({"id": lid, "asset": id, "slot": k})
	return moving_layer(lid, id, PIP_RECTS[k])


func _headline() -> String:
	var t := pick_one("headlines", {"types": ["text"]})
	if t != "" and rng.randf() < 0.7:
		var e: Dictionary = assets.assets[t]
		return text_asset(str(e.get("text", "")), "headline")
	return text_asset(fiction_label(), "headline")


func on_beat(beat: int, t: float) -> void:
	if comp == null or not is_instance_valid(comp):
		return
	var every := int(params["cutting.beats"])
	if every <= 0:
		return
	if (beat + 1) % every == 0 and _next.is_empty():
		_preload(t)
	if beat % every == 0 and beat > 0:
		_cut(t)
	if rng.randf() < float(params["text_rate.prob"]) * 0.3:
		_swap_headline(t)


func _preload(t: float) -> void:
	var exclude := [_main.get("asset", "")]
	var budget := max_videos - video_layers()
	var id := pick_one("channels", {"exclude": exclude, "max_videos": maxi(budget, 0)})
	if id == "" or (is_video(id) and budget <= 0):
		return
	var d := _main_layer(id, 0.0)
	if add(d, 0, t, "fx") == OK:
		_next = {"id": d["id"], "asset": id}


func _cut(t: float) -> void:
	if _next.is_empty():
		_preload(t)  # no pre-load happened (e.g. cadence changed): load now
		if _next.is_empty():
			return
	comp.remove_item(_main["id"])
	var l := comp.find(_next["id"]) as Layer
	if l:
		l.opacity = 1.0  # pre-loaded at the bottom of the fx group, under the inserts
	_main = _next
	_next = {}
	var ann := face_annotation(_main["id"], _main["asset"])
	if not ann.is_empty():
		add(ann, -1, t, "fx")
	# Swap a share of the inserts on the same cut.
	for p in _pips.duplicate():
		if rng.randf() < float(params["cutting.share"]):
			comp.remove_item(p["id"])
			_pips.erase(p)
			var d := _pip_layer(int(p["slot"]))
			if not d.is_empty():
				add(d, -1, t, "fx")


func _swap_headline(t: float) -> void:
	if comp.find("lower_third") == null:
		return
	comp.remove_item("lower_third")
	add({"kind": "layer", "id": "lower_third", "asset": _headline(), "rect": [0.05, 0.76, 0.6, 0.06]}, -1, t)
