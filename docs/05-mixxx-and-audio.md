# Mixxx and audio integration

[Documentation index](../README.md#documentation)

## Input strategy

Make the audible stereo mix the primary input. Mixxx telemetry is an optional timing and context enhancement.

```text
Live Mixxx main audio ----+
                         +-> common PCM interface -> causal analysis
Recorded DJ-set file -----+                              |
                                                        +-> musical state
Optional Mixxx telemetry -> timing/context adapter ------+
```

This allows existing recorded sets to drive development and training without requiring original deck metadata.

## Linux audio capture

- With PipeWire, route or monitor the appropriate Mixxx output into the analyser.
- With JACK, connect the appropriate Mixxx output ports to the analyser.

Capture the main mix rather than headphone cueing or unrelated desktop audio. Exact routing depends on the installed backend, Mixxx package, and audio interface.

The analyser should not interrupt Mixxx playback. Use bounded buffering and publish feature age/overrun metrics. Timestamp blocks against a shared monotonic reference, preserve sample counts, and account for resampling and route latency.

## Analysis rates

Separate fast signal processing from slower inference:

| Rate | Examples | Consumer |
| --- | --- | --- |
| Fast | Band energies, envelopes, onsets | Modulation and scheduling |
| Medium | Tempo, beat tracking, rhythmic activity | Musical clock and policy |
| Slow | Energy trends, section-change evidence, music embeddings | Artistic policy |

Initial useful features include bass/mid/high activity, transient density, short/long energy, spectral changes, and uncertainty. Use rolling normalization appropriate to live operation rather than statistics requiring the whole set.

The current speech-emotion model is not a strong default for musical mood. Introduce learned music representations only when they improve held-out behavior.

## Mixxx telemetry

Mixxx's control system documents per-deck values such as `bpm`, `beat_distance`, `beat_active`, playback state, channel volume, and crossfader position. Controller scripting can inspect these values. Export to an external process needs a version-appropriate adapter; it is not assumed to be a built-in external Python API.

References:

- [Mixxx 2.5 Controls](https://manual.mixxx.org/2.5/en/chapters/appendix/mixxx_controls)
- [Mixxx advanced topics and scripting](https://manual.mixxx.org/2.5/en/chapters/advanced_topics)

Verify behavior against the installed Mixxx version. Do not assume a generic OSC/WebSocket telemetry service exists without checking it.

## Timing reference

During a transition, a playing deck is not necessarily audible or dominant. Choose or smoothly follow a suitable timing reference using available context; crossfader position alone is insufficient because channel faders, routing, and effects also matter.

Publish:

- Timestamp and tempo.
- Beat phase and confidence.
- Timing source and freshness.
- Bar/downbeat alignment when available, with separate confidence.
- Transport discontinuities such as seeks and jumps.

Interpolate phase between telemetry updates. Use audio tracking when metadata is missing or unreliable. Avoid abrupt phase jumps on reference changes.

Beat phase does not establish downbeat or phrase position. Provide a bar estimator and/or an operator alignment control before promising `next_bar` execution.

Measure audiovisual latency end to end. Metadata callback time, audible output time, and projected frame time can differ.

## Existing recordings versus new sessions

| Material | Provides | Does not provide by itself |
| --- | --- | --- |
| Existing set audio | Musical transitions, effects, tempo and energy development | Original deck controls and stems |
| New Mixxx audio recording | Representative audio from the target setup | Detailed control history |
| New recording with telemetry | Audio plus timestamped deck/mixer context | Visual-quality labels |

Existing DJ sets are sufficient for the first useful baseline. New performances are not required. Later, record a few Mixxx sessions with telemetry to validate the live integration.

Audio recordings do not reliably recover the original crossfader positions, deck playheads, or control history. Training should not assume those values are present.

## Train/live parity

Use the same analysis code on file and live inputs. Cached features must preserve when each value becomes available causally. Future-looking emotion windows, full-set normalization, or offline section detection must not become hidden training-only observations.

Offline beat labels can be useful references for evaluating a causal tracker. Keep those labels separate from policy observations.

Initially, let the policy rely on audio-derived features while the scheduler optionally benefits from Mixxx timing. If telemetry later enters the policy, include availability indicators and train with missing telemetry.

## Recording format

Record main audio, telemetry, monotonic timestamp/sample mapping, route configuration, feature versions, and discontinuities. Playback should support both real-time audition and externally clocked training through the same musical-state interface.
