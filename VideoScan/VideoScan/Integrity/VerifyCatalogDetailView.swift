// VerifyCatalogDetailView.swift
// Double-click detail for the "Verify catalog" MFO row: one line per tier
// (result, summary, how long), where the report went (or why it did not),
// then every kept finding grouped by tier — the record's filename and the
// words. Pure presentation over the job's published values — no model
// access, no I/O, nothing O(catalog) in the body (the findings are capped
// at IntegrityReport.findingsCap and already grouped by the job).

import SwiftUI

struct VerifyCatalogDetailView: View {
    @ObservedObject var job: VerifyCatalogJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(job.tiers) { tierRow($0) }
            reportLine
            if job.findingsTotal == 0 {
                Text(job.state.isActive ? "Checking…" : "No finding.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.tiers.filter { !(job.findingsByTier[$0.tier] ?? []).isEmpty }) { tier in
                            Text("Tier \(tier.tier) — \(tier.name)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(Array((job.findingsByTier[tier.tier] ?? []).enumerated()), id: \.offset) { _, finding in
                                findingRow(finding)
                            }
                        }
                        if job.findingsTotal > job.findings.count {
                            Text("…and \((job.findingsTotal - job.findings.count).formatted()) more (the report keeps the first \(IntegrityReport.findingsCap.formatted()))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.verifyCatalog.detail")
    }

    @ViewBuilder
    private var reportLine: some View {
        if let problem = job.reportProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Self.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let url = job.reportURL {
            Label("report: \(url.path)", systemImage: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        }
    }

    private func tierRow(_ tier: IntegrityTier) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(tier.result))
                .foregroundStyle(Self.color(tier.result))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tier \(tier.tier) — \(tier.name)  ·  \(tier.result.words)")
                    .font(.system(size: 12, weight: .medium))
                Text(tier.summary + (tier.elapsedSeconds > 0 ? String(format: "  (%.2f s)", tier.elapsedSeconds) : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func findingRow(_ finding: IntegrityFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.needsDecision ? "questionmark.circle.fill" : "info.circle")
                .foregroundStyle(finding.needsDecision ? Self.red : Color.secondary)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.filename ?? "the catalog")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(finding.words)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static let red = Color(red: 0.80, green: 0.10, blue: 0.10)

    static func icon(_ result: IntegrityTierResult) -> String {
        switch result {
        case .ok: return "checkmark.circle.fill"
        case .needsDecision: return "questionmark.circle.fill"
        case .couldNotCheck: return "exclamationmark.triangle.fill"
        case .notRun: return "minus.circle"
        }
    }

    static func color(_ result: IntegrityTierResult) -> Color {
        switch result {
        case .ok: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .needsDecision: return red
        case .couldNotCheck: return Color(red: 0.75, green: 0.45, blue: 0.00)
        case .notRun: return .secondary
        }
    }
}
