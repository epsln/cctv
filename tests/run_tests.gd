extends SceneTree
## Minimal headless test runner.
## Usage: godot --headless --path . -s res://tests/run_tests.gd
## Discovers tests/unit/test_*.gd and tests/integration/test_*.gd; runs every
## method named test_*. Test scripts extend res://tests/test_case.gd.

const DIRS := ["res://tests/unit", "res://tests/integration"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
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
			var script: GDScript = load(dir_path + "/" + f)
			for m in script.get_script_method_list():
				var name: String = m["name"]
				if not name.begins_with("test_"):
					continue
				var tc: Node = script.new()
				root.add_child(tc)
				if tc.has_method("before_each"):
					await tc.before_each()
				await tc.call(name)
				if tc.has_method("after_each"):
					await tc.after_each()
				if tc.errors.is_empty():
					passed += 1
					print("  PASS %s::%s" % [f, name])
				else:
					failed += 1
					for e in tc.errors:
						failures.append("%s::%s: %s" % [f, name, e])
					print("  FAIL %s::%s" % [f, name])
				tc.queue_free()
				await process_frame
	print("\n%d passed, %d failed" % [passed, failed])
	for fl in failures:
		printerr("  " + fl)
	quit(1 if failed > 0 else 0)
