# Video LLM benchmarks

*Written by `tools/video-llm-bench/bench.py summarize`; overwritten on every run, never appended (CLAUDE.md). Aggregates only — per-clip results stay in `.scratch/` (DECISIONS 2026-10-26). Design: `docs/design/video_llm_lab_2026_10_30.md` §4.*

## Approach `a0-py` — baseline (today's 3B captioner, stills, the three app prompts)

| Run | Value |
|---|---|
| generated | 2026-10-31T01:52:01+00:00 |
| run id | 20261030T201824-a0-py |
| model | `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` |
| weights sha256 (first 12) | `0ab6cb1e8958` |
| sampler | `stills-5-middle90` (5 frames/clip, 448×448 letterboxed, middle 90 %) |
| prompts | date/scene/text as in `CaptionRunner.swift`; sha256 first 12: date `8ff71ebc71ae`, scene `cbe72f16aa0f`, text `f2e910929721` |
| host | RicksUltra.local · macOS-27.2-arm64-arm-64bit |
| mlx-vlm / mlx | 0.5.0 / 0.31.2 |
| git | `406d6c208cb6` |
| corpus hash (first 12) | `10295f9e9b14` |
| run state | finished |
| clips | 327 done · 0 partial · 24 unreadable · ERA scored 248/272 · OCR scored 63/63 |

*unreadable* = no frame could be decoded by ffmpeg (QuickTime reference movies whose media is on an unmounted volume, zero-length files); nothing any approach could see, so they are excluded from the tables rather than scored as "no answer".

### Cost

| Metric | Value |
|---|---|
| model load | 1.4 s |
| s / frame (3 prompts) | 0.91 |
| s / generation | 0.30 |
| ffmpeg rip s / frame | 0.13 |
| peak RSS | 3.73 GB |
| frames · generations · errors | 1506 · 4518 · 0 |

### ERA — best single year vs truth

Rule: the year of every parsed calendar date in the date/text answers counts 3; every explicit 4-digit year in any answer counts 1; a decade mention ("1990s" → 1995, early/mid/late → +2/+5/+7) counts 1; the heaviest year wins (tie → median). A clip whose answers yield no year is **no answer** and is excluded from MAE; its rate is reported, not invented. Truth: `user_dates` (Rick) or `files.embedded_created_at` for camera-native codecs only (ProRes/FFV1/DNxHD stamps are transfers).

| Group | n | answered | no answer | MAE y | median y | ±5 y (answered) | ±5 y (all) |
|---|---|---|---|---|---|---|---|
| **all** | 248 | 45 | 82% | 20.2 | 7.0 | 47% | 8% |
| family: camera | 176 | 19 | 89% | 38.5 | 41.0 | 21% | 2% |
| family: rick-dated | 72 | 26 | 64% | 6.9 | 2.0 | 65% | 24% |
| decade: 1960s | 4 | 4 | 0% | 10.0 | 10.0 | 0% | 0% |
| decade: 1980s | 14 | 6 | 57% | 20.0 | 19.0 | 33% | 14% |
| decade: 1990s | 40 | 13 | 68% | 0.9 | 0.0 | 92% | 30% |
| decade: 2000s | 53 | 16 | 70% | 32.9 | 15.0 | 38% | 11% |
| decade: 2010s | 27 | 2 | 93% | 48.0 | 48.0 | 0% | 0% |
| decade: 2020s | 110 | 4 | 96% | 29.0 | 35.0 | 25% | 1% |
| stratum: camera/2000s/dvvideo | 9 | 3 | 67% | 31.7 | 26.0 | 0% | 0% |
| stratum: camera/2000s/h263 | 1 | 1 | 0% | 2.0 | 2.0 | 100% | 100% |
| stratum: camera/2000s/h264 | 9 | 2 | 78% | 34.0 | 34.0 | 0% | 0% |
| stratum: camera/2000s/mjpeg | 11 | 2 | 82% | 55.5 | 55.5 | 50% | 9% |
| stratum: camera/2000s/mpeg4 | 5 | 1 | 80% | 64.0 | 64.0 | 0% | 0% |
| stratum: camera/2000s/svq3 | 8 | 4 | 50% | 44.8 | 38.0 | 25% | 12% |
| stratum: camera/2010s/h264 | 16 | 1 | 94% | 50.0 | 50.0 | 0% | 0% |
| stratum: camera/2010s/hevc | 1 | 0 | 100% | — | — | — | 0% |
| stratum: camera/2010s/mjpeg | 4 | 0 | 100% | — | — | — | 0% |
| stratum: camera/2010s/mpeg4 | 1 | 1 | 0% | 46.0 | 46.0 | 0% | 0% |
| stratum: camera/2010s/svq3 | 3 | 0 | 100% | — | — | — | 0% |
| stratum: camera/2020s/dvvideo | 4 | 0 | 100% | — | — | — | 0% |
| stratum: camera/2020s/h263 | 1 | 0 | 100% | — | — | — | 0% |
| stratum: camera/2020s/h264 | 13 | 2 | 85% | 14.5 | 14.5 | 50% | 8% |
| stratum: camera/2020s/hevc | 78 | 2 | 97% | 43.5 | 43.5 | 0% | 0% |
| stratum: camera/2020s/mjpeg | 12 | 0 | 100% | — | — | — | 0% |
| stratum: rick-dated/1960s | 4 | 4 | 0% | 10.0 | 10.0 | 0% | 0% |
| stratum: rick-dated/1980s | 14 | 6 | 57% | 20.0 | 19.0 | 33% | 14% |
| stratum: rick-dated/1990s | 40 | 13 | 68% | 0.9 | 0.0 | 92% | 30% |
| stratum: rick-dated/2000s | 10 | 3 | 70% | 2.3 | 3.0 | 100% | 30% |
| stratum: rick-dated/2010s | 2 | 0 | 100% | — | — | — | 0% |
| stratum: rick-dated/2020s | 2 | 0 | 100% | — | — | — | 0% |

### OCR — burned-in date vs the catalog's verdict

Truth: the `DateTriangulator` on-screen date in `inferred_dates.reason` when present, else the majority parsed date of the catalog's existing `ocrDate` captions. *any-frame exact*: some frame's date answer parses to the truth date. *majority exact*: the most frequent parsed date equals it. *schema-valid*: at least one date answer contained a parseable date. *degenerate*: the "!!!!…" failure mode.

| Group | n | any-frame exact | majority exact | year match | schema-valid | date frames | frames with a date | degenerate frames |
|---|---|---|---|---|---|---|---|---|
| **all** | 63 | 92% | 90% | 97% | 98% | 315 | 63% | 0% |
| stratum: ocr/dvvideo | 6 | 100% | 83% | 83% | 100% | 30 | 60% | 0% |
| stratum: ocr/ffv1 | 2 | 100% | 100% | 100% | 100% | 10 | 60% | 0% |
| stratum: ocr/h264 | 14 | 79% | 79% | 100% | 100% | 70 | 40% | 0% |
| stratum: ocr/hevc | 13 | 85% | 85% | 92% | 92% | 65 | 58% | 0% |
| stratum: ocr/mjpeg | 7 | 100% | 100% | 100% | 100% | 35 | 100% | 0% |
| stratum: ocr/prores | 21 | 100% | 100% | 100% | 100% | 105 | 70% | 1% |

## Approach `a1-py` — chronological windows + strict JSON contract (same model and weights)

**A1 vs A0**

1. **Answered rate:** A0 18% → A1 98% of 248 readable ERA clips; MAE 20.2 → 22.8 y where answered; ±5 y of all clips 8% → 19%; truth inside A1's range 33% of answered (median width 20.0 y).
2. **OCR (same `date` prompt):** any-frame exact 92% → 86%, majority exact 90% → 86%, year match 97% → 92% (A1 reads 12 frames per OCR clip vs A0's 5, which favours any-frame; majority is the fairer comparison).
3. **Cost:** 5.2 s/clip (A0) → 6.0 s/clip (A1, era + roomFeatures windows plus OCR date frames); 1.26 s per multi-image window generation; peak RSS 3.73 → 3.81 GB.

| Run | Value |
|---|---|
| generated | 2026-10-31T01:52:01+00:00 |
| run id | 20261030T212056-a1-py |
| model | `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` |
| weights sha256 (first 12) | `0ab6cb1e8958` |
| sampler | `windows-3x6-max60s-middle90` (≤ 3 windows — start / middle / end of the middle 90 %, each ≤ 60 s, 6 frames each shown together in one prompt; a middle-90 % span under 30 s gets one window) |
| prompts | era / roomFeatures strict JSON (§3.3), OCR `date` verbatim from A0; sha256 first 12: date `8ff71ebc71ae`, era `d693a62a8602`, roomFeatures `29a786746630` |
| decoding | fail-closed mirror of `ContractDecoder`: raw text must be exactly one JSON object; unknown key, wrong type, null, missing key, wrong family, year outside 1900…2100, reversed range → `schemaInvalid`; never repaired |
| host | RicksUltra.local · macOS-27.2-arm64-arm-64bit |
| mlx-vlm / mlx | 0.5.0 / 0.31.2 |
| git | `8aece0152971` |
| corpus hash (first 12) | `10295f9e9b14` |
| run state | finished |
| clips | 327 done · 0 partial · 24 unreadable · ERA scored 248/272 · OCR scored 63/63 |

### Cost

| Metric | Value |
|---|---|
| model load | 1.4 s |
| s / clip (all generations + ffmpeg) | 6.0 |
| s / frame (all generations ÷ frames ripped) | 0.38 |
| s / window generation (multi-image, era or roomFeatures) | 1.26 |
| s / OCR date generation (one frame) | 0.14 |
| ffmpeg rip s / frame | 0.12 |
| peak RSS | 3.81 GB |
| frames · windows · window gens · date gens · errors | 3629 · 510 · 1020 · 726 · 0 |

### Schema-valid rate per family (per window)

| Family | windows | schema-valid | rate | invalid, by reason |
|---|---|---|---|---|
| era | 510 | 501 | 98% | cue kind not in vocabulary 5, not JSON (prose, fence, truncated, trailing text) 3, missing key 1 |
| roomFeatures | 510 | 413 | 81% | wrong family 95, not JSON (prose, fence, truncated, trailing text) 2 |

### ERA — yearRange vs truth

Rule: a schema-valid `era` window is an answer. Per clip, range = [median FROM, median TO] over its valid windows; point estimate = the range midpoint (MAE, ±5 y). *inside* = truth year within the range, inclusive. A clip with no valid window is **no answer** (excluded from MAE, counted in the rate). Truth as for A0.

| Group | n | answered | no answer | MAE y | median y | ±5 y (answered) | ±5 y (all) | inside range (answered) | inside range (all) | median width y |
|---|---|---|---|---|---|---|---|---|---|---|
| **all** | 248 | 242 | 2% | 22.8 | 20.0 | 20% | 19% | 33% | 32% | 20.0 |
| family: camera | 176 | 170 | 3% | 29.9 | 24.0 | 4% | 4% | 12% | 12% | 20.0 |
| family: rick-dated | 72 | 72 | 0% | 5.9 | 5.0 | 57% | 57% | 81% | 81% | 10.0 |
| decade: 1960s | 4 | 4 | 0% | 1.2 | 0.0 | 100% | 100% | 100% | 100% | 10.0 |
| decade: 1980s | 14 | 14 | 0% | 2.6 | 1.0 | 79% | 79% | 86% | 86% | 10.0 |
| decade: 1990s | 40 | 40 | 0% | 5.0 | 5.0 | 52% | 52% | 82% | 82% | 10.5 |
| decade: 2000s | 53 | 53 | 0% | 17.7 | 18.0 | 15% | 15% | 36% | 36% | 10.0 |
| decade: 2010s | 27 | 26 | 4% | 21.2 | 16.0 | 4% | 4% | 27% | 26% | 20.0 |
| decade: 2020s | 110 | 105 | 5% | 36.0 | 33.0 | 3% | 3% | 4% | 4% | 20.0 |
| stratum: camera/2000s/dvvideo | 9 | 9 | 0% | 16.1 | 13.0 | 22% | 22% | 44% | 44% | 20.0 |
| stratum: camera/2000s/h263 | 1 | 1 | 0% | 8.0 | 8.0 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: camera/2000s/h264 | 9 | 9 | 0% | 20.6 | 14.0 | 0% | 0% | 56% | 56% | 20.0 |
| stratum: camera/2000s/mjpeg | 11 | 11 | 0% | 21.6 | 23.0 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: camera/2000s/mpeg4 | 5 | 5 | 0% | 24.2 | 18.0 | 20% | 20% | 20% | 20% | 20.0 |
| stratum: camera/2000s/svq3 | 8 | 8 | 0% | 20.1 | 19.0 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: camera/2010s/h264 | 16 | 15 | 6% | 20.5 | 16.0 | 7% | 6% | 20% | 19% | 20.0 |
| stratum: camera/2010s/hevc | 1 | 1 | 0% | 68.0 | 68.0 | 0% | 0% | 0% | 0% | 100.0 |
| stratum: camera/2010s/mjpeg | 4 | 4 | 0% | 10.0 | 10.0 | 0% | 0% | 100% | 100% | 20.0 |
| stratum: camera/2010s/mpeg4 | 1 | 1 | 0% | 56.0 | 56.0 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: camera/2010s/svq3 | 3 | 3 | 0% | 14.3 | 11.0 | 0% | 0% | 0% | 0% | 20.0 |
| stratum: camera/2020s/dvvideo | 4 | 4 | 0% | 34.2 | 35.5 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: camera/2020s/h263 | 1 | 1 | 0% | 33.0 | 33.0 | 0% | 0% | 0% | 0% | 20.0 |
| stratum: camera/2020s/h264 | 13 | 13 | 0% | 39.7 | 35.0 | 8% | 8% | 8% | 8% | 20.0 |
| stratum: camera/2020s/hevc | 78 | 73 | 6% | 35.9 | 31.0 | 3% | 3% | 4% | 4% | 20.0 |
| stratum: camera/2020s/mjpeg | 12 | 12 | 0% | 34.2 | 38.0 | 0% | 0% | 0% | 0% | 10.0 |
| stratum: rick-dated/1960s | 4 | 4 | 0% | 1.2 | 0.0 | 100% | 100% | 100% | 100% | 10.0 |
| stratum: rick-dated/1980s | 14 | 14 | 0% | 2.6 | 1.0 | 79% | 79% | 86% | 86% | 10.0 |
| stratum: rick-dated/1990s | 40 | 40 | 0% | 5.0 | 5.0 | 52% | 52% | 82% | 82% | 10.5 |
| stratum: rick-dated/2000s | 10 | 10 | 0% | 7.9 | 7.0 | 50% | 50% | 90% | 90% | 20.0 |
| stratum: rick-dated/2010s | 2 | 2 | 0% | 18.0 | 18.0 | 0% | 0% | 0% | 0% | 15.0 |
| stratum: rick-dated/2020s | 2 | 2 | 0% | 31.5 | 31.5 | 0% | 0% | 0% | 0% | 25.0 |

### OCR — A0's `date` prompt on the A1 window frames

Same truth and columns as A0. A1 reads every window frame (up to 3 × N per clip) instead of 5 stills.

| Group | n | any-frame exact | majority exact | year match | schema-valid | date frames | frames with a date | degenerate frames |
|---|---|---|---|---|---|---|---|---|
| **all** | 63 | 86% | 86% | 92% | 92% | 726 | 48% | 1% |
| stratum: ocr/dvvideo | 6 | 100% | 100% | 100% | 100% | 108 | 57% | 0% |
| stratum: ocr/ffv1 | 2 | 100% | 100% | 100% | 100% | 36 | 67% | 0% |
| stratum: ocr/h264 | 14 | 57% | 57% | 86% | 86% | 192 | 28% | 1% |
| stratum: ocr/hevc | 13 | 85% | 85% | 85% | 85% | 126 | 37% | 0% |
| stratum: ocr/mjpeg | 7 | 100% | 100% | 100% | 100% | 42 | 100% | 0% |
| stratum: ocr/prores | 21 | 95% | 95% | 95% | 95% | 222 | 54% | 3% |

### roomFeatures

No ground truth yet (design §4: needs Rick's place labels); reported for shape only. Vocabulary = distinct lower-cased feature strings over schema-valid windows. The top-20 list prints only strings of lowercase letters, spaces and hyphens; any string with a capital, digit or punctuation is counted but never printed.

| Metric | Value |
|---|---|
| schema-valid windows | 413 of 510 (81%) |
| feature items · distinct vocabulary | 3160 · 384 |
| items not printable (capital / digit / punctuation) | 0 |
| setting | indoor 293, outdoor 120 |

| # | feature | occurrences (a window may repeat an item) |
|---|---|---|
| 1 | furniture | 603 |
| 2 | floor | 162 |
| 3 | wall | 123 |
| 4 | trees | 115 |
| 5 | curtains | 102 |
| 6 | flooring | 102 |
| 7 | ceiling | 66 |
| 8 | chair | 57 |
| 9 | wooden floor | 51 |
| 10 | sky | 50 |
| 11 | window | 45 |
| 12 | table | 44 |
| 13 | lighting | 42 |
| 14 | sand | 41 |
| 15 | door | 40 |
| 16 | wood floor | 38 |
| 17 | wooden table | 38 |
| 18 | floor lamp | 36 |
| 19 | grass | 36 |
| 20 | clouds | 35 |

