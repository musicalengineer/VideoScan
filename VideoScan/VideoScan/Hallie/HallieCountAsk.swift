// HallieCountAsk.swift
// "how many …" / "how much …" / "the number of …": the question asks for
// a COUNT, so the answer's list is remembered as a count scope and the
// next fragment ("and the 80s?") stays a count (design §3.2, §3.5). Pure.

import Foundation

enum HallieCountAsk {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\bhow\s+many\b|\bhow\s+much\b|\bnumber\s+of\b|\bcount\s+(?:of|the|how|up)\b|\btotal\s+(?:number|count)\b|\bhow\s+many\s+of\s+those\b"#,
        options: .caseInsensitive)

    static func isCountAsk(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 512 else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
