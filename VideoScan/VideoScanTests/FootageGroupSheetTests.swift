// FootageGroupSheetTests.swift
// Copilot review of FootageGroups (2026-09-29), finding #1: the sheet built
// every member row eagerly (ScrollView → VStack → ForEach). Identical-byte
// merges are exempt from the grouping cap (FootageGrouping rule 2), so a
// group has no hard size bound. The fix: a LazyVStack, the member list
// still computed outside `body`, and only the first
// `FootageGroupSheet.initialVisibleMembers` rows until "Show all N".
//
// Sensors read the app source by NAME through SourceTree (never a path).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Source sensors

@Suite("Footage group sheet — member list is lazy and computed outside body")
struct FootageGroupSheetSourceSensorTests {

    /// The text of `FootageGroupSheet.body` — from `var body: some View {`
    /// to the first `// MARK:` after it (the sheet's "Pieces" section).
    private static func sheetBody() throws -> String {
        let src = try SourceTree.appSource(named: "FootageGroupSheet.swift")
        let start = try #require(src.range(of: "var body: some View {"), "FootageGroupSheet has no body")
        let rest = src[start.upperBound...]
        let end = rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("the member rows sit in a LazyVStack, not an eager VStack")
    func memberListIsLazy() throws {
        let body = try Self.sheetBody()
        #expect(body.contains("LazyVStack"), "member rows must be built lazily (Copilot #1)")
        // The ScrollView's direct child must be the lazy stack.
        let afterScroll = try #require(body.range(of: "ScrollView {"), "member list is no longer in a ScrollView")
        let next = body[afterScroll.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(next.hasPrefix("LazyVStack"), "ScrollView's content must be a LazyVStack, found: \(next.prefix(40))")
    }

    @Test("footageGroupMembers (one O(records) pass) is never called from body")
    func membersNotComputedInBody() throws {
        let body = try Self.sheetBody()
        #expect(!body.contains("footageGroupMembers"), "O(records) work in a view body")
        #expect(!body.contains("model.records"), "O(records) work in a view body")
        // …and it IS still called, from the sheet's reload (the .task / .onChange path).
        let src = try SourceTree.appSource(named: "FootageGroupSheet.swift")
        #expect(src.contains("model.footageGroupMembers(of:"), "the sheet no longer loads its members")
    }
}

// MARK: - Logic: the visible-member cap

@Suite("Footage group sheet — first N rows until Show all")
@MainActor
struct FootageGroupSheetVisibleMembersTests {

    private static func recs(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in let r = VideoRecord(); r.filename = "m\(i).mov"; return r }
    }

    @Test("a small group shows every member")
    func smallGroupShowsAll() {
        let m = Self.recs(12)
        #expect(FootageGroupSheet.visibleMembers(m, anchorID: m[5].id, showAll: false).map(\.id) == m.map(\.id))
    }

    @Test("a group at the limit shows every member; one over is cut to the limit")
    func boundary() {
        let n = FootageGroupSheet.initialVisibleMembers
        let at = Self.recs(n)
        #expect(FootageGroupSheet.visibleMembers(at, anchorID: at[0].id, showAll: false).count == n)
        let over = Self.recs(n + 1)
        let shown = FootageGroupSheet.visibleMembers(over, anchorID: over[0].id, showAll: false)
        #expect(shown.map(\.id) == over.prefix(n).map(\.id))
    }

    @Test("a large group is cut, but the anchor file is always shown; Show all shows everything")
    func largeGroupKeepsAnchor() {
        let m = Self.recs(5_000)
        let anchor = m[4_321]
        let shown = FootageGroupSheet.visibleMembers(m, anchorID: anchor.id, showAll: false)
        #expect(shown.count == FootageGroupSheet.initialVisibleMembers + 1)
        #expect(shown.last?.id == anchor.id)
        #expect(Array(shown.prefix(FootageGroupSheet.initialVisibleMembers)).map(\.id)
                == m.prefix(FootageGroupSheet.initialVisibleMembers).map(\.id), "likely-original order kept")
        #expect(FootageGroupSheet.visibleMembers(m, anchorID: anchor.id, showAll: true).count == 5_000)
    }
}

// MARK: - Scale: one huge Identical group

@Suite("Footage group sheet — SCALE: 5,000-member identical group", .serialized)
@MainActor
struct FootageGroupSheetScaleTests {

    private static func rec(_ i: Int, group: UUID?, rank: Int) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip\(i).mov"
        r.directory = "/Volumes/T/d\(i % 97)"
        r.fullPath = r.directory + "/" + r.filename
        r.durationSeconds = 10
        r.sizeBytes = 1000
        if let group {
            r.footage = FootageMembership(groupID: group, groupSize: 5_000, confidence: .identical,
                                          role: rank == 0 ? .original : .copy, rank: rank,
                                          likelyOriginalID: UUID(), originalInCatalog: true, evidence: [],
                                          scannedAt: Date(), algorithmVersion: 2)
        }
        return r
    }

    @Test("footageGroupMembers over 100k records with a 5,000-member group stays within budget",
          .timeLimit(.minutes(1)))
    func hugeIdenticalGroup() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("footage_sheet_scale")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let g = UUID()
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        // Members interleaved through the catalog in scrambled rank order,
        // so the filter walks everything and the sort has real work.
        for i in 0..<100_000 {
            let inGroup = i % 20 == 0
            rows.append(Self.rec(i, group: inGroup ? g : nil, rank: inGroup ? (i / 20 * 7_919) % 5_000 : 0))
        }
        m.records = rows
        let anchor = rows[20 * 123]

        let clock = ContinuousClock()
        var members: [VideoRecord] = []
        let elapsed = clock.measure { members = m.footageGroupMembers(of: anchor) }

        #expect(members.count == 5_000)
        #expect(members.first?.footage?.rank == 0, "likely original first")
        #expect(zip(members, members.dropFirst()).allSatisfy {
            ($0.footage?.rank ?? .max, $0.fullPath) <= ($1.footage?.rank ?? .max, $1.fullPath)
        })
        // One filter + one sort of 5k; measured well under this in Debug.
        #expect(elapsed < PerformanceLane.loadAwareDebugCeiling(.milliseconds(500)),
                "footageGroupMembers took \(elapsed) (\(PerformanceLane.loadDescription()))")
    }
}
