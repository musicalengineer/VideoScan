# POI Cycle 2 — Calibrated Reference Set (cohesion audit + operating point)

Branch `poi/c02-refs-threshold` (cut from main @ 83b7796). One attributable
matcher-level change: **the calibrated reference set** — which reference
faces are allowed to define "Donna" (mutual-cohesion clustering at load
time) *plus* the match operating point calibrated to the curated
distribution. One canonical, hashable configuration (below); the A/B is
production defaults vs exactly that object.

## Scope — eval-only in C2 (precise)

The calibration rule is implemented in `ReferenceCalibration.swift` and is
invoked **only** by the person-eval CLI's ArcFace path
(`PersonEvaluationCLI`) when `--reference-calibration audited` (or
`--audit-references`) is passed. **The production VideoScan app is
unchanged**: `PersonFinderModel`'s scan path still loads references via
`arcfaceLoadReferenceEmbeddings` (all faces, legacy behavior) and never
calls `ReferenceCalibration`. This is NOT yet a production reference-load
rule.

The candidate flags nonetheless exercise the exact code intended for later
production integration: the CLI loads references through
`arcfaceLoadReferenceEmbeddingsDetailed` — the same pipeline
`arcfaceLoadReferenceEmbeddings` delegates to (same enumeration, detection
filter, crop, alignment, embedding) — applies
`ReferenceCalibration.calibrate`, and feeds the kept embeddings to the
production matcher `pfProcessVideoWithArcFace`. Promotion after a PASS grade
is one call: apply `calibrate` at the app's reference-load site.

## Canonical candidate (one definition)

The C2 candidate is `--reference-calibration audited` run against the
**original production reference folder**, algorithm
single-link-largest-component as implemented by
`ReferenceCalibration.calibrate`, configuration:

```
{"matchThreshold":0.48,"minClusterLink":0.35,"mode":"audited"}
sha256 bd51533452efb5b1dd00f5d2d52f273e2b933f900350167b9583ef31d6f6ce4b
```

byte-stable via sorted-keys encoding; emitted verbatim in the CLI JSON as
`referenceCalibration`, so every graded run is attributable to exactly this
object. `matchThreshold` 0.48 is a calibrated change from the production
default 0.40 (rationale under "Operating point"); on the current dev corpus
every t in 0.40–0.56 makes identical decisions, so curation-only
attribution is preserved in practice while 0.48 buys drift margin. The
in-code `ReferenceCalibrationConfig.standard` default stays 0.40 (pinned by
test); the candidate sets 0.48 explicitly via `--calibration-threshold`.

The Python helpers in `tools/poi-c02/` never define a second candidate:
`audit_references.py` replicates the same algorithm only as a parity
cross-check (hard failure on divergence) and emits refset manifests whose
kept/dropped lists are taken verbatim from the Swift audit dump;
`make_refset.py` materializes such a manifest as a cross-check utility with
all-or-nothing hash validation (validate everything, stage the copies,
re-hash the staged copies, then rename the staging directory into place —
publication into a fresh target is atomic; a dirty target without this
script's provenance marker, or any hash mismatch, writes nothing) — the
materialized folder is not the candidate and is refused entirely when
file-level curation cannot reproduce the face-level candidate.

## Planning evidence (published only)

From `tools/person-eval/benchmarks/donna-dev-27/report.json` (published
2026-07-16) and codex's C1 raw-evidence channel message (2026-07-18 18:36):

- Legacy flags 11/13 NotDonna clips; recall is already 1.0. The headroom is
  entirely false-positive suppression.
- Published NotDonna best distances: 0.056–0.449, with **eight of thirteen
  in 0.055–0.13** — cosine ≥ 0.87 against *some* reference embedding.
- `notdonna-4` (best 0.0556) scores closer than every true Donna clip.
  No global threshold can separate that; codex's evidence message makes the
  same point and explicitly green-lights a reference-audit C2.

The planning hypothesis was that those same-person-level scores meant
non-target (bystander) faces serving as references. **The audit did not
confirm that hypothesis** (next section). Disclosure: planning used
published evidence only, but the operating point was subsequently calibrated
on the dev corpus via the working-evidence sweep below — that is
corpus-fitting and is labeled as such.

## Audit result on the production Donna reference folder

Captured with `--audit-references` (Release build, production ArcFace path,
read-only). Per-face tables, component listings, and the raw dump are in
`/private/tmp/poi-c02-artifacts/` (`audit-candidate.json`,
`audit-report.md`) for the grader — **not committed** (see sensitive-data
note below). Aggregates:

- **31 embedded faces from 30 image files** (one file contributes two
  detected faces); 0 files skipped by the loader.
- Single-link components at link 0.35: sizes `[19, 4, 1×8]` in the
  canonical audit run (dominant-component size varies run-to-run — see
  "Nondeterminism").
- **Visual verification** of the satellite component and every isolate
  against known-good anchors: they are the **target person** in other eras
  or lower photo quality — *not* bystanders. The reference set spans ~45
  years; ArcFace cohesion fragments along era and quality lines.
- Exactly one reference file is stored 90°-rotated (EXIF orientation is not
  applied by the reference loader). Its two faces — one of which is indeed
  not the target person — produce garbage embeddings with nearest-neighbor
  cosine ≤ 0.06 to the rest of the set. They match nothing (probe frames
  are orientation-corrected): dead weight, not the FP driver. The loader
  EXIF defect is real but fixing it changes production behavior — filed as
  a follow-up lever, out of C2's one-change scope.
- Quality flags: 4 faces < 100 px min side (57–82 px); detection
  confidence range 0.67–0.87; raw embedding norms 0.8–52 (norm did not
  correlate with cohesion; not used for curation).
- Consequence for the planning inference: the cosine-0.87–0.94 NotDonna
  matches are **not** explained by non-target references. Age-band
  confusers genuinely reach those scores against true-Donna references
  under the production pipeline (bbox crop, landmark alignment off).
  Measured below: no global threshold separates this corpus.

## The cycle-2 rule

At reference-load time in the person-eval CLI (in memory only — the
reference folder is never modified; see Scope above):

1. Embed all reference faces exactly as before (same enumeration order,
   detection filter, crop, alignment, embedding).
2. Build a graph: edge between two reference faces iff cosine ≥
   `minClusterLink` (**0.35** in the candidate config).
3. Keep only the largest connected component; drop satellite components.
4. Safety: if no component has ≥ 2 faces, fall back to keeping everything
   and surface `calibrationFellBack: true` — the audited arm degrades to
   legacy rather than silently gutting recognition.

Given the audit findings, the rule's measured value on this corpus is
**not** bystander removal (none were operative) but false-positive-surface
reduction: the confuser clips' best matches concentrated in the
era-fragmented satellite references, and dropping those cost zero corpus
recall (2×2 below).

## Working-evidence sweep (NOT the official grade — codex owns that)

`tools/poi-c02/threshold_sweep.py`, Release build, dynamic corpus enumerated
at run start (13 Donna / 13 NotDonna). Corpus fingerprint as recorded at
capture time (recipe then: sha256 over sorted relative filenames + byte
sizes): `5738f448735f234e1054f9adf21f71168f73d559f0cc59dd8eb9846c43c8934e`.
(The tool has since moved to content-hash fingerprints; captures carry their
provenance either way.) Presence = any hit (`hits > 0`), matching the graded
`presence` field on this branch. One capture per clip per arm at the loosest
threshold with `--emit-hit-distances`; stricter thresholds computed exactly
offline (a hit at t ⇔ recorded distance ≤ 1 − t). Full curves and per-clip
captures with provenance: `/private/tmp/poi-c02-artifacts/arm-*/sweep.json`.

Balanced accuracy (condensed; t = cosine threshold):

| arm | refs used (realized) | t 0.40 | 0.48 | 0.56 | 0.58 | 0.61 | 0.64 | 0.66 | 0.67 | max BA |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| legacy (all faces) | 31 | 0.500 | 0.500 | 0.538 | 0.538 | **0.577** | 0.577 | 0.577 | 0.538 | 0.577 @ 0.61–0.66 |
| audited link 0.35 | 16–23 | **0.577** | **0.577** | **0.577** | 0.538 | 0.538 | 0.462 | 0.500 | 0.500 | 0.577 @ 0.40–0.56 |
| audited link 0.25 | 24–28 | 0.500 | 0.500 | 0.500 | 0.538 | 0.462 | 0.462 | 0.462 | 0.462 | 0.538 @ 0.58–0.59 |

2×2 at the chosen operating point (audited 0.35 @ t 0.48): **TP 13, FN 0,
FP 11, TN 2 → TPR 1.000, TNR 0.154, BA 0.577.** Legacy at production
defaults (t 0.40) on the same runs: TP 13, FN 0, FP 13, TN 0 → BA 0.500.

### Explicit negative result (as codex predicted)

In these working runs, **neither a tightened global threshold alone nor
curated references plus threshold EXCEEDS balanced accuracy 0.576923** (the
acceptance bar). The candidate *ties* it. What the candidate buys is
robustness, not a higher peak:

- Legacy reaches 0.577 only at t 0.61–0.66 — a knife edge 0.003 below the
  weakest positive's best cosine (0.664); one drift-flip from a recall
  loss.
- The candidate reaches 0.577 on a 0.16-wide plateau (0.40–0.56) with
  recall 13/13 and ≥ 0.08 cosine margin to the weakest positive (0.563) at
  the chosen mid-plateau t = 0.48.

If the grader's paired runs land the same way, C2 fails the strict bar and
that is the honest outcome to record: reference hygiene + global threshold
are exhausted as levers on this corpus. The separators the data points to
are rule-out attributes (C3, already queued) and margin/second-best-
reference discrimination ("Future levers").

## Operating point rationale

- `minClusterLink 0.35`: the value at which the confuser-matching satellite
  references separate from the dominant component. Link 0.25 keeps them
  (curve ≈ legacy; max BA 0.538): measured, not assumed.
- `matchThreshold 0.48`: mid-plateau. Every t in 0.40–0.56 makes identical
  decisions on this corpus; 0.48 maximizes two-sided margin (≥ 0.08 to the
  recall cliff at 0.563, ≥ 0.08 above the plateau floor 0.40) instead of
  chasing a knife-edge peak — extra important given the reference-set
  membership drift measured below. Deliberately conservative: the corpus is
  26 development clips; optimizing harder on it would be overfitting.

## Nondeterminism (documented, not averaged away)

ArcFace inference here is not bit-stable run to run; each CLI invocation
re-embeds and re-clusters the references. Measured, Release build:

- Same-face cross-run cosine on the reference set: min 0.982, mean 0.999
  (31 faces, back-to-back audits).
- That ±0.02 is enough to flip single-link chains: across the 26 candidate
  captures the realized kept set (`referencesUsed`) ranged **16–23** (mode
  19); at link 0.25, 24–28. Membership at 0.35 is strongly drift-sensitive
  even though the *decisions* held: the candidate curve above is computed
  from those 26 independently-realized variants and still shows the flat
  0.40–0.56 plateau at BA 0.577. This is a real weakness of the
  cluster-at-load candidate — the grader will see it directly in
  `referencesUsed`, and per-file AB/BA pairing (codex's protocol; 25/26
  pairs changed raw stats in C1) is the right mitigation.
- Debug and Release numerics differ more than Release run-to-run; all
  evidence in this cycle is from the Release build codex grades.
- Sweep outputs flag drift-sensitive clips (best cosine within 0.02 of a
  sweep threshold) per arm (`boundaryCases` in `sweep.json`); at t 0.48 the
  nearest clip in the candidate captures is 0.08 away from the boundary.

## A/B reproduction (grader)

Release build, same binary both arms, per-file AB/BA pairing:

```
# legacy arm (production defaults; complete unchanged reference set)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10

# candidate arm (calibrated reference set + operating point)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10 \
    --reference-calibration audited --calibration-link 0.35 \
    --calibration-threshold 0.48
```

Grade `presence` (`"confirmed"` ⇔ hits > 0; the video-level rule is
unchanged legacy any-hit — C1's aggregation branch is unmerged and not on
this branch). Config attribution: the candidate's emitted
`referenceCalibration` must hash to `bd51533452…d6f6ce4b`. Corpus
fingerprint discipline unchanged: enumerate `Donna/` + `NotDonna/` at run
start and stamp the fingerprint alongside the 2×2 and config hash.

## A/B surface (CLI, schemaVersion 2 — additive)

- `--reference-calibration legacy|audited` — the A/B switch (legacy is the
  default and preserves the pre-C2 recognition rule (all loaded reference
  embeddings remain eligible, in loader order); pinned by pass-through
  test). Legacy **recognition behavior is unchanged**, but the CLI JSON is
  **not byte-identical** to pre-C2 output: schemaVersion 1 → 2 with
  additive fields; existing keys keep their names, types, and semantics —
  the same additive discipline as C1's grading contract.
- `--calibration-link X`, `--calibration-threshold X` — per-parameter
  overrides, folded into the hashed config object.
- Output adds: `presence` ("confirmed" ⇔ hits > 0 — the video-level rule is
  unchanged legacy any-hit; C2's change is upstream), `referenceCalibration`
  (config object), `referencesLoaded`, `referencesUsed`,
  `calibrationFellBack`, and (with `--emit-hit-distances`) `hitDistances`
  so the grader can report threshold sensitivity from a single run.
- `--audit-references` — reference-set audit report (per-face provenance,
  detection confidence, face pixel size, raw embedding norm, cluster
  decision, skipped files with reasons). No video processed; read-only.
  **Sensitive local biometric data:** this JSON contains raw face embeddings,
  absolute reference paths, and filenames. Keep it private and local. It must
  not be committed, attached to GitHub/issues, placed in shared/public
  reports, or copied into application logs. Publish only aggregate counts and
  configuration after removing paths, names, and embeddings.
  An audit always executes audited clustering, so its emitted
  `referenceCalibration.mode` is always `"audited"` — the run and the
  reported config are a single value by construction, and combining
  `--audit-references` with `--reference-calibration legacy` is rejected
  at parse time (config provenance can never claim a mode that didn't run).
- Emitted-config truthfulness on the legacy arm: a legacy ArcFace eval
  reports `matchThreshold` as the operating point actually used
  (`--threshold` or the production default 0.40). `--calibration-link` /
  `--calibration-threshold` are rejected outside audited/audit runs — they
  would alter the emitted config without changing the run. The
  `referenceCalibration` object applies to ArcFace only; other engines emit
  the legacy defaults.

## Sensitive-data rule (formal, applies to every C2 artifact)

Raw face embeddings and absolute reference paths/filenames are **sensitive
local biometric data**. Classification rule for this cycle and all POI
work:

- Forbidden in: git commits (any branch), GitHub issues/PRs/attachments,
  shared or public reports, application logs
  (`~/Library/Logs/VideoScan/*`), and the team channel.
- Permitted in: local `/private/tmp` artifact directories only (e.g.
  `/private/tmp/poi-c02-artifacts/`), consumed in place by the grader.
- Committed documents (this one included) carry only aggregate counts,
  cosine statistics, and configuration objects/hashes — no reference
  filenames, no per-file hashes, no embeddings.

This is why the refset manifests and audit dumps are generated on demand
and never checked in.

## Disclosed risks

- **Multi-era recall risk:** the kept dominant component is modern-era-
  heavy; middle-era references land in the dropped satellites. On a
  multi-era archive (the real catalog) the audited rule could cost recall
  that this all-young-Donna dev corpus cannot measure. The corpus is 26
  clips, development tier, not a holdout — every number above carries that
  caveat.
- Disclosed FN risk stands as designed: if a dropped face were the only
  reference for some era, clips from that era lose their match. The A/B
  grade's full 2×2 (FN row included) is the check — no concealed FN cost.
- Reference-set membership drift (16–23 realized) is disclosed above; a
  stability fix (e.g., averaging reference embeddings over k repeats, or
  freezing a vetted embedding snapshot) is a follow-up lever, not smuggled
  into C2.
- If C2 fails: revert is this single branch (unmerged).

## Future levers surfaced by this cycle's data (out of C2 scope)

1. **Margin / second-best-reference discrimination:** confusers matched the
   satellite references best; a top-minus-second-match margin or
   per-reference attribution term separates cases a global threshold
   cannot.
2. **EXIF orientation in the reference loader** (garbage-embedding defect;
   production behavior change — its own cycle + tests).
3. **Reference-embedding stability** (see membership drift above).
4. Landmark alignment on for reference AND probe crops.
5. Quality-weighted track pooling (already adopted as the C4 candidate).

## What was touched (attribution / revert range)

- **New:** `VideoScan/VideoScan/ReferenceCalibration.swift`;
  `tools/poi-c02/` (audit analysis, threshold sweep, refset materializer,
  corpus-manifest builder — `tools/person-eval/` and the corpus untouched);
  this doc.
- **`ArcFaceEngine.swift`** — detailed reference loader (per-face label,
  confidence, pixel size, raw norm, skip reasons) that the production
  loader delegates to (behavior-identical); `arcfaceEmbeddingWithNorm`;
  per-hit distances captured in the ArcFace result.
- **`PersonFinderTypes.swift`** — additive `pfVideoResult.hitDistances`
  (defaulted; empty for non-ArcFace engines and cache restores).
- **`PersonEvaluationCLI.swift`** — flags and schemaV2 additive output as
  listed above; truthful-config plumbing.
- **Tests:** `ReferenceCalibrationTests.swift`,
  `PersonEvaluationCLIConfigTests.swift`,
  `PersonEvaluationCLIIntegrationTests.swift`.
