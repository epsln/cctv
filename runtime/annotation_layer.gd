class_name AnnotationLayer
extends Control
## Draws boxes, labels, highlights, redaction bars, track paths and insets.
##
## {"kind": "annotation", "id": "faces", "target": "<layer id>", "style": "box",
##  "label": "SUBJECT", "show_ids": false, "min_conf": 0.0,
##  "color": [1, 0, 0, 1], "boxes": [[x, y, w, h], ...]}
##
## Styles: box, redact, highlight, track (box + track ID), trail (box + recent
## path), inset (box + enlarged crop of the face in the corner).
##
## With a target, boxes come from the target source's metadata, normalized to
## the source frame, and follow the target's rect, crop and transform (with
## "boxes" and a target, the boxes are fixed in the target's displayed space):
##   "faces": [[x, y, w, h], ...]                      static
##   "face_track": [{"t": 0.0, "boxes": [...]}, ...]   sorted by t, step-sampled
##   "face_tracks": [{"id": 1, "samples": [{"t", "box", "conf"}]}]
##       detector tracks (cctv-ingest), linearly interpolated between samples;
##       a track is shown only within its sampled time range.
## `label` is display text chosen by the composition (possibly fictional); it
## is never stored with, or derived from, detector data. `show_ids` shows the
## detector's per-asset track number instead.
## Placing an annotation before/after a group's effects decides whether it
## inherits that distortion.

const STYLES := ["box", "redact", "highlight", "track", "trail", "inset"]
## Tracks are held this long (s) past their last sample before disappearing.
const TRACK_HOLD := 0.25
const TRAIL_SECONDS := 1.5
const TRAIL_POINTS := 12

var layer_id := ""
var target_id := ""
var target: Layer
var style := "box"
var label := ""
var show_ids := false
var min_conf := 0.0
var color := Color(1, 0.1, 0.1, 1)
var static_boxes: Array = []
var norm_rect := Rect2(0, 0, 1, 1)
var line_width := 3.0
var error := ""
var _boxes: Array = []
var _ids: Array = []
var _trails: Array = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(d: Dictionary) -> Error:
	layer_id = d.get("id", "")
	name = ("ann_" + layer_id).validate_node_name()
	target_id = d.get("target", "")
	style = d.get("style", "box")
	label = d.get("label", "")
	show_ids = bool(d.get("show_ids", false))
	min_conf = float(d.get("min_conf", 0.0))
	static_boxes = d.get("boxes", [])
	var r: Array = d.get("rect", [0, 0, 1, 1])
	norm_rect = Rect2(r[0], r[1], r[2], r[3])
	if d.has("color"):
		var c: Array = d["color"]
		color = Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0)
	if style not in STYLES:
		error = "annotation %s: unknown style '%s'" % [layer_id, style]
		return ERR_INVALID_PARAMETER
	return OK


func layout(parent_size: Vector2) -> void:
	position = norm_rect.position * parent_size
	size = norm_rect.size * parent_size


static func boxes_at(meta: Dictionary, playhead: float) -> Array:
	if meta.has("face_tracks"):
		return tracks_at(meta["face_tracks"], playhead).map(func(e): return e["box"])
	if meta.has("face_track"):
		var cur: Array = []
		for k in meta["face_track"]:
			if float(k["t"]) <= playhead:
				cur = k["boxes"]
			else:
				break
		return cur
	return meta.get("faces", [])


## Interpolated boxes of detector tracks at time t: [{"id", "box", "conf"}].
static func tracks_at(tracks: Array, t: float, conf_min := 0.0) -> Array:
	var out := []
	for tr in tracks:
		var s: Array = tr["samples"]
		if s.is_empty():
			continue
		var first: Dictionary = s[0]
		var last: Dictionary = s[-1]
		# (Stills have playhead 0 and a single sample at t=0: always shown.)
		if t < float(first["t"]) or t > float(last["t"]) + TRACK_HOLD:
			continue
		var box: Array = last["box"]
		var conf := float(last.get("conf", 1.0))
		var lo := 0
		var hi := s.size() - 1
		if t < float(last["t"]):
			while hi - lo > 1:  # binary search: s[lo].t <= t < s[hi].t
				var mid := (lo + hi) / 2
				if float(s[mid]["t"]) <= t:
					lo = mid
				else:
					hi = mid
			var a: Dictionary = s[lo]
			var b: Dictionary = s[hi]
			var span := float(b["t"]) - float(a["t"])
			var f := clampf((t - float(a["t"])) / span, 0.0, 1.0) if span > 0.0 else 0.0
			box = []
			for i in 4:
				box.append(lerpf(float(a["box"][i]), float(b["box"][i]), f))
			conf = minf(float(a.get("conf", 1.0)), float(b.get("conf", 1.0)))
		if conf >= conf_min:
			out.append({"id": tr["id"], "box": box, "conf": conf})
	return out


func _source_entries(meta: Dictionary, playhead: float) -> Array:
	if meta.has("face_tracks"):
		return tracks_at(meta["face_tracks"], playhead, min_conf)
	var out := []
	var i := 0
	for b in boxes_at(meta, playhead):
		i += 1
		out.append({"id": i, "box": b})
	return out


func _to_crop(b: Array, c: Rect2) -> Rect2:
	# source-normalized -> crop-normalized
	return Rect2((b[0] - c.position.x) / c.size.x, (b[1] - c.position.y) / c.size.y, b[2] / c.size.x, b[3] / c.size.y)


func update(_t: float, _u: Dictionary) -> void:
	_trails = []
	if target:
		position = target.position
		size = target.size
		rotation = target.rotation
		scale = target.scale
		pivot_offset = target.pivot_offset
		_boxes = []
		_ids = []
		if not static_boxes.is_empty():
			# Fixed boxes in the target's displayed (crop) space, e.g. redactions on a page.
			_boxes = static_boxes.map(func(b): return Rect2(b[0], b[1], b[2], b[3]))
			_ids = range(1, _boxes.size() + 1)
		elif target.source:
			var meta := target.source.metadata
			var ph := target.source.get_playhead()
			for e in _source_entries(meta, ph):
				_boxes.append(_to_crop(e["box"], target.crop))
				_ids.append(e["id"])
			if style == "trail" and meta.has("face_tracks"):
				for k in TRAIL_POINTS:
					var tt := ph - TRAIL_SECONDS * float(k) / float(TRAIL_POINTS)
					for e in tracks_at(meta["face_tracks"], tt, min_conf):
						if e["id"] in _ids:
							var r := _to_crop(e["box"], target.crop)
							_trails.append([e["id"], k, r.get_center()])
	else:
		_boxes = static_boxes.map(func(b): return Rect2(b[0], b[1], b[2], b[3]))
		_ids = range(1, _boxes.size() + 1)
	queue_redraw()


func current_boxes() -> Array:
	return _boxes


func current_ids() -> Array:
	return _ids


func _text_for(i: int) -> String:
	if show_ids or style == "track":
		return ("%s TRK %02d" % [label, int(_ids[i])]).strip_edges() if i < _ids.size() else label
	return label


func _draw() -> void:
	var font := ThemeDB.fallback_font
	for i in _boxes.size():
		var nb: Rect2 = _boxes[i]
		var r := Rect2(nb.position * size, nb.size * size)
		match style:
			"redact":
				draw_rect(r, Color.BLACK, true)
			"highlight":
				draw_rect(r, Color(color, 0.35), true)
			_:
				draw_rect(r, color, false, line_width)
				var txt := _text_for(i)
				if txt != "":
					draw_string(font, r.position + Vector2(0, -6), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, color)
		if style == "inset" and target:
			_draw_inset(i, nb, r)
	if style == "trail":
		for p in _trails:
			var a := 1.0 - float(p[1]) / float(TRAIL_POINTS)
			draw_circle(p[2] * size, 2.0 + 2.0 * a, Color(color, a))


func _draw_inset(i: int, nb: Rect2, r: Rect2) -> void:
	var tex := target.output_texture()
	if tex == null:
		return
	var ts := tex.get_size()
	var c := target.crop
	# crop-normalized box -> texture region, padded a little
	var src := Rect2((c.position + nb.position * c.size) * ts, nb.size * c.size * ts).grow(
		nb.size.x * c.size.x * ts.x * 0.15
	)
	var h := size.y * 0.32
	var w := h * (src.size.x / maxf(src.size.y, 1.0))
	var dst := Rect2(Vector2(size.x - w - 8.0, 8.0 + float(i) * (h + 8.0)), Vector2(w, h))
	draw_texture_rect_region(tex, dst, src)
	draw_rect(dst, color, false, 2.0)
	draw_line(r.get_center(), dst.position + Vector2(0, h * 0.5), Color(color, 0.6), 1.0)


func to_dict() -> Dictionary:
	var d := {
		"kind": "annotation",
		"id": layer_id,
		"style": style,
		"label": label,
		"show_ids": show_ids,
		"min_conf": min_conf,
		"color": [color.r, color.g, color.b, color.a],
		"rect": [norm_rect.position.x, norm_rect.position.y, norm_rect.size.x, norm_rect.size.y],
	}
	if target_id != "":
		d["target"] = target_id
	if target_id == "" or not static_boxes.is_empty():
		d["boxes"] = static_boxes.duplicate(true)
	return d
