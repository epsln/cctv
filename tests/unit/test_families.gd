extends "res://tests/test_case.gd"
## Macro controls and composition families: axis independence, determinism,
## video budget and beat behaviours.

const FIX := "res://tests/fixtures"
var am: AssetManager
var _comps: Array = []


func before_each() -> void:
	am = AssetManager.new()
	add_child(am)
	am.load_manifest(FIX + "/library_v2.json")


func after_each() -> void:
	for c in _comps:
		if is_instance_valid(c):
			c.release()
	am.queue_free()


func make(fid: String, sd: int, ctl := {}) -> CompositionFamily:
	var sel := AssetSelector.new(am)
	sel.load_collections(FIX + "/collections.json")
	var f := CompositionFamily.create(fid)
	f.setup(am, sel, MacroControls.from_dict(ctl), sd, {}, Vector2i(64, 36), 4)
	return f


func build(f: CompositionFamily) -> Composition:
	var spec := f.generate()
	var hints := f.take_hints(spec)
	spec["id"] = f.family_id
	var c := Composition.new()
	add_child(c)
	_comps.append(c)
	eq(c.build(spec, am, Vector2i(64, 36)), OK, "%s builds: %s" % [f.family_id, str(c.errors)])
	f.attach(c)
	f.attach_hints(hints)
	return c


func test_macro_controls_bounded() -> void:
	var m := MacroControls.new()
	eq(m.set_axis("density", 3.0), OK)
	eq(m.get_axis("density"), 1.0)
	eq(m.set_axis("intensity", 0.5), ERR_INVALID_PARAMETER, "no single intensity knob")
	eq(m.set_character("glitch"), OK)
	eq(m.set_character("melt"), ERR_INVALID_PARAMETER)
	var r := MacroControls.from_dict(m.to_dict())
	eq(r.to_dict(), m.to_dict())


func test_axes_are_independent() -> void:
	for fid in CompositionFamily.ids():
		var f := make(fid, 1)
		for axis in MacroControls.AXES:
			var lo := MacroControls.new()
			var hi := MacroControls.new()
			lo.set_axis(axis, 0.0)
			hi.set_axis(axis, 1.0)
			var a := f.resolve(lo)
			var b := f.resolve(hi)
			eq(a.keys(), b.keys())
			var changed := a.keys().filter(func(k): return str(a[k]) != str(b[k]))
			check(not changed.is_empty(), "%s: axis %s changes something" % [fid, axis])
			for k in changed:
				eq(MacroControls.prefix_of(k), axis, "%s: %s moved %s" % [fid, axis, k])


func test_cut_cadence_mapping() -> void:
	eq(MacroControls.base_params("cutting", 0.0, "")["cutting.beats"], 32)
	eq(MacroControls.base_params("cutting", 1.0, "")["cutting.beats"], 1)


func test_generation_is_deterministic() -> void:
	for fid in CompositionFamily.ids():
		var a := make(fid, 7).generate()
		var b := make(fid, 7).generate()
		eq(JSON.stringify(a), JSON.stringify(b), fid + " same seed")
		var c := make(fid, 8).generate()
		check(JSON.stringify(a) != JSON.stringify(c), fid + " different seed differs")


func test_families_build_within_budget_over_many_beats() -> void:
	for fid in CompositionFamily.ids():
		for dens in [0.0, 0.5, 1.0]:
			var f := make(fid, 5, {"density": dens, "cutting": 1.0, "text_rate": 1.0, "annotation": 1.0})
			var c := build(f)
			check(f.video_layers() <= 4, "%s initial videos %d" % [fid, f.video_layers()])
			for beat in range(1, 40):
				f.on_beat(beat, beat * 0.5)
				check(f.video_layers() <= 4, "%s beat %d videos %d" % [fid, beat, f.video_layers()])
			check(c.ids().size() > 0)
			check(am.active_videos() <= 4 + 4, "decoders released (pending frees allowed)")
			c.release()
			await frames(1)
	await frames(1)
	eq(am.get_children().filter(func(n): return not n.is_queued_for_deletion()).size(), 0, "all sources released")


func test_surveillance_wall_density_sets_grid() -> void:
	var lo := make("surveillance_wall", 1, {"density": 0.0})
	var hi := make("surveillance_wall", 1, {"density": 1.0})
	build(lo)
	build(hi)
	eq(lo.grid, 2)
	eq(hi.grid, 4)
	var cells := func(f):
		return f.comp.ids().filter(func(i): return str(i).begins_with("cell") and not str(i).ends_with("_faces"))
	eq(cells.call(lo).size(), 4)
	eq(cells.call(hi).size(), 16, "16 cells with at most 4 videos")


func test_surveillance_wall_swaps_cells_on_cut_beats() -> void:
	var f := make("surveillance_wall", 2, {"cutting": 0.6})  # every 4 beats
	var c := build(f)
	var before := c.ids().duplicate()
	f.on_beat(1, 0.5)
	eq(c.ids(), before, "no swap off the cut grid")
	f.on_beat(4, 2.0)
	check(c.ids() != before, "cells swapped on the cut beat")


func test_live_controls_update_in_place() -> void:
	var f := make("surveillance_wall", 3, {"distortion": 0.0, "character": "glitch"})
	var c := build(f)
	var fx := c.find("fx") as LayerGroup
	var g: Effect = fx.chain.effects[-1]
	eq(g.type, "glitch")
	near(float(g.params["amount"]), 0.0)
	var m := f.controls.copy()
	m.set_axis("distortion", 1.0)
	check(not f.set_controls(m), "distortion amount is live")
	f.apply_live(0.0)
	near(float(g.params["amount"]), 0.06)
	check(c.find("fx") == fx, "same composition")
	m.set_character("edge")
	check(f.set_controls(m), "character is structural")
	m = f.controls.copy()
	m.set_axis("density", 0.0)
	check(f.set_controls(m), "density is structural")


func test_document_storm_caps_pages() -> void:
	var f := make("document_storm", 4, {"density": 0.0, "text_rate": 1.0})
	build(f)
	for beat in range(1, 30):
		f.on_beat(beat, beat * 0.5)
		check(f._pages.size() <= 2, "max pages at density 0")


func test_channel_surfing_preloads_next_channel() -> void:
	var f := make("channel_surfing", 6, {"cutting": 0.6})  # every 4 beats
	var c := build(f)
	var main0: String = f._main["id"]
	f.on_beat(3, 1.5)
	check(not f._next.is_empty(), "next channel pre-loaded one beat ahead")
	var nl := c.find(f._next["id"]) as Layer
	eq(nl.opacity, 0.0, "pre-loaded channel invisible")
	f.on_beat(4, 2.0)
	check(c.find(main0) == null, "old channel removed on the cut")
	eq(nl.opacity, 1.0)
	eq(f._main["id"], nl.layer_id)
