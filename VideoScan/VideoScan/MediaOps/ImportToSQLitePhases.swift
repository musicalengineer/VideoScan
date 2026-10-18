// ImportToSQLitePhases.swift
// The pieces of Import to SQLite's three phases that are not the job's
// lifecycle (Rick 2026-10-17: "in future this should be one action verb").
// One sentence: Import to SQLite holds every catalog save from its first
// step to its last, and inside that hold runs Audit Catalog, then Verify
// Catalog, then the import — so the three describe one generation by
// construction.
//
//   • ImportPhaseJob — what the import needs from the two jobs it runs as
//     phases 1 and 2 (the existing CatalogAuditJob and VerifyCatalogJob,
//     unchanged in what they do; they are simply not added to the center).
//   • ImportPhaseVerdict — PURE: what a finished phase job's state means
//     for the import (go on / stopped / could not complete, with words).
//   • ImportToSQLiteTiming.verifyStartDelay — PURE: the importer's gate
//     refuses an audit that finished in the same whole second Verify
//     Catalog started (`finishedAt >= report.startedAt`, unix seconds); the
//     job waits out that second before it makes the verify job.
//   • ImportBuildIdentity — "this build" for the dry-run marker: the
//     bundle's CFBundleVersion plus the Mach-O UUID of the image this code
//     is linked into (a fresh UUID every link; the git SHA is not baked
//     into the binary, and reading .git at run time would name the checkout,
//     not the build).
//   • MediaFileOperationsCenter.importRunsItsOwn — the standalone Audit /
//     Verify starts refuse while an import runs (it runs its own; a second
//     audit would write the same marker under it).
//
// (For Rick: a protocol here ≈ a C++ abstract interface the two concrete
// job classes already satisfy; `extension X: P {}` declares that they do.)

import Foundation
import MachO

/// What Import to SQLite drives in a phase job: start it, await its task,
/// read its state. Both phase jobs already have these members (main-actor
/// isolated conformances, like their MediaFileOperationJob ones).
protocol ImportPhaseJob: MediaFileOperationJob {
    func start()
    var task: Task<Void, Never>? { get }
}

extension CatalogAuditJob: @MainActor ImportPhaseJob {}
extension VerifyCatalogJob: @MainActor ImportPhaseJob {}

/// What a phase job's terminal state means for the import.
enum ImportPhaseVerdict: Equatable {
    case proceed
    case stopped
    /// The phase's own words, prefixed with who could not complete.
    case couldNotComplete(String)

    /// `step` names the phase in the row ("the audit", "Verify Catalog").
    static func of(_ state: MediaFileOperationState, step: String) -> ImportPhaseVerdict {
        switch state {
        case .finished: return .proceed
        case .cancelled, .cancelling: return .stopped
        case .failed(let message): return .couldNotComplete("\(step) could not complete: \(message)")
        case .running: return .couldNotComplete("\(step) did not finish")
        }
    }
}

enum ImportToSQLiteTiming {
    /// Seconds to wait after the audit finished before Verify Catalog may
    /// start. The marker and the report both carry ISO-8601 whole seconds
    /// (truncated or rounded — either way monotone), and the gate refuses
    /// `audit.finishedAt >= report.startedAt`; starting at or after
    /// floor(finished) + 1.5 s puts the report's second strictly after the
    /// audit's under either rounding. Worst case 1.5 s.
    static func verifyStartDelay(auditFinishedAt: Date, now: Date) -> TimeInterval {
        let safe = auditFinishedAt.timeIntervalSince1970.rounded(.down) + 1.5
        return max(0, safe - now.timeIntervalSince1970)
    }
}

enum ImportBuildIdentity {
    /// "<CFBundleVersion> · <Mach-O UUID>" of the running build.
    static let current: String = {
        let bundle = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(bundle) · \(imageUUID() ?? "no-image-uuid")"
    }()

    /// The LC_UUID of the image this code is linked into (`#dsohandle` =
    /// its mach header — the app binary in Release, the debug dylib in
    /// Debug), so a rebuild is a new identity even when CFBundleVersion is
    /// not bumped. (For Rick: walking the load commands of our own Mach-O
    /// header, the same thing `dwarfdump --uuid` prints.)
    private static func imageUUID() -> String? {
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                return UUID(uuid: cursor.loadUnaligned(as: uuid_command.self).uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}

extension VideoScanModel {
    /// The acknowledged durable save (codex #1659), presenting the token of
    /// a MOPS-16 write hold — the holder's own writer (the audit inside
    /// Import to SQLite) passes the hold; nil = an ordinary save, which a
    /// hold refuses. `saveCatalogAcknowledged()` is this with nil.
    func saveCatalogAcknowledged(asHoldOwner owner: CatalogWriteHoldOwner?) async -> Bool {
        noteCatalogMutated()
        return await catalogStore.saveAcknowledged(records: records, as: owner)
    }
}

extension MediaFileOperationsCenter {
    /// The refusal words when an Import to SQLite is running — it runs its
    /// own Audit Catalog and Verify Catalog inside its hold; nil otherwise.
    func importRunsItsOwn(_ what: String) -> String? {
        guard jobs.contains(where: { $0.state.isActive && $0 is ImportToSQLiteJob }) else { return nil }
        return "Import to SQLite is running and runs its own \(what) — wait for it to finish (or stop it). Nothing was started."
    }
}
