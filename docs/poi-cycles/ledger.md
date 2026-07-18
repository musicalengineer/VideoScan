# POI Improvement Loop — Cycle Ledger

Ratchet directive (room-ratified by Rick, 2026-07-17): iterate cycles until
**≥90% balanced accuracy** on the dynamic Donna/NotDonna corpus. Grading is
confirmed-only presence (schemaVersion 2), corpus enumerated fresh per run
with a corpus fingerprint. Codex grades; FAIL means the candidate does not
merge and the loop continues.

| Cycle | Candidate | Branch @ commit | Verdict | Balanced acc (A/B) | Graded | Notes |
|---|---|---|---|---|---|---|
| C1 | Score-based presence aggregation (minHits=3, minHitRate=0.08, maxMedianDistance=0.50) | `poi/c01-aggregation` @ 0ea582f | **FAIL** | legacy 0.577 → score 0.500 (−0.077) | 2026-07-17 22:28 UTC, codex `poi-c01-grade-2026-07-17` | Score mode reduced every headline metric; added 1 FN (`Donna-14.mov`) and 1 FP. Do not merge. |

## C1 detail (2026-07-17, corpus: 13 Donna / 13 NotDonna)

| Mode | TP | FN | FP | TN | Precision | Recall | F1 | Bal. acc |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| legacy | 13 | 0 | 11 | 2 | 0.542 | 1.000 | 0.703 | 0.577 |
| score  | 12 | 1 | 12 | 1 | 0.500 | 0.923 | 0.649 | 0.500 |

**The dominant error mode is false positives**: legacy flags 11/13 NotDonna
clips (the corpus now includes adult-female negatives in Donna's age band).
Recall is already 1.0 — the loop's headroom is almost entirely FP
suppression, not hit sensitivity. Aggregation-rule tweaks atop the same
match distances (C1's approach) demonstrably cannot fix this: the per-frame
matcher itself calls NotDonna faces "Donna."

**Implication for cycle ordering**: the planned C2 (birthdate/age prior)
targets kin-child confusion, but the observed FPs are same-age-band adults —
the prior cannot separate them. Evidence points to reference-set audit +
threshold/margin recalibration (planned C3/C4) as the direct lever.
Reordering proposed to Rick 2026-07-18 (pending his call — ladder was
room-ratified, so the reorder needs the director's sign-off).

Grade provenance: control-plane task `poi-c01-grade-2026-07-17` (Engineering
Room sqlite), read-only worktree `agent-aec3dc10f9abf15ef`, Release build,
artifacts under `/private/tmp` per codex report. Codex's follow-up channel
message did not post — flagged in channel 2026-07-18.
