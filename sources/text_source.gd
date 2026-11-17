class_name TextSource
extends VisualSource
## Text rendered into its own small SubViewport (transparent background).
## Styles: "caption" (static) and "ticker" (scrolls horizontally with clock time).

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
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.size = box_size
	_vp.disable_3d = true
	_vp.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if style == "ticker" else SubViewport.UPDATE_ONCE
	)
	_label = Label.new()
	_label.text = text
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", color)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size = Vector2(box_size)
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
		_vp.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if style == "ticker" else SubViewport.UPDATE_ONCE
		)


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
