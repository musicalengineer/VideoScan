// ArcFacePredictorTests.swift
// Guards the safety-critical invariant: ArcFace inference is SERIALIZED by
// default (K=1). Serialization is what protects the reproduced MLE5
// BindEmptyMemoryObjectToPort crash; the concurrent pool (K>1) is opt-in and
// experimental. These tests must NOT configure K>1, because ArcFacePredictor
// is a process-wide singleton and a pool would leak into other suites' arcface
// inference. They only assert the default + serialized configuration.

import Testing
@testable import VideoScan

@Suite("ArcFacePredictor — serialized-by-default invariant")
struct ArcFacePredictorTests {

    @Test("Default concurrency is 1 (serialized)")
    func defaultIsSerialized() {
        #expect(ArcFacePredictor.shared.concurrency == 1)
    }

    @Test("configure(1) keeps the predictor serialized")
    func configureOneStaysSerialized() async {
        await ArcFacePredictor.shared.configure(concurrency: 1)
        #expect(ArcFacePredictor.shared.concurrency == 1)
    }

    @Test("configure clamps non-positive K up to 1")
    func configureClampsToSerialized() async {
        await ArcFacePredictor.shared.configure(concurrency: 0)
        #expect(ArcFacePredictor.shared.concurrency == 1)
        await ArcFacePredictor.shared.configure(concurrency: -4)
        #expect(ArcFacePredictor.shared.concurrency == 1)
    }

    @Test("The persisted flag defaults to 1 in PersonFinderSettings")
    func settingDefaultsToSerialized() {
        #expect(PersonFinderSettings().arcfaceInferenceConcurrency == 1)
    }


    /// Swift 6 stage 4 (#376): the pool moved into `OSAllocatedUnfairLock<Pool>`
    /// and the class is `Sendable`. Eight tasks reading `concurrency` while
    /// others call `configure(1)` must always see the serialized pool — the
    /// state is reachable only through the lock. (Never K>1 here; see the
    /// header.)
    @Test("concurrent configure(1) and concurrency reads always see 1")
    func concurrentReadersAndConfigureAgree() async {
        let seen = await withTaskGroup(of: Int.self, returning: Set<Int>.self) { group in
            for lane in 0..<8 {
                group.addTask {
                    var worst = 1
                    for _ in 0..<200 {
                        if lane % 2 == 0 { await ArcFacePredictor.shared.configure(concurrency: 1) }
                        worst = max(worst, ArcFacePredictor.shared.concurrency)
                    }
                    return worst
                }
            }
            return await group.reduce(into: Set<Int>()) { $0.insert($1) }
        }
        #expect(seen == [1])
    }
}
