# Relocate Volume — Implementation Plan

**Drafted:** 2026-05-29 evening
**Author:** Plan agent (Claude Opus 4.7), with reconcile-step addendum
**Status:** Awaiting Rick's review before implementation
**Driving need:** Migrate catalogued files off the failing Mini2TB HDD to a folder on LaCie 8TB before the drive dies. Same pattern reusable for other flaky drives.

---

## Locked design decisions

These were settled in conversation before the agent drafted the plan; do not re-litigate:

1. **Scope: catalogued files only.** Walk every `VideoRecord` whose `fullPath` is under `/Volumes/<sourceVolume>/`. Uncatalogued media on the source is out of scope.
2. **Failure handling: `salvageFailed` disposition.** When a source file can't be read, keep the record, flip a new disposition flag, leave `fullPath` pointing at the now-disconnected source. Triage surfaces these for later attention.
3. **Provenance preserved.** New immutable fields `originalFullPath: String?` and `originVolume: String?` on `VideoRecord`, set at migration time.
4. **Verification: size + partial-MD5** (the hash the catalog already stores). No full byte-compare.
5. **Source NEVER deleted by the feature.** Two-step: migrate → verify → flip catalog. Rick disconnects the old drive manually at his discretion.

---

## Architectural framing

VideoScan's model layer is an `@MainActor`-isolated `VideoScanModel` whose surface area is sliced into ~30 `+Feature.swift` extensions. Long-running engines hang off the model (Combine, Archive, ScanLifecycle, etc.) and report progress through `DashboardState` — a separate `ObservableObject` so high-frequency counter ticks don't redraw the catalog Table. `VideoRecord` is a `class` with hand-written `Codable` using `decodeIfPresent ?? default` for forward-compat. The catalog is persisted as `~/Library/Application Support/VideoScan/catalog.json` via `CatalogStore`, atomic-rename writes, debounced 2s, with one-generation `.prev` rotation on every successful load. Bundle export already does whole-catalog snapshotting via `BundleExporter`. Per-feature logs land in `~/Library/Logs/VideoScan/<name>.log` via `PersistentLog`.

Relocate Volume slots into this model directly as another feature extension + engine + sheet — the closest existing analog is Combine end-to-end (preflight → engine → per-job dashboard → end-of-batch banner).

### Copy mechanism: `FileManager.copyItem` (not `rsync`)

- Source records always come from the catalog as individual file paths. There is no recursive tree to walk, no `--delete`, no incremental rerun — `rsync`'s headline features add nothing here.
- `rsync` adds Process management, env piping, stdout/stderr parsing for progress, and a new external dependency footprint.
- `FileManager.copyItem(at:to:)` on macOS preserves resource forks + xattrs + ACLs in a single syscall and writes via `copyfile(3)` under the hood with `COPYFILE_ALL` semantics. That handles HFS+ → APFS extended-attribute migration correctly (xattrs round-trip; legacy HFS+ "type/creator" Finder bits land in `com.apple.FinderInfo` and survive).
- Failure surfaces as a typed Swift `Error` and we can pre-test readability with `open(O_RDONLY)` + 1-byte `read` to detect bad sectors fast without copying GB first.

Reserve `rsync` only if integration testing surfaces an HFS+ catalog corruption that breaks `copyfile`'s xattr enumerate (unlikely — `copyfile(3)` is the same primitive Finder uses).

---

## Execution Plan (numbered, sequential)

### 1. Schema — provenance fields on `VideoRecord`

- **File:** `VideoScan/VideoScan/Models.swift`
- Add two new optional stored properties next to `fullPath`:
  ```swift
  var originalFullPath: String?    // immutable after first migration; nil = never relocated
  var originVolume: String?        // friendly volume name at original location
  ```
  Add `case originalFullPath, originVolume` to `CodingKeys`. In `init(from:)` use `decodeIfPresent` (matches the `audioTranscript` pattern at Models.swift:501-503). In `encode(to:)` use `encodeIfPresent` so unrelocated records add zero JSON bytes.
- Add a new `ArchiveStage` case after `archived` (preserves Comparable ordering):
  ```swift
  case salvageFailed   = "Salvage Failed"
  ```
  Update `icon` / `color`: `"exclamationmark.octagon.fill"` + `.red`. Bump `CatalogSnapshot.currentVersion` 4 → 5; old catalogs still load via `decodeIfPresent`.
- **Test:** new `RelocateSchemaTests.swift` round-tripping new+legacy JSON. Add a version assertion to `CatalogSnapshotTests.swift`.
- **Expected diff:** ~40 lines Models.swift, ~5 lines CatalogStore.swift, ~80 lines tests.

### 2. Model API — public entry on `VideoScanModel`

- **File (new):** `VideoScan/VideoScan/VideoScanModel+Relocate.swift`
- Mirror the `combineSelectedPairs` style: synchronous entry that spawns the work `Task`, async engine internals.
  ```swift
  struct RelocateOptions {
      var sourceVolumeRootPath: String       // "/Volumes/Mini2TB"
      var destinationRoot: URL               // user-chosen, e.g. /Volumes/LaCie8TB/from-Mini2TB
      var maxConcurrency: Int                // default 1 — Mini2TB is slow; parallel reads hurt
      var dryRun: Bool                       // default false
      var skipAlreadyRelocated: Bool         // default true — re-run safety
      var skipDupsOnOtherVolumes: Bool       // default true — enables Bucket E (added 2026-05-30)
  }

  enum RelocateError: Error {
      case sourceUnreachable, destinationUnwritable, insufficientSpace(needed: Int64, free: Int64)
      case readFailed(String), copyFailed(String), verifyFailed(String)
  }

  func relocateVolume(_ options: RelocateOptions)   // fire-and-forget; sets isRelocating
  func pauseRelocate()
  func resumeRelocate()
  func stopRelocate()
  ```
- Flow inside the spawned `Task` mirrors `combineAllPairsInternal`:
  1. **Pre-flight reconcile** — see §1A below.
  2. **Pre-flight stats** — filter records to those under the source root and not already relocated. Sum `sizeBytes`. Stat destination free space via `URLResourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`. Bail with `.insufficientSpace` if `total > free`.
  3. **Snapshot** — see §5.
  4. **Per-record loop** gated by `AsyncSemaphore(limit: options.maxConcurrency)`. State machine per record: `queued → reading → copying → verifying → committing → done | salvageFailed`.
  5. **End-of-batch summary** via `logRelocateSummary()` and a new pure `formatRelocatePerfSummary(jobs:)` paralleling `formatCombinePerfSummary` in VideoScanModel+Combine.swift.
- **Pure helpers** (testable without disk):
  ```swift
  static func recordsScoped(to sourceVolumeRootPath: String, in all: [VideoRecord]) -> [VideoRecord]
  static func rewrittenPath(forSourcePath src: String, sourceRoot: String, destRoot: String) -> String
  static func suggestDestinationName(forSourceVolumeName: String, now: Date) -> String  // "from-Mini2TB-20260530"
  ```
  `recordsScoped` filters by `"<sourceRoot>/"` (trailing slash) so `/Volumes/Mini2TB-backup` doesn't false-match `/Volumes/Mini2TB`.
- **Test:** `RelocateScopeTests.swift` covers scope selection, path rewriting (subdirectories, leading/trailing slashes), suggested-name format.
- **Expected diff:** ~350 lines engine, ~150 lines tests.

### 1B. Retire Volume (added 2026-05-30)

> **Context:** Real-world case is `Maxtor500FW`. After a Bucket E + Bucket B run, 100% of catalog records on that volume are `.manuallyDeleted`. The drive is failing; Rick wants to unplug it and never see the dashboard nag about it being offline again. This isn't about deleting catalog data — those records stay forever for audit and Compare & Rescue. It's about marking the *volume itself* retired so it stops showing up in scan suggestions and dashboard reachability complaints.

- **File (schema):** `VideoScan/VideoScan/Models.swift` — add three optional `@Published` properties to `CatalogScanTarget`:
  ```swift
  @Published var retiredAt: Date?
  @Published var retiredReason: String?       // free-text, e.g. "Failing HDD; all content dup-elsewhere"
  @Published var retiredWitnesses: [String]?  // union of Bucket E witnesses
  var isRetired: Bool { retiredAt != nil }
  ```
  Presence of `retiredAt` = retired. No new dedicated retire schema in `VideoRecord`; the record-level `.manuallyDeleted` disposition is already enough.
- **File (persistence):** `ScanTargetPersistence.swift` + `VideoScanModel+ScanTargetPersistence.swift` + three new UserDefaults dictionary keys (`VideoScan.scanTargetRetired{At,Reason,Witnesses}`). Missing entries decode as nil — pre-§1B installs round-trip not-retired.
- **File (bundle):** `VolumeMetadataSnapshot` gains the same three optional fields so bundle export/import round-trips retirement state. Legacy bundles (pre-§1B) decode the new fields as nil via `decodeIfPresent`.
- **Catalog version bump:** `CatalogSnapshot.currentVersion 5 → 6`. Pure marker — no record-level field was added, so v5 catalog.json files load cleanly on a v6-aware build. The version signals "a v6-aware build's parallel volume metadata layer (UserDefaults + bundle) *may* carry retire fields."

#### Flow

After `runRelocate` completes its catalog mutation phase and writes the end-of-batch summary, the §1A post-Apply summary sheet is published (`model.pendingRelocateSummary = ...`). The summary sheet's Done button calls `model.acknowledgeRelocateSummary()` — but as of §1A.2 (2026-05-30 PM) that no longer fires the retire offer. Instead the summary ends with "Open Volumes window to retire <name>", and the explicit retire surface is the new "Mark Retired…" context-menu action in the Volumes window (which calls `maybeOfferRetire(for:)` and presents the same `RelocateRetireSheet`). The `pendingRetireOffer` programmatic path is unchanged — tests still drive it directly via `maybeOfferRetire(for:)`. Trigger-order history: see §1A.1 (gate-after-summary) and §1A.2 (move-to-Volumes-window) below.

- Pure predicate: `shouldOfferRetire(volumeRootPath:in:) → bool`. True iff the volume has at least one record AND every catalogued record on it is `.manuallyDeleted`.
- When true, aggregate witnesses (`aggregateRetiredWitnesses` walks every `.manuallyDeleted` record on the volume and parses the structured Bucket E note via `parseWitnessesFromNote`, deduped/sorted union).
- Set `model.pendingRetireOffer = PendingRetireOffer(...)` carrying volume root path, friendly name, total record count, default reason text, witness union.

`ContentView` binds a `.sheet(item: $model.pendingRetireOffer)` to `RelocateRetireSheet`. Two buttons:
- **Retire:** calls `model.retireVolume(at:reason:witnesses:)` → stamps `retiredAt = Date()`, `retiredReason` (free-text, editable in the sheet), `retiredWitnesses`. Persists via `persistScanDates`. Audit-logs to the relocate log + in-app console.
- **Skip for now:** clears `pendingRetireOffer` without mutation. Can be triggered later from the volume row context menu.

No typed confirmation. Two buttons, fully reversible via Reinstate, friction unnecessary.

#### UI consequences

1. **`VolumesWindow` sidebar:** retired volumes get a `"Retired YYYY-MM-DD"` badge (brown pill), opacity reduced to 0.55, sorted to the bottom. Hidden entirely unless the toolbar `"Show retired"` toggle is ON.
2. **`VolumesWindow` editor:** the online/offline status line is replaced by a brown archive banner showing the retire date + reason + witness count. The destination-policy badge is hidden (retired drives aren't viable destinations).
3. **Context menu** on a sidebar row: a `"Reinstate"` action that opens a one-line yes/no alert → `model.reinstateVolume(at:)` clears all three retire fields.
4. **Scan suggestions:** `startAllTargets` adds a `guard !target.isRetired else { continue }` clause alongside the existing reachable / VideoScan_Temp guards. Reinstate puts the volume back in the loop.
5. **Dashboard "missing volume" nag:** the only relevant surface is the editor's online/offline line, suppressed for retired drives as described above. A retired-and-offline volume is the expected steady state — silent by design.

#### Tests

`RelocateRetireVolumeTests.swift` — Swift Testing, matches the existing relocate suite style:
- `retire_firesOnlyWhen100PercentDisposed` — predicate behavior at 0%, 66%, 100%.
- `retire_neverOffersOnEmptyVolume` — 0 records is not 100%.
- `retire_stampsTimestampReasonAndWitnesses` — full mutation persists.
- `retire_aggregatesWitnessesAcrossBucketERecords` — multi-record dedup.
- `retire_witnessParser_handlesEmbeddedQuotes` — defensive round-trip.
- `retire_skipDoesNothing` — clearing `pendingRetireOffer` doesn't mutate.
- `reinstate_clearsAllRetirementFields` — round-trip.
- `retiredVolume_isExcludedFromScanSuggestions` — predicate logic mirrored.
- `retiredVolume_isNotFlaggedAsMissing` — predicate logic.
- `snapshotRollback_restoresPreRetiredState` — pre-relocate snapshot has the volume not-yet-disposed.
- `volumeMetadataSnapshot_roundTripsRetireFields` — bundle export/import.
- `legacyV5CatalogWithoutRetiredFieldsDecodes` (in `RelocateSchemaTests`) — v5 catalog.json + legacy `VolumeMetadataSnapshot` JSON decode cleanly on v6 build.

Plus `RelocateSchemaTests.currentSnapshotVersionIsSix` swap for the v5→v6 bump.

### 1B.1. Delete from list (added 2026-05-31)

> **Context:** §1B Retire is the *"data is safely backed up, drive is going on the shelf"* path. It assumes the volume was a real catalog target and we want its records (plus history) preserved forever. But the Volumes window also accumulates *erroneous* entries — typos, dangling mounts, one-time scratch paths. The driving case is `/Volumes/rickb`: 0 catalog records, no purpose, just visual noise. Retire is wrong for it (nothing to back up; the brown badge would be a lie). The right call is to remove the entry from the list entirely.

**Delete vs. Retire — when to use which:**

| | Retire | Delete from list |
|---|---|---|
| **Use when** | Data is safely backed up; drive is going on the shelf | Volume entry was a mistake (orphan, typo, never used) |
| **Catalog records** | Kept, marked `.manuallyDeleted`, retain history | Untouched — become orphans (no scan-target context) |
| **`scanTargets` entry** | Kept, gets brown "Retired YYYY-MM-DD" badge | Removed entirely |
| **UserDefaults entries** | Updated (retire fields stamped) | All per-path entries cleared (dates, roles, trust, etc.) |
| **Reversibility** | Reinstate button puts it back to active | Re-scan the volume to re-add the entry |
| **Friction** | Two-button sheet, no typed confirmation | Destructive alert ("This cannot be undone") |
| **System-volume guard** | Allowed (the system volume is reachable, so usually not 100%-disposed anyway) | Blocked outright (`role == .system OR searchPath == "/"`) |

- **Surface:** Right-click on a volume row in the Volumes window → `"Delete from list…"` (red, with ellipsis to signal a confirmation dialog). Available for ALL volumes including retired ones; disabled only for the system volume.
- **Confirmation:** Single `.alert(item:)` carrying the pre-computed orphan count so the message reads truthfully ("The N catalog records still pointing at this path will become orphans"). Cancel is the default-highlighted button.
- **Model:** `VideoScanModel.deleteScanTarget(_:)` in `VideoScanModel+DeleteScanTarget.swift`. Removes from `scanTargets`, calls `persistScanTargets()` + `persistScanDates()` to rebuild every per-path UserDefaults dict from the surviving targets (the path naturally falls out), logs `"Volume <name> deleted from scan-targets list (had <N> catalog records — kept as orphans)"` to `catalog.log` and the in-app console.
- **Tests:** `DeleteScanTargetTests.swift` — Swift Testing.
  - `deleteScanTarget_removesFromScanTargets` — basic removal.
  - `deleteScanTarget_clearsAllPerPathDictionaries` — every dict (dates, phases, roles, trust, filesystem, mediaTech, purchaseYear, capacity, notes, retiredAt, retiredReason, retiredWitnesses) loses the doomed path; surviving targets keep theirs.
  - `deleteScanTarget_doesNotTouchCatalogRecords` — records' `fullPath` + `id` unchanged; orphans still scope to the deleted volume path.
  - `deleteScanTarget_systemVolume_isBlocked` — both `role == .system` AND `searchPath == "/"` trip the guard.
  - `deleteScanTarget_logsBreadcrumb` — console flush carries "deleted from scan-targets list" + record count.
  - `deleteScanTarget_returnsFalseWhenTargetNotInArray` — idempotent no-op for stray objects.

### 1A. Pre-flight reconcile (added 2026-05-29 evening; Bucket E added 2026-05-30)

> **Context:** Rick is manually deleting / moving / pre-copying files off Mini2TB while the feature is being designed. By the time Relocate runs, the catalog will be drifted from reality. Reconcile sorts this out before the migration phase walks records, so manual triage and Relocate compose cleanly.

- **File:** `VideoScan/VideoScan/VideoScanModel+Relocate.swift` (same file as §2; new internal phase that runs as step 1 of `relocateVolume`'s Task body, before the §2 pre-flight stats so the stats already reflect the reconciled state).
- **Algorithm — for each catalog record whose `fullPath` is under `sourceVolumeRootPath`:**
  1. `fileExists(atPath: rec.fullPath)` and partial-MD5 still matches → **Bucket A: ready to migrate**. Proceed normally.
  2. File missing AND no plausible match found in scan of source volume or scan of `destinationRoot` → **Bucket B: manually deleted**. Flip `archiveStage = .manuallyDeleted` (new enum case alongside `salvageFailed`, same conventions), append note "Reconcile <ISO8601>: source file not found", leave `fullPath` untouched so Compare & Rescue can still see what was lost from where.
  3. File missing at recorded path BUT a same-size + same-partialMD5 file is found *elsewhere on the same source volume* → **Bucket C: moved within source before migration**. Rewrite `fullPath` to the new in-source location, log "Reconcile <ISO8601>: source-side move <old> → <new>", queue for migration as Bucket A.
  4. File missing at recorded path BUT a same-size + same-partialMD5 file is already at the planned destination (`rewrittenPath(forSourcePath:rec.fullPath, ...)`) → **Bucket D: pre-migrated manually**. Set `originalFullPath = rec.fullPath`, set `originVolume = rec.volumeName`, rewrite `fullPath` to the dest path. *Skip the copy.* Log "Reconcile <ISO8601>: already at destination — adopted, no copy needed."
  5. **Bucket E (added 2026-05-30): safely redundant on a third volume.** Same (`sizeBytes`, `partialMD5`) exists on at least one catalogued volume that is *neither* the source nor the destination → mark `archiveStage = .manuallyDeleted` and append a structured audit-trail note carrying the first 5 witness `fullPath` values plus the full witness count. **Source file is never read or modified** — pure catalog mutation. Gated by `skipDupsOnOtherVolumes: Bool` (default `true`) in `RelocateOptions`. Preference order: destination match (Bucket D) wins over safely-redundant; the source-still-present record (Bucket A) also wins. This is the failing-drive escape hatch: Mini2TB has 741 records, ~739 dup'd on MyBook3Terabytes / InternalRaid / Seagate2TB / LACIE500; we don't burn a copy cycle on content already safe elsewhere. Empty-hash records and zero-byte records are unconditionally excluded — too weak a signal for a "safely redundant" claim.
- **Discovery scan optimization:** Build a `[Int64 -> [URL]]` size-index of source volume contents once at start (fast — single `enumerator` walk; no hashing). Only hash candidate files when a record's size matches an entry in the index. Same trick on the destination subfolder. Without this, reconcile would be O(records × files) hashes — unaffordable on a flaky drive.
- **Reconcile dashboard line in the pre-flight UI:**
  ```
  Reconcile complete:
    Ready to migrate:     112
    Already at dest:       18   (will be adopted, not copied)
    Safely redundant:     739   (will mark as deleted with audit trail)
    Source-side moves:      4   (paths rewritten)
    Manually deleted:       6   (will be marked deleted, kept for audit)
  ```
- **`.manuallyDeleted` ArchiveStage** — added to the §1 schema work; same pattern as `salvageFailed`. icon: `"trash.slash.fill"`, color: `.secondary` (less alarming than salvageFailed; manual deletion is expected, not a failure).
- **Idempotency:** Reconcile is safe to re-run; Buckets B and D are no-ops on records already in those states. The migration phase itself reads from the (now-reconciled) record set.
- **Dry run flag** in `RelocateOptions` runs reconcile + reports the bucket breakdown without committing any catalog mutation. Lets Rick preview before pulling the trigger.
- **Test:** `RelocateReconcileTests.swift` — synthetic catalog with 4 records, fault-inject the 4 conditions (file present / file missing / file moved within source / file already at dest), assert correct bucket assignment + catalog mutation after `reconcile()`. ~200 lines.
- **Expected diff:** ~250 lines engine (reconcile is the heavyweight new logic), ~200 lines tests.

### 1A.1. Post-Apply summary sheet + dry-run mutation gate (added 2026-05-30)

> **Context:** Rick's first end-to-end §1A run (on Maxtor500FW) finished correctly but raced past him into the §1B Retire prompt with no visible confirmation that the source media was accounted for elsewhere. Same session, the dry-run code path was silently committing Bucket B/D/E disposition writes despite the user-facing "preview only" framing.

**Trigger ordering — `pendingRelocateSummary` gates `pendingRetireOffer`:**

- `runRelocate` no longer calls `maybeOfferRetire` itself. Instead it sets a new `@Published var pendingRelocateSummary: RelocateSummary?` on `VideoScanModel` after the work completes (both real runs AND dry-runs).
- `ContentView` binds a `.sheet(item: $model.pendingRelocateSummary)` to a new `RelocateSummarySheet`. The sheet renders the same buckets the end-of-batch log block carries plus a "Show witnesses" disclosure (up to 10 sample `source → witness` pairs parsed from the Bucket E audit notes) and a clickable pre-relocate snapshot path (reveal-in-Finder).
- The sheet's **Done** button calls `model.acknowledgeRelocateSummary()`, which drops `pendingRelocateSummary` AND — when the run wasn't a dry-run — calls `maybeOfferRetire`. The retire offer can no longer fire before the user has dismissed the summary.

**Progress sheet — minimum-visible window:**

- A new `RelocateProgressSheet` auto-presents while `model.isRelocating == true`. Two modes: when `toMigrate.count > 0` it shows `[N / M] currentFile.mxf` + a linear progress bar driven by `dashboard.relocateCompleted / dashboard.relocateTotal` + a verified counter; when there's nothing to copy (Bucket B/D/E only) it shows a `"Verifying audit trail…"` spinner.
- `runRelocate` enforces a minimum visible window of 800 ms via `padToMinVisible(runStart:minVisibleSeconds:)` before publishing the summary. Bucket-E-only sweeps that complete in <100 ms used to flash past unreadable; the pad is a real `Task.sleep` after the I/O has finished, not a fake delay during work.

**Dry-run mutation gate:**

- Previously, Bucket B/D/E disposition writes were applied BEFORE the `if options.dryRun { return }` short-circuit. That was a latent bug — dry-run flipped `archiveStage = .manuallyDeleted` on records the user expected to be untouched. Now every disposition write is wrapped in `if !options.dryRun { ... }`. The dry-run summary computes its counts directly from `reconcile.*.count` instead of the (skipped) mutations.
- The pre-relocate `.json` snapshot still runs in dry-run (cheap, useful audit), but no record state is touched.

**`relocate.log` routing fix:**

- `PersistentLog` instances are no-ops until `start()` is called (the file handle stays nil). The earlier wiring never opened `relocate.log`, so every `relocateLog.write(...)` silently dropped while the same lines flowed through the in-app `log()` into `catalog.log`. Fixed by calling `relocateLog.start(append: true)` at the top of `runRelocate` and writing a per-session header (`── Relocate session started <ISO8601> on <hostname> v<MARKETING_VERSION>`).

**Tests (`RelocateSummarySheetTests.swift`):**

- `dryRun_doesNotMutateBucketBDEDispositions` — assembled a B + D + E mini-catalog, runs dry-run, asserts all three records still `.archiveStage == .none`.
- `apply_setsPendingRelocateSummary_andDoesNotFireRetireUntilDone` — verifies trigger ordering directly; `pendingRetireOffer` stays nil until `acknowledgeRelocateSummary()` is called.
- `summarySheet_witnessDisclosure_extractsSourceWitnessPairsFromBucketE` — pure helper coverage for `witnessSamples(from:limit:)`.
- `progressUI_shortRun_paddedToMin800ms` — wall-clock check that a Bucket-E-only run holds at least 750 ms before publishing the summary.
- `relocateLog_writesToRelocateLogFile_notCatalogLog` — measures `relocate.log` growth + spot-checks the session header.

Plus a small touch to `RelocateRetireVolumeTests.snapshotRollback_restoresPreRetiredState` to acknowledge the summary before checking the retire offer (the test now exercises the new gate explicitly).

### 1A.2. Safe-witness ranking + Volumes-window retire flow + friendly copy (added 2026-05-30, same day)

> **Context (Rick):** "the backups/dups verified copies being on mini2tb is not so reassuring, the role or status of that drive is old or nearing retirement [...] when you confirm we have copies/backups we need to see the safest volume first [...] ideally the app would give a very reassuring message saying 'we got ya files dude, there safe over here and I just checksummed them and so, all is well [...]'."

Three changes follow:

**Safe-witness filter (reconcile-time gate):**

- New `SafeWitnessInfo` struct: `path`, `role`, `trust`, derived `safetyScore` (`roleScore*10 + trustScore` — role weighted 10x to dominate trust), derived `isSafe` (role != .retired AND trust != .unreliable).
- `SafelyRedundantEntry` gains `safeWitnesses: [SafeWitnessInfo]` (ranked safe-only) and `degradedWitnesses: [SafeWitnessInfo]` (retired/unreliable hosts). The existing `witnesses: [String]` audit-trail array now contains the safe-only top sample so backward-compatible parsing keeps working.
- `RelocateReconcile.reconcile(...)` gains `resolveVolumeSafety: VolumeSafetyResolver` parameter (closure `(String) -> (VolumeRole, VolumeTrust)`). Default is `permissiveResolver` so existing test callers compile unchanged.
- Bucket E classification now hard-gates on `!safe.isEmpty`. If every witness lives on a degraded host, the record falls through to Bucket A (must be copied) — the conservative call. The same record's degraded witnesses are still recorded on the entry for the disclosure but cannot justify classification.
- `VideoScanModel.makeVolumeSafetyResolver()` builds the resolver from the current `scanTargets` — longest-prefix match, falls back to `(.unassigned, .unknown)` for unknown paths (neutral; counts as safe-by-default since neither matches the explicit retired/unreliable predicates).

**Family-friendly summary copy + Volumes-window CTA:**

- `RelocateSummarySheet` rewritten with three headline modes:
  - "Your files are safe" — every record disposed and at least one safe witness per record. Subhead: "I found backup copies of all NN files on safer drives and checksum-verified them. Everything's accounted for — you can retire <name> whenever you're ready."
  - "Files copied and verified" — some Bucket A copies happened. Subhead summarises copies + remaining safely-backed-up count.
  - "Dry-run preview" — preview only.
- Witness section reorganised: safe witnesses appear first with `host volume · role · trust` badges, sorted by safety score. Degraded witnesses go under a "See all matches (N on aging/retired drives)" disclosure and are greyed + tagged `(retired)` / `(unreliable)`.
- "Open Volumes window" button added. Clicking it pre-selects the source volume (`model.pendingVolumesSelectionID`) and opens the Volumes window via `@Environment(\.openWindow)`. Replaces the prior auto-retire trigger from the Done button.
- `acknowledgeRelocateSummary()` no longer fires `maybeOfferRetire`. The `pendingRetireOffer` machinery + `maybeOfferRetire(for:)` API remain — tests use the programmatic path, and the Mark Retired action in the Volumes window calls into it.

**Mark Retired action in Volumes window:**

- New `VolumeRetireStatus` UI-only struct: `totalRecords`, `disposedRecords`, `allDisposed`, `hasSafeWitness`. Derived predicates: `isSafeToRetire`, `isDegradedDisposed`, `canRetire` (= `isSafeToRetire`).
- Right-click menu on each non-retired sidebar row gains a "Mark Retired…" item, enabled only when `canRetire` is true. Disabled state carries a tooltip explaining what's missing ("Not all files on this volume are accounted for yet — run Relocate first." / "Files are marked disposed, but no backup copies are confirmed on safer drives.").
- Sidebar row badges: green pill "Safe to retire" when `isSafeToRetire`; yellow pill "Disposed, degraded backups" when `isDegradedDisposed`.
- Clicking Mark Retired builds a `PendingRetireOffer` (witness union via `aggregateRetiredWitnesses`) and presents the existing `RelocateRetireSheet`. Single confirmation surface for both the (deprecated) post-Relocate flow and the new explicit menu flow.

**Tests added to `RelocateSummarySheetTests.swift`:**

- `bucketE_requiresAtLeastOneSafeWitness` — fault-injects a degraded-only witness set, asserts no Bucket E classification; then adds a safe witness and asserts classification fires.
- `witnessRanking_sortsBySafetyScore_roleDominatesOverTrust` — LTA+Aging beats Backup+Reliable in the safe-witness ranking.
- `witnessRanking_demotesRetiredAndUnreliableBelowSafeOnes` — retired/unreliable witnesses go into `degradedWitnesses`, safe goes into `safeWitnesses`.
- `summarySheet_headlineMatchesPattern_allSafe` — Bucket E only + safe witness ⇒ `succeededCount == 0`, `safelyBackedUpCount > 0`.
- `summarySheet_headlineMatchesPattern_mixedCopyAndRedundant` — mixed Bucket A + Bucket E run.
- `summarySheet_endsWithVolumesWindowCTA_notAutoRetirePrompt` — `acknowledgeRelocateSummary()` no longer fires `pendingRetireOffer`.

**Tests in new `VolumesWindowRetireTests.swift`:**

- `volumesWindow_markRetiredAction_enabledOnlyWhen100PercentSafelyDisposed` — state machine: empty → no record → disposed-with-degraded-only → disposed-with-safe (enabled) → mixed-not-disposed.

Plus `RelocateRetireVolumeTests.snapshotRollback_restoresPreRetiredState` updated again: Done no longer fires retire; the test now calls `maybeOfferRetire(for:)` directly to simulate the Volumes-window menu action.

### 2. Provenance & Audit Trail (added 2026-05-30 evening)

> **Context (Rick):** "For Matt's 32nd birthday reel I want to be able to point at every clip and show its journey — where it was scanned, what we did to it, where the safe copies are."

A read-only feature that surfaces what the catalog already knows about every file's history. No schema changes; reuses `notes`, `originalFullPath`, `originVolume`, `archiveStage`, `partialMD5`, and the existing `scanTargetRoles` / `scanTargetTrust` taxonomy from §1A.2.

**Three views (all sheets — no new tabs, no toolbar real estate change beyond one button):**

1. **Volume Provenance** — "Where files from \<vol\> live now." Triggered by right-clicking any sidebar row in `VolumesWindow.swift` ("Show where files went…"). Works on retired AND active volumes. Two tabs:
   - *Safe backups* (default): destination volumes whose host has `role != .retired` AND `trust != .unreliable`. Sorted by the same `roleScore*10 + trustScore` ranking from §1A.2.
   - *All known copies*: everything, with degraded volumes greyed and tagged `(retired)`/`(unreliable)`.
   - Header strip: green "All NN files have at least one safe backup" OR yellow "M of NN files lack a safe backup" with a disclosure listing the at-risk filenames. Retired volumes show the retire-date / reason banner.

2. **File Journey** — "Following \<filename\>." Triggered by right-clicking any active record in the catalog table ("Show this file's journey"). Vertical timeline:
   - Origin (Scanned on \<originVolume\> at \<originalFullPath\>).
   - One event per parsed Reconcile/Combine/Relocate line in `notes`. Sorted ascending by parsed timestamp; free-form notes pinned to the end.
   - Current state (Now at \<fullPath\> OR Marked deleted) with safe-witness count.
   - Disclosure of every other known copy: dup-group siblings ∪ Bucket E witnesses, ranked safe-first.
   - Hash status line at top.

3. **Migration Overview** — "From aging drives to safe homes." Triggered by a new toolbar button in `VolumesWindow.swift` (icon: `chart.bar.doc.horizontal`). Four sections:
   - Fleet snapshot pie (records by current host role) — native SwiftUI `Chart` with `SectorMark`.
   - Migration flow bars (stacked, one bar per origin role; segments = destination roles) — `Chart` with `BarMark`.
   - Triage funnel (Scanned → Triaged → Repaired/Combined → Archived) — derived from `archiveStage` + `combinedFromPairID`.
   - "The best stuff" highlight — records that went through Combine AND reached `.archived` OR live on an `.lta`/`.archive` role volume. Big friendly count.

**Files (all new, except thin hooks in two existing files):**

- `VideoScan/VideoScan/ProvenanceTypes.swift` — value types: `VolumeProvenance`, `DestinationVolumeGroup`, `FileJourney`, `JourneyEvent`, `JourneyEventKind`, `KnownCopy`, `MigrationOverview`, `FleetRoleSlice`, `MigrationFlowBar`, `MigrationFlowEntry`, `TriageFunnelStage`.
- `VideoScan/VideoScan/VideoScanModel+Provenance.swift` — pure `nonisolated static` builders + MainActor wrappers. Reuses `VolumeSafetyResolver` from §1A.2 and `parseWitnessesFromNote` from §1B. New: `parseRelocateEventsFromNotes` lifts every Reconcile/Combine/Relocate line into a typed `ParsedNoteEvent`.
- `VideoScan/VideoScan/VolumeProvenanceSheet.swift` — View 1. Two-tab Picker + scrollable card list + at-risk disclosure.
- `VideoScan/VideoScan/FileJourneySheet.swift` — View 2. Vertical timeline with icon spine + copies disclosure.
- `VideoScan/VideoScan/MigrationOverviewSheet.swift` — View 3. Native `Charts` framework (`SectorMark`, `BarMark`).
- `VideoScan/VideoScan/VolumesWindow.swift` — adds context-menu item "Show where files went…" + toolbar button "Migration Overview" + two `.sheet(item:)` bindings.
- `VideoScan/VideoScan/CatalogHelpers.swift` — adds context-menu item "Show this file's journey" to the active-row branch + one `.sheet(item:)` binding.

**Tests (new file `VideoScan/VideoScanTests/ProvenanceTests.swift`, 10 tests):**

- `volumeProvenance_groupsWitnessesByDestinationVolume` — multi-witness records ⇒ groups keyed by host volume, sort by safety score.
- `volumeProvenance_safeTabExcludesRetiredAndUnreliable` — retired-only witnesses don't satisfy "safely backed up."
- `volumeProvenance_safeTabIncludesAgingButTrustedNonRetired` — guards against conflating "aging" with "degraded."
- `volumeProvenance_emptyVolumeShowsEmptyState`.
- `fileJourney_parsesReconcileEventsFromNotesInOrder` — out-of-order timestamps sort ascending.
- `fileJourney_handlesRecordWithNoNotes` — minimum-info path renders Origin + Current.
- `fileJourney_currentStateReflectsArchiveStage` — `.manuallyDeleted` ⇒ retire icon + friendly copy.
- `migrationOverview_countsByOriginRoleCorrectly` — origin role derived from `originalFullPath` ?? `fullPath`.
- `migrationOverview_bestStuffCountsRecordsThatAreCombinedAndArchived` — `combinedFromPairID != nil` AND (`.archived` OR on `.lta`/`.archive` volume).
- `friendlyHeadlineDoesNotContainSecurityJargon` — anti-drift guard. Caught a real "audit" leak during initial implementation; fixed.

**Friendly-tone rule enforced via test guard** (per `feedback_friendly_language.md`): no "audit", "compliance", "integrity scan", "surveillance", or "forensic" in any user-facing string the builders produce.

### 3. Engine — per-record copy + verify

- **File (new):** `VideoScan/VideoScan/RelocateEngine.swift`
- Pure, nonisolated engine — no `VideoScanModel` reference — takes a `Sendable` `RelocateJob` snapshot and returns `RelocateOutcome`. Same separation `CombineEngine` enforces vs `VideoScanModel+Combine`.
  ```swift
  struct RelocateJob: Sendable {
      let recordID: UUID
      let sourcePath: String
      let destPath: String
      let expectedBytes: Int64
      let expectedPartialMD5: String
  }

  enum RelocateOutcome {
      case success(actualBytes: Int64, newPartialMD5: String, copyDuration: TimeInterval)
      case salvageFailed(reason: String, stage: Stage)
      enum Stage { case preRead, copy, postStat, hashMismatch, sizeMismatch }
  }

  static func runOne(_ job: RelocateJob,
                     fileManager: FileManager = .default,
                     onProgress: (@Sendable (Int64) -> Void)? = nil) async -> RelocateOutcome
  ```
- Per-record sequence inside `runOne`:
  1. **Destination collision:** if `fileExists(atPath: job.destPath)`, → `salvageFailed(.copy, "destination exists")`. A pre-existing file at the planned dest is almost certainly a half-finished previous run. Reconcile's Bucket D handles the legitimate case of "already there."
  2. **Source pre-read probe:** `open(O_RDONLY | O_NONBLOCK)`, `read` 1 byte, close. Catches dead drives in ~1s instead of stalling on a 2 GB copy attempt. On failure → `salvageFailed(.preRead, errno)`.
  3. **Create intermediate dirs:** `createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)`.
  4. **Copy:** `copyItem(atPath: job.sourcePath, toPath: job.destPath)`. Wrap in a Swift `Task` with `withThrowingTaskGroup` so an outer per-file timeout (default 30 min for giant DV files on Mini2TB) can cancel a hung read.
  5. **Verify:**
     - `attributesOfItem(atPath: dest).size` must equal `job.expectedBytes` → else `salvageFailed(.sizeMismatch)`.
     - `FileHasher.partialMD5(path: dest)` (existing util, FileHasher.swift:15) must equal `job.expectedPartialMD5` → else `salvageFailed(.hashMismatch)`. If the catalog has no stored hash (legacy), accept size-only verify and log it.
  6. On mid-copy `salvageFailed`, `try? removeItem(atPath: job.destPath)` so dest doesn't accumulate half-files. On `.hashMismatch`, leave the dest in place and log the path — Rick may want to inspect.
- **No retry policy.** Mini2TB is failing; retries waste time. Surface and move on.
- **HFS+ → APFS:** `copyfile(3)` handles xattrs natively. Document in a comment on `runOne`; integration test asserts `xattr -l` parity (§10).
- **Test:** `RelocateEngineTests.swift` — synthetic `/tmp` source files exercise success path; truncate dest to exercise `.sizeMismatch`; flip a byte mid-file to exercise `.hashMismatch`; non-existent source for `.preRead`. ~250 lines.
- **Expected diff:** ~280 lines engine.

### 4. Catalog mutation — provenance + commit

- **File:** `VideoScan/VideoScan/VideoScanModel+Relocate.swift` (same as §2)
- After successful `runOne`, on the main actor:
  ```swift
  if rec.originalFullPath == nil { rec.originalFullPath = rec.fullPath }
  if rec.originVolume == nil { rec.originVolume = rec.volumeName }
  rec.fullPath = newPath
  rec.directory = (newPath as NSString).deletingLastPathComponent
  rec.scanContext = ScanContext.capture(for: URL(fileURLWithPath: newPath))
  rec.partialMD5 = newPartialMD5
  catalogStore.scheduleSave(records: records)   // debounced; not per-record
  ```
- On `.salvageFailed`:
  ```swift
  rec.archiveStage = .salvageFailed
  rec.notes = appendNote(rec.notes, "Relocate \(stamp): \(reason)")
  catalogStore.scheduleSave(records: records)
  ```
- **Resume / idempotency:** records with non-nil `originalFullPath` skip on the next run (default `skipAlreadyRelocated: true`). A crash mid-batch leaves N records mutated, M untouched; rerunning hits only M. Atomic JSON write means no torn catalog. Best-effort `.relocate-state.json` next to the run records `{ runID, sourceVolume, completedRecordIDs }` so resume can detect "dest file exists AND record still points at source" (rare half-committed state from SIGKILL between `copyItem` and `scheduleSave`).

### 5. Catalog snapshot before mutation

- **File:** `VideoScan/VideoScan/VideoScanModel+Relocate.swift`
- One-shot belt-and-suspenders snapshot before any record mutation:
  ```swift
  let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
  let snapURL = appSupportURL.appendingPathComponent("catalog.pre-relocate.\(stamp).json")
  try? FileManager.default.copyItem(at: catalogStore.fileURL, to: snapURL)
  log("Pre-relocate snapshot: \(snapURL.path)")
  ```
  Simple `copyItem` of `catalog.json` rather than `BundleExporter` — the bundle exporter is for cross-machine portability and is overkill here. CatalogStore's `.prev` rotation is one-generation only and isn't enough for a multi-minute run spanning multiple debounced saves.
- Snapshot is never auto-deleted; surface its path in the end-of-run summary banner.
- **Test:** asserts a `catalog.pre-relocate.*.json` file lands in the test's `CatalogStore(directory:)` after `relocateVolume(...)`. ~20 lines.

### 6. Dashboard wiring

- **File:** `VideoScan/VideoScan/DashboardState.swift`
- Parallel block to Combine state (DashboardState.swift:117-126):
  ```swift
  @Published var relocateTotal: Int = 0
  @Published var relocateCompleted: Int = 0
  @Published var relocateSucceeded: Int = 0
  @Published var relocateSalvageFailed: Int = 0
  @Published var relocateManuallyDeleted: Int = 0   // reconcile result
  @Published var relocateAdopted: Int = 0           // reconcile Bucket D
  @Published var relocateSkipped: Int = 0
  @Published var relocateBytesCopied: Int64 = 0
  @Published var relocateCurrentFile: String = ""
  @Published var relocateJobs: [RelocateJobStatus] = []
  var relocateStartTime: Date?
  func resetForRelocate(total: Int) { ... }
  ```
- New `RelocateJobStatus` struct mirroring `CombineJobStatus`: id, recordID, sourcePath, destPath, expectedBytes, phase enum (`queued → reconciling → reading → copying → verifying → done | salvageFailed | manuallyDeleted | adopted | skipped`), startTime, endTime, progressFraction, errorReason.
- Add `isRelocating: Bool`, `isRelocatePaused: Bool` `@Published` on `VideoScanModel` (parallel to `isCombining`).

### 7. UI — Relocate sheet + toolbar entry + progress window

- **File (new):** `VideoScan/VideoScan/RelocateSheet.swift`
- Modeled directly off `CombineSheet.swift` — same layout language, idioms (`GroupBox`, `chooseOutputFolder`, free-space readout, insufficient-space red banner, `@AppStorage` for last-used dest, `accessibilityIdentifier` hooks).
- **Pre-flight sections:**
  - Source volume picker: `Menu` over `model.scanTargets`, defaulting to volumes flagged `.unreliable` / `.aging` per `VolumeTrust`. Mini2TB will surface naturally once flagged.
  - Destination folder picker, persisted under `relocateDestFolderKey`.
  - **Reconcile preview** (new): a small button "Reconcile (preview)" that runs the reconcile phase in dry mode and shows the 4-bucket breakdown before commit.
  - Pre-flight stats: matching record count, total bytes, free space on dest, count already relocated (skipped).
  - "Dry run (no copies)" checkbox.
- **Button bar:** Cancel + "Relocate N file(s) (X.X GB)" — disabled when count == 0, dest nil, insufficientSpace, or source unreachable.
- **Progress window** — `RelocateWindow.swift` mirroring `CombineWindow.swift`: per-job rows, current file, progress bar, live MB/s, pause/resume/stop. Register `WindowGroup(id: "relocate")` in `VideoScanApp.swift`. Recommend the separate-window pattern since runs may take hours.
- **Toolbar entry** in `CatalogHelpers.swift` next to Combine (around line 207):
  ```swift
  Button(action: { showRelocateSheet = true }) {
      Label("Relocate…", systemImage: "externaldrive.badge.checkmark")
  }
  .buttonStyle(.bordered)
  .disabled(model.isScanning || model.isReadOnly || model.records.isEmpty)
  .accessibilityIdentifier("catalog.relocate.openSheet")
  .help("Copy all catalogued files from a flaky source volume onto a healthier destination and rewrite catalog paths.")
  ```
- ContentView wire-up: `@State private var showRelocateSheet = false`, `.sheet(isPresented: $showRelocateSheet) { RelocateSheet() }`.
- **Expected diff:** ~450 lines sheet, ~180 lines window, ~30 lines toolbar/ContentView.

### 8. Logging

- Dedicated `PersistentLog(name: "relocate")` → `~/Library/Logs/VideoScan/relocate.log`.
- Per-record success: `[N/M] <filename> — copied <bytes> in <s>, hash <prefix>, → <destPath>`.
- Per-record failure: `[N/M] <filename> — SALVAGE FAILED at <stage>: <reason>`.
- Reconcile lines: `[RECONCILE] adopted: <path>` / `[RECONCILE] source-move: <old> → <new>` / `[RECONCILE] manual-delete: <path>`.
- High-level start/end lines mirrored into global `appLog.write(...)` (Combine pattern at VideoScanModel+Combine.swift:29).
- End-of-batch banner via `logRelocateSummary()` paralleling `logCombineSummary()`. Numbers: succeeded, skipped, salvageFailed, adopted, manuallyDeleted, total bytes copied, wall clock, average MB/s, list of salvageFailed paths (first 20 + "...and N more — see relocate.log"), pre-relocate snapshot path.
- Pure formatter: `static func formatRelocatePerfSummary(jobs:fileManager:now:)` paralleling `formatCombinePerfSummary`. Same testing pattern as `CombinePerfSummaryTests.swift` applies verbatim. ~80 lines test, ~30 lines formatter.

### 9. Compare & Rescue audit

- **Files to check:** `VolumeCompare.swift` and `VideoScanModel+Duplicates.swift`.
- **Risk:** Compare's dedup matches on (`sizeBytes`, `partialMD5`, `filename`). After Relocate there's still **one record per file** (not two), so Compare won't see ghost duplicates. Downgraded.
- **Action:** document the invariant in a doc-comment on `originalFullPath` and add `DuplicateDetectorRelocateRegressionTests.swift` (3 relocated + 3 fresh records sharing nothing → assert no duplicate groups form). ~60 lines test, ~5 lines comment.

### 10. End-to-end integration test

- **File (new):** `VideoScan/VideoScanTests/RelocateIntegrationTests.swift`
- Build temp source `dir1 = NSTemporaryDirectory()/relocate-src-<UUID>/` with 5 known files (varying sizes; one zero-byte; one with xattrs set via `setxattr`); temp dest `dir2`. Synthesize 5 `VideoRecord`s pointing at `dir1`, stamp `partialMD5` via `FileHasher`. Construct a `VideoScanModel` with `CatalogStore(directory: testDir)`. Call `relocateVolume(...)`.
- Assertions:
  - All 5 records' `fullPath` now under `dir2`.
  - `originalFullPath` and `originVolume` populated.
  - Files exist at new paths; size matches; `partialMD5` matches.
  - xattrs survived (`getxattr` read-back).
  - `catalog.pre-relocate.*.json` exists in `testDir`.
- **Salvage-failed fault inject:** 6th record's source `chmod 0000`. Re-run. Assert `archiveStage == .salvageFailed`, `originalFullPath == nil`, `fullPath` unchanged.
- `VS_RELOCATE_INJECT_FAIL=<recordID>` env var honored by `RelocateEngine.runOne` (mirrors `VS_COMBINE_LIMIT_N` at VideoScanModel+Combine.swift:655) for deterministic `.copy`-stage failure injection without chmod gymnastics.
- **Reconcile integration:** synthesize the 4 reconcile buckets in dir1 + dir2 setup; assert bucket assignments + post-reconcile catalog mutation.
- **Expected diff:** ~300 lines + ~10 lines fault injection.

### 11. UI smoke test

- **File (new):** `VideoScan/VideoScanUITests/RelocateSheetUITests.swift`
- Pattern: follow `CombineBulkWorkflowUITests` (commit `98a8cd9`). Fixture catalog, fake source in `/tmp`, drive `catalog.relocate.openSheet`, pick volume + dest, click Relocate, assert progress window + summary banner. ~120 lines. Skipped in CI like the other UI tests.

---

## Risk register (severity ordered)

1. **SEV 1 — Mid-run crash leaves catalog half-mutated.** Mitigated by per-record `scheduleSave` debounce (≤2s unwritten window), atomic-rename in `CatalogStore.writeToDisk`, pre-relocate full snapshot (§5), and `originalFullPath != nil` as resume marker. Residual: a record may be "copied to dest, catalog still says source" for up to 2s — SIGKILL there orphans the dest file. The `.relocate-state.json` audit trail (§4) lets resume detect this.
2. **SEV 1 — Capacity exhaustion mid-run.** Pre-flight free-space check blocks if `total > free`. Stat free space every 50 records during run and abort if `freeNow < remainingBytes * 1.05`. Mid-run abort leaves N committed, M untouched; Rick frees space and re-runs.
3. **SEV 2 — Destination has a file at the planned path.** Treated as `salvageFailed(.copy, "destination exists")` rather than overwriting (§3.1). Reconcile's Bucket D handles the legitimate already-there case. Rejected alternative: rename with `-(2).mov` suffix — would double feature surface area.
4. **SEV 2 — Compare & Rescue post-Relocate confusion.** Audited in §9; no code change but regression-tested.
5. **SEV 2 — HFS+ xattr/resource-fork loss on copy.** `copyfile(3)` with `COPYFILE_ALL` preserves xattrs, ACLs, FinderInfo. Integration test asserts `xattr -l` parity. INFO-level "xattr count delta" line per record for auditability.
6. **SEV 3 — User picks the wrong source volume.** Pre-flight banner shows file count + total bytes; if 0 records match, Relocate button stays disabled. Picker defaults to volumes flagged `.unreliable` / `.aging`.
7. **SEV 3 — Source disconnects mid-run.** 1-byte pre-read fails fast; subsequent records cascade to `.preRead` `salvageFailed`. Engine doesn't crash; user reconnects and re-runs.
8. **SEV 3 — Read-only viewer mode (sync follower).** Disable toolbar entry when `isReadOnly`. `CatalogStore.saveNow` already refuses writes if bypassed.
9. **SEV 4 — Snapshot files accumulate forever.** `catalog.pre-relocate.<ISO8601>.json` not auto-cleaned. Document in tooltip; revisit when >10. Cheap to clean by hand.
10. **SEV 4 — `partialMD5` re-stamping.** Engine recomputes on dest. Legacy records get a hash (improvement). Catalog-vs-dest hash mismatch IS the `.hashMismatch` salvage failure; original record left intact.

---

## Critical files

- `VideoScan/VideoScan/Models.swift` — schema (§1)
- `VideoScan/VideoScan/VideoScanModel+Relocate.swift` (new) — model API + reconcile + commit (§§2, 1A, 4, 5)
- `VideoScan/VideoScan/RelocateEngine.swift` (new) — per-record copy/verify (§3)
- `VideoScan/VideoScan/RelocateSheet.swift` (new) — UI (§7)
- `VideoScan/VideoScan/RelocateWindow.swift` (new) — progress (§7)
- `VideoScan/VideoScan/DashboardState.swift` — counters (§6)
- `VideoScan/VideoScan/CatalogHelpers.swift` — toolbar (§7)
- `VideoScan/VideoScan/ContentView.swift` — sheet plumbing (§7)
- `VideoScan/VideoScanTests/Relocate*Tests.swift` (new × ~5)
- `VideoScan/VideoScanUITests/RelocateSheetUITests.swift` (new)

## Estimated total diff

~2,200 lines added across ~12 files (production + tests). Production-only ≈ 1,300 lines. Comparable to Combine's footprint.

## Sequencing recommendation

1. Schema + provenance (§1) — lands first; legacy catalogs still load.
2. Pure helpers + reconcile logic + tests (§§2 partial, 1A) — testable without disk.
3. Engine + tests (§3) — testable in /tmp.
4. Catalog mutation + snapshot (§§4, 5) — needs §§1–3.
5. Dashboard wiring (§6) — needs §§2, 4.
6. UI (§7) — needs all of the above.
7. Logging (§8) — fold into §§2–5.
8. Compare audit + regression test (§9) — independent, can land any time.
9. Integration test (§10) — last; exercises everything end-to-end.
10. UI smoke test (§11) — after §7 lands.

A reasonable single-day shipping plan: §§1–6 + §10 morning (model + engine + tests proven in /tmp), §§7–9 + §11 afternoon (UI + smoke test).
