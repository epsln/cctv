extends Node
## Base class for tests. Records assertion failures instead of aborting.

var errors: Array[String] = []


func check(cond: bool, msg := "assertion failed") -> void:
	if not cond:
		errors.append(msg)


func eq(a: Variant, b: Variant, msg := "") -> void:
	if a != b:
		errors.append("%s expected %s == %s" % [msg, str(a), str(b)])


func near(a: float, b: float, eps := 1e-4, msg := "") -> void:
	if absf(a - b) > eps:
		errors.append("%s expected %f ~= %f" % [msg, a, b])


func frames(n := 1) -> void:
	for i in n:
		await get_tree().process_frame
