# Donna production recognition — current-folder read-only acceptance

Generated: 2026-07-17 16:25 America/New_York

## Result

- Donna found: **13/13**
- NotDonna falsely flagged: **13/13**
- TP: **13**
- FN: **0**
- FP: **13**
- TN: **0**
- Precision: **0.5000 (50.0%)**
- Recall: **1.0000 (100.0%)**
- F1: **0.6667 (66.7%)**

The current `Donna/` folder contains 13 clips; `Donna-6.MOV` is not present today.

## Errors

- Misses: **none**
- False positives:
  - `NotDonna-1.mov`
  - `NotDonna-2.mov`
  - `NotDonna-3.mov`
  - `NotDonna-4.mov`
  - `NotDonna-5.mov`
  - `NotDonna-6.mp4`
  - `NotDonna-7.mov`
  - `NotDonna-8.mov`
  - `NotDonna-9.mov`
  - `NotDonna-10.mov`
  - `NotDonna-11.mov`
  - `NotDonna-12.mov`
  - `NotDonna-13.mov`

## Production configuration

- Engine: live production **ArcFace**, fresh current-source Release `VideoScan` build
- Threshold: default cosine similarity **>= 0.40**; stored match distance **<= 0.60**
- Reference set: **30 current image files** in `/Users/rickb/Library/Application Support/VideoScan/POI/donna`
- Frame step: **10**
- `largestFaceOnly`: **false**
- Aggregation/evaluator rule: a video is predicted present when it has **any hit or any non-empty segment**
- Dataset tier: development, not holdout; metrics are not publication-eligible

## Reproduction and evidence

```sh
python3 tools/person-eval/person_eval.py /private/tmp/videoscan-donna-production-2026-07-17/manifest.json \
  --app /private/tmp/videoscan-donna-production-2026-07-17/DerivedData/Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan \
  --json /private/tmp/videoscan-donna-production-2026-07-17/report.json \
  --markdown /private/tmp/videoscan-donna-production-2026-07-17/report.md
```

- Cases: 26
- Result source: live engine
- Elapsed: 98.70 seconds
- Peak RSS: 311.89 MB
- `report.json` SHA-256: `8b4d6134ce55305f6024b3f13c837da6d93a8ae5a6e2603a746cfd08399c6436`
- Evaluated executable SHA-256: `3149daee063111c8550d3a51687b567dfe204bcd535fcb0f81dccf7b5d97e382`
- Raw artifacts: `/private/tmp/videoscan-donna-production-2026-07-17/`

## Outbound orchestration acceptance

- Durable task: `donna-production-2026-07-17`
- Worker: `codex/testing/donna-production`
- State transition: queued at `20:08:24Z` → claimed/working at `20:08:35Z` → completed at `20:27:28Z`
- Live heartbeat events were recorded throughout the production run.
- Originating room directive message: `f6f6f16e-7bbf-41d5-b982-aa085bfa563f`
- Automatically posted result message: `2e3c745d-0c9c-4b81-88ba-4f0abbd43ed9`
- The result message is an attributed system reply to the originating directive in `Topics of the day`; no Rick relay was used.
