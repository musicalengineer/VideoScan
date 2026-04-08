# Catalog-Aided Face Detection

**Status:** Idea / design exploration. Nothing implemented yet.
**Last updated:** 2026-04-08
**Author:** Rick + Claude
**Subsystem:** crosses `VideoScan.py` (catalog), `VideoScanModel.swift`
(Swift catalog), and `PersonFinderModel.swift` (face detection).

## TL;DR

The Person Finder currently treats every video as an opaque black box and
runs the same uniform face-detection pass on each. The catalog already
knows a great deal about every file — codec, resolution, frame rate,
audio layout, partial MD5, duration, container format. None of that
knowledge is currently used to make face detection faster, smarter, or
more informative.

This document collects the highest-leverage ways to feed catalog
metadata back into the face-detection pipeline, ranked by ROI against
Rick's three explicit project goals:

1. **Find** the videos that contain his family.
2. **Organize** the keepers (by person, by decade).
3. **Identify junk** for manual deletion.

The unifying principle: catalog signals **bias work order and skip
clearly-impossible candidates**, but they never *replace* the face
detector for any file the user might want fully scanned. Priors guide
the search; they never reject content silently.

## Goals

- Make subsequent scans of the same archive dramatically faster than
  the first.
- Surface a "junk candidate" list as a free byproduct of catalog
  scanning, **without** needing face detection to run on those files.
- Get to the first family hit faster on a fresh archive.
- Provide enough determinism that two identical scans produce
  identical results — no ML drift, no opaque scoring.

## Non-goals

- Auto-deleting anything based on catalog signals. Risk/reward is
  wrong: one bad classification deletes a wedding video. Always
  surface, never reap.
- Training a learned classifier on the catalog. The deterministic
  rules below capture most of what a learned model would, with zero
  training data, zero opacity, and no risk of confidently-wrong
  predictions.
- Skipping face detection on files based on "low confidence" priors.
  Priors bias *order*, never *coverage*. A complete scan must
  eventually visit every video.

## The six ideas, ranked

### 1. Pre-filter — files that *cannot* contain family content

Catalog metadata can eliminate certain files from face detection
entirely. These are deterministic, not heuristic: each skip is
provably safe.

| Signal | Action | Why it's safe |
|---|---|---|
| `stream_type == audio_only` | Skip face detection | No video stream to scan |
| `duration < 2.0 s` | Skip face detection | Below the per-segment minimum already enforced downstream |
| `width × height < 160 × 120` | Skip face detection | Below dlib/Vision usable face size |
| `file_size < (bitrate × duration × 0.5)` | Mark as truncated, skip | File is corrupt; ffprobe usually catches but not always |
| `partial_md5 ∈ already_scanned` | Inherit prior result | Same content as a file we've already seen |

Estimated savings on Rick's archive: probably 10–25% of files dropped
outright (audio-only DV captures, GoPro thumbnails, screen-record
artifacts, duplicates across drives).

**Implementation cost:** small. The catalog already produces every
field above. Wire a single `shouldFaceDetect(catalogRow)` function in
`PersonFinderModel.swift` that consults it before queuing a job.

### 2. Negative cache keyed by partial MD5

When face detection finishes a video and produces zero hits **with
full coverage** (i.e. it actually scanned the file end-to-end and
didn't bail out from memory pressure or thermal throttling), persist
a row to a small SQLite table:

```
( partial_md5, file_size, scanner_version, scanned_at, segments_examined,
  faces_detected, hits, duration_secs )
```

On any subsequent scan — *any volume, any folder* — when the catalog
encounters a file whose `(partial_md5, file_size)` matches a
`scanner_version`-current row with `hits == 0`, skip face detection
and inherit the result.

Why this is the most valuable single idea:

- **It compounds.** First pass over the archive is slow; second pass
  is mostly cache hits even after files have been moved or renamed.
  The hash is the identity, not the path.
- **It survives organization.** As Rick triages and reorganizes the
  archive, the cache stays valid because it isn't keyed on path.
- **It produces the junk pile for free.** Anything in the negative
  cache after a thorough scan is, by definition, a junk candidate.
  A "show me everything in the negative cache" view becomes a
  one-click triage list.
- **It supports detector upgrades.** When the face-detect engine
  improves (ANE tuning, CoreML swap, dlib version bump), bumping
  `scanner_version` invalidates the cache selectively. Old results
  stay valid for files where the upgrade can't possibly help; new
  results are recomputed where it can.

Schema lives in `~/Library/Application Support/VideoScan/face_cache.sqlite`
or similar. Single-table, single-writer (the Person Finder), single
reader (also the Person Finder). No locking concerns.

**Implementation cost:** medium. Maybe a day. The hardest part is
defining "full coverage" honestly so we don't poison the cache with
runs that bailed out under memory pressure.

### 3. Folder-level priors

Once a folder has had at least N videos scanned (say N = 5), compute
two simple statistics for the folder:

- `family_hit_rate = videos_with_hits / videos_scanned`
- `coverage_rate   = videos_scanned / videos_total`

Use these to bias the *order* in which the remaining videos in that
folder get scheduled:

- `family_hit_rate > 0.5` → boost remaining videos to the front of
  the scan queue.
- `family_hit_rate == 0.0` after N≥10 → push remaining videos to the
  back of the queue, but **still scan them eventually**.

Folder name lexical hints can seed the prior before any scanning
happens: tokens like `vacation`, `birthday`, `christmas`, `wedding`,
`donna`, year tokens (`1995`–`2025`), or any reference photo's
filename match all bump the prior up.

The user-visible payoff: when Rick aims the Person Finder at a 14 TB
archive, the first hits start appearing in seconds rather than
minutes. The dashboard already tracks per-volume progress; this just
re-orders work within a volume.

**Implementation cost:** medium. Needs a priority-queue-style work
scheduler in `PersonFinderModel.swift` instead of the current
straight-through walk. Folder statistics are trivial to maintain
incrementally.

### 4. Format fingerprinting → "is this a home video at all"

Family camcorder material has surprisingly distinctive signatures in
the catalog already, and the rules are deterministic:

| Signal pattern | Implies | Likelihood weight |
|---|---|---|
| `dvvideo`, 720×480, interlaced, 29.97, `pcm_s16le` 32 k or 48 k | Mini-DV camcorder, 1995–2008 | +3 |
| `mpeg2video`, 1440×1080 anamorphic, 1080i | AVCHD camcorder, 2007–2014 | +3 |
| `h264 High`, 1920×1080, 29.97, AAC 48 k 2 ch | iPhone or modern phone | +2 |
| `hevc`, 1920×1080 or 3840×2160, 30 or 60 | Modern iPhone | +2 |
| `mjpeg`, 320×240, no audio | Old digicam video mode | +1 |
| `h264`, atypical aspect (e.g. 1920×1200), no audio | Screencast — almost certainly junk | −3 |
| Any video, no audio, < 10 s | Screen recording / GIF / artifact | −2 |
| Any video, audio sample rate 8 k mono | Voicemail / VoIP capture | −2 |

Sum the weights into a `home_video_likelihood` score per file. Surface
it as a column in the catalog table; let Rick sort by it. The
high-scorers go to face detection first; the strong-negative scorers
go straight onto the "review for deletion" list **without** needing
face detection to confirm they're junk.

**Implementation cost:** small to medium. Pure metadata table lookup,
no new I/O. Add a score field to the catalog row, populate during
ffprobe ingest.

### 5. Scene-targeted frame sampling

Currently the face scanner samples every Nth frame uniformly. For a
1080p AVCHD source at frame_step=15, that's already ~2 fps which is
plenty for catching lingering faces. But for a noisy 480i VHS
transfer, consecutive frames are nearly identical due to motion blur
and interlacing, so uniform sampling wastes work re-checking
near-duplicate content.

Catalog metadata gives us the codec, resolution, and (with one extra
ffprobe pass) the GOP size. With those, we can switch to **keyframe-
locked sampling** for codecs where keyframes correspond to scene
boundaries:

```
ffmpeg -skip_frame nokey -i input.mp4 -vf "select=eq(pict_type\,I)" \
       -vsync 0 -f image2pipe -
```

This typically reduces sampled-frame count by 5–20× on family
content while *increasing* scene coverage, because every keyframe is
guaranteed to be a fresh scene start rather than a midway frame.

**Implementation cost:** medium. Needs a per-codec policy table and
either a frame-source switch in the scan loop, or a pre-pass to
extract keyframe timestamps and feed them to the existing scanner.

### 6. Date-aware decade routing

Year extraction already exists for decade chaptering in the
compilation path. Lift it into a first-class column on the catalog
table so we can:

- Run "Donna pre-2000" as one job and "Donna 2000s" as another in
  parallel, with the catalog filtering inputs at queue time.
- Auto-name compiled files by decade without re-extracting at compile
  time. (This also fixes a small inconsistency — the compile path
  re-derives years when it could just trust the catalog.)
- Spot videos with a *missing* year — no path token, no creation date,
  no EXIF — and flag them for manual review. Orphans are often the
  most interesting finds in a family archive (they're the ones nobody
  bothered to organize).

**Implementation cost:** small. Year extraction logic already exists;
this is just a column addition and one query path.

## What this looks like end-to-end

After all six ideas land, a fresh scan over a new external drive
proceeds roughly like this:

1. Catalog phase (existing): ffprobe every file, compute partial MD5,
   write the catalog row. **Augmentation:** also compute
   `home_video_likelihood`, extract year, populate
   `should_face_detect` flag.
2. Pre-filter phase (new): drop audio-only, tiny, truncated, and
   already-cached files. Log counts.
3. Priority queue (new): order remaining files by
   `home_video_likelihood DESC, folder_prior DESC, year DESC`.
4. Scan loop (existing, with modification): consult negative cache
   per file; on miss, run face detection; on completion, write
   results back to negative cache **only if scan completed under
   normal conditions**.
5. Post-pass: surface the union of `(audio_only, tiny, no_faces,
   negative_score)` files as a junk-candidate review list.

The user-visible win on a second pass over the same archive is
roughly an order of magnitude faster, because nearly everything is a
cache hit. The user-visible win on a fresh archive is "I see family
hits within seconds instead of minutes."

## Open questions

- **Where to store the negative cache?** SQLite is the obvious answer
  but introduces a dependency. Alternative: a single newline-delimited
  JSON file per partial-MD5 prefix (so it stays grep-able and
  diff-able). Open to discussion.
- **How to define "full coverage" for cache writes?** Need a clear
  contract: `coverage = scanned_frames / expected_frames > 0.95`,
  *and* no memory-pressure pause occurred, *and* no thermal throttle
  occurred during the scan. Otherwise we risk poisoning the cache.
- **Cross-drive partial-MD5 collisions?** Partial MD5 is not a true
  hash. Two unrelated files could collide. Mitigate by also matching
  on `(file_size, duration, vcodec)` before trusting a cache hit.
- **What does "scanner_version" mean exactly?** Probably a tuple of
  `(engine_name, engine_version, threshold, frame_step, min_conf)`
  hashed into a stable string. Any change to scan parameters
  invalidates the cache for the affected files.

## Testing strategy

Roughly the same shape as compilation-bucketing: synthetic tests for
the deterministic pieces (pre-filter rules, format fingerprinting,
folder prior arithmetic), plus a manual smoke pass over the real
archive to validate the negative cache behaves correctly under
re-scan.

Concrete unit tests would assert:

- `shouldFaceDetect()` returns false for synthetic audio-only,
  truncated, tiny, and dup-MD5 catalog rows.
- `homeVideoLikelihood()` produces expected weights for a hand-built
  set of `(codec, resolution, audio)` tuples.
- Negative cache hit/miss table for various `scanner_version` and
  `(md5, size)` combinations.

## Connection to existing subsystems

- **Catalog (`VideoScan.py`, `VideoScanModel.swift`):** Source of
  truth for everything except `home_video_likelihood`, which would
  be a new derived field.
- **Compilation bucketing
  (`docs/compilation-bucketing.md`):** Both subsystems reuse the
  ffprobe-derived stream-parameter view of a file. The `CompatKey`
  defined there and the `format fingerprint` defined here are
  cousins; we should keep them in sync or unify them under a single
  `MediaFingerprint` type when both have stabilized.
- **Person Finder (`PersonFinderModel.swift`):** The integration
  point. Pre-filter and negative cache are the smallest change;
  priority-queue scheduling is the largest.

## Future work beyond this doc

- Surface the negative cache as a sortable table in a new "Junk
  Triage" tab, with bulk-action buttons (move to a folder, mark
  reviewed, etc.).
- Use folder priors to *adapt* the per-file scan budget — high-prior
  files get more frames per second of video, low-prior files get
  fewer.
- Cross-correlate audio-only and video-only catalog rows via the
  existing Correlate/Combine subsystem, then face-detect the
  combined output. (This already works manually; could be
  triggered automatically when the catalog is filled.)
