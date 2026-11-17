# Agent–engine protocol

[Documentation index](../README.md#documentation)

**Status: illustrative protocol proposal.** Names and schemas below are not current engine APIs.

## Abstraction boundary

The policy selects semantic artistic actions. An action adapter converts model outputs into engine commands. The engine resolves assets, creates layers, prepares effects, and executes musical scheduling.

Initial actions:

- Select composition family and source collections.
- Select a bounded layout.
- Set document/text/panel density.
- Set distortion and motion profiles.
- Select cut cadence and transition type.
- Hold the current direction.

Later actions may add or remove a layer in a bounded slot, replace one source, or change one effect profile. Arbitrary node creation and shader-code generation are outside the initial action space.

## Transport

A local WebSocket connection is sufficient for an initial command/state channel. Send preview images through a separate path so they cannot delay commands. Timestamp musical-state messages and interpolate in the runtime; do not make high-frequency animation depend on request/response round trips.

Negotiate protocol version and runtime capabilities on connection, including supported templates, controls, media types, and resource limits.

## Composition command

```json
{
  "protocol_version": 1,
  "type": "apply_composition",
  "command_id": "cmd-1042",
  "base_revision": 81,
  "seed": 32017,
  "execute": {
    "quantize": "next_bar"
  },
  "composition": {
    "template": "surveillance_collage",
    "sources": {
      "background": {"collection": "tv_news"},
      "panels": {"collection": "cctv", "count": 3}
    },
    "controls": {
      "document_density": 0.35,
      "distortion": 0.6,
      "text_density": 0.2
    },
    "behaviors": {
      "source_cut_every_beats": 8,
      "document_spawn_probability_per_beat": 0.15,
      "face_boxes": true
    }
  },
  "transition": {
    "type": "crossfade",
    "duration_beats": 4
  }
}
```

`next_bar` requires valid bar alignment. Define an explicit rejection or fallback policy when it is unavailable. A beat counter alone does not establish a musical downbeat.

Collection selection is resolved into concrete asset IDs, source instances, and playhead choices. Log the resolution so replay does not depend on later library changes.

## Modulation command

```json
{
  "protocol_version": 1,
  "type": "set_modulation",
  "command_id": "cmd-1043",
  "base_revision": 82,
  "target": "global.distortion.amount",
  "signal": "audio.bass_envelope",
  "mapping": {
    "base": 0.1,
    "depth": 0.5,
    "attack_ms": 15,
    "release_ms": 180
  }
}
```

Targets and signals come from declared capabilities. The runtime continuously evaluates this mapping and clamps to the declared parameter range. The policy does not send one update per kick.

## Transaction lifecycle

1. Validate command identity, schema, revision, capabilities, and parameter ranges.
2. Resolve and prepare assets within resource limits.
3. Assign a musical execution point.
4. Apply the composition atomically at the logical state level.
5. Report actual execution and the resulting revision.

Possible states include `accepted`, `preparing`, `scheduled`, `applied`, and `rejected`. Cancellation/rescheduling must also be explicit if supported.

For a missed preparation deadline, choose and document a policy: retain the current composition and reschedule, or reject. Do not silently pretend the requested beat was met.

Use command IDs for idempotency so a reconnect/retry cannot duplicate an event. Reject stale revisions or require the sender to reconcile against a state snapshot. Specify the idempotency retention period for long sessions.

## Execution feedback

```json
{
  "protocol_version": 1,
  "type": "command_result",
  "command_id": "cmd-1042",
  "status": "applied",
  "revision": 82,
  "actual_time_sec": 753.412,
  "actual_beat_index": 1472,
  "resolved_assets": ["video:news_017", "video:cctv_004"],
  "seed": 32017
}
```

This abbreviated example omits the full source/layer mapping. The real execution record should preserve it, including source start positions and scheduling deviations.

State snapshots should expose current composition, layer/source states, modulation bindings, pending events, timing confidence, and relevant performance statistics.

**Training should associate outcomes with executed actions, not merely requested commands.** Delayed actions require correct execution-time attribution or explicit exclusion from affected training transitions.

## Manual and automated control

Manual controls, scripted baselines, and agents use the same semantic API. Define an explicit active-controller policy so competing writers cannot silently modify the composition. Manual interventions should be logged as such and handled consistently in learning data.

## Replay record

Persist audio identity and sample/time mapping, accepted commands, execution results, asset versions, seeds, clock alignment, configuration, policy version, and renderer version. Previews and exported clips reference this record.
