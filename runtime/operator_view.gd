extends Control
## Operator view: output preview, composition triggers, transition controls,
## feedback toggle, timing controls and live status.
## Keys: 1-9 trigger compositions, B = "this beat is the one" (bar alignment),
## Shift+B clears it, [ and ] nudge the beat phase by -/+ NUDGE beats.
## Families (FamilyPanel): F1-F3 select a family, R reseeds, H toggles hold.

const NUDGE := 0.02
const QUANTIZE := ["now", "next_beat", "next_bar", "grid:4", "grid:8", "grid:16"]

var performance: PerformanceRoot
var _preview: TextureRect
var _status: Label
var _kind: OptionButton
var _beats: SpinBox
var _quantize: OptionButton
var _fb: CheckBox
var _comp_box: VBoxContainer
var _families: FamilyPanel


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

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 380
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	h.add_child(scroll)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(right)
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
	_quantize = OptionButton.new()
	for q in QUANTIZE:
		_quantize.add_item(q)
	_quantize.select(1)
	right.add_child(_quantize)
	right.add_child(_label("Timing"))
	var row := HBoxContainer.new()
	right.add_child(row)
	row.add_child(_button("Bar: this is 1 (B)", performance.clock.align_bar_now))
	row.add_child(_button("Clear", performance.clock.clear_bar_alignment))
	row = HBoxContainer.new()
	right.add_child(row)
	row.add_child(_button("Nudge - ([)", performance.clock.nudge.bind(-NUDGE)))
	row.add_child(_button("Nudge + (])", performance.clock.nudge.bind(NUDGE)))
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
	if performance.director:
		_families = FamilyPanel.new()
		_families.director = performance.director
		_families.transition_kind = func(): return _kind.get_item_text(_kind.selected)
		_families.transition_beats = func(): return _beats.value
		_families.quantize = func(): return QUANTIZE[_quantize.selected]
		right.add_child(_families)


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _go(id: String) -> void:
	performance.trigger(id, _kind.get_item_text(_kind.selected), _beats.value, QUANTIZE[_quantize.selected])


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_B:
			if k.shift_pressed:
				performance.clock.clear_bar_alignment()
			else:
				performance.clock.align_bar_now()
		KEY_BRACKETLEFT:
			performance.clock.nudge(-NUDGE)
		KEY_BRACKETRIGHT:
			performance.clock.nudge(NUDGE)
		KEY_R:
			if _families:
				_families.reseed()
		KEY_H:
			if _families:
				_families.toggle_hold()
	if _families and k.keycode >= KEY_F1 and k.keycode <= KEY_F3:
		var fams := CompositionFamily.ids()
		var fi := k.keycode - KEY_F1
		if fi < fams.size():
			_families.select_family(fams[fi])
	if k.keycode >= KEY_1 and k.keycode <= KEY_9:
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
	var tm: Dictionary = s["timing"]
	(
		lines
		. append(
			(
				"timing=%s bpm=%.2f conf=%.2f age=%.0fms err=%+.3fb bar=%s(%.2f) bar_phase=%.2f"
				% [
					tm["timing_source"],
					tm["bpm"],
					tm["beat_confidence"],
					tm["timing_age"] * 1000.0,
					tm["phase_error"],
					tm["bar_source"],
					tm["bar_confidence"],
					performance.clock.bar_phase(),
				]
			)
		)
	)
	var an: Dictionary = s["analysis"]
	if not an.is_empty():
		var st: Dictionary = an["stats"]
		lines.append(
			(
				"analysis: %s rx=%d age=%.0fms transport=%.1fms overruns=%d"
				% [
					"listening" if an["listening"] else "OFF",
					st["received"],
					st["age_ms"],
					st["transport_ms"],
					st["overruns"]
				]
			)
		)
	var sc: Dictionary = s["scheduler"]
	lines.append(
		(
			"scheduler: pending=%d done=%d late=%d max=%.1fms rejected=%d"
			% [sc["pending"], sc["executed"], sc["late"], sc["max_late_ms"], sc["rejected"]]
		)
	)
	lines.append(
		"sources=%d videos=%d library=%s" % [s["sources"].size(), s["videos"], performance.assets.library_version]
	)
	for src in s["sources"].slice(0, 6):
		lines.append("  %s %s %s ph=%.2f" % [src["id"], src["type"], src["state"], src["playhead"]])
	for e in s["errors"].slice(-5):
		lines.append("ERR " + e)
	_status.text = "\n".join(lines)
