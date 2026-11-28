# AV Sync Analysis — design (phase 1: a processed file against its original)

Status: built (phase 1) — 2026-11-27, merge ea94e7f1e. Result storage waits for Rick's schema decision (results in memory and the log meanwhile); phase 2 (no original) and phase 3 (repair) not built.

*Rick said "design it" 2026-11-27. Problem statement and first ideas: Rick's notes `lip_sync.md` (in his checkout, not yet in git). This doc replaces their
"Proposed Solution" for phase 1. Deleted when built (CLAUDE.md); git keeps it.*

## 1. What it answers

"Did processing (Topaz upscale, repair, re-encode) move the sound against the picture?" — for a processed file whose
**original is known** (a `derivedFrom` lineage link, a confirmed pair, or chosen by Rick in the verb's sheet). It reports
measured facts in plain words, per CLAUDE.md rule 1 and DECISIONS ("facts at the gate, never a probability"):

- **In sync** — every measured window within the thresholds (§4): "in sync: sound within 12 ms of the picture across 41 of 44
  windows (3 could not be measured: no movement)".
- **Offset** — a constant shift: "sound 80 ms late against the picture, the same through the whole file".
- **Drift** — the shift changes steadily: "sound drifts from 0 to 160 ms late over 58 minutes".
- **Jump** — a step change: "sound jumps 200 ms late at 23:41 (frames dropped or added there)".
- **Could not measure** — no usable evidence: silence, a static picture, or the two files share too little. Never "in sync".

A ranking number (worst |offset|) may order a review list; it is never the verdict.

Phase 2 (not here): a file with **no** original — needs a face/mouth model (SyncNet-style, local only, rule 13), works only on
footage of people talking; research first (BACKLOG). Phase 3: repair (§8).

## 2. The method: differential, not lip reading

For each window *i* of the processed file's timeline:

- **audio lag** Δa = the time offset that best aligns the processed file's sound to the original's sound;
- **picture lag** Δv = the time offset that best aligns the processed file's picture-motion signal to the original's;
- **net sync shift** sᵢ = Δa − Δv.

A trim that removes the same span from both sound and picture moves Δa and Δv equally: s = 0, harmless. Only a shift of the
sound *relative to* the picture survives. This needs no faces and no speech — any sound with structure and any picture with
movement will do — and the signals are tiny.

**Sign convention:** s > 0 means the sound comes **early** relative to the picture; s < 0 means **late**. Every word shown says
"early" or "late", never a signed number alone.

## 3. Signals and how they are made

**Decode through the existing ffmpeg pipeline**, not AVFoundation: much of the archive (DV in AVI, MXF, Matroska, old codecs)
does not open in AVFoundation, and VideoScan already decodes everything through ffmpeg with an authenticated log
(`AudioPCMDecoder`, the Verify Audio / Check Media passes). One decode per file produces both signals:

- **Sound:** mono 8 kHz float PCM (`AudioPCMDecoder`, existing), then an **onset envelope**: |PCM| → 5 ms frames → log energy →
  first difference, half-wave rectified. Correlating envelopes, not raw samples, survives Topaz-style re-encoding, sample-rate
  changes, gain changes and mono/stereo folds. 1 h ≈ 720k envelope samples (2.9 MB).
- **Picture:** ffmpeg scales each frame to 32×18 grey **inside the decoder** (`scale=32:18,format=gray`), output as raw frames
  with their PTS; the signal is the mean absolute frame-to-frame difference (motion energy), plus a **cut detector** (large
  spikes). Resampled onto the same 5 ms grid by PTS (handles VFR and frame-rate changes such as 24→60 interpolation: the
  processed file's interpolated frames add small values between the original's peaks; cuts and motion onsets still align).
  1 h at 60 fps: 216k frames × 576 B = 124 MB streamed, never held whole.

Memory per file pair: a few tens of MB. Cost: decode-bound (scaling inside the decoder keeps it far faster than real time on
the M4/Ultra). No GPU, MLX or ANE needed for phase 1 — `Accelerate` (vDSP FFT) for correlation.

## 4. Thresholds (asymmetric, tunable)

People notice sound that arrives **early** much sooner than sound that arrives **late**. ITU-R BT.1359 gives detectability at
about **+45 ms** (sound early) and **−125 ms** (sound late), acceptability at about +90 / −185 ms; broadcast chains aim tighter
(EBU R37 about +40 / −60 ms). Home video starting point, both adjustable in Settings:

| verdict | rule (worst measured window, after outlier rejection) |
|---|---|
| in sync | −60 ms ≤ s ≤ +30 ms in every measured window, drift < 20 ms over the file |
| offset / drift / jump (flag for review) | outside that band — said in words, with the time and size |
| could not measure | fewer than 3 measured windows, or < 30 % of the file measurable |

The numbers live in one `AVSyncPolicy` struct (like `AudioMatchPolicy`), versioned, so a re-measure (DECISIONS 2026-11-25) can
run when the policy changes.

## 5. Windows, correlation, confidence

1. **Coarse alignment first:** `AudioFingerprintMatcher` (existing) gives the whole-file sound offset at 64 ms resolution and
   whether the processed file is the same recording at all. No match → "could not measure: these two files do not share the
   same sound" (never a guess).
2. **Windows:** 20 s every 10 s across the overlap (an hour → ~360 windows; a 3-minute clip → 17).
3. **Per window:** normalised FFT cross-correlation of the envelopes within ±250 ms of the coarse offset → Δa; same for motion →
   Δv; parabolic peak interpolation → ~1 ms resolution on a 5 ms grid.
4. **Confidence per window:** peak height and peak-to-second-peak ratio for each signal. A window is **measured** only when both
   are confident; otherwise "not measured" with the reason (silent, static picture, ambiguous — e.g. a periodic beat).
5. **Across windows:** median offset; robust line fit of sᵢ against time → drift; change-point test on sᵢ → jumps (step
   larger than 2× the window jitter, held for ≥ 3 windows).

## 6. Where it lives (architecture)

- **Core:** `AVSyncAnalyzer` (pure: signals in → `AVSyncReport` out), `AVSyncSignals` (envelope, motion, resampling),
  `AVSyncPolicy`. Pure functions, unit-testable without media.
- **App:** one MFO job **"Check A/V Sync"** (progress, Pause/Stop, START/OUTCOME through the one sink), launched from the
  Catalog row menu (Analyze ▸ Check A/V Sync…) for one or more selected processed files; the sheet shows the original it will
  compare against (from lineage) and lets Rick choose one when none is known. Later: the background cycler, for files with a
  known original that were never checked.
- **Storage:** the result as an observation/evidence row keyed by **both** whole-file digests (processed, original) and the
  policy version — no schema change if the existing analysis-results/observation table fits; if a new table is needed, STOP
  and ask Rick (rule 6). Shown in Media Info and the Inspector as a "Sound & picture timing" line.
- **One engine** (rule 4): the menu verb and the background cycler call the same job.

## 7. Tests (CLAUDE.md rules 7–8)

- **Synthetic truth (TDD):** generate pairs with ffmpeg from one source — `-itsoffset` for constant offsets of −200…+200 ms,
  `atempo`/`asetrate` for drift, a cut-and-splice for a jump, `minterpolate`/fps change for interpolation, a re-encode for
  codec change. The analyzer must recover each within ±5 ms (offset), ±10 ms/min (drift), ±1 window (jump time), and say
  "in sync" for an unchanged re-encode.
- **Honest negatives:** silence, a static slide, a tone, a periodic metronome → "could not measure", never "in sync".
- **Media matrix:** mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv.
- **Scale:** a 2-hour pair inside a time budget on the M4; memory bounded (streaming).
- **Real data:** then 3–5 of Rick's Topaz pairs (local only), compared with what Rick hears — the only manual step, a spot check.

## 8. Repair (phase 3, not built now)

A constant offset → a lossless remux with the sound shifted (no re-encode). Drift → resample the sound (re-encode the sound
only). Always a new file through the existing Repair engine; the original is never touched; the result is re-checked with this
same analyzer before it is offered.

## 9. Build order (phase 1)

1. Core signals + analyzer + policy, with synthetic-pair tests (pure Swift + ffmpeg fixtures).
2. The MFO job and the verb, the sheet, Media Info / Inspector line; storage (or stop for Rick if a table is needed).
3. Media matrix, scale, honest negatives; then a spot check on real Topaz pairs.
