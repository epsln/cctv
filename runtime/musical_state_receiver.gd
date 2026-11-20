class_name MusicalStateReceiver
extends Node
## Receives MusicalState datagrams (docs/musical-state.md) from the analyser
## and applies the newest one to the MusicalClock each frame.
##
## The analyser and Godot both use monotonic clocks but with different origins.
## The offset between them is estimated as the minimum of
## (local receive time - t_sent) over a sliding window. On localhost the
## minimum one-way delay is effectively zero, so this recovers the clock offset.
## The state's t_audio is then mapped into MusicalClock time.
##
## Only the newest datagram per frame is applied, because older ones are
## superseded. Receive and parse cost is measured (`stats.process_ms`).

const SCHEMA_VERSION := 1
const DEFAULT_PORT := 9870

@export var port := DEFAULT_PORT
@export var bind_address := "127.0.0.1"
## Window (s) for the clock-offset minimum. Longer is more robust to jitter;
## shorter adapts faster if a clock steps.
@export var offset_window := 10.0

var clock: MusicalClock
var last_state := {}
var stats := {
	"received": 0,
	"applied": 0,
	"rejected": 0,
	"out_of_order": 0,
	"overruns": 0,
	"age_ms": -1.0,
	"transport_ms": -1.0,
	"analysis_ms": 0.0,
	"process_ms": 0.0,
}
var errors: PackedStringArray = []

var _udp := PacketPeerUDP.new()
var _last_seq := -1
## Windowed minimum in one-second buckets: [bucket_second, min_offset_s].
var _buckets: Array = []
var _offset := INF


func _ready() -> void:
	process_priority = -110  # before MusicalClock (-100)
	if listen() != OK:
		push_warning("MusicalStateReceiver: cannot bind %s:%d" % [bind_address, port])


func listen() -> Error:
	_udp.close()
	var err := _udp.bind(port, bind_address)
	if err != OK:
		errors.append("cannot bind %s:%d (%d)" % [bind_address, port, err])
	return err


func is_listening() -> bool:
	return _udp.is_bound()


func _exit_tree() -> void:
	_udp.close()


func _process(_delta: float) -> void:
	if not _udp.is_bound():
		return
	var t0 := Time.get_ticks_usec()
	var newest := {}
	var newest_usec := 0
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var now := Time.get_ticks_usec()
		var s = JSON.parse_string(pkt.get_string_from_utf8())
		stats["received"] += 1
		if not (s is Dictionary) or int(s.get("v", -1)) != SCHEMA_VERSION:
			stats["rejected"] += 1
			continue
		_observe_offset(now, float(s.get("t_sent", 0.0)))
		if newest.is_empty() or int(s.get("seq", 0)) > int(newest.get("seq", 0)):
			newest = s
			newest_usec = now
	if not newest.is_empty():
		receive(newest, newest_usec)
	stats["process_ms"] = (Time.get_ticks_usec() - t0) / 1000.0


## Apply a parsed state received at local time `recv_usec` (also used by tests).
func receive(s: Dictionary, recv_usec: int) -> void:
	var seq := int(s.get("seq", 0))
	if seq < _last_seq - 1000:  # analyser restarted
		_last_seq = -1
	if seq <= _last_seq:
		stats["out_of_order"] += 1
		return
	_last_seq = seq
	last_state = s
	if _offset == INF:
		_observe_offset(recv_usec, float(s.get("t_sent", 0.0)))
	# t_audio in local monotonic seconds, then in clock time.
	var t_audio_local := float(s.get("t_audio", 0.0)) + _offset
	var now_s := Time.get_ticks_usec() / 1_000_000.0
	var age := now_s - t_audio_local
	stats["age_ms"] = age * 1000.0
	stats["transport_ms"] = (recv_usec / 1_000_000.0 - (float(s.get("t_sent", 0.0)) + _offset)) * 1000.0
	stats["analysis_ms"] = float(s.get("analysis_ms", 0.0))
	stats["overruns"] = int(s.get("overruns", 0))
	stats["applied"] += 1
	if clock:
		clock.apply_state(s, clock.time - age)


func _observe_offset(now_usec: int, t_sent: float) -> void:
	var o := now_usec / 1_000_000.0 - t_sent
	var sec := now_usec / 1_000_000
	if _buckets.is_empty() or int(_buckets[-1][0]) != sec:
		_buckets.append([sec, o])
		while _buckets.size() > maxi(1, ceili(offset_window)):
			_buckets.pop_front()
		_offset = INF
		for b in _buckets:
			_offset = minf(_offset, float(b[1]))
	elif o < float(_buckets[-1][1]):
		_buckets[-1][1] = o
	_offset = minf(_offset, o)


## Restart sequence tracking (the analyser was restarted).
func reset() -> void:
	_last_seq = -1
	_buckets.clear()
	_offset = INF


func clock_offset() -> float:
	return _offset


func describe() -> Dictionary:
	return {
		"listening": is_listening(),
		"port": port,
		"stats": stats,
		"clock_offset": _offset,
		"errors": errors,
	}
