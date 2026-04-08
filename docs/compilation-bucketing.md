# Compilation Bucketing — Person Finder

**Status:** Implemented (initial cut). Manual smoke test on Rick's mixed
DV/H.264/HEVC archive still pending; results table UI shipped; tests not
yet wired (no Swift test target exists yet — listed under Testing as
intended additions when one lands).
**Last updated:** 2026-04-08
**Author:** Rick + Claude
**Subsystem:** `VideoScan/VideoScan/PersonFinderModel.swift` (concat path),
`VideoScan/VideoScan/PersonFinderView.swift` (results UI)

## TL;DR

The current Person Finder compiles every extracted clip for a job into a
single MP4 by way of `ffmpeg -f concat ... -c:v libx264 ...`. With
heterogeneous family-video sources (DV, AVCHD, H.264 phone, HEVC phone, MXF),
this single-file output corrupts about ten minutes in — the moment the
demuxer hits a clip whose stream parameters differ from the first one.

We are replacing the "one giant file" model with a **bucketed** model:
group consecutive clips that share identical codec parameters into
**stream-copy** compilations. The result is a small handful of files like
`Donna_compilation_01_h264_1080p30_aac48k.mp4`, each one lossless, fast
to produce, and timeline-ordered. We accept multiple files as the cost of
correctness and quality.

## Problem

### Symptoms
- Compiled output plays correctly for the first ~10 minutes.
- Around the first codec/format boundary, the video either freezes,
  shows green/black frames, drifts audio, or stops decoding entirely.
- Different players (QuickTime vs VLC vs Finder preview) disagree on
  where the corruption begins.

### Root cause
`pfConcatenateClips` and `pfConcatenateWithDecadeChapters` both feed the
clip list to ffmpeg's **concat demuxer** (`-f concat -safe 0 -i list.txt`)
followed by a libx264 transcode. The concat demuxer is documented to
require that every input share identical stream layout: codec, codec
parameters (extradata), pixel format, resolution, SAR, time base, audio
codec, sample rate, channel layout, and stream count/order. Even when a
re-encode follows, the demuxer stage emits broken timestamps and dropped
streams once parameters change between segments.

Family-archive clips routinely cross all of these boundaries:

| Boundary | Typical mismatch |
|---|---|
| VHS capture → DV camcorder | DV NTSC 720×480 vs MPEG-2 720×480, different pix_fmt/SAR |
| DV → AVCHD | 720×480 anamorphic vs 1440×1080 anamorphic |
| AVCHD → phone H.264 | 1080i interlaced vs 1080p30 vs 1080p60 |
| H.264 → HEVC | codec change (different extradata) |
| Any analog → digital | 32 kHz mono vs 48 kHz stereo audio |
| Some clips have no audio | demuxer stream count mismatch |

A small extracted clip can also have its parameters chosen by
`AVAssetExportSession` rather than copied from source, so two clips
extracted from two different sources will frequently differ even when
the user thinks "everything is H.264".

### Why we are not "fixing" the single-file approach
There are valid alternatives — `concat` filter with full re-decode, or
per-clip pre-normalization to a common target — but both involve a lossy
re-encode of the entire archive and feel wrong for a preservation-grade
tool. Rick's stated priority is **timeline order and quality first**.
Multiple files is an acceptable price.

## Goals

1. **Lossless.** Every output clip is bit-identical to the originating
   extracted clip — pure stream copy, no re-encode.
2. **Timeline-preserving.** Clips appear in chronological order across
   the entire set of output files. We do **not** merge non-adjacent
   buckets just because their formats happen to match.
3. **Self-describing filenames.** A glance at the filename tells you
   what is inside: index, codec family, resolution, frame rate, audio.
4. **Robust to mixed inputs.** Adding a single new format never breaks
   any other bucket.
5. **Visible in the UI.** The Person Finder results table lists every
   produced compilation with format label, clip count, and duration.

## Non-goals (for this change)

- A single-file output across all formats. Punted; can return as a
  future "Compile (single, transcoded)" opt-in button.
- Re-extracting clips with `ffmpeg -c copy` instead of
  `AVAssetExportSession`. Worth considering later for true
  source-fidelity preservation, but out of scope here.
- Cross-job compilation. Each job still produces its own buckets.
- Decade chaptering inside buckets. Decade chapters require a single
  metadata stream that aligns with one container; we can re-introduce
  chaptering *within* a single bucket later if useful, but the initial
  cut just emits flat compilations.

## Design

### Compatibility key

A `CompatKey` is the set of stream parameters that the ffmpeg concat
demuxer cares about for stream copy. Two clips are concat-copy
compatible iff their `CompatKey` values are equal.

```swift
struct CompatKey: Hashable {
    // Video
    let vCodec:     String   // e.g. "h264", "hevc", "dvvideo", "mpeg2video", "none"
    let vProfile:   String   // e.g. "High", "Main", "Baseline" — empty if N/A
    let pixFmt:     String   // e.g. "yuv420p", "yuv422p10le"
    let width:      Int
    let height:     Int
    let sar:        String   // sample aspect ratio as "num:den", e.g. "1:1", "10:11"
    let fpsRational:String   // r_frame_rate as "30000/1001", "25/1", or "0/0" if VFR
    let colorSpace: String   // bt709 / smpte170m / unknown
    let colorRange: String   // tv / pc / unknown

    // Audio
    let aCodec:     String   // "aac", "pcm_s16le", "ac3", "none"
    let aSampleRate:Int      // 48000, 44100, 32000, 0 if no audio
    let aChannels:  Int      // 1, 2, 6, 0 if no audio
    let aLayout:    String   // "stereo", "mono", "5.1" — best-effort

    // Container
    let hasAudio:   Bool     // distinct stream-count signal
}
```

We populate it by running `ffprobe -v error -print_format json -show_streams`
on each clip and parsing the result. The key is intentionally strict —
better to fragment into a couple of extra buckets than to silently allow
a mismatch the demuxer can't handle.

### Short label (for filenames)

```swift
extension CompatKey {
    var shortLabel: String { ... }   // e.g. "h264_1080p30_aac48k_2ch"
}
```

Rules:
- Codec family abbreviated: `h264`, `hevc`, `dv`, `mpeg2`, `prores`, `xdcam`.
- Resolution as `<height>p` or `<height>i` if interlaced; `4k`/`uhd`/`hd`
  prefixes only when unambiguous.
- Frame rate rounded to common labels: `24`, `25`, `30`, `50`, `60`,
  `2997` for 29.97, `5994` for 59.94.
- Audio: codec + sample rate in kHz + channel count, e.g. `aac48k_2ch`,
  `pcm48k_1ch`, or `noaudio` when absent.
- Sanitized to filesystem-safe characters via `pfSanitize`.

### Bucketing algorithm

Input: `entries: [pfClipEntry]` already sorted by timeline
(year + filename, the existing `pfBuildSortedClipEntries` order).

```
bucket = []
buckets = []
currentKey = nil
for clip in entries:
    key = compatKey(for: clip)         // ffprobe + parse, cached per-path
    if currentKey == nil || key == currentKey:
        bucket.append(clip)
        currentKey = key
    else:
        buckets.append((currentKey, bucket))
        bucket = [clip]
        currentKey = key
if not bucket.isEmpty:
    buckets.append((currentKey, bucket))
```

This is **strict-adjacent**: when the timeline goes
DV → H.264 → DV → H.264, you get four buckets, not two. The user
explicitly endorsed this in the design conversation — preserving
chronology inside each output file is the whole point of a memory
compilation.

#### Optional bucket cap

To keep individual files manageable, we apply a soft cap on bucket
duration:

```swift
let maxBucketSeconds: Double = 30 * 60   // 30 minutes
```

If appending the next clip would push the bucket past the cap, we close
the current bucket and start a new one with the same key. Same key, new
file, same naming pattern (the index increments). Initial value: 30
minutes; easy to tune later or expose in settings if Rick wants.

#### Compat-key cache

`CompatKey` derivation runs ffprobe once per clip. We cache by absolute
clip path inside the compile function — clips are short-lived
intermediate files for one job, so the cache lifetime equals the
compile call.

### File naming

Pattern:

```
<JobName>_compilation_<NN>_<shortLabel>.<ext>
```

- `JobName` — sanitized name of the search target / reference set,
  matching the existing single-file naming.
- `NN` — zero-padded ordinal across **all buckets for this job**, in
  timeline order (so `01` is the earliest material on disk).
- `shortLabel` — from `CompatKey.shortLabel`.
- `<ext>` — `.mov` if any clip in the bucket uses a codec or pixel
  format that the MP4 container can't legally hold (PCM audio,
  ProRes, 10-bit yuv422p10le, etc.); otherwise `.mp4`. The decision
  is made from the bucket's `CompatKey` — no extra probing needed.

Examples:

```
Donna_compilation_01_dv_480i2997_pcm48k_2ch.mov
Donna_compilation_02_h264_1080p2997_aac48k_2ch.mp4
Donna_compilation_03_dv_480i2997_pcm48k_2ch.mov
Donna_compilation_04_hevc_2160p30_aac48k_2ch.mp4
```

Note buckets 01 and 03 share a key but are separate files because the
timeline crossed into a different format and back. That is by design.

### ffmpeg invocation per bucket

```sh
ffmpeg -hide_banner -nostdin \
       -f concat -safe 0 -i <bucketlist.txt> \
       -map 0:v? -map 0:a? \
       -c copy \
       -movflags +faststart \
       -y <output>
```

- `-c copy` is the only line that matters for the loss-less guarantee.
- `-map 0:v? -map 0:a?` makes audio optional (`?`) so a no-audio
  bucket still works. Within a bucket all clips agree on
  audio-or-no-audio because that's part of `CompatKey.hasAudio`.
- `-movflags +faststart` moves the moov atom to the front so the file
  starts playing before it's fully buffered.
- `-nostdin` and `-hide_banner` keep the stderr volume low; we still
  drain stderr asynchronously into a buffer for diagnostics, the same
  way the existing concat path does.

### Pre-flight sanity check

Before stream-copying a bucket we run one cheap sanity pass:

1. ffprobe each clip in the bucket and verify the parsed `CompatKey`
   actually matches the bucket's key. (Defensive — the clip files on
   disk should match what we already probed, but this catches the
   case where AVAssetExportSession produced something we
   misinterpreted.)
2. If any clip in the bucket disagrees, we **split it out** into its
   own single-clip bucket and append a warning to the job log.

This costs one extra ffprobe per clip and prevents a single bad
extraction from corrupting an otherwise-valid bucket.

## Data model changes

### `ScanJob`
- Replace `@Published var compiledVideoPath: String? = nil` with
  `@Published var compiledVideoPaths: [CompiledOutput] = []`
- Where `CompiledOutput` is a small struct:
  ```swift
  struct CompiledOutput: Identifiable, Equatable {
      let id = UUID()
      let path: String          // absolute path
      let label: String         // shortLabel
      let clipCount: Int
      let durationSecs: Double
      let bytesOnDisk: Int64
  }
  ```
- `reset()` clears the array.

### Migration
- The single-string field is referenced from `PersonFinderView.swift`
  in the results table for the "open compiled video" affordance.
  Replace that with a small subview that lists all `CompiledOutput`
  rows under the job header — see UI section below.

## Code changes by file

### `PersonFinderModel.swift`
- New section `// MARK: - Compatibility bucketing`
  - `struct CompatKey` and `extension CompatKey { var shortLabel }`
  - `private func pfProbeCompatKey(path: String) async -> CompatKey?`
    using ffprobe JSON.
  - `private func pfBucketByCompat(entries: [pfClipEntry], maxSecs: Double) async -> [(CompatKey, [pfClipEntry])]`
- New `private func pfConcatenateBuckets(...)` that replaces
  `pfConcatenateClips` for the bucketed case. Returns
  `[CompiledOutput]` to populate `job.compiledVideoPaths`.
- The old `pfConcatenateClips` becomes a fallback only used when
  `decadeChapters` is on **and** there is exactly one bucket — i.e.
  the homogeneous-input happy path. If multi-bucket, decade
  chapters are silently dropped and we log a note. (Future work
  re-introduces them inside one bucket.)
- The cleanup pass that deletes intermediate clip files now skips
  *every* path that appears in `job.compiledVideoPaths`, not just
  one.

### `PersonFinderView.swift`
- Replace the existing single "Show compiled video" / Finder reveal
  affordance in the results section with a `CompiledOutputsList`
  subview that renders one row per `CompiledOutput`:
  ```
  ▸ 01  h264_1080p2997_aac48k_2ch  ·  18 clips  ·  12:34  ·  340 MB   [Reveal] [Open]
  ```
- Job-level "Open All Compilations" button reveals the output folder
  in Finder.

### `tests/personfinder_cases.json`
- New case: `mixed_format_compilation` with a fixture set containing
  at least one DV clip and one H.264 clip in chronological order.
  Expected outcome: two `CompiledOutput` entries, ordinals `01` and
  `02`, with distinct `shortLabel` values.

## Edge cases

| Case | Behavior |
|---|---|
| Zero clips found | No buckets, no output, current "no clips" log line stays. |
| One clip found | One bucket, one output, ordinal `01`. |
| All clips identical params | One bucket, one output. Equivalent to today's happy path but lossless instead of transcoded. |
| Clip with no audio mixed into clips with audio | Different `hasAudio` → separate buckets. |
| Clip whose ffprobe fails | Logged as a warning, clip skipped, bucketing continues. |
| Bucket exceeds 30 minutes | Splits into `_NN_<label>` and `_NN+1_<label>`, same label. |
| Single bucket exceeds 4 GB on disk for `.mp4` | We still emit `.mp4`; ffmpeg handles 64-bit MP4 atoms automatically when needed. |
| Bucket includes clips with disagreeing extradata | Pre-flight check catches it; offending clip splits out into its own bucket. |
| User deletes a clip mid-compile | Bucket build sees the missing file at the ffprobe step → warning, skip. |

## Testing

1. **Unit-ish:** synthetic `pfClipEntry` arrays with hand-crafted
   `CompatKey` values (no actual ffprobe) to assert the bucketing
   algorithm produces the expected groupings, including:
   - all-same → 1 bucket
   - alternating A/B/A/B → 4 buckets
   - run length cap → splits at the cap
2. **Integration:** new manifest case in
   `tests/personfinder_cases.json` that points at a hand-built mixed
   fixture (one DV clip + one H.264 clip) and asserts:
   - two `CompiledOutput` entries
   - both files exist on disk
   - both files play (ffprobe duration > 0)
   - both files have ordinals `01` and `02` in filename order
3. **Manual smoke test:** run the existing big VHS+DV+phone job that
   reproduces today's bug and confirm it now produces N working
   compilations instead of one corrupt one.

## Future work

- Re-enable decade chaptering **inside** a single bucket (chapters
  are a per-output-file concept, so they map naturally to one
  bucket).
- Optional "Compile (single, transcoded)" button using the concat
  *filter* (`-filter_complex concat=n=N:v=1:a=1`), which can handle
  mixed inputs at the cost of re-encoding. Useful when the user
  wants one shareable file and accepts the quality hit.
- Switch clip extraction itself from `AVAssetExportSession` to
  `ffmpeg -c copy` so individual clips truly preserve source
  parameters. This would shrink the number of buckets, since clips
  from the same source would share keys.
- Persist `CompiledOutput` rows in the per-job log so reopening the
  app can re-display previously produced compilations without
  re-running anything.
- Expose `maxBucketSeconds` in Settings.
