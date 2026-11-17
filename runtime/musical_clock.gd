class_name MusicalClock
extends Node
## Single source of time for animation, playheads, scheduling and feedback.
##
## Modes:
##  - LIVE:   advances from the monotonic clock (Time.get_ticks_usec) each frame.
##  - REPLAY: advances only through advance()/seek(); deterministic for capture.
##
## Phase convention: beat_phase is in [0, 1), 0.0 exactly at a beat onset and
## increasing linearly to the next beat. bar_phase follows the same convention
## and is only meaningful when bar_aligned is true; otherwise it is -1.0.
##
## Musical features are a fixed-BPM placeholder until Milestone 2 supplies
## real analysis via set_features().

signal seeked(time: float)
signal beat(index: int)

enum Mode { LIVE, REPLAY }

@export var mode: Mode = Mode.LIVE
@export var bpm := 124.0
## Time (s) of a reference beat onset.
@export var beat_offset := 0.0
@export var beats_per_bar := 4
@export var bar_aligned := false
## Envelope decay time constant (s).
@export var envelope_decay := 0.12
## Timing confidence in [0, 1]. Placeholder clock reports 1.0 for beat, 0 for bar.
var beat_confidence := 1.0

var time := 0.0
var frame := 0
var _last_usec := -1
var _last_beat_index := -2147483648
## External feature overrides (Milestone 2). Empty = synthesise from clock.
var _features := {}


func _ready() -> void:
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
	time += maxf(dt, 0.0)
	frame += 1
	var bi := beat_index()
	if bi != _last_beat_index:
		_last_beat_index = bi
		beat.emit(bi)


## Jump to time t. Listeners must reset temporal state (feedback, envelopes).
func seek(t: float) -> void:
	time = maxf(t, 0.0)
	_last_usec = -1
	_last_beat_index = beat_index()
	seeked.emit(time)


func beat_length() -> float:
	return 60.0 / bpm


func beat_position() -> float:
	return (time - beat_offset) / beat_length()


func beat_index() -> int:
	return floori(beat_position())


func beat_phase() -> float:
	var p := beat_position()
	return p - floorf(p)


func bar_phase() -> float:
	if not bar_aligned:
		return -1.0
	var p := beat_position() / beats_per_bar
	return p - floorf(p)


## Clock time of the first beat onset strictly after `after` (default: now).
func next_beat_time(after := -1.0) -> float:
	var t := time if after < 0.0 else after
	return beat_offset + (floorf((t - beat_offset) / beat_length()) + 1.0) * beat_length()


func beat_envelope() -> float:
	return exp(-beat_phase() * beat_length() / envelope_decay)


func set_features(f: Dictionary) -> void:
	_features = f


## Shader-facing values. Names match docs/03-visualization-architecture.md.
func uniforms() -> Dictionary:
	var env := beat_envelope()
	return {
		"uTime": time,
		"uBeatPhase": beat_phase(),
		"uBeatEnvelope": env,
		"uBassEnergy": _features.get("bass_energy", env),
		"uOnsetEnvelope": _features.get("onset_envelope", env),
		"uBarPhase": bar_phase(),
	}
