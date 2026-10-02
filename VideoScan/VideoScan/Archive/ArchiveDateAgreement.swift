// ArchiveDateAgreement.swift
// GH #219 (Rick approved 2026-10-02): "one Promote-time date drives the
// folder, the filename, the manifest record_date and the copy's catalog
// record together, or the Promote refuses" — plus the sensor: "an archived
// record's manifest date, its folder/filename date and its catalog date
// must agree, or the record is flagged."
//
// The 2026-09-27 fix (aba783fa, `dateDecision`) writes a typed / Review /
// copy's YEAR, MONTH or DAY into all four places. What it could not write is
// a date the user-date grammar has no form for (a typed DECADE, "1940s") or
// a date that is not Rick's (an Angel MACHINE proposal, never written as a
// user date by design). In both cases registration kept the SOURCE's own
// `userDate` on the archived copy — so the catalog could say 1990 (known)
// while the folder, the filename and the manifest said the 1940s.
//
// ONE RULE, two callers:
//   • Promote (`promoteRefusal`) — before the journal intent, so a refusal
//     writes zero bytes (ARCH-7): the date the archived record WILL carry
//     must agree with where it is filed.
//   • Verify Archive Copies (`problems`) — report only: an archived
//     record whose index row, placement and catalog date disagree is listed
//     and logged; nothing is rewritten (archived records are read-only to
//     every background job; only Rick changes a name/date, via Update…).
//
// "The catalog date" of an archived record = the claim the catalog makes
// for it: Rick's `userDate` when present, else the date it is FILED under
// (the filename prefix, `archiveFiledDate`). Machine fallbacks (camera
// stamp, inferred date, filesystem date) are labelled as machine guesses in
// the Date column and are not a claim of record, so they are not compared.
//
// "Agree" = equal at the coarser of the two precisions: 1992 agrees with
// 1992-07-15 (the resolver refines a year-only user date by an agreeing
// finer camera date — that is placement, not disagreement); 1945 agrees
// with the 1940s; 1990 does not agree with the 1940s; any date disagrees
// with Undated.
//
// (For Rick: an enum with only static funcs ≈ a C++ namespace of free
// functions; `nonisolated` = callable from any thread.)

import Foundation
import VideoScanCore

enum ArchiveDateAgreement {

    /// (year, month?, day?) for a dated hint; nil for unknown. A decade is
    /// handled by the caller (it is a range, not a point).
    private static func parts(_ h: ArchiveDateHint) -> (y: Int, m: Int?, d: Int?)? {
        switch h {
        case .day(let y, let m, let d): return (y, m, d)
        case .month(let y, let m):      return (y, m, nil)
        case .year(let y):              return (y, nil, nil)
        case .decade, .unknown:         return nil
        }
    }

    /// Do two dates agree at the coarser of their precisions? Pure.
    nonisolated static func agree(_ a: ArchiveDateHint, _ b: ArchiveDateHint) -> Bool {
        switch (a, b) {
        case (.unknown, .unknown): return true
        case (.unknown, _), (_, .unknown): return false
        case (.decade(let s), .decade(let t)): return s == t
        case (.decade(let s), _):
            guard let p = parts(b) else { return false }
            return (s..<(s + 10)).contains(p.y)
        case (_, .decade):
            return agree(b, a)
        default:
            guard let p = parts(a), let q = parts(b), p.y == q.y else { return false }
            if let pm = p.m, let qm = q.m, pm != qm { return false }
            if let pd = p.d, let qd = q.d, pd != qd { return false }
            return true
        }
    }

    /// The catalog's claim for an archived record: Rick's user date, else
    /// the filed (filename-prefix) date; nil = no claim. Pure.
    nonisolated static func catalogClaim(userDate: String?, filedDate: String?) -> ArchiveDateHint? {
        if let ud = userDate, let c = UserDateEntry.canonicalize(ud), let h = ArchiveRefile.hint(fromUserDate: c) { return h }
        if let f = filedDate, let h = ArchiveRefile.hint(fromUserDate: f) { return h }
        return nil
    }

    // MARK: Promote — refuse before a byte moves

    /// nil = fine to file; else the one-line reason (no trailing period).
    /// - `placement`: the date Promote will file under (folder + filename
    ///   prefix + manifest record_date — they are one value already).
    /// - `writesChosenDate`: Promote will write the chosen date onto the
    ///   archived record (`dateDecision(...).recordUserDate != nil`).
    /// - `sourceUserDate` / `sourceKnown`: what registration otherwise
    ///   carries onto the archived record from the source.
    /// - `isMachineProposal`: the placement date is the Angel's, not Rick's.
    nonisolated static func promoteRefusal(placement: ArchiveDateHint,
                                           writesChosenDate: Bool,
                                           sourceUserDate: String?,
                                           sourceKnown: Bool,
                                           isMachineProposal: Bool) -> String? {
        guard !writesChosenDate, let ud = sourceUserDate,
              let canonical = UserDateEntry.canonicalize(ud),
              let carried = ArchiveRefile.hint(fromUserDate: canonical),
              !agree(carried, placement) else { return nil }
        let filed = ArchiveRefile.datedLabel(placement)
        let own = "\(UserDateEntry.friendlyDisplay(canonical)) (\(sourceKnown ? "known" : "estimated"))"
        let fix: String
        if isMachineProposal {
            fix = "the proposed date is a machine guess and your own date wins — promote it without the proposal, or change the file's date first"
        } else if case .decade = placement {
            fix = "a decade cannot be written as the archived file's own date, so it would keep \(UserDateEntry.friendlyDisplay(canonical)) — type a year in \(filed), or change the file's date first"
        } else {
            fix = "type the date again, or change the file's date first"
        }
        return "would be filed under \(filed), but its own date is \(own) and the archived copy would disagree with its folder and index. Nothing was filed; \(fix)"
    }

    // MARK: Sensor — report, never rewrite

    /// What disagrees for one archived record (empty = all agree). Pure.
    /// - `relPath`: the archived copy's CURRENT archive-relative path (its
    ///   placement on disk) — not the index row's path, which may be stale
    ///   after a fallback match (codex 2026-10-02 #5).
    /// - `manifestDate`: the row's record_date ("1947-xx-xx", "1940s", "").
    /// - `userDate` / `filedDate`: the catalog record's claim inputs.
    /// Both legs use `agree` — equal at the coarser precision (codex
    /// 2026-10-02 #6): a 2001-02-03 placement agrees with an index "2001".
    nonisolated static func problems(relPath: String, manifestDate: String,
                                     userDate: String?, filedDate: String?) -> [String] {
        let index = ArchiveRefile.hint(fromManifestDate: manifestDate)
        var out: [String] = []
        if let placed = PromoteToArchiveJob.placementHint(relPath: relPath), !agree(placed, index) {
            out.append("index says \(ArchiveRefile.datedLabel(index)) but its folder/filename say \(ArchiveRefile.datedLabel(placed))")
        }
        if let claim = catalogClaim(userDate: userDate, filedDate: filedDate), !agree(claim, index) {
            out.append("catalog says \(ArchiveRefile.datedLabel(claim)) but its index says \(ArchiveRefile.datedLabel(index))")
        }
        return out
    }
}
