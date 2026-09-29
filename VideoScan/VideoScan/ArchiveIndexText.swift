// ArchiveIndexText.swift
// THE one way to split archive-index text (00_Index manifest CSV, the
// promote / attestation JSONL journals) into lines.
//
// Why a helper: in Swift "\r\n" is ONE Character (a grapheme cluster), so
// `text.split(separator: "\n")` never separates CRLF-terminated records —
// a CRLF manifest reads as one giant line and every row after the first
// CRLF is silently dropped (codex r2 #3, first fixed in ArchiveLockJob by
// e9277d5d; the other readers had the same split). C++ analogy: iterating
// a String yields grapheme clusters, not bytes, so a "\n" char comparison
// can never match the middle of a "\r\n" cluster.
//
// Contract (read-only; nothing here decides what is written):
//   • "\n" and "\r\n" both terminate a line (mixed files are fine).
//   • A "\r" left at the very end of a line is dropped.
//   • A lone "\r" in the middle of a line is NOT a terminator (classic
//     Mac endings are not a format any writer of ours ever produced; such
//     a line stays one line and is judged — usually refused — by the
//     caller's own row validation).
//   • omittingEmpty: true (default) matches `split(separator:)`'s
//     default; false keeps blank lines so line numbers stay 1:1 with the
//     file (ArchiveLockJob reports "manifest line N").
// The header check in ArchivePromoteEngine.openIndexFile is byte-based
// and deliberately NOT relaxed: a CRLF header still refuses.
//
// SENSOR: ArchiveIndexLineSplitSensorTests fails if an index reader splits
// text on Character "\n" anywhere else.

import Foundation

enum ArchiveIndexText {

    /// Lines of `text`, terminators removed (see the file header).
    /// (`nonisolated` ≈ a free function: callable from background readers.)
    nonisolated static func lines(_ text: String, omittingEmpty: Bool = true) -> [Substring] {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        var out: [Substring] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            let line = part.last == "\r" ? part.dropLast() : part
            if omittingEmpty && line.isEmpty { continue }
            out.append(line)
        }
        return out
    }
}
