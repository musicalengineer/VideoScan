# Archive Angel as curator — direction and plan

**Status:** direction agreed with Rick 2026-09-19; Phase 1 not started.
**Supersedes nothing.** Builds on the uniqueness direction (2026-09-11,
`docs/archive_angel_uniqueness_direction.md`), the short-clips rule
(2026-09-10) and the promote-and-prune workflow (`docs/promote_and_prune_workflow_design.md`).

## The problem, in Rick's words (2026-09-19)

> "X media files in catalog, but Y have been promoted where Y is much smaller
> than X. AA keeps suggesting the same N files due to score, user sees
> derived/similar events and skips. AA goes round and promotes same files
> almost all over again, the goal of increasing Y grows slowly … So the
> challenge is to get the AA to suggest files that have not had any
> attention."

And the wider goal:

> "I am trying to get the angel to rotate through the whole catalog and get me
> to promote, delete, disposition, date, add notes, and CURATE the catalog."

So the Angel is not only a promoter. It is the app's **curator**: it should
walk the whole catalog over time and draw a human decision out of Rick for
each item — archive it, junk it, date it, name it, note it, or explicitly
leave it for later — and it should never spend his attention twice on the
same thing without new reason.

Rick's reward idea, kept because it is the point: when 25 files are promoted
in 24 hours, "an angel gets its wings and a bell goes off" (*It's a Wonderful
Life*).

## Why the same files keep coming back (measured, 2026-09-19)

Read of `ArchiveAngelScorer` / `ArchiveAngelJob.selectFromEvidence`:

1. **A skip is forgotten.** `skip()` means "not in this batch"; nothing
   persists it, and `inFlightRecordIDs` deliberately frees a skipped row for
   the next batch. Scores are unchanged, so the same top scores win again.
2. **Variants are only sometimes recognised.** `derivativeOfOriginal` is a
   FILENAME-token rule (`ArchiveAngelNaming.derivativeBaseStem`) and it only
   REJECTS when `starRating == 0`. A rated "fixedup" competes on its own
   merits; a differently-named clip of the same event is not related at all.
3. **Nothing rewards novelty.** "Played 7 times" and star ratings push Rick's
   favourites up every round; a file he has never been shown gets no credit
   for being new.

## How institutions curate at scale (what to borrow)

Notes from archival and digital-preservation practice, to be extended with
sources next session (flagged: written from knowledge, not yet verified):

- **Appraisal, not completeness.** Archives accept that not everything is
  kept; value is judged against a collection policy (evidential, informational
  and associational value). For VideoScan the policy is the family: people,
  events, era coverage, uniqueness. → the score IS an appraisal, and it should
  be explainable in those terms.
- **MPLP — "More Product, Less Process"** (Greene & Meissner, 2005): describe
  at the coarsest level that still serves users; do the minimum per item so
  the whole collection gets touched. → prefer a shallow pass over EVERYTHING
  (a decision per file) to deep work on a few. This is exactly Rick's "rotate
  through the whole catalog".
- **Accession → appraisal → arrangement → description**, with a backlog that
  is worked in passes, not perfected in one. → the Angel's batches are passes;
  "unassessed" is a first-class state to be drained.
- **Significance assessment** (e.g. Australia's *Significance 2.0*): rate items
  against criteria (historic, aesthetic, social, rarity, condition,
  interpretive potential) and let rarity/condition raise priority. → uniqueness
  and at-risk formats as points, already half-present.
- **Retention schedules / disposition** (NARA and records management): every
  item ends with an explicit disposition, even "review again in N years".
  → Rick's "not sure" must be a real, recorded answer with a date, never a
  silent skip.
- **Sampling for large series**: when a series is too big to appraise item by
  item, sample it and generalise. → the Angel can offer "here are 10 from a
  folder of 400 — tell me about the folder".
- **Condition/obsolescence triage**: media at risk of loss goes first (old
  codecs, DV tapes, single copies). → already in the scorer as at-risk format
  and original-era bonuses; deserves more weight.
- **Digital preservation "significant properties"**: decide what must survive
  a transcode (image, sound, timecode). → why the lossless master exists.

Algorithms that fit the "which file next?" problem:

- **Explore / exploit (multi-armed bandit; UCB1, Thompson sampling).** Most of
  a batch exploits the best scores; a fixed share explores unseen files. UCB's
  "uncertainty bonus" is literally "we know nothing about this one".
- **Spaced repetition (Leitner boxes, SM-2).** A skipped item drops into a
  longer-interval box and comes back later; repeated skips push it further
  out. Matches Rick's "give that file a rest" and gives a principled decay.
- **Diversity-aware ranking (MMR — maximal marginal relevance; determinantal
  point processes).** Choose the next item to maximise score MINUS similarity
  to what is already in the batch. That is the "one Thanksgiving variant per
  batch" rule, generalised.
- **Stratified coverage.** Strata = year (or decade) × volume × people.
  Under-archived strata get a bonus, so the timeline fills instead of
  deepening around favourites.
- **Near-duplicate detection** for real event families: perceptual/video
  hashing (pHash per keyframe, chromaprint for audio) rather than filenames.
  This is the T11 uniqueness-fingerprinting theme; expensive, overnight work.

## The plan

### Phase 1 — the Angel remembers what it showed you

Data (durable, auditable — every action already logged per Rick's rule):
- New Media Ledger events per record: `angelProposed`, `angelSkipped`,
  `angelCleared` (a batch cleared without a decision), alongside the existing
  `archived` / `copyTrashed`. Ledger = the audit trail AND the input.
- A derived per-record summary (rebuildable from the ledger, cached):
  `timesProposed`, `timesSkipped`, `lastProposedAt`, `lastSkippedAt`.

Scoring:
- **Fatigue:** `effective = score × 0.7^skips`, skips older than 90 days count
  half. Three skips → **resting** for 90 days (excluded, with the reason shown:
  "Resting — you passed 3 times, back in December").
- **Family fatigue:** members of one event family share half of each other's
  fatigue; **at most one family member per batch** (extend the existing
  `duplicateOfPick` gate). Family key: derivative base stem + date hint +
  folder, plus the share-out tokens (`clip\d`, `fixed`, `denoise`, `edit`,
  `v\d`, `_1`).
- **Novelty:** `+15` for never proposed; a batch reserves ~3 of 10 slots for
  "fresh eyes" (never proposed, decent score) — the explore arm.

Proof (the metric, not a vibe): a simulation test over a 10k-record synthetic
catalog with a "user" who skips every pick for 10 rounds, asserting
**distinct files seen** and **fraction of catalog touched** rise sharply
versus today, and that no file is proposed more than 3 times in the run.

### Phase 2 — buffer hygiene, when the Angel is opened

On opening the Angel panel (or its chevron/button), if prepared batches are
waiting: "3 prepared batches (74 GB) are waiting. What next?" Per batch:
**Review and Promote / Clear / Later**; plus **Clear all**. Clearing removes
only the Angel's derived copies (regenerable; originals untouched), frees the
buffer, returns the rows to the pool, and counts as half a skip. Nothing is
auto-deleted without an ask (delete-safety); a batch untouched for 14 days is
flagged in that prompt.

### Phase 3 — "New to you", and a better "should be promoted"

- **Quick triage of unassessed files** (the MPLP pass): play a few seconds,
  then ✨ Gold (★★★) / Keep / Not this again (junk) / Not sure (rest 90 days).
  Answers write real human signals — stars and Disposition — which the scorer
  trusts above its own guesses. Frame: "Here are some files nobody has looked
  at. How do you want to deal with them?"
- **Timeline-gap bonus** (stratified coverage): years with few archived files
  give their candidates points. Cheap, and it serves "fill the timeline with
  unique videos".
- **Uniqueness fingerprinting (T11)**: overnight perceptual hashing to build
  real event families and a uniqueness score, replacing the filename
  heuristics.

### Phase 4 — the reward

Archive progress (Y promoted of X eligible, a decision-per-day count), and at
25 promotions in 24 hours: the wings animation and the bell. Streaks and a
gentle daily target; sound optional.

## Numbers to keep honest

The fatigue factor (0.7), the rest interval (90 days), the three fresh slots
and the novelty bonus are starting guesses. The Phase 1 simulation is the
instrument for tuning them; the Angel testbed
(`scripts/angel_testbed.py`) measures the cost side.

## Open questions for Rick

1. Should a batch left untouched for a long time (say 30 days) clear itself
   with a notice, or always wait for an answer?
2. Is "resting" per FILE, or per event family (skip one Thanksgiving variant →
   rest the whole event)?
3. How many of a 10-file batch should be "fresh eyes" — 3, or more early on
   while the backlog is large?
