extends Control
## Operator view: output preview, composition triggers, transition controls,
## feedback toggle and live status. Keys 1-9 trigger compositions.

var performance: PerformanceRoot
var _preview: TextureRect
var _status: Label
var _kind: OptionButton
var _beats: SpinBox
var _quantize: CheckBox
var _fb: CheckBox
var _comp_box: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(h)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(left)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_preview)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.custom_minimum_size.y = 200
	left.add_child(_status)

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 260
	h.add_child(right)
	right.add_child(_label("Transition"))
	_kind = OptionButton.new()
	for k in TransitionCompositor.KINDS:
		_kind.add_item(k)
	_kind.select(1)
	right.add_child(_kind)
	_beats = SpinBox.new()
	_beats.min_value = 0
	_beats.max_value = 32
	_beats.step = 0.5
	_beats.value = 2
	_beats.suffix = "beats"
	right.add_child(_beats)
	_quantize = CheckBox.new()
	_quantize.text = "Start on next beat"
	_quantize.button_pressed = true
	right.add_child(_quantize)
	_fb = CheckBox.new()
	_fb.text = "Feedback"
	_fb.button_pressed = performance.feedback.enabled
	_fb.toggled.connect(
		func(on):
			performance.feedback.enabled = on
			performance.feedback.reset()
	)
	right.add_child(_fb)
	right.add_child(_label("Compositions (keys 1-9)"))
	_comp_box = VBoxContainer.new()
	right.add_child(_comp_box)
	for id in performance.composition_ids():
		var b := Button.new()
		b.text = id
		b.pressed.connect(_go.bind(id))
		_comp_box.add_child(b)


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _go(id: String) -> void:
	performance.trigger(id, _kind.get_item_text(_kind.selected), _beats.value, _quantize.button_pressed)


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k and k.pressed and not k.echo and k.keycode >= KEY_1 and k.keycode <= KEY_9:
		var ids := performance.composition_ids()
		var i := k.keycode - KEY_1
		if i < ids.size():
			_go(ids[i])


func _process(_d: float) -> void:
	_preview.texture = performance.output_texture()
	var s := performance.status()
	var m: Dictionary = s["metrics"]
	var lines := [
		"t=%.2fs frame=%d beat=%d phase=%.2f clock=%s" % [s["time"], s["frame"], s["beat"], s["beat_phase"], s["mode"]],
		(
			"fps=%.1f p95=%.1fms p99=%.1fms late=%d/%d"
			% [m["recent_fps"], m["p95_ms"], m["p99_ms"], m["late_frames"], m["frames"]]
		),
		(
			"active=%s incoming=%s %s %.2f"
			% [
				s["transition"]["active"],
				s["transition"]["incoming"],
				s["transition"]["kind"],
				s["transition"]["progress"]
			]
		),
	]
	for src in s["sources"]:
		lines.append("  %s %s %s ph=%.2f" % [src["id"], src["type"], src["state"], src["playhead"]])
	for e in s["errors"].slice(-5):
		lines.append("ERR " + e)
	_status.text = "\n".join(lines)
