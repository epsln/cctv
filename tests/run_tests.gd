extends SceneTree
## Minimal headless test runner.
## Usage: godot --headless --path . -s res://tests/run_tests.gd
## Discovers tests/unit/test_*.gd and tests/integration/test_*.gd; runs every
## method named test_*. Test scripts extend res://tests/test_case.gd.
##
## A test fails on a failed assertion or on any GDScript runtime error raised
## while it runs. A test file that does not compile fails as a whole.
## (push_error() calls are expected in negative tests and do not fail.)

const DIRS := ["res://tests/unit", "res://tests/integration"]


class ScriptErrorLogger:
	extends Logger
	var errors: PackedStringArray = []
	var _m := Mutex.new()

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type != ERROR_TYPE_SCRIPT and not code.contains("Parse Error"):
			return
		_m.lock()
		errors.append("%s:%d %s: %s %s" % [file, line, function, code, rationale])
		_m.unlock()

	func take() -> PackedStringArray:
		_m.lock()
		var e := errors
		errors = []
		_m.unlock()
		return e


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var logger := ScriptErrorLogger.new()
	OS.add_logger(logger)
	var passed := 0
	var failed := 0
	var failures: Array[String] = []
	for dir_path in DIRS:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		var files := Array(dir.get_files())
		files.sort()
		for f in files:
			if not (f.begins_with("test_") and f.ends_with(".gd")):
				continue
			logger.take()
			var script: GDScript = load(dir_path + "/" + f)
			if script == null or not script.can_instantiate():
				failed += 1
				failures.append("%s: does not compile %s" % [f, str(logger.take())])
				print("  FAIL %s (compile)" % f)
				continue
			for m in script.get_script_method_list():
				var name: String = m["name"]
				if not name.begins_with("test_"):
					continue
				logger.take()
				var tc: Node = script.new()
				root.add_child(tc)
				if tc.has_method("before_each"):
					await tc.before_each()
				await tc.call(name)
				if tc.has_method("after_each"):
					await tc.after_each()
				var errs: Array[String] = tc.errors.duplicate()
				for e in logger.take():
					errs.append("script error: " + e)
				if errs.is_empty():
					passed += 1
					print("  PASS %s::%s" % [f, name])
				else:
					failed += 1
					for e in errs:
						failures.append("%s::%s: %s" % [f, name, e])
					print("  FAIL %s::%s" % [f, name])
				tc.queue_free()
				await process_frame
	print("\n%d passed, %d failed" % [passed, failed])
	for fl in failures:
		printerr("  " + fl)
	for i in 3:
		await process_frame
	OS.remove_logger(logger)
	quit(1 if failed > 0 else 0)
