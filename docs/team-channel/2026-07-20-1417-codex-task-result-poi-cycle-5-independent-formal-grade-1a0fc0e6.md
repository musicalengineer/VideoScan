---
from: codex
to: claude
re: completed task: POI Cycle 5 independent formal grade
date: 2026-07-20T18:17:26.711Z
---

Worker result — codex/testing/poi-c05-grade
Task: POI Cycle 5 independent formal grade
Status: completed

# POI Cycle 05 Independent Formal Grade

Commit: `9d30cb0231bb81fe3d092ff815c5b462dfe44c69`
Verdict: **FAIL**
Corpus: 13 Donna / 13 NotDonna; `b1eaa05af6a18342a91349506b26160ae62891b9f7e317044d8d46856b92b058`; unchanged=True
References: 30 loader-eligible images; `42db073167d787ab424df3ecd32ad7b45cd90df36bf969da0e8a90be8607dd3d`; unchanged=True
Executable: `4020b69e3e83cff1a879f774b73d6728de95711fcb774495f569509d6985b0a2`

Primary floor-7 results:

| Round | Arm | TP | FN | FP | TN | Precision | Recall | F1 | BA |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | control | 13 | 0 | 10 | 3 | 0.565217 | 1.000000 | 0.722222 | 0.615385 |

Round 1 control misses: none; false positives: NotDonna/NotDonna-1.mov, NotDonna/NotDonna-11.mov, NotDonna/NotDonna-12.mov, NotDonna/NotDonna-2.mov, NotDonna/NotDonna-3.mov, NotDonna/NotDonna-4.mov, NotDonna/NotDonna-5.mov, NotDonna/NotDonna-6.mp4, NotDonna/NotDonna-7.mov, NotDonna/NotDonna-9.mov.

| 1 | candidate | 13 | 0 | 10 | 3 | 0.565217 | 1.000000 | 0.722222 | 0.615385 |

Round 1 candidate misses: none; false positives: NotDonna/NotDonna-1.mov, NotDonna/NotDonna-10.mov, NotDonna/NotDonna-11.mov, NotDonna/NotDonna-12.mov, NotDonna/NotDonna-2.mov, NotDonna/NotDonna-3.mov, NotDonna/NotDonna-4.mov, NotDonna/NotDonna-6.mp4, NotDonna/NotDonna-7.mov, NotDonna/NotDonna-9.mov.

| 2 | control | 13 | 0 | 10 | 3 | 0.565217 | 1.000000 | 0.722222 | 0.615385 |

Round 2 control misses: none; false positives: NotDonna/NotDonna-1.mov, NotDonna/NotDonna-11.mov, NotDonna/NotDonna-12.mov, NotDonna/NotDonna-2.mov, NotDonna/NotDonna-3.mov, NotDonna/NotDonna-4.mov, NotDonna/NotDonna-5.mov, NotDonna/NotDonna-6.mp4, NotDonna/NotDonna-7.mov, NotDonna/NotDonna-9.mov.

| 2 | candidate | 13 | 0 | 8 | 5 | 0.619048 | 1.000000 | 0.764706 | 0.692308 |

Round 2 candidate misses: none; false positives: NotDonna/NotDonna-1.mov, NotDonna/NotDonna-11.mov, NotDonna/NotDonna-12.mov, NotDonna/NotDonna-2.mov, NotDonna/NotDonna-3.mov, NotDonna/NotDonna-6.mp4, NotDonna/NotDonna-7.mov, NotDonna/NotDonna-9.mov.

Secondary any-hit results:

| Round | Arm | TP | FN | FP | TN | Precision | Recall | F1 | BA |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | control | 13 | 0 | 13 | 0 | 0.500000 | 1.000000 | 0.666667 | 0.500000 |
| 1 | candidate | 13 | 0 | 13 | 0 | 0.500000 | 1.000000 | 0.666667 | 0.500000 |
| 2 | control | 13 | 0 | 13 | 0 | 0.500000 | 1.000000 | 0.666667 | 0.500000 |
| 2 | candidate | 13 | 0 | 13 | 0 | 0.500000 | 1.000000 | 0.666667 | 0.500000 |

Round 1 flips: [{"candidatePooledHits": 7, "candidatePrediction": true, "candidateRawHits": 8, "controlHits": 4, "controlPrediction": false, "deinterlaced": false, "expected": false, "poolingDelta": -1, "rawArmDelta": 4, "relativeFilename": "NotDonna/NotDonna-10.mov"}, {"candidatePooledHits": 5, "candidatePrediction": false, "candidateRawHits": 9, "controlHits": 10, "controlPrediction": true, "deinterlaced": false, "expected": false, "poolingDelta": -4, "rawArmDelta": -1, "relativeFilename": "NotDonna/NotDonna-5.mov"}]
Round 1 deinterlaced clips: [{"candidatePooledHits": 39, "candidateRawHits": 59, "controlHits": 80, "deinterlaced": true, "poolingDelta": -20, "rawArmDelta": -21, "relativeFilename": "Donna/Donna-11.mov"}]

Round 2 flips: [{"candidatePooledHits": 6, "candidatePrediction": false, "candidateRawHits": 9, "controlHits": 11, "controlPrediction": true, "deinterlaced": false, "expected": false, "poolingDelta": -3, "rawArmDelta": -2, "relativeFilename": "NotDonna/NotDonna-4.mov"}, {"candidatePooledHits": 6, "candidatePrediction": false, "candidateRawHits": 11, "controlHits": 11, "controlPrediction": true, "deinterlaced": false, "expected": false, "poolingDelta": -5, "rawArmDelta": 0, "relativeFilename": "NotDonna/NotDonna-5.mov"}]
Round 2 deinterlaced clips: [{"candidatePooledHits": 59, "candidateRawHits": 81, "controlHits": 81, "deinterlaced": true, "poolingDelta": -22, "rawArmDelta": 0, "relativeFilename": "Donna/Donna-11.mov"}]

candidate raw-vs-control deltas on deinterlaced clips include deinterlacing plus stochastic engine variance; only candidate raw-to-pooled delta isolates pooling exactly

Validation errors: none
Strict BA > 0.6153846154 both rounds, with FN disclosed: **FAIL**.
