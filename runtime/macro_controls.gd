class_name MacroControls
extends RefCounted
## Bounded semantic controls for composition families (docs/06). Each axis is
## normalised to 0..1 and maps to its own disjoint set of concrete parameters,
## so density, motion, cutting, distortion and persistence vary independently
## rather than collapsing into one intensity knob.
##
## Axes:
##   density      how much is on screen (layer count / covered area)
##   motion       movement of layers (drift, beat pulse, rotation range)
##   cutting      source-change cadence (beats between cuts, share swapped)
##   distortion   effect amount; `character` picks the kind of distortion
##   persistence  temporal memory: feedback trails and motif recurrence
##   annotation   face boxes / labels / redactions
##   text_rate    document and text event rate
##
## Live axes are applied in place; STRUCTURAL ones (and character) rebuild
## the composition with the same seed.

const DEFAULTS := {
	"density": 0.5,
	"motion": 0.3,
	"cutting": 0.4,
	"distortion": 0.2,
	"persistence": 0.3,
	"annotation": 0.5,
	"text_rate": 0.3,
}
const AXES := ["density", "motion", "cutting", "distortion", "persistence", "annotation", "text_rate"]
const CHARACTERS := ["glitch", "chromatic", "edge", "kaleido"]
const STRUCTURAL := ["density"]
## Cut cadence options in beats, slow to fast.
const CUT_BEATS := [32, 16, 8, 4, 2, 1]

var values := DEFAULTS.duplicate()
var character := "glitch"


static func from_dict(d: Dictionary) -> MacroControls:
	var m := MacroControls.new()
	for k in d:
		if k == "character":
			m.set_character(str(d[k]))
		else:
			m.set_axis(k, float(d[k]))
	return m


func set_axis(axis: String, v: float) -> Error:
	if axis not in AXES:
		push_error("unknown macro axis " + axis)
		return ERR_INVALID_PARAMETER
	values[axis] = clampf(v, 0.0, 1.0)
	return OK


func set_character(c: String) -> Error:
	if c not in CHARACTERS:
		push_error("unknown distortion character " + c)
		return ERR_INVALID_PARAMETER
	character = c
	return OK


func get_axis(axis: String) -> float:
	return float(values.get(axis, 0.0))


func copy() -> MacroControls:
	return from_dict(to_dict())


func to_dict() -> Dictionary:
	var d := values.duplicate()
	d["character"] = character
	return d


## Concrete parameters for one axis. Families override density_params() and
## may extend the others, but every key must start with the axis prefix
## returned by prefix_of(), which keeps the axes disjoint by construction.
static func base_params(axis: String, v: float, char_kind: String) -> Dictionary:
	match axis:
		"motion":
			return {
				"motion.wobble": lerpf(0.0, 0.035, v),
				"motion.freq": lerpf(0.03, 0.25, v),
				"motion.pulse": lerpf(0.0, 0.06, v),
				"motion.rotation": lerpf(0.0, 25.0, v * v),
			}
		"cutting":
			var i := clampi(int(round(v * (CUT_BEATS.size() - 1))), 0, CUT_BEATS.size() - 1)
			return {"cutting.beats": CUT_BEATS[i], "cutting.share": lerpf(0.15, 0.75, v)}
		"distortion":
			return {"distortion.effects": distortion_effects(v, char_kind), "distortion.amount": v}
		"persistence":
			return {
				"persistence.feedback": v > 0.05,
				"persistence.decay": lerpf(0.5, 0.93, v),
				"persistence.beat_cut": lerpf(0.6, 0.05, v),
				"persistence.repeat_window": int(round(lerpf(12.0, 1.0, v))),
				"persistence.recur": lerpf(0.0, 0.5, v),
			}
		"annotation":
			return {
				"annotation.faces": v > 0.1,
				"annotation.prob": v,
				"annotation.labels": v > 0.4,
				"annotation.trails": v > 0.75,
				"annotation.redact": lerpf(0.0, 0.8, v),
			}
		"text_rate":
			return {"text_rate.prob": lerpf(0.0, 0.9, v), "text_rate.max": int(round(lerpf(1.0, 5.0, v)))}
	return {}


static func prefix_of(key: String) -> String:
	return key.get_slice(".", 0)


## Effect chain for the distortion axis. Effects are always present (amount 0
## means visually neutral) so live amount changes need no rebuild; only the
## character is structural.
static func distortion_effects(a: float, c: String) -> Array:
	match c:
		"chromatic":
			return [
				{
					"type": "chromatic",
					"params": {"strength": 0.025 * a, "barrel": 0.4 * a},
					"bindings": [{"param": "strength", "signal": "uBassEnergy", "amount": 0.02 * a}],
				}
			]
		"edge":
			return [{"type": "edge_detect", "params": {"mix_amount": a, "gain": 1.0 + 2.0 * a}}]
		"kaleido":
			return [
				{"type": "kaleidoscope", "params": {"segments": 2.0 + round(6.0 * a), "rotation": 0.1 + 0.3 * a}},
				{"type": "glitch", "params": {"amount": 0.03 * a}},
			]
	return [
		{
			"type": "glitch",
			"params": {"amount": 0.06 * a},
			"bindings": [{"param": "amount", "signal": "uOnsetEnvelope", "amount": 0.12 * a}],
		}
	]
