# Visualization architecture

[Documentation index](../README.md#documentation)

**Status: proposed architecture.** Godot is a candidate composition engine, not an implemented migration.

## Godot decision

Godot provides useful building blocks for 2D composition, text, masks, annotation graphics, shaders, transitions, offscreen textures, and an operator interface. These match the intended visual language well.

The main technical uncertainty is video. Core Godot 4 video support primarily targets Ogg Theora; broad codec support generally requires an extension or custom integration. Verify the exact Godot version and any candidate FFmpeg-backed extension before choosing a backend.

Use Godot for composition while keeping decoding behind a replaceable interface. Validate simultaneous playback, seeking, looping, preloading, frame upload cost, and sustained resource use with representative assets.

## System boundaries

```text
Mixxx / recorded audio
        |
Audio analysis + optional Mixxx telemetry
        |
Timestamped musical state
        |                         |
Python artistic policy       Godot runtime
        |                         |
Semantic action adapter --------> Command gateway
                                  |
                         Composition controller
                                  |
                       Scheduler + modulation engine
                                  |
                     Sources -> layers -> groups
                                  |
                            Compositing
                                  |
                       Global post-processing
                                  |
                       Projector / recording
                                  |
                 State, execution events, previews
```

Policy inference must not block drawing, musical envelopes, or scheduled events. Expensive asset work belongs in preprocessing or background preparation.

## Sources

A `VisualSource` supplies timestamped frames or drawable content:

- Video source.
- Static image.
- Rasterized PDF page.
- Text source.
- Procedural graphic.
- Later, camera source.

Expose preparation state, dimensions, duration where applicable, playback position, seek/loop capabilities, and frame availability. Source instances distinguish shared playheads from independent playback of the same file.

Face tracks and document regions are metadata associated with a source; annotation layers consume them.

## Layers and groups

```text
Layer
 ├─ Stable layer ID
 ├─ Source instance
 ├─ Transform: position, scale, rotation
 ├─ Crop and mask
 ├─ Opacity and blend mode
 ├─ Local effect chain
 └─ Animation and musical modulation bindings
```

Groups combine layers under shared transforms, masks, and effects. Layer order and effect order are explicit and serializable.

Example composition:

```text
Composition
 ├─ Background: news video
 ├─ Panel group: three independent CCTV clips
 ├─ Document group
 │   ├─ Scanned page
 │   ├─ Highlight rectangles
 │   └─ Redaction bars
 ├─ Face boxes and labels
 ├─ Text ticker
 └─ Global effect chain
```

## Local, group, and global effects

```text
News video -> color treatment -> crop -----+
CCTV panels -> local distortion ----------+
Document group -> mask -------------------+-> composition
Text and annotations ---------------------+       |
                                             feedback
                                                 |
                                         output distortion
                                                 |
                                               output
```

Annotations before distortion inherit the distortion; annotations afterward remain clean. Both are useful deliberate choices.

The initial render graph should be bounded and acyclic, except for explicit temporal-history resources. Arbitrary graph generation is not an initial policy action.

## Suggested Godot runtime structure

```text
PerformanceRoot
 ├─ MusicalClock
 ├─ CommandGateway
 ├─ EventScheduler
 ├─ ModulationEngine
 ├─ AssetManager
 ├─ CompositionController
 ├─ CompositionA
 ├─ CompositionB
 ├─ TransitionCompositor
 ├─ GlobalEffectChain
 ├─ Recorder
 └─ OutputWindow
```

Two prepared composition slots support transitions. Their combined resource cost must fit the performance budget.

Use ordinary 2D drawing for simple layers. Allocate `SubViewport` render targets when a group needs intermediate processing, an effect needs a separate pass, compositions must be blended, or temporal history is required.

Do not allocate a full-resolution viewport for every overlay by default. Combine compatible effects where useful, use lower-resolution targets for suitable effects, and measure GPU bandwidth and memory.

Feedback needs separate previous/current textures or ping-pong targets. Do not sample a render target while writing to it.

## Musical execution

The runtime receives timestamped audio features and timing state. It evaluates modulation bindings and exposes useful shader inputs:

```text
uBeatPhase
uBeatEnvelope
uBassEnergy
uMidEnergy
uHighEnergy
uOnsetEnvelope
uEnergyTrend    # short minus long energy
uBeatConfidence
uBarPhase       # only when bar alignment is available
```

Use a documented phase convention. Include confidence and availability in runtime timing state rather than treating uncertain bar alignment as established fact.

Shaders animate pixels. The scheduler handles source cuts, document spawning, text events, and composition transitions.

## Clock and replay

Support both a live monotonic clock and an externally advanced replay clock. Derive animations, event schedules, playheads, and effect history from that clock rather than untracked wall time.

Record random seeds, resolved assets, action application times, and renderer versions. Seek/reset must also reset temporal effects. Exact bitwise determinism across GPU drivers is not assumed; define an acceptable replay tolerance.

## Output and monitoring

Provide a dedicated projector window and an operator view. Produce timestamped preview frames and recordings without blocking the control path. Validate output capture and accelerated/offscreen playback early, since training and annotation depend on them.

## Technical feasibility gate

Test a representative workload, such as four simultaneous videos plus document/text overlays, local effects, global feedback, and a transition. The final target count is a product decision, not a claimed capacity.

Measure sustained frame rate, late frames, switch/seek latency, decoder CPU use, upload cost, GPU memory, and long-session stability at the intended resolution.
