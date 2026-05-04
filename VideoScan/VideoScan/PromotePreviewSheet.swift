// PromotePreviewSheet.swift
// Confirmation sheet for the cluster→POI bridge in Identify Family.
// Shows the planned actions (create / merge / skip per cluster) so the
// user can review before any filesystem mutation happens.
//
// Workflow:
//   1. User names clusters in IdentifyFamilyView's review screen.
//   2. User clicks "Save & Promote to People".
//   3. IdentifyFamilyModel.planPromotion() returns [PromotionAction].
//   4. This sheet renders the plan; user confirms or cancels.
//   5. On confirm, IdentifyFamilyModel.executePromotion(_:) does the work
//      and PersonFinderModel.savedProfiles is reloaded.

import SwiftUI

struct PromotePreviewSheet: View {
    let plan: [IdentifyFamilyModel.PromotionAction]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var creates: [IdentifyFamilyModel.PromotionAction] {
        plan.filter { if case .create = $0 { return true } else { return false } }
    }
    private var merges: [IdentifyFamilyModel.PromotionAction] {
        plan.filter { if case .merge = $0 { return true } else { return false } }
    }
    private var skips: [IdentifyFamilyModel.PromotionAction] {
        plan.filter { if case .skip = $0 { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Promote clusters to People")
                    .font(.title2).fontWeight(.semibold)
                Text("Review what will happen before any files are written.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !creates.isEmpty {
                        sectionHeader(
                            "Create new POIs",
                            count: creates.count,
                            icon: "plus.circle.fill",
                            color: .green
                        )
                        ForEach(creates) { action in
                            row(for: action)
                        }
                    }
                    if !merges.isEmpty {
                        sectionHeader(
                            "Merge into existing POIs",
                            count: merges.count,
                            icon: "arrow.triangle.merge",
                            color: .blue
                        )
                        ForEach(merges) { action in
                            row(for: action)
                        }
                    }
                    if !skips.isEmpty {
                        sectionHeader(
                            "Skip (no name)",
                            count: skips.count,
                            icon: "minus.circle",
                            color: .secondary
                        )
                        ForEach(skips) { action in
                            row(for: action)
                        }
                    }
                    if plan.isEmpty {
                        Text("No clusters to promote. Name at least one cluster first.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save & Promote") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creates.isEmpty && merges.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 480)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text("(\(count))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(for action: IdentifyFamilyModel.PromotionAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.square.filled.and.at.rectangle")
                .foregroundStyle(.secondary)
            switch action {
            case .create(let cid, let name, let faceCount):
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text("← cluster \(String(format: "%03d", cid)), \(faceCount) faces")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .merge(let cid, let name, let faceCount, let existingCount):
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text("+ \(faceCount) faces from cluster \(String(format: "%03d", cid)) (existing: \(existingCount))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .skip(let cid, let reason):
                Text("cluster \(String(format: "%03d", cid))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("— \(reason)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 12)
    }
}
