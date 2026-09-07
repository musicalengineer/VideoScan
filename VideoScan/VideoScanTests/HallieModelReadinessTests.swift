import Foundation
import SwiftUI
import Testing
@testable import VideoScan

/// The Archivist Brain pane's three new honesty features (Rick, 2026-09-06):
/// what the model costs, whether it is ready HERE, and whether two servers
/// serving one tag are serving the same bytes.
@Suite("Model readiness, memory and identity")
struct HallieModelReadinessTests {

    // MARK: rounding

    /// Rounds UP, always. This number answers "will it fit", and rounding
    /// 22.7 down to 22 answers that question wrong in the one direction
    /// that costs something.
    @Test func memorySizeRoundsUpNeverDown() {
        let gb: (Double) -> Int64 = { Int64($0 * 1_073_741_824) }
        #expect(ArchivistEndpointSettings.roundedGB(gb(22.7)) == 23)
        #expect(ArchivistEndpointSettings.roundedGB(gb(18.2)) == 19)
        #expect(ArchivistEndpointSettings.roundedGB(gb(24.0)) == 24)
        #expect(ArchivistEndpointSettings.roundedGB(gb(0.1)) == 1, "never zero GB")
        #expect(ArchivistEndpointSettings.roundedGB(0) == 1)
    }

    // MARK: what a server holds vs what it could load

    private func translator(
        tags: String, ps: String
    ) -> OllamaQueryTranslator {
        var t = OllamaQueryTranslator()
        t.host = "example.local"
        t.transport = .fake { url, _ in
            if url.hasSuffix("/api/ps") { return .ok(ps) }
            if url.hasSuffix("/api/tags") { return .ok(tags) }
            return .down("unexpected \(url)")
        }
        return t
    }

    /// The live shapes from Rick's M4, 2026-09-06: /api/tags reports the
    /// ON-DISK size, /api/ps the RESIDENT size. 18.2 GB and 22.7 GB for the
    /// same model — the difference is the KV cache at our 32K context, and
    /// conflating them would understate what the machine gives up.
    @Test func diskSizeAndResidentSizeAreReadFromTheirOwnEndpoints() async {
        let t = translator(
            tags: #"{"models":[{"name":"qwen3.8:27b-mlx","size":18200000000,"digest":"sha256:5642e97495e1"}]}"#,
            ps: #"{"models":[{"name":"qwen3.8:27b-mlx","size":22700000000,"digest":"sha256:5642e97495e1"}]}"#)

        let installed = await t.installedModelFacts()
        #expect(installed.count == 1)
        #expect(installed.first?.bytes == 18_200_000_000)
        #expect(installed.first?.digest == "sha256:5642e97495e1")

        let resident = await t.residentModelFacts()
        #expect(resident.first?.bytes == 22_700_000_000)

        // And the figure a human is shown is the resident one, rounded up.
        #expect(ArchivistEndpointSettings.roundedGB(resident.first!.bytes) == 22
                || ArchivistEndpointSettings.roundedGB(resident.first!.bytes) == 22 + 1)
    }

    /// A host with the model installed but nothing loaded — exactly what
    /// RicksM4.local looked like when its green "online" light sat beside a
    /// restart report saying no answer. Both were true.
    @Test func aHostThatHasTheModelButHasNotLoadedItIsCold() async {
        let t = translator(
            tags: #"{"models":[{"name":"qwen3.8:27b-mlx","size":18200000000,"digest":"sha256:abc"}]}"#,
            ps: #"{"models":[]}"#)
        #expect(await t.installedModelFacts().contains { $0.name == "qwen3.8:27b-mlx" })
        #expect(await t.residentModelFacts().isEmpty)
    }

    /// A host serving a DIFFERENT model — ricksm5 was holding
    /// qwen3.6:35b-a3b-nvfp4 while the configured tag was qwen3.8:27b-mlx.
    @Test func aHostHoldingSomeOtherModelDoesNotCountAsReady() async {
        let t = translator(
            tags: #"{"models":[{"name":"qwen3.6:35b-a3b-nvfp4","size":23600000000,"digest":"sha256:e92a"}]}"#,
            ps: #"{"models":[{"name":"qwen3.6:35b-a3b-nvfp4","size":23600000000,"digest":"sha256:e92a"}]}"#)
        let installed = await t.installedModelFacts()
        #expect(!installed.contains { $0.name == "qwen3.8:27b-mlx" },
                "the configured tag is absent here, which is 'missing', not 'ready'")
    }

    @Test func anUnreachableHostYieldsNoFactsRatherThanThrowing() async {
        var t = OllamaQueryTranslator()
        t.transport = .fake { _, _ in .down("connection refused") }
        #expect(await t.installedModelFacts().isEmpty)
        #expect(await t.residentModelFacts().isEmpty)
    }

    /// Malformed output must not crash or invent facts.
    @Test func garbageFromAServerYieldsNoFacts() async {
        let t = translator(tags: #"{"models":"not-an-array"}"#, ps: #"not json"#)
        #expect(await t.installedModelFacts().isEmpty)
        #expect(await t.residentModelFacts().isEmpty)
    }

    /// An entry with no digest is still usable for size and readiness — the
    /// digest is an extra, and its absence must not drop the model.
    @Test func aModelWithoutADigestIsStillReported() async {
        let t = translator(
            tags: #"{"models":[{"name":"qwen3.8:27b-mlx","size":18200000000}]}"#,
            ps: #"{"models":[]}"#)
        let facts = await t.installedModelFacts()
        #expect(facts.first?.name == "qwen3.8:27b-mlx")
        #expect(facts.first?.digest == "")
    }

    /// The Restart verdict has to reach the LOG, not only the pane. Rick
    /// went looking in videoscan.log for whether the schema had been
    /// accepted and found nothing — the answer existed only in a view.
    @Test func everyProbeVerdictHasAWordForTheLog() {
        let words: [OllamaQueryTranslator.StructuredOutputProbe: String] = [
            .available: "accepted",
            .unverified: "accepted but not obeyed",
            .refused: "refused",
            .unreachable: "not answered",
        ]
        for (verdict, fragment) in words {
            let said = ArchivistEndpointSettings.probeWord(verdict)
            #expect(said.contains(fragment), Comment(rawValue: "\(verdict) → \(said)"))
        }
        // "accepted" must not be how a REFUSAL reads at a glance in a log.
        #expect(!ArchivistEndpointSettings.probeWord(.refused).hasPrefix("accepted"))
        #expect(!ArchivistEndpointSettings.probeWord(.unreachable).hasPrefix("accepted"))
    }

    // MARK: the readiness lights are their own vocabulary

    /// Deliberately NOT folded into `Liveness`. Rick ruled an offline HOST
    /// is yellow, not red — a sleeping laptop is normal. Red here means
    /// something else: asking this server for this model will fail.
    @Test func modelReadinessColoursAreDistinctFromHostLiveness() {
        #expect(ArchivistEndpointSettings.ModelReadiness.resident.color == .green)
        #expect(ArchivistEndpointSettings.ModelReadiness.cold.color == .yellow)
        #expect(ArchivistEndpointSettings.ModelReadiness.missing.color == .red)
        // Rick's ruling on the host light stands, untouched.
        #expect(ArchivistEndpointSettings.Liveness.offline("asleep").color == .yellow)
    }

    @Test func everyReadinessStateExplainsItselfExceptUnknown() {
        for state: ArchivistEndpointSettings.ModelReadiness in [.resident, .cold, .missing] {
            #expect(!state.label.isEmpty)
            #expect(state.detail.count > 20, Comment(rawValue: state.label))
        }
        #expect(ArchivistEndpointSettings.ModelReadiness.unknown.label.isEmpty,
                "an unasked host shows no second light at all")
    }
}
