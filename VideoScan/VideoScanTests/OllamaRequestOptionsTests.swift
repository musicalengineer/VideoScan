import Testing
import Foundation
@testable import VideoScan

// Rick, 2026-09-01: "seems like memory pressure is going crazy". Two models
// were resident and each ran at its 262K maximum context, so the 27B brain
// occupied 37 GB instead of ~18. Every request now names a context window.
struct OllamaRequestOptionsTests {

    @Test func everyRequestCarriesAContextWindow() {
        let bounded = OllamaQueryTranslator.bounded(["temperature": 0, "num_predict": 512])
        #expect(bounded["num_ctx"] as? Int == OllamaQueryTranslator.defaultContextTokens)
        #expect(bounded["temperature"] as? Int == 0)
        #expect(bounded["num_predict"] as? Int == 512)
    }

    @Test func aCallerChosenWindowIsKept() {
        let bounded = OllamaQueryTranslator.bounded(["num_ctx": 4096])
        #expect(bounded["num_ctx"] as? Int == 4096)
    }

    @Test func theDefaultIsGenerousForHallieAndSmallForTheGPU() {
        // A schema, a plan and a few history turns are a few thousand
        // tokens; 262K would be the model's maximum and 8× the memory.
        #expect(OllamaQueryTranslator.defaultContextTokens >= 16_384)
        #expect(OllamaQueryTranslator.defaultContextTokens <= 65_536)
    }
}
