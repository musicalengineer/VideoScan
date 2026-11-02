// CatalogTrashConfirmation.swift
// The ONE confirmation in front of the Catalog's Move to Trash — the row
// menu's item and ⌘⌫ alike (codex delete-engines F8, design R9: "one
// confirmation"). Both gestures end in `CatalogContent.confirmThenTrash`,
// which shows these words and, only on "Move to Trash", hands the rows to
// `VideoScanModel.trashSelectedRecords`.
//
//   Move 3 files (1.2 GB) to the Trash?
//   They move to the Finder Trash; you can put them back until you empty it.
//   2 will be held back: half of a recovered audio/video pair (1), drive not connected (1).
//   [Move to Trash]  [Cancel]        (Return = Move to Trash, Esc = Cancel)
//
// A recovered audio/video pair selected whole (DECISIONS 2026-11-01) gets
// its own line, and the title counts files · pairs —
//   Move 2 files · 1 pair group (2 KB) to the Trash?
//   Move this clip and its related half to the Trash: A001.V.mxf + A001.A.mxf.
// (N related halves when a group has more than two.) At most
// `groupLineCap` lines, then "…and N more pair groups."
//
// When any file that will move is the only copy the catalog knows of
// (tab-charter audit T3, 2026-10-11), a line says so —
//   ⚠︎ 2 of these are the only copy we know of.
// — and Move to Trash turns destructive with NO Return key: a deliberate
// click. It is still allowed; Rick decides. Esc still cancels.
//
// Pure value built from the same plan the routine runs (`catalogTrashPlan`),
// so the count shown is the set handed on; each file is still re-checked at
// its own turn. (For Rick: a plain struct of numbers and strings — no UI.)

import Foundation

struct CatalogTrashConfirmation: Equatable {
    /// One reason something will be held back, with how many files.
    struct Held: Equatable {
        let reason: String
        let count: Int
    }

    let moveCount: Int
    let moveBytes: Int64
    /// In the plan's fixed reason order.
    let held: [Held]
    /// How many of the files that will move are the only copy the catalog
    /// knows of (the plan's `onlyCopy`, computed before the alert).
    let onlyCopyCount: Int
    /// The whole recovered A/V pairs among the files that will move.
    let groupCount: Int
    /// One line per such pair, from the plan (capped).
    let groupLines: [String]

    static let moveButton = "Move to Trash"
    static let groupLineCap = 5

    /// `sizes` = catalog size per record id (an estimate for the question;
    /// the result reports the measured sizes).
    init(plan: VideoScanModel.CatalogTrashPlan, sizes: [UUID: Int64]) {
        moveCount = plan.toTrash.count
        moveBytes = plan.toTrash.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        held = VideoScanModel.CatalogTrashPlan.Refusal.allCases.compactMap { reason in
            let n = plan.refusedCount(reason)
            return n > 0 ? Held(reason: Self.words(reason), count: n) : nil
        }
        onlyCopyCount = plan.onlyCopy.count
        groupCount = plan.groups.count
        var lines = plan.groups.prefix(Self.groupLineCap).map(Self.groupLine)
        if plan.groups.count > Self.groupLineCap {
            let more = plan.groups.count - Self.groupLineCap
            lines.append("…and \(more) more pair group\(more == 1 ? "" : "s").")
        }
        groupLines = lines
    }

    /// "Move this clip and its related half to the Trash: a.mxf + b.mxf."
    static func groupLine(_ g: CatalogPairGroups.Group) -> String {
        let files = g.filenames.joined(separator: " + ")
        var line: String
        switch g.relatedCount {
        case 0: line = "Move this clip to the Trash: \(files)"
        case 1: line = "Move this clip and its related half to the Trash: \(files)"
        default: line = "Move this clip and its \(g.relatedCount) related halves to the Trash: \(files)"
        }
        if !g.departed.isEmpty {
            line += " (\(CatalogPairGroups.list(g.departed)) \(g.departed.count == 1 ? "was" : "were") already removed from the catalog)"
        }
        return line + "."
    }

    /// Something can move — the confirmation is shown. (Nothing can move:
    /// no question; the result lists every file and why it stayed.)
    var canMove: Bool { moveCount > 0 }

    /// Return presses Move to Trash only when no file is the only copy.
    /// Otherwise Move to Trash is a destructive button with no key — a
    /// deliberate click (tab-charter audit T3). Esc still cancels.
    var moveIsDefault: Bool { onlyCopyCount == 0 }

    /// "⚠︎ 2 of these are the only copy we know of." — nil when none is.
    var onlyCopyWarning: String? {
        guard onlyCopyCount > 0 else { return nil }
        if moveCount == 1 { return "⚠︎ This is the only copy we know of." }
        return "⚠︎ \(onlyCopyCount) of these \(onlyCopyCount == 1 ? "is" : "are") the only copy we know of."
    }

    /// "Move 3 files (1.2 GB) to the Trash?" — with whole pairs among
    /// them: "Move 4 files · 2 pair groups (1.2 GB) to the Trash?"
    var title: String {
        let size = ByteCountFormatter.string(fromByteCount: moveBytes, countStyle: .file)
        let groups = groupCount == 0 ? "" : " · \(groupCount) pair group\(groupCount == 1 ? "" : "s")"
        return "Move \(moveCount) file\(moveCount == 1 ? "" : "s")\(groups) (\(size)) to the Trash?"
    }

    /// The put-back sentence, then what will be held back and why.
    var detail: String {
        // The 11/01 "what and how long" rule: what it touches, what it
        // never touches, how long (CatalogActionBrief.deleteSelectedFiles).
        var text = "\(moveCount == 1 ? "It moves" : "They move") to the Finder Trash; you can put \(moveCount == 1 ? "it" : "them") back until you empty it."
        text += "\n" + CatalogActionBrief.deleteSelectedFiles.neverTouches + " " + CatalogActionBrief.deleteSelectedFiles.time.words
        if !groupLines.isEmpty { text += "\n\n" + groupLines.joined(separator: "\n") }
        if let warning = onlyCopyWarning { text += "\n\n" + warning }
        let heldCount = held.reduce(0) { $0 + $1.count }
        if heldCount > 0 {
            let reasons = held.map { "\($0.reason) (\($0.count))" }.joined(separator: ", ")
            text += "\n\n\(heldCount) will be held back: \(reasons)."
        }
        return text
    }

    /// A plan refusal in the person's words.
    static func words(_ reason: VideoScanModel.CatalogTrashPlan.Refusal) -> String {
        switch reason {
        case .masterArchive: return "in the Master Archive or on a protected drive"
        case .pairMember: return "half of a recovered audio/video pair not selected whole"
        case .pairGroupHeld: return "held with its recovered audio/video pair"
        case .offlineVolume: return "drive not connected"
        case .notActive: return "already removed or set aside"
        }
    }
}
