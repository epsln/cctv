extends CompositionFamily
## Surveillance wall: a grid of feeds with camera labels, face boxes and a
## recording timestamp. Cells are re-selected on a beat grid.
##
## density     grid size 2x2 / 3x3 / 4x4 (videos capped by the budget; other
##             cells show stills or NO SIGNAL)
## cutting     beats between cell swaps and the share of cells swapped
## persistence chance that a swapped cell repeats another cell's feed (motif)
## annotation  face boxes / track IDs / fictional labels / trails
## text_rate   caption changes per beat
## Distortion applies to the wall (group "fx"); labels and timestamp stay clean.

const GRIDS := [2, 3, 4]
const GRADE := {"type": "color_grade", "params": {"saturation": 0.25, "contrast": 1.25}}

var grid := 2
var _cells := {}  # cell index -> {"id", "asset"}
var _cam := 0


func _init() -> void:
	display_name = "Surveillance wall"
	slots = {"feeds": "cctv", "people": "talking_heads", "text": "captions"}


func density_params(v: float) -> Dictionary:
	return {"density.grid": GRIDS[clampi(int(round(v * 2.0)), 0, 2)], "density.gap": 0.004}


func _cell_rect(i: int) -> Array:
	var g := float(grid)
	var gap := float(params["density.gap"])
	var x := float(i % grid) / g
	var y := float(i / grid) / g
	return [x + gap, y + gap, 1.0 / g - 2.0 * gap, 1.0 / g - 2.0 * gap]


func generate() -> Dictionary:
	grid = int(params["density.grid"])
	var n := grid * grid
	_cells.clear()
	var chosen := []
	var videos := 0
	# One talking head among the feeds, when available (faces for annotation).
	var head := pick_one("people", {"max_videos": max_videos})
	if head != "":
		chosen.append(head)
		videos += 1 if is_video(head) else 0
	chosen.append_array(pick("feeds", n - chosen.size(), {"max_videos": max_videos - videos, "exclude": chosen}))
	# Fill remaining cells with stills of chosen feeds, then NO SIGNAL.
	var fill := []
	for id in chosen:
		var st := still_of(id) if is_video(id) else ""
		if st != "":
			fill.append(st)
	while chosen.size() < n:
		if not fill.is_empty() and rng.randf() < 0.75:
			chosen.append(fill[rng.randi_range(0, fill.size() - 1)])
		else:
			chosen.append(text_asset("NO SIGNAL", "stamp"))
	_shuffle(chosen)
	var cells := []
	for i in n:
		cells.append_array(_cell_items(i, chosen[i]))
	var layers: Array = [fx_group(cells)]
	(layers[0]["effects"] as Array).push_front(GRADE.duplicate(true))
	for i in n:
		layers.append(_label(i))
	(
		layers
		. append(
			{
				"kind": "layer",
				"id": "rec",
				"asset": text_asset("REC  CH%02d  %s" % [rng.randi_range(1, 64), fiction_label()], "terminal"),
				"rect": [0.012, 0.012, 0.32, 0.03],
			}
		)
	)
	if float(params["text_rate.prob"]) > 0.0:
		var cap := _caption()
		if not cap.is_empty():
			layers.append(cap)
	return {"background": [0.01, 0.01, 0.01, 1], "layers": layers}


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


func _cell_items(i: int, asset_id: String) -> Array:
	var id := next_id("cell%d_" % i)
	_cells[i] = {"id": id, "asset": asset_id}
	var r := _cell_rect(i)
	if assets.assets[asset_id]["type"] == "text":
		# Keep text proportions: centre a box with the text's aspect in the cell.
		var w: float = r[2] * 0.8
		var h: float = w * float(size.x) / float(size.y) * 130.0 / 900.0
		r = [r[0] + (r[2] - w) * 0.5, r[1] + (r[3] - h) * 0.5, w, h]
	var d := moving_layer(id, asset_id, r)
	# Wall cells barely move: a camera grid is static; motion shows as pulse.
	d["motion"]["wobble"] = 0.0
	d["meta_moves"] = 0.0
	var out := [d]
	var ann := face_annotation(id, asset_id)
	if not ann.is_empty():
		out.append(ann)
	return out


func _label(i: int) -> Dictionary:
	_cam += 1
	var r := _cell_rect(i)
	return {
		"kind": "layer",
		"id": "label%d" % i,
		"asset": text_asset("CAM %02d" % (_cam % 100), "label"),
		"rect": [r[0] + 0.004, r[1] + 0.004, minf(0.12, r[2] * 0.45), minf(0.024, r[3] * 0.12)],
	}


func _caption() -> Dictionary:
	var t := pick_one("text", {"types": ["text"]})
	if t == "":
		return {}
	return {"kind": "layer", "id": next_id("caption"), "asset": t, "rect": [0.0, 0.94, 1.0, 0.05], "meta_caption": true}


func on_beat(beat: int, t: float) -> void:
	if comp == null or not is_instance_valid(comp):
		return
	var every := int(params["cutting.beats"])
	if every > 0 and beat % every == 0:
		var n := grid * grid
		var k := clampi(int(round(float(params["cutting.share"]) * n)), 1, n)
		var idx := range(n)
		_shuffle(idx)
		for j in k:
			_swap_cell(idx[j], t)
	if rng.randf() < float(params["text_rate.prob"]) * 0.25:
		_swap_caption(t)


func _swap_cell(i: int, t: float) -> void:
	var old: Dictionary = _cells.get(i, {})
	if old.is_empty():
		return
	var pos := comp.index_of(old["id"])
	var budget := max_videos - video_layers() + (1 if is_video(old["asset"]) else 0)
	var asset_id := ""
	# Motif recurrence: repeat another cell's feed (shared playhead, no new decoder).
	if rng.randf() < float(params["persistence.recur"]):
		var others := _cells.values().filter(func(c): return c["asset"] != old["asset"])
		if not others.is_empty():
			asset_id = others[rng.randi_range(0, others.size() - 1)]["asset"]
	if asset_id == "":
		var exclude := _cells.values().map(func(c): return c["asset"])
		asset_id = pick_one("feeds", {"max_videos": maxi(budget, 0), "exclude": exclude})
	if asset_id == "":
		return
	if is_video(asset_id) and budget <= 0:
		return
	comp.remove_item(old["id"])
	var items := _cell_items(i, asset_id)
	add(items[0], pos, t, "fx")
	if items.size() > 1:
		add(items[1], pos + 1, t, "fx")


func _swap_caption(t: float) -> void:
	for id in comp.ids():
		var n := comp.find(id)
		if n and n.has_meta("caption"):
			comp.remove_item(id)
			break
	var cap := _caption()
	if not cap.is_empty():
		add(cap, -1, t)
