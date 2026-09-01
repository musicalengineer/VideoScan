# Model strategy — one brain, two roles (2026-09-01)

Rick's question: should Hallie and the code reviewer (and Swift-specific
review, test design, metrics help) use separate local models, or one model
for everything? And which model gives the most convincing "librarian
archivist" conversation?

## Decision

**One model, `qwen3.8:27b-mlx`, for every role, until the hardware changes.**
The reviewer is a *role* (a prompt, a harness, a schedule), not a second
model. Nothing installed or installable on a 64 GB machine beats it at either
job, and the evidence says Hallie's remaining quality gaps are not in the
model at all.

## Evidence

| Measurement | Result | Source |
|---|---|---|
| Hallie, Rick's own 214-question corpus, new vs old model | 77% vs 78% — a tie | 2026-09-01 eval |
| Four "Hallie is dumb" failures this week | all four deterministic plumbing; a better model fixes none | 2026-09-01 memory |
| Fitness corpus (code review, history, abstention, AST) | 3.8 dense 29/29; 3.6 dense 28/29; MoE baseline code review 7/10 | `model-fitness-20260831-2124/run.log` |
| Reviewer on 21 real, believed-correct commits | 18 quiet, 3 flagged, 2 of 3 genuine; 14% flag rate | `real-review-overnight.log` |
| Speed | 3.8 dense faster than the MoE on 4 of 6 categories | 2026-08-31 bake-off |

The fitness corpus is saturated (two models at 29/29), so it can no longer
separate candidates. Any future candidate must be judged on
`review_real_commits.py` over real commits and on the Hallie corpus, never
on the synthetic corpus alone.

## Why not a separate code-review model

- **No candidate.** The only argument for a second model is a coder-tuned
  model that beats 3.8 dense on *our* review corpus. Installing one costs
  ~18 GB and an evening; the harness to judge it already exists
  (`tools/model-fitness/run_fitness.py`, `review_real_commits.py`). Do that
  experiment before adopting anything.
- **Memory.** Two resident 27B models is 36 GB before Xcode, the app, and
  the 7k-record catalog. On the M4 they would page each other out; Ollama
  reloads cost 10–20 s per swap, which is exactly the cold-start that was
  making the composer fall back to templates.
- **The reviewer's failure mode is count bias, not intelligence.** What it
  misses means nothing; what it flags is worth reading twice. A second
  model does not change that; a second *reader* (Claude's qa agent, codex
  when he is back) does.

## Where a split WOULD pay — the hardware question

If a second machine with its own GPU memory appears:

1. **Reviewer host.** Run the nightly review and on-demand `--staged`
   reviews there, so the M4 never swaps models mid-conversation.
2. **Escalation tier for Hallie.** The 2026-09-01 finding was that
   per-domain routing is pointless (3.8 wins or ties everywhere) but
   *escalation on failure* — a stronger model only when the 27B declines or
   the verifier rejects its phrasing — needs a model above 27B dense. That
   is the first thing more memory buys.
3. **Bigger context for composition** without the 20 s translation budget
   suffering.

## How Hallie answers a query (the librarian architecture)

Swift owns the facts; the model owns language. Order of operations per turn:

1. **Split** — `HallieQuestionSplitter`: a cross-shape conjunction ("where
   was Martha Lamson born and when was she born") becomes two questions,
   the pronoun bound to the name in the first. On by default in shell, app
   and web as of today; `VIDEOSCAN_HALLIE_SPLIT=0` is the kill switch.
2. **Continuity** — `HalliePronounContinuity`: "did she have kids" takes
   the last answer's person before any model call.
3. **Modal owners** — reset, picker, name drill, pronunciation, telling,
   photo caption: deterministic, no model.
4. **Translate** — the model turns the question into one `ArchivistQueryAST`
   shape under a strict JSON schema (temperature 0). This is the model's
   first real job.
5. **Execute** — Swift: family tree (kinship, lineage, common ancestor),
   People tab profiles, catalog search/count/temporal, CyberBrain facts.
6. **World knowledge floors** — `WorldKnowledge`: a photo of someone who
   died in 1654 gets "photography begins in 1838", not a search. Film
   (1888), home movies (1923/1932), sound (1877), videotape (1975),
   camcorders (1983) are all on file. Photo and film floors are wired;
   the sound floor is not yet (see gaps).
7. **Compose** — `HallieGroundedComposer`: the model phrases a verified
   answer plan in Hallie's register (temperature 0.3, 6 s budget), and the
   verifier rejects any sentence not resting on a claim. Template on
   timeout. Keep-alive (30 m) and a warm-up on chat open landed today so
   the budget is spent on phrasing, not loading.
8. **Speak** — lexicon-driven pronunciation (`HalliePronunciationLexicon`)
   with Kokoro phoneme overrides; the model is not in this path, which is
   why the voice got "better" with the new model only where the *words*
   changed.

What this means for model choice: steps 4 and 7 are the whole model
surface. A model is good enough for Hallie when it (a) emits the schema
reliably and (b) phrases warmly without inventing. 3.8 dense does both;
the remaining misses are in steps 5–6 and in the eval corpus itself.

## Open gaps, ranked by what a family reader would notice

1. **grandparent_style (36%) — NOT the model's register.** Read every
   failure (evening of 09-01): "what was your first job", "what's your
   earliest memory", "what was your childhood home like" all came back as
   the BIOGRAPHY OF HALLIE MAE McGILL (1876–1908), the real ancestor the
   persona is named after. Second-person "you/your" was resolving to the
   namesake's tree record. Three more ended in interpretation-failed.
   Deterministic routing, fixed the same evening (persona question →
   conversation lane, never graph). Fifth "Hallie is dumb" failure this
   week whose cause was plumbing.
1b. **smalltalk (67%) — thanks, apologies, "hold on", goodbyes** were routed
   to a presence search ("I need something to look for"). Deterministic
   social detector, same evening.
1c. **Eight questions were never graded at all.** A transcript-search answer
   ("35 videos where someone says 'school'") carried every hit with every
   basis string, blew the conversation log's 256 KB line cap, and the
   whole turn was refused (`[HallieTranscript] append failed:
   eventTooLarge`). The store now trims evidence instead of dropping the
   turn. Any category can hide misses this way — check the "produced no
   matched turn" warning every run.
2. **temporal (60%)** — "was that before or after we moved" depends on
   CyberBrain facts that are not entered yet.
3. **Sound-recording floor.** "recordings of Edmund Rice's voice" should
   get the 1877 line the way photos get 1838.
4. **Research help for tree people** — `FamilyTreeResearchLinks` exists
   (archives chosen by place); Hallie should offer it when a biography is
   thin.
5. **Composition budget** — measure the template-fallback rate after today's
   keep-alive before raising the 6 s budget.

## The reviewer, 2026-09-01 → 09-07 (codex out of tokens)

- `tools/model-fitness/nightly_review.sh` runs at 04:30 (launchd
  `com.videoscan.nightly-review`), reviews every commit on origin/main
  since the last run, keeps raw verdicts under
  `~/Library/Logs/VideoScan/model-review/`, and mails a digest to Claude on
  the team channel as `reviewer`.
- On demand before a commit: `python3 tools/model-fitness/review_real_commits.py --staged`.
- Claude's `qa` subagent stays the primary reviewer; the local model is
  additive. Test design and metrics stay with the `testing` and `metrics`
  agents — a 27B local model is not a substitute there, and the harness
  numbers above say so.
