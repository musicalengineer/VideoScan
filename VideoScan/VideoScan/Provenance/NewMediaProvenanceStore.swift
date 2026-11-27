// NewMediaProvenanceStore.swift — "N new media files came into the catalog —
// review their provenance when you can." (DECISIONS 2026-11-27: the notice
// fires when Fill In Full Hashes lands content the catalog has never seen;
// identity is whole-file SHA-256; it can always be skipped.)
//
// One sentence: files that come INTO the catalog — a scan merge's genuine
// strangers (not re-seen at their path, not a moved file that kept its
// record) and files added by hand — wait here until Fill In Full Hashes gives
// them a whole-file SHA-256; then Core's NewContentFinder decides which are
// content the catalog has never seen, and ONE non-modal notice offers to
// review exactly those (one row per content).
//
// Shape: a feature store behind a seam (rule 12) — the model holds ONE
// (`VideoScanModel.newMediaProvenance`); nothing extends the model. Three
// doors in: `register` (scan merge, manual add), `evaluate` (after Fill In
// Full Hashes saves its hashes), `skip` / `reviewed` (the notice's buttons).
// It never writes the catalog: the review list writes through
// ProvenanceFieldsStore.
//
// Remembered per CONTENT, not path: a digest offered once (reviewed or
// skipped) is never offered again, and a copy of content the catalog already
// holds is settled quietly. Never shown for zero.
//
// Persistence: `new-media-provenance.json` beside the catalog — the waiting
// record ids and the offered digests (bookkeeping only, never a fact shown as
// truth; a lost file means at most one notice fewer or one offered again).
// Written atomically after each change; a session without a catalog folder
// keeps it in memory. Worst case: 100k waiting ids (~4 MB) plus 100k offered
// digests (~7 MB).
//
// Logging: one line per change through the one sink (`note`): files queued,
// the decision (new / copies / still waiting), the notice shown, skipped,
// reviewed.
//
// (For Rick: a persistent work queue keyed by record id, drained by a pure
// set-difference when the hashes arrive — like a C++ pending-set flushed
// against an unordered_set of seen keys.)

import Combine
import Foundation
import VideoScanCore

/// The words (pure; tests read them).
enum NewMediaProvenanceWords {
    static func notice(_ count: Int) -> String {
        count == 1
            ? "1 new media file came into the catalog — review its provenance when you can."
            : "\(count.formatted()) new media files came into the catalog — review their provenance when you can."
    }
    static let reviewButton = "Review…"
    static let skipButton = "Skip"
    static let reviewHelp = "Enter the digitization date, the tape and the source of each new file. Every field is optional."
    static let skipHelp = "Nothing is required. These files are not offered again; their provenance can be entered any time from the Inspector."
    static let reviewTitle = "Review provenance"
    static func reviewSubtitle(_ count: Int) -> String {
        "\(count.formatted()) new media file\(count == 1 ? "" : "s"). Every field is optional — Skip leaves a file as it is."
    }
    static let doneButton = "Done"
    static let manualAddWaits = "Its provenance (digitized, tape, source) is asked once Content Analysis ▸ Full Hashes gives it a full SHA-256."
}

@MainActor
final class NewMediaProvenanceStore: ObservableObject {

    /// The one notice: the new contents it offers (first-seen order).
    struct Notice: Equatable, Identifiable {
        let id: UUID
        var contents: [NewContentFinder.NewContent]
        var count: Int { contents.count }
        var text: String { NewMediaProvenanceWords.notice(count) }
    }

    nonisolated static let fileName = "new-media-provenance.json"

    @Published private(set) var notice: Notice?
    /// Record ids waiting for a whole-file digest.
    private(set) var pending: Set<UUID> = []
    /// Digests ever offered (reviewed or skipped) — never offered again.
    private(set) var offered: Set<String> = []
    /// The one log sink.
    var note: (String) -> Void = { _ in }
    private var fileURL: URL?

    private struct Persisted: Codable {
        var version = 1
        var pending: [UUID]
        var offered: [String]
    }

    // MARK: Attach

    /// Keep the queue beside the catalog in `folder`. Reads what a previous
    /// session left (an unreadable file is said once and replaced).
    func attach(folder: URL) {
        let url = folder.appendingPathComponent(Self.fileName)
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let stored = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: url))
            pending.formUnion(stored.pending)
            offered.formUnion(stored.offered)
        } catch {
            note("New media: \(Self.fileName) could not be read (\(error)) — starting an empty queue; at most a notice is lost")
        }
    }

    // MARK: Doors in

    /// Files that came into the catalog (`why`: "scan of <volume>", "manual add").
    func register(_ ids: [UUID], why: String) {
        let fresh = ids.filter { !pending.contains($0) }
        guard !fresh.isEmpty else { return }
        pending.formUnion(fresh)
        persist()
        note("New media: \(fresh.count.formatted()) file(s) came into the catalog (\(why)) — "
             + "their provenance is offered once Fill In Full Hashes gives them a full SHA-256")
    }

    /// A rescan replaced re-seen records with fresh instances (old id → new
    /// id): a waiting file keeps waiting under its new id.
    func followReplacements(_ replacedBy: [UUID: UUID]) {
        let moved = replacedBy.filter { pending.contains($0.key) }
        guard !moved.isEmpty else { return }
        for (old, new) in moved {
            pending.remove(old)
            pending.insert(new)
        }
        persist()
    }

    /// Decide every waiting file that has a digest now; offer the new contents.
    /// O(records) only when something is waiting.
    @discardableResult
    func evaluate(records: [VideoRecord]) -> NewContentFinder.Outcome {
        guard !pending.isEmpty else { return NewContentFinder.Outcome() }
        let out = NewContentFinder.evaluate(records: records, pending: pending, offered: offered)
        guard !out.settled.isEmpty else { return out }
        pending.subtract(out.settled)
        offered.formUnion(out.newContents.map(\.digest))
        persist()
        note("New media: \(out.newContents.count.formatted()) new content(s), \(out.copiesOfKnown.formatted()) cop(ies) of content "
             + "already in the catalog, \(out.dropped.formatted()) gone or removed, \(out.waiting.count.formatted()) still waiting for a full hash")
        guard !out.newContents.isEmpty else { return out }
        var shown = notice ?? Notice(id: UUID(), contents: [])
        shown.contents.append(contentsOf: out.newContents)
        notice = shown
        note("New media: notice shown — \(shown.text)")
        return out
    }

    /// The notice's Skip: nothing is required; the contents stay offered.
    func skip() {
        guard let shown = notice else { return }
        notice = nil
        note("New media: skipped — \(shown.count.formatted()) content(s) not offered again; their provenance can be entered from the Inspector")
    }

    /// The review list closed.
    func reviewed(saved: Int) {
        guard let shown = notice else { return }
        notice = nil
        note("New media: reviewed — provenance saved for \(saved.formatted()) of \(shown.count.formatted()) content(s); the rest stay unknown")
    }

    // MARK: Persistence

    private func persist() {
        guard let fileURL else { return }
        let stored = Persisted(pending: pending.sorted { $0.uuidString < $1.uuidString }, offered: offered.sorted())
        do {
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            note("New media: \(Self.fileName) could not be written (\(error)) — the queue stays in memory this session")
        }
    }
}
