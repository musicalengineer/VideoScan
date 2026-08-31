import Testing
import Foundation
import VideoScanCore

/// One-off diagnostic against Rick's real export. Opt-in only.
struct RealTreeVerifyProbe {
    @Test func reportOnTheRealTree() throws {
        guard let path = ProcessInfo.processInfo.environment["VS_REAL_GEDCOM"] else {
            print("[verify] set VS_REAL_GEDCOM to run"); return
        }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let clock = ContinuousClock(); let t0 = clock.now
        let graph = GedcomFamilyGraph(gedcomText: text)
        let parsed = clock.now - t0
        let t1 = clock.now
        let report = FamilyTreeVerification.verify(graph)
        let verified = clock.now - t1

        print("[verify] people=\(report.peopleChecked) parse=\(parsed) verify=\(verified)")
        print("[verify] TOTAL findings=\(report.findings.count) needingReview=\(report.needingReview)")
        for kind in [FamilyTreeVerification.Kind.ancestorCycle, .deathBeforeBirth,
                     .duplicatePerson, .parentTooYoung, .implausibleLifespan,
                     .unattachedPerson, .placeholderValue] {
            print("[verify]   \(kind.rawValue): \(report.of(kind).count)")
        }
        print("[verify] --- first 12 needing review ---")
        for f in report.findings.filter({ $0.severity <= .review }).prefix(12) {
            let fs = f.familySearchIDs.isEmpty ? "" : "  [\(f.familySearchIDs.joined(separator: ", "))]"
            print("[verify] \(f.severity.rawValue.uppercased()) \(f.kind.rawValue): \(f.personNames.joined(separator: " + "))\(fs) — \(f.detail)")
        }
    }
}
