class_name AnnotationLayer
extends Control
## Draws boxes, labels, highlights or redaction bars.
##
## {"kind": "annotation", "id": "faces", "target": "<layer id>", "style": "box",
##  "label": "SUBJECT", "color": [1, 0, 0, 1], "boxes": [[x, y, w, h], ...]}
##
## With a target, boxes come from the target source's metadata, normalized to
## the source frame, and follow the target's rect and crop:
##   "faces": [[x, y, w, h], ...]                      static
##   "face_track": [{"t": 0.0, "boxes": [...]}, ...]   sorted by t, sampled at playhead
## Placing an annotation before/after a group's effects decides whether it
## inherits that distortion.

const STYLES := ["box", "redact", "highlight"]

var layer_id := ""
var target_id := ""
var target: Layer
var style := "box"
var label := ""
var color := Color(1, 0.1, 0.1, 1)
var static_boxes: Array = []
var norm_rect := Rect2(0, 0, 1, 1)
var line_width := 3.0
var error := ""
var _boxes: Array = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(d: Dictionary) -> Error:
	layer_id = d.get("id", "")
	name = ("ann_" + layer_id).validate_node_name()
	target_id = d.get("target", "")
	style = d.get("style", "box")
	label = d.get("label", "")
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
	if meta.has("face_track"):
		var cur: Array = []
		for k in meta["face_track"]:
			if float(k["t"]) <= playhead:
				cur = k["boxes"]
			else:
				break
		return cur
	return meta.get("faces", [])


func update(_t: float, _u: Dictionary) -> void:
	if target:
		position = target.position
		size = target.size
		var src_boxes := boxes_at(target.source.metadata, target.source.get_playhead()) if target.source else []
		var c := target.crop
		_boxes = []
		for b in src_boxes:
			# source-normalized -> crop-normalized
			_boxes.append(Rect2((b[0] - c.position.x) / c.size.x, (b[1] - c.position.y) / c.size.y,
				b[2] / c.size.x, b[3] / c.size.y))
	else:
		_boxes = static_boxes.map(func(b): return Rect2(b[0], b[1], b[2], b[3]))
	queue_redraw()


func current_boxes() -> Array:
	return _boxes


func _draw() -> void:
	var font := ThemeDB.fallback_font
	for nb in _boxes:
		var r := Rect2(nb.position * size, nb.size * size)
		match style:
			"box":
				draw_rect(r, color, false, line_width)
				if label != "":
					draw_string(font, r.position + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, color)
			"redact":
				draw_rect(r, Color.BLACK, true)
			"highlight":
				draw_rect(r, Color(color, 0.35), true)


func to_dict() -> Dictionary:
	var d := {
		"kind": "annotation", "id": layer_id, "style": style, "label": label,
		"color": [color.r, color.g, color.b, color.a],
		"rect": [norm_rect.position.x, norm_rect.position.y, norm_rect.size.x, norm_rect.size.y],
	}
	if target_id != "":
		d["target"] = target_id
	else:
		d["boxes"] = static_boxes.duplicate(true)
	return d
