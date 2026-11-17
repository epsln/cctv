# Current implementation assessment

[Documentation index](../README.md#documentation)

This assessment describes the source reviewed in this repository. It is a source-level assessment, not a live performance benchmark or evidence of training quality.

## Existing strategy

| Component | Implementation |
| --- | --- |
| Renderer | C++/OpenGL with video source and sequential shader passes |
| Music observations | Mel spectrum, energy, spectral features, onset strength, beat phase, estimated emotion |
| Low-level policy | Discrete-action PPO at approximately 0.5-second intervals |
| High-level policy | Separate PPO selecting seven goals at approximately 10-second intervals |
| Network | Audio and engine-state MLP encoders with actor and critic heads |
| Visual scoring | CLIP prompt-based arousal/valence and grayscale histogram entropy |
| Crowd values | Time-dependent simulated signals |
| Pretraining | Older NumPy actor–critic simulator harness |

PPO is a reasonable small-action-space baseline. The current limitations are primarily observation design, action semantics, reward grounding, integration, and training correctness.

## Critical learning issues

### Incorrect critic bootstrap

[`ActorCritic.act()`](../rl_agent/networks.py) returns `(action, log_prob, value, entropy)`. `PPOTrainer.update()` unpacks the second element into `last_value`, so GAE bootstraps from an action log-probability instead of the critic value.

### Actions and stored probabilities disagree

[`high_level_agent.py`](../rl_agent/high_level_agent.py) overrides sampled actions based on audio. [`low_level_agent.py`](../rl_agent/low_level_agent.py) can replace sampled actions with `NOOP`. Both retain the original action's log-probability when storing the modified action.

PPO requires old action probabilities to correspond to the actual behavior policy. Mask constraints before sampling and use the same distribution during training. Overrides need explicit behavior-policy handling or exclusion from ordinary PPO updates.

### Disconnected hierarchy

The runner calls `low.set_goal()`, but the low-level agent only stores the dictionary. It does not use the goal in observations, rewards, or command generation. Target intensity, preferred shaders, and transition goals therefore have no effect.

The high-level agent is rewarded for visual outcomes it cannot influence through the intended hierarchy.

### Goal-change penalty does not activate normally

The high-level reward compares `_prev_action` and `_current_action`, which are assigned the same action at the end of each step. The normal runner flow therefore does not detect the intended goal changes.

### Trainer settings and diagnostics

`gamma` and `gae_lam` are stored by `PPOTrainer`, but buffer return computation uses its own defaults. The low-level return statistic is computed after the update has reset the buffer, so it does not report the collected rollout's mean reward.

## Observations do not describe the controlled result

[`features.py`](../rl_agent/features.py) encodes engine metadata, including pass bits, source progress, and simulated crowd values. It does not provide the policy with:

- Rendered image features.
- Visual emotion values used in the reward.
- Shader uniform values or internal intensity.
- Source identity or content representation.
- High-level goals.
- Sufficient temporal history for longer visual development.

Visually different situations can therefore share the same observation. The high-level eight-state history covers roughly 0.8 seconds at the default state publication rate, not eight high-level decisions.

## Reward limitations

### Emotion alignment is not calibrated audiovisual quality

The audEERING model in [`audio_pipeline.py`](../rl_agent/audio_pipeline.py) is a speech-emotion model trained on MSP-Podcast. Its performance on DJ music is unestablished. The implementation adds a sigmoid to regression outputs that the reference implementation returns directly, shifting and compressing their values.

The [model reference](https://huggingface.co/audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim) documents the intended inference behavior.

CLIP similarity to emotional text anchors in [`visual_emotion.py`](../rl_agent/visual_emotion.py) is a stylistic heuristic, not a calibrated measure of audience response. Single frames cannot measure rapid movement, pulsing, or slow drift. Sharing arousal/valence labels does not establish a common calibrated coordinate system across the two models.

### Entropy is not visual energy

Histogram entropy can be high for static noise and low for a powerful synchronized visual. It is an auxiliary descriptor, not a sufficient artistic objective.

### Crowd matching is a placeholder

[`main.cpp`](../src/main.cpp) generates crowd values from elapsed time. [`rewards.py`](../rl_agent/rewards.py) rewards matching active-pass count to crowd energy. Neither measures nor rewards action-dependent crowd response. Crowd influence is outside the present implementation and current milestone.

## Timing limitations

- Structural actions use fixed wall-clock intervals rather than a musical scheduler.
- Onset tracking is updated during low-level reward processing instead of every audio tick.
- Beat phase uses position modulo global beat duration, ignoring detected beat timestamps.
- Audio progresses from a wall-clock start without synchronizing to actual audible playback.
- Slow emotion inference shares the fast audio feature thread.
- Visual emotion updates are cached for longer than the action interval, weakening attribution.
- Full-file preprocessing and forward-looking audio windows are not equivalent to causal live analysis.

## Renderer and action integration gaps

- The Python registry includes `edge_detect`; C++ does not register it.
- C++ attempts to load an absent `color_grade.frag`.
- Glitch and bloom are registered in C++ but absent from the Python registry.
- Default pass IDs such as `chroma` differ from agent-generated IDs such as `rl_chromatic`, so some removals are ineffective.
- The intensity heuristic finds no eligible chromatic parameter under its range rule.
- The feedback shader expects a previous-frame texture that the renderer does not bind.
- [`frame_export.h`](../src/frame_export.h) is not connected to the main loop, so file-based capture is not produced by that path.
- The JSON file bridge lacks command IDs and execution acknowledgments; requested actions cannot reliably be distinguished from applied actions.

Silent no-ops and inconsistent action meanings undermine learning, independently of policy choice.

## Pretraining harness mismatch

[`train_offline.py`](../rl_agent/train_offline.py) has obsolete imports including `KNOWN_SHADERS`, `NOOP`, `_is_structural`, and high-level `N_ACTIONS`.

It also trains a different NumPy policy/checkpoint format, lacks audio and rendered visual rewards, does not model uniform effects, and samples high-level actions without applying them through a low-level controller. Its crowd trajectory is action-independent. The simulator ends sources while the live decoder loops them, introducing an additional mismatch.

Repairing imports alone would not make it a valid pretraining environment for the proposed agent.

## Retain and change

Retain the idea of separate musical timescales, a compact policy, a shader registry, and structured metrics. Prioritize a reliable rendering instrument, meaningful scene actions, causal observations, and reproducible execution before interpreting learning curves.

The proposed replacement is described in [visualization architecture](03-visualization-architecture.md) and [learning strategy](07-learning-strategy.md).
