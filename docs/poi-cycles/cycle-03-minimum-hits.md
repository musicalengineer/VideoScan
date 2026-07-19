# POI Cycle 03 — Minimum-Hit Confirmation Floor

Branch: `poi/c03-minimum-hits` (cut from `4bb3e42`; eval-only — production
app behavior stays legacy). Dispatch: codex 2026-07-18T21:40
(`docs/team-channel/2026-07-18-2140-codex-c03-minimum-hits-dispatch.md`),
after the age/gender model was held on license review and C3 was redirected
to the strongest existing-signal lever.

## The single change

A video-level presence rule for the person-eval CLI:

> **`presence = "confirmed"` iff `totalHits >= 7`; otherwise `"none"`.**

`totalHits` is the raw matched face-observation count — ArcFace counts
matched face observations, and multiple observations can land in a single
frame, so this is not a frame count.

Selected with `--aggregation minimum-hits --min-hits 7`. Nothing else moves:
same production ArcFace path, same full unmodified reference set, default
threshold, `--frame-step 10`. The raw `hits` field is emitted unchanged;
only the confirmed/none classification of that already-computed count
differs between arms. The default run (no flags) remains the legacy any-hit
arm: `confirmed ⇔ hits > 0`.

## Why this is attributable

C1 failed as a *compound* gate: `minHits >= 3 AND hitRate >= 0.08 AND
medianHitDistance <= 0.50`. The rate and distance components were the
unstable parts — they created a Donna false negative while still passing
drifting negatives, and a three-parameter rule cannot attribute a grade
delta to any one parameter. C3 removes both of those gates and keeps ONLY
the count floor. One parameter, one comparison, pure O(1) math over one
counter (`EvalPresenceRule.presence(hits:)`). If the grade moves, the floor
moved it; revert = don't pass the flag (or revert this single commit).

## Development evidence (post-hoc — NOT a grade)

Codex testing independently reclassified four preserved recognizer captures
under `confirmed ⇔ totalHits >= 7`:

| capture | weakest Donna | rejected NotDonna hit counts | TP/FN/FP/TN | BA |
|---|---:|---|---|---:|
| C1 legacy | 10 | ND10=5, ND13=5, ND8=5 | 13/0/10/3 | .615384 |
| C1 score-arm raw stats | 8 | ND10=6, ND13=5, ND8=5 | 13/0/10/3 | .615384 |
| C2 valid legacy round 1 | 8 | ND10=4, ND13=5, ND8=5 | 13/0/10/3 | .615384 |
| C2 valid legacy round 2 | 11 | ND10=4, ND13=5, ND8=5 | 13/0/10/3 | .615384 |

All four captures reclassify to BA 16/26 = **0.615384** with **FN = 0**,
strictly above the historical 15/26 = 0.576923 bar. This is *post-hoc*
evidence: the floor of 7 was chosen by looking at these same captures, so
the numbers above cannot certify generalization — that is exactly what the
independent two-round paired grade on the dynamic corpus exists to test.

### Disclosed limitations

- **Thin one-hit margin.** The weakest positive across the four captures had
  8 hits; the strongest rejected negative had 6. The floor at 7 sits in a
  two-hit gap. ArcFace inference is not bit-stable run to run (measured in
  C2: ±0.02 cosine cross-run); a single hit flipping either way on a
  boundary clip flips its classification.
- **Duration / frame-step bias.** Hits are an absolute matched-observation
  count, not a rate —
  deliberately (C1's rate gate was the unstable one). But that means longer
  clips accumulate hits faster at fixed frame-step. **The FN risk is a
  short, genuine Donna clip**: at frame-step 10 a brief appearance may
  simply not have 7 sampled opportunities to match. The four captures
  contained no such clip; the dynamic corpus may.
- **Corpus scale.** Four captures of the same 26-clip corpus shape, 13
  positives, no short-positive representative. The 0.615 prediction is a
  consistency observation, not a distribution estimate.

### FN / generalization risk statement

FN was 0 in all four development captures, but the mechanism above makes a
future FN plausible and its most likely shape known (short genuine
appearance). If the graded rounds surface an FN, that is signal about the
floor mechanism, not noise — it must be fully disclosed per round, and a
duration-aware variant would be a *different lever* for a *future cycle*,
not a tuning knob for this one. No post-commit tuning: the candidate is
frozen at the commit named below.

## Canonical config

The CLI emits the exact rule it executed (single `EvalPresenceRule` value
flows from parse → decision → output; inert or conflicting flags are hard
parse errors — C2's provenance lesson):

- Candidate arm: `{"minHits":7,"mode":"minimumHits"}`
  sha256 `e981faa37be39891b21a1f650858e24cfef989e2816bf71fe043c2cd15dbe7ea`
- Legacy arm: `{"mode":"legacyAnyHit"}`
  sha256 `4f475fab1db48dba996da6415cdac83c9fd38837c0a036704c395e7ff953af16`

Byte-stable: sorted keys, no whitespace, meaningful fields only (legacy
carries no floor). Pinned by `EvalPresenceRuleTests.canonicalHashStability`.

## A/B reproduction (grader)

Release build, same binary both arms, per-file AB/BA pairing, schema v2,
positive ⇔ `presence == "confirmed"` (exact spelling):

```
# legacy arm (production defaults; any-hit presence)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10

# candidate arm (minimum-hit confirmation floor)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10 \
    --aggregation minimum-hits --min-hits 7
```

No `--threshold` in either arm (production default). Reference directory,
corpus, and labels are codex-owned and untouched by this branch.

## Validation surface (pinned by tests)

`VideoScan/VideoScanTests/EvalPresenceRuleTests.swift` (27 tests / 38
executions):

- Exact boundary: hits 0 and 6 ⇒ `none`; 7 and 8 ⇒ `confirmed`; full 0–20
  neighborhood; floor 1 ≡ any-hit; zero-faces; `Int.max`-scale counts.
- Legacy parity sensor: default rule ≡ `hits > 0` any-hit for 0–50.
- Canonical bytes + sha256 pins (both arms), 100× byte-stability, Codable
  round-trip.
- Output schema: emitted `aggregation` object bytes, presence spelling, raw
  `hits` unchanged; same raw count classifies differently across arms.
- Flag truth table: flag changes mode AND presence; order-independent;
  rejected — `--min-hits` without the mode, `--min-hits` with explicit
  legacy, mode without `--min-hits` (no silent default), duplicates,
  `minimum-hits` + `--face-presence-only` (inert: no hits to count), 12
  malformed floor spellings (`0`, `-3`, `7.5`, `nan`, `0x7`, overflow, …),
  unknown modes, missing values. Half-specified rule fails closed.

## Implementation decisions (recorded for review)

- Non-confirmed spelling is `none` (dispatch's suggestion; matches C2's
  schema-v2 precedent). Grader matches exact `confirmed` only.
- schemaVersion 2, purely additive over 1 (`aggregation`, `presence`); all
  pre-existing fields keep raw pipeline semantics.
- `--aggregation minimum-hits` REQUIRES an explicit `--min-hits` — the
  "no silent defaults" clause read strictly; there is no built-in 7.
- Explicit `--aggregation legacy` is accepted (spells the default; useful
  for self-documenting A/B scripts).
- The rule is engine-independent count math; the CLI does not forbid it on
  non-ArcFace engines (the grade runs ArcFace only). Rejecting by engine
  would have added a second axis to a one-axis change.
- Error outputs report the rule that was actually requested when parsing
  succeeded (truthful attribution even on failed runs), presence `none`.
