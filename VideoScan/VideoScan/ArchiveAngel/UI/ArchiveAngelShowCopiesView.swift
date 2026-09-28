// ArchiveAngelShowCopiesView.swift
// Archive Angel ▸ Show Copies… — READ-ONLY (Consolidation S4, Rick
// 2026-09-22). One recording's copies: the verdict, the cautions, and one
// card per distinct representation (role · signature · every location ·
// the recommended copy · why). No buttons that act: to archive the file,
// use "Prepare with Archive Angel" (it verifies and balances the audio),
// then Review → Promote.
//
// The summary, caution box and representation cards are moved from the
// retired Promote Helper panel (AssessCopiesDetailView, 2026-08-19) with
// their wording, colours and layout; only "Promote this copy:" became
// "Recommended copy:" because nothing here promotes.
//
// Public surface: `ArchiveAngelShowCopiesHost` (the catalog's sheet host).
// The Review sheet presents `ArchiveAngelShowCopiesView` from its own state.

import SwiftUI

/// The catalog's sheet host: presents Show Copies… whenever the façade's
/// presenter holds a request. (A ViewModifier ≈ a decorator: it wraps the
/// catalog view and adds the `.sheet` without the catalog knowing the
/// Angel's internals.)
struct ArchiveAngelShowCopiesHost: ViewModifier {
    @ObservedObject private var presenter: ArchiveAngelShowCopiesPresenter

    init(angel: ArchiveAngel) {
        presenter = angel.showCopiesPresenter
    }

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.request) { request in
            ArchiveAngelShowCopiesView(request: request)
        }
    }
}

struct ArchiveAngelShowCopiesView: View {
    let request: ArchiveAngelShowCopiesRequest
    @Environment(\.dismiss) private var dismiss
    @State private var expandedReps: Set<String> = []

    private var a: CopyFamilyAssessment { request.assessment }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary
                    if !a.cautions.isEmpty { cautions }
                    Text("All copies found (\(a.representations.count) representations, \(a.locationCount) locations)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(a.representations) { rep in
                        representationCard(rep)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 520)
        .accessibilityIdentifier("archiveAngel.showCopies")
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Copies of \(request.seedFilename)")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Which of these copies is the original? Read-only — nothing here changes a file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text("To archive it, choose Prepare with Archive Angel in the Catalog — it verifies the audio first.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("archiveAngel.showCopies.done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Summary / cautions

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.recommendedRepresentation == nil ? "questionmark.circle.fill" : "crown.fill")
                .font(.title2)
                .foregroundStyle(a.recommendedRepresentation == nil ? Color.orange : Color.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(a.headline).font(.headline)
                Text(a.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cautions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(a.cautions, id: \.self) { c in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    Text(c)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Representation cards

    /// Role chip fills — dark enough to carry white small-caps text
    /// (Rick 2026-08-19: "I can barely read the words"; same luminance
    /// bar as the MFO badge palette).
    static func roleColor(_ r: CopyRole) -> Color {
        switch r {
        case .originalSource:        return Color(red: 0.26, green: 0.22, blue: 0.62)  // deep indigo
        case .presumedOriginal:      return Color(red: 0.42, green: 0.20, blue: 0.58)  // dark violet
        case .repairedCopy:          return Color(red: 0.55, green: 0.30, blue: 0.05)  // dark amber
        case .preservationCompanion: return Color(red: 0.05, green: 0.42, blue: 0.22)  // forest green
        case .editingDerivative:     return Color(red: 0.00, green: 0.40, blue: 0.44)  // dark teal
        case .accessCopy:            return Color(red: 0.08, green: 0.32, blue: 0.72)  // cobalt
        case .unconfirmedVariant:    return Color(red: 0.72, green: 0.36, blue: 0.00)  // burnt orange
        }
    }

    // One card, built from named pieces: the inline form timed out CI's
    // type-checker budget (ArchiveAngelShowCopiesView.swift:155, 1927 ms,
    // nightly run 36121118356). Same views, same order, same labels.
    private func representationCard(_ rep: CopyRepresentation) -> some View {
        let isRecommended: Bool = rep.id == a.recommendedRepresentationID
        let fill: Color = isRecommended ? Color.indigo.opacity(0.08) : Color.primary.opacity(0.03)
        let stroke: Color = isRecommended ? Color.indigo.opacity(0.5) : Color.clear
        return representationContent(rep, isRecommended: isRecommended)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    /// The instance a representation recommends, if it names one.
    static func recommendedInstance(of rep: CopyRepresentation) -> CopyInstance? {
        guard let wanted: UUID = rep.recommendedInstanceID else { return nil }
        return rep.instances.first { (inst: CopyInstance) -> Bool in inst.id == wanted }
    }

    /// Title row, reason, recommended copy, and (expanded) every location.
    private func representationContent(_ rep: CopyRepresentation, isRecommended: Bool) -> some View {
        let recInstance: CopyInstance? = Self.recommendedInstance(of: rep)
        return VStack(alignment: .leading, spacing: 6) {
            representationTitle(rep)
            Text(rep.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let inst = recInstance {
                recommendedLine(inst, isRecommended: isRecommended)
            }
            if expandedReps.contains(rep.id) {
                instanceList(rep)
            }
        }
    }

    /// "3 locations · 1.2 GB" — the count and the representation's size.
    static func locationSummary(_ rep: CopyRepresentation) -> String {
        let count: Int = rep.instances.count
        let plural: String = count == 1 ? "" : "s"
        let size: String = CatalogStorageTotals.displaySize(rep.sizeBytes)
        return "\(count) location\(plural) · \(size)"
    }

    /// Role chip · signature · location summary · expand chevron.
    private func representationTitle(_ rep: CopyRepresentation) -> some View {
        let isExpanded: Bool = expandedReps.contains(rep.id)
        return HStack(spacing: 8) {
            Text(rep.role.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Self.roleColor(rep.role), in: Capsule())
            Text(rep.signature)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Self.locationSummary(rep))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button {
                if expandedReps.contains(rep.id) { expandedReps.remove(rep.id) } else { expandedReps.insert(rep.id) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Show every location of this representation")
        }
    }

    /// "Recommended copy:" (or "Best copy:") and its path.
    private func recommendedLine(_ inst: CopyInstance, isRecommended: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isRecommended ? "checkmark.seal.fill" : "arrow.turn.down.right")
                .foregroundStyle(isRecommended ? Color.green : Color.secondary)
                .font(.system(size: 11))
            Text(isRecommended ? "Recommended copy:" : "Best copy:")
                .font(.system(size: 11, weight: .medium))
            Text(inst.fullPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(inst.fullPath)
            if !inst.isReachable {
                Text("offline").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    /// Every location of the representation (shown when expanded).
    private func instanceList(_ rep: CopyRepresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rep.instances) { inst in
                instanceRow(inst)
            }
        }
        .padding(.leading, 8)
    }

    private func instanceRow(_ inst: CopyInstance) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(inst.isReachable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(inst.fullPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if inst.isArchiveCopy {
                Text("archive copy").font(.system(size: 10)).foregroundStyle(.indigo)
            }
            if inst.byteCluster == nil {
                Text("no signature").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(CatalogStorageTotals.displaySize(inst.sizeBytes))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
