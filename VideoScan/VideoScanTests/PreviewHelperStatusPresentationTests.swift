import Testing
@testable import VideoScan

struct PreviewHelperStatusPresentationTests {
    @Test func runningAndNotRunningLabelsAreTruthful() {
        #expect(PreviewHelperStatusPresentation.text(isRunning: true)
                == "Background helper: running")
        #expect(PreviewHelperStatusPresentation.text(isRunning: false)
                == "Background helper: not running")
        #expect(PreviewHelperStatusPresentation.symbolName(isRunning: true) == "circle.fill")
        #expect(PreviewHelperStatusPresentation.symbolName(isRunning: false) == "circle")
    }
}
