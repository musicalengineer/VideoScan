import Foundation
import Testing
@testable import VideoScan

/// 2026-09-29 (Rick: "Hallie's voice regressed after the upgrade"): launched
/// from Xcode 27 the app carries MTL_DEBUG_LAYER=1, the Kokoro engine
/// inherited it, and Metal's validation layer aborted it on every sentence
/// ("setBytes … bytes argument cannot be nil", exit 6) — Hallie fell back to
/// Apple speech. Reproduced by hand: the same engine and text exit -6 with
/// MTL_DEBUG_LAYER=1 and write the WAV without it.
@Suite("Hallie neural voice — the engine never inherits Metal debug switches")
struct HallieNeuralWorkerEnvironmentTests {

    @Test func metalDebugSwitchesAreDroppedEverythingElseKept() {
        let parent = [
            "MTL_DEBUG_LAYER": "1",
            "MTL_DEBUG_LAYER_VALIDATE_LOAD_ACTIONS": "0",
            "MTL_SHADER_VALIDATION": "1",
            "METAL_DEVICE_WRAPPER_TYPE": "1",
            "METAL_DEBUG_ERROR_MODE": "0",
            "HOME": "/Users/test", "PATH": "/usr/bin", "TMPDIR": "/tmp/x",
            "MTL_HUD_ENABLED": "1",          // not a debug switch — kept
        ]
        let env = HallieNeuralSpeech.workerEnvironment(parent)
        #expect(env == ["HOME": "/Users/test", "PATH": "/usr/bin", "TMPDIR": "/tmp/x", "MTL_HUD_ENABLED": "1"])
    }

    @Test func aCleanEnvironmentPassesThroughUnchanged() {
        let parent = ["HOME": "/Users/test", "LANG": "en_US.UTF-8"]
        #expect(HallieNeuralSpeech.workerEnvironment(parent) == parent)
    }

    /// SENSOR: every engine launch in HallieNeuralSpeech.swift sets its
    /// environment through workerEnvironment() — a new launch site that
    /// forgets would silently bring the Apple-speech fallback back.
    @Test func everyEngineLaunchUsesTheFilteredEnvironment() throws {
        let source = try String(contentsOf: Self.sourceURL("VideoScan/HallieNeuralSpeech.swift"), encoding: .utf8)
        let launches = source.components(separatedBy: "Process()").count - 1
        let filtered = source.components(separatedBy: "process.environment = HallieNeuralSpeech.workerEnvironment()").count - 1
        #expect(launches >= 2, "expected the worker and the legacy helper launches")
        #expect(filtered == launches, "\(launches) Process() launches, \(filtered) with the filtered environment")
    }

    private static func sourceURL(_ relative: String) -> URL {
        // …/VideoScan/VideoScanTests/<this file> → …/VideoScan/<relative>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
