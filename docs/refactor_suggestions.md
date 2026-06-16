Findings

  1. High: scan probe work is still implicitly @MainActor.
     VideoScan/VideoScan/VideoScanModel.swift:10 is @MainActor, but VideoScan/VideoScan/VideoScanModel+ProbeEngine.swift:24, VideoScan/VideoScan/
     VideoScanModel+ProbeEngine.swift:150, and VideoScan/VideoScan/VideoScanModel+ScanExecution.swift:28 are not marked nonisolated despite comments saying the probe engine runs
     off-main. With SWIFT_APPROACHABLE_CONCURRENCY = YES in VideoScan/VideoScan.xcodeproj/project.pbxproj:439, plain nonisolated async helpers can also inherit the caller’s
     actor. This risks serializing probe orchestration and running filesystem/hash/ffprobe setup through the UI actor. Best next step: extract a sendable ProbeEngine service or
     mark worker entry points @concurrent nonisolated, passing only value snapshots plus explicit @MainActor progress closures.

  2. High: per-file probe timeout may not actually bound stuck I/O.
     VideoScan/VideoScan/VideoScanModel+ProbeEngine.swift:279 races probeFile against sleep, but the losing child can be stuck in synchronous reads such as VideoScan/VideoScan/
     VideoScanModel+ProbeEngine.swift:472 or process/ffprobe work at VideoScan/VideoScan/VideoScanModel+ProbeEngine.swift:405. Throwing out of a task group still waits for child
     cleanup, so a blocked read can defeat the 300s timeout. Use subprocess-level timeouts for ffprobe and avoid cancellable task-group races around blocking POSIX reads unless
     the blocking work itself has a deadline or runs in a disposable subprocess.

  3. High: subprocess handling is fragmented, so cancellation semantics vary.
     ProcessRunner is the best abstraction, but key paths still hand-roll Process: VideoScan/VideoScan/CombineEngine.swift:20, VideoScan/VideoScan/IdentifyFamilyModel.swift:197,
     and VideoScan/VideoScan/PersonFinderCompilation.swift:247. Some use waitUntilExit, some only terminate, some do not drain both pipes after termination. This is a real
     behavioral risk for long ffmpeg/python jobs. Consolidate on one runner that drains both streams, supports line callbacks, escalates from terminate to kill after a grace
     period, and is injectable in tests.

  4. Medium: unsafe cross-actor mutable state is concentrated in ScanJob.
     VideoScan/VideoScan/PersonFinderModel.swift:107, VideoScan/VideoScan/PersonFinderModel.swift:108, VideoScan/VideoScan/PersonFinderModel.swift:127, and VideoScan/VideoScan/
     PersonFinderModel.swift:156 use nonisolated(unsafe). The previewRate comment relies on ARM64 atomicity, but Swift’s data-race model still needs synchronization. Prefer a
     small actor or ManagedAtomic for live knobs, and keep recognition output behind @MainActor snapshots passed into compilation.

  5. Medium: published model state is over-broad and manually invalidated.
     VideoScanModel has many unrelated @Published fields from VideoScan/VideoScan/VideoScanModel.swift:12 through UI routing/progress state, plus manual invalidation like
     VideoScan/VideoScan/VideoScanModel.swift:116. CatalogScanTarget repeats the pattern with many published fields at VideoScan/VideoScan/Models.swift:1357. This makes SwiftUI
     invalidation hard to reason about. Safest decomposition: keep VideoScanModel as an app coordinator, but move scan targets, catalog selection/routing, backup status, and
     operation progress into smaller @MainActor ObservableObjects.

  6. Medium: VideoRecord is doing too many jobs as a mutable reference type.
     VideoScan/VideoScan/Models.swift:121 mixes probe metadata, archive state, duplicate state, people tags, captions, provenance, UI colors, and persistence. The manual clone
     warns that every new field must update four places at VideoScan/VideoScan/Models.swift:764, and background save safety depends on @unchecked Sendable in VideoScan/VideoScan/
     CatalogStore.swift:489. Decompose by value-type subrecords first: probe metadata, user annotations, archive/provenance, and derived UI state. Keep Codable compatibility by
     nesting without changing top-level JSON until migrations are ready.

  7. Low: ContentView.swift is too large to safely evolve.
     VideoScan/VideoScan/ContentView.swift:167 spans most of a 2151-line file and owns filtering, scan-target UI, sheets, table actions, backup badge, and window routing. This is
     not immediately broken, but it raises regression risk. Split along existing boundaries: CatalogTabView, ScanTargetsPane, VolumeTable, CatalogToolbar, and BackupStatusBadge.

