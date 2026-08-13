import Foundation
import Testing
@testable import VideoScan

// MARK: - Signature lane planning at scale (codex #322, #324)
//
// The partition is where the dangerous bugs live, and they are not
// races — no worker shares mutable state. They are ACCOUNTING bugs:
//
//   * a file assigned to two lanes  → wasted I/O, harmless
//   * a file assigned to NO lane    → never signed, silently absent from
//                                     duplicate detection forever
//   * lanes exceeding the cap       → memory and I/O-scheduler blowout
//
// All three are invisible at runtime and provable here, which is the
// whole reason the split is a pure function.
//
// codex's stress run found the third one: above 24 volumes the cap was
// not merely exceeded, it was ABANDONED — 30 volumes produced 240 lanes
// and ~240 MiB of buffers against an intended 24.

private func items(_ n: Int, groups: Int) -> [SignatureWorkItem] {
    (0..<n).map {
        SignatureWorkItem(id: UUID(), path: "/Volumes/V\($0 % groups)/f\($0).mov")
    }
}

private let volumeOfPath: (String) -> String = { path in
    path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
}

@Suite("Signature lanes — scale and hard cap")
struct SignatureConcurrencyScaleTests {

    /// THE invariant. Every item lands in exactly one lane, at every
    /// fleet size — including the sizes where the cap starts biting.
    @Test func exactlyOnceAcrossOneToThirtyVolumes() {
        for groups in 1...30 {
            let input = items(3_000, groups: groups)
            let lanes = SignatureConcurrency.partition(
                items: input, volumeOf: volumeOfPath, lanesFor: { _ in 8 })

            let flat = lanes.flatMap { $0 }
            #expect(flat.count == input.count,
                    "\(groups) volumes: expected \(input.count) items, got \(flat.count)")
            #expect(Set(flat.map(\.id)).count == input.count,
                    "\(groups) volumes: duplicate or missing item")
        }
    }

    /// SENSOR for codex #322. The cap is absolute — not "usually", and
    /// emphatically not "until you exceed it with volumes".
    @Test func laneCountNeverExceedsTheCap() {
        for groups in 1...30 {
            let lanes = SignatureConcurrency.partition(
                items: items(2_000, groups: groups), volumeOf: volumeOfPath,
                lanesFor: { _ in 8 })
            let cap = SignatureConcurrency.totalLaneCap
            #expect(lanes.count <= cap,
                    "\(groups) volumes produced \(lanes.count) lanes, cap \(cap)")
        }
    }

    /// The exact boundary codex measured: 23/24/25/30 previously gave
    /// 23/24/200/240.
    @Test func sharpBoundaryAroundTheCap() {
        for groups in [23, 24, 25, 30] {
            let lanes = SignatureConcurrency.partition(
                items: items(1_200, groups: groups), volumeOf: volumeOfPath,
                lanesFor: { _ in 8 })
            #expect(lanes.count <= 24, "\(groups) volumes → \(lanes.count) lanes")
            #expect(lanes.flatMap { $0 }.count == 1_200, "\(groups) volumes lost items")
        }
    }

    /// Below the cap, every volume still gets at least one reader —
    /// Rick's floor: "4 volumes means minimally 4 threads."
    @Test func everyVolumeKeepsALaneBelowTheCap() {
        let lanes = SignatureConcurrency.partition(
            items: items(400, groups: 4), volumeOf: volumeOfPath,
            lanesFor: { _ in 1 })
        #expect(lanes.count == 4)
    }

    /// A spinning drive must never see two concurrent readers, even when
    /// packing kicks in above the cap — that is the property the HDD
    /// policy exists to guarantee, and packing whole volume-lanes
    /// together is what preserves it.
    @Test func hddVolumesNeverSplitAcrossTwoLanes() {
        let lanes = SignatureConcurrency.partition(
            items: items(3_000, groups: 30), volumeOf: volumeOfPath,
            lanesFor: { _ in 1 })   // every volume an HDD
        for volume in (0..<30).map({ "V\($0)" }) {
            let carrying = lanes.filter { lane in
                lane.contains { volumeOfPath($0.path) == volume }
            }
            #expect(carrying.count == 1,
                    "\(volume) is being read by \(carrying.count) lanes at once")
        }
    }

    /// Performance: the plan runs before any I/O starts, so it must not
    /// itself be the slow part. codex measured 1...24 at 0.297s.
    @Test func planningOneHundredThousandItemsIsFast() {
        let input = items(100_000, groups: 12)
        let start = ContinuousClock.now
        let lanes = SignatureConcurrency.partition(
            items: input, volumeOf: volumeOfPath, lanesFor: { _ in 6 })
        let elapsed = ContinuousClock.now - start
        #expect(lanes.flatMap { $0 }.count == 100_000)
        #expect(elapsed < .seconds(10), "planning took \(elapsed)")
    }

    /// The media policy table, pinned. Rick's Pegasus R4 is RAID-5 with
    /// spinning drives behind it, so 4 is the number that will actually
    /// be used tomorrow.
    @Test func mediaPolicyTable() {
        #expect(SignatureConcurrency.lanes(for: .hdd) == 1)
        #expect(SignatureConcurrency.lanes(for: .ssd) == 6)
        #expect(SignatureConcurrency.lanes(for: .raid0) == 8)
        #expect(SignatureConcurrency.lanes(for: .raid10) == 8)
        #expect(SignatureConcurrency.lanes(for: .raid5) == 4, "Pegasus R4")
        #expect(SignatureConcurrency.lanes(for: .raid1) == 4)
        #expect(SignatureConcurrency.lanes(for: .network) == 3)
        #expect(SignatureConcurrency.lanes(for: .cloud) == 4)
        #expect(SignatureConcurrency.lanes(for: .unknown) == 2)
    }
}

// MARK: - Delete safety (codex #320 blocker)

@Suite("Signature verification — the delete gate")
struct SignatureVerificationTests {

    private func tempFile(_ name: String, _ bytes: [UInt8]) -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SigVerify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url.path
    }

    /// THE blocker, demonstrated. Two files with identical size, head and
    /// tail that differ only in an UNSAMPLED region share a segmented
    /// signature — and full verification catches them. This is why a
    /// matching signature may never authorise a deletion by itself.
    @Test func unsampledDifferenceFoolsTheSignatureButNotVerification() {
        // 8 KiB with a 1 KiB segment. The sampled windows are
        // head 0-1023, middle 3584-4607, tail 7168-8191 — leaving real
        // gaps at 1024-3583 and 4608-7167. Byte 6000 sits in the second
        // gap, so no window ever sees it.
        //
        // (My first attempt used 4500, which is INSIDE the middle window
        // — the test failed and the code was right. Worth recording:
        // the unsampled region is smaller than it looks.)
        let seg = 1024
        var a = [UInt8](repeating: 7, count: 8192)
        var b = a
        b[6000] = 200

        let pa = tempFile("a.mov", a), pb = tempFile("b.mov", b)
        let sa = FileHasher.segmentedHash(path: pa, segmentSize: seg)
        let sb = FileHasher.segmentedHash(path: pb, segmentSize: seg)

        #expect(sa == sb,
                "precondition: sampling cannot see this difference — that is the point")
        #expect(FileHasher.fullHash(path: pa) != FileHasher.fullHash(path: pb),
                "full hash MUST see it")

        let verdict = SignatureVerification.verify(keeperPath: pa, duplicatePath: pb)
        #expect(verdict == .failure(.contentDiffers),
                "the delete gate must refuse a pair the signature called identical")
        a.removeAll(); b.removeAll()
    }

    @Test func identicalFilesVerify() {
        let bytes = (0..<5000).map { UInt8($0 % 251) }
        let pa = tempFile("x.mov", bytes), pb = tempFile("y.mov", bytes)
        guard case .success(let proof) =
                SignatureVerification.verify(keeperPath: pa, duplicatePath: pb) else {
            Issue.record("identical files should verify"); return
        }
        #expect(proof.keeperPath == pa)
        #expect(!proof.fullHash.isEmpty)
    }

    /// Deleting "the duplicate" when both paths are the same file would
    /// delete the only copy.
    @Test func samePathIsRefused() {
        let p = tempFile("solo.mov", [1, 2, 3])
        #expect(SignatureVerification.verify(keeperPath: p, duplicatePath: p)
                == .failure(.samePath))
    }

    @Test func unreadableInputIsRefusedNotAssumedEqual() {
        let p = tempFile("real.mov", [1, 2, 3])
        let verdict = SignatureVerification.verify(
            keeperPath: p, duplicatePath: "/nonexistent/gone.mov")
        #expect(verdict == .failure(.unreadable("/nonexistent/gone.mov")))
    }
}
