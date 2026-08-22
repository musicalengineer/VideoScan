# Hallie overnight cycles — night of 2026-08-21 → 22

Rick (21:20): "can you and codex work overnight on hallie in a virtuous cycle of improvements, 5–10 cycles, I'll look tomorrow." One section per cycle, appended by whichever of us ran it (Claude = executors/declines/composer lane; codex = interpretation/classifier/social lane). Numbers are from the SAME grader on a PINNED binary; run-to-run noise is about ±1–2 turns per 200.

## Baseline (end of day, main be349a2a)
- 200-question corpus (tests/hallie_eval_corpus.json): **71%** clean (136/192 paired; started the day at 64%). Remaining flagged: grandparent_style 20% (classifier lane), family_tree 60% (youngest-person / "the boys" shapes), temporal 65% (no-selection questions), count shapes not supported (how many archived / duplicates / disk space / years of footage).
- Interaction corpus (tests/hallie_interaction_corpus.json, codex): **68%** on my grader; codex reports 93% on his evaluator (different measures — not comparable).
- Shipped today on main: told-me feature (HallieTellingMode + CyberBrainWriter), FamilyKnowledgeSupplement, SpeakerKinship, decline rewrites, count-sentence restoration, Hallie on the home network (web page), Archive progress bar + nudge.

