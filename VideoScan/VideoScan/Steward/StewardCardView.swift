// StewardCardView.swift
// ONE focused steward case, drawn in the Archive Angel list's visual
// language (Rick 2026-09-24, "senior rows": a large title, plain words
// instead of grades, coloured labelled buttons — ColorActionButton,
// .large). What · why (evidence) · payoff · do it / skip.
//
// Pure presentation: the case, its evidence and its button states arrive
// precomputed; the buttons call closures. Nothing here touches the catalog
// — every list it draws is already capped (StewardCaseBuilder
// .maxCopiesPerCase) and it shows the first `visibleRows` of that.
//
// AN EVENT CARD (2026-10-03) says what belongs together: its name, how the
// clips were placed in it (the labeller's reasons, counted, and per clip
// when opened), and what is inside from knowledge the catalog already has.
// It offers no way to let anything go — only ways to look.
//
// (For Rick: `@ViewBuilder` ≈ a function whose body is a list of views,
// with `if`/`switch` allowed; `ViewThatFits` picks the first layout that
// fits the width; `@State` ≈ a member variable SwiftUI keeps for this card
// while it is on screen.)

import SwiftUI

/// What the card's buttons do — supplied by the pane.
struct StewardCardActions {
    var showInCatalog: () -> Void = {}
    var deleteDuplicates: () -> Void = {}
    var openFootageGroup: () -> Void = {}
    var showOnePerFootage: () -> Void = {}
    var reviewBelow: () -> Void = {}
    var reviewCopies: () -> Void = {}
    var skip: () -> Void = {}
    var bringBack: () -> Void = {}
}

struct StewardCardView: View {
    let item: StewardCase
    /// Reclaim set only: the keeper's reason and the planner's proof.
    let evidence: StewardGroupEvidence?
    /// "duplicates checked 2 h ago · 14 files not checked yet"
    let freshness: String
    /// Reclaim only: the Delete duplicates button's state.
    let deleteGate: StewardActionGate
    let isReadOnly: Bool
    /// Shown from the "Show skipped" list: offers Bring back, not Skip.
    let isSkipped: Bool
    let actions: StewardCardActions

    /// Evidence rows drawn before "and N more".
    static let visibleRows = 8

    /// Event card: the per-clip reasons are opened.
    @State private var showReasons = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            evidenceSection
            buttons
            Text(freshness)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("steward.card.freshness")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("steward.card")
    }

    // MARK: What

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StewardKindChip(kind: item.kind)
                if isSkipped {
                    Text("Skipped")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("steward.card.title")
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("steward.card.detail")
            }
        }
    }

    // MARK: Why

    @ViewBuilder
    private var evidenceSection: some View {
        switch item.kind {
        case .event, .unlabelledDay: occasionEvidence
        case .reclaimDrive: driveEvidence
        case .reclaimGroup: groupEvidence
        case .sameFootage: footageEvidence
        case .junk: junkEvidence
        }
    }

    /// An event or a day to name: how the clips were placed, what is
    /// inside, and — opened — why each clip is here.
    @ViewBuilder
    private var occasionEvidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.whyLine.isEmpty {
                line(item.kind == .event ? "How these were placed: \(item.whyLine)" : item.whyLine + ".")
                    .accessibilityIdentifier("steward.event.why")
            }
            if !item.insideLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inside")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.insideLines, id: \.self) { text in
                        line(text)
                    }
                }
                .accessibilityIdentifier("steward.event.inside")
            }
            if !item.alsoInLine.isEmpty {
                line(item.alsoInLine, faint: true)
                    .accessibilityIdentifier("steward.event.alsoIn")
            }
            DisclosureGroup(isExpanded: $showReasons) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.copies.prefix(Self.visibleRows)) { copy in
                        copyRow(copy)
                    }
                    moreRowsNote
                }
                .padding(.top, 4)
            } label: {
                Text("Why each clip is here")
                    .font(.system(size: 14, weight: .medium))
            }
            .accessibilityIdentifier("steward.event.reasons")
        }
        .accessibilityIdentifier("steward.card.evidence")
    }

    @ViewBuilder
    private var driveEvidence: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = item.estimate {
                if e.copiesWithOfflineSiblings > 0 {
                    line("\(e.copiesWithOfflineSiblings.formatted()) of them have copies on drives that are not connected.")
                }
                line(ReclaimableEstimate.survivalRule)
                line(ReclaimableEstimate.estimateNote, faint: true)
            }
        }
        .accessibilityIdentifier("steward.card.evidence")
    }

    @ViewBuilder
    private var groupEvidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let evidence {
                line("Why keep that one: \(evidence.keeperReason)")
            }
            ForEach(item.copies.prefix(Self.visibleRows)) { copy in
                copyRow(copy)
            }
            moreRowsNote
            if evidence != nil, evidence?.proofs == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking the copies on the drives…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let unproved = evidence?.unprovedCopies, unproved > 0 {
                line("\(unproved) more cop\(unproved == 1 ? "y is" : "ies are") not worked out here — the Delete step's forecast covers every one.", faint: true)
            }
            line(ReclaimableEstimate.survivalRule)
            line(StewardGroupEvidence.keeperCaveat, faint: true)
            if item.protectedCopies > 0 {
                line("\(item.protectedCopies) cop\(item.protectedCopies == 1 ? "y is" : "ies are") never offered — in the archive, on its drive, filed as Archived or chosen by the Archive Angel.", faint: true)
            }
        }
        .accessibilityIdentifier("steward.card.evidence")
    }

    @ViewBuilder
    private var footageEvidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.likelyOriginalName.isEmpty {
                line(item.originalInCatalog
                     ? "Likely original: \(item.likelyOriginalName)"
                     : "The camera original is probably not in the catalog. Best available: \(item.likelyOriginalName)")
            }
            ForEach(item.copies.prefix(Self.visibleRows)) { copy in
                copyRow(copy)
            }
            moreRowsNote
            if !item.evidenceLines.isEmpty {
                line("Why they belong together: " + item.evidenceLines.joined(separator: " · "), faint: true)
            }
        }
        .accessibilityIdentifier("steward.card.evidence")
    }

    @ViewBuilder
    private var junkEvidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.copies.prefix(Self.visibleRows)) { copy in
                copyRow(copy)
            }
            moreRowsNote
        }
        .accessibilityIdentifier("steward.card.evidence")
    }

    @ViewBuilder
    private var moreRowsNote: some View {
        if item.memberCount > min(item.copies.count, Self.visibleRows), item.kind != .reclaimDrive {
            let more = item.memberCount - min(item.copies.count, Self.visibleRows)
            line("and \(more.formatted()) more", faint: true)
        }
    }

    /// One file: drive · folder · name · size (· length), then what would
    /// happen to it, in words.
    private func copyRow(_ copy: StewardCopy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(copy.isOnline ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(copy.drive + (copy.isOnline ? "" : " (not connected)"))
                    .font(.system(size: 14, weight: .medium))
                if !copy.folder.isEmpty {
                    Text(copy.folder)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(copy.filename)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: copy.sizeBytes, countStyle: .file))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if item.kind != .reclaimGroup, copy.durationSeconds > 0 {
                    Text(Self.length(copy.durationSeconds))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if !copy.roleLabel.isEmpty {
                    Text(copy.roleLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            if let words = StewardStandingWords.words(for: copy, proof: evidence?.proofs?[copy.id]) {
                Text(words)
                    .font(.system(size: 13))
                    .foregroundStyle(copy.standing == .keeper ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
            // Event rows: the labeller's reason, and the clip's other events.
            if !copy.reason.isEmpty {
                Text(copy.reason + (copy.alsoIn.isEmpty ? "" : " · also in: \(copy.alsoIn)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
    }

    // MARK: Do it / skip

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
            ForEach(notes, id: \.self) { note in
                line(note, faint: true)
            }
        }
    }

    /// The lines under the buttons: why one is off, and what is not there yet.
    private var notes: [String] {
        switch item.kind {
        case .event:
            return [StewardActionGate.eventNamingGap]
        case .unlabelledDay:
            return [StewardActionGate.dayNamingGap]
        case .reclaimDrive:
            return deleteGate.isEnabled ? [] : [deleteGate.reason]
        case .reclaimGroup:
            return (deleteGate.isEnabled ? [] : [deleteGate.reason]) + [StewardActionGate.perGroupDeleteGap]
        case .sameFootage:
            return [StewardActionGate.namingGap]
        case .junk:
            return []
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.kind {
        case .event, .unlabelledDay:
            // Ways to LOOK only — an event card never lets anything go.
            showInCatalogButton
            if item.footageGroupID != nil {
                button("Open the footage group", "square.stack.3d.up", ColorActionButton.Palette.info,
                       id: "steward.event.openFootageGroup", enabled: true,
                       help: "Every clip in the group, its part in it, and your say on whether they are the same footage",
                       action: actions.openFootageGroup)
            }
            if item.kind == .event || !item.copyReviewIDs.isEmpty {
                button(item.kind == .event ? "Review the copies in this event" : "Review the copies among these",
                       "doc.on.doc", ColorActionButton.Palette.play,
                       id: "steward.event.reviewCopies", enabled: !item.copyReviewIDs.isEmpty,
                       help: item.copyReviewIDs.isEmpty
                           ? "None of these clips are copies of each other, as far as the last duplicate check found"
                           : "Goes to the Catalog with just the clips here that are copies of each other. Nothing is selected or changed.",
                       action: actions.reviewCopies)
            }
        case .reclaimDrive, .reclaimGroup:
            showInCatalogButton
            button("Delete duplicates on \(item.driveLabel.isEmpty ? "this drive" : item.driveLabel)…", "trash",
                   .red, id: "steward.action.deleteDuplicates", enabled: deleteGate.isEnabled,
                   help: deleteGate.reason, action: actions.deleteDuplicates)
        case .sameFootage:
            button("Open the footage group", "square.stack.3d.up", ColorActionButton.Palette.info,
                   id: "steward.action.openFootageGroup", enabled: true,
                   help: "Every clip in the group, its part in it, and your say on whether they are the same footage",
                   action: actions.openFootageGroup)
            showInCatalogButton
            button("Show one per footage in the Catalog", "rectangle.stack", ColorActionButton.Palette.play,
                   id: "steward.action.onePerFootage", enabled: true,
                   help: "Turns on “One Per Footage” in the Catalog's Show menu and goes there: each set of the same footage is shown once",
                   action: actions.showOnePerFootage)
            button("Name this footage…", "pencil", ColorActionButton.Palette.archive,
                   id: "steward.action.nameFootage", enabled: false,
                   help: StewardActionGate.namingGap, action: {})
        case .junk:
            button("Review these below", "arrow.down.to.line", ColorActionButton.Palette.showInCatalog,
                   id: "steward.action.reviewBelow", enabled: true,
                   help: "Shows just these files in the table below. Nothing is selected or changed — pick the ones you mean, then keep them or mark them",
                   action: actions.reviewBelow)
        }
        if isSkipped {
            button("Bring back", "arrow.uturn.backward", .secondary, id: "steward.action.bringBack", enabled: true,
                   help: "Put this back among the suggestions", action: actions.bringBack)
        } else {
            button("Skip", "forward.end", .secondary, id: "steward.action.skip", enabled: true,
                   help: "Not now. It stays away until its files or its size change by a tenth or more.",
                   action: actions.skip)
        }
    }

    private var showInCatalogButton: some View {
        button("Show these in the Catalog", "film.stack", ColorActionButton.Palette.showInCatalog,
               id: "steward.action.showInCatalog", enabled: !item.recordIDs.isEmpty,
               help: "Goes to the Catalog with just these files listed", action: actions.showInCatalog)
    }

    // The parameter list is long because a button IS that many facts; a
    // wrapper type would only move them.
    // swiftlint:disable:next function_parameter_count
    private func button(_ title: String, _ image: String, _ color: Color, id: String, enabled: Bool,
                        help: String, action: @escaping () -> Void) -> some View {
        ColorActionButton(title: title, systemImage: image, color: color, size: .large, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .help(help)
            .accessibilityIdentifier(id)
    }

    private func line(_ text: String, faint: Bool = false) -> some View {
        Text(text)
            .font(.system(size: faint ? 13 : 14))
            .foregroundStyle(faint ? .tertiary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "1:02:03" / "4:05" / "12 s".
    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The kind chip on the card and on each "next up" row.
struct StewardKindChip: View {
    let kind: StewardCaseKind

    var color: Color {
        switch kind {
        case .event: return .purple
        case .unlabelledDay: return .teal
        case .reclaimDrive, .reclaimGroup: return .orange
        case .sameFootage: return .blue
        case .junk: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.systemImage)
            Text(kind.chip)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .fixedSize()
    }
}
