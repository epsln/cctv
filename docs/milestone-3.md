# Milestone 3: visual vocabulary

[Documentation index](../README.md#documentation)

Goal ([roadmap](09-development-roadmap.md#milestone-3-build-the-visual-vocabulary)):
an operator can create convincing sequences with manual semantic controls,
without writing shaders during a performance.

## Overview

```
raw media (dirs = tags) --cctv-ingest--> library/manifest.json (v2) + cache/
                                              |
collections.json --> AssetSelector (seeded, repetition window, logged)
                                              |
MacroControls --> CompositionFamily.resolve() --> generate() --> Composition
                       (disjoint params per axis)    on_beat(): add/remove items
                                              |
FamilyDirector: apply / reseed / hold / live vs structural changes / history
                                              |
OperatorView + FamilyPanel: families, sliders, collections, presets
```

## Media library (`analysis/src/cctv_library`)

`cctv-ingest SRC OUT` (or `PYTHONPATH=analysis/src python3 -m cctv_library`;
the core needs only ffmpeg and poppler) scans `SRC`:

| Input | Assets | Steps |
| --- | --- | --- |
| video | `video` | `probe`, `proxy` (Theora at each of `--proxy-heights` ≤ source, default 540,1080), `thumb`, `faces` |
| image | `image` | `probe`, `copy`, `thumb`, `faces` |
| PDF | `pdf_page` per page | `raster` (`--dpi`, thumbnails) |
| `.txt` | `text` per line | `# style:` / `# lang:` headers; file stem becomes a tag |
| `.gen.json` | `procedural` | `{"generator", "params", "size"}` |

- **Tags** are the directory names, plus `SRC/tags.json` (`{"path or dir/": [tags]}`).
  Assets with face tracks get `has_faces`.
- **IDs** are stable slugs of the relative path (`cctv/lobby_cam_2`,
  `documents/minutes/p2`). The **content hash** (sha256) identifies the version.
- **Cache:** `OUT/cache/<hash16>/<step>@<version>/`. A step is recomputed
  only when the content or `STEP_VERSIONS[step]` changes, so re-running is cheap.
- **`library_version`** hashes IDs, content, text, analysis versions and tags.
  It is logged with every family application.
- **Faces:** `--faces MODEL.onnx` runs OpenCV YuNet (`tools/get_face_model.sh`,
  `uv sync --group faces`) on the CPU. It samples video every `--face-step` s
  (0.2), runs detection at 640 px wide, and links detections into tracks with
  greedy IoU matching (`tracking.py`). It stores boxes, a per-asset track number
  and a confidence: no landmarks, no embeddings, no identities. A hand-made
  sidecar `<file>.faces.json` overrides the detector (`detector: "manual"`).

The Godot `AssetManager` reads v1 (hand-written) and v2 manifests:

- **Proxy choice:** `shared(id, h)`/`instance(id, h)` pick the smallest proxy
  at least `h` output pixels tall. Compositions pass each layer's on-screen
  height, so a 2×2 wall decodes 540p and only full-frame layers decode 1080p.
- **Shared instances** are reference counted and freed when the last
  composition releases them. Before this, they were never freed.
- **Face tracks** are loaded lazily into `metadata["face_tracks"]`.

## Sources

- **`TextSource` presets:** caption, ticker, headline, label (boxed), stamp
  (red, bordered, upper case) and terminal (monospace).
- **`ProceduralSource`:** a generator shader rendered in its own viewport,
  receiving the musical uniforms. Unknown generators or params are rejected.
  The first generator is `lissajous`; it is the hook for mathematical
  visualisations. Adding one means adding a shader to `GENERATORS`.
- **`pdf_page` assets with a PNG path** (v2) load as pre-rasterised images, so
  no `pdftoppm` call happens at runtime.

## Annotations

`AnnotationLayer` changes:

- Detector tracks are interpolated linearly between samples. A track is shown
  only within its sampled range, plus a 0.25 s hold. `min_conf` filters weak
  detections.
- New styles: `track` (track number), `trail` (recent path), `inset` (an
  enlarged crop of the face in the corner).
- Annotations follow the target's rotation and scale.
- With a target and `boxes`, the boxes stay fixed in the target's displayed
  space. Document storm uses this for redactions on rotated pages.
- **Real vs fictional:** `label` is display text chosen by the family from a
  seeded fictional pool (`CompositionFamily.FICTION`). It is never stored with,
  or derived from, detector data. `show_ids` shows the detector's track number.

## Collections and selection

- **`shows/collections.json`** defines the 11 collections of
  [docs/06](06-media-library-and-style.md) plus `captions` and `tickers`.
  Rules: `ids`, `tags_any`, `tags_all`, `exclude_tags`, `types`. An undefined
  name that is a library tag resolves to that tag.
- **`AssetSelector.select(collection, n, rng, constraints)`:**
  - Members come in sorted order and are drawn by a seeded RNG.
  - The last `repeat_window` picks are avoided while fresh members remain.
  - Constraints: `types`, `tags`, `exclude`, `max_videos`.
  - Every call logs `{collection, seed, state, ids, assets: [{id, content_hash, analyses}]}`.

## Macro controls (`MacroControls`)

Each axis is a value from 0 to 1. Each axis maps to its own key prefix, and
`CompositionFamily.resolve()` asserts this, so changing one axis cannot move
another axis's parameters. `test_axes_are_independent` checks this for every
family and axis.

| Axis | Common parameters | Applied |
| --- | --- | --- |
| density | family-specific (grid size, inserts, max pages, page size) | structural (rebuild, same seed) |
| motion | wobble amplitude/frequency, beat pulse, rotation range | live |
| cutting | beats between cuts (32…1), share of elements swapped | live (read on each beat) |
| distortion | effect amounts in the `fx` group | live; `character` (glitch, chromatic, edge, kaleido) is structural |
| persistence | feedback on/decay/beat_cut, selector repeat window, motif recurrence | live |
| annotation | face boxes, probability, labels/IDs, trails, redaction probability | live (visibility) |
| text_rate | text/document event probability per beat, max text items | live |

## Composition families

| Family | Density | Beat behaviour | Notes |
| --- | --- | --- | --- |
| `surveillance_wall` | 2×2 / 3×3 / 4×4 grid | swaps `share` of cells every `cutting.beats`; persistence repeats a feed in another cell (shared playhead, no extra decoder) | Cells beyond the video budget show thumbnails or NO SIGNAL. Camera labels and timestamp sit outside the distortion. |
| `channel_surfing` | PiP inserts (0–2), lower third, ticker | cuts the main channel; the **next channel is pre-loaded invisibly one beat ahead**; swaps inserts | Shared playheads follow the clock, so a channel is "live" when you return to it. |
| `document_storm` | max pages and page size | spawns pages with redactions/highlights/stamps; removes the oldest; changes the background feed every `cutting.beats` | Pages rotate within the motion range; redactions rotate with them. |

Families generate a normal composition spec. It is deterministic for a given
seed, controls, library and video budget (golden test:
`test_generation_is_deterministic`). After that, families edit the live
composition through `Composition.add_item(spec, index, t, parent_group)` and
`remove_item(id)`, which are transactional and release their sources.
Distortion lives in one top-level offscreen group `fx`, so it costs one pass
per effect regardless of layer count. Some overlays deliberately stay outside
it: labels, ticker, timestamp.

### Video budget (laptop target)

The laptop target is a ThinkPad T480: 4-core i5/i7-8x50U, Intel UHD 620,
optionally an MX150.

- `families.max_videos` (default 4) caps the video layers per composition.
  Every pick and swap checks the budget.
- During a non-cut transition, the outgoing composition still decodes. The
  incoming one is therefore generated with `max_videos + transition_videos −
  outgoing` videos (at least 1). It grows back on later beat events.
- The peak is 6 decoders for about one transition. On the T480, set
  `transition_videos: 0` if transitions drop frames.
- The budget and library version used are logged in the director history.

## Runtime and operator

- **`FamilyDirector`** (`PerformanceRoot.director`):
  - Actions: `apply_family`, `reseed`, `set_axis` / `set_character` /
    `set_controls`, `hold`, `detach`.
  - Live changes apply in place. Structural changes regenerate with the same
    seed, crossfading on the next beat.
  - `history` records every apply (family, seed, collections, controls,
    budget, library) and every control change.
- **`PerformanceRoot.trigger_spec`** switches to a generated spec with the
  existing transactional, quantised path.
- **Show config:** `"families": {collections, max_videos, transition_videos,
  seed, controls, bindings, initial}` (see `shows/families.json`).
- **Operator `FamilyPanel`:**
  - F1–F3 select a family, R reseeds, H holds.
  - One slider per axis. Density applies on release; the others while dragging.
  - Distortion character selector.
  - Per-slot collection selector, which shows member counts.
  - Named presets in `user://presets.json`.
  - Status: seed, videos / budget, recent selections.

## Usage

```sh
tools/make_sample_assets.sh            # v1 sample + tagged raw library ingested into assets/sample/library
godot --path . -- --show=res://shows/families.json
tools/get_face_model.sh && cd analysis && uv sync --group faces && \
  uv run cctv-ingest ~/media/raw ../assets/library --faces ../.models/face_detection_yunet_2023mar.onnx
tools/bench.sh 120 --show=res://shows/bench_families.json [--fps=30]   # families stress benchmark
```

The real library goes in `assets/library/` (gitignored). Point a copy of
`shows/families.json` at it.

## Status and limitations

- **Tests:** 123 Godot tests pass (headless and GL). They cover manifest v2,
  proxies, refcounts, face-track interpolation, the selector, axis
  independence, determinism, the budget over 40 beats, live vs structural
  changes, the director and the operator panel. 50 Python tests pass,
  including ingest end to end, cache invalidation, PDF pages, sidecars, and a
  YuNet run when the model is present.
- **Performance is not yet measured on target hardware.** The development
  machine only had llvmpipe (software GL) in this session: about 36 fps at
  1080p, which says nothing about a GPU. Run `bench_families.json` on the T480
  at 60 and 30 fps. Acceptance needs ≥98% of target fps, ≤1% late frames and
  p99 ≤ 1.5 frame periods. A dedicated GPU remains the M1 reference.
- **Switch frame cost:** composition build and decoder opens still happen
  synchronously. Channel surfing hides this with pre-loading; wall swaps and
  document background changes do not yet. Measured prepare time on llvmpipe
  was 14–66 ms per family switch.
- **Faces:** the sample library has a synthetic track, because test patterns
  contain no faces. Detection quality on real footage has not been evaluated.
  Choose `min_conf` and `--face-step` per library.
- **Annotation order:** face annotations are inside `fx`, so they distort with
  the image. Making this a per-family setting is still open.
- **Still missing:** shot boundaries and motion/colour summaries in preprocessing.
- **Acceptance** still needs a real library (about 50 or more assets across
  the collections) and an operator session to a recorded set.
