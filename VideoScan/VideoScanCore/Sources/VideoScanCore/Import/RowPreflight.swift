// RowPreflight.swift
// fix 2026-10-17 (codex D′ #6): the DDL's row-local CHECKs (UUID shapes,
// absolute paths, non-negative sizes / durations / revisions, the enum
// vocabularies CatalogDDL loads, removal-marker and audit-stamp consistency,
// backup kinds, sound-print and footage rules, event states and ranges,
// ignored ids and sizes, audit judged paths) applied in Swift BEFORE any
// insert. A catalog row that violates one lands in `quarantine` as
// `unrepresentable` with the check's words — no files / content / derived /
// relation row of it is inserted, so one odd row (the v6 golden's
// `"volumeUUID":"VU-1"`, a negative size on a hashed row) no longer aborts
// 13,792 good ones. A sidecar entry that violates one is a named RUN
// refusal (there is no quarantine for sidecars).
//
// Data-shaped: each check is one table row `(name, scope, test)`; `report`
// runs the table. The checks mirror the DDL's CHECKs one for one and say
// which they mirror; the DDL stays the authority (a row this table misses
// still fails the run with the engine's words, as before).
//
// Scope: `.main` checks guard tables only a main landing writes (files,
// volumes, backup_destinations); `.any` checks guard what a quarantined
// occurrence still writes (content, sound_prints, footage_decisions).
//
// (For Rick: a `static const` table of predicates, like a validation table
// in a C++ form library; one loop applies it.)

import Foundation

public enum RowPreflight {

    public enum Scope: Sendable, Equatable {
        case main, any
    }

    /// What a row violates, by scope. Words name the DDL's own columns.
    public struct Report: Sendable, Equatable {
        public var main: [String] = []
        public var any: [String] = []

        public init(main: [String] = [], any: [String] = []) {
            self.main = main
            self.any = any
        }

        public var isClean: Bool { main.isEmpty && any.isEmpty }

        /// The violations that make the row unrepresentable for the gate's
        /// landing: a main row answers to every check, a quarantined row only
        /// to the `.any` ones (its files row is never written).
        public func violations(for landing: ImportGate.Landing) -> [String] {
            if case .main = landing { return any + main }
            return any
        }
    }

    /// One check: its DDL name, where it applies, the words when it fails (nil = passes).
    struct Check: Sendable {
        let name: String
        let scope: Scope
        let test: @Sendable (CatalogRecordDTO) -> String?
    }

    // MARK: - The row table (files / volumes / backups: main; content / prints / footage: any)

    static let checks: [Check] = [
        Check(name: "files.id", scope: .main) { d in
            UUID(uuidString: d.file.id) == nil ? "id \"\(d.file.id)\" is not a UUID" : nil
        },
        Check(name: "volumes.volume_uuid", scope: .main) { d in
            RowPreflight.isVolumeUUID(d.file.volumeUUID) ? nil : "volume id \"\(d.file.volumeUUID)\" is not a 36-character UUID"
        },
        Check(name: "files.full_path", scope: .main) { d in
            RowPreflight.isAbsolutePath(d.file.fullPath) ? nil : "path \"\(d.file.fullPath)\" is not an absolute path"
        },
        Check(name: "files.size_bytes", scope: .main) { d in
            d.file.sizeBytes < 0 ? "size_bytes is negative (\(d.file.sizeBytes))" : nil
        },
        Check(name: "files.duration_s", scope: .main) { d in
            d.file.durationS < 0 ? "duration_s is negative (\(d.file.durationS))" : nil
        },
        Check(name: "files.stream_type", scope: .main) { d in
            CatalogDDL.StreamType(rawValue: d.file.streamType) == nil ? "stream_type \"\(d.file.streamType)\" is not a known stream type" : nil
        },
        Check(name: "files.lifecycle", scope: .main) { d in
            CatalogDDL.Lifecycle(rawValue: d.file.lifecycle) == nil ? "lifecycle \"\(d.file.lifecycle)\" is not a known stage" : nil
        },
        Check(name: "files.archive_stage", scope: .main) { d in
            CatalogDDL.ArchiveStage(rawValue: d.file.archiveStage) == nil ? "archive_stage \"\(d.file.archiveStage)\" is not a known stage" : nil
        },
        Check(name: "files.removal_state", scope: .main) { d in
            guard let state = d.file.removalState, CatalogDDL.RemovalState(rawValue: state) == nil else { return nil }
            return "removal_state \"\(state)\" is not a known state"
        },
        Check(name: "files.removal_trash_path", scope: .main) { d in
            d.file.removalTrashPath != nil && d.file.removalState != CatalogDDL.RemovalState.inTrash.rawValue
                ? "a trash path on a marker that is not inTrash" : nil
        },
        Check(name: "files.removal_trash_emptied_at", scope: .main) { d in
            d.file.removalTrashEmptiedAt != nil
                && (d.file.removalState != CatalogDDL.RemovalState.inTrash.rawValue || d.file.removalTrashPath == nil)
                ? "a trash-emptied stamp without an inTrash marker and its trash path" : nil
        },
        Check(name: "files.removal_last_seen", scope: .main) { d in
            d.file.removalLastSeen != nil && d.file.removalState != CatalogDDL.RemovalState.missing.rawValue
                ? "a last-seen stamp on a marker that is not missing" : nil
        },
        Check(name: "files removalMirrorsLifecycle", scope: .main) { d in
            d.file.removalState == CatalogDDL.RemovalState.inTrash.rawValue && d.file.lifecycle != CatalogDDL.Lifecycle.trashed.rawValue
                ? "an inTrash marker on a row whose lifecycle is \"\(d.file.lifecycle)\", not Trashed" : nil
        },
        Check(name: "files.removal_revision", scope: .main) { d in
            d.file.removalRevision < 0 ? "removal_revision is negative (\(d.file.removalRevision))" : nil
        },
        Check(name: "files.audit_seen_volume_uuid", scope: .main) { d in
            guard let volume = d.file.auditSeenVolumeUUID else { return nil }
            return volume.trimmingCharacters(in: .whitespaces).isEmpty ? "the audit stamp names no volume" : nil
        },
        Check(name: "backup_destinations.kind", scope: .main) { d in
            let bad = d.backupDestinations.map(\.kind).filter { CatalogDDL.BackupKind(rawValue: $0) == nil }
            return bad.isEmpty ? nil : "backup kind \"\(bad[0])\" is not Local, Cloud or Offsite"
        },
        Check(name: "content.byte_count", scope: .any) { d in
            guard let content = d.content, content.byteCount < 0 else { return nil }
            return "content byte_count is negative (\(content.byteCount))"
        },
        Check(name: "sound_prints.engine_version", scope: .any) { d in
            guard let print = d.soundPrint, print.engineVersion < 1 else { return nil }
            return "sound print engine_version \(print.engineVersion) is below 1"
        },
        Check(name: "sound_prints.outcome", scope: .any) { d in
            guard let print = d.soundPrint, CatalogDDL.SoundOutcome(rawValue: print.outcome) == nil else { return nil }
            return "sound print outcome \"\(print.outcome)\" is not fingerprinted or noAudio"
        },
        Check(name: "sound_prints counts", scope: .any) { d in
            guard let print = d.soundPrint, print.analyzedS < 0 || print.landmarks < 0 || print.blobBytes < 0 else { return nil }
            return "sound print analyzed seconds, landmarks and bytes must be ≥ 0"
        },
        Check(name: "sound_prints noAudio", scope: .any) { d in
            guard let print = d.soundPrint, print.outcome == CatalogDDL.SoundOutcome.noAudio.rawValue,
                  print.landmarks != 0 || print.blobBytes != 0 else { return nil }
            return "a noAudio sound print carries landmarks or bytes"
        },
        Check(name: "footage_decisions.verdict", scope: .any) { d in
            let bad = d.curated.footageDecisions.map(\.verdict).filter { CatalogDDL.FootageVerdict(rawValue: $0) == nil }
            return bad.isEmpty ? nil : "footage verdict \"\(bad[0])\" is not same or notSame"
        },
        Check(name: "footage_decisions self", scope: .any) { d in
            d.curated.footageDecisions.contains { $0.rowID == $0.otherRowID } ? "a footage decision names its own row" : nil
        },
    ]

    /// Every violation of the row, by scope, in table order.
    public static func report(_ dto: CatalogRecordDTO) -> Report {
        var report = Report()
        for check in checks {
            guard let words = check.test(dto) else { continue }
            if check.scope == .main { report.main.append(words) } else { report.any.append(words) }
        }
        return report
    }

    /// The quarantine's own floor: a row the quarantine table itself cannot
    /// hold (json_row_id must be 36 characters) is the one row-level case that
    /// still fails the run, in these words.
    public static func quarantineFloor(_ dto: CatalogRecordDTO) -> String? {
        dto.file.id.utf8.count == 36 ? nil : "its id \"\(dto.file.id)\" is not 36 characters — not even quarantine can key it"
    }

    /// The quarantine words: what the gate had decided, then every check.
    public static func words(gate landing: ImportGate.Landing, violations: [String]) -> String {
        let verdict: String
        switch landing {
        case .main(let tombstoned): verdict = tombstoned ? "main, tombstoned" : "main"
        case .quarantine(let reason, _, _): verdict = reason.rawValue
        }
        return "cannot be stored as-is (the gate said \(verdict)): " + violations.joined(separator: "; ")
    }

    // MARK: - Sidecar entries (a violation is a named run refusal)

    /// One sidecar entry the DDL would refuse: the file, its ordinal, the words.
    public struct SidecarFault: Sendable, Equatable {
        public var file: CatalogDDL.ImportSourceFile
        public var ordinal: Int
        public var words: String

        public init(file: CatalogDDL.ImportSourceFile, ordinal: Int, words: String) {
            self.file = file
            self.ordinal = ordinal
            self.words = words
        }
    }

    /// `events`: a 36-character id and a known state.
    public static func violations(event: EventsDecisionsJSON.Event) -> [String] {
        var out: [String] = []
        if CatalogRecordDTO.canonicalID(event.id).utf8.count != 36 { out.append("event id \"\(event.id)\" is not 36 characters") }
        if let state = event.state, CatalogDDL.EventState(rawValue: state) == nil {
            out.append("event state \"\(state)\" is not confirmed or dismissed")
        }
        return out
    }

    /// `event_members`: both range ends or neither, and start ≤ end.
    public static func violations(member: EventsDecisionsJSON.Member) -> [String] {
        if (member.start == nil) != (member.end == nil) {
            return ["member \(member.contentKey): a range needs both its start and its end"]
        }
        if let start = member.start, let end = member.end, start > end {
            return ["member \(member.contentKey): range start \(start) is after its end \(end)"]
        }
        return []
    }

    /// `ignored_content`: a 36-character id and a non-negative size.
    public static func violations(ignored entry: IgnoredContentJSON.Entry) -> [String] {
        var out: [String] = []
        if CatalogRecordDTO.canonicalID(entry.id).utf8.count != 36 { out.append("ignored entry id \"\(entry.id)\" is not 36 characters") }
        if let size = entry.sizeBytes, size < 0 { out.append("ignored entry size_bytes is negative (\(size))") }
        return out
    }

    /// `audit_results`: a result other than `present` names the path it judged
    /// (N1). An unknown result word is its own refusal (`auditResultUnknownWord`),
    /// not a judged-path fault as well.
    public static func violations(auditRow row: AuditMarkerJSON.Row) -> [String] {
        guard let result = row.gateClass, result != .present, row.judgedPath == nil else { return [] }
        return ["audit result \"\(row.result)\" for \(row.id) names no judged path"]
    }

    // MARK: - Shapes

    /// `volumes.volume_uuid`: '' or 36 characters of 0-9 A-F and '-'.
    static func isVolumeUUID(_ s: String) -> Bool {
        s.isEmpty || (s.utf8.count == 36 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || $0 == 45 })
    }

    static func isAbsolutePath(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.hasPrefix("/")
    }
}
