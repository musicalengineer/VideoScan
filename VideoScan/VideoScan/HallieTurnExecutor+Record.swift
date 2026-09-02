// HallieTurnExecutor+Record.swift
// The `record` route: ONE catalog record (the selected row or a named
// file) → its people / date / dossier. Placeholder until the record
// executor lands; see the follow-on commit.

import Foundation

extension HallieTurnExecutor {
    static func executeRecord(
        _ payload: ArchivistQueryAST.Record,
        request: Request,
        context: Context
    ) -> Result {
        Result(
            route: .record,
            outcome: .declined,
            prose: "I can't look inside one video yet.",
            basisLine: "Basis: record route not wired.",
            queryDescription: "shape=record",
            citations: [],
            catalogPersonName: nil)
    }
}
