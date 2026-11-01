// JournalApplication.swift — VideoScanCore/Background
//
// What one batch of journal lines does INSIDE the app's one transaction
// (design §3.4; the app's JournalApplier owns the timer, the cursor and the
// commit door — this is only the body it runs). Pure admission first, then
// the store's door (`appendProvenanceAssertion`), which decides duplicate /
// vetoed / unknown digest / archived name-or-date itself. Every line ends in
// exactly one bucket: applied, duplicate, or refused WITH ITS RULE.
//
// Refusal rules (the words in refused.jsonl's `reason`):
//   invalid           — not a version-1 line, or its id does not match it
//                       (a torn tail sealed by the writer lands here)
//   unknownTable      — `table` is not provenance_assertions (step 1)
//   notAnObservation  — state ≠ inferred or by ≠ machine:* — the helper may
//                       never write a decision (only Rick decides)
//   notADigest        — subject_id is not a whole-file SHA-256
//   unknownDigest     — the digest is not a `content` row
//   archivedNameOrDate — a name or date field on an archived content (rule 3)
//   vetoed            — Rick's latest decision on this value is "rejected"
//
// The batch is applied in digest order ("batched by digest", §3.4) so one
// content's lines sit together in the transaction.
//
// Memory: the batch the caller read (≤ 256 lines) and one outcome per line.
//
// C++ reading: a free function `Outcome apply(span<Line>, Txn&)`; the
// transaction is the caller's RAII scope.

import Foundation

public enum JournalRefusalReason: String, Sendable, CaseIterable {
    case invalid
    case unknownTable
    case notAnObservation
    case notADigest
    case unknownDigest
    case archivedNameOrDate
    case vetoed
}

public struct JournalRefusal: Error, Sendable {
    public let line: ObservationJournal.ReadLine
    public let reason: JournalRefusalReason
    public let detail: String
}

public struct JournalBatchOutcome: Sendable {
    public var applied = 0
    public var duplicates = 0
    public var refused: [JournalRefusal] = []
    public init() {}
}

public enum JournalApplication {

    /// A line's draft, or the rule that refuses it before the store is asked. Pure.
    public static func admit(_ read: ObservationJournal.ReadLine) -> Result<CatalogRow.ProvenanceAssertionDraft, JournalRefusal> {
        func refuse(_ reason: JournalRefusalReason, _ detail: String) -> Result<CatalogRow.ProvenanceAssertionDraft, JournalRefusal> {
            .failure(JournalRefusal(line: read, reason: reason, detail: detail))
        }
        let line: ObservationLine
        switch read.result {
        case .failure(let problem): return refuse(.invalid, problem.words)
        case .success(let l): line = l
        }
        guard line.table == ObservationLine.assertionsTable else { return refuse(.unknownTable, "table \(line.table)") }
        guard line.state == "inferred", line.by.hasPrefix("machine:") else {
            return refuse(.notAnObservation, "state \(line.state) by \(line.by) — the helper writes observations only")
        }
        var subject = line.subjectID
        if line.subjectKind == ProvenanceAssertionSubject.content {
            guard let id = ProvenanceAssertionSubject.contentID(line.subjectID) else {
                return refuse(.notADigest, "subject \(line.subjectID.prefix(24)) is not a whole-file SHA-256")
            }
            subject = id
        }
        return .success(CatalogRow.ProvenanceAssertionDraft(subjectKind: line.subjectKind, subjectID: subject, field: line.field,
                                                            value: line.value, state: line.state, by: line.by, at: line.at,
                                                            confidence: line.confidence, evidenceJSON: line.evidenceJSON))
    }

    /// Apply `lines` through `tx`, digest by digest. Throws only what the
    /// store throws (a CHECK the admission did not foresee) — the caller's
    /// transaction then rolls the whole batch back and the cursor stays.
    public static func apply(_ lines: [ObservationJournal.ReadLine], in tx: any CatalogProvenanceAssertionWriting) throws -> JournalBatchOutcome {
        var outcome = JournalBatchOutcome()
        var drafts: [(ObservationJournal.ReadLine, CatalogRow.ProvenanceAssertionDraft)] = []
        for line in lines {
            switch admit(line) {
            case .failure(let refusal): outcome.refused.append(refusal)
            case .success(let draft): drafts.append((line, draft))
            }
        }
        drafts.sort { ($0.1.subjectID, $0.0.offset) < ($1.1.subjectID, $1.0.offset) }
        for (line, draft) in drafts {
            switch try tx.appendProvenanceAssertion(draft) {
            case .recorded: outcome.applied += 1
            case .duplicate: outcome.duplicates += 1
            case .vetoed:
                outcome.refused.append(JournalRefusal(line: line, reason: .vetoed, detail: "Rick rejected \(draft.field) = \(draft.value) for this content"))
            case .contentMissing:
                outcome.refused.append(JournalRefusal(line: line, reason: .unknownDigest, detail: "content \(draft.subjectID.prefix(12))… is not in the catalog"))
            case .archivedNameOrDate:
                outcome.refused.append(JournalRefusal(line: line, reason: .archivedNameOrDate,
                                                      detail: "\(draft.field) is a name or date and the content is archived — only Rick changes it (rule 3)"))
            }
        }
        return outcome
    }
}
