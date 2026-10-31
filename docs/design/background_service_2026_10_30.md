# VideoScan Background — the analyzer service (design, 2026-10-30)

*Rick said "design it" on 2026-10-30: "The app is essentially the UI/UX… peel off services into a BG process that
can keep running, persist after we quit the app… We need a persistent service or process that survives app reboots.
I don't like the idea of having an option to launch the app in the BG but I am open to these trade-offs… we can't
lose the app for 2 weeks while we completely refactor it into a front-end backend." This is the VideoScan answer.
It builds on `docs/design/video_llm_lab_2026_10_30.md` (the first job the service hosts) and ARCHITECTURE §4 (MFO,
Analyze cyclers, the one commit door). Not yet built.*

## 0. In one page

## Responsibilities of the Background Service (Rick, 2026-10-30)
The VS BG Service is responsible for continuous Content Analysis of the media. The service is constantly analyzing the media, 
metadata, dates, times, and gleaning as much as it can from the media, the metadata, and the catalog so it can
populate "observations" or "derived machine-generated" information into the app to help the user so when the user searches for
something, the app has this information. It is like a family archivist working 24x7 to understand patterns, connections, and what is where.

INPUTS: all media files + catalog database + all metadata + any new machine generated observations (provisionally within reason)
OUTPUTS: machine generated intelligence all about the media
GOAL: Anything in the content analysis window, audio transcripts, Sound fingerprints, Date Inference, Provenance Estimation, Scene Captions, etc.

Question for Claude: clarify where the observations and machine generated intelligence is stored, since you said the catalog is open read-only, 
how does machine generated intelligence get into the app and persist and be searchable?

**Claude's answer (2026-10-30).** Two stores, one road into the catalog:
- **Bulk observations** — sound prints, picture prints, every raw model output, embeddings, timed transcript segments — live in
  **sidecar SQLite files the service owns** (`model-lab.sqlite`, `audio-fingerprints.sqlite`, `picture-prints.sqlite`), exactly as
  the audio fingerprints do today. The app reads them directly (Find Master, Related, the model lab); they never pass through the catalog.
- **Catalog-bound facts** — a scene caption, a transcript, an inferred date, an era claim, a provenance assertion — are written by the
  service to an **append-only journal** (`background/journal/*.jsonl`, one line per fact, keyed by content digest). The app's one
  committer **applies** the journal into the real catalog tables (`captions`, `transcripts`, `inferred_dates`, `provenance_assertions`)
  at launch and every few minutes while open, through the same commit door as every other write. From then on they are ordinary rows:
  search, Hallie, Catalog Status and the Provenance sheet all see them, with `by = background:<job>@<version>` and their evidence.
- **Lag and visibility.** A fact the service produced while the app was closed is searchable the next time the app opens; Catalog
  Status shows "N journal lines waiting / M refused" so nothing is invisible. Refused lines (an archived row's name or date — rule 3;
  a value Rick already rejected — the veto trigger) are kept with the reason, never dropped. Rejected: the service writing the catalog
  itself when the app is closed — two writers on one catalog is the bug class that cost us twice (`fix/committer-lost-writes`); the
  journal keeps one committer. Revisit only if the lag is felt.
- **Observations as inputs.** Yes: once applied, an era claim feeds `DateTriangulator`, a confirmed event feeds example memory, a
  place signature feeds retrieval — with one standing rule: **no circular corroboration** — a derived fact never supports the inference
  that produced it (`events_design.md` §1 rule 6), and a machine fact never outranks a human one.
- **"Constantly analyzing."** The Analyze cyclers — the staleness rule that decides which file needs captions, transcript, prints or a
  date pass next — move into the service (§4 step 4) and run continuously under backoff; the service keeps itself busy without being
  told, and the app or the nightly may still enqueue specific jobs. §0.5 below is amended to say so.

1. **One helper app inside the app bundle, registered as a launchd agent** through Apple's `SMAppService`:
   `VideoScan.app/Contents/Library/LoginItems/VideoScan Background.app`. Its own name and badged icon in Activity
   Monitor and in System Settings ▸ Login Items; launchd starts it, restarts it if it dies, keeps it alive after the
   app quits and across reboots. This is the macOS best practice for "work that outlives the window" (Apple's
   "Updating helper executables from earlier versions of macOS", `SMAppService.agent(plistName:)`). It is **not** a
   copy of VideoScan launched in the background; Rick ruled that out.
2. **The service never writes the catalog.** It reads it read-only (the schema-13 read-only door), writes its
   results to **sidecar SQLite files and an append-only journal**, and the app's one committer applies the journal
   when the app is next open. The one-committer rule (hard rule 6) is untouched; there is still exactly one process
   that can write `catalog.sqlite`.
3. **One engine per action is kept by moving engines, not copying them.** An engine lives in the app *or* in the
   service, never both. The order of the move is the order of value: the model lab (new, so it is born in the
   service) → Scene Captions → sound and picture fingerprints → the rest of Content Analysis → Event Analysis.
   The app keeps working at every step; a job that has not moved yet still runs in-app as today.
4. **The app is the window onto the service.** Jobs in the service appear in the same MFO list as in-app jobs, with
   the same row (verb, N of M, current file, Pause/Stop). Control and progress go over **XPC**; durable state (queue,
   checkpoints, journal) is on disk so a crash of either side loses nothing. With the app closed, Activity Monitor
   and a one-line CLI (`videoscan-bg status|pause|stop`) are the window.
5. **It backs off while Rick works.** Idle detection (no keyboard or mouse for N minutes, or the app in the
   foreground on a Rick-attended job) drops the service to a trickle; it runs full-out on the night shift and on the
   M4. Every job declares its RAM and whether it needs the one resident model; the service refuses to start a job
   the Mac cannot hold.
6. **Cost Rick pays once:** the helper is its own bundle, so macOS asks for Full Disk Access (and removable-volume
   access) for it once; signed with "VideoScan Local" (DECISIONS 2026-10-28) so the grant survives rebuilds. One
   grant, one time, is the price of its own name and lifecycle; the single-binary alternative (§2 option B) shares
   grants but is the design Rick does not want.

## 0.5 Statement of responsibility (Rick, 2026-10-30: "good SW design requires clear responsibilities")

**`VideoScan Background` is a persistent container.** It keeps analysis engines running when the VideoScan window is
not open. It owns no analysis logic of its own.

| It is responsible for | It is not responsible for |
|---|---|
| Staying alive across app quit and reboot (launchd), and exiting when idle | Any user interface; it has no windows and draws nothing |
| Running jobs from the queue, one per lane, in order, with checkpoints; and, once the Analyze cyclers have moved (§4 step 4), running them continuously so the media is always being analyzed (Rick's statement above) | Owning the *rule* that decides what is stale (that is the cyclers' policy, in the engine library); the app and the nightly may enqueue specific jobs at any time |
| Hosting engines from the libraries (`VideoScanCore`, `VideoScanEngine`) and loading at most one resident model | Containing an engine's logic; an engine that needs the service must first live in a library with its own tests |
| Backing off while Rick works; thermal and memory pressure | Scheduling policy beyond backoff (the nightly rota and the app decide when) |
| Writing results to sidecar stores and the append-only journal, with START/OUTCOME in `background.log` | **Writing the catalog**, ever; the app's one committer applies the journal |
| Reading media and the catalog read-only | Moving, renaming, deleting, trashing, re-encoding or promoting media (data-risk verbs stay in the app, with Rick present) |
| Answering XPC `status/enqueue/pause/resume/stop` from a signed VideoScan client | Trusting any other client; and it never initiates contact with the app |
| Refusing in words what it cannot do (RAM, missing weights, newer sidecar schema, unsigned caller) | Guessing, repairing, or coercing |

C++ reading: a daemon that owns a thread pool and a work queue and dynamically hosts plug-in libraries behind one
interface; the plug-ins carry the knowledge, the daemon carries the lifetime.

### The direction this sets: libraries, not folders

Today VideoScan is one app target (~700K lines organised by folder) plus one library (`VideoScanCore`). Folders are
not modules: the compiler sees one module and anything may call anything; `VideoScanModel` (one object, ~90
published properties, ~133 extending files) is the hub of the coupling. The target is **the UI/UX app plus a library
per functional group** — in C++ terms, static libraries with narrow headers:

| Library | Holds | Status |
|---|---|---|
| `VideoScanCore` | pure types, catalog store and commit door, fingerprints, date triangulation, GEDCOM graph | exists |
| `VideoScanEngine` | media reading (ffmpeg/AVFoundation wrappers), captioning, transcription, model-lab approaches, sidecar stores, `LogSink` | new; filled one engine at a time as each moves into the service |
| `VideoScanBackground` | the container of this design | new |
| later: `VideoScanEvents`, `VideoScanProvenance`, `VideoScanFamilyTree` | the domain engines behind those tabs, each with its own tests | as #337 splits `VideoScanModel` |
| `VideoScan` (app) | SwiftUI, feature stores, the one committer, the data-risk verbs | shrinks |

The service is the lever: an engine can only move into the container if it imports no SwiftUI and touches no
`VideoScanModel`, so every move extracts a library first. Not everything at once ("no way"); every increment in
this direction, each one compile-proven, test-proven and merged.

**What this does to the grades (honestly).** CCN is per function: extraction alone does not lower it. What
modularization lowers directly is coupling (the `extension VideoScanModel` count, imports per file, fan-in/out) and
build time, and it raises testability. CCN falls when the untangling that extraction forces splits long functions —
a consequence to measure, not assume. The metrics page should carry a coupling figure beside CCN so the refactor
shows in the number it actually moves (BACKLOG).

## 1. Purpose, in Rick's terms

Rapid dev means the app is started and stopped all day. Every start kills the captioner, the fingerprint backfill,
the model lab run. The Macs sit idle all night with 96 GB and 64 GB of RAM. The work that absorbs the family media
(captions, transcripts, fingerprints, era guesses, event evidence) should keep running whether or not the window is
open, should be visible and stoppable from outside the app, and should never risk the catalog. The app becomes what
Rick says it essentially is: the UI/UX, plus the one committer.

## 2. Options weighed

| Option | Survives quit | Own name/icon | Permissions | Code sharing | Verdict |
|---|---|---|---|---|---|
| **A. Helper app in the bundle, `SMAppService` login-item agent** | yes (launchd `KeepAlive`) | yes | one extra FDA grant, once | links the same Core + a new engine target | **Chosen.** Apple's current pattern; survives reboot; user-visible in Login Items; sandbox-free like the app. |
| B. Same binary, `--background` mode (today's `--find-tag` shape) | yes if detached | no — shows as "VideoScan" twice | shares the app's grants | trivial | Rejected by Rick (10/30). Also fragile: spawned-detached processes are not supervised; #395 turned the Find Tag daemon off for this. |
| C. XPC service inside the bundle (`Contents/XPCServices`) | **no** — dies with the app | no | shares | trivial | Wrong lifetime. |
| D. LaunchDaemon (root, `/Library/LaunchDaemons`) | yes | yes | runs outside the login session: no TCC grants for user media, no Vision/CoreML context, wrong user for App Support | hard | Wrong user. |
| E. Separate app (second `.app` in /Applications) | yes | yes | one grant | separate target | Same as A with a worse install story (two things to copy, two signatures to keep in step). A keeps it inside one bundle. |

Option A, with one honest caveat: `SMAppService.register()` makes macOS show a "VideoScan added items that can run
in the background" notification and the item appears under Login Items; Rick can switch it off there at any time,
and the app must read `SMAppService.status` and say so in Settings instead of assuming.

## 3. Shape

```
  VideoScan.app (UI/UX + the one committer)                 VideoScan Background.app (launchd agent, same bundle)
  ┌─────────────────────────────────────────┐   XPC         ┌──────────────────────────────────────────────┐
  │ MFO window ── BackgroundJobsClient ─────┼──control/───▶ │ JobSupervisor ── one job at a time per lane   │
  │ Settings ▸ Background (status, on/off)  │◀──progress──  │  ├ ModelLabJob (A0…)                          │
  │ CatalogCommitter ◀── JournalApplier ◀───┼── files ──────┼──┤ CaptionJob · FingerprintJob · …            │
  └─────────────────────────────────────────┘               │  └ Backoff (idle, thermal, app-foreground)    │
            │ read/write                                    │ writes: sidecars/*.sqlite · journal/*.jsonl   │
            ▼                                               │ reads : catalog.sqlite (read-only door), media│
     catalog.sqlite  ◀────────────────── read-only ─────────┘ logs  : ~/Library/Logs/VideoScan/background.log│
                                                            └──────────────────────────────────────────────┘
```

C++ reading: the service is a separate process hosting a `JobSupervisor` (a work queue with one worker per lane);
`BackgroundJobsClient` in the app is a proxy object over an `NSXPCConnection` (think CORBA stub, but typed by a
Swift protocol); the journal is a write-ahead log the app replays into the catalog under its existing transaction.

### 3.1 Targets

| Target | Kind | Holds |
|---|---|---|
| `VideoScanCore` (exists) | SwiftPM | pure types, store, commit door, fingerprints, triangulator — unchanged |
| **`VideoScanEngine`** (new) | SwiftPM or framework | engine code that both processes need and that today lives in the app target without `VideoScanModel` coupling: `CaptionRunner`, `extractFramesForCaptioning`, `ProcessRunner`/ffmpeg wrappers, `LogSink`, the sidecar stores, the model-lab types. Moved file by file, each move a compile-proven no-behaviour-change commit. Nothing in it may import SwiftUI or touch `VideoScanModel` (a sensor greps for it). |
| **`VideoScan Background`** (new) | macOS app target, no windows, `LSUIElement`, `LSBackgroundOnly` | `main.swift` (NSApplication `.prohibited`, like `--find-tag`, because Vision/CoreML/MLX need an app context), `JobSupervisor`, `XPCListener`, `Backoff`, the job types |
| `VideoScan` (exists) | app | adds `BackgroundJobsClient`, `JournalApplier`, Settings ▸ Background; **removes** each engine as it moves (rule 4) |
| `videoscan-bg` | small CLI (in `swift_cli/`) | `status`, `pause`, `resume`, `stop`, `enqueue <job>`; talks XPC; used by the nightly and by Rick with the app closed |

### 3.2 Lifecycle

- **Registration.** On first launch after install, the app calls `SMAppService.agent(plistName: "com.rickbreen.VideoScan.Background.plist").register()`.
  The plist (in `Contents/Library/LaunchAgents/`) declares `MachServices` (`com.rickbreen.VideoScan.Background`),
  `KeepAlive: { SuccessfulExit: false }`, `ProcessType: Background`, `LowPriorityIO: true`, `Nice: 10`.
- **On demand, not resident forever.** The agent is started by launchd on the first XPC message (the app opening,
  the CLI, the nightly). It exits **cleanly** when the queue is empty and nothing has happened for 10 minutes; with
  `SuccessfulExit: false` launchd leaves it down until the next message, and relaunches it at once after a crash
  (`ThrottleInterval` 10 s). So "persists after quit" is true whenever there is work, and the Mac is not carrying an
  idle 20 GB model at breakfast. Rick can pin it resident with one Settings toggle (`KeepAlive: true`).
- **Reboot.** launchd agents load at login; a queue with work in it resumes from its last checkpoint without anyone
  touching anything.
- **One resident model.** The service owns the "one resident MLX model" rule that `CaptionRunner` enforces today;
  the app no longer loads a VLM at all once Scene Captions has moved. A job's `ResourceProfile` (peak RAM, needs
  resident model, s/unit) is checked against `ProcessInfo.physicalMemory` minus a reserve before START.

### 3.3 Control and progress: XPC

One protocol, versioned, in `VideoScanEngine`:

```swift
@objc protocol BackgroundServiceXPC {
    func status(reply: @escaping (Data) -> Void)                       // ServiceStatus (jobs, lane, backoff state, version)
    func enqueue(_ request: Data, reply: @escaping (Data) -> Void)     // JobRequest → JobID or refusal (words)
    func pause(_ id: Data, reply: @escaping (Bool) -> Void)
    func resume(_ id: Data, reply: @escaping (Bool) -> Void)
    func stop(_ id: Data, reply: @escaping (Bool) -> Void)
    func subscribe(progress endpoint: NSXPCListenerEndpoint)           // app hands the service a callback endpoint
}
```

Payloads are `Codable` structs serialised to `Data` (one serializer, versioned with a `schema` field; a mismatch is a
refusal in words, like the catalog's). The service checks the caller's code signature (`SecCodeCheckValidity`
against the "VideoScan Local" designated requirement) before accepting a connection — any process on the Mac can
otherwise open a Mach service. Progress is pushed at most 4×/s; the app's MFO row draws it exactly as it draws an
in-app job (`JobProgressSnapshot` is the same type).

If XPC is down (service disabled in Login Items, or not yet registered), the app says so in the MFO window in one
line and the verbs that need the service are disabled with the reason; nothing silently falls back to in-app.

### 3.4 Durable state: files

| What | Where (`~/Library/Application Support/VideoScan/background/`) | Shape |
|---|---|---|
| Queue | `queue/<jobID>.json` | the `JobRequest`; atomic write-then-rename; the supervisor scans it at start and on XPC `enqueue` |
| Checkpoints | `checkpoints/<jobID>.json` | last completed unit (digest + window); rewritten atomically per unit |
| Journal | `journal/<yyyy-mm-dd>.jsonl` | append-only, one line per catalog-bound fact: `{digest, table, field, value, by, evidence, at}`; fsync per batch |
| Sidecars | `../model-lab.sqlite`, `../audio-fingerprints.sqlite`, `../picture-prints.sqlite` | as designed already; the service is their only writer once the engine has moved |
| Log | `~/Library/Logs/VideoScan/background.log` | same line format as `videoscan.log`, same `LogSink` class, its own file (two processes never append to one file) |

**The journal is the only road into the catalog.** `JournalApplier` in the app reads unapplied lines at launch and
every few minutes, applies them through `CatalogCommitter.commit(as:)` in batches keyed by digest (idempotent: a
line already applied is a no-op), marks the file applied with a `.applied` sidecar holding the last line offset, and
logs OUTCOME with rows before · rows after. Lines the catalog refuses (unknown digest, archived row and the field is
a name or date — rule 3, a rejected value — the veto trigger) are written to `journal/refused.jsonl` with the reason
and shown as a count in Catalog Status. The service never learns whether a line was applied; it does not need to.

### 3.5 Backing off

`Backoff` is one actor with one published state: `.full`, `.trickle`, `.paused(reason)`.

| Signal | Source | Effect |
|---|---|---|
| Rick is at the keyboard | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` < 300 s | `.trickle`: one unit at a time, QoS `.background`, no model loads |
| The app is frontmost and a Rick-attended job is running | XPC heartbeat from the app | `.trickle` for service jobs; the attended job keeps the lane |
| Thermal pressure | `ProcessInfo.thermalState` ≥ `.serious` | `.paused(thermal)` until `.nominal` |
| Memory pressure | `DispatchSource.makeMemoryPressureSource` `.warning`/`.critical` | finish the unit, unload the model, `.paused(memory)` |
| Night window | `nightly_rota.json` hours, or the CLI's `--full` | `.full` regardless of idle |
| Display asleep / Mac locked | `CGSessionCopyCurrentDictionary` `CGSSessionScreenIsLocked` | `.full` (Rick is away) |

Each job is written as a loop over *units* (one file, one window) and checks `Backoff.state` and cancellation
between units, exactly as MFO jobs check `Task.isCancelled` today. Pause is honoured within one unit's length
(seconds for a window, a minute for a long hash); the row says "pausing…" meanwhile.

### 3.6 What may run in the service, and what never does

| Runs in the service | Stays in the app |
|---|---|
| anything that reads media and produces metadata: captions, transcripts, fingerprints, picture prints, model-lab runs, OCR, era claims, event evidence, fixity re-reads | anything that **moves, renames, deletes, trashes, re-encodes or promotes** media (data-risk paths, rule 10) — Rick is present for those |
| read-only catalog opens | every catalog write |
| nightly `--validate-catalog` (today a headless app run) — a later move | Hallie (paused), Family Tree writers, People writers |

The service binary **does not link the committer**: a sensor proves that `VideoScan Background` contains no symbol
from `CatalogCommitter`/`commit(as:)` and opens the catalog with `SQLITE_OPEN_READONLY` only. The archive choke
point is untouched because the service never has a delete verb.

## 4. The move, one engine at a time (no two-week outage)

| Step | Moves | Proof that nothing changed | Leaves in the app |
|---|---|---|---|
| **0 — skeleton** (≈ 3 days) | the helper target, plist, `SMAppService` registration, XPC protocol, `JobSupervisor` with a `NoOpJob`, `Backoff`, `videoscan-bg`, Settings ▸ Background, the MFO row for a service job | the sensor set in §6; Activity Monitor shows "VideoScan Background"; quit the app, the no-op job keeps counting | everything |
| **1 — model lab `A0`** (the video-LLM design's Phase 0) | born in the service: `ModelLabJob` running `MLXVLMCaptionRunner` out of `VideoScanEngine` | baseline numbers published from a service run; same numbers from the harness | Scene Captions still in-app (two processes could both want the resident model: the service refuses to load while the app's captioner reports loaded, via XPC status — temporary, removed in step 2) |
| **2 — Scene Captions** | `CaptionOrchestrator` → `CaptionJob`; results via journal into `captions`/`caption_runs` | the caption truth tests pass against journal-applied rows; the catalog writer quartet (debounce, write hold, role flip, relaunch) on `JournalApplier` | the in-app captioner is **deleted** (rule 4: one engine) |
| **3 — fingerprints** | sound prints, picture prints backfills | row counts in sidecars before/after match an in-app run on the same fixture set | deleted in-app |
| **4 — Content Analysis, Event Analysis evidence** | transcripts (the Whisper worker becomes a child of the service), OCR, event evidence packets | the Analyze cycler stamps read the same | deleted in-app; the Analyze pane becomes a view of service state |
| **5 — nightly** | `--validate-catalog` and the fixity re-read run as service jobs enqueued by the nightly | the morning metrics line unchanged | the headless-app CLI modes retire |

Each step is one branch, one gate, Codex on step 2 (it writes the catalog through the applier). Between steps the
app is whole; a job that has not moved runs as it does today.

## 5. Machines

- **Ultra:** the service runs big models beside the app; `.trickle` while Rick works; `.full` at night.
- **M4:** the service runs `.full` all day on read-only model jobs and backfills against its catalog `.backup` copy
  and media over TB5 (STATUS 10/30); it is the natural home of the 3B model and of long benchmark runs.
- One service per Mac; they do not talk to each other. The nightly already knows both.

## 6. Tests (rule 8) and sensors

- **Logic:** `JobRequest`/`ServiceStatus` round-trip; version mismatch refuses in words; queue scan ignores
  partial files; checkpoint resume skips completed units; journal idempotence (apply twice = once); refused lines
  land in `refused.jsonl` with the rule that refused them.
- **Scale:** 100k queued units planned in budget; a 1 M-line journal applied in 256-line batches without blocking
  the UI (main-actor commit ≤ 0.1 s per batch); progress pushes capped at 4/s under a 10k-unit job.
- **Media matrix:** `CaptionJob` in the service yields a caption for mp4/h264, mov/prores, mkv/ffv1+pcm, mxf,
  avi/dv (the existing extractor fixtures, run through the service path).
- **Isolation:** `kill -9` the service mid-unit → relaunch resumes, no duplicate journal line; a corrupt checkpoint
  → the job restarts from zero and says so; the catalog missing or newer schema → read-only open refuses, jobs that
  need it wait, jobs that do not proceed; XPC from an unsigned client → refused; disk full on the journal →
  job pauses with `paused(disk)`, no truncated line (write-then-rename).
- **Sensors (lane):** (1) **no committer in the helper** — symbol scan of the built helper + a runtime check that
  its catalog handle is read-only; (2) **journal only** — a fake job that tries to open `catalog.sqlite` read-write
  is refused; (3) **backoff honoured** — with simulated recent input the supervisor runs ≤ 1 unit per 5 s;
  (4) **one resident model** — two jobs declaring `needsResidentModel` never overlap; (5) **MFO lifecycle** —
  START/OUTCOME lines with counts in `background.log` for every job, including stopped and crashed ones
  (OUTCOME written by the supervisor on relaunch from the checkpoint).
- **Truth:** a service-produced fact shown in the UI carries `by = background:<job>@<version>` and its evidence, same
  as an in-app one; Catalog Status shows "N journal lines waiting / M refused".
- **Writer quartet** on `JournalApplier`: edit inside the debounce window, during a write hold, across a role flip,
  then relaunch — plus a Codex pass (it is a catalog writer).

## 7. Rulings wanted from Rick (one at a time)

1. **One extra permission grant** for the helper bundle (Full Disk Access + removable volumes, once, sticky under
   "VideoScan Local") — acceptable? It is the price of its own name and lifecycle. Default: yes. Rick Agrees.
2. **Name and icon:** "VideoScan Background" with the app icon badged (gear-in-arrows or clock, BACKLOG 10/28)?
3. **Exit-when-idle (default) or always resident?** Default: exit after 10 idle minutes; a Settings toggle pins it.
4. **Step order:** model lab first (new, no risk, proves the service), captions second? Or captions first because
   they are the most-restarted job today?

## 8. Sources

Apple: `SMAppService` (ServiceManagement, macOS 13+), "Updating helper executables from earlier versions of macOS",
`NSXPCConnection`/`NSXPCListener`, launchd.plist(5) (`KeepAlive`, `MachServices`, `ProcessType`, `LowPriorityIO`),
`ProcessInfo.thermalState`, `DispatchSource.makeMemoryPressureSource`, `CGEventSource.secondsSinceLastEventType`.
Repo: `App/main.swift` (`--find-tag`, the headless-Aqua arrangement this keeps), ARCHITECTURE §4 (MFO, the commit
door, LogSink), `docs/design/video_llm_lab_2026_10_30.md` §3.5 (the first job), BACKLOG "Background helper looks
like the app" (Rick 2026-10-28), DECISIONS 2026-10-28 (signing identity), #395 (Find Tag daemon off).
