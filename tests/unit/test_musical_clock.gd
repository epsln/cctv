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
