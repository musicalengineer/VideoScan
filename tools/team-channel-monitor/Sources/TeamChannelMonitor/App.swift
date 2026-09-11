import AppKit
import SwiftUI

@main
struct TeamChannelMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MonitorModel()

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

    /// A status item shows real colour only from a NON-template NSImage
    /// (the flag CyberPower/Adobe set); SF Symbols and SwiftUI text are
    /// template-tinted. So the state is a hand-drawn badge: grey bubble
    /// when nothing is outstanding, yellow "2" when two are waiting, red
    /// "2!" when any is unanswered past 15 minutes.
    var body: some View {
        Image(nsImage: StatusBadge.image(red: snapshot.red, yellow: snapshot.yellow))
    }
}

enum StatusBadge {
    static func image(red: Int, yellow: Int) -> NSImage {
        let outstanding = red + yellow
        let text = outstanding == 0 ? "" : (red > 0 ? "\(outstanding)!" : "\(outstanding)")
        // Colours chosen to read on both light and dark menu bars.
        let fill: NSColor = red > 0 ? NSColor(srgbRed: 0.86, green: 0.16, blue: 0.16, alpha: 1)
            : yellow > 0 ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.10, alpha: 1)
            : NSColor(white: 0.55, alpha: 1)
        let height: CGFloat = 18
        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let width = text.isEmpty ? height : max(height, textSize.width + 10)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
            fill.setFill()
            path.fill()
            if text.isEmpty {
                // Idle: a small hollow bubble.
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
                inner.lineWidth = 2
                inner.stroke()
            } else {
                let origin = NSPoint(x: (rect.width - textSize.width) / 2,
                                     y: (rect.height - textSize.height) / 2 + 0.5)
                (text as NSString).draw(at: origin, withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false   // keep the colour
        return image
    }
}
