# Unified Review — design note

**Branch:** `feature/unified-review` (worktree, base `39d9997`)
**Approved by Rick:** 2026-07-27 (high-stakes restructure — grading-contract contamination risk)

## Goal

One entry point per person — **"Review \<name\>"** — that walks a single session:

1. **Holdout phase** — sealed blind rows (yes/no → sealed CSV only), identical
   semantics to today's Review badge path.
2. **Candidate phase** — pfConfirmRound output (4-tier ratings →
   ValidationLabelStore + catalog writeback), identical semantics to today's
   "Confirm \<name\>…" path.

with a visible, understated transition between them, and the redundant
"Confirm \<name\>…" menu item removed.

## Decisions (the ones the spec asked us to make)

### D1 — Phase-2 candidate fetch timing: **lazily, on phase transition**

`prepareSetup()`/`pfConfirmRound` run only when the session ENTERS the
candidate-setup phase — i.e. strictly after the last actionable holdout row is
answered or skipped. Nothing candidate-scored is computed, fetched, or held in
sheet state while any holdout row can still be presented. No background
prefetch during the holdout phase — the scorer is ~1–2 s over 16k records and
the transition pane is a natural place to absorb that.

Corollary: **"Continue Reviewing" purges candidates.** The transition pane
keeps the existing "Continue Reviewing" affordance (skipped rows, reconnected
drives). Re-entering the holdout phase PURGES all candidate state
(`fullCandidatePool`, `stats`, `candidates`) and re-runs the scorer on the next
transition. Loaded-but-not-rendered would violate the never-LOADED invariant
for re-presented blind rows; a 1–2 s re-score is the price of the hard
guarantee. Pinned by `ReviewSessionPolicy` tests.

### D2 — Back across phases: **NO**

Back in the candidate phase stops at the first candidate; it never crosses into
answered holdout rows. Holdout answers remain editable only *within* the
holdout phase (existing Back/re-answer semantics, already durable in the CSV).
Crossing back would re-present blind rows inside a session whose state now
contains model scores — a cheap contamination vector for zero benefit (the CSV
already supports re-answering on the next open). Pinned by
`ReviewSessionPolicy.canGoBack` tests.

### D3 — Progress copy cannot show the candidate count during holdout

The spec's example ("Holdout 3 of 9 · then 20 new candidates") needs
pfConfirmRound to have RUN to know "20" — which D1 forbids during the holdout
phase. Header therefore reads "Holdout: 3 of 9 answered · … hidden ·
candidates next" during phase 1, and the exact counts appear from the
transition pane onward.

### D4 — Write-sink custody enforced at the type level

New pure layer (`UnifiedReviewSession.swift`):

- `ReviewItem` — `.holdout(HoldoutReviewRow)` / `.candidate(PersonCandidateScore)`
  with `fullPath`/`filename`/`isBlind`.
- `ReviewAnswer` — `.holdoutConfirm(String)` / `.rating(ConfirmRating)`.
  **Distinct schemas, no lossy mapping** — there is deliberately no conversion
  between them.
- `ReviewWriteRouting.sink(item:answer:)` → `.sealedHoldoutCSV`,
  `.validationStoreAndCatalog`, or **nil for a mismatched pairing** (caller
  must drop the write and log — never coerce). The sheet's answer handlers go
  through this router in production, so the custody sensors bite real code,
  not a test-only shadow.

### D5 — One navigation core, two walk policies

`HoldoutNavigation` gains a generic `nextIndex(after:count:wraps:isActionable:)`
core. Holdout phase keeps today's wrap-walk over actionable rows
(pending − in-flight − offline-hidden − unplayable-hidden); the candidate
phase keeps today's LINEAR walk (skipped candidates do not come back around —
that is the existing Confirm semantic and it must not change). Both existing
entry points delegate to the core; with empty exclusion sets the holdout walk
still reduces exactly to `HoldoutReviewQueue.nextPendingIndex`.

### D6 — Transition pane = holdout status banner + existing setup pane

When no actionable holdout row remains, the session enters candidate setup:
the pane shows an understated holdout-completion banner (reusing today's
honest done-pane states verbatim — fully committed / still saving N /
all-remaining-hidden / N still pending, with "Continue Reviewing") above the
existing round-size picker + stats. "Holdout review done — continuing with new
candidates" (friendly language). Sessions opened with no pending holdout queue
land directly on the plain setup pane — same as today's Confirm flow.

### D7 — Entry points

- The purple Review badge (nag-button) stays: badge count = pending holdout
  rows; clicking opens the unified session in holdout mode. Unchanged.
- Context menu: "Confirm \<name\>…" is REMOVED; "Review \<name\>…" replaces it
  and opens the same unified session (holdout-first when a queue is pending
  for that person, straight to candidates otherwise). One verb, one meaning.
- "View Confirmations…" dashboard stays, and is ALSO reachable from the
  unified session's summary pane ("View Confirmations" button).
- A source-scan sensor (dlib-removal style) pins that the old menu item cannot
  quietly come back and the Review entry stays wired.

## What does NOT change

- `HoldoutReviewQueue` — untouched (CSV schema, merge-on-write recordAnswer,
  discovery, blindness sensors).
- codex's `tools/person-eval` Python and the sealed CSV schema.
- Holdout answer path: yes/no → serialized write chain →
  `HoldoutReviewQueue.recordAnswer` → CSV only.
- Confirm rating path: 4-tier → `ValidationLabelStore.record` +
  `catalogWriteback`. Same tiers, same writeback rules.
- Offline/unplayable prefilter, read-ahead, spindle keepalive, routed
  thumbnails — the read-ahead path is *extended* to serve candidate items too
  (same prefetcher instance, same one-reader-at-a-time discipline).
- Resume: exiting mid-holdout keeps first-unanswered-actionable-row-on-reopen.

## Test plan (five dimensions)

- **Logic:** router pairings, phase-gating (`mayLoadCandidates`,
  purge-on-re-entry), Back-no-cross, navigation core parity (wrap == old
  holdout walk incl. never-own-successor; linear == old candidate advance).
- **Scale:** pfConfirmRound over a 100k-record synthetic catalog with a time
  budget (was NOT previously covered — verified 2026-07-27; added here).
- **Media matrix:** n/a — no media I/O touched (renderers reused).
- **Isolation:** poisoned state — garbage queue CSV *and* garbage
  validation_labels.json simultaneously, in temp dirs; both surfaces degrade
  independently, neither writes to the other's file.
- **Sensors:** blindness (existing, must stay green) + custody both
  directions + mismatched-pairing rejection + removed-menu-item source scan.
