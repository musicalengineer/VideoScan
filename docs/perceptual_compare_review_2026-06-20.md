# Perceptual Compare — Merge-Readiness Review (2026-06-20)

Reviewer: Claude (Opus 4.8, 1M). Read-only inspection of
`feature/perceptual-compare` via `git show`/`git diff` against `main`
(HEAD `5cc617a`). No branch switch, no build, no edits.

Branch HEAD: `ee12464` (2026-06-11), 10 commits ahead. Local-only
(not on origin), ~9 days stale.

---

## TL;DR — MERGE RECOMMENDATION

**Merge-after-fixes.** The perceptual-compare core is well-engineered,
well-documented, and unusually well-tested (1,200+ test lines, positive
+ negative + boundary coverage, an independent re-derivation of the
statistical constant). It is **not** merge-ready *as a branch* because
the branch is stale and carries ~7 unrelated/already-landed commits
that must be dropped or rebased away first. The feature code itself is
close to merge-ready; the work is rebase hygiene, an integration smoke
test, and two small robustness checks — **not** algorithm rework.

**Effort estimate:** ~0.5–1 day. The bulk is a careful rebase + drop of
already-landed commits, one build, and running the suite (including the
env-gated `VS_RUN_PERCEPTUAL=1` integration test once).

### Top 3 concerns
1. **Stale branch carrying already-landed / unrelated commits.** Of the
   10 commits, only 3 are the feature (`f9885bf`, `6d48dd3`, `ee12464`).
   The doc itself flags `9d24781` "Find Online Version" as
   byte-identical on main already, plus Extract-Frames-split / verb-badge
   / XcodeRAM commits overlap with `feature/extract-frames-split`. Merging
   the branch wholesale would re-introduce or conflict with landed work.
   Must rebase and keep only the perceptual (and intentionally, the
   All-Frames) pieces.
2. **Tier-3 doubles compare cost and runs full decode-at-thumbnail-scale
   per file** — at archive scale (thousands of cross-volume pairs) this
   is a real, if bounded, perf cost. It is gated correctly (only fires
   when Tiers 0–2 say "different" AND both files carry video), so it
   only burns on genuine near-duplicate candidates, but a bulk
   "compare everything" sweep should be sanity-checked on representative
   HDD pairs before this is leaned on heavily.
3. **No automated coverage of the Tier-3 *integration* path in
   MediaPairComparator.** The pure math and arg-building are
   exhaustively unit-tested, and there is an opt-in real-ffmpeg
   fingerprint test, but the actual escalation wiring inside
   `run(recordA:recordB:)` (gen-token progress reset, error→fallback,
   verdict fold) is only exercised by reading. The fold logic *is*
   unit-tested separately; the in-comparator orchestration is not.

---

## 1. What the feature does & implementation state

**What:** A "Tier-3" perceptual A/V comparison stage for the media-pair
compare pipeline. After the existing exact (Tier 1 byte) and stream-hash
(Tier 2 packet) tiers conclude "different", and *only* if both files
carry video with a known duration, Tier-3 decodes 32 evenly-spaced
interior frames per file (skipping first/last 5%), reduces each to a
9×8 grayscale thumbnail, computes a 64-bit **dHash** (difference hash),
and compares the two 32-hash fingerprints index-aligned with a small
±2-frame alignment search. A strong statistical match yields a new
verdict **`.samePerceptualContent`** → "Same content (re-encoded)".
This catches the DV-original-vs-H.264-copy case that shares zero bytes
and zero packet hashes — the missing piece for collapsing re-encoded
duplicates across volumes.

**Hash family:** **dHash**, not pHash or aHash. (Doc and one code
comment loosely call it "perceptual hash"; the implementation and the
bulk of comments are explicit and correct that it is difference-hash:
bit set iff `pixel[x] > pixel[x+1]`.) dHash is a defensible choice
here — cheap, no DCT, robust to the sign-preserving transforms a
re-encode applies.

**State — complete:**
- `PerceptualHash.swift` (336 lines) — pure dHash math, sequence
  compare, statistical model, verdict gate, and fingerprint
  encode/decode (Data + base64, big-endian). Complete and pure (no I/O).
- `PerceptualFingerprinter.swift` (210 lines) — pure ffmpeg argv
  builder + the `@concurrent` extraction runner using the existing
  `ProcessRunner`. Complete.
- `MediaPairComparator.swift` (+130 lines) — Tier-3 escalation wired
  into `run(recordA:recordB:)`, new verdict case, progress generation
  token, `finishedSubtitle`. Complete.
- `PairCompareJob.swift` (+8 lines) — surfaces `finishedSubtitle`.
  Complete.
- Tests — `PerceptualHashTests.swift` (427 lines),
  `PerceptualFingerprinterTests.swift` (179 lines). Complete.

**State — stubbed / deliberately deferred (documented, not bugs):**
- **Fingerprint persistence.** `data(from:)` / `base64(from:)` round-trip
  helpers exist but are *not* wired to the SQLite catalog — the author
  explicitly leaves persistence as a separate schema decision. So every
  compare re-decodes; no fingerprint caching yet.
- **Letterbox/crop tolerance.** Known v1 limitation: letterboxed-vs-
  cropped variants defeat dHash (every row's gradient shifts). Documented
  as "can miss, never invents" — acceptable for v1.
- `VolumeCompare.swift` — **unchanged** on this branch (no diff). The
  Tier-3 work lives entirely in the pair comparator/fingerprinter.

---

## 2. Correctness & risk

**Algorithm — sound.** The statistical model is the strongest part.
Per-frame match threshold is Hamming ≤ 16 (= mean − 4σ for unrelated
64-bit dHashes under Binomial(64, 0.5)). The per-frame coincidence
constant (~3.9e-5) is computed via an exact multiplicative binomial
recurrence (terms < 2^53 stay exact in Double), and the test suite
*independently re-derives the same constant via lgamma* and asserts
agreement to 1e-9 — exactly the kind of cross-check this deserves.
Coincidence bound uses log-space C(n,m) (lgamma) clamped at −300 to
avoid underflow/`-inf`/NaN poisoning the summary string.

**False-positive posture — conservative, correct direction.** The
verdict gate requires *all three*: median ≤ 10, ≥ 80% frames matching,
≥ 10 frames compared. The "inconclusive zone" (e.g. median 12, fraction
1.0) deliberately does **not** match and falls through to
`differentMedia` while keeping stats visible. Empty/short inputs report
worst-case numbers (median 64, fraction 0) that can never be mistaken
for evidence. The whole module is engineered to "miss before it
invents", which is the right bias for a dedup/triage tool that could
otherwise delete a unique file.

**Honesty in the math.** Comments correctly flag the two ways the
coincidence bound overstates: consecutive frames aren't independent
draws (mitigated by sampling across the whole duration and *also*
gating on median + fraction, not the probability), and best-of-5
alignment offsets costs ~log10(5) ≈ 0.7 decades. The probability is
treated as display-only / order-of-magnitude; the verdict never leans
on it. Good discipline.

**Robustness contract — correct.** A Tier-3 fingerprint failure
(undecodable video, e.g. Avid RGBA MXF) is caught and falls back to
`differentMedia` rather than erroring — Tiers 0–2 already proved both
files readable, so the tier "must never make the feature less robust
than before it existed." `CancellationError` is rethrown distinctly.

**Concurrency.** `@concurrent nonisolated` on the extraction func
matches an established pattern already used 7× in main's
MediaPairComparator (this is not a new threading model). Cancellation
propagates via `ProcessRunner` (SIGTERM to child) + explicit
`Task.checkCancellation()`. The progress callbacks hop to `@MainActor`
via unstructured `Task`; the new **`fractionGeneration` token** correctly
guards against a late Tier-2 callback snapping the bar backward after
Tier-3 resets it — a genuine ordering hazard the author spotted and
fixed (the `ee12464` QA-follow-up commit).

**Memory — negligible.** 256 bytes/fingerprint; temp file ≤ 2,304 bytes,
read once, `defer`-deleted on every exit path. Nothing scales with media
size. Confirmed.

**Performance — the real cost, bounded but worth a sanity pass.** The
`fps` filter decodes *every* frame in the trimmed 90%-of-duration span
(one full decode at thumbnail scale), roughly doubling a compare's
runtime. The author chose this over 32 `-ss` seeks to avoid 32 process
launches + keyframe-snap misalignment between differently-encoded copies
— a defensible call for *correctness*. Mitigations already in place: the
tier only fires after Tiers 0–2 say "different" AND both files carry
video AND durations are known, and it runs inside the same per-volume
read gate the job already holds (one reader at a time per spinning
disk). Recommend: before a bulk sweep, profile a handful of real
long-file pairs on an HDD to confirm the doubled cost is acceptable; the
deferred fingerprint persistence (§1) is the obvious lever if it isn't.

**Minor correctness notes (non-blocking):**
- ffmpeg uses `-v error` *and* `-progress pipe:2` (both to stderr). The
  stderr error-tail filter is written to exclude `key=value` progress
  lines while preserving real error messages containing `=`. The filter
  logic looks correct (keeps a line unless its pre-`=` token is all
  letters/underscores), but it is the one spot worth a quick real-ffmpeg
  eyeball when a decode genuinely fails — the integration test only
  exercises the *success* path.
- dHash strict `>` means a flat frame hashes to 0; two unrelated flat
  black frames would compare equal. The 5% leader/trailer trim mitigates
  this, but pathological all-black interiors could inflate match
  fraction. The median + 80% gates make a full false-positive unlikely,
  but it is the theoretical soft spot.

---

## 3. Test coverage

**Strong, and a model for the rest of the codebase.** ~600 lines across
two files plus a fold suite:
- dHash: flat→0, strictly-dec→all-ones, strictly-inc→0, single-pixel-
  flip locality (≤2 bits), explicit bit-0/bit-63 layout pins.
- Hamming: identity, complement, known XOR cases.
- Sequence compare: identical→perfect, unrelated→no match, off-by-one
  alignment rescue, too-short→inconclusive, empty→worst-case,
  inconclusive-zone (median 12)→no match.
- Statistics: independent lgamma re-derivation of the per-frame
  constant, log10Choose known values + out-of-range → −∞, clamp to −300.
- Verdict gate: every boundary probed exactly (median 10/11, fraction
  0.80/0.79, frames 10/9), all-three-simultaneous, summary-string
  format + weak-probability omission + zero-frames.
- Fold (PairCompareLogic.verdict): perceptual upgrades differentMedia,
  never outranks stronger tiers, false/nil stays different, 3-arg
  default-arg back-compat regression sensor.
- buildArgs: exact argv pin for 100s file, short-file high-fps, tiny-
  duration no-divide-by-zero, arg-order invariants, span/trim math,
  production constants pinned (frameCount==32, minimumFrames coupled to
  verdict gate, trimFraction==0.05).
- Integration: env-gated (`VS_RUN_PERCEPTUAL=1`) real-ffmpeg re-encode-
  to-H.264-half-res-and-match — the actual DV-vs-H.264 scenario.

**Gaps:**
- The Tier-3 path *inside* `MediaPairComparator.run` (progress gen-token
  reset, error→fallback, perceptualStats publication, finishedSubtitle)
  has no automated test — only the pure fold helper does. An async test
  driving `run()` with two records, or at least one over the real
  fixtures, would close the integration-boundary gap (consistent with
  the project's "integration-boundary bugs escape unit tests" memory).
- The error-tail stderr filter has no direct test on a failing decode.

Tests use Swift Testing (`@Test`/`@Suite`), `@testable import`, and
deterministic splitmix64 vectors (no randomness — failures reproduce).
Consistent with project conventions.

---

## 4. Integration risk with main

**Low for the feature code; the risk is branch hygiene, not the code.**

- **New files auto-include.** The project uses
  `PBXFileSystemSynchronizedRootGroup` (5 synced root groups; only 5
  `PBXFileReference` total). The branch makes **no `project.pbxproj`
  change** and needs none — new `.swift` files in the synced folder are
  picked up automatically. (The "0 pbxproj references to PerceptualHash"
  is expected and correct, *not* a missing-from-target bug.)
- **Shared-file edits are additive.** `MediaPairComparator.swift`:
  `run(recordA:recordB:)` signature unchanged (no caller breakage);
  `PairCompareLogic.verdict` gains a *defaulted* `perceptualMatch:`
  param (back-compat preserved, with a regression sensor test). New
  enum case is additive. `PairCompareJob.swift`: one-line subtitle
  swap. All referenced record fields (`durationSeconds`, `streamType`,
  `.videoAndAudio`, `.videoOnly`) exist on `VideoRecord` on current main.
- **No schema changes.** Fingerprint persistence is deliberately *not*
  wired to SQLite — no catalog migration. (Escalation gate per
  CLAUDE.md: none tripped.)
- **No log path / format changes.** Uses the existing
  `Rick-Breen.VideoScan` subsystem, `fileOps` category — convention-
  compliant. `ProcessRunner` pattern reused (not replaced). No
  recovered-MXF-pair data touched.
- **The actual conflict surface is the stale branch.** ~7 of 10 commits
  are unrelated or already-landed (`9d24781` byte-identical on main per
  the branch notes; Extract-Frames-split/verb-badge/XcodeRAM overlap
  with `feature/extract-frames-split`; `6581613` dossier; `ce75f2e`
  refactor-agent; `1f3ca04` lint; `a245d7e` scripts). The branch diff
  also touches `ContentView`, `CatalogHelpers`, `MediaFileOperations*`,
  `DossierDashboardView`, `OnlineCopyFinder*`, `AllFramesRipper*`,
  `VolumeMigrationSheet`, `CaptionOrchestrator`, `FrameRipper`,
  `setup-xcoderam.sh`, and `scripts` — most of which belong to those
  other commits, **not** to perceptual-compare, and are the likely
  rebase-conflict points.

---

## 5. Required fixes before merge

1. **Rebase onto current main; keep only the 3 perceptual commits**
   (`f9885bf`, `6d48dd3`, `ee12464`). Decide deliberately whether the
   All-Frames ripper + `VolumeMigrationSheet` come along or go on their
   own branch (confirm they aren't already superseded on main). Drop
   `9d24781`, the Extract-Frames-split/verb-badge/XcodeRAM commits, the
   dossier/refactor-agent/lint/scripts commits.
2. **Build + run the full suite** (Release per the project's test-parity
   policy), and run the integration test once with
   `VS_RUN_PERCEPTUAL=1` against a real fixture to validate the
   end-to-end ffmpeg path.
3. **Add one integration-level test** driving `MediaPairComparator.run`
   over two fixture records (or at minimum the error→fallback path), to
   cover the Tier-3 orchestration the unit tests don't reach.
4. **Quick perf sanity** on a few real long-file HDD pairs to confirm
   the doubled-compare cost is acceptable at sweep scale; note the
   deferred fingerprint-persistence lever if it isn't.

Optional (not blocking): eyeball the stderr error-tail filter against a
genuinely failing decode; consider whether all-black interior frames
need a guard beyond the 5% trim.

**Nothing in the algorithm, thresholds, concurrency model, or test
design needs rework.** This is solid work parked at a clean stopping
point; the cost to land it is hygiene + one integration test + a build,
not redesign.
