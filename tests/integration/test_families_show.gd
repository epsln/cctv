extends "res://tests/test_case.gd"
## FamilyDirector inside PerformanceRoot: initial family, beat events,
## live/structural control changes, reseed, history and feedback mapping.

var pr: PerformanceRoot


func before_each() -> void:
	pr = PerformanceRoot.new()
	pr.args = {
		"show": "res://tests/fixtures/families_show.json", "replay": true, "no-projector": true, "no-operator": true
	}
	add_child(pr)


func after_each() -> void:
	pr.queue_free()
	await frames(1)


func test_initial_family_is_active() -> void:
	eq(pr.errors.size(), 0, str(pr.errors))
	var d := pr.director
	check(d.family != null)
	eq(d.family.family_id, "surveillance_wall")
	eq(d.family.seed, 11)
	eq(pr.compositor.active_id(), "surveillance_wall#1")
	eq(d.history[-1]["action"], "apply")
	check(pr.status()["family"]["videos"] <= 4)


func test_beats_drive_the_family() -> void:
	pr.director.set_axis("cutting", 1.0)  # every beat
	var before: Array = pr.director.family.comp.ids().duplicate()
	for i in 40:
		await frames(1)  # 40 frames at 30 fps > 2 beats at 120 bpm
	check(pr.director.family.comp.ids() != before, "cells swapped on beats")


func test_hold_freezes_events() -> void:
	pr.director.set_axis("cutting", 1.0)
	pr.director.hold = true
	var before: Array = pr.director.family.comp.ids().duplicate()
	for i in 40:
		await frames(1)
	eq(pr.director.family.comp.ids(), before)


func test_structural_change_regenerates_with_same_seed() -> void:
	var d := pr.director
	eq(d.set_axis("density", 1.0), OK)
	eq(d.family.seed, 11, "same seed")
	eq(d.family.comp.comp_id, "surveillance_wall#2")
	eq(d.history[-1]["action"], "apply")


func test_live_change_keeps_composition() -> void:
	var d := pr.director
	var comp := d.family.comp
	eq(d.set_axis("distortion", 0.9), OK)
	check(d.family.comp == comp)
	eq(d.history[-1]["action"], "controls")


func test_persistence_maps_to_feedback() -> void:
	var d := pr.director
	d.set_axis("persistence", 0.0)
	check(not pr.feedback.enabled)
	d.set_axis("persistence", 1.0)
	check(pr.feedback.enabled)
	near(float(pr.feedback.params["decay"]), 0.93, 1e-4)


func test_switch_family_and_reseed() -> void:
	var d := pr.director
	eq(d.apply_family("document_storm", null, 5, {}, "cut", 0.0, "now"), OK)
	eq(pr.compositor.active_id(), "document_storm#2")
	eq(d.reseed("cut", 0.0, "now"), OK)
	check(d.family.seed != 5)
	eq(d.apply_family("melting_clocks"), ERR_DOES_NOT_EXIST)


func test_hand_authored_trigger_detaches() -> void:
	pr.show["compositions"] = {"plain": {"layers": []}}
	eq(pr.trigger("plain", "cut", 0.0, false), OK)
	check(pr.director.family == null)


func test_operator_family_panel() -> void:
	var p2 := PerformanceRoot.new()
	p2.args = {"show": "res://tests/fixtures/families_show.json", "replay": true}
	add_child(p2)
	await frames(2)
	var panel: FamilyPanel = p2.operator._families
	check(panel != null, "family panel present")
	eq(panel._sliders.size(), MacroControls.AXES.size())
	eq(panel._slots.get_child_count(), p2.director.family.slots.size())
	panel._sliders["distortion"].value = 0.8
	near(p2.director.controls.get_axis("distortion"), 0.8, 1e-6, "live slider applies")
	panel.select_family("channel_surfing")
	eq(p2.director.family.family_id, "channel_surfing")
	panel.save_preset("__test")
	check(panel._load_presets().has("__test"))
	var all := panel._load_presets()
	all.erase("__test")
	var f := FileAccess.open(FamilyPanel.PRESETS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(all))
	f.close()
	p2.queue_free()
	await frames(1)
