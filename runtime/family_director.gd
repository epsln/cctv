class_name FamilyDirector
extends Node
## Runs composition families: generates and switches compositions, forwards
## beats to the active family, applies macro-control changes (live in place or
## structurally by regenerating with the same seed) and logs every decision.
##
## Show config ("families"):
##   {"collections": "collections.json", "max_videos": 4, "seed": 1,
##    "transition_videos": 2,
##    "bindings": {"surveillance_wall": {"feeds": "cctv"}},
##    "initial": {"family": "surveillance_wall", "controls": {...}, "seed": 7}}
## `bindings` overrides each family's default slot -> collection mapping.
##
## Decoder budget: a composition never holds more than `max_videos` video
## layers. During a (non-cut) transition the outgoing composition still
## decodes, so the incoming one is generated with a reduced budget so that the
## total stays within max_videos + transition_videos (at least 1 video); it
## grows back to max_videos on later beat events once the old one is gone.

signal family_changed(family_id: String, seed: int)

const HISTORY_SIZE := 512

var performance: PerformanceRoot
var selector: AssetSelector
var controls := MacroControls.new()
var family: CompositionFamily
var max_videos := 4
var transition_videos := 2
var hold := false
var bindings := {}
var history: Array = []
var errors: PackedStringArray = []
var _seeds := RandomNumberGenerator.new()
var _count := 0


func setup(p: PerformanceRoot, cfg: Dictionary, base_dir: String) -> Error:
	performance = p
	selector = AssetSelector.new(p.assets)
	max_videos = int(cfg.get("max_videos", 4))
	transition_videos = int(cfg.get("transition_videos", 2))
	bindings = cfg.get("bindings", {})
	_seeds.seed = int(cfg.get("seed", 1))
	if cfg.has("controls"):
		controls = MacroControls.from_dict(cfg["controls"])
	if cfg.has("collections"):
		var cp: String = cfg["collections"]
		if cp.is_relative_path():
			cp = base_dir.path_join(cp)
		if selector.load_collections(cp) != OK:
			errors.append("cannot load collections " + cp)
			errors.append_array(selector.errors)
			return ERR_INVALID_DATA
	p.clock.beat.connect(_on_beat)
	return OK


## Generate a composition of `family_id` and switch to it.
## seed < 0 draws the next seed from the director's seed sequence.
func apply_family(
	family_id: String,
	ctl: Variant = null,
	seed := -1,
	collections := {},
	kind := "crossfade",
	beats := 2.0,
	quantize: Variant = "next_beat"
) -> Error:
	errors = []
	var f := CompositionFamily.create(family_id)
	if f == null:
		errors.append("unknown family " + family_id)
		return ERR_DOES_NOT_EXIST
	if ctl is Dictionary and not (ctl as Dictionary).is_empty():
		controls = MacroControls.from_dict(ctl)
	elif ctl is MacroControls:
		controls = (ctl as MacroControls).copy()
	if seed < 0:
		seed = _seeds.randi() & 0x7fffffff
	var coll: Dictionary = bindings.get(family_id, {}).duplicate()
	coll.merge(collections, true)
	f.setup(performance.assets, selector, controls, seed, coll, performance.output_size, max_videos)
	selector.repeat_window = int(f.params["persistence.repeat_window"])
	var outgoing := 0 if kind == "cut" else performance.assets.active_videos()
	var budget := clampi(max_videos + transition_videos - outgoing, 1, max_videos)
	f.max_videos = budget
	var spec := f.generate()
	f.max_videos = max_videos
	if not f.errors.is_empty():
		errors.append_array(f.errors)
		return ERR_INVALID_DATA
	var hints := f.take_hints(spec)
	_count += 1
	spec["id"] = "%s#%d" % [family_id, _count]
	var err := performance.trigger_spec(spec, kind, beats, quantize)
	if err != OK:
		errors.append_array(performance.errors)
		return err
	f.attach(performance.last_prepared)
	f.attach_hints(hints)
	family = f
	f.apply_live(performance.clock.time)
	_apply_persistence()
	_record(
		"apply",
		{
			"family": family_id,
			"seed": seed,
			"comp": spec["id"],
			"collections": f.collections,
			"controls": controls.to_dict(),
			"video_budget": budget,
			"library": performance.assets.library_version,
		}
	)
	family_changed.emit(family_id, seed)
	return OK


## Stop driving the current family (a hand-authored composition took over).
func detach() -> void:
	if family:
		_record("detach", {"family": family.family_id})
	family = null


## Regenerate the current family with a new seed.
func reseed(kind := "cut", beats := 0.0, quantize: Variant = "next_beat") -> Error:
	if family == null:
		return ERR_UNCONFIGURED
	return apply_family(family.family_id, controls, -1, family.collections, kind, beats, quantize)


func set_axis(axis: String, v: float) -> Error:
	var c := controls.copy()
	if c.set_axis(axis, v) != OK:
		return ERR_INVALID_PARAMETER
	return set_controls(c)


func set_character(ch: String) -> Error:
	var c := controls.copy()
	if c.set_character(ch) != OK:
		return ERR_INVALID_PARAMETER
	return set_controls(c)


## Apply new controls: live axes in place; structural changes regenerate the
## family with the same seed on the next beat.
func set_controls(c: MacroControls) -> Error:
	controls = c.copy()
	if family == null:
		return OK
	var structural := family.set_controls(controls)
	_record("controls", {"controls": controls.to_dict(), "structural": structural})
	if structural:
		return apply_family(family.family_id, controls, family.seed, family.collections, "crossfade", 1.0, "next_beat")
	family.apply_live(performance.clock.time)
	_apply_persistence()
	return OK


func _apply_persistence() -> void:
	if family == null:
		return
	var fb := performance.feedback
	var on := bool(family.params["persistence.feedback"])
	if on != fb.enabled:
		fb.enabled = on
		fb.reset()
	fb.set_params({"decay": family.params["persistence.decay"], "beat_cut": family.params["persistence.beat_cut"]})


func _on_beat(index: int) -> void:
	if hold or family == null or family.comp == null or not is_instance_valid(family.comp):
		return
	if not family.comp.is_inside_tree():
		return  # not switched in yet
	family.on_beat(index, performance.clock.time)


func _record(action: String, d: Dictionary) -> void:
	d["action"] = action
	d["t"] = performance.clock.time
	d["beat"] = performance.clock.beat_index()
	history.append(d)
	if history.size() > HISTORY_SIZE:
		history.pop_front()


func describe() -> Dictionary:
	var d := family.describe() if family else {}
	d["hold"] = hold
	d["controls"] = controls.to_dict()
	return d
