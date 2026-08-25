import Foundation
import Testing
@testable import VideoScan

// HallieHelperFailure (2026-08-25): the reply must name what actually
// happened. A bad model answer is NOT a network problem, and telling
// Rick to "try again in a moment" for one sends him to wake hosts that
// are awake.
struct HallieHelperFailureTests {

    @Test func badResponseIsUnusableAnswerNotUnreachable() {
        let e = NLTranslatorError.badResponse("content is not a strict ArchivistQueryAST")
        #expect(HallieHelperFailure.kind(of: e) == .unusableAnswer)
        let m = HallieHelperFailure.message(for: e)
        #expect(m.contains("say it another way"))
        #expect(!m.contains("reaching"))
        #expect(m.contains("didn't search the archive"), "fail-closed sentence stays")
    }

    @Test func hostShapedErrorsAreUnreachable() {
        for e: Error in [NLTranslatorError.unreachable("asleep"),
                         NLTranslatorError.serverError(status: 503, detail: ""),
                         NLTranslatorError.modelUnavailable("x"),
                         URLError(.timedOut)] {
            #expect(HallieHelperFailure.kind(of: e) == .unreachable)
            let m = HallieHelperFailure.message(for: e)
            #expect(m.contains("reaching my language helper"))
            #expect(m.contains("didn't search the archive"))
        }
    }
}
