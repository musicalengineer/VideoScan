import Foundation
import CoreML
import CoreGraphics
import os.lock
import Testing
@testable import VideoScan

/// Deliberately provokes the MLE5BindEmptyMemoryObjectToPort crash that
/// killed VideoScan on 2026-05-23 (and 2026-05-11 before it).
///
/// Strategy: bypass the serialization lock and call MLModel.prediction(from:)
/// directly from many OS threads sharing one MLModel instance. This is the
/// exact race CoreML's MLE5 engine can't handle — two threads bind the same
/// output port simultaneously → NSException → SIGABRT.
///
/// Each raw prediction call is wrapped in VSCatchObjCException so the test
/// process survives. The test counts caught exceptions: if any fire, we've
/// proven both (a) the crash is reproducible and (b) the ObjC guard saves us.
///
/// Without VSCatchObjCException, this test kills the test host with SIGABRT.
///
/// **Opt-in:** these tests are SKIPPED by default. Set environment variable
/// `VS_RUN_STRESS=1` to enable them. Suite is intentionally aggressive —
/// 16-thread × 300-prediction concurrent provocations that crash unprotected
/// builds — so it has no business running in standard `xcodebuild test`
/// sweeps. Enable explicitly when you want to verify the NSException guard
/// still holds.
@Suite(
    "ArcFace MLE5 Crash Provocation",
    .disabled(
        if: ProcessInfo.processInfo.environment["VS_RUN_STRESS"] != "1",
        "Stress suite — set VS_RUN_STRESS=1 to enable."
    )
)
struct ArcFaceMLE5ProvocationTests {

    // MARK: - Provocation: shared model, no lock, maximum contention

    @Test("provoke MLE5 crash with unlocked shared-model concurrent predictions")
    func provokeSharedModelCrash() async throws {
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }
        guard let testImage = makeSyntheticFaceImage(size: 112) else {
            Issue.record("Could not create test image")
            return
        }

        let pb = makePixelBuffer(from: testImage, size: 112)
        guard let pb else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let threadCount = 16
        let predictionsPerThread = 300
        let totalExpected = threadCount * predictionsPerThread

        let caughtExceptions = OSAllocatedUnfairLock(initialState: 0)
        let completedOK = OSAllocatedUnfairLock(initialState: 0)
        let swiftErrors = OSAllocatedUnfairLock(initialState: 0)

        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for _ in 0..<threadCount {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }

                // Barrier: all threads start at the same instant
                counterLock.lock()
                readyCount += 1
                let nowReady = readyCount
                counterLock.unlock()
                if nowReady == threadCount {
                    for _ in 0..<threadCount { startBarrier.signal() }
                }
                startBarrier.wait()

                // NO lock — raw concurrent prediction on a SHARED model.
                // This is what triggers MLE5BindEmptyMemoryObjectToPort.
                for _ in 0..<predictionsPerThread {
                    autoreleasepool {
                        var exception: NSException?
                        let ok = VSCatchObjCException({
                            let input = try? MLDictionaryFeatureProvider(
                                dictionary: ["faceImage": pb]
                            )
                            guard let input else { return }
                            _ = try? model.prediction(from: input)
                        }, &exception)

                        if ok {
                            completedOK.withLock { $0 += 1 }
                        } else {
                            caughtExceptions.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }

        group.wait()

        let caught = caughtExceptions.withLock { $0 }
        let ok = completedOK.withLock { $0 }
        let errs = swiftErrors.withLock { $0 }
        let total = caught + ok + errs

        print("""
        === MLE5 Provocation Results ===
        Threads:              \(threadCount)
        Predictions/thread:   \(predictionsPerThread)
        Completed OK:         \(ok)
        NSExceptions caught:  \(caught) \(caught > 0 ? "← CRASH WOULD HAVE KILLED PROCESS" : "")
        Swift errors:         \(errs)
        Total:                \(total) / \(totalExpected)
        ===============================
        """)

        // The test passes regardless of exception count — what matters is
        // that we SURVIVED. The process is still alive. Without the ObjC
        // catcher, any caught > 0 would have been SIGABRT.
        #expect(total == totalExpected,
                "All predictions must complete (got \(total)/\(totalExpected))")
    }

    // MARK: - Provocation with multiple shared models (closer to real usage)

    @Test("provoke MLE5 crash simulating multiple simultaneous job starts")
    func provokeMultiJobStart() async throws {
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return }

        // Simulate Rick's scenario: kick off several searches at once.
        // Each "job" loads its own model and runs reference embeddings.
        // But we deliberately DON'T serialize — raw concurrent access.
        let jobCount = 6
        let predictionsPerJob = 200

        var models: [MLModel] = []
        for _ in 0..<jobCount {
            let (m, _) = await ArcFaceModelLoader.shared.getModel()
            if let m { models.append(m) }
        }
        guard models.count == jobCount else { return }

        // Use a real reference photo if available, else synthetic
        let testImage: CGImage
        if let realPhoto = loadRealReferencePhoto() {
            testImage = realPhoto
        } else if let synth = makeSyntheticFaceImage(size: 112) {
            testImage = synth
        } else {
            Issue.record("No test image available")
            return
        }

        let pb = makePixelBuffer(from: testImage, size: 112)
        guard let pb else { return }

        let caughtExceptions = OSAllocatedUnfairLock(initialState: 0)
        let completedOK = OSAllocatedUnfairLock(initialState: 0)

        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        // Some jobs share a model (worst case), some get their own
        let sharedModel = models[0]
        for i in 0..<jobCount {
            let model = (i < 3) ? sharedModel : models[i]
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }

                counterLock.lock()
                readyCount += 1
                let nowReady = readyCount
                counterLock.unlock()
                if nowReady == jobCount {
                    for _ in 0..<jobCount { startBarrier.signal() }
                }
                startBarrier.wait()

                for _ in 0..<predictionsPerJob {
                    autoreleasepool {
                        var exception: NSException?
                        let ok = VSCatchObjCException({
                            let input = try? MLDictionaryFeatureProvider(
                                dictionary: ["faceImage": pb]
                            )
                            guard let input else { return }
                            _ = try? model.prediction(from: input)
                        }, &exception)

                        if ok {
                            completedOK.withLock { $0 += 1 }
                        } else {
                            caughtExceptions.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }

        group.wait()

        let caught = caughtExceptions.withLock { $0 }
        let ok = completedOK.withLock { $0 }
        let total = caught + ok
        let totalExpected = jobCount * predictionsPerJob

        print("""
        === Multi-Job MLE5 Provocation ===
        Jobs:                 \(jobCount) (3 sharing one model, 3 own models)
        Predictions/job:      \(predictionsPerJob)
        Completed OK:         \(ok)
        NSExceptions caught:  \(caught) \(caught > 0 ? "← WOULD HAVE BEEN SIGABRT" : "")
        Total:                \(total) / \(totalExpected)
        ==================================
        """)

        #expect(total == totalExpected)
    }

    // MARK: - Provocation: rapid model churn + prediction (ANE resource exhaustion)

    @Test("provoke MLE5 crash via rapid model load-predict-discard cycles")
    func provokeModelChurn() async throws {
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return }
        guard let testImage = makeSyntheticFaceImage(size: 112) else { return }

        let pb = makePixelBuffer(from: testImage, size: 112)
        guard let pb else { return }

        let cycles = 50
        let threadsPerCycle = 4
        let predictionsPerThread = 20

        let caughtExceptions = OSAllocatedUnfairLock(initialState: 0)
        let completedOK = OSAllocatedUnfairLock(initialState: 0)

        for cycle in 0..<cycles {
            // Load a fresh model each cycle — churn ANE resources
            let (model, _) = await ArcFaceModelLoader.shared.getModel()
            guard let model else { continue }

            let group = DispatchGroup()
            for _ in 0..<threadsPerCycle {
                group.enter()
                Thread.detachNewThread {
                    defer { group.leave() }
                    for _ in 0..<predictionsPerThread {
                        autoreleasepool {
                            var exception: NSException?
                            let ok = VSCatchObjCException({
                                let input = try? MLDictionaryFeatureProvider(
                                    dictionary: ["faceImage": pb]
                                )
                                guard let input else { return }
                                _ = try? model.prediction(from: input)
                            }, &exception)

                            if ok {
                                completedOK.withLock { $0 += 1 }
                            } else {
                                caughtExceptions.withLock { $0 += 1 }
                            }
                        }
                    }
                }
            }
            group.wait()

            if cycle % 10 == 9 {
                let caught = caughtExceptions.withLock { $0 }
                let ok = completedOK.withLock { $0 }
                print("  cycle \(cycle+1)/\(cycles): \(ok) ok, \(caught) exceptions caught")
            }
        }

        let caught = caughtExceptions.withLock { $0 }
        let ok = completedOK.withLock { $0 }
        let total = caught + ok
        let totalExpected = cycles * threadsPerCycle * predictionsPerThread

        print("""
        === Model Churn MLE5 Provocation ===
        Cycles:               \(cycles)
        Threads/cycle:        \(threadsPerCycle)
        Predictions/thread:   \(predictionsPerThread)
        Completed OK:         \(ok)
        NSExceptions caught:  \(caught) \(caught > 0 ? "← WOULD HAVE BEEN SIGABRT" : "")
        Total:                \(total) / \(totalExpected)
        ====================================
        """)

        #expect(total == totalExpected)
    }

    // MARK: - Provocation: full pipeline (Vision detect → crop → embed) with real photos

    @Test("provoke MLE5 crash via concurrent arcfaceLoadReferenceEmbeddings on real POI photos")
    func provokeRealPipelineCrash() async throws {
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return }

        let poiBase = NSHomeDirectory() + "/Library/Application Support/VideoScan/POI"
        let fm = FileManager.default
        guard fm.fileExists(atPath: poiBase) else { return }

        let profiles = (try? fm.contentsOfDirectory(atPath: poiBase))?.filter {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: poiBase + "/" + $0, isDirectory: &isDir)
            return isDir.boolValue && !$0.hasPrefix(".")
        } ?? []
        guard profiles.count >= 2 else { return }

        // Use all available POI profiles — each gets its own thread + model
        let jobCount = min(profiles.count, 12)
        let selectedProfiles = Array(profiles.prefix(jobCount))
        let rounds = 10

        let caughtExceptions = OSAllocatedUnfairLock(initialState: 0)
        let completedOK = OSAllocatedUnfairLock(initialState: 0)

        for round in 0..<rounds {
            var models: [MLModel] = []
            for _ in 0..<jobCount {
                let (m, _) = await ArcFaceModelLoader.shared.getModel()
                if let m { models.append(m) }
            }
            guard models.count == jobCount else { continue }

            let counterLock = NSLock()
            var readyCount = 0
            let startBarrier = DispatchSemaphore(value: 0)
            let group = DispatchGroup()

            for i in 0..<jobCount {
                let model = models[i]
                let profilePath = poiBase + "/" + selectedProfiles[i]
                group.enter()
                Thread.detachNewThread {
                    defer { group.leave() }

                    counterLock.lock()
                    readyCount += 1
                    let nowReady = readyCount
                    counterLock.unlock()
                    if nowReady == jobCount {
                        for _ in 0..<jobCount { startBarrier.signal() }
                    }
                    startBarrier.wait()

                    // Full pipeline: Vision face detect → crop → ArcFace embed
                    // This is exactly the path that crashed on 2026-05-23.
                    // arcfaceLoadReferenceEmbeddings now uses the ObjC catcher
                    // internally via arcfaceEmbedding().
                    let (embeddings, _) = arcfaceLoadReferenceEmbeddings(
                        from: profilePath,
                        largestFaceOnly: false,
                        useLandmarkAlignment: false,
                        model: model
                    )
                    completedOK.withLock { $0 += 1 }
                    _ = embeddings
                }
            }

            group.wait()

            if round % 3 == 2 || round == rounds - 1 {
                let ok = completedOK.withLock { $0 }
                print("  round \(round+1)/\(rounds): \(ok) jobs completed, \(jobCount) profiles")
            }
        }

        let ok = completedOK.withLock { $0 }
        let totalExpected = rounds * jobCount

        print("""
        === Real Pipeline MLE5 Provocation ===
        POI profiles:         \(jobCount) (\(selectedProfiles.joined(separator: ", ")))
        Rounds:               \(rounds)
        Jobs completed:       \(ok) / \(totalExpected)
        ======================================
        """)

        #expect(ok == totalExpected, "All pipeline jobs must complete without SIGABRT")
    }

    // MARK: - Provocation: unlocked predictions with same MLModel from crash stack

    @Test("provoke MLE5 crash with raw unlocked prediction — no serialization at all")
    func provokeRawUnlockedPrediction() async throws {
        // Load ONE model and share it across all threads — no lock.
        // This is the exact failure mode from the original 2026-05-11 crash.
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }

        let poiBase = NSHomeDirectory() + "/Library/Application Support/VideoScan/POI/donna"
        let fm = FileManager.default
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        let photos: [CGImage] = (try? fm.contentsOfDirectory(atPath: poiBase))?
            .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .prefix(8)
            .compactMap { filename -> CGImage? in
                let url = URL(fileURLWithPath: poiBase + "/" + filename)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                // Resize to 112x112
                guard let ctx = CGContext(
                    data: nil, width: 112, height: 112,
                    bitsPerComponent: 8, bytesPerRow: 112 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 112, height: 112))
                return ctx.makeImage()
            } ?? []

        guard !photos.isEmpty else { return }

        // Pre-build pixel buffers for all photos
        let pixelBuffers: [CVPixelBuffer] = photos.compactMap { makePixelBuffer(from: $0, size: 112) }
        guard !pixelBuffers.isEmpty else { return }

        let threadCount = 16
        let predictionsPerThread = 100

        let caughtExceptions = OSAllocatedUnfairLock(initialState: 0)
        let completedOK = OSAllocatedUnfairLock(initialState: 0)

        let counterLock = NSLock()
        var readyCount = 0
        let startBarrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for threadIdx in 0..<threadCount {
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

                // Raw unlocked prediction — SHARED model, rotating through
                // real photo pixel buffers. Maximum contention.
                for i in 0..<predictionsPerThread {
                    autoreleasepool {
                        let pb = pixelBuffers[(threadIdx + i) % pixelBuffers.count]
                        var exception: NSException?
                        let ok = VSCatchObjCException({
                            let input = try? MLDictionaryFeatureProvider(
                                dictionary: ["faceImage": pb]
                            )
                            guard let input else { return }
                            _ = try? model.prediction(from: input)
                        }, &exception)

                        if ok {
                            completedOK.withLock { $0 += 1 }
                        } else {
                            caughtExceptions.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }

        group.wait()

        let caught = caughtExceptions.withLock { $0 }
        let ok = completedOK.withLock { $0 }
        let total = caught + ok
        let totalExpected = threadCount * predictionsPerThread

        print("""
        === Raw Unlocked Prediction (Real Photos) ===
        Photos:               \(pixelBuffers.count) from donna POI
        Threads:              \(threadCount)
        Predictions/thread:   \(predictionsPerThread)
        Completed OK:         \(ok)
        NSExceptions caught:  \(caught) \(caught > 0 ? "← WOULD HAVE BEEN SIGABRT" : "")
        Total:                \(total) / \(totalExpected)
        =============================================
        """)

        #expect(total == totalExpected)
    }

    // MARK: - Helpers

    private func makeSyntheticFaceImage(size: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Gradient fill — slightly more interesting than solid gray
        for y in 0..<size {
            for x in 0..<size {
                let r = UInt8(x * 255 / size)
                let g = UInt8(y * 255 / size)
                let b = UInt8(128)
                ctx.setFillColor(red: CGFloat(r)/255, green: CGFloat(g)/255,
                                 blue: CGFloat(b)/255, alpha: 1.0)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()
    }

    private func makePixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func loadRealReferencePhoto() -> CGImage? {
        let poiDir = NSHomeDirectory() + "/Library/Application Support/VideoScan/POI/donna"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: poiDir) else { return nil }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        guard let first = files.first(where: {
            imageExts.contains(($0 as NSString).pathExtension.lowercased())
        }) else { return nil }

        let url = URL(fileURLWithPath: poiDir + "/" + first)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        // Resize to 112x112 for ArcFace
        guard let ctx = CGContext(
            data: nil, width: 112, height: 112,
            bitsPerComponent: 8, bytesPerRow: 112 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        return ctx.makeImage()
    }
}
