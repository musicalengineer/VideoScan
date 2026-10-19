// catalog-crash-helper — TEST-ONLY child process (2026-10-18).
//
// CatalogHardKillTests (Tests/VideoScanCoreTests/Store/) spawns this, lets it
// commit, and SIGKILLs it at a random moment — mid-commit, mid-fsync, between
// the high-water's two phases — then reopens the catalog through the real
// open path and checks it. A thrown error inside one process (the store's
// `injectCrashBeforeCommit` seam) rolls back cleanly by construction; only a
// second process that really dies proves what a crash leaves on disk.
//
//   catalog-crash-helper commit-loop <catalog.sqlite>
//
// Opens the catalog through GRDBCatalogRepository with the PRODUCTION
// durability (.archival: synchronous=FULL, fullfsync, F_FULLFSYNC'd
// high-water), loads every record through CatalogLoad + VideoRecord(loaded:)
// — the app's load — and then, forever: sets every record's notes to
// "crash-gen <next generation>" and commits all of them in ONE
// CatalogCommit (the app's commit path). One stdout line per event, flushed:
//
//   READY generation <g> records <n>
//   COMMITTED <g> landed <n>      (printed only AFTER the commit returned)
//   OPEN <outcome> / LOAD <error> / STOPPED <outcome>   (then exit 3/5/4)
//
// The parent therefore knows a lower bound on what is durable: every
// generation printed as COMMITTED. Nothing ships in the app: the app target
// links only the VideoScanCore library product.
//
// For Rick: `main.swift` with top-level `await` is the whole program, like a
// C `main()` that may block on async calls.

import Foundation
import VideoScanCore

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "commit-loop" else {
    FileHandle.standardError.write(Data("usage: catalog-crash-helper commit-loop <catalog.sqlite>\n".utf8))
    exit(64)
}

let repository = GRDBCatalogRepository(host: "crash-helper", durability: .archival)
let opened = await repository.open(at: URL(fileURLWithPath: arguments[2]))
guard opened == .readWrite else {
    print("OPEN \(opened)")
    exit(3)
}

let records: [VideoRecord]
do {
    let snapshot = try await CatalogLoad.read(repository)
    records = try snapshot.rows.map { try VideoRecord(loaded: $0) }
} catch {
    print("LOAD \(error)")
    exit(5)
}
print("READY generation \(await repository.generation) records \(records.count)")

while true {
    let next = await repository.generation + 1
    let note = "crash-gen \(next)"
    let items = records.map { record -> CatalogCommit.Item in
        record.userNotes = note
        let snapshot = VideoRecordDTO(record)
        return CatalogCommit.Item(id: record.id, snapshot: snapshot,
                                  fingerprint: CatalogChangeDetector.fingerprint(snapshot))
    }
    let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: items), on: repository)
    guard case .committed(let generation, let rows) = outcome, generation == next else {
        print("STOPPED \(outcome)")
        exit(4)
    }
    print("COMMITTED \(generation) landed \(rows.filter { $0.landing.landed }.count)")
}
