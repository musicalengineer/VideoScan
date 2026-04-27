# Session Handoff — 2026-04-24

State of the family-FD beta test, picked up from the prior session.

## Where we are in the four-tier plan

`docs/Media_Analyzer.md` defines a four-tier ROI-ordered plan:

1. **Diagnostic** — confusion matrix on reference photos. ✅ DONE.
2. **Classifier on frozen embeddings** — train an SVM/MLP head. NEXT.
3. Embedder fine-tuning (only if Tier 2 plateaus).
4. Active-learning loop.

We are between Tier 1 and Tier 2. Tier 1 said the embeddings are
**separable on reference photos** (gap +0.073 dlib, +0.096 facenet,
0/28 confusable pairs). The open question is whether they hold up on
**video frames** of the same family across decades. So before training
a classifier, we did a beta-test scan.

## What we built

### `scripts/fd_diagnostic.py` — Tier 1 diagnostic

Builds the gallery of FaceNet (512-D) and dlib (128-D) embeddings from
`poi_photos/<person>/*.jpg`, computes within-person and between-person
distance distributions, and writes:

- `output/fd_diagnostic/embeddings.npz` — **the gallery, reused below**
- `output/fd_diagnostic/summary.md` — confusion matrix
- heatmaps for each embedder

Run: `venv/bin/python3.12 scripts/fd_diagnostic.py`. Took 30s on MPS.

### `scripts/fd_scan_volume.py` — first-cut volume scanner

Quick-and-dirty version used for the proving run on
`/Volumes/MyBook3Terabytes`. Outputs in `output/fd_scan_volume/`:

- `scan_donna_20260424_191158.csv` — full result table, 2059 videos
- `top_donna_20260424_191158.md` — top hits as markdown for verification

Result of that run: **152 STRONG, 96 WEAK in 38 min**. Top files include
`ChristmasEve.mov` (best dist 0.110), `MattIsBorn1994.mov`, the Eileen
memorial 2023, Brockton Christmas 2010 — all plausible Donna content.
**Rick will eyeball this list to score actual precision.**

Keep this around for one more session as a known-good baseline; once
`find_person.py` matches its output we can delete it.

### `scripts/find_person.py` — the polished CLI Rick asked for

What the prompt wanted: *"a script I can run that does this via cli, ie,
'find person on volume(s) producing CSV or HTML'. it can be interactive,
but the point is we can use it without the app on cli."*

Modes:

```bash
# list available galleries
venv/bin/python3.12 scripts/find_person.py --list-persons

# scan one or more volumes for a known person
venv/bin/python3.12 scripts/find_person.py /Volumes/MyBook3Terabytes --person donna

# multiple roots, custom thresholds
venv/bin/python3.12 scripts/find_person.py /Volumes/A /Volumes/B \
    --person donna --strong-thresh 0.55 --max-frames 80

# interactive: prompts for person + roots
venv/bin/python3.12 scripts/find_person.py --interactive

# CSV only (skip HTML), or vice versa
venv/bin/python3.12 scripts/find_person.py /Volumes/A --format csv
```

Outputs land in `output/find_person/<person>_<timestamp>.{csv,html}`.
The HTML is sortable (click headers), color-codes STRONG/WEAK rows, and
links each filename via `file://`.

Defaults (top of file, easy to tweak):

| constant | default | meaning |
|---|---|---|
| `DEFAULT_FRAME_INTERVAL` | 5.0 s | seconds between sampled frames |
| `DEFAULT_MAX_FRAMES` | 120 | cap per video |
| `DEFAULT_STRONG_THRESH` | 0.60 | cosine dist for STRONG hit |
| `DEFAULT_WEAK_THRESH` | 0.75 | cosine dist for WEAK hit |
| `DEFAULT_MIN_DURATION` | 30 s | skip shorter |
| `DEFAULT_MAX_DURATION` | 4 h | skip longer |
| `STRONG_HIT_COUNT` | 3 | ≥ this → STRONG verdict |
| `WEAK_VIA_WEAK_COUNT` | 5 | ≥ this many weak (no strong) → WEAK |

### `tests/test_find_person.py` — unit tests for the framing logic

27 tests, all pass. Coverage:

- `compute_sample_timestamps` — short videos return empty, endpoints
  avoided, capped at max_frames, monotonic.
- `verdict_for_counts` — STRONG/WEAK/NO bucketing.
- `is_video_path` / `should_skip_dir` / `iter_videos` — walk logic
  including a real-fs tmpdir test that creates `.git`, `node_modules`,
  and `.Spotlight-V100` and confirms they're pruned.
- `min_distance_to_gallery` — synthetic L2-normed vectors at distance
  0, 1, 2 (cosine).
- Constants sanity (threshold ordering, hit-count ordering).

Run: `venv/bin/python3.12 -m unittest tests.test_find_person -v`

These are **pure-Python**: no torch, no ffmpeg, no gallery file
required. They guard the framing rules so we can twiddle thresholds and
walk filters without breaking semantics silently.

## Critical gotcha — Python 3.12 vs 3.14

Homebrew upgrade orphaned the venv: `venv/bin/python` symlinks to 3.14
but the installed packages (torch, facenet-pytorch, dlib, numpy) live
under `python3.12/site-packages`. **Always invoke
`venv/bin/python3.12` directly** — never `venv/bin/python` and never
just `python3`. All the example commands above already do this.

## Tomorrow's plan

1. **Verify the STRONG list.** Rick scrolls through
   `output/fd_scan_volume/top_donna_20260424_191158.md` (or open the
   newer HTML produced by `find_person.py`) and tags each video as
   correct / incorrect / mixed.
2. **Calibrate thresholds.** From verified labels, see whether 0.60 /
   0.75 are the right cutoffs or whether we should tighten/loosen.
3. **Rerun on a second volume** (`MacStudioDrive` Movies folder or
   another) so we have two independent samples.
4. If precision looks good, **start Tier 2**: train a tiny classifier
   (linear SVM or 2-layer MLP) on `embeddings.npz` and replace the
   "min distance to gallery" decision with classifier probability.
5. Once Tier 2 is solid, **plug it into the Swift app's pluggable FD
   dispatch** as a fifth engine.

## Other open threads

- 1618 videos got skipped via `min_duration` filter on the
  MyBook3Terabytes scan. Most were < 30s clips. Worth a sweep with
  `--min-duration 5` to see if family content lurks there.
- One file (`babies tim and matt.mov`) has corrupt DV packets — ffmpeg
  can't decode any. Confirmed unrecoverable; we currently log it as
  `no_frames` and move on, which is correct.
- The diagnostic flagged matt/timmy as the closest within-family pair
  on FaceNet (gap +0.096). If misclassifications cluster between
  brothers, that's the first place to look.
