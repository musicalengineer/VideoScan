// ArchiveAngelBalancedProofSensorTests.swift
// SENSOR (source scan): the balanced-copy proof DECIDES NOTHING (2026-11-18;
// DECISIONS 2026-11-17 — nothing may trash or delete on the proof's word until
// the next slice's dry run and Codex review). Its result may be produced,
// logged, kept on the Prepare row and shown in Review — and read by nothing
// else: not readiness, not Promote, not the Angel's holds, not a gate, not any
// Trash or cleanup verb. The behaviour twin (each outcome run through the real
// Prepare, every decision compared) is ArchiveAngelBalancedProofTests.
//
// How: every app source whose CODE (comments removed) names the proof — the
// engine's types, the row's note, the Prepare stage — must be one of the files
// below, each with its reason. A new reader anywhere else is red here, before
// review. Inside the allowed files that also hold decisions (the plan and the
// job), the row's note is only declared and only written.

import Foundation
import Testing

@Suite("Archive Angel — the balanced-copy proof is read by nothing that decides (source sensor)")
struct ArchiveAngelBalancedProofSensorTests {

    /// The proof's names in code: the engine, its Prepare stage, the row's note.
    static let token = try! NSRegularExpression(pattern: #"BalancedCopyProof|balancedCopyProof|BalancedProofNote|ArchiveAngelBalancedProof"#)

    /// Every file allowed to name the proof, and why.
    static let allowed: [String: String] = [
        "MediaOps/BalancedCopyProof.swift": "the engine",
        "MediaOps/BalancedCopyProofMeasure.swift": "the engine",
        "MediaOps/BalancedCopyProofRules.swift": "the engine",
        "MediaOps/BalancedCopyProofReadLog.swift": "the engine",
        "ArchiveAngel/Prepare/ArchiveAngelBalancedProof.swift": "the Prepare stage's pure helpers and the row's note",
        "ArchiveAngel/Prepare/ArchiveAngelJob.swift": "runs the stage; WRITES the note (checked below)",
        "ArchiveAngel/Prepare/ArchiveAngelPlan.swift": "DECLARES the note on the row (checked below)",
        "ArchiveAngel/UI/ArchiveAngelReviewSheet.swift": "shows the row's one line",
    ]

    /// Where the decisions live — named so a widening of `allowed` is seen.
    static let deciders = [
        "Archive/ArchiveReadiness.swift", "Archive/PromoteSoundGate.swift",
        "ArchiveAngel/Promote/ArchiveAngelPromoter.swift", "ArchiveAngel/Promote/ArchiveAngelFamilyFacts.swift",
        "ArchiveAngel/Review/ArchiveAngelBufferHygiene.swift", "ArchiveAngel/Facade/ArchiveAngel.swift",
        "MediaOps/MediaTrash.swift", "MediaOps/PruneApplyJob.swift", "MediaOps/DeleteDuplicatesJob.swift",
        "MediaOps/DeleteDuplicatesTargetGates.swift", "MediaOps/Cleanup/CleanupTrashJob.swift",
        "MediaOps/Cleanup/CleanupPlan.swift",
    ]

    static func names(_ code: String) -> Bool {
        token.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    static func count(_ pattern: String, in code: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? -1
    }

    @Test("SENSOR: only the engine, the Prepare stage, the plan row and the review line name the proof in code")
    func onlyAllowedFilesNameTheProof() throws {
        var readers: [String] = []
        var seen = 0
        for (relative, url) in SourceTree.appSources {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard Self.names(text) else { continue }        // cheap pre-filter on the raw text
            let code = try SourceTree.code(of: text, named: relative)
            guard Self.names(code) else { continue }        // a comment only — not a reader
            seen += 1
            if !Self.allowed.keys.contains(where: { relative == $0 || relative.hasSuffix("/" + $0) }) { readers.append(relative) }
        }
        #expect(seen >= Self.allowed.count, "the scan found only \(seen) files naming the proof — did it read the tree?")
        #expect(readers.isEmpty, "these app sources name the balanced-copy proof but are not allowed to read it: \(readers)")
    }

    @Test("SENSOR: readiness, Promote, the holds, the sound gate and every Trash verb never name the proof")
    func decidersNeverNameTheProof() throws {
        for name in Self.deciders {
            let code = try SourceTree.appCode(named: name)
            #expect(!Self.names(code), "\(name) names the balanced-copy proof — it must decide nothing yet")
            #expect(Self.allowed[name] == nil)
        }
    }

    @Test("SENSOR: the plan only declares the note; the job only writes it; nothing in either reads it")
    func theNoteIsDeclaredAndWrittenNeverRead() throws {
        let plan = try SourceTree.appCode(named: "ArchiveAngel/Prepare/ArchiveAngelPlan.swift")
        #expect(Self.count(#"balancedCopyProof"#, in: plan) == 1, "ArchiveAngelPlan names the note more than once")
        #expect(Self.count(#"var balancedCopyProof: BalancedProofNote\?"#, in: plan) == 1)

        let job = try SourceTree.appCode(named: "ArchiveAngel/Prepare/ArchiveAngelJob.swift")
        let mentions = Self.count(#"\.balancedCopyProof\b"#, in: job)
        let writes = Self.count(#"\.balancedCopyProof\s*=[^=]"#, in: job)
        #expect(writes == 1 && mentions == writes, "ArchiveAngelJob reads the row's note (\(mentions) mentions, \(writes) writes)")
        // The job hands the engine's outcome only to the log and to the note.
        #expect(Self.count(#"\.(isProven|playsTheSame|differences)\b|outcome\.evidence\b"#, in: job) == 0,
                "ArchiveAngelJob looks inside a proof outcome")
        // Nor matches on it (Codex #317 F1): no `case .notProven`, no `switch outcome`, no `outcome ==`.
        #expect(Self.count(#"\.(proven|sameContent|notProven|couldNotCheck)\b|switch\s+outcome\b|outcome\s*[!=]="#, in: job) == 0,
                "ArchiveAngelJob branches on a proof outcome")
    }
}
