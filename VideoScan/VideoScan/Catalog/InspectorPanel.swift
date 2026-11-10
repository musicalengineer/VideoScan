// InspectorPanel.swift
// Catalog inspector panel (right-hand detail pane) and the star-rating
// control it uses. Extracted verbatim from CatalogHelpers.swift
// (refactor 2026-06-11) — behavior-preserving move, no rewrites.

import SwiftUI

// MARK: - Inspector Panel

struct InspectorPanel: View {
    let record: VideoRecord?
    /// The record's folder identity (the Events content key), resolved by
    /// the CALLER; nil = it cannot be in a folder. Drives "In folders: …"
    /// (2026-10-19), which observes the folder store itself.
    var folderKey: String?
    /// Persistence hook for edits made INSIDE the inspector (star rating):
    /// the panel has no model access by design; the host passes
    /// `model.saveCatalogDebounced`. Defaulted for previews.
    var onRecordEdited: () -> Void = {}
    let duplicateGroupMembers: [VideoRecord]
    /// Same footage, different file (2026-10-19): the members of this
    /// record's footage group whose bytes differ — resolved and memoized by
    /// the CALLER (InspectorPanelRules.sameFootageOthers), never in a body.
    var sameFootageMembers: [VideoRecord] = []
    /// "Same footage as (possible)" (schema v1.11): one file per weak
    /// likeness pair of this record's content nobody has answered yet —
    /// resolved and memoized by the CALLER
    /// (InspectorPanelRules.possibleSameFootage), never in a body.
    var possibleSameFootage: [VideoRecord] = []
    /// The person's answer to a possible pair (this record, the other file,
    /// same / not the same) — the existing footage decision; the host saves
    /// it and re-runs Find Similar Footage for the two files.
    var onDecideFootage: ((UUID, UUID, FootageDecision.Verdict) -> Void)?
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?
    var onSelectRecord: ((UUID) -> Void)?
    /// Trim provenance (Trim Master, 2026-07-16), resolved by the CALLER
    /// (O(1) id-index lookup + memoized reverse scan — no O(records)
    /// work in this view body). `trimSource` = the record this one was
    /// trimmed from; `trimDerivatives` = trimmed versions of this one.
    var trimSource: VideoRecord?
    var trimDerivatives: [VideoRecord] = []
    /// Repair lifecycle (GH #132), resolved by the CALLER (O(1) id-index
    /// lookups — no O(records) work in this view body). `repairSource` =
    /// the record this repair copy was made from; `repairCopy` = the
    /// repaired record that superseded this one.
    var repairSource: VideoRecord?
    var repairCopy: VideoRecord?
    /// One-click confirm for the selected awaiting-confirmation repair.
    var onConfirmRepair: ((UUID) -> Void)?
    /// Master Archive (2026-08-15), resolved by the CALLER (memoized
    /// reverse index + O(1) id lookup — no O(records) work here).
    /// `masterCopy` = the archive copy promoted from this record;
    /// `promotionSource` = the record this archive copy came from.
    var masterCopy: VideoRecord?
    var promotionSource: VideoRecord?
    /// Archive Angel phase 2: the background sweep's verdict for this
    /// record (O(1) sidecar lookup by the CALLER). nil = not scored yet.
    var angelEvidence: ArchiveAngel.Evidence?
    /// Provenance ▸ Set Role (2026-10-26): the store the "Role: …" line
    /// reads catalog.sqlite through, and the selected file's whole-file
    /// digest (resolved by the CALLER, O(1)). nil store = no line (previews).
    var provenanceRoles: ProvenanceRoleStore?
    var contentDigest: String?
    /// Estimated provenance (2026-11-10): the store the "Provenance
    /// (estimated): …" line reads catalog.sqlite through. nil = no line.
    var provenanceEstimates: ProvenanceEstimateStore?
    /// The file dossier's one door (FileDossierLoader.production), passed by
    /// the host; nil = no Dossier section (previews).
    var fileDossiers: FileDossierLoader?

    // The sections, top to bottom. Each builder lives in
    // InspectorPanel+Sections.swift and decides its own visibility through
    // InspectorPanelRules (refactor R4, GH #281); this list is the order.
    var body: some View {
        if let rec = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection(rec)

                    InspectorFoldersLine(contentKey: folderKey)   // nothing when in no folder

                    if let provenanceRoles {
                        InspectorProvenanceRoleLine(digest: contentDigest, store: provenanceRoles)
                        if let provenanceEstimates {
                            // The archived file: this row's master copy, else the row itself (an archive copy).
                            InspectorProvenanceEstimateLine(record: rec, digest: contentDigest,
                                                            archivePath: (masterCopy ?? rec).fullPath,
                                                            store: provenanceEstimates, roles: provenanceRoles)
                        }
                    }

                    Divider().padding(.horizontal, 16)

                    generalSection(rec)
                    videoSection(rec)
                    audioSection(rec)
                    familyTagsSection(rec)
                    workflowTagsSection(rec)
                    whenSection(rec)
                    whereSection(rec)
                    historySection(rec)
                    dossierSection(rec)          // the file dossier view (every file)
                    timestampsSection(rec)
                    correlationSection(rec)      // only when paired / scored
                    trimSection(rec)             // only on trims and their sources
                    masterArchiveSection(rec)    // only on either side of a promotion
                    angelSection()               // only with evidence, never on archived
                    repairSection(rec)           // only in the repair lifecycle
                    duplicatesSection(rec)       // only when duplicate-flagged
                    avidProjectSection(rec)      // only with Avid metadata
                    userNotesSection(rec)        // only when non-empty
                    notesSection(rec)            // only when non-empty
                    locationSection(rec)

                    Spacer(minLength: 16)
                }
            }
            .contextMenu {
                Button("Copy All Metadata") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatAllMetadata(rec), forType: .string)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            emptyState
        }
    }

    // MARK: - Copy Metadata

    /// The plain-text copy of every section (InspectorMetadataText, one
    /// formatter per section), fed the related records this panel was
    /// handed by its caller — nothing is looked up here.
    func formatAllMetadata(_ rec: VideoRecord) -> String {
        InspectorMetadataText.format(rec, related: .init(
            duplicateGroup: duplicateGroupMembers,
            sameFootage: sameFootageMembers,
            possibleSameFootage: possibleSameFootage))
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func inspectorThumbnail(for rec: VideoRecord) -> some View {
        if previewOfflineVolumeName != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                Text("OFFLINE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else if let img = previewImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
                .shadow(radius: 2)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if rec.streamType == .audioOnly {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else {
            EmptyView()
        }
    }

    // MARK: - Section Builder

    @ViewBuilder
    func inspectorSection(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            content()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Row Helpers

    /// Clickable record link for the Trim section — same visual language
    /// as the Correlation section's "Paired With" row.
    func trimLinkRow(label: String, target: VideoRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 9))
                    Text(target.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            Spacer()
        }
    }

    /// Clickable record link for the Repair section — trimLinkRow's
    /// visual language with the lifecycle's swap glyph (GH #132).
    /// Master Archive link row: filename link (selects the other record)
    /// plus a small Reveal button that opens Finder on that file.
    func promotionLinkRow(label: String, target: VideoRecord, revealTitle: String) -> some View {
        // Green = "this file is safely in the Master Archive" (Rick
        // 2026-08-16); the filename stays accent-colored because it is a
        // link that jumps to the other record.
        let verified = label.hasPrefix("Master copy")
        return HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: verified ? .semibold : .regular))
                .foregroundColor(verified ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: verified ? "checkmark.seal.fill" : "star.circle")
                        .font(.system(size: 9))
                        .foregroundColor(verified ? .green : .accentColor)
                    Text(target.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            Text("·").font(.system(size: 11)).foregroundColor(.secondary)
            Button(revealTitle) {
                if VolumeReachability.isReachable(path: target.fullPath) {
                    NSWorkspace.shared.selectFile(target.fullPath, inFileViewerRootedAtPath: "")
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(!VolumeReachability.isReachable(path: target.fullPath))
            .help(VolumeReachability.isReachable(path: target.fullPath)
                  ? target.fullPath
                  : "\(target.fullPath) (volume offline)")
            Spacer()
        }
    }

    func repairLinkRow(label: String, target: VideoRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 9))
                    Text(target.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            Spacer()
        }
    }

    /// The "Archived on … to …" line. Pure so it can be pinned by tests.
    /// `verified` = a fixity record exists (read-back SHA-256 after the copy);
    /// without one the line goes orange and says so — a file that merely
    /// sits under the archive root is not "archived" yet.
    struct ArchivedBanner: Equatable {
        let text: String
        let verified: Bool
    }

    nonisolated static func archivedBanner(
        record: VideoRecord, masterCopy: VideoRecord?, promotionSource: VideoRecord?
    ) -> ArchivedBanner? {
        // The archive-side record is either the copy of this source, or
        // this record itself when it IS the archive copy.
        let archived: VideoRecord? = masterCopy ?? (promotionSource != nil ? record : nil)
        guard let archived else { return nil }
        let volume: String = {
            if !archived.scanContext.volumeName.isEmpty { return archived.scanContext.volumeName }
            let parts = archived.fullPath.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
            return archived.masterLocation.isEmpty
                ? "the Master Archive"
                : URL(fileURLWithPath: archived.masterLocation).lastPathComponent
        }()
        let identical = masterCopy != nil && masterCopy?.derivedFrom != record.id
        let via = identical ? " (identical copy)" : ""
        if let fixity = archived.archiveFixity {
            let when = fixity.verifiedAt.formatted(date: .abbreviated, time: .omitted)
            return ArchivedBanner(text: "Archived on \(when) to \(volume)\(via)", verified: true)
        }
        return ArchivedBanner(text: "In the archive on \(volume)\(via) — not yet verified", verified: false)
    }

    @ViewBuilder
    func inspectorRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func inspectorCopyableRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }

    func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }

    // MARK: - Duplicate Copy Row

    @ViewBuilder
    func duplicateCopyRow(
        filename: String,
        volumeName: String,
        directory: String,
        disposition: DuplicateDisposition,
        isSameVolume: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(disposition.textColor)
                    .frame(width: 6, height: 6)
                Text(filename)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSelected {
                    Text("(selected)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: isSameVolume ? "internaldrive" : "externaldrive")
                    .font(.system(size: 9))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                Text(volumeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                if !isSameVolume {
                    Text("(different volume)")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            Text(directory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }
}

// MARK: - Star Rating View

struct StarRatingView: View {
    @Binding var rating: Int
    /// Fired after a tap changes the rating — hosts hang persistence here
    /// (`model.saveCatalogDebounced()`). Defaulted so previews stay simple.
    var onCommit: () -> Void = {}
    let maxStars: Int = 3

    /// Local mirror of the bound value (Rick 2026-08-19: "the stars don't
    /// turn on — sometimes they do"). `VideoRecord` is a plain class, so
    /// writing `rec.starRating` through the binding never invalidates the
    /// host view — the control repainted only when something ELSE
    /// re-rendered it. The tap drives THIS @State (always repaints), and
    /// the binding write follows for the model.
    @State private var shown: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= shown ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundColor(star <= shown ? .yellow : .secondary.opacity(0.4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let new = (shown == star) ? 0 : star
                        shown = new
                        rating = new
                        onCommit()
                    }
                    .accessibilityIdentifier("starRating.\(star)")
            }
        }
        .onAppear { shown = rating }
        // Row reuse / selection change / external edits (Promote sets ★★★):
        // the bound value re-reads each render; follow it when it moves.
        .onChange(of: rating) { _, new in shown = new }
    }
}
