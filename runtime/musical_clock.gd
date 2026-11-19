class_name MusicalClock
extends Node
## Single source of time for animation, playheads, scheduling and feedback.
##
## Modes:
##  - LIVE:   advances from the monotonic clock (Time.get_ticks_usec) each frame.
##  - REPLAY: advances only through advance()/seek(); deterministic for capture.
##
## Beat position is integrated (pos += dt * bpm / 60), so tempo changes never
## make the phase jump. Phase convention: beat_phase is in [0, 1), 0.0 exactly at
## a beat onset. bar_phase follows the same convention and is -1.0 unless bars
## are aligned (operator alignment, or an analyser estimate above
## bar_min_confidence).
##
## Timing sources (docs/milestone-2.md):
##  - "internal": free-running at `bpm`. This is the show tempo when nothing
##    else has been received, and the fallback when external timing is stale or
##    not confident: the clock keeps the last tempo and phase and its
##    confidence decays.
##  - "audio" / "mixxx": follows MusicalState messages (apply_state). Tempo is
##    smoothed and phase errors are slewed, never jumped, unless the source
##    reports a discontinuity (new track, seek).

signal seeked(time: float)
signal beat(index: int)
## Emitted when the timing source changes (e.g. "audio" -> "internal").
signal timing_source_changed(source: String)

enum Mode { LIVE, REPLAY }

@export var mode: Mode = Mode.LIVE
@export var bpm := 124.0
## Time (s) of a reference beat onset (internal timing and seek()).
@export var beat_offset := 0.0
@export var beats_per_bar := 4
## True when bar_phase is meaningful. Set by align_bar_now(), by confident
## estimates, or directly (downbeat on beat index 0 mod beats_per_bar).
@export var bar_aligned := false
## Envelope decay time constant (s).
@export var envelope_decay := 0.12

@export_group("External timing")
## External timing older than this (s) is stale: fall back to internal.
@export var stale_after := 0.5
## Ignore external timing below this beat confidence.
@export var min_confidence := 0.3
## Time constant (s) for following external tempo.
@export var tempo_smoothing := 0.5
## Time constant (s) for removing phase error.
@export var phase_slew_time := 0.3
## Phase errors above this (beats) are jumped when the source flags a discontinuity.
@export var jump_threshold := 0.25
## Let analyser bar estimates align bars. Off by default: on real techno the
## estimate is often consistently a beat off (docs/beat-evaluation.md), so a
## wrong bar is likelier than none. Estimates are still reported (bar_estimate).
@export var auto_bar_alignment := false
## Bar estimates at or above this confidence align bars (if enabled and not manual).
@export var bar_min_confidence := 0.5
## Shift visuals earlier (s) to compensate projector/display latency.
@export var latency_compensation := 0.0
## Features older than this (s) fade back to clock-synthesised values.
@export var feature_stale_after := 0.25

## Timing confidence in [0, 1].
var beat_confidence := 1.0
var timing_source := "internal"
## "none", "estimate" or "manual".
var bar_source := "none"
var bar_confidence := 0.0
## Latest analyser downbeat estimate in local numbering (-1: none), aligned or not.
var bar_estimate := -1

var time := 0.0
var frame := 0
var stats := {"states": 0, "jumps": 0, "fallbacks": 0, "max_phase_error": 0.0}
var _beat_pos := 0.0
var _last_usec := -1
var _last_beat_index := -2147483648
## Beat index (mod beats_per_bar) that starts a bar, in local numbering.
var _downbeat := 0
## Last external state, the clock time it describes and when it was applied.
var _ext := {}
var _ext_t := -INF
var _ext_bpm := 0.0
var _phase_trim := 0.0
var _ever_external := false
var _phase_error := 0.0
## External feature overrides. Empty = synthesise from clock.
var _features := {}
var _features_t := -INF


func _ready() -> void:
	_beat_pos = (time - beat_offset) / beat_length()
	_last_beat_index = beat_index()


func _process(_delta: float) -> void:
	if mode == Mode.LIVE:
		var now := Time.get_ticks_usec()
		if _last_usec >= 0:
			_step((now - _last_usec) / 1_000_000.0)
		_last_usec = now


func set_mode(m: Mode) -> void:
	mode = m
	_last_usec = -1


## Advance by dt seconds (REPLAY). Ignored in LIVE mode to avoid double counting.
func advance(dt: float) -> void:
	if mode == Mode.REPLAY:
		_step(dt)


func _step(dt: float) -> void:
	dt = maxf(dt, 0.0)
	time += dt
	frame += 1
	var nominal := dt * bpm / 60.0
	var correction := 0.0
	_update_source()
	if timing_source != "internal" and dt > 0.0:
		var age := time - _ext_t
		bpm += (1.0 - exp(-dt / tempo_smoothing)) * (_ext_bpm - bpm)
		_phase_error = _wrap(_target_position(age) - (_beat_pos + nominal))
		correction = _phase_error * minf(1.0, dt / phase_slew_time)
		# Never run backwards or more than twice as fast.
		correction = clampf(correction, -0.5 * nominal, nominal)
	elif timing_source == "internal" and _ever_external:
		beat_confidence *= exp(-dt / 2.0)
	_beat_pos += nominal + correction
	_emit_beats()


func _emit_beats() -> void:
	var bi := beat_index()
	if bi != _last_beat_index:
		_last_beat_index = bi
		beat.emit(bi)


## Jump to time t. Listeners must reset temporal state (feedback, envelopes).
## Beat position is reset from beat_offset and the current tempo.
func seek(t: float) -> void:
	time = maxf(t, 0.0)
	_beat_pos = (time - beat_offset) / beat_length()
	_last_usec = -1
	_ext = {}
	_ext_t = -INF
	_update_source()
	_last_beat_index = beat_index()
	seeked.emit(time)


func beat_length() -> float:
	return 60.0 / bpm


func beat_position() -> float:
	return _beat_pos


func beat_index() -> int:
	return floori(_beat_pos)


func beat_phase() -> float:
	return _beat_pos - floorf(_beat_pos)


func bar_phase() -> float:
	if not bar_aligned:
		return -1.0
	return fposmod(_beat_pos - _downbeat, beats_per_bar) / beats_per_bar


## Clock time at beat position `pos`, extrapolated at the current tempo.
func time_at_position(pos: float) -> float:
	return time + (pos - _beat_pos) * beat_length()


## Clock time of the first beat onset strictly after `after` (default: now).
func next_beat_time(after := -1.0) -> float:
	var t := time if after < 0.0 else after
	var p := _beat_pos + (t - time) / beat_length()
	return time_at_position(floorf(p) + 1.0)


## Beat position of the next bar start strictly after now, or -1 if bars are not aligned.
func next_bar_position() -> float:
	if not bar_aligned:
		return -1.0
	var into := fposmod(_beat_pos - _downbeat, beats_per_bar)
	return _beat_pos - into + beats_per_bar


## Clock time of the next bar start, or -1 if bars are not aligned.
func next_bar_time() -> float:
	return -1.0 if not bar_aligned else time_at_position(next_bar_position())


func beat_envelope() -> float:
	return exp(-beat_phase() * beat_length() / envelope_decay)


# --- External timing -------------------------------------------------------


## Apply a MusicalState (docs/musical-state.md) describing clock time `at`
## (the receiver maps the sender's timestamps into clock time).
func apply_state(s: Dictionary, at: float) -> void:
	stats["states"] += 1
	set_features(s)
	_features_t = at
	var pos = s.get("beat_position")
	var conf := float(s.get("beat_confidence", 0.0))
	var src := str(s.get("timing_source", "none"))
	if pos == null or src == "none" or float(s.get("bpm", 0.0)) <= 0.0 or conf < min_confidence:
		_update_source()
		return
	var first := timing_source == "internal"
	_ext = s
	_ext_t = at
	_ext_bpm = float(s["bpm"])
	_ever_external = true
	beat_confidence = conf
	var err := _wrap(_target_position(time - at) - _beat_pos)
	if (first or bool(s.get("discontinuity", false))) and absf(err) > jump_threshold:
		_beat_pos += err  # re-acquired: jump instead of a long slew
		bpm = _ext_bpm
		_last_beat_index = beat_index()
		stats["jumps"] += 1
	elif first:
		bpm = _ext_bpm
	_update_bar(s, at)
	_update_source()


## Analyser beat position extrapolated to `age` seconds after the state.
func _target_position(age: float) -> float:
	var p := float(_ext["beat_position"])
	return p + (age + latency_compensation) * _ext_bpm / 60.0 + _phase_trim


func _update_bar(s: Dictionary, at: float) -> void:
	var conf := float(s.get("bar_confidence", 0.0))
	var db := int(s.get("downbeat", -1))
	var shift := roundi(_beat_pos - _target_position(time - at))
	bar_estimate = posmod(db + shift, beats_per_bar) if db >= 0 else -1
	if bar_source == "manual":
		return
	if db < 0 or conf < bar_min_confidence or not auto_bar_alignment:
		if bar_source == "estimate":
			bar_aligned = false
			bar_source = "none"
		bar_confidence = conf
		return
	# Translate the analyser's beat numbering into ours.
	_downbeat = bar_estimate
	bar_aligned = true
	bar_source = "estimate"
	bar_confidence = conf


func _update_source() -> void:
	var src := "internal"
	if not _ext.is_empty() and time - _ext_t <= stale_after:
		src = str(_ext.get("timing_source", "audio"))
	if src != timing_source:
		if src == "internal":
			stats["fallbacks"] += 1
			_phase_error = 0.0
		timing_source = src
		timing_source_changed.emit(src)
	stats["max_phase_error"] = maxf(stats["max_phase_error"], absf(_phase_error))


static func _wrap(x: float) -> float:
	return x - roundf(x)


## Operator: the beat nearest to now is the first beat of a bar.
func align_bar_now() -> void:
	_downbeat = posmod(roundi(_beat_pos), beats_per_bar)
	bar_aligned = true
	bar_source = "manual"
	bar_confidence = 1.0


## Operator: forget manual alignment; analyser estimates may align bars again.
func clear_bar_alignment() -> void:
	bar_aligned = false
	bar_source = "none"
	bar_confidence = 0.0


## Operator: shift the phase by `beats` (persistent while following external timing).
func nudge(beats: float) -> void:
	_beat_pos += beats
	if timing_source != "internal":
		_phase_trim += beats
	_last_beat_index = beat_index()


## Override features manually (no timestamp: never goes stale).
func set_features(f: Dictionary) -> void:
	_features = f
	_features_t = -INF


func describe() -> Dictionary:
	return {
		"timing_source": timing_source,
		"bpm": bpm,
		"beat_position": _beat_pos,
		"beat_confidence": beat_confidence,
		"timing_age": time - _ext_t if _ext_t > -INF else -1.0,
		"phase_error": _phase_error,
		"bar_aligned": bar_aligned,
		"bar_source": bar_source,
		"bar_confidence": bar_confidence,
		"bar_estimate": bar_estimate,
		"phase_trim": _phase_trim,
		"stats": stats,
	}


## 1 while features are fresh, fading to 0 over feature_stale_after after that.
func _feature_weight() -> float:
	if _features.is_empty():
		return 0.0
	if _features_t == -INF:
		return 1.0  # set_features() without a timestamp: manual override
	var age := time - _features_t
	return clampf(1.0 - (age - feature_stale_after) / feature_stale_after, 0.0, 1.0)


func _feature(keys: Array, synth: float) -> float:
	var w := _feature_weight()
	if w <= 0.0:
		return synth
	for k in keys:
		if _features.has(k) and _features[k] != null:
			return lerpf(synth, float(_features[k]), w)
	return synth


## Shader-facing values. Names match docs/03-visualization-architecture.md.
func uniforms() -> Dictionary:
	var env := beat_envelope()
	return {
		"uTime": time,
		"uBeatPhase": beat_phase(),
		"uBeatEnvelope": env,
		"uBassEnergy": _feature(["bass", "bass_energy"], env),
		"uMidEnergy": _feature(["mid"], 0.0),
		"uHighEnergy": _feature(["high"], 0.0),
		"uOnsetEnvelope": _feature(["onset_envelope"], env),
		"uEnergyTrend": _feature(["energy_trend"], 0.0),
		"uBeatConfidence": beat_confidence,
		"uBarPhase": bar_phase(),
	}
