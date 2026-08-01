# Donna Recipe v1 — per-person auto-tagger spec

Status: DESIGN — awaiting Rick + codex review. 2026-08-01.
Inputs: deep-research digest + Immich/PhotoPrism audit (docs/research/), POI
C-cycle assets (C1 aggregation, C2 calibration tools, C3 minimum-hits, C4
donna-lr-v1.json — resurrected to main 84959e4), Donna reference gallery
(Rick assembling: DonnaRefs/{1970s,1980s,1990s,2000s}/ 5–10 photos each).

## Principle

One person, one recipe. "Is this Donna?" with priors — never "who is this?".
Auto-tags write ONLY machine tiers (suspectedPeople / detectedPeople) with
provenance; confirmedByUserPeople stays human; rejectedPeople is a veto the
recipe must honor (PhotoPrism veto-list pattern). Goal metric: search recall
for Donna by year — not forensic certainty. Everything graded on benchmarks
BEFORE touching the catalog (era-stratified: research finding 9 says no
published number can be trusted for our worst footage).

## Pipeline (stage → tool → research basis)

1. **Sample + decode**: ffmpeg frame sampling (~2–4 fps), deinterlace (C5
   learning: yadif), duration-scaled representative offsets as sanity anchors
   (PhotoPrism steal #video).
2. **Detect**: SCRFD **10G tier minimum** via ONNX Runtime (CoreML EP — Immich
   proves the path on Apple Silicon). 0.5G-class detectors silently drop the
   small faces that matter (17-point Hard-set gap).
3. **Track**: IoU-based association within shots (v1: simple greedy IoU linker;
   ByteTrack-class upgrade is a SPIKE — research had zero surviving claims on
   tracking degraded/interlaced footage, so we measure our own).
4. **Two-tier quality gates** (PhotoPrism, production-tuned): record faces
   ≥ ~25px, but only faces ≥ ~60px + high detector confidence may VOTE identity.
   Small faces can be matched later; they never define presence.
5. **Attribute gates**: MiVOLO adult + female gate with body-only fallback for
   tiny faces. Kills the Donna↔boys/Rick confusion class structurally. (Blonde
   gate: v1 optional cheap hair-region hue check on high-quality tracks only.)
6. **Best frames**: CR-FIQA top-K (K≈5) per track → embedding candidates.
7. **Verify**: AdaFace embeddings vs ERA-BANDED Donna gallery (match footage
   era to reference band; C2 audit_references/make_refset validate the gallery
   first) → donna-lr head (C4) → per-person calibrated threshold (C2 sweep on
   the benchmark; global cutoffs are provably miscalibrated).
8. **Aggregate per video**: track votes → C1 score-based presence aggregation +
   C3 minimum-hits floor. Cannot-link sanity: two simultaneous same-frame faces
   can't both be Donna.
9. **Emit**: per-video Donna presence score → suspectedPeople ("Donna") above
   the low bar, detectedPeople above the high bar, never confirmed; provenance
   sidecar (recipe id, version, score, date). Respect rejectedPeople. Per-year
   rollup report (year index already in catalog) = Rick's "find her by year".

## Grading gates (in order, all must pass before catalog-wide run)

- G1: reference gallery report card (C2 tools) — internal consistency per era.
- G2: donna-dev-27 — must beat C3's 0.615 graded score, FN=0 preserved.
- G3: NEW era-stratified benchmark (~40–60 clips Rick spot-labels across
  decades/quality tiers, incl. Donna-absent parties with other blonde adults) —
  the honest number for the degraded end. Blind holdout protocol as C3/C4.
- G4: pilot on ONE volume, review queue in the existing blind-review UI;
  precision eyeballed by Rick before fleet-wide sweep.

## v2 levers (explicitly deferred)

- Self-supervised embedding fine-tune on our own face tracks (VideoClusterNet
  pattern) if G3 shows the domain gap dominating.
- Voice/speaker channel + transcript name-mention mining (research came back
  silent — promising, unverified).
- Collision-radius shrinking + ambiguous-state mechanics (PhotoPrism) when a
  second recipe (Rick) exists to collide with.
- Recipes for Rick, Dad ("grey-haired older white male" gates), Ma.
- Kids child→adult: OUT OF SCOPE by design.

## Risks, named

- Tracking on interlaced footage is unmeasured anywhere — hence the spike + G3.
- MiVOLO weights licensing is messy for redistribution (fine for personal use).
- ONNX/CoreML conversion friction for SCRFD/MiVOLO on Apple Silicon — Immich's
  provider list says it works; our spike confirms.
- Worst-tier footage may bottom out regardless (finding 9) — the machine-tier
  design means partial coverage still pays: every confident hit is a video Rick
  never has to scrub.
