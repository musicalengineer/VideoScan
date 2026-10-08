# Check Media + Catalog row-menu cleanup — shape (2026-10-07)

Rick approved 2026-10-07 ("Make it so"). Branch `feat/check-media-and-menu-cleanup`.

## 1. Shape in five lines

- **One model, two views.** `MediaFacts` (what ffprobe knows, per stream) and
  `MediaReportCard` (one `MediaCheck` row per check) are value types.
  *Get Media Info…* (⌘I) shows the facts and the last card's verdict line;
  *Check Media…* runs the checks and writes the card.
- **Pure engine, thin I/O.** `CheckMediaRules` (pure: parsers + one function per
  check) and `CheckMediaProbe` (I/O: ffprobe / ffmpeg through `ProcessRunner`,
  the one shell-out module). The probe never decides; the rules never touch disk.
- **Two tiers.** Fast = header probe + sampled packet scan + a few short
  `mpdecimate` windows (seconds, any file size). Deep = one full decode with
  `idet,blackdetect,freezedetect` riding along, plus the existing Verify Audio
  levels pass (astats per channel → silent track, clipping, loudness).
- **One MFO job.** `CheckMediaJob` — one row for the whole selection: verb chip,
  "N of M · file · step", fraction/ETA, Pause/Stop, per-file detail on
  double-click, START / OUTCOME to console + catalog.log + videoscan.log through
  the Center's existing `logStart` / terminal-summary sink.
- **Existing verdicts keep their meaning.** Check Media's deep tier produces the
  *same* `AudioVerifyDiagnosis` / `VideoVerifyDiagnosis` the Verify jobs produce
  (same rules, same engines) and writes them to the same fields with the same
  rules. The card is a new, additive field.

## 2. Ownership and where things live

| Piece | Kind | Module | Why |
|---|---|---|---|
| `MediaReportCard`, `MediaCheck`, `MediaCheckVerdict`, `MediaCheckKind`, `MediaEvidence` | value types, `Codable`, `Sendable` | **VideoScanCore** | persisted on `VideoRecord` (which lives in Core) |
| `MediaFacts`, `MediaStreamFacts`, JSON parser | value types | **VideoScanCore** | pure, no app deps |
| `CheckMediaRules` (fast + deep checks, sentences, headline) | caseless enum of pure funcs | app `MediaOps/CheckMedia/` | composes `VerifyVideoRules` / `VerifyAudioRules`, which live in the app target — one source of truth for thresholds, no copy |
| `CheckMediaProbe` | `@concurrent` async funcs | app `MediaOps/CheckMedia/` | needs `VerifyVideoProbe` / `VerifyAudioProbe` |
| `CheckMediaJob` | `@MainActor final class`, `MediaFileOperationJob` | app | owns run Task, progress, per-file results |
| `MediaVolumeGateHold` | `@MainActor final class` | app | the per-volume gate + pause lend-back, extracted once instead of an 8th verbatim copy |
| `MediaInfoSheet`, `CheckMediaSheet`, `CheckMediaDetailView` | SwiftUI views | app | presentation only |

Deviation from "engine in Core where possible": the check *rules* stay in the app
target because the rules they reuse (`VerifyVideoRules`, `VerifyAudioRules`) are
there. Moving those two (≈1,500 lines, all pure) to Core is a clean follow-up —
**quick or right?** for Rick: quick = this branch as is; right = a mechanical
move + `public` sweep (≈1 h, no behaviour change), then `CheckMediaRules` follows.

## 3. Canon

- **Swift API Design Guidelines:** nouns for values (`MediaFacts`,
  `MediaReportCard`), verbs for side effects (`startCheckMedia`), labels read as
  phrases (`facts(fromProbeJSON:)`, `checks(for:)`).
- **TSPL — enums with associated values:** `MediaCheckVerdict` is
  `.ok / .warning / .problem / .notRun(reason:)` — "not run" carries *why*, so
  an unknown can never masquerade as OK (the GH #128 rule). Value semantics for
  every fact and card; the only reference type is the job (it has identity).
- **Swift Concurrency:** I/O funcs are `@concurrent` (Approachable Concurrency
  trap — a plain `nonisolated async` runs on the caller's actor); the job is
  `@MainActor`; results cross actors as `Sendable` values; cancellation is
  cooperative (`Task.checkCancellation` between passes, SIGTERM via
  `ProcessControl`); pause = SIGSTOP + lend the volume slot back.
- **SwiftUI data flow:** sheets via `.sheet(item:)` (never chained
  `isPresented`); the sheet owns its transient `@State` facts; the record stays
  the single source of truth for the persisted card.
- **Exemplars in repo:** `VerifyVideoRules` / `VerifyVideoProbe` /
  `VerifyVideoJob` (pure/I-O/job split), `CatalogInfoCommand` (focused-value
  menu command), NetNewsWire-style small focused types.

## 4. Existing data and callers

**Stored verify results are preserved and keep their meaning.** Fields:
`audioVerifyStatus/Note/Date`, `videoVerifyStatus/Note/Date` on `VideoRecord`.
Check Media writes them only from a *complete* diagnosis by the existing engines,
exactly as `VerifyAudioJob.persistVerdict` / `VerifyVideoJob.persistVerdict`
do (shared via one static writer each — no copy). A quick check that already
proves the picture broken (`VerifyVideoRules.decodeIsPointless`) writes the video
verdict too, because Verify Video would have skipped the decode and written the
same thing. A failed check writes nothing ("couldn't check is not a verdict").

Every reader of those fields (grep 2026-10-07), all unchanged:

- Catalog: `CatalogContent+Table.swift` (row tooltip), `CatalogQueries.swift`
  (`notes:` search), `CatalogRowMenuPlan.swift` (`damagedAudio` → Repair Damaged
  Audio), `CatalogRowContextMenu+Audio.swift` (Link Repaired Copy),
  `ModelsUI/VideoRecord+Presentation.swift` (red rows).
- Archive: `ArchiveReadiness.swift` (audio readiness, `lacksUsableSound`),
  `CopyFamilyAssessor.swift` (`audioVerifyStatus` ok/damaged → cautions and
  `.verifyAudioFirst`).
- Archive Angel: `ArchiveAngelJob.swift` (prepare step: cache hit on
  `center.verifyDiagnosis`), `ArchiveAngel.swift` (Angel Checks verdict),
  `ArchiveAngelRowFacts+Record.swift`, `ArchiveAngelCatalogHint.swift`,
  `ArchiveAngelListRowModel.swift`, `ArchiveAngelReadinessExplanation.swift`,
  `ArchiveAngelCandidate+Record.swift` / `ArchiveAngelScorer*.swift`,
  `ArchiveAngelShowCopies.swift`, `ArchiveAngel+CatalogHints.swift`.
- Core: `VideoRecord` / `+Codable` / `+Clone` / `VideoRecordDTO` (persistence).

**Routing the "Verify Audio" consumers.**
- `CopyFamilyAction.verifyAudioFirst` (raw value "Verify Audio") and its two
  caution sentences now name **Check Media**; case name unchanged (tests pin it).
- `ArchiveAngelDetailView.swift:399` is the Angel's *prepare-step* column
  ("Verify Audio"), not a menu verb: the Angel runs the audio engine itself to get
  the balance analysis it needs. It stays on that engine (an Angel batch must not
  start a full picture decode per file). Check Media stores its audio diagnosis in
  the same session cache (`storeVerifyDiagnosis`), so a file checked from the
  Catalog is a cache hit for the Angel — the routing runs that way round.
- `VerifyAudioJob` / `VerifyVideoJob` stay (Angel Checks, Repair Damaged Audio's
  re-verify, tests). Only the two catalog menu verbs go.
- The Verify Audio results sheet (Balance / Rebuild offers) stays reachable from
  Get Media Info ("Sound Details…") when a session diagnosis exists.

**New, additive:** `VideoRecord.mediaReportCard: MediaReportCard?` — optional,
`decodeIfPresent`, DTO writes the key only when present, cloned with the record.
No other schema change. Family Music marks stay on records, inert.

## 5. ⌘I conflict

⌘I is File ▸ Catalog Info (Rick 2026-10-06), live when the *volumes* table has the
keyboard. Following Finder (⌘I = Get Info on whatever is selected), the one File
menu item becomes context-sensitive: volumes table focused → "Catalog Info";
files table focused with one row → "Get Media Info…". Still one owner, two
focused values, the `catalogOpenSelection` pattern. Flagged for Rick's spot test.

## 6. Memory and cost

Fast tier: ffprobe JSON ≤ 1 MB cap, packet text ≤ 3 × 96 KB, `mpdecimate`
windows counted line-by-line (nothing retained) — ≈ 1.5 MB per file regardless
of size; reads a few MB of the file. Deep tier: the Verify Video decode (bounded
tallies, ≈ 1.2 MB) + Verify Audio astats (KBs). Deep reads the whole file twice
(picture once, sound once) — the price of reusing both engines unchanged; a
single combined pass is possible later if the audio engine grows a filter hook.
