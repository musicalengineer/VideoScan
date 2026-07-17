# Person Recognition Evaluation — Donna

**Score:** 65.0/100 (identity F1)

Engine: **ArcFace** · Cases: **27** · Generated: 2026-07-16T23:27:56.499046+00:00

Dataset: **donna-testvideos-assess-v0** · Tier: **development** · Holdout: **no**

Metrics publication: **NOT ELIGIBLE**

| Signal | Precision | Recall | F1 | Accuracy | FP | FN |
|---|---:|---:|---:|---:|---:|---:|
| Any face | 100.0% | 100.0% | 100.0% | 100.0% | 0 | 0 |
| Donna present | 50.0% | 92.9% | 65.0% | 48.1% | 13 | 1 |
| Screen-time segments | 0.0% | n/a | — | — | — | — |

Reasons: suite is not marked as quality-tier; suite is not marked as a holdout

## Cases

| Case | Expected | Predicted | Result | Tags |
|---|---|---|---|---|
| donna-1 | present | present | PASS | positive |
| donna-2 | present | present | PASS | positive |
| donna-3 | present | present | PASS | positive |
| donna-4 | present | present | PASS | positive |
| donna-5 | present | present | PASS | positive |
| donna-6 | present | absent | FALSE NEGATIVE | positive |
| donna-7 | present | present | PASS | positive |
| donna-8 | present | present | PASS | positive |
| donna-9 | present | present | PASS | positive |
| donna-10 | present | present | PASS | positive |
| donna-11 | present | present | PASS | positive |
| donna-12 | present | present | PASS | positive |
| donna-13 | present | present | PASS | positive |
| donna-14 | present | present | PASS | positive |
| notdonna-1 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-2 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-3 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-4 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-5 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-7 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-8 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-9 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-10 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-11 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-12 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-13 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
| notdonna-6 | absent | present | FALSE POSITIVE | family-similarity, hard-negative, negative |
