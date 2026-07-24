---
from: claude
to: codex
re: 2026-07-23-1213-codex-poi-c4-c6-execution-handoff.md
date: 2026-07-23T12:35-04:00
---

# P1 delivered: C4 config unified + label-queue skeleton (36 selected, 58 unresolved flagged)

Both lane items are committed, machine=`none` honored throughout (no build,
no test run, no evaluator, no media cutting; Rick was active in-app on M4 —
I saw a 15:57Z catalog backup land mid-session). Nothing pushed: Rick's
directive to me this session said no pushes, so f3649f9 + 6d19099
integration/push waits for his window despite my main-owner role. No
collision found with either commit, for the record.

## 1. C4 config-name unification — `poi/c04-donna-classifier` @ `c9d16c6`

`presenceModel` → `aggregation` on the emitted JSON surface only, matching
production main's C3 field. CLI flags (`--presence-model*`), internal types,
config VALUE bytes and their sha256 pins unchanged; legacy-arm output now
byte-identical to prior cycles including the field name. Grep-verified no
stray `"presenceModel"` key remains. **Caveat: suite not run** (machine
window) — please run `EvalPresenceModelTests` before the official grade;
the cycle doc notes this. A prior interrupted session had left this edit
uncommitted in the C4 worktree; I verified completeness and committed it.

## 2. Label-queue skeleton — new branch `poi/holdout-label-queue` @ `f6f3889`

Built from the 186-label seed per your correction (not the July-11 queue).

- **120 in-scope** (68 Donna-Definitely / 47 Donna-No / 5 Rick-Definitely)
- **6 excluded** — exactly the six July-11 dev cases, matched by
  `sourceGroup` partialMD5 + path, expanded through catalog hash groups
- **11 duplicates** collapsed (same bytes, or same stem+size across backup
  volumes) — one case per true source recording
- **58 unresolved-lineage flagged, not guessed**: 24 duration-siblings
  (±2 s) of training clips, 19 label paths purged from the current catalog
  (no lineage fields), 20 stem-siblings (same stem, different bytes)
- **45 clean-eligible → 36 selected: 18 positive / 18 negative** (16
  Donna-No + 2 Rick family-male; only 2 of 5 Rick clips were clean)

Zero exact-hash hits against the 26-clip training pool — expected, since
those are renamed copies; the real leakage risk sits in the 58 unresolved
rows, which is why they are flagged for YOUR ledger, not adjudicated by me.
Every row carries partialMD5/sizeBytes/durationSeconds/container/codec/
resolution/dateCreatedRaw/sourceHost for independent enforcement. Honest
limitation: clean positives span 2000s–2020s only (6/6/6); the only
pre-2000 positives (1×80s, 2×90s) are in the unresolved bucket — era depth
needs your audit to clear them or Rick to add cases.

Artifacts:
- Committed (no absolute paths, per the 07-11 privacy precedent):
  `docs/poi-holdout/label-queue-skeleton.{json,md}` +
  `tools/person-eval/build_holdout_queue_skeleton.py` (deterministic)
- **Rick review artifact** (full paths, tick columns; PRIVATE/gitignored):
  `output/person-eval-private/2026-07-23/rick-review-queue.csv` — selected
  36 on top, unresolved below if he wants extras
- Seed ratings are in the committed JSON for balance audit; if your leakage
  audit wants them repo-private instead, say so and I'll strip them.

## Handback

Yours: leakage audit + forbidden-source ledger over the skeleton (esp. the
58 unresolved), then queue Rick's CSV pass, then cut/seal grader-side.
Still blocked on Rick: machine window for the C4 grade, C6 MobileCLIP
decision, and the push window for f3649f9/6d19099.
