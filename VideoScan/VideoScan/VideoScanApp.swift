//
//  VideoScanApp.swift
//  VideoScan
//
//  Created by rickb on 3/15/26.
//

import SwiftUI
import AppKit
import os

/// Quit-path diagnostics — `log stream --predicate 'subsystem ==
/// "Rick-Breen.VideoScan" && category == "shutdown"'` to watch a quit.
private let shutdownLogger = Logger(subsystem: "Rick-Breen.VideoScan", category: "shutdown")

// MARK: - App Lifecycle Log (DI via LogSink)
//
// Persistent file at ~/Library/Logs/VideoScan/videoscan.log — accumulates
// across launches so you can read "started X, quit Y, started Z" history
// by `tail` or Console.app. Distinct from per-scan PersistentLog instances
// (which truncate per job) and from the macOS unified log (`log show`).
//
// `appLog` is typed as `LogSink` (a protocol — see LogSink.swift) so test
// code can swap in NullLogSink / InMemoryLogSink without touching the 30+
// production call sites. In production this is a `PersistentLog` writing
// to videoscan.log. Under a test host this defaults to `NullLogSink` so
// even forgotten test-side injection can't pollute the user's real log.
//
// Why `var` and not `let`: tests need to overwrite this from
// `LogSinks+Test.swift` to inject an InMemoryLogSink for content
// assertions. The production code never mutates it after init.
//
// Swift's top-level `var` is roughly a C++ namespace-scope variable
// with a lazy initializer — first access runs the closure, then
// caches the result.
nonisolated(unsafe) var appLog: LogSink = makeDefaultAppLog()

/// Builds the default sink for the global `appLog`. Returns a
/// production `PersistentLog` opened on videoscan.log, OR a discarding
/// `NullLogSink` if we detect we're being hosted by XCTest / Swift
/// Testing. Test code is still expected to inject an `InMemoryLogSink`
/// when it wants to assert on output — the NullLogSink is just the
/// safe-by-default fallback so a forgotten injection can't write to
/// the user's real videoscan.log.
private func makeDefaultAppLog() -> LogSink {
    if appLogIsRunningUnderTests {
        return NullLogSink(name: "videoscan-null")
    }
    let log = PersistentLog(name: "videoscan")
    log.start(append: true)
    return log
}

/// Mirrors CatalogStore.isRunningTests so the default appLog sink is
/// consistent with the codebase's other test-environment checks.
private let appLogIsRunningUnderTests: Bool = {
    if NSClassFromString("XCTestCase") != nil { return true }
    let env = ProcessInfo.processInfo.environment
    if env["XCTestConfigurationFilePath"] != nil { return true }
    if env["XCTestBundlePath"] != nil { return true }
    if env["SWIFT_TESTING_ENABLED"] != nil { return true }
    if env["VS_UI_TEST"] == "1" { return true } // UI-test target — see TestEnvironment.detect
    if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
        return true
    }
    return false
}()

// MARK: - App Delegate (RAM disk lifecycle)

/// We use an NSApplicationDelegate solely so we can:
///   1. Reap any orphaned VideoScan_Temp RAM disks left over from a previous
///      launch that crashed or was force-quit before unmount could run.
///   2. Force-detach our RAM disk on a normal Cmd-Q so we never leak one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by VideoScanApp at launch so the delegate can flush the catalog
    /// snapshot synchronously on Cmd-Q.
    weak var catalogModel: VideoScanModel?

    /// Set by VideoScanApp at launch — the quit guard below consults it
    /// so a Cmd-Q can't silently kill in-flight file operations.
    weak var fileOpsCenter: MediaFileOperationsCenter?

    /// Set by VideoScanApp at launch — the quit path drains in-flight
    /// VLM (MLX) inference before letting termination proceed, so
    /// `exit()` never tears down Metal underneath running GPU work.
    /// See MLXShutdown.swift for the full crash story.
    weak var captionOrchestrator: CaptionOrchestrator?

    /// Max seconds applicationShouldTerminate waits for the VLM batch
    /// to drain. A single Qwen2.5-VL generation step is sub-second;
    /// the cooperative cancel usually lands within one frame's
    /// inference, so 5s is generous without making Cmd-Q feel hung.
    static let vlmDrainDeadline: TimeInterval = 5.0

    /// True when the quit-time VLM drain hit its deadline. willTerminate
    /// then SKIPS the MLX stream synchronize (it would block behind the
    /// still-running generation) and relies on the `_exit` backstop.
    private var vlmDrainTimedOut = false

    /// True when the app is launched as a test host (unit tests).
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Second check covers the UI-test target (VS_UI_TEST=1): the app
        // under XCUITest runs this delegate for real, and the RAM-disk
        // reap below force-detaches EVERY /Volumes/VideoScan_Temp* —
        // including one belonging to a concurrently running production
        // instance. Skip all launch side effects under UI tests.
        guard !Self.isRunningTests, !TestEnvironment.isTestHost else { return }
        let startLine = "app started — \(BuildInfo.summary) (pid \(ProcessInfo.processInfo.processIdentifier))"
        NSLog("VideoScan: %@", startLine)
        appLog.write(startLine)

        // Install the MLX safety net BEFORE any MLX code runs. This is
        // the belt-and-suspenders global handler — per-call runMLX
        // wrappers (see MLXSafety.swift) are the primary defense, but
        // any forgotten call site will fall through to this handler
        // instead of SIGTRAP. Skipped under tests; tests that need it
        // call installMLXSafetyNet() explicitly.
        installMLXSafetyNet()

        // Last-gasp signal handler: writes to videoscan.log on SIGSEGV/SIGBUS/
        // SIGFPE/SIGILL/SIGABRT, then re-raises for the system crash report.
        // Skipped when appLog isn't file-backed (e.g. NullLogSink under tests)
        // — there's nowhere to write and AppDelegate already guards against
        // running under tests anyway.
        if let logPath = appLog.fileURL?.path {
            logPath.withCString { VSInstallCrashGuard($0) }
        }

        let detached = RAMDisk.cleanupStaleMounts()
        if !detached.isEmpty {
            NSLog("VideoScan: reaped %d orphaned RAM disk(s) from previous run: %@",
                  detached.count, detached.joined(separator: ", "))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowHelper.shared.openMainWindow()
        }
        return true
    }

    /// Quit guard, two stages:
    ///   1. If Media File Operations jobs are still running, confirm
    ///      before quitting, then cancel them so any ffmpeg children
    ///      die (ProcessRunner's cancellation handler terminates them).
    ///   2. If a dossier/VLM (MLX) batch is in flight, return
    ///      `.terminateLater`, cancel the batch, and drain it with a
    ///      bounded wait before replying. We use `.terminateLater`
    ///      rather than a synchronous wait in willTerminate because the
    ///      batch task hops through the MainActor for status writes —
    ///      blocking the main thread on the drain would deadlock it.
    ///      `.terminateLater` keeps the runloop alive while the drain
    ///      awaits; the reply is guaranteed within `vlmDrainDeadline`.
    /// Extends — doesn't replace — the existing willTerminate cleanup.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // UI-test target (VS_UI_TEST=1): quit immediately, no alerts —
        // nothing real is running and a modal would hang the test runner.
        guard !Self.isRunningTests, !TestEnvironment.isTestHost else { return .terminateNow }
        // Delegate callbacks arrive on the main thread; assumeIsolated
        // lets us touch the MainActor-bound center and NSAlert without
        // an async hop (same pattern as applicationWillTerminate).
        return MainActor.assumeIsolated {
            if let center = fileOpsCenter, center.runningCount > 0 {
                let running = center.runningCount

                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = running == 1
                    ? "A file operation is still running"
                    : "\(running) file operations are still running"
                alert.informativeText = "Quitting now will stop the work in progress. Anything already finished is safe."
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Keep Working")

                if alert.runModal() == .alertFirstButtonReturn {
                    center.cancelAll()
                } else {
                    return .terminateCancel
                }
            }

            // Quit is committed past this point (fileops either idle
            // or cancelled). Latch the orchestrator's shutdown flag
            // NOW, even if no batch is active — a fast Cmd-Q during
            // the DossierAutoResume launch delay would otherwise take
            // the .terminateNow path with the latch unset, and the
            // deferred auto-resume could start fresh VLM inference
            // mid-teardown. drainForShutdown latches too; this covers
            // the nothing-active path.
            captionOrchestrator?.beginShutdown()

            // VLM drain: cancel + bounded wait so MLX stops dispatching
            // GPU work before AppKit tears Metal down around it
            // (crash variant VideoScan-2026-06-11-232946.ips).
            if let orch = captionOrchestrator, orch.currentStatus.isActive {
                shutdownLogger.notice("quit requested with VLM batch active — draining (max \(Self.vlmDrainDeadline, format: .fixed(precision: 1))s)")
                appLog.write("shutdown: cancelling dossier/VLM batch, draining in-flight inference")
                Task { @MainActor [weak self] in
                    let drained = await orch.drainForShutdown(deadline: Self.vlmDrainDeadline)
                    self?.vlmDrainTimedOut = !drained
                    appLog.write(drained
                        ? "shutdown: VLM drain completed"
                        : "shutdown: VLM drain deadline expired — proceeding, _exit backstop covers teardown")
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let quitLine = "app quitting — \(BuildInfo.summary)"
        NSLog("VideoScan: %@", quitLine)
        appLog.write(quitLine)
        MainActor.assumeIsolated {
            // Belt-and-suspenders: a termination path that skipped
            // applicationShouldTerminate (rare) could still have a VLM
            // batch active. We can't block on a drain here (MainActor
            // deadlock — see applicationShouldTerminate), so request
            // cancellation and treat it as a timed-out drain: skip the
            // stream synchronize, rely on the _exit backstop.
            captionOrchestrator?.beginShutdown()
            if let orch = captionOrchestrator, orch.currentStatus.isActive {
                shutdownLogger.error("willTerminate with VLM batch still active — cancelling, deferring to _exit backstop")
                orch.cancel()
                vlmDrainTimedOut = true
            }
            // Flush the catalog snapshot first so the user's records
            // survive an offline-volume relaunch.
            catalogModel?.saveCatalogNow()
        }
        // Synchronous on purpose — Cmd-Q must not return before the RAM disk
        // is gone, otherwise it survives in /Volumes. Skipped under a UI-test
        // target: the test app never creates a RAM disk, and the force-detach
        // would hit a live one owned by a concurrently running real instance.
        if !TestEnvironment.isTestHost {
            let detached = RAMDisk.cleanupStaleMounts()
            if !detached.isEmpty {
                NSLog("VideoScan: detached %d RAM disk(s) on exit", detached.count)
            }
        }

        // MLX teardown (see MLXShutdown.swift). Only when in-process
        // VLM inference actually ran this session.
        if mlxInferenceWasUsed() && !Self.isRunningTests {
            if !vlmDrainTimedOut {
                // Flush queued GPU work while Metal is still healthy.
                synchronizeMLXForShutdown()
            }
            shutdownLogger.notice("MLX used this session — bypassing C++ static destructors via _exit(0)")
            appLog.write("app exit (clean, MLX static-dtor bypass)")
            appLog.flush()
            // MLX's static Scheduler destructor segfaults in
            // __cxa_finalize (Metal waitUntilCompleted after teardown)
            // — see crash reports 2026-06-11/12. All persistence above
            // is explicit (saveCatalogNow is synchronous, appLog is
            // write-through, UserDefaults lives in cfprefsd), so
            // skipping ALL static destructors is safe here.
            _exit(0)
        }
    }
}

// MARK: - Build Info

enum BuildInfo {
    static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build: String   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    static let buildDate: String = {
        // __DATE__ and __TIME__ aren't available in Swift, so use the
        // bundle executable's creation date as a proxy for "when did I
        // last build this". Accurate enough to answer "am I running the
        // build I just made?".
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let date = attrs[.creationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            return fmt.string(from: date)
        }
        return "unknown"
    }()

    /// Git branch baked in at build time via `#filePath`. Walks up from
    /// this source file to find `.git/HEAD`. Works for Debug and Release
    /// builds as long as the app runs on the machine that built it (the
    /// source path is embedded in the binary via #filePath).
    /// Returns "unknown" if the source tree isn't reachable (e.g. a build
    /// shipped to another machine).
    static let gitBranch: String = {
        var url = URL(fileURLWithPath: #filePath)
        // Up to 8 levels should cover any reasonable project layout.
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if url.path == "/" { break }
            let gitDir = url.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitDir.path) else { continue }
            let head = gitDir.appendingPathComponent("HEAD")
            guard let contents = try? String(contentsOf: head, encoding: .utf8) else { break }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "ref: refs/heads/"
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
            // Detached HEAD — show the first 8 chars of the SHA.
            return "detached@\(trimmed.prefix(8))"
        }
        return "unknown"
    }()

    static let buildMode: String = {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }()

    static let summary: String = "v\(version) (\(buildMode)) · \(gitBranch) · \(buildDate)"
}

struct VideoScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var catalogModel = VideoScanModel()
    /// Read-only catalog sync between Rick's Macs. The master writes
    /// manifest.sha256 after every save; viewers rsync the catalog +
    /// POI tree on launch and on manual Refresh, verify the manifest,
    /// and atomically swap into place. See CatalogSync.swift.
    @StateObject private var catalogSync = CatalogSync.production()
    /// Lifted from ContentView to app level so the separate Dossier
    /// Dashboard window can observe the same in-flight state. Lazy MLX
    /// model load is unchanged — the model container only loads on the
    /// first `caption()` / `dossier()` call.
    @StateObject private var captionOrchestrator = CaptionOrchestrator()

    /// Lifted to app level too — the Compare window scene needs to
    /// observe the same running rescue task that the main window's
    /// toolbar chip observes. Was on ContentView when Compare was a
    /// modal sheet; promoted here once Compare became its own Window.
    @StateObject private var volumeRescue = VolumeRescueOperation()

    /// Registry for the Media File Operations window's new-style jobs
    /// (compare today, extract in phase 2). App-level so the catalog
    /// context menu, the operations window, and the quit guard all see
    /// the same instance — jobs survive the window closing.
    @StateObject private var fileOpsCenter = MediaFileOperationsCenter()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowCapture {
                ContentView()
                    .environmentObject(catalogModel)
                    .environmentObject(catalogModel.dashboard)
                    .environmentObject(catalogSync)
                    .environmentObject(captionOrchestrator)
                    .environmentObject(volumeRescue)
                    .environmentObject(fileOpsCenter)
                    .onAppear {
                        appDelegate.catalogModel = catalogModel
                        appDelegate.fileOpsCenter = fileOpsCenter
                        // Quit path drains in-flight VLM inference —
                        // see AppDelegate.applicationShouldTerminate.
                        appDelegate.captionOrchestrator = captionOrchestrator
                        // Volume classification for per-volume read
                        // gating (HDD = one compare at a time): longest
                        // matching scan-target prefix wins; no match →
                        // .unknown (gate allows 2).
                        fileOpsCenter.mediaTechForPath = { [weak catalogModel] path in
                            guard let model = catalogModel else { return .unknown }
                            return model.scanTargets
                                .filter { !$0.searchPath.isEmpty && path.hasPrefix($0.searchPath) }
                                .max(by: { $0.searchPath.count < $1.searchPath.count })?
                                .mediaTech ?? .unknown
                        }
                        // Apply viewer-vs-master semantics to model + store.
                        catalogModel.applyReadOnlyMode(catalogSync.isReadOnly)
                        // On the master, install the observer that
                        // refreshes manifest.sha256 after each save.
                        // On a viewer, kick off the initial sync.
                        if catalogSync.mode == .master {
                            catalogModel.catalogStore.observer = catalogSync
                            // Seed the manifest once at launch so a
                            // viewer that connects before the master
                            // has saved anything still has something
                            // to verify against.
                            catalogSync.writeManifestIfMaster()
                        } else {
                            // Initial sync at launch — pulls the
                            // latest catalog from M4 if the master is
                            // reachable. Auto-refresh below keeps it
                            // current after that.
                            Task { await catalogSync.syncFromMaster() }
                            catalogSync.startViewerAutoRefresh()
                        }
                        // Live dossier reload — picks up new dossier
                        // results written to catalog.json by external
                        // workers (scripts/dossier_batch.py + merger)
                        // without quitting the app. Polls every 30s.
                        // On viewers, this composes with the auto-
                        // refresh above: the rsync pulls a fresh
                        // catalog.json, then this poll picks up the
                        // dossier-channel changes from disk into
                        // in-memory records.
                        catalogModel.startLiveDossierReload()

                        if !TestEnvironment.isTestHost,
                           !catalogSync.isReadOnly,
                           UserDefaults.standard.bool(forKey: "DossierAutoResume") {
                            Task {
                                try? await Task.sleep(for: .seconds(3))
                                guard !Task.isCancelled else { return }
                                // Per-volume auto-resume (Rick 2026-06-13).
                                // Pick up every volume that had a batch in
                                // flight when the app last quit and run them
                                // serially in path order. Phase 1: one at a
                                // time. Falls back to the global pass when
                                // no per-volume work was recorded (legacy
                                // catalogs migrating from the old single-
                                // batch model).
                                let pending = captionOrchestrator.activeVolumePrefixes.sorted()
                                if pending.isEmpty {
                                    await captionOrchestrator.startCatalogWideDossier(model: catalogModel)
                                } else {
                                    for prefix in pending where !Task.isCancelled {
                                        await captionOrchestrator.startAnalyzing(
                                            volumePrefix: prefix,
                                            model: catalogModel
                                        )
                                    }
                                }
                            }
                        }
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(replacing: .appSettings) {
                SettingsMenuItem()
            }
            // Anchor on .newItem (which always has the default Close item
            // in non-document SwiftUI apps). Anchoring on .saveItem looks
            // correct semantically but silently no-ops when no Save group
            // exists — the symptom Rick saw: File menu had only New and
            // Close.
            CommandGroup(after: .newItem) {
                Divider()
                // One backup action, two entry points (2026-07): this menu
                // item and the badge in the catalog header both run
                // exportBundleViaPanel() — the whole-shebang bundle
                // (catalog + volume metadata + settings + POI photos).
                // The old partial menu items (Volume CSV, Catalog Only)
                // are gone from the menu; their functions remain in
                // VideoScanModel unreferenced, for scripted/diagnostic use.
                Button("Back Up Catalog…") {
                    catalogModel.exportBundleViaPanel()
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Import Catalog…") {
                    catalogModel.importBundleViaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                WindowMenuItems()
            }
        }

        Window("About VideoScan", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Keep About out of the Window menu — it's reachable from
        // VideoScan ▸ About VideoScan and doesn't belong in the list of
        // working windows. (commandsRemoved strips the scene's auto-added
        // menu items; openWindow(id: "about") still works.)
        .commandsRemoved()

        Window("VideoScan Dashboard", id: "dashboard") {
            DashboardWindow()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("Analyze Dashboard", id: "dossier") {
            DossierDashboardView()
                .environmentObject(catalogModel)
                .environmentObject(captionOrchestrator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        // Compare Volumes — independent NSWindow rather than a modal sheet.
        // Reason: sheets are macOS-modal, which throttles the parent
        // window's event delivery and produces the beachball behavior Rick
        // hit during a multi-hour rescue copy (2026-06-07). The window
        // pattern matches Dossier Dashboard: non-modal, fully responsive,
        // user can interact with the main window while a copy is in flight.
        // `volumeRescue` is owned by ContentView's @StateObject so its
        // running task survives whether this window is open, closed, or
        // re-opened mid-copy.
        Window("Compare Volumes", id: "compare") {
            VolumeCompareSheet(model: catalogModel, rescue: volumeRescue)
                .environmentObject(catalogModel)
                .environmentObject(volumeRescue)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("VideoScan Console", id: "console") {
            ConsoleWindow()
                .environmentObject(catalogModel.dashboard)
        }
        .defaultPosition(.bottomTrailing)

        // Independent resizable window per-volume for "Catalog Info" — the
        // value-based WindowGroup reuses the window when the same volume is
        // re-opened (CatalogInfoItem.id == volume path) and shows side-by-side
        // windows for different volumes. Truly resizable, unlike .sheet.
        WindowGroup("Catalog Info", for: CatalogInfoItem.self) { $item in
            if let item {
                CatalogInfoWindow(item: item)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 560)

        // Media File Operations — the one window for every file-by-file
        // verb (combine, compare, extract-frames…). Evolved from the old
        // "Combine & Render" window; keeps the scene id "combine" so
        // existing openWindow(id:) call sites and the ⌘⇧R shortcut
        // keep working.
        Window("Media File Operations", id: "combine") {
            MediaFileOperationsWindow()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
                .environmentObject(fileOpsCenter)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 480)
        .defaultPosition(.center)

        Window("Settings", id: "settings") {
            SettingsTabView(
                settings: Binding(
                    get: { catalogModel.perfSettings },
                    set: { catalogModel.perfSettings = $0 }
                ),
                totalRAMGB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
            )
            .frame(minWidth: 500, idealWidth: 620, minHeight: 400, idealHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("Volumes", id: "volumes") {
            VolumesWindow()
                .environmentObject(catalogModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
        .defaultPosition(.center)
    }
}

struct AboutMenuItem: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("About VideoScan") {
            openWindow(id: "about")
        }
    }
}

struct SettingsMenuItem: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

struct WindowMenuItems: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Main Window") {
            MainWindowHelper.shared.openMainWindow()
        }
        .keyboardShortcut("0", modifiers: .command)

        Button("Dashboard") {
            openWindow(id: "dashboard")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Button("Console") {
            openWindow(id: "console")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Button("Media File Operations") {
            openWindow(id: "combine")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Volumes") {
            openWindow(id: "volumes")
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])

        Button("Analyze Dashboard") {
            DossierWindowOpener.open(using: openWindow, source: "menu")
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

/// Provides a way to reopen the main WindowGroup window from anywhere.
/// SwiftUI's WindowGroup destroys windows on close and `openWindow` only
/// works from a View's Environment. We capture the Environment action on
/// appear and stash it so non-View code (Dock click, menu) can use it.
@MainActor
final class MainWindowHelper {
    static let shared = MainWindowHelper()

    /// Captured from a View's @Environment(\.openWindow)
    var openWindowAction: OpenWindowAction?

    /// Known auxiliary window titles — anything else is the main window.
    private let auxiliaryTitles = ["Dashboard", "Console", "About", "Realtime", "Media File Operations"]

    func openMainWindow() {
        // First try to find and unhide an existing main window
        if let w = findMainWindow() {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // Otherwise ask SwiftUI to create a new one
        openWindowAction?(id: "main")
    }

    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first { w in
            // Skip known auxiliary windows and tiny/invisible ones
            !auxiliaryTitles.contains(where: { w.title.contains($0) })
            && w.contentView != nil
            && w.frame.width > 200
        }
    }
}

/// Thin wrapper that captures the SwiftUI openWindow environment action
/// so non-View code can reopen the main WindowGroup.
struct MainWindowCapture<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                MainWindowHelper.shared.openWindowAction = openWindow
            }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header collage — full image, nothing on top of the faces
            Image("AboutCollage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)

            // Title sits below the collage so both rows of family photos stay visible
            VStack(spacing: 4) {
                Text("VideoScan")
                    .font(.largeTitle.bold())
                    // XCUITest hook — SmokeUITests asserts the About window's
                    // content actually rendered, not just that a window with
                    // the right title exists.
                    .accessibilityIdentifier("about.title")
                Text("Find friends and family in all your home videos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AboutSection(icon: "heart.fill", color: .pink, title: "Catalogs your videos so you can search for people."){}

                    AboutSection(icon: "person.crop.rectangle.stack", color: .blue, title: "Repairs broken videos and updates them to a modern format.") {}

                    AboutSection(icon: "externaldrive.connected.to.line.below", color: .green, title: "Finds videos on attached storage or network drives.") {}

                    AboutSection(icon: "waveform.and.magnifyingglass", color: .purple, title: "Understands nearly all video formats and helps archive your favorite memories for the long-term.") {}

                    Divider()

                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("Developed By Rick.  Inspired by Donna.")
                                .font(.headline)
                            Text(BuildInfo.summary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "cpu.fill")
                                    .font(.system(size: 10))
                                Text(aboutChipName())
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                            Text("PolyForm Noncommercial 1.0.0 · Not for sale")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 620)
    }
}

private func aboutChipName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return "Apple Silicon" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? "Apple Silicon" : s
}

struct AboutSection<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder let content: () -> Content

    init(icon: String, color: Color, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon; self.color = color; self.title = title; self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                content()
                    .font(.body)
                    .foregroundColor(.primary.opacity(0.85))
            }
        }
    }
}

