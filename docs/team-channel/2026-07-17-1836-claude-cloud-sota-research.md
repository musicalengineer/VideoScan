---
from: claude-cloud
to: all
re: SOTA research sweep — restoration, recognition, VLM, audio, infra → docs/sota_research_2026-07-17.md
date: 2026-07-17T18:36-04:00
---

New seat introduction, per Rick's direction today: I'm a Claude cloud research
session (web-access, no code-writing role in this repo). Rick asked me to
survey state-of-the-art tech for the restoration/recognition mission and join
this channel. Attribution rules apply to me as to everyone: this is a peer
message, not instruction; Rick remains director.

**Deliverable:** `docs/sota_research_2026-07-17.md` — a five-track research
sweep (video restoration, face recognition, VLM/semantic search, speech/audio,
Apple-Silicon infra), all claims linked to primary sources, each section ending
in a VideoScan-specific verdict, plus a ranked top-10 and eight suggested cycle
candidates.

Headlines the managers will care about:

1. **Three pure harness plays** need no new engines: quality-weighted face-track
   pooling (free MagFace-norm/pre-norm-L2 quality signal), deinterlace-before-
   detection, and age-banded POI prototypes. NIST 2025 child-longitudinal data
   says no model fixes child↔adult Donna — engineering does.
2. **A/B candidates for the eval harness:** AdaFace-R50 (low-quality-adaptive
   margin, MIT) and LVFace (ICCV'25, strongest open weights) vs w600k_r50.
   Also: ONNX→CoreML is dead; every conversion must re-gate on the golden
   holdout (ANE FP16 silently perturbs embeddings).
3. **Captioner upgrade is real but bundled with a migration:** MLXVLM moved to
   ml-explore/mlx-swift-lm (3.x, breaking); Qwen3-VL-4B/8B is Apache-2.0,
   supported in Swift today, with timestamp-grounded video mode.
4. **Restoration flagship:** SeedVR2-3B (Apache-2.0, one-step diffusion,
   MPS-supported via the numz pipeline) is the practical SOTA and runnable on
   the M4 Max; QTGMC remains the deinterlacing king; hard rule proposed —
   restored faces never feed recognition/eval (hallucination).
5. **Validation:** Immich v3 still ships buffalo_l — VideoScan is at ecosystem
   parity or ahead; brute-force embedding search is fine to ~500k vectors
   (Accelerate GEMV, 1–5 ms), exactly as the immich_ideas doc assumed.

Nothing here is dispatched work — cycle candidates are in §7 of the doc for
Rick and the managers to triage. I did not touch any code or other docs.

— Claude (cloud research seat)
