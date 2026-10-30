# VideoScan — Purpose and Charter

*Rick's words. Reorganized 2026-10-30 by Claude at Rick's request: duplicates folded, brainstorming leftovers
removed, the research reading lists replaced by one pointer each. Paragraphs headed **Claude Feedback** were written
by Claude for Rick to review and keep, edit or strike; everything else is Rick's.*

# 1. Purpose
This app hosts and organizes family multimedia and family ancestry information. It has the following primary Tabs or foci for the user:

**People Tab:** This tab has the current and recent generation of immediate family. Some members in this tab are recently deceased but it is your typical family, a man & woman married with four sons and grandparents. The people tab focuses on People and also groups, ie, Families like "The Rick & Donna Breen" Family. The people tab allows the user to click on a person and edit their essential vital stats, show videos associated with that person, and it previously allowed searching for that person in video files but we found people in the family look too similar for those algs to really have a high enough success rate to be practicable. This code may be reused or retired, not sure yet.

**Catalog Tab:** Holds the media catalog and displays this to the user in various helpful ways, allows for search, etc. The catalog has Content Analysis and Event Analysis and other tools.

**Storage Tab:** Is a pretty colorful but technical view of the catalog, the files, and the storage underlying the catalog geared to helping the user understand how the files are distributed and how safe they are and how performant a drive is and its age and technology, ie, SSD, HDD, RAID, etc.

**Triage Tab:** Of questionable value, but originally conceived to help the user identify broken pairs of A/V that need to be merged or repaired. Also aids in duplicate detection and reducing the number of copies. Identify junk, delete junk, etc.

**Archive Tab:** Shows the media by decades and years with tags and highlights indicating events like birthday and vacations, christmas and thanksgiving, etc.

**Family Tree Tab:** shows the family tree as downloaded from FamilySearch.org via gedcom files. It has the merge of the Hudson and Breen family trees, allows for notes, research, and much more.

**Hallie:** Is a way to query the database and get audio feedback. The idea is to be an agentic interface to the family tree and catalog. The agent is modeled on an archive librarian and in this case, Hallie is my great grandmother and her avatar is based on restored photos of her. The family archivist avatar can be changed but currently Hallie has been worked out pretty well and is the default. Hallie primarily responds to family tree questions and finds videos in the archive and catalog.

**What I want (Rick, 2026-10-30):** to take advantage of the powerful hardware to be able to find anything in my media database, with Hallie assisting, on robust code. Push the envelope on absorbing and processing family media files, so that the app can answer just about any question about my family.

# 2. Media
The app is focused on the Breen family multimedia from 1940s–present. It facilitates the ingestion of media, analyzes the media, and manages the media, assisting the user in archiving important recordings of events like birthdays, holidays, vacations, and other special family events.

## Workflow
The essential workflow for media is: **INGEST → MANAGE → ARCHIVE.** The app helps the user identify the most important recordings so they can be archived to the most reliable storage which includes 1. RAID 2. Cloud 3. Offsite. This app facilitates and helps the user identify important family events and makes sure the best or master copy is copied to the RAID. The app does also ask / suggest the user make a copy for the cloud and offsite but these are currently outside the scope of control of this app.

## Archive
The archive holds media deemed important enough to be stored robustly in a RAID with the intention of making it available for future generations. Imagine a great granddaughter looking at her great grandfather from the 1980s in the year 2065 or something. This is for them, in many ways.

## Provenance
According to the best in class INGEST → MANAGE → ARCHIVE workflow we would be very careful upon ingest of new media, but since we have a lot of media already in the database we need to have a machine generated guess as to provenance, which can be confirmed by the user. This is where the app can get creative, using any metadata, file information, audio transcripts, scene captions, user tags, and anything in the metadata to produce a guess as to this file's ingest point, its master if possible, and its journey. The user will work hard to look at this info and confirm; the app will work hard to correlate, extrapolate, and help the user fill in provenance information. This is an important primary value of the app. Any new media coming in should have a provenance gate that requests important provenance information which is stored with that media.

## Events
The app may try to auto determine "this is a birthday", thanksgiving, christmas, holiday, vacation, graduation, birth, etc. This may work in tandem with provenance. We would like to know the master file, for example, this master copy was ingested using a digitizer at max settings on July 4 2026. If possible we identify derivative material and/or duplicates. We can detect "same event, different codec" for example. This is a nice win. We need to do more.

# 3. Family Tree
Holds the family tree and assists the user in researching members, bookmarking, looking at maps, biographical info, documents, birth certs, death certs, marriage certs, and allows for agentic crawling of websites such as archives for that person's location, say North Carolina in the 1880s. Unique and important historic events are looked for by the app and, like event analyzer, we can search automatically and find associations like "great great great grampa so-and-so fought in the revolutionary war in America".

## GEDCOM
The family tree uses the gedcom interface and, as such, should be nearly off-the-shelf SW and very reliable. A user of VS may make local changes to the FT which are stored as local notes. If a genuine problem or difference shows up, say Mary O'Connor has the wrong middle name, a mechanism exists to refresh our gedcom tree. Typically a user corrects familysearch.org first then tells the app to update the person from familysearch.org. We work hard to make sure our information is correct. There is no current mechanism, at this time Oct 28 2026, that I know of, which allows me to upload a person or tree or partial tree into familysearch.org, so we do it manually, ie, Rick logs into that site and performs the correction.

## Documentation and Verification
Info obtained from familysearch.org and other web sites must be backed up by documents, for example Birth Certs (BC), Death Certs (DC), Marriage Certs (MC), and Census Data (CD). Headstone photos with legible Name, DOB, and DOD are considered suitable documentation. We try to include as much documentation as possible and make sure it is consistent. If a person from the grandparents' generation and back has all THREE certificates BC, MC (or CD), and DC, then a nice green "Documentation: Excellent" shall appear on the right side in FT view for that person when we click on them. Documentation: {Excellent, Good, none} — all three means Excellent, any one of them is Good, no docs gets "Documentation: none". Note, all Rick and Donna's grandparents are deceased.

## Claude Feedback — agentic assistance in the Family Tree view (2026-10-30)
Rick meant to list these and had not yet; proposed, for his edit:
- **Documentation grade computed, not typed.** The Excellent/Good/none badge comes from the documents actually filed for the person (kind detected from the scan: BC, MC, DC, census, headstone), with the document as the evidence behind the badge. Same rule as the catalog: a shown fact comes from evidence.
- **Refresh discrepancies become review rows, never silent edits.** When a FamilySearch refresh changes a name, date or relation, the tree shows "FamilySearch now says X; we have Y" and Rick confirms, exactly as he confirms a machine-drafted date in the catalog.
- **Tree facts constrain media facts.** A clip tagged with a person who had died, or dated before a person was born, is flagged; a birth year plus an apparent age in footage narrows a date range. The tree is the one fact store the model may lean on (ruling 2026-08-16).
- **The memories button is the tree's face for the media expert.** "Show me some memories…" already has a provider list (`FamilyTreeMemories.swift`); the background expert's confirmed findings ("three new clips of Grandpa's house, 1991–94") plug in as one more provider, with Story of the Day (#236) and Life & Times (#238) behind it.
- **Record Finder stays agentic but cited.** Website crawling for a person and place returns candidate records with their source; nothing enters the tree without Rick.

# 4. Agentic Assistance (LLMs/AI) with the Breen Family Media and Family Tree
This is a rich topic of research and experimentation we are performing. We have locally hosted LLMs and various strategies to experiment with to solve a few problems. The app assists in analyzing, curating, estimating dates, people, events, and provenance, but **the user must confirm.** Machine-generated guesses must be called out as machine generated needing human confirmation; the machine has access to lots of metadata and compute power to help the user with this.

The goal of the agentic assisted component of the VideoScan App (LLMs, etc) is to help with:
1. **Provenance Estimation.** Many media files were ingested with incomplete or nonexistent provenance info and we believe some provenance info can be synthesized using various techniques.
2. **Event Recognition** such as birthdays, christmas, thanksgiving, vacations, ie, when someone cared enough to use a video camera. (Today everyone has a camera, but in the 80s it was unusual.)
3. **Identifying Duplicates, Similar Footage, Same Events, Derivative Clips, Re-encodes, etc.** These are all over the place in this media corpus. Finding and handling these is a big challenge.
4. **People identification.** We know it is too difficult, so far, to distinguish specific members of the same family due to facial commonalities, but we can try, based on metadata and heuristics, to estimate someone. For example, we know the birthdates of the primary people, so we can interpolate things like "thin woman with blonde hair about 35 yrs old changing a diaper" is very likely the mother, Donna. Using dates, metadata, previous videos, such inferences should be within reach of this app, using a combination of techniques.

Originally we thought we'd "train" an LLM or a Visual LLM on the Breen Family media, feeding it every video, to allow an LLM to recognize individuals in the family, or say "it is a 97% chance this person in the video is Donna", but this has proven elusive. The idea from months ago was a collection of models under a master controller, like a Mixture of Experts, specifically trained on the Breen Family Media and the Breen Family Tree — a much more constrained problem than the general one, but with plenty of challenges. We decided to try 1, 2 and 3 first and see if we can eventually try 4 again once we get some successful strategies working.

**Where the design lives:** `docs/design/video_llm_lab_2026_10_30.md` (the design: samplers, approaches, the judge, the approach ladder A0–A6), `docs/reviews/video_llm_design.md` (the running review verdict), `docs/research/video_llm_for_family_media_2026-10-29.md` (the research behind it). Provenance: `docs/design/provenance_retroactive_2026_10_26.md` and `docs/guides/provenance_roles.md`. Earlier research is in `docs/research/`.

## Claude Feedback — the Mixture-of-Experts idea against what the designs settled (2026-10-30)
**The architecture is right; the word "trained" is the only disagreement.** A master controller routing work to specialist engines and judging their output is exactly what the model-lab design describes (`ApproachRegistry` + the MFO job + the `Judge`), and the experts already exist or are designed:

| Goal | Expert | Kind |
|---|---|---|
| Provenance | whole-file SHA-256, 25 M audio landmarks, picture prints, encoder-signature chains, `DateTriangulator` | deterministic; built or designed |
| Events | Events v1 rules, transcripts, captions; VLM `occasionKind` / `roomFeatures` | rules built; VLM planned, gated |
| Duplicates | hashes, sound prints, picture prints, supersessions | deterministic; built |
| Era / date | OCR burn-ins (1,448), camera stamps, VLM `era` claim | built; VLM gated on MAE < 7 years |
| Knowledge | GEDCOM graph + CyberBrain; Hallie's fixed tool schema | built |

What is **not** done is training the experts' weights on family facts, and three rulings close that door on purpose (2026-08-16 no fine-tune as a fact store; 2026-08-14 deterministic facts, LLM phrases; 2026-10-14 no percentages without calibration on Rick's own footage). The reason is practical, not purist: a wrong weight cannot be corrected through Update…, and a LoRA on 18 confirmed events and 73 dates would mostly learn which carpets the family films on. What *is* trained, honestly, is the **gating**: Rick's confirmed examples retrieved into the prompt (A5), a small pair-classifier over his Events decisions (the 10/16 review), and LoRA only on *extraction* (reading an OSD) if the error analysis says the model sees the clue but writes it down badly (A6). So: a Mixture of Experts whose experts are mostly deterministic or frozen, and whose learning lives in the router and the judge. The facts live in the catalog and the tree, inspectable and correctable.

**Goal 3 (duplicates) needs no model.** It is solved by fingerprints; a VLM adds nothing there. The open work is coverage and scale of the picture-print backfill, not intelligence.

**Goal 4 (people) is a constraint solver, not a VLM, and nobody has designed it yet.** Proposed as the first honest rung, `A7 Household Roster`: for a file's date window (from the triangulator), the tree gives who was alive, their ages and sex, who lived in the house, and who was probably holding the camera (absent from frame). The VLM contributes only attribute perceptions — adult/child, age band, sex, "infant present" — never a name. The intersection usually leaves one or two candidates with a written reason ("woman 30–40 with an infant; in 1991 the household had one woman 30–40; Rick was likely filming"). It is a proposal to Rick, never a name written by the machine (ruling 2026-10-10), and it shows no percentage until calibrated against his confirmations (ruling 2026-10-14). Deterministic, cheap, testable; the VLM's part is the same attribute schema the era work already needs.

**How a model earns its place.** The way a bug fix does: seen failing (the baseline numbers from today's 3B captioner), then seen passing a bar measured on ground truth we already hold (73 Rick-dated files, 5,635 camera-dated files, 18 confirmed events, 1,448 OCR dates). Phase 0 of the design — wrap what exists, publish its numbers — needs no schema change and no ruling, and every later model is compared to that number.

**Privacy holds by code.** No pixels or audio of living family to a cloud model (rule 13); the runner refuses the payload before a byte leaves the process, and a sensor proves it.

# 5. Architecture and Design
Modularity, Object-Orientation, and state-of-the-art software development design patterns will be used. Algorithms and libraries of known good quality will be used rather than home grown code.

## Languages: Swift, Python, Shell, and if needed C/C++ on macOS
**Swift.** The app is written in Swift 6 using best practices and best-in-class per Apple guidelines for macOS 27 and Xcode 27. Swift Concurrency (async/await) and the actor model: the UI runs on the `@MainActor`; ingestion, local AI processing (Hallie's pipeline) and SQLite writes are explicitly assigned to background task groups or custom background actors to keep the app responsive. All heavy computational loops (ingestion, duplicate hashing, metadata crawling, video parsing) are isolated in background actors or `Task(priority: .background)`. ARC: escaping closures and async task captures use `[weak self]`/`[unowned self]` where a cycle is possible (the C++ `shared_ptr` cycle).

**Python and Shell.** The app invokes python and shell and relies heavily on ffmpeg, vlc, and other open source to handle media files.

## Code Style
- All code compiles under Swift's strictest configuration: Strict Concurrency Checking set to Complete.
- swiftlint enforces formatting. No force-casts (`as!`) or force-unwraps (`!`) pass code review; `try!` is prohibited. Pipeline transitions use `throws`/`Result` with typed error enums.
- Business logic and formatting operations are side-effect-free so they are unit-testable without mocking frameworks.

## Hardware and Use of Resources … to the max
The M4 Max has 64 GB and the Ultra 96 GB; we utilize the hardware as much as possible for the app, for testing, for LLMs. In rapid dev we use an Xcode RAM cache; the app uses a RAM cache for scanning and may allocate RAM generously (multi-gigabyte caches during disk parsing, duplicate scanning and catalog queries; no premature disk swaps or memory-pinching). Compute goes to all cores via Swift Concurrency task groups, and to the ANE and GPU via Metal/MLX where the work permits. The systems are on a UPS, so external drives and computers are not subject to sudden power loss.

## Database
The underlying database is SQLite behind an abstraction layer (GRDB) that centralizes call sites and makes the DB technology a plugin. WAL mode. The code must be rock solid and all best practices followed; tests for corner cases and boundary cases must exist and run in the overnight testbed. The integrity of the database is of paramount importance. The app always reflects the reality underneath the database to the user so we can see what is going on, and protects the user and the DB from problems and human-induced accidents or errors. File identity is the whole-file SHA-256 (CLAUDE.md rule 6).

The app is distributed Developer ID / unsandboxed, so native `Process()` and shell utilities are available to the Storage tab and the media pipeline; code generated by Claude and other LLMs is expected to follow best practices under that freedom.

## System Topology
A starting point for the top-level shape:
```
[Presentation Layer (SwiftUI)] <==> [@MainActor observed objects / feature stores]
              ▼
[Domain Engine Layer] (Swift Concurrency, strict actor isolation)
   ├── Ingest & Triage Core (AsyncSequence / task groups)
   ├── Local model broker (Ollama / MLX; JSON tool-calling; streaming)
   └── Hardware Diagnostic Engine (IOKit / BSD Darwin bridges)
              ▼
[Persistence & Storage Layer]
   └── GRDB queue hierarchy ==> SQLite3 (WAL)
```

## Claude Feedback — the background analyzer service (2026-10-30)
Rick, 2026-10-30: "The app is essentially the UI/UX… peel off services into a BG process that can keep running,
persist after we quit the app… I don't like the idea of having an option to launch the app in the BG… we can't lose
the app for 2 weeks." Designed in `docs/design/background_service_2026_10_30.md`; the shape in four lines:
- **`VideoScan Background.app`**, a helper inside the app bundle registered as a launchd agent through Apple's `SMAppService`: its own name and badged icon in Activity Monitor and Login Items; launchd keeps it alive after the app quits and across reboots; it exits when idle and relaunches on the next request. Not a copy of the app in the background.
- **It never writes the catalog.** Read-only catalog, results into sidecar SQLite files and an append-only journal that the app's one committer applies. The one-committer rule stands.
- **Engines move, never copy** (one engine per action): model lab first (born there), then Scene Captions, fingerprints, the rest of Content Analysis, Event Analysis. The app is whole at every step.
- **XPC for control and progress; files for durable state.** The MFO window shows service jobs in the same row as in-app jobs; `videoscan-bg status|pause|stop` and Activity Monitor are the window when the app is closed. It backs off while Rick is at the keyboard and runs full-out at night and on the M4.
The one cost: the helper is its own bundle, so macOS asks once for Full Disk Access for it (sticky under the "VideoScan Local" signature). Rick's call.

## Hallie: deterministic tool-calling and the persona (advisory starting point)
To let the LLM query the media database and family tree without hallucinated answers, the client enforces native JSON tool-calling schemas: the model returns `tool_calls`, the client validates arguments against typed Swift functions, dispatches the work to the background database queue, and feeds the result back as a tool message for the natural-language reply. Example tools: `query_family_tree` (structured GEDCOM relations, e.g. "who are the four sons of Rick Breen?"), `search_media_catalog(keyword, decade?)`. (Built this way: Hallie's QueryAST → deterministic executors; DECISIONS 2026-08-14.)

Persona and TTS: the `HallieAgent` actor filters markdown and structural JSON out of the token stream before it reaches `AVSpeechSynthesizer`; a ring buffer absorbs token delivery faster than speech so nothing drops or overlaps.

## Logging
Logging is critical for the ability to audit or reconstruct a sequence of events, for debugging, and overall historical information regarding the disposition of media and the behavior of the app. State-of-the-art logging is almost an art form, but good logging is critical and all modules must consider how they log so as to allow events to be reconstructed: where media has gone, status of the database, recovery from critical errors, etc.

# 6. Process
We use best-in-class solutions and best practices for everything we do. We don't quite go to the extremes of an FDA approval regime, but we follow best dev processes, find bugs early, ensure we have tests, and we have gates such as code reviews to keep the code healthy.

## Testing
We use unit tests and expect code to be testable. We are focused on our code, not the supporting framework. We use code coverage analysis tools and the highest possible settings of the compiler to check the code. We use static analysis and swift-lint, and we measure code complexity and plot how each module is doing, giving it a grade A–D. We do not allow F to make it to the repo.

Test classes include unit, regression, performance or stress, UI, and integration. We always write unit tests and try for 90% coverage, focusing on app-specific logic rather than outside frameworks or UIs we cannot control. Regression tests are always written when a bug is found and fixed, red/green: demonstrate the bug, show the fail, insert the fix, show the pass — PROVING the fix and preventing the bug from reappearing, since regression tests run in the nightly automation. Performance or stress tests demonstrate bottlenecks and their fixes, threading issues, or overall performance problems. Hardware and memory are available for as much testing as needed.

## Automation, Automation, Automation
We use state-of-the-art overnight methods to improve and ensure the robustness and integrity of the code. Any bug has a regression test which demonstrates the failure before and after the fix.

## Code Reviews
Codex performs adversarial code reviews, scoped and focused so as not to get sidetracked, and after several iterations Claude must decide that it is good enough for now — incremental progress is important. If an issue is seen by Codex or testing and we still want to proceed, we file a GH issue and circle back.

### Claude Feedback — local review models on the night shift (Rick's direction, 2026-10-30)
Codex runs out of usage; the Ultra (96 GB) and the M4 (64 GB) sit idle after Rick goes to bed. Direction: try a local model as an overnight code reviewer, one folder at a time; grade its findings against held answers (historical bugs at their pre-fix commits, their fixed versions as negative controls); keep it if it finds real defects at a triage cost Rick accepts, otherwise try the next model. This is tooling, separate from the app, and it never replaces the Codex pass that data-risk code requires. Codex's unmerged pilot (`experiment/attended-model-review`: attended runner, pinned-SHA packets, honest `failed`/`completed_unverified` outcomes, a proposed 04:00 slot) is the starting point; its first live run has yet to happen (the agent sandbox blocked localhost).

## Bug Reports
GH Issues are filed on GH; p0 for severe, p1 for critical, etc. The bug reports are reviewed weekly.

## Metrics
We have a series of best-in-class metrics and an associated web page where we plot our progress. See the metrics page for more.

## Nightly Automation and Themes
We take advantage of the night-time cycle to perform as much automated testing as possible, providing a detailed report via the code metrics page in the morning for the CTO, Rick, to review. The overnight themes are usually hardening, where a particular module or problem is attacked by Claude with Codex as reviewer so that by morning the app has 1. been tested thoroughly with metrics posted 2. the hardening theme of the night completed and tests added as needed.

## Development Modes
We work in three modes. The mode in force is said at the start of a session, and it decides what runs, where it runs, and when the gate is paid. (Mechanics: `docs/PROCESS.md` §Modes; rulings of 2026-10-24 in `docs/DECISIONS.md`.)

**Rapid Dev (RD).** Rick and Claude work on main together, in the foreground. Claude edits; Rick builds (Debug), runs, debugs and spot-tests in Xcode; no test runs between look-and-tweak rounds. The first pass of a change still ships its red/green tests, and one sensor-lane run is made when Rick says "happy". This is the mode for UI and workflow work, where the judgement is Rick's eye against Apple HIG and best-in-class apps.

**Automated Dev.** Rick talks to Claude in the foreground; the work runs in the background. Claude plans and merges; worker agents take file-disjoint slices in their own git worktrees with their own DerivedData, never on Rick's checkout, and every slice pays the full gate before merge: related suites green with counts, the sensor lane GREEN (it carries the warning ratchet), a Codex pass on data-risk code. Rick's machine stays responsive; long builds and whole suites go to the fleet. This is the mode for carrying out a plan that is already written — a design doc, a migration stage, a backlog item — and Rick's part is rulings and spot tests, not waiting.

**Overnight Themes.** 02:00 on the fleet, never on Rick's machine: the full suites, the gauntlet, metrics, the static-analysis lane, and one hardening theme — a module or a problem attacked by Claude with Codex as the adversarial reviewer, tests added as the proof. Nothing deletes overnight except scratch; the checkout is on main by 02:00; by morning the metrics page, the session-start lines and the Swift 6 progress figure show what the night did, and the P0/P1 counts say what the day owes.

The mode changes only WHEN the gate is paid, never WHETHER: a change that reaches main has its tests, its sensor-lane GREEN and, where it touches family media or its records, its Codex verdict, in every mode.

# 7. Principles and Mottos
Elegant design is an art but we're engineers … so we do our best and always consult best practices and state-of-the-art solutions. Most problems already have solutions, so we make sure we're using best-in-class templates and code examples already well proven. KISS.

- **We Melt Silicon.** We use the hardware resources at our disposal — RAM, CPU, GPU, ANE, all cores, Metal, MLX. Let the computer do the work; don't give Rick 10 steps to follow when you can do it.
- **Trust But Verify.** If a bug is fixed, ask how we let it in; write a regression test that proves it red/green.
- **Test and Measurement is critical.** If you can't measure it, you can't be sure about it.
- **Automate as much as possible.** Testing and testbeds, static analysis, code review tools, regression tests, performance tests.
- **Don't reinvent the wheel.** A given problem is usually already solved; find best-in-class solutions and adapt them. We scan GitHub open source for anything that helps.
- **Incremental daily progress.** Keep main up to date; never let feature branches fester or age.
- **Stay Updated.** Technology marches quickly: weekly checks for new models, better algorithms, best practices.
- **Robustness of code and Integrity of Data are paramount.** Once these are achieved we optimize and push for the highest performance.
