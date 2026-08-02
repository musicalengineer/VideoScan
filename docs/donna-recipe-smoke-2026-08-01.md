# Donna Recipe — overnight platform spike + smoke results (2026-08-01)

One evening, three questions answered. All runs on the M4 via the venv
(python3.12) with insightface buffalo_l (SCRFD-10G + ArcFace-w600k +
genderage) over ONNX Runtime with the CoreML execution provider.

## 1. Platform spike — PASSED

- onnxruntime 1.28 exposes CoreMLExecutionProvider on this machine; all five
  buffalo_l models load and run under it.
- Reference gallery: detect+embed at **0.05 s/photo**. Video: **~0.09 s/frame**
  end-to-end including decode — a 10-minute video at 2 fps sampling ≈ 2 min of
  compute. Archive-scale (≈1000 videos) ≈ 30–35 machine-hours on ONE Mac —
  a weekend across the fleet. Feasibility confirmed.
- venv note: `venv/bin/python` symlinks to 3.14 but site-packages live under
  3.12 — use `venv/bin/python3.12` explicitly (did not rewire Rick's venv).

## 2. G1 gallery report card — PASSED (docs/donna-gallery-report-2026-08-01.md)

60 photos, 6 eras (70s–2020s), 56 clean votable references, 0 unusable.
Intra-era cohesion 0.52–0.73 (strong); cross-era centroids 0.67–0.95 —
Rick's "she looks the same 25–50" hypothesis is CONFIRMED in embedding space
(weakest link: 70s↔2020s 0.667, exactly where era-banding earns its keep).
4 photos flagged for a human glance (2 sub-voting-tier 70s faces — still
record-tier usable; 2 genderage "M" mislabels with peer-cos ≈ 0.67, i.e.
clearly Donna — lesson: the sex gate must MAJORITY-VOTE per track, never
judge single frames).

## 3. End-to-end smoke over DonnaTestVideos (15 Donna / 13 NotDonna) — AUC 0.995

Pipeline: ffmpeg yadif+2fps → SCRFD detect → two-tier size gate → sex gate →
ArcFace embed → max cosine vs era-banded centroids → top-5 mean per clip
(tools/donna-recipe/recipe_smoke.py).

| | min | median | max |
|---|---|---|---|
| Donna clips | 0.295 | 0.697 | 0.768 |
| NotDonna clips | 0.029 | 0.194 | 0.307 |

At threshold 0.40: **14/15 recall, 0/13 false positives.**

Two diagnosed cases, both instructive:
- `Donna-14.mov` initially scored 0 — her face matches at 0.70 but is only
  35 px. Fix was the CORRECT reading of the two-tier rule: small faces may
  CONFIRM a known person at a raised bar (≥0.55), they just can't smear weak
  evidence (rescued to 0.581; NotDonna scores untouched).
- `Donna_OrangeShorts_Cape_1993.mov` (0.295): 130 large faces, best cosine
  0.343 anywhere in the clip — face signal genuinely absent (beach; almost
  certainly sunglasses). Known-hard; v2 channels (body/clothing continuity,
  context) or higher-fps sampling for a glasses-off moment. NOT a
  threshold-tuning target.

## Honest caveats

- 28 dev clips ≠ a grade. G2 (frozen grader, beat C3's 0.615) and G3 (new
  era-stratified benchmark with hard negatives) still gate any catalog run.
- No tracking yet — frame-level sufficed on this corpus; degraded archive
  footage is where tracks should pay.
- Threshold 0.40/0.55 are eyeballed from this corpus; C2-style sweep with
  proper calibration comes with G2.
- Python/insightface embeddings ≠ the app's production ArcFace path; the
  production-vector audit re-runs once the C2 Swift CLI deltas are re-merged.

## Next

1. codex: review gates + this smoke methodology (channel #73/#74).
2. Re-merge C2/C4 Swift CLI deltas (audit-references, dump-embeddings) — deliberate, reviewed.
3. G2 run with the frozen grader; C2 threshold sweep on these scores.
4. Tracking spike design (zero verified literature on interlaced footage).
