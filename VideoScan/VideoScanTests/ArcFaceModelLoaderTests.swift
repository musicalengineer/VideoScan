import Testing
import CoreML
@testable import VideoScan

/// Regression tests for `ArcFaceModelLoader`.
///
/// Locks down the contract that the loader must return DISTINCT MLModel
/// instances across calls. This is the load-bearing property that prevents
/// the MLE5BindEmptyMemoryObjectToPort crash when multiple worker threads
/// run prediction in parallel during an ArcFace search.
///
/// History: prior to 2026-05-11 the loader cached a single MLModel across
/// all calls. Running concurrent searches (or one search with a parallel
/// worker pool) hit a CoreML MLE5 race where two threads' prediction calls
/// raced on the same output port → SIGABRT crash. Fix: cache the resolved
/// model URL, construct a fresh MLModel per `getModel()` call.
///
/// See memory note `project_arcface_concurrency_bug.md` and crash report
/// `~/Library/Logs/DiagnosticReports/VideoScan-2026-05-11-202800.ips`.
@Suite("ArcFace Model Loader") struct ArcFaceModelLoaderTests {

    // regression: 2026-05-11 — concurrent prediction on shared MLModel crashed
    @Test func getModelReturnsDistinctInstancesAcrossCalls() async {
        let (m1, _) = await ArcFaceModelLoader.shared.getModel()
        let (m2, _) = await ArcFaceModelLoader.shared.getModel()

        // If the model isn't present on this machine the test can't make a
        // meaningful assertion — skip rather than fail. ArcFace model lives
        // at ~/dev/VideoScan/models/w600k_r50.{mlmodelc,mlpackage} or in the
        // app bundle. Local dev should have it; CI runners may not.
        guard let m1, let m2 else {
            // No model available — nothing to verify. Treat as inconclusive.
            return
        }

        // With the singleton-cached MLModel bug (pre-fix), m1 === m2 because
        // both calls returned the same cached instance. After the fix each
        // call constructs a fresh MLModel, so identities differ.
        //
        // This is the property that makes concurrent prediction safe: the
        // MLE5 engine state is per-MLModel, so two callers with two MLModels
        // do not race on a shared output port.
        #expect(m1 !== m2, "ArcFaceModelLoader.getModel() must return a fresh MLModel per call; sharing causes MLE5BindEmptyMemoryObjectToPort races under concurrent inference")
    }

    // regression: 2026-05-11 — actual crash reproducer (stress test).
    //
    // This test exercises the failure mode end-to-end: many concurrent tasks
    // each do their own getModel() + run real CoreML predictions. With the
    // pre-fix singleton cache, all tasks would receive the SAME MLModel and
    // their concurrent prediction calls would race on the MLE5 output port,
    // typically crashing the test host with SIGABRT inside
    // MLE5BindEmptyMemoryObjectToPort within a few seconds.
    //
    // With the fix in place (per-job MLModel), each task gets its own
    // instance — no shared MLE5 state, no race — and the suite completes
    // cleanly.
    //
    // Heavier than the property test above. Skip-gated on model presence
    // (CI runners without ArcFace model on disk just return cleanly).
    @Test func concurrentPredictionsAcrossJobsDoNotCrash() async throws {
        // Quick gate: only run if the model is actually available.
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return }

        // Synthetic 112x112 test image (solid gray). Real face content not
        // needed — we just need *valid* MLFeatureProvider input so the
        // prediction path executes. The bug fires on the CoreML output-port
        // binding regardless of input content.
        guard let testImage = makeSyntheticFaceImage() else {
            Issue.record("Could not construct synthetic test image")
            return
        }

        // Stress parameters. Many OS threads + many predictions per thread,
        // launched via Thread (not Task) to bypass Swift Concurrency's
        // cooperative scheduling — gives us genuine parallel kernel-level
        // contention, which is what triggers the MLE5 output-port race.
        // Synchronization barrier ensures all threads enter the prediction
        // loop at the same instant for maximum simultaneous contention.
        //
        // Tuning: 16 threads × 200 predictions = 3,200 predictions with
        // ~16 simultaneously in flight at peak. The pre-fix singleton bug
        // crashes the test host with SIGABRT inside MLE5BindEmptyMemoryObjectToPort
        // within seconds; the fix makes this scenario safe because each
        // thread has its own MLModel.
        let threadCount = 16
        let predictionsPerThread = 200

        // Pre-load N models in serial first — getModel() is actor-isolated,
        // so we can't call it from raw threads cleanly. Loading them up-front
        // also matches the pre-fix bug pattern exactly: with the bug, all N
        // of these would be the SAME object (singleton cache).
        var models: [MLModel] = []
        for _ in 0..<threadCount {
            let (m, _) = await ArcFaceModelLoader.shared.getModel()
            if let m { models.append(m) }
        }
        guard models.count == threadCount else {
            Issue.record("Couldn't load \(threadCount) models — got \(models.count)")
            return
        }

        // Barrier so all threads enter the hot loop at exactly the same
        // moment — maximum simultaneous contention is what triggers the
        // MLE5 race.
        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for i in 0..<threadCount {
            let model = models[i]
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }

                counterLock.lock()
                readyCount += 1
                let nowReady = readyCount
                counterLock.unlock()
                if nowReady == threadCount {
                    for _ in 0..<threadCount { startBarrier.signal() }
                }
                startBarrier.wait()

                // Hot loop — tight prediction calls with no yields. With the
                // pre-fix singleton bug, all threads share `model` and race
                // here, crashing the process inside MLE5BindEmptyMemoryObjectToPort.
                for _ in 0..<predictionsPerThread {
                    _ = arcfaceEmbedding(from: testImage, model: model)
                }
            }
        }
        // Wait for all threads. If any thread crashed the host process with
        // SIGABRT, xcodebuild reports the test as crashed (this wait never
        // returns because the process is already dead).
        group.wait()

        // Reaching this line means all threads completed without crashing.
        // Under the pre-fix singleton bug, the test process would have died
        // inside MLE5BindEmptyMemoryObjectToPort.
        #expect(true, "Concurrent prediction across per-thread MLModels completed without SIGABRT")
    }

    /// Build a 112x112 gray CGImage suitable as ArcFace input. The pixel
    /// content is irrelevant for the race-condition reproduction.
    private func makeSyntheticFaceImage() -> CGImage? {
        let size = 112
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
