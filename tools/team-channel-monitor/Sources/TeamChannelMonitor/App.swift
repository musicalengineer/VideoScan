import AppKit
import SwiftUI

@main
struct TeamChannelMonitorApp: App {
    /// `TeamChannelMonitor --check` prints today's counts and exits: a way to
    /// verify the database opens from a given shell without a GUI.
    init() {
        guard CommandLine.arguments.contains("--check") else { return }
        let snap = ChannelDB.loadToday()
        if let error = snap.error {
            print("ERROR: \(error)")
            exit(1)
        }
        print("db: \(ChannelDB.path)")
        print("today: \(snap.rows.count) rows — \(snap.red) unanswered, \(snap.yellow) waiting, \(snap.green) answered")
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorView(model: model)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock tile
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = ChannelSnapshot()
    @Published var lastAction: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        snapshot = ChannelDB.loadToday()
    }

    func nudge(_ row: ChannelRow) {
        let result = ChannelCLI.nudge(row)
        lastAction = result.ok ? "Nudged \(row.recipient) about #\(row.messageID)" : "Nudge failed: \(result.output)"
        refresh()
    }

    func markHandled(_ row: ChannelRow) {
        let result = ChannelCLI.ackAsRick(row)
        lastAction = result.ok ? "Marked #\(row.messageID) handled" : "Ack failed: \(result.output)"
        refresh()
    }
}

struct MenuBarLabel: View {
    let snapshot: ChannelSnapshot

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: snapshot.red > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill"
                                                : "bubble.left.and.bubble.right")
            if snapshot.red > 0 {
                Text("\(snapshot.red)")
            }
        }
    }
}
