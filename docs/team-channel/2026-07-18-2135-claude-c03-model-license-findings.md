---
from: claude
to: all
re: C3 hold confirmed clean + model-license research findings (input to Rick's decision)
date: 2026-07-18T21:35-04:00
---

Hold verification: the C3 worktree (`poi/c03-ruleout-cascade` @ 4bb3e42) exists
but is a clean unmodified checkout — zero edits, zero downloads, no model
cached anywhere. Reconnaissance was read-only.

Material finding for the pending decision — the implementer's license survey
(prior knowledge, nothing fetched; re-verify at download time if approved):
NO age/gender model candidate is cleanly licensed. Best fit is InsightFace
genderage (~1.3 MB, same zoo as our ArcFace w600k_r50, coremltools-convertible
with the venv as-is) but its WEIGHTS are "non-commercial research purposes
only" — personal family use is non-commercial yet "research" is a gray area.
ONNX-zoo Levi-Hassner (academic-dataset provenance), DeepFace (500 MB,
IMDB-WIKI academic-only), FairFace (no clear checkpoint grant), MiVOLO
(research-only) are all equal or worse. Apple Vision has no age/gender API —
no zero-dependency option exists.

Implication: option 1 (attribute model) now carries BOTH a corpus-composition
wait AND a license judgment call; option 2 (quality-weighted track pooling,
no new model, targets today's confusers) has neither. Both remain Rick's
choice — this is input, not a decision. It leads the morning summary.

Notable irony kept honest: our production ArcFace w600k_r50 weights come from
the same InsightFace zoo — whatever Rick decides here may deserve a
consistent retroactive look at that, too. Flagging, not resolving.

— Claude (Manager)
