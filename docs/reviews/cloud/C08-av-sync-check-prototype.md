Finding count: 5 | Verdict: works with limits

Brief: C08-av-sync-check-prototype | Source: main@4e3210e5 | Wall clock: ~85 | Files written: 3 (+ this report)
Finding count: 5 (REAL 5 / NEEDS-MAC 0 / NOISE 0)
Verdict: Comparing the improved copy's audio with the original's measures offset and drift to within 1-2 ms on every synthetic case, and calls "unsure" where it should. Two limits: audio vs audio is blind to a **picture** shift, and it reads a start cut as a 2 s lag. A cheap picture-vs-picture check (frame-difference envelope) fixes both, so the prototype ships with it.

## What was built
- **`scripts/av_sync/measure.py ORIGINAL IMPROVED [--no-video] [--max-lag-ms N]`** prints the JSON the brief asks for: `offset_ms`, `drift_ms`, `confidence`, `windows`, `verdict` (`in_sync` | `offset` | `drifting` | `unsure`). It also prints:
  - `video_offset_ms`: the same lag measured on the picture
  - `av_offset_ms`: the sound's lag relative to the improved copy's own picture, which is what a viewer sees
  - `trim_ms`: sound and picture moved together, so it is a cut
  - `duration_delta_ms`
  - `notes`
  - Sign: positive = the improved sound is **late**.
- **Method:**
  - ffmpeg decodes each file's first audio track to mono 8 kHz float.
  - Onset envelope at 1 kHz: energy in 8 ms frames, log, the half-wave-rectified rise, Gaussian-smoothed to σ = 8 ms.
  - Normalised FFT cross-correlation in 5 windows (≤ 15 s each) spread over the original, searching ±3 s. The peak is refined with a parabola.
  - Theil-Sen line through the confident windows, then a second pass that drops any window more than 40 ms off the line.
  - A window counts only with peak ≥ 0.20 **and** peak-to-sidelobe ratio ≥ 1.5. Fewer than 3 such windows, or a track quieter than −55 dBFS (95th-percentile frame RMS), gives `unsure`.
  - The picture check runs the same correlation on a frame-difference envelope (64×36 grey, each frame placed on a 100 Hz grid by its own timestamp).
  - numpy and scipy only, plus ffmpeg/ffprobe. Every subprocess has a timeout and an exit-code check.
- **`scripts/av_sync/fixtures.py OUTDIR [--duration S]`** builds the synthetic matrix with ffmpeg only:
  - **Original:** `testsrc2` with full-frame flashes, plus spoken-like bursts (`aevalsrc` warbling tone) over pink `anoisesrc` room tone, h264 + 48 kHz mono PCM.
  - The flashes and the bursts share one irregular gate (five incommensurate sines, thresholded), so the pattern never repeats within the search range.
  - **Improved:** each variant re-encodes and 2×-upscales the picture, as Topaz does, then applies one change.
- **`tests/test_av_sync.py`** (pytest): 21 tests. Here, 20 pass by default (~100 s, including fixture generation), and the 10-minute runtime test, which runs only with `AV_SYNC_LONG=1`, also passed. The file skips cleanly without numpy, scipy or ffmpeg.
- **Privacy:** only synthetic media generated at test time into pytest's temp dir. Nothing real was read, and no media is committed.

## Accuracy (60 s fixtures; tolerances ±10 ms offset, ±15 ms drift)

| Fixture | Expected | Measured | Pass |
|---|---|---|---|
| in sync | in_sync, 0 / 0 | in_sync, 0.0 / 0.0, conf 1.0 | ✓ |
| +40 ms (`adelay`) | offset +40 | offset **+40.0** | ✓ |
| −120 ms (`atrim`) | offset −120 | offset **−120.0** | ✓ |
| +500 ms | offset +500 | offset **+500.0** | ✓ |
| drift 0→200 ms / 60 s via **`atempo`** (brief) | drifting, 0 / +200 | drifting, **−10.7** / +201.4 | ✓ drift; offset outside ±10 by 0.7 ms, but see F1: `atempo` itself moves the sound ~10-21 ms early |
| drift 0→200 ms / 60 s via **`asetrate`** (a slow capture clock) | drifting, 0 / +200 | drifting, **+1.2** / +199.9 | ✓ |
| 48 k original vs 44.1 k improved | in_sync | in_sync, 0.0 / 0.0 | ✓ |
| PCM original vs AAC improved (.mp4) | in_sync | in_sync, 0.0 / 0.0, conf 1.0 | ✓ (ffmpeg honours AAC priming; see F4) |
| improved cut 2 s at the start | a cut, not a sync error | audio −2000.0, **picture −2000.0**, av 0.0 → **in_sync**, `trim_ms` −2000, duration −2000 | ✓ |
| same, audio only (`--no-video`) | — | **offset −2000** | as expected: audio alone cannot tell (F2) |
| near-silent original (−78 dBFS) | unsure | unsure, "too quiet to measure" | ✓ |
| mono original vs stereo improved | in_sync | in_sync, 0.0 / 0.0 | ✓ |
| **picture** 200 ms late, sound untouched (added) | sound 200 ms early vs picture | audio 0.0, picture +200.0, **av −200.0 → offset**; audio only says in_sync | ✓ (F3) |
| file with no audio track (added) | unsure | unsure, "a file has no audio track" | ✓ |
| unrelated recording, same length (added) | unsure | unsure (no window matches clearly) | ✓ |

## Runtime
Measured in this cloud container: 4 vCPUs, software decode, Linux, ffmpeg 6.1.

| Case | Time |
|---|---|
| 60 s file, audio + picture | 3.8-4.3 s (10 fixtures) |
| 60 s file, audio only | ~1.0 s (decode 0.4 s per file; envelope + correlation 0.03 s) |
| 10 min file, audio + picture | 39.6 s (first build, which resampled every frame to 100 fps: 70.7 s) |
| 10 min file, audio only | **9.6 s** (a 200 ms drift over 10 min: measured +200.3 ms, start −0.5 ms) |

Decoding is nearly all of the cost; the maths takes milliseconds. Decoding the 2× upscaled picture dominates, at about 70 % of the time. On the Mac, AVFoundation's hardware decode should make the picture check a fraction of this. That is unmeasured; the figures above are a ceiling, not a forecast.

## Findings (failure modes found)

### C08-F1 — P3 · REAL · `atempo` moves the whole track ~10-21 ms early by itself, so a time-stretch fixture has no "0 ms" ground truth
- **Evidence:** clicks every 7 s pushed through `atempo=60/60.2` land **21.4 ms early** (−20.1 to −21.4) relative to a pure stretch. The envelope method measures **−10.7 ms** at t = 0 on the burst fixture. The same 200 ms stretch done by resampling (`asetrate`, a slow sample clock) measures +1.2 ms, and its drift of 199.9 ms is exact.
- **What it means:** the measurer is right. `atempo`'s WSOLA overlap-add has a built-in lead. An improver that time-stretches sound the same way would really introduce a ~10-20 ms lead, and Verify should report it. It is under every perception threshold below.
- **Pinned by:** `test_atempo_drift_is_measured_but_atempo_itself_shifts_the_start` (drift strict; start offset −25..+10 ms). The `clockdrift200` fixture carries the strict ±10 ms check.

### C08-F2 — P2 · REAL · Audio vs audio alone reports a start cut as a lag (−2000 ms "offset")
- **Evidence:** `trim2s` with `--no-video` gives `verdict: offset`, `offset_ms: −2000`.
- **How to tell a cut from a sync error** (implemented):
  1. The picture check measures the **same** lag on the picture (−2000 ms), so the sound relative to the picture (`av_offset_ms`) is 0. That gives `trim_ms`, verdict `in_sync`, and a note.
  2. Supporting evidence: the improved file is shorter by the same amount (`duration_delta_ms` −2000).
- A sync error moves only the sound: picture ≈ 0 and duration ≈ unchanged (`plus500`: picture 0.0, `trim_ms` null).
- **Limit:** when the picture check is inconclusive (a static picture), the tool falls back to audio only and says so in `notes`. A large offset with an equal duration loss should then be worded "may be a cut", not "out of sync".
- **Pinned by:** `test_trim_is_told_apart_from_a_sync_error`, `test_a_sound_shift_is_not_mistaken_for_a_trim`, `test_audio_only_check_still_reports_the_raw_lag`.

### C08-F3 — P2 · REAL · The brief's question answered: yes, a picture-vs-picture check catches a picture shift that audio vs audio cannot see
- **Evidence:** the `video_late200` fixture (first frame held 200 ms, sound untouched). Audio vs audio says `in_sync`, 0.0 ms. The picture check measures +200.0 ms, so `av_offset_ms` is −200 (the sound now leads the picture by 200 ms) and the verdict is `offset`.
- **Why it matters for Topaz:** an improver that re-times frames (frame-rate conversion, dropped or held leading frames) can move the picture while the sound is copied untouched. That is a real sync error that audio vs audio passes as clean.
- **Recommendation:** keep both checks. The picture check is the expensive half, but it is the only one that sees this class.
- **Pinned by:** `test_a_picture_shift_is_caught_only_by_the_picture_check`.

### C08-F4 — P3 · REAL · AAC priming: ffmpeg compensates (0.0 ms measured); the Swift port must prove AVFoundation does too
- AAC adds 1024-2112 samples of encoder delay (21-44 ms at 48 kHz). ffmpeg reads the MP4 edit list and skips it, so PCM vs AAC measures 0.0 ms here. If a decoder ignored the edit list, every AAC-improved file would read ~+21-44 ms late: a false warning just above the "early" threshold region.
- **Swift check:** the same fixture pair through `AVAssetReader` must also measure 0 ± 5 ms. Make it the first Swift test.

### C08-F5 — P3 · REAL · The ±3 s search range bounds what it can see; outside it the result is `unsure`, never a wrong number
- Windows sit inside the original, and lags whose target span falls more than 10 % outside the improved file are excluded. A cut or offset larger than `--max-lag-ms` (default 3000) finds no clear peak, so the result is `unsure`, not a confident wrong lag (fail-safe).
- **For bigger cuts:** add a coarse first pass (whole-file envelope at 100 Hz, ±60 s) that centres the fine search. It costs milliseconds.

## Recommended thresholds
Using **ITU-R BT.1359-1 (1998)**:
- **Detectability:** sound **early** by 45 ms, or **late** by 125 ms.
- **Acceptability:** early by 90 ms, or late by 185 ms.
- Note ITU's sign convention: positive = sound leads. This tool's `av_offset_ms` is positive = sound **late**.
- EBU R37 (a +40 / −60 ms broadcast chain budget) is stricter than a home archive needs.

Apply to `av_offset_ms` (or `offset_ms` when the picture check is unavailable). For a drifting file, apply to the **worst point**: the larger of |offset| and |offset + drift| on each side.

| Level | Sound late (av > 0) | Sound early (av < 0) | Verify says |
|---|---|---|---|
| in sync | < 20 ms | > −20 ms | nothing (inside the method's error budget, about ±2 ms measured, padded for real media) |
| note | 20-125 ms | −20 to −45 ms | "sound N ms late/early, below what most people notice" (informational) |
| **warn** | ≥ 125 ms | ≤ −45 ms | "sound N ms late/early: noticeable on lip sync" |
| **point to Repair…** | ≥ 185 ms | ≤ −90 ms | warn + Repair… (shift the sound by −offset; for drift, a linear time-stretch) |
| unsure | — | — | "couldn't measure sync (reason)", never a warning |

- **Drift note:** a 0→200 ms drift over 60 s starts in sync and ends past the Repair line. Its fix is a stretch, not a shift. Report both numbers.

## Plan for porting to Swift (inside Verify)
1. **Where:** a check on records with `derivedFrom` (Import… links improved → original), run when Verify visits the improved copy and the original is online. Batches over many files are an MFO job (CLAUDE.md long-operations rule): START / progress / OUTCOME lines, one row, per-file detail.
2. **Audio decode:** `AVAssetReader` + `AVAssetReaderAudioMixOutput` with `outputSettings` of linear PCM Float32, `AVSampleRateKey: 8000`, `AVNumberOfChannelsKey: 1`. AVFoundation downmixes and resamples; one reader per file, off the main actor.
3. **Envelope (Accelerate):** frame energy with `vDSP.square` + a running sum (`vDSP_vswsum` with hop 8), `vForce.log10`, a first difference with ReLU (`vDSP.subtract`, `vDSP.clip`), and a Gaussian with `vDSP.convolve` (σ = 8 samples).
4. **Correlation:** per window, `vDSP.FFT` (or `vDSP_DFT_zrop`) on zero-padded power-of-two buffers. Multiply by the conjugate, inverse, and divide by the sliding norm (prefix sums of the squared target, as in `_ncc_lags`). A direct `vDSP_conv` (15 k × 6 k lags ≈ 90 M multiply-adds per window) is also fine on Apple Silicon. Parabolic refinement and Theil-Sen are a few lines of plain Swift.
5. **Picture envelope:** `AVAssetReaderTrackOutput` with `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`. Read every 10th luma pixel per row and column from plane 0, compute the mean |Δ| per frame, and place it at the sample buffer's PTS on a 100 Hz grid. Hardware decode, no scaling pass.
6. **Types (playbook "decision with several outcomes"):**
   - `struct SyncMeasurement { offsetMs, driftMs, videoOffsetMs?, avOffsetMs?, trimMs?, confidence }`
   - `enum SyncVerdict { case inSync, offset(ms), drifting(startMs, driftMs), trimmed(ms), unsure(reason) }`
   - The threshold table above as one pure function `SyncVerdict.advice → (level, sentence, offersRepair)`.
7. **Persist:** additive fields on the improved record (`avSyncOffsetMs`, `avSyncDriftMs`, `avSyncCheckedAt`) or a line in `videoVerifyNote`. A schema addition is **Rick's call** (CLAUDE.md escalation list).
8. **Tests:** reuse this Python matrix as the **oracle**. Generate the same fixtures with ffmpeg (`test_*` prefix, CLAUDE.md media matrix), run the Swift measurer, and assert agreement with `measure.py` within ±3 ms. Add F4's AAC check, a 100k-record scan budget for "which records need a check" (scale dimension), and the near-silent and unrelated `unsure` cases.

## Not covered
- **Real Topaz output:** frame-rate conversion (25 → 50/60 fps) and its exact frame timing were not modelled beyond the 2× upscale and the held-frame case. The first real file pair on the Mac is the next test (run `measure.py` on it; nothing to commit).
- **Non-linear drift** (a speed that wanders): the line fit flags it only through dropped windows. Five windows is the brief's number; more windows would resolve it.
- **A static picture:** the picture check reports itself inconclusive, as it is designed to, but no fixture pins that path.
- **CI:** the Linux job installs numpy but not scipy or ffmpeg, so these tests **skip** there. Running them in CI needs `scipy` added to the pip line and an `apt-get install ffmpeg` step, about 1-2 min including fixture generation. Rick's call.

## Blockers & environment
- **numpy, scipy and pytest were not installed** in the container's Python, and the repo denies `pip install`. The repo's allowlist does permit a virtualenv's pip, so I created a throwaway venv in the session scratchpad (outside the repo, not committed) and installed numpy 2.4.6, scipy 1.17.1 and pytest 9.1.1 from PyPI there. Nothing in the repo depends on that venv.
- **Branch:** the brief asks for `cloud/C08-av-sync-check`. This session may push only to its designated branch, so the work is on `claude/compassionate-babbage-kn9mbj`.
- ffmpeg 6.1.1 was present on PATH. No other failures.
