// CatalogTrashConfirmation.swift
// The ONE confirmation in front of the Catalog's Move to Trash — the row
// menu's item and ⌘⌫ alike (codex delete-engines F8, design R9: "one
// confirmation"). Both gestures end in `CatalogContent.confirmThenTrash`,
// which shows these words and, only on "Move to Trash", hands the rows to
// `VideoScanModel.trashSelectedRecords`.
//
//   Move 3 files (1.2 GB) to the Trash?
//   You can put them back from the Trash until you empty it.
//   2 will be held back: half of a recovered audio/video pair (1), drive not connected (1).
//   [Move to Trash]  [Cancel]        (Return = Move to Trash, Esc = Cancel)
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

    static let moveButton = "Move to Trash"

    /// `sizes` = catalog size per record id (an estimate for the question;
    /// the result reports the measured sizes).
    init(plan: VideoScanModel.CatalogTrashPlan, sizes: [UUID: Int64]) {
        moveCount = plan.toTrash.count
        moveBytes = plan.toTrash.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        held = VideoScanModel.CatalogTrashPlan.Refusal.allCases.compactMap { reason in
            let n = plan.refusedCount(reason)
            return n > 0 ? Held(reason: Self.words(reason), count: n) : nil
        }
    }

    /// Something can move — the confirmation is shown. (Nothing can move:
    /// no question; the result lists every file and why it stayed.)
    var canMove: Bool { moveCount > 0 }

    /// "Move 3 files (1.2 GB) to the Trash?"
    var title: String {
        let size = ByteCountFormatter.string(fromByteCount: moveBytes, countStyle: .file)
        return "Move \(moveCount) file\(moveCount == 1 ? "" : "s") (\(size)) to the Trash?"
    }

    /// The put-back sentence, then what will be held back and why.
    var detail: String {
        var text = "You can put \(moveCount == 1 ? "it" : "them") back from the Trash until you empty it."
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
        case .pairMember: return "half of a recovered audio/video pair"
        case .offlineVolume: return "drive not connected"
        case .notActive: return "already removed or set aside"
        }
    }
}
