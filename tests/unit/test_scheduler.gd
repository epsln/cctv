extends "res://tests/test_case.gd"

var clock: MusicalClock
var sched: Scheduler
var log := []


func before_each() -> void:
	clock = MusicalClock.new()
	clock.mode = MusicalClock.Mode.REPLAY
	clock.bpm = 120.0
	add_child(clock)
	sched = Scheduler.new()
	sched.clock = clock
	add_child(sched)
	log = []


func _tick(n: int, dt := 1.0 / 60.0) -> void:
	for i in n:
		clock.advance(dt)
		sched.run_due()


func test_next_beat_executes_on_the_beat() -> void:
	clock.advance(0.1)
	var id := sched.schedule(func(): log.append(clock.beat_position()), "next_beat")
	check(id > 0)
	_tick(10)  # 0.1 + 10/60 = 0.267 s < 0.5
	eq(log.size(), 0, "not yet")
	_tick(20)
	eq(log.size(), 1)
	var ev := sched.last_event()
	eq(ev["status"], "executed")
	check(ev["late_ms"] >= -1e-6 and ev["late_ms"] < 1000.0 / 60.0 + 0.01, "within a frame: %s" % ev["late_ms"])
	near(ev["target_position"], 1.0, 1e-9)


func test_target_follows_tempo_changes() -> void:
	sched.schedule(func(): log.append(clock.time), "beats", 2.0)
	clock.bpm = 60.0  # 2 beats now take 2 s
	_tick(60)
	eq(log.size(), 0, "1 s: only one beat elapsed")
	_tick(61)
	eq(log.size(), 1)


func test_next_bar_rejected_without_alignment() -> void:
	eq(sched.schedule(func(): log.append(1), "next_bar"), -1)
	eq(sched.last_event()["status"], "rejected")
	eq(sched.describe()["rejected"], 1)
	clock.align_bar_now()
	clock.advance(0.1)
	check(sched.schedule(func(): log.append(1), "next_bar") > 0)
	_tick(130)  # 4 beats = 2 s
	eq(log, [1])
	near(sched.last_event()["target_position"], 4.0, 1e-9)


func test_grid_and_ordering() -> void:
	clock.advance(0.6)  # beat 1.2
	sched.schedule(func(): log.append("b"), "grid", 4.0)
	sched.schedule(func(): log.append("a"), "grid", 2.0)
	sched.schedule(func(): log.append("now"), "now")
	_tick(1)
	eq(log, ["now"])
	_tick(130)
	eq(log, ["now", "a", "b"])


func test_cancel_and_invalid() -> void:
	var id := sched.schedule(func(): log.append(1), "next_beat")
	check(sched.cancel(id))
	check(not sched.cancel(id))
	_tick(60)
	eq(log, [])
	eq(sched.schedule(func(): pass, "grid", 0.0), -1)
	eq(sched.schedule(func(): pass, "bogus"), -1)


func test_failed_action_reported() -> void:
	sched.schedule(func(): return ERR_INVALID_DATA, "now")
	_tick(1)
	eq(sched.last_event()["status"], "failed")
