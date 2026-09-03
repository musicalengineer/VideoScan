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
        /// Nothing is called `name`. `similar` = the files whose filename
        /// or stem is a shorter tail of the name (codex #1020 item 2):
        /// offered under their OWN names as did-you-mean chips, never
        /// substituted.
        case notFound(name: String, similar: [ArchivistRecordReferenceResolver.Candidate] = [], similarTotal: Int = 0)
        /// The first candidates and the TRUE number of files that fit.
        case ambiguous([ArchivistRecordReferenceResolver.Candidate], total: Int)
        /// An explicit path nobody has, with the files that share its
        /// basename (codex #976 item 3: never a silent substitute).
        case pathNotFound(path: String, sameName: [ArchivistRecordReferenceResolver.Candidate], sameNameTotal: Int)
        /// Nothing selected (the default for a Context built without a
        /// record capture).
        case noSelection

        /// The scope for a resolver verdict; the snapshot is built here,
        /// on the main actor, from the resolved record.
        @MainActor
        init(_ resolution: ArchivistRecordReferenceResolver.Resolution) {
            switch resolution {
            case .resolved(let record): self = .resolved(ArchivistRecordDossierSnapshot(record: record))
            case .ambiguous(let candidates, let total): self = .ambiguous(candidates, total: total)
            case .notFound(let name, let similar, let total):
                self = .notFound(name: name, similar: similar, similarTotal: total)
            case .pathNotFound(let path, let sameName, let total):
                self = .pathNotFound(path: path, sameName: sameName, sameNameTotal: total)
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

        case .ambiguous(let candidates, let total):
            let name: String
            if case .file(let typed) = payload.reference { name = typed } else { name = "that" }
            let labels = ArchivistRecordReferenceResolver.chipLabels(for: candidates)
            let listed = labels.joined(separator: ", ")
            let prose = total > candidates.count
                ? "I found \(total) files that could be “\(name)”; here are the first \(candidates.count): "
                    + listed + ". Which one do you mean?"
                : "I found \(total) files that could be “\(name)”: " + listed + ". Which one do you mean?"
            return Result(
                route: .record,
                outcome: .declined,
                prose: prose,
                basisLine: "Basis: file reference “\(name)” matched \(total) catalog "
                    + "filenames (\(candidates.count) offered, \(ArchivistRecordReferenceResolver.maxCandidates) at most); "
                    + "nothing was searched.",
                queryDescription: description + " ambiguous=\(total)",
                citations: [],
                catalogPersonName: nil,
                offeredActions: zip(candidates, labels).map { candidate, label in
                    .ask(question: ArchivistRecordExecutor.question(for: payload, path: candidate.fullPath),
                         label: label)
                })

        case .pathNotFound(let path, let sameName, let total):
            return pathNotFoundResult(
                path: path, sameName: sameName, total: total,
                payload: payload, description: description)

        case .notFound(let name, let similar, let total):
            return notFoundResult(
                name: name, similar: similar, total: total,
                payload: payload, description: description)

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

    /// A name nobody has. With did-you-mean candidates (codex #1020 item
    /// 2) the decline says so by the TYPED name and offers each candidate
    /// by ITS OWN name, each chip asking about that exact path — never a
    /// silent resolution to a file that merely ends the way the name does.
    private static func notFoundResult(
        name: String,
        similar: [ArchivistRecordReferenceResolver.Candidate],
        total: Int,
        payload: ArchivistQueryAST.Record,
        description: String
    ) -> Result {
        let couldNotFind = "I couldn't find a file called “\(name)” in the catalog."
        guard !similar.isEmpty else {
            return Result(
                route: .record,
                outcome: .declined,
                prose: couldNotFind + " Name it exactly "
                    + "as it appears in the Catalog, or select it there and ask me again.",
                basisLine: "Basis: file reference “\(name)” matched no catalog path, filename, "
                    + "or filename tokens; nothing was searched.",
                queryDescription: description + " notFound",
                citations: [],
                catalogPersonName: nil)
        }
        let labels = ArchivistRecordReferenceResolver.chipLabels(for: similar)
        let didYouMean: String
        if similar.count == 1 {
            didYouMean = "Did you mean “\(similar[0].filename)” (\(similar[0].fullPath))?"
        } else if total > similar.count {
            didYouMean = "Did you mean one of these \(total) files (the first \(similar.count)): "
                + labels.joined(separator: ", ") + "?"
        } else {
            didYouMean = "Did you mean one of these: " + labels.joined(separator: ", ") + "?"
        }
        return Result(
            route: .record,
            outcome: .declined,
            prose: couldNotFind + " " + didYouMean,
            basisLine: "Basis: file reference “\(name)” matched no catalog path, filename, "
                + "or filename tokens; \(total) catalog filename\(total == 1 ? "" : "s") "
                + "match a shorter tail of it (\(similar.count) offered by their own names); "
                + "nothing was searched.",
            queryDescription: description + " notFound similar=\(total)",
            citations: [],
            catalogPersonName: nil,
            offeredActions: zip(similar, labels).map { candidate, label in
                .ask(question: ArchivistRecordExecutor.question(for: payload, path: candidate.fullPath),
                     label: label)
            })
    }

    /// An explicit path nobody has (codex #976 item 3): never a silent
    /// substitute — the files that share its basename are OFFERED, each
    /// chip asking about that exact path.
    private static func pathNotFoundResult(
        path: String,
        sameName: [ArchivistRecordReferenceResolver.Candidate],
        total: Int,
        payload: ArchivistQueryAST.Record,
        description: String
    ) -> Result {
        let basename = (path as NSString).lastPathComponent
        guard !sameName.isEmpty else {
            return Result(
                route: .record,
                outcome: .declined,
                prose: "I don't have \(path), and nothing in the catalog is called “\(basename)”. "
                    + "Name the file as it appears in the Catalog, or select it there and ask me again.",
                basisLine: "Basis: path “\(path)” matched no catalog path and its filename matched "
                    + "no catalog filename; nothing was searched.",
                queryDescription: description + " pathNotFound sameName=0",
                citations: [],
                catalogPersonName: nil)
        }
        let labels = ArchivistRecordReferenceResolver.chipLabels(for: sameName)
        let have: String
        if sameName.count == 1 {
            have = "I do have \(sameName[0].fullPath) — that one?"
        } else if total > sameName.count {
            have = "I do have \(total) files called “\(basename)”; the first \(sameName.count): "
                + labels.joined(separator: ", ") + ". One of those?"
        } else {
            have = "I do have \(total) files called “\(basename)”: "
                + labels.joined(separator: ", ") + ". One of those?"
        }
        return Result(
            route: .record,
            outcome: .declined,
            prose: "I don't have \(path). " + have,
            basisLine: "Basis: path “\(path)” matched no catalog path; \(total) catalog "
                + "filename\(total == 1 ? "" : "s") match its basename (\(sameName.count) offered); "
                + "nothing was searched.",
            queryDescription: description + " pathNotFound sameName=\(total)",
            citations: [],
            catalogPersonName: nil,
            offeredActions: zip(sameName, labels).map { candidate, label in
                .ask(question: ArchivistRecordExecutor.question(for: payload, path: candidate.fullPath),
                     label: label)
            })
    }
}
