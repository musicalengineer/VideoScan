// ImportReconciliation.swift
// The counts of the import's OUTCOME line (contract §f "Reconciliation
// line"), read from the rows the import wrote — never from the importer's
// own tallies, which the contract says are not the proof. The store fills
// the SQL-countable members (`CatalogRecordReading.importReconciliation`);
// the importer adds the two it alone can know (member keys it listed,
// ledger lines it could not parse).
//
// (For Rick: a POD of integers and one `description`-style formatter.)

import Foundation

public struct ImportReconciliation: Sendable, Equatable {
    public var rowsBefore = 0
    public var rowsMain = 0
    public var rowsTombstoned = 0
    public var rowsQuarantine = 0
    public var quarantineByReason: [String: Int] = [:]
    public var digests = 0
    public var knowledgeRows = 0
    public var knowledgeByField: [String: Int] = [:]
    /// (digest, field) groups whose copies disagree, by field.
    public var conflictsByField: [String: Int] = [:]
    public var unverified = 0
    public var unverifiedConflicts = 0
    public var pendingLineage = 0
    public var events = 0
    public var eventDecisions = 0
    public var membersResolved = 0
    public var membersListed = 0
    public var ignored = 0
    public var ignoredBound = 0
    public var ledgerLines = 0
    public var ledgerUnparseable = 0
    public var searches = 0
    public var searchesZeroHit = 0
    public var searchesUnreadable = 0
    public var auditResults = 0
    public var auditAccepted = 0
    public var markers = 0

    public init() {}

    public var rowsLive: Int { rowsMain - rowsTombstoned }
    public var conflicts: Int { conflictsByField.values.reduce(0, +) }
    public var ignoredUnbound: Int { ignored - ignoredBound }
    public var auditRefused: Int { auditResults - auditAccepted }

    /// `name a, name b` in name order; "none" when empty.
    private static func breakdown(_ counts: [String: Int]) -> String {
        counts.isEmpty ? "none" : counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    /// The §f line, verbatim in shape.
    public var line: String {
        [
            "rows before \(rowsBefore)",
            "main \(rowsMain) (live \(rowsLive), tombstoned \(rowsTombstoned))",
            "quarantine \(rowsQuarantine) (by reason \(Self.breakdown(quarantineByReason)))",
            "digests \(digests)",
            "knowledge rows \(knowledgeRows) (by field \(Self.breakdown(knowledgeByField)))",
            "conflicts \(conflicts) (by field \(Self.breakdown(conflictsByField)))",
            "unverified \(unverified) (conflicts \(unverifiedConflicts))",
            "pending lineage \(pendingLineage)",
            "events \(events) (\(eventDecisions) decisions, members \(membersResolved) resolved / \(membersListed) listed)",
            "ignored \(ignored) (\(ignoredBound) bound / \(ignoredUnbound) unbound)",
            "ledger lines \(ledgerLines)" + (ledgerUnparseable > 0 ? " (\(ledgerUnparseable) torn at the end, kept with its bytes)" : ""),
            "searches \(searches) (zero-hit \(searchesZeroHit), unreadable \(searchesUnreadable))",
            "audit results \(auditResults) (\(auditAccepted) accepted / \(auditRefused) refused)",
            "markers \(markers)",
        ].joined(separator: " · ")
    }
}
