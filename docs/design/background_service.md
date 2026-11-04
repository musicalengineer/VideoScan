# VideoScan Background — the analyzer service

Status: in flight — 2026-11-04: **the helper owns its schedule** (DECISIONS 2026-11-04; §3.2, §3.5 below). Earlier: 2026-11-01. Step 0 is built (the helper, its launchd job, XPC control, a no-op job; off unless `background.service.enabled` is set, no Settings toggle yet). Step 1 merged on 2026-11-01 (`0656aee6`): the seated 8B era/OCR job, the observation journal, `JournalApplier` through the commit door, schema v14 `provenance_assertions` (DECISIONS 2026-10-31, 2026-11-01). The corpus run proceeds in Rick's windows on the Ultra (STATUS). Step 2, captions on the 8B, is §4.

VideoScan Background is the helper process that keeps analysing after the app quits: a login-item launchd job the app registers, controlled over XPC, with its durable state in files under `App Support/VideoScan/background/`, backing off when Rick is working, and taking one engine at a time out of the app so the app is never down for a rewrite. What it may run is listed in §3.6; it never touches media. §0.6 (Rick, 10/31) says what goes in and what comes out; §0.7 names the outputs **observations**, says where they live (the three homes) and in what order they are produced (1960–2010, oldest first). An observation reaches the catalog only through the app's one commit door, and is never shown as a date (DECISIONS 2026-11-01). The first job it hosts is the video-model work in `docs/design/machine_intelligence.md`.

*The design as written on 2026-10-30, with §0.5–§0.7 added 10/30–10/31 (Rick said "design it"); the italic note below is its original preface.*


*Rick said "design it" on 2026-10-30: "The app is essentially the UI/UX… peel off services into a BG process that
can keep running, persist after we quit the app… We need a persistent service or process that survives app reboots.
I don't like the idea of having an option to launch the app in the BG but I am open to these trade-offs… we can't
lose the app for 2 weeks while we completely refactor it into a front-end backend." This is the VideoScan answer.
It builds on `docs/design/machine_intelligence.md` (the first job the service hosts) and ARCHITECTURE §4 (MFO,
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
5. **It runs whenever there is work (2026-11-04, replacing "it backs off while Rick works").** No keyboard or
   trickle backoff: the worker child runs at utility QoS, so interactive apps win the CPU and the performance cores
   stay reachable. Only the Mac's own thermal and memory pauses, Pause in the menu bar, or a hold after a failure stop
   it. A Speed control is deferred until Rick sees interference. Every job declares its RAM and whether it needs the
   one resident model; the service refuses to start a job the Mac cannot hold.
6. **Cost Rick pays once:** the helper is its own bundle, so macOS asks for Full Disk Access (and removable-volume
   access) for it once; signed with Rick's Apple Development identity (DECISIONS 2026-11-03, replacing "VideoScan Local" of 10-28) so the grant and the launch constraint survive rebuilds. One
   grant, one time, is the price of its own name and lifecycle; the single-binary alternative (§2 option B) shares
   grants but is the design Rick does not want.

## 0.5 Statement of responsibility (Rick, 2026-10-30: "good SW design requires clear responsibilities")

**`VideoScan Background` is a persistent container.** It keeps analysis engines running when the VideoScan window is
not open. It owns no analysis logic of its own.

| It is responsible for | It is not responsible for |
|---|---|
| Staying alive across app quit and reboot while registered (launchd KeepAlive; no idle exit since 2026-11-04) | Any user interface; it has no windows and draws nothing |
| **Its own schedule** (2026-11-04): planning each scheduled kind at launch, every 10 minutes and when the catalog generation changes; running jobs one per lane with checkpoints; holding a kind whose job failed | Owning the *rule* that decides what is stale (that is the job's planner, in the engine library). The app enqueues nothing; the CLI may still `--enqueue` / `--run` by hand |
| Hosting engines from the libraries (`VideoScanCore`, `VideoScanEngine`) and loading at most one resident model | Containing an engine's logic; an engine that needs the service must first live in a library with its own tests |
| Thermal and memory pressure (pause); utility QoS for the worker | Energy backoff while Rick works (removed 2026-11-04) |
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

## 0.6 What goes in, what comes out, and why (Rick, 2026-10-31, after the first review session)

**The goal, in Rick's words:** make the corpus easier to search and organize. Estimate dates over the whole corpus; a date within
2–3 years is valuable; "find all the videos down the Cape from 1990–1995" answered 90 % right is a win. Then the same for places,
events, people. The service's job is to produce that intelligence in bulk, file after file, so Rick never dates by hand again.

**On confidence.** A 95 % percentile per file is overkill and would be invented: the model's own confidence number is not calibrated.
What we need is a **calibrated claim**: a range (or a year ± n) plus the *measured* hit rate of that kind of claim on the confirmed
set. "Era 1990–1995, kind of claim right 80 % of the time on Rick-dated files" is honest and is enough for a 90 %-right search when
the search also uses the file's own facts. The Catalog Status line "machine era within 5 y of your confirmed date: N of 73 (p %)" is
that calibration, read week over week. Today (25 Rick-dated clips, 8B, pixels only): midpoint within 5 y on 20 of 25; the model's
ranges are padded (15–20 y wide on 9 of the 13 misses) — a prompt/contract problem, not a model problem; midpoint ± 5 is the usable claim.

### Inputs — what the machine can look at

| Layer | Facts | Have / not yet |
|---|---|---|
| Container & metadata | container, duration, size, creation vs modification dates (file system, `mvhd` creation time since 1904, EXIF `DateTimeOriginal`), encoder string, device make/model, GPS, orientation, timecode track, chapters, **DV datecode** (per-frame recording date/time on DV) | most read; `exiftool` fields and the DV datecode **not yet** |
| Video technical | codec, profile, bit depth, chroma, color primaries/transfer, frame size, PAR/DAR, frame rate, scan + field order, **3:2 pulldown (film detector)**, GOP, bitrate, grain/noise, letterbox geometry, VHS head-switching noise, film gate weave | first group read; signal-level ones **not yet** |
| Audio technical | codec, channels, sample rate, bit depth, loudness, dual-mono vs stereo, **mains hum (ENF)**, hiss floor, dropouts | first group read; ENF **not yet** |
| Picture content | scene cuts, shot length, camera motion, exposure/white balance, color cast, camcorder OSD date/time, on-screen text, faces, people, clothing, objects, cars, signage, room features, weather, season, time of day | OCR, captions, faces, era (8B); cuts and signal stats **not yet** |
| Audio content | transcript, speaker identity, spoken names, music (a song = a lower bound on the date), ambient sound, language | transcripts; speaker similarity in BACKLOG |
| Identity & provenance | whole-file SHA-256, perceptual video hash, audio fingerprint, **PRNU sensor noise (the physical camera)**, edit signatures | hash + audio fingerprint; perceptual hash and PRNU **not yet** |
| The catalog and Rick | confirmed dates, people tags, places, occasions, archive decisions; earlier machine observations | read; **no circular corroboration** (a derived fact never supports the inference that produced it; a machine fact never outranks a human one) |

### Outputs — machine-generated intelligence, where it lives, what it unlocks

| Output | How it is made | Store | Unlocks |
|---|---|---|---|
| **Era / date claim** | 8B vision model, windows + contract (A2); fused with the file's facts as bounds (codec/carrier floor, stamp read, DV datecode, metadata on camera-native files) | journal → `provenance_assertions` (v14) only — never `inferred_dates`, the triangulator or a filter (DECISIONS 2026-11-01) | its own inspector line; the convergence count; search by era words ("90s"); a date only if Rick later rules |
| Burned-in date (OCR) | 8B `date` prompt on 5 stills | journal → `provenance_assertions` (`ocr.date`, step 1) | exact dates on camcorder footage, once Rick rules how they rank |
| Scene captions, on-screen text | 8B `scene` / `text` prompts (the captioner moves to the 8B) | journal → `captions` | free-text search |
| Transcript, spoken names | Whisper; name presence | journal → `transcripts` | search by what was said; people |
| Room / place signature | `roomFeatures` contract → signature over the corpus | sidecar (vectors) + journal (place label once ruled) | "find the Cape house"; events |
| People presence | face pipeline + Household Roster filter + Rick's confirmations | `people` stores (separate by design) | "find Donna" |
| Events / occasions | **rulings over the above** (same date window + same place + same people + same audio print), never a model | `events` | "Thanksgiving 1984" as a folder |
| Duplicates / same footage | SHA-256, audio fingerprint, perceptual hash | catalog + `audio-fingerprints.sqlite` | let copies go safely; link transfers |
| Provenance | carrier, device chain (PRNU, encoder strings), transfer chain | `provenance_assertions` | which file is the master; what a date means |

The service produces the per-file rows; **conflation is deterministic**, in the rulings and the triangulator, auditable and tested.
The model is a witness per file, not the organizer.

### Forensics, read for our scale (Rick's guide, 2026-10-31)

Rick's guide (`audio_video_digital_forensics_guide.pdf`) is court-oriented and single-file. What transfers to hundreds of files:
- **The checklist is our rule set:** never one timestamp (the triangulator weighs every source); map to UTC (every stored date carries
  its zone); audit for "timestomping" — for us the benign version, **transfer versus content**: a 2003 file holding 1984 footage is
  the normal case, not an attack, and the output must say which date is which.
- **ExifTool** beside ffprobe for `DateTimeOriginal`, `mvhd` creation time (seconds since 1904, a classic off-by-66-years trap),
  encoder signatures: cheap in bulk, worth a probe pass over the corpus. **DCode-style epoch decoding** matters only for odd containers;
  ffprobe already normalises the common ones.
- **Amped / Axon / Magnet / Belkasoft** reconstruct one timeline from one file for a courtroom; nothing in them beats ffmpeg + Python
  for bulk, and their proprietary-DVR strengths do not apply. **VideoCleaner**'s tamper checks do not apply.
- **Beyond the guide, the cheap date sources, checked the same evening** (lab design §11; research pass + a probe over the corpus):
  - **ExifTool / container dates — first, hours.** `QuickTime:CreateDate` / `MediaCreateDate` / `TrackCreateDate`, iPhone's
    `Keys:CreationDate` (local time with offset, the best phone field), `Matroska:DateUTC`; always `-api QuickTimeUTC=1`; a 1904 or
    zero value is unset; a date equal to the file's mtime is the transfer, not the recording. One-day test: tabulate every date field
    against mtime over the corpus and count the files with real evidence.
  - **DV datecode — yes, a day.** It lives in the DV frames (VAUX/SSYB), survives a stream copy into .mov/.mkv, and is lost by any
    re-encode (FFV1, ProRes, H.264). ffprobe does not read it (a raw .dv shows only the timecode). **Probe tonight:** MediaInfo finds a
    `Recorded_Date` on 5 of the 51 DV clips, all 2000s camcorder captures wrapped in QuickTime, and the year matches the file's own
    date 4 of 5 (one Dec 21 vs a Jan label — the boundary case); the ten raw `.dv` captures from the 1990s show a subcode timecode
    but no date in the frames MediaInfo reads — either the camcorder clock was unset or the date appears later in the tape. Next:
    `dvrescue` (MediaArea; needs a Brewfile entry and Rick's install) reads the datecode per frame and would settle it.
  - **Mains hum (ENF) — dropped.** No public US 60 Hz reference exists for 1985–2010 (FNET/GridEye starts ~2004 and is not open in
    bulk); battery camcorders with AGC, music and speech rarely carry a usable hum; tape transfers add wow and flutter.
  - **PRNU camera fingerprint — grouping only, later.** Compression, stabilization and scaling weaken it; interlaced SD DV is marginal;
    analog transfers carry the capture card's pattern, not the camera's. It yields a cluster, never a date; worth a try only for
    grouping uncropped phone clips from one phone.
  - **3:2 pulldown as a film detector — untested**, still worth a day.

**Step 1, as built (DECISIONS 2026-10-31; merged 2026-11-01):** the 8B era/OCR job first, with schema v14; captions second (§4).
§7 ruling 4 answered; 2 and 3 take the defaults unless Rick says otherwise.

## 0.7 Where the machine intelligence lives, and what to call it (Rick, 2026-10-31 evening)

**Name: observations** (glossary: `docs/ARCHITECTURE.md` "Terms"). Rick's own word in §0 ("populate observations or derived machine-generated information"). A fact Rick set is a
**decision**; a fact a machine produced is an **observation**. Not "meta-metadata" (it describes the footage, not the metadata) and
not "machine intel" (it sounds like it reasons; it records). Every observation carries who made it (`by = engine@version`, the model
and prompt hash for a model), when, and its evidence; a decision always outranks an observation; an observation never supports the
inference that produced it.

**Where (three homes, see `docs/design/data_organization_2026_10_31.md` — the full table-by-table map, also rendered as a PDF for Rick):**
1. **`catalog.sqlite`** — observations that have earned a seat, as ordinary rows beside Rick's decisions: `captions` / `caption_runs`,
   `transcripts`, `inferred_dates` (range, confidence, source, reason — never the 8B's era, DECISIONS 2026-11-01), `dossiers`, `sound_prints` / `perceptual_prints` stamps,
   `footage_likeness` / `footage_membership`, `duplicate_*`, `media_checks`, and (v14) `provenance_assertions`. They get there only
   through the app's one committer, from the helper's journal. Searchable, backed up, fixity-checked, never deleted.
2. **Sidecar stores** the engines own, regenerable bulk the app reads directly: `audio-fingerprints.sqlite` (landmarks),
   `model-lab.sqlite` (every raw model output with run, model and prompt hash; segments; vectors; append-only by trigger),
   `metadata_cache.sqlite` (the ffprobe cache, keyed by path + size + mtime).
3. **The helper's files** (`background/queue`, `checkpoints`, `journal/*.jsonl`): work in transit, atomic publish, append-only journal.
`.scratch/` is the lab bench: per-clip bench records, frames, Rick's review verdicts; thrown away, never in git.

**Rick's priorities that shape the analyzer (2026-10-31):** the valuable years are **1960–2010, before the phone**; the older the file, the
more valuable, so the analyzer walks **oldest first** (by the best date bound it has) and modern phone footage last — its own
metadata dates it anyway. The People tab's **birthdays, sex and descriptions** are constraints the machine must use: a baby walking for
the first time and a birthdate in the roster bound a file to a window (constraint propagation — also in Rick's architecture note);
a known hair colour or build narrows a face match. The Household Roster (A7) is that filter.

**On caching, since Rick asked:** observations keyed by content digest are never recomputed for an unchanged file — the captioner
skips a digest with a `caption_runs` row for the same model, transcripts and prints likewise. The ffprobe cache is keyed by path +
size + mtime, so a move or a touch re-probes (cheap, by design). Verify and fixity verbs re-hash on purpose: that is their job. If an
MFO verb visibly repeats work on unchanged files, that is a bug against this rule and should be named (BACKLOG, "MFO verb repeats").

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
  └─────────────────────────────────────────┘               │  └ Schedule + holds; thermal/memory pause    │
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

- **Registration.** The Settings checkbox (Release build, catalog master only) calls
  `SMAppService.agent(plistName:).register()` / `unregister()` and nothing else. The plist (in
  `Contents/Library/LaunchAgents/`) declares `MachServices`, `RunAtLoad`, `KeepAlive {SuccessfulExit: false, Crashed:
  true}`, `ProcessType: Interactive`, `ThrottleInterval 10`, `ExitTimeOut 30` (sources and reasons:
  launchd.plist(5); `.scratch/helper-schedule-bp.md` at the time of the change). `Background` and the unspecified
  `Standard` type both throttle CPU and I/O; the priority comes from QoS instead.
- **Resident while registered (2026-11-04, replacing "on demand, exit when idle").** `register()` bootstraps the
  agent at once and at every login. A crash or an error exit restarts it (throttled to one spawn per 10 s). A clean exit 0
  (SIGTERM from `unregister()` or logout) leaves it down, so off means not running. There is no idle exit.
- **A plist change needs a re-registration.** `SMAppService.h` says to re-register when the plist or the executable
  changes, and to unregister first if the executable changed. The app does not do this automatically, so after an
  update that changes the plist, Rick unticks and re-ticks the checkbox once.
- **The schedule.** `JobSupervisor` with a `JobSchedule` (`JobSchedule.swift`): every 30 s it reads the catalog's
  `generations.generation` through the read-only door. It plans at start, every 10 minutes and on a generation change.
  For each scheduled kind with no active job and no hold, it asks the planner for the plan size (the job's own planner;
  EraPlanner for era), reports that size in `ServiceStatus.planned`, and enqueues a job when the plan is not empty.
  It runs only while it owns the state root (StateRootLock).
- **Failures hold.** A scheduled kind whose job ends `.failed` is held in `background/holds.json`:
  - after `failFastUnits = 5` identical systemic failures;
  - when every unit failed, whatever the cause ("nothing written");
  - after a START or admission refusal.

  The hold survives a restart and is released by Resume on its menu line, by a new build (the executable's size and mtime), or by new work. New work means the plan size differs from the first plan measured after the hold. A catalog commit that adds no work does not release it. (Fable review 2026-11-04: failure words carry a stderr tail that differs per spawn, so no words-based rule is stable.) A release drops the kind's old work item and plans one fresh job. The menu bar and Settings say why. This answers Codex #232 F4.
- **Pause** from the menu bar is kept per kind in `background/paused.json`. A restart adopts the job still paused, and Resume clears it.
- **Only the helper enqueues a scheduled kind.** XPC and the CLI refuse `era`, and the CLI keeps `--run era` for hand runs. A queue file goes with its job's OUTCOME.
- **Crash loops.** Before each unit, the checkpoint records that unit as in flight. A unit found in flight at 3 relaunches is quarantined: counted failed, skipped, and logged. A clean SIGTERM (unregister, logout) clears the mark first, so it never counts. The failure streak lives in the checkpoint, so the verdict survives a relaunch.
- **An older helper is said.** `ServiceStatus.build` names the running build. When it differs from the helper bundled in the app, Settings says "older helper running — turn the checkbox off and on".
- **Full Disk Access (note, 2026-11-04).** DTS (forum threads 694948, 661178) says TCC treats the containing app as
  the responsible code for a helper embedded in it, so the grant is the app's. This is not verified on the Ultra; the
  §0 point 6 wording stands until it is.
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
against the helper's own designated requirement, read at runtime) before accepting a connection — any process on the Mac can
otherwise open a Mach service. Progress is pushed at most 4×/s; the app's MFO row draws it exactly as it draws an
in-app job (`JobProgressSnapshot` is the same type).

If XPC is down (service disabled in Login Items, or not yet registered), the app says so in the MFO window in one
line and the verbs that need the service are disabled with the reason; nothing silently falls back to in-app.

### 3.4 Durable state: files

| What | Where (`~/Library/Application Support/VideoScan/background/`) | Shape |
|---|---|---|
| Queue | `queue/<jobID>.json` | the `JobRequest`; atomic write-then-rename; the supervisor scans it at start and on XPC `enqueue` |
| Checkpoints | `checkpoints/<jobID>.json` | last completed unit (digest + window); rewritten atomically per unit |
| Journal | `journal/<yyyy-mm-dd>.jsonl` (UTC day) | append-only, one line per observation, version 1, canonical JSON: `{at, by, confidence, evidence, field, id, job, state, subject_id, subject_kind, table, unit, v, value}`; `id` = SHA-256 of the line without `id` (the idempotence key); one `write(2)` + `F_FULLFSYNC` per unit; a torn tail is sealed and refused, never glued (`ObservationJournal.swift`) |
| Sidecars | `../model-lab.sqlite`, `../audio-fingerprints.sqlite`, `../picture-prints.sqlite` | as designed already; the service is their only writer once the engine has moved |
| Log | `~/Library/Logs/VideoScan/background.log` | same line format as `videoscan.log`, same `LogSink` class, its own file (two processes never append to one file) |
| Owner | `owner.lock` | advisory `flock(2)` held for the owner's life, contents "pid N · cli --run era · since HH:MM"; **one supervisor per state root** (2026-11-02): the service and a hand run share these folders, so whichever claims first runs the jobs; the other serves status, refuses `enqueue` in the holder's words and asks again every 30 s; the kernel drops a dead holder's lock (`StateRootLock.swift`) |

**The journal is the only road into the catalog.** `JournalApplier` in the app reads unapplied lines at launch and
every few minutes, applies them through `CatalogCommitter.commit(as:)` in batches keyed by digest (idempotent: a
line already applied is a no-op), marks the file applied with a `.applied` sidecar holding the last line offset, and
logs OUTCOME with rows before · rows after. Lines the catalog refuses (unknown digest, archived row and the field is
a name or date — rule 3, a rejected value — the veto trigger) are written to `journal/refused.jsonl` with the reason
and shown as a count in Catalog Status. The service never learns whether a line was applied; it does not need to.

### 3.5 The Mac's pause (was "Backing off"; 2026-11-04)

`Backoff` is one actor with one published state: `.full` or `.paused(reason)`. Thermal at serious or above pauses
until the Mac is back to nominal. Memory pressure at warning or critical pauses after the current unit. There is no keyboard,
lock-screen, night-window or app-heartbeat row, and no trickle. `.trickle` and `JobProgressSnapshot.waiting` still
decode so an older helper's payload reads correctly; this helper never produces them. Each job is a loop over units.
The supervisor checks Pause, Stop and the Mac's pause between units and runs units back to back. The worker
child is spawned with `Process.qualityOfService = .utility`, so interactive and user-initiated work outrank it. It is
never `.background`, which Apple says is "more likely" to run on the efficiency cores. The model stays loaded in the worker for
the whole job.

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

*Rewritten 2026-11-01 to the effective handoff (Codex docs review F04). The original 10/30 step table, where step 1 was
the model lab's A0 and the order was still a question (§7 ruling 4), is in git history; ruling 4 was answered by
DECISIONS 2026-10-31.*

| Step | State | What it is |
|---|---|---|
| **0 — skeleton** | **built** | the helper target, plist, `SMAppService` registration, XPC protocol, `JobSupervisor` with a `NoOpJob`, `Backoff`, `videoscan-bg`, the MFO row for a service job. Off unless `background.service.enabled`; no Settings toggle yet. |
| **1 — the 8B era/OCR job** | **merged 2026-11-01** (`0656aee6`) | `EraJob` runs the seated 8B (`qwen3-vl-8b-4bit`, the A2 contract, pixels only; the file's own facts enter as deterministic bounds, never prompt text) through `ClipService` / `PythonClipWorker` (watchdog), oldest first, digests already seen by that signer skipped. Per window it writes `era.yearRange` and `ocr.date` observations and one `era.fused` per file to the journal; the app's `JournalApplier` commits them through the commit door into v14 `provenance_assertions`. UI: the inspector's "Machine era … · 8B, unconfirmed" line, Catalog Status's convergence and journal lines, era words in search. Started by hand (`--run era` / `--enqueue era`). A machine era is never a date (DECISIONS 2026-11-01). A file the model answered but that yields no fused range gets one `era.none` line (value `none`, evidence = windows tried / valid / refused; never an era, never a date), so the signer's caching rule skips it next run. A record with no fused range in which the model did not see the whole file (an era window or OCR still that was a generation error, a frame that would not rip) is not evidence: the unit writes no line at all — any line would cache it — and is retried next run (branch `fix/era-none-observation`, 2026-11-02; Codex F1/F2). A fused range wins over such a failure. |
| **2 — captions on the 8B** | **next** | `CaptionOrchestrator` → a `CaptionJob` in the helper on the 8B; uncaptioned files first, then a backfill; the 3B captioner then retires and the in-app captioner is **deleted** (rule 4: one engine). Contract below. |
| **3 — fingerprints** | planned | sound prints, picture prints backfills; row counts in sidecars before/after match an in-app run on the same fixture set; deleted in-app. |
| **4 — Content Analysis, Event Analysis evidence** | planned | transcripts (the Whisper worker becomes a child of the service), event evidence packets; the Analyze cycler stamps read the same; the Analyze pane becomes a view of service state. |
| **5 — nightly** | planned | `--validate-catalog` and the fixity re-read as service jobs enqueued by the nightly; the morning metrics line unchanged; the headless-app CLI modes retire. |

Each step is one branch, one gate, and a Codex pass when it writes the catalog through the applier (step 1: #187;
step 2 needs its own). Between steps the app is whole; a job that has not moved runs as it does today.

**Step 2, the caption journal contract.** It mirrors step 1's journal (§3.4, `ObservationJournal.swift`): one line
per caption the 8B produced, each with its `id` (SHA-256 of the canonical line, the idempotence key), its `by`
(`machine:<approach id>@r<revision>` for the 8B caption approach) and its `evidence` (window, frame times, prompt
hash), appended per unit (one file) and fsynced once per unit, the unit checkpointed only after its lines are whole.
The destinations are the existing `captions` (one row per `(digest, kind, seq)`, kinds `scene` / `ocrDate` /
`ocrText`, `at_s`, `text`) and `caption_runs` (one row per digest: `model`, `made_at`) — so a caption line carries
`table = "captions"` with kind, seq and time, and a file's run is one closing `caption_runs` line written after its
caption lines; the applier commits a file's captions and its run row together, so a run row never stands without its
captions. **A file the 8B looked at and found nothing in gets an explicit "none" line** (its `caption_runs` row with
no caption rows, the same shape as a transcript's empty text = "ran, found no speech"), so it is not retried every
run — the same rule as the era job's `era.none` (above). The applier gains `captions` / `caption_runs` as known
tables (today it refuses anything but `provenance_assertions` as `unknownTable`); every other refusal rule
(`unknownDigest`, `archivedNameOrDate`, `invalid`, torn tail) and the `refused.jsonl` count apply unchanged. Caching
(§0.7): a digest with a `caption_runs` row for the same model is never re-run.

Open: Rick —
1. **The 3B rows during the 8B backfill.** Today `caption_runs` holds one row per digest and `captions` refuses a
   different text at an occupied `(digest, kind, seq)` (trigger `captions_bound_conflict`), so the 8B cannot simply
   overwrite a 3B caption. Keep the 3B rows and skip those files, replace them (needs a supersession rule), or keep
   both (an additive migration keyed by model) — a schema question, so Rick's.
2. **The `by` / evidence for a caption row.** `captions` has no `by` or evidence column (only `provenance = 'bound'`);
   whether the journal's `by` and evidence land in `caption_runs.model` alone or in a new additive column is the same
   approval.

**Tests that already exist and bind to step 2** (cite these; extend, do not duplicate):
- Writer quartet on the applier: `VideoScanTests/JournalApplierWriterTests` (debounce window, write hold,
  viewer/master flip, quit with lines waiting → relaunch); truth and logic: `JournalApplierTruthTests`,
  `JournalApplierCodex187Tests`, `JournalApplierSensorTests` (all in `VideoScanTests/JournalApplierTests.swift`); Core:
  `ObservationJournalTests`, `JournalApplicationTests`, `JobSupervisorIsolationTests`, `JobSupervisorScaleTests`
  (`VideoScanCore/Tests/VideoScanCoreTests/Background/`).
- Caption truth: `CaptionDegenerateRefusalTests`, `CaptionDegenerateReaderRouteTests`,
  `CatalogStatusDegenerateOCRTests` (`VideoScanTests/CaptionDegenerateRefusalTests.swift`, GH #402: junk OCR is never
  date evidence on any route), `SceneCaptionsTests`, `CaptionOrchestratorTests`, and the archived-row rule
  `DossierArchivedAdmissionTests`. The cutover passes when these hold against journal-applied rows.
- Host and fixtures: the app suites run on the M4 (PROCESS §8, the default testbed); a live 8B smoke needs the Ultra
  (the model and the media are there). The five-container media matrix uses the existing extractor fixtures (§6).

## 5. Machines

- **Ultra:** the service runs big models beside the app whenever there is work, at utility QoS (2026-11-04).
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
  is refused; (3) **schedule** — the helper plans by itself at launch and on a generation change, holds a failed kind across a
  restart, the app enqueues nothing (`BackgroundSettingsSensorTests.noAppCodeEnqueues`), the bundled plist carries the
  KeepAlive keys, and the worker child reports utility QoS (`JobScheduleTests`, `PythonClipWorkerQoSTests`,
  `BackgroundHelperBundleSensorTests`);
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
3. ~~Exit-when-idle or always resident?~~ — **answered** (DECISIONS 2026-11-04): resident while registered; the helper owns its schedule.
4. ~~Step order~~ — **answered** (DECISIONS 2026-10-31): the 8B era/OCR job first (step 1, merged), captions second.

## 8. Sources

Apple: `SMAppService` (ServiceManagement, macOS 13+), "Updating helper executables from earlier versions of macOS",
`NSXPCConnection`/`NSXPCListener`, launchd.plist(5) (`KeepAlive`, `MachServices`, `ProcessType`, `LowPriorityIO`),
`ProcessInfo.thermalState`, `DispatchSource.makeMemoryPressureSource`, `CGEventSource.secondsSinceLastEventType`.
Repo: `App/main.swift` (`--find-tag`, the headless-Aqua arrangement this keeps), ARCHITECTURE §4 (MFO, the commit
door, LogSink), `docs/design/machine_intelligence.md` §3.5 (the first job), BACKLOG "Background helper looks
like the app" (Rick 2026-10-28), DECISIONS 2026-10-28 (signing identity), #395 (Find Tag daemon off).
