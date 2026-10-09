import SwiftUI

// MARK: - Repair's small views (Rick 2026-10-08)
//
//   MediaRepairBanner      — the ORANGE "Recommended action" box with the
//                             GREEN button (Get Info, the Repair sheet).
//   MediaRepairComparisonView — the before → after card; GREEN headline
//                             only when every aimed-at row was re-checked
//                             and reads OK.
//   MediaRepairDetailView  — the MFO row's double-click detail.
// Presentation only; they read values and write nothing. Calm, family
// words: "repair", "play properly" — never "improve" or "enhance".

struct MediaRepairBanner: View {
    let advice: MediaRepairAdvice
    /// nil = no button (the sheet draws its own Repair Now below the plan).
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        switch advice {
        case .none:
            EmptyView()
        case .recommended(let headline, let fixLine, _, let unfixable, _):
            box(color: .orange) {
                Label("Recommended action", systemImage: "wrench.and.screwdriver.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(headline).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(fixLine).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(unfixable, id: \.self) { line in
                    Text("Not something Repair can fix — \(line)")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .accessibilityIdentifier("repair.banner.repairNow")
                }
            }
            .accessibilityIdentifier("repair.banner")
        case .noAutomaticFix(let sentence):
            box(color: .secondary) {
                Text(sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("repair.banner.noFix")
        }
    }

    private func box<Content: View>(color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.6), lineWidth: 1))
    }
}

struct MediaRepairComparisonView: View {
    let comparison: MediaRepairComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(comparison.headline).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: comparison.isFullyRepaired ? "checkmark.seal.fill" : "checkmark.circle")
            }
            .foregroundStyle(comparison.isFullyRepaired ? Color.green : Color.primary)
            .accessibilityIdentifier("repair.after.headline")
            ForEach(comparison.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MediaVerdictIcon(verdict: row.before)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    MediaVerdictIcon(verdict: row.after ?? .notRun(reason: ""))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.kind.title).font(.callout.weight(.semibold))
                        Text(Self.rowSentence(row)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((comparison.isFullyRepaired ? Color.green : Color.secondary).opacity(0.08)))
        .accessibilityIdentifier("repair.after")
    }

    static func rowSentence(_ row: MediaRepairComparison.Row) -> String {
        if row.isFixed { return "Fixed in the copy." }
        if !row.wasRechecked { return "Not re-checked yet — run a full Verify on the copy." }
        return row.afterSentence ?? "Still needs attention in the copy."
    }
}

/// The MFO row's double-click detail: the plan, then how it ended.
struct MediaRepairDetailView: View {
    @ObservedObject var job: MediaRepairJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan").font(.callout.weight(.semibold))
            ForEach(job.request.recipe.stepLines, id: \.self) { Text("• \($0)").font(.callout) }
            ForEach(job.request.recipe.skipped, id: \.fix) { skip in
                Text("• Not in this pass — \(skip.fix.title): \(skip.reason).").font(.callout).foregroundStyle(.secondary)
            }
            Text("Saving to: \(job.request.output.path)").font(.callout.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let comparison = job.comparison {
                MediaRepairComparisonView(comparison: comparison)
            } else if !job.state.isActive {
                Text(job.subtitle).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("mfo.repair.detail")
    }
}
