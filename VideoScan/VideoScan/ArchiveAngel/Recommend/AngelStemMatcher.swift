// AngelStemMatcher.swift
// The Archive Angel's file-stem matcher for the `appCache` floor — a
// CLOSED, linear-time language that replaced the policy's regular
// expression (codex #1643, 2026-09-23).
//
// Why: `tables.appCacheNamePattern` was a user-supplied regular expression
// run once per record on the main actor. A shape check plus one timed probe
// cannot bound a backtracking engine: `^a*a*a*a*a*a*a*a*a*b$` passed
// validation in 1 ms and took > 2 s on a 30-character name, and
// `^[a1_-]*[a1_-]*[a1_-]*[a1_-]*[a1_-]*b$` hung validation itself. Rick's
// requirement is programmable criteria, not arbitrary regex — so the policy
// language no longer has a regex anywhere.
//
// The language (policy `tables`):
//   appCacheStemNames     bare tool nouns: the whole stem equals one
//                         ("Cache", "render"), case-insensitively
//   appCacheStemNumbered  true: a noun may be followed by an optional ONE
//                         separator (space, `_` or `-`) and a number
//                         ("Cache-30", "render_7", "tmp12")
//   appCacheStemGlobs     extra whole-stem patterns, literal text with `*`
//                         = any run of characters: "render*" (prefix),
//                         "*_proxy" (suffix), "pre*post", or "*cache*"
//                         (contains). At most one `*`, or exactly two
//                         when they are the first and last character.
//
// Cost: the stem is case-folded once (O(n)); the nouns are an O(Σ|noun|)
// prefix check plus an O(1) look at a precomputed digit tail; an exact /
// prefix / suffix glob is O(|glob|); a contains glob is Knuth–Morris–Pratt,
// O(n + |glob|). Nothing backtracks — the worst case is linear in the stem
// times the (validated, capped) table size. The default table is exactly
// the retired pattern `^(cache|render|proxy|proxies|preview|thumb|
// thumbnail|temp|tmp)([ _-]?\d+)?$` (case-insensitive): `\d` is a Unicode
// decimal digit, case folding is Unicode simple folding, and even the
// retired `$` quirk is kept (it also matched before ONE final line
// terminator). AngelStemMatcherTests pins parity against that regex.
//
// (For Rick: a hand-rolled matcher over a vector<uint32_t> of folded code
// points — no engine, no recursion, no allocation per candidate beyond the
// folded copy of the stem.)

import Foundation

struct AngelStemMatcher: Sendable, Equatable {

    /// One pattern of `appCacheStemGlobs`, compiled.
    enum Glob: Sendable, Equatable {
        case exact([UInt32])
        case prefix([UInt32])
        case suffix([UInt32])
        case prefixSuffix([UInt32], [UInt32])
        /// The literal and its KMP failure table.
        case contains([UInt32], [Int])
    }

    let names: [[UInt32]]
    let numbered: Bool
    let globs: [Glob]
    /// The folded first scalar of every name — most stems are rejected on
    /// their first character without folding the rest (the sweep asks this
    /// of every record: 100k per pass).
    private let nameFirstsASCII: [Bool]
    private let nameFirstsOther: Set<UInt32>

    init(names: [String], numbered: Bool, globs: [String]) {
        self.names = names.map(Self.folded).filter { !$0.isEmpty }
        self.numbered = numbered
        self.globs = globs.compactMap(Self.compile)
        var ascii = [Bool](repeating: false, count: 128)
        var other = Set<UInt32>()
        for n in self.names {
            if n[0] < 128 { ascii[Int(n[0])] = true } else { other.insert(n[0]) }
        }
        nameFirstsASCII = ascii
        nameFirstsOther = other
    }

    static func == (a: AngelStemMatcher, b: AngelStemMatcher) -> Bool {
        a.names == b.names && a.numbered == b.numbered && a.globs == b.globs
    }

    // MARK: Matching

    /// Does `stem` (a filename without its extension) match? Linear time;
    /// no allocation unless the table has globs.
    func matches(_ stem: String) -> Bool {
        let scalars = stem.unicodeScalars
        if !names.isEmpty, matchesNames(scalars) { return true }
        guard !globs.isEmpty else { return false }
        let folded = scalars.map(Self.fold)
        for g in globs where Self.matches(g, folded) { return true }
        return false
    }

    /// noun, or (when `numbered`) noun + optional one separator + digits —
    /// the whole stem, allowing one final line terminator (the retired
    /// `$`). Walks the scalar view in place: O(Σ|noun|) for the prefixes,
    /// plus ONE backward walk over the trailing digits (only once a noun
    /// has matched, and shared by every noun).
    private func matchesNames(_ scalars: String.UnicodeScalarView) -> Bool {
        guard let first = scalars.first else { return false }
        let f = Self.fold(first)
        guard f < 128 ? nameFirstsASCII[Int(f)] : nameFirstsOther.contains(f) else { return false }
        let start = scalars.startIndex
        var end = scalars.endIndex
        // `$` also matched before one final line terminator.
        let last = scalars.index(before: end)
        if scalars[last].value == 0x0A, last > start, scalars[scalars.index(before: last)].value == 0x0D {
            end = scalars.index(before: last)
        } else if Self.lineTerminators.contains(scalars[last].value) {
            end = last
        }
        var digitStart: String.Index?   // the maximal run of digits ending at `end` starts here
        for noun in names where noun[0] == f {
            var i = start
            var k = 0
            while k < noun.count, i < end, Self.fold(scalars[i]) == noun[k] {
                i = scalars.index(after: i)
                k += 1
            }
            guard k == noun.count else { continue }
            if i == end { return true }
            guard numbered else { continue }
            if digitStart == nil {
                var d = end
                while d > start, Self.isDecimalDigit(scalars[scalars.index(before: d)]) { d = scalars.index(before: d) }
                digitStart = d
            }
            guard let ds = digitStart, ds < end else { continue }
            // Rest = digits+ : the noun ends inside the digit run.
            if i >= ds { return true }
            // Rest = sep digits+ : one separator right before the run.
            if scalars.index(after: i) == ds, Self.separators.contains(scalars[i].value) { return true }
        }
        return false
    }

    /// `\d` in ICU: a Unicode decimal digit (Nd) — "3", "٣", "３".
    static func isDecimalDigit(_ s: Unicode.Scalar) -> Bool {
        if s.value < 0x80 { return (0x30...0x39).contains(s.value) }
        return s.properties.generalCategory == .decimalNumber
    }

    private static func matches(_ g: Glob, _ s: [UInt32]) -> Bool {
        switch g {
        case .exact(let lit):
            return s == lit
        case .prefix(let lit):
            return s.count >= lit.count && s.starts(with: lit)
        case .suffix(let lit):
            return s.count >= lit.count && s[(s.count - lit.count)...].elementsEqual(lit)
        case .prefixSuffix(let pre, let suf):
            return s.count >= pre.count + suf.count && s.starts(with: pre)
                && s[(s.count - suf.count)...].elementsEqual(suf)
        case .contains(let lit, let failure):
            return kmpContains(s, lit, failure)
        }
    }

    /// Knuth–Morris–Pratt: O(|s| + |lit|), never backtracks over `s`.
    private static func kmpContains(_ s: [UInt32], _ lit: [UInt32], _ failure: [Int]) -> Bool {
        guard !lit.isEmpty else { return true }
        var k = 0
        for c in s {
            while k > 0 && lit[k] != c { k = failure[k - 1] }
            if lit[k] == c { k += 1 }
            if k == lit.count { return true }
        }
        return false
    }

    private static func failureTable(_ lit: [UInt32]) -> [Int] {
        var f = [Int](repeating: 0, count: lit.count)
        var k = 0
        var i = 1
        while i < lit.count {
            while k > 0 && lit[i] != lit[k] { k = f[k - 1] }
            if lit[i] == lit[k] { k += 1 }
            f[i] = k
            i += 1
        }
        return f
    }

    // MARK: Folding

    /// " ", "_", "-".
    static let separators: Set<UInt32> = [0x20, 0x5F, 0x2D]
    /// What ICU's `$` accepts before the end: LF, VT, FF, CR, NEL, LS, PS.
    static let lineTerminators: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    /// Unicode simple case folding of one scalar (what a case-insensitive
    /// regex compares): ASCII by arithmetic; a non-ASCII scalar only when
    /// it changes under folding and folds to ONE scalar ("ſ" → "s",
    /// "K" (Kelvin) → "k"); a multi-scalar folding ("ﬀ", "İ") is kept as
    /// is — the retired regex did not match those either.
    static func fold(_ s: Unicode.Scalar) -> UInt32 {
        let v = s.value
        if v < 0x80 { return (0x41...0x5A).contains(v) ? v | 0x20 : v }
        guard s.properties.changesWhenCaseFolded else { return v }
        let f = String(s).folding(options: [.caseInsensitive], locale: nil).unicodeScalars
        guard f.count == 1, let only = f.first else { return v }
        return only.value
    }

    static func folded(_ text: String) -> [UInt32] { text.unicodeScalars.map(fold) }

    // MARK: Globs

    /// nil for a pattern `problems` refuses (validation names it).
    static func compile(_ glob: String) -> Glob? {
        guard globProblem(glob) == nil else { return nil }
        let f = folded(glob)
        let star: UInt32 = 0x2A
        let stars = f.indices.filter { f[$0] == star }
        switch stars.count {
        case 0:
            return .exact(f)
        case 1:
            let i = stars[0]
            if i == 0 { return .suffix(Array(f[1...])) }
            if i == f.count - 1 { return .prefix(Array(f[..<i])) }
            return .prefixSuffix(Array(f[..<i]), Array(f[(i + 1)...]))
        default:
            let lit = Array(f[1..<(f.count - 1)])
            return .contains(lit, failureTable(lit))
        }
    }

    static let maxNames = 500
    static let maxGlobs = 100
    static let maxTokenLength = 100

    /// Why one glob is refused, or nil.
    static func globProblem(_ glob: String) -> String? {
        let scalars = Array(glob.unicodeScalars)
        if scalars.isEmpty { return "is empty" }
        if scalars.count > maxTokenLength { return "is longer than \(maxTokenLength) characters" }
        let stars = scalars.indices.filter { scalars[$0] == "*" }
        if stars.count == scalars.count { return "is only `*` — it would match every file" }
        switch stars.count {
        case 0, 1: return nil
        case 2 where stars[0] == 0 && stars[1] == scalars.count - 1: return nil
        default: return "has more than one `*` (allowed: one `*`, or `*text*` for \"contains\")"
        }
    }

    /// Every problem with a names/globs table; empty = usable.
    static func problems(names: [String], globs: [String]) -> [String] {
        var out: [String] = []
        if names.count > maxNames { out.append("tables.appCacheStemNames: more than \(maxNames) entries") }
        if globs.count > maxGlobs { out.append("tables.appCacheStemGlobs: more than \(maxGlobs) entries") }
        for (i, n) in names.enumerated() {
            if n.unicodeScalars.isEmpty {
                out.append("tables.appCacheStemNames[\(i)] is empty")
            } else if n.unicodeScalars.count > maxTokenLength {
                out.append("tables.appCacheStemNames[\(i)] is longer than \(maxTokenLength) characters")
            } else if n.contains("*") {
                out.append("tables.appCacheStemNames[\(i)] \"\(n)\" has a `*` — a name is literal (put patterns in appCacheStemGlobs)")
            }
        }
        for (i, g) in globs.enumerated() {
            if let why = globProblem(g) { out.append("tables.appCacheStemGlobs[\(i)] \"\(g.prefix(40))\" \(why)") }
        }
        return out
    }

    // MARK: The retired regular expression

    /// The pattern the policy carried until codex #1643 (bundled default,
    /// rules v11). A policy.json copied from that bundled file still has it.
    static let retiredDefaultPattern = #"^(cache|render|proxy|proxies|preview|thumb|thumbnail|temp|tmp)([ _-]?\d+)?$"#

    enum RetiredPatternVerdict: Equatable {
        /// Migrate: these names, numbered or not.
        case names([String], numbered: Bool)
        /// Refuse the file, with this reason.
        case refuse(String)
    }

    /// What to do with a policy.json that still has `tables.appCacheNamePattern`.
    /// NO regex engine runs here — a linear parse of the text:
    ///   • the retired default, byte for byte → the default names, numbered;
    ///   • a plain anchored literal alternation `^(a|b|c)$` (or `^a$`,
    ///     `^(?:a|b)$`) of ASCII letters, digits, space, `_`, `-` → those
    ///     names, not numbered (exactly what that regex matched; a `.` is
    ///     "any character" in a regex, so it is not literal and refused);
    ///   • anything else → refused, with the reason.
    static func migrateRetired(_ value: Any) -> RetiredPatternVerdict {
        let why = "is a regular expression — no longer read: a pattern can hang the Angel's sweep (codex #1643). "
            + "Use tables.appCacheStemNames / appCacheStemNumbered / appCacheStemGlobs (docs/archive_angel_policy.md)"
        guard let pattern = value as? String else { return .refuse(why) }
        if pattern == retiredDefaultPattern {
            return .names(AngelPolicyTables.standard.appCacheStemNames, numbered: true)
        }
        guard pattern.count <= 300, pattern.hasPrefix("^"), pattern.hasSuffix("$"), pattern.count >= 3 else {
            return .refuse(why)
        }
        var body = String(pattern.dropFirst().dropLast())
        if body.hasPrefix("(?:"), body.hasSuffix(")") {
            body = String(body.dropFirst(3).dropLast())
        } else if body.hasPrefix("("), body.hasSuffix(")") {
            body = String(body.dropFirst().dropLast())
        }
        let alternatives = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let plain = alternatives.allSatisfy { alt in
            !alt.isEmpty && alt.unicodeScalars.allSatisfy { s in
                (s.value < 0x80 && (CharacterSet.alphanumerics.contains(s) || " _-".unicodeScalars.contains(s)))
            }
        }
        return plain ? .names(alternatives, numbered: false) : .refuse(why)
    }
}
