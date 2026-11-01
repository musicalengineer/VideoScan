# Developer guide — source layout, bring-up, tools

*Rewritten in place. Consolidated 2026-11-01 from `guides/source_layout.md` (this file, renamed), three machine notes from `guides/ops/` and the Swift 6 migration plan; originals under `docs/archive/`. Rules: `CLAUDE.md`; architecture: `docs/ARCHITECTURE.md`; patterns: `docs/practices/swift_playbook.md`; tests: `docs/guides/testing.md`.*

Bring-up on a clean Mac: `scripts/install_dev_tools.sh` (Homebrew `Brewfile`: ffmpeg/ffprobe and friends), then the two Python environments (`venv/` 3.14 for tools and tests, `venv-mlx/` for the model lab). Build: `VideoScan/VideoScan.xcodeproj`, scheme `VideoScan` (Debug) or `VideoScan-Release`; Core: `swift test --package-path VideoScan/VideoScanCore`. Agents work in a `git worktree` with their own `-derivedDataPath` (CLAUDE.md rule 11). The rest of this guide is where the code is and the few tools that are not obvious.

## Contents
1. App source layout · 2. Swift 6 language mode (done 2026-10-25) · 3. Python paths · 4. lldb through a fifo · 5. The complexity counter

## 1. App source layout — `VideoScan/VideoScan/`

*From `guides/source_layout.md` (adopted 2026-09-29), whole.*

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

### Folders

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
`docs/design/catalog.md`): the Events
lane (`StewardEvents.swift` — occasions grouped from the Angel's event labels
and trusted day, asked only through the Angel's front door
`archiveAngel.occasionReader` in `ArchiveAngel/Facade/ArchiveAngel+Occasions.swift`;
nothing stored), the case builder over knowledge already on
the records (duplicate sets, footage groups, junk scores), the skip memory,
the focused-card proof (the Delete planner's own functions) and the pane and card views. It
deletes nothing itself — its only way to deletion is the shared Delete
duplicates front door (`VideoScan/VideoScan/MediaOps/DeleteDuplicatesFlow.swift`);
a source sensor pins that.

Folders that pre-date this layout are unchanged: **ArchiveAngel/** (the
Archive Angel, by stage), **FootageGroups/**, **ModelsUI/**.

### Data-risk code (for the codex review policy)

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
- **Catalog/** — `ShowAgain*` (clears the false "deleted" label; label only,
  but it puts rows back in the Delete Duplicates / Excess / Prune pools).

Everything else (UI, Hallie answers, analysis, search) is covered by the
in-house `qa` agent and Rick's spot test.

## 2. Swift 6 language mode (done 2026-10-25)

*Summary of `design/swift6_migration_2026_10_25.md` (archived at `docs/archive/design/`; scripts cite its §5 and §7 there).* Rick ruled on 2026-10-25 that the app and Core use Swift 6 language mode with no older-compatibility allowance. All eight stages were done on 2026-10-25: Core in Swift 6 mode (stage 1), the nightly analysis lane (`scripts/nightly_analysis_lane.sh`, stage 2; the "Coverity analogue"), the non-concurrency, global-state, main-actor, capture/`sending` and `Sendable` warning categories driven to zero (stages 3–7, with a Codex pass per slice that touched data-risk code), and the app target flipped to `SWIFT_VERSION = 6` with the ratchet floor at "any warning is red" (stage 8; Codex merge, `docs/reviews/codex.md`). What still holds from it: `scripts/warning_ratchet.py` runs in the sensor lane; every concurrency escape hatch (`@unchecked Sendable`, `nonisolated(unsafe)`, `Task.detached`) carries a comment saying why, counted nightly by `scripts/escape_hatch_census.py` (plan §5); the nightly analysis lane calls the same runner as the weekly sanitizer jobs (`scripts/weekly_sanitizer.py`: Address + Undefined Behavior Sanitizer on Saturdays, Thread Sanitizer on Sundays). STATUS (2026-11-01) tracks closing #376 once #381/#385 are called.

## 3. Python paths

*From `guides/ops/python_paths.md` (moved out of Claude memory 2026-10-23), whole. CLAUDE.md names the two venvs.*

<!-- moved from Claude memory (reference_python_paths) on 2026-10-23; operational reference, rewrite in place -->

#### Person Finder (dlib engine)

- **Python path:** `/Users/rickb/dev/VideoScan/venv/bin/python3`
- **Script path:** `/Users/rickb/dev/VideoScan/scripts/face_recognize.py`
- **Venv:** `~/dev/VideoScan/venv` (Python 3.14, has dlib/face_recognition, openpyxl)

Auto-detected as defaults and persisted in UserDefaults (pf_ prefix).

#### Dossier worker (Qwen + Whisper + OCR)

- **Python path:** `/Users/rickb/dev/VideoScan/venv-mlx/bin/python3` — **NOT the same venv as PersonFinder**
- **Script path:** `/Users/rickb/dev/VideoScan/scripts/dossier_batch.py`
- **Venv:** `~/dev/VideoScan/venv-mlx` (Python 3.12, has `mlx_vlm`, `mlx-whisper`)
- **Same venv layout on all three fleet nodes:** ricksm4.local, ricksm5.local, ricksm1.local
- The script's shebang picks system Python which does NOT have `mlx_vlm` — **always invoke explicitly:** `~/dev/VideoScan/venv-mlx/bin/python3 dossier_batch.py …`

Trip wire fixed 2026-06-07: launching workers without the venv path produces `ModuleNotFoundError: No module named 'mlx_vlm'` and silent failure (the worker exits, no JSONL output, fleet looks stuck). Always include the venv-mlx prefix.

Related: [[project_metadata_dossier_vision]], [[reference_host_fleet_ssh]]

## 4. lldb through a fifo

*From `guides/ops/lldb_fifo_control.md` (moved out of Claude memory 2026-10-23), whole. Never `kill` a process on Rick's machines without asking (CLAUDE.md).*

<!-- moved from Claude memory (reference_lldb_fifo_control) on 2026-10-23; operational reference, rewrite in place -->

When a hung macOS app needs deeper inspection than `sample` provides — specifically per-thread stacks, register state, or specific frame inspection — drive `lldb` from bash via a fifo. The pattern is non-interactive but flexible: write commands to the fifo as needed, read output from a log file.

#### Setup

```bash
BIN="/path/to/AppName.app/Contents/MacOS/AppName"
LLDB_IN=/tmp/lldb.in
LLDB_OUT=/tmp/lldb.out
rm -f "$LLDB_IN" "$LLDB_OUT"
mkfifo "$LLDB_IN"

# Launch lldb reading commands from fifo, all output to log file
( lldb -X < "$LLDB_IN" > "$LLDB_OUT" 2>&1 ) &
LLDB_PID=$!

# Hold the fifo open from a sleeping background process so writes
# don't EOF after lldb consumes them
( sleep 99999 > "$LLDB_IN" ) &
HOLDER_PID=$!

sleep 2
{
  echo 'target create "'"$BIN"'"'
  echo 'process launch --working-dir /Users/rickb'
} > "$LLDB_IN"
```

Or attach to an already-running PID:
```bash
echo "process attach --pid $TARGET_PID" > "$LLDB_IN"
```

#### When the user reports "hung", interrupt and dump

```bash
kill -SIGINT $LLDB_PID    # interrupts the inferior, returns lldb prompt
sleep 2
{
  echo 'thread list'
  echo 'thread backtrace all'
  echo 'process status'
} > "$LLDB_IN"
sleep 8                    # let output flush
```

Then parse `/tmp/lldb.out` for the dump. Useful greps:
- `awk '/^\* thread #1/,/^[* ]\s*thread #/'` — Main Thread stack
- `awk '...VideoScan|libswift_Concurrency...'` — only frames in your code or Swift Concurrency runtime
- `grep -E 'mach_msg2_trap|__psynch_cvwait|semaphore_wait_trap'` — what threads are parked on

#### Detach cleanly

```bash
echo 'detach' > "$LLDB_IN"; sleep 2
echo 'quit'   > "$LLDB_IN"; sleep 2
kill $HOLDER_PID 2>/dev/null
rm -f "$LLDB_IN" "$LLDB_OUT"
```

#### Gotchas

- `lldb -X` disables the curses UI so all output stays line-based and greppable.
- The `sleep 99999 > fifo` holder is essential — without it, the fifo writer side closes after each write batch and lldb sees EOF mid-session.
- `SIGINT` to lldb's PID interrupts the *inferior*, not lldb itself. lldb then awaits the next command from its stdin (your fifo).
- If the inferior is a SwiftUI app and main thread shows `mach_msg2_trap` only, that's the normal CFRunLoop park — NOT a blocking wait. Look elsewhere (per [[feedback_diagnostic_methodology]]).

Related: [[feedback_diagnostic_methodology]] for what to do with the dump once you have it.

## 5. The complexity counter

*From `guides/ops/complexity_counter_source_of_truth.md` (2026-10-20, moved out of Claude memory 2026-10-23), whole.*

<!-- moved from Claude memory (reference_complexity_counter_source_of_truth) on 2026-10-23; operational reference, rewrite in place -->

Dashboard (metrics/complexity.jsonl via nightly-analysis.yml), the pre-commit/CI gate (scripts/complexity_gate.py vs ci/baselines/complexity_debt.json) and the nightly baseline (scripts/complexity_baseline_nightly.py; "401→398" = entries over CCN 15 OR NLOC 80) all use `measure` in scripts/complexity_metrics.py.

Stock `python -m lizard` is WRONG on this repo: Swift `/…/` regex `|` counted as branches; `get` inside a regex makes a fake getter swallowing the file (HallieLineageQuestion "get" 93, detectShape 88 vs real 42); misses PrunePlan.plan (52). I quoted stock-lizard numbers to Rick on 10/20 and had to retract — don't repeat.

10/20 list: 28 production functions over CCN 30 (all baselined); top = PrunePlan.plan 52 (Core → D). Goal 0 over 30 before the Ultra ([[project_nightly_refactor_and_swift_expert_review]]).
