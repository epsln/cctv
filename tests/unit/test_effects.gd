extends "res://tests/test_case.gd"


func test_all_shaders_load_and_expose_musical_uniforms() -> void:
	for t in Effect.types():
		var e := Effect.from_dict({"type": t})
		check(e.is_valid(), t + ": " + e.error)
		var names := e.material.shader.get_shader_uniform_list().map(func(u): return u["name"])
		for m in Effect.MUSICAL:
			check(m in names, "%s missing %s" % [t, m])
		check(not e.param_names().is_empty(), t + " has tunables")


func test_unknown_type_and_param_rejected() -> void:
	check(not Effect.from_dict({"type": "rl_chromatic"}).is_valid(), "unknown type")
	check(not Effect.from_dict({"type": "chromatic", "params": {"nope": 1}}).is_valid(), "bad param")
	var bad_bind := {"type": "chromatic", "bindings": [{"param": "strength", "signal": "uCrowd", "amount": 1}]}
	check(not Effect.from_dict(bad_bind).is_valid(), "bad signal")


func test_binding_modulates_param() -> void:
	var e := Effect.from_dict({
		"type": "chromatic", "params": {"strength": 0.01},
		"bindings": [{"param": "strength", "signal": "uBassEnergy", "amount": 0.1}]})
	var out := e.apply({"uBassEnergy": 0.5})
	near(out["strength"], 0.06)
	near(e.material.get_shader_parameter("strength"), 0.06)


func test_binding_uses_shader_default_when_unset() -> void:
	var e := Effect.from_dict({"type": "chromatic", "bindings": [{"param": "barrel", "signal": "uBeatEnvelope", "amount": 1.0}]})
	near(e.apply({"uBeatEnvelope": 0.0})["barrel"], 0.15)


func test_roundtrip() -> void:
	var d := {"type": "glitch", "params": {"amount": 0.1}, "bindings": [{"param": "amount", "signal": "uOnsetEnvelope", "amount": 0.2}]}
	eq(Effect.from_dict(d).to_dict(), d)


func test_empty_chain_is_passthrough() -> void:
	var c := EffectChain.new()
	add_child(c)
	var tex := solid(Color.RED)
	eq(c.configure([], tex, Vector2i(32, 32)), OK)
	check(c.get_output() == tex)
	eq(c.pass_count(), 0)


func test_chain_order_and_invalid_rejected() -> void:
	var c := EffectChain.new()
	add_child(c)
	c.configure([{"type": "glitch"}, {"type": "chromatic"}], solid(Color.RED), Vector2i(32, 32))
	eq(c.to_array().map(func(e): return e["type"]), ["glitch", "chromatic"])
	eq(c.configure([{"type": "bogus"}], null, Vector2i(8, 8)), ERR_INVALID_PARAMETER)


func test_chain_renders_pixels() -> void:
	if not gpu():
		return
	var c := EffectChain.new()
	add_child(c)
	c.configure([{"type": "color_grade", "params": {"saturation": 0.0}}], solid(Color.RED), Vector2i(32, 32))
	c.update({})
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var p := center_pixel(c.get_output())
	near(p.r, p.g, 0.02, "desaturated r==g")
	check(p.r > 0.1 and p.r < 0.4, "red luma ~0.21, got %s" % str(p))
