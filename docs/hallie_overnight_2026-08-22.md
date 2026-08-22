# Hallie overnight cycles — night of 2026-08-21 → 22

Rick (21:20): "can you and codex work overnight on hallie in a virtuous cycle of improvements, 5–10 cycles, I'll look tomorrow." One section per cycle, appended by whichever of us ran it (Claude = executors/declines/composer lane; codex = interpretation/classifier/social lane). Numbers are from the SAME grader on a PINNED binary; run-to-run noise is about ±1–2 turns per 200.

## Baseline (end of day, main be349a2a)
- 200-question corpus (tests/hallie_eval_corpus.json): **71%** clean (136/192 paired; started the day at 64%). Remaining flagged: grandparent_style 20% (classifier lane), family_tree 60% (youngest-person / "the boys" shapes), temporal 65% (no-selection questions), count shapes not supported (how many archived / duplicates / disk space / years of footage).
- Interaction corpus (tests/hallie_interaction_corpus.json, codex): **68%** on my grader; codex reports 93% on his evaluator (different measures — not comparable).
- Shipped today on main: told-me feature (HallieTellingMode + CyberBrainWriter), FamilyKnowledgeSupplement, SpeakerKinship, decline rewrites, count-sentence restoration, Hallie on the home network (web page), Archive progress bar + nudge.

## Claude cycle 1 — 23:13–00:05 — 4c652e69
**Before** (main f966ed7d = your evening + codex's 87a21a4d/5ce7c75b): 200-Q **73%** (143/197), interaction **92%** (184/199). Codex's evening work moved the interaction corpus from 68% to 92% on my grader — smalltalk/persona/safety all 100%.
**Fix:** provenance follow-ups. "Where did that come from?", "Which records support that biography?", "How certain are you about that date?" were landing in keyword search or a vague model disclaimer. Hallie now keeps each archive answer's trail (route, basis line, cited files, family-knowledge citations, whether tags were person-confirmed, whether anything is "not yet verified") and answers those questions from it, deterministically — never the model. A lead plus only back-references counts ("how do you know that"); a lead plus a name ("how do you know Donna") still searches. "Play the first one" keeps working after asking.
**After:** 200-Q **73%** (flat — no provenance turns in that corpus; within ±2 noise), interaction **94%** (187/199); the three provenance turns are clean.
**Tests:** HallieProvenanceFollowUpTests (4); 25-suite battery 312/312. **Known red on main, NOT mine:** 4 suites since codex's 5ce7c75b (HallieShellCLIFollowUpTests, HallieConversationMemoryTests ×2, HallieAppTurnCoordinatorFollowUpTests, ArchivistGoldenAnswerTests:353) — reported #567, codex's lane.
**Next (my lane):** temporal no-selection questions ("when was this filmed" with nothing selected), then count shapes (archived / duplicates / disk space / years of footage) if a cycle has room — that one needs a new AST shape and touches codex's translator schema, so I'll propose the contract on the channel first.

