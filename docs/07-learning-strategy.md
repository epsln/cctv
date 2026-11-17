# Learning strategy and objectives

[Documentation index](../README.md#documentation)

## Recommended progression

1. Build curated, manually playable compositions.
2. Establish a beat-aware scripted baseline.
3. Record demonstrations through the semantic command API.
4. Train an imitation policy.
5. Fine-tune scene sequencing with rendered-environment RL.
6. Refine taste through preference feedback.

A strong instrument and meaningful actions are more important initially than a more complex optimizer.

## Recorded-set training

Existing prerecorded DJ sets provide realistic musical situations. They do not provide labels for good visual responses. A few varied sets can support a prototype baseline; they do not guarantee generalization.

```text
Recorded audio -> causal musical state -> policy
                                           |
                                semantic composition action
                                           |
                                  actual visual renderer
                                           |
                                  audiovisual sequence
                                           |
                           quality metrics / preferences
```

Training against a renderer while replaying recorded music is interactive RL outside a live performance. Strictly, offline RL means learning from a fixed action/outcome dataset without new environment interaction. Keep these meanings distinct.

Use the actual compositor or a validated equivalent, not a state-only simulator that cannot evaluate visual motion, layering, or editing.

## Training efficiency

- Cache causal audio features and asset analysis.
- Use reduced render resolution where quality signals remain meaningful.
- Advance an explicit clock rather than waiting for wall time, if the media backend supports it.
- Render enough intermediate state for feedback, animation, and video playback to evolve correctly.
- Use multiple independent environments only after resource behavior is understood.
- Mix longer sequences with shorter excerpts so pacing can be learned.

Faster-than-real-time rendering is a capability to validate, not an assumed property of Godot or the decoder.

## Demonstrations

Use manual scene controls while listening to existing sets. Record observations, requested actions, actual execution, and resulting compositions. You do not need to make new DJ sets to demonstrate visual decisions.

Behavior cloning provides an initial policy consistent with the available artistic vocabulary. Demonstrations can also reveal missing controls before RL begins.

## Initial policy

Use one scene-level policy over curated templates and bounded macro controls. Act on musical intervals, such as once per bar or every few bars, with hold actions available. Exact cadence is a design parameter to evaluate.

Observations should include:

- Recent causal music features and energy trends.
- Timing confidence and feature availability.
- Current composition, source categories, and actual parameter values.
- Time/beats since composition and source changes.
- Recent actions and outcomes.
- Temporal visual descriptors or clip embeddings when useful.
- Creative brief: style, desired intensity, novelty, legibility.
- Optional future context/objective fields with availability flags.

A recurrent or temporal encoder is appropriate if history improves sequencing. An MLP with an explicitly designed history is a simpler baseline. Do not call pipeline metadata a pixel-level visual observation.

## PPO baseline

PPO is reasonable for this bounded sequential problem once correctness is established:

- Mask invalid actions before sampling and when recomputing probabilities.
- Store the actual behavior-policy log-probability.
- Bootstrap from critic values.
- Handle episode ends and time-limit truncations correctly.
- Aggregate outcomes over the action interval.
- Account for action duration in discounting when durations vary.
- Attribute outcomes using applied-action timestamps.
- Log meaningful returns, entropy, policy divergence, value fit, and action distribution.

Start with discrete presets or discretized controls. A broad hybrid discrete/continuous action space can follow later.

If the problem is reduced to independent preset selection per excerpt, a contextual bandit may be enough. RL becomes useful when motif recurrence, accumulation, contrast, and scene persistence make choices affect later outcomes.

## Objectives

A conceptual sequence-level reward is:

```text
R = w_music * musical_relationship
  + w_style * style_quality
  + w_pacing * pacing_and_variety
  + w_visual * composition_quality
  - w_change * unnecessary_change
```

Weights and preferred relationships may depend on the creative brief. Validate components rather than assuming these labels produce measurable quality automatically.

### Musical relationship

Evaluate whether visual motion, contrast, or density develops meaningfully with the music; whether changes are appropriately placed; and whether sparse and dense passages receive differentiated treatment.

Do not require literal matching at every moment. Deliberate contrast can work. A scheduler guarantees event placement, so a large reward merely for cutting on a beat encourages excessive cuts rather than good decisions.

### Style

Curated composition families establish the initial aesthetic. Human preferences can later evaluate how convincingly broadcast graphics, documents, surveillance annotations, and corruption work together.

### Pacing and variety

Reward useful duration ranges, recurring motifs, controlled novelty, and accumulation/release. Evaluate over temporal windows and longer sequences. Raw entropy and random variation are poor substitutes.

### Composition and operational quality

Assess layer visibility when intended, useful text/document placement, active sources, and coherent effects. Guarantee resource limits and invalid-state avoidance in the runtime where possible rather than asking RL to discover them through penalties.

### Preference-based reward

Train on audiovisual clip comparisons using music history, temporal visual features, composition/action history, and creative brief. A pairwise model can learn to score preferred sequences higher. Tie and rejection labels need appropriate handling rather than forced binary preferences.

Use learned reward as an imperfect component. Do not equate its score with independent success.

## Evaluation

Compare scripted, imitation, and RL controllers on complete held-out sets. Avoid random adjacent-window splits that leak the same tracks and transitions between train and test. Where practical, separate DJs and track selections too.

Measure:

- Blind audiovisual preferences and live-use acceptability.
- Short-clip musical fit and longer-term pacing.
- Scene duration, recurrence, and repetitive-action statistics.
- Applied-event timing error.
- Rendering and decoder performance.
- Behavior when timing/telemetry is missing or uncertain.

Keep human evaluation separate from training feedback. Inspect reward exploitation, such as constant cutting, excessive noise, or repeated use of a single scoring-friendly scene.

## Future crowd objectives

The creative-brief/context interface leaves space for later audience observations and delayed objectives. Adding them will require data and a revised control objective; current audio-response training does not establish crowd influence.
