# POI Improvement Loop — Cycle Ledger

Ratchet directive (room-ratified by Rick, 2026-07-17): iterate cycles until
**≥90% balanced accuracy** on the dynamic Donna/NotDonna corpus. Grading is
confirmed-only presence (schemaVersion 2), corpus enumerated fresh per run
with a corpus fingerprint. Codex grades; FAIL means the candidate does not
merge and the loop continues.

| Cycle | Candidate | Branch @ commit | Verdict | Balanced acc (A/B) | Graded | Notes |
|---|---|---|---|---|---|---|
| C1 | Score-based presence aggregation (minHits=3, minHitRate=0.08, maxMedianDistance=0.50) | `poi/c01-aggregation` @ 0ea582f | **FAIL** | legacy 0.577 → score 0.500 (−0.077) | 2026-07-17 22:28 UTC, codex `poi-c01-grade-2026-07-17` | Score mode reduced every headline metric; added 1 FN (`Donna-14.mov`) and 1 FP. Do not merge. |

| C2 | Calibrated reference set (audited clustering minClusterLink=0.35 + threshold 0.48; config sha256 bd515334…f6ce4b) | `poi/c02-refs-threshold` @ 3e5a4bb | **FAIL** | legacy 0.500/0.500 vs candidate 0.538/0.577 (2 paired AB/BA rounds) — never strictly > 15/26 | 2026-07-18 21:05 ET, codex | Recall 1.0 both arms. Candidate better than legacy in-round but ties the historical bar at best. Instability: references-used varied 17–25 on identical config+images; NotDonna-5 flipped FP→TN between rounds; 25/26 clips changed raw fields across rounds. Do not merge/promote. |

## C2 detail (2026-07-18)

Audit finding of record: the 30-reference set is NOT contaminated — satellite
clusters/isolates are genuinely Donna (era/quality fragmentation). One
reference is stored 90°-rotated (loader applies no EXIF orientation → garbage
embeddings incl. one non-Donna face) — future lever. Confusers score cosine
0.85–0.94 against true-Donna references; no reference subset or global
threshold separates them (codex's NotDonna-4 evidence: a negative closer than
every positive). Robustness gain (plateau 0.40–0.56 vs legacy knife-edge)
was real but the acceptance rule is strict improvement, correctly applied.
Grade provenance: report + raw argv under
`/private/tmp/poi-c02-grade-3e5a4bb-20260718T2045/`, corpus sha256
b1eaa05a…92b058, refs content sha256 42db0731…07dd3d, exe sha256
6e384152…2dfca.

**C3 (declared 2026-07-18 21:15 ET, Rick-ratified lever): rule-out cascade** —
one matcher-level change: per-face age/gender attributes rule out
males/children before Donna matching; eval-only flag; reference input = full
legacy 30 (deterministic by construction; C2's audited calibration is
abandoned, resolving the 17–25 variance by removal). Disclosed caveat: current
corpus negatives are adult women, whom the cascade cannot reject — measurable
corpus gain depends on Rick's planned family-member negatives (boys/Rick/
parents); if the corpus is unchanged at grade time, expected delta ≈ 0 and
the cycle documents that honestly. FN risk: Donna misclassified male/child →
conservative rule-out thresholds, disclosed in the rationale doc.

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
