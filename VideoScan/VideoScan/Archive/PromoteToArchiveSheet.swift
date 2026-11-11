// PromoteToArchiveSheet.swift
// "Promote to Archive" confirmation (design v2 §4): N files, total GB,
// destination folders grouped, warnings (undated / low-confidence /
// already promoted — skipped), the free-space check, and one Confirm
// that enqueues ONE MFO Promote job. Driven by
// `model.pendingPromoteRequest` (bound in ContentView) so the catalog
// right-click and the File ▸ Archive menu share it.
//
// Dates from copies (Rick 2026-09-27, PromoteDateChoice.swift): a file with
// no date of its own takes the date Rick gave its copies. One distinct KNOWN
// date → one line "dated 1984 (known) from 2 copies · change"; copies that
// disagree, or only estimated dates → the sheet ASKS (each copy's date, where
// it lives, and when it was set; Use / Enter a date… / Promote undated), and
// Promote waits for the answer. Machine dates never trigger this.

import SwiftUI

struct PromoteToArchiveSheet: View {
    @EnvironmentObject private var model: VideoScanModel
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: ArchivePromoteRequest

    /// "Archive anyway (I know this file)" — Rick's explicit override for
    /// un-probeable files (the ONE blocking readiness state).
    @State var overrideUnprobeable = false

    /// Archive-name overrides per entry (Promote-Helper, Rick 2026-08-19):
    /// a vertical list — Master / Lossless Copy / Edit Copy — each
    /// with its own name; empty = keep that file's stem. Seeded from the
    /// request (Assess pre-fills suggestions); editable for plain
    /// right-click Promotes too. Slugified at destination time.
    @State private var archiveTitles: [UUID: String] = [:]
    /// What the reader typed for entries whose date the archive could not
    /// work out. Empty means "file it under Undated/", which is permanent.
    @State private var archiveDates: [UUID: String] = [:]

    /// Per entry: what its copies say (computed once, in `.task` — one pass
    /// over the catalog, never in the body).
    @State private var copyChoices: [UUID: PromoteCopiesDateChoice] = [:]
    /// The copy date chosen (or pre-selected) per entry.
    @State private var chosenCopyDate: [UUID: PromoteCopyDate] = [:]
    /// Entries where the person said "Promote undated" (no copy date).
    @State private var declinedCopyDate: Set<UUID> = []
    /// Entries where the person chose "Enter a date…" (show the field).
    @State private var typingDate: Set<UUID> = []
    /// Pre-selected lines the person opened with "change".
    @State private var expandedChoice: Set<UUID> = []

    private var plan: ArchivePromotePlan { request.plan }

    /// Confirm is blocked ONLY by un-probeable files without the override
    /// (plus the pre-existing free-space / read-only / identity gates) and
    /// by a copies-date question not yet answered.
    private var blockedByReadiness: Bool {
        plan.unprobeableCount > 0 && !overrideUnprobeable
    }

    private var unansweredDateQuestions: Int {
        plan.entries.filter { needsAnswer($0.recordID) }.count
    }

    private var rootLabel: String {
        VolumeReachability.displayLabel(forPath: plan.rootPath)
            + "/" + MasterArchiveLayout.rootFolderName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.headline)
                    Text("Verified copies into \(rootLabel) — the originals stay where they are.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if !plan.entries.isEmpty {
                GroupBox("Destination folders") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.foldersGrouped, id: \.folder) { group in
                            HStack {
                                Text(group.folder)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text("\(group.count) file\(group.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            copiesDateSection

            archiveNameSection

            readinessSection

            warnings

            HStack {
                if unansweredDateQuestions > 0 {
                    Text("Choose a date for \(unansweredDateQuestions) file\(unansweredDateQuestions == 1 ? "" : "s") above")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.entries.count == 1 ? "Promote" : "Promote \(plan.entries.count) Files") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.entries.isEmpty || !plan.hasEnoughFreeSpace || model.isReadOnly
                          || model.masterArchiveIdentityMismatch != nil || blockedByReadiness
                          || unansweredDateQuestions > 0)
                .accessibilityIdentifier("promote.confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { loadCopyDates() }
    }

    private var headline: String {
        let n = plan.entries.count
        let size = PromoteToArchiveJob.humanBytes(plan.totalBytes)
        switch n {
        case 0:  return "Nothing to promote"
        case 1:  return "Promote 1 file (\(size)) to the Master Archive?"
        default: return "Promote \(n) files (\(size)) to the Master Archive?"
        }
    }

    // MARK: Dates from copies

    /// One pass over the catalog for the whole selection, then the ledger
    /// (off-main) for "when set" on the rows that ask.
    private func loadCopyDates() {
        guard copyChoices.isEmpty else { return }
        let choices = model.promoteCopyDateChoices(recordIDs: plan.entries.map(\.recordID))
        copyChoices = choices
        for (id, choice) in choices {
            if case .preselected(let d, _) = choice { chosenCopyDate[id] = d }
        }
        let askIDs = Set(choices.values.flatMap { choice -> [UUID] in
            if case .ask(let list) = choice { return list.map(\.recordID) }
            return []
        })
        guard !askIDs.isEmpty else { return }
        let ledger = model.mediaLedger
        Task {
            let times = await PromoteCopyDates.dateSetTimes(ids: askIDs, ledger: ledger)
            guard !times.isEmpty else { return }
            for (id, choice) in copyChoices {
                guard case .ask(let list) = choice else { continue }
                copyChoices[id] = .ask(list.map { var d = $0; d.setAt = times[d.recordID]; return d })
            }
        }
    }

    /// An ask not yet answered (a pre-selection needs no answer).
    private func needsAnswer(_ id: UUID) -> Bool {
        guard case .ask = copyChoices[id] else { return false }
        if chosenCopyDate[id] != nil || declinedCopyDate.contains(id) { return false }
        return ArchiveDateEntry.parse(archiveDates[id] ?? "") == nil
    }

    @ViewBuilder
    private var copiesDateSection: some View {
        let rows = plan.entries.filter { (copyChoices[$0.recordID] ?? .noCopyDates) != .noCopyDates }
        if !rows.isEmpty {
            GroupBox("Dates you gave its copies") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { entry in copyDateRow(entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func copyDateRow(_ entry: ArchivePromotePlan.Entry) -> some View {
        let id = entry.recordID
        let choice = copyChoices[id] ?? .noCopyDates
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.filename)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            switch choice {
            case .noCopyDates:
                EmptyView()
            case .preselected(let d, _):
                if expandedChoice.contains(id) {
                    askList([d], id: id)
                } else {
                    HStack(spacing: 6) {
                        Label(currentLine(id: id, fallback: choice.line ?? ""), systemImage: "calendar.badge.checkmark")
                            .font(.system(size: 12))
                        Button("change") { expandedChoice.insert(id) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("promoteSheet.copyDate.change")
                    }
                }
            case .ask(let list):
                Text("Its copies say different things (or only estimate) — which date?")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                askList(list, id: id)
            }
        }
    }

    /// The line for an answered entry ("dated … from …", or the answer).
    private func currentLine(id: UUID, fallback: String) -> String {
        if declinedCopyDate.contains(id) { return "no date from its copies" }
        if let typed = ArchiveDateEntry.parse(archiveDates[id] ?? "")?.hint, typingDate.contains(id) {
            return "you typed \(ArchiveRefile.datedLabel(typed))"
        }
        return fallback
    }

    private func askList(_ list: [PromoteCopyDate], id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(list) { d in
                HStack(spacing: 6) {
                    let picked = chosenCopyDate[id] == d && !typingDate.contains(id)
                    Button(picked ? "✓ Using \(UserDateEntry.friendlyDisplay(d.date))" : "Use \(UserDateEntry.friendlyDisplay(d.date))") {
                        chosenCopyDate[id] = d
                        declinedCopyDate.remove(id)
                        typingDate.remove(id)
                        archiveDates[id] = nil
                    }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("promoteSheet.copyDate.use")
                    Text(PromoteCopyDates.askRowText(d))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Button("Enter a date…") {
                    typingDate.insert(id)
                    chosenCopyDate[id] = nil
                    declinedCopyDate.remove(id)
                }
                .font(.system(size: 11))
                Button(declineLabel(id)) {
                    declinedCopyDate.insert(id)
                    chosenCopyDate[id] = nil
                    typingDate.remove(id)
                    archiveDates[id] = nil
                }
                .font(.system(size: 11))
                if declinedCopyDate.contains(id) {
                    Text("✓").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.leading, 8)
    }

    /// "Promote undated" — or, when the archive worked a date out itself,
    /// the truthful "Use the file's own date (…)".
    private func declineLabel(_ id: UUID) -> String {
        guard let e = plan.entries.first(where: { $0.recordID == id }), e.dateHint != .unknown else {
            return "Promote undated"
        }
        return "Use the file's own date (\(ArchiveRefile.datedLabel(e.dateHint)))"
    }

    // MARK: Warnings

    @ViewBuilder
    private var warnings: some View {
        let undated = plan.undatedCount
        let low = plan.lowConfidenceCount
        let already = plan.alreadyPromotedCount
        let offline = plan.skipped.filter { $0.reason == .offline }.count
        let inside = plan.skipped.filter { $0.reason == .insideArchiveRoot }.count
        VStack(alignment: .leading, spacing: 4) {
            if undated > 0 {
                // NOT "you can refile later" — the date chosen here is the
                // one the archive files it under (Update… can change it).
                warnLine("\(undated) undated — type a date below, or they land in Undated/",
                         color: .orange)
            }
            if low > 0 {
                warnLine("\(low) with a low-confidence inferred date — type a date below to override the guess",
                         color: .orange)
            }
            // Skips are named, not just counted (Rick 2026-08-16: "I
            // promoted five, four landed — which one and why?").
            ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, skip in
                // GH #190: name WHERE it is archived (O(skips), index reads).
                let at = model.promoteSkipDetail(recordID: skip.id, reason: skip.reason)
                warnLine("Skipped \(skip.filename) — \(VideoScanModel.skipReasonLabel(skip.reason))\(at.map { " as \($0)" } ?? "")",
                         color: .secondary)
            }
            let _ = (already, inside, offline)
            if let free = plan.freeBytesAtRoot {
                let ok = plan.hasEnoughFreeSpace
                warnLine(ok
                         ? "Free space on the archive volume: \(PromoteToArchiveJob.humanBytes(free)) — enough (needs about \(PromoteToArchiveJob.humanBytes(plan.requiredBytes)))"
                         : "Not enough free space: \(PromoteToArchiveJob.humanBytes(free)) free, about \(PromoteToArchiveJob.humanBytes(plan.requiredBytes)) needed",
                         color: ok ? .green : .red)
            } else {
                warnLine("Could not read free space on the archive volume — is it connected?", color: .orange)
            }
            if let mismatch = model.masterArchiveIdentityMismatch {
                warnLine(mismatch, color: .red)
            }
            if model.isReadOnly {
                warnLine("This Mac is a read-only viewer of the catalog — promotion runs on the master Mac.", color: .red)
            }
            warnLine("Every copy is verified byte-for-byte (SHA-256), logged in the manifest and LOCKED — only Update… can change it. Promoted files become ★★★.",
                     color: .secondary)
        }
    }

    private func warnLine(_ text: String, color: Color) -> some View {
        Label(text, systemImage: color == .green ? "checkmark.circle" : "info.circle")
            .font(.system(size: 12))
            .foregroundColor(color)
    }

    // MARK: Names + typed dates

    /// How many entries get an editable name row. A huge batch promote is
    /// about moving bytes, not christening — the fields would be noise.
    private static let maxNamingRows = 6

    /// "Names in the archive" — a vertical list, one row per file: role
    /// label (from Assess) or the filename, then the name to use. Empty =
    /// keep that file's own name. Masters on disk are never renamed.
    @ViewBuilder
    private var archiveNameSection: some View {
        if plan.entries.count <= Self.maxNamingRows {
            GroupBox("Names in the archive") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.entries) { entry in
                        namingRow(entry)
                    }
                    if genericNameWarning {
                        Label("A generic filename tells the archive nothing — name it for the people, place, or occasion. The original file is never renamed.",
                              systemImage: "character.cursor.ibeam")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onAppear { archiveTitles = plan.archiveTitles }
        } else {
            // Large batches: only the date fields the reader asked for.
            let typing = plan.entries.filter { typingDate.contains($0.recordID) }
            if !typing.isEmpty {
                GroupBox("Dates to enter") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(typing) { entry in
                            Text(entry.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            dateRow(entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func namingRow(_ entry: ArchivePromotePlan.Entry) -> some View {
        let stem = (entry.filename as NSString).deletingPathExtension
        let role = plan.roleLabels[entry.recordID]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(role ?? stem)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 130, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.filename)
                TextField("keep “\(stem)”", text: titleBinding(entry.recordID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("promoteSheet.archiveName.\(role ?? stem)")
            }
            Text(namePreview(entry))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 138)
            dateRow(entry)
        }
    }

    /// Asked for when the archive does not already know the date, or when
    /// the reader chose "Enter a date…" instead of a copy's date. A file with
    /// a solid date needs no question, and asking anyway is how a reader
    /// learns to click past the sheet without reading it.
    @ViewBuilder
    private func dateRow(_ entry: ArchivePromotePlan.Entry) -> some View {
        let id = entry.recordID
        let fromCopies = chosenCopyDate[id] != nil
        if typingDate.contains(id) || (!fromCopies && (entry.dateHint == .unknown || entry.lowConfidenceDate)) {
            let typed = archiveDates[id] ?? ""
            let parsed = ArchiveDateEntry.parse(typed)
            HStack(spacing: 8) {
                Text("date")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 130, alignment: .trailing)
                TextField("1947, March 1947, 1947-03-12, 1940s",
                          text: dateBinding(id))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("promoteSheet.archiveDate.\(id)")
                Text(ArchiveDateEntry.guidance(for: parsed, typed: typed))
                    .font(.system(size: 10))
                    .foregroundColor(parsed == nil && !typed.isEmpty ? .orange : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func dateBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { archiveDates[id] ?? "" },
                set: { archiveDates[id] = $0 })
    }

    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { archiveTitles[id] ?? "" },
                set: { archiveTitles[id] = $0 })
    }

    /// The hint this entry will be filed under, as the sheet stands.
    private func effectiveHint(_ e: ArchivePromotePlan.Entry) -> ArchiveDateHint {
        PromoteSheetDates.resolve(entryHint: e.dateHint, typed: archiveDates[e.recordID],
                                  copy: chosenCopyDate[e.recordID],
                                  declined: declinedCopyDate.contains(e.recordID)).hint ?? e.dateHint
    }

    /// Live preview of this entry's destination filename.
    private func namePreview(_ e: ArchivePromotePlan.Entry) -> String {
        let title = VideoScanModel.normalizedTitle(archiveTitles[e.recordID])
        let stemSource = title ?? (e.filename as NSString).deletingPathExtension
        let ext = (e.filename as NSString).pathExtension
        let hint = effectiveHint(e)
        let stem = "\(hint.filenamePrefix)_\(ArchivePathResolver.slug(from: stemSource))"
        let name = ext.isEmpty ? stem : "\(stem).\(ext.lowercased())"
        // Keep the entry's own bucket (audio stays audio); the date part follows the hint.
        let bucket = e.folder.split(separator: "/").first.map(String.init) ?? MasterArchiveLayout.videoBucket
        let datePart = ArchivePathResolver.folder(for: .videoAndAudio, hint: hint).split(separator: "/").dropFirst()
        let folder = ([bucket] + datePart.map(String.init)).joined(separator: "/")
        return "→ \(hint == e.dateHint ? e.folder : folder)/\(name)"
    }

    private var genericNameWarning: Bool {
        plan.entries.contains { e in
            VideoScanModel.normalizedTitle(archiveTitles[e.recordID]) == nil
                && ArchiveNameAdvisor.isGenericStem((e.filename as NSString).deletingPathExtension)
        }
    }

    private func confirm() {
        var confirmed = plan
        confirmed.allowUnprobeable = overrideUnprobeable
        confirmed.archiveTitles = archiveTitles.compactMapValues { VideoScanModel.normalizedTitle($0) }
        // Only entries with a real answer. An unparseable string is NOT an
        // override — it must not silently become Undated when they meant
        // something.
        for e in plan.entries {
            let id = e.recordID
            let r = PromoteSheetDates.resolve(entryHint: e.dateHint, typed: archiveDates[id],
                                              copy: chosenCopyDate[id], declined: declinedCopyDate.contains(id))
            if let hint = r.hint { confirmed.archiveDateOverrides[id] = hint }
            if let source = r.source { confirmed.archiveDateSources[id] = source }
        }
        _ = fileOpsCenter.startedByUser { $0.startPromote(plan: confirmed, model: model) }
        dismiss()
        MediaFileOperationsWindowOpener.openBehindMain(openWindow)   // Media File Operations window (legacy id)
    }
}

/// The sheet's per-entry answer → override + source. Pure (tested).
enum PromoteSheetDates {
    /// A typed date wins; else a chosen copy date; declined / nothing = no
    /// override (the file's own date stands).
    static func resolve(entryHint: ArchiveDateHint, typed: String?, copy: PromoteCopyDate?,
                        declined: Bool) -> (hint: ArchiveDateHint?, source: ArchiveDateSource?) {
        if let t = typed, let hint = ArchiveDateEntry.parse(t)?.hint { return (hint, .typed) }
        if !declined, let copy, let hint = copy.hint { return (hint, PromoteCopyDates.source(for: copy)) }
        return (nil, nil)
    }
}
