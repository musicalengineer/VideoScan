//
//  VideoScanApp.swift
//  VideoScan
//
//  Created by rickb on 3/15/26.
//

import SwiftUI
import AppKit

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

    /// True when the app is launched as a test host (unit tests).
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let startLine = "app started — \(BuildInfo.summary) (pid \(ProcessInfo.processInfo.processIdentifier))"
        NSLog("VideoScan: %@", startLine)
        appLog.write(startLine)

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

    func applicationWillTerminate(_ notification: Notification) {
        let quitLine = "app quitting — \(BuildInfo.summary)"
        NSLog("VideoScan: %@", quitLine)
        appLog.write(quitLine)
        // Flush the catalog snapshot first so the user's records survive
        // an offline-volume relaunch.
        MainActor.assumeIsolated {
            catalogModel?.saveCatalogNow()
        }
        // Synchronous on purpose — Cmd-Q must not return before the RAM disk
        // is gone, otherwise it survives in /Volumes.
        let detached = RAMDisk.cleanupStaleMounts()
        if !detached.isEmpty {
            NSLog("VideoScan: detached %d RAM disk(s) on exit", detached.count)
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

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowCapture {
                ContentView()
                    .environmentObject(catalogModel)
                    .environmentObject(catalogModel.dashboard)
                    .onAppear { appDelegate.catalogModel = catalogModel }
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
                // Whole-shebang bundle — the "make this Mac look like the
                // other one" entry point. Use this when moving between
                // Rick's Mac Studio and MBP.
                Button("Export Everything…") {
                    catalogModel.exportBundleViaPanel()
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Import Everything…") {
                    catalogModel.importBundleViaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                // Partial exports — kept for callers who want just the
                // catalog (smaller file, AirDrop-friendly) or just a CSV
                // summary of volume status.
                Button("Export Volume Info (CSV)…") {
                    catalogModel.exportVolumeInfo()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export Catalog Only…") {
                    catalogModel.exportCatalogViaPanel()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])

                Button("Import Catalog Only…") {
                    catalogModel.importCatalogViaPanel()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
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

        Window("VideoScan Dashboard", id: "dashboard") {
            DashboardWindow()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

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

        Window("Combine & Render", id: "combine") {
            CombineWindow()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 420)
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

        Button("Combine & Render") {
            openWindow(id: "combine")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Volumes") {
            openWindow(id: "volumes")
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
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
    private let auxiliaryTitles = ["Dashboard", "Console", "About", "Realtime", "Combine"]

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

