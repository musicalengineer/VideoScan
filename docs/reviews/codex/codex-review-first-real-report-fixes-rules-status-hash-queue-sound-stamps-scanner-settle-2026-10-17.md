# Codex review — First-real-report fixes: rules, status, hash queue, sound stamps, scanner settle

- Range: `8f308d333..21076822c`
- Credits spent: unavailable
- Tokens: 81670
- Finding count: 4
- Verdict: fix — the shared probe path materializes skipped outcomes as failed records; three additional correctness issues remain.
- Run: 2026-10-17T15:51:39Z (cycle #93, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4

Verdict: fix — the shared probe path materializes skipped outcomes as failed records; three additional correctness issues remain.

**P1 — Settling affects single-file reprobes, whose wrapper discards the skip signal.** [VideoScanModel+ProbeEngine.swift:796](/Users/rickb/dev/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:796), [wrapper:731](/Users/rickb/dev/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:731). Failure scenario: immediately after completing a valid MP4, call `probeFile` with the production 60-second window; it returns a `VideoRecord` marked `ffprobeFailed`, with default codec/duration fields. The wrapper unconditionally applies the skipped outcome, losing `stillBeingWritten`. Its documentation identifies Transcode/Reformat as callers; downstream persistence was outside scope. Restrict settling to scanning or propagate deferral through this entry point.

Other attack results, from source inspection:

1. **Archive:** `CheckCopies.swift:114` excludes existing `archiveFixity`; `:443` checks again before storing. An archive stamp added *after planning* can still permit a read, but prevents re-stamping. Both scoped jobs use this guard. Planners admit otherwise-active Trash/link paths (`CheckCopies.swift:79`, `FullHashBackfill.swift:84`); actual link refusal depends on the unlisted rehash implementation. Likewise, `storeContentFixity` is outside the permitted files, so complete name/date/stage/lineage immutability is **unproved**. Check Copies also deliberately invokes duplicate regrouping (`:377`). The archived-row tests assert hashes, not preservation of all protected fields.

2. **Sound:** A silent file retaining stale `audioCodec = "aac"` retries indefinitely without a stamp (`AudioFingerprintBackfillJob.swift:381`); conservative failure is appropriate until the contradictory evidence is resolved. Conversely, video-only/empty-codec rows bypass decoding (`:341`), and tier 3 checks only Video+Audio rows (`VerifyCatalogTiers.swift:241`): missed sound escapes, a **preexisting limitation**. Migration holds: exactly one v2 class is newly rejected—noAudio/nonempty codec; three remain accepted—complete fingerprints, partial fingerprints, and noAudio/empty codec (`AudioFingerprintStamp.swift:129`). No blob-format change is visible; exhaustive reader compatibility requires unlisted readers.

3. **Scanner:** The age check precedes cache lookup (`ProbeEngine.swift:796`, `:805`). However, equal-size rewrites preserving an old mtime can still hit stale cache; hits return without the second stat. FAT granularity alone does not make unchanged timestamps disagree—it can conceal changes. The 60/0 mapping holds (`ScanWriteInProgress.swift:54`), but `TestEnvironment.isTestHost` detection is outside scope. Preservation of an existing skipped row also depends on the unlisted merge implementation; listed tests do not establish it.

4. **Rules:** Exact hash matching holds: split on `+`, trim, compare with `"hash"` (`CatalogConstraints.swift:319`); `"phash"` cannot match.

5. **Status:** Local counts/precedence hold: 100 kept produces zero decisions and 100 unchecked; one decision takes red precedence and its rule words precede kept words (`VerifyCatalogTiers.swift:324`, `:349`; `CatalogFreshness.swift:326`). Exact tier-5 naming relies on the unlisted integration bridge. Headline work remains linear; the 1,000-row budget sensor remains but was not rerun. `/Volumes` enumeration accepts leftover directories (`VerifyCatalogJob.swift:313`): acceptable only as an approximate hint; literal mounted-drive truth requires mount-table information.

6. **Schema:** No new serialized report field is visible; report construction is unchanged (`VerifyCatalogJob.swift:247`), and tests pin schema 2 (`VerifyCatalogTests.swift:613`). Strict-reader definitions are outside scope, so exhaustive compatibility remains unproved.

No files written; tests were inspected, not run.

- **P2 — Lost replacement downgraded:** [CatalogConstraints.swift:371](/Users/rickb/dev/VideoScan/VideoScan/Integrity/CatalogConstraints.swift:371): if superseded A points to missing replacement B—the only usable copy—the rule classifies that loss signal as kept history without evidence of intentional pruning.
- **P2 — Future mtime prevents cataloging:** [ScanWriteInProgress.swift:67](/Users/rickb/dev/VideoScan/VideoScan/Volumes/ScanWriteInProgress.swift:67): a stable file dated 2040 is skipped until that timestamp plus 60 seconds; negative ages also fail with a zero window.
- **P2 — Real video mislabeled as reference movie:** [CatalogConstraints.swift:546](/Users/rickb/dev/VideoScan/VideoScan/Integrity/CatalogConstraints.swift:546): a no-write FFmpeg reproduction produced a valid, self-contained 20-second H.264 MP4 of 13,237 bytes; its 662 B/s triggers the rule despite requiring no external media.

## Brief

# Codex brief: first-real-report fixes — rules, status words, hash queue, sound stamps, scanner settle (2026-10-17)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**One sentence (Rick, 2026-10-17):** the first real Verify Catalog report (745 findings) was mostly our tools' own errors; these fixes make the report true so the verified rows can be imported into SQLite (plan v3, `docs/design/catalog_sqlite_migration_2026_10_16.md` §10).

**Range:** `8f308d333..21076822c` on `main` (two merges: `7a4c879db` rules + status, `21076822c` MediaOps). Read with `git show 21076822c:<path>`. Paths under `VideoScan/VideoScan/` unless noted.
- `Integrity/CatalogConstraints.swift` — `duplicateGroupDigestsAgree` now fires only when a live member's `duplicateReasons` contains the exact tag `hash` (DuplicateDetector tags: hash/timecode/filename/duration/resolution/vcodec/audio/tape/created) and ≥2 live members' digests differ; `lineageTargetsExist` findings are `needsDecision: false` ("kept as history"); new `referenceMovie` (live row, non-empty videoCodec, duration ≥ 10 s, bytes/second < 5,000). 14 rules.
- `Integrity/VerifyCatalogTiers.swift` — tier 5 splits decided/kept findings (`needsDecision` = decided, `couldNotCheck` = kept + unreadable); tier 1 words split by `mountedVolumeRoots` (readdir of /Volumes ∪ "/"); tier 3 words.
- `Integrity/VerifyCatalogJob.swift` — `mountedVolumeRootsNow()`.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogFreshness.swift` — `Tally.redWords`, headline names up to two red rows then "· N more".
- `MediaOps/CheckCopies.swift` — `CheckCopiesPlanner.need(_:)` no longer takes `isReadOnly` (it was `isDateReadOnly` — the archive DATE rule; it never meant fixity): valid `contentFixity` → hashed; `archiveFixity` → leftAlone; else hash. `storeCheckedCopyFixity` guard is `archiveFixity == nil` only. `MediaOps/FullHashBackfill.swift`, `FullHashBackfillJob.swift` — callers.
- `MediaOps/AudioFingerprintBackfill.swift`, `AudioFingerprintBackfillJob.swift`, `VideoScanCore/.../AudioFingerprintStamp.swift` — a `.noAudio` stamp only when the header agrees (`headerHasAudio = !audioCodec.isEmpty`); decoder `noAudioStream` with a header that has audio → FAILED (retried), no stamp; stamp rule version 3 (`currentEngineVersion`), `noAudioOnDecodeFailureVersion = 2`; `describes(...)` refuses v2 noAudio stamps whose row has an audio codec so the plan re-queues ONLY those; sidecar blob format (`AudioFingerprint.currentVersion`) stays 2.
- `Media/VideoScanModel+ProbeEngine.swift`, `Volumes/ScanWriteInProgress.swift`, `Volumes/VideoScanModel+ScanExecution.swift`, `Volumes/DiscoveryAudit.swift`, `Model/VideoScanModel.swift` (`scanSettleSeconds` 60 in the app, 0 under the test host), `VideoScanCore/.../VideoRecord+ProbeOutcome.swift` (`stillBeingWritten`) — stat before and after ffprobe; size/mtime differ, file gone, or mtime within the settle window → SKIPPED "still being written — rescan later", never cached, never catalogued; an already-catalogued file being rewritten keeps its old row.
- Tests: `VideoScanTests/VerifyCatalogTests.swift`, `CatalogFreshnessTests.swift` (Core), `CheckCopiesTests.swift`, `FullHashBackfillTests.swift`, `AudioFingerprintBackfillTests.swift`, `ScanStillBeingWrittenTests.swift`, Core `AudioFingerprintStampTests.swift`.

**Attack (prove with file:line or say it holds):**
1. ARCHIVE RULE: hashing an archived-lifecycle row now writes `contentFixity` on it. Prove nothing else on that row can change through this path (name, dates, `archiveStage`, `archiveFixity`, lineage) — `storeContentFixity` and every caller. Can a promoted archive copy (which HAS `archiveFixity`) ever be re-read or re-stamped? Can the planner now hash a row whose file is in the Trash or whose path is a link (the audit refuses links)?
2. SOUND STAMPS: with the header rule, name a file that truly has no audio but whose row carries an `audioCodec` (a stale probe, a container with an empty audio track) — does it now fail forever (retried every run) rather than being stamped, and is that the right outcome? Conversely a row with EMPTY `audioCodec` whose file has sound (probe missed it) still gets a `noAudio` stamp — say whether tier 3 or anything catches it. Does `describes` refusing v2 noAudio stamps re-decode anything it should not (count the classes)? Is the sidecar format really untouched (any reader keyed on `currentEngineVersion`)?
3. SCANNER SETTLE: a legitimate file whose mtime is in the future (clock skew, camera clock) — skipped forever? A file on a volume with coarse mtime (FAT, 2 s) — can the two stats disagree spuriously? Cache: can a stale cache entry vouch for a rewritten file (the check runs before the cache lookup — prove the order)? The test-host `settleSeconds = 0` — can it leak into the app (how is `isTestHost` decided)?
4. RULES: `referenceMovie` false positives — a tiny real clip (an h264 thumbnail-sized video at < 5 KB/s for ≥ 10 s; a screen recording of a static image; a slideshow .mov); the `hash` tag match — can `duplicateReasons` contain "hash" inside another token (e.g. "phash") and does the split guard it? Lineage to a purged row = kept: name a case where the dangling link IS a data-loss signal that this now hides.
5. STATUS: the Integrity row with 100 kept + 0 decided → yellow naming tier 5 — prove; with 1 decided + 100 kept → red words name the decided one. The headline "A · B · N more" — the 1,000-row budget still holds? Tier 1 "connected" from a readdir of /Volumes — a leftover empty mount folder reads as connected; say whether that is acceptable or `getmntinfo` is required.
6. REPORT SCHEMA: still 2 — any new field written that a schema-2 strict reader refuses?

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the SQLite plan, the importer, Fix Links, wording.

**Do not explore outside the files listed above and their tests.**
