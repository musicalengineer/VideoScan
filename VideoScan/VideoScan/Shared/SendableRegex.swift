import Foundation

/// A `Regex` that may live in a `static let` under strict concurrency.
///
/// Swift 6: `Regex<Output>` is not marked `Sendable` in this SDK (Xcode 27 /
/// Swift 6.4) because a regex may be built from a custom
/// `CustomConsumingRegexComponent`, whose closure the compiler cannot vet.
/// Every regex in this app is a literal or `Regex(String)` — pure data: the
/// matching program is immutable after construction and its lazy
/// compilation is lock-guarded inside `_StringProcessing`, so matching from
/// several threads at once is safe. This wrapper is the ONE place that claim
/// is made (design doc §5 rule 1: "a type that is immutable after init but
/// holds a class"); delete it when `Regex` becomes `Sendable`.
///
/// Conforms to `RegexComponent`, so every `String` API — `contains(_:)`,
/// `firstMatch(of:)`, `wholeMatch(of:)`, `matches(of:)`, `replacing(_:with:)`,
/// `split(separator:)` — takes it unchanged, captures and all.
///
/// C++: a `const std::regex` at namespace scope. `std::regex_search` on a
/// const object is thread-safe by the standard; the Swift checker just cannot
/// see that from the type.
///
/// Memory: one `Regex` per static — a few KB each, allocated once per process.
struct SendableRegex<Output>: RegexComponent, @unchecked Sendable {
    let regex: Regex<Output>

    init(_ regex: Regex<Output>) {
        self.regex = regex
    }
}
