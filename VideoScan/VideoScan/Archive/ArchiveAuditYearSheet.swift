// ArchiveAuditYearSheet.swift
// Archive tab — "Audit <year>…" (Rick 2026-10-07), opened from a year
// header's right-click on the decade page. One question: does this year
// hold DISTINCT family events, or the same footage repeated?
//
//   header   "1995: 4 events · 1 repeat · 1 filed from 1992"
//   Events   one row per occasion, its videos beneath (thumbnail if cached)
//   Repeats  each group with its evidence in plain words, and three
//            NON-destructive actions: These are different, keep both ·
//            Show in Catalog · Update date… (the existing Update… sheet —
//            name/date only; archived files are otherwise read-only)
//   Other    videos with no occasion, each with Tag occasion ▸ …
//
// No delete here, ever in v1 — "keep the best" is the delete-excess lane's
// job. The report is built OFF the main actor (ArchiveAuditBuilder), once
// per open and again only after one of Rick's own actions; the body only
// lays out the finished report.

import AppKit
import SwiftUI
import VideoScanCore

struct ArchiveAuditYearSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    let year: Int
    /// Main-actor projection (ArchiveView.auditSnapshot) — called once per
    /// (re)build, never from the body.
    let snapshot: @MainActor () -> (inputs: [ArchiveAuditInput], decisions: [ArchiveAuditDecision])
    let showInCatalog: ([UUID]) -> Void

    @State private var report: ArchiveAuditReport?
    /// Bumped after the Update… sheet closes (a date change refiles items).
    @State private var refreshToken = 0
    @State private var updatePreview: ArchiveUpdatePreview?
    @State private var updateRefusal: String?
    /// The last "keep both" — offered for Undo until the next one.
    @State private var lastKept: ArchiveAuditRepeatGroup?
    /// Tag occasion ▸ Other… asks for a word.
    @State private var otherTagTarget: ArchiveAuditInput?
    @State private var otherWord = ""

    private struct BuildKey: Equatable { let revision: Int; let token: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        eventsSection(report)
                        repeatsSection(report)
                        unlabeledSection(report)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking through \(String(year))…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let kept = lastKept {
                    Button("Undo “keep both”") {
                        model.archiveAuditUndoKeepBoth(kept)
                        lastKept = nil
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 640)
        .task(id: BuildKey(revision: model.archiveAuditRevision, token: refreshToken)) { await rebuild() }
        .sheet(item: $updatePreview) { preview in
            ArchiveUpdateSheet(preview: preview)
                .onDisappear {
                    model.closeArchiveUpdate(preview)
                    refreshToken &+= 1
                }
        }
        .alert("Update…", isPresented: Binding(get: { updateRefusal != nil },
                                              set: { if !$0 { updateRefusal = nil } })) {
            Button("OK", role: .cancel) { updateRefusal = nil }
        } message: {
            Text(updateRefusal ?? "")
        }
        .alert("Tag occasion", isPresented: Binding(get: { otherTagTarget != nil },
                                                    set: { if !$0 { otherTagTarget = nil } })) {
            TextField("Halloween, Graduation, Wedding…", text: $otherWord)
            Button("Tag") {
                if let t = otherTagTarget {
                    model.archiveAuditTag(itemID: t.id, occasion: .other, word: otherWord, title: t.title)
                }
                otherTagTarget = nil
            }
            Button("Cancel", role: .cancel) { otherTagTarget = nil }
        } message: {
            Text("What was the occasion?")
        }
    }

    /// Project on the main actor (O(archived)), build off it.
    private func rebuild() async {
        let snap = snapshot()
        let built = await ArchiveAuditBuilder.buildOffMain(year: year, inputs: snap.inputs,
                                                           decisions: snap.decisions)
        guard !Task.isCancelled else { return }
        report = built
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audit \(String(year))")
                .font(.title2.weight(.semibold))
            Text(report?.verdict ?? " ")
                .font(.system(size: 16, weight: .medium))
                .accessibilityIdentifier("archive.audit.verdict")
            Text("Different family events, or the same footage more than once? Nothing here deletes or moves a file.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Events

    @ViewBuilder
    private func eventsSection(_ r: ArchiveAuditReport) -> some View {
        sectionTitle("Events")
        if r.events.isEmpty {
            quiet("No occasions found in \(String(year)).")
        }
        ForEach(r.events) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(eventTitle(event))
                    .font(.system(size: 15, weight: .semibold))
                ForEach(event.itemIDs, id: \.self) { id in
                    if let item = r.items[id] { itemRow(item) }
                }
            }
        }
    }

    private func eventTitle(_ e: ArchiveAuditEvent) -> String {
        let n = ArchiveAuditReport.plural(e.itemIDs.count, "video")
        let dur = ArchiveTimelinePath.friendlyDuration(seconds: e.seconds)
        return "\(e.occasion.emoji) \(e.word) \(String(year)) · \(n)" + (dur.isEmpty ? "" : " · \(dur)")
    }

    // MARK: Repeats

    @ViewBuilder
    private func repeatsSection(_ r: ArchiveAuditReport) -> some View {
        sectionTitle("Repeats")
        if r.repeats.isEmpty {
            quiet("Nothing looks repeated.")
        }
        ForEach(r.repeats) { group in
            repeatGroup(group, report: r)
        }
        if r.dismissedCount > 0 {
            quiet(r.dismissedCount == 1
                  ? "1 group you marked as different is not shown."
                  : "\(r.dismissedCount) groups you marked as different are not shown.")
        }
    }

    private func repeatGroup(_ g: ArchiveAuditRepeatGroup, report r: ArchiveAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.kind == .possiblySame ? "\(g.kind.heading) (possible)" : g.kind.heading)
                .font(.system(size: 15, weight: .semibold))
            ForEach(g.evidence, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(g.itemIDs + g.otherYearIDs, id: \.self) { id in
                if let item = r.items[id] { itemRow(item) }
            }
            HStack(spacing: 8) {
                Button("These are different, keep both") {
                    model.archiveAuditKeepBoth(g, titles: (g.itemIDs + g.otherYearIDs).compactMap { r.items[$0]?.title })
                    lastKept = g
                }
                .help("Remember that these are different videos — this group won't be flagged again.")
                .accessibilityIdentifier("archive.audit.keepBoth")
                Button("Show in Catalog") { showInCatalog(g.itemIDs + g.otherYearIDs) }
                if let first = g.itemIDs.first, let item = r.items[first], canUpdate(item) {
                    Button("Update date…") { openUpdate(item) }
                        .help("Change “\(item.title)”'s date or name with the archive's Update… sheet.")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: Other / unlabeled

    @ViewBuilder
    private func unlabeledSection(_ r: ArchiveAuditReport) -> some View {
        sectionTitle("Other / unlabeled")
        if r.unlabeledIDs.isEmpty {
            quiet("Every video has an occasion.")
        }
        ForEach(r.unlabeledIDs, id: \.self) { id in
            if let item = r.items[id] {
                HStack {
                    itemRow(item)
                    tagMenu(item)
                }
            }
        }
    }

    private func tagMenu(_ item: ArchiveAuditInput) -> some View {
        Menu("Tag occasion") { tagButtons(item) }
            .menuStyle(.button)
            .fixedSize()
            .controlSize(.small)
            .accessibilityIdentifier("archive.audit.tagOccasion")
    }

    /// Christmas / Thanksgiving / Birthday / Trip / Other… (+ clear).
    @ViewBuilder
    private func tagButtons(_ item: ArchiveAuditInput) -> some View {
        ForEach([ArchiveOccasion.christmas, .thanksgiving, .birthday, .trip], id: \.self) { o in
            Button("\(o.emoji) \(o.word)") { model.archiveAuditTag(itemID: item.id, occasion: o, title: item.title) }
        }
        Button("\(ArchiveOccasion.other.emoji) Other…") {
            otherWord = ""
            otherTagTarget = item
        }
        if item.occasionIsUserTag {
            Divider()
            Button("Remove my tag") { model.archiveAuditClearTag(itemID: item.id, title: item.title) }
        }
    }

    // MARK: One item

    private func itemRow(_ item: ArchiveAuditInput) -> some View {
        HStack(spacing: 10) {
            ArchiveAuditThumbnail(paths: item.thumbnailPaths)
            Text(item.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.middle)
            if let cue = item.occasion { ArchiveOccasionCueView(cue: cue) }
            if !item.friendlyDuration.isEmpty {
                Text(item.friendlyDuration).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let y = item.year, y != year {
                Text("filed in \(String(y))").font(.system(size: 13)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu { itemMenu(item) }
    }

    @ViewBuilder
    private func itemMenu(_ item: ArchiveAuditInput) -> some View {
        Button("Show in Catalog") { showInCatalog([item.id]) }
        Button("Update date…") { openUpdate(item) }
            .disabled(!canUpdate(item))
        Menu("Tag occasion") { tagButtons(item) }
    }

    // MARK: Update…

    private func canUpdate(_ item: ArchiveAuditInput) -> Bool {
        guard !model.isReadOnly, model.masterArchive != nil, let rec = model.record(forID: item.id) else { return false }
        return model.archiveCopyForUpdate(rec) != nil
    }

    private func openUpdate(_ item: ArchiveAuditInput) {
        let id = item.id
        Task {
            switch await model.openArchiveUpdate(recordID: id) {
            case .success(let p): updatePreview = p
            case .failure(let r): updateRefusal = r.message
            }
        }
    }

    // MARK: Bits

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func quiet(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.secondary)
    }
}

// MARK: - Thumbnail (cached frames only)

/// A small frame when one is ALREADY cached — memory first, then the
/// on-disk preview cache (a stat + JPEG decode, off the main actor).
/// Never decodes video; no frame → a quiet film glyph. Same discipline as
/// PersonVideosSection.
struct ArchiveAuditThumbnail: View {
    @EnvironmentObject var model: VideoScanModel
    let paths: [String]
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 48, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: paths) { await load() }
    }

    private func load() async {
        for p in paths {
            if let cached = model.thumbnailCache.object(forKey: p as NSString) { image = cached; return }
        }
        let disk = model.previewDiskCache
        let candidates = paths
        let found: CGImage? = await Task.detached(priority: .utility) {
            for p in candidates {
                guard let sig = PreviewDiskCache.fileSignature(atPath: p) else { continue }
                if let img = disk.lookup(path: p, mtime: sig.mtime, size: sig.size) { return img }
            }
            return nil
        }.value
        if let found, !Task.isCancelled { image = NSImage(cgImage: found, size: .zero) }
    }
}
