//
//  VideoScanApp.swift
//  VideoScan
//
//  Created by rickb on 3/15/26.
//

import SwiftUI
import AppKit

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

    static let summary: String = "v\(version) · \(gitBranch) · \(buildDate)"
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
            CommandGroup(after: .saveItem) {
                Button("Export Volume Info…") {
                    catalogModel.exportVolumeInfo()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Export Catalog…") {
                    catalogModel.exportCatalogViaPanel()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])

                Button("Import Catalog…") {
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
    private let auxiliaryTitles = ["Dashboard", "Console", "About", "Realtime"]

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
            // Header
            ZStack(alignment: .bottom) {
                Image("AboutCollage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)

                // Title overlay
                VStack(spacing: 4) {
                    Text("VideoScan")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text("Find the people you love in your home videos")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .clipped()

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AboutSection(icon: "heart.fill", color: .pink, title: "What it does") {
                        Text("VideoScan finds persons in your media so you can organize memories by person or create a catalog for reference.")
                    }

                    AboutSection(icon: "person.crop.rectangle.stack", color: .blue, title: "How it works") {
                        Text("You provide a folder of photos (or pick from Apple Photos) and the app detects faces in videos and can compile new videos of that person.")
                    }

                    AboutSection(icon: "externaldrive.connected.to.line.below", color: .green, title: "Multi-volume, parallel scanning") {
                        Text("Add as many folders or network volumes as you like and the app scans in parallel.")
                    }

                    AboutSection(icon: "waveform.and.magnifyingglass", color: .purple, title: "Handles Any Video Format") {
                        Text("Supports 40+ video formats.")
                    }

                    Divider()

                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("Developed By Rick Breen.   Inspired by Donna.")
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

struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.secondary)
            Text(text)
        }
    }
}

