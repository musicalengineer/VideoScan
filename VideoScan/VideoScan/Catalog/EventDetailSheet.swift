// EventDetailSheet.swift
// Triage ▸ Events — one suggestion or one confirmed event, opened: its
// recordings with their evidence lines ("caption @ 1:35 — …cake with
// candles…", "transcript — …happy birthday dear Timmy…", "folder name
// says 'xmas'"), Open through the catalog's opener, accept / reject a
// member, Rename, "These are different occasions", Merge with….
//
// The sheet holds only the subject's KEY and reads the current value from
// the store each render (O(1) lookup), so a decision made here shows at
// once; a suggestion that just became a confirmed event says so.
// Thumbnails come from the on-disk preview cache (a stat + JPEG decode,
// off the main actor); nothing here ever decodes video.

import SwiftUI
import VideoScanCore

/// What the sheet shows. (For Rick: an enum with payloads as the sheet's
/// `item`; SwiftUI needs it `Identifiable` to present one at a time.)
enum EventsDetailSubject: Identifiable, Equatable {
    case suggestion(String)
    case confirmed(UUID)

    var id: String {
        switch self {
        case .suggestion(let key): return "s:" + key
        case .confirmed(let id): return "e:" + id.uuidString
        }
    }
}

struct EventDetailSheet: View {
    let subject: EventsDetailSubject
    let model: VideoScanModel
    @ObservedObject var store: EventsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming = false
    /// The rename field takes focus the moment it appears (repo rule:
    /// @FocusState + .defaultFocus, never a key on the container).
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch subject {
            case .suggestion(let key):
                if let s = store.suggestionByKey[key] { suggestionBody(s) } else { gone("This suggestion has your answer now.") }
            case .confirmed(let id):
                if let e = store.confirmedByID[id] { confirmedBody(e) } else { gone("This event was merged or dismissed.") }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
    }

    private func gone(_ words: String) -> some View {
        Text(words).font(.system(size: 13)).foregroundStyle(.secondary)
    }

    // MARK: A suggestion

    @ViewBuilder
    private func suggestionBody(_ s: EventSuggestion) -> some View {
        titleRow(name: s.name, categories: s.categories, dateWords: s.dateWords, note: s.note)
        memberList(s.members) { m in
            Button(EventsWords.notThisOne) { store.reject(m, in: s) }
                .help("Not \(s.primaryCategory) — this recording leaves the suggestion")
        }
        HStack {
            if renaming {
                nameField { confirmNamed(s) }
                Button(EventsWords.confirm) { confirmNamed(s) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button(EventsWords.confirm) { store.confirm(s) }
                Button(EventsWords.rename) { beginRename(s.name) }
            }
            Button(EventsWords.dismiss) { store.dismiss(s) }
            if s.folders.count > 1 {
                Button(EventsWords.differentOccasions) { store.markDifferentOccasions(in: s, model: model) }
            }
        }
        .controlSize(.small)
        .disabled(store.decisions.isReadOnly)
    }

    private func confirmNamed(_ s: EventSuggestion) {
        store.confirm(s, name: name)
        renaming = false
    }

    // MARK: A confirmed event

    @ViewBuilder
    private func confirmedBody(_ e: ConfirmedEvent) -> some View {
        titleRow(name: e.name, categories: e.categories, dateWords: e.dateWords, note: nil)
        memberList(e.members) { m in
            Button(EventsWords.notThisOne) { store.setMember(m, of: e, accepted: false) }
        }
        HStack {
            if renaming {
                nameField { renameNow(e) }
                Button(EventsWords.rename) { renameNow(e) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button(EventsWords.rename) { beginRename(e.name) }
            }
            Button(EventsWords.dismiss) { store.dismiss(e) }
            mergeMenu(e)
        }
        .controlSize(.small)
        .disabled(store.decisions.isReadOnly)
    }

    private func renameNow(_ e: ConfirmedEvent) {
        store.rename(e, to: name)
        renaming = false
    }

    /// The store's precomputed list (newest first); the event itself is
    /// greyed out rather than filtered per render.
    private func mergeMenu(_ e: ConfirmedEvent) -> some View {
        Menu(EventsWords.mergeWith) {
            ForEach(store.mergeCandidates) { other in
                Button(other.name) { store.merge(e, into: other) }
                    .disabled(other.id == e.id)
            }
        }
        .disabled(store.mergeCandidates.count < 2)
        .frame(maxWidth: 200)
    }

    private func beginRename(_ current: String) {
        name = current
        renaming = true
        nameFocused = true
    }

    /// The rename field: focused on appearance, Return submits.
    private func nameField(onSubmit: @escaping () -> Void) -> some View {
        TextField("Name", text: $name)
            .frame(maxWidth: 320)
            .focused($nameFocused)
            .defaultFocus($nameFocused, true)
            .onSubmit(onSubmit)
    }

    // MARK: Shared pieces

    private func titleRow(name: String, categories: [String], dateWords: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.title3.weight(.semibold))
            Text("\(categories.joined(separator: " · ")) · \(dateWords)").font(.system(size: 12)).foregroundStyle(.secondary)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }

    private func memberList(_ members: [EventMember], @ViewBuilder action: @escaping (EventMember) -> some View) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(members) { m in
                    EventMemberRow(member: m, model: model, onOpen: { open(m) }) { action(m) }
                }
            }
        }
        .frame(minHeight: 220, maxHeight: 520)
    }

    /// The catalog's opener (the Catalog tab's double-click), one record.
    private func open(_ m: EventMember) {
        guard let rec = model.record(forID: m.id) else {
            model.eventsNote("\(m.filename) is not in the catalog now — nothing opened.")
            return
        }
        CatalogOpenAction.open(ids: [rec.id], rows: [rec], gesture: "Events", model: model)
    }
}

// MARK: - One member

struct EventMemberRow<Action: View>: View {
    let member: EventMember
    let model: VideoScanModel
    let onOpen: () -> Void
    @ViewBuilder let action: () -> Action
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(member.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let copies = EventsWords.copies(member.copies) {
                        Text(copies).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if member.state == .rejected { Text("rejected").font(.system(size: 11)).foregroundStyle(.red) }
                }
                Text("\(member.date.words) · \(member.volumeName)").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(member.evidence, id: \.self) { line in
                    Text(evidenceWords(line)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let link = member.link { Text(link).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let lineage = member.lineage { Text(lineage).font(.system(size: 11)).foregroundStyle(.secondary) }
                if !member.people.isEmpty {
                    Text(member.people.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: 4) {
                Button(EventsWords.open, action: onOpen).disabled(member.path.isEmpty)
                action()
            }
            .controlSize(.small)
        }
        .help(member.path)
        .task(id: member.path) { await loadCachedThumbnail() }
    }

    /// "caption @ 1:35 — …"; "transcript — …"; "folder name — says 'xmas'".
    private func evidenceWords(_ line: EvidenceLine) -> String {
        let when = line.timestamp.map { " @ \(Int($0) / 60):\(String(format: "%02d", Int($0) % 60))" } ?? ""
        return "\(line.category) · \(line.source.words)\(when) — \(line.words)"
    }

    @ViewBuilder
    private var thumb: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFill()
                .frame(width: 96, height: 54).clipped().cornerRadius(4)
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 96, height: 54)
        }
    }

    /// Cached frames only: memory first, then the on-disk preview cache
    /// (a stat + JPEG decode, off the main actor). Never decodes video.
    private func loadCachedThumbnail() async {
        guard !member.path.isEmpty else { return }
        if let cached = model.thumbnailCache.object(forKey: member.path as NSString) {
            thumbnail = cached
            return
        }
        let path = member.path
        let disk = model.previewDiskCache
        let image: CGImage? = await Task.detached(priority: .utility) {
            guard let sig = PreviewDiskCache.fileSignature(atPath: path) else { return nil }
            return disk.lookup(path: path, mtime: sig.mtime, size: sig.size)
        }.value
        if let image, !Task.isCancelled { thumbnail = NSImage(cgImage: image, size: .zero) }
    }
}
