extends "res://tests/test_case.gd"


func test_slope_per_hour() -> void:
	var tl := [{"elapsed": 0.0, "rss": 100.0}, {"elapsed": 1800.0, "rss": 110.0}, {"elapsed": 3600.0, "rss": 120.0}]
	near(Benchmark.slope_per_hour(tl, "rss"), 20.0, 1e-6)
	eq(Benchmark.slope_per_hour([], "rss"), 0.0)


func test_evaluate_acceptance() -> void:
	var good := {"mean_fps": 59.9, "late_ratio": 0.001, "p99_ms": 18.0}
	check(Benchmark.evaluate(good, 60.0)["pass"])
	var bad := {"mean_fps": 59.9, "late_ratio": 0.05, "p99_ms": 18.0}
	var r := Benchmark.evaluate(bad, 60.0)
	check(not r["pass"])
	check(not r["late_ratio"])


func test_proc_readers() -> void:
	if OS.get_name() != "Linux":
		return
	check(Benchmark.rss_mb() > 1.0, "rss")
	check(Benchmark.cpu_seconds() > 0.0, "cpu time")


func test_upload_benchmark_reports_sizes() -> void:
	var r := Benchmark.upload_benchmark(2)
	eq(r.keys().size(), 3)
	check(r.has("1920x1080"))
