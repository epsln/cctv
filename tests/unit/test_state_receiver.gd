extends "res://tests/test_case.gd"

var clock: MusicalClock
var rx: MusicalStateReceiver


func before_each() -> void:
	clock = MusicalClock.new()
	clock.mode = MusicalClock.Mode.REPLAY
	clock.bpm = 120.0
	add_child(clock)
	rx = MusicalStateReceiver.new()
	rx.port = 0  # bound below on an ephemeral port
	rx.clock = clock


func _state(seq: int, t: float, extra := {}) -> Dictionary:
	var s := {
		"v": 1,
		"seq": seq,
		"t_audio": t,
		"t_sent": t,
		"timing_source": "audio",
		"bpm": 124.0,
		"beat_position": 3.25,
		"beat_confidence": 0.9,
	}
	s.merge(extra, true)
	return s


func test_maps_clock_offset_and_applies() -> void:
	add_child(rx)
	var now := Time.get_ticks_usec()
	# Sender clock is 1000 s behind ours; message sent "now".
	rx.receive(_state(1, now / 1e6 - 1000.0), now)
	near(rx.clock_offset(), 1000.0, 1e-3)
	eq(clock.timing_source, "audio")
	near(clock.bpm, 124.0)
	check(rx.stats["age_ms"] >= 0.0 and rx.stats["age_ms"] < 50.0, "age %s" % rx.stats["age_ms"])


func test_out_of_order_dropped_and_restart_detected() -> void:
	add_child(rx)
	var now := Time.get_ticks_usec()
	rx.receive(_state(5000, now / 1e6), now)
	rx.receive(_state(4999, now / 1e6), now)
	eq(rx.stats["out_of_order"], 1)
	rx.receive(_state(1, now / 1e6), now)  # analyser restarted
	eq(rx.stats["applied"], 2)


func test_udp_end_to_end() -> void:
	rx.port = 39871
	add_child(rx)
	check(rx.is_listening(), "bound")
	var tx := PacketPeerUDP.new()
	tx.set_dest_address("127.0.0.1", rx.port)
	var t := Time.get_ticks_usec() / 1e6
	tx.put_packet(JSON.stringify(_state(1, t)).to_utf8_buffer())
	tx.put_packet("garbage".to_utf8_buffer())
	tx.put_packet(JSON.stringify(_state(2, t, {"bpm": 125.0})).to_utf8_buffer())
	for i in 10:
		await frames(1)
		if rx.stats["received"] >= 3:
			break
	eq(rx.stats["received"], 3)
	eq(rx.stats["rejected"], 1)
	eq(int(rx.last_state["seq"]), 2, "newest applied")
	near(clock.bpm, 125.0)
	tx.close()
