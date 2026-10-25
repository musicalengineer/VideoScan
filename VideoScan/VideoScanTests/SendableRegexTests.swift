import Foundation
import Testing
@testable import VideoScan

/// `SendableRegex` is the one place a `Regex` is declared safe to share
/// (Swift 6 stage 4, #376). These pin the two things that matter: it is a
/// drop-in `RegexComponent` for every String API the Hallie statics flow
/// into — captures included — and a `static let` of it can be read from a
/// detached task (the compile-time proof the warning was about).
@Suite("SendableRegex")
struct SendableRegexTests {

    private static let dashed = SendableRegex(/(\d+)-(\w+)/)
    private static let seam = SendableRegex(/\s*,\s*/)
    private static let built = SendableRegex(try! Regex("a+"))

    // MARK: Logic — every String verb the statics are used with

    @Test func stringAPIsAcceptItWithCapturesIntact() throws {
        let m = try #require("12-ab".firstMatch(of: Self.dashed))
        #expect(m.1 == "12")
        #expect(m.2 == "ab")
        #expect("x 1-a y".contains(Self.dashed))
        #expect(!"nothing".contains(Self.dashed))
        #expect("1-a,2-b".matches(of: Self.dashed).count == 2)
        #expect("a1-bc".replacing(Self.dashed, with: "Z") == "aZ")
        #expect("a, b ,c".split(separator: Self.seam).map(String.init) == ["a", "b", "c"])
        let whole = try #require("7-seven".wholeMatch(of: Self.dashed))
        #expect(whole.2 == "seven")
        #expect("7-seven!".wholeMatch(of: Self.dashed) == nil)
    }

    @Test func aRegexBuiltFromAStringWrapsToo() {
        #expect("caab".contains(Self.built))
        #expect("ccb".contains(Self.built) == false)
        #expect("caab".firstMatch(of: Self.built)?.0 == "aa")
    }

    // MARK: Isolation — readable from another isolation domain

    @Test func aStaticIsUsableFromADetachedTask() async {
        let hits = await Task.detached {
            (0..<200).reduce(into: 0) { acc, i in
                if "\(i)-k".contains(Self.dashed) { acc += 1 }
            }
        }.value
        #expect(hits == 200)
    }

    // MARK: Scale — concurrent matching on one shared instance agrees

    @Test func concurrentMatchersOnOneInstanceAgree() async {
        let total = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<2_000).reduce(into: 0) { acc, i in
                        if let m = "\(i)-v".firstMatch(of: Self.dashed), m.1 == "\(i)" { acc += 1 }
                    }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(total == 16_000)
    }
}
