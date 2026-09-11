import SwiftUI

struct MonitorView: View {
    @ObservedObject var model: MonitorModel

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if let error = model.snapshot.error {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if openRows.isEmpty {
                Text("Nothing outstanding.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // A ScrollView inside a MenuBarExtra window collapses to
                // nothing unless it is given a height: room for ~5 rows
                // by default, growing with the list up to a cap.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(openRows) { row in
                            RowView(row: row, model: model)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 5 * 34, maxHeight: 560)
                .frame(height: min(CGFloat(max(openRows.count, 5)) * 34 + 8, 560))
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 680)
    }

    /// Answered rows are noise; only unanswered and waiting ones are shown.
    private var openRows: [ChannelRow] {
        model.snapshot.rows.filter { !$0.status.isGreen }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Team Channel — open today").font(.headline)
            Spacer()
            Counter(color: .red, count: model.snapshot.red, label: "unanswered")
            Counter(color: .yellow, count: model.snapshot.yellow, label: "waiting")
            Text("\(model.snapshot.green) answered").font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var footer: some View {
        HStack {
            Text(model.lastAction ?? "Red = unanswered after 15 min. Nudge posts a message from you.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("checked \(Self.clock.string(from: model.snapshot.fetchedAt))")
                .font(.caption).foregroundStyle(.secondary)
            Button("Refresh") { model.refresh() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

private struct Counter: View {
    let color: Color; let count: Int; let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("\(count) \(label)").font(.callout).monospacedDigit()
        }
    }
}

private struct RowView: View {
    let row: ChannelRow
    @ObservedObject var model: MonitorModel
    @State private var expanded = false

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text("\(row.author) → \(row.recipient)")
                    .frame(width: 130, alignment: .leading)
                Text("#\(row.messageID)").monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                Text(Self.clock.string(from: row.createdAt)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(statusText)
                    .foregroundStyle(color == .red ? Color.red : Color.primary)
                    .frame(width: 150, alignment: .leading)
                Spacer(minLength: 8)
                action
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                Text(row.subject).font(.caption).bold().padding(.leading, 26)
                Text(row.body)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .help(row.body.prefix(600))
    }

    @ViewBuilder
    private var action: some View {
        switch row.status {
        case .answered:
            Color.clear.frame(width: 96, height: 1)
        case .waiting, .inProgress, .stuck:
            if row.recipient == "rick" {
                Button("Handled") { model.markHandled(row) }
                    .frame(width: 96)
            } else if let nudged = row.nudgedAt {
                Text("nudged \(Self.clock.string(from: nudged))")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 96)
            } else {
                Button("Tell \(row.recipient)") { model.nudge(row) }
                    .frame(width: 96)
            }
        }
    }

    private var color: Color {
        switch row.status {
        case .answered: return .green
        case .waiting, .inProgress: return .yellow
        case .stuck: return .red
        }
    }

    private var statusText: String {
        switch row.status {
        case .answered(let when):
            let how: String
            if let replied = row.repliedAt, replied <= (row.acknowledgedAt ?? .distantFuture) {
                how = "replied"
            } else {
                how = "acked"
            }
            return "\(how) \(Self.clock.string(from: when))"
        case .waiting(let age): return "waiting \(minutes(age))"
        case .inProgress(let age): return "in progress \(minutes(age))"
        case .stuck(let age): return "UNANSWERED \(minutes(age))"
        }
    }

    private func minutes(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
