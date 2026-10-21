// PreflightQAR1RedTests.swift
// QA round 1 on bb49d543f: RED tests authored by the reviewer. Each one
// fails on bb49d543f and names the line it pins. Extensions of the existing
// suites, so the gauntlet manifest needs no new suite entry.

import Foundation
import Testing
@testable import VideoScanCore

extension PreflightGateTests {

    /// PreflightGate.swift:100-105 — the reserve left behind a same-disk job is
    /// only the BYTE floor (max(20 GB, 3x catalog)); the 95%-used half of the
    /// red line is ignored, so the gate starts a job that ends with the disk red.
    @Test func qaR1_longJobOnCatalogDiskMustNotLeaveTheDiskRedByPercent() {
        let gb = PreflightThresholds.gigabyte
        let disk = PreflightVolume(id: "/", name: "Macintosh HD", availableBytes: 250 * gb, totalBytes: 4_000 * gb)
        let catalog: UInt64 = 275_000_000
        #expect(PreflightDiskRule.judge(disk, catalogBytes: catalog, thresholds: PreflightThresholds()).0 == .warn)
        let verdict = PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: 100 * gb),
                                           catalogVolume: disk, catalogBytes: catalog)
        // After the job: 150 GB free of 4 TB = 96.25% used — red.
        let after = PreflightVolume(id: "/", name: "Macintosh HD", availableBytes: 150 * gb, totalBytes: 4_000 * gb)
        #expect(PreflightDiskRule.judge(after, catalogBytes: catalog, thresholds: PreflightThresholds()).0 == .red)
        #expect(verdict != .go, "the gate started a job that drives the catalog disk into red")
    }

    /// PreflightGate.swift:95-98 — on a red disk the refusal's shortfall is only
    /// "bytes to leave red"; it ignores the job's own need, so "free at least X
    /// more" is a lie: the person frees X, retries, and is refused again.
    @Test func qaR1_redRefusalStatesTheWholeShortfall() {
        let gb = PreflightThresholds.gigabyte
        let red = PreflightVolume(id: "/", name: "Macintosh HD", availableBytes: 40 * gb, totalBytes: 1_000 * gb)
        let verdict = PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: 200 * gb),
                                           catalogVolume: red, catalogBytes: 275_000_000)
        guard case .refused(_, _, let short) = verdict else {
            Issue.record("expected refused, got \(verdict)")
            return
        }
        // The job needs 200 GB + the 20 GB reserve = 220 GB; 40 GB is free.
        #expect(short >= 180 * gb, "short \(short) bytes: freeing that much still won't let the job start")
    }

    /// SystemPreflightProbe.swift:33,36 — availableBytes is
    /// volumeAvailableCapacityForImportantUsage, which counts purgeable space
    /// macOS has NOT freed. A SQLite commit's write() does not wait for the
    /// purge, so the edit floor and the red line must use the bytes that are
    /// free right now. Fails on any Mac with purgeable space (8.2 GB on the M4
    /// on 2026-10-21).
    @Test func qaR1_realProbeNeverReportsMoreThanActuallyFreeBytes() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let volume = try #require(try SystemPreflightProbe().volume(containing: home))
        let realFree = try #require(try home.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
        #expect(volume.availableBytes <= Int64(realFree) + 64 * 1_048_576,
                "probe says \(volume.availableBytes) free; the disk has \(realFree) actually free")
    }
}

extension LaunchPreflightTests {

    /// LaunchPreflight.swift:293 / PreflightGate.swift:114-120 — the hold is
    /// computed from the disk alone. A catalog that FAILED quick_check gets the
    /// words "please don't edit until it's sorted out", but hold stays .none and
    /// PreflightGate.decide(.edit) says .go: the words promise a hold nothing enforces.
    @Test func qaR1_catalogThatFailedQuickCheckHoldsEdits() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.quickCheck = .problems(["Page 7: btreeInitPage() returns error code 11"], elapsed: .milliseconds(5))
        let report = try await LaunchPreflight.run(Self.context, probe: probe)
        #expect(report.checks.first { $0.id == .catalogQuickCheck }?.level == .red)
        #expect(report.hold == .edits, "red catalog words say don't edit; hold is \(report.hold)")
    }

    /// Same seam, the cutover marker (#354 "refuse loudly").
    @Test func qaR1_missingCutoverMarkerHoldsEdits() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.files.removeValue(forKey: Self.context.latchURL.path)
        let report = try await LaunchPreflight.run(Self.context, probe: probe)
        #expect(report.hold == .edits, "missing catalog.cutover; hold is \(report.hold)")
    }
}
