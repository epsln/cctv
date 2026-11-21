class_name TextSource
extends VisualSource
## Text rendered into its own small SubViewport (transparent background).
## Style presets (PRESETS): caption, ticker (scrolls horizontally with clock
## time), headline, label (boxed), stamp (red, bordered), terminal (monospace).

const PRESETS := {
	"caption": {"font_size": 48, "box": [1024, 96]},
	"ticker": {"font_size": 48, "box": [1024, 96]},
	"headline": {"font_size": 88, "box": [1600, 150], "upper": true},
	"label": {"font_size": 28, "box": [512, 48], "bg": [0, 0, 0, 0.75], "color": [1, 1, 1, 1]},
	"stamp": {"font_size": 72, "box": [900, 130], "color": [0.85, 0.05, 0.05, 1], "border": 6, "upper": true},
	"terminal": {"font_size": 30, "box": [1024, 64], "color": [0.55, 1, 0.55, 1], "mono": true},
}

var text := ""
var style := "caption"
var font_size := 48
var color := Color.WHITE
var box_size := Vector2i(1024, 96)
## Ticker scroll speed in px/s.
var scroll_speed := 200.0

var _vp: SubViewport
var _label: Label
var _scroll := 0.0


func _init(t := "", st := "caption") -> void:
	text = t
	style = st


func prepare() -> void:
	if not PRESETS.has(style):
		push_warning("unknown text style '%s', using caption" % style)
		style = "caption"
	var pr: Dictionary = PRESETS[style]
	font_size = int(pr["font_size"])
	box_size = Vector2i(int(pr["box"][0]), int(pr["box"][1]))
	if pr.has("color"):
		var c: Array = pr["color"]
		color = Color(c[0], c[1], c[2], c[3])
	if pr.get("upper", false):
		text = text.to_upper()
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.size = box_size
	_vp.disable_3d = true
	_vp.render_target_update_mode = (SubViewport.UPDATE_ALWAYS if style == "ticker" else SubViewport.UPDATE_ONCE)
	_label = Label.new()
	_label.text = text
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", color)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size = Vector2(box_size)
	if pr.get("mono", false):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["monospace"])
		_label.add_theme_font_override("font", f)
	if pr.has("bg") or pr.has("border"):
		var sb := StyleBoxFlat.new()
		var bg: Array = pr.get("bg", [0, 0, 0, 0])
		sb.bg_color = Color(bg[0], bg[1], bg[2], bg[3])
		var bw := int(pr.get("border", 0))
		sb.set_border_width_all(bw)
		sb.border_color = color
		sb.content_margin_left = 12 + bw
		_label.add_theme_stylebox_override("normal", sb)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if bw > 0 else HORIZONTAL_ALIGNMENT_LEFT
	if style == "ticker":
		_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_label.size.x = 0
	_vp.add_child(_label)
	add_child(_vp)
	_set_state(State.READY)


func set_text(t: String) -> void:
	text = t
	if _label:
		_label.text = t
		_vp.render_target_update_mode = (SubViewport.UPDATE_ALWAYS if style == "ticker" else SubViewport.UPDATE_ONCE)


func update(t: float) -> void:
	if style != "ticker" or _label == null:
		return
	var w := maxf(_label.get_minimum_size().x, 1.0)
	var span := w + box_size.x
	_scroll = fposmod((t - start_time) * scroll_speed, span)
	_label.position.x = box_size.x - _scroll


func get_scroll() -> float:
	return _scroll


func get_texture() -> Texture2D:
	return _vp.get_texture() if _vp else null


func get_size() -> Vector2i:
	return box_size


func get_class_name() -> String:
	return "TextSource"
