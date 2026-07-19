# POI Improvement Loop — Cycle Ledger

Ratchet directive (room-ratified by Rick, 2026-07-17): iterate cycles until
**≥90% balanced accuracy** on the dynamic Donna/NotDonna corpus. Grading is
confirmed-only presence (schemaVersion 2), corpus enumerated fresh per run
with a corpus fingerprint. Codex grades; FAIL means the candidate does not
merge and the loop continues.

**REVISED LADDER (Rick-ratified 2026-07-19, after C1–C3 evidence review):**
post-processing levers on unchanged ArcFace distances are RETIRED (C2 proved
confusers score cosine 0.85–0.94 — the separation signal is not in a blurry
SD face crop; "the 4-year-old test" shows the signal lives in whole-person
features the crop discards). New ladder: **C4 = learned Donna classifier
head** on ArcFace embeddings, trained on Rick's labeled clips (first
learning-based cycle; hard negatives become training signal); **C5 =
deinterlace + quality-weighted pooling** (embedding quality); **C6 =
whole-person witness** (MobileCLIP person-region embeddings — needs Rick
model sign-off); fusion ladder (rule-out cascade, only-adult-female prior)
in parallel. **Corpus split rule from C4 on: current 26 clips = TRAINING
POOL; Rick's new clips = SEALED HOLDOUT (grader-only). Never train and grade
on the same clips.** Face-only ceiling vs same-age adult negatives is
expected well below 0.90 — the 0.90 goal is a fusion-system goal; the loop
grades each component honestly along the way.

**Publication (mandatory per-cycle completion step, codex 2026-07-19):** update
`docs/poi-cycles/metrics.jsonl` with the cycle row + honest evidence tier
(`grade` | `development`), `python3 scripts/publish_poi_cycle_metrics.py
--check`, then publish to the metrics branch. Cycles must stay unique,
ordered, contiguous from C1. Dashboard graphs BA/precision/recall/F1 on
GitHub Pages.

| Cycle | Candidate | Branch @ commit | Verdict | Balanced acc (A/B) | Graded | Notes |
|---|---|---|---|---|---|---|
| C1 | Score-based presence aggregation (minHits=3, minHitRate=0.08, maxMedianDistance=0.50) | `poi/c01-aggregation` @ 0ea582f | **FAIL** | legacy 0.577 → score 0.500 (−0.077) | 2026-07-17 22:28 UTC, codex `poi-c01-grade-2026-07-17` | Score mode reduced every headline metric; added 1 FN (`Donna-14.mov`) and 1 FP. Do not merge. |

| C2 | Calibrated reference set (audited clustering minClusterLink=0.35 + threshold 0.48; config sha256 bd515334…f6ce4b) | `poi/c02-refs-threshold` @ 3e5a4bb | **FAIL** | legacy 0.500/0.500 vs candidate 0.538/0.577 (2 paired AB/BA rounds) — never strictly > 15/26 | 2026-07-18 21:05 ET, codex | Recall 1.0 both arms. Candidate better than legacy in-round but ties the historical bar at best. Instability: references-used varied 17–25 on identical config+images; NotDonna-5 flipped FP→TN between rounds; 25/26 clips changed raw fields across rounds. Do not merge/promote. |

| C3 | Minimum-hit confirmation floor (confirmed iff totalHits >= 7; config sha256 e981faa3…dbe7ea) | `poi/c03-minimum-hits` @ fbb8e6a | **PASS** | legacy 0.500/0.500 vs candidate **0.6154/0.6154** (2 fresh paired rounds, both strictly > 15/26 bar) | 2026-07-19 13:51 ET, codex | FIRST PASS. FN=0 both rounds; same 3 FPs corrected in both repeats (NotDonna-8/10/13); zero prediction flips across repeats in either arm (raw observations varied, none crossed a boundary); 104/104 processes clean; completion audit PASS. Frozen/unmerged — Rick decides integration. Report sha256 ccb48a15…3073bd. |

## C4 status (2026-07-19, implementation complete — NOT YET GRADED)

`poi/c04-donna-classifier` @ 74ec6a3: donna-lr classifier head (sklearn LR on
8,079 production-ArcFace face rows from the 26 training clips; model sha256
7ff1ad9a…ea6858, ~12 KB weights-only). **LOCO cross-validated development
evidence (NOT a grade): balanced accuracy 0.769** (TP 11 / FN 2 / FP 4 / TN 9)
vs 0.500 legacy on identical runs; corrects 9/13 legacy FPs INCLUDING
NotDonna-4 (C2's no-threshold-can-separate clip). Disclosed: first candidate
with Donna FNs (Donna-7, Donna-14 — Rick's integration call); knife-edge
p*≈0.9849 (optimal gap ~0.005 ≈ ArcFace run drift — holdout boundary flips
expected); config-name unification (presenceModel vs aggregation) pending.
Official grade: sealed holdout (Rick building) + M4 quiet window or M5/M1
routing per machine policy. Suite 2853/0 green in worktree — the unit-runner
wedge has CLEARED; UI-runner testmanagerd flake persists.

## C3 detail (2026-07-19)

Eval-only change; production default untouched. Known limitations carried
from the declaration: thin one-hit margin (weakest positive 8 vs strongest
rejected negative 6) and absolute-count duration/frame-step bias — short
genuine-Donna clips are the FN exposure; the current corpus contains none
(sealed-holdout growth should include some). Note: legacy measured 0.500 in
both formal rounds (13/13 FP) vs its historical 0.577 — same-day corpus
drift within legacy itself; the acceptance comparator was the exact
historical bar 15/26, disclosed. LAST cycle graded on the current 26 clips
(they become the C4+ training pool per the revised ladder).

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

**C3 REDIRECTED (2026-07-18 21:45 ET): minimum-hit confirmation floor** —
`confirmed` iff totalHits >= 7, eval-only flag, config {"minHits":7,
"mode":"minimumHits"}. Codex development evidence (four preserved captures,
NOT a grade): all four reclassify to BA 0.615 (16/26) with FN=0; thin margin
(weakest positive 8 hits vs strongest rejected negative 6) and duration/
frame-step bias disclosed. Attributable because C1's failure came from the
compound rate/distance gates, which this removes. Branch poi/c03-minimum-hits
from 4bb3e42. Codex authorized as non-architectural under Rick's standing
bounded-cycle authorization.

**Rule-out cascade: HELD, decision queued for Rick** (was the 21:15 C3
declaration) — needs (a) new age/gender model approval; license survey found
NO cleanly-licensed candidate (best: InsightFace genderage, weights
"non-commercial research only" — same zoo/license as production ArcFace,
consistency question flagged); and (b) family-member negatives in the corpus
for measurability. Alternative no-model lever if declined: quality-weighted
track pooling (research #1). Original note follows for the record:
**(superseded 21:15 declaration): rule-out cascade** —
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
