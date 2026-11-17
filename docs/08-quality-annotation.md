# Quality annotation workflow

[Documentation index](../README.md#documentation)

## Purpose

Teach aesthetic preference through concrete audiovisual examples. Short comparisons assess local quality; longer reviews assess pacing and fatigue.

You do not need to score an entire set or identify the exact action responsible for every judgment.

## Basic workflow

1. Select an excerpt from a recorded set.
2. Generate two interpretations with the same music, starting context, and creative brief.
3. Vary scene choices, parameters, or action sequences.
4. Render audiovisual candidates and save their execution records.
5. Review the pair and record a preference.
6. Use feedback to improve presets, candidate selection, or a learned reward.

Initial candidates can be curated variations. A trained agent is not required to start annotation.

## Review interface

```text
Set: session_03     Excerpt: 12:30-13:00
Brief: fragmented broadcast, medium density

             [ Play A ]       [ Play B ]

Which interpretation works better with this music?

[ A ] [ B ] [ Equally good ] [ Both bad ] [ Skip ]

Optional reason:
[ musical fit ] [ pacing ] [ composition ] [ style ] [ repetition ]

Optional note: __________________________
```

Include keyboard controls, replay, and switching between A and B at matching playback positions. Play one aligned audio stream when switching synchronously; do not accidentally sum two copies of the music.

Provide sequential full-size viewing as well as an optional side-by-side preview. Small previews can conceal text and composition details. Randomize presentation order and hide controller identity during comparisons.

## Labels

Pairwise preference is generally easier to judge consistently than a numerical score. Distinguish relative preference from absolute acceptability:

- A preferred.
- B preferred.
- Equally good.
- Both bad.
- Skip/cannot judge.

“Both bad” rejects the pair but does not state which is less bad. If both ranking and acceptance are needed, store them as separate fields. An optional “would use live” judgment can be captured for each candidate.

Reason tags are helpful diagnostics, not mandatory work for every comparison. Free-text notes should be optional.

## Two review timescales

| Review | Starting duration | Purpose |
| --- | --- | --- |
| Short comparison | 15–30 seconds | Musical fit, composition, effect choices |
| Sequence review | 2–5 minutes | Pacing, recurrence, buildup, fatigue |

Adjust duration to the music and decision cadence. Include enough lead-in context to understand a transition. Short clips alone can favor immediately striking but exhausting behavior.

Longer reviews can support timeline markers such as “too repetitive,” “good transition,” “too dense for too long,” or “should have held this scene.” Treat markers as approximate intervals: human reactions are delayed and dissatisfaction may accumulate.

## Minimal versus dedicated tooling

### First experiment

Export audiovisual files with stable candidate IDs. Use a normal player and a spreadsheet of pair IDs, choices, and notes. A few dozen comparisons can test the workflow and reveal useful questions; they are not a guaranteed sufficient reward-model dataset.

### Repeatable workflow

Build a small local web application with:

- Candidate queue and progress persistence.
- Aligned audio/video playback and A/B switching.
- Keyboard voting and optional reason tags.
- Long-sequence timeline comments.
- Automatic connection to candidate metadata.

The reviewer can be independent of Godot and consume exported files. The reproducible export pipeline matters as much as the voting screen.

## Annotation record

Illustrative metadata:

```json
{
  "annotation_id": "ann-0081",
  "pair_id": "pair-0042",
  "audio_id": "set-03",
  "start_sec": 750.0,
  "duration_sec": 30.0,
  "brief_id": "broadcast-medium-v1",
  "candidate_a": "candidate-0084",
  "candidate_b": "candidate-0085",
  "choice": "a",
  "reasons": ["pacing", "musical_fit"],
  "note": "The quieter opening makes the interruption more effective."
}
```

Each candidate references audio/version, excerpt context, renderer/configuration version, policy or generator version, asset IDs/versions, seed, requested actions, actual execution, and the rendered clip. Store presentation order, reviewer identity or local reviewer ID, and annotation time separately as needed.

## Choosing useful comparisons

- Same scene with different cut cadence.
- Sparse versus layered composition over identical music.
- Alternative transition strategies.
- Learned policy versus a strong scripted baseline.
- Later, pairs on which a preference model is uncertain.

Balance uncertainty-driven sampling with coverage of styles, musical sections, and longer sequences. Avoid a queue dominated by nearly identical candidates or obviously broken output.

## Using the feedback

First, improve presets and control ranges directly. Then train a sequence scorer from music, temporal visual information, action history, and creative brief.

A preference applies to the whole reviewed sequence, not automatically to its final action. Sequence-level RL can use it, but credit assignment remains a learning problem.

Keep held-out comparisons and unseen complete sets for evaluation. Repeat a small number of comparisons to understand reviewer consistency. A rising learned score is not enough: periodically perform blind comparisons against the baseline to detect reward exploitation.
