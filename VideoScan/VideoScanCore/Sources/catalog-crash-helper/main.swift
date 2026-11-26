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
//   catalog-crash-helper restore-once <catalog.sqlite> <backup> <generation> <step-delay-µs>   (GH #343, below)
//   catalog-crash-helper posix-lock-probe <file> <offset> <length>                         (codex #388, below)
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

// GH #343 — `restore-once <catalog.sqlite> <sealed backup> <expected generation> <step delay µs>`:
// opens the catalog (.archival), prints READY, restores the backup INTO it
// through `restore(fromSealedCopy:…)` one page per step, sleeping `step
// delay` after each step so a SIGKILL can land mid-copy, prints STEP <n>
// <total> per step and RESTORED <outcome> at the end (then exit 0).
// CatalogRestoreHardKillTests kills it at a random moment and reopens.
if arguments.count == 6, arguments[1] == "restore-once", let expected = Int(arguments[4]), let delay = UInt32(arguments[5]) {
    let repository = GRDBCatalogRepository(host: "crash-helper", durability: .archival)
    let opened = await repository.open(at: URL(fileURLWithPath: arguments[2]))
    guard opened == .readWrite else {
        print("OPEN \(opened)")
        exit(3)
    }
    print("READY generation \(await repository.generation)")
    let source: CatalogPinnedSource
    do {
        source = try CatalogPinnedSource.pin(URL(fileURLWithPath: arguments[3]))
    } catch {
        print("PIN \(error)")
        exit(4)
    }
    let outcome = await repository.restore(fromSealedCopy: source, expectedGeneration: expected,
                                           pagesPerStep: 1) { copied, total in
        print("STEP \(copied) \(total)")
        usleep(delay)
    }
    print("RESTORED \(outcome)")
    exit(0)
}

// Codex #388 P2 — `posix-lock-probe <file> <offset> <length>`: asks the
// kernel (F_GETLK, from THIS separate process) whether another process
// holds a classic POSIX lock that conflicts with a write lock on the range,
// prints `LOCKED <type> <pid>` or `UNLOCKED`, exits 0. A process's POSIX
// locks are invisible to itself, so only a second process can see them.
if arguments.count == 5, arguments[1] == "posix-lock-probe", let offset = Int64(arguments[3]), let length = Int64(arguments[4]) {
    let fd = open(arguments[2], O_RDONLY)
    guard fd >= 0 else { print("OPEN \(String(cString: strerror(errno)))"); exit(3) }
    var lock = flock(l_start: off_t(offset), l_len: off_t(length), l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    guard fcntl(fd, F_GETLK, &lock) == 0 else { print("GETLK \(String(cString: strerror(errno)))"); exit(4) }
    print(lock.l_type == Int16(F_UNLCK) ? "UNLOCKED" : "LOCKED \(lock.l_type) \(lock.l_pid)")
    exit(0)
}

guard arguments.count == 3, arguments[1] == "commit-loop" else {
    FileHandle.standardError.write(Data("usage: catalog-crash-helper commit-loop <catalog.sqlite> | restore-once <catalog.sqlite> <backup> <generation> <step-delay-µs> | posix-lock-probe <file> <offset> <length>\n".utf8))
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
