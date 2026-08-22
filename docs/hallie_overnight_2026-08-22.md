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

## Claude cycle 2 — 00:13–00:55 — fa956012
**Before** (= cycle 1 after, 4c652e69; main had not moved): 200-Q **73%**, interaction **94%**.
**Fix:** catalog-wide numbers. "How much footage is there altogether?", "how many are archived", "how many duplicates", "How much disk space does the whole archive take up?", "how many years of footage" were reaching the translator as empty searches. Now recognised before translation by a closed vocabulary (a name, place, year or any other content word → still a real search) and answered from one snapshot computed from the records the client already holds — the same totals as the Storage footer and the Archive progress bar. Fixed text; the model never re-phrases numbers. No new AST shape, translator untouched. Real answers tonight: *"There are 4,048 media files in the catalog across 8 volumes — 3,038 unique once the duplicate copies are set aside."* · *"About 401 hours (17 days of playing time) of footage altogether."*
**After:** 200-Q **76%** (149/197; catalog_count 70→90, temporal 65→70), interaction **94%** (flat).
**Tests:** HallieCatalogStatsTests (5, incl. 100k-record budget); battery 317/317. Lint debt noted: `HallieShellCLI.answer()` is at cyclomatic 39 (pre-existing; my 3 lines nudged it) — a refactor cycle, not a night one.
**Spotted for cycle 3 (my lane):** a composed list answer read *"Two examples are Item 1 and Item 2"* — the model echoed the claim labels as if they were names and the verifier let it through. The verifier should drop a sentence that names "Item N" literally (the labels are plan scaffolding, never prose).
**Still not mine:** grandparent_style 8% and the temporal turns that need a selected video (the headless eval has none).

## Claude cycle 3 — 01:13–01:50 — 59cdc38d
**Before** (= cycle 2 after): 200-Q **76%**, interaction **94%**.
**Fix:** composed list answers were saying *"Two examples are Item 1 and Item 2"* — the model echoing the plan's claim labels as if they were names, and the verifier (which checks leaks, not scaffolding) letting it through. Eight such answers across the two corpora. Three layers: item claims are now sentences ("One of them is Cape_1993.mov — confirmed person tag Donna."), so there is no label to echo; the verifier drops any sentence naming "Item N" / "claim N" / "cN"; the prompt says so in words. The exact-filename rule understands both claim shapes; counting words up to the number of cited claims are vouched by construction.
**After:** 200-Q **76%** (flat), interaction **93%** (−1 turn, noise). Scaffold leaks: **8 → 0**; answers now read *"One of them is Cape-1992-archive.mkv. Another is Cape-1993-archive.mkv."* This was a quality fix the grader can't see — it doesn't score wording — but Rick will.
**Tests:** scaffoldLabelsNeverReachTheReader + pin updates; battery 317/317.
**Next (my lane):** "the boys" / "all four boys" as an any-of identity (cc011 declines today: "I don't have any videos tagged with all four boys"); presence people are ANDed and the AST has no any-of — needs a small executor-side expansion (kin phrase → the owner's children by name, OR'd) without touching the translator.

## Claude cycle 4 — 02:13–02:50 — 256da75a
**Before** (= cycle 3 after): 200-Q **76%**, interaction **93%**.
**Fix:** two wrong-person answers. (1) *"did my dad have brothers or sisters"* was answered about **Rick** — the family-tree route bound "my" to the owner and dropped "dad". SpeakerKinship now runs on that route before pronoun binding, except when the translator already made the phrase the query's own relation ("who is my father" must not become the father's father). It now answers about Richard Harding Breen **Sr** — and honestly says the tree records no siblings for him. (2) *"show me Timmy as a baby"* / *"Donna and Timmy together"* asked "Did you mean Tim or Timmy?" because Tim's profile lists "Timmy" as an alias; a name typed exactly as a profile's own name now wins over alias matches. Real answer tonight: *"There are 2 catalog items matching that request. Donna is confirmed in both of them. Timmy is also confirmed in both of them."*
**After:** 200-Q **77%** (151/197; catalog_search 75→81), interaction **94%**.
**Tests:** 2 new; battery 319/319.
**Next (my lane):** "when did they get married" — a bare pronoun reaching the tree route as a name ("I don't find 'they'… tell me about They"); resolve from the last answer's people or decline by asking who. Then "the boys" any-of (needs a family-word → names mapping; the tree stops in 1959 so the sons aren't in it — honest decline + telling door until Rick tells her who the boys are).

