# Per-person detector recipes — deep research digest (2026-08-01)

108-agent adversarially-verified research pass on the "Donna recipe" strategy
(per-person detectors over degraded home video). Each finding survived 3-vote
refutation attempts; refuted claims are listed as such. Companion to the
Immich/PhotoPrism source audit (immich-photoprism-face-audit-2026-08-01.md).

## Verified findings

1. **Detection — SCRFD, and the compute tier IS the small-face recall dial** (high).
   WIDER FACE Hard AP: SCRFD-34G 85.29 / SCRFD-10G 83.05 / SCRFD-0.5G 68.51;
   RetinaFace-R50 64.17 at 4x the latency of 10G. Budget ≥ the 10G tier for
   VHS-era footage — the light tier silently drops exactly the faces that matter.
   [insightface SCRFD; arXiv:2105.04714]

2. **Best-frame selection — quality = RECOGNIZABILITY, learned, not aesthetics**
   (high). Mature FIQA lineage: SDD-FIQA (CVPR21), CR-FIQA (CVPR23 — public code,
   scores generalize across FR backbones → practical pick), Recognizability Index
   (CVPR23 — conceptually best for very-low-res, no confirmed public code).
   Use a FIQA scalar to pick the top-K frames per track for verification.

3. **Attribute gates — MiVOLO (face+body fusion)** (high). 99.46% gender / 4.24 age
   MAE with face+body; degrades gracefully to BODY-ONLY (96.48% gender, 6.87 MAE)
   when the face is too small/blurry — precisely the VHS failure mode where
   face-only attribute models fail outright. License: repo Apache-2.0 since
   2026-03 but weights ship separately w/ conflicting metadata — fine for
   personal use, re-check before any redistribution. [arXiv:2307.04616]

4. **Per-person calibrated thresholds beat any global cutoff** (high). The same
   cosine distance means different match probabilities in different regions of
   embedding space (Brown & Russell 2026; Doddington menagerie lineage). Directly
   validates the donna-lr learned head + C2 per-person threshold sweeps over a
   universal threshold. [arXiv:2606.04469]

5. **Cross-age 22–50 is NOT the binding constraint** (medium). AgeDB-30 (30-year
   gaps — larger than any within-band gap after era-banding) holds AUC ~0.95 for
   FaceNet/ArcFace; original ArcFace reports 98.15% on that protocol. Era-banding
   shrinks gaps further. The binding constraint is image DEGRADATION, not age.

6. **Track-level judgment + free constraints are canonical** (high). Video face
   clustering is defined over TRACKS; tracks yield free must-links (within-track)
   and cannot-links (same frame / temporally overlapping tracks); constraints are
   worth ~11–15 absolute accuracy points; uniform track subsampling + mode-label
   voting cuts cost without hurting accuracy. [Wu CVPR13; ConPaC]

7. **Constraints cannot rescue a bad embedding** (medium, 2-1 vote on one leg).
   On low-quality imagery, constraint satisfaction collapses on exactly the hard
   pairs (3% of targeted must-links satisfied on IJB-B-1024). Embedding quality
   is the load-bearing component; constraints are seasoning.

8. **Domain adaptation matters on degraded footage** (medium). Generic embeddings
   degrade out-of-domain (VideoClusterNet ECCV24; DArFace 25; FaceMoE 26).
   Reusable pattern: SELF-SUPERVISED fine-tune on the corpus's own face tracks
   (temporal identity-consistency — no labels needed). v2 lever, not v1.

9. **No trustworthy accuracy numbers exist for worst-case footage** (high — as a
   negative result). Every claim pinning low-res/surveillance-grade accuracy was
   REFUTED (TinyFace ~77% rank-1; SurvFace AUCs). Consequence: build our OWN
   era-stratified benchmark (extend donna-dev-27) and trust nothing else.

## Coverage gaps (silence, not negative findings)

- Voice diarization / speaker embeddings and transcript name-mention mining:
  zero surviving claims — still open, still promising, unverified.
- Photo-manager internals: covered instead by our own source audit (companion doc).
- VLM reference-photo verification: zero surviving claims.
- TRACKING specifics (ByteTrack/SORT/SAM 2 on interlaced footage): no surviving
  claims — needs an in-house spike.
- Nearly all verified numbers come from clean/celebrity benchmarks; degraded-end
  expectations are extrapolation (see finding 9).
