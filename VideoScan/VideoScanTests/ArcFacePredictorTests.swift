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
}
