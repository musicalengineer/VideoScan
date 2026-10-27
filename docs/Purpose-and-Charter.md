1. Purpose
This app hosts and organizes family multimedia and family ancestry information. It has the following primary Tabs or foci for the user:
		
People Tab: This tab has the current and recent generation of immediate family. Some members in this tab are recently deceased but it is your typical family, a man & woman married with fours sons and grandparents. The people tab focuses on People and also groups, ie, Families like "The Rick & Donna Breen" Family. The people tab allows the user to click on a person and edit their essential vital stats, show videos associated with that person, and it previously allowd searching for that person in video files but we found people in the family look too similar for those algs to really have a high enough success rate to be practicable. this code may be reused or retired, not sure yet. 

Catalog Tab: Holds the media catalog and displays this to the user in various helpful ways, allows for search, etc. The catalog has Content Analysis and Event Analysis and other tools like 

Storage Tab: Is a pretty colorful but technical view of the catalog, the files, and the storage underlying the catalog geared to helping the user understand how the files are distributed and how safe they are and how performant a drive is and its age and technology, ie, SSD, HDD, RAID, etc.

Triage Tab: Of questionable value, but originally conceoved to help the user identify broken pairs of A/V that need to be merged or repaired. Also aids in duplicate detection and reducing the number of copies. Identify junk, delete junk, etc.

Archive Tab: Shows the media by decades and years with tahs and highlights indicating events like birthday and vacations, christmas and thanksgiving, etc. 

Family Tree Tab: shows the family tree as downloaded from FamilySearch.org via gedcom files. It has the merge of the Hudson and Breen family trees, allows for notes, research, and much more. I can fill in more here as needed...

Hallie: Is a way to query the database and get audio feedback. the idea is to be an agentic interfacte to the family tree and catalog. The agent is modeled on an archive librarian and in this case, Hallie is my great grandmother and her avatar is based on restored photos of her. Tha family archivist avatar can be changed but currently Hallie has been worked out pretty well and is the defalult. Hallie primarily responds to family tree questions and finds videos in the archive and catalog. 

1.1 Media 
The app is focused on the Breen family multimedia from 1940s-present. It facilitates the ingestion of media, analyzes the media, and manages the media, assisting the user in archiving important recordings of events like birthdays, holidays, vacations, and other special family events. 

1.2 Archive
The archive holds media deemed important enough to be stored robustly in a RAID with the intention of making it available for future generations. Imagine a great grandaughter looking at her grand grandfather from the 1980s in the year 2065 or something. This is for them, in many ways.

1.3 Family Tree
Holds the family tree and assists the user in researching members, bookmarking, looking at maps, biograhpical info, documents, birth certs, death certs, marriage certs, and allows for agentic or crawling of website such as archives for that person's location, say North Carolina in 1880s. Unique and important historic events are looked for by the app and, like event analyzer, we can search automatically and find association like "great great great grampa so-and-so- fought in the revolutionary war in America".

2. Workflow UI/UX 
The essential workflow for media is: INGEST -> MANAGE -> ARCHIVE
 The app helps the user identify the most important recordings so they can be archived to the most reliable storage which includes 1. RAID 2. Cloud 3. Offsite. This app facilitates and helps the user identify important family events and makes sure the best or master copy is copied to the RAID. The app does also ask / suggest user make a copy for the cloud and offsite but these are currently outside the scope of control of this app.

2.1 Database 
The underlying database is sqlite. the code must be rock solid and all best practices followed. Tests for corner cases and boundary cases must exist and be part of the automated testbed run overnight.

2.2 Agentic and Automated Event and Provenance Discovery
The app assists in analyzing, curating, estimating dates, people, events, and provenance, but the user must confirm. Any new media coming in should have a provenance gate that requests important provanance information which should be stored with that media. The app can try to retroactively create machine generated guesses at provanance but this must be called out as machin egernated needing human confirmation, but the machine has access to lots of metadata and compute power etc., to help the user with such.


3. Process
We use best-in-class and best practices for everything we do, within reason. We don't quite go to the extremes of a medical device which needs FDA approval, but we do follow strict process that detects bugs early, ensures we have tests, and we have gates such as code reviews to keep the code healthy. 

3.1 Testing
We use unit tests and expect code to be testable. We are focused on our code not the supporting framwork. We use code coverage analysis tools and the highest possible settings of the compiler to check the code. We use static analysis and any swift-lint tools, we also measure code complexity and plot how each module is doing, providing it with a grade A-D. We do not allow F to make it to the repo.

Test classes include unit, regression, performance or stress tests, UI, and integration. We always write unit tests and try for 90% coverage, focusing on app-specific logic not so must the outside frameworks or UIs which we cannot control. Regressions tests are always written when a bug is found and fixed. We use the red-green approach of demonstrating the bug, showing the fail, inserting the fix, showing the pass, PROVING the bug fix and also preventing the bug from re-appearing since regressions tests are included in nightly automation.  Performance or Stress tests can be used as needed to either demonstrate bottlenecks, demonstrate fixes to bottlenecks, identify threading issues, or overal performance problems.

Hardware and Memory are available for as much testing as needed. The m4 max has 64GB and the Ultra 96 GB, we will utilize the hardware as much as possible for the App, for testing, for LLMs etc. For example, when we're doing rapid dev, we use an xcode ram cache. The app uses ram cache for scanning. The app can allocat ram generously to improve performance. 

We Melt Silicon is a team motto we somtimes use to indicate we are using the RAM, CPU, GPU, ANE, and all cores inasmuch as possible, including metal, mlx, and more. If a technology exists on macos we will get it if it helps us. We will scan GH open source for any helping code models. We will follow best practices for robust and fast processing.

Note also the systems are backed up on a UPS so the external drives and computers are not subject to sudden loss of power.

Automation, Automation, Automation, ie, we use state of the art overnight methods to improve and ensure the robustness and integrity of the code.

3.2 Metrics
We have a series of best-in-class metrics and an associated web page where we plot our progress. See the metrics page.

3.3 Automation
We use as much automation as possible for testing. Any bug has a regression test which can demonstrate the failure before an after fix using red/green approach. 

3.4 Code Reviews
Codex will perform adversarial code reviews, scoped and focused so as not to get sidetracked and after several iterations Claude must decide that it is good enough for now, ie, incremtnal progress is important. If an issue is seen by codex or testing and we still want to proceed we can file a GH issue and circle back.

3.6 Bug Reports
GH Issues will be filed on GH and we will use p0 for severe and p1 for critical, etc. The bug reports should be reviewed weekly.

3.7 Nightly Automation and Themes
We will take advantage of the night time cycle to perform as much automated testing as possible, providing a detailed report via code metrics page in the morning for the CTO, Rick, to review. The overnight themes are usually hardening, where a particular module or problem is attacked by claude and codex as reviewer so that by morning the app has 1. been tested thoroughly with metrics posted 2. hardening theme of the night completed and tests added as needed.

3.8 Development Modes
We work in three modes. The mode in force is said at the start of a session, and it decides what runs, where it runs, and when the gate is paid. (Mechanics: docs/PROCESS.md §Modes; rulings of 2026-10-24 in docs/DECISIONS.md.)

1. Rapid Dev (RD). Rick and Claude work on main together, in the foreground. Claude edits; Rick builds (Debug), runs, debugs and spot-tests in Xcode; no test runs between look-and-tweak rounds. The first pass of a change still ships its red/green tests, and one sensor-lane run is made when Rick says "happy". This is the mode for UI and workflow work, where the judgement is Rick's eye against Apple HIG and best-in-class apps.

2. Automated Dev. Rick talks to Claude in the foreground; the work runs in the background. Claude plans and merges; worker agents take file-disjoint slices in their own git worktrees with their own DerivedData, never on Rick's checkout, and every slice pays the full gate before merge: related suites green with counts, the sensor lane GREEN (it carries the warning ratchet), a Codex pass on data-risk code. Rick's machine stays responsive; long builds and whole suites go to the fleet. This is the mode for carrying out a plan that is already written — a design doc, a migration stage, a backlog item — and Rick's part is rulings and spot tests, not waiting.

3. Overnight Themes. 02:00 on the fleet, never on Rick's machine: the full suites, the gauntlet, metrics, the static-analysis lane, and one hardening theme — a module or a problem attacked by Claude with Codex as the adversarial reviewer, tests added as the proof. Nothing deletes overnight except scratch; the checkout is on main by 02:00; by morning the metrics page, the session-start lines and the Swift 6 progress figure show what the night did, and the P0/P1 counts say what the day owes.

The mode changes only WHEN the gate is paid, never WHETHER: a change that reaches main has its tests, its sensor-lane GREEN and, where it touches family media or its records, its Codex verdict, in every mode.

4. Architectiure and Design
Modularity, Object-Orientation, and state-of-the-art software development design patterns will be used. algorithms and libraries of known good quality witll be used rather than home grown code. 

4.1 Languages used include Swift, Python, Shell, and if needed C/C++ on Macos
4.2 Swift
The app is written in swift (6 if possible) using best practives and best-in-class per apple guidelines for macos 27 and xcode 27. 
• Swift Concurrency (async/await) and Actor model strategy.
	• The UI must run on the @MainActor.
	• Ingestion, local AI processing (Hallie's pipeline), and SQLite writes must be explicitly assigned to background processing Task groups or custom background Actors to keep the app responsive.

4.3 Python and Shell
The app invokes python and shell and relies heavily on ffmpeg, vlc, and other open source to handle media files.

4.4 Code Style & Linting Constraints
• All generated code must compile under Swift’s strictest compiler configuration: Strict Concurrency Checking set to Complete.
• The project enforces explicit formatting rules via swiftlint. No structural force-casts (as!) or force-unwraps (!) will pass code review.
• All business logic and formatting operations must be designed to be side-effect-free, enabling direct unit testability without relying on mocking frameworks.

4.5 Hardware and Use of Resources ... to the max.
• Memory Allocations: Implement multi-gigabyte RAM caching subsystems during intensive disk parsing operations, duplicate scanning loops, and catalog queries. Avoid premature disk swaps or memory-pinching configurations.
• Compute Utilization: Leverage multi-core distribution via Swift Concurrency TaskGroup frameworks. Dispatch math-heavy tasks, media indexing, and graph-traversal queries across the Apple Neural Engine (ANE) and GPU via Metal/MLX where native Swift optimization boundaries permit.


5. Database Architecture & SQLite Strategy

SQLite database is used with an abstraction layer to centralize call sites and make the DB technology a plugin. We use GRDB as an abstraction layer. The integrity of the database is of paramount importance. The app always reflects the reality underneath of the database to th euser so we can see what is going on. The app protects the user and the db from problems and human induced accidents or errors.

- WAL Mode for SQLite, ARC cyclic references ([weak self]), and Strict Concurrency set to Complete forces the LLM to write low-overhead, thread-safe code rather than single-threaded scripts shall be considered, ie, follow best practices for this.

- Boundaries to consider: Setting the distribution profile to "Developer ID / Unsandboxed" gives the LLM explicit authorization to generate native Process() and shell utility architectures for your Storage tab instead of writing empty UI placeholders. We're using Claude and other LLms for code generation and we expect these to follow best practices.

6. Provenance
According to the best in class INGEST -> MANAGE -> ARCHIVE workflow we would be very careful upon ingest of new media but since we have a lot of media already in the database we need to have a machine generated guess as to provenance, which can be confirmed by user. This is where the app can get creative, using any metadata, file information, audio transcripts, scene captions, user tags, and anything in the metadata to produce a guess as to this files ingest point, its master if possible, and it's journey. The user will work hard to look at this info and confirm. the app will work hard to correlate, extrapolate, and help the user fill in provenance information. This is an important primary value of the app.

6.1 Events Identification
The app may try to auto determine "this is a birthday", thanksgiving, christmas, holiday, vavatation, graduation, birth, etc. This may work in tandem with the above provenance. We would like to know the master file, for example, this master copy was ingested using a digitizer at max settings on july 4 2026. If possible we identify derivative material and/or duplicates. We can detect "same even" different codec for example. This is a nice win. We need to do more.

6.2 Family Tree and GEDCOM
<needs best advice here>

7. System Topology and Process Boundaries
7.1 Consider this a starting point for the top-level swift-oriented models in our software:
[Presentation Layer (SwiftUI)] <==> [@MainActor Observed Objects]
              ||
              ▼
[Domain Engine Layer] (Swift Concurrency / Strict Actor Isolation)
   ├── Ingest & Triage Core (AsyncSequence / Parallel Task Groups)
   ├── Local Ollama Broker (JSON Tool-Calling / Streaming URLSession)
   └── Hardware Diagnostic Engine (IOKit / Native BSD Darwin Bridges)
              ||
              ▼
[Persistence & Storage Layer]
   └── GRDB.swift Queue Hierarchy ==> SQLite3 (WAL Mode Enabled)


7.2 Resource Management & Threading Model
To ensure deterministic execution and prevent UI thread stalling, the codebase must strictly enforce Apple's modern structured concurrency:
• Threading Boundaries: All UI presentation logic is bound to the @MainActor. All heavy computational loops (ingestion, duplicate hashing, metadata crawling, and video parsing) must be isolated within dedicated background actor instances or spawned inside detached Task(priority: .background) closures.
• Memory Management: Swift uses Automatic Reference Counting (ARC). To prevent cyclic reference leaks (the C++ equivalent of shared_ptr cycles) during async callbacks, all escaping closures, event observers, and asynchronous task capture blocks must explicitly use [weak self] or [unowned self] guard patterns.


8 Ingest & Triage Core

• Concurrency Pattern: Implement data streaming ingestion using AsyncSequence or TaskGroup patterns to concurrently hash and index new files.
• Data Deduplication: File uniqueness is determined by a cryptographically secure hash (SHA-256) evaluated over the first and last 4MB chunks of a file to optimize for large video files.
• Error Handling: All pipeline transitions must use native Swift Result types or throws/catch patterns with strongly typed custom Error enums. Crashing patterns like try! or force-unwrapping optionals (!) are strictly prohibited.


9. Deterministic Tool-Calling / Agentic Interface for "Hallie" and Other Tools
9.1 This is advisory and can be discussed: It is a starting point...
To allow the LLM to query your media database and family tree reliably without generating hallucinated answers, the client must enforce native JSON Tool Calling Schemas.
• Schema Enforcement: The OllamaClient must include a strict tools payload array in its JSON request envelope, explicitly defining the Swift application's internal functions as callable schema tools.
• Tool Execution Pipeline:
	1. Intent / Arguments Parsing: When Ollama returns a tool_calls object instead of content text, the OllamaClient catches the payload, maps the JSON arguments to native types, and validates constraints.
	2. Isolated Execution: The app dispatches the required database task to the background database queue (via GRDB).
	3. Context Injection: The tool result is wrapped back into a standard tool role message envelope and fed back to Ollama to synthesize the final natural-language response.

9.2 Explicit Tool Schemas to Code via LLM:

• query_family_tree(sql_query: String): Allows the model to pull structured GEDCOM relations (e.g., “Who are the four sons of Rick Breen?”).
• search_media_catalog(keyword: String, decade: Int?): Triggers a type-safe index search across database media tags.

9.3  Hallie Persona & Text-to-Speech (TTS) Interception

• Streaming Triage: The HallieAgent actor must analyze incoming tokens in real-time. Text responses must filter out raw markdown tags or structural JSON before piping the plain text directly into AVSpeechSynthesizer via streaming text-to-speech buffers.
• Backpressure Handling: The audio feedback loop must catch token delivery speeds exceeding verbal articulation capabilities, utilizing a ring-buffer strategy to queue text blocks without dropping or overlapping audio outputs.

10. Logging
Logging is critical for the ability to audit or reconstruct a sequence of events, for debugging, and overall historical information regarding the disposition of media and the behavior of the app. State of the art logging is almost an artform, but good logging is critical and all modules must consider how the log so as to allow events to be reconstructed and where media has gone, status of the database, recovery from critival errors etc.

11. KISS Principle and other mottos

Elegant design is an art almost but we're engineers ... anyway we do our best and always consult BPs and state-of-the-art solutions. Most problems already have solutions so we're just making sure we're using best-in-class templates and code examples already well proven.

Test and Measurement is critical