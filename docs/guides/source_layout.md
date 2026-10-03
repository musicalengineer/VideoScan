# App source layout — `VideoScan/VideoScan/`

Adopted 2026-09-29 (Rick: "a one-time logical grouping … for the sake of my
mere human mind", and so a reviewer can be told "review folder X"). The move
was pure renames; no code changed. The Xcode target uses a
file-system-synchronized group, so a new file dropped into any folder is
compiled with no `project.pbxproj` edit. Put a new file beside its closest
neighbours. File names stay unique across the whole tree — source sensors look
files up by NAME (`SourceTree.appSource(named:)` in `VideoScanTests`), so a
later move cannot break or blind them.

`VideoScan-Bridging-Header.h` and `ObjCExceptionCatcher.h/.m` stay at the top
level: build settings name the bridging header by path.

## Folders

**App/** — the shell: `main.swift`, `VideoScanApp`, `ContentView` (the tab
window), Settings, console and dashboard windows, dependency checks, remote
viewer mode, and bundle/workspace export and import.

**Model/** — the core model: `VideoScanModel.swift` (the class itself),
`Models.swift` (records, enums, dispositions) and the provenance types. The
many `VideoScanModel+Feature.swift` extensions live with their feature.

**Catalog/** — the catalog store, sync, lock, snapshot and search index; the
Catalog tab (table, toolbar, inspector panes, sheets); audit and repair; date
inference and validation; rename, notes, workflow tags, ignored content,
Triage and the natural-language query.

**Volumes/** — scanning (walker, scan engine, checkpoints, scan jobs), scan
targets, volume reachability, status caches, keep-alive, drive health, volume
roles, renames and migrations, the Volumes window, compare, and retiring or
deleting a volume's catalog.

**Media/** — reading media without changing it: ffprobe/ffmpeg probing, MXF
and Avid bin parsers, thumbnails, filmstrips and the preview sweep, frame
ripping, captions and transcription, perceptual hashing and fingerprints,
media signatures, audio balance analysis, embedded-date and content-hash
backfills.

**MediaOps/** — Media File Operations: every job that writes, moves or
removes media, and the MFO window. Combine and correlate, transcode, trim,
reformat, cleanup, rebuild and balance audio, verify audio/video, rescue
copy, partial-file naming and derivative publishing; and the destructive
lanes: Delete Duplicates, junk delete and trash selection, soft delete,
prune apply, the purges (non-video, cover-art music, unrelated audio),
repair lifecycle, and relocate.

**Archive/** — the Master Archive (FamilyArchive): promote (engine, job,
sheets, date choice), the `00_Index` manifest and its lock, index text and
index rename, archive update (refile), file locking, fixity and fixity
rebind, verify copies, the media ledger, backup attestations, archive
volume protection, and the Archive tab.

**People/** — Person Finder and face engines (Vision, ArcFace, AdaFace),
POI profiles and storage, confirm/review sheets and holdouts, validation
labels, recipes, dossiers, Find and Tag, Identify Family, and the People tab.

**FamilyTree/** — the Family Tree tab and walk, GEDCOM loading, FamilySearch
pull and person refresh, kinship inference and overlays, tree identities,
family assets and documents, research people and sources, CyberBrain
notes, and the family-facing extras (Person of the Day, the Roll Call
credits over the family map). Their pure logic lives in VideoScanCore
(`PersonOfTheDay*.swift`, `RollCall.swift`).

**Hallie/** — Hallie the archivist: the chat window, question parsers,
planners, executors, lineage answers, composition, conversation memory and
offers. Sub-folders: **Hallie/Voice/** (speech, pronunciation, lexicon and
drills), **Hallie/Web/** (the local web server, proxy, remote client),
**Hallie/Shell/** (the `hallie` terminal CLI), **Hallie/LLM/** (Ollama
endpoints, translators, the grounded composer, general-knowledge lane).

**Shared/** — small cross-cutting utilities: logging sinks, process runner
and subprocess environment, file hashing, path scope, RAM disk, memory and
stall monitors, test-host detection, notification observer bag, and generic
SwiftUI pieces.

**Steward/** — the content steward's trial pane at the top of the Triage tab
(2026-10-03; design §5.6 of
`docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md`): the Events
lane (`StewardEvents.swift` — occasions grouped from the Angel's event labels
and trusted day; nothing stored), the case builder over knowledge already on
the records (duplicate sets, footage groups, junk scores), the skip memory,
the focused-card proof (the Delete planner's own functions) and the pane and card views. It
deletes nothing itself — its only way to deletion is the shared Delete
duplicates front door (`VideoScan/VideoScan/MediaOps/DeleteDuplicatesFlow.swift`);
a source sensor pins that.

Folders that pre-date this layout are unchanged: **ArchiveAngel/** (the
Archive Angel, by stage), **FootageGroups/**, **FamilyMusic/**, **ModelsUI/**.

## Data-risk code (for the codex review policy)

A miss in these folders can lose or corrupt family media, the archive, or
the family record. They are the paths the codex spend policy reserves
adversarial passes for:

- **Archive/** — all of it: promote, the `00_Index` writers and lock,
  archive update (refile), file locking, fixity, the media ledger, and
  `ArchiveVolumeProtection`.
- **MediaOps/** — the delete / prune / relocate parts: `DeleteDuplicates*`,
  `SignatureVerification`, `VideoScanModel+JunkDelete`, `+TrashSelection`,
  `+SoftDelete`, `+PruneApply`, `+PruneVerification`, `PruneApplyJob`, the
  `*Purge` files, `Relocate*` and `VideoScanModel+Relocate*`,
  `VideoScanModel+RepairLifecycle`, `RescueFileCopier`, `PartialFileNaming`
  and the output publishers (`DerivativeOutputPublish`,
  `CombineOutputPublish`) that must never clobber.
- **FamilyTree/** — CyberBrain writes (`FamilyTreeNotes`,
  `FamilyTreeLiveModel`, `ResearchAttestation`, `ResearchPersonSheet`) and
  FamilySearch pull/refresh, which replace the tree on disk. Hallie's telling
  and pronunciation modes also write CyberBrain through `CyberBrainWriter`.
- **ArchiveAngel/Promote/** — the Angel's hand-off into promote.
- **Volumes/** — `VideoScanModel+RetireVolume` and `+DeleteScanTarget`
  (remove catalog records for a whole volume).

Everything else (UI, Hallie answers, analysis, search) is covered by the
in-house `qa` agent and Rick's spot test.
