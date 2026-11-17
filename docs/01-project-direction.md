# Project direction

[Documentation index](../README.md#documentation)

## Goal

Build an AI-controlled VJ instrument that produces intentional, varied visual compositions in response to live DJ music. The first live target is Mixxx on Linux. Recorded DJ sets provide development, replay, and training inputs.

Visual assets initially come from a local library:

- Video clips.
- Images.
- PDF documents and individual document pages.
- Text rendered as overlays, captions, tickers, or document-like graphics.

The output should support multiple simultaneous videos, independent overlay layers, per-layer effects, group effects, global effects, and transitions between compositions.

## Core principle

**The agent chooses artistic direction; the engine executes it musically.**

| Component | Responsibility |
| --- | --- |
| Audio analysis | What is happening in the audible music? |
| Musical clock | Where are the beats, and how reliable is that estimate? |
| Agent | Which visual direction, source categories, layout, and pacing should be used? |
| Scheduler | When should structural events happen? |
| Compositor and shaders | How should layers and pixel-level animation be rendered? |

The agent should not need to predict a kick precisely enough to issue a shader uniform update at that instant. It can select a bass-driven distortion mapping, while the runtime continuously evaluates that mapping.

Source cuts, text spawning, and document events belong in a beat-aware CPU-side scheduler. Pixel displacement, exposure modulation, and feedback decay can consume musical signals inside shaders.

## Artistic brief

Use **fragmented broadcast / surveillance collage / information overload** as a concrete working description of the desired aesthetic.

Disparate sources should produce structured disorder rather than arbitrary noise:

- Recurring faces, phrases, documents, and channel identities.
- A stable visual anchor surrounded by changing material.
- Contrasting rhythms across layers.
- Alternation between accumulation and release.
- Occasional strong interruptions instead of permanent maximum distortion.
- Variation in density, motion, cutting, and distortion independently.

High musical energy does not require every visual parameter to increase. A single enlarged face held for several bars can be more intense than a dense, rapidly cut grid.

See [media library and style](06-media-library-and-style.md).

## Initial control model

Start with one slower artistic policy controlling curated composition families and bounded macro parameters. Use the same command interface for manual control, scripted baselines, and the learned controller.

The policy initially selects:

- Composition family and layout.
- Source collections.
- Overlay density.
- Distortion and motion profiles.
- Cut cadence and event rules.
- Transition type.
- Whether to hold the current direction.

Introduce bounded layer editing only after this baseline produces convincing output.

## Future crowd influence

Preserve an optional context/objective interface, but do not use synthetic crowd values as evidence of audience response.

A future crowd-influence system would require real measurements, action-dependent responses, delay handling, and an explicit target such as a desired engagement trajectory. Matching current crowd energy and influencing future crowd response are different objectives.

## Deferred cameras

Define a common visual-source interface so cameras can later provide timestamped frames through the same compositor. Local assets remain the initial implementation target.

## Open decisions

- Installed Mixxx version and Linux audio backend.
- Target output resolution, frame rate, and hardware budget.
- Number and resolution of simultaneous videos.
- Suitable Godot video backend and its maintenance status.
- Whether accurate bar alignment will come from an estimator, a manual alignment control, or both.
- How much manual demonstration and preference annotation is practical.
