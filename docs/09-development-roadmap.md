# Development roadmap

[Documentation index](../README.md#documentation)

## Milestone 1: prove the rendering substrate

Build a Godot technical prototype with a replaceable video backend:

- Multiple simultaneous representative videos.
- Image/PDF-page and text overlays.
- Local and global effects.
- Explicit temporal feedback.
- Composition transitions.
- Projector and operator views.
- Output capture.

**Acceptance:** sustain the agreed workload at the target output resolution/frame rate; measure memory, decoder load, upload cost, switch/seek latency, late frames, and long-session behavior. Validate backend maintenance and deployment before migration.

If retaining the existing renderer during this phase, address registry mismatch, pass ownership, feedback binding, capture, and execution observability before using it as a learning environment.

## Milestone 2: build the musical runtime

- Common live/file PCM input.
- Mixxx main-output routing on the actual Linux setup.
- Separate fast DSP and slow analysis.
- Timestamped musical state with confidence and freshness.
- Beat-aware scheduler and continuous modulation.
- Explicit bar alignment strategy.
- Optional Mixxx telemetry adapter.

**Acceptance:** recorded and live inputs drive the same feature interface; scheduled events and projected visuals have measured timing behavior; loss of metadata has a defined fallback.

## Milestone 3: build the visual vocabulary

- Versioned asset manifest and preprocessing cache.
- Videos, images, PDF pages, and text sources.
- Precomputed face tracks and annotation layers.
- Curated collections.
- Three initial composition families, then expand as useful.
- Independent density, motion, cutting, distortion, and persistence controls.

**Acceptance:** an operator can create convincing sequences using manual semantic controls without writing shaders during a performance.

## Milestone 4: establish the control contract

- Semantic action adapter and command schema.
- Capability discovery and bounded controls.
- Transactional preparation/application.
- Command IDs, revisions, execution results, and snapshots.
- Shared interface for manual, scripted, and agent control.

**Acceptance:** requested actions can be traced to actual execution, failed/delayed operations are explicit, and reconnects do not duplicate events.

## Milestone 5: recording and replay

- Externally controllable replay clock.
- Audio/sample-time mapping.
- Action and execution logs.
- Resolved asset IDs, playheads, versions, and seeds.
- Reproducible clip export.
- Reset behavior for temporal effects.

**Acceptance:** the same session can be replayed within defined audiovisual tolerances, and candidate clips can be regenerated from their manifests. Validate whether offscreen or accelerated replay meets training needs.

## Milestone 6: scripted baseline and annotation

- Strong beat-aware scripted controller.
- A/B audiovisual export and review queue.
- Preference/acceptability labels.
- Longer-sequence timeline review.
- Complete held-out sets and comparison pairs.

**Acceptance:** feedback identifies actionable differences in musical fit and style; all judgments resolve to reproducible candidates.

## Milestone 7: imitation baseline

- Record manual decisions over existing sets.
- Train a scene-level policy.
- Include current composition and temporal music context.
- Evaluate blind against the scripted baseline.

**Acceptance:** the policy produces useful sequences on unseen sets and handles missing timing metadata. A few sets support prototyping; expand diversity when evaluation shows overfitting.

## Milestone 8: RL and preference refinement

- Use the actual renderer as the environment.
- Implement validated scene-level PPO or an equivalently justified baseline.
- Correct masking, action probabilities, critic bootstrapping, duration handling, and termination semantics.
- Introduce preference-based sequence scoring when sufficient useful labels exist.
- Compare against scripted and imitation controllers.

**Acceptance:** held-out human judgments improve without unacceptable pacing, repetition, timing, or performance regressions. Training reward alone is not the success criterion.

If reusing the present PPO code, fix its documented correctness issues before running comparative experiments.

## Later extensions

- Bounded layer-level policy actions.
- Richer music and visual temporal embeddings.
- Camera sources and online face tracking.
- Larger composition vocabulary.
- Crowd observations and explicit delayed objectives, supported by appropriate data.

## Immediate vertical slice

The smallest useful end-to-end target is:

> One recorded set or live Mixxx input → shared musical state → three composition families → beat-scheduled events → videos, PDF pages, text, and precomputed face boxes → recorded output and replayable commands.

This creates a usable instrument and the infrastructure required for learning, annotation, and future expansion.
