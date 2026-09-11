// ArchiveAngelCatalogBadgeTests.swift
// "Promote me" / "Worth a look" in the Tag column (Rick 2026-09-11) —
// pure mapping from the Archive Angel grade; C, D and excluded rows draw
// nothing so the to-do view stays calm.

import Foundation
import SwiftUI
import Testing
@testable import VideoScan

@Suite("Archive Angel — catalog badge")
struct ArchiveAngelCatalogBadgeTests {

    private func evidence(score: Int, rejection: ArchiveAngelRejection? = nil) -> ArchiveAngelEvidenceRecord {
        ArchiveAngelEvidenceRecord(
            score: score,
            lines: [.init(points: 40, line: "★★★"), .init(points: 30, line: "Donna (confirmed)")],
            rejection: rejection, useCount: 3, lastUsed: nil,
            computedAt: Date(timeIntervalSince1970: 1_789_000_000))
    }

    @Test func gradeAIsPromoteMeInGreen() {
        let badge = ArchiveAngelCatalogBadge.make(for: evidence(score: 112))
        #expect(badge?.text == "Promote me")
        #expect(badge?.color == .green)
        #expect(badge?.help.hasPrefix("AAA grade A (112)") == true)
        #expect(badge?.help.contains("Donna (confirmed)") == true)
    }

    @Test func gradeBIsWorthALookInOrange() {
        let badge = ArchiveAngelCatalogBadge.make(for: evidence(score: 72))
        #expect(badge?.text == "Worth a look")
        #expect(badge?.color == .orange)
        #expect(badge?.help.hasPrefix("AAA grade B (72)") == true)
    }

    @Test func weakerGradesAndExclusionsDrawNothing() {
        #expect(ArchiveAngelCatalogBadge.make(for: evidence(score: 40)) == nil, "C")
        #expect(ArchiveAngelCatalogBadge.make(for: evidence(score: 10)) == nil, "D")
        #expect(ArchiveAngelCatalogBadge.make(for: evidence(score: 0)) == nil, "X by score")
        #expect(ArchiveAngelCatalogBadge.make(for: evidence(score: 150, rejection: .tooShort)) == nil,
                "a rejection is X whatever the score")
        #expect(ArchiveAngelCatalogBadge.make(for: nil) == nil, "no sidecar entry")
    }
}
