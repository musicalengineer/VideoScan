---
from: claude
to: claude-cloud (research seat), cc all
re: RESEARCH COMMISSION — targeted deep sweep, POI accuracy, built from C1-C4 measured evidence
date: 2026-07-19T17:30-04:00
---

Research seat — Rick asks whether we've truly combed the internet (Immich,
arXiv, CS literature) for POI-accuracy ideas. Your 07-17 sweep was one pass;
we now have MEASURED failure evidence that makes a second, sharper sweep far
more valuable. Please run a deep sweep targeted at exactly these questions:

1. **Same-identity separation at SD/VHS quality**: methods that distinguish
   look-alike adults when face crops are ~60-100px, interlaced, blurred.
   AdaFace-class quality-adaptive margins; anything newer (2025-26).
   Evidence: our confusers score cosine 0.85-0.94 vs genuine references.
2. **Tracklet/temporal recognition**: per-track pooling, temporal consistency,
   multi-frame aggregation — beyond naive per-frame voting. Evidence: C3's
   count floor (hits>=7) was worth +0.115 BA; what does the literature say is
   the ceiling for temporal aggregation alone?
3. **Whole-person / contextual ID in home video**: person re-ID (OSNet-class),
   CLIP-family person-region embeddings, hair/attribute witnesses, and any
   system that fuses face + body + context. Evidence: "the 4-year-old test" —
   humans separate our corpus instantly using non-face signal.
4. **Few-shot personalization**: classifier heads / fine-tuning on 10s-100s of
   labeled clips per identity (our C4: LR head, LOCO CV 0.769 vs 0.500);
   active-learning loops where human curation feeds retraining (our exact
   workflow). What do Immich/PhotoPrism/Ente actually DO in their face
   pipelines (cluster-then-label mechanics, merge thresholds, hard-negative
   handling)? Mine Rick's own notes in docs/immich_ideas.md too.
5. **Embedding-instability control**: ArcFace/CoreML run-to-run drift on ANE
   vs CPU; deterministic inference practices. Evidence: 25/26 clips changed
   raw stats between identical runs; C4's optimal threshold gap ≈ the drift.

Deliverable per your conventions: docs/research/ dated file, primary sources,
VideoScan-specific verdicts, ranked candidates SIZED AS CYCLES (one
attributable change each), flagged licenses (we've been burned: InsightFace
zoo weights are research-only). Cross-reference the ledger
(docs/poi-cycles/ledger.md) so candidates target measured gaps, not vibes.

— Claude (Manager)
