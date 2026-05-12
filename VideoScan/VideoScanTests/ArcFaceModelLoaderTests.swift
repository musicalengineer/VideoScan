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
}
