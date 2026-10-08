import SwiftUI

// MARK: - The report card, drawn (Rick 2026-10-07)
//
// One view for every place a card appears — the Check Media job's detail
// and Get Media Info — so the two can't drift. Presentation only: it
// reads a MediaReportCard value and writes nothing.
//
// Large, readable text on purpose (.body / .callout, nothing smaller) —
// the GH #128 accessibility note.

struct MediaReportCardView: View {
    let card: MediaReportCard
    /// Show the evidence numbers under each row (the detail view does;
    /// a compact summary can turn them off).
    var showsEvidence = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(card.headline)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                MediaVerdictIcon(verdict: card.verdict)
            }
            .accessibilityIdentifier("checkMedia.headline")

            Text("\(card.tier == .full ? "Full" : "Quick") check, \(card.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(card.checks) { check in
                row(check)
            }
        }
    }

    @ViewBuilder
    private func row(_ check: MediaCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MediaVerdictIcon(verdict: check.verdict)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.kind.title).font(.callout.weight(.semibold))
                Text(check.sentence)
                    .font(.callout)
                    .foregroundStyle(isNotRun(check) ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsEvidence, !check.evidence.isEmpty {
                    Text(check.evidence.map { "\($0.label): \($0.value)" }.joined(separator: " · "))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !check.fix.isEmpty, check.verdict.rank >= MediaCheckVerdict.warning.rank {
                    Text("What to do: \(check.fix)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("checkMedia.row.\(check.kind.rawValue)")
    }

    private func isNotRun(_ c: MediaCheck) -> Bool {
        if case .notRun = c.verdict { return true }
        return false
    }
}

/// ✓ / ⚠︎ / ✕ / – for a verdict.
struct MediaVerdictIcon: View {
    let verdict: MediaCheckVerdict

    var body: some View {
        switch verdict {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .problem:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notRun:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// The Check Media row's double-click detail: every file and its card.
struct CheckMediaDetailView: View {
    @ObservedObject var job: CheckMediaJob

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(job.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcome(item.outcome)
                }
                if item.id != job.items.last?.id { Divider() }
            }
        }
        .accessibilityIdentifier("mfo.checkMedia.detail")
    }

    @ViewBuilder
    private func outcome(_ o: CheckMediaItem.Outcome) -> some View {
        switch o {
        case .waiting:
            Text("Waiting").font(.callout).foregroundStyle(.secondary)
        case .running(let step):
            Text("Checking — \(step)…").font(.callout).foregroundStyle(.secondary)
        case .checked(let card):
            MediaReportCardView(card: card)
        case .failed(let reason):
            Label("Couldn't check: \(reason)", systemImage: "questionmark.circle")
                .font(.callout)
        case .cancelled:
            Text("Stopped before this file").font(.callout).foregroundStyle(.secondary)
        }
    }
}
