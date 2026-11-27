// AudioVerdictWithdrawal.swift — GH #518, Codex round 2 on schema v17.
//
// One sentence: a stale sound verdict "ok" is withdrawn as a CONTENT
// decision, never per copy — the stored verdict lives once per digest
// (`media_checks`, kind 'audio') and every copy of the content shows it.
//
// Why (Codex round 2, three P1s, one root cause): the verdict is stored per
// content but was withdrawn per copy. (1) Re-measure on [A "damaged", B "ok"]
// wrote B's "unverified" over the content's measured damage; (2) Verify
// Audio withdrew A only, so B's stale "ok" in memory was written back by
// B's next unrelated save (a star rating) — `CatalogRecordDiff` compares a
// record's derived values with what the store holds, and the store is shared.
//
// The rule (coordinator, 2026-11-27), in ONE synchronous main-actor step
// (no await between reading the copies and writing them):
//   * find every copy of the content by digest at that moment;
//   * if the content's stored verdict, or any copy, holds measured damage
//     ("damaged" / "attention"): KEEP it — never withdraw over damage — and
//     every copy is set to that damage (the newest-dated one), so no copy's
//     stale "ok" can be committed over it later;
//   * otherwise, if the store or any copy says "ok": every copy is set to
//     "unverified" with the same note and date, together;
//   * the stored verdict could not be read: change nothing (refuse rather
//     than guess — a withdrawal over damage the store may hold is the loss).
// The caller commits every changed copy (Re-measure: the same scoped
// synchronous commit as the card; Verify / Check Media: the debounced save,
// which commits every changed row in one pass).
//
// The store read happens BEFORE the step (async); the step itself is
// synchronous. Only the content's BOUND row is read; an imported catalog.json
// value (derived_unverified) shows on every copy at load, so the copies carry it.
//
// Memory: the copies of one content (references) and one short row.
// (For Rick: `@MainActor enum` with static funcs ≈ a namespace of free
// functions that must run on the UI thread — the thread that owns the records.)

import Foundation
import os
import VideoScanCore

private let withdrawalLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "audioVerdictWithdrawal")

@MainActor
enum AudioVerdictWithdrawal {

    /// What catalog.sqlite holds for the content's sound verdict, read just
    /// before the deciding step.
    enum StoredRead: Sendable, Equatable {
        /// No SQLite store, no digest, or no bound row.
        case none
        case check(StoredAudioCheck)
        /// Could not be read: the step changes nothing.
        case unreadable(String)
    }

    /// What the step did.
    struct Outcome {
        enum Kind: Equatable {
            /// Every copy now holds "unverified".
            case withdrew
            /// Measured damage stands; every copy holds it.
            case keptDamage(String)
            /// The stored verdict could not be read: nothing changed.
            case unreadable(String)
            /// No "ok" anywhere: nothing to withdraw.
            case nothingToWithdraw
        }
        var kind: Kind
        /// Copies whose verdict fields changed: commit these.
        var changed: [VideoRecord] = []
        /// Copies that held "ok" before the step.
        var heldOK = 0
        var copies = 0
    }

    /// One copy's verdict fields (≈ a POD tuple compared field by field).
    private struct Fields: Equatable {
        var status: String
        var note: String
        var date: Date?

        init(status: String, note: String, date: Date?) {
            self.status = status
            self.note = note
            self.date = date
        }

        init(_ r: VideoRecord) { self.init(status: r.audioVerifyStatus, note: r.audioVerifyNote, date: r.audioVerifyDate) }

    }

    /// Every record of `record`'s content NOW, removed ones included — they
    /// load the same stored verdict (by digest; a row with no digest is its
    /// own content). Always contains `record`. O(records).
    static func copies(of record: VideoRecord, in records: [VideoRecord]) -> [VideoRecord] {
        let found = SoundLevelsRemeasureItem.copiesNow(records, key: SoundLevelsRemeasureItem.key(record))
        return found.contains { $0 === record } ? found : found + [record]
    }

    /// THE content-level withdrawal — the ONE place "unverified" is written.
    /// Synchronous: call it in the same main-actor step as the copies were found.
    static func decide(copies: [VideoRecord], stored: StoredRead, at date: Date) -> Outcome {
        var out = Outcome(kind: .nothingToWithdraw)
        out.copies = copies.count
        out.heldOK = copies.filter { StoredAudioStatus($0.audioVerifyStatus) == .ok }.count
        let storedFields: Fields?
        switch stored {
        case .unreadable(let why):
            out.kind = .unreadable(why)
            return out
        case .none:
            storedFields = nil
        case .check(let c):
            storedFields = Fields(status: c.status, note: c.note, date: c.checkedAt)
        }
        // Measured damage anywhere: it stands, on every copy (newest first;
        // the stored row wins a tie — it is what every copy loads).
        var damage = copies.map(Fields.init).filter { StoredAudioStatus($0.status).refusesLikeDamage }
        if let s = storedFields, StoredAudioStatus(s.status).refusesLikeDamage { damage.insert(s, at: 0) }
        if let keep = damage.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            out.kind = .keptDamage(keep.status)
            out.changed = set(copies, to: keep)
            return out
        }
        let anyOK = out.heldOK > 0 || storedFields.map { StoredAudioStatus($0.status) == .ok } == true
        guard anyOK else { return out }
        out.kind = .withdrew
        out.changed = set(copies, to: Fields(status: StoredAudioStatus.unverifiedWord,
                                             note: StoredAudioStatus.unverifiedWords, date: date))
        return out
    }

    private static func set(_ copies: [VideoRecord], to f: Fields) -> [VideoRecord] {
        var changed: [VideoRecord] = []
        for c in copies where Fields(c) != f {
            // Through the one writer's field setter (PromoteSoundGateSensor
            // 4: the verdict fields are assigned in VerifyAudioJob.swift only).
            VerifyAudioJob.setVerdictFields(c, status: f.status, note: f.note, date: f.date)
            changed.append(c)
        }
        return changed
    }

    /// The content's bound sound verdict, read through the committer's
    /// repository (no SQLite store → none).
    static func readStored(_ repository: (any CatalogRepository)?, digest: String?) async -> StoredRead {
        guard let repository, let digest else { return .none }
        do {
            return try await repository.read { try $0.storedAudioCheck(digest: digest) }.map(StoredRead.check) ?? .none
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// The live store read for a record's content (the jobs' default seam).
    static func readStored(for record: VideoRecord, model: VideoScanModel?) async -> StoredRead {
        await readStored(model?.catalogCutover.committer?.repository, digest: CatalogCommit.digest(of: record))
    }

    /// The one sink's line for a withdrawal step that did something, or
    /// refused (console + catalog.log through `model.log`, videoscan.log,
    /// the unified log). Path-free. Nothing for "nothing to withdraw".
    static func log(_ o: Outcome, filename: String, by verb: String, model: VideoScanModel) {
        guard let line = words(o, subject: filename) else { return }
        let words = "\(verb): \(line)"
        model.log(words)
        appLog.write("[verify-audio] " + words)
        withdrawalLog.notice("\(words, privacy: .public)")
    }

    /// The words of `log` after its verb: "<subject> — …". Pure.
    static func words(_ o: Outcome, subject: String) -> String? {
        let why = "the sound's sample rate, format or layout changes partway, so the earlier check did not cover it (#518)"
        let all = o.copies == 1 ? "its one copy" : "all \(o.copies) copies"
        switch o.kind {
        case .withdrew:
            return "\(subject) — stored sound verdict \"ok\" withdrawn to \"unverified\" on \(all): \(why)"
        case .keptDamage(let status):
            guard o.heldOK > 0 || !o.changed.isEmpty else { return nil }
            return "\(subject) — stored sound verdict \"\(status)\" kept on \(all): measured damage is never withdrawn"
                + (o.changed.isEmpty ? "" : " (\(o.changed.count) cop\(o.changed.count == 1 ? "y" : "ies") set to it)")
        case .unreadable(let w):
            return "\(subject) — stored sound verdict left as it is: the content's stored verdict could not be read (\(w)); it is checked again next time"
        case .nothingToWithdraw:
            return nil
        }
    }
}
