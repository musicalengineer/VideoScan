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

## 7. Follow-up (same day): Layout, Sound continuity, honest quick verdict

**Why.** A quick check called a file "Looks healthy" whose sound stutters badly
(a 41.5 GB DNxHD 220 + pcm_s24be mov from an FCP library). The Manager's hand
diagnosis: the sound is perfect (70,038 packets, no PTS gaps, no dropouts, no
replays, no clicks) but every picture packet is stored at the front of the file
and every sound packet at the end, 41 GB apart. A player on a spinning RAID
seeks between the two ends for every refill and the sound starves.

**Shape.**
- *Layout* (quick tier, `CheckMediaLayout.swift`: `MediaLayoutMeasure` /
  `MediaLayoutSample` value types + `CheckMediaRules.checkLayout`; I/O in
  `CheckMediaProbe.layoutSample`). Three windows (start, middle, end). Per
  window: ≤ 300 picture packets (≈ 5 s, by count so a 60,000 fps file can't
  read gigabytes), then the sound packets for the same time span, both with
  `pos`, fields named in `-show_entries` (never csv column order). Measured
  only over the time BOTH windows cover (otherwise a shorter sound window
  reads as a long picture run; seen on a healthy ffmpeg mp4).
  Separation = median (sound byte − byte of the picture packet nearest in
  time); longest run = longest file-order stretch of one stream, in seconds.
  Brockton: 0.2 s per window, whole quick tier 2.7 s.
- *Sound continuity* (full tier, `SoundContinuity.swift`: four single-job
  detectors — `SilenceRunTracker`, `BlockRepeatTracker`, `ClickTracker`,
  `SoundTimeline` — composed by `SoundContinuityAnalyzer`, a value type wrapped
  in a locked `SoundContinuityTally`; I/O in `CheckMediaProbe+SoundContinuity`).
  One ffmpeg pass: `-map 0:a:0 -af asettb=1/sr,ashowinfo -c:a pcm_s32le -f
  s32le pipe:1`. PCM streams through a new additive `stdoutData:` callback on
  `ProcessRunner.runProcess` (raw chunks, nothing collected, pipe
  back-pressure); `ashowinfo` lines (pts in samples after `asettb`; pts_time
  is only 6 significant digits) feed the timing check and the progress bar.
  Runs inside the existing full-tier MFO job as phase "listening to every
  sample" (`CheckMediaProbe.FullPhase`). Memory ≈ 0.4 MB worst case,
  independent of length. Brockton: 25 min of sound in 23 s (mov: the demuxer
  reads only the sound by index).
- *PTS gaps/overlaps stay in the full tier.* An audio-only packet scan reads
  only the sound for mov/mp4, but the whole file for mxf/mkv/avi, so it can't
  be "quick" in general; the decode pass gets it for free.
- *Honest quick verdict.* `MediaReportCard.isQuickPassOnly`, `verdictWord`,
  `displayHeadline` (Core). A quick pass reads "No problems found in the quick
  check — run the full check to listen to every sample and decode every
  frame.", an outlined grey tick (never the solid green one), and "N with no
  problems in the quick check" in the MFO summary. `displayHeadline` also
  fixes cards persisted before today with the old "Looks healthy (quick
  check …)" headline. Only a full pass may say "Looks healthy".

**Layout thresholds (pinned by tests).**
- **Problem:** the sound sits > **64 MB** from its picture AND one stream runs
  ≥ **2 s** before the other appears. 64 MB is far past any player's read-ahead
  (a few MB to tens of MB), ≈ 2.3 s of DNxHD 220, ≈ 20 s of 25 Mbit/s HDV; a
  sane 0.5–1 s interleave of even 4K ProRes stays under it. 2 s is longer
  than a player's default sound buffer (≈ 1 s), so the sound runs dry while the
  picture is read. Bytes are the physical cause (a seek per refill on a
  spinning disk); seconds guard against huge-bitrate files with fine
  interleave.
- **Warning:** > 64 MB apart with short runs (very high bitrate, big pieces), or
  runs ≥ **4 s** at a low bitrate (close in bytes, long in time).
- **OK:** everything else, e.g. 1 s chunks of DNxHD 220 (≤ 27 MB apart).
- A window where the two streams share < 0.2 s is not measured; no window →
  "not run" (CapeCod: 300 packets at 60,000 fps span 5 ms). A file whose
  streams are stored wholly apart in a *file-order* container (mkv/avi/mxf)
  is found the same way: ffprobe's `-select_streams` keeps reading until the
  selected stream's interval appears.

**Sound continuity rules.** Dropout = exact digital zero on every channel for
5 ms – 2 s, not within the first/last 100 ms (≥ 2 s = "silent passage",
counted only: often a deliberate gap in an edit). Replay = 1024 sounding
frames (peak-to-peak ≥ −60 dBFS) identical to the 1024 before them, any
alignment. Timing jump = decoded frame pts off the expected by > 2 ms (mkv
stores ms). Click = second difference > 0.5 FS AND > 25× its own 10 ms level
AND > 4× the 10 ms signal envelope — calibrated on Brockton, where the first
two tests alone flagged 43 loud real transients. Verdict: ≥ 3 stutter events
(dropouts + replays + timing jumps) = Problem, 1–2 = Warning; clicks alone =
Warning.

**Compatibility.** `layout` and `soundContinuity` are new `MediaCheckKind` raw
values (additive). An older build reading a newer card drops the card (the
record decodes it with `try?`), never the record.

**Follow-ups (not built).** A "Remux side by side" button on the Layout row
(lossless `-c copy` into a new file next to the original; needs Rick's UI
approval and the delete-safety rules); replay detection for buffer lengths
other than 1024; one combined sound pass (Verify Audio astats + continuity).

## 8. Broadened full tier (same day: "do as much as possible; OK to wait")

**Passes — two reads of the picture, one of the sound (chosen over a
single pass).** One combined pass would mean reworking the shared Verify
Video / Verify Audio engines that other jobs use; two passes were allowed.
1. *Picture decode* (Verify Video's, unchanged for Verify Video): the signal
   chain gains `signalstats` + two `metadata=print` filters → each frame's
   YMIN/YMAX and pts_time; decoder error lines are now also handed to the
   signal hook, so each complaint is stamped with the last frame's time
   (`DecodeErrorClock`, ± a few frames).
2. *Packet census* (new, `PacketCensus.swift` + `CheckMediaProbe+Census`):
   `ffprobe -select_streams v:0` then `a:0`, `packet=pts_time,dts_time,
   duration_time,size,pos,flags`, streamed line by line, nothing collected.
   One stream per run so ffprobe discards the other and a non-interleaved
   mov is read straight through. Feeds packet timing (dts backwards, gaps),
   keyframes, picture bytes per second, A/V first/last times, and a ¼-second
   picture index against which EVERY sound packet's distance is measured
   (the whole-file Layout row, which replaces the quick sample on the card:
   `CheckMediaRules.merging`).
3. *Sound pass* (part 1's) gains `ebur128=peak=true:framelog=quiet` in its
   chain and three sample trackers (`SoundLevels.swift`): DC offset, clip
   runs (≥ 3 samples pinned at full scale), channel relation (identical /
   inverted / independent + correlation).
Header facts gain colour labels (`MediaColourLabels`, Core) and timecode tags
(additive probe entries).

**Memory (worst case):** census ≤ 8 MB (¼-s picture index capped at 55 h,
bytes-per-second capped at 200,000 s; a 2 h tape ≈ 0.3 MB); sound pass
≈ 0.4 MB; decode tallies O(1). No whole-file buffers; pipe back-pressure.
No read-ahead buffer was added: on the M4's internal SSD the full tier ran
at 168 MB/s on a 1 GB ProRes 422 HQ file (decode + census + sound, Debug
app build), so ffmpeg's own decode, not I/O, is the limit there.

**New rows (all full tier; raw values additive):**
| Row | Problem | Warning | Notes |
|---|---|---|---|
| Timing, every packet | dts goes back | gap > max(0.5 s, 3 packets) | dts only (B-frame pts reorder is normal) |
| Keyframes | — | only one keyframe (> 300 frames); gap > 10 s | all-intra = OK |
| Data rate over time | — | an interior second with no picture bytes (≥ 2 fps) | evidence: low/median/high |
| Sound and picture start together | ≥ 5 s | ≥ 0.5 s | end difference as evidence |
| Timecode track | — | invalid HH:MM:SS:FF; tags disagree; track ≠ picture length by > 1 s | not run when no timecode |
| Colour labels | — | HD with SD matrix (or reverse); YUV labelled full range whose luma stays 8–246 | the opposite direction is NOT judged: compression ringing puts single pixels at 0/255 (mpeg2 fixture) |
| Loudness (EBU R128) | — | true peak > 0 dBTP; integrated < −36 LUFS | |
| Sound centred on zero | — | \|DC\| > 1 % FS | |
| Left and right | — | inverted (≥ 99.9 % of frames L = −R, or r < −0.9) | identical = "mono stored as stereo", OK |
| Clipped stretches | — | any run of ≥ 3 pinned samples | |
The Layout threshold is now a decimal 64 MB (64,000,000 B) so the card's
"64 MB" and the rule agree.

## 9. Get Info → Verify → Repair (Rick 2026-10-08, "EXACTLY!")

Branch `feat/info-verify-repair-menu`. Demo week: stability first.

**The funnel.** Three verbs, one model (the `MediaReportCard` on the record),
each handing on to the next:

| Verb | What it does | Writes | Owner |
|---|---|---|---|
| **Get Info… ⌘I** (was Get Media Info…) | facts + last verdict | nothing | `MediaInfoSheet` (unchanged but for words) |
| **Verify…** (was Check Media…) | runs the quick / full checks | the card (+ the verify fields, as before) | `CheckMediaSheet` → `CheckMediaJob` (unchanged but for words) |
| **Repair…** (new) | offers the fixes the latest card earns | a NEW file + a NEW record; never the original | `RepairSheet` → `MediaRepairJob`, or the existing Balance / Rebuild jobs |

Renames are user-visible strings only. Enum cases, accessibility ids,
`MediaFileOperationKind.checkMedia` and persisted raw values stay. The MFO
chip reads "Verify Media" (badge) / "verify media" (log verb) — the old
"check media" log lines stay greppable through the job's own Logger
category, which keeps the name `checkMedia`.

**Which fix answers which check** (pure, `MediaRepairPlan`):

| Fix | Offered for | How | Output |
|---|---|---|---|
| Lossless remux | `layout` Problem / Warning; also listed under "Always available" | `ffmpeg -i src -map 0 -c copy` (muxer interleaves); then a packet census of both files must match per stream (codec, packets, bytes, duration ticks) | `<stem>_remuxed.<same ext>` |
| Remove repeated frames | `distinctFrames` Problem (the CapeCod class) | measure the real rate first (kept-frame spacing after `mpdecimate`, two short windows, snapped to a camera rate), then `mpdecimate,fps=<rate>` + libx264 CRF 16 / slow, sound copied; re-encode stated in the confirmation | `<stem>_repaired.<ext or mov/mkv>` |
| Balance Audio | `sound` Warning with a session channel-imbalance diagnosis | the existing `startBalanceAudio(fromDiagnosis:)` — unchanged | unchanged (`_balanced`) |
| Rebuild Audio Track | `sound` Problem (damaged) | the existing `startRebuildAudio` with a session diagnosis, else the existing "Repair Damaged Audio" path (`startVerifyAudio(autoRepair:)`) — unchanged | unchanged (`_RepairedAudio.mov`) |

Repair… menu state: no card (or a stale card) → enabled, runs the quick Verify
first; a card with an offered fix → enabled; a card with none → disabled with
the reason. One file at a time; offline → disabled.

**Safety (non-negotiable).** The original is only ever read. Output goes beside
the original UNLESS the original's volume is protected (the delete-protection
predicate `bulkDeleteRefusal(forPath:)`: archive tree/volume, unprovable, Read
only marks) — then a save panel defaulting to ~/Movies, and a chosen folder that
is itself protected is refused. ffmpeg writes a reserved partial; the publish is
`DerivativeOutputPublish.publish(…, policy: .keep)` (ExclusivePublish:
RENAME_EXCL / link(2) / refuse — never a rename over anything, never
`replaceItemAt`; no new `rename(` call site). Balance / Rebuild keep their own
(unchanged) beside-the-original output, so on a protected original they are
shown disabled with the reason instead of being re-plumbed this week.

**After a fix.** The output is probed and catalogued as a NEW record
(`derivedFrom` = original, `derivationKind` "remux" / "removeRepeatedFrames",
NOT a repair-lifecycle kind, so nothing is superseded or hidden), then the
quick Verify runs on it and its card goes on the new record, the job's detail
and the open Repair sheet.

**One MFO job.** `MediaRepairJob` (kind `.repair`, badge "Repair"): chip, step,
"N of M" = phase, fraction from ffmpeg `-progress`, ETA, Pause (SIGSTOP) /
Stop (SIGTERM), StallMonitor, START / OUTCOME through the Center's `logStart` /
terminal sink.

**Memory.** Packet census streams lines (O(streams) counters); the rate sample
keeps ≤ 2 × 4 s of kept-frame timestamps (a few thousand doubles); ffmpeg
does all media I/O. No in-process media buffers.

**Canon.** Pure / I-O / job split (the `VerifyVideoRules` / `Probe` / `Job`
exemplar); fixes as an enum, offers as value types; `@concurrent` I/O, a
`@MainActor` job, `Sendable` results; `.sheet(item:)`; the record stays the
single source of truth for the card.

**Menu (target).** 1 Reveal · Open With ▸ | 2 Get Info… · Verify… · Repair…
(+ the existing repair-lifecycle items: Repair Damaged Audio, Link Repaired
Copy…, Sounds Good — Confirm) | 3 the pair verbs (Combine This Pair…, Compare
These Two Files…) · Analyze ▸ · Transcode ▸ · Clean Up Video ▸ | 4 Promote ·
Archive Angel ▸ | 5 Rename… · Tags ▸ · People ▸ · Notes… | 6 Find Matching
Audio/Video, Find Missing Audio, Find A/V Pair, Find Online Version / Copy,
All Matches ▸, Find ▸ · Copy Path | 7 Remove from Catalog · Remove from Catalog
(keep files) · Delete File ▸ (disabled with the reason when nothing selected may
be deleted). Clean Up Video ▸ holds only VHS Quick Clean (an enhancement), so
nothing moves out of it; Balance / Rebuild were never in it (they lived behind
Get Info ▸ Sound Details…) and now also appear under Repair.
