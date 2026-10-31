# Video LLM benchmarks

*Written by `tools/video-llm-bench/bench.py summarize`; overwritten on every run, never appended (CLAUDE.md). Aggregates only — per-clip results stay in `.scratch/` (DECISIONS 2026-10-26). Design: `docs/design/video_llm_lab_2026_10_30.md` §4.*

## Approach `a0-py` — baseline (today's 3B captioner, stills, the three app prompts)

| Run | Value |
|---|---|
| generated | 2026-10-31T00:45:44+00:00 |
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

