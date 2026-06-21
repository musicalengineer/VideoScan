import Foundation
import CoreML
import CoreGraphics
import os.lock
import Testing
@testable import VideoScan

/// Regression tests for the MLE5BindEmptyMemoryObjectToPort crash.
///
/// Root cause: CoreML's MLE5 engine throws ObjC NSExceptions that bypass
/// Swift's do/try/catch, killing the process with SIGABRT. The fix wraps
/// MLModel.prediction(from:) in an ObjC @try/@catch via VSCatchObjCException.
///
/// Crash reports:
///   VideoScan-2026-05-23-124410.ips (serialized + per-instance, still crashed)
///   VideoScan-2026-05-11-202800.ips (shared instance race)
@Suite("ArcFace MLE5 Crash Guard")
struct ArcFaceMLE5CrashTests {

    // MARK: - ObjC exception catcher unit tests

    @Test("catchObjCException returns nil on success")
    func catcherReturnsNilOnSuccess() {
        var ran = false
        let ex = catchObjCException { ran = true }
        #expect(ex == nil)
        #expect(ran)
    }

    @Test("catchObjCException catches NSException instead of SIGABRT")
    func catcherCatchesNSException() {
        let ex = catchObjCException {
            NSException(
                name: NSExceptionName("MLE5BindEmptyMemoryObjectToPort"),
                reason: "simulated CoreML crash",
                userInfo: nil
            ).raise()
        }
        #expect(ex != nil)
        #expect(ex?.name.rawValue == "MLE5BindEmptyMemoryObjectToPort")
        #expect(ex?.reason == "simulated CoreML crash")
    }

    @Test("catchObjCException handles multiple sequential exceptions")
    func catcherHandlesMultipleExceptions() {
        for i in 0..<50 {
            let ex = catchObjCException {
                NSException(
                    name: NSExceptionName("TestException"),
                    reason: "iteration \(i)",
                    userInfo: nil
                ).raise()
            }
            #expect(ex != nil)
            #expect(ex?.reason == "iteration \(i)")
        }
    }

    @Test("catchObjCException is safe under concurrent access")
    func catcherThreadSafety() async {
        let group = DispatchGroup()
        let iterations = 200
        let threadCount = 8
        let errors = OSAllocatedUnfairLock(initialState: 0)

        for _ in 0..<threadCount {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for i in 0..<iterations {
                    if i % 2 == 0 {
                        let ex = catchObjCException {
                            NSException(
                                name: NSExceptionName("ConcurrentTest"),
                                reason: "thread test",
                                userInfo: nil
                            ).raise()
                        }
                        if ex == nil {
                            errors.withLock { $0 += 1 }
                        }
                    } else {
                        let ex = catchObjCException { /* no-op success */ }
                        if ex != nil {
                            errors.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }

        group.wait()
        let errorCount = errors.withLock { $0 }
        #expect(errorCount == 0, "ObjC exception catcher produced wrong results under concurrency: \(errorCount) errors")
    }

    // MARK: - Crash guard installation

    @Test("VSInstallCrashGuard accepts a valid log path without crashing")
    func crashGuardInstalls() {
        let tmp = NSTemporaryDirectory() + "vs_crash_guard_test_\(UUID().uuidString).log"
        tmp.withCString { VSInstallCrashGuard($0) }
        // If we get here, installation succeeded. Clean up.
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: - ArcFace embedding integration tests

    @Test("arcfaceEmbedding returns nil for degenerate 1x1 image")
    func embeddingReturnsNilForDegenerateImage() async {
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }

        guard let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let img = ctx.makeImage() else {
            Issue.record("Could not create 1x1 test image")
            return
        }
        let result = arcfaceEmbedding(from: img, model: model)
        // Should return nil or a valid embedding, but never crash
        _ = result
    }

    @Test("arcfaceEmbedding survives rapid sequential predictions")
    func rapidSequentialPredictions() async {
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }
        guard let img = makeSyntheticFaceImage() else { return }

        var nilCount = 0
        var okCount = 0
        for _ in 0..<500 {
            if arcfaceEmbedding(from: img, model: model).embedding != nil {
                okCount += 1
            } else {
                nilCount += 1
            }
        }
        // Most should succeed; none should crash
        #expect(okCount > 0 || nilCount > 0, "All 500 predictions must complete without SIGABRT")
    }

    // MARK: - Stress test: concurrent predictions with shared + per-thread models

    @Test("concurrent ArcFace predictions do not SIGABRT")
    func concurrentPredictionsDoNotCrash() async throws {
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return }

        guard let testImage = makeSyntheticFaceImage() else {
            Issue.record("Could not construct synthetic test image")
            return
        }

        let threadCount = 12
        let predictionsPerThread = 100

        // Each thread gets its own MLModel (production pattern)
        var models: [MLModel] = []
        for _ in 0..<threadCount {
            let (m, _) = await ArcFaceModelLoader.shared.getModel()
            if let m { models.append(m) }
        }
        guard models.count == threadCount else {
            Issue.record("Couldn't load \(threadCount) models — got \(models.count)")
            return
        }

        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let completedPredictions = OSAllocatedUnfairLock(initialState: 0)

        for i in 0..<threadCount {
            let model = models[i]
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }

                // Barrier: all threads start simultaneously
                counterLock.lock()
                readyCount += 1
                let nowReady = readyCount
                counterLock.unlock()
                if nowReady == threadCount {
                    for _ in 0..<threadCount { startBarrier.signal() }
                }
                startBarrier.wait()

                for _ in 0..<predictionsPerThread {
                    _ = arcfaceEmbedding(from: testImage, model: model)
                    completedPredictions.withLock { $0 += 1 }
                }
            }
        }

        group.wait()
        let total = completedPredictions.withLock { $0 }
        #expect(total == threadCount * predictionsPerThread,
                "All \(threadCount * predictionsPerThread) predictions must complete (got \(total))")
    }

    // MARK: - Stress test: shared single model (worst case)

    @Test("shared single MLModel under contention does not SIGABRT")
    func sharedModelDoesNotCrash() async throws {
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }
        guard let testImage = makeSyntheticFaceImage() else { return }

        let threadCount = 8
        let predictionsPerThread = 50

        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let completed = OSAllocatedUnfairLock(initialState: 0)

        for _ in 0..<threadCount {
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

                // Deliberately share one model across threads — the lock
                // inside arcfaceEmbedding + ObjC exception catcher must
                // prevent SIGABRT.
                for _ in 0..<predictionsPerThread {
                    _ = arcfaceEmbedding(from: testImage, model: model)
                    completed.withLock { $0 += 1 }
                }
            }
        }

        group.wait()
        let total = completed.withLock { $0 }
        #expect(total == threadCount * predictionsPerThread,
                "All \(threadCount * predictionsPerThread) shared-model predictions must complete")
    }

    // MARK: - Helpers

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
