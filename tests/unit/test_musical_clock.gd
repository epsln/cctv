extends "res://tests/test_case.gd"

var clock: MusicalClock


func before_each() -> void:
	clock = MusicalClock.new()
	clock.mode = MusicalClock.Mode.REPLAY
	clock.bpm = 120.0
	add_child(clock)


func test_replay_advances_only_explicitly() -> void:
	await frames(3)
	eq(clock.time, 0.0, "time")
	clock.advance(0.25)
	near(clock.time, 0.25)
	eq(clock.frame, 1)


func test_beat_phase_convention() -> void:
	near(clock.beat_phase(), 0.0, 1e-6, "onset")
	clock.advance(0.25)
	near(clock.beat_phase(), 0.5, 1e-6, "half beat")
	clock.advance(0.25)
	near(clock.beat_phase(), 0.0, 1e-6, "next onset")
	eq(clock.beat_index(), 1)


func test_beat_offset() -> void:
	clock.beat_offset = 0.1
	clock.seek(0.1)
	near(clock.beat_phase(), 0.0, 1e-6)


func test_envelope_peaks_on_beat() -> void:
	near(clock.beat_envelope(), 1.0)
	clock.advance(0.2)
	check(clock.beat_envelope() < 0.5, "envelope decays")


func test_bar_phase_unavailable_without_alignment() -> void:
	eq(clock.bar_phase(), -1.0)
	clock.bar_aligned = true
	clock.advance(1.0)  # 2 beats of 4
	near(clock.bar_phase(), 0.5)


func test_seek_emits_and_negative_clamps() -> void:
	var got := []
	clock.seeked.connect(func(t): got.append(t))
	clock.seek(-5.0)
	eq(got, [0.0])


func test_beat_signal() -> void:
	var beats := []
	clock.beat.connect(func(i): beats.append(i))
	for i in 11:
		clock.advance(0.1)
	eq(beats, [1, 2])


func test_live_mode_uses_monotonic_time() -> void:
	clock.set_mode(MusicalClock.Mode.LIVE)
	await frames(5)
	check(clock.time > 0.0, "live time advances")


func test_uniforms_keys_and_feature_override() -> void:
	var u := clock.uniforms()
	for k in ["uBeatPhase", "uBeatEnvelope", "uBassEnergy", "uOnsetEnvelope", "uBarPhase"]:
		check(u.has(k), k)
	clock.set_features({"bass_energy": 0.3})
	near(clock.uniforms()["uBassEnergy"], 0.3)


func test_bpm_change_keeps_phase_continuous() -> void:
	clock.advance(0.25)  # half a beat at 120
	clock.bpm = 60.0
	near(clock.beat_phase(), 0.5, 1e-6, "no jump on tempo change")
	clock.advance(0.5)  # half a beat at 60
	near(clock.beat_phase(), 0.0, 1e-6)
	eq(clock.beat_index(), 1)


func test_next_beat_and_bar_times() -> void:
	clock.advance(0.1)
	near(clock.next_beat_time(), 0.5, 1e-6)
	eq(clock.next_bar_time(), -1.0, "no bar without alignment")
	clock.advance(0.5)  # beat 1.2
	clock.align_bar_now()  # nearest beat (1) is a downbeat
	near(clock.next_bar_position(), 5.0, 1e-6)
	near(clock.next_bar_time(), 0.6 + 3.8 * 0.5, 1e-6)
	near(clock.bar_phase(), 0.2 / 4.0, 1e-6)
	eq(clock.bar_source, "manual")
	clock.clear_bar_alignment()
	eq(clock.bar_phase(), -1.0)


func _state(pos: float, bpm := 120.0, conf := 0.9, extra := {}) -> Dictionary:
	var s := {"timing_source": "audio", "bpm": bpm, "beat_position": pos, "beat_confidence": conf, "bass": 0.7}
	s.merge(extra, true)
	return s


func test_follows_external_tempo_and_phase() -> void:
	clock.advance(1.0)  # internal: beat 2.0
	# Analyser says we are at 2.3 beats, 126 BPM: first acquisition jumps.
	clock.apply_state(_state(10.3, 126.0), clock.time)
	eq(clock.timing_source, "audio")
	near(clock.beat_phase(), 0.3, 1e-6, "jump on first lock")
	eq(clock.beat_index(), 2, "local beat count kept")
	near(clock.bpm, 126.0, 1e-6)
	# Small error afterwards is slewed, not jumped.
	clock.apply_state(_state(10.4, 126.0), clock.time)
	near(clock.beat_phase(), 0.3, 1e-6, "no jump for small error")
	for i in 90:
		clock.advance(1.0 / 60.0)
		clock.apply_state(_state(10.4 + (i + 1) / 60.0 * 2.1, 126.0), clock.time)
	near(clock.beat_phase(), fposmod(0.4 + 1.5 * 2.1, 1.0), 0.01, "converged")
	check(absf(clock.describe()["phase_error"]) < 0.01)


func test_slew_never_runs_backwards() -> void:
	clock.apply_state(_state(0.0), clock.time)
	clock.apply_state(_state(-0.2), clock.time)  # 0.2 beat behind: slew
	var last := clock.beat_position()
	for i in 20:
		clock.advance(1.0 / 60.0)
		check(clock.beat_position() > last, "monotonic")
		last = clock.beat_position()


func test_discontinuity_jumps() -> void:
	clock.apply_state(_state(0.0), clock.time)
	clock.apply_state(_state(0.45, 120.0, 0.9, {"discontinuity": true}), clock.time)
	near(clock.beat_phase(), 0.45, 1e-6)
	eq(clock.stats["jumps"], 1)


func test_low_confidence_ignored_and_stale_falls_back() -> void:
	clock.apply_state(_state(0.3, 130.0, 0.1), clock.time)
	eq(clock.timing_source, "internal", "low confidence ignored")
	near(clock.bpm, 120.0)
	near(clock.uniforms()["uBassEnergy"], 0.7, 1e-6, "features still used")
	clock.apply_state(_state(0.3, 130.0), clock.time)
	eq(clock.timing_source, "audio")
	var got := []
	clock.timing_source_changed.connect(func(s): got.append(s))
	for i in 60:  # 1 s without states
		clock.advance(1.0 / 60.0)
	eq(clock.timing_source, "internal", "stale -> internal")
	eq(got, ["internal"])
	near(clock.bpm, 130.0, 0.01, "keeps last tempo")
	check(clock.beat_confidence < 0.9, "confidence decays")
	near(clock.uniforms()["uBassEnergy"], clock.beat_envelope(), 1e-6, "stale features fade out")


func test_bar_estimate_translated_to_local_numbering() -> void:
	clock.advance(1.0)  # local beat 2.0
	# Analyser numbering is 8 ahead; its downbeat is beat 1 (mod 4) -> local 1 - 8 = 1 (mod 4).
	clock.apply_state(_state(10.0, 120.0, 0.9, {"downbeat": 1, "bar_confidence": 0.8}), clock.time)
	check(clock.bar_aligned)
	eq(clock.bar_source, "estimate")
	near(clock.bar_phase(), 0.25, 1e-6, "local beat 2 is 1 beat into the bar")
	clock.apply_state(_state(10.0, 120.0, 0.9, {"downbeat": 1, "bar_confidence": 0.2}), clock.time)
	check(not clock.bar_aligned, "weak estimate drops alignment")
	clock.align_bar_now()
	clock.apply_state(_state(10.0, 120.0, 0.9, {"downbeat": 3, "bar_confidence": 0.9}), clock.time)
	eq(clock.bar_source, "manual", "manual wins")


func test_nudge_persists_while_following() -> void:
	clock.apply_state(_state(0.0), clock.time)
	clock.nudge(0.1)
	for i in 30:
		clock.advance(1.0 / 60.0)
		clock.apply_state(_state((i + 1) / 60.0 * 2.0), clock.time)
	near(clock.beat_phase(), fposmod(1.0 + 0.1, 1.0), 0.01)


func test_latency_compensation_leads_visuals() -> void:
	clock.latency_compensation = 0.05
	clock.apply_state(_state(0.0), clock.time)
	for i in 90:
		clock.advance(1.0 / 60.0)
		clock.apply_state(_state((i + 1) / 60.0 * 2.0), clock.time)
	near(clock.beat_phase(), 0.1, 0.01, "50 ms at 120 BPM = 0.1 beat ahead")


func test_new_uniforms() -> void:
	var u := clock.uniforms()
	for k in ["uMidEnergy", "uHighEnergy", "uEnergyTrend", "uBeatConfidence"]:
		check(u.has(k), k)
		check(k in Effect.MUSICAL, k + " bindable")
