# Media library and visual language

[Documentation index](../README.md#documentation)

## Asset ingestion

Build a versioned manifest of local assets rather than making the policy navigate arbitrary filenames.

| Asset | Preprocessing |
| --- | --- |
| Video | Probe codecs/duration/dimensions; thumbnails; shot boundaries; motion/color summaries; optional transcodes |
| Image | Dimensions, thumbnails, palette, content/style tags |
| PDF | Rasterized pages, thumbnails, optional text and layout regions |
| Text | Entries or fragments with font/layout presets and language metadata |
| Faces | Detections in images and timestamped tracks in video |

Use stable asset IDs, content/version identifiers, cached-analysis versions, and links back to source files. Store useful crop regions and playback constraints where appropriate.

Heavy analysis and document rasterization happen before a performance. Load/decode preparation should happen ahead of scheduled events.

## Face annotations

Face detection and tracking are enough to draw rectangles. Identity recognition is unnecessary for this visual feature.

Store bounding boxes in source coordinates with timestamps and stable track IDs. Apply the same crop and transform as the associated video layer. Decide whether annotations should be composited before or after distortion.

Possible graphics include boxes, track numbers, confidence-like stylistic labels, paths, and occasional enlarged face crops. Distinguish genuine detector metadata from deliberately fictional visual labels in the implementation.

## Collections

Example categories:

```text
tv_news
advertising
cctv
talking_heads
crowds
domestic_footage
landscapes
technical_diagrams
bureaucratic_documents
redacted_pages
abstract_material
```

The policy selects categories and composition rules; an asset selector resolves them with controlled randomness, repetition limits, and recorded seeds. This scales better than one action per file.

## Composition families

| Family | Treatment | Possible role |
| --- | --- | --- |
| Channel surfing | Disparate broadcasts, tuning transitions, channel labels | Percussive or changing passages |
| Surveillance wall | Multiple feeds, face boxes, timestamps, occasional enlargement | Repetition and sustained tension |
| Document storm | Scans, redactions, highlighted fragments, photocopy artifacts | Accumulation and density |
| Signal collapse | Frame holds, strip displacement, subtitle corruption, feedback | Brief accents and transitions |
| Uncanny presenter | A held talking head with intrusive annotations | Contrast and unease |
| Dead air | A sparse feed, isolated page, minimal annotation | Release and breakdowns |

These musical roles are starting hypotheses, not rigid genre rules.

## Macro controls

Expose distinct dimensions:

- Layer density and occupied area.
- Source-change cadence.
- Motion speed and magnitude.
- Distortion amount and character.
- Document/text event rate.
- Annotation density.
- Persistence and motif recurrence.
- Palette/contrast profile.

Do not collapse them into one universal intensity knob. Useful mappings may be non-monotonic or scene-specific.

## Structured disorder

- Keep one anchor while peripheral layers change.
- Reintroduce a face, phrase, page, or station identity later.
- Use different cadences across layers.
- Let material persist and accumulate instead of respawning everything on every kick.
- Alternate dense passages with intentional emptiness.
- Use brief strong corruption rather than continuous maximum corruption.
- Treat legibility as an artistic control: sometimes text is read, sometimes it is texture.

Randomness should operate inside these constraints. Maximizing random cuts or pixel entropy does not establish a convincing style.

## Future source types

Keep camera capture behind the common source interface. Live face detection can later publish the same annotation metadata format used by precomputed local tracks.
