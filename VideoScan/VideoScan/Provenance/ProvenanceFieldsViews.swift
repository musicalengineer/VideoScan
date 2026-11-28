// ProvenanceFieldsViews.swift — the views of the three provenance fields
// (DECISIONS 2026-11-27):
//   * ProvenanceFieldsEditor — the compact form: Digitized · Tape · Source,
//     every field optional, Save and Skip. One form, reused by the review
//     list, the manual add (Triage ▸ Import to Workspace) and the Inspector's
//     Edit Provenance….
//   * ProvenanceReviewSheet — the review list: one row per content, the form
//     for the selected one, prefilled from catalog.sqlite.
//   * NewMediaProvenanceBanner — the one non-modal notice, [Review…] [Skip].
//   * InspectorProvenanceFieldsLines — "Digitized: … / Tape: … / Source: …"
//     ("unknown" when missing), read from catalog.sqlite.
// Views only: no SQL and no commit here — every save goes through
// ProvenanceFieldsStore.save (rule 4). Nothing O(records) in a body: the
// review rows are built once, from the notice's record ids (O(contents)).
//
// (For Rick: `.task(id:)` ≈ start an async read when the key changes and
// cancel the previous one; `.id(x)` on a view ≈ destroy and re-create it when
// x changes, which re-seeds its @State from the new initial values.)

import SwiftUI
import VideoScanCore

// MARK: - The form

struct ProvenanceFieldsEditor: View {
    let initial: ProvenanceFieldValues
    /// The content is archived: its digitization date is Update…'s (rule 3).
    let dateLocked: Bool
    /// nil = saved; else the words to show (nothing was saved).
    let onSave: (ProvenanceFieldValues) -> String?
    let onSkip: () -> Void

    @State private var digitized: String
    @State private var tape: String
    @State private var source: String
    @State private var message: String?

    init(initial: ProvenanceFieldValues, dateLocked: Bool,
         onSave: @escaping (ProvenanceFieldValues) -> String?, onSkip: @escaping () -> Void) {
        self.initial = initial
        self.dateLocked = dateLocked
        self.onSave = onSave
        self.onSkip = onSkip
        _digitized = State(initialValue: initial.digitizedOn ?? "")
        _tape = State(initialValue: initial.carrier ?? "")
        _source = State(initialValue: initial.source ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(ProvenanceField.digitizedOn.label + ":").gridColumnAlignment(.trailing)
                    TextField(ProvenanceFieldsWords.digitizedPlaceholder, text: $digitized)
                        .disabled(dateLocked)
                        .help(dateLocked ? ProvenanceFieldsWords.archivedDateHelp : "When the tape or film was digitized")
                        .accessibilityIdentifier("provenanceFields.digitized")
                }
                GridRow {
                    Text(ProvenanceField.carrier.label + ":")
                    TextField(ProvenanceFieldsWords.tapePlaceholder, text: $tape)
                        .accessibilityIdentifier("provenanceFields.tape")
                }
                GridRow {
                    Text(ProvenanceField.source.label + ":")
                    TextField(ProvenanceFieldsWords.sourcePlaceholder, text: $source)
                        .accessibilityIdentifier("provenanceFields.source")
                }
            }
            .textFieldStyle(.roundedBorder)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(ProvenanceFieldsWords.skipButton) { onSkip() }
                Button(ProvenanceFieldsWords.saveButton) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        switch ProvenanceFields.values(digitizedOn: dateLocked ? (initial.digitizedOn ?? "") : digitized, carrier: tape, source: source) {
        case .failure(let refusal): message = refusal.words
        case .success(let values): message = onSave(values)
        }
    }
}

// MARK: - The review list

/// One row of the review list: one content, shown by one of its files.
struct ProvenanceReviewItem: Identifiable, Equatable {
    let digest: String
    let recordID: UUID
    let filename: String
    let place: String
    /// The file's own container creation stamp — a hint for the digitized
    /// date, labelled as what it is (never shown as the filming date).
    let containerDate: Date?
    let dateLocked: Bool
    var id: String { digest }

    var containerDateText: String {
        containerDate.map { "Container stamp: " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Container stamp: unknown"
    }

    /// The rows for `contents`, each shown by its first record still in the
    /// catalog. O(contents).
    static func make(contents: [NewContentFinder.NewContent], record: (UUID) -> VideoRecord?,
                     dateLocked: (VideoRecord) -> Bool) -> [ProvenanceReviewItem] {
        contents.compactMap { content in
            guard let rec = content.recordIDs.lazy.compactMap(record).first else { return nil }
            return item(rec, digest: content.digest, dateLocked: dateLocked(rec))
        }
    }

    static func item(_ rec: VideoRecord, digest: String, dateLocked: Bool) -> ProvenanceReviewItem {
        ProvenanceReviewItem(digest: digest, recordID: rec.id, filename: rec.filename,
                             place: rec.volumeName.isEmpty ? rec.directory : rec.volumeName,
                             containerDate: rec.embeddedCreationDate, dateLocked: dateLocked)
    }
}

struct ProvenanceReviewSheet: View {
    let items: [ProvenanceReviewItem]
    let store: ProvenanceFieldsStore
    /// Where the rows say they were entered ("review list", "inspector").
    let place: String
    let subtitle: String
    /// How many contents were saved.
    let onDone: (Int) -> Void

    @State private var selection: String?
    @State private var saved: Set<String> = []
    @State private var skipped: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NewMediaProvenanceWords.reviewTitle).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if items.count > 1 {
                    List(items, selection: $selection) { item in
                        HStack(spacing: 6) {
                            Image(systemName: saved.contains(item.digest) ? "checkmark.circle.fill"
                                  : skipped.contains(item.digest) ? "arrow.uturn.right.circle" : "circle")
                                .foregroundStyle(saved.contains(item.digest) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.filename).lineLimit(1).truncationMode(.middle)
                                Text(item.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(item.digest)
                    }
                    .listStyle(.bordered)
                    .frame(minWidth: 220, idealWidth: 260, minHeight: 240)
                }
                if let item = items.first(where: { $0.digest == selection }) {
                    ProvenanceReviewEditorHost(item: item, store: store, place: place,
                                               onSaved: { saved.insert(item.digest); advance(from: item) },
                                               onSkip: { skipped.insert(item.digest); advance(from: item) })
                        .id(item.digest)
                        .frame(minWidth: 380)
                } else {
                    Text("Nothing left to review.").foregroundStyle(.secondary).frame(minWidth: 380, minHeight: 120)
                }
            }
            HStack {
                Spacer()
                Button(NewMediaProvenanceWords.doneButton) { onDone(saved.count) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: items.count > 1 ? 680 : 420)
        .onAppear { if selection == nil { selection = items.first?.digest } }
    }

    /// The next row not yet saved or skipped; none left → Done.
    private func advance(from item: ProvenanceReviewItem) {
        let open = items.filter { !saved.contains($0.digest) && !skipped.contains($0.digest) }
        if let next = open.first(where: { $0.digest != item.digest }) {
            selection = next.digest
        } else {
            onDone(saved.count)
        }
    }
}

/// Reads what stands for the content from catalog.sqlite, then shows the form.
private struct ProvenanceReviewEditorHost: View {
    let item: ProvenanceReviewItem
    let store: ProvenanceFieldsStore
    let place: String
    let onSaved: () -> Void
    let onSkip: () -> Void
    @State private var reading: ProvenanceFieldsStore.Reading?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.filename).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(item.containerDateText).font(.caption).foregroundStyle(.secondary)
            switch reading {
            case .values(_, let values)?:
                ProvenanceFieldsEditor(initial: values, dateLocked: item.dateLocked, onSave: { typed in
                    switch store.save(digest: item.digest, typed: typed, enteredIn: place) {
                    case .saved, .unchanged:
                        onSaved()
                        return nil
                    case .refused(let words):
                        return words.prefix(1).uppercased() + words.dropFirst()
                    }
                }, onSkip: onSkip)
            case .unavailable(_, let why)?:
                Text("Provenance cannot be read now (\(why)).").foregroundStyle(.secondary)
                HStack { Spacer(); Button(ProvenanceFieldsWords.skipButton) { onSkip() } }
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.digest) {
            let now = await store.readCurrent(digest: item.digest)
            if !Task.isCancelled { reading = now }
        }
    }
}

// MARK: - The notice

struct NewMediaProvenanceBanner: View {
    @ObservedObject var store: NewMediaProvenanceStore
    let fields: ProvenanceFieldsStore
    /// NOT observed: read once when Review… is pressed.
    let model: VideoScanModel

    private struct Review: Identifiable {
        let id = UUID()
        let items: [ProvenanceReviewItem]
    }
    @State private var review: Review?

    var body: some View {
        if let notice = store.notice {
            HStack(spacing: 10) {
                Image(systemName: "film.stack").foregroundStyle(.teal)
                Text(notice.text).font(.system(size: 13))
                Spacer()
                Button(NewMediaProvenanceWords.reviewButton) {
                    review = Review(items: ProvenanceReviewItem.make(contents: notice.contents, record: { model.record(forID: $0) },
                                                                     dateLocked: { model.isDateReadOnly($0) }))
                }
                .help(NewMediaProvenanceWords.reviewHelp)
                Button(NewMediaProvenanceWords.skipButton) { store.skip() }
                    .help(NewMediaProvenanceWords.skipHelp)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.10))
            .accessibilityIdentifier("newMedia.provenanceNotice")
            .sheet(item: $review) { r in
                ProvenanceReviewSheet(items: r.items, store: fields, place: "review list",
                                      subtitle: NewMediaProvenanceWords.reviewSubtitle(r.items.count)) { saved in
                    review = nil
                    store.reviewed(saved: saved)
                }
            }
        }
    }
}

// MARK: - The Inspector

struct InspectorProvenanceFieldsLines: View {
    let record: VideoRecord
    /// The selected file's whole-file digest (CatalogCommit.digest(of:)); nil = none yet.
    let digest: String?
    let dateLocked: Bool
    @ObservedObject var store: ProvenanceFieldsStore
    @State private var completed: Completed?
    @State private var editing: ProvenanceReviewItem?

    struct ReadKey: Equatable {
        let digest: String?
        let revision: Int
    }

    private struct Completed: Equatable {
        let key: ReadKey
        let reading: ProvenanceFieldsStore.Reading
    }

    /// The lines shown (pure; the truth tests read it). A reading for any
    /// other content than `digest` is "still reading", never shown.
    static func lines(digest: String?, reading: ProvenanceFieldsStore.Reading?) -> [String] {
        guard let digest else { return [ProvenanceFieldsWords.inspectorNoDigest] }
        guard let reading, reading.digest == digest.lowercased() else { return ["Digitized: …", "Tape: …", "Source: …"] }
        switch reading {
        case .values(_, let values): return ProvenanceFields.lines(values)
        case .unavailable(_, let why): return ["Digitized, tape, source: not readable now (\(why))"]
        }
    }

    var body: some View {
        let key = ReadKey(digest: digest, revision: store.revision)
        let shown = Self.lines(digest: digest, reading: completed?.key == key ? completed?.reading : nil)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown, id: \.self) { line in
                Text(line).font(.callout).textSelection(.enabled)
            }
            if let digest {
                Button(ProvenanceFieldsWords.editButton) {
                    editing = ProvenanceReviewItem.item(record, digest: digest, dateLocked: dateLocked)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(ProvenanceFieldsWords.editHelp)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("catalog.inspector.provenanceFields")
        .task(id: key) {
            guard let digest = key.digest else { return }
            let now = await store.readCurrent(digest: digest)
            if !Task.isCancelled { completed = Completed(key: key, reading: now) }
        }
        .sheet(item: $editing) { item in
            ProvenanceReviewSheet(items: [item], store: store, place: "inspector",
                                  subtitle: "Every field is optional; a field left empty stays unknown.") { _ in editing = nil }
        }
    }
}
