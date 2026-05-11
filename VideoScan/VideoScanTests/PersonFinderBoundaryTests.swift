import Testing
import Foundation
import Vision
import CoreImage
import CoreGraphics
@testable import VideoScan

// MARK: - PersonFinderModel Boundary / Characterization Tests
//
// Pre-refactor seam pinning. PersonFinderModel.swift (~3500 LOC) is about to
// be split into six files (Types, Detection, EngineDispatch, JobLifecycle,
// Compilation, CatalogFilter). These tests lock current observable behavior
// at the planned cut lines so we catch regressions during the split.
//
// Style mirrors PersonFinderLifecycleTests.swift: Swift Testing (@Test,
// #expect), MainActor-bound where touching the model, fixture paths derived
// from #filePath. C++ analogy: @Test ≈ TEST_F, #expect ≈ EXPECT_TRUE/EQ.
//
// IMPORTANT: characterization tests pin what IS, not what SHOULD BE. If a
// test seems to encode questionable behavior, that's intentional — the
// refactor agent should preserve it (or break it deliberately and update
// this file in the same commit).

@MainActor
struct PersonFinderBoundaryTests {

    // MARK: - 1. pfNormalizeFaceCrop: dimensions contract
    //
    // Refactor risk: pfNormalizeFaceCrop lives at file-scope and will move
    // into the Detection sub-file. The 256-default output size is baked into
    // the ReferenceFace.thumbnail contract — downstream consumers assume it.
    // Visibility: `nonisolated func` (internal) — reachable via @testable.

    @Test func pfNormalizeFaceCropDefaultProducesTargetSizeOutput() {
        // Build a 512x512 solid CGImage. Vision face crop math doesn't need
        // a real face — just valid geometry. The bbox spans (0.25..0.75) in
        // both axes (Vision coords: bottom-left origin, normalized) so the
        // 1.7x expansion stays within the image and crop succeeds.
        let img = Self.makeSolidCGImage(width: 512, height: 512, gray: 0.5)
        let obs = VNFaceObservation(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )

        let cropped = pfNormalizeFaceCrop(from: img, observation: obs)

        #expect(cropped != nil, "Crop should succeed for well-conditioned bbox")
        if let c = cropped {
            #expect(c.width == 256, "Default outputSize is 256; width was \(c.width)")
            #expect(c.height == 256, "Default outputSize is 256; height was \(c.height)")
        }
    }

    @Test func pfNormalizeFaceCropRespectsCustomOutputSize() {
        // Pin the outputSize parameter contract — callers (currently
        // ReferenceFace loading) rely on the default but if any future
        // call site passes a custom size, it must be honored.
        let img = Self.makeSolidCGImage(width: 512, height: 512, gray: 0.5)
        let obs = VNFaceObservation(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )

        let cropped = pfNormalizeFaceCrop(from: img, observation: obs, outputSize: 128)

        #expect(cropped?.width == 128)
        #expect(cropped?.height == 128)
    }

    @Test func pfNormalizeFaceCropReturnsNilForDegenerateBBox() {
        // Guard line `guard sideLen > 4 else { return nil }` — pin the
        // tiny-face rejection. A 1x1 px bbox in a 512px image gives
        // sideLen = 1 * 1.7 = 1.7 → nil.
        let img = Self.makeSolidCGImage(width: 512, height: 512, gray: 0.5)
        let obs = VNFaceObservation(
            boundingBox: CGRect(x: 0.5, y: 0.5,
                                width: 1.0 / 512.0, height: 1.0 / 512.0)
        )

        let cropped = pfNormalizeFaceCrop(from: img, observation: obs)
        #expect(cropped == nil, "Tiny bbox (<4px expanded side) should return nil")
    }

    // MARK: - 2. pfDetectFacesInBuffer: blank-buffer returns empty
    //
    // Refactor risk: this is the Phase-1 ANE entry point. It moves to the
    // Detection sub-file. Empty input → empty output is a load-bearing
    // invariant (the caller doesn't null-check, it iterates).
    // Visibility: `nonisolated func` (internal) — reachable.

    @Test func pfDetectFacesInBufferReturnsEmptyForBlankBuffer() {
        guard let buffer = Self.makeSolidPixelBuffer(width: 320, height: 240,
                                                     gray: 0.5) else {
            Issue.record("Could not allocate test CVPixelBuffer")
            return
        }

        let faces = pfDetectFacesInBuffer(buffer, orientation: .up)

        // A solid mid-gray buffer cannot contain a face. Vision must
        // return zero observations. If a future Vision revision starts
        // hallucinating faces in noise, this test will fail loudly.
        #expect(faces.isEmpty,
                "Solid pixel buffer should yield no face observations; got \(faces.count)")
    }

    // MARK: - 3. pauseJob / resumeJob round-trip preserves gate state
    //
    // Refactor risk: pause/resume is the cooperative-cancellation contract.
    // The status flips synchronously, but PauseGate updates happen on an
    // unstructured Task — order matters. Pin both surfaces.
    // Visibility: public model API + actor PauseGate (internal) — reachable.

    @Test func pauseThenResumeRoundTripsBothStatusAndGate() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")  // reachable, real path
        model.jobs.append(job)
        job.status = .scanning  // pre-condition for pauseJob

        // Round 1: pauseJob flips status to .paused synchronously, then
        // posts an async pauseGate.pause(). Wait for the Task hop.
        model.pauseJob(job)
        #expect(job.status == .paused, "pauseJob must set status synchronously")
        // Yield repeatedly so the unstructured Task runs. We can't await
        // it directly (no handle), but the actor will service the pause
        // call before our next await on it.
        await Task.yield()
        let gatePausedAfterPause = await job.pauseGate.isPaused
        #expect(gatePausedAfterPause, "PauseGate.isPaused should be true after pauseJob")

        // Round 2: resumeJob flips status back to .scanning synchronously,
        // posts pauseGate.resume().
        model.resumeJob(job)
        #expect(job.status == .scanning, "resumeJob must set status synchronously")
        await Task.yield()
        let gatePausedAfterResume = await job.pauseGate.isPaused
        #expect(!gatePausedAfterResume, "PauseGate.isPaused should be false after resumeJob")
    }

    // MARK: - 4. removeJob removes the job from the array
    //
    // Refactor risk: removeJob calls scanTask?.cancel() and timerTask?.cancel()
    // before removing the job from the array. scanTask/timerTask are
    // `fileprivate` — not observable from a test target (gap below). What we
    // CAN assert: the job is gone from `jobs` after removal. The existing
    // lifecycle suite covers happy-path; this pins the contract that
    // removeJob is the ONLY exit point — no double-removal, no orphan.

    @Test func removeJobRemovesEvenWhenJobHasNoTasks() {
        // ScanJob created in tests has scanTask=nil, timerTask=nil
        // (both fileprivate — see gap log). The cancel calls on nil are
        // no-ops — pin that removeJob doesn't crash on a job that never
        // started, and pin the array-removal contract (idempotent on a
        // missing job).
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        #expect(model.jobs.count == 1)

        model.removeJob(job)

        #expect(model.jobs.isEmpty, "Job should be removed from array")
        // Calling remove again on the same job must be a safe no-op
        // (current implementation: `removeAll { $0.id == job.id }` over
        // an empty array is fine).
        model.removeJob(job)
        #expect(model.jobs.isEmpty, "Double removeJob must be a safe no-op")
    }

    // MARK: - 5. restoreFromCache no-op path: no profile → status stays idle
    //
    // Refactor risk: restoreFromCache has three early-return guards
    // (status.isIdle, assignedProfile non-nil + searchPath non-empty,
    // refIdentifiers non-empty). When restoreFromCache moves to the
    // JobLifecycle sub-file, these guards must come with it. The most
    // common no-op trigger in practice is "no profile yet" — pin that.

    @Test func restoreFromCacheWithoutProfileIsNoOp() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")  // reachable path
        // No assignedProfile → guard fails on line 874.
        #expect(job.assignedProfile == nil, "Precondition: no profile")
        #expect(job.status == .idle, "Precondition: idle")
        let preLineCount = job.consoleLines.count
        let preResultCount = job.results.count

        model.restoreFromCache(job: job)

        // Guard returns silently — no status change, no log lines, no results.
        // (scanTask spin-up is the other side of the contract but scanTask
        // is fileprivate — see gap log; the observable surface here is
        // status + consoleLines + results.)
        #expect(job.status == .idle, "Status must stay .idle when no profile")
        #expect(job.consoleLines.count == preLineCount,
                "restoreFromCache must not log when bailing on missing profile")
        #expect(job.results.count == preResultCount, "Results must remain unchanged")
    }

    @Test func restoreFromCacheWithEmptySearchPathIsNoOp() {
        // Second guard branch: profile present but searchPath empty.
        // Construct a profile pointing at a non-existent reference dir —
        // we never get past the profile guard so the dir doesn't matter.
        let model = PersonFinderModel()
        let profile = POIProfile(name: "T",
                                 referencePath: "/tmp/_pf_boundary_no_such_dir_",
                                 engine: RecognitionEngine.vision.rawValue)
        let job = ScanJob(searchPath: "")  // empty
        job.assignedProfile = profile
        model.jobs.append(job)
        let preLineCount = job.consoleLines.count

        model.restoreFromCache(job: job)

        #expect(job.status == .idle)
        #expect(job.consoleLines.count == preLineCount,
                "Empty searchPath guard must be silent")
    }

    // MARK: - Helpers

    /// Create a solid-gray CGImage in deviceGray colorspace. Used as input
    /// to face-detection / face-crop helpers that just need valid geometry.
    /// CGContext owns the backing store when data=nil, so the image returned
    /// remains valid after this function returns.
    nonisolated static func makeSolidCGImage(width: Int, height: Int,
                                             gray: CGFloat) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil,
                            width: width, height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Create a solid-gray CVPixelBuffer in BGRA. Mid-gray content guarantees
    /// no face will be detected — useful for negative-path face-detection tests.
    nonisolated static func makeSolidPixelBuffer(width: Int, height: Int,
                                                 gray: CGFloat) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pb)
        guard status == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let value = UInt8(max(0, min(255, gray * 255)))
        // Fill BGRA: B=G=R=value, A=255.
        for y in 0..<height {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = value
                p[1] = value
                p[2] = value
                p[3] = 255
            }
        }
        return buf
    }

    // MARK: - Documented gaps for refactor-agent
    //
    // Tests intentionally NOT included here because they require visibility
    // widening (which belongs in the refactor, not the harness):
    //
    //   • pfBuildSortedClipEntries — `private func` at file scope; the
    //     pfClipEntry value type it returns is also `private struct`.
    //     UNBLOCK: when the refactor moves these into Compilation.swift,
    //     either keep them `internal` (preferred — tests are intra-target)
    //     or mark them with a small `// MARK: - testable` extension. Then
    //     write: sort-by-year-ascending, ties-broken-by-path-ascending,
    //     empty-input returns empty.
    //
    //   • pfExtractYear — `private func` at file scope. Same fix as above.
    //     The interesting characterization cases (current behavior):
    //       - path containing "/2018/" → returns 2018
    //       - path with no 4-digit year → returns 0 (or whatever current
    //         sentinel is — pin it as-is even if it seems quirky)
    //       - path with multiple year-like substrings (e.g.
    //         "/projects/2020-archive/2018-summer/clip.mov") — pin
    //         whichever the current scanner picks; the current impl uses
    //         a regex pass and likely returns first match, but verify.
    //
    //   • ScanJob.scanTask / .timerTask cancellation observation — both
    //     are `fileprivate`. UNBLOCK: change to `internal` (the lifecycle
    //     orchestration is moving to a coordinator anyway, so external
    //     visibility is acceptable for the new contract). With access,
    //     a test can call removeJob on a job with a real scanTask and
    //     assert `job.scanTask?.isCancelled == true` before nil-out.
    //
    //   • restoreFromCache with a populated cache → empty results path.
    //     The cache is a process-wide singleton (PersonFinderCache.shared)
    //     and writing test entries pollutes Rick's actual cache file. The
    //     refactor should accept an injected cache (or a protocol) so
    //     a fake cache can be substituted in tests. Until then, only the
    //     guard-side no-op paths are tested above.
}
