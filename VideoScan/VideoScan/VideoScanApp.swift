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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let detached = RAMDisk.cleanupStaleMounts()
        if !detached.isEmpty {
            NSLog("VideoScan: reaped %d orphaned RAM disk(s) from previous run: %@",
                  detached.count, detached.joined(separator: ", "))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
    #if DEBUG
    static let configuration = "Debug"
    #else
    static let configuration = "Release"
    #endif
    static let buildDate: String = {
        // __DATE__ and __TIME__ aren't available in Swift, so use the compilation
        // date of this file by reading its own modification via the embedded timestamp.
        // Best-practice alternative: Xcode build phase sets BUILD_DATE in Info.plist.
        // For now, use the bundle's executable creation date as a proxy.
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let date = attrs[.creationDate] as? Date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            return fmt.string(from: date)
        }
        return "unknown"
    }()
    static let summary: String = "v\(version) (\(build)) · \(configuration) · \(buildDate)"
}

@main
struct VideoScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var catalogModel = VideoScanModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(catalogModel)
                .environmentObject(catalogModel.dashboard)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
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

struct WindowMenuItems: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
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

