# Footage Spectrum — Find Similar Footage that looks at the footage

Status: PROPOSED 2026-10-03 (Rick + Claude; no implementation yet).
Follows docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md
§5.6–5.7 (the content steward; events are the point) and
docs/design/find_original_design.md / perceptual_compare.md (the existing
Compare engine). Tracks GH #259 (false duplicates) and #257 (events).

## 1. Why

Find Similar Footage today reasons over facts already in the catalog —
whole-file and sampled digests, recorded lineage, Avid/FCP identifiers,
normalized name + length. It never looks at a picture, which is why it
runs in a second and why it misses:

- a clip that was **renamed** (no name match);
- an **excerpt or a longer cut** of the same tape (different length);
- a **re-export** — same name and length, different bytes: the 408
  "content differs — NOT a duplicate" pairs of 2026-10-03, filed under
  duplicates when they are the same footage in another encode.

And it knows nothing about *what* the footage shows, so Events rest on
dates and folder names alone.

The app already has eyes — **Compare** (frame-by-frame perceptual verdict
for two chosen files) and **Scene Captions / OCR** (a vision-language
model over sampled frames) — but neither is connected to grouping.

## 2. The idea (Rick, 2026-10-03)

> "A kind of spectrum, like one uses in chemistry — a list of 5 videos
> with the spectra lining up; a visual indication showing the user the
> similarities … like you might do for stars or chemical elements."

This is the right tree, and it has a known form: the **movie barcode** —
each moment of a video reduced to one thin column of its colours, laid
left to right in time. One strip per video.

It is a spectrum in the useful sense:

| Spectroscopy | Footage |
|---|---|
| wavelength axis | time |
| continuum colour | the scene's palette (warm indoor, blue beach, green lawn) |
| absorption lines | **scene cuts** — sharp boundaries between bands |
| the same element's lines in two stars | the same footage in two files: the bands line up |
| red-shift | a **time offset** — an excerpt's bands sit somewhere inside the longer tape's |
| line strength | how long each scene runs |

So one small artifact does three jobs:

1. **A picture a person can read.** Five strips stacked on one time axis:
   identical footage is visibly identical; an excerpt is a shorter strip
   sitting where it matches; a re-export is the same strip slightly
   shifted in tone; different footage simply doesn't line up.
2. **A fingerprint a machine can align.** The strip is a sequence of
   small colour signatures; sliding one along another finds copies,
   excerpts and their offset.
3. **A map of a tape.** Scene boundaries are visible at a glance — a
   90-minute tape reads as "kitchen · yard · dark · beach" before any
   frame is opened.

A second band under the first carries the **sound** (loudness / coarse
spectrum over time): the same soundtrack lines up even when the picture
was cropped, re-encoded or re-framed.

## 3. Two questions, two amounts of looking

"**Is this the same footage?**" and "**Is this the same kind of
occasion?**" are different questions and need different evidence.

### 3.1 Same footage — the strip

- One tiny sample every 1–2 seconds (decoded at low resolution, hardware
  decode via ffmpeg/VideoToolbox), each reduced to a short column of
  colour values. A one-hour tape ≈ 1,800–3,600 columns ≈ a few tens of KB.
- **Nominate, then prove**: aligned strips only *suggest* "same footage"
  (with an offset and an overlap length). The existing **Compare** engine
  then verifies frame-by-frame at the matched positions before the
  catalog says so. Same propose-then-verify shape as Hallie and the Angel.
- Outcomes feed the existing footage groups as new evidence kinds:
  *same picture* (verified), *excerpt of* (with offset), *same footage,
  different encode* — which is where the 408 false duplicates go, and
  why the delete run stops re-reading them (#259).

### 3.2 Same kind of occasion — a handful of frames

- **8–16 frames spread across a clip** is enough to say "there is a tree
  with lights", "a cake with candles", "a beach", "a long table of food".
- Three sources, cheapest first:
  1. **Words we already have.** Scene Captions and OCR text are on the
     records now. Cue words (tree, presents, candles, cake, turkey,
     beach, lighthouse) become one more reason line for the event
     labeller — *zero new GPU work*.
  2. **Image embeddings** (SigLIP 2, approved 2026-09-26) on those 8–16
     frames, stored per file: "looks like Christmas" by comparing with
     plain-language descriptions (no training), and "looks like *that
     other* video" by comparing files with each other.
  3. **Rick teaches it.** Every event he confirms or names becomes a
     labelled example in his own family's terms — "our Cape house",
     "Grandma's kitchen" — and new footage is compared with those. The
     generic model knows what a Christmas tree is; only the family knows
     which living room it is. Something in between, as he put it.
- As everywhere: a look-alike is a **guess shown as a guess**, with its
  reason ("3 of 12 frames: a decorated tree"), until a person confirms.
  Face recognition stays demoted; this is scene and object evidence.

## 4. What the user sees

In the Triage tab's event and same-footage cards, and in the footage
group sheet:

```
Christmas 1994 — 5 clips · 3 drives                         0:00 ───────────────── 1:02:10
 tape_12.mov        ▓▓▓▒▒▒░░░▓▓▓▓███▓▓▒▒░░▒▒▓▓▓███▓▓▓▒▒▒░░░▓▓▓▓▓▒▒▒░░░▓▓▓▓▒▒░░
                    ▁▂▃▅▃▂▁▁▂▅▇▅▃▂▁▂▃▅▃▂▁▁▂▃▅▇▅▃▂▁▂▃▅▃▂▁▁▂▃▅▇▅▃▂▁▂▃▅▃▂▁▁▂  sound
 tape_12 copy.mov   ▓▓▓▒▒▒░░░▓▓▓▓███▓▓▒▒░░▒▒▓▓▓███▓▓▓▒▒▒░░░▓▓▓▓▓▒▒▒░░░▓▓▓▓▒▒░░   identical
 xmas_export.mp4    ▓▓▓▒▒▒░░░▓▓▓▓███▓▓▒▒░░▒▒▓▓▓███▓▓▓▒▒▒░░░▓▓▓▓▓▒▒▒░░░▓▓▓▓▒▒░░   same picture, re-encoded
 opening gifts.mov              ▓▓▓▓███▓▓▒▒░░▒▒▓▓▓███                             excerpt · starts 11:40
 dinner.mov         ░░▒▒▓▓▒▒░░▒▒▓▓░░▒▒                                            same day · different footage
```

- One shared time axis; an excerpt is drawn **at its offset**.
- Hover a strip → the frame at that moment; click → play there, or open
  Compare on that pair at that position.
- A match is drawn as a faint bracket between the two strips, so the eye
  lands on what lines up.
- Per-clip actions stay the existing ones (Show in Catalog, open the
  group); adding a note or naming the event waits on the stored event
  name (after #167).
- Colours are the footage's own; the strip is honest about what it is
  ("colours over time — bands that line up are the same pictures").

## 5. Architecture

- **A new cycler: "Footage Spectrum"** in Content Analysis (design
  §5.5): continuous, incremental, off-main, per-drive lanes, expensive
  lane (decode) — overnight on the M4 or on demand. This is the
  silicon-melting work.
- **Storage: a derived cache, not the catalog.** Strips (and later the
  frame embeddings) live in a cache keyed by the file's content
  signature — like thumbnails and the probe cache — so there is no
  catalog schema change, they survive rename/move, and they can be
  rebuilt. The record carries only a small stamp `{analyzer version, at,
  input signature}` (the analysis-ledger rule).
- **Alignment**: pure, table-testable (`FootageSpectrum.align(a, b) →
  [overlap, offset, score]`), run only over candidate pairs — buckets by
  coarse strip signature plus what the catalog already suggests (same
  day, same event, same name family, the refused duplicate pairs) — never
  all-pairs.
- **Verification**: the existing Compare engine, called at the aligned
  offsets (a few frames, not the whole file), gated per volume exactly
  as Compare is today.
- **Grouping**: FootageGrouping gains evidence kinds with the existing
  confidence ladder — verified *same picture* = Likely-or-stronger;
  aligned-only = Possible (never chains); a person's "not the same"
  still outranks everything.
- **Occasion evidence** goes to the one labeller (VideoScanCore
  EventLabeler via the Angel's `OccasionReader` front door) as new
  reason kinds — *caption words*, *looks like*, *looks like one you
  named* — so the Angel and the steward keep agreeing.

## 6. Safety and honesty

- Nothing here deletes, moves or rewrites media. A spectrum match never
  makes two files "duplicates"; only byte verification does (unchanged).
  If anything, it *removes* files from the duplicate lane.
- Read-only volumes are read, never written (the cache lives with the
  app's other caches).
- Every claim carries its reason and its strength; guesses are labelled.
- Feature-test checklist applies: logic (alignment truth tables,
  synthetic strips), scale (100k files of strips; alignment budget),
  **media matrix** (mp4/h264, mov/prores, mkv/ffv1, mxf, avi/dv —
  strips from the five fixtures, plus re-encode / crop / excerpt
  variants generated by ffmpeg), isolation (cache directory injectable),
  sensor (no all-pairs alignment; no strip work in a view body).

## 7. Staging (UI-first where a human has to judge it)

| Stage | What | Why first |
|---|---|---|
| **0** | Caption/OCR cue words as an event reason | no new compute; immediate lift for Events |
| **1** | The strip for one file + the stacked view in the footage group sheet, computed on demand for the group being viewed | Rick judges the *picture* before any pipeline exists (UI-first trial) |
| **2** | Alignment + Compare verification for the pairs the catalog already suspects — starting with the refused "not a duplicate" pairs | closes #259 with evidence; small candidate set |
| **3** | The cycler: strips for the whole catalog, cache, coverage row in Content Analysis | the overnight melt |
| **4** | Frame embeddings: "looks like", and learning from Rick's confirmed events | needs the stored event name; biggest model work |

## 8. Decisions for Rick

1. Strip density: one column per 2 s (smaller, faster) or per 1 s
   (finer alignment)? Recommend 2 s, re-sample around a candidate match.
2. Sound band in Stage 1, or picture first? Recommend picture first.
3. Stage 1 as a trial in the footage group sheet (on demand, nothing
   stored) before any cycler — agreed shape?
4. Where the caches live and how big they may grow (estimate: tens of KB
   per hour of footage for strips; embeddings ≈ 10–20 KB per file).
