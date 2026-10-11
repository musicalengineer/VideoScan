# C08: A/V sync check for improved versions, a Python prototype (GH #309)

Brief id: `C08-av-sync-check-prototype`. Inherits every rule in `docs/briefs/cloud/README.md`.
Output:
- the prototype in `scripts/av_sync/`;
- its tests in `tests/test_av_sync.py` (pytest);
- ONE report at `docs/reviews/cloud/C08-av-sync-check-prototype.md`.

Push to `cloud/C08-av-sync-check` if your session allows it; otherwise name the branch under
"Blockers". Time box: about 90 minutes.

## Why
Rick cleans up old home videos in Topaz and re-imports them. Import… links the improved file to
its original (`derivedFrom`). Sometimes the improved file comes back with its sound out of sync.
We want Verify to say, as far as it can: "the sound in the improved copy is X ms late, and
drifts Y ms over the length", and point to Repair… when that matters. Nothing in the app checks
sync today. This brief proves the measurement before any Swift is written.

## Privacy (hard rule)
Use ONLY synthetic media that you generate with ffmpeg: `testsrc2`, `sine`, `anoisesrc`,
and spoken-like bursts from `aevalsrc`. No real or downloaded family media, and no media
committed to git. Generate fixtures at test time into a temp dir.

## Build
1. `scripts/av_sync/measure.py ORIGINAL IMPROVED`. It prints JSON:
   - `offset_ms`, the constant lag of IMPROVED's audio vs ORIGINAL's audio;
   - `drift_ms`, the change in lag from the start window to the end window;
   - `confidence`, between 0 and 1;
   - `windows`, the per-window lag and correlation peak;
   - `verdict`: `in_sync` | `offset` | `drifting` | `unsure`.

   **Method:** decode both audio tracks with ffmpeg to mono 8 kHz float. Take an onset or
   energy envelope. Cross-correlate (FFT) in about 5 windows spread across the file. Use a
   robust median offset, plus a linear fit for drift. Mark low peak-to-sidelobe ratio as `unsure`.
   Only numpy and scipy, plus ffmpeg on PATH.

   **Why audio vs audio:** improvers (Topaz) re-encode the picture, so comparing the original's
   audio with the improved file's audio is the reliable signal. Also note in the report whether
   a picture-vs-picture check (frame-difference envelope) would catch a *video* shift that
   audio vs audio cannot.
2. **Fixtures**, built with ffmpeg at test time:
   - in sync;
   - +40 ms, −120 ms and +500 ms offsets;
   - linear drift of 0→200 ms over 60 s, via `atempo`;
   - different sample rate (48k vs 44.1k);
   - re-encoded audio (AAC vs PCM);
   - improved file trimmed 2 s at the start, where the offset is a trim, not a sync error, and
     the report should say how to tell those apart;
   - silent or near-silent original, which should give `unsure`;
   - mono vs stereo.
3. **pytest:** for every fixture, assert verdict, offset within ±10 ms and drift within ±15 ms,
   or `unsure` where expected. Also record the runtime on a 60 s and a 10 min fixture.

## Report
- An accuracy table: fixture · expected · measured · pass.
- Runtime numbers.
- Failure modes found.
- Recommended thresholds for "warn" and for "point to Repair…". Lip sync is noticeable around
  45 ms when the sound is early and 125 ms when it is late (ITU-R BT.1359); cite what you used.
- A short plan for porting it to Swift (AVFoundation decode + Accelerate vDSP correlation)
  inside Verify.
- First line: `Finding count: N | Verdict: <works / works with limits / doesn't>`.
