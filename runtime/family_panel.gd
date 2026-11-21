class_name FamilyPanel
extends VBoxContainer
## Operator controls for composition families: family selection, macro-control
## sliders, distortion character, collection bindings per slot, reseed/hold
## and named presets (user://presets.json).
##
## Keys (handled by OperatorView): F1-F3 families, R reseed, H hold.
## Structural sliders (density) apply when released; live ones while dragging.

const PRESETS_PATH := "user://presets.json"

var director: FamilyDirector
var transition_kind := func() -> String: return "crossfade"
var transition_beats := func() -> float: return 2.0
var quantize := func() -> Variant: return "next_beat"
var _sliders := {}
var _character: OptionButton
var _hold: CheckBox
var _slots: VBoxContainer
var _presets_box: VBoxContainer
var _preset_name: LineEdit
var _info: Label
var _syncing := false


func _ready() -> void:
	add_child(_label("Families (F1-F3)"))
	var row := HBoxContainer.new()
	add_child(row)
	for fid in CompositionFamily.ids():
		var b := Button.new()
		b.text = fid.replace("_", " ")
		b.pressed.connect(select_family.bind(fid))
		row.add_child(b)
	row = HBoxContainer.new()
	add_child(row)
	var rs := Button.new()
	rs.text = "Reseed (R)"
	rs.pressed.connect(reseed)
	row.add_child(rs)
	_hold = CheckBox.new()
	_hold.text = "Hold (H)"
	_hold.toggled.connect(func(on): director.hold = on)
	row.add_child(_hold)
	_info = _label("")
	_info.add_theme_font_size_override("font_size", 12)
	add_child(_info)

	add_child(_label("Macro controls"))
	for axis in MacroControls.AXES:
		var h := HBoxContainer.new()
		var l := _label(axis)
		l.custom_minimum_size.x = 90
		h.add_child(l)
		var s := HSlider.new()
		s.min_value = 0.0
		s.max_value = 1.0
		s.step = 0.01
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.value = director.controls.get_axis(axis)
		if axis in MacroControls.STRUCTURAL:
			s.drag_ended.connect(_on_drag_ended.bind(axis, s))
		else:
			s.value_changed.connect(func(v): _set_axis(axis, v))
		h.add_child(s)
		add_child(h)
		_sliders[axis] = s
	var ch := HBoxContainer.new()
	ch.add_child(_label("character"))
	_character = OptionButton.new()
	for c in MacroControls.CHARACTERS:
		_character.add_item(c)
	_character.item_selected.connect(func(i): director.set_character(MacroControls.CHARACTERS[i]))
	ch.add_child(_character)
	add_child(ch)

	add_child(_label("Collections"))
	_slots = VBoxContainer.new()
	add_child(_slots)

	add_child(_label("Presets"))
	row = HBoxContainer.new()
	add_child(row)
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "name"
	_preset_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_preset_name)
	var sv := Button.new()
	sv.text = "Save"
	sv.pressed.connect(func(): save_preset(_preset_name.text))
	row.add_child(sv)
	_presets_box = VBoxContainer.new()
	add_child(_presets_box)
	_rebuild_presets()
	director.family_changed.connect(func(_f, _s): sync())
	sync()


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func select_family(fid: String) -> void:
	director.apply_family(
		fid, director.controls, -1, {}, transition_kind.call(), transition_beats.call(), quantize.call()
	)


func reseed() -> void:
	director.reseed(transition_kind.call(), transition_beats.call(), quantize.call())


func toggle_hold() -> void:
	_hold.button_pressed = not _hold.button_pressed


func _on_drag_ended(changed: bool, axis: String, s: HSlider) -> void:
	if changed:
		_set_axis(axis, s.value)


func _set_axis(axis: String, v: float) -> void:
	if not _syncing:
		director.set_axis(axis, v)


## Refresh widgets from the director (after family changes or preset loads).
func sync() -> void:
	_syncing = true
	for axis in _sliders:
		_sliders[axis].set_value_no_signal(director.controls.get_axis(axis))
	_character.select(MacroControls.CHARACTERS.find(director.controls.character))
	_syncing = false
	for c in _slots.get_children():
		c.queue_free()
	var f := director.family
	if f == null:
		return
	var names := director.selector.names()
	for slot in f.slots:
		var h := HBoxContainer.new()
		var l := _label(slot)
		l.custom_minimum_size.x = 90
		h.add_child(l)
		var o := OptionButton.new()
		o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for n in names:
			o.add_item("%s (%d)" % [n, director.selector.members(n).size()])
		var cur: String = f.collections.get(slot, "")
		if cur not in names:
			o.add_item(cur + " (0)")
			names = names + [cur]
		o.select(names.find(cur))
		var list := names.duplicate()
		o.item_selected.connect(func(i): _rebind(slot, list[i]))
		h.add_child(o)
		_slots.add_child(h)


func _rebind(slot: String, collection: String) -> void:
	var f := director.family
	if f == null:
		return
	var coll := f.collections.duplicate()
	coll[slot] = collection
	director.apply_family(
		f.family_id, director.controls, f.seed, coll, transition_kind.call(), transition_beats.call(), quantize.call()
	)


func _process(_d: float) -> void:
	var f := director.family
	if f == null:
		_info.text = "no family active"
		return
	var sel: Array = director.selector.log.slice(-3).map(
		func(e): return "%s:%s" % [e["collection"], ",".join(e["ids"])]
	)
	_info.text = (
		"%s seed=%d videos=%d/%d%s\n%s"
		% [f.family_id, f.seed, f.video_layers(), f.max_videos, " HOLD" if director.hold else "", "\n".join(sel)]
	)


# -- presets -------------------------------------------------------------------


func _load_presets() -> Dictionary:
	var f := FileAccess.open(PRESETS_PATH, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}


func save_preset(preset_name: String) -> void:
	if preset_name.strip_edges() == "" or director.family == null:
		return
	var all := _load_presets()
	all[preset_name] = {
		"family": director.family.family_id,
		"controls": director.controls.to_dict(),
		"collections": director.family.collections,
		"seed": director.family.seed,
	}
	var f := FileAccess.open(PRESETS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(all, " "))
	_rebuild_presets()


func load_preset(preset_name: String) -> void:
	var p: Dictionary = _load_presets().get(preset_name, {})
	if p.is_empty():
		return
	director.apply_family(
		p["family"],
		p["controls"],
		int(p.get("seed", -1)),
		p.get("collections", {}),
		transition_kind.call(),
		transition_beats.call(),
		quantize.call()
	)


func _rebuild_presets() -> void:
	for c in _presets_box.get_children():
		c.queue_free()
	for n in _load_presets():
		var b := Button.new()
		b.text = n
		b.pressed.connect(load_preset.bind(n))
		_presets_box.add_child(b)
