import SwiftUI

// MARK: - CombinePreflightSheet
//
// Surfaces the CombineBatchPlan to the user before any ffmpeg starts.
// Shows: how many pairs are ready, which got their sources swapped via
// UMID substitution (with full original → resolved paths), and which
// are blocked entirely. Lets the user back out before an overnight run
// that's silently using "copies" instead of the master files.
//
// Presented only when the plan has substitutions or blocked items —
// the all-ready case (the most common one) skips this sheet so we
// don't add friction to a normal flow.
//
// Step 2B-2 of [[project_archive_combine_pipeline_order]].

struct CombinePreflightSheet: View {
    let plan: VideoScanModel.CombineBatchPlan
    let onProceed: () -> Void
    let onCancel: () -> Void

    @State private var substitutionsExpanded = true
    @State private var blockedExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryChips
                .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !plan.substituted.isEmpty {
                        substitutionsSection
                    }
                    if !plan.blocked.isEmpty {
                        blockedSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            buttonBar
                .padding(14)
        }
        .frame(width: 720, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Combine Batch")
                    .font(.headline)
                Text("Confirm substitutions and blocked pairs before running.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    // MARK: - Summary Chips

    private var summaryChips: some View {
        HStack(spacing: 14) {
            Spacer()
            chip(label: "Ready",       count: plan.runnable.count - plan.substituted.count,
                 color: .green, icon: "checkmark.circle.fill")
            chip(label: "Substituted", count: plan.substituted.count,
                 color: .orange, icon: "arrow.triangle.swap")
            chip(label: "Blocked",     count: plan.blocked.count,
                 color: .red, icon: "xmark.octagon.fill")
            Spacer()
        }
    }

    private func chip(label: String, count: Int, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(color)
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Substitutions Section

    private var substitutionsSection: some View {
        DisclosureGroup(isExpanded: $substitutionsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.substituted.indices, id: \.self) { i in
                    substitutionRow(plan.substituted[i])
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").foregroundColor(.orange)
                Text("Substitutions").font(.system(size: 13, weight: .semibold))
                Text("(\(plan.substituted.count))")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder
    private func substitutionRow(_ item: VideoScanModel.CombineBatchPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.originalVideo.filename)
                .font(.system(size: 13, weight: .medium))
            if item.videoSubstituted {
                pathSwap(label: "video",
                         from: item.originalVideo.fullPath,
                         to:   item.resolvedVideo.fullPath)
            }
            if item.audioSubstituted {
                pathSwap(label: "audio",
                         from: item.originalAudio.fullPath,
                         to:   item.resolvedAudio.fullPath)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.orange.opacity(0.05))
        )
    }

    private func pathSwap(label: String, from: String, to: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                    .frame(width: 40, alignment: .leading)
                Text(from)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .strikethrough(true, color: .secondary.opacity(0.6))
                    .help(from)
            }
            HStack(spacing: 6) {
                Text("→")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                    .frame(width: 40, alignment: .leading)
                Text(to)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .help(to)
            }
        }
    }

    // MARK: - Blocked Section

    private var blockedSection: some View {
        DisclosureGroup(isExpanded: $blockedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.blocked.indices, id: \.self) { i in
                    blockedRow(plan.blocked[i])
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                Text("Blocked").font(.system(size: 13, weight: .semibold))
                Text("(\(plan.blocked.count))")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
    }

    private func blockedRow(_ item: VideoScanModel.CombineBatchPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(item.originalVideo.filename)  +  \(item.originalAudio.filename)")
                .font(.system(size: 13, weight: .medium))
            Text(item.blockReason ?? "unknown reason")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.red.opacity(0.06))
        )
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.escape)
            Button(proceedLabel, action: onProceed)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(plan.runnable.isEmpty)
        }
    }

    private var proceedLabel: String {
        let n = plan.runnable.count
        if n == 0 { return "Nothing to combine" }
        if n == 1 { return "Combine 1 Pair" }
        return "Combine \(n) Pairs"
    }
}
