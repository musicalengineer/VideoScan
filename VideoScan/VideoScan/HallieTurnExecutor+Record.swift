// HallieTurnExecutor+Record.swift
// The `record` route: ONE catalog record (the selected row or a named
// file) → its people / date / dossier (2026-09-02). The client resolves
// the reference on the main actor BEFORE execution (ArchivistRecord-
// ReferenceResolver) and hands the executor a RecordScope; the executor
// never sees the catalog, so a record turn can never widen into a
// catalog-wide search (the live 2026-09-02 failure: "who is in New
// Hampshire.mov" → "29 videos…").

import Foundation

extension HallieTurnExecutor {
    /// What the reference resolved to, captured with the Context.
    enum RecordScope: Sendable, Equatable {
        case resolved(ArchivistRecordDossierSnapshot)
        case notFound(name: String)
        case ambiguous([ArchivistRecordReferenceResolver.Candidate])
        /// Nothing selected (the default for a Context built without a
        /// record capture).
        case noSelection

        /// The scope for a resolver verdict; the snapshot is built here,
        /// on the main actor, from the resolved record.
        @MainActor
        init(_ resolution: ArchivistRecordReferenceResolver.Resolution) {
            switch resolution {
            case .resolved(let record): self = .resolved(ArchivistRecordDossierSnapshot(record: record))
            case .ambiguous(let candidates): self = .ambiguous(candidates)
            case .notFound(let name): self = .notFound(name: name)
            case .noSelection: self = .noSelection
            }
        }
    }

    static func executeRecord(
        _ payload: ArchivistQueryAST.Record,
        request: Request,
        context: Context
    ) -> Result {
        let description = "shape=record reference=\(ArchivistRecordExecutor.referenceText(payload.reference))"
        var scope = context.recordScope
        // A named file the client never resolved is not "nothing selected".
        if case .file(let name) = payload.reference, scope == .noSelection {
            scope = .notFound(name: name)
        }
        switch scope {
        case .resolved(let snapshot):
            return ArchivistRecordExecutor.execute(
                payload, snapshot: snapshot, ownerName: context.speakers.ownerName)

        case .ambiguous(let candidates):
            let name: String
            if case .file(let typed) = payload.reference { name = typed } else { name = "that" }
            let listed = candidates.map(\.filename)
            return Result(
                route: .record,
                outcome: .declined,
                prose: "I found \(candidates.count) files that could be “\(name)”: "
                    + listed.joined(separator: ", ") + ". Which one do you mean?",
                basisLine: "Basis: file reference “\(name)” matched \(candidates.count) catalog "
                    + "filenames (\(ArchivistRecordReferenceResolver.maxCandidates) at most are offered); "
                    + "nothing was searched.",
                queryDescription: description + " ambiguous=\(candidates.count)",
                citations: [],
                catalogPersonName: nil,
                offeredActions: candidates.map { candidate in
                    .ask(question: ArchivistRecordExecutor.question(for: payload, path: candidate.fullPath),
                         label: candidate.filename)
                })

        case .notFound(let name):
            return Result(
                route: .record,
                outcome: .declined,
                prose: "I couldn't find a file called “\(name)” in the catalog. Name it exactly "
                    + "as it appears in the Catalog, or select it there and ask me again.",
                basisLine: "Basis: file reference “\(name)” matched no catalog path, filename, "
                    + "or filename tokens; nothing was searched.",
                queryDescription: description + " notFound",
                citations: [],
                catalogPersonName: nil)

        case .noSelection:
            return Result(
                route: .record,
                outcome: .declined,
                prose: "Which video? Select one in the Catalog, or name the file, and ask me again.",
                basisLine: "Basis: the question refers to the selected video and nothing is selected; "
                    + "nothing was searched.",
                queryDescription: description + " noSelection",
                citations: [],
                catalogPersonName: nil)
        }
    }
}
